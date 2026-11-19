#if canImport(SwiftUI)
import SwiftUI

/// Main application entry container coordinating Downloads, Browser, Media, and Settings screens.
public struct DownloadManagerAppView: View {
    @StateObject public var viewModel: DownloadManagerViewModel

    public init(engine: DownloadEngine, downloadsDirectory: URL? = nil) {
        let hlsPersistenceStore: HLSPersistenceStore?
        do {
            hlsPersistenceStore = try HLSPersistenceStore(
                storageDirectoryURL: engine.persistenceStore.storageDirectoryURL
            )
        } catch {
            PipelineLogger.shared.log(stage: .persistence, message: "Failed to create HLSPersistenceStore in DownloadManagerAppView: \(error)")
            hlsPersistenceStore = nil
        }
        let orchestrator = StreamingDownloadOrchestrator(
            downloadCoordinator: engine.coordinator,
            downloadEngine: engine,
            hlsPersistenceStore: hlsPersistenceStore
        )
        let vm = DownloadManagerViewModel(
            engine: engine,
            downloadsDirectory: downloadsDirectory,
            streamingOrchestrator: orchestrator
        )
        _viewModel = StateObject(wrappedValue: vm)
    }

    public init(viewModel: DownloadManagerViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            // Tab 0: Downloads
            DownloadsView(viewModel: viewModel)
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle.fill")
                }
                .tag(0)

            // Tab 1: Browser
            BrowserView(viewModel: viewModel, onDownloadInitiated: {
                viewModel.selectedTab = 0
            }, onOpenAddDownload: { url in
                viewModel.addDownloadPrefilledURL = url.absoluteString
                viewModel.showAddDownloadSheet = true
                viewModel.selectedTab = 0
            }, onOpenDownloads: {
                viewModel.selectedTab = 0
            })
                .tabItem {
                    Label("Browser", systemImage: "globe")
                }
                .tag(1)

            // Tab 2: Media (Moved from Downloads page)
            LIDPlayerLibraryView(
                baseDirectory: viewModel.downloadsDirectoryURL,
                knownTransfers: viewModel.unifiedTransfers
            )
                .tabItem {
                    Label("Media", systemImage: "film.stack")
                }
                .tag(2)

            // Tab 3: Settings
            SettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .task {
            // Automatically begin observing real-time engine events
            await viewModel.startObserving()
        }
    }
}
#endif
