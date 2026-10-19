import Foundation

#if canImport(LibTorrent)
import LibTorrent

/// Swift-concurrency facade for the native libtorrent session.
///
/// Milestone 2 intentionally covers session lifecycle and health only. Adding magnet
/// links, torrent metadata, transfer controls, and alert-driven progress belongs to the
/// subsequent core-download milestone.
public actor TorrentEngine {
    private let bridge: TorrentSessionBridge
    private var isRunning = false

    public init(
        storageDirectoryURL: URL,
        portStart: UInt = 6881,
        portEnd: UInt = 6891
    ) {
        self.bridge = TorrentSessionBridge(
            storagePath: storageDirectoryURL.path,
            portStart: portStart,
            portEnd: portEnd
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
    }

    /// Returns a point-in-time view of native session health.
    public func status() -> TorrentSessionStatus {
        TorrentSessionStatus(
            isRunning: isRunning,
            isListening: bridge.isListening,
            listenPort: bridge.listenPort,
            libtorrentVersion: TorrentSessionBridge.libtorrentVersion()
        )
    }

    deinit {
        // The bridge also stops itself in dealloc; explicit stop() remains the
        // preferred lifecycle path so callers can control teardown deterministically.
    }
}
#endif
