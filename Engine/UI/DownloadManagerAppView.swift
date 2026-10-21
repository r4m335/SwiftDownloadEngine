#if canImport(SwiftUI)
import SwiftUI

/// Main application entry container coordinating Downloads, Add Download, and Settings screens.
public struct DownloadManagerAppView: View {
    @StateObject public var viewModel: DownloadManagerViewModel
    @State private var selectedTab = 0

    public init(engine: DownloadEngine, downloadsDirectory: URL? = nil) {
        _viewModel = StateObject(wrappedValue: DownloadManagerViewModel(
            engine: engine,
            downloadsDirectory: downloadsDirectory
        ))
    }

    public init(viewModel: DownloadManagerViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            DownloadsView(viewModel: viewModel)
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle.fill")
                }
                .tag(0)

            BrowserView(viewModel: viewModel, onDownloadInitiated: {
                selectedTab = 0
            })
                .tabItem {
                    Label("Browser", systemImage: "globe")
                }
                .tag(1)

            AddDownloadView(viewModel: viewModel, onDownloadAdded: {
                selectedTab = 0
            })
                .tabItem {
                    Label("Add", systemImage: "plus.circle")
                }
                .tag(2)

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
