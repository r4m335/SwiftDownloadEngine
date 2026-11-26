#if canImport(SwiftUI)
import SwiftUI

#if canImport(WebKit)
import WebKit
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct BrowserExternalAppLink: Identifiable, Equatable {
    public let id: String
    public let url: URL
    public let webURL: URL?
    public let serviceName: String

    public init(url: URL, webURL: URL? = nil, serviceName: String) {
        self.id = url.absoluteString
        self.url = url
        self.webURL = webURL
        self.serviceName = serviceName
    }
}

// MARK: - Browser View Model

/// Manages navigation state and coordinates actions between SwiftUI and WKWebView.
@MainActor
public final class BrowserViewModel: NSObject, ObservableObject {
    @Published public var urlInputText: String = ""
    @Published public var currentURL: URL? = nil
    @Published public var pageTitle: String = ""
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    @Published public var isLoading: Bool = false
    @Published public var estimatedProgress: Double = 0.0
    @Published public var errorMessage: String? = nil
    @Published public var selectedSearchEngine: BrowserSearchEngine = .duckDuckGo
    @Published public var activeSearchEngineID: String = BrowserSearchEngine.duckDuckGo.rawValue
    @Published public var customSearchEngines: [CustomSearchEngine] = []
    @Published public var isShowingSearchEngineManager: Bool = false
    @Published public var quickAccessShortcuts: [QuickAccessShortcut] = []
    public let quickAccessStore: QuickAccessStore
    public let bookmarkStore: BrowserBookmarkStore
    public let historyStore: BrowserHistoryStore
    public let sitePermissionsStore: BrowserSitePermissionsStore
    public let faviconService: FaviconService
    public let tabPreviewCache: BrowserTabPreviewCache
    public let certificateDecisionStore: BrowserCertificateDecisionStore
    public let contentBlocker: BrowserContentBlocker
    public let permissionCoordinator: BrowserPermissionCoordinator
    public let promptHandler: BrowserPromptHandler
    public let authenticationHandler: BrowserAuthenticationHandler
    public let diagnosticLogger: BrowserDiagnosticLogger
    public let streamManifestExpander: StreamManifestResourceExpander
    @Published public private(set) var tabs: [BrowserTabState] = []
    @Published public private(set) var groups: [BrowserTabGroup] = []
    @Published public private(set) var activeTabID: UUID?
    @Published public var isShowingTabSwitcher: Bool = false
    @Published public var isShowingBookmarksAndHistory: Bool = false
    @Published public var isToolbarCollapsed: Bool = false
    @Published public var externalAppLinkPrompt: BrowserExternalAppLink?

    public func setToolbarCollapsed(_ collapsed: Bool) {
        let target = collapsed && currentURL != nil && !isShowingFindInPage
        guard isToolbarCollapsed != target else { return }
        isToolbarCollapsed = target
    }

    // Download modal state
    @Published public var isShowingDownloadSheet: Bool = false
    @Published public var downloadCandidateURL: URL? = nil
    @Published public var downloadCandidateFilename: String = ""
    @Published public var downloadCandidateRequestContext: BrowserRequestContext? = nil
    @Published public var useBrowserCredentials: Bool = true
    @Published public var downloadCandidateThreads: Int = 6
    @Published public var downloadCandidateSpeedLimitKBps: String = ""
    @Published public var downloadSuccessNotification: String? = nil
    @Published public var activeDownloadCandidate: BrowserMediaCandidate? = nil
    @Published public var activeDownloadResource: WebpageResource? = nil
    @Published public var activeStreamingFilename: String? = nil
    @Published public var resumeTargetTransferID: String? = nil
    @Published public var resumeTargetTransferName: String? = nil
    private var activeMSECaptureSuggestedFilename: String? = nil

