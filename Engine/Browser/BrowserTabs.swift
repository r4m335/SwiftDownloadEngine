import Foundation

/// State that is safe to keep when a browser tab is not currently visible.
/// The WebKit view that owns the actual navigation history is managed by the
/// browser UI layer; this value carries the state needed by the tab overview
/// and by the active-tab presentation.
public struct BrowserTabState: Identifiable, Equatable, Sendable, Codable {
    public static let defaultDesktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    public static let defaultMobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

    public let id: UUID
    public var url: URL?
    public var title: String
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var estimatedProgress: Double
    public var isDesktopMode: Bool
    public var isIncognito: Bool
    public var createdAt: Date
    public var previewUpdatedAt: Date?
    public var groupID: UUID?
    public var customTitle: String?

    public init(
        id: UUID = UUID(),
        url: URL? = nil,
        title: String? = nil,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        estimatedProgress: Double = 0,
        isDesktopMode: Bool = false,
        isIncognito: Bool = false,
        createdAt: Date = Date(),
        previewUpdatedAt: Date? = nil,
        groupID: UUID? = nil,
        customTitle: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title ?? (isIncognito ? "Private Tab" : "New Tab")
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.estimatedProgress = estimatedProgress
        self.isDesktopMode = isDesktopMode
        self.isIncognito = isIncognito
        self.createdAt = createdAt
        self.previewUpdatedAt = previewUpdatedAt
        self.groupID = groupID
        self.customTitle = customTitle
    }

    public var displayName: String {
        if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           title != "New Tab", title != "Private Tab" {
            return title
        }
        if let host = url?.host, !host.isEmpty {
            return host
        }
        return isIncognito ? "Private Tab" : "New Tab"
    }
}

/// A logical group of browser tabs created by dragging tabs together or via the group menu.
public struct BrowserTabGroup: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var title: String
    public var colorName: String
    public var isCollapsed: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        colorName: String = "blue",
        isCollapsed: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.colorName = colorName
        self.isCollapsed = isCollapsed
        self.createdAt = createdAt
    }
}

/// Retains tab-scoped resource discovery, variant stream items, and selections
/// so that switching tabs preserves each tab's individual resource inspector state.
public struct BrowserTabResourceState: Sendable, Equatable {
    public var discoveredResources: [WebpageResource]
    public var variantStreamItems: [String: HLSVariantStreamItem]
    public var selectedResourceIDs: Set<String>
    public var sortOption: ResourceSortOption
    public var sortDirection: SortDirection
    public var groupingOption: ResourceGroupingOption

    public init(
        discoveredResources: [WebpageResource] = [],
        variantStreamItems: [String: HLSVariantStreamItem] = [:],
        selectedResourceIDs: Set<String> = [],
        sortOption: ResourceSortOption = .newest,
        sortDirection: SortDirection = .descending,
        groupingOption: ResourceGroupingOption = .none
    ) {
        self.discoveredResources = discoveredResources
        self.variantStreamItems = variantStreamItems
        self.selectedResourceIDs = selectedResourceIDs
        self.sortOption = sortOption
        self.sortDirection = sortDirection
        self.groupingOption = groupingOption
    }
}

/// Pure tab-selection state. It deliberately has no download or WebKit
/// responsibilities, so closing a tab cannot cancel managed downloads.
public struct BrowserTabManager: Sendable, Equatable {
    public private(set) var tabs: [BrowserTabState]
    public private(set) var groups: [BrowserTabGroup]
    public private(set) var activeTabID: UUID?

    public init(initialTab: BrowserTabState = BrowserTabState()) {
        self.tabs = [initialTab]
        self.groups = []
        self.activeTabID = initialTab.id
    }

    public init(tabs: [BrowserTabState], groups: [BrowserTabGroup] = [], activeTabID: UUID? = nil) {
        self.tabs = tabs.isEmpty ? [BrowserTabState()] : tabs
        self.groups = groups
        if let activeTabID, self.tabs.contains(where: { $0.id == activeTabID }) {
            self.activeTabID = activeTabID
        } else {
            self.activeTabID = self.tabs.first?.id
        }
    }

