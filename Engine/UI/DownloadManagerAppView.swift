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
    @State private var tabBarWidth: CGFloat = 0
    @State private var isScrubbingTabBar: Bool = false
    @State private var scrubLocationX: CGFloat? = nil
    @State private var lastScrubbedIndex: Int? = nil
    @State private var isKeyboardVisible: Bool = false

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
        ZStack(alignment: .bottom) {
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

            if !isKeyboardVisible {
                modernBottomTabBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            visitedTabs.insert(viewModel.selectedTab)
        }
        .onChange(of: viewModel.selectedTab) { newTab in
            visitedTabs.insert(newTab)
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) {
                isKeyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) {
                isKeyboardVisible = false
            }
        }
        #endif
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
        let count = max(1, tabItems.count)
        let slotWidth = tabBarWidth > 0 ? (tabBarWidth / CGFloat(count)) : 0
        let activeHighlightIndex = lastScrubbedIndex ?? viewModel.selectedTab

        return HStack(spacing: 4) {
            ForEach(tabItems, id: \.index) { item in
                let isSelected = activeHighlightIndex == item.index
                let isLensFocused = isScrubbingTabBar && lastScrubbedIndex == item.index

                VStack(spacing: 3) {
                    Image(systemName: isSelected ? item.activeIcon : item.icon)
                        .font(.system(size: 19, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .accentColor : .primary)
                        .frame(height: 22)
                        .overlay(alignment: .topTrailing) {
                            if item.badgeCount > 0 {
                                Text(item.badgeCount > 99 ? "99+" : "\(item.badgeCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, item.badgeCount > 9 ? 5 : 0)
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Capsule().fill(item.badgeColor))
                                    .offset(x: 11, y: -4)
                            }
                        }

                    Text(item.title)
                        .font(.system(size: 10, weight: isSelected ? .bold : .semibold))
                        .foregroundColor(isSelected ? .accentColor : .primary)
                        .lineLimit(1)
                }
                .scaleEffect(isLensFocused ? 1.12 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isLensFocused)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background {
                    if !isScrubbingTabBar && isSelected {
                        Capsule()
                            .fill(Color.primary.opacity(0.09))
                            .matchedGeometryEffect(id: "activeTabPill", in: tabPillNamespace)
                    }
                }
                .contentShape(Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.badgeCount > 0 ? "\(item.title), \(item.badgeCount)" : item.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { tabBarWidth = geo.size.width }
                    .onChange(of: geo.size.width) { newWidth in
                        tabBarWidth = newWidth
                    }
            }
        )
        .overlay(alignment: .leading) {
            if isScrubbingTabBar, let scrubX = scrubLocationX, slotWidth > 0 {
                let lensWidth = slotWidth + 10
                let clampedCenter = min(max(scrubX, lensWidth / 2 - 4), tabBarWidth - lensWidth / 2 + 4)
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.38), Color.white.opacity(0.06), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    )
                    .frame(width: lensWidth, height: 54)
                    .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 4)
                    .offset(x: clampedCenter - lensWidth / 2)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard tabBarWidth > 0 else { return }
                    let x = min(max(value.location.x, 0), tabBarWidth - 1)
                    let idx = min(count - 1, max(0, Int(x / (tabBarWidth / CGFloat(count)))))
                    let moved = hypot(value.translation.width, value.translation.height) > 5

                    if moved || isScrubbingTabBar {
                        if !isScrubbingTabBar {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                                isScrubbingTabBar = true
                            }
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            #endif
                        }
                        scrubLocationX = x
                        if lastScrubbedIndex != idx {
                            lastScrubbedIndex = idx
                            #if canImport(UIKit)
                            UISelectionFeedbackGenerator().selectionChanged()
                            #endif
                            if viewModel.selectedTab != idx {
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                    viewModel.selectedTab = idx
                                }
                            }
                        }
                    }
                }
                .onEnded { value in
                    let wasScrubbing = isScrubbingTabBar
                    let width = max(1, tabBarWidth)
                    let x = min(max(value.location.x, 0), width - 1)
                    let idx = min(count - 1, max(0, Int(x / (width / CGFloat(count)))))

                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        isScrubbingTabBar = false
                        scrubLocationX = nil
                        lastScrubbedIndex = nil
                    }

                    if !wasScrubbing {
                        handleTabTap(idx)
                    } else if viewModel.selectedTab != idx {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                            viewModel.selectedTab = idx
                        }
                    }
                }
        )
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 14, x: 0, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
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

public extension View {
    /// Applies `.navigationViewStyle(.stack)` on iOS so sheets and root views never split unexpectedly.
    @ViewBuilder
    func modernStackNavigation() -> some View {
        #if os(iOS)
        self.navigationViewStyle(.stack)
        #else
        self
        #endif
    }

    /// Uses native iOS 16+ medium/large sheet detents with a visible drag indicator while preserving iOS 15 compatibility.
    @ViewBuilder
    func modernSheetDetents() -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
#endif