    /// Count of distinct downloadable media assets detected on the active webpage.
    public var detectedMediaCount: Int {
        var seenKeys = Set<String>()
        var count = 0
        for candidate in mediaCandidates {
            guard candidate.kind != .unknown, candidate.availability != .unsupported else { continue }
            let url = candidate.url ?? URL(string: candidate.rawURL)
            let ext = url?.pathExtension.lowercased()
            if ext == "ts" || ext == "m4s" { continue }
            if let mime = candidate.mimeType?.lowercased(), mime.contains("mp2t") || mime.contains("iso.segment") { continue }

            let key = (url?.absoluteString ?? candidate.rawURL).lowercased()
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                count += 1
            }
        }
        return count
    }

    // Magnet-link interception state
    @Published public var magnetCandidate: MagnetLink? = nil
    @Published public var magnetSourcePageURL: URL? = nil
    @Published public var isShowingMagnetSheet: Bool = false
    @Published public var magnetErrorMessage: String? = nil

    // Download detection & interception state (Milestone 7B / 7C)
    @Published public var detectedDownloadURL: URL? = nil
    @Published public var detectedDownloadFilename: String = ""
    @Published public var activeHandoff: BrowserDownloadHandoff? = nil
    public let interceptionManager = BrowserDownloadInterceptionManager()

    // Resource discovery state (Milestone 7D)
    @Published public var isShowingResourceInspector: Bool = false
    @Published public var isScanningResources: Bool = false
    @Published public var resourceSortOption: ResourceSortOption = .newest
    @Published public var resourceSortDirection: SortDirection = .descending
    @Published public var resourceGroupingOption: ResourceGroupingOption = .none
    @Published public var discoveredResources: [WebpageResource] = [] {
        didSet {
            if discoveryCoordinator.discoveredResources != discoveredResources {
                discoveryCoordinator.discoveredResources = discoveredResources
            }
        }
    }
    @Published public var variantStreamItems: [String: HLSVariantStreamItem] = [:] {
        didSet {
            if discoveryCoordinator.variantStreamItems != variantStreamItems {
                discoveryCoordinator.variantStreamItems = variantStreamItems
            }
        }
    }
    @Published public var selectedResourceIDs: Set<String> = [] {
        didSet {
            if discoveryCoordinator.selectedResourceIDs != selectedResourceIDs {
                discoveryCoordinator.selectedResourceIDs = selectedResourceIDs
            }
        }
    }
    @Published public var resourceScanError: String? = nil
    @Published public private(set) var mediaCandidates: [BrowserMediaCandidate] = []
    public func setMediaCandidatesForTesting(_ candidates: [BrowserMediaCandidate]) {
        self.mediaCandidates = candidates
    }
    public let mediaDiscoveryBridge = BrowserMediaDiscoveryBridge()
    public let discoveryCoordinator: BrowserResourceDiscoveryCoordinator

    /// Returns discovered resources for the active tab sorted by the specified or active sort option.
    public func sortedDiscoveredResources(
        by sortOption: ResourceSortOption? = nil,
        selectedCategory: WebpageResourceType? = nil,
        showsAllResources: Bool = false,
        searchText: String = ""
    ) -> [WebpageResource] {
        let option = sortOption ?? resourceSortOption
        return BrowserResourceInspectorSheet.filteredResources(
            in: discoveredResources,
            variantURLs: HLSResourceGrouping.variantURLs(in: discoveredResources),
            selectedCategory: selectedCategory,
            showsAllResources: showsAllResources,
            searchText: searchText,
            sortOption: option,
            variantMetadataMap: variantStreamItems
        )
    }

    /// Returns media candidates for the active tab sorted by the specified or active sort option.
    public func sortedMediaCandidates(
        by sortOption: ResourceSortOption? = nil,
        selectedCategory: WebpageResourceType? = nil,
        showsAllResources: Bool = false,
        searchText: String = ""
    ) -> [BrowserMediaCandidate] {
        let sorted = sortedDiscoveredResources(
            by: sortOption,
            selectedCategory: selectedCategory,
            showsAllResources: showsAllResources,
            searchText: searchText
        )
        if !sorted.isEmpty {
            return sorted.map { $0.toMediaCandidate() }
        }
        let option = sortOption ?? resourceSortOption
        return BrowserMediaCandidate.sorted(mediaCandidates, by: option)
    }

    /// Groups discovered resources by domain according to the specified or active sort/grouping criteria.
    public func groupedDiscoveredResourcesByDomain(
        by sortOption: ResourceSortOption? = nil,
        selectedCategory: WebpageResourceType? = nil,
        showsAllResources: Bool = false,
        searchText: String = ""
    ) -> [(domain: String, resources: [WebpageResource])] {
        let sorted = sortedDiscoveredResources(
            by: sortOption,
            selectedCategory: selectedCategory,
            showsAllResources: showsAllResources,
            searchText: searchText
        )
        return WebpageResource.groupedByDomain(sorted)
    }

    /// Groups discovered resources by category (WebpageResourceType).
    public func groupedDiscoveredResourcesByCategory(
        by sortOption: ResourceSortOption? = nil,
        showsAllResources: Bool = false,
        searchText: String = ""
    ) -> [(category: WebpageResourceType, resources: [WebpageResource])] {
        let sorted = sortedDiscoveredResources(
            by: sortOption,
            selectedCategory: nil,
            showsAllResources: showsAllResources,
            searchText: searchText
        )
        return WebpageResource.groupedByCategory(sorted)
    }

    /// Groups media candidates by domain according to the specified or active sort/grouping criteria.
    public func groupedMediaCandidatesByDomain(
        by sortOption: ResourceSortOption? = nil,
        selectedCategory: WebpageResourceType? = nil,
        showsAllResources: Bool = false,
        searchText: String = ""
    ) -> [(domain: String, candidates: [BrowserMediaCandidate])] {
        let sorted = sortedMediaCandidates(
            by: sortOption,
            selectedCategory: selectedCategory,
            showsAllResources: showsAllResources,
            searchText: searchText
        )
        return BrowserMediaCandidate.groupedByDomain(sorted)
    }

    /// Groups media candidates by category (WebpageResourceType).
    public func groupedMediaCandidatesByCategory(
        by sortOption: ResourceSortOption? = nil,
        showsAllResources: Bool = false,
        searchText: String = ""
    ) -> [(category: WebpageResourceType, candidates: [BrowserMediaCandidate])] {
        let sorted = sortedMediaCandidates(
            by: sortOption,
            selectedCategory: nil,
            showsAllResources: showsAllResources,
            searchText: searchText
        )
        return BrowserMediaCandidate.groupedByCategory(sorted)
    }

    // Tab-scoped media grabber candidate & variant caches (delegated to discoveryCoordinator)
    public var tabResourceStates: [UUID: BrowserTabResourceState] {
        get { discoveryCoordinator.tabResourceStates }
        set { discoveryCoordinator.tabResourceStates = newValue }
    }
    public var tabDiscoveredResources: [UUID: [WebpageResource]] {
        get { discoveryCoordinator.tabDiscoveredResources }
        set {
            discoveryCoordinator.tabDiscoveredResources = newValue
            if let active = activeTabID, let current = newValue[active] {
                discoveredResources = current
                discoveryCoordinator.discoveredResources = current
            }
        }
    }
    public var tabVariantStreamItems: [UUID: [String: HLSVariantStreamItem]] {
        get { discoveryCoordinator.tabVariantStreamItems }
        set {
            discoveryCoordinator.tabVariantStreamItems = newValue
            if let active = activeTabID, let current = newValue[active] {
                variantStreamItems = current
                discoveryCoordinator.variantStreamItems = current
            }
        }
    }
    public var tabSelectedResourceIDs: [UUID: Set<String>] {
        get { discoveryCoordinator.tabSelectedResourceIDs }
        set {
            discoveryCoordinator.tabSelectedResourceIDs = newValue
            if let active = activeTabID, let current = newValue[active] {
                selectedResourceIDs = current
                discoveryCoordinator.selectedResourceIDs = current
            }
        }
    }

    /// Persists the active tab's resource inspector state into its tab-scoped caches.
    public func saveActiveTabResourceState() {
        guard let current = activeTabID else { return }
        discoveryCoordinator.discoveredResources = discoveredResources
        discoveryCoordinator.variantStreamItems = variantStreamItems
        discoveryCoordinator.selectedResourceIDs = selectedResourceIDs
        discoveryCoordinator.saveTabState(
            for: current,
            sortOption: resourceSortOption,
            sortDirection: resourceSortDirection,
            groupingOption: resourceGroupingOption
        )
    }

    /// Restores a given tab's resource inspector state into the published properties.
    public func restoreTabResourceState(for tabID: UUID?) {
        let restored = discoveryCoordinator.restoreTabState(for: tabID)
        discoveredResources = restored.resources
        variantStreamItems = restored.variants
        selectedResourceIDs = restored.selections
        if tabID != nil {
            resourceSortOption = restored.sort
            resourceSortDirection = restored.sortDirection
            resourceGroupingOption = restored.group
        }
    }

    /// Returns the comprehensive tab-scoped resource state for a given tab (or the active tab).
    public func resourceState(for tabID: UUID? = nil) -> BrowserTabResourceState {
        discoveryCoordinator.resourceState(
            for: tabID,
            activeTabID: activeTabID,
            sortOption: resourceSortOption,
            sortDirection: resourceSortDirection,
            groupingOption: resourceGroupingOption
        )
    }

    /// Returns discovered resources for a specific tab without requiring a tab switch.
    public func discoveredResources(for tabID: UUID? = nil) -> [WebpageResource] {
        discoveryCoordinator.discoveredResources(for: tabID, activeTabID: activeTabID)
    }

    /// Returns variant stream items for a specific tab without requiring a tab switch.
    public func variantStreamItems(for tabID: UUID? = nil) -> [String: HLSVariantStreamItem] {
        discoveryCoordinator.variantStreamItems(for: tabID, activeTabID: activeTabID)
    }

    /// Returns selected resource IDs for a specific tab without requiring a tab switch.
    public func selectedResourceIDs(for tabID: UUID? = nil) -> Set<String> {
        discoveryCoordinator.selectedResourceIDs(for: tabID, activeTabID: activeTabID)
    }

    /// Checks if a resource ID is selected in the given tab (or active tab).
    public func isResourceSelected(_ id: String, tabID: UUID? = nil) -> Bool {
        discoveryCoordinator.isResourceSelected(id, tabID: tabID, activeTabID: activeTabID)
    }

    /// Toggles resource selection for the given tab (or active tab).
    public func toggleResourceSelection(_ id: String, tabID: UUID? = nil) {
        discoveryCoordinator.toggleResourceSelection(id, tabID: tabID, activeTabID: activeTabID)
        selectedResourceIDs = discoveryCoordinator.selectedResourceIDs
    }

    /// Selects a resource ID for the given tab (or active tab).
    public func selectResource(_ id: String, tabID: UUID? = nil) {
        discoveryCoordinator.selectResource(id, tabID: tabID, activeTabID: activeTabID)
        selectedResourceIDs = discoveryCoordinator.selectedResourceIDs
    }

    /// Explicitly updates discovered resources for a specific tab (or active tab).
    public func setDiscoveredResources(_ resources: [WebpageResource], for tabID: UUID? = nil) {
        discoveryCoordinator.setDiscoveredResources(resources, for: tabID, activeTabID: activeTabID)
        discoveredResources = discoveryCoordinator.discoveredResources
    }

    /// Explicitly updates variant stream items for a specific tab (or active tab).
    public func setVariantStreamItems(_ items: [HLSVariantStreamItem], for tabID: UUID? = nil) {
        discoveryCoordinator.setVariantStreamItems(items, for: tabID, activeTabID: activeTabID)
        variantStreamItems = discoveryCoordinator.variantStreamItems
    }

    /// Deselects a resource ID for the given tab (or active tab).
    public func deselectResource(_ id: String, tabID: UUID? = nil) {
        discoveryCoordinator.deselectResource(id, tabID: tabID, activeTabID: activeTabID)
        selectedResourceIDs = discoveryCoordinator.selectedResourceIDs
    }

    /// Selects all discovered resources for the given tab (or active tab).
    public func selectAllResources(tabID: UUID? = nil) {
        discoveryCoordinator.selectAllResources(tabID: tabID, activeTabID: activeTabID)
        selectedResourceIDs = discoveryCoordinator.selectedResourceIDs
    }

    /// Deselects all resources for the given tab (or active tab).
    public func deselectAllResources(tabID: UUID? = nil) {
        discoveryCoordinator.deselectAllResources(tabID: tabID, activeTabID: activeTabID)
        selectedResourceIDs = discoveryCoordinator.selectedResourceIDs
    }

    /// Cancels all in-flight media probe and manifest expansion tasks associated with a tab.
    public func cancelInFlightProbes(for tabID: UUID) {
        discoveryCoordinator.cancelInFlightProbes(for: tabID)
    }

        // Streaming proposal/execution state. The orchestrator remains the only
    // owner of transfer execution; the browser owns confirmation presentation.
    @Published public var streamingProposal: StreamingTransferProposal? = nil
    @Published public var isPreparingStreaming: Bool = false
    @Published public var isShowingStreamingConfirmation: Bool = false
    @Published public var isExecutingStreaming: Bool = false
    @Published public var streamingProgress: StreamingTransferProgress? = nil
    @Published public var streamingErrorMessage: String? = nil
    public let streamingOrchestrator: StreamingDownloadOrchestrator?
    public let streamingDestinationDirectoryURL: URL
    private var streamingExecutionTask: Task<Void, Never>?

    public var activeEngineConfiguration: EngineConfiguration {
        if let manager = downloadDelegate as? DownloadManagerViewModel {
            return manager.activeEngineConfiguration
        }
        return AppSettings.load().makeEngineConfiguration()
    }

    // Bounded Blob export state. Blob bytes are written by the per-tab
    // capture service; the view model only presents progress and lifecycle.
    @Published public private(set) var blobCaptureSnapshot: BlobExportSnapshot?
    @Published public var blobCaptureErrorMessage: String?
    @Published public private(set) var isCapturingBlob: Bool = false
    private var activeBlobCaptureID: String?
    private var activeBlobCaptureTabID: UUID?
    private var activeBlobCaptureOriginalURL: URL?
    private var activeBlobCaptureMIMEType: String?
    private var activeBlobCaptureSuggestedFilename: String?
    private var blobCaptureTimeoutTask: Task<Void, Never>?

    // Optional MSE capture state (7H.4). Metadata observation remains the
    // default; bytes are retained only while an explicit capture is active.
    @Published public private(set) var mseCaptureSnapshot: BrowserMSECaptureSnapshot?
    @Published public var mseCaptureErrorMessage: String?
    @Published public private(set) var isCapturingMSE: Bool = false
    private var activeMSECaptureID: String?
    private var activeMSECaptureTabID: UUID?

    // Interactive Stream Quality Picker state (Phase 3 Milestone 3.1)
    @Published public var isShowingQualityPicker: Bool = false
    @Published public var qualityPickerTargetResource: WebpageResource? = nil
    @Published public var qualityPickerTargetCandidate: BrowserMediaCandidate? = nil
    @Published public var qualityPickerOptions: [StreamQualityOption] = []
    @Published public var selectedQualityOption: StreamQualityOption? = nil
    @Published public var isInspectingQualities: Bool = false
    @Published public var qualityInspectionError: String? = nil
    @Published public var qualityPickerFilename: String = ""

    // Native Content Blocking & Shields (Phase 3 Milestone 3.2 & Workstream B Milestone B.2)
    @Published public var isAdBlockerEnabled: Bool = true
    @Published public var isTrackerBlockerEnabled: Bool = true
    @Published public var isAnnoyanceBlockerEnabled: Bool = true
    @Published public var cookiePolicy: BrowserCookiePolicy = .blockThirdParty
    @Published public var isPopupBlockerEnabled: Bool = true
    @Published public var adBlockerWhitelistedDomains: Set<String> = []
    @Published public var isShowingShieldSheet: Bool = false
    @Published public var isShowingClearDataSheet: Bool = false

    // Security & Permissions Prompts (Milestone B.2)
    @Published public var certificateWarningPrompt: BrowserCertificatePrompt? = nil
    @Published public var suspiciousDownloadPrompt: BrowserSuspiciousDownloadPrompt? = nil
    @Published public var permissionPrompt: BrowserPermissionPrompt? = nil

    // Safari-Style Reader Mode (Milestone B.3)
    @Published public var isShowingReaderMode: Bool = false
    @Published public var readerArticle: BrowserReaderArticle? = nil
    @Published public var isExtractingReaderArticle: Bool = false
    @Published public var readerSettings: BrowserReaderSettings = BrowserReaderSettings()
    @Published public var readerFeedbackBanner: String? = nil

    // Find in Page (Milestone B.3)
    @Published public var isShowingFindInPage: Bool = false
    @Published public var findInPageQuery: String = ""
    @Published public var findInPageResult: BrowserFindInPageResult = BrowserFindInPageResult()

    // Webpage & Link Sharing (Milestone B.3)
    @Published public var isShowingShareSheet: Bool = false
    @Published public var shareItems: [Any] = []

    // Custom Homepage & Session Persistence (Milestone B.3)
    public var browserHomepage: String = "https://duckduckgo.com"
    public var restoreTabsOnLaunch: Bool = true
    public let sessionStore: BrowserSessionStore?

    // User-controlled redirect & popup confirmation
    @Published public var redirectPrompt: BrowserRedirectPrompt? = nil
    private var tabOriginChains: [UUID: Set<String>] = [:]

    public var activeTabOriginChain: Set<String> {
        guard let tabID = activeTabID else { return [] }
        return tabOriginChains[tabID] ?? []
    }

    public weak var downloadDelegate: BrowserDownloadDelegate?
    public weak var magnetDelegate: (any BrowserMagnetDelegate)?
    public var onDownloadInitiated: (() -> Void)? = nil
    public var onOpenAddDownload: ((URL) -> Void)? = nil
    public var onOpenDownloads: (() -> Void)? = nil
    @Published public var preferredStreamingTransportPolicy: HTTPTransportPolicy? = .background

    var tabManager = BrowserTabManager()
    public var mediaCandidateCatalogs: [UUID: BrowserMediaCandidateCatalog] {
        get { discoveryCoordinator.mediaCandidateCatalogs }
        set { discoveryCoordinator.mediaCandidateCatalogs = newValue }
    }

    #if canImport(WebKit)
    public weak var webView: WKWebView?
    private var pendingNavigationURLs: [UUID: URL] = [:]
    private var tabSessions: [UUID: BrowserWebViewSession] = [:]

    // Navigation generation tracking to prevent stale callbacks from race conditions
    private var tabNavigationGenerations: [UUID: UInt64] = [:]
    private var tabNavigationTargets: [UUID: URL] = [:]

    // Memory pressure management & LRU tab eviction
    private var tabLastAccessed: [UUID: Date] = [:]
    public var maxInactiveWebViews: Int = 3

    @discardableResult
    public func nextNavigationGeneration(for tabID: UUID, target: URL? = nil) -> UInt64 {
        let next = tabNavigationGenerations[tabID, default: 0] &+ 1
        tabNavigationGenerations[tabID] = next
        tabNavigationTargets[tabID] = target
        return next
    }

    public func currentNavigationGeneration(for tabID: UUID) -> UInt64 {
        tabNavigationGenerations[tabID, default: 0]
    }

    public func isNavigationCurrent(tabID: UUID, generation: UInt64, url: URL?) -> Bool {
        guard let current = tabNavigationGenerations[tabID] else {
            // First navigation or unregistered
            return true
        }
        return current == generation
    }

    public func recordTabAccess(_ tabID: UUID) {
        tabLastAccessed[tabID] = Date()
    }

    public func handleMemoryWarning() {
        PipelineLogger.shared.log(stage: .browser, message: "[BrowserViewModel] Memory warning received. Evicting inactive WebViews.")
        evictInactiveWebViews(maxKeepInactive: 0)
    }

    public func evictInactiveWebViews(keepingActive activeID: UUID? = nil, maxKeepInactive: Int = 2) {
        let keepID = activeID ?? self.activeTabID
        let candidateIDs = tabSessions.keys.filter { $0 != keepID }
        guard candidateIDs.count > maxKeepInactive else { return }

        let sortedCandidates = candidateIDs.sorted { id1, id2 in
            let d1 = tabLastAccessed[id1] ?? .distantPast
            let d2 = tabLastAccessed[id2] ?? .distantPast
            return d1 < d2
        }

        let evictCount = candidateIDs.count - maxKeepInactive
        let toEvict = sortedCandidates.prefix(evictCount)

        for tabID in toEvict {
            if let session = tabSessions.removeValue(forKey: tabID) {
                session.tearDown()
                PipelineLogger.shared.log(stage: .browser, message: "[BrowserViewModel] Evicted inactive WebView session for tab \(tabID).")
            }
        }
    }

    public func ensureRestoredTabLoaded(for tabID: UUID) {
        guard let tab = tabManager.tab(withID: tabID),
              let url = tab.url,
              url.absoluteString != "about:blank" else { return }
        let session = webViewSession(for: tabID)
        if session.webView.url == nil {
            session.webView.load(URLRequest(url: url))
        }
    }

    /// Attaches the WebKit instance created by SwiftUI and delivers the
    /// navigation requested while the home view was being replaced.
    func attachWebView(_ webView: WKWebView, for tabID: UUID? = nil) {
        let targetTabID = tabID ?? activeTabID
        guard let targetTabID else { return }
        if targetTabID == activeTabID {
            self.webView = webView
        }
        recordTabAccess(targetTabID)
        let consumed = consumePendingNavigation(for: targetTabID) { request in
            webView.load(request)
        }
        if !consumed, webView.url == nil, let tab = tabManager.tab(withID: targetTabID), let url = tab.url, url.absoluteString != "about:blank" {
            webView.load(URLRequest(url: url))
        }
    }

    /// Delivers a pending request at most once. The injectable loader keeps
    /// the lifecycle behavior deterministic in unit tests without requiring
    /// a live WebKit navigation.
    @discardableResult
    func consumePendingNavigation(using load: (URLRequest) -> Void) -> Bool {
        guard let activeTabID else { return false }
        return consumePendingNavigation(for: activeTabID, using: load)
    }

    @discardableResult
    private func consumePendingNavigation(
        for tabID: UUID,
        using load: (URLRequest) -> Void
    ) -> Bool {
        guard let url = pendingNavigationURLs.removeValue(forKey: tabID) else { return false }
        load(URLRequest(url: url))
        return true
    }
    #endif

    public init(
        downloadDelegate: BrowserDownloadDelegate? = nil,
        magnetDelegate: (any BrowserMagnetDelegate)? = nil,
        onDownloadInitiated: (() -> Void)? = nil,
        onOpenAddDownload: ((URL) -> Void)? = nil,
        onOpenDownloads: (() -> Void)? = nil,
        streamingOrchestrator: StreamingDownloadOrchestrator? = nil,
        streamingDestinationDirectoryURL: URL? = nil,
        sessionStore: BrowserSessionStore? = nil,
        bookmarkStore: BrowserBookmarkStore = .shared,
        historyStore: BrowserHistoryStore = .shared,
        sitePermissionsStore: BrowserSitePermissionsStore = .shared,
        quickAccessStore: QuickAccessStore = .shared,
        faviconService: FaviconService = .shared,
        tabPreviewCache: BrowserTabPreviewCache = .shared,
        certificateDecisionStore: BrowserCertificateDecisionStore = .shared,
        contentBlocker: BrowserContentBlocker = .shared,
        permissionCoordinator: BrowserPermissionCoordinator = .shared,
        promptHandler: BrowserPromptHandler = .shared,
        authenticationHandler: BrowserAuthenticationHandler = .shared,
        diagnosticLogger: BrowserDiagnosticLogger = .shared,
        streamManifestExpander: StreamManifestResourceExpander = .shared
    ) {
        self.downloadDelegate = downloadDelegate
        self.magnetDelegate = magnetDelegate
        self.onDownloadInitiated = onDownloadInitiated
        self.onOpenAddDownload = onOpenAddDownload
        self.onOpenDownloads = onOpenDownloads
        self.sessionStore = sessionStore
        self.bookmarkStore = bookmarkStore
        self.historyStore = historyStore
        self.sitePermissionsStore = sitePermissionsStore
        self.quickAccessStore = quickAccessStore
        self.faviconService = faviconService
        self.tabPreviewCache = tabPreviewCache
        self.certificateDecisionStore = certificateDecisionStore
        self.contentBlocker = contentBlocker
        self.permissionCoordinator = permissionCoordinator
        self.promptHandler = promptHandler
        self.authenticationHandler = authenticationHandler
        self.diagnosticLogger = diagnosticLogger
        self.streamManifestExpander = streamManifestExpander
        self.discoveryCoordinator = BrowserResourceDiscoveryCoordinator(
            bridge: mediaDiscoveryBridge,
            streamManifestExpander: streamManifestExpander
        )

        let orchestrator = streamingOrchestrator ?? (downloadDelegate as? DownloadManagerViewModel)?.streamingOrchestrator
        if let orchestrator, let vm = downloadDelegate as? DownloadManagerViewModel {
            Task {
                await vm.engine.setStreamingOrchestrator(orchestrator)
                await orchestrator.setDownloadEngine(vm.engine)
            }
        }
        self.streamingOrchestrator = orchestrator
        self.streamingDestinationDirectoryURL = streamingDestinationDirectoryURL ??
            (downloadDelegate as? DownloadManagerViewModel)?.downloadsDirectoryURL ??
            DownloadManagerViewModel.defaultDownloadsDirectory()

        let initialSettings = (downloadDelegate as? DownloadManagerViewModel)?.appSettings ?? AppSettings.load()
        self.isAdBlockerEnabled = initialSettings.isAdBlockerEnabled
        self.isTrackerBlockerEnabled = initialSettings.isTrackerBlockerEnabled
        self.isAnnoyanceBlockerEnabled = initialSettings.isAnnoyanceBlockerEnabled
        self.cookiePolicy = initialSettings.cookiePolicy
        self.isPopupBlockerEnabled = initialSettings.isPopupBlockerEnabled
        self.adBlockerWhitelistedDomains = Set(initialSettings.adBlockerWhitelistedDomains)
        self.selectedSearchEngine = initialSettings.browserSearchEngine
        self.activeSearchEngineID = initialSettings.activeSearchEngineID
        self.customSearchEngines = initialSettings.customSearchEngines
        self.browserHomepage = initialSettings.browserHomepage
        self.restoreTabsOnLaunch = initialSettings.restoreTabsOnLaunch
        self.quickAccessShortcuts = quickAccessStore.load()
        self.readerSettings = BrowserReaderSettings(
            theme: initialSettings.readerTheme,
            fontFamily: initialSettings.readerFontFamily,
            fontSize: initialSettings.readerFontSize
        )

        if initialSettings.restoreTabsOnLaunch,
           let sessionStore,
           let saved = sessionStore.loadSession(),
           !saved.tabs.isEmpty {
            self.tabManager = BrowserTabManager(tabs: saved.tabs, groups: saved.groups, activeTabID: saved.activeTabID)
        }

        super.init()
        permissionCoordinator.provider = self
        discoveryCoordinator.onStateChanged = { [weak self] in
            guard let self = self else { return }
            self.discoveredResources = self.discoveryCoordinator.discoveredResources
            self.variantStreamItems = self.discoveryCoordinator.variantStreamItems
            self.selectedResourceIDs = self.discoveryCoordinator.selectedResourceIDs
            self.mediaCandidates = self.discoveryCoordinator.mediaCandidates
            self.isScanningResources = self.discoveryCoordinator.isScanningResources
            self.resourceScanError = self.discoveryCoordinator.resourceScanError
        }

        #if canImport(WebKit)
        Task {
            await contentBlocker.prepareRuleLists(
                whitelistedDomains: initialSettings.adBlockerWhitelistedDomains
            )
        }
        #endif

        if let orchestrator {
            Task { await orchestrator.setURLResolver(self) }
        }
        publishTabState()
        mediaDiscoveryBridge.observationHandler = { [weak self] observation in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.discoveryCoordinator.handleMediaDiscoveryObservation(
                    observation,
                    tabID: self.activeTabID,
                    activeTabID: self.activeTabID,
                    currentURL: self.currentURL,
                    streamingOrchestrator: self.streamingOrchestrator
                )
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("LIDNavigateBrowserToURL"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            if let url = notif.userInfo?["url"] as? URL {
                self?.load(url: url)
            }
        }

        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
        #endif

        #if canImport(WebKit)
        if let activeID = activeTabID {
            recordTabAccess(activeID)
            ensureRestoredTabLoaded(for: activeID)
        }
        #endif
    }

    private func publishTabState() {
        tabs = tabManager.tabs
        groups = tabManager.groups
        activeTabID = tabManager.activeTabID
        if restoreTabsOnLaunch, let sessionStore {
            sessionStore.saveSession(tabs: tabManager.tabs, groups: tabManager.groups, activeTabID: tabManager.activeTabID)
        }
    }

    private func syncActiveTabState() {
        guard let activeTab = tabManager.activeTab else {
            currentURL = nil
            urlInputText = ""
            pageTitle = ""
            isLoading = false
            estimatedProgress = 0
            canGoBack = false
            canGoForward = false
            #if canImport(WebKit)
            webView = nil
            #endif
            return
        }

        currentURL = activeTab.url
        urlInputText = activeTab.url?.absoluteString ?? ""
        pageTitle = activeTab.displayName == "New Tab" ? "" : activeTab.displayName
        isLoading = activeTab.isLoading
        estimatedProgress = activeTab.estimatedProgress
        canGoBack = activeTab.canGoBack
        canGoForward = activeTab.canGoForward

        #if canImport(WebKit)
        if activeTab.url == nil {
            webView = nil
        } else if let activeTabID,
           let session = tabSessions[activeTabID] {
            webView = session.webView
            canGoBack = session.webView.canGoBack
            canGoForward = session.webView.canGoForward
        } else {
            webView = nil
        }
        #endif
    }

    public static let defaultDesktopUserAgent = BrowserTabState.defaultDesktopUserAgent
    public static let defaultMobileUserAgent = BrowserTabState.defaultMobileUserAgent

    public var activeTab: BrowserTabState? {
        tabManager.activeTab
    }

    public var isCurrentTabDesktopMode: Bool {
        tabManager.activeTab?.isDesktopMode ?? false
    }

    public var isCurrentTabIncognito: Bool {
        tabManager.activeTab?.isIncognito ?? false
    }

    @discardableResult
    public func createNewTab(
        with url: URL? = nil,
        isIncognito: Bool = false,
        isDesktopMode: Bool = false
    ) -> UUID {
        saveActiveTabResourceState()
        let id = tabManager.createTab(
            select: true,
            isIncognito: isIncognito,
            isDesktopMode: isDesktopMode
        )
        publishTabState()
        syncActiveTabState()

        discoveredResources = []
        variantStreamItems = [:]
        selectedResourceIDs = []
        tabDiscoveredResources[id] = []
        tabVariantStreamItems[id] = [:]
        tabSelectedResourceIDs[id] = []
        tabResourceStates[id] = BrowserTabResourceState()
        publishMediaCandidates()
        setToolbarCollapsed(false)

        publishMediaCandidates()
        setToolbarCollapsed(false)
        isShowingTabSwitcher = false
        recordTabAccess(id)
        #if canImport(WebKit)
        evictInactiveWebViews(keepingActive: id, maxKeepInactive: maxInactiveWebViews)
        #endif
        if let url = url {
            #if canImport(WebKit)
            let session = webViewSession(for: id)
            session.webView.load(URLRequest(url: url))
            if let host = url.host {
                recordTabOrigin(host, for: id)
            }
            #endif
        }
        return id
    }

    /// Toggles desktop/mobile user agent and viewport presentation for the specified tab (or active tab).
    public func toggleDesktopMode(for tabID: UUID? = nil) {
        let targetID = tabID ?? activeTabID
        guard let id = targetID, var tab = tabManager.tab(withID: id) else { return }
        tab.isDesktopMode.toggle()
        _ = tabManager.updateTab(tab)
        publishTabState()
        syncActiveTabState()

        #if canImport(WebKit)
        if let session = tabSessions[id] {
            session.webView.customUserAgent = tab.isDesktopMode
                ? Self.defaultDesktopUserAgent
                : Self.defaultMobileUserAgent
            #if os(iOS)
            if #available(iOS 13.0, *) {
                session.webView.configuration.defaultWebpagePreferences.preferredContentMode = tab.isDesktopMode ? .desktop : .mobile
            }
            #endif
            session.webView.reload()
        }
        #endif
    }

    public func showBookmarksAndHistory() {
        isShowingBookmarksAndHistory = true
    }

    public func setSearchEngine(id: String) {
        self.activeSearchEngineID = id
        if let builtIn = BrowserSearchEngine(rawValue: id) {
            self.selectedSearchEngine = builtIn
        }
        var settings = AppSettings.load()
        settings.activeSearchEngineID = id
        if let builtIn = BrowserSearchEngine(rawValue: id) {
            settings.browserSearchEngine = builtIn
        }
        settings.save()
    }

    public func setSearchEngine(_ engine: BrowserSearchEngine) {
        setSearchEngine(id: engine.rawValue)
    }

    public var currentSearchEngineName: String {
        if let custom = customSearchEngines.first(where: { $0.id == activeSearchEngineID }) {
            return custom.name
        }
        if let builtIn = BrowserSearchEngine(rawValue: activeSearchEngineID) {
            return builtIn.displayName
        }
        return selectedSearchEngine.displayName
    }

    public var currentSearchEngineTemplate: String {
        if let custom = customSearchEngines.first(where: { $0.id == activeSearchEngineID }) {
            return custom.urlTemplate
        }
        if let builtIn = BrowserSearchEngine(rawValue: activeSearchEngineID) {
            return builtIn.urlTemplate
        }
        return selectedSearchEngine.urlTemplate
    }

    // MARK: - Quick Access Management

    public func addQuickAccessShortcut(name: String, url: URL, faviconURL: URL? = nil) {
        quickAccessStore.add(name: name, url: url, faviconURL: faviconURL)
        self.quickAccessShortcuts = quickAccessStore.load()
    }

    public func updateQuickAccessShortcut(_ shortcut: QuickAccessShortcut) {
        quickAccessStore.update(shortcut)
        self.quickAccessShortcuts = quickAccessStore.load()
    }

    public func deleteQuickAccessShortcut(id: String) {
        quickAccessStore.delete(id: id)
        self.quickAccessShortcuts = quickAccessStore.load()
    }

    public func moveQuickAccessShortcut(id: String, direction: QuickAccessMoveDirection) {
        quickAccessStore.move(id: id, direction: direction)
        self.quickAccessShortcuts = quickAccessStore.load()
    }

    public func moveQuickAccessShortcuts(fromOffsets source: IndexSet, toOffset destination: Int) {
        quickAccessStore.move(fromOffsets: source, toOffset: destination)
        self.quickAccessShortcuts = quickAccessStore.load()
    }

    public func reloadQuickAccessShortcuts() {
        self.quickAccessShortcuts = quickAccessStore.load()
    }

    public func openDownloads() {
        if let onOpenDownloads {
            onOpenDownloads()
        } else {
            isShowingDownloadSheet = true
        }
    }

    public var activeDownloadCount: Int {
        guard let vm = downloadDelegate as? DownloadManagerViewModel else { return 0 }
        return vm.unifiedTransfers.filter { $0.state == .downloading }.count
    }

    public var activeDownloadProgress: Double {
        guard let vm = downloadDelegate as? DownloadManagerViewModel else { return 0.0 }
        let active = vm.unifiedTransfers.filter { $0.state == .downloading }
        guard !active.isEmpty else { return 0.0 }
        let sum = active.reduce(into: 0.0) { $0 += $1.progressFraction }
        return sum / Double(active.count)
    }

    public func closeAllIncognitoTabs() {
        let incognitoIDs = tabs.filter(\.isIncognito).map(\.id)
        for id in incognitoIDs {
            _ = closeTab(id)
        }
    }

    @discardableResult
    public func selectTab(_ id: UUID) -> Bool {
        saveActiveTabResourceState()
        guard tabManager.selectTab(id) else { return false }
        recordTabAccess(id)
        publishTabState()
        syncActiveTabState()

        // Restore tab-scoped discovered resources, variant items, and selections
        restoreTabResourceState(for: id)

        publishMediaCandidates()
        setToolbarCollapsed(false)
        isShowingTabSwitcher = false
        errorMessage = nil
        #if canImport(WebKit)
        ensureRestoredTabLoaded(for: id)
        #endif
        return true
    }

    @discardableResult
    public func closeTab(_ id: UUID) -> UUID? {
        let isIncognito = tabManager.tab(withID: id)?.isIncognito ?? false
        tabPreviewCache.removePreview(for: id)
        cancelInFlightProbes(for: id)
        tabDiscoveredResources.removeValue(forKey: id)
        tabVariantStreamItems.removeValue(forKey: id)
        tabSelectedResourceIDs.removeValue(forKey: id)
        tabResourceStates.removeValue(forKey: id)
        #if canImport(WebKit)
        cancelBlobCapture(for: id)
        cancelMSECapture(for: id)
        pendingNavigationURLs.removeValue(forKey: id)
        tabNavigationGenerations.removeValue(forKey: id)
        tabNavigationTargets.removeValue(forKey: id)
        tabLastAccessed.removeValue(forKey: id)
        if let session = tabSessions.removeValue(forKey: id) {
            session.tearDown()
            if isIncognito {
                let store = session.webView.configuration.websiteDataStore
                let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
                store.fetchDataRecords(ofTypes: dataTypes) { records in
                    store.removeData(ofTypes: dataTypes, for: records) { }
                }
            }
        }
        #endif
        tabOriginChains.removeValue(forKey: id)
        mediaCandidateCatalogs.removeValue(forKey: id)
        let replacement = tabManager.closeTab(id)
        publishTabState()
        syncActiveTabState()

        // Restore tab-scoped discovered resources, variant items, and selections for the replacement tab
        restoreTabResourceState(for: replacement)

        publishMediaCandidates()
        if replacement == nil {
            isShowingTabSwitcher = false
        }
        return replacement
    }

    // MARK: - Tab Renaming & Grouping

    @discardableResult
    public func renameTab(_ id: UUID, newTitle: String?) -> Bool {
        let changed = tabManager.renameTab(id, newTitle: newTitle)
        if changed {
            publishTabState()
            syncActiveTabState()
        }
        return changed
    }

    @discardableResult
    public func createGroup(
        title: String,
        colorName: String = "blue",
        tabIDs: [UUID] = []
    ) -> BrowserTabGroup {
        let group = tabManager.createGroup(title: title, colorName: colorName, tabIDs: tabIDs)
        publishTabState()
        return group
    }

    @discardableResult
    public func renameGroup(_ id: UUID, newTitle: String) -> Bool {
        let changed = tabManager.renameGroup(id, newTitle: newTitle)
        if changed {
            publishTabState()
        }
        return changed
    }

    public func deleteGroup(_ id: UUID, closeContainedTabs: Bool = false) {
        tabManager.deleteGroup(id, closeContainedTabs: closeContainedTabs)
        publishTabState()
        syncActiveTabState()
    }

    @discardableResult
    public func addTabToGroup(tabID: UUID, groupID: UUID) -> Bool {
        let changed = tabManager.addTabToGroup(tabID: tabID, groupID: groupID)
        if changed {
            publishTabState()
        }
        return changed
    }

    @discardableResult
    public func removeTabFromGroup(tabID: UUID) -> Bool {
        let changed = tabManager.removeTabFromGroup(tabID: tabID)
        if changed {
            publishTabState()
        }
        return changed
    }

    @discardableResult
    public func groupTabs(sourceTabID: UUID, targetTabID: UUID) -> UUID? {
        let groupID = tabManager.groupTabs(sourceTabID: sourceTabID, targetTabID: targetTabID)
        if groupID != nil {
            publishTabState()
        }
        return groupID
    }

    public func toggleGroupCollapse(_ groupID: UUID) {
        tabManager.toggleGroupCollapse(groupID)
        publishTabState()
    }

    public func tabsInGroup(_ groupID: UUID) -> [BrowserTabState] {
        tabManager.tabsInGroup(groupID)
    }

    public func ungroupedTabs() -> [BrowserTabState] {
        tabManager.ungroupedTabs()
    }

    // MARK: - Redirect & Popup Confirmation Handling

    public func promptRedirectConfirmation(
        destinationURL: URL,
        originURL: URL?,
        sourceTabID: UUID?,
        reason: BrowserRedirectReason,
        isSuspicious: Bool
    ) {
        self.redirectPrompt = BrowserRedirectPrompt(
            destinationURL: destinationURL,
            originURL: originURL,
            sourceTabID: sourceTabID,
            reason: reason,
            isSuspicious: isSuspicious
        )
    }

    public func confirmRedirectInNewTab(_ prompt: BrowserRedirectPrompt) {
        self.redirectPrompt = nil
        let scheme = prompt.destinationURL.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" && scheme != "about" && scheme != "blob" && scheme != "data" {
            openExternalScheme(prompt.destinationURL)
        } else {
            createNewTab(with: prompt.destinationURL)
        }
    }

    public func confirmRedirectInCurrentTab(_ prompt: BrowserRedirectPrompt) {
        self.redirectPrompt = nil
        let scheme = prompt.destinationURL.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" && scheme != "about" && scheme != "blob" && scheme != "data" {
            openExternalScheme(prompt.destinationURL)
        } else {
            #if canImport(WebKit)
            let targetID = prompt.sourceTabID ?? activeTabID
            if let tabID = targetID, let webView = webView(for: tabID) {
                if let host = prompt.destinationURL.host {
                    recordTabOrigin(host, for: tabID)
                }
                webView.load(URLRequest(url: prompt.destinationURL))
            }
            #endif
        }
    }

    public func cancelRedirectPrompt() {
        self.redirectPrompt = nil
    }

    public func recordTabOrigin(_ host: String, for tabID: UUID?) {
        guard let resolvedID = tabID ?? activeTabID else { return }
        let normalized = BrowserDomainMatcher.normalizeDomain(host)
        guard !normalized.isEmpty else { return }
        if tabOriginChains[resolvedID] == nil {
            tabOriginChains[resolvedID] = []
        }
        tabOriginChains[resolvedID]?.insert(normalized)
    }

    private func openExternalScheme(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    public func showTabSwitcher() {
        guard !tabs.isEmpty else { return }
        isShowingTabSwitcher = true
    }

    public func handleEdgeGesture(
        startX: Double,
        translationX: Double,
        containerWidth: Double,
        modalPresented: Bool
    ) {
        let policy = BrowserEdgeGesturePolicy()
        guard let action = policy.action(
            startX: startX,
            translationX: translationX,
            containerWidth: containerWidth,
            canGoBack: canGoBack,
            modalPresented: modalPresented
        ) else { return }

        switch action {
        case .goBack:
            goBack()
        case .showTabSwitcher:
            showTabSwitcher()
        }
    }

    private var allowedInBrowserURLs = Set<String>()

    public func isURLAllowedInBrowser(_ url: URL) -> Bool {
        if allowedInBrowserURLs.contains(url.absoluteString) {
            return true
        }
        if let host = url.host?.lowercased() {
            let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if allowedInBrowserURLs.contains(cleanHost) || allowedInBrowserURLs.contains(host) {
                return true
            }
        }
        return false
    }

    public func allowURLInBrowser(_ url: URL) {
        allowedInBrowserURLs.insert(url.absoluteString)
        if let host = url.host?.lowercased() {
            allowedInBrowserURLs.insert(host)
            let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            allowedInBrowserURLs.insert(cleanHost)
        }
    }

    #if canImport(WebKit)
    nonisolated fileprivate static func externalAppPrompt(
        for url: URL,
        navigationAction: WKNavigationAction,
        currentURL: URL?,
        isExplicitlyAllowed: Bool
    ) -> BrowserExternalAppLink? {
        if isExplicitlyAllowed {
            return nil
        }

        guard let (serviceName, webURL) = externalAppService(for: url) else {
            return nil
        }

        // Check if user is ALREADY navigating inside this same web service in the current tab
        // (e.g. they are already browsing on m.youtube.com and clicking another video on youtube.com)
        if let currentURL = currentURL,
           let (currentService, _) = externalAppService(for: currentURL),
           currentService == serviceName {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                // Keep browsing seamlessly inside the web service without prompt interruption
                return nil
            }
        }

        return BrowserExternalAppLink(url: url, webURL: webURL, serviceName: serviceName)
    }
    #endif

    public func continueInBrowser(_ link: BrowserExternalAppLink) {
        externalAppLinkPrompt = nil
        let targetURL = link.webURL ?? link.url
        allowURLInBrowser(targetURL)
        allowURLInBrowser(link.url)
        #if canImport(WebKit)
        guard let tabID = activeTabID, let webView = webView(for: tabID) else { return }
        webView.load(URLRequest(url: targetURL))
        #endif
    }

    public func openInAssociatedApp(_ link: BrowserExternalAppLink) {
        externalAppLinkPrompt = nil
        #if canImport(UIKit)
        UIApplication.shared.open(
            link.url,
            options: [:]
        ) { [weak self] opened in
            guard !opened else { return }
            self?.continueInBrowser(link)
        }
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(link.url)
        #else
        continueInBrowser(link)
        #endif
    }

    nonisolated public static func externalAppService(for url: URL) -> (serviceName: String, webURL: URL)? {
        let scheme = url.scheme?.lowercased() ?? ""

        // 1. Custom app schemes (e.g. youtube://, vnd.youtube:, twitter://, etc.)
        if scheme == "youtube" || scheme == "vnd.youtube" {
            let webURL = convertCustomSchemeToWebURL(url, service: "YouTube") ?? URL(string: "https://www.youtube.com")!
            return ("YouTube", webURL)
        }
        if scheme == "twitter" || scheme == "x" {
            let webURL = convertCustomSchemeToWebURL(url, service: "X") ?? URL(string: "https://x.com")!
            return ("X", webURL)
        }
        if scheme == "instagram" {
            let webURL = convertCustomSchemeToWebURL(url, service: "Instagram") ?? URL(string: "https://www.instagram.com")!
            return ("Instagram", webURL)
        }
        if scheme == "reddit" {
            let webURL = convertCustomSchemeToWebURL(url, service: "Reddit") ?? URL(string: "https://www.reddit.com")!
            return ("Reddit", webURL)
        }
        if scheme == "spotify" {
            let webURL = convertCustomSchemeToWebURL(url, service: "Spotify") ?? URL(string: "https://open.spotify.com")!
            return ("Spotify", webURL)
        }
        if scheme == "whatsapp" {
            let webURL = convertCustomSchemeToWebURL(url, service: "WhatsApp") ?? URL(string: "https://web.whatsapp.com")!
            return ("WhatsApp", webURL)
        }
        if scheme == "tg" {
            let webURL = convertCustomSchemeToWebURL(url, service: "Telegram") ?? URL(string: "https://t.me")!
            return ("Telegram", webURL)
        }
        if scheme == "discord" {
            let webURL = convertCustomSchemeToWebURL(url, service: "Discord") ?? URL(string: "https://discord.com")!
            return ("Discord", webURL)
        }
        if scheme == "itms-apps" || scheme == "itms-appss" || scheme == "itms" {
            return ("App Store", url)
        }

        // 2. HTTP/HTTPS Universal Links
        guard scheme == "http" || scheme == "https", let rawHost = url.host?.lowercased() else {
            return nil
        }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost

        // YouTube
        if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" {
            var webURL = url
            if host == "youtu.be" {
                let videoID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !videoID.isEmpty {
                    webURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)") ?? url
                }
            }
            return ("YouTube", webURL)
        }
        // Twitter / X
        if host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com") || host == "t.co" {
            return ("X", url)
        }
        // Instagram
        if host == "instagram.com" || host.hasSuffix(".instagram.com") {
            return ("Instagram", url)
        }
        // Reddit
        if host == "reddit.com" || host.hasSuffix(".reddit.com") || host == "redd.it" {
            return ("Reddit", url)
        }
        // TikTok
        if host == "tiktok.com" || host.hasSuffix(".tiktok.com") {
            return ("TikTok", url)
        }
        // Spotify
        if host == "spotify.com" || host.hasSuffix(".spotify.com") {
            return ("Spotify", url)
        }
        // Telegram
        if host == "t.me" || host == "telegram.me" {
            return ("Telegram", url)
        }
        // WhatsApp
        if host == "wa.me" || host == "api.whatsapp.com" || host == "chat.whatsapp.com" {
            return ("WhatsApp", url)
        }
        // Discord
        if host == "discord.com" || host.hasSuffix(".discord.com") || host == "discord.gg" {
            return ("Discord", url)
        }
        // Netflix
        if host == "netflix.com" || host.hasSuffix(".netflix.com") {
            return ("Netflix", url)
        }
        // Facebook
        if host == "facebook.com" || host.hasSuffix(".facebook.com") || host == "fb.watch" {
            return ("Facebook", url)
        }
        // App Store
        if host == "apps.apple.com" || host == "itunes.apple.com" {
            return ("App Store", url)
        }

        return nil
    }

    nonisolated private static func convertCustomSchemeToWebURL(_ url: URL, service: String) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""
        let absolute = url.absoluteString

        if scheme == "youtube" || scheme == "vnd.youtube" {
            if absolute.contains("watch?") {
                if let query = url.query {
                    return URL(string: "https://www.youtube.com/watch?\(query)")
                }
            }
            let raw = absolute.replacingOccurrences(of: "vnd.youtube://", with: "")
                              .replacingOccurrences(of: "vnd.youtube:", with: "")
                              .replacingOccurrences(of: "youtube://", with: "")
            let videoID = raw.components(separatedBy: "?").first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            if !videoID.isEmpty && !videoID.contains(".") {
                return URL(string: "https://www.youtube.com/watch?v=\(videoID)")
            }
            return URL(string: "https://www.youtube.com")
        }

        if scheme == "twitter" || scheme == "x" {
            if let host = url.host {
                return URL(string: "https://x.com/\(host)\(url.path)")
            }
            return URL(string: "https://x.com")
        }

        if scheme == "instagram" {
            if let host = url.host {
                return URL(string: "https://www.instagram.com/\(host)\(url.path)")
            }
            return URL(string: "https://www.instagram.com")
        }

        if scheme == "reddit" {
            return URL(string: "https://www.reddit.com\(url.path)")
        }

        return URL(string: "https://\(url.host ?? "")\(url.path)")
    }

    nonisolated private static func externalAppService(for host: String) -> String? {
        if let dummyURL = URL(string: "https://\(host)") {
            return externalAppService(for: dummyURL)?.serviceName
        }
        return nil
    }

    nonisolated private static func normalizedHost(_ host: String?) -> String {
        guard let host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    #if canImport(WebKit)
    func webViewSession(for tabID: UUID) -> BrowserWebViewSession {
        recordTabAccess(tabID)
        if let existing = tabSessions[tabID] { return existing }
        let session = BrowserWebViewSession(tabID: tabID, viewModel: self)
        tabSessions[tabID] = session
        return session
    }

    func updateWebViewState(
        for tabID: UUID,
        webView: WKWebView,
        url: URL?,
        title: String?,
        isLoading: Bool,
        generation: UInt64? = nil
    ) {
        if let generation {
            guard isNavigationCurrent(tabID: tabID, generation: generation, url: url) else {
                BrowserDiagnosticLogger.shared.log(
                    category: .navigation,
                    message: "updateWebViewState dropped stale callback for tab \(tabID) (gen: \(generation))",
                    url: url,
                    tabID: tabID
                )
                return
            }
        }
        guard var tab = tabManager.tab(withID: tabID) else { return }
        let previousURL = tab.url
        if let url, url.absoluteString != "about:blank" {
            if let prev = previousURL,
               prev.absoluteString != "about:blank",
               (prev.host?.lowercased() != url.host?.lowercased() ||
                prev.path != url.path ||
                prev.query != url.query) {
                resetMediaDiscovery(for: tabID)
            }
            tab.url = url
        }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tab.title = title
        } else if !isLoading {
            tab.title = tab.url?.host ?? "New Tab"
        }
        tab.isLoading = isLoading
        tab.canGoBack = webView.canGoBack
        tab.canGoForward = webView.canGoForward
        tab.estimatedProgress = webView.estimatedProgress
        _ = tabManager.updateTab(tab)
        publishTabState()
        if !isLoading, let effectiveURL = tab.url, effectiveURL.absoluteString != "about:blank" {
            self.historyStore.recordVisit(url: effectiveURL, title: tab.title, isIncognito: tab.isIncognito)
            #if canImport(UIKit)
            let tabIncognito = tab.isIncognito
            webView.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let image, let data = image.jpegData(compressionQuality: 0.6) else { return }
                self?.tabPreviewCache.setPreview(data, for: tabID, isIncognito: tabIncognito)
                DispatchQueue.main.async {
                    self?.publishTabState()
                }
            }
            #endif
        }
        if tabID == activeTabID {
            self.webView = webView
            syncActiveTabState()
        }
    }

    fileprivate func updateWebViewProgress(for tabID: UUID, webView: WKWebView) {
        guard var tab = tabManager.tab(withID: tabID) else { return }
        tab.estimatedProgress = webView.estimatedProgress
        _ = tabManager.updateTab(tab)
        publishTabState()
        if tabID == activeTabID {
            estimatedProgress = webView.estimatedProgress
        }
    }

    fileprivate func handleWebViewError(
        _ error: Error,
        for tabID: UUID,
        webView: WKWebView,
        generation: UInt64? = nil
    ) {
        if let generation {
            guard isNavigationCurrent(tabID: tabID, generation: generation, url: webView.url) else {
                return
            }
        }
        updateWebViewState(
            for: tabID,
            webView: webView,
            url: tabManager.tab(withID: tabID)?.url,
            title: nil,
            isLoading: false,
            generation: generation
        )
        if tabID == activeTabID {
            let nsError = error as NSError
            let isCancelled = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            let isPluginHandledLoad = (nsError.domain == "WebKitErrorDomain" && (nsError.code == 204 || nsError.code == 102))
            if !isCancelled && !isPluginHandledLoad {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func resetMediaDiscovery(for tabID: UUID) {
        cancelInFlightProbes(for: tabID)
        cancelBlobCapture(for: tabID)
        cancelMSECapture(for: tabID)
        tabSessions[tabID]?.mediaDiscoveryBridge.reset()
        resetMediaCandidateCatalog(for: tabID)

        tabDiscoveredResources[tabID] = []
        tabVariantStreamItems[tabID] = [:]
        tabSelectedResourceIDs[tabID] = []
        tabResourceStates[tabID] = BrowserTabResourceState(
            discoveredResources: [],
            variantStreamItems: [:],
            selectedResourceIDs: []
        )
        if tabID == activeTabID {
            discoveredResources = []
            variantStreamItems = [:]
            selectedResourceIDs = []
            publishMediaCandidates()
        }
    }

    #if canImport(WebKit)
    public func webViewForTab(_ tabID: UUID?) -> WKWebView? {
        guard let tabID else { return webView }
        return webViewSession(for: tabID).webView
    }

    fileprivate func webView(for tabID: UUID?) -> WKWebView? {
        return webViewForTab(tabID)
    }
    #endif

    /// Starts an explicitly requested export for a complete, readable Blob
    /// candidate. The page reads bounded Blob slices; this method never asks
    /// WebKit to materialize the complete object in native memory.
    public func exportBlobCandidate(_ candidate: BrowserMediaCandidate) {
        let effectiveMIME = candidate.mimeType?.lowercased()
        let isMediaSourceMIME = effectiveMIME == "application/x-mediasource"
        let isGenericMIME = effectiveMIME == nil || effectiveMIME?.isEmpty == true || effectiveMIME == "application/octet-stream"
        let isBinOrStreamName = candidate.suggestedFilename.lowercased().hasSuffix(".bin") || candidate.suggestedFilename.lowercased().hasPrefix("blob_stream")
        let isMediaSource = candidate.blobKind == .mediaSource ||
            candidate.kind == .mediaSource ||
            isMediaSourceMIME ||
            (isGenericMIME && isBinOrStreamName)
        guard !isMediaSource else {
            blobCaptureErrorMessage = "This site uses MediaSource streaming. You must download the manifest (.m3u8 or .mpd) instead."
            return
        }
        guard candidate.kind == .completeBlob,
              candidate.availability == .captureCandidate || candidate.availability == .uncertain,
              let blobURL = URL(string: candidate.rawURL),
              blobURL.scheme?.lowercased() == "blob" else {
            blobCaptureErrorMessage = "This browser resource is not available for bounded Blob export."
            BrowserDiagnosticLogger.shared.log(
                category: .blobCapture,
                message: "Blob capture rejected: resource not eligible",
                details: ["rawURL": candidate.rawURL, "kind": candidate.kind.rawValue]
            )
            return
        }

        #if canImport(WebKit)
        let ownerTabID: UUID? = {
            if let activeTabID, mediaCandidateCatalogs[activeTabID]?.candidates.contains(where: { $0.id == candidate.id }) == true {
                return activeTabID
            }
            return mediaCandidateCatalogs.first { _, catalog in
                catalog.candidates.contains(where: { $0.id == candidate.id })
            }?.key
        }()
        let tabID = ownerTabID ?? activeTabID ?? tabManager.activeTabID ?? tabManager.tabs.first?.id
        guard let resolvedTabID = tabID else {
            blobCaptureErrorMessage = "No active browser tab found for Blob export."
            BrowserDiagnosticLogger.shared.log(
                category: .blobCapture,
                message: "Blob capture rejected: no active browser tab found",
                url: blobURL
            )
            return
        }
        let session = webViewSession(for: resolvedTabID)
        #else
        blobCaptureErrorMessage = "WebKit is not supported in this environment."
        return
        #endif

        if isCapturingBlob || isCapturingMSE {
            blobCaptureErrorMessage = "Another browser capture is already in progress."
            #if canImport(WebKit)
            BrowserDiagnosticLogger.shared.log(
                category: .blobCapture,
                message: "Blob capture rejected: another capture already in progress",
                url: blobURL,
                tabID: resolvedTabID
            )
            #endif
            return
        }

        let captureID = "blob-" + UUID().uuidString.lowercased()
        activeBlobCaptureID = captureID
        #if canImport(WebKit)
        activeBlobCaptureTabID = resolvedTabID
        #endif
        activeBlobCaptureOriginalURL = blobURL
        activeBlobCaptureMIMEType = candidate.mimeType
        activeBlobCaptureSuggestedFilename = candidate.suggestedFilename
        blobCaptureSnapshot = nil
        blobCaptureErrorMessage = nil
        isCapturingBlob = true
        scheduleBlobCaptureTimeout(for: captureID, tabID: resolvedTabID)

        #if canImport(WebKit)
        BrowserDiagnosticLogger.shared.log(
            category: .blobCapture,
            message: "Blob capture initialization started",
            url: blobURL,
            tabID: resolvedTabID,
            details: [
                "transferID": captureID,
                "candidateID": candidate.id,
                "suggestedFilename": candidate.suggestedFilename
            ]
        )

        let cleanDocID = candidate.documentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentID = (cleanDocID?.isEmpty == false) ? cleanDocID : nil
        let service = session.blobCaptureService
        let webView = session.webView
        Task { @MainActor [weak self] in
            await service.authorize(
                transferID: captureID,
                tabID: resolvedTabID.uuidString,
                documentID: documentID,
                candidateID: candidate.id,
                suggestedFilename: candidate.suggestedFilename
            )
            BrowserDiagnosticLogger.shared.log(
                category: .blobCapture,
                message: "Native service accepted authorization",
                url: blobURL,
                tabID: resolvedTabID,
                details: ["transferID": captureID]
            )
            guard let self,
                  self.activeBlobCaptureID == captureID,
                  self.activeBlobCaptureTabID == resolvedTabID else {
                await service.cancel(captureID: captureID)
                BrowserDiagnosticLogger.shared.log(
                    category: .blobCapture,
                    message: "Blob capture aborted before JavaScript evaluation (tab changed or cancelled)",
                    url: blobURL,
                    tabID: resolvedTabID,
                    details: ["transferID": captureID]
                )
                return
            }
            do {
                BrowserDiagnosticLogger.shared.log(
                    category: .blobCapture,
                    message: "Invoking JavaScript blob capture bridge",
                    url: blobURL,
                    tabID: resolvedTabID,
                    details: ["transferID": captureID]
                )
                _ = try await webView.evaluateJavaScript(
                    BlobCaptureBridge.startCommand(
                        blobURL: blobURL,
                        transferID: captureID,
                        documentID: documentID,
                        tabID: resolvedTabID.uuidString,
                        candidateID: candidate.id
                    )
                )
                BrowserDiagnosticLogger.shared.log(
                    category: .blobCapture,
                    message: "JavaScript blob capture bridge invoked successfully",
                    url: blobURL,
                    tabID: resolvedTabID,
                    details: ["transferID": captureID]
                )
            } catch {
                BrowserDiagnosticLogger.shared.log(
                    category: .blobCapture,
                    message: "JavaScript blob capture bridge invocation failed",
                    url: blobURL,
                    tabID: resolvedTabID,
                    details: ["transferID": captureID, "error": error.localizedDescription]
                )
                await service.cancel(captureID: captureID)
                self.blobCaptureErrorMessage = "The browser Blob capture could not start: \(error.localizedDescription)"
                self.clearActiveBlobCaptureState()
            }
        }
        #endif
    }

    private func clearActiveBlobCaptureState() {
        blobCaptureTimeoutTask?.cancel()
        blobCaptureTimeoutTask = nil
        activeBlobCaptureID = nil
        activeBlobCaptureTabID = nil
        activeBlobCaptureOriginalURL = nil
        activeBlobCaptureMIMEType = nil
        activeBlobCaptureSuggestedFilename = nil
        blobCaptureSnapshot = nil
        isCapturingBlob = false
    }

    private func scheduleBlobCaptureTimeout(for captureID: String, tabID: UUID, timeoutSeconds: TimeInterval = 15) {
        blobCaptureTimeoutTask?.cancel()
        blobCaptureTimeoutTask = Task { @MainActor [weak self] in
            let nanos = UInt64(max(1.0, timeoutSeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled,
                  let self,
                  self.isCapturingBlob,
                  self.activeBlobCaptureID == captureID else { return }
            #if canImport(WebKit)
            if let session = self.tabSessions[tabID] {
                _ = try? await session.webView.evaluateJavaScript(
                    BlobCaptureBridge.cancelCommand(transferID: captureID)
                )
                let service = session.blobCaptureService
                await service.cancel(captureID: captureID, reason: "Blob export timed out")
            }
            #endif
            self.clearActiveBlobCaptureState()
            self.blobCaptureErrorMessage = "Blob export timed out. This site may use a streaming buffer or revoked Blob URL that cannot be exported directly."
        }
    }

    /// Cancels the active page reader and removes the native partial file.
    public func cancelBlobCapture(for tabID: UUID? = nil) {
        guard let captureID = activeBlobCaptureID else { return }
        if let tabID, activeBlobCaptureTabID != tabID { return }
        let targetTabID = activeBlobCaptureTabID
        if let targetTabID, let session = tabSessions[targetTabID] {
            _ = try? session.webView.evaluateJavaScript(
                BlobCaptureBridge.cancelCommand(transferID: captureID)
            )
            let service = session.blobCaptureService
            Task { await service.cancel(captureID: captureID) }
        }
        clearActiveBlobCaptureState()
    }

    /// Handles unexpected WebContent process termination (crash or memory pressure) for blob captures.
    /// Preserves the partial staging file for recovery instead of discarding it, and records diagnostics.
    public func handleBlobProcessTermination(for tabID: UUID) {
        if let session = tabSessions[tabID] {
            let service = session.blobCaptureService
            let tabString = tabID.uuidString
            Task {
                _ = await service.handleWebContentProcessTermination(tabID: tabString)
            }
        }
        if activeBlobCaptureTabID == tabID {
            clearActiveBlobCaptureState()
            blobCaptureErrorMessage = "The webpage process was terminated by iOS (likely memory pressure). Partial download preserved for recovery."
        }
    }

    /// Handles unexpected WebContent process termination (crash or memory pressure) for MSE captures.
    /// Preserves partial staging track segments for recovery and persists recovery metadata.
    public func handleMSEProcessTermination(for tabID: UUID) {
        if let session = tabSessions[tabID] {
            let service = session.mseCaptureService
            let captureID = activeMSECaptureID
            Task {
                _ = await service.handleWebContentProcessTermination(captureID: captureID)
            }
        }
        if activeMSECaptureTabID == tabID {
            activeMSECaptureID = nil
            activeMSECaptureTabID = nil
            activeMSECaptureSuggestedFilename = nil
            isCapturingMSE = false
            mseCaptureErrorMessage = "The webpage process was terminated by iOS (likely memory pressure). Partial MSE capture preserved for recovery."
        }
    }

    fileprivate func handleBlobCaptureAcknowledgement(
        _ acknowledgement: BlobCaptureAck,
        tabID: UUID
    ) {
        guard acknowledgement.transferID == activeBlobCaptureID,
              activeBlobCaptureTabID == tabID else { return }

        if let snapshot = acknowledgement.snapshot {
            blobCaptureSnapshot = snapshot
            if !snapshot.isComplete {
                scheduleBlobCaptureTimeout(for: acknowledgement.transferID, tabID: tabID)
            }
        }
        guard acknowledgement.accepted else {
            blobCaptureErrorMessage = acknowledgement.error?.localizedDescription ??
                "The browser Blob could not be exported."
            clearActiveBlobCaptureState()
            return
        }
        if acknowledgement.snapshot?.isComplete == true {
            blobCaptureTimeoutTask?.cancel()
            blobCaptureTimeoutTask = nil
            guard let snapshot = acknowledgement.snapshot,
                  snapshot.bytesWritten > 0,
                  let finalURL = snapshot.finalURL else {
                blobCaptureErrorMessage = "The Blob capture failed: 0 bytes received or no finalized output produced."
                clearActiveBlobCaptureState()
                return
            }
            let candidateFilename = self.activeBlobCaptureSuggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let filename: String
            if let candidateFilename, !candidateFilename.isEmpty {
                filename = candidateFilename
            } else {
                filename = URL(fileURLWithPath: finalURL.path).lastPathComponent
            }
            guard !filename.isEmpty else {
                blobCaptureErrorMessage = "The Blob was captured but no finalized output filename was produced."
                clearActiveBlobCaptureState()
                return
            }
            let expectedSize = snapshot.expectedSize
            let originalURL = self.activeBlobCaptureOriginalURL
            let mimeType = self.activeBlobCaptureMIMEType
            Task { @MainActor [weak self] in
                do {
                    guard let self,
                          let downloadDelegate = self.downloadDelegate else {
                        throw BrowserDownloadDelegateError.completedFileImportUnavailable
                    }
                    try await downloadDelegate.importCompletedBrowserFile(
                        fileURL: finalURL,
                        filename: filename,
                        expectedSize: expectedSize,
                        originalURL: originalURL,
                        mimeType: mimeType
                    )
                    self.clearActiveBlobCaptureState()
                    self.downloadSuccessNotification = "Blob download completed: \(filename)"
                    self.onDownloadInitiated?()
                } catch {
                    guard let self else { return }
                    self.blobCaptureErrorMessage = error.localizedDescription
                    self.clearActiveBlobCaptureState()
                }
            }
        }
    }

    /// Starts an explicit MSE capture for a supported MediaSource candidate.
    /// Observation remains metadata-only until this method runs.
    public func startMSECapture(_ candidate: BrowserMediaCandidate) {
        let ownerTabID: UUID? = {
            if let activeTabID, mediaCandidateCatalogs[activeTabID]?.candidates.contains(where: { $0.id == candidate.id }) == true {
                return activeTabID
            }
            return mediaCandidateCatalogs.first { _, catalog in
                catalog.candidates.contains(where: { $0.id == candidate.id })
            }?.key
        }()
        let tabID = ownerTabID ?? activeTabID ?? tabManager.activeTabID ?? tabManager.tabs.first?.id
        guard candidate.kind == .mediaSource,
              candidate.availability == .captureCandidate || candidate.availability == .uncertain,
              candidate.rawURL.lowercased().hasPrefix("blob:"),
              let resolvedTabID = tabID else {
            mseCaptureErrorMessage = "This MediaSource session is not available for bounded capture."
            return
        }

        let support = BrowserMSECaptureSupportClassifier.evaluate(mimeType: candidate.mimeType)
        guard support.isCapturable else {
            mseCaptureErrorMessage = support.reason
            return
        }

        if isCapturingBlob || isCapturingMSE {
            mseCaptureErrorMessage = "Another browser capture is already in progress."
            return
        }

        let captureID = "mse-" + UUID().uuidString.lowercased()
        activeMSECaptureID = captureID
        activeMSECaptureTabID = resolvedTabID
        activeMSECaptureSuggestedFilename = candidate.suggestedFilename.isEmpty ? nil : candidate.suggestedFilename
        mseCaptureSnapshot = nil
        mseCaptureErrorMessage = nil
        isCapturingMSE = true

        let session = webViewSession(for: resolvedTabID)
        let documentID = candidate.documentID
        let service = session.mseCaptureService
        let webView = session.webView
        let mediaSourceURL = candidate.rawURL
        Task { @MainActor [weak self] in
            await service.register(captureID: captureID, documentID: documentID)
            guard let self,
                  self.activeMSECaptureID == captureID,
                  self.activeMSECaptureTabID == resolvedTabID else {
                await service.cancel(captureID: captureID)
                return
            }
            do {
                _ = try await webView.evaluateJavaScript(
                    BrowserMSECaptureBridge.startCommand(
                        mediaSourceURL: mediaSourceURL,
                        captureID: captureID,
                        documentID: documentID
                    )
                )
            } catch {
                await service.cancel(captureID: captureID)
                self.mseCaptureErrorMessage = "The MediaSource capture could not start: \(error.localizedDescription)"
                self.isCapturingMSE = false
                self.activeMSECaptureID = nil
                self.activeMSECaptureTabID = nil
                self.activeMSECaptureSuggestedFilename = nil
            }
        }
    }

    /// Stops capture and attempts reconstruction. Success requires validated output.
    public func stopMSECapture() {
        guard let captureID = activeMSECaptureID,
              let tabID = activeMSECaptureTabID,
              let session = tabSessions[tabID] else { return }
        _ = try? session.webView.evaluateJavaScript(
            BrowserMSECaptureBridge.stopCommand(captureID: captureID)
        )
    }

    public func cancelMSECapture(for tabID: UUID? = nil) {
        guard let captureID = activeMSECaptureID else { return }
        if let tabID, activeMSECaptureTabID != tabID { return }
        let targetTabID = activeMSECaptureTabID
        if let targetTabID, let session = tabSessions[targetTabID] {
            _ = try? session.webView.evaluateJavaScript(
                BrowserMSECaptureBridge.cancelCommand(captureID: captureID)
            )
            let service = session.mseCaptureService
            Task { await service.cancel(captureID: captureID) }
        }
        activeMSECaptureID = nil
        activeMSECaptureTabID = nil
        activeMSECaptureSuggestedFilename = nil
        isCapturingMSE = false
    }

    fileprivate func handleMSECaptureAcknowledgement(
        _ acknowledgement: BrowserMSECaptureAck,
        tabID: UUID
    ) {
        guard acknowledgement.captureID == activeMSECaptureID,
              activeMSECaptureTabID == tabID else { return }

        if let snapshot = acknowledgement.snapshot {
            mseCaptureSnapshot = snapshot
        }
        guard acknowledgement.accepted else {
            mseCaptureErrorMessage = acknowledgement.error?.localizedDescription ??
                "The MediaSource session could not be captured."
            isCapturingMSE = false
            activeMSECaptureID = nil
            activeMSECaptureTabID = nil
            activeMSECaptureSuggestedFilename = nil
            return
        }
        if let snapshot = acknowledgement.snapshot, snapshot.isSuccessfullyReconstructed {
            let outputURL = snapshot.reconstructedURL
            let capturedBytes = snapshot.bytesCaptured
            let defaultFilename = outputURL?.lastPathComponent ?? "mse-capture.mp4"
            let candidateFilename = self.activeMSECaptureSuggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let filename: String = {
                if let candidateFilename, !candidateFilename.isEmpty {
                    return candidateFilename.hasSuffix(".mp4") ? candidateFilename : candidateFilename + ".mp4"
                }
                return defaultFilename
            }()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let outputURL {
                    try? await self.downloadDelegate?.importCompletedBrowserFile(
                        fileURL: outputURL,
                        filename: filename,
                        expectedSize: capturedBytes > 0 ? capturedBytes : nil,
                        originalURL: nil,
                        mimeType: "video/mp4"
                    )
                }
                self.isCapturingMSE = false
                self.activeMSECaptureID = nil
                self.activeMSECaptureTabID = nil
                self.activeMSECaptureSuggestedFilename = nil
                self.downloadSuccessNotification = "MSE capture completed: \(filename)"
                self.onDownloadInitiated?()
            }
        } else if acknowledgement.snapshot?.lifecycle == .cancelled {
            isCapturingMSE = false
            activeMSECaptureID = nil
            activeMSECaptureTabID = nil
            activeMSECaptureSuggestedFilename = nil
        }
    }

    public func inspectStreamCandidate(_ candidate: BrowserMediaCandidate) {
        guard candidate.kind == .mediaSource else { return }
        let support = BrowserMSECaptureSupportClassifier.evaluate(mimeType: candidate.mimeType)
        if support.status == .protectedMedia {
            mseCaptureErrorMessage = support.reason
        } else if support.isCapturable {
            mseCaptureErrorMessage = support.reason + " Start capture to retain appendBuffer payloads."
        } else {
            mseCaptureErrorMessage = support.reason + " Prefer HLS/DASH manifest discovery when available."
        }
    }
    #endif

    public func shouldSuppressDuplicatePrompt(for url: URL) -> Bool {
        interceptionManager.shouldSuppressDuplicate(for: url, isSheetPresented: isShowingDownloadSheet)
    }

    public func openAddDownload(for url: URL) {
        guard !StreamingManifestClassifier.classify(url: url).isManifest else { return }
        onOpenAddDownload?(url)
    }

    public func handleNativeDownloadHandoff(
        originalURL: URL,
        finalURL: URL? = nil,
        suggestedFilename: String? = nil,
        contentDisposition: String? = nil,
        mimeType: String? = nil,
        expectedLength: Int64? = nil,
        source: BrowserDownloadHandoffSource = .nativeWebKitDownload,
        requestContext: BrowserRequestContext? = nil
    ) {
        let dest = finalURL ?? originalURL
        guard !interceptionManager.shouldSuppressDuplicate(for: dest, isSheetPresented: isShowingDownloadSheet) else {
            return
        }
        guard let handoff = interceptionManager.prepareHandoff(
            originalURL: originalURL,
            finalURL: finalURL,
            serverSuggestedFilename: suggestedFilename,
            contentDisposition: contentDisposition,
            mimeType: mimeType,
            expectedLength: expectedLength,
            source: source,
            requestContext: requestContext
        ) else {
            return
        }

        interceptionManager.recordInterception(for: handoff.finalURL)
        activeHandoff = handoff
        activeDownloadCandidate = mediaCandidates.first {
            $0.url == handoff.finalURL || $0.rawURL.caseInsensitiveCompare(handoff.finalURL.absoluteString) == .orderedSame
        }
        activeDownloadResource = discoveredResources.first { $0.url == handoff.finalURL }
        downloadCandidateURL = handoff.finalURL
        downloadCandidateFilename = handoff.suggestedFilename
        downloadCandidateRequestContext = handoff.requestContext
        useBrowserCredentials = handoff.requestContext != nil
        downloadCandidateThreads = 6
        downloadCandidateSpeedLimitKBps = ""
        isShowingDownloadSheet = true
    }

    public func promptDownload(
        for candidate: BrowserMediaCandidate,
        customFilename: String? = nil
    ) {
        activeDownloadCandidate = candidate
        if activeDownloadResource == nil || (activeDownloadResource?.url != candidate.url && activeDownloadResource?.id != candidate.id) {
            activeDownloadResource = discoveredResources.first {
                $0.id == candidate.id ||
                $0.url.absoluteString.caseInsensitiveCompare(candidate.rawURL) == .orderedSame ||
                (candidate.url != nil && $0.url == candidate.url)
            } ?? candidate.toWebpageResource()
        }
        let url = candidate.url ?? URL(string: candidate.rawURL)
        downloadCandidateURL = url
        let resolvedFilename: String = {
            if let custom = customFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                return custom
            }
            if !candidate.suggestedFilename.isEmpty {
                return candidate.suggestedFilename
            }
            if let url {
                return BrowserURLResolver.suggestedFilename(from: url)
            }
            return "download.bin"
        }()
        downloadCandidateFilename = resolvedFilename
        downloadCandidateRequestContext = candidate.requestContext
        useBrowserCredentials = candidate.requestContext != nil
        downloadCandidateThreads = 6
        downloadCandidateSpeedLimitKBps = ""
        isShowingDownloadSheet = true
    }

    public func promptDownload(
        for resource: WebpageResource,
        customFilename: String? = nil
    ) {
        activeDownloadResource = resource
        let matchedCandidate = mediaCandidates.first { cand in
            cand.id == resource.id ||
            cand.rawURL.caseInsensitiveCompare(resource.url.absoluteString) == .orderedSame ||
            (cand.url != nil && cand.url == resource.url)
        }
        let candidate = matchedCandidate ?? BrowserMediaCandidateClassifier.classify(resource: resource)
        promptDownload(for: candidate, customFilename: customFilename ?? resource.suggestedFilename)
    }

    public func promptDownload(
        for url: URL,
        suggestedFilename: String?,
        requestContext: BrowserRequestContext? = nil
    ) {
        activeDownloadCandidate = mediaCandidates.first {
            $0.url == url || $0.rawURL.caseInsensitiveCompare(url.absoluteString) == .orderedSame
        }
        activeDownloadResource = discoveredResources.first { $0.url == url }
        handleNativeDownloadHandoff(
            originalURL: url,
            finalURL: url,
            suggestedFilename: suggestedFilename,
            source: .responseAttachment,
            requestContext: requestContext
        )
    }

    public var recoveryManager: DownloadRecoveryManager? {
        downloadDelegate?.downloadRecoveryManager
    }

    public func matchingTransferDot(for resource: WebpageResource) -> DownloadStatusDot? {
        guard let rm = recoveryManager else { return nil }
        let transfers = downloadDelegate?.unifiedTransfersList ?? []
        return rm.matcher.match(resource: resource, transfers: transfers)?.statusDot
    }

    public func matchingTransfer(for resource: WebpageResource) -> DownloadMatchResult? {
        guard let rm = recoveryManager else { return nil }
        let transfers = downloadDelegate?.unifiedTransfersList ?? []
        return rm.matcher.match(resource: resource, transfers: transfers)
    }

    public func matchingTransferDot(for candidate: BrowserMediaCandidate) -> DownloadStatusDot? {
        if let res = candidate.toWebpageResource() {
            return matchingTransferDot(for: res)
        }
        return nil
    }

    public func matchingTransfer(for candidate: BrowserMediaCandidate) -> DownloadMatchResult? {
        if let res = candidate.toWebpageResource() {
            return matchingTransfer(for: res)
        }
        return nil
    }

    /// Synchronizes all media candidates captured dynamically during video playback
    /// directly into discoveredResources, ensuring the resource grabber can display
    /// grabbed links immediately without waiting for DOM evaluation or showing a blocking spinner.
    public func syncMediaCandidatesToDiscoveredResources(for tabID: UUID? = nil) {
        discoveryCoordinator.discoveredResources = discoveredResources
        discoveryCoordinator.variantStreamItems = variantStreamItems
        discoveryCoordinator.selectedResourceIDs = selectedResourceIDs
        discoveryCoordinator.syncMediaCandidatesToDiscoveredResources(for: tabID, activeTabID: activeTabID)
        discoveredResources = discoveryCoordinator.discoveredResources
    }

        public func openResourceInspector() {
        syncMediaCandidatesToDiscoveredResources()
        isShowingResourceInspector = true
        if discoveredResources.isEmpty {
            inspectCurrentPageResources(includeNonVideo: false)
        } else {
            expandStreamingManifests()
        }
    }

    public func promptDownloadFromInspector(for candidate: BrowserMediaCandidate) {
        if let res = candidate.toWebpageResource() {
            activeDownloadResource = res
            activeDownloadCandidate = candidate
            promptDownloadFromInspector(for: res)
        } else {
            promptDownload(for: candidate)
        }
    }

    public func promptDownloadFromInspector(for resource: WebpageResource) {
        activeDownloadResource = resource
        resumeTargetTransferID = nil
        resumeTargetTransferName = nil
        // Evaluate against existing transfers to avoid duplicates and handle link recovery
        if let match = matchingTransfer(for: resource) {
            // Case 1: In active link-refresh session or matched transfer failed -> Open download page in Resume mode
            if recoveryManager?.activeSession != nil || match.statusDot == .failed {
                let targetID = recoveryManager?.activeSession?.targetTransferID ?? match.transferID
                let targetName = downloadDelegate?.unifiedTransfersList.first(where: { $0.id == targetID })?.name ?? resource.suggestedFilename
                isShowingResourceInspector = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }
                    self.resumeTargetTransferID = targetID
                    self.resumeTargetTransferName = targetName
                    self.activeDownloadResource = resource
                    let matchedCandidate = self.mediaCandidates.first { cand in
                        cand.id == resource.id ||
                        cand.rawURL.caseInsensitiveCompare(resource.url.absoluteString) == .orderedSame ||
                        (cand.url != nil && cand.url == resource.url)
                    }
                    let candidate = matchedCandidate ?? BrowserMediaCandidateClassifier.classify(resource: resource)
                    self.activeDownloadCandidate = candidate
                    self.downloadCandidateURL = resource.url
                    self.downloadCandidateFilename = targetName.isEmpty ? (resource.suggestedFilename.isEmpty ? "download" : resource.suggestedFilename) : targetName
                    self.downloadCandidateRequestContext = resource.requestContext ?? candidate.requestContext
                    self.useBrowserCredentials = (resource.requestContext != nil || candidate.requestContext != nil)
                    self.downloadCandidateThreads = 6
                    self.downloadCandidateSpeedLimitKBps = ""
                    self.isShowingQualityPicker = false
                    self.selectedQualityOption = nil
                    self.isShowingDownloadSheet = true
                }
                return
            }

            // Case 2: Currently downloading -> Avoid starting duplicate transfer
            if match.statusDot == .downloading {
                isShowingResourceInspector = false
                onOpenDownloads?()
                return
            }

            // Case 3: Paused -> Resume existing transfer
            if match.statusDot == .paused {
                isShowingResourceInspector = false
                Task { [weak self] in
                    try? await self?.recoveryManager?.retry(transferID: match.transferID)
                    await MainActor.run {
                        self?.onOpenDownloads?()
                    }
                }
                return
            }

            // Case 4: Completed -> Avoid creating duplicate download
            if match.statusDot == .completed {
                isShowingResourceInspector = false
                onOpenDownloads?()
                return
            }
        }

        isShowingResourceInspector = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.activeDownloadResource = resource
            let matchedCandidate = self.mediaCandidates.first { cand in
                cand.id == resource.id ||
                cand.rawURL.caseInsensitiveCompare(resource.url.absoluteString) == .orderedSame ||
                (cand.url != nil && cand.url == resource.url)
            }
            let candidate = matchedCandidate ?? BrowserMediaCandidateClassifier.classify(resource: resource)
            self.activeDownloadCandidate = candidate
            self.downloadCandidateURL = resource.url
            self.downloadCandidateFilename = resource.suggestedFilename.isEmpty ? (candidate.suggestedFilename.isEmpty ? "download" : candidate.suggestedFilename) : resource.suggestedFilename
            self.downloadCandidateRequestContext = resource.requestContext ?? candidate.requestContext
            self.useBrowserCredentials = (resource.requestContext != nil || candidate.requestContext != nil)
            self.downloadCandidateThreads = 6
            self.downloadCandidateSpeedLimitKBps = ""
            self.isShowingQualityPicker = false
            self.selectedQualityOption = nil
            self.isShowingDownloadSheet = true
        }
    }

    /// Prefills the global Add Download sheet with this candidate's URL and dismisses the inspector.
    public func sendToGlobalAddDownload(for candidate: BrowserMediaCandidate) {
        if let res = candidate.toWebpageResource() {
            sendToGlobalAddDownload(for: res)
        } else if let url = candidate.url ?? URL(string: candidate.rawURL) {
            isShowingResourceInspector = false
            onOpenAddDownload?(url)
        }
    }

    /// Prefills the global Add Download sheet with this resource's URL and dismisses the inspector.
    public func sendToGlobalAddDownload(for resource: WebpageResource) {
        isShowingResourceInspector = false
        onOpenAddDownload?(resource.url)
    }

    private func findNewerCandidate(for url: URL) -> BrowserMediaCandidate? {
        mediaCandidates
            .filter { cand in
                guard let candURL = cand.url, !cand.isExpired else { return false }
                return candURL.host?.lowercased() == url.host?.lowercased() &&
                       candURL.path == url.path &&
                       candURL != url
            }
            .max(by: { $0.lastObserved < $1.lastObserved })
    }

    /// Refreshes expired or expiring signed media tokens from the active webpage.
    public func refreshResourceToken(for resource: WebpageResource) {
        let isVariant = resource.hlsVariantPreferences != nil
        let exactURI = resource.hlsVariantPreferences?.exactURI
        let masterURL = resource.url

        var refreshedExactURI: URL? = nil
        var refreshedMasterURL: URL? = nil
        var candidateContext: BrowserRequestContext? = nil

        if isVariant {
            // 1. If variant has an exactURI, look for a newer candidate matching the variant URL
            if let exact = exactURI, let newerVariant = findNewerCandidate(for: exact) {
                refreshedExactURI = newerVariant.url
                candidateContext = newerVariant.requestContext
            }

            // 2. Also check if the master manifest URL has a newer candidate
            if let newerMaster = findNewerCandidate(for: masterURL) {
                refreshedMasterURL = newerMaster.url
                if candidateContext == nil {
                    candidateContext = newerMaster.requestContext
                }
                // If variant's exactURI did not match a separate candidate, propagate query token from master
                if refreshedExactURI == nil, let exact = exactURI, let parentQuery = newerMaster.url?.query {
                    refreshedExactURI = exact.mergingParentQuery(parentQuery)
                }
            }
        } else {
            // Direct resource (or unexpanded master manifest): refresh resource.url
            if let newerDirect = findNewerCandidate(for: resource.url) {
                refreshedMasterURL = newerDirect.url
                candidateContext = newerDirect.requestContext
            }
        }

        let didRefresh = (isVariant && (refreshedExactURI != nil || refreshedMasterURL != nil)) || (!isVariant && refreshedMasterURL != nil)
        if didRefresh {
            let targetURL = isVariant ? (refreshedExactURI ?? exactURI ?? refreshedMasterURL ?? masterURL) : (refreshedMasterURL ?? resource.url)
            let baseContext = candidateContext ?? resource.requestContext
            let effectivePageURL = baseContext?.pageURL ?? currentURL ?? URL(string: "about:blank")!
            let effectiveUserAgent = baseContext?.userAgent ?? BrowserViewModel.defaultDesktopUserAgent
            let effectiveCookies = baseContext?.cookies ?? []
            let effectiveCustomHeaders = baseContext?.customHeaders ?? [:]
            let effectiveAllowedOrigins = baseContext?.allowedCredentialOrigins ?? []
            let reconstructedContext = BrowserRequestContext(
                url: targetURL,
                pageURL: effectivePageURL,
                userAgent: effectiveUserAgent,
                cookies: effectiveCookies,
                customHeaders: effectiveCustomHeaders,
                captureDate: Date(),
                source: baseContext?.source ?? .webpageResource,
                allowedCredentialOrigins: effectiveAllowedOrigins
            )

            let updatedPreferences: HLSVariantSelectionPreferences? = {
                if let currentPrefs = resource.hlsVariantPreferences {
                    return HLSVariantSelectionPreferences(
                        maximumBandwidth: currentPrefs.maximumBandwidth,
                        maximumWidth: currentPrefs.maximumWidth,
                        maximumHeight: currentPrefs.maximumHeight,
                        exactURI: refreshedExactURI ?? currentPrefs.exactURI
                    )
                }
                return nil
            }()

            let updated = WebpageResource(
                id: resource.id,
                url: isVariant ? (refreshedMasterURL ?? resource.url) : (refreshedMasterURL ?? resource.url),
                title: resource.title,
                suggestedFilename: resource.suggestedFilename,
                resourceType: resource.resourceType,
                mimeType: resource.mimeType,
                estimatedSize: resource.estimatedSize,
                isSupported: resource.isSupported,
                unsupportedReason: resource.unsupportedReason,
                requestContext: reconstructedContext,
                manifestText: resource.manifestText,
                hlsVariantPreferences: updatedPreferences ?? resource.hlsVariantPreferences,
                dashVideoRepresentationID: resource.dashVideoRepresentationID,
                dashAudioRepresentationID: resource.dashAudioRepresentationID,
                dashTextRepresentationID: resource.dashTextRepresentationID,
                isDRMProtected: resource.isDRMProtected,
                drmProtectionType: resource.drmProtectionType,
                discoveredAt: resource.discoveredAt,
                isLive: resource.isLive
            )

            if let currentItem = variantStreamItems[resource.id] {
                variantStreamItems[resource.id] = HLSVariantStreamItem(
                    id: currentItem.id,
                    masterURL: refreshedMasterURL ?? currentItem.masterURL,
                    variantURL: refreshedExactURI ?? currentItem.variantURL,
                    bandwidth: currentItem.bandwidth,
                    resolution: currentItem.resolution,
                    qualityLabel: currentItem.qualityLabel,
                    resolutionText: currentItem.resolutionText,
                    bitrateText: currentItem.bitrateText,
                    hasAudio: currentItem.hasAudio,
                    audioText: currentItem.audioText,
                    hasSubtitles: currentItem.hasSubtitles,
                    subtitleText: currentItem.subtitleText,
                    codecs: currentItem.codecs,
                    videoCodec: currentItem.videoCodec,
                    estimatedSizeBytes: currentItem.estimatedSizeBytes,
                    estimatedSizeText: currentItem.estimatedSizeText,
                    isLive: currentItem.isLive,
                    isIFrameOnly: currentItem.isIFrameOnly,
                    isLowLatency: currentItem.isLowLatency
                )
            }

            var updatedResources = discoveredResources
            if let idx = updatedResources.firstIndex(where: { $0.id == resource.id }) {
                updatedResources[idx] = updated
                discoveredResources = updatedResources
            }

            promptDownloadFromInspector(for: updated)
            return
        }

        inspectCurrentPageResources()
    }

    /// Refreshes expired or expiring signed media tokens for a candidate from the active webpage.
    public func refreshResourceToken(for candidate: BrowserMediaCandidate) {
        if let res = candidate.toWebpageResource() {
            refreshResourceToken(for: res)
        }
    }

    public func executeDecision(_ decision: BrowserDownloadDecision) {
        switch decision.action {
        case .streaming(let manifestURL, _, let suggestedFilename, let cachedText, let requestContext):
            let res = WebpageResource(
                url: manifestURL,
                title: decision.candidate.suggestedFilename.isEmpty ? suggestedFilename : decision.candidate.suggestedFilename,
                suggestedFilename: suggestedFilename,
                resourceType: .video,
                requestContext: requestContext ?? decision.candidate.requestContext,
                manifestText: cachedText,
                hlsVariantPreferences: nil
            )
            self.presentQualityPicker(for: res)

        case .mseCapture(let candidate):
            #if canImport(WebKit)
            self.startMSECapture(candidate)
            #else
            self.mseCaptureErrorMessage = "MSE capture requires WebKit."
            #endif

        case .blobExport(let candidate):
            #if canImport(WebKit)
            self.exportBlobCandidate(candidate)
            #else
            self.blobCaptureErrorMessage = "Blob export requires WebKit."
            #endif

        case .direct(let url, let suggestedFilename, _, _, let requestContext):
            if decision.candidate.kind == .directMedia {
                do {
                    let plan = try DirectMediaTransferPlanner.makePlan(candidate: decision.candidate)
                    self.promptDownload(
                        for: plan.transferURL,
                        suggestedFilename: plan.filename,
                        requestContext: plan.requestContext
                    )
                } catch {
                    self.resourceScanError = error.localizedDescription
                }
            } else {
                self.promptDownload(
                    for: url,
                    suggestedFilename: suggestedFilename,
                    requestContext: requestContext
                )
            }

        case .protectedMedia(let reason):
            self.streamingErrorMessage = reason
            self.blobCaptureErrorMessage = reason
            self.mseCaptureErrorMessage = reason

        case .unsupported(let reason):
            self.streamingErrorMessage = reason
            self.blobCaptureErrorMessage = reason
            self.mseCaptureErrorMessage = reason
        }
    }

    public func promptStreamingDownload(
        for candidate: BrowserMediaCandidate,
        customFilename: String? = nil,
        transportPolicy: HTTPTransportPolicy? = nil
    ) {
        guard let resource = candidate.toWebpageResource() else {
            let errorMsg = "This media candidate is not a recognized streaming manifest."
            streamingErrorMessage = errorMsg
            return
        }
        promptStreamingDownload(for: resource, customFilename: customFilename, transportPolicy: transportPolicy)
    }

    public func promptStreamingDownload(
        for resource: WebpageResource,
        customFilename: String? = nil,
        transportPolicy: HTTPTransportPolicy? = nil
    ) {
        print("[HLS Pipeline] promptStreamingDownload invoked for resource: \(resource.url.absoluteString)")
        if let custom = customFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            self.activeStreamingFilename = custom
        } else if !resource.suggestedFilename.isEmpty {
            self.activeStreamingFilename = resource.suggestedFilename
        }
        guard resource.isStreamingManifest || resource.url.pathExtension.lowercased() == "m3u8" || resource.url.pathExtension.lowercased() == "mpd" else {
            let errorMsg = "This resource is not a recognized HLS or DASH manifest."
            print("[HLS Pipeline] \(errorMsg)")
            streamingErrorMessage = errorMsg
            blobCaptureErrorMessage = errorMsg
            return
        }
        let effectiveOrchestrator = streamingOrchestrator ?? (downloadDelegate as? DownloadManagerViewModel)?.streamingOrchestrator
        guard let orchestrator = effectiveOrchestrator else {
            let errorMsg = "Streaming downloads are unavailable: StreamingDownloadOrchestrator is nil."
            print("[HLS Pipeline] \(errorMsg)")
            streamingErrorMessage = errorMsg
            blobCaptureErrorMessage = errorMsg
            return
        }
        guard !isPreparingStreaming, !isExecutingStreaming else {
            print("[HLS Pipeline] Streaming download is already preparing or executing.")
            return
        }

        isShowingResourceInspector = false
        isShowingStreamingConfirmation = false
        isPreparingStreaming = true
        streamingErrorMessage = nil
        streamingProposal = nil
        streamingProgress = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                #if canImport(WebKit)
                let sessionSnapshot: BrowserSessionSnapshot?
                if let wv = self.webView {
                    sessionSnapshot = await DownloadRequestEnricher.snapshot(from: wv)
                } else {
                    sessionSnapshot = nil
                }
                #else
                let sessionSnapshot: BrowserSessionSnapshot? = nil
                #endif
                print("[HLS Pipeline] Setting active BrowserViewModel as urlResolver on orchestrator...")
                await orchestrator.setURLResolver(self)
                var effectiveResource = resource
                if effectiveResource.manifestText == nil || effectiveResource.manifestText?.isEmpty == true {
                    if let cachedText = self.discoveredResources.first(where: { $0.url == resource.url })?.manifestText, !cachedText.isEmpty {
                        effectiveResource = WebpageResource(
                            id: effectiveResource.id,
                            url: effectiveResource.url,
                            title: effectiveResource.title,
                            suggestedFilename: effectiveResource.suggestedFilename,
                            resourceType: effectiveResource.resourceType,
                            mimeType: effectiveResource.mimeType,
                            estimatedSize: effectiveResource.estimatedSize,
                            isSupported: effectiveResource.isSupported,
                            unsupportedReason: effectiveResource.unsupportedReason,
                            requestContext: effectiveResource.requestContext,
                            manifestText: cachedText,
                            hlsVariantPreferences: effectiveResource.hlsVariantPreferences,
                            dashVideoRepresentationID: effectiveResource.dashVideoRepresentationID,
                            dashAudioRepresentationID: effectiveResource.dashAudioRepresentationID,
                            dashTextRepresentationID: effectiveResource.dashTextRepresentationID,
                            isDRMProtected: effectiveResource.isDRMProtected,
                            drmProtectionType: effectiveResource.drmProtectionType,
                            discoveredAt: effectiveResource.discoveredAt,
                            isLive: effectiveResource.isLive
                        )
                    } else if let cachedText = self.mediaCandidates.first(where: { $0.url == resource.url })?.cachedManifestText, !cachedText.isEmpty {
                        effectiveResource = WebpageResource(
                            id: effectiveResource.id,
                            url: effectiveResource.url,
                            title: effectiveResource.title,
                            suggestedFilename: effectiveResource.suggestedFilename,
                            resourceType: effectiveResource.resourceType,
                            mimeType: effectiveResource.mimeType,
                            estimatedSize: effectiveResource.estimatedSize,
                            isSupported: effectiveResource.isSupported,
                            unsupportedReason: effectiveResource.unsupportedReason,
                            requestContext: effectiveResource.requestContext,
                            manifestText: cachedText,
                            hlsVariantPreferences: effectiveResource.hlsVariantPreferences,
                            dashVideoRepresentationID: effectiveResource.dashVideoRepresentationID,
                            dashAudioRepresentationID: effectiveResource.dashAudioRepresentationID,
                            dashTextRepresentationID: effectiveResource.dashTextRepresentationID,
                            isDRMProtected: effectiveResource.isDRMProtected,
                            drmProtectionType: effectiveResource.drmProtectionType,
                            discoveredAt: effectiveResource.discoveredAt,
                            isLive: effectiveResource.isLive
                        )
                    }
                }

                // If no specific variant was pre-selected, inspect the manifest first.
                // When multiple quality variants exist (e.g. 1080p, 720p, 480p, audio),
                // present the interactive StreamQualityPickerSheet so user can choose.
                if resource.hlsVariantPreferences == nil && resource.dashVideoRepresentationID == nil && resource.dashTextRepresentationID == nil && !self.isShowingQualityPicker {
                    do {
                        let options = try await StreamQualityInspector.inspect(
                            manifestText: effectiveResource.manifestText ?? "",
                            url: effectiveResource.url,
                            mimeType: effectiveResource.mimeType,
                            requestContext: effectiveResource.requestContext
                        )
                        if options.count > 1 {
                            print("[HLS Pipeline] Discovered \(options.count) variants. Presenting StreamQualityPickerSheet...")
                            self.isPreparingStreaming = false
                            self.presentQualityPicker(for: effectiveResource, preloadedOptions: options)
                            return
                        }
                    } catch {
                        print("[HLS Pipeline] Quality inspection note: \(error.localizedDescription). Proceeding with standard preparation.")
                    }
                }

                if effectiveResource.isLive {
                    let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                    let videosDir = docDir.appendingPathComponent("Downloads/Videos", isDirectory: true)
                    let effectiveFilename = self.activeStreamingFilename ?? (effectiveResource.suggestedFilename.isEmpty ? "live_stream.mp4" : effectiveResource.suggestedFilename)
                    let destination = videosDir.appendingPathComponent(effectiveFilename)
                    let req = LiveRecordingRequest(
                        manifestURL: effectiveResource.url,
                        manifestKind: (effectiveResource.url.pathExtension.lowercased() == "mpd") ? .dash : .hls,
                        destinationURL: destination,
                        title: effectiveFilename,
                        requestContext: effectiveResource.requestContext,
                        preferredQualityOption: nil
                    )
                    do {
                        try LiveStreamRecorder.shared.startRecording(request: req)
                        self.downloadSuccessNotification = "Live stream recording started: \(effectiveFilename)"
                        self.isPreparingStreaming = false
                    } catch {
                        self.streamingErrorMessage = "Live recording error: \(error.localizedDescription)"
                        self.isPreparingStreaming = false
                    }
                    return
                }

                print("[HLS Pipeline] Creating StreamingManifestCandidate and preparing proposal with orchestrator...")
                let effectivePolicy = transportPolicy ?? self.preferredStreamingTransportPolicy ?? .background
                let candidate = try StreamingManifestCandidate(
                    resource: effectiveResource,
                    browserSessionSnapshot: sessionSnapshot,
                    transportPolicy: effectivePolicy
                )
                let proposal = try await orchestrator.prepare(candidate: candidate)
                print("[HLS Pipeline] Proposal prepared successfully. Automatically starting streaming download in background...")
                self.streamingProposal = proposal
                self.isPreparingStreaming = false
                self.downloadSuccessNotification = "Streaming download started"
                self.executeStreamingProposal()
            } catch {
                let errorMsg: String
                if case StreamingDownloadOrchestratorError.unsupportedEncryption = error {
                    errorMsg = "Download Failed: This video is protected by DRM (Digital Rights Management) and cannot be downloaded."
                } else {
                    errorMsg = "Streaming preparation failed: \(error.localizedDescription)"
                }
                print("[HLS Pipeline] \(errorMsg)")
                self.streamingErrorMessage = errorMsg
                self.blobCaptureErrorMessage = errorMsg
                self.downloadSuccessNotification = nil
                self.isPreparingStreaming = false
            }
        }
    }

    public func executeStreamingProposal() {
        guard let proposal = streamingProposal,
              let orchestrator = streamingOrchestrator ?? (downloadDelegate as? DownloadManagerViewModel)?.streamingOrchestrator,
              !isExecutingStreaming else { return }

        isExecutingStreaming = true
        isShowingStreamingConfirmation = false
        streamingErrorMessage = nil
        onDownloadInitiated?()
        let destination = streamingDestinationDirectoryURL
        let progressSink: @Sendable (StreamingTransferProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.streamingProgress = progress
            }
        }
        #if canImport(UIKit) && !os(watchOS)
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "DownloadEngineKit.streamingDownload") {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
        #endif
        streamingExecutionTask = Task { @MainActor [weak self] in
            defer {
                #if canImport(UIKit) && !os(watchOS)
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
                #endif
            }
            do {
                let completionMessage: String
                let tempAssemblyDir = destination
                    .appendingPathComponent(".assembly_temp_\(UUID().uuidString)", isDirectory: true)
                try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(destination)
                try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(tempAssemblyDir)

                if proposal.transportPolicy == .background, let bgManager = orchestrator.backgroundSessionManager {
                    PipelineLogger.shared.log("[BrowserView] Explicitly scheduling streaming proposal in background URLSession transport...")
                    _ = try? await orchestrator.scheduleBackgroundStreaming(
                        proposal: proposal,
                        destinationDirectory: tempAssemblyDir,
                        backgroundManager: bgManager
                    )
                }

                switch proposal.manifest {
                case .hls(let transferPlan):
                    let filename: String
                    if let custom = self?.activeStreamingFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                        filename = custom.hasSuffix(".mp4") ? custom : custom + ".mp4"
                    } else {
                        filename = HLSVODReconstructionPlanner.suggestedFilename(for: transferPlan)
                    }
                    let targetURL = destination.appendingPathComponent(filename, isDirectory: false)
                    _ = try await orchestrator.executeAndAssembleHLS(
                        proposal,
                        approved: true,
                        destinationDirectory: tempAssemblyDir,
                        outputURL: targetURL,
                        progress: progressSink
                    )
                    completionMessage = "Streaming download completed: \(filename)."
                case .dash(let transferPlan):
                    let filename: String
                    let isTextOnly = transferPlan.video == nil && transferPlan.audio == nil && transferPlan.text != nil
                    if let custom = self?.activeStreamingFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                        if isTextOnly {
                            if custom.hasSuffix(".vtt") {
                                filename = custom
                            } else if custom.hasSuffix(".mp4") {
                                filename = (custom as NSString).deletingPathExtension + ".vtt"
                            } else {
                                filename = custom + ".vtt"
                            }
                        } else {
                            filename = custom.hasSuffix(".mp4") ? custom : custom + ".mp4"
                        }
                    } else {
                        filename = DASHVODReconstructionPlanner.suggestedFilename(for: transferPlan)
                    }
                    let targetURL = destination.appendingPathComponent(filename, isDirectory: false)
                    _ = try await orchestrator.executeAndAssembleDASH(
                        proposal,
                        approved: true,
                        destinationDirectory: tempAssemblyDir,
                        outputURL: targetURL,
                        progress: progressSink
                    )
                    completionMessage = "Streaming download completed: \(filename)."
                }

                // Streaming downloads are registered, tracked, and completed directly in DownloadEngine
                // through StreamingDownloadOrchestrator. Avoid calling importCompletedFile to prevent duplicates.

                guard let self else { return }
                self.isExecutingStreaming = false
                self.downloadSuccessNotification = completionMessage
            } catch is CancellationError {
                self?.isExecutingStreaming = false
            } catch {
                self?.isExecutingStreaming = false
                let errorMsg = "Streaming download failed: \(error.localizedDescription)"
                print("[HLS Pipeline] \(errorMsg)")
                self?.streamingErrorMessage = errorMsg
                self?.blobCaptureErrorMessage = errorMsg
            }
        }
    }

    public func cancelStreamingDownload() {
        streamingExecutionTask?.cancel()
        streamingExecutionTask = nil
        if let transferID = streamingProposal?.transferID,
           let orchestrator = streamingOrchestrator {
            Task { await orchestrator.cancel(transferID: transferID) }
        }
        isPreparingStreaming = false
        isExecutingStreaming = false
        isShowingStreamingConfirmation = false
    }

    /// Initiates a background streaming transfer for a specific manifest resource variant.
    public func startStreamingTransfer(
        for resource: WebpageResource,
        customFilename: String? = nil,
        sessionSnapshot: BrowserSessionSnapshot? = nil,
        transportPolicy: HTTPTransportPolicy? = nil
    ) {
        let effectiveOrchestrator = streamingOrchestrator ?? (downloadDelegate as? DownloadManagerViewModel)?.streamingOrchestrator
        guard let orchestrator = effectiveOrchestrator else {
            let errorMsg = "Streaming downloads are unavailable: StreamingDownloadOrchestrator is nil."
            streamingErrorMessage = errorMsg
            blobCaptureErrorMessage = errorMsg
            return
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                await orchestrator.setURLResolver(self)
                let effectivePolicy = transportPolicy ?? self.preferredStreamingTransportPolicy ?? .background
                let candidate = try StreamingManifestCandidate(
                    resource: resource,
                    browserSessionSnapshot: sessionSnapshot,
                    transportPolicy: effectivePolicy
                )
                let proposal = try await orchestrator.prepare(candidate: candidate)
                let destination = self.streamingDestinationDirectoryURL
                let tempAssemblyDir = destination
                    .appendingPathComponent(".assembly_temp_\(UUID().uuidString)", isDirectory: true)
                try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(destination)
                try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(tempAssemblyDir)

                if proposal.transportPolicy == .background, let bgManager = orchestrator.backgroundSessionManager {
                    PipelineLogger.shared.log("[BrowserView] Explicitly scheduling streaming proposal in background URLSession transport...")
                    _ = try? await orchestrator.scheduleBackgroundStreaming(
                        proposal: proposal,
                        destinationDirectory: tempAssemblyDir,
                        backgroundManager: bgManager
                    )
                }

                let targetFilename: String = {
                    let isTextOnly: Bool
                    if case .dash(let plan) = proposal.manifest {
                        isTextOnly = plan.video == nil && plan.audio == nil && plan.text != nil
                    } else {
                        isTextOnly = false
                    }
                    if let custom = customFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                        if isTextOnly {
                            if custom.hasSuffix(".vtt") { return custom }
                            if custom.hasSuffix(".mp4") { return (custom as NSString).deletingPathExtension + ".vtt" }
                            return custom + ".vtt"
                        }
                        return custom.hasSuffix(".mp4") ? custom : custom + ".mp4"
                    }
                    if !resource.suggestedFilename.isEmpty && resource.suggestedFilename != resource.url.lastPathComponent {
                        let f = resource.suggestedFilename
                        if isTextOnly || f.hasSuffix(".vtt") {
                            return f.hasSuffix(".vtt") ? f : (f as NSString).deletingPathExtension + ".vtt"
                        }
                        return f.hasSuffix(".mp4") ? f : f + ".mp4"
                    }
                    switch proposal.manifest {
                    case .hls(let plan): return HLSVODReconstructionPlanner.suggestedFilename(for: plan)
                    case .dash(let plan): return DASHVODReconstructionPlanner.suggestedFilename(for: plan)
                    }
                }()
                let targetURL = destination.appendingPathComponent(targetFilename, isDirectory: false)

                switch proposal.manifest {
                case .hls:
                    _ = try await orchestrator.executeAndAssembleHLS(
                        proposal,
                        approved: true,
                        destinationDirectory: tempAssemblyDir,
                        outputURL: targetURL,
                        progress: { _ in }
                    )
                case .dash:
                    _ = try await orchestrator.executeAndAssembleDASH(
                        proposal,
                        approved: true,
                        destinationDirectory: tempAssemblyDir,
                        outputURL: targetURL,
                        progress: { _ in }
                    )
                }
            } catch {
                let errorMsg = "Streaming transfer failed: \(error.localizedDescription)"
                print("[HLS Pipeline] \(errorMsg)")
                self.streamingErrorMessage = errorMsg
            }
        }
    }

    /// Asynchronously inspects and expands streaming master manifests (HLS and DASH)
    /// into individual selectable video and audio quality resources directly in `discoveredResources`.
    public func expandStreamingManifests(in resources: [WebpageResource]? = nil, tabID: UUID? = nil) {
        let targets = resources ?? discoveredResources
        discoveryCoordinator.discoveredResources = discoveredResources
        discoveryCoordinator.variantStreamItems = variantStreamItems
        discoveryCoordinator.selectedResourceIDs = selectedResourceIDs
        discoveryCoordinator.expandStreamingManifests(in: targets, tabID: tabID, activeTabID: activeTabID)
    }

        // MARK: - Interactive Stream Quality Picker (Phase 3 Milestone 3.1)

    public func presentQualityPicker(for resource: WebpageResource, preloadedOptions: [StreamQualityOption]? = nil) {
        qualityPickerTargetResource = resource
        qualityPickerTargetCandidate = nil
        let baseFilename = resource.suggestedFilename.isEmpty ? "video.mp4" : resource.suggestedFilename
        qualityPickerFilename = baseFilename
        selectedQualityOption = nil
        qualityInspectionError = nil
        isShowingQualityPicker = true

        if let preloaded = preloadedOptions, !preloaded.isEmpty {
            self.qualityPickerOptions = preloaded
            self.selectedQualityOption = preloaded.first
            self.isInspectingQualities = false
            return
        }

        qualityPickerOptions = []
        isInspectingQualities = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let options = try await StreamQualityInspector.inspect(
                    manifestText: resource.manifestText ?? "",
                    url: resource.url,
                    mimeType: resource.mimeType,
                    requestContext: resource.requestContext
                )
                self.qualityPickerOptions = options
                self.selectedQualityOption = options.first
                self.isInspectingQualities = false
            } catch {
                self.qualityInspectionError = error.localizedDescription
                self.isInspectingQualities = false
            }
        }
    }

    public func presentQualityPicker(for candidate: BrowserMediaCandidate, preloadedOptions: [StreamQualityOption]? = nil) {
        qualityPickerTargetCandidate = candidate
        qualityPickerTargetResource = candidate.toWebpageResource()
        let url = candidate.url ?? URL(string: candidate.rawURL)
        let baseFilename = candidate.suggestedFilename.isEmpty ? (url.map { BrowserURLResolver.suggestedFilename(from: $0) } ?? "video.mp4") : candidate.suggestedFilename
        qualityPickerFilename = baseFilename
        selectedQualityOption = nil
        qualityInspectionError = nil
        isShowingQualityPicker = true

        if let preloaded = preloadedOptions, !preloaded.isEmpty {
            self.qualityPickerOptions = preloaded
            self.selectedQualityOption = preloaded.first
            self.isInspectingQualities = false
            return
        }

        qualityPickerOptions = []
        isInspectingQualities = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let targetURL = url else {
                self.qualityInspectionError = "Invalid streaming candidate URL."
                self.isInspectingQualities = false
                return
            }
            do {
                let options = try await StreamQualityInspector.inspect(
                    manifestText: candidate.cachedManifestText ?? "",
                    url: targetURL,
                    mimeType: candidate.mimeType,
                    requestContext: candidate.requestContext
                )
                self.qualityPickerOptions = options
                self.selectedQualityOption = options.first
                self.isInspectingQualities = false
            } catch {
                self.qualityInspectionError = error.localizedDescription
                self.isInspectingQualities = false
            }
        }
    }

    public func selectQualityOption(_ option: StreamQualityOption) {
        selectedQualityOption = option
        let base = (qualityPickerFilename as NSString).deletingPathExtension
        if option.isAudioOnly {
            qualityPickerFilename = "\(base).m4a"
        } else {
            qualityPickerFilename = "\(base).mp4"
        }
    }

    public func confirmQualitySelectionAndDownload() {
        isShowingQualityPicker = false
        let filename = qualityPickerFilename.trimmingCharacters(in: .whitespacesAndNewlines)

        if let resource = qualityPickerTargetResource {
            var prefs = resource.hlsVariantPreferences
            var targetURL = resource.url
            if let selected = selectedQualityOption {
                if selected.manifestKind == .hls {
                    if selected.isAudioOnly {
                        targetURL = selected.uri
                        prefs = nil
                    } else {
                        prefs = HLSVariantSelectionPreferences(
                            maximumBandwidth: Int(selected.bandwidth),
                            maximumWidth: selected.resolution?.width,
                            maximumHeight: selected.resolution?.height,
                            exactURI: selected.uri
                        )
                    }
                }
            }

            let isAudio = selectedQualityOption?.isAudioOnly == true
            let isText = selectedQualityOption?.dashTextRepresentationID != nil || selectedQualityOption?.label.lowercased().contains("subtitle") == true || selectedQualityOption?.label.lowercased().contains("caption") == true
            let effectiveFilename: String
            if !filename.isEmpty {
                effectiveFilename = filename
            } else if !resource.suggestedFilename.isEmpty {
                effectiveFilename = resource.suggestedFilename
            } else {
                effectiveFilename = isText ? "subtitles.vtt" : (isAudio ? "audio.m4a" : "video.mp4")
            }

            let configuredResource = WebpageResource(
                id: resource.id,
                url: targetURL,
                title: effectiveFilename,
                suggestedFilename: effectiveFilename,
                resourceType: isText ? .other : (isAudio ? .audio : .video),
                mimeType: resource.mimeType,
                estimatedSize: selectedQualityOption?.estimatedSizeBytes ?? resource.estimatedSize,
                isSupported: selectedQualityOption?.isLive != true && resource.isSupported,
                unsupportedReason: selectedQualityOption?.isLive == true ? "Live stream recording required; VOD download unsupported for live/event manifests" : resource.unsupportedReason,
                requestContext: resource.requestContext,
                manifestText: (targetURL == resource.url) ? resource.manifestText : nil,
                hlsVariantPreferences: prefs,
                dashVideoRepresentationID: selectedQualityOption?.dashVideoRepresentationID,
                dashAudioRepresentationID: selectedQualityOption?.dashAudioRepresentationID,
                dashTextRepresentationID: selectedQualityOption?.dashTextRepresentationID,
                isDRMProtected: resource.isDRMProtected,
                drmProtectionType: resource.drmProtectionType,
                discoveredAt: resource.discoveredAt,
                isLive: selectedQualityOption?.isLive ?? resource.isLive
            )

            if selectedQualityOption?.isLive == true {
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                let videosDir = docDir.appendingPathComponent("Downloads/Videos", isDirectory: true)
                let destination = videosDir.appendingPathComponent(effectiveFilename)
                let req = LiveRecordingRequest(
                    manifestURL: targetURL,
                    manifestKind: selectedQualityOption?.manifestKind ?? .hls,
                    destinationURL: destination,
                    title: effectiveFilename,
                    requestContext: resource.requestContext,
                    preferredQualityOption: selectedQualityOption
                )
                do {
                    try LiveStreamRecorder.shared.startRecording(request: req)
                    self.downloadSuccessNotification = "Live stream recording started: \(effectiveFilename)"
                } catch {
                    self.streamingErrorMessage = "Live recording error: \(error.localizedDescription)"
                }
                return
            }

            promptStreamingDownload(for: configuredResource, customFilename: effectiveFilename)
        } else if let candidate = qualityPickerTargetCandidate, let url = candidate.url ?? URL(string: candidate.rawURL) {
            var prefs: HLSVariantSelectionPreferences? = nil
            var targetURL = url
            if let selected = selectedQualityOption {
                if selected.manifestKind == .hls {
                    if selected.isAudioOnly {
                        targetURL = selected.uri
                        prefs = nil
                    } else {
                        prefs = HLSVariantSelectionPreferences(
                            maximumBandwidth: Int(selected.bandwidth),
                            maximumWidth: selected.resolution?.width,
                            maximumHeight: selected.resolution?.height,
                            exactURI: selected.uri
                        )
                    }
                }
            }

            let isAudio = selectedQualityOption?.isAudioOnly == true
            let isText = selectedQualityOption?.dashTextRepresentationID != nil || selectedQualityOption?.label.lowercased().contains("subtitle") == true || selectedQualityOption?.label.lowercased().contains("caption") == true
            let effectiveFilename: String
            if !filename.isEmpty {
                effectiveFilename = filename
            } else if !candidate.suggestedFilename.isEmpty {
                effectiveFilename = candidate.suggestedFilename
            } else {
                effectiveFilename = isText ? "subtitles.vtt" : (isAudio ? "audio.m4a" : "video.mp4")
            }

            if selectedQualityOption?.isLive == true {
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                let videosDir = docDir.appendingPathComponent("Downloads/Videos", isDirectory: true)
                let destination = videosDir.appendingPathComponent(effectiveFilename)
                let req = LiveRecordingRequest(
                    manifestURL: targetURL,
                    manifestKind: selectedQualityOption?.manifestKind ?? .hls,
                    destinationURL: destination,
                    title: effectiveFilename,
                    requestContext: candidate.requestContext,
                    preferredQualityOption: selectedQualityOption
                )
                do {
                    try LiveStreamRecorder.shared.startRecording(request: req)
                    self.downloadSuccessNotification = "Live stream recording started: \(effectiveFilename)"
                } catch {
                    self.streamingErrorMessage = "Live recording error: \(error.localizedDescription)"
                }
                return
            }

            let configuredResource = WebpageResource(
                id: candidate.id,
                url: targetURL,
                title: effectiveFilename,
                suggestedFilename: effectiveFilename,
                resourceType: isText ? .other : (isAudio ? .audio : .video),
                mimeType: candidate.mimeType,
                estimatedSize: selectedQualityOption?.estimatedSizeBytes,
                isSupported: true,
                requestContext: candidate.requestContext,
                manifestText: (targetURL == url) ? candidate.cachedManifestText : nil,
                hlsVariantPreferences: prefs,
                dashVideoRepresentationID: selectedQualityOption?.dashVideoRepresentationID,
                dashAudioRepresentationID: selectedQualityOption?.dashAudioRepresentationID,
                dashTextRepresentationID: selectedQualityOption?.dashTextRepresentationID
            )

            promptStreamingDownload(for: configuredResource, customFilename: effectiveFilename)
        }
    }

    // MARK: - Native Content Blocking & Shields (Phase 3 Milestone 3.2)

    public var isCurrentSiteWhitelisted: Bool {
        guard let host = currentURL?.host else { return false }
        return BrowserDomainMatcher.isDomainWhitelisted(host, in: Array(adBlockerWhitelistedDomains))
    }

    public var currentDomainDisplayName: String {
        guard let host = currentURL?.host else { return "Current Website" }
        return BrowserDomainMatcher.normalizeDomain(host)
    }

    public func toggleShieldForCurrentSite() {
        guard let host = currentURL?.host else { return }
        let domain = BrowserDomainMatcher.normalizeDomain(host)
        if adBlockerWhitelistedDomains.contains(domain) {
            adBlockerWhitelistedDomains.remove(domain)
        } else {
            adBlockerWhitelistedDomains.insert(domain)
        }
        persistShieldSettings()
        updateActiveTabBlocker()
        reload()
    }

    public func setAdBlockerEnabled(_ enabled: Bool) {
        isAdBlockerEnabled = enabled
        persistShieldSettings()
        updateActiveTabBlocker()
    }

    public func setTrackerBlockerEnabled(_ enabled: Bool) {
        isTrackerBlockerEnabled = enabled
        persistShieldSettings()
        updateActiveTabBlocker()
    }

    public func setAnnoyanceBlockerEnabled(_ enabled: Bool) {
        isAnnoyanceBlockerEnabled = enabled
        persistShieldSettings()
        updateActiveTabBlocker()
    }

    public func setCookiePolicy(_ policy: BrowserCookiePolicy) {
        cookiePolicy = policy
        persistShieldSettings()
        updateActiveTabBlocker()
    }

    public func setPopupBlockerEnabled(_ enabled: Bool) {
        isPopupBlockerEnabled = enabled
        persistShieldSettings()
    }

    public func persistShieldSettings() {
        var current = AppSettings.load()
        current.isAdBlockerEnabled = isAdBlockerEnabled
        current.isTrackerBlockerEnabled = isTrackerBlockerEnabled
        current.isAnnoyanceBlockerEnabled = isAnnoyanceBlockerEnabled
        current.cookiePolicy = cookiePolicy
        current.isPopupBlockerEnabled = isPopupBlockerEnabled
        current.adBlockerWhitelistedDomains = Array(adBlockerWhitelistedDomains)
        current.save()
        if let vm = downloadDelegate as? DownloadManagerViewModel {
            vm.appSettings = current
        }
    }

    public func updateActiveTabBlocker() {
        #if canImport(WebKit)
        guard let webView = self.webView else { return }
        contentBlocker.update(
            for: webView,
            isAdBlockerEnabled: isAdBlockerEnabled,
            isTrackerBlockerEnabled: isTrackerBlockerEnabled,
            isAnnoyanceBlockerEnabled: isAnnoyanceBlockerEnabled,
            cookiePolicy: cookiePolicy,
            isCurrentDomainWhitelisted: isCurrentSiteWhitelisted
        )
        #endif
    }

    public func reloadSettings(from providedSettings: AppSettings? = nil) {
        let currentSettings = providedSettings ?? (downloadDelegate as? DownloadManagerViewModel)?.appSettings ?? AppSettings.load()
        self.isAdBlockerEnabled = currentSettings.isAdBlockerEnabled
        self.isTrackerBlockerEnabled = currentSettings.isTrackerBlockerEnabled
        self.isAnnoyanceBlockerEnabled = currentSettings.isAnnoyanceBlockerEnabled
        self.cookiePolicy = currentSettings.cookiePolicy
        self.isPopupBlockerEnabled = currentSettings.isPopupBlockerEnabled
        self.adBlockerWhitelistedDomains = Set(currentSettings.adBlockerWhitelistedDomains)
        self.selectedSearchEngine = currentSettings.browserSearchEngine
        self.activeSearchEngineID = currentSettings.activeSearchEngineID
        self.customSearchEngines = currentSettings.customSearchEngines
        self.browserHomepage = currentSettings.browserHomepage
        self.restoreTabsOnLaunch = currentSettings.restoreTabsOnLaunch
        self.readerSettings = BrowserReaderSettings(
            theme: currentSettings.readerTheme,
            fontFamily: currentSettings.readerFontFamily,
            fontSize: currentSettings.readerFontSize
        )
        #if canImport(WebKit)
        Task {
            await contentBlocker.prepareRuleLists(
                whitelistedDomains: currentSettings.adBlockerWhitelistedDomains
            )
        }
        #endif
        updateActiveTabBlocker()
        publishMediaCandidates()
    }

    public func presentMagnetLink(_ magnet: MagnetLink, sourcePageURL: URL?) {
        guard !isShowingMagnetSheet || magnetCandidate?.uri != magnet.uri else { return }
        magnetCandidate = magnet
        magnetSourcePageURL = sourcePageURL.flatMap {
            BrowserURLResolver.isValidWebNavigationURL($0) ? $0 : nil
        }
        magnetErrorMessage = nil
        isShowingMagnetSheet = true
    }

    public var isTorrentEngineAvailable: Bool {
        magnetDelegate?.isTorrentEngineAvailable == true
    }

    public func confirmMagnetLink() async throws {
        guard let magnet = magnetCandidate else {
            throw MagnetLinkError.invalidStructure
        }
        guard let delegate = magnetDelegate, delegate.isTorrentEngineAvailable else {
            throw MagnetLinkError.torrentEngineUnavailable
        }
        try await delegate.handleMagnetLink(magnet)
        magnetErrorMessage = nil
        isShowingMagnetSheet = false
        magnetCandidate = nil
        magnetSourcePageURL = nil
    }

    @discardableResult
    public func openMagnetExternally() -> Bool {
        guard let url = magnetCandidate?.uri else { return false }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        return true
        #elseif canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }

    // MARK: - Safari-Style Reader Mode (Milestone B.3)

    public func toggleReaderMode() {
        if isShowingReaderMode {
            closeReaderMode()
            return
        }
        #if canImport(WebKit)
        guard let webView, currentURL != nil else {
            readerFeedbackBanner = "Reader Mode is not available for this page."
            return
        }
        isExtractingReaderArticle = true
        webView.evaluateJavaScript(BrowserReaderExtractor.extractionScript) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExtractingReaderArticle = false
                if let dict = result as? [String: Any],
                   let article = BrowserReaderExtractor.parseExtraction(jsonDict: dict, sourceURL: self.currentURL) {
                    self.readerArticle = article
                    self.isShowingReaderMode = true
                } else {
                    let reason = (result as? [String: Any])?["reason"] as? String
                        ?? "Reader Mode is not available for this page."
                    self.readerFeedbackBanner = reason
                }
            }
        }
        #else
        readerFeedbackBanner = "Reader Mode requires WebKit runtime."
        #endif
    }

    public func closeReaderMode() {
        isShowingReaderMode = false
    }

    // MARK: - Find in Page (Milestone B.3)

    public func openFindInPage() {
        isShowingFindInPage = true
    }

    public func closeFindInPage() {
        isShowingFindInPage = false
        findInPageQuery = ""
        findInPageResult = BrowserFindInPageResult()
        #if canImport(WebKit)
        webView?.evaluateJavaScript(BrowserFindInPageEngine.clearHighlightsScript, completionHandler: nil)
        #endif
    }

    public func updateFindInPageQuery(_ query: String) {
        findInPageQuery = query
        #if canImport(WebKit)
        guard let webView else { return }
        let script = BrowserFindInPageEngine.searchScript(query: query)
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            let res = BrowserFindInPageEngine.parseResult(from: result as? [String: Any])
            DispatchQueue.main.async {
                self?.findInPageResult = res
            }
        }
        #endif
    }

    public func findInPageNext() {
        #if canImport(WebKit)
        guard let webView else { return }
        webView.evaluateJavaScript(BrowserFindInPageEngine.nextMatchScript) { [weak self] result, _ in
            let res = BrowserFindInPageEngine.parseResult(from: result as? [String: Any])
            DispatchQueue.main.async {
                self?.findInPageResult = res
            }
        }
        #endif
    }

    public func findInPagePrevious() {
        #if canImport(WebKit)
        guard let webView else { return }
        webView.evaluateJavaScript(BrowserFindInPageEngine.previousMatchScript) { [weak self] result, _ in
            let res = BrowserFindInPageEngine.parseResult(from: result as? [String: Any])
            DispatchQueue.main.async {
                self?.findInPageResult = res
            }
        }
        #endif
    }

    // MARK: - Webpage & Link Sharing (Milestone B.3)

    public func shareCurrentPage() {
        guard let url = currentURL else { return }
        let title = pageTitle.isEmpty ? (url.host ?? "Webpage") : pageTitle
        shareItems = [url, title]
        isShowingShareSheet = true
    }

    public func shareURL(_ url: URL, title: String? = nil) {
        let effectiveTitle = title ?? url.host ?? "Link"
        shareItems = [url, effectiveTitle]
        isShowingShareSheet = true
    }

    /// Rescans resources on the current webpage, preserving live streams, manifests, and MSE/blob candidates.
    public func rescanResources(includeNonVideo: Bool = false) {
        inspectCurrentPageResources(includeNonVideo: includeNonVideo)
    }

    /// Rescans resources on the current webpage, preserving live streams, manifests, and MSE/blob candidates.
    public func rescanCurrentPageResources(includeNonVideo: Bool = false) {
        inspectCurrentPageResources(includeNonVideo: includeNonVideo)
    }

    public func inspectCurrentPageResources(includeNonVideo: Bool = false) {
        #if canImport(WebKit)
        guard let wv = webView else {
            isScanningResources = false
            resourceScanError = "Web browser engine is not ready."
            return
        }
        discoveryCoordinator.inspectCurrentPageResources(
            currentURL: currentURL,
            activeTabID: activeTabID,
            includeNonVideo: includeNonVideo,
            evaluateScript: { script, completion in
                wv.evaluateJavaScript(script, completionHandler: completion)
            },
            captureContexts: { [weak self] resources, pageURL, completion in
                guard let self = self else {
                    completion(resources)
                    return
                }
                self.captureRequestContexts(for: resources, pageURL: pageURL, webView: wv, completion: completion)
            }
        )
        #else
        discoveryCoordinator.inspectCurrentPageResources(
            currentURL: currentURL,
            activeTabID: activeTabID,
            includeNonVideo: includeNonVideo,
            evaluateScript: nil
        )
        #endif
    }

    fileprivate func handleMediaDiscoveryObservation(
        _ observation: BrowserMediaDiscoveryObservation,
        tabID: UUID? = nil
    ) {
        let enrichedObservation: BrowserMediaDiscoveryObservation
        if let targetTabID = tabID ?? activeTabID {
            let docGen = observation.documentGeneration ?? discoveryCoordinator.currentDocumentGeneration(for: targetTabID)
            let navGen = observation.navigationGeneration ?? currentNavigationGeneration(for: targetTabID)
            enrichedObservation = BrowserMediaDiscoveryObservation(
                url: observation.url,
                rawURL: observation.rawURL,
                source: observation.source,
                tag: observation.tag,
                declaredType: observation.declaredType,
                eventID: observation.eventID,
                responseURL: observation.responseURL,
                method: observation.method,
                statusCode: observation.statusCode,
                contentLength: observation.contentLength,
                manifestKind: observation.manifestKind,
                manifestPrefix: observation.manifestPrefix,
                documentID: observation.documentID,
                appendedByteCount: observation.appendedByteCount,
                isPotentiallyProtected: observation.isPotentiallyProtected,
                pageOrigin: observation.pageOrigin,
                frameOrigin: observation.frameOrigin,
                mayUseBrowserCredentials: observation.mayUseBrowserCredentials,
                blobKind: observation.blobKind,
                width: observation.width,
                height: observation.height,
                duration: observation.duration,
                codecs: observation.codecs,
                documentGeneration: docGen,
                navigationGeneration: navGen
            )
        } else {
            enrichedObservation = observation
        }
        discoveryCoordinator.handleMediaDiscoveryObservation(
            enrichedObservation,
            tabID: tabID,
            activeTabID: activeTabID,
            currentURL: currentURL,
            streamingOrchestrator: streamingOrchestrator
        )
    }

    private func publishMediaCandidates() {
        discoveryCoordinator.publishMediaCandidates(activeTabID: activeTabID)
    }

    private func ingestMediaObservation(
        _ observation: BrowserMediaDiscoveryObservation,
        tabID: UUID?
    ) {
        discoveryCoordinator.ingestMediaObservation(observation, tabID: tabID, activeTabID: activeTabID)
    }

    public func ingestMediaResources(
        _ resources: [WebpageResource],
        tabID: UUID? = nil,
        updateCatalog: Bool = true
    ) {
        discoveryCoordinator.ingestMediaResources(
            resources,
            tabID: tabID,
            activeTabID: activeTabID,
            updateCatalog: updateCatalog
        )
    }

    public func ingestMediaResource(
        _ resource: WebpageResource,
        tabID: UUID? = nil
    ) {
        discoveryCoordinator.ingestMediaResource(resource, tabID: tabID, activeTabID: activeTabID)
    }

    public func ingestMediaCandidates(
        _ candidates: [BrowserMediaCandidate],
        tabID: UUID? = nil
    ) {
        discoveryCoordinator.ingestMediaCandidates(candidates, tabID: tabID, activeTabID: activeTabID)
    }

    public func ingestMediaCandidate(
        _ candidate: BrowserMediaCandidate,
        tabID: UUID? = nil
    ) {
        discoveryCoordinator.ingestMediaCandidate(candidate, tabID: tabID, activeTabID: activeTabID)
    }

    public static func isPreservedCandidateOnRescan(_ candidate: BrowserMediaCandidate) -> Bool {
        BrowserResourceDiscoveryCoordinator.isPreservedCandidateOnRescan(candidate)
    }

    public func resetMediaCandidateCatalog(for tabID: UUID? = nil) {
        discoveryCoordinator.resetMediaCandidateCatalog(for: tabID, activeTabID: activeTabID)
    }

        #if canImport(WebKit)
    /// Captures only cookies that can match each discovered resource. The WebKit
    /// store is never copied into the download engine wholesale.
    private func captureRequestContexts(
        for resources: [WebpageResource],
        pageURL: URL,
        webView: WKWebView,
        completion: @escaping ([WebpageResource]) -> Void
    ) {
        let userAgentScript = "navigator.userAgent"
        webView.evaluateJavaScript(userAgentScript) { [weak self] result, _ in
            guard self != nil else { return }
            let userAgent = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let browserCookies = cookies.compactMap(BrowserCookie.init(from:))
                let contextualResources = resources.map { resource in
                    guard resource.isSupported || resource.isStreamingManifest else { return resource }
                    let matchingCookies = browserCookies.filter { $0.matches(url: resource.url) }
                    let context = BrowserRequestContext(
                        url: resource.url,
                        pageURL: pageURL,
                        userAgent: userAgent,
                        cookies: matchingCookies,
                        source: .webpageResource
                    )
                    return WebpageResource(
                        id: resource.id,
                        url: resource.url,
                        title: resource.title,
                        suggestedFilename: resource.suggestedFilename,
                        resourceType: resource.resourceType,
                        mimeType: resource.mimeType,
                        estimatedSize: resource.estimatedSize,
                        isSupported: resource.isSupported,
                        unsupportedReason: resource.unsupportedReason,
                        requestContext: context,
                        manifestText: resource.manifestText
                    )
                }
                DispatchQueue.main.async {
                    completion(contextualResources)
                }
            }
        }
    }

    public func captureBrowserRequestContext(
        for resourceURL: URL,
        pageURL: URL?,
        webView: WKWebView,
        source: BrowserRequestContextSource,
        customHeaders: [String: String] = [:],
        allowedCredentialOrigins: Set<String> = [],
        completion: @escaping (BrowserRequestContext?) -> Void
    ) {
        let page = pageURL ?? webView.url
        webView.evaluateJavaScript("navigator.userAgent") { result, _ in
            let userAgent = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let sessionCookies = cookies.compactMap(BrowserCookie.init(from:))
                let context = BrowserRequestContext(
                    url: resourceURL,
                    pageURL: page,
                    userAgent: userAgent,
                    cookies: sessionCookies,
                    customHeaders: BrowserHeaderFilter.sanitizeHeaders(customHeaders).filter {
                        let key = $0.key.lowercased()
                        return BrowserHeaderFilter.isApprovedForwardedHeader(key) &&
                            key != "cookie" && key != "referer" && key != "user-agent"
                    },
                    source: source,
                    allowedCredentialOrigins: allowedCredentialOrigins
                )
                DispatchQueue.main.async {
                    completion(context)
                }
            }
        }
    }
    #endif

    public func downloadSelectedResources() async throws {
        let targets = discoveredResources.filter { res in
            let isEligibleManifest = res.isStreamingManifest && res.resourceType != .other && res.unsupportedReason == nil
            return (res.isSupported || isEligibleManifest) && selectedResourceIDs.contains(res.id)
        }

        guard !targets.isEmpty else { return }

        #if canImport(WebKit)
        let sessionSnapshot: BrowserSessionSnapshot?
        if let wv = self.webView {
            sessionSnapshot = await DownloadRequestEnricher.snapshot(from: wv)
        } else {
            sessionSnapshot = nil
        }
        #else
        let sessionSnapshot: BrowserSessionSnapshot? = nil
        #endif

        for resource in targets {
            var resContext = resource.requestContext
            if resContext == nil, let snapshot = sessionSnapshot {
                let matchedCookies = snapshot.allCookies.compactMap { BrowserCookie(from: $0) }
                resContext = BrowserRequestContext(
                    url: resource.url,
                    pageURL: snapshot.pageURL ?? currentURL,
                    userAgent: snapshot.userAgent.isEmpty ? nil : snapshot.userAgent,
                    cookies: matchedCookies,
                    source: .webpageResource,
                    allowedCredentialOrigins: resource.requestContext?.allowedCredentialOrigins ?? []
                )
            }

            let decision = BrowserDownloadDecisionPipeline.decide(
                resource: resource,
                availableResources: self.discoveredResources,
                availableCandidates: self.mediaCandidates,
                preferManifestIfAvailable: true
            )

            switch decision.action {
            case .streaming(let manifestURL, _, let suggestedFilename, let cachedText, let requestContext):
                if streamingOrchestrator == nil && (downloadDelegate as? DownloadManagerViewModel)?.streamingOrchestrator == nil {
                    let errorMsg = "Streaming downloads are unavailable: StreamingDownloadOrchestrator is nil."
                    blobCaptureErrorMessage = errorMsg
                    streamingErrorMessage = errorMsg
                    return
                }
                let effectiveFilename: String = {
                    if !resource.suggestedFilename.isEmpty && resource.suggestedFilename != manifestURL.lastPathComponent {
                        return resource.suggestedFilename
                    }
                    if !decision.candidate.suggestedFilename.isEmpty {
                        return decision.candidate.suggestedFilename
                    }
                    return suggestedFilename
                }()
                let res = WebpageResource(
                    id: resource.id,
                    url: manifestURL,
                    title: resource.title,
                    suggestedFilename: effectiveFilename,
                    resourceType: resource.resourceType,
                    mimeType: resource.mimeType,
                    estimatedSize: resource.estimatedSize,
                    isSupported: true,
                    requestContext: requestContext ?? resContext ?? decision.candidate.requestContext,
                    manifestText: cachedText ?? resource.manifestText,
                    hlsVariantPreferences: resource.hlsVariantPreferences,
                    dashVideoRepresentationID: resource.dashVideoRepresentationID,
                    dashAudioRepresentationID: resource.dashAudioRepresentationID,
                    dashTextRepresentationID: resource.dashTextRepresentationID,
                    isDRMProtected: resource.isDRMProtected,
                    drmProtectionType: resource.drmProtectionType,
                    discoveredAt: resource.discoveredAt,
                    isLive: resource.isLive
                )
                if targets.count == 1 {
                    promptStreamingDownload(for: res, customFilename: effectiveFilename)
                } else {
                    startStreamingTransfer(for: res, customFilename: effectiveFilename, sessionSnapshot: sessionSnapshot)
                }

            case .blobExport(let candidate):
                #if canImport(WebKit)
                exportBlobCandidate(candidate)
                #endif

            case .mseCapture(let candidate):
                #if canImport(WebKit)
                startMSECapture(candidate)
                #endif

            case .direct(let url, let suggestedFilename, _, _, let requestContext):
                do {
                    if decision.candidate.kind == .directMedia {
                        let plan = try DirectMediaTransferPlanner.makePlan(candidate: decision.candidate)
                        let headers = useBrowserCredentials
                            ? (plan.requestHeaders.isEmpty ? nil : plan.requestHeaders)
                            : nil
                        try await downloadDelegate?.handleDownloadRequest(
                            url: plan.transferURL,
                            filename: plan.filename.isEmpty ? nil : plan.filename,
                            threadCount: 6,
                            speedLimitBytesPerSecond: nil,
                            headers: headers
                        )
                        continue
                    }
                    try await downloadDelegate?.handleDownloadRequest(
                        url: url,
                        filename: suggestedFilename.isEmpty ? nil : suggestedFilename,
                        threadCount: 6,
                        speedLimitBytesPerSecond: nil,
                        headers: (requestContext ?? resContext)?.effectiveHeaders(
                            for: url,
                            includeCredentials: useBrowserCredentials
                        )
                    )
                } catch {
                    blobCaptureErrorMessage = "Engine error: \(error.localizedDescription)"
                }

            case .protectedMedia(let reason), .unsupported(let reason):
                blobCaptureErrorMessage = reason
                streamingErrorMessage = reason
            }
        }

        selectedResourceIDs = []
        isShowingResourceInspector = false
        downloadSuccessNotification = "\(targets.count) download(s) queued successfully."
        onDownloadInitiated?()
    }

    /// Converts one discovered browser resource into a streaming proposal. The
    /// caller owns user confirmation and execution; ordinary HTTP resources keep
    /// using `downloadSelectedResources()` and the existing download delegate.
    public func prepareStreamingProposal(
        for resource: WebpageResource,
        using orchestrator: StreamingDownloadOrchestrator,
        transportPolicy: HTTPTransportPolicy? = nil
    ) async throws -> StreamingTransferProposal {
        let effectivePolicy = transportPolicy ?? preferredStreamingTransportPolicy ?? .background
        let candidate = try StreamingManifestCandidate(resource: resource, transportPolicy: effectivePolicy)
        return try await orchestrator.prepare(candidate: candidate)
    }

    public func navigate(to input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let url = BrowserURLResolver.resolve(input: trimmed, template: currentSearchEngineTemplate) else {
            errorMessage = "Invalid or unsupported web address. Only HTTP and HTTPS are permitted."
            return
        }

        load(url: url)
    }

    public func load(url: URL) {
        allowURLInBrowser(url)
        errorMessage = nil
        let targetTabID: UUID
        if let existingID = tabManager.activeTabID {
            targetTabID = existingID
        } else {
            targetTabID = tabManager.createTab(select: true)
            publishTabState()
        }
        cancelInFlightProbes(for: targetTabID)
        resetMediaDiscovery(for: targetTabID)
        setToolbarCollapsed(false)
        guard var tab = tabManager.tab(withID: targetTabID) else { return }
        tab.url = url
        tab.isLoading = true
        tab.estimatedProgress = 0
        tab.title = tab.title == "New Tab" ? "Loading…" : tab.title
        _ = tabManager.updateTab(tab)
        publishTabState()
        syncActiveTabState()

        #if canImport(WebKit)
        let gen = nextNavigationGeneration(for: targetTabID, target: url)
        if let session = tabSessions[targetTabID] {
            session.coordinator.startNavigation(generation: gen, target: url)
        }
        pendingNavigationURLs[targetTabID] = url
        if let webView {
            _ = consumePendingNavigation(for: targetTabID) { request in
                webView.load(request)
            }
        }
        #endif
    }

    #if canImport(WebKit)
    /// Loads an inline HTML5 player for an HLS stream directly into the active or specified tab,
    /// keeping the browser tab alive and preventing WebKit from launching the native full-screen player.
    public func loadInlineHLSPlayer(
        for url: URL,
        title: String? = nil,
        in webView: WKWebView,
        tabID: UUID? = nil
    ) {
        let displayTitle: String
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            displayTitle = title
        } else {
            let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            displayTitle = last.isEmpty ? (url.host ?? "HLS Stream") : last
        }

        let html = BrowserHLSInlinePlayer.html(for: url, title: displayTitle)
        webView.loadHTMLString(html, baseURL: url)

        let targetTabID = tabID ?? activeTabID
        if let targetTabID = targetTabID {
            updateWebViewState(
                for: targetTabID,
                webView: webView,
                url: url,
                title: displayTitle,
                isLoading: false
            )
        } else {
            currentURL = url
            urlInputText = url.absoluteString
            pageTitle = displayTitle
            isLoading = false
        }

        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Loaded inline HLS player for \(url.absoluteString)",
            url: url,
            tabID: targetTabID
        )
    }

    /// Convenience method to load the inline HLS player in the current tab session.
    public func loadInlineHLSPlayer(
        for url: URL,
        title: String? = nil,
        tabID: UUID? = nil
    ) {
        let targetTabID = tabID ?? activeTabID
        let targetWebView: WKWebView?
        if let targetTabID, let session = tabSessions[targetTabID] {
            targetWebView = session.webView
        } else {
            targetWebView = self.webView
        }
        if let wv = targetWebView {
            loadInlineHLSPlayer(for: url, title: title, in: wv, tabID: targetTabID)
        }
    }
    #endif

    public func goBack() {
        errorMessage = nil
        #if canImport(WebKit)
        webView?.goBack()
        #endif
    }

    public func goForward() {
        errorMessage = nil
        #if canImport(WebKit)
        webView?.goForward()
        #endif
    }

    public func reload() {
        errorMessage = nil
        #if canImport(WebKit)
        if let wv = webView, wv.url != nil {
            wv.reload()
        } else if let url = currentURL {
            load(url: url)
        }
        #endif
    }

    public func stopLoading() {
        #if canImport(WebKit)
        webView?.stopLoading()
        #endif
        isLoading = false
    }

    public func goHome() {
        #if canImport(WebKit)
        webView?.stopLoading()
        if let blank = URL(string: "about:blank") {
            webView?.load(URLRequest(url: blank))
        }
        if let activeTabID {
            pendingNavigationURLs.removeValue(forKey: activeTabID)
        }
        webView = nil
        #endif
        if let activeTabID,
           var tab = tabManager.tab(withID: activeTabID) {
            tab.url = nil
            tab.title = "New Tab"
            tab.isLoading = false
            tab.canGoBack = false
            tab.canGoForward = false
            tab.estimatedProgress = 0
            _ = tabManager.updateTab(tab)
        }
        currentURL = nil
        urlInputText = ""
        pageTitle = ""
        publishTabState()
        syncActiveTabState()
        if let activeTabID {
            resetMediaDiscovery(for: activeTabID)
        } else {
            resetMediaCandidateCatalog(for: activeTabID)
            discoveredResources = []
            variantStreamItems = [:]
            selectedResourceIDs = []
        }
        setToolbarCollapsed(false)
        errorMessage = nil
    }

    public func prepareDownloadCurrentURL() {
        guard let url = currentURL, BrowserURLResolver.isValidDownloadURL(url) else {
            errorMessage = "The current page URL cannot be downloaded directly."
            return
        }

        #if canImport(WebKit)
        if let wv = webView {
            captureBrowserRequestContext(
                for: url,
                pageURL: wv.url ?? currentURL,
                webView: wv,
                source: .directLink
            ) { [weak self] context in
                guard let self = self else { return }
                self.handleNativeDownloadHandoff(
                    originalURL: url,
                    finalURL: url,
                    suggestedFilename: BrowserURLResolver.suggestedFilename(from: url),
                    source: .manualUserAction,
                    requestContext: context
                )
            }
            return
        }
        #endif

        downloadCandidateURL = url
        downloadCandidateFilename = BrowserURLResolver.suggestedFilename(from: url)
        downloadCandidateRequestContext = nil
        useBrowserCredentials = false
        downloadCandidateThreads = 6
        downloadCandidateSpeedLimitKBps = ""
        isShowingDownloadSheet = true
    }

    public func executeDownload() async throws {
        guard let url = downloadCandidateURL else { return }
        let customFilename = downloadCandidateFilename.trimmingCharacters(in: .whitespacesAndNewlines)

        #if canImport(WebKit)
        let sessionSnapshot: BrowserSessionSnapshot?
        if let wv = webView {
            sessionSnapshot = await DownloadRequestEnricher.snapshot(from: wv)
        } else {
            sessionSnapshot = nil
        }
        #else
        let sessionSnapshot: BrowserSessionSnapshot? = nil
        #endif

        var effectiveContext = downloadCandidateRequestContext
        if effectiveContext == nil, let snapshot = sessionSnapshot {
            let matchedCookies = snapshot.allCookies.compactMap { BrowserCookie(from: $0) }
            effectiveContext = BrowserRequestContext(
                url: url,
                pageURL: snapshot.pageURL ?? currentURL,
                userAgent: snapshot.userAgent.isEmpty ? nil : snapshot.userAgent,
                cookies: matchedCookies,
                source: .nativeInterception
            )
            downloadCandidateRequestContext = effectiveContext
        }

        // Dedicated direct execution for pre-selected streaming variants (HLS / DASH)
        if let res = activeDownloadResource, res.hlsVariantPreferences != nil || res.dashVideoRepresentationID != nil {
            isShowingDownloadSheet = false
            let finalFilename = customFilename.isEmpty ? res.suggestedFilename : customFilename
            activeStreamingFilename = finalFilename

            let isLive = res.isLive || (self.variantStreamItems[res.id]?.isLive == true)
            if isLive {
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                let videosDir = docDir.appendingPathComponent("Downloads/Videos", isDirectory: true)
                let destination = videosDir.appendingPathComponent(finalFilename)
                let req = LiveRecordingRequest(
                    manifestURL: res.hlsVariantPreferences?.exactURI ?? res.url,
                    manifestKind: (res.url.pathExtension.lowercased() == "mpd") ? .dash : .hls,
                    destinationURL: destination,
                    title: finalFilename,
                    requestContext: res.requestContext ?? effectiveContext,
                    preferredQualityOption: nil
                )
                do {
                    try LiveStreamRecorder.shared.startRecording(request: req)
                    self.downloadSuccessNotification = "Live stream recording started: \(finalFilename)"
                } catch {
                    self.streamingErrorMessage = "Live recording error: \(error.localizedDescription)"
                }
                return
            }

            let configuredResource = WebpageResource(
                id: res.id,
                url: res.url,
                title: finalFilename,
                suggestedFilename: finalFilename,
                resourceType: res.resourceType,
                mimeType: res.mimeType,
                estimatedSize: res.estimatedSize,
                isSupported: true,
                requestContext: res.requestContext ?? effectiveContext,
                manifestText: res.manifestText,
                hlsVariantPreferences: res.hlsVariantPreferences,
                dashVideoRepresentationID: res.dashVideoRepresentationID,
                dashAudioRepresentationID: res.dashAudioRepresentationID,
                dashTextRepresentationID: res.dashTextRepresentationID,
                isDRMProtected: res.isDRMProtected,
                drmProtectionType: res.drmProtectionType,
                discoveredAt: res.discoveredAt,
                isLive: false
            )
            promptStreamingDownload(for: configuredResource, customFilename: finalFilename)
            return
        }

        // 1. Resolve candidate through BrowserDownloadDecisionPipeline
        let candidate: BrowserMediaCandidate
        if let active = activeDownloadCandidate {
            candidate = active
        } else if let resource = activeDownloadResource {
            candidate = BrowserMediaCandidateClassifier.classify(resource: resource)
        } else if let matched = mediaCandidates.first(where: {
            $0.url == url || $0.rawURL.caseInsensitiveCompare(url.absoluteString) == .orderedSame
        }) {
            candidate = matched
        } else if let matchedResource = discoveredResources.first(where: { $0.url == url }) {
            candidate = BrowserMediaCandidateClassifier.classify(resource: matchedResource)
        } else {
            let isBlob = url.scheme?.lowercased() == "blob"
            let manifest = StreamingManifestClassifier.classify(url: url)
            let kind: BrowserMediaCandidateKind
            let blobKind: BlobKind?
            if isBlob {
                kind = .completeBlob
                blobKind = .blob
            } else if manifest.isManifest || url.pathExtension.lowercased() == "m3u8" {
                kind = .hlsManifest
                blobKind = nil
            } else if url.pathExtension.lowercased() == "mpd" {
                kind = .dashManifest
                blobKind = nil
            } else {
                kind = .directMedia
                blobKind = nil
            }
            candidate = BrowserMediaCandidate(
                id: BrowserMediaCandidateClassifier.stableIdentity(rawURL: url.absoluteString, url: url),
                url: url,
                rawURL: url.absoluteString,
                kind: kind,
                blobKind: blobKind,
                suggestedFilename: customFilename.isEmpty ? BrowserURLResolver.suggestedFilename(from: url) : customFilename,
                availability: .downloadable,
                evidence: ["User confirmed from download sheet"],
                requestContext: effectiveContext
            )
        }

        let decision = BrowserDownloadDecisionPipeline.decide(
            candidate: candidate,
            availableResources: discoveredResources,
            availableCandidates: mediaCandidates,
            preferManifestIfAvailable: true
        )

        switch decision.action {
        case .protectedMedia(let reason):
            isShowingDownloadSheet = false
            streamingErrorMessage = reason
            blobCaptureErrorMessage = reason
            mseCaptureErrorMessage = reason
            return

        case .unsupported(let reason):
            isShowingDownloadSheet = false
            streamingErrorMessage = reason
            blobCaptureErrorMessage = reason
            mseCaptureErrorMessage = reason
            return

        case .streaming(let manifestURL, _, let suggestedFilename, let cachedText, let requestContext):
            isShowingDownloadSheet = false
            let finalFilename = customFilename.isEmpty ? suggestedFilename : customFilename
            activeStreamingFilename = finalFilename
            let res = WebpageResource(
                url: manifestURL,
                title: finalFilename,
                suggestedFilename: finalFilename,
                resourceType: .video,
                requestContext: requestContext ?? effectiveContext,
                manifestText: cachedText,
                hlsVariantPreferences: activeDownloadResource?.hlsVariantPreferences,
                dashVideoRepresentationID: activeDownloadResource?.dashVideoRepresentationID,
                dashAudioRepresentationID: activeDownloadResource?.dashAudioRepresentationID,
                dashTextRepresentationID: activeDownloadResource?.dashTextRepresentationID,
                isDRMProtected: activeDownloadResource?.isDRMProtected ?? false,
                drmProtectionType: activeDownloadResource?.drmProtectionType,
                discoveredAt: activeDownloadResource?.discoveredAt ?? Date(),
                isLive: activeDownloadResource?.isLive ?? false
            )
            promptStreamingDownload(for: res, customFilename: finalFilename)
            return

        case .mseCapture(let mseCandidate):
            isShowingDownloadSheet = false
            var configuredCandidate = mseCandidate
            if !customFilename.isEmpty {
                configuredCandidate = BrowserMediaCandidate(
                    id: mseCandidate.id,
                    url: mseCandidate.url,
                    rawURL: mseCandidate.rawURL,
                    finalURL: mseCandidate.finalURL,
                    kind: mseCandidate.kind,
                    blobKind: mseCandidate.blobKind,
                    mimeType: mseCandidate.mimeType,
                    suggestedFilename: customFilename,
                    estimatedSize: mseCandidate.estimatedSize,
                    availability: mseCandidate.availability,
                    evidence: mseCandidate.evidence,
                    documentID: mseCandidate.documentID,
                    requestContext: mseCandidate.requestContext ?? effectiveContext,
                    associatedManifestID: mseCandidate.associatedManifestID,
                    associatedManifestURL: mseCandidate.associatedManifestURL,
                    cachedManifestText: mseCandidate.cachedManifestText,
                    lastObserved: mseCandidate.lastObserved,
                    isLive: mseCandidate.isLive,
                    width: mseCandidate.width,
                    height: mseCandidate.height,
                    duration: mseCandidate.duration,
                    codecs: mseCandidate.codecs,
                    audioLanguage: mseCandidate.audioLanguage
                )
            }
            #if canImport(WebKit)
            startMSECapture(configuredCandidate)
            #else
            mseCaptureErrorMessage = "MSE capture requires WebKit."
            #endif
            return

        case .blobExport(let blobCandidate):
            isShowingDownloadSheet = false
            var configuredCandidate = blobCandidate
            if !customFilename.isEmpty {
                configuredCandidate = BrowserMediaCandidate(
                    id: blobCandidate.id,
                    url: blobCandidate.url,
                    rawURL: blobCandidate.rawURL,
                    finalURL: blobCandidate.finalURL,
                    kind: blobCandidate.kind,
                    blobKind: blobCandidate.blobKind,
                    mimeType: blobCandidate.mimeType,
                    suggestedFilename: customFilename,
                    estimatedSize: blobCandidate.estimatedSize,
                    availability: blobCandidate.availability,
                    evidence: blobCandidate.evidence,
                    documentID: blobCandidate.documentID,
                    requestContext: blobCandidate.requestContext ?? effectiveContext,
                    associatedManifestID: blobCandidate.associatedManifestID,
                    associatedManifestURL: blobCandidate.associatedManifestURL,
                    cachedManifestText: blobCandidate.cachedManifestText,
                    lastObserved: blobCandidate.lastObserved,
                    isLive: blobCandidate.isLive,
                    width: blobCandidate.width,
                    height: blobCandidate.height,
                    duration: blobCandidate.duration,
                    codecs: blobCandidate.codecs,
                    audioLanguage: blobCandidate.audioLanguage
                )
            }
            #if canImport(WebKit)
            exportBlobCandidate(configuredCandidate)
            #else
            blobCaptureErrorMessage = "Blob export requires WebKit."
            #endif
            downloadSuccessNotification = "Blob export started: \(configuredCandidate.suggestedFilename)"
            onDownloadInitiated?()
            return

        case .direct(let directURL, let suggestedFilename, _, _, let requestContext):
            let limit: Int64?
            if let kb = Int64(downloadCandidateSpeedLimitKBps), kb > 0 {
                limit = kb * 1024
            } else {
                limit = nil
            }

            let finalFilename = customFilename.isEmpty ? suggestedFilename : customFilename
            let effectiveHeaders = (requestContext ?? effectiveContext)?.effectiveHeaders(
                for: directURL,
                includeCredentials: useBrowserCredentials
            )

            // Suspicious download evaluation (Milestone B.2)
            if let warning = BrowserDownloadSecurityInspector.evaluate(url: directURL, declaredFilename: finalFilename) {
                isShowingDownloadSheet = false
                self.suspiciousDownloadPrompt = BrowserSuspiciousDownloadPrompt(
                    warning: warning,
                    onProceed: { [weak self] in
                        guard let self else { return }
                        Task { @MainActor in
                            self.suspiciousDownloadPrompt = nil
                            try? await self.downloadDelegate?.handleDownloadRequest(
                                url: directURL,
                                filename: finalFilename.isEmpty ? nil : finalFilename,
                                threadCount: self.downloadCandidateThreads,
                                speedLimitBytesPerSecond: limit,
                                headers: effectiveHeaders
                            )
                            self.downloadSuccessNotification = "Download queued: \(finalFilename)"
                            self.onDownloadInitiated?()
                        }
                    },
                    onCancel: { [weak self] in
                        Task { @MainActor in
                            self?.suspiciousDownloadPrompt = nil
                        }
                    }
                )
                return
            }

            do {
                try await downloadDelegate?.handleDownloadRequest(
                    url: directURL,
                    filename: finalFilename.isEmpty ? nil : finalFilename,
                    threadCount: downloadCandidateThreads,
                    speedLimitBytesPerSecond: limit,
                    headers: effectiveHeaders
                )
                isShowingDownloadSheet = false
                downloadSuccessNotification = "Download queued: \(finalFilename)"
                onDownloadInitiated?()
            } catch {
                isShowingDownloadSheet = false
                blobCaptureErrorMessage = "Engine error: \(error.localizedDescription)"
                throw error
            }
        }
    }

    public var userScriptManager: BrowserMediaDiscoveryBridge.UserScriptManager {
        mediaDiscoveryBridge.userScriptManager
    }

    @MainActor
    public func resolveMediaURL(_ rawURL: URL) async throws -> URL {
        #if canImport(WebKit)
        let activeWebView = self.webView ?? (activeTabID.flatMap { tabSessions[$0]?.webView })
        guard let activeWebView else { return rawURL }
        return await mediaDiscoveryBridge.resolveMediaURL(rawURL, on: activeWebView)
        #else
        return rawURL
        #endif
    }

    @MainActor
    public func fetchManifestText(from url: URL) async throws -> String {
        try await fetchManifestText(from: url, maxBytes: 1_048_576)
    }

    @MainActor
    public func fetchManifestText(from url: URL, maxBytes: Int) async throws -> String {
        #if canImport(WebKit)
        let activeWebView = self.webView ?? (activeTabID.flatMap { tabSessions[$0]?.webView })
        guard let activeWebView else {
            throw StreamingManifestLoadError.browserFetchUnavailable
        }
        return try await mediaDiscoveryBridge.fetchManifestText(from: url, on: activeWebView, maxBytes: maxBytes)
        #else
        throw StreamingManifestLoadError.browserFetchUnavailable
        #endif
    }
}

