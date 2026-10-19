import Foundation

#if canImport(LibTorrent)
import LibTorrent

/// Swift-concurrency facade for the native libtorrent session, queue scheduling, and fast-resume persistence.
///
/// Milestone 4: Torrent Persistence, Fast-Resume, Crash Recovery, and Queue Management.
public actor TorrentEngine {
    private let bridge: TorrentSessionBridge
    private let persistenceStore: TorrentPersistenceStore
    private var scheduler: TorrentQueueScheduler?
    private let storageDirectoryURL: URL
    private let portStart: UInt
    private let portEnd: UInt
    private let defaultMaxConcurrentTorrents: Int
    private var isRunning = false
    private var tasks: [String: TorrentTask] = [:]

    public init(
        storageDirectoryURL: URL,
        portStart: UInt = 6881,
        portEnd: UInt = 6891,
        maxConcurrentTorrents: Int = 3
    ) {
        self.storageDirectoryURL = storageDirectoryURL
        self.portStart = portStart
        self.portEnd = portEnd
        self.defaultMaxConcurrentTorrents = maxConcurrentTorrents
        self.bridge = TorrentSessionBridge(
            storagePath: storageDirectoryURL.path,
            portStart: Int(portStart),
            portEnd: Int(portEnd)
        )
        let persistURL = storageDirectoryURL.appendingPathComponent("TorrentMetadata", isDirectory: true)
        self.persistenceStore = (try? TorrentPersistenceStore(storageDirectoryURL: persistURL)) ?? (try! TorrentPersistenceStore())
    }

    /// Starts the native session, restores persisted torrents with fast-resume, and starts queue scheduling.
    public func start() async throws {
        guard !isRunning else { return }
        try bridge.startSession()
        isRunning = true

        // Initialize scheduler with persistence store
        let sched = try await TorrentQueueScheduler(
            persistenceStore: persistenceStore,
            maxConcurrentTorrents: defaultMaxConcurrentTorrents
        )
        self.scheduler = sched

        // Restore persisted torrents
        let records = await sched.allRecords()
        for record in records {
            let hash = record.infoHash
            var restoredHash: String?

            // 1. Try fast-resume restoration if resume data exists
            if let resumeData = await persistenceStore.loadResumeData(for: hash) {
                restoredHash = try? bridge.addTorrent(withResumeData: resumeData, savePath: record.savePath.path)
            }

            // 2. Safe fallback if fast-resume missing or corrupt: re-add using original source
            if restoredHash == nil {
                if record.source.hasPrefix("magnet:") {
                    restoredHash = try? bridge.addTorrent(withMagnetURI: record.source, savePath: record.savePath.path)
                } else if record.source.hasSuffix(".torrent") || FileManager.default.fileExists(atPath: record.source) {
                    restoredHash = try? bridge.addTorrent(withFilePath: record.source, savePath: record.savePath.path)
                }
            }

            // 3. Preserve pause / queued status
            if record.isExplicitlyPaused || record.state == .paused || record.state == .queued {
                try? bridge.pauseTorrent(withHash: hash)
            }
        }

        // 4. Pump queue to activate admitted torrents up to concurrency limit
        let changes = await sched.pumpQueue()
        for h in changes.promoted {
            try? bridge.resumeTorrent(withHash: h)
        }
        for h in changes.demoted {
            try? bridge.pauseTorrent(withHash: h)
        }

        // Update task cache
        _ = allTasks()
    }

    /// Stops the native session safely, saving fast-resume data for active torrents before session shutdown.
    public func stop(timeoutSeconds: TimeInterval = 4.0) async {
        guard isRunning else { return }

        // 1. Request fast-resume data for all valid torrents
        let currentStatuses = bridge.allTorrentStatuses()
        for s in currentStatuses {
            try? bridge.requestResumeData(forTorrentWithHash: s.infoHash)
        }

        // 2. Bounded wait for resume-data alerts (up to timeoutSeconds)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var pendingHashes = Set(currentStatuses.map { $0.infoHash.lowercased() })

        while !pendingHashes.isEmpty && Date() < deadline {
            bridge.pollAlerts()
            for h in Array(pendingHashes) {
                if bridge.isResumeDataReady(forTorrentWithHash: h) {
                    if let data = bridge.resumeData(forTorrentWithHash: h) {
                        try? await persistenceStore.saveResumeData(data, for: h)
                    }
                    pendingHashes.remove(h)
                } else if bridge.resumeDataError(forTorrentWithHash: h) != nil {
                    pendingHashes.remove(h)
                }
            }
            if !pendingHashes.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }

        // 3. Persist final task records to manifest
        for s in currentStatuses {
            let key = s.infoHash.lowercased()
            if var rec = await scheduler?.record(for: key) {
                rec.state = TorrentState(bridgeState: s.state)
                rec.progress = TorrentProgress(
                    bytesDownloaded: s.totalDone,
                    totalBytes: s.totalWanted,
                    downloadBytesPerSecond: s.downloadPayloadRate,
                    uploadBytesPerSecond: s.uploadPayloadRate,
                    connectedPeers: s.numPeers,
                    activeSeeds: s.numSeeds,
                    progressFraction: Double(s.progress)
                )
                rec.updatedAt = Date()
                try? await persistenceStore.saveRecord(rec)
            }
        }

        // 4. Clean session shutdown
        bridge.stopSession()
        isRunning = false
        tasks.removeAll()
    }

    /// Stops the session without parameters (backward compatible with Milestone 2/3).
    public func stop() async {
        await stop(timeoutSeconds: 3.0)
    }

    /// Returns a point-in-time view of native session health.
    public func status() -> TorrentSessionStatus {
        TorrentSessionStatus(
            isRunning: isRunning,
            isListening: bridge.isListening,
            listenPort: UInt(max(0, bridge.listenPort)),
            libtorrentVersion: TorrentSessionBridge.libtorrentVersion()
        )
    }

    // MARK: - Ingestion

    @discardableResult
    public func addTorrent(
        magnetURI: String,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false
    ) async throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let savePath = saveDirectoryURL?.path ?? storageDirectoryURL.path
        let hash = try bridge.addTorrent(withMagnetURI: magnetURI, savePath: savePath)

        if let sched = scheduler {
            let record = try await sched.enqueue(
                infoHash: hash,
                source: magnetURI,
                name: "Magnet \(hash.prefix(8))",
                savePath: saveDirectoryURL ?? storageDirectoryURL,
                priority: priority,
                isExplicitlyPaused: isExplicitlyPaused
            )

            if record.state == .downloading && !isExplicitlyPaused {
                try? bridge.resumeTorrent(withHash: hash)
            } else {
                try? bridge.pauseTorrent(withHash: hash)
            }
        }

        guard let status = bridge.status(forTorrentWithHash: hash) else {
            throw TorrentEngineError.bridgeError("Failed to fetch status for added magnet torrent.")
        }
        return updateTask(from: status, source: magnetURI)
    }

    @discardableResult
    public func addTorrent(
        fileURL: URL,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false
    ) async throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let savePath = saveDirectoryURL?.path ?? storageDirectoryURL.path
        let hash = try bridge.addTorrent(withFilePath: fileURL.path, savePath: savePath)

        if let sched = scheduler {
            let record = try await sched.enqueue(
                infoHash: hash,
                source: fileURL.path,
                name: fileURL.deletingPathExtension().lastPathComponent,
                savePath: saveDirectoryURL ?? storageDirectoryURL,
                priority: priority,
                isExplicitlyPaused: isExplicitlyPaused
            )

            if record.state == .downloading && !isExplicitlyPaused {
                try? bridge.resumeTorrent(withHash: hash)
            } else {
                try? bridge.pauseTorrent(withHash: hash)
            }
        }

        guard let status = bridge.status(forTorrentWithHash: hash) else {
            throw TorrentEngineError.bridgeError("Failed to fetch status for added file torrent.")
        }
        return updateTask(from: status, source: fileURL.lastPathComponent)
    }

    @discardableResult
    public func addTorrent(
        data: Data,
        name: String? = nil,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false
    ) async throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let savePath = saveDirectoryURL?.path ?? storageDirectoryURL.path
        let hash = try bridge.addTorrent(with: data, savePath: savePath)

        let displayName = name ?? "Torrent \(hash.prefix(8))"
        if let sched = scheduler {
            let record = try await sched.enqueue(
                infoHash: hash,
                source: "raw-buffer",
                name: displayName,
                savePath: saveDirectoryURL ?? storageDirectoryURL,
                priority: priority,
                isExplicitlyPaused: isExplicitlyPaused
            )

            if record.state == .downloading && !isExplicitlyPaused {
                try? bridge.resumeTorrent(withHash: hash)
            } else {
                try? bridge.pauseTorrent(withHash: hash)
            }
        }

        guard let status = bridge.status(forTorrentWithHash: hash) else {
            throw TorrentEngineError.bridgeError("Failed to fetch status for added buffer torrent.")
        }
        return updateTask(from: status, source: displayName)
    }

    // MARK: - Transfer Controls

    public func pause(infoHash: String) async throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let key = infoHash.lowercased()
        try bridge.pauseTorrent(withHash: key)

        try? bridge.requestResumeData(forTorrentWithHash: key)

        if let sched = scheduler {
            let changes = try await sched.pause(infoHash: key)
            for h in changes.promoted {
                try? bridge.resumeTorrent(withHash: h)
            }
        }

        if var task = tasks[key] {
            task.state = .paused
            task.isExplicitlyPaused = true
            tasks[key] = task
        }
    }

    public func resume(infoHash: String) async throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let key = infoHash.lowercased()

        if let sched = scheduler {
            let changes = try await sched.resume(infoHash: key)
            for h in changes.promoted {
                try? bridge.resumeTorrent(withHash: h)
            }
            for h in changes.demoted {
                try? bridge.pauseTorrent(withHash: h)
            }
        } else {
            try bridge.resumeTorrent(withHash: key)
        }

        if var task = tasks[key] {
            task.isExplicitlyPaused = false
            task.state = .downloading
            task.errorMessage = nil
            tasks[key] = task
        }
    }

    public func remove(infoHash: String, deleteFiles: Bool = false) async throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let key = infoHash.lowercased()
        try bridge.removeTorrent(withHash: key, deleteFiles: deleteFiles)

        if let sched = scheduler {
            let changes = try await sched.remove(infoHash: key)
            for h in changes.promoted {
                try? bridge.resumeTorrent(withHash: h)
            }
        }

        tasks.removeValue(forKey: key)
        try? await persistenceStore.deleteRecord(infoHash: key)
        try? await persistenceStore.deleteResumeData(for: key)
    }

    // MARK: - Queue & Concurrency Management

    public func setMaxConcurrentTorrents(_ limit: Int) async throws {
        guard let sched = scheduler else { return }
        let changes = try await sched.setMaxConcurrentTorrents(limit)
        for h in changes.promoted {
            try? bridge.resumeTorrent(withHash: h)
        }
        for h in changes.demoted {
            try? bridge.pauseTorrent(withHash: h)
        }
    }

    public func setPriority(_ priority: TorrentPriority, for infoHash: String) async throws {
        guard let sched = scheduler else { return }
        let changes = try await sched.setPriority(priority, for: infoHash)
        for h in changes.promoted {
            try? bridge.resumeTorrent(withHash: h)
        }
        for h in changes.demoted {
            try? bridge.pauseTorrent(withHash: h)
        }
    }

    public func queueSnapshot() async -> TorrentQueueSnapshot? {
        await scheduler?.snapshot()
    }

    // MARK: - Status & Inspection

    public func task(for infoHash: String) -> TorrentTask? {
        let key = infoHash.lowercased()
        if let bridgeStatus = bridge.status(forTorrentWithHash: key) {
            return updateTask(from: bridgeStatus)
        }
        return tasks[key]
    }

    public func allTasks() -> [TorrentTask] {
        let statuses = bridge.allTorrentStatuses()
        for s in statuses {
            _ = updateTask(from: s)
        }
        return Array(tasks.values)
    }

    // MARK: - Private Helpers

    @discardableResult
    private func updateTask(from status: TorrentBridgeStatus, source: String? = nil) -> TorrentTask {
        let key = status.infoHash.lowercased()
        let state = TorrentState(bridgeState: status.state)
        let progress = TorrentProgress(
            bytesDownloaded: status.totalDone,
            totalBytes: status.totalWanted,
            downloadBytesPerSecond: status.downloadPayloadRate,
            uploadBytesPerSecond: status.uploadPayloadRate,
            connectedPeers: status.numPeers,
            activeSeeds: status.numSeeds,
            progressFraction: Double(status.progress)
        )
        let saveURL = URL(fileURLWithPath: status.savePath)

        if var existing = tasks[key] {
            existing.state = state
            existing.progress = progress
            if !status.name.isEmpty {
                existing.name = status.name
            }
            existing.errorMessage = status.errorMessage
            tasks[key] = existing
            return existing
        } else {
            let task = TorrentTask(
                source: source ?? "magnet:?xt=urn:btih:\(key)",
                name: status.name.isEmpty ? key : status.name,
                savePath: saveURL,
                state: state,
                progress: progress,
                errorMessage: status.errorMessage,
                infoHash: key
            )
            tasks[key] = task
            return task
        }
    }

    deinit {
        // Deterministic cleanup
    }
}

private extension TorrentState {
    init(bridgeState: TorrentBridgeState) {
        switch bridgeState {
        case .queued:
            self = .queued
        case .checking:
            self = .checking
        case .downloading:
            self = .downloading
        case .finished:
            self = .finished
        case .seeding:
            self = .seeding
        case .paused:
            self = .paused
        case .error:
            self = .error
        case .removed:
            self = .removed
        @unknown default:
            self = .queued
        }
    }
}
#endif
