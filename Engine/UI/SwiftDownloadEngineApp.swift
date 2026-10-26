#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit) && !os(watchOS)
public final class AppDelegate: NSObject, UIApplicationDelegate {
    public static var backgroundSessionManager: BackgroundDownloadSessionManager?
    private static var retainedCompletionHandlers: [String: () -> Void] = [:]
    private static let lock = NSLock()

    public func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloadSessionManager.defaultSessionIdentifier else {
            // Unrecognized session identifier: invoke immediately to prevent battery drain
            completionHandler()
            return
        }

        Self.lock.lock()
        defer { Self.lock.unlock() }

        if let manager = Self.backgroundSessionManager {
            manager.setEventsCompletionHandler(completionHandler)
        } else {
            // Retain until manager is instantiated or attached
            Self.retainedCompletionHandlers[identifier] = completionHandler
        }
    }

    public static func attach(manager: BackgroundDownloadSessionManager) {
        lock.lock()
        defer { lock.unlock() }
        self.backgroundSessionManager = manager
        if let pending = retainedCompletionHandlers.removeValue(forKey: manager.sessionIdentifier) {
            manager.setEventsCompletionHandler(pending)
        }
    }

    public static func retainedHandlerCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedCompletionHandlers.count
    }

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        backgroundSessionManager = nil
        retainedCompletionHandlers.removeAll()
    }
}
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
    #if canImport(UIKit) && !os(watchOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

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

        var bgManager: BackgroundDownloadSessionManager? = nil
        #if canImport(UIKit) && !os(watchOS)
        do {
            let bgTransportDir = storeDir.appendingPathComponent("BackgroundTransport", isDirectory: true)
            let manager = try BackgroundDownloadSessionManager(
                sessionIdentifier: BackgroundDownloadSessionManager.defaultSessionIdentifier,
                storageDirectoryURL: bgTransportDir
            )
            bgManager = manager
            AppDelegate.attach(manager: manager)
        } catch {
            print("Notice: BackgroundDownloadSessionManager initialization in AppDelegate skipped: \(error.localizedDescription)")
        }
        #endif

        var engineInstance: DownloadEngine? = nil
        do {
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            engineInstance = try DownloadEngine(
                storageDirectoryURL: storeDir,
                maxConcurrentDownloads: 3,
                maxGlobalRequests: 12,
                globalBandwidthLimit: nil,
                session: .shared,
                backgroundSessionManager: bgManager
            )
        } catch {
            print("Notice: DownloadEngine primary storage initialization failed: \(error.localizedDescription). Initializing fallback storage.")
            let fallbackStore = FileManager.default.temporaryDirectory.appendingPathComponent("1DMDownloads_Fallback", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallbackStore, withIntermediateDirectories: true)
            engineInstance = try? DownloadEngine(
                storageDirectoryURL: fallbackStore,
                maxConcurrentDownloads: 3,
                maxGlobalRequests: 12,
                globalBandwidthLimit: nil,
                session: .shared,
                backgroundSessionManager: nil
            )
        }

        let engine: DownloadEngine
        if let initialized = engineInstance {
            engine = initialized
        } else {
            let emergencyStore = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: emergencyStore, withIntermediateDirectories: true)
            let persistence = (try? DownloadPersistenceStore(storageDirectoryURL: emergencyStore)) ?? DownloadPersistenceStore(inMemory: true)
            let qm = DownloadQueueManager(coordinator: DownloadCoordinator(), persistenceStore: persistence)
            engine = DownloadEngine(queueManager: qm, coordinator: DownloadCoordinator(), persistenceStore: persistence)
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
                        _ = try? await viewModel.engine.reconcileBackgroundTransfers()
                    } else {
                        _ = try? await viewModel.engine.reconcileBackgroundTransfers()
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