extension BrowserViewModel: BrowserMediaURLResolver, BrowserPermissionProviding {
    public func requestPermission(
        type: BrowserPermissionType,
        originHost: String,
        frameURL: URL?,
        completionHandler: @escaping @Sendable (BrowserPermissionDecisionResult) -> Void
    ) {
        let store = self.sitePermissionsStore
        if let stored = store.permission(for: originHost, type: type) {
            completionHandler(stored)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completionHandler(.deny)
                return
            }
            self.permissionPrompt = BrowserPermissionPrompt(
                type: type,
                host: originHost,
                onDecision: { [weak self] decision in
                    if decision != .prompt {
                        store.setPermission(decision, for: originHost, type: type)
                    }
                    completionHandler(decision)
                    Task { @MainActor in
                        self?.permissionPrompt = nil
                    }
                }
            )
        }
    }
}

// MARK: - Browser View (SwiftUI)

/// Native in-app web browser interface integrating address bar, navigation controls, and direct engine download handoff.
public struct BrowserView: View {
    @StateObject public var viewModel: BrowserViewModel
    @FocusState private var isAddressBarFocused: Bool
    @State private var isShowingDiagnosticLogs: Bool = false

    public init(viewModel: BrowserViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public init(
        downloadDelegate: BrowserDownloadDelegate? = nil,
        magnetDelegate: (any BrowserMagnetDelegate)? = nil,
        onDownloadInitiated: (() -> Void)? = nil,
        onOpenAddDownload: ((URL) -> Void)? = nil,
        onOpenDownloads: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: BrowserViewModel(
            downloadDelegate: downloadDelegate,
            magnetDelegate: magnetDelegate,
            onDownloadInitiated: onDownloadInitiated,
            onOpenAddDownload: onOpenAddDownload,
            onOpenDownloads: onOpenDownloads,
            sessionStore: BrowserSessionStore.shared
        ))
    }

