#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public extension Notification.Name {
    static let sdeBrowserTabRetapped = Notification.Name("SDEBrowserTabRetapped")
}

/// Main application entry container coordinating Downloads, Browser, Media, and Settings screens.
public struct DownloadManagerAppView: View {
    @StateObject public var viewModel: DownloadManagerViewModel
    @State private var visitedTabs: Set<Int> = [0]
    @Namespace private var tabPillNamespace

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

    private var activeDownloadCount: Int {
        viewModel.unifiedTransfers.filter { $0.state == .downloading || $0.state == .queued }.count
    }

    private var failedDownloadCount: Int {
        viewModel.unifiedTransfers.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if visitedTabs.contains(0) || viewModel.selectedTab == 0 {
                    DownloadsView(viewModel: viewModel)
                        .opacity(viewModel.selectedTab == 0 ? 1 : 0)
                        .allowsHitTesting(viewModel.selectedTab == 0)
                        .zIndex(viewModel.selectedTab == 0 ? 1 : 0)
                }

                if visitedTabs.contains(1) || viewModel.selectedTab == 1 {
                    BrowserView(viewModel: viewModel, onDownloadInitiated: {
                        viewModel.selectedTab = 0
                    }, onOpenAddDownload: { url in
                        viewModel.addDownloadPrefilledURL = url.absoluteString
                        viewModel.showAddDownloadSheet = true
                        viewModel.selectedTab = 0
                    }, onOpenDownloads: {
                        viewModel.selectedTab = 0
                    })
                    .opacity(viewModel.selectedTab == 1 ? 1 : 0)
                    .allowsHitTesting(viewModel.selectedTab == 1)
                    .zIndex(viewModel.selectedTab == 1 ? 1 : 0)
                }

                if visitedTabs.contains(2) || viewModel.selectedTab == 2 {
                    LIDPlayerLibraryView(
                        baseDirectory: viewModel.downloadsDirectoryURL,
                        knownTransfers: viewModel.unifiedTransfers
                    )
                    .opacity(viewModel.selectedTab == 2 ? 1 : 0)
                    .allowsHitTesting(viewModel.selectedTab == 2)
                    .zIndex(viewModel.selectedTab == 2 ? 1 : 0)
                }

                if visitedTabs.contains(3) || viewModel.selectedTab == 3 {
                    SettingsView(viewModel: viewModel)
                        .opacity(viewModel.selectedTab == 3 ? 1 : 0)
                        .allowsHitTesting(viewModel.selectedTab == 3)
                        .zIndex(viewModel.selectedTab == 3 ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            modernBottomTabBar
        }
        .onAppear {
            visitedTabs.insert(viewModel.selectedTab)
        }
        .onChange(of: viewModel.selectedTab) { newTab in
            visitedTabs.insert(newTab)
        }
        .task {
            // Automatically begin observing real-time engine events
            await viewModel.startObserving()
        }
    }

    private struct AppTabDescriptor {
        let index: Int
        let title: String
        let icon: String
        let activeIcon: String
        let badgeCount: Int
        let badgeColor: Color
    }

    private var tabItems: [AppTabDescriptor] {
        let dlBadgeCount = activeDownloadCount > 0 ? activeDownloadCount : failedDownloadCount
        let dlBadgeColor: Color = activeDownloadCount > 0 ? .blue : .red
        return [
            AppTabDescriptor(
                index: 0,
                title: "Downloads",
                icon: "arrow.down.circle",
                activeIcon: "arrow.down.circle.fill",
                badgeCount: dlBadgeCount,
                badgeColor: dlBadgeColor
            ),
            AppTabDescriptor(
                index: 1,
                title: "Browser",
                icon: "safari",
                activeIcon: "safari.fill",
                badgeCount: 0,
                badgeColor: .blue
            ),
            AppTabDescriptor(
                index: 2,
                title: "Media",
                icon: "play.rectangle",
                activeIcon: "play.rectangle.fill",
                badgeCount: 0,
                badgeColor: .blue
            ),
            AppTabDescriptor(
                index: 3,
                title: "Settings",
                icon: "gearshape",
                activeIcon: "gearshape.fill",
                badgeCount: 0,
                badgeColor: .blue
            )
        ]
    }

    private var modernBottomTabBar: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.6)

            HStack(spacing: 4) {
                ForEach(tabItems, id: \.index) { item in
                    let isSelected = viewModel.selectedTab == item.index
                    Button {
                        handleTabTap(item.index)
                    } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                if isSelected {
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.14))
                                        .frame(width: 54, height: 30)
                                        .matchedGeometryEffect(id: "activeTabPill", in: tabPillNamespace)
                                }

                                Image(systemName: isSelected ? item.activeIcon : item.icon)
                                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(isSelected ? .accentColor : .secondary)
                                    .frame(width: 54, height: 30)
                                    .overlay(alignment: .topTrailing) {
                                        if item.badgeCount > 0 {
                                            Text(item.badgeCount > 99 ? "99+" : "\(item.badgeCount)")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, item.badgeCount > 9 ? 4 : 0)
                                                .frame(minWidth: 16, minHeight: 16)
                                                .background(Capsule().fill(item.badgeColor))
                                                .offset(x: -6, y: 1)
                                        }
                                    }
                            }

                            Text(item.title)
                                .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .accentColor : .secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.badgeCount > 0 ? "\(item.title), \(item.badgeCount)" : item.title)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 8)
            .background(.ultraThinMaterial)
        }
    }

    private func handleTabTap(_ index: Int) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif

        if viewModel.selectedTab == index {
            // WhatsApp / Telegram / YouTube behavior when tapping the active tab:
            // Reset filter / expand collapsed browser bar
            switch index {
            case 0:
                viewModel.selectedFilter = .all
                viewModel.searchText = ""
            case 1:
                NotificationCenter.default.post(name: .sdeBrowserTabRetapped, object: nil)
            default:
                break
            }
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.selectedTab = index
            }
        }
    }
}
#endif
