#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks

/// Bridges an explicit foreground download action to iOS 26's continued
/// processing task. URLSession remains the durable fallback if iOS expires or
/// cancels this foreground-originated task.
@MainActor
public final class ContinuedProcessingTaskCoordinator {
    private static let taskIdentifier = "com.r4m335.SwiftDownloadEngine.continued-download"
    private static let pendingIDsKey = "SwiftDownloadEngine.continuedProcessingDownloadIDs"
    private static var didRegister = false
    private static var didSubmit = false

    private let engine: DownloadEngine
    private var monitorTask: Task<Void, Never>?

    public init(engine: DownloadEngine) {
        self.engine = engine
    }

    public func registerIfAvailable() {
        guard #available(iOS 26.0, *) else { return }
        guard !Self.didRegister else { return }
        Self.didRegister = true
        registerAvailable()
    }

    @available(iOS 26.0, *)
    private func registerAvailable() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.handle(task)
            }
        }
    }

    /// Call only in response to an explicit foreground download action.
    public func submit(downloadID: String) {
        guard #available(iOS 26.0, *) else { return }
        submitAvailable(downloadID: downloadID)
    }

    @available(iOS 26.0, *)
    private func submitAvailable(downloadID: String) {
        var pendingIDs = UserDefaults.standard.stringArray(forKey: Self.pendingIDsKey) ?? []
        if !pendingIDs.contains(downloadID) {
            pendingIDs.append(downloadID)
        }
        UserDefaults.standard.set(pendingIDs, forKey: Self.pendingIDsKey)
        guard !Self.didSubmit else { return }
        Self.didSubmit = true

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: "Downloading",
            subtitle: "Continuing while the app is in the background"
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The foreground queue is already running; failure to obtain the
            // optional iOS 26 continuation must not fail the download itself.
            print("[ContinuedProcessing] Submission unavailable: \(error.localizedDescription)")
        }
    }

    @available(iOS 26.0, *)
    private func handle(_ task: BGContinuedProcessingTask) {
        let ids = UserDefaults.standard.stringArray(forKey: Self.pendingIDsKey) ?? []
        guard !ids.isEmpty else {
            Self.didSubmit = false
            task.setTaskCompleted(success: true)
            return
        }

        task.progress.totalUnitCount = 1_000
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor [weak self, weak task] in
                await self?.handoffAfterExpiration(ids: ids)
                task?.setTaskCompleted(success: false)
            }
        }

        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self, weak task] in
            guard let self else { return }
            while !Task.isCancelled {
                let snapshots = await engine.allSnapshots().filter { ids.contains($0.id) }
                let fraction = snapshots.isEmpty
                    ? 1.0
                    : snapshots.map(\.progressFraction).reduce(0, +) / Double(snapshots.count)
                task?.progress.completedUnitCount = Int64(fraction * 1_000)

                if snapshots.isEmpty || snapshots.allSatisfy(\.isTerminal) {
                    UserDefaults.standard.removeObject(forKey: Self.pendingIDsKey)
                    Self.didSubmit = false
                    task?.setTaskCompleted(success: snapshots.allSatisfy(\.isCompleted))
                    return
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func handoffAfterExpiration(ids: [String]) async {
        for id in ids {
            try? await engine.handoffScheduledDownloadToBackground(id: id, earliestBeginDate: Date())
        }
        UserDefaults.standard.removeObject(forKey: Self.pendingIDsKey)
        Self.didSubmit = false
    }
}
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

        let initialSettings = AppSettings.load(from: .standard)
        let engineConfig = initialSettings.makeEngineConfiguration()
        let foregroundSession = ForegroundURLSession.make(
            maximumConnectionsPerHost: SegmentAllocator.maxThreadCount
        )

        var engineInstance: DownloadEngine? = nil
        do {
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            engineInstance = try DownloadEngine(
                configuration: engineConfig,
                storageDirectoryURL: storeDir,
                session: foregroundSession,
                backgroundSessionManager: bgManager
            )
        } catch {
            print("Notice: DownloadEngine primary storage initialization failed: \(error.localizedDescription). Initializing fallback storage.")
            let fallbackStore = FileManager.default.temporaryDirectory.appendingPathComponent("1DMDownloads_Fallback", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallbackStore, withIntermediateDirectories: true)
            engineInstance = try? DownloadEngine(
                configuration: engineConfig,
                storageDirectoryURL: fallbackStore,
                session: foregroundSession,
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
            let coordinator = (try? DownloadCoordinator(session: foregroundSession, persistenceStore: persistence)) ?? (try! DownloadCoordinator(session: foregroundSession, persistenceStore: DownloadPersistenceStore(inMemory: true)))
            let qm = DownloadQueueManager(coordinator: coordinator, persistenceStore: persistence)
            engine = DownloadEngine(configuration: engineConfig, queueManager: qm, coordinator: coordinator, persistenceStore: persistence)
        }

        var torrentEngine: TorrentEngine? = nil
        do {
            let torrentStorage = storeDir.appendingPathComponent("Torrents", isDirectory: true)
            try? FileManager.default.createDirectory(at: torrentStorage, withIntermediateDirectories: true)
            torrentEngine = try TorrentEngine(
                configuration: engineConfig,
                storageDirectoryURL: torrentStorage
            )
        } catch {
            print("Notice: TorrentEngine initialization skipped or deferred: \(error.localizedDescription)")
        }

        let vm = DownloadManagerViewModel(
            engine: engine,
            torrentEngine: torrentEngine,
            downloadsDirectory: downloadsDir,
            userDefaults: .standard
        )
        let orchestrator = StreamingDownloadOrchestrator(
            configuration: engineConfig,
            downloadCoordinator: engine.coordinator,
            downloadEngine: engine
        )
        StreamingDownloadOrchestrator.shared = orchestrator
        Task { await engine.setStreamingOrchestrator(orchestrator) }
        _viewModel = StateObject(wrappedValue: vm)
    }

    /// Primary designated initializer allowing custom view model injection (e.g., testing or preview).
    public init(viewModel: DownloadManagerViewModel) {
        let orchestrator = StreamingDownloadOrchestrator(downloadCoordinator: viewModel.engine.coordinator, downloadEngine: viewModel.engine)
        StreamingDownloadOrchestrator.shared = orchestrator
        Task { await viewModel.engine.setStreamingOrchestrator(orchestrator) }
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
        let orchestrator = StreamingDownloadOrchestrator(downloadCoordinator: engine.coordinator, downloadEngine: engine)
        StreamingDownloadOrchestrator.shared = orchestrator
        Task { await engine.setStreamingOrchestrator(orchestrator) }
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
                    await viewModel.reconcileSchedule()
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
                    await viewModel.scheduleCoordinator.prepareForBackground()

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
