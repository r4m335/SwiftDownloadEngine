import Foundation

/// Priority-based, deterministic queue scheduler for torrent downloads.
///
/// Features:
/// - Enforces strict concurrency limits (`maxConcurrentTorrents`) isolated from HTTP downloads.
/// - Priority scheduling: `.high` > `.normal` > `.low`.
/// - Deterministic FIFO tie-breaking for equal priority levels using monotonically increasing sequence indices.
/// - State machine: `queued`, `checking`, `downloading`, `finished`, `seeding`, `paused`, `error`, `removed`.
/// - Preserves explicit user pause (`isExplicitlyPaused == true`) across relaunches and queue promotions.
/// - Automatically admits the next eligible queued download when active transfers pause, complete, or are removed.
/// - Thread-safe actor architecture integrating seamlessly with `TorrentPersistenceStore`.
public actor TorrentQueueScheduler {
    public let persistenceStore: TorrentPersistenceStore

    public private(set) var maxConcurrentTorrents: Int
    private var sequenceCounter: Int64
    private var records: [String: TorrentRecord] = [:]

    public init(
        persistenceStore: TorrentPersistenceStore,
        maxConcurrentTorrents: Int? = nil
    ) async throws {
        self.persistenceStore = persistenceStore
        let manifest = await persistenceStore.loadManifest()
        self.sequenceCounter = manifest.sequenceCounter
        if let explicit = maxConcurrentTorrents {
            self.maxConcurrentTorrents = max(1, explicit)
        } else if manifest.maxConcurrentTorrents > 0 {
            self.maxConcurrentTorrents = manifest.maxConcurrentTorrents
        } else {
            self.maxConcurrentTorrents = 3
        }

        // Restore persisted records into in-memory dictionary
        for record in manifest.records {
            let key = record.infoHash.lowercased()
            self.records[key] = record
        }

        // Reconcile and recover states on startup
        _ = await self.reconcileInterruptedDownloads()
    }

    // MARK: - Enqueue & Registration

    /// Enqueues a new torrent into the scheduler.
    @discardableResult
    public func enqueue(
        infoHash: String,
        source: String,
        name: String,
        savePath: URL,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false
    ) async throws -> TorrentRecord {
        let key = infoHash.lowercased()
        guard records[key] == nil else {
            throw TorrentEngineError.duplicateTorrent(key)
        }

        sequenceCounter += 1
        let record = TorrentRecord(
            infoHash: key,
            source: source,
            name: name,
            savePath: savePath,
            createdAt: Date(),
            updatedAt: Date(),
            state: .queued,
            progress: TorrentProgress(),
            priority: priority,
            sequenceIndex: sequenceCounter,
            isExplicitlyPaused: isExplicitlyPaused
        )

        records[key] = record
        try await persistenceStore.saveRecord(record)

        // Evaluate admission
        _ = await pumpQueue()
        return records[key] ?? record
    }

    // MARK: - Transfer Controls

    /// Explicitly pauses a torrent. It will not be resumed by the queue scheduler until explicitly unpaused.
    public func pause(infoHash: String) async throws -> (promoted: [String], demoted: [String]) {
        let key = infoHash.lowercased()
        guard var record = records[key] else {
            throw TorrentEngineError.torrentNotFound
        }

        record.isExplicitlyPaused = true
        record.state = .paused
        record.updatedAt = Date()
        records[key] = record
        try await persistenceStore.saveRecord(record)

        // Vacated active slot may now promote another queued torrent
        let changes = await pumpQueue()
        return changes
    }

    /// Resumes a paused torrent, unsetting explicit pause and admitting it if slots are available.
    public func resume(infoHash: String) async throws -> (promoted: [String], demoted: [String]) {
        let key = infoHash.lowercased()
        guard var record = records[key] else {
            throw TorrentEngineError.torrentNotFound
        }

        record.isExplicitlyPaused = false
        record.errorMessage = nil
        record.updatedAt = Date()

        // Place in .queued; pumpQueue() will promote immediately if under concurrency limit
        record.state = .queued
        records[key] = record
        try await persistenceStore.saveRecord(record)

        let changes = await pumpQueue()
        return changes
    }

    /// Removes a torrent from the queue scheduler and deletes its persistent record.
    public func remove(infoHash: String) async throws -> (promoted: [String], demoted: [String]) {
        let key = infoHash.lowercased()
        guard records[key] != nil else {
            throw TorrentEngineError.torrentNotFound
        }

        records.removeValue(forKey: key)
        try await persistenceStore.deleteRecord(infoHash: key)

        let changes = await pumpQueue()
        return changes
    }

    // MARK: - Priority & Concurrency Updates

    /// Updates the scheduling priority of an enqueued or active torrent.
    public func setPriority(_ priority: TorrentPriority, for infoHash: String) async throws -> (promoted: [String], demoted: [String]) {
        let key = infoHash.lowercased()
        guard var record = records[key] else {
            throw TorrentEngineError.torrentNotFound
        }

        record.priority = priority
        record.updatedAt = Date()
        records[key] = record
        try await persistenceStore.saveRecord(record)

        return await pumpQueue()
    }

    /// Configures the maximum number of simultaneously active downloading torrents.
    public func setMaxConcurrentTorrents(_ limit: Int) async throws -> (promoted: [String], demoted: [String]) {
        self.maxConcurrentTorrents = max(1, limit)
        var manifest = await persistenceStore.loadManifest()
        manifest.maxConcurrentTorrents = self.maxConcurrentTorrents
        try await persistenceStore.saveManifest(manifest)

        return await pumpQueue()
    }

    /// Updates and persists per-file download priorities for a torrent.
    public func setFilePriorities(_ priorities: [Int: TorrentFilePriority], for infoHash: String) async throws {
        let key = infoHash.lowercased()
        guard var record = records[key] else {
            throw TorrentEngineError.torrentNotFound
        }
        record.filePriorities = priorities
        record.updatedAt = Date()
        records[key] = record
        try await persistenceStore.saveRecord(record)
    }

    /// Updates and persists the seeding policy preference for a torrent.
    public func setSeedingPreference(_ preference: SeedingPreference, for infoHash: String) async throws {
        let key = infoHash.lowercased()
        guard var record = records[key] else {
            throw TorrentEngineError.torrentNotFound
        }
        record.seedingPreference = preference
        record.updatedAt = Date()
        records[key] = record
        try await persistenceStore.saveRecord(record)
    }

    /// Evaluates whether an active seeding torrent has fulfilled its configured ratio or duration limit.
    public func shouldStopSeeding(infoHash: String, totalUploaded: Int64, totalDownloaded: Int64, elapsedSeedingSeconds: TimeInterval) -> Bool {
        let key = infoHash.lowercased()
        guard let record = records[key] else { return false }
        let pref = record.seedingPreference ?? (record.seedRatioLimit.map { SeedingPreference(mode: .ratio, targetRatio: $0) }) ?? SeedingPreference.default

        switch pref.mode {
        case .doNotSeed:
            return true
        case .ratio:
            let dl = max(1, totalDownloaded)
            let currentRatio = Double(totalUploaded) / Double(dl)
            return currentRatio >= pref.targetRatio
        case .duration:
            return elapsedSeedingSeconds >= pref.targetDurationSeconds
        case .indefinitely:
            return false
        }
    }

    // MARK: - Progress & State Transitions

    /// Updates the progress and optionally the state of a torrent.
    /// Callers can throttle persistent disk writes to avoid high-frequency disk I/O.
    public func updateProgress(
        infoHash: String,
        progress: TorrentProgress,
        state: TorrentState? = nil,
        errorMessage: String? = nil,
        persistToDisk: Bool = false
    ) async throws -> (promoted: [String], demoted: [String]) {
        let key = infoHash.lowercased()
        guard var record = records[key] else {
            return ([], [])
        }

        let oldState = record.state
        record.progress = progress
        if let newState = state {
            if record.isExplicitlyPaused {
                // Invariant: An explicitly paused torrent must NEVER transition to active or queued states
                record.state = .paused
            } else {
                record.state = newState
            }
        }
        if let err = errorMessage {
            record.errorMessage = err
        }
        record.updatedAt = Date()
        records[key] = record

        if persistToDisk {
            try? await persistenceStore.saveRecord(record)
        }

        // If transfer transitioned out of active downloading (e.g. finished or error), pump queue
        var changes: (promoted: [String], demoted: [String]) = ([], [])
        if oldState.isActive && !record.state.isActive {
            try? await persistenceStore.saveRecord(record)
            changes = await pumpQueue()
        }
        return changes
    }

    // MARK: - Queue Evaluation & Promotion

    /// Re-evaluates queue ordering, promoting highest-priority queued downloads into active slots
    /// and demoting excess active downloads if the concurrency limit was reduced.
    @discardableResult
    public func pumpQueue() async -> (promoted: [String], demoted: [String]) {
        var promoted: [String] = []
        var demoted: [String] = []

        // 1. Calculate active torrent count
        var activeKeys = records.values
            .filter { $0.state.isActive }
            .sorted { lhs, rhs in
                // Sort active: higher priority kept active first, then earlier sequence index
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }
                return lhs.sequenceIndex < rhs.sequenceIndex
            }
            .map { $0.infoHash }

        // 2. If active exceeds max limit (e.g. limit reduced), demote excess lowest-priority items
        while activeKeys.count > maxConcurrentTorrents {
            let demotedKey = activeKeys.removeLast()
            if var r = records[demotedKey] {
                r.state = .queued
                r.updatedAt = Date()
                records[demotedKey] = r
                try? await persistenceStore.saveRecord(r)
                demoted.append(demotedKey)
            }
        }

        // 3. If capacity allows, promote eligible queued downloads
        let availableSlots = maxConcurrentTorrents - activeKeys.count
        if availableSlots > 0 {
            let eligible = records.values
                .filter { $0.state == .queued && !$0.isExplicitlyPaused }
                .sorted { lhs, rhs in
                    if lhs.priority != rhs.priority {
                        return lhs.priority > rhs.priority
                    }
                    return lhs.sequenceIndex < rhs.sequenceIndex
                }

            for r in eligible.prefix(availableSlots) {
                guard !r.isExplicitlyPaused else {
                    #if DEBUG
                    print("[TorrentQueueScheduler] Invariant guard: skipping promotion of explicitly paused torrent \(r.infoHash)")
                    #endif
                    continue
                }
                let key = r.infoHash
                var updated = r
                updated.state = .downloading
                updated.updatedAt = Date()
                records[key] = updated
                try? await persistenceStore.saveRecord(updated)
                promoted.append(key)
            }
        }

        return (promoted, demoted)
    }

    // MARK: - Inspection & Snapshots

    /// Point-in-time immutable snapshot of the torrent queue.
    public func snapshot() -> TorrentQueueSnapshot {
        let all = Array(records.values)
        let activeCount = all.filter { $0.state.isActive }.count
        let queuedCount = all.filter { $0.state == .queued }.count
        let pausedCount = all.filter { $0.state == .paused }.count
        let completedCount = all.filter { $0.state == .finished }.count
        let seedingCount = all.filter { $0.state == .seeding }.count
        let failedCount = all.filter { $0.state == .error }.count

        return TorrentQueueSnapshot(
            totalTorrents: all.count,
            activeCount: activeCount,
            queuedCount: queuedCount,
            pausedCount: pausedCount,
            completedCount: completedCount,
            seedingCount: seedingCount,
            failedCount: failedCount,
            records: all.sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }
                return lhs.sequenceIndex < rhs.sequenceIndex
            }
        )
    }

    /// Fetches a specific record by info-hash.
    public func record(for infoHash: String) -> TorrentRecord? {
        records[infoHash.lowercased()]
    }

    /// Returns all tracked records.
    public func allRecords() -> [TorrentRecord] {
        Array(records.values)
    }

    // MARK: - Startup Reconciliation

    private func reconcileInterruptedDownloads() async -> (promoted: [String], demoted: [String]) {
        // Interrupted active downloads from prior session:
        // Torrents marked .downloading or .checking that were not explicitly paused are marked .queued
        // and re-evaluated through pumpQueue() to respect concurrency limits.
        // Explicitly paused torrents are strictly preserved in .paused state.
        for (key, var r) in records {
            if r.isExplicitlyPaused {
                if r.state != .paused {
                    r.state = .paused
                    records[key] = r
                    try? await persistenceStore.saveRecord(r)
                }
            } else if r.state.isActive {
                r.state = .queued
                records[key] = r
            }
        }
        return await pumpQueue()
    }
}

private extension TorrentState {
    var isActive: Bool {
        self == .downloading || self == .checking
    }
}
