import Foundation

#if canImport(LibTorrent)
import LibTorrent

/// Swift-concurrency facade for the native libtorrent session and torrent transfers.
///
/// Milestone 3: Core Torrent Downloads — provides magnet and .torrent ingestion,
/// transfer state inspection, progress polling, pause/resume/removal controls, and
/// session lifecycle.
public actor TorrentEngine {
    private let bridge: TorrentSessionBridge
    private var isRunning = false
    private var tasks: [String: TorrentTask] = [:]

    public init(
        storageDirectoryURL: URL,
        portStart: UInt = 6881,
        portEnd: UInt = 6891
    ) {
        self.bridge = TorrentSessionBridge(
            storagePath: storageDirectoryURL.path,
            portStart: Int(portStart),
            portEnd: Int(portEnd)
        )
    }

    /// Starts the native session. Calling this repeatedly is safe.
    public func start() throws {
        guard !isRunning else { return }
        try bridge.startSession()
        isRunning = true
    }

    /// Stops the native session. Calling this repeatedly is safe.
    public func stop() {
        guard isRunning else { return }
        bridge.stopSession()
        isRunning = false
        tasks.removeAll()
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

    /// Adds a torrent by Magnet URI.
    /// - Parameters:
    ///   - magnetURI: The RFC-compliant magnet link.
    ///   - saveDirectoryURL: Optional override destination for downloaded files.
    /// - Returns: Initial `TorrentTask` representation.
    @discardableResult
    public func addTorrent(
        magnetURI: String,
        saveDirectoryURL: URL? = nil
    ) throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let savePath = saveDirectoryURL?.path
        let hash = try bridge.addTorrent(withMagnetURI: magnetURI, savePath: savePath)
        guard let status = bridge.status(forTorrentWithHash: hash) else {
            throw TorrentEngineError.bridgeError("Failed to fetch status for added magnet torrent.")
        }
        return updateTask(from: status, source: magnetURI)
    }

    /// Adds a torrent by reading a `.torrent` file from disk.
    /// - Parameters:
    ///   - fileURL: Local URL pointing to a `.torrent` file.
    ///   - saveDirectoryURL: Optional override destination for downloaded files.
    /// - Returns: Initial `TorrentTask` representation.
    @discardableResult
    public func addTorrent(
        fileURL: URL,
        saveDirectoryURL: URL? = nil
    ) throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let savePath = saveDirectoryURL?.path
        let hash = try bridge.addTorrent(withFilePath: fileURL.path, savePath: savePath)
        guard let status = bridge.status(forTorrentWithHash: hash) else {
            throw TorrentEngineError.bridgeError("Failed to fetch status for added file torrent.")
        }
        return updateTask(from: status, source: fileURL.lastPathComponent)
    }

    /// Adds a torrent from raw `.torrent` file bytes.
    /// - Parameters:
    ///   - data: In-memory bencoded torrent payload.
    ///   - name: Optional display name for the task.
    ///   - saveDirectoryURL: Optional override destination for downloaded files.
    /// - Returns: Initial `TorrentTask` representation.
    @discardableResult
    public func addTorrent(
        data: Data,
        name: String? = nil,
        saveDirectoryURL: URL? = nil
    ) throws -> TorrentTask {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let savePath = saveDirectoryURL?.path
        let hash = try bridge.addTorrent(with: data, savePath: savePath)
        guard let status = bridge.status(forTorrentWithHash: hash) else {
            throw TorrentEngineError.bridgeError("Failed to fetch status for added buffer torrent.")
        }
        return updateTask(from: status, source: name ?? "Raw Torrent Data")
    }

    // MARK: - Transfer Controls

    /// Pauses an active torrent transfer.
    public func pause(infoHash: String) throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let key = infoHash.lowercased()
        try bridge.pauseTorrent(withHash: key)
        if var task = tasks[key] {
            task.state = .paused
            tasks[key] = task
        }
    }

    /// Resumes a paused torrent transfer.
    public func resume(infoHash: String) throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let key = infoHash.lowercased()
        try bridge.resumeTorrent(withHash: key)
        if var task = tasks[key] {
            task.state = .downloading
            task.errorMessage = nil
            tasks[key] = task
        }
    }

    /// Removes a torrent from the session, optionally deleting all downloaded payload files.
    public func remove(infoHash: String, deleteFiles: Bool = false) throws {
        guard isRunning else { throw TorrentEngineError.sessionNotRunning }
        let key = infoHash.lowercased()
        try bridge.removeTorrent(withHash: key, deleteFiles: deleteFiles)
        tasks.removeValue(forKey: key)
    }

    // MARK: - Status & Inspection

    /// Fetches the latest task snapshot for a specific infoHash.
    public func task(for infoHash: String) -> TorrentTask? {
        let key = infoHash.lowercased()
        if let bridgeStatus = bridge.status(forTorrentWithHash: key) {
            return updateTask(from: bridgeStatus)
        }
        return tasks[key]
    }

    /// Returns the latest task snapshots for all tracked torrents.
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
