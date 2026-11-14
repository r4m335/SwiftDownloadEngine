import Foundation

#if canImport(LibTorrent)
import LibTorrent

public typealias TorrentSession = TorrentEngine

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
    public private(set) var configuration: EngineConfiguration
    private var isRunning = false
    private var tasks: [String: TorrentTask] = [:]

    public init(
        configuration: EngineConfiguration = .default,
        storageDirectoryURL: URL,
        portStart: UInt = 6881,
        portEnd: UInt = 6891,
        persistenceStore: TorrentPersistenceStore? = nil
    ) throws {
        self.configuration = configuration
        self.storageDirectoryURL = storageDirectoryURL
        self.portStart = portStart
        self.portEnd = portEnd
        self.defaultMaxConcurrentTorrents = configuration.maxConcurrentTorrents
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

    public init(
        storageDirectoryURL: URL,
        portStart: UInt = 6881,
        portEnd: UInt = 6891,
        maxConcurrentTorrents: Int,
        persistenceStore: TorrentPersistenceStore? = nil
    ) throws {
        var config = EngineConfiguration.default
        config.maxConcurrentTorrents = maxConcurrentTorrents
        try self.init(
            configuration: config,
            storageDirectoryURL: storageDirectoryURL,
            portStart: portStart,
            portEnd: portEnd,
            persistenceStore: persistenceStore
        )
    }

    public func updateConfiguration(_ newConfig: EngineConfiguration) async throws {
        self.configuration = newConfig
        try await setMaxConcurrentTorrents(newConfig.maxConcurrentTorrents)
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

            // 3. Preserve pause / queued status & sequential mode & custom trackers
            if record.isSequentialDownload {
                try? bridge.setSequentialDownload(true, inTorrentWithHash: hash)
            }
            if let custom = record.customTrackers {
                for t in custom {
                    try? bridge.addTracker(url: t, tier: 0, toTorrentWithHash: hash)
                }
            }
            if record.isExplicitlyPaused {
                bridge.setExplicitlyPaused(true, forTorrentWithHash: hash)
                try? bridge.pauseTorrent(withHash: hash)
            } else if record.state == .paused || record.state == .queued {
                try? bridge.pauseTorrent(withHash: hash)
            }
        }

        // 4. Pump queue to activate admitted torrents up to concurrency limit
        let changes = await sched.pumpQueue()
        for h in changes.promoted {
            try? await safeResumeTorrent(withHash: h, source: "start.pumpQueue")
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
                if rec.isExplicitlyPaused {
                    rec.state = .paused
                } else {
                    rec.state = TorrentState(bridgeState: s.state)
                }
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

    /// Safely resumes a torrent across bridge and scheduler if and only if
    /// it is NOT explicitly paused.
    private func safeResumeTorrent(withHash infoHash: String, source: String = #function) async throws {
        let key = infoHash.lowercased()
        if let sched = scheduler, let record = await sched.record(for: key) {
            if record.isExplicitlyPaused {
                #if DEBUG
                print("[TorrentEngine] Invariant enforced: Rejected resume for explicitly paused torrent: \(key) (caller: \(source))")
                #endif
                bridge.setExplicitlyPaused(true, forTorrentWithHash: key)
                try? bridge.pauseTorrent(withHash: key)
                return
            }
        }
        bridge.setExplicitlyPaused(false, forTorrentWithHash: key)
        try bridge.resumeTorrent(withHash: key)
    }

    // MARK: - Metadata Extraction Helpers

    public static func extractInfoHash(from magnetURI: String) -> String? {
        TorrentMetadataParser.extractInfoHash(from: magnetURI)
    }

    public static func extractDisplayName(from magnetURI: String) -> String? {
        TorrentMetadataParser.extractDisplayName(from: magnetURI)
    }

    public static func extractBencodedInfo(from data: Data) -> (infoHash: String, name: String?, isMultiFile: Bool)? {
        TorrentMetadataParser.extractBencodedInfo(from: data)
    }

    // MARK: - Ingestion

    @discardableResult
    public func addTorrent(
        magnetURI: String,
        name: String? = nil,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false,
        isSequential: Bool = false
    ) async throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let savePath = saveDirectoryURL?.path ?? storageDirectoryURL.path
        let hash = try bridge.addTorrent(withMagnetURI: magnetURI, savePath: savePath)

        if isSequential {
            try? bridge.setSequentialDownload(true, inTorrentWithHash: hash)
        }

        let displayName = name ?? Self.extractDisplayName(from: magnetURI) ?? "Magnet \(hash.prefix(8))"
        if let sched = scheduler {
            let record = try await sched.enqueue(
                infoHash: hash,
                source: magnetURI,
                name: displayName,
                savePath: saveDirectoryURL ?? storageDirectoryURL,
                priority: priority,
                isExplicitlyPaused: isExplicitlyPaused,
                isSequential: isSequential
            )

            if isExplicitlyPaused {
                bridge.setExplicitlyPaused(true, forTorrentWithHash: hash)
                try? bridge.pauseTorrent(withHash: hash)
            } else if record.state == .downloading {
                try? await safeResumeTorrent(withHash: hash, source: "addTorrent.magnet")
            } else {
                try? bridge.pauseTorrent(withHash: hash)
            }
        }

        guard let status = bridge.status(forTorrentWithHash: hash) else {
            throw TorrentEngineError.bridgeError("Failed to fetch status for added magnet torrent.")
        }
        var task = updateTask(from: status, source: magnetURI)
        if !displayName.isEmpty && (status.name.isEmpty || status.name == hash) {
            task.name = displayName
        }
        task.isSequentialDownload = isSequential
        tasks[hash.lowercased()] = task
        return task
    }

    @discardableResult
    public func addTorrent(
        fileURL: URL,
        name: String? = nil,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false,
        isSequential: Bool = false
    ) async throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let savePath = saveDirectoryURL?.path ?? storageDirectoryURL.path
        let hash = try bridge.addTorrent(withFilePath: fileURL.path, savePath: savePath)

        if isSequential {
            try? bridge.setSequentialDownload(true, inTorrentWithHash: hash)
        }

        let displayName = name ?? fileURL.deletingPathExtension().lastPathComponent
        if let sched = scheduler {
            let record = try await sched.enqueue(
                infoHash: hash,
                source: fileURL.path,
                name: displayName,
                savePath: saveDirectoryURL ?? storageDirectoryURL,
                priority: priority,
                isExplicitlyPaused: isExplicitlyPaused,
                isSequential: isSequential
            )

            if isExplicitlyPaused {
                bridge.setExplicitlyPaused(true, forTorrentWithHash: hash)
                try? bridge.pauseTorrent(withHash: hash)
            } else if record.state == .downloading {
                try? await safeResumeTorrent(withHash: hash, source: "addTorrent.file")
            } else {
                try? bridge.pauseTorrent(withHash: hash)
            }
        }

        guard let status = bridge.status(forTorrentWithHash: hash) else {
            throw TorrentEngineError.bridgeError("Failed to fetch status for added file torrent.")
        }
        var task = updateTask(from: status, source: fileURL.lastPathComponent)
        if !displayName.isEmpty && (status.name.isEmpty || status.name == hash) {
            task.name = displayName
        }
        task.isSequentialDownload = isSequential
        tasks[hash.lowercased()] = task
        return task
    }

    @discardableResult
    public func addTorrent(
        data: Data,
        name: String? = nil,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false,
        isSequential: Bool = false
    ) async throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let savePath = saveDirectoryURL?.path ?? storageDirectoryURL.path
        let hash = try bridge.addTorrent(with: data, savePath: savePath)

        if isSequential {
            try? bridge.setSequentialDownload(true, inTorrentWithHash: hash)
        }

        let displayName = name ?? "Torrent \(hash.prefix(8))"
        if let sched = scheduler {
            let record = try await sched.enqueue(
                infoHash: hash,
                source: "raw-buffer",
                name: displayName,
                savePath: saveDirectoryURL ?? storageDirectoryURL,
                priority: priority,
                isExplicitlyPaused: isExplicitlyPaused,
                isSequential: isSequential
            )

            if isExplicitlyPaused {
                bridge.setExplicitlyPaused(true, forTorrentWithHash: hash)
                try? bridge.pauseTorrent(withHash: hash)
            } else if record.state == .downloading {
                try? await safeResumeTorrent(withHash: hash, source: "addTorrent.buffer")
            } else {
                try? bridge.pauseTorrent(withHash: hash)
            }
        }

        guard let status = bridge.status(forTorrentWithHash: hash) else {
            throw TorrentEngineError.bridgeError("Failed to fetch status for added buffer torrent.")
        }
        var task = updateTask(from: status, source: displayName)
        task.isSequentialDownload = isSequential
        tasks[hash.lowercased()] = task
        return task
    }

    // MARK: - Transfer Controls

    public func pause(infoHash: String) async throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let key = infoHash.lowercased()
        bridge.setExplicitlyPaused(true, forTorrentWithHash: key)
        try bridge.pauseTorrent(withHash: key)

        try? bridge.requestResumeData(forTorrentWithHash: key)

        if let sched = scheduler {
            let changes = try await sched.pause(infoHash: key)
            for h in changes.promoted {
                try? await safeResumeTorrent(withHash: h, source: "pause.promoted")
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
        bridge.setExplicitlyPaused(false, forTorrentWithHash: key)

        if let sched = scheduler {
            let changes = try await sched.resume(infoHash: key)
            for h in changes.promoted {
                try? await safeResumeTorrent(withHash: h, source: "resume.promoted")
            }
            for h in changes.demoted {
                try? bridge.pauseTorrent(withHash: h)
            }
            if var task = tasks[key], let rec = await sched.record(for: key) {
                task.isExplicitlyPaused = false
                task.state = rec.state
                task.errorMessage = nil
                tasks[key] = task
            }
        } else {
            try bridge.resumeTorrent(withHash: key)
            if var task = tasks[key] {
                task.isExplicitlyPaused = false
                task.state = .downloading
                task.errorMessage = nil
                tasks[key] = task
            }
        }
    }

    public func remove(infoHash: String, deleteFiles: Bool = false) async throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let key = infoHash.lowercased()
        try bridge.removeTorrent(withHash: key, deleteFiles: deleteFiles)

        if let sched = scheduler {
            let changes = try await sched.remove(infoHash: key)
            for h in changes.promoted {
                try? await safeResumeTorrent(withHash: h, source: "remove.promoted")
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
            try? await safeResumeTorrent(withHash: h, source: "setMaxConcurrentTorrents.promoted")
        }
        for h in changes.demoted {
            try? bridge.pauseTorrent(withHash: h)
        }
    }

    public func setPriority(_ priority: TorrentPriority, for infoHash: String) async throws {
        guard let sched = scheduler else { return }
        let changes = try await sched.setPriority(priority, for: infoHash)
        for h in changes.promoted {
            try? await safeResumeTorrent(withHash: h, source: "setPriority.promoted")
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

    // MARK: - Milestone 4.2: Sequential Download Mode & Tracker Management

    public func setSequentialDownload(_ sequential: Bool, for infoHash: String) async throws {
        let key = infoHash.lowercased()
        try bridge.setSequentialDownload(sequential, inTorrentWithHash: key)
        if var t = tasks[key] {
            t.isSequentialDownload = sequential
            tasks[key] = t
        }
        if var record = await persistenceStore.loadRecord(infoHash: key) {
            record.isSequentialDownload = sequential
            try? await persistenceStore.saveRecord(record)
        }
    }

    public func isSequentialDownload(for infoHash: String) async -> Bool {
        let key = infoHash.lowercased()
        return bridge.isSequentialDownload(forTorrentWithHash: key)
    }

    public func trackers(for infoHash: String) async -> [TorrentTrackerInfo] {
        let key = infoHash.lowercased()
        if let nativeTrackers = bridge.trackers(forTorrentWithHash: key) {
            return nativeTrackers.map { t in
                let state: TorrentTrackerState
                switch t.state {
                case .working: state = .working
                case .updating: state = .updating
                case .notWorking: state = .notWorking
                case .notContacted: state = .notContacted
                @unknown default: state = .notContacted
                }
                return TorrentTrackerInfo(
                    tier: t.tier,
                    url: t.url,
                    state: state,
                    numPeers: t.numPeers,
                    numSeeds: t.numSeeds,
                    numDownloaded: t.numDownloaded,
                    message: t.message
                )
            }
        }
        return tasks[key]?.trackers ?? []
    }

    public func addTracker(url: String, tier: Int = 0, for infoHash: String) async throws {
        let validated = try TorrentTrackerURLValidator.validate(url)
        let key = infoHash.lowercased()
        try bridge.addTracker(url: validated.absoluteString, tier: tier, toTorrentWithHash: key)
        if var record = await persistenceStore.loadRecord(infoHash: key) {
            var list = record.customTrackers ?? []
            if !list.contains(validated.absoluteString) {
                list.append(validated.absoluteString)
                record.customTrackers = list
                try? await persistenceStore.saveRecord(record)
            }
        }
    }

    public func removeTracker(url: String, for infoHash: String) async throws {
        let key = infoHash.lowercased()
        try bridge.removeTracker(url: url, fromTorrentWithHash: key)
        if var record = await persistenceStore.loadRecord(infoHash: key) {
            record.customTrackers?.removeAll(where: { $0 == url })
            try? await persistenceStore.saveRecord(record)
        }
    }

    public func replaceTrackers(_ urls: [String], for infoHash: String) async throws {
        let validatedURLs = try urls.map { try TorrentTrackerURLValidator.validate($0).absoluteString }
        let key = infoHash.lowercased()
        try bridge.replaceTrackers(validatedURLs, inTorrentWithHash: key)
        if var record = await persistenceStore.loadRecord(infoHash: key) {
            record.customTrackers = validatedURLs
            try? await persistenceStore.saveRecord(record)
        }
    }

    public func forceReannounce(for infoHash: String) async throws {
        let key = infoHash.lowercased()
        try bridge.forceReannounce(forTorrentWithHash: key)
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
                    // Enforce native pause invariant if bridge status deviated
                    bridge.setExplicitlyPaused(true, forTorrentWithHash: key)
                    if bridgeStatus.state != .paused {
                        try? bridge.pauseTorrent(withHash: key)
                    }
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
                        // Enforce native pause invariant if bridge status deviated
                        bridge.setExplicitlyPaused(true, forTorrentWithHash: key)
                        if let bridgeStatus = bridge.status(forTorrentWithHash: key), bridgeStatus.state != .paused {
                            try? bridge.pauseTorrent(withHash: key)
                        }
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
        let isSequential = bridge.isSequentialDownload(forTorrentWithHash: key)

        if var existing = tasks[key] {
            existing.state = state
            existing.progress = progress
            if !status.name.isEmpty && status.name != key {
                existing.name = status.name
            }
            existing.errorMessage = status.errorMessage
            existing.isSequentialDownload = isSequential
            tasks[key] = existing
            return existing
        } else {
            let fallbackName: String = {
                if !status.name.isEmpty && status.name != key {
                    return status.name
                }
                if let src = source, let dn = TorrentMetadataParser.extractDisplayName(from: src) {
                    return dn
                }
                return key
            }()
            let task = TorrentTask(
                source: source ?? "magnet:?xt=urn:btih:\(key)",
                name: fallbackName,
                savePath: saveURL,
                state: state,
                progress: progress,
                errorMessage: status.errorMessage,
                infoHash: key,
                isSequentialDownload: isSequential
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

    public func connectPeer(address: String, port: UInt, toTorrentWithHash infoHash: String) throws {
        try bridge.connectPeer(address: address, port: Int(port), toTorrentWithHash: infoHash)
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
    public private(set) var configuration: EngineConfiguration
    private var isRunning = false
    private var tasks: [String: TorrentTask] = [:]

    public init(
        configuration: EngineConfiguration = .default,
        storageDirectoryURL: URL,
        portStart: UInt = 6881,
        portEnd: UInt = 6891,
        persistenceStore: TorrentPersistenceStore? = nil
    ) throws {
        self.configuration = configuration
        self.storageDirectoryURL = storageDirectoryURL
        self.portStart = portStart
        self.portEnd = portEnd
        self.currentMaxConcurrentTorrents = configuration.maxConcurrentTorrents
        if let store = persistenceStore {
            self.persistenceStore = store
        } else {
            let persistURL = storageDirectoryURL.appendingPathComponent("TorrentMetadata", isDirectory: true)
            self.persistenceStore = try TorrentPersistenceStore(storageDirectoryURL: persistURL)
        }
    }

    public init(
        storageDirectoryURL: URL,
        portStart: UInt = 6881,
        portEnd: UInt = 6891,
        maxConcurrentTorrents: Int,
        persistenceStore: TorrentPersistenceStore? = nil
    ) throws {
        var config = EngineConfiguration.default
        config.maxConcurrentTorrents = maxConcurrentTorrents
        try self.init(
            configuration: config,
            storageDirectoryURL: storageDirectoryURL,
            portStart: portStart,
            portEnd: portEnd,
            persistenceStore: persistenceStore
        )
    }

    public func updateConfiguration(_ newConfig: EngineConfiguration) async throws {
        self.configuration = newConfig
        try await setMaxConcurrentTorrents(newConfig.maxConcurrentTorrents)
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
            var task = TorrentTask(
                id: record.id,
                source: record.source,
                name: record.name,
                savePath: record.savePath,
                state: state,
                createdAt: record.createdAt,
                infoHash: record.infoHash,
                priority: record.priority,
                isExplicitlyPaused: record.isExplicitlyPaused,
                isSequentialDownload: record.isSequentialDownload,
                filePriorities: record.filePriorities,
                seedingPreference: record.seedingPreference
            )
            if let custom = record.customTrackers {
                task.trackers = custom.enumerated().map { idx, u in
                    TorrentTrackerInfo(tier: idx, url: u, state: .notContacted)
                }
            }
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
        name: String? = nil,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false,
        isSequential: Bool = false
    ) async throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        guard let infoHash = Self.extractInfoHash(from: magnetURI) else {
            throw TorrentEngineError.invalidMagnetURI(magnetURI)
        }
        if tasks[infoHash] != nil {
            throw TorrentEngineError.duplicateTorrent(infoHash)
        }
        let saveDir = saveDirectoryURL ?? storageDirectoryURL
        let resolvedName = name ?? Self.extractDisplayName(from: magnetURI) ?? "Torrent-\(infoHash.prefix(8))"

        guard let sched = scheduler else { throw TorrentEngineError.sessionNotRunning }
        let record = try await sched.enqueue(
            infoHash: infoHash,
            source: magnetURI,
            name: resolvedName,
            savePath: saveDir.appendingPathComponent(resolvedName),
            priority: priority,
            isExplicitlyPaused: isExplicitlyPaused,
            isSequential: isSequential
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
            isExplicitlyPaused: record.isExplicitlyPaused,
            isSequentialDownload: isSequential
        )
        tasks[infoHash] = task
        return task
    }

    public func addTorrent(
        fileURL: URL,
        name: String? = nil,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false,
        isSequential: Bool = false
    ) async throws -> TorrentTask {
        let data = try Data(contentsOf: fileURL)
        var resolvedName = name ?? fileURL.deletingPathExtension().lastPathComponent
        if name == nil, let parsed = Self.extractBencodedInfo(from: data), let parsedName = parsed.name {
            resolvedName = parsedName
        }
        return try await addTorrent(
            data: data,
            name: resolvedName,
            saveDirectoryURL: saveDirectoryURL,
            priority: priority,
            isExplicitlyPaused: isExplicitlyPaused,
            isSequential: isSequential
        )
    }

    public func addTorrent(
        data: Data,
        name: String? = nil,
        saveDirectoryURL: URL? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false,
        isSequential: Bool = false
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
            isExplicitlyPaused: isExplicitlyPaused,
            isSequential: isSequential
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
            isExplicitlyPaused: record.isExplicitlyPaused,
            isSequentialDownload: isSequential
        )
        tasks[infoHash] = task
        return task
    }

    public func pause(infoHash: String) async throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let hash = infoHash.lowercased()
        guard var task = tasks[hash] else { throw TorrentEngineError.torrentNotFound }
        _ = try await scheduler?.pause(infoHash: hash)
        task.state = .paused
        task.isExplicitlyPaused = true
        tasks[hash] = task
    }

    public func pauseTorrent(infoHash: String) async throws {
        try await pause(infoHash: infoHash)
    }

    public func resume(infoHash: String) async throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let hash = infoHash.lowercased()
        guard var task = tasks[hash] else { throw TorrentEngineError.torrentNotFound }
        let changes = try await scheduler?.resume(infoHash: hash) ?? (promoted: [], demoted: [])
        task.isExplicitlyPaused = false
        if let rec = await scheduler?.record(for: hash) {
            task.state = rec.state
        } else {
            task.state = changes.promoted.contains(hash) ? .downloading : .queued
        }
        tasks[hash] = task
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
            } else {
                task.state = rec.state
            }
            tasks[hash] = task
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

    // MARK: - Milestone 4.2: Sequential Download Mode & Tracker Management

    public func setSequentialDownload(_ sequential: Bool, for infoHash: String) async throws {
        let key = infoHash.lowercased()
        guard var task = tasks[key] else { throw TorrentEngineError.torrentNotFound }
        task.isSequentialDownload = sequential
        tasks[key] = task
        if var record = await persistenceStore.loadRecord(infoHash: key) {
            record.isSequentialDownload = sequential
            try? await persistenceStore.saveRecord(record)
        }
    }

    public func isSequentialDownload(for infoHash: String) async -> Bool {
        let key = infoHash.lowercased()
        return tasks[key]?.isSequentialDownload ?? false
    }

    public func trackers(for infoHash: String) async -> [TorrentTrackerInfo] {
        let key = infoHash.lowercased()
        guard let task = tasks[key] else { return [] }
        if let existing = task.trackers {
            return existing
        }
        return [
            TorrentTrackerInfo(tier: 0, url: "udp://tracker.opentrackr.org:1337/announce", state: .working, numPeers: 12, numSeeds: 45)
        ]
    }

    public func addTracker(url: String, tier: Int = 0, for infoHash: String) async throws {
        let validated = try TorrentTrackerURLValidator.validate(url)
        let key = infoHash.lowercased()
        guard var task = tasks[key] else { throw TorrentEngineError.torrentNotFound }
        var current = task.trackers ?? []
        if !current.contains(where: { $0.url == validated.absoluteString }) {
            current.append(TorrentTrackerInfo(tier: tier, url: validated.absoluteString, state: .notContacted))
            task.trackers = current
            tasks[key] = task
        }
        if var record = await persistenceStore.loadRecord(infoHash: key) {
            var list = record.customTrackers ?? []
            if !list.contains(validated.absoluteString) {
                list.append(validated.absoluteString)
                record.customTrackers = list
                try? await persistenceStore.saveRecord(record)
            }
        }
    }

    public func removeTracker(url: String, for infoHash: String) async throws {
        let key = infoHash.lowercased()
        guard var task = tasks[key] else { throw TorrentEngineError.torrentNotFound }
        task.trackers?.removeAll(where: { $0.url == url })
        tasks[key] = task
        if var record = await persistenceStore.loadRecord(infoHash: key) {
            record.customTrackers?.removeAll(where: { $0 == url })
            try? await persistenceStore.saveRecord(record)
        }
    }

    public func replaceTrackers(_ urls: [String], for infoHash: String) async throws {
        let validatedURLs = try urls.map { try TorrentTrackerURLValidator.validate($0).absoluteString }
        let key = infoHash.lowercased()
        guard var task = tasks[key] else { throw TorrentEngineError.torrentNotFound }
        task.trackers = validatedURLs.enumerated().map { TorrentTrackerInfo(tier: $0.offset, url: $0.element, state: .notContacted) }
        tasks[key] = task
        if var record = await persistenceStore.loadRecord(infoHash: key) {
            record.customTrackers = validatedURLs
            try? await persistenceStore.saveRecord(record)
        }
    }

    public func forceReannounce(for infoHash: String) async throws {
        let key = infoHash.lowercased()
        guard var task = tasks[key] else { throw TorrentEngineError.torrentNotFound }
        if let current = task.trackers {
            task.trackers = current.map { t in
                var updated = t
                updated.state = .updating
                return updated
            }
            tasks[key] = task
        }
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
                } else {
                    t.state = rec.state
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

    public func connectPeer(address: String, port: UInt, toTorrentWithHash infoHash: String) throws {
        // Fallback: no-op for non-native environment
    }

    public func saveState() async throws {}

    public static func extractInfoHash(from magnetURI: String) -> String? {
        TorrentMetadataParser.extractInfoHash(from: magnetURI)
    }

    public static func extractDisplayName(from magnetURI: String) -> String? {
        TorrentMetadataParser.extractDisplayName(from: magnetURI)
    }

    public static func extractBencodedInfo(from data: Data) -> (infoHash: String, name: String?, isMultiFile: Bool)? {
        TorrentMetadataParser.extractBencodedInfo(from: data)
    }
}

#endif
