#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Top-level native SwiftUI application coordinator for iOS/macOS.
///
/// Features:
/// - Engine Lifecycle Bootstrapping: Automatically configures both `DownloadEngine` and `TorrentEngine`
///   with persistent storage located in the application sandbox (`Application Support` or `Documents`).
/// - Scene Phase Management: Listens to `.scenePhase` changes (`.active`, `.background`) to start observing
///   real-time transfer events, restore persistent queues, and perform bounded fast-resume saves on backgrounding.
/// - Shared Application State: Connects `DownloadManagerViewModel` to `DownloadManagerAppView`.
public struct SwiftDownloadEngineApp: App {
    @StateObject private var viewModel: DownloadManagerViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasRestoredQueue = false

    /// Resolves the app's persistent storage URL for download manifests and segment states.
    public static func defaultStorageDirectory() -> URL {
        let fileManager = FileManager.default
        let baseDir: URL
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            baseDir = appSupport.appendingPathComponent("SwiftDownloadEngine", isDirectory: true)
        } else {
            baseDir = DownloadManagerViewModel.defaultDownloadsDirectory().appendingPathComponent(".store", isDirectory: true)
        }
        try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        return baseDir
    }

    /// Convenience initializer configuring production engines and view model automatically.
    public init() {
        let downloadsDir = DownloadManagerViewModel.defaultDownloadsDirectory()
        let storeDir = Self.defaultStorageDirectory()

        let engine: DownloadEngine
        do {
            engine = try DownloadEngine(
                storageDirectoryURL: storeDir,
                maxConcurrentDownloads: 3,
                maxGlobalRequests: 12,
                globalBandwidthLimit: nil,
                session: .shared
            )
        } catch {
            fatalError("Failed to initialize DownloadEngine: \(error)")
        }

        var torrentEngine: TorrentEngine? = nil
        do {
            let torrentStorage = storeDir.appendingPathComponent("Torrents", isDirectory: true)
            try? FileManager.default.createDirectory(at: torrentStorage, withIntermediateDirectories: true)
            torrentEngine = try TorrentEngine(storageDirectoryURL: torrentStorage)
        } catch {
            print("Notice: TorrentEngine initialization skipped or deferred: \(error.localizedDescription)")
        }

        let vm = DownloadManagerViewModel(
            engine: engine,
            torrentEngine: torrentEngine,
            downloadsDirectory: downloadsDir,
            userDefaults: .standard
        )
        _viewModel = StateObject(wrappedValue: vm)
    }

    /// Primary designated initializer allowing custom view model injection (e.g., testing or preview).
    public init(viewModel: DownloadManagerViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    /// Designated initializer accepting explicit engines.
    public init(engine: DownloadEngine, torrentEngine: TorrentEngine? = nil, downloadsDirectory: URL? = nil) {
        let vm = DownloadManagerViewModel(
            engine: engine,
            torrentEngine: torrentEngine,
            downloadsDirectory: downloadsDirectory,
            userDefaults: .standard
        )
        _viewModel = StateObject(wrappedValue: vm)
    }

    public var body: some Scene {
        WindowGroup {
            DownloadManagerAppView(viewModel: viewModel)
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                Task { @MainActor in
                    await viewModel.startObserving()
                    try? await viewModel.startTorrentEngine()
                    if !hasRestoredQueue {
                        hasRestoredQueue = true
                        try? await viewModel.restoreQueue(autoStart: false)
                    } else {
                        await viewModel.refreshSnapshots()
                        await viewModel.refreshTorrentSnapshots()
                    }
                }
            case .background:
                #if canImport(UIKit) && !os(watchOS)
                var bgTaskID: UIBackgroundTaskIdentifier = .invalid
                bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "SwiftDownloadEngine.saveState") {
                    if bgTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskID)
                        bgTaskID = .invalid
                    }
                }
                #endif

                Task { @MainActor in
                    await viewModel.refreshSnapshots()
                    await viewModel.refreshTorrentSnapshots()
                    try? await viewModel.stopTorrentEngine()

                    #if canImport(UIKit) && !os(watchOS)
                    if bgTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskID)
                        bgTaskID = .invalid
                    }
                    #endif
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
#endif
