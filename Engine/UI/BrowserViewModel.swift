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
    @Published public var existingTransferWarning: (transferID: String, statusDot: DownloadStatusDot, transferName: String)? = nil
    var activeMSECaptureSuggestedFilename: String? = nil

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
    var streamingExecutionTask: Task<Void, Never>?

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
    var activeBlobCaptureID: String?
    var activeBlobCaptureTabID: UUID?
    var activeBlobCaptureOriginalURL: URL?
    var activeBlobCaptureMIMEType: String?
    var activeBlobCaptureSuggestedFilename: String?
    var blobCaptureTimeoutTask: Task<Void, Never>?

    // Optional MSE capture state (7H.4). Metadata observation remains the
    // default; bytes are retained only while an explicit capture is active.
    @Published public private(set) var mseCaptureSnapshot: BrowserMSECaptureSnapshot?
    @Published public var mseCaptureErrorMessage: String?
    @Published public private(set) var isCapturingMSE: Bool = false
    var activeMSECaptureID: String?
    var activeMSECaptureTabID: UUID?

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
    var tabOriginChains: [UUID: Set<String>] = [:]

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
    var pendingNavigationURLs: [UUID: URL] = [:]
    var tabSessions: [UUID: BrowserWebViewSession] = [:]

    // Navigation generation tracking to prevent stale callbacks from race conditions
    var tabNavigationGenerations: [UUID: UInt64] = [:]
    var tabNavigationTargets: [UUID: URL] = [:]

    // Memory pressure management & LRU tab eviction
    var tabLastAccessed: [UUID: Date] = [:]
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
    func consumePendingNavigation(
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

    func publishTabState() {
        tabs = tabManager.tabs
        groups = tabManager.groups
        activeTabID = tabManager.activeTabID
        if restoreTabsOnLaunch, let sessionStore {
            sessionStore.saveSession(tabs: tabManager.tabs, groups: tabManager.groups, activeTabID: tabManager.activeTabID)
        }
    }

    func syncActiveTabState() {
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

    static let blockedExternalSchemes: Set<String> = [
        "file", "javascript", "data", "blob", "about", "itms-services", "smb", "afp", "ftp"
    ]

    public static func isAllowedExternalScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !blockedExternalSchemes.contains(scheme)
    }

    func openExternalScheme(_ url: URL) {
        guard Self.isAllowedExternalScheme(url) else { return }
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

    var allowedInBrowserURLs = Set<String>()

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
    nonisolated static func externalAppPrompt(
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
        guard Self.isAllowedExternalScheme(link.url) else {
            continueInBrowser(link)
            return
        }
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

    func updateWebViewProgress(for tabID: UUID, webView: WKWebView) {
        guard var tab = tabManager.tab(withID: tabID) else { return }
        tab.estimatedProgress = webView.estimatedProgress
        _ = tabManager.updateTab(tab)
        publishTabState()
        if tabID == activeTabID {
            estimatedProgress = webView.estimatedProgress
        }
    }

    func handleWebViewError(
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

    func webView(for tabID: UUID?) -> WKWebView? {
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

    func clearActiveBlobCaptureState() {
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

    func scheduleBlobCaptureTimeout(for captureID: String, tabID: UUID, timeoutSeconds: TimeInterval = 15) {
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
                await service.cancel(captureID: captureID)
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

    func handleBlobCaptureAcknowledgement(
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

    func handleMSECaptureAcknowledgement(
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
        existingTransferWarning = nil

        let match = matchingTransfer(for: resource)
        let isFailedOrRecovery = (match != nil) && (recoveryManager?.activeSession != nil || match?.statusDot == .failed)
        let targetID: String? = isFailedOrRecovery ? (recoveryManager?.activeSession?.targetTransferID ?? match?.transferID) : nil
        let targetName: String? = {
            if let targetID {
                return downloadDelegate?.unifiedTransfersList.first(where: { $0.id == targetID })?.name ?? resource.suggestedFilename
            }
            if let match {
                return downloadDelegate?.unifiedTransfersList.first(where: { $0.id == match.transferID })?.name ?? resource.suggestedFilename
            }
            return nil
        }()

        isShowingResourceInspector = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            if let targetID, let targetName {
                self.resumeTargetTransferID = targetID
                self.resumeTargetTransferName = targetName
            } else if let match {
                self.existingTransferWarning = (
                    transferID: match.transferID,
                    statusDot: match.statusDot,
                    transferName: targetName ?? resource.suggestedFilename
                )
            }
            self.activeDownloadResource = resource
            let matchedCandidate = self.mediaCandidates.first { cand in
                cand.id == resource.id ||
                cand.rawURL.caseInsensitiveCompare(resource.url.absoluteString) == .orderedSame ||
                (cand.url != nil && cand.url == resource.url)
            }
            let candidate = matchedCandidate ?? BrowserMediaCandidateClassifier.classify(resource: resource)
            self.activeDownloadCandidate = candidate
            self.downloadCandidateURL = resource.url
            let preferredFilename = (isFailedOrRecovery ? targetName : nil) ?? resource.suggestedFilename
            self.downloadCandidateFilename = preferredFilename.isEmpty
                ? (candidate.suggestedFilename.isEmpty ? "download" : candidate.suggestedFilename)
                : preferredFilename
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

    func findNewerCandidate(for url: URL) -> BrowserMediaCandidate? {
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
        PipelineLogger.shared.log("[HLS Pipeline] promptStreamingDownload invoked for resource: \(resource.url.absoluteString)")
        if let custom = customFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            self.activeStreamingFilename = custom
        } else if !resource.suggestedFilename.isEmpty {
            self.activeStreamingFilename = resource.suggestedFilename
        }
        guard resource.isStreamingManifest || resource.url.pathExtension.lowercased() == "m3u8" || resource.url.pathExtension.lowercased() == "mpd" else {
            let errorMsg = "This resource is not a recognized HLS or DASH manifest."
            PipelineLogger.shared.log("[HLS Pipeline] \(errorMsg)")
            streamingErrorMessage = errorMsg
            blobCaptureErrorMessage = errorMsg
            return
        }
        let effectiveOrchestrator = streamingOrchestrator ?? (downloadDelegate as? DownloadManagerViewModel)?.streamingOrchestrator
        guard let orchestrator = effectiveOrchestrator else {
            let errorMsg = "Streaming downloads are unavailable: StreamingDownloadOrchestrator is nil."
            PipelineLogger.shared.log("[HLS Pipeline] \(errorMsg)")
            streamingErrorMessage = errorMsg
            blobCaptureErrorMessage = errorMsg
            return
        }
        guard !isPreparingStreaming, !isExecutingStreaming else {
            PipelineLogger.shared.log("[HLS Pipeline] Streaming download is already preparing or executing.")
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
                PipelineLogger.shared.log("[HLS Pipeline] Setting active BrowserViewModel as urlResolver on orchestrator...")
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
                            PipelineLogger.shared.log("[HLS Pipeline] Discovered \(options.count) variants. Presenting StreamQualityPickerSheet...")
                            self.isPreparingStreaming = false
                            self.presentQualityPicker(for: effectiveResource, preloadedOptions: options)
                            return
                        }
                    } catch {
                        PipelineLogger.shared.log("[HLS Pipeline] Quality inspection note: \(error.localizedDescription). Proceeding with standard preparation.")
                    }
                }

                if effectiveResource.isLive {
                    let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                    let videosDir = docDir.appendingPathComponent("Downloads/Videos", isDirectory: true)
                    let rawFilename = self.activeStreamingFilename ?? (effectiveResource.suggestedFilename.isEmpty ? "live_stream.mp4" : effectiveResource.suggestedFilename)
                    let lastComponent = URL(fileURLWithPath: rawFilename).lastPathComponent
                    let sanitized = FilenameExtensionHelper.sanitizeFilename(lastComponent)
                    let effectiveFilename = sanitized.isEmpty ? "live_stream.mp4" : sanitized
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

                PipelineLogger.shared.log("[HLS Pipeline] Creating StreamingManifestCandidate and preparing proposal with orchestrator...")
                let effectivePolicy = transportPolicy ?? self.preferredStreamingTransportPolicy ?? .background
                let candidate = try StreamingManifestCandidate(
                    resource: effectiveResource,
                    browserSessionSnapshot: sessionSnapshot,
                    transportPolicy: effectivePolicy
                )
                let proposal = try await orchestrator.prepare(candidate: candidate)
                PipelineLogger.shared.log("[HLS Pipeline] Proposal prepared successfully. Automatically starting streaming download in background...")
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
                PipelineLogger.shared.log("[HLS Pipeline] \(errorMsg)")
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
                PipelineLogger.shared.log("[HLS Pipeline] \(errorMsg)")
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
                PipelineLogger.shared.log("[HLS Pipeline] \(errorMsg)")
                self.streamingErrorMessage = errorMsg
            }
        }
    }

    /// Asynchronously inspects and expands streaming master manifests (HLS and DASH)
    /// into individual selectable video and audio quality resources directly in `discoveredResources`.
    public func expandStreamingManifests(in resources: [WebpageResource]? = nil, tabID: UUID? = nil) {
        let targets = resources ?? discoveredResources
        let targetTabID = tabID ?? activeTabID
        let pageTitle = targetTabID.flatMap { tabManager.tab(withID: $0)?.title } ?? self.pageTitle
        discoveryCoordinator.discoveredResources = discoveredResources
        discoveryCoordinator.variantStreamItems = variantStreamItems
        discoveryCoordinator.selectedResourceIDs = selectedResourceIDs
        discoveryCoordinator.expandStreamingManifests(in: targets, tabID: tabID, activeTabID: activeTabID, pageTitle: pageTitle)
    }

}
#endif