    public init(
        viewModel: DownloadManagerViewModel,
        onDownloadInitiated: (() -> Void)? = nil,
        onOpenAddDownload: ((URL) -> Void)? = nil,
        onOpenDownloads: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: BrowserViewModel(
            downloadDelegate: viewModel,
            magnetDelegate: viewModel,
            onDownloadInitiated: onDownloadInitiated,
            onOpenAddDownload: onOpenAddDownload,
            onOpenDownloads: onOpenDownloads,
            streamingOrchestrator: viewModel.streamingOrchestrator,
            streamingDestinationDirectoryURL: viewModel.downloadsDirectoryURL,
            sessionStore: BrowserSessionStore.shared
        ))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Keep one navigation menu at the top, like a compact browser toolbar.
            if !viewModel.isToolbarCollapsed || isAddressBarFocused || viewModel.currentURL == nil {
                topNavigationToolbar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if viewModel.isLoading {
                ProgressView(value: max(0.05, viewModel.estimatedProgress), total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .frame(height: 2)
            } else {
                Divider()
            }

            // Find in Page Search Bar (Milestone B.3)
            if viewModel.isShowingFindInPage {
                BrowserFindInPageView(
                    query: Binding(
                        get: { viewModel.findInPageQuery },
                        set: { viewModel.updateFindInPageQuery($0) }
                    ),
                    result: viewModel.findInPageResult,
                    onPrevious: { viewModel.findInPagePrevious() },
                    onNext: { viewModel.findInPageNext() },
                    onDone: { viewModel.closeFindInPage() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Reader Mode Feedback Banner (Milestone B.3)
            if let banner = viewModel.readerFeedbackBanner {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(banner)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.readerFeedbackBanner = nil
                    }
                    .font(.caption.bold())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.18))
                .foregroundColor(.primary)
            }

            // Main View Area: Home Screen, Error Screen, or Active Web View
            ZStack {
                if viewModel.currentURL == nil {
                    BrowserHomeView(viewModel: viewModel)
                } else if let error = viewModel.errorMessage {
                    BrowserErrorView(error: error, onRetry: {
                        viewModel.reload()
                    }, onHome: {
                        viewModel.goHome()
                    })
                } else {
                    #if canImport(WebKit)
                    if let activeTabID = viewModel.activeTabID {
                        PlatformWebView(viewModel: viewModel, tabID: activeTabID)
                            .id(activeTabID)
                    } else {
                        BrowserHomeView(viewModel: viewModel)
                    }
                    #else
                    Text("WebKit is not supported in this environment.")
                        .foregroundColor(.secondary)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "browserContent")
            .overlay {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: 32)
                            .highPriorityGesture(
                                DragGesture(
                                    minimumDistance: 12,
                                    coordinateSpace: .named("browserContent")
                                )
                                .onEnded { value in
                                    viewModel.handleEdgeGesture(
                                        startX: value.startLocation.x,
                                        translationX: value.translation.width,
                                        containerWidth: geometry.size.width,
                                        modalPresented: isModalPresented
                                    )
                                }
                            )

                        Spacer(minLength: 0)

                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: 32)
                            .highPriorityGesture(
                                DragGesture(
                                    minimumDistance: 12,
                                    coordinateSpace: .named("browserContent")
                                )
                                .onEnded { value in
                                    viewModel.handleEdgeGesture(
                                        startX: value.startLocation.x,
                                        translationX: value.translation.width,
                                        containerWidth: geometry.size.width,
                                        modalPresented: isModalPresented
                                    )
                                }
                            )
                    }
                }
            }

        }
        .sheet(isPresented: $viewModel.isShowingDownloadSheet) {
            BrowserDownloadSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingResourceInspector) {
            BrowserResourceInspectorSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingQualityPicker) {
            StreamQualityPickerSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingShieldSheet) {
            BrowserShieldSheet(viewModel: viewModel)
        }
        .sheet(item: $viewModel.redirectPrompt) { prompt in
            BrowserRedirectSheet(viewModel: viewModel, prompt: prompt)
        }
        .sheet(isPresented: $viewModel.isShowingMagnetSheet) {
            BrowserMagnetConfirmationSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingTabSwitcher) {
            BrowserTabSwitcherView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingBookmarksAndHistory) {
            BrowserBookmarksAndHistoryView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingClearDataSheet) {
            BrowserClearDataSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingReaderMode) {
            if let article = viewModel.readerArticle {
                BrowserReaderView(
                    article: article,
                    settings: $viewModel.readerSettings,
                    onDismiss: {
                        viewModel.closeReaderMode()
                    },
                    onShare: {
                        viewModel.shareCurrentPage()
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingShareSheet) {
            BrowserShareSheet(items: viewModel.shareItems)
        }
        .sheet(isPresented: $viewModel.isShowingSearchEngineManager) {
            SearchEngineManagementView {
                viewModel.reloadSettings()
            }
        }
        .sheet(isPresented: $isShowingDiagnosticLogs) {
            DiagnosticLogView(configuration: viewModel.activeEngineConfiguration)
        }
        .alert(item: $viewModel.certificateWarningPrompt) { prompt in
            Alert(
                title: Text("Security Warning"),
                message: Text(prompt.message),
                primaryButton: .destructive(Text("Proceed Anyway")) {
                    prompt.onProceed()
                },
                secondaryButton: .cancel(Text("Go Back (Safe)")) {
                    prompt.onCancel()
                }
            )
        }
        .alert(item: $viewModel.suspiciousDownloadPrompt) { prompt in
            Alert(
                title: Text("Dangerous Download Warning"),
                message: Text(prompt.warning.warningMessage),
                primaryButton: .destructive(Text("Download Anyway")) {
                    prompt.onProceed()
                },
                secondaryButton: .cancel(Text("Cancel")) {
                    prompt.onCancel()
                }
            )
        }
        .alert(item: $viewModel.permissionPrompt) { prompt in
            Alert(
                title: Text("Permission Request"),
                message: Text("'\(prompt.host)' wants access to your \(prompt.type.rawValue.capitalized)."),
                primaryButton: .default(Text("Allow")) {
                    prompt.onDecision(.grant)
                },
                secondaryButton: .cancel(Text("Deny")) {
                    prompt.onDecision(.deny)
                }
            )
        }
        .alert(item: $viewModel.externalAppLinkPrompt) { link in
            Alert(
                title: Text("Open in \(link.serviceName)?"),
                message: Text("Would you like to open this in the \(link.serviceName) app or continue browsing here?"),
                primaryButton: .default(Text("Continue in Browser")) {
                    viewModel.continueInBrowser(link)
                },
                secondaryButton: .default(Text("Open in App")) {
                    viewModel.openInAssociatedApp(link)
                }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isToolbarCollapsed && !isAddressBarFocused && viewModel.currentURL != nil {
                collapsedAddressPill
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                addressBarHeader
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.isToolbarCollapsed)
        .onReceive(NotificationCenter.default.publisher(for: .sdeBrowserTabRetapped)) { _ in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                if viewModel.isToolbarCollapsed {
                    viewModel.setToolbarCollapsed(false)
                } else {
                    isAddressBarFocused = true
                }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if viewModel.isCapturingMSE {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Capturing MediaSource stream...")
                                .font(.caption.bold())
                                .foregroundColor(.primary)
                            if let snapshot = viewModel.mseCaptureSnapshot {
                                Text("\(ByteCountFormatter.string(fromByteCount: snapshot.bytesCaptured, countStyle: .file)) captured (\(snapshot.segmentCount) segments)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            viewModel.stopMSECapture()
                        } label: {
                            Text("Save")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.blue)
                                .cornerRadius(6)
                        }
                        Button {
                            viewModel.cancelMSECapture()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    #if canImport(UIKit)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                    #else
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.2)))
                    #endif
                    .shadow(radius: 4)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if viewModel.isCapturingBlob {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Exporting in-memory Blob...")
                                .font(.caption.bold())
                                .foregroundColor(.primary)
                            if let snapshot = viewModel.blobCaptureSnapshot {
                                Text("\(ByteCountFormatter.string(fromByteCount: snapshot.bytesWritten, countStyle: .file)) written")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            viewModel.cancelBlobCapture()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    #if canImport(UIKit)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                    #else
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.2)))
                    #endif
                    .shadow(radius: 4)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let notification = viewModel.downloadSuccessNotification {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(notification)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    #if canImport(UIKit)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                    #else
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.2)))
                    #endif
                    .shadow(radius: 4)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                            withAnimation { viewModel.downloadSuccessNotification = nil }
                        }
                    }
                }
                if let error = viewModel.blobCaptureErrorMessage ?? viewModel.mseCaptureErrorMessage ?? viewModel.streamingErrorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                        Button {
                            isShowingDiagnosticLogs = true
                        } label: {
                            Text("Logs")
                                .font(.caption.bold())
                                .foregroundColor(.blue)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(6)
                        }
                        Button {
                            withAnimation {
                                viewModel.blobCaptureErrorMessage = nil
                                viewModel.mseCaptureErrorMessage = nil
                                viewModel.streamingErrorMessage = nil
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    #if canImport(UIKit)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                    #else
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.2)))
                    #endif
                    .shadow(radius: 4)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 8)
            .animation(.easeInOut, value: viewModel.downloadSuccessNotification)
            .animation(.easeInOut, value: viewModel.blobCaptureErrorMessage)
            .animation(.easeInOut, value: viewModel.mseCaptureErrorMessage)
            .animation(.easeInOut, value: viewModel.streamingErrorMessage)
            .animation(.easeInOut, value: viewModel.isCapturingMSE)
            .animation(.easeInOut, value: viewModel.isCapturingBlob)
        }
        #if canImport(UIKit)
        .background(Color(UIColor.systemBackground))
        #endif
        .onAppear {
            viewModel.reloadSettings()
        }
    }

    private var isModalPresented: Bool {
        viewModel.isShowingDownloadSheet ||
        viewModel.isShowingResourceInspector ||
        viewModel.isShowingQualityPicker ||
        viewModel.isShowingShieldSheet ||
        viewModel.isShowingReaderMode ||
        viewModel.isShowingShareSheet ||
        viewModel.redirectPrompt != nil ||
        viewModel.isShowingMagnetSheet ||
        viewModel.isShowingTabSwitcher
    }

    private var shieldIconName: String {
        if !viewModel.isAdBlockerEnabled {
            return "shield.slash"
        }
        if viewModel.isCurrentSiteWhitelisted {
            return "shield.slash.fill"
        }
        return "shield.checkered"
    }

    private var shieldIconColor: Color {
        if !viewModel.isAdBlockerEnabled {
            return .secondary
        }
        if viewModel.isCurrentSiteWhitelisted {
            return .orange
        }
        return .blue
    }

    // MARK: - Address Bar Header

    private var collapsedWebsiteName: String {
        guard let host = viewModel.currentURL?.host, !host.isEmpty else {
            return viewModel.currentURL?.lastPathComponent ?? "Website"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var collapsedAddressPill: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                viewModel.setToolbarCollapsed(false)
            }
        } label: {
            HStack(spacing: 6) {
                if let url = viewModel.currentURL {
                    Image(systemName: url.scheme?.lowercased() == "https" ? "lock.fill" : "lock.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(url.scheme?.lowercased() == "https" ? .green : .orange)
                }
                Text(collapsedWebsiteName)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
        .accessibilityLabel("Website: \(collapsedWebsiteName). Tap to expand browser bar.")
    }

    private var addressBarHeader: some View {
        VStack(spacing: 4) {
            // Show Quick Search Engine Switcher only when editing or on start page
            if isAddressBarFocused || viewModel.currentURL == nil {
                searchEngineQuickSwitcher
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                // Address Bar Capsule
                HStack(spacing: 6) {
                // Shield Protection Button
                Button {
                    viewModel.isShowingShieldSheet = true
                } label: {
                    Image(systemName: shieldIconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(shieldIconColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Content Shields")

                // Incognito Private Indicator (Phase 3 Milestone 3.4)
                if viewModel.isCurrentTabIncognito {
                    HStack(spacing: 3) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 11, weight: .bold))
                        Text("Private")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .clipShape(Capsule())
                }

                // Security / Search Icon
                if let url = viewModel.currentURL {
                    if url.scheme?.lowercased() == "https" {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "lock.slash.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                TextField("Search or enter website address", text: $viewModel.urlInputText)
                    #if canImport(UIKit)
                    .keyboardType(.webSearch)
                    .autocapitalization(.none)
                    #endif
                    .disableAutocorrection(true)
                    .focused($isAddressBarFocused)
                    .onSubmit {
                        viewModel.navigate(to: viewModel.urlInputText)
                        isAddressBarFocused = false
                    }

                if isAddressBarFocused && !viewModel.urlInputText.isEmpty {
                    Button {
                        viewModel.urlInputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Clear search bar")
                } else if viewModel.isLoading {
                    Button {
                        viewModel.stopLoading()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Stop loading")
                } else if !viewModel.urlInputText.isEmpty {
                    Button {
                        viewModel.urlInputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Clear search bar")
                }

                if viewModel.currentURL != nil {
                    Button {
                        viewModel.openResourceInspector()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(width: 26, height: 26)

                            if viewModel.detectedMediaCount > 0 {
                                Text("\(viewModel.detectedMediaCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, viewModel.detectedMediaCount > 9 ? 3 : 0)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(Circle().fill(Color.red))
                                    .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .accessibilityLabel(viewModel.detectedMediaCount > 0
                        ? "Find Resources (\(viewModel.detectedMediaCount))"
                        : "Find Resources")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)

            if isAddressBarFocused {
                Button("Go") {
                    viewModel.navigate(to: viewModel.urlInputText)
                    isAddressBarFocused = false
                }
                .font(.body.weight(.semibold))
            }
        }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var searchEngineQuickSwitcher: some View {
        HStack {
            Menu {
                Section("Search Engines") {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Button {
                            viewModel.setSearchEngine(id: engine.rawValue)
                        } label: {
                            if viewModel.activeSearchEngineID == engine.rawValue {
                                Label(engine.displayName, systemImage: "checkmark")
                            } else {
                                Text(engine.displayName)
                            }
                        }
                    }
                    ForEach(viewModel.customSearchEngines) { custom in
                        Button {
                            viewModel.setSearchEngine(id: custom.id)
                        } label: {
                            if viewModel.activeSearchEngineID == custom.id {
                                Label(custom.name, systemImage: "checkmark")
                            } else {
                                Text(custom.name)
                            }
                        }
                    }
                }

                Divider()

                Button {
                    viewModel.isShowingSearchEngineManager = true
                } label: {
                    Label("Manage Search Engines...", systemImage: "gearshape")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                    Text(viewModel.currentSearchEngineName)
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                #if canImport(UIKit)
                .background(Color(UIColor.tertiarySystemFill))
                #else
                .background(Color.secondary.opacity(0.12))
                #endif
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Active search engine: \(viewModel.currentSearchEngineName). Tap to switch.")

            Spacer()
        }
    }

    // MARK: - Top Navigation Toolbar

    private var topNavigationToolbar: some View {
        VStack(spacing: 0) {
            HStack {
                // Back Button
                Button {
                    viewModel.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 18, weight: .semibold))
                }
                .accessibilityLabel("Back")
                .disabled(!viewModel.canGoBack)
                .frame(maxWidth: .infinity, minHeight: 44)

                // Forward Button
                Button {
                    viewModel.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 18, weight: .semibold))
                }
                .accessibilityLabel("Forward")
                .disabled(!viewModel.canGoForward)
                .frame(maxWidth: .infinity, minHeight: 44)

                // Home Button
                Button {
                    viewModel.goHome()
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 18))
                }
                .accessibilityLabel("Home")
                .frame(maxWidth: .infinity, minHeight: 44)

                // Tab overview button with live count badge
                Button {
                    viewModel.showTabSwitcher()
                } label: {
                    ZStack {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 18))
                        if !viewModel.tabs.isEmpty {
                            Text("\(viewModel.tabs.count)")
                                .font(.system(size: 9, weight: .bold))
                                .offset(x: 1, y: 1)
                        }
                    }
                }
                .accessibilityLabel("Tabs (\(viewModel.tabs.count) open)")
                .disabled(viewModel.tabs.isEmpty)
                .frame(maxWidth: .infinity, minHeight: 44)

                // Dynamic Reload / Stop Button
                Button {
                    if viewModel.isLoading {
                        viewModel.stopLoading()
                    } else {
                        viewModel.reload()
                    }
                } label: {
                    Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 18))
                }
                .accessibilityLabel(viewModel.isLoading ? "Stop" : "Reload")
                .disabled(viewModel.currentURL == nil && !viewModel.isLoading)
                .frame(maxWidth: .infinity, minHeight: 44)

                // Vertical Three-Dot (⋮) Overflow Menu
                overflowMenu
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            #if canImport(UIKit)
            .background(Color(UIColor.secondarySystemBackground))
            #else
            .background(Color.secondary.opacity(0.15))
            #endif
            Divider()
        }
    }

    // MARK: - Overflow Menu (⋮)

    @ViewBuilder
    private var overflowMenu: some View {
        BrowserOverflowMenu(
            isDesktopMode: viewModel.isCurrentTabDesktopMode,
            isWhitelisted: viewModel.isCurrentSiteWhitelisted,
            hasURL: viewModel.currentURL != nil,
            activeDownloadCount: viewModel.activeDownloadCount,
            onToggleDesktopMode: { viewModel.toggleDesktopMode() },
            onShowBookmarksAndHistory: { viewModel.showBookmarksAndHistory() },
            onShowShieldSheet: { viewModel.isShowingShieldSheet = true },
            onToggleReaderMode: { viewModel.toggleReaderMode() },
            onOpenFindInPage: { viewModel.openFindInPage() },
            onShareCurrentPage: { viewModel.shareCurrentPage() }
        )
        .equatable()
    }
}

private struct BrowserOverflowMenu: View, Equatable {
    let isDesktopMode: Bool
    let isWhitelisted: Bool
    let hasURL: Bool
    let activeDownloadCount: Int
    let onToggleDesktopMode: () -> Void
    let onShowBookmarksAndHistory: () -> Void
    let onShowShieldSheet: () -> Void
    let onToggleReaderMode: () -> Void
    let onOpenFindInPage: () -> Void
    let onShareCurrentPage: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isDesktopMode == rhs.isDesktopMode &&
        lhs.isWhitelisted == rhs.isWhitelisted &&
        lhs.hasURL == rhs.hasURL &&
        lhs.activeDownloadCount == rhs.activeDownloadCount
    }

    var body: some View {
        Menu {
            // Desktop / Mobile Mode Toggle
            Button(action: onToggleDesktopMode) {
                Label(
                    isDesktopMode ? "Request Mobile Site" : "Request Desktop Site",
                    systemImage: isDesktopMode ? "iphone" : "desktopcomputer"
                )
            }
            .disabled(!hasURL)

            // Bookmarks & History
            Button(action: onShowBookmarksAndHistory) {
                Label("Bookmarks & History", systemImage: "book")
            }

            // Content Shields (Milestone B.2)
            Button(action: onShowShieldSheet) {
                Label(
                    "Content Shields",
                    systemImage: isWhitelisted ? "shield.slash" : "shield.checkered"
                )
            }

            // Safari-Style Reader Mode (Milestone B.3)
            Button(action: onToggleReaderMode) {
                Label("Reader Mode", systemImage: "doc.plaintext")
            }
            .disabled(!hasURL)

            // Find in Page (Milestone B.3)
            Button(action: onOpenFindInPage) {
                Label("Find in Page", systemImage: "magnifyingglass")
            }
            .disabled(!hasURL)

            // Webpage Sharing (Milestone B.3)
            Button(action: onShareCurrentPage) {
                Label("Share Webpage...", systemImage: "square.and.arrow.up")
            }
            .disabled(!hasURL)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.system(size: 18, weight: .semibold))

                // Priority Badge Indicator: Blue for active downloads
                if activeDownloadCount > 0 {
                    Text("\(activeDownloadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue)
                        .clipShape(Capsule())
                        .offset(x: 8, y: -6)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("More Options")
    }
}

// MARK: - Home / New Tab View

public struct BrowserHomeView: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @State private var isShowingAddSheet: Bool = false
    @State private var editingShortcut: QuickAccessShortcut? = nil
    @State private var shortcutToDelete: QuickAccessShortcut? = nil
    @State private var isShowingDeleteConfirm: Bool = false

    private let columns = [
        GridItem(.adaptive(minimum: 70, maximum: 90), spacing: 14)
    ]

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero Branding Card
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.22), Color.indigo.opacity(0.14)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 78, height: 78)
                            .overlay(
                                Circle()
                                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                            )
                            .shadow(color: .blue.opacity(0.15), radius: 10, x: 0, y: 4)
                        Image(systemName: "globe")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    .padding(.top, 18)

                    Text("LID In-App Browser")
                        .font(.title2.weight(.bold))

                    Text("Browse privately, auto-detect media streams, and route transfers directly to the multi-threaded engine.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Quick Access Section (Speed Dial)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Quick Access")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Spacer()

                        Button {
                            isShowingAddSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Add")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.blue.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.quickAccessShortcuts) { shortcut in
                            QuickAccessItemView(
                                shortcut: shortcut,
                                onTap: {
                                    viewModel.load(url: shortcut.url)
                                },
                                onOpenInNewTab: {
                                    viewModel.createNewTab(with: shortcut.url)
                                },
                                onEdit: {
                                    editingShortcut = shortcut
                                },
                                onDelete: {
                                    shortcutToDelete = shortcut
                                    isShowingDeleteConfirm = true
                                },
                                onMoveLeft: {
                                    viewModel.moveQuickAccessShortcut(id: shortcut.id, direction: .left)
                                },
                                onMoveRight: {
                                    viewModel.moveQuickAccessShortcut(id: shortcut.id, direction: .right)
                                }
                            )
                        }

                        QuickAccessAddButtonCell {
                            isShowingAddSheet = true
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Integrated Engine & Privacy Shield Card
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(viewModel.isAdBlockerEnabled ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(systemName: viewModel.isAdBlockerEnabled ? "bolt.shield.fill" : "shield.slash")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(viewModel.isAdBlockerEnabled ? .green : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Integrated Transfer Engine")
                                .font(.subheadline.weight(.bold))
                            if viewModel.isAdBlockerEnabled {
                                Text("Shields On")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.16))
                                    .foregroundColor(.green)
                                    .clipShape(Capsule())
                            }
                        }
                        Text("Downloads initiated from this browser automatically inherit cookies, referer headers, segmented range writing, and background recovery.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.04), radius: 5, x: 0, y: 2)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            QuickAccessEditSheet { name, url in
                viewModel.addQuickAccessShortcut(name: name, url: url)
            }
        }
        .sheet(item: $editingShortcut) { shortcut in
            QuickAccessEditSheet(editingShortcut: shortcut) { name, url in
                var updated = shortcut
                updated.name = name
                updated.url = url
                viewModel.updateQuickAccessShortcut(updated)
            }
        }
        .confirmationDialog(
            "Delete '\(shortcutToDelete?.name ?? "Shortcut")'?",
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let shortcut = shortcutToDelete {
                    viewModel.deleteQuickAccessShortcut(id: shortcut.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This shortcut will be removed from your Quick Access page. Your bookmarks and browsing history will not be affected.")
        }
    }
}

// MARK: - Browser Tab Switcher (Visual 2-Column Grid with Tab Groups & Renaming)

extension BrowserTabGroup {
    public var swiftUIColor: Color {
        switch colorName.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        case "indigo": return .indigo
        default: return .blue
        }
    }
}

public struct BrowserTabSwitcherView: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var tabToRename: BrowserTabState? = nil
    @State private var renameText: String = ""
    @State private var isShowingRenameAlert: Bool = false

    @State private var groupToRename: BrowserTabGroup? = nil
    @State private var renameGroupText: String = ""
    @State private var isShowingRenameGroupAlert: Bool = false

    @State private var dropTargetGroupID: UUID? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if viewModel.tabs.isEmpty {
                        VStack(spacing: 12) {
                            Spacer(minLength: 40)
                            Image(systemName: "square.on.square.dashed")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("No Open Tabs")
                                .font(.headline)
                            Text("Open a new tab to begin browsing.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer(minLength: 40)
                        }
                    } else {
                        // Render Groups (if any)
                        ForEach(viewModel.groups) { group in
                            groupSection(group)
                        }

                        // Render Ungrouped Tabs
                        let ungrouped = viewModel.ungroupedTabs()
                        if !ungrouped.isEmpty {
                            if !viewModel.groups.isEmpty {
                                HStack {
                                    Text("Tabs (\(ungrouped.count))")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 4)
                            }

                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(ungrouped) { tab in
                                    tabCard(for: tab)
                                }
                            }
                        }
                    }

                    // Action buttons (New Tab, Private Tab, Close All Private)
                    actionButtons
                }
                .padding(16)
            }
            .navigationTitle("Tabs (\(viewModel.tabs.count))")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        viewModel.isShowingTabSwitcher = false
                        dismiss()
                    }
                }
            }
            .alert("Rename Tab", isPresented: $isShowingRenameAlert) {
                TextField("Tab Title", text: $renameText)
                Button("Save") {
                    if let tab = tabToRename {
                        viewModel.renameTab(tab.id, newTitle: renameText)
                    }
                    tabToRename = nil
                }
                Button("Reset to Default") {
                    if let tab = tabToRename {
                        viewModel.renameTab(tab.id, newTitle: nil)
                    }
                    tabToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    tabToRename = nil
                }
            }
            .alert("Rename Group", isPresented: $isShowingRenameGroupAlert) {
                TextField("Group Name", text: $renameGroupText)
                Button("Save") {
                    if let group = groupToRename {
                        viewModel.renameGroup(group.id, newTitle: renameGroupText)
                    }
                    groupToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    groupToRename = nil
                }
            }
        }
    }

    private func groupSection(_ group: BrowserTabGroup) -> some View {
        let groupTabs = viewModel.tabsInGroup(group.id)
        let isDropTarget = dropTargetGroupID == group.id

        return VStack(alignment: .leading, spacing: 10) {
            // Group Header (Drop Target for adding tabs to group)
            HStack(spacing: 8) {
                Circle()
                    .fill(group.swiftUIColor)
                    .frame(width: 12, height: 12)

                Text(group.title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("(\(groupTabs.count))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                // Collapse/Expand Button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.toggleGroupCollapse(group.id)
                    }
                } label: {
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)

                // Group Menu
                Menu {
                    Button {
                        groupToRename = group
                        renameGroupText = group.title
                        isShowingRenameGroupAlert = true
                    } label: {
                        Label("Rename Group", systemImage: "pencil")
                    }

                    Button {
                        withAnimation {
                            viewModel.deleteGroup(group.id, closeContainedTabs: false)
                        }
                    } label: {
                        Label("Ungroup Tabs", systemImage: "folder.badge.minus")
                    }

                    Divider()

                    Button(role: .destructive) {
                        withAnimation {
                            viewModel.deleteGroup(group.id, closeContainedTabs: true)
                        }
                    } label: {
                        Label("Close Group", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDropTarget ? group.swiftUIColor.opacity(0.2) : Color.clear)
            )
            .onDrop(of: ["public.plain-text", "public.text"], isTargeted: Binding(
                get: { dropTargetGroupID == group.id },
                set: { targeted in dropTargetGroupID = targeted ? group.id : nil }
            )) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                    if let str = string as? String, let sourceUUID = UUID(uuidString: str) {
                        DispatchQueue.main.async {
                            viewModel.addTabToGroup(tabID: sourceUUID, groupID: group.id)
                        }
                    }
                }
                return true
            }

            // Group Contained Tabs
            if !group.isCollapsed {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(groupTabs) { tab in
                        tabCard(for: tab)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func tabCard(for tab: BrowserTabState) -> some View {
        BrowserTabCardView(
            tab: tab,
            isActive: tab.id == viewModel.activeTabID,
            previewData: viewModel.tabPreviewCache.preview(for: tab.id),
            onSelect: {
                _ = viewModel.selectTab(tab.id)
                dismiss()
            },
            onClose: {
                close(tab.id)
            },
            onRename: {
                tabToRename = tab
                renameText = tab.customTitle ?? tab.title
                isShowingRenameAlert = true
            },
            onResetName: {
                viewModel.renameTab(tab.id, newTitle: nil)
            },
            onRemoveFromGroup: {
                withAnimation {
                    _ = viewModel.removeTabFromGroup(tabID: tab.id)
                }
            },
            onGroup: { sourceTabID in
                withAnimation {
                    _ = viewModel.groupTabs(sourceTabID: sourceTabID, targetTabID: tab.id)
                }
            }
        )
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    viewModel.createNewTab(isIncognito: false)
                    dismiss()
                } label: {
                    Label("New Tab", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.createNewTab(isIncognito: true)
                    dismiss()
                } label: {
                    Label("Private Tab", systemImage: "eyeglasses")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
            }

            if viewModel.tabs.contains(where: \.isIncognito) {
                Button {
                    viewModel.closeAllIncognitoTabs()
                } label: {
                    Label("Close All Private Tabs", systemImage: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.purple)
                }
                .padding(.top, 4)
            }
        }
        .padding(.top, 8)
    }

    private func close(_ tabID: UUID) {
        withAnimation(.easeInOut(duration: 0.25)) {
            _ = viewModel.closeTab(tabID)
        }
    }
}

// MARK: - Browser Tab Card View with Drag & Drop Grouping, Renaming & Left/Right Swipe-to-Close

public struct BrowserTabCardView: View {
    public let tab: BrowserTabState
    public let isActive: Bool
    public let previewData: Data?
    public let onSelect: () -> Void
    public let onClose: () -> Void
    public let onRename: (() -> Void)?
    public let onResetName: (() -> Void)?
    public let onRemoveFromGroup: (() -> Void)?
    public let onGroup: ((UUID) -> Void)?

    @State private var dragOffset: CGSize = .zero
    @State private var isDismissing: Bool = false
    @State private var isDropTarget: Bool = false

    public init(
        tab: BrowserTabState,
        isActive: Bool,
        previewData: Data?,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onRename: (() -> Void)? = nil,
        onResetName: (() -> Void)? = nil,
        onRemoveFromGroup: (() -> Void)? = nil,
        onGroup: ((UUID) -> Void)? = nil
    ) {
        self.tab = tab
        self.isActive = isActive
        self.previewData = previewData
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRename = onRename
        self.onResetName = onResetName
        self.onRemoveFromGroup = onRemoveFromGroup
        self.onGroup = onGroup
    }

    public var body: some View {
        ZStack {
            // Swipe action background indicator (Left or Right)
            if dragOffset.width != 0 {
                swipeActionBackground
            }

            cardContent
                .offset(dragOffset)
                .opacity(isDismissing ? 0 : max(0.2, 1.0 - Double(abs(dragOffset.width) / 160.0)))
                .scaleEffect(isDismissing ? 0.8 : max(0.92, 1.0 - (abs(dragOffset.width) / 800.0)))
        }
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: ["public.plain-text", "public.text"], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                if let str = string as? String, let sourceUUID = UUID(uuidString: str), sourceUUID != tab.id {
                    DispatchQueue.main.async {
                        onGroup?(sourceUUID)
                    }
                }
            }
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(-2)
        )
        .overlay(
            Group {
                if isDropTarget {
                    VStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                            Text("Group Tabs")
                                .font(.caption.weight(.bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .foregroundColor(.primary)
                        .padding(.bottom, 8)
                    }
                }
            }
        )
        .contextMenu {
            if let onRename = onRename {
                Button(action: onRename) {
                    Label("Rename Tab", systemImage: "pencil")
                }
            }
            if tab.customTitle != nil, let onResetName = onResetName {
                Button(action: onResetName) {
                    Label("Reset Tab Name", systemImage: "arrow.counterclockwise")
                }
            }
            if tab.groupID != nil, let onRemoveFromGroup = onRemoveFromGroup {
                Button(action: onRemoveFromGroup) {
                    Label("Remove from Group", systemImage: "folder.badge.minus")
                }
            }
            Divider()
            Button(role: .destructive, action: onClose) {
                Label("Close Tab", systemImage: "trash")
            }
        }
        .gesture(
            DragGesture(minimumDistance: 15)
                .onChanged { value in
                    if abs(value.translation.width) > abs(value.translation.height) {
                        dragOffset = CGSize(width: value.translation.width, height: 0)
                    } else if value.translation.height < -20 {
                        dragOffset = CGSize(width: 0, height: value.translation.height)
                    }
                }
                .onEnded { value in
                    let shouldClose = BrowserTabSwipePolicy.shouldClose(translationX: Double(value.translation.width), translationY: Double(value.translation.height))
                    if shouldClose {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        withAnimation(.easeOut(duration: 0.2)) {
                            if abs(value.translation.width) > abs(value.translation.height) {
                                dragOffset.width = value.translation.width > 0 ? 350 : -350
                            } else {
                                dragOffset.height = -350
                            }
                            isDismissing = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onClose()
                        }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            dragOffset = .zero
                        }
                    }
                }
        )
    }

    private var swipeActionBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.red)
            .overlay(
                HStack {
                    if dragOffset.width > 0 {
                        // Swiping right: show close indicator on the left
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                            Text("Close")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.leading, 16)
                        Spacer()
                    } else {
                        // Swiping left: show close indicator on the right
                        Spacer()
                        HStack(spacing: 6) {
                            Text("Close")
                                .font(.system(size: 14, weight: .bold))
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.trailing, 16)
                    }
                }
            )
            .opacity(min(1.0, Double(abs(dragOffset.width) / 60.0)))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: Title & Dedicated Rename & Close Buttons
            HStack(spacing: 6) {
                if tab.isIncognito {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.purple)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                }

                Text(tab.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if tab.customTitle != nil {
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 4)

                // Dedicated Rename Button
                if let onRename = onRename {
                    Button(action: onRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Rename \(tab.displayName)")
                }

                // Dedicated Close Button with explicit hit target
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        onClose()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Close \(tab.displayName)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            #if canImport(UIKit)
            .background(Color(UIColor.secondarySystemBackground))
            #else
            .background(Color.secondary.opacity(0.12))
            #endif

            Divider()

            // Thumbnail / Preview Body
            Button(action: onSelect) {
                ZStack {
                    #if canImport(UIKit)
                    if let previewData, let uiImage = UIImage(data: previewData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 115)
                            .clipped()
                    } else {
                        placeholderPreview
                    }
                    #else
                    placeholderPreview
                    #endif
                }
                .frame(maxWidth: .infinity, minHeight: 115, maxHeight: 115)
                .background(tab.isIncognito ? Color.purple.opacity(0.06) : Color.secondary.opacity(0.04))
            }
            .buttonStyle(.plain)

            Divider()

            // Footer
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    Text(displayURL)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if tab.isDesktopMode {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.blue)
                    }

                    if tab.isIncognito {
                        Text("Private")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.16))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                #if canImport(UIKit)
                .background(Color(UIColor.secondarySystemBackground))
                #else
                .background(Color.secondary.opacity(0.12))
                #endif
            }
            .buttonStyle(.plain)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isActive
                        ? (tab.isIncognito ? Color.purple : Color.blue)
                        : (tab.isIncognito ? Color.purple.opacity(0.3) : Color.secondary.opacity(0.2)),
                    lineWidth: isActive ? 2.5 : 1
                )
        )
        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    private var placeholderPreview: some View {
        VStack(spacing: 6) {
            Image(systemName: tab.isIncognito ? "eyeglasses" : "globe")
                .font(.system(size: 26))
                .foregroundColor(tab.isIncognito ? .purple.opacity(0.7) : .blue.opacity(0.7))

            Text(tab.url?.host ?? (tab.isIncognito ? "Private Tab" : "New Tab"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayURL: String {
        guard let url = tab.url else { return "New tab" }
        return BrowserURLResolver.sanitizeURLForLogging(url)
    }
}

// MARK: - Browser Error View

public struct BrowserErrorView: View {
    public let error: String
    public let onRetry: () -> Void
    public let onHome: () -> Void

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Unable to Load Page")
                .font(.headline)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            HStack(spacing: 16) {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)

                Button("Return to Home", action: onHome)
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .padding()
    }
}

// MARK: - Browser Download Modal Sheet

public struct BrowserMagnetConfirmationSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var isSubmitting = false

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            Form {
                if let magnet = viewModel.magnetCandidate {
                    Section(header: Text("Resource")) {
                        magnetDetailRow(label: "Resource type", value: "BitTorrent magnet link")
                        magnetDetailRow(label: "Name", value: magnet.presentationName)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Identifier")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(magnet.identifier)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(4)
                        }
                        magnetDetailRow(
                            label: "Source",
                            value: viewModel.magnetSourcePageURL.map(BrowserURLResolver.sanitizeURLForDisplay) ?? "Current webpage"
                        )
                        if let length = magnet.contentLength {
                            magnetDetailRow(label: "Declared size", value: "\(length) bytes")
                        }
                    }

                    if viewModel.isTorrentEngineAvailable {
                        Section {
                            Button {
                                submitMagnet()
                            } label: {
                                HStack {
                                    Spacer()
                                    if isSubmitting {
                                        ProgressView()
                                            .padding(.trailing, 8)
                                    }
                                    Text("Add to Torrent Queue")
                                        .bold()
                                    Spacer()
                                }
                            }
                            .disabled(isSubmitting)
                        }
                    } else {
                        Section {
                            Text("Built-in torrent downloading is unavailable. You can hand this magnet link to an installed torrent application instead.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Open in External Torrent App") {
                                openExternally()
                            }
                        }
                    }
                } else {
                    Text("No magnet link is awaiting confirmation.")
                        .foregroundColor(.secondary)
                }

                if let error = viewModel.magnetErrorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Torrent Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    private func submitMagnet() {
        viewModel.magnetErrorMessage = nil
        isSubmitting = true
        Task { @MainActor in
            do {
                try await viewModel.confirmMagnetLink()
                isSubmitting = false
                presentationMode.wrappedValue.dismiss()
            } catch {
                isSubmitting = false
                viewModel.magnetErrorMessage = error.localizedDescription
            }
        }
    }

    private func openExternally() {
        guard viewModel.openMagnetExternally() else {
            viewModel.magnetErrorMessage = "No external torrent application could be opened."
            return
        }
        presentationMode.wrappedValue.dismiss()
    }

    private func magnetDetailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Confirms a prepared, finite streaming proposal before its resources are
/// submitted through the existing download coordinator.
public struct BrowserStreamingConfirmationSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            Form {
                if let proposal = viewModel.streamingProposal {
                    Section(header: Text("Stream")) {
                        detailRow(label: "Type", value: proposal.manifest.kind.rawValue.uppercased())
                        detailRow(label: "Resources", value: "\(proposal.resources.count) ordered segments")
                        if let bytes = proposal.estimatedTransferBytes {
                            detailRow(label: "Estimated size", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Manifest")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(BrowserURLResolver.sanitizeURLForDisplay(proposal.manifest.manifestURL))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                    }

                    if let progress = viewModel.streamingProgress {
                        Section(header: Text("Progress")) {
                            ProgressView(value: progress.currentFraction)
                            Text("Segment \(progress.currentOrder) of \(progress.totalSegments)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let error = viewModel.streamingErrorMessage {
                        Section {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }

                    Section {
                        Button {
                            viewModel.executeStreamingProposal()
                        } label: {
                            HStack {
                                Spacer()
                                if viewModel.isExecutingStreaming {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                }
                                Text(viewModel.isExecutingStreaming ? "Downloading Stream" : "Start Stream")
                                    .bold()
                                Spacer()
                            }
                        }
                        .disabled(viewModel.isExecutingStreaming)
                    }
                } else if viewModel.isPreparingStreaming {
                    ProgressView("Preparing manifest")
                } else {
                    Text("No streaming proposal is awaiting confirmation.")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Streaming Download")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelStreamingDownload()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

public struct BrowserDownloadSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var isSubmitting = false
    @State private var submitErrorMessage: String? = nil
    @State private var baseFilename: String = ""
    @State private var fileExtension: String = ""

    private var isPreSelectedVariant: Bool {
        viewModel.activeDownloadResource?.hlsVariantPreferences != nil ||
        viewModel.activeDownloadResource?.dashVideoRepresentationID != nil
    }

    private var preSelectedVariantQualityInfo: (badge: String, resolution: String?, details: String?, isAudio: Bool, buttonTitle: String) {
        guard let res = viewModel.activeDownloadResource else {
            return ("Video", nil, nil, false, "Download Video")
        }

        let isAudio = res.resourceType == .audio

        // 1. Try matching HLSVariantStreamItem from viewModel.variantStreamItems
        if let item = viewModel.variantStreamItems[res.id] {
            let isLive = res.isLive || item.isLive
            let badge = item.qualityLabel
            let resText = item.resolutionText ?? item.resolution.map { "\($0.width) × \($0.height)" }
            var detailsParts: [String] = []
            if isLive {
                detailsParts.append("Live Broadcast")
            } else if let size = item.estimatedSizeText, !size.isEmpty && size != "Size unavailable" {
                detailsParts.append(size)
            }
            if !item.bitrateText.isEmpty {
                detailsParts.append(item.bitrateText)
            }
            let details = detailsParts.isEmpty ? nil : detailsParts.joined(separator: " • ")
            let title = isLive ? "Record Live Stream" : (isAudio ? "Download Audio" : "Download \(badge)")
            return (badge, resText, details, isAudio, title)
        }

        // 2. Derive from HLSVariantSelectionPreferences & resource metadata
        let badge: String = {
            if isAudio { return "Audio" }
            if let h = res.hlsVariantPreferences?.maximumHeight { return "\(h)p" }
            let stem = (res.suggestedFilename as NSString).deletingPathExtension
            if let match = stem.range(of: #"(?:^|[-_])(\d{3,4}p)(?:$|[-_])"#, options: .regularExpression) {
                return String(stem[match]).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            }
            return "Video"
        }()

        let resText: String? = {
            if let w = res.hlsVariantPreferences?.maximumWidth, let h = res.hlsVariantPreferences?.maximumHeight {
                return "\(w) × \(h)"
            }
            return nil
        }()

        let details: String? = {
            if let size = res.estimatedSize, size > 0 {
                return StreamQualityOption.formatByteSize(size)
            }
            return nil
        }()

        let title = isAudio ? "Download Audio" : "Download \(badge)"
        return (badge, resText, details, isAudio, title)
    }

    private var downloadFileInfo: (badge: String, badgeColor: Color, resolution: String?, details: String?, isAudio: Bool, buttonTitle: String) {
        if isPreSelectedVariant {
            let info = preSelectedVariantQualityInfo
            let isLive = viewModel.activeDownloadResource?.isLive == true || (viewModel.activeDownloadResource != nil && viewModel.variantStreamItems[viewModel.activeDownloadResource!.id]?.isLive == true)
            let badgeColor: Color = isLive ? .red : (info.isAudio ? .orange : .blue)
            return (info.badge, badgeColor, info.resolution, info.details, info.isAudio, info.buttonTitle)
        }

        let res = viewModel.activeDownloadResource
        let cand = viewModel.activeDownloadCandidate
        let url = viewModel.downloadCandidateURL

        let ext = fileExtension.lowercased()
        let isAudio = res?.resourceType == .audio || (cand?.kind == .completeBlob && cand?.mimeType?.contains("audio") == true) || ["mp3", "m4a", "aac", "flac", "wav", "ogg"].contains(ext)
        let isVideo = res?.resourceType == .video || cand?.kind == .directMedia || ["mp4", "mkv", "webm", "mov", "avi", "flv", "m4v"].contains(ext)

        let badge: String = {
            if !ext.isEmpty {
                return ext.uppercased()
            }
            if isAudio { return "Audio" }
            if isVideo { return "Video" }
            return "File"
        }()

        let badgeColor: Color = isAudio ? .orange : (isVideo ? .blue : .purple)

        var detailsParts: [String] = []
        if let size = res?.estimatedSize ?? cand?.estimatedSize, size > 0 {
            detailsParts.append(StreamQualityOption.formatByteSize(size))
        }
        if let host = url?.host {
            detailsParts.append(host)
        }
        let details = detailsParts.isEmpty ? nil : detailsParts.joined(separator: " • ")

        let buttonTitle = isAudio ? "Download Audio" : (isVideo ? "Download \(badge)" : "Start Download")
        return (badge, badgeColor, nil, details, isAudio, buttonTitle)
    }

    public var body: some View {
        NavigationView {
            Form {
                // MARK: - FILE NAME
                Section(header: Text("FILE NAME")) {
                    HStack(alignment: .center, spacing: 6) {
                        TextField("Filename", text: $baseFilename)
                            #if canImport(UIKit)
                            .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .font(.system(size: 15, weight: .medium))
                            .onChange(of: baseFilename) { newBase in
                                let cleanBase = FilenameExtensionHelper.sanitizeFilename(newBase)
                                viewModel.downloadCandidateFilename = FilenameExtensionHelper.combine(base: cleanBase, ext: fileExtension)
                            }

                        Text(".")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.secondary)

                        TextField("ext", text: $fileExtension)
                            #if canImport(UIKit)
                            .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 55)
                            .onChange(of: fileExtension) { newExt in
                                let cleanExt = FilenameExtensionHelper.sanitizeFilename(newExt)
                                viewModel.downloadCandidateFilename = FilenameExtensionHelper.combine(base: baseFilename, ext: cleanExt)
                            }
                    }
                }

                // MARK: - DOWNLOAD DETAILS
                let info = downloadFileInfo
                let detailRows = technicalDetailRows
                Section(header: Text(info.isAudio ? "AUDIO DETAILS" : (info.badge == "Video" || ["MKV", "MP4", "WEBM", "MOV"].contains(info.badge) || isPreSelectedVariant ? "MEDIA DETAILS" : "DETAILS"))) {
                    HStack(spacing: 12) {
                        Text(info.badge)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(info.badgeColor)
                            .cornerRadius(6)

                        if let res = info.resolution {
                            Text(res)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primary)
                        }

                        Spacer()

                        if let details = info.details, !details.isEmpty {
                            Text(details)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    ForEach(detailRows, id: \.label) { row in
                        HStack {
                            Text(row.label)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(row.value)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                // If unexpanded HLS or DASH manifest, provide the quality picker button
                if !isPreSelectedVariant,
                   let cand = viewModel.activeDownloadCandidate,
                   (cand.kind == .hlsManifest || cand.kind == .dashManifest || cand.url?.pathExtension.lowercased() == "m3u8" || cand.url?.pathExtension.lowercased() == "mpd") {
                    Section(header: Text("Stream Resolution"), footer: Text("Choose from available multi-variant resolutions or download audio only.")) {
                        Button {
                            viewModel.isShowingDownloadSheet = false
                            if let res = viewModel.activeDownloadResource {
                                viewModel.presentQualityPicker(for: res)
                            } else {
                                viewModel.presentQualityPicker(for: cand)
                            }
                        } label: {
                            HStack {
                                Label("Select Stream Quality...", systemImage: "slider.horizontal.3")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                if let selected = viewModel.selectedQualityOption {
                                    Text(selected.qualityBadge)
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(selected.badgeColor)
                                        .cornerRadius(5)
                                } else {
                                    Text("Choose")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // MARK: - Advanced Options (Collapsed by default so it stays clean)
                Section {
                    DisclosureGroup("Advanced Settings") {
                        VStack(spacing: 12) {
                            Stepper("Worker Threads: \(viewModel.downloadCandidateThreads)", value: $viewModel.downloadCandidateThreads, in: 1...32)

                            HStack {
                                Text("Speed Limit (KB/s)")
                                Spacer()
                                TextField("Unlimited", text: $viewModel.downloadCandidateSpeedLimitKBps)
                                    #if canImport(UIKit)
                                    .keyboardType(.numberPad)
                                    #endif
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 120)
                            }

                            if viewModel.downloadCandidateRequestContext != nil {
                                Toggle("Use browser credentials", isOn: $viewModel.useBrowserCredentials)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }

                if let err = submitErrorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                // MARK: - Action Button
                Section {
                    Button {
                        submitDownload()
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isResumeMode ? "Resume" : info.buttonTitle)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .disabled(isSubmitting || viewModel.downloadCandidateURL == nil)
                    .listRowBackground(isResumeMode ? Color.green : info.badgeColor)
                }
            }
            .navigationTitle(isResumeMode ? "Resume Download" : "Download File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.resumeTargetTransferID = nil
                        viewModel.resumeTargetTransferName = nil
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .onAppear {
                let (base, ext) = FilenameExtensionHelper.split(filename: viewModel.downloadCandidateFilename)
                baseFilename = base
                let defaultExt: String = {
                    if let resExt = viewModel.activeDownloadResource?.suggestedExtension, !resExt.isEmpty {
                        return resExt
                    }
                    if let candExt = viewModel.activeDownloadCandidate?.suggestedFilename {
                        let e = FilenameExtensionHelper.split(filename: candExt).ext
                        if !e.isEmpty { return e }
                    }
                    let detected = FilenameExtensionHelper.detectExtension(
                        from: viewModel.downloadCandidateURL,
                        mimeType: viewModel.activeDownloadCandidate?.mimeType ?? viewModel.activeDownloadResource?.mimeType
                    )
                    return detected.isEmpty ? "mp4" : detected
                }()
                fileExtension = ext.isEmpty ? defaultExt : ext
                viewModel.downloadCandidateFilename = FilenameExtensionHelper.combine(base: baseFilename, ext: fileExtension)
            }
        }
    }

    private var isResumeMode: Bool {
        viewModel.resumeTargetTransferID != nil
    }

    private struct TechnicalDetailRow {
        let label: String
        let value: String
    }

    private var technicalDetailRows: [TechnicalDetailRow] {
        let res = viewModel.activeDownloadResource
        let cand = viewModel.activeDownloadCandidate
        let variant = res.flatMap { viewModel.variantStreamItems[$0.id] }
        let selected = viewModel.selectedQualityOption
        var rows: [TechnicalDetailRow] = []

        // Size / Predicted Size
        if res?.isLive == true || variant?.isLive == true {
            rows.append(TechnicalDetailRow(label: "Size", value: "Live Broadcast"))
        } else if let bytes = selected?.estimatedSizeBytes ?? variant?.estimatedSizeBytes {
            rows.append(TechnicalDetailRow(label: "Predicted Size", value: "~\(StreamQualityOption.formatByteSize(bytes))"))
        } else if let sizeText = selected?.estimatedSizeText ?? variant?.estimatedSizeText,
                  !sizeText.isEmpty && sizeText != "Size unavailable" {
            rows.append(TechnicalDetailRow(label: "Predicted Size", value: sizeText))
        } else if let size = res?.estimatedSize ?? cand?.estimatedSize, size > 0 {
            rows.append(TechnicalDetailRow(label: "Size", value: StreamQualityOption.formatByteSize(size)))
        } else {
            rows.append(TechnicalDetailRow(label: "Size", value: "Unknown"))
        }

        // Resolution
        let variantResText: String? = variant?.resolutionText ?? variant?.resolution.map { "\($0.width) × \($0.height)" }
        let resolvedResText: String? = selected?.resolutionText ?? variantResText ?? res?.resolutionText
        if let resText = resolvedResText, !resText.isEmpty {
            rows.append(TechnicalDetailRow(label: "Resolution", value: resText))
        } else if let w = res?.hlsVariantPreferences?.maximumWidth, let h = res?.hlsVariantPreferences?.maximumHeight {
            rows.append(TechnicalDetailRow(label: "Resolution", value: "\(w) × \(h)"))
        }

        // Audio
        if let res {
            switch res.trackType {
            case .muxed:
                rows.append(TechnicalDetailRow(label: "Audio", value: res.audioLanguage.map { "Yes (\($0.uppercased()))" } ?? "Yes"))
            case .audioOnly:
                rows.append(TechnicalDetailRow(label: "Audio", value: res.audioLanguage.map { "Audio Only (\($0.uppercased()))" } ?? "Audio Only"))
            case .videoOnly:
                rows.append(TechnicalDetailRow(label: "Audio", value: "No (Video Only)"))
            case .subtitles:
                rows.append(TechnicalDetailRow(label: "Audio", value: "No (Subtitles)"))
            default:
                if res.resourceType == .audio {
                    rows.append(TechnicalDetailRow(label: "Audio", value: "Audio Only"))
                } else if res.resourceType == .video {
                    rows.append(TechnicalDetailRow(label: "Audio", value: "Unknown"))
                }
            }
        }

        // Subtitles
        if let res, res.resourceType == .video || res.isStreamingManifest || variant != nil || selected != nil {
            let hasSubs = (selected?.hasSubtitles == true) || (variant?.hasSubtitles == true) || res.trackType == .subtitles
            rows.append(TechnicalDetailRow(label: "Subtitles", value: hasSubs ? "Yes" : "No"))
        }

        // Bitrate
        if let bitrate = selected?.bitrateText ?? variant?.bitrateText, !bitrate.isEmpty {
            rows.append(TechnicalDetailRow(label: "Bitrate", value: bitrate))
        }

        // Codec
        if let codecs = selected?.codecs ?? variant?.codecs ?? res?.codecs ?? cand?.codecs, !codecs.isEmpty {
            rows.append(TechnicalDetailRow(label: "Codec", value: codecs))
        }

        // Duration
        if let duration = res?.formattedDuration, !duration.isEmpty {
            rows.append(TechnicalDetailRow(label: "Duration", value: duration))
        }

        // Format / Container
        let ext = fileExtension.uppercased()
        if res?.isStreamingManifest == true || cand?.kind == .hlsManifest || cand?.kind == .dashManifest {
            let streamKind = (viewModel.downloadCandidateURL?.pathExtension.lowercased() == "mpd" || cand?.kind == .dashManifest) ? "DASH (.mpd)" : "HLS (.m3u8)"
            rows.append(TechnicalDetailRow(label: "Format", value: ext.isEmpty ? streamKind : "\(streamKind) → \(ext)"))
        } else if let container = res?.container, !container.isEmpty {
            rows.append(TechnicalDetailRow(label: "Format", value: container))
        } else if !ext.isEmpty {
            rows.append(TechnicalDetailRow(label: "Format", value: ext))
        }

        if let host = viewModel.downloadCandidateURL?.host, !host.isEmpty {
            rows.append(TechnicalDetailRow(label: "Host", value: host))
        }

        return rows
    }

    private func submitDownload() {
        submitErrorMessage = nil
        isSubmitting = true
        viewModel.downloadCandidateFilename = FilenameExtensionHelper.combine(base: baseFilename, ext: fileExtension)

        let resumeID = viewModel.resumeTargetTransferID
        let resource = viewModel.activeDownloadResource
        let url = viewModel.downloadCandidateURL

        Task { @MainActor in
            do {
                if let targetID = resumeID, let rm = viewModel.recoveryManager {
                    if let res = resource {
                        _ = try await rm.reconnectBrowserResource(transferID: targetID, resource: res)
                    } else if let url {
                        try await rm.updateDownloadLink(transferID: targetID, newURLText: url.absoluteString)
                    }
                    viewModel.resumeTargetTransferID = nil
                    viewModel.resumeTargetTransferName = nil
                    isSubmitting = false
                    presentationMode.wrappedValue.dismiss()
                    viewModel.onOpenDownloads?()
                } else {
                    try await viewModel.executeDownload()
                    isSubmitting = false
                    presentationMode.wrappedValue.dismiss()
                }
            } catch {
                submitErrorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

// MARK: - Platform WebView Wrapper (WebKit)

#if canImport(WebKit)

#if canImport(UIKit)
public final class BrowserContainerView: UIView {
    private var currentWebView: WKWebView?

    public func setWebView(_ webView: WKWebView) {
        if currentWebView === webView { return }
        currentWebView?.removeFromSuperview()
        currentWebView = webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
}

public struct PlatformWebView: UIViewRepresentable {
    @ObservedObject public var viewModel: BrowserViewModel
    public let tabID: UUID

    public init(viewModel: BrowserViewModel, tabID: UUID) {
        self.viewModel = viewModel
        self.tabID = tabID
    }

    public func makeCoordinator() -> BrowserWebViewCoordinator {
        viewModel.webViewSession(for: tabID).coordinator
    }

    public func makeUIView(context: Context) -> BrowserContainerView {
        let container = BrowserContainerView()
        let webView = viewModel.webViewSession(for: tabID).webView
        container.setWebView(webView)
        viewModel.attachWebView(webView, for: tabID)
        viewModel.ensureRestoredTabLoaded(for: tabID)
        return container
    }

    public func updateUIView(_ uiView: BrowserContainerView, context: Context) {
        let webView = viewModel.webViewSession(for: tabID).webView
        uiView.setWebView(webView)
        viewModel.attachWebView(webView, for: tabID)
    }
}
#elseif canImport(AppKit)
public final class BrowserContainerView: NSView {
    private var currentWebView: WKWebView?

    public func setWebView(_ webView: WKWebView) {
        if currentWebView === webView { return }
        currentWebView?.removeFromSuperview()
        currentWebView = webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
}

public struct PlatformWebView: NSViewRepresentable {
    @ObservedObject public var viewModel: BrowserViewModel
    public let tabID: UUID

    public init(viewModel: BrowserViewModel, tabID: UUID) {
        self.viewModel = viewModel
        self.tabID = tabID
    }

    public func makeCoordinator() -> BrowserWebViewCoordinator {
        viewModel.webViewSession(for: tabID).coordinator
    }

    public func makeNSView(context: Context) -> BrowserContainerView {
        let container = BrowserContainerView()
        let webView = viewModel.webViewSession(for: tabID).webView
        container.setWebView(webView)
        viewModel.attachWebView(webView, for: tabID)
        viewModel.ensureRestoredTabLoaded(for: tabID)
        return container
    }

    public func updateNSView(_ nsView: BrowserContainerView, context: Context) {
        let webView = viewModel.webViewSession(for: tabID).webView
        nsView.setWebView(webView)
        viewModel.attachWebView(webView, for: tabID)
    }
}
#endif

@MainActor
final class BrowserWebViewSession {
    // Process isolation: dedicated process pools for standard vs incognito tabs
    private static let standardProcessPool = WKProcessPool()
    private static let incognitoProcessPool = WKProcessPool()

    let tabID: UUID
    let mediaDiscoveryBridge: BrowserMediaDiscoveryBridge
    let blobCaptureService: BrowserBlobCaptureService
    let mseCaptureService: BrowserMSECaptureService
    let webView: WKWebView
    let coordinator: BrowserWebViewCoordinator

    init(tabID: UUID, viewModel: BrowserViewModel) {
        self.tabID = tabID
        let tab = viewModel.tabs.first(where: { $0.id == tabID })
        let isIncognito = tab?.isIncognito ?? false
        let isDesktop = tab?.isDesktopMode ?? false

        let config = WKWebViewConfiguration()
        // Strict privacy isolation: use dedicated process pool and non-persistent store for incognito
        config.processPool = isIncognito ? Self.incognitoProcessPool : Self.standardProcessPool
        config.websiteDataStore = isIncognito ? WKWebsiteDataStore.nonPersistent() : .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = !viewModel.isPopupBlockerEnabled
#if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 13.0, *) {
            config.defaultWebpagePreferences.preferredContentMode = isDesktop ? .desktop : .mobile
        }
#endif

        // Native Content Blocking & Privacy Shields (Granular Multi-List Configuration)
        viewModel.contentBlocker.apply(
            to: config,
            isAdBlockerEnabled: viewModel.isAdBlockerEnabled,
            isTrackerBlockerEnabled: viewModel.isTrackerBlockerEnabled,
            isAnnoyanceBlockerEnabled: viewModel.isAnnoyanceBlockerEnabled,
            cookiePolicy: viewModel.cookiePolicy,
            isCurrentDomainWhitelisted: false
        )

        let bridge = BrowserMediaDiscoveryBridge()
        bridge.observationHandler = { [weak viewModel] observation in
            DispatchQueue.main.async {
                viewModel?.handleMediaDiscoveryObservation(observation, tabID: tabID)
            }
        }
        bridge.install(on: config)
        self.mediaDiscoveryBridge = bridge

        let blobCaptureService = BrowserBlobCaptureService(
            destinationDirectoryURL: viewModel.streamingDestinationDirectoryURL
                .appendingPathComponent("BlobExports", isDirectory: true)
        )
        self.blobCaptureService = blobCaptureService
        let blobHandler = BlobCaptureWebKitHandler(
            receiver: blobCaptureService.receiver
        )
        blobHandler.acknowledgementHandler = { [weak viewModel] acknowledgement in
            DispatchQueue.main.async {
                viewModel?.handleBlobCaptureAcknowledgement(acknowledgement, tabID: tabID)
            }
        }
        blobHandler.install(on: config)

        let mseCaptureService = BrowserMSECaptureService(
            destinationDirectoryURL: viewModel.streamingDestinationDirectoryURL
                .appendingPathComponent("MSEExports", isDirectory: true)
        )
        self.mseCaptureService = mseCaptureService
        let mseHandler = BrowserMSECaptureWebKitHandler(
            receiver: mseCaptureService.receiver
        )
        mseHandler.acknowledgementHandler = { [weak viewModel] acknowledgement in
            DispatchQueue.main.async {
                viewModel?.handleMSECaptureAcknowledgement(acknowledgement, tabID: tabID)
            }
        }
        mseHandler.install(on: config)

        let diagHandler = BrowserDiagnosticWebKitHandler(tabID: tabID)
        diagHandler.install(on: config)

        // Frame-busting & anti-hijack defense (Milestone B.2)
        config.userContentController.addUserScript(BrowserFrameBustingDefense.makeUserScript())
        // Media playback optimization (ManagedMediaSource & playsinline activation)
        config.userContentController.addUserScript(BrowserMediaPlaybackOptimization.makeUserScript())

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = isDesktop
            ? BrowserViewModel.defaultDesktopUserAgent
            : BrowserViewModel.defaultMobileUserAgent
        self.webView = webView
        let coordinator = BrowserWebViewCoordinator(viewModel: viewModel, tabID: tabID)
        self.coordinator = coordinator
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        #if os(iOS)
        webView.scrollView.delegate = coordinator
        #endif
        coordinator.setupProgressObserver(for: webView)

        // Automatically load restored URL exactly once
        if let url = tab?.url,
           webView.url == nil,
           url.absoluteString != "about:blank" {
            webView.load(URLRequest(url: url))
        }
    }

    func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        #if os(iOS)
        webView.scrollView.delegate = nil
        #endif
        webView.configuration.userContentController.removeAllUserScripts()
        mediaDiscoveryBridge.reset()
    }
}

// MARK: - WKNavigationDelegate & WKUIDelegate Coordinator

public final class BrowserWebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    public weak var viewModel: BrowserViewModel?
    private let tabID: UUID?
    private var progressObserver: NSKeyValueObservation?
    private let redirectLoopDetector = BrowserRedirectLoopDetector()
    fileprivate var lastScrollOffsetY: CGFloat = 0

    // Navigation generation to drop late/stale callbacks from superseded navigations
    public private(set) var navigationGeneration: UInt64 = 0
    public private(set) var activeNavigationTarget: URL?

    public init(viewModel: BrowserViewModel, tabID: UUID? = nil) {
        self.viewModel = viewModel
        self.tabID = tabID
        super.init()
    }

    deinit {
        progressObserver?.invalidate()
    }

    public func startNavigation(generation: UInt64, target: URL?) {
        self.navigationGeneration = generation
        self.activeNavigationTarget = target
    }

    public func setupProgressObserver(for webView: WKWebView) {
        progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            DispatchQueue.main.async {
                guard let self, let vm = self.viewModel else { return }
                if let tabID = self.tabID {
                    vm.updateWebViewProgress(for: tabID, webView: wv)
                } else {
                    vm.estimatedProgress = wv.estimatedProgress
                }
            }
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let gen: UInt64
        if let vm = self.viewModel, let tabID = self.tabID {
            gen = vm.nextNavigationGeneration(for: tabID, target: webView.url)
        } else {
            navigationGeneration &+= 1
            gen = navigationGeneration
        }
        self.navigationGeneration = gen
        self.activeNavigationTarget = webView.url
        let capturedGen = gen

        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Provisional navigation started (gen \(gen))",
            url: webView.url,
            tabID: tabID
        )
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            guard self.navigationGeneration == capturedGen else { return }
            if let tabID = self.tabID {
                guard vm.isNavigationCurrent(tabID: tabID, generation: capturedGen, url: webView.url) else { return }
                vm.updateWebViewState(
                    for: tabID,
                    webView: webView,
                    url: webView.url,
                    title: nil,
                    isLoading: true,
                    generation: capturedGen
                )
                vm.resetMediaDiscovery(for: tabID)
                vm.errorMessage = nil
                return
            }
            if let activeID = vm.activeTabID {
                vm.resetMediaDiscovery(for: activeID)
            }
            vm.isLoading = true
            vm.errorMessage = nil
            vm.mediaDiscoveryBridge.reset()
            if let url = webView.url, url.absoluteString != "about:blank" {
                vm.currentURL = url
                vm.urlInputText = url.absoluteString
            }
            vm.canGoBack = webView.canGoBack
            vm.canGoForward = webView.canGoForward
        }
    }

    public func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        BrowserDiagnosticLogger.shared.log(
            category: .redirect,
            message: "Server redirect received",
            url: webView.url,
            tabID: tabID
        )
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let capturedGen = self.navigationGeneration
        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Navigation content committed (gen \(capturedGen))",
            url: webView.url,
            tabID: tabID
        )

        redirectLoopDetector.reset()

        if let host = webView.url?.host, let vm = viewModel {
            if let tabID = self.tabID {
                guard vm.isNavigationCurrent(tabID: tabID, generation: capturedGen, url: webView.url) else { return }
                vm.discoveryCoordinator.setNavigationGeneration(capturedGen, for: tabID)
                vm.discoveryCoordinator.nextDocumentGeneration(for: tabID)
            }
            vm.recordTabOrigin(host, for: tabID)
            let isWhitelisted = BrowserDomainMatcher.isDomainWhitelisted(
                host,
                in: Array(vm.adBlockerWhitelistedDomains)
            )
            vm.contentBlocker.update(
                for: webView,
                isAdBlockerEnabled: vm.isAdBlockerEnabled,
                isTrackerBlockerEnabled: vm.isTrackerBlockerEnabled,
                isAnnoyanceBlockerEnabled: vm.isAnnoyanceBlockerEnabled,
                cookiePolicy: vm.cookiePolicy,
                isCurrentDomainWhitelisted: isWhitelisted
            )
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let currentURL = webView.url
        let capturedGen = self.navigationGeneration
        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Navigation finished (gen \(capturedGen)): \(webView.title ?? "")",
            url: currentURL,
            tabID: tabID,
            details: ["title": webView.title ?? ""]
        )

        // Inspect and capture session snapshot (User-Agent, language, and all cookies by domain)
        Task { @MainActor [weak self] in
            guard let self, self.navigationGeneration == capturedGen else { return }
            let snapshot = await DownloadRequestEnricher.snapshot(from: webView)
            BrowserDiagnosticLogger.shared.log(
                category: .cookie,
                message: "Browser session snapshot captured with \(snapshot.allCookies.count) cookies across \(snapshot.cookiesByDomain.count) domains and UA: \(snapshot.userAgent)",
                url: currentURL,
                tabID: self.tabID,
                details: ["domains": snapshot.cookiesByDomain.keys.joined(separator: ", ")]
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            guard self.navigationGeneration == capturedGen else { return }
            if let tabID = self.tabID {
                guard vm.isNavigationCurrent(tabID: tabID, generation: capturedGen, url: webView.url) else { return }
                vm.updateWebViewState(
                    for: tabID,
                    webView: webView,
                    url: webView.url,
                    title: webView.title,
                    isLoading: false,
                    generation: capturedGen
                )
                return
            }
            vm.isLoading = false
            if let url = webView.url, url.absoluteString != "about:blank" {
                vm.currentURL = url
                vm.urlInputText = url.absoluteString
            }
            vm.pageTitle = webView.title ?? ""
            vm.canGoBack = webView.canGoBack
            vm.canGoForward = webView.canGoForward
        }
    }

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        BrowserDiagnosticLogger.shared.log(
            category: .challenge,
            message: "Authentication challenge received for host: \(challenge.protectionSpace.host)",
            url: webView.url,
            tabID: tabID,
            details: [
                "host": challenge.protectionSpace.host,
                "method": challenge.protectionSpace.authenticationMethod,
                "previousFailures": "\(challenge.previousFailureCount)"
            ]
        )
        // HTTPS Certificate validation and user override handling (Milestone B.2)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            let host = challenge.protectionSpace.host
            let decisionStore = viewModel?.certificateDecisionStore ?? BrowserCertificateDecisionStore.shared
            if decisionStore.isHostAllowedForSession(host) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }

            var secError: CFError?
            let isTrusted = SecTrustEvaluateWithError(serverTrust, &secError)
            if isTrusted {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            let errorMsg = secError.map { CFErrorCopyDescription($0) as String }
                ?? "The security certificate for this server is untrusted, expired, or invalid."

            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.certificateWarningPrompt = BrowserCertificatePrompt(
                    host: host,
                    message: "Your connection to '\(host)' is not private (\(errorMsg)). Attackers might be trying to steal your credentials or personal information.",
                    onProceed: {
                        decisionStore.allowHostForSession(host)
                        completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    },
                    onCancel: {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                    }
                )
            }
            return
        }

        let authHandler = viewModel?.authenticationHandler ?? BrowserAuthenticationHandler.shared
        authHandler.handleChallenge(
            challenge,
            targetPageURL: webView.url,
            completionHandler: completionHandler
        )
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        let capturedGen = self.navigationGeneration
        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Navigation failed (gen \(capturedGen)): \(error.localizedDescription)",
            url: webView.url,
            tabID: tabID,
            details: [
                "domain": nsError.domain,
                "code": "\(nsError.code)",
                "isCancelled": "\(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)"
            ]
        )
        if let vm = self.viewModel, let tabID = self.tabID {
            guard vm.isNavigationCurrent(tabID: tabID, generation: capturedGen, url: webView.url) else {
                BrowserDiagnosticLogger.shared.log(
                    category: .navigation,
                    message: "Ignored didFail from stale navigation generation \(capturedGen)",
                    url: webView.url,
                    tabID: tabID
                )
                return
            }
        }
        handleNavigationError(error, webView: webView, generation: capturedGen)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        let capturedGen = self.navigationGeneration
        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Provisional navigation failed (gen \(capturedGen)): \(error.localizedDescription)",
            url: webView.url,
            tabID: tabID,
            details: [
                "domain": nsError.domain,
                "code": "\(nsError.code)",
                "isCancelled": "\(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)"
            ]
        )
        if let vm = self.viewModel, let tabID = self.tabID {
            guard vm.isNavigationCurrent(tabID: tabID, generation: capturedGen, url: webView.url) else {
                BrowserDiagnosticLogger.shared.log(
                    category: .navigation,
                    message: "Ignored didFailProvisionalNavigation from stale navigation generation \(capturedGen)",
                    url: webView.url,
                    tabID: tabID
                )
                return
            }
        }
        handleNavigationError(error, webView: webView, generation: capturedGen)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        BrowserDiagnosticLogger.shared.log(
            category: .processTermination,
            message: "WebContent process terminated. Triggering reload.",
            url: webView.url,
            tabID: tabID
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, let tabID = self.tabID else { return }
            self.viewModel?.handleBlobProcessTermination(for: tabID)
            self.viewModel?.handleMSEProcessTermination(for: tabID)
        }
        guard webView.url != nil else { return }
        webView.reload()
    }

    private func handleErrorInternal(_ error: Error) {
        let nsError = error as NSError
        // Ignore NSURLErrorCancelled (-999), emitted on redirection or intentional user stops
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        // Ignore WebKit plugin handoff (204) and frame load interrupted by policy (102)
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 204 || nsError.code == 102) {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            vm.isLoading = false
            vm.errorMessage = error.localizedDescription
        }
    }

    private func handleNavigationError(_ error: Error, webView: WKWebView, generation: UInt64? = nil) {
        if let tabID {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.handleWebViewError(error, for: tabID, webView: webView, generation: generation)
            }
        } else {
            handleErrorInternal(error)
        }
    }

    // MARK: - WKUIDelegate

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let destURL = navigationAction.request.url
        let isUserInitiated = navigationAction.navigationType == .linkActivated
        let isPopupBlockerEnabled = viewModel?.isPopupBlockerEnabled ?? true

        let decision = BrowserPopupPolicyEvaluator.evaluateWindowOpen(
            destinationURL: destURL,
            currentURL: webView.url,
            isUserInitiated: isUserInitiated,
            isPopupBlockerEnabled: isPopupBlockerEnabled
        )

        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "createWebViewWith decision: \(decision)",
            url: destURL,
            tabID: tabID,
            details: [
                "targetFrame": navigationAction.targetFrame == nil ? "nil" : "non-nil",
                "navigationType": "\(navigationAction.navigationType.rawValue)",
                "isUserInitiated": "\(isUserInitiated)"
            ]
        )

        switch decision {
        case .openInNewTab:
            if let destURL = destURL {
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel?.createNewTab(with: destURL)
                }
            }
            return nil

        case .allowSameTab:
            webView.load(navigationAction.request)
            return nil

        case .blockPopunder:
            BrowserDiagnosticLogger.shared.log(
                category: .policy,
                message: "Blocked advertisement popunder to: \(destURL?.host ?? "")",
                url: destURL,
                tabID: tabID
            )
            return nil

        case .promptConfirmation(let reason, let isSuspicious):
            if let destURL = destURL {
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel?.promptRedirectConfirmation(
                        destinationURL: destURL,
                        originURL: webView.url,
                        sourceTabID: self?.tabID,
                        reason: reason,
                        isSuspicious: isSuspicious
                    )
                }
            }
            return nil

        case .promptExternalScheme(let isSuspicious):
            if let destURL = destURL {
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel?.promptRedirectConfirmation(
                        destinationURL: destURL,
                        originURL: webView.url,
                        sourceTabID: self?.tabID,
                        reason: .externalAppScheme,
                        isSuspicious: isSuspicious
                    )
                }
            }
            return nil
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        BrowserDiagnosticLogger.shared.log(
            category: .challenge,
            message: "JavaScript alert panel: \(message)",
            url: frame.request.url,
            tabID: tabID
        )
        completionHandler()
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        BrowserDiagnosticLogger.shared.log(
            category: .challenge,
            message: "JavaScript confirm panel: \(message)",
            url: frame.request.url,
            tabID: tabID
        )
        completionHandler(true)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        BrowserDiagnosticLogger.shared.log(
            category: .challenge,
            message: "JavaScript prompt panel: \(prompt)",
            url: frame.request.url,
            tabID: tabID
        )
        let pHandler = viewModel?.promptHandler ?? BrowserPromptHandler.shared
        pHandler.handlePrompt(
            prompt: prompt,
            defaultText: defaultText,
            frameURL: frame.request.url,
            completionHandler: completionHandler
        )
    }

    @available(iOS 15.0, macOS 12.0, *)
    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let permType: BrowserPermissionType
        switch type {
        case .camera: permType = .camera
        case .microphone: permType = .microphone
        case .cameraAndMicrophone: permType = .cameraAndMicrophone
        @unknown default: permType = .cameraAndMicrophone
        }

        let dLogger = viewModel?.diagnosticLogger ?? BrowserDiagnosticLogger.shared
        dLogger.log(
            category: .policy,
            message: "Requesting media capture permission: \(permType.rawValue) for origin \(origin.host)",
            url: frame.request.url,
            tabID: tabID
        )

        let permCoordinator = viewModel?.permissionCoordinator ?? BrowserPermissionCoordinator.shared
        permCoordinator.decidePermission(
            type: permType,
            originHost: origin.host,
            frameURL: frame.request.url
        ) { decision in
            switch decision {
            case .grant: decisionHandler(.grant)
            case .deny: decisionHandler(.deny)
            case .prompt: decisionHandler(.prompt)
            }
        }
    }

#if canImport(UIKit)
    @available(iOS 13.0, *)
    public func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        guard let linkURL = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }

        let config = UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: nil
        ) { [weak self] _ in
            guard let self, let vm = self.viewModel else {
                return UIMenu(title: "", children: [])
            }

            let openAction = UIAction(
                title: "Open",
                image: UIImage(systemName: "safari")
            ) { _ in
                Task { @MainActor in
                    vm.load(url: linkURL)
                }
            }

            let openInNewTabAction = UIAction(
                title: "Open in New Tab",
                image: UIImage(systemName: "plus.square.on.square")
            ) { _ in
                Task { @MainActor in
                    vm.createNewTab(with: linkURL, isIncognito: false)
                }
            }

            let openInPrivateTabAction = UIAction(
                title: "Open in Private Tab",
                image: UIImage(systemName: "eye.slash")
            ) { _ in
                Task { @MainActor in
                    vm.createNewTab(with: linkURL, isIncognito: true)
                }
            }

            let copyAction = UIAction(
                title: "Copy Link Address",
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.url = linkURL
            }

            let shareAction = UIAction(
                title: "Share Link...",
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                Task { @MainActor in
                    vm.shareURL(linkURL)
                }
            }

            let downloadAction = UIAction(
                title: "Download Linked File",
                image: UIImage(systemName: "arrow.down.circle")
            ) { _ in
                Task { @MainActor in
                    try? await vm.downloadDelegate?.handleDownloadRequest(
                        url: linkURL,
                        filename: nil,
                        threadCount: 4,
                        speedLimitBytesPerSecond: nil,
                        headers: [:]
                    )
                }
            }

            return UIMenu(
                title: linkURL.absoluteString,
                children: [
                    openAction,
                    openInNewTabAction,
                    openInPrivateTabAction,
                    copyAction,
                    shareAction,
                    downloadAction
                ]
            )
        }

        completionHandler(config)
    }
#endif



    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        BrowserDiagnosticLogger.shared.log(
            category: .policy,
            message: "Deciding policy for navigation action",
            url: url,
            tabID: tabID,
            details: [
                "method": navigationAction.request.httpMethod ?? "GET",
                "targetFrame": navigationAction.targetFrame == nil ? "nil" : "non-nil",
                "isMainFrame": "\(navigationAction.targetFrame?.isMainFrame ?? false)",
                "navigationType": "\(navigationAction.navigationType.rawValue)"
            ]
        )

        // Magnet links identify torrent metadata rather than HTTP resources.
        // Intercept them before the normal web-navigation scheme check so
        // WebKit cannot hand them to an unrelated URL-scheme handler.
        if url.scheme?.lowercased() == "magnet" {
            decisionHandler(.cancel)
            guard let magnet = try? MagnetLinkParser.parse(url) else {
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel?.errorMessage = "This magnet link is invalid or unsupported."
                }
                return
            }
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let vm = self.viewModel else { return }
                vm.presentMagnetLink(magnet, sourcePageURL: webView?.url)
            }
            return
        }

        // Subframe navigation (such as Cloudflare Turnstile iframes, about:srcdoc, about:blank)
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame {
            if BrowserURLResolver.isValidWebNavigationURL(url) {
                decisionHandler(.allow)
                return
            }
        }

        let isAllowedInBrowser = viewModel?.isURLAllowedInBrowser(url) ?? false
        if let link = BrowserViewModel.externalAppPrompt(
            for: url,
            navigationAction: navigationAction,
            currentURL: webView.url,
            isExplicitlyAllowed: isAllowedInBrowser
        ) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.externalAppLinkPrompt = link
            }
            return
        }

        // Native download request via HTML5 <a download> attribute
        if #available(iOS 14.5, macOS 11.3, *) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
        }

        // Redirect loop detection for automatic navigations (Milestone B.2)
        if isMainFrame && navigationAction.navigationType == .other {
            let loopEvaluation = redirectLoopDetector.recordNavigation(url: url)
            if loopEvaluation.isLoopDetected {
                decisionHandler(.cancel)
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel?.errorMessage = loopEvaluation.reason
                    self?.viewModel?.isLoading = false
                }
                return
            }
        } else if isMainFrame && navigationAction.navigationType == .linkActivated {
            redirectLoopDetector.reset()
        }

        let isPopupBlockerEnabled = viewModel?.isPopupBlockerEnabled ?? true
        let originChain = viewModel?.activeTabOriginChain ?? []
        let decision = BrowserPopupPolicyEvaluator.evaluateNavigation(
            destinationURL: url,
            currentURL: webView.url,
            navigationType: navigationAction.navigationType.rawValue,
            isTargetFrameNil: navigationAction.targetFrame == nil,
            isPopupBlockerEnabled: isPopupBlockerEnabled,
            originChain: originChain
        )

        switch decision {
        case .allowSameTab:
            if let host = url.host {
                viewModel?.recordTabOrigin(host, for: tabID)
            }
            decisionHandler(.allow)

        case .openInNewTab:
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.createNewTab(with: url)
            }

        case .blockPopunder:
            decisionHandler(.cancel)
            BrowserDiagnosticLogger.shared.log(
                category: .policy,
                message: "Blocked advertisement redirect or popunder to: \(url.host ?? "")",
                url: url,
                tabID: tabID
            )

        case .promptConfirmation(let reason, let isSuspicious):
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.promptRedirectConfirmation(
                    destinationURL: url,
                    originURL: webView.url,
                    sourceTabID: self?.tabID,
                    reason: reason,
                    isSuspicious: isSuspicious
                )
            }

        case .promptExternalScheme(let isSuspicious):
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.promptRedirectConfirmation(
                    destinationURL: url,
                    originURL: webView.url,
                    sourceTabID: self?.tabID,
                    reason: .externalAppScheme,
                    isSuspicious: isSuspicious
                )
            }
        }
    }

    @available(iOS 14.5, macOS 11.3, *)
    public func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard let response = navigationResponse.response as? HTTPURLResponse,
              let url = response.url ?? navigationResponse.response.url else {
            decisionHandler(.allow)
            return
        }

        // Case-insensitive header lookup for Content-Disposition and Content-Type
        var disposition: String? = nil
        var contentType: String? = nil
        for (k, v) in response.allHeaderFields {
            let keyStr = String(describing: k)
            if keyStr.caseInsensitiveCompare("Content-Disposition") == .orderedSame {
                disposition = v as? String
            } else if keyStr.caseInsensitiveCompare("Content-Type") == .orderedSame {
                contentType = v as? String
            }
        }
        if contentType == nil {
            contentType = response.mimeType
        }

        BrowserDiagnosticLogger.shared.log(
            category: .policy,
            message: "Deciding policy for navigation response (HTTP \(response.statusCode))",
            url: url,
            tabID: tabID,
            details: [
                "statusCode": "\(response.statusCode)",
                "mimeType": contentType ?? "unknown",
                "disposition": disposition ?? "none"
            ]
        )

        let outcome = BrowserNavigationResponseClassifier.evaluate(
            url: url,
            statusCode: response.statusCode,
            contentDisposition: disposition,
            contentType: contentType,
            canShowMIMEType: navigationResponse.canShowMIMEType
        )

        if outcome.isStreamingManifest, let resource = outcome.resource {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.viewModel?.ingestMediaResource(resource, tabID: self.tabID)
            }
        }

        // Intercept top-level (main-frame) HLS stream navigations to render
        // an inline HTML5 player in the existing tab, preventing iOS WebKit
        // from presenting a full-screen native media document that dismisses
        // the tab upon closing.
        if navigationResponse.isForMainFrame && outcome.shouldPlayHLSInline {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self = self, let webView = webView, let vm = self.viewModel else { return }
                vm.loadInlineHLSPlayer(
                    for: url,
                    title: outcome.suggestedFilename,
                    in: webView,
                    tabID: self.tabID
                )
            }
            return
        }

        if outcome.shouldInterceptAsDownload {
            if #available(iOS 14.5, macOS 11.3, *) {
                // Use native WebKit download conversion to resolve redirects and server filename
                decisionHandler(.download)
            } else {
                // Fallback: cancel rendering and prompt directly
                decisionHandler(.cancel)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let vm = self.viewModel else { return }
                    vm.captureBrowserRequestContext(
                        for: url,
                        pageURL: webView.url,
                        webView: webView,
                        source: .nativeInterception
                    ) { context in
                        vm.promptDownload(
                            for: url,
                            suggestedFilename: outcome.suggestedFilename,
                            requestContext: context
                        )
                    }
                }
            }
        } else {
            decisionHandler(.allow)
        }
    }

    @available(iOS 14.5, macOS 11.3, *)
    public func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate (Native Interception & Handoff)

    @available(iOS 14.5, macOS 11.3, *)
    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // Resolve original and final redirected URLs
        let originalURL = download.originalRequest?.url ?? response.url
        let finalURL = response.url ?? originalURL

        // Halt WebKit internal disk download to prevent duplicate downloading and bypassing coordinator
        completionHandler(nil)

        guard let destinationURL = finalURL, BrowserURLResolver.isValidDownloadURL(destinationURL) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let vm = self.viewModel,
                  let browser = vm.webView(for: self.tabID) else { return }
            vm.captureBrowserRequestContext(
                for: destinationURL,
                pageURL: browser.url,
                webView: browser,
                source: .nativeInterception,
                customHeaders: download.originalRequest?.allHTTPHeaderFields ?? [:]
            ) { context in
                vm.handleNativeDownloadHandoff(
                    originalURL: originalURL ?? destinationURL,
                    finalURL: destinationURL,
                    suggestedFilename: suggestedFilename,
                    mimeType: response.mimeType,
                    expectedLength: response.expectedContentLength > 0 ? response.expectedContentLength : nil,
                    source: .nativeWebKitDownload,
                    requestContext: context
                )
            }
        }
    }

    @available(iOS 14.5, macOS 11.3, *)
    public func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void
    ) {
        // Preserve valid HTTP/HTTPS redirects during download resolution
        if let newURL = request.url, BrowserURLResolver.isValidDownloadURL(newURL) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    @available(iOS 14.5, macOS 11.3, *)
    public func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        // Ignore intentional cancellations during handoff to DownloadCoordinator
        if BrowserDownloadInterceptionManager.isIntentionalHandoffCancellation(error) {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.viewModel?.errorMessage = "Download preparation failed: \(error.localizedDescription)"
        }
    }

    @available(iOS 14.5, macOS 11.3, *)
    public func downloadDidFinish(_ download: WKDownload) {
        // WebKit download finished
    }
}

#if os(iOS)
extension BrowserWebViewCoordinator: UIScrollViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        lastScrollOffsetY = scrollView.contentOffset.y
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating else { return }
        let y = scrollView.contentOffset.y
        if y <= 10 {
            lastScrollOffsetY = y
            viewModel?.setToolbarCollapsed(false)
            return
        }
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        if maxY > 40 && y >= maxY - 10 {
            lastScrollOffsetY = y
            return
        }
        let delta = y - lastScrollOffsetY
        if delta > 14 {
            lastScrollOffsetY = y
            viewModel?.setToolbarCollapsed(true)
        } else if delta < -14 {
            lastScrollOffsetY = y
            viewModel?.setToolbarCollapsed(false)
        }
    }
}
#endif

#endif // canImport(WebKit)

#endif // canImport(SwiftUI)