    public var activeTab: BrowserTabState? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    @discardableResult
    public mutating func createTab(
        select: Bool = true,
        isIncognito: Bool = false,
        isDesktopMode: Bool = false,
        groupID: UUID? = nil
    ) -> UUID {
        let tab = BrowserTabState(
            isDesktopMode: isDesktopMode,
            isIncognito: isIncognito,
            groupID: groupID
        )
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

    // MARK: - Tab Renaming

    @discardableResult
    public mutating func renameTab(_ id: UUID, newTitle: String?) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].customTitle = (trimmed?.isEmpty == false) ? trimmed : nil
        return true
    }

    // MARK: - Tab Grouping

    @discardableResult
    public mutating func createGroup(
        title: String,
        colorName: String = "blue",
        tabIDs: [UUID] = []
    ) -> BrowserTabGroup {
        let group = BrowserTabGroup(title: title, colorName: colorName)
        groups.append(group)
        for tabID in tabIDs {
            if let idx = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[idx].groupID = group.id
            }
        }
        return group
    }

    @discardableResult
    public mutating func renameGroup(_ id: UUID, newTitle: String) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            groups[index].title = trimmed
        }
        return true
    }

    public mutating func deleteGroup(_ id: UUID, closeContainedTabs: Bool = false) {
        if closeContainedTabs {
            let tabIDsToClose = tabs.filter { $0.groupID == id }.map(\.id)
            for tabID in tabIDsToClose {
                _ = closeTab(tabID)
            }
        } else {
            for i in tabs.indices where tabs[i].groupID == id {
                tabs[i].groupID = nil
            }
        }
        groups.removeAll { $0.id == id }
    }

    @discardableResult
    public mutating func addTabToGroup(tabID: UUID, groupID: UUID) -> Bool {
        guard groups.contains(where: { $0.id == groupID }),
              let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        tabs[tabIndex].groupID = groupID
        return true
    }

    @discardableResult
    public mutating func removeTabFromGroup(tabID: UUID) -> Bool {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        let oldGroupID = tabs[tabIndex].groupID
        tabs[tabIndex].groupID = nil
        if let oldGroupID {
            cleanEmptyGroupIfNecessary(oldGroupID)
        }
        return true
    }

    /// Drag and drop tab to group tabs:
    /// - If targetTab is already in a group, adds sourceTab to that group.
    /// - If targetTab is not grouped but sourceTab is, adds targetTab to source's group.
    /// - If neither is grouped, creates a new group containing both tabs.
    @discardableResult
    public mutating func groupTabs(sourceTabID: UUID, targetTabID: UUID) -> UUID? {
        guard sourceTabID != targetTabID,
              let sourceIndex = tabs.firstIndex(where: { $0.id == sourceTabID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetTabID }) else { return nil }

        let targetTab = tabs[targetIndex]
        let sourceTab = tabs[sourceIndex]

        if let targetGroupID = targetTab.groupID {
            tabs[sourceIndex].groupID = targetGroupID
            return targetGroupID
        } else if let sourceGroupID = sourceTab.groupID {
            tabs[targetIndex].groupID = sourceGroupID
            return sourceGroupID
        } else {
            let groupTitle = "\(targetTab.displayName) & \(sourceTab.displayName)"
            let group = createGroup(title: groupTitle, tabIDs: [targetTabID, sourceTabID])
            return group.id
        }
    }

    public mutating func toggleGroupCollapse(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].isCollapsed.toggle()
    }

    public func tabsInGroup(_ groupID: UUID) -> [BrowserTabState] {
        tabs.filter { $0.groupID == groupID }
    }

    public func ungroupedTabs() -> [BrowserTabState] {
        tabs.filter { $0.groupID == nil }
    }

    private mutating func cleanEmptyGroupIfNecessary(_ groupID: UUID) {
        if !tabs.contains(where: { $0.groupID == groupID }) {
            groups.removeAll { $0.id == groupID }
        }
    }

    /// Closes a tab and returns the tab that should become active. The manager
    /// permits zero tabs so the browser can present its home screen naturally.
    @discardableResult
    public mutating func closeTab(_ id: UUID) -> UUID? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return activeTabID }
        let wasActive = activeTabID == id
        let groupID = tabs[index].groupID
        tabs.remove(at: index)
        if let groupID {
            cleanEmptyGroupIfNecessary(groupID)
        }
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

/// Evaluates tab card swipe gestures for dismiss / close actions.
public struct BrowserTabSwipePolicy: Sendable {
    public static let defaultThreshold: Double = 65.0

    public static func shouldClose(translationX: Double, translationY: Double, threshold: Double = defaultThreshold) -> Bool {
        let horizontal = abs(translationX) > threshold
        let verticalUp = translationY < -threshold && abs(translationY) > abs(translationX)
        return horizontal || verticalUp
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
