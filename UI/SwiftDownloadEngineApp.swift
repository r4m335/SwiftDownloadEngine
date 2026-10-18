#if canImport(SwiftUI)
import SwiftUI

/// Top-level native SwiftUI application coordinator for iOS/macOS.
///
/// Features:
/// - Engine Lifecycle Bootstrapping: Automatically configures `DownloadEngine` with persistent storage
///   located in the application sandbox (`Application Support` or `Documents`).
/// - Scene Phase Management: Listens to `.scenePhase` changes (`.active`, `.background`) to start observing
///   real-time transfer events and restore persistent queues upon returning to the foreground.
/// - Shared Application State: Connects `DownloadManagerViewModel` to `DownloadManagerAppView`.
public struct SwiftDownloadEngineApp: App {
    @StateObject private var viewModel: DownloadManagerViewModel
    @Environment(\.scenePhase) private var scenePhase

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

    /// Convenience initializer configuring the production engine and view model automatically.
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

        let vm = DownloadManagerViewModel(
            engine: engine,
            downloadsDirectory: downloadsDir,
            userDefaults: .standard
        )
        _viewModel = StateObject(wrappedValue: vm)
    }

    /// Primary designated initializer allowing custom engine injection (e.g., testing or preview).
    public init(viewModel: DownloadManagerViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    /// Primary designated initializer accepting an explicit DownloadEngine.
    public init(engine: DownloadEngine, downloadsDirectory: URL? = nil) {
        let vm = DownloadManagerViewModel(
            engine: engine,
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
                    try? await viewModel.restoreQueue(autoStart: false)
                }
            case .background:
                Task { @MainActor in
                    await viewModel.refreshSnapshots()
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
