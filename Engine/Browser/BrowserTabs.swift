import Foundation

/// State that is safe to keep when a browser tab is not currently visible.
/// The WebKit view that owns the actual navigation history is managed by the
/// browser UI layer; this value carries the state needed by the tab overview
/// and by the active-tab presentation.
public struct BrowserTabState: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var url: URL?
    public var title: String
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var estimatedProgress: Double

    public init(
        id: UUID = UUID(),
        url: URL? = nil,
        title: String = "New Tab",
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        estimatedProgress: Double = 0
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.estimatedProgress = estimatedProgress
    }

    public var displayName: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           title != "New Tab" {
            return title
        }
        if let host = url?.host, !host.isEmpty {
            return host
        }
        return "New Tab"
    }
}

/// Pure tab-selection state. It deliberately has no download or WebKit
/// responsibilities, so closing a tab cannot cancel managed downloads.
public struct BrowserTabManager: Sendable, Equatable {
    public private(set) var tabs: [BrowserTabState]
    public private(set) var activeTabID: UUID?

    public init(initialTab: BrowserTabState = BrowserTabState()) {
        self.tabs = [initialTab]
        self.activeTabID = initialTab.id
    }

    public var activeTab: BrowserTabState? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    @discardableResult
    public mutating func createTab(select: Bool = true) -> UUID {
        let tab = BrowserTabState()
        tabs.append(tab)
        if select || activeTabID == nil {
            activeTabID = tab.id
        }
        return tab.id
    }

    @discardableResult
    public mutating func selectTab(_ id: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        activeTabID = id
        return true
    }

    public func tab(withID id: UUID) -> BrowserTabState? {
        tabs.first(where: { $0.id == id })
    }

    @discardableResult
    public mutating func updateTab(_ state: BrowserTabState) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == state.id }) else { return false }
        tabs[index] = state
        return true
    }

    /// Closes a tab and returns the tab that should become active. The manager
    /// permits zero tabs so the browser can present its home screen naturally.
    @discardableResult
    public mutating func closeTab(_ id: UUID) -> UUID? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return activeTabID }
        let wasActive = activeTabID == id
        tabs.remove(at: index)
        guard wasActive else { return activeTabID }

        if tabs.isEmpty {
            activeTabID = nil
        } else {
            let replacementIndex = min(index, tabs.count - 1)
            activeTabID = tabs[replacementIndex].id
        }
        return activeTabID
    }
}

public enum BrowserEdgeGestureAction: Equatable, Sendable {
    case goBack
    case showTabSwitcher
}

/// Accepts only edge-originating horizontal gestures. Middle-of-page drags
/// are intentionally ignored so WebKit retains normal scrolling and controls.
public struct BrowserEdgeGesturePolicy: Sendable, Equatable {
    public var activationWidth: Double
    public var minimumTranslation: Double

    public init(activationWidth: Double = 32, minimumTranslation: Double = 60) {
        self.activationWidth = max(1, activationWidth)
        self.minimumTranslation = max(1, minimumTranslation)
    }

    public func action(
        startX: Double,
        translationX: Double,
        containerWidth: Double,
        canGoBack: Bool,
        modalPresented: Bool
    ) -> BrowserEdgeGestureAction? {
        guard !modalPresented,
              containerWidth > 0,
              startX >= 0,
              startX <= containerWidth else { return nil }

        let startedAtLeftEdge = startX <= activationWidth
        let startedAtRightEdge = startX >= containerWidth - activationWidth

        if startedAtLeftEdge,
           translationX >= minimumTranslation,
           canGoBack {
            return .goBack
        }
        if startedAtRightEdge,
           translationX <= -minimumTranslation {
            return .showTabSwitcher
        }
        return nil
    }
}
