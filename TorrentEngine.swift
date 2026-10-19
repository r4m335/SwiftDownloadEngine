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
        maxConcurrentTorrents: Int = 3,
        persistenceStore: TorrentPersistenceStore? = nil
    ) throws {
        self.storageDirectoryURL = storageDirectoryURL
        self.portStart = portStart
        self.portEnd = portEnd
        self.defaultMaxConcurrentTorrents = maxConcurrentTorrents
        self.bridge = TorrentSessionBridge(
            storagePath: storageDirectoryURL.path,
            portStart: Int(portStart),
            portEnd: Int(portEnd)
        )
        if let store = persistenceStore {
            self.persistenceStore = store
        } else {
            let persistURL = storageDirectoryURL.appendingPathComponent("TorrentMetadata", isDirectory: true)
            self.persistenceStore = try TorrentPersistenceStore(storageDirectoryURL: persistURL)
        }
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
        _ = await allTasks()
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
            portRange: UInt(portStart)...UInt(portEnd),
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

    // MARK: - Milestone 6: Per-File Priority & Seeding Controls

    /// Returns the file list for a torrent, or nil if metadata is not yet resolved.
    public func files(for infoHash: String) async -> [TorrentFileInfo]? {
        let key = infoHash.lowercased()
        guard let bridgeFiles = bridge.files(forTorrentWithHash: key) else {
            return nil
        }
        let stored = await scheduler?.record(for: key)?.filePriorities ?? [:]
        return bridgeFiles.map { bf in
            let prio = stored[bf.index] ?? (TorrentFilePriority(rawValue: bf.priority) ?? .normal)
            return TorrentFileInfo(
                index: bf.index,
                path: bf.path,
                size: bf.size,
                priority: prio,
                progressFraction: Double(bf.progress)
            )
        }
    }

    /// Sets the download priority for a specific file index within a torrent.
    public func setFilePriority(_ priority: TorrentFilePriority, forFileAt index: Int, in infoHash: String) async throws {
        let key = infoHash.lowercased()
        try bridge.setPriority(priority.rawValue, forFileAtIndex: index, inTorrentWithHash: key)
        if let sched = scheduler {
            var priorities = (await sched.record(for: key)?.filePriorities) ?? [:]
            priorities[index] = priority
            try await sched.setFilePriorities(priorities, for: key)
        }
    }

    /// Sets download priorities for all files within a torrent simultaneously.
    public func setFilePriorities(_ priorities: [Int: TorrentFilePriority], for infoHash: String) async throws {
        let key = infoHash.lowercased()
        if let currentFiles = bridge.files(forTorrentWithHash: key) {
            var prioArray: [NSNumber] = []
            for i in 0..<currentFiles.count {
                let p = priorities[i] ?? .normal
                prioArray.append(NSNumber(value: p.rawValue))
            }
            try bridge.setFilePriorities(prioArray, inTorrentWithHash: key)
        }
        if let sched = scheduler {
            try await sched.setFilePriorities(priorities, for: key)
        }
    }

    /// Updates the seeding policy preference for a specific torrent.
    public func setSeedingPreference(_ preference: SeedingPreference, for infoHash: String) async throws {
        let key = infoHash.lowercased()
        try await scheduler?.setSeedingPreference(preference, for: key)
    }

    // MARK: - Status & Inspection

    public func task(for infoHash: String) async -> TorrentTask? {
        let key = infoHash.lowercased()
        if let bridgeStatus = bridge.status(forTorrentWithHash: key) {
            var t = updateTask(from: bridgeStatus)
            if let sched = scheduler, let rec = await sched.record(for: key) {
                if rec.isExplicitlyPaused {
                    t.state = .paused
                    t.isExplicitlyPaused = true
                } else if rec.state == .queued && (t.state == .paused || t.state == .downloading) {
                    t.state = .queued
                }
                t.priority = rec.priority
                t.filePriorities = rec.filePriorities
                t.seedingPreference = rec.seedingPreference

                if (t.state == .seeding || t.state == .finished) && !t.isExplicitlyPaused {
                    if await sched.shouldStopSeeding(infoHash: key, totalUploaded: t.progress.bytesDownloaded, totalDownloaded: t.progress.totalBytes, elapsedSeedingSeconds: 0) {
                        try? bridge.pauseTorrent(withHash: key)
                        t.state = .finished
                    }
                }
                tasks[key] = t
            }
            return t
        }
        return tasks[key]
    }

    public func allTasks() async -> [TorrentTask] {
        let statuses = bridge.allTorrentStatuses()
        for s in statuses {
            _ = updateTask(from: s)
        }
        if let sched = scheduler {
            let records = await sched.allRecords()
            for rec in records {
                let key = rec.infoHash.lowercased()
                if var task = tasks[key] {
                    if rec.isExplicitlyPaused {
                        task.state = .paused
                        task.isExplicitlyPaused = true
                    } else if rec.state == .queued && (task.state == .paused || task.state == .downloading) {
                        task.state = .queued
                    }
                    task.priority = rec.priority
                    task.filePriorities = rec.filePriorities
                    task.seedingPreference = rec.seedingPreference

                    if (task.state == .seeding || task.state == .finished) && !task.isExplicitlyPaused {
                        if await sched.shouldStopSeeding(infoHash: key, totalUploaded: task.progress.bytesDownloaded, totalDownloaded: task.progress.totalBytes, elapsedSeedingSeconds: 0) {
                            try? bridge.pauseTorrent(withHash: key)
                            task.state = .finished
                        }
                    }
                    tasks[key] = task
                }
            }
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

    public func pauseTorrent(infoHash: String) async throws {
        try await pause(infoHash: infoHash)
    }

    public func resumeTorrent(infoHash: String) async throws {
        try await resume(infoHash: infoHash)
    }

    public func removeTorrent(infoHash: String, deleteFiles: Bool = false) async throws {
        try await remove(infoHash: infoHash, deleteFiles: deleteFiles)
    }

    public func sessionStatus() -> TorrentSessionStatus {
        status()
    }

    public func maxConcurrentTorrents() async -> Int {
        await scheduler?.maxConcurrentTorrents ?? defaultMaxConcurrentTorrents
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
#else

/// Fallback TorrentEngine for environments without native LibTorrent bridging (e.g. Linux WSL unit tests / headless CI).
/// Implements identical public actor interface backed by TorrentPersistenceStore and TorrentQueueScheduler.
public actor TorrentEngine {
    private let persistenceStore: TorrentPersistenceStore
    private var scheduler: TorrentQueueScheduler?
    private let storageDirectoryURL: URL
    private let portStart: UInt
    private let portEnd: UInt
    private var currentMaxConcurrentTorrents: Int
    private var isRunning = false
    private var tasks: [String: TorrentTask] = [:]

    public init(
        storageDirectoryURL: URL,
        portStart: UInt = 6881,
        portEnd: UInt = 6891,
        maxConcurrentTorrents: Int = 3,
        persistenceStore: TorrentPersistenceStore? = nil
    ) throws {
        self.storageDirectoryURL = storageDirectoryURL
        self.portStart = portStart
        self.portEnd = portEnd
        self.currentMaxConcurrentTorrents = maxConcurrentTorrents
        if let store = persistenceStore {
            self.persistenceStore = store
        } else {
            let persistURL = storageDirectoryURL.appendingPathComponent("TorrentMetadata", isDirectory: true)
            self.persistenceStore = try TorrentPersistenceStore(storageDirectoryURL: persistURL)
        }
    }

    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true
        let scheduler = try await TorrentQueueScheduler(
            persistenceStore: persistenceStore,
            maxConcurrentTorrents: currentMaxConcurrentTorrents
        )
        self.scheduler = scheduler
        let records = await scheduler.allRecords()
        for record in records {
            let state: TorrentState = record.isExplicitlyPaused ? .paused : .queued
            let task = TorrentTask(
                id: record.id,
                source: record.source,
                name: record.name,
                savePath: record.savePath,
                state: state,
                createdAt: record.createdAt,
                infoHash: record.infoHash,
                priority: record.priority,
                isExplicitlyPaused: record.isExplicitlyPaused,
                filePriorities: record.filePriorities,
                seedingPreference: record.seedingPreference
            )
            tasks[record.infoHash.lowercased()] = task
        }
    }

    public func stop(timeoutSeconds: TimeInterval = 4.0) async {
        isRunning = false
    }

    public func stop() async {
        await stop(timeoutSeconds: 3.0)
    }

    public func addTorrent(
        magnetURI: String,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false
    ) async throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        guard let infoHash = Self.extractInfoHash(from: magnetURI) else {
            throw TorrentEngineError.invalidMagnetURI(magnetURI)
        }
        if tasks[infoHash] != nil {
            throw TorrentEngineError.duplicateTorrent(infoHash)
        }
        let saveDir = saveDirectoryURL ?? storageDirectoryURL
        let name = Self.extractDisplayName(from: magnetURI) ?? "Torrent-\(infoHash.prefix(8))"

        guard let sched = scheduler else { throw TorrentEngineError.sessionNotRunning }
        let record = try await sched.enqueue(
            infoHash: infoHash,
            source: magnetURI,
            name: name,
            savePath: saveDir.appendingPathComponent(name),
            priority: priority,
            isExplicitlyPaused: isExplicitlyPaused
        )
        let task = TorrentTask(
            id: record.id,
            source: record.source,
            name: record.name,
            savePath: record.savePath,
            state: record.state,
            createdAt: record.createdAt,
            infoHash: record.infoHash,
            priority: record.priority,
            isExplicitlyPaused: record.isExplicitlyPaused
        )
        tasks[infoHash] = task
        return task
    }

    public func addTorrent(
        fileURL: URL,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false
    ) async throws -> TorrentTask {
        let data = try Data(contentsOf: fileURL)
        var name = fileURL.deletingPathExtension().lastPathComponent
        if let parsed = Self.extractBencodedInfo(from: data), let parsedName = parsed.name {
            name = parsedName
        }
        return try await addTorrent(
            data: data,
            name: name,
            saveDirectoryURL: saveDirectoryURL,
            priority: priority,
            isExplicitlyPaused: isExplicitlyPaused
        )
    }

    public func addTorrent(
        data: Data,
        name: String? = nil,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false
    ) async throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        guard !data.isEmpty else {
            throw TorrentEngineError.invalidTorrentFile("Empty data")
        }
        let infoHash: String
        let displayName: String
        if let parsed = Self.extractBencodedInfo(from: data) {
            infoHash = parsed.infoHash.lowercased()
            displayName = name ?? parsed.name ?? "Torrent-\(infoHash.prefix(8))"
        } else {
            let sha1 = data.prefix(20).map { String(format: "%02x", $0) }.joined()
            infoHash = (sha1.count == 40 ? sha1 : sha1.padding(toLength: 40, withPad: "0", startingAt: 0)).lowercased()
            displayName = name ?? "Torrent-\(infoHash.prefix(8))"
        }
        if tasks[infoHash] != nil {
            throw TorrentEngineError.duplicateTorrent(infoHash)
        }
        let saveDir = saveDirectoryURL ?? storageDirectoryURL

        guard let sched = scheduler else { throw TorrentEngineError.sessionNotRunning }
        let record = try await sched.enqueue(
            infoHash: infoHash,
            source: "raw-buffer",
            name: displayName,
            savePath: saveDir.appendingPathComponent(displayName),
            priority: priority,
            isExplicitlyPaused: isExplicitlyPaused
        )
        let task = TorrentTask(
            id: record.id,
            source: record.source,
            name: record.name,
            savePath: record.savePath,
            state: record.state,
            createdAt: record.createdAt,
            infoHash: record.infoHash,
            priority: record.priority,
            isExplicitlyPaused: record.isExplicitlyPaused
        )
        tasks[infoHash] = task
        return task
    }

    public func pause(infoHash: String) async throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let hash = infoHash.lowercased()
        guard var task = tasks[hash] else { throw TorrentEngineError.torrentNotFound }
        task.state = .paused
        task.isExplicitlyPaused = true
        tasks[hash] = task
        _ = try await scheduler?.pause(infoHash: hash)
    }

    public func pauseTorrent(infoHash: String) async throws {
        try await pause(infoHash: infoHash)
    }

    public func resume(infoHash: String) async throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let hash = infoHash.lowercased()
        guard var task = tasks[hash] else { throw TorrentEngineError.torrentNotFound }
        task.state = .downloading
        task.isExplicitlyPaused = false
        tasks[hash] = task
        _ = try await scheduler?.resume(infoHash: hash)
    }

    public func resumeTorrent(infoHash: String) async throws {
        try await resume(infoHash: infoHash)
    }

    public func remove(infoHash: String, deleteFiles: Bool = false) async throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let hash = infoHash.lowercased()
        guard let task = tasks[hash] else { throw TorrentEngineError.torrentNotFound }
        tasks.removeValue(forKey: hash)
        _ = try await scheduler?.remove(infoHash: hash)
        try? await persistenceStore.deleteRecord(infoHash: hash)
        try? await persistenceStore.deleteResumeData(for: hash)
        if deleteFiles {
            try? FileManager.default.removeItem(at: task.savePath)
        }
    }

    public func removeTorrent(infoHash: String, deleteFiles: Bool = false) async throws {
        try await remove(infoHash: infoHash, deleteFiles: deleteFiles)
    }

    public func setPriority(_ priority: TorrentPriority, for infoHash: String) async throws {
        let hash = infoHash.lowercased()
        guard var task = tasks[hash] else { throw TorrentEngineError.torrentNotFound }
        task.priority = priority
        tasks[hash] = task
        _ = try await scheduler?.setPriority(priority, for: hash)
    }

    public func task(for infoHash: String) async -> TorrentTask? {
        let hash = infoHash.lowercased()
        guard var task = tasks[hash] else { return nil }
        if let rec = await scheduler?.record(for: hash) {
            task.priority = rec.priority
            task.isExplicitlyPaused = rec.isExplicitlyPaused
            task.filePriorities = rec.filePriorities
            task.seedingPreference = rec.seedingPreference
            if rec.isExplicitlyPaused {
                task.state = .paused
            } else if rec.state == .queued {
                task.state = .queued
            }
        }
        return task
    }

    public func files(for infoHash: String) async -> [TorrentFileInfo]? {
        let key = infoHash.lowercased()
        guard let task = tasks[key] else { return nil }
        let stored = await scheduler?.record(for: key)?.filePriorities ?? [:]
        let p1 = stored[0] ?? .normal
        let p2 = stored[1] ?? .normal
        let p3 = stored[2] ?? .normal
        let f1 = TorrentFileInfo(index: 0, path: "\(task.name)/chapter1.pdf", size: 2048, priority: p1, progressFraction: 0.5)
        let f2 = TorrentFileInfo(index: 1, path: "\(task.name)/chapter2.pdf", size: 4096, priority: p2, progressFraction: 0.2)
        let f3 = TorrentFileInfo(index: 2, path: "\(task.name)/video_extra.mkv", size: 16384, priority: p3, progressFraction: 0.0)
        return [f1, f2, f3]
    }

    public func setFilePriority(_ priority: TorrentFilePriority, forFileAt index: Int, in infoHash: String) async throws {
        let key = infoHash.lowercased()
        guard tasks[key] != nil else { throw TorrentEngineError.torrentNotFound }
        var map = (await scheduler?.record(for: key)?.filePriorities) ?? [:]
        map[index] = priority
        try await scheduler?.setFilePriorities(map, for: key)
        tasks[key]?.filePriorities = map
    }

    public func setFilePriorities(_ priorities: [Int: TorrentFilePriority], for infoHash: String) async throws {
        let key = infoHash.lowercased()
        guard tasks[key] != nil else { throw TorrentEngineError.torrentNotFound }
        try await scheduler?.setFilePriorities(priorities, for: key)
        tasks[key]?.filePriorities = priorities
    }

    public func setSeedingPreference(_ preference: SeedingPreference, for infoHash: String) async throws {
        let key = infoHash.lowercased()
        guard tasks[key] != nil else { throw TorrentEngineError.torrentNotFound }
        try await scheduler?.setSeedingPreference(preference, for: key)
        tasks[key]?.seedingPreference = preference
    }

    public func allTasks() async -> [TorrentTask] {
        var result: [TorrentTask] = []
        let records = await scheduler?.allRecords() ?? []
        let recMap = Dictionary(uniqueKeysWithValues: records.map { ($0.infoHash.lowercased(), $0) })
        for (hash, var t) in tasks {
            if let rec = recMap[hash] {
                t.priority = rec.priority
                t.isExplicitlyPaused = rec.isExplicitlyPaused
                t.filePriorities = rec.filePriorities
                t.seedingPreference = rec.seedingPreference
                if rec.isExplicitlyPaused {
                    t.state = .paused
                } else if rec.state == .queued {
                    t.state = .queued
                }
            }
            result.append(t)
        }
        return result
    }

    public func status() -> TorrentSessionStatus {
        TorrentSessionStatus(
            isRunning: isRunning,
            isListening: isRunning,
            listenPort: UInt(portStart),
            portRange: UInt(portStart)...UInt(portEnd),
            libtorrentVersion: "mock-1.0"
        )
    }

    public func sessionStatus() -> TorrentSessionStatus {
        status()
    }

    public func queueSnapshot() async -> TorrentQueueSnapshot? {
        await scheduler?.snapshot()
    }

    public func setMaxConcurrentTorrents(_ max: Int) async throws {
        currentMaxConcurrentTorrents = max
        _ = try await scheduler?.setMaxConcurrentTorrents(max)
    }

    public func maxConcurrentTorrents() async -> Int {
        currentMaxConcurrentTorrents
    }

    public func saveState() async throws {}

    private static func extractInfoHash(from magnetURI: String) -> String? {
        guard let components = URLComponents(string: magnetURI),
              let queryItems = components.queryItems else {
            return nil
        }
        for item in queryItems where item.name == "xt" {
            guard let value = item.value?.lowercased() else { continue }
            if value.hasPrefix("urn:btih:") {
                let hash = String(value.dropFirst("urn:btih:".count))
                if hash.count == 40 || hash.count == 32 {
                    return hash
                }
            }
        }
        return nil
    }

    private static func extractDisplayName(from magnetURI: String) -> String? {
        guard let components = URLComponents(string: magnetURI),
              let queryItems = components.queryItems else {
            return nil
        }
        for item in queryItems where item.name == "dn" {
            if let name = item.value, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private static func extractBencodedInfo(from data: Data) -> (infoHash: String, name: String?)? {
        guard let infoRange = data.range(of: Data("4:info".utf8)) else { return nil }
        let infoStart = infoRange.upperBound
        guard infoStart < data.count, data[infoStart] == 0x64 else { return nil }

        var depth = 0
        var idx = infoStart
        var inString = false
        var stringLength = 0

        while idx < data.count {
            let b = data[idx]
            if inString {
                stringLength -= 1
                if stringLength == 0 { inString = false }
                idx += 1
                continue
            }
            if b >= 0x30 && b <= 0x39 {
                var lenStr = ""
                while idx < data.count && data[idx] >= 0x30 && data[idx] <= 0x39 {
                    lenStr.append(Character(UnicodeScalar(data[idx])))
                    idx += 1
                }
                if idx < data.count && data[idx] == 0x3a {
                    idx += 1
                    if let len = Int(lenStr), len > 0 {
                        inString = true
                        stringLength = len
                    }
                }
                continue
            }
            if b == 0x64 || b == 0x6c {
                depth += 1
                idx += 1
            } else if b == 0x69 {
                idx += 1
                while idx < data.count && data[idx] != 0x65 { idx += 1 }
                if idx < data.count { idx += 1 }
            } else if b == 0x65 {
                depth -= 1
                idx += 1
                if depth == 0 {
                    let infoSlice = data.subdata(in: infoStart..<idx)
                    var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE, h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
                    var msg = infoSlice
                    let bitLength = UInt64(infoSlice.count) * 8
                    msg.append(0x80)
                    while (msg.count % 64) != 56 { msg.append(0x00) }
                    var bigEndianBits = bitLength.bigEndian
                    msg.append(Data(bytes: &bigEndianBits, count: 8))
                    for chunkStart in stride(from: 0, to: msg.count, by: 64) {
                        var w = [UInt32](repeating: 0, count: 80)
                        for i in 0..<16 {
                            let off = chunkStart + i * 4
                            w[i] = UInt32(msg[off]) << 24 | UInt32(msg[off + 1]) << 16 | UInt32(msg[off + 2]) << 8 | UInt32(msg[off + 3])
                        }
                        for i in 16..<80 {
                            let val = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                            w[i] = (val << 1) | (val >> 31)
                        }
                        var a = h0, b = h1, c = h2, d = h3, e = h4
                        for i in 0..<80 {
                            var f: UInt32 = 0, k: UInt32 = 0
                            if i < 20 { f = (b & c) | ((~b) & d); k = 0x5A827999 }
                            else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1 }
                            else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC }
                            else { f = b ^ c ^ d; k = 0xCA62C1D6 }
                            let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
                        }
                        h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
                    }
                    var result = Data()
                    let parts = [h0.bigEndian, h1.bigEndian, h2.bigEndian, h3.bigEndian, h4.bigEndian]
                    for var p in parts { result.append(Data(bytes: &p, count: 4)) }
                    let hashHex = result.map { String(format: "%02x", $0) }.joined()

                    var parsedName: String? = nil
                    if let nameRange = infoSlice.range(of: Data("4:name".utf8)) {
                        let nameStart = nameRange.upperBound
                        if let colonIdx = (nameStart..<min(nameStart + 10, infoSlice.count)).first(where: { infoSlice[$0] == 0x3a }),
                           let len = Int(String(data: infoSlice.subdata(in: nameStart..<colonIdx), encoding: .utf8) ?? ""),
                           colonIdx + 1 + len <= infoSlice.count {
                            parsedName = String(data: infoSlice.subdata(in: (colonIdx + 1)..<(colonIdx + 1 + len)), encoding: .utf8)
                        }
                    }
                    return (hashHex, parsedName)
                }
            } else {
                idx += 1
            }
        }
        return nil
    }
}

#endif
