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
    @Published public private(set) var tabs: [BrowserTabState] = []
    @Published public private(set) var activeTabID: UUID?
    @Published public var isShowingTabSwitcher: Bool = false

    // Download modal state
    @Published public var isShowingDownloadSheet: Bool = false
    @Published public var downloadCandidateURL: URL? = nil
    @Published public var downloadCandidateFilename: String = ""
    @Published public var downloadCandidateRequestContext: BrowserRequestContext? = nil
    @Published public var useBrowserCredentials: Bool = true
    @Published public var downloadCandidateThreads: Int = 6
    @Published public var downloadCandidateSpeedLimitKBps: String = ""
    @Published public var downloadSuccessNotification: String? = nil

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
    @Published public var discoveredResources: [WebpageResource] = []
    @Published public var selectedResourceIDs: Set<String> = []
    @Published public var resourceScanError: String? = nil
    public let mediaDiscoveryBridge = BrowserMediaDiscoveryBridge()

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

    public weak var downloadDelegate: BrowserDownloadDelegate?
    public weak var magnetDelegate: (any BrowserMagnetDelegate)?
    public var onDownloadInitiated: (() -> Void)? = nil

    private var tabManager = BrowserTabManager()

    #if canImport(WebKit)
    public weak var webView: WKWebView?
    private var pendingNavigationURLs: [UUID: URL] = [:]
    private var tabSessions: [UUID: BrowserWebViewSession] = [:]

    /// Attaches the WebKit instance created by SwiftUI and delivers the
    /// navigation requested while the home view was being replaced.
    func attachWebView(_ webView: WKWebView, for tabID: UUID? = nil) {
        let targetTabID = tabID ?? activeTabID
        guard let targetTabID else { return }
        if targetTabID == activeTabID {
            self.webView = webView
        }
        _ = consumePendingNavigation(for: targetTabID) { request in
            webView.load(request)
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
        streamingOrchestrator: StreamingDownloadOrchestrator? = nil,
        streamingDestinationDirectoryURL: URL? = nil
    ) {
        self.downloadDelegate = downloadDelegate
        self.magnetDelegate = magnetDelegate
        self.onDownloadInitiated = onDownloadInitiated
        self.streamingOrchestrator = streamingOrchestrator
        self.streamingDestinationDirectoryURL = streamingDestinationDirectoryURL ??
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Downloads", isDirectory: true) ??
            FileManager.default.temporaryDirectory.appendingPathComponent("LIDDownloads", isDirectory: true)
        super.init()
        publishTabState()
        mediaDiscoveryBridge.observationHandler = { [weak self] observation in
            DispatchQueue.main.async { [weak self] in
                self?.handleMediaDiscoveryObservation(observation)
            }
        }
    }

    private func publishTabState() {
        tabs = tabManager.tabs
        activeTabID = tabManager.activeTabID
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
        pageTitle = activeTab.title == "New Tab" ? "" : activeTab.title
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

    @discardableResult
    public func createNewTab() -> UUID {
        let id = tabManager.createTab(select: true)
        publishTabState()
        syncActiveTabState()
        isShowingTabSwitcher = false
        return id
    }

    @discardableResult
    public func selectTab(_ id: UUID) -> Bool {
        guard tabManager.selectTab(id) else { return false }
        publishTabState()
        syncActiveTabState()
        isShowingTabSwitcher = false
        errorMessage = nil
        return true
    }

    @discardableResult
    public func closeTab(_ id: UUID) -> UUID? {
        #if canImport(WebKit)
        pendingNavigationURLs.removeValue(forKey: id)
        tabSessions.removeValue(forKey: id)
        #endif
        let replacement = tabManager.closeTab(id)
        publishTabState()
        syncActiveTabState()
        if replacement == nil {
            isShowingTabSwitcher = false
        }
        return replacement
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

    #if canImport(WebKit)
    func webViewSession(for tabID: UUID) -> BrowserWebViewSession {
        if let existing = tabSessions[tabID] { return existing }
        let session = BrowserWebViewSession(tabID: tabID, viewModel: self)
        tabSessions[tabID] = session
        return session
    }

    fileprivate func updateWebViewState(
        for tabID: UUID,
        webView: WKWebView,
        url: URL?,
        title: String?,
        isLoading: Bool
    ) {
        guard var tab = tabManager.tab(withID: tabID) else { return }
        if let url, url.absoluteString != "about:blank" {
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
        webView: WKWebView
    ) {
        updateWebViewState(
            for: tabID,
            webView: webView,
            url: tabManager.tab(withID: tabID)?.url,
            title: nil,
            isLoading: false
        )
        if tabID == activeTabID {
            let nsError = error as NSError
            if !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                errorMessage = error.localizedDescription
            }
        }
    }

    fileprivate func resetMediaDiscovery(for tabID: UUID) {
        tabSessions[tabID]?.mediaDiscoveryBridge.reset()
    }

    fileprivate func webView(for tabID: UUID?) -> WKWebView? {
        guard let tabID else { return webView }
        return tabSessions[tabID]?.webView
    }
    #endif

    public func shouldSuppressDuplicatePrompt(for url: URL) -> Bool {
        interceptionManager.shouldSuppressDuplicate(for: url, isSheetPresented: isShowingDownloadSheet)
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
        downloadCandidateURL = handoff.finalURL
        downloadCandidateFilename = handoff.suggestedFilename
        downloadCandidateRequestContext = handoff.requestContext
        useBrowserCredentials = handoff.requestContext != nil
        downloadCandidateThreads = 6
        downloadCandidateSpeedLimitKBps = ""
        isShowingDownloadSheet = true
    }

    public func promptDownload(
        for url: URL,
        suggestedFilename: String?,
        requestContext: BrowserRequestContext? = nil
    ) {
        handleNativeDownloadHandoff(
            originalURL: url,
            finalURL: url,
            suggestedFilename: suggestedFilename,
            source: .responseAttachment,
            requestContext: requestContext
        )
    }

    public func openResourceInspector() {
        isShowingResourceInspector = true
        inspectCurrentPageResources()
    }

    public func promptDownloadFromInspector(for resource: WebpageResource) {
        isShowingResourceInspector = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.promptDownload(
                for: resource.url,
                suggestedFilename: resource.suggestedFilename,
                requestContext: resource.requestContext
            )
        }
    }

    public func promptStreamingDownload(for resource: WebpageResource) {
        guard resource.isStreamingManifest else {
            streamingErrorMessage = "This resource is not a recognized HLS or DASH manifest."
            return
        }
        guard let orchestrator = streamingOrchestrator else {
            streamingErrorMessage = "Streaming downloads are unavailable in this browser configuration."
            return
        }
        guard !isPreparingStreaming, !isExecutingStreaming else { return }

        isShowingResourceInspector = false
        isPreparingStreaming = true
        streamingErrorMessage = nil
        streamingProposal = nil
        streamingProgress = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let candidate = try StreamingManifestCandidate(resource: resource)
                let proposal = try await orchestrator.prepare(candidate: candidate)
                self.streamingProposal = proposal
                self.isShowingStreamingConfirmation = true
            } catch {
                self.streamingErrorMessage = error.localizedDescription
            }
            self.isPreparingStreaming = false
        }
    }

    public func executeStreamingProposal() {
        guard let proposal = streamingProposal,
              let orchestrator = streamingOrchestrator,
              !isExecutingStreaming else { return }

        isExecutingStreaming = true
        streamingErrorMessage = nil
        let destination = streamingDestinationDirectoryURL
        let progressSink: @Sendable (StreamingTransferProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.streamingProgress = progress
            }
        }
        streamingExecutionTask = Task { @MainActor [weak self] in
            do {
                let result = try await orchestrator.execute(
                    proposal,
                    approved: true,
                    destinationDirectory: destination,
                    progress: progressSink
                )
                guard let self else { return }
                self.isExecutingStreaming = false
                self.isShowingStreamingConfirmation = false
                self.downloadSuccessNotification = "Streaming download completed (\(result.localFiles.count) resources)."
                self.onDownloadInitiated?()
            } catch is CancellationError {
                self?.isExecutingStreaming = false
            } catch {
                self?.isExecutingStreaming = false
                self?.streamingErrorMessage = error.localizedDescription
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

    public func inspectCurrentPageResources() {
        guard let url = currentURL else {
            resourceScanError = "No active webpage is currently loaded."
            discoveredResources = []
            selectedResourceIDs = []
            return
        }

        isScanningResources = true
        resourceScanError = nil

        #if canImport(WebKit)
        guard let wv = webView else {
            isScanningResources = false
            resourceScanError = "Web browser engine is not ready."
            return
        }

        let jsScript = """
        (function() {
            var candidates = [];
            document.querySelectorAll('video').forEach(function(v) {
                if (v.src) candidates.push({ rawURL: v.src, tag: 'video', text: v.title || v.getAttribute('aria-label') || '' });
            });
            document.querySelectorAll('audio').forEach(function(a) {
                if (a.src) candidates.push({ rawURL: a.src, tag: 'audio', text: a.title || a.getAttribute('aria-label') || '' });
            });
            document.querySelectorAll('source').forEach(function(s) {
                if (s.src) candidates.push({ rawURL: s.src, tag: 'source', declaredType: s.type || null });
            });
            document.querySelectorAll('a[href]').forEach(function(a) {
                var href = a.getAttribute('href');
                if (href && !href.startsWith('#') && !href.startsWith('javascript:')) {
                    candidates.push({ rawURL: href, tag: 'a', text: (a.innerText || a.textContent || '').trim(), declaredType: a.getAttribute('type') || null });
                }
            });
            document.querySelectorAll('img[src]').forEach(function(img) {
                var src = img.getAttribute('src');
                if (src && !src.startsWith('data:')) {
                    candidates.push({ rawURL: src, tag: 'img', text: (img.getAttribute('alt') || '').trim() });
                }
            });
            return JSON.stringify(candidates);
        })()
        """

        wv.evaluateJavaScript(jsScript) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isScanningResources = false

                if let error = error {
                    self.resourceScanError = "Failed to scan webpage: \(error.localizedDescription)"
                    return
                }

                guard let jsonStr = result as? String,
                      let data = jsonStr.data(using: .utf8),
                      let rawCandidates = try? JSONDecoder().decode([WebpageRawResourceCandidate].self, from: data) else {
                    self.resourceScanError = "Unable to process resources from webpage."
                    return
                }

                let resources = WebpageResourceExtractor.extractFromRawCandidates(rawCandidates, baseURL: url)
                self.captureRequestContexts(for: resources, pageURL: url, webView: wv) { [weak self] contextualResources in
                    guard let self = self else { return }
                    self.discoveredResources = contextualResources
                    self.selectedResourceIDs = []
                }
            }
        }
        #else
        isScanningResources = false
        resourceScanError = "WebKit is not available in this environment."
        #endif
    }

    /// Adds dynamically observed media candidates to the existing resource
    /// classifier. Blob observations remain signals only and never become
    /// download candidates.
    fileprivate func handleMediaDiscoveryObservation(
        _ observation: BrowserMediaDiscoveryObservation,
        tabID: UUID? = nil
    ) {
        if let tabID, tabID != activeTabID { return }
        guard let discoveredURL = observation.url else { return }

        let rawCandidate = WebpageRawResourceCandidate(
            rawURL: discoveredURL.absoluteString,
            tag: observation.tag ?? (observation.isManifestSignal ? "video" : nil),
            declaredType: observation.declaredType
        )
        let baseURL = currentURL ?? observation.pageOrigin
        var resources = WebpageResourceExtractor.extractFromRawCandidates(
            [rawCandidate],
            baseURL: baseURL
        )
        // A fetch/XHR response can identify a manifest even when its URL has
        // no useful extension and the media element has not yet attached it.
        // Preserve that signal as a candidate; the orchestrator performs the
        // authoritative fetch, classification, and parsing later.
        if resources.isEmpty, observation.isManifestSignal {
            let manifestType = observation.manifestKind == .dash
                ? "application/dash+xml"
                : "application/vnd.apple.mpegurl"
            resources = [WebpageResource(
                url: discoveredURL,
                title: BrowserURLResolver.suggestedFilename(from: discoveredURL),
                suggestedFilename: BrowserURLResolver.suggestedFilename(from: discoveredURL),
                resourceType: .video,
                mimeType: observation.declaredType ?? manifestType,
                isSupported: false,
                unsupportedReason: "Streaming playlist manifest. Prepare a manifest-aware transfer to continue."
            )]
        }
        guard var resource = resources.first,
              !discoveredResources.contains(where: {
                  $0.url.absoluteString.lowercased() == resource.url.absoluteString.lowercased()
              }) else {
            return
        }

        if observation.isManifestSignal && !resource.isStreamingManifest {
            let manifestType = observation.manifestKind == .dash
                ? "application/dash+xml"
                : "application/vnd.apple.mpegurl"
            resource = WebpageResource(
                id: resource.id,
                url: resource.url,
                title: resource.title,
                suggestedFilename: resource.suggestedFilename,
                resourceType: .video,
                mimeType: resource.mimeType ?? observation.declaredType ?? manifestType,
                estimatedSize: observation.contentLength ?? resource.estimatedSize,
                isSupported: false,
                unsupportedReason: "Streaming playlist manifest. Prepare a manifest-aware transfer to continue."
            )
        }

        // A resource observed by a cross-origin frame, or a resource hosted on
        // another origin, is deliberately added without browser credentials.
        guard observation.mayUseBrowserCredentials,
              let wv = webView else {
            discoveredResources.append(resource)
            return
        }

        captureRequestContexts(
            for: [resource],
            pageURL: currentURL ?? observation.pageOrigin,
            webView: wv
        ) { [weak self] contextualResources in
            guard let self,
                  let contextualResource = contextualResources.first,
                  !self.discoveredResources.contains(where: {
                      $0.url.absoluteString.lowercased() == contextualResource.url.absoluteString.lowercased()
                  }) else {
                return
            }
            self.discoveredResources.append(contextualResource)
        }
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
                        requestContext: context
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
        completion: @escaping (BrowserRequestContext?) -> Void
    ) {
        let page = pageURL ?? webView.url
        webView.evaluateJavaScript("navigator.userAgent") { result, _ in
            let userAgent = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let matchingCookies = cookies
                    .compactMap(BrowserCookie.init(from:))
                    .filter { $0.matches(url: resourceURL) }
                let context = BrowserRequestContext(
                    url: resourceURL,
                    pageURL: page,
                    userAgent: userAgent,
                    cookies: matchingCookies,
                    customHeaders: BrowserHeaderFilter.sanitizeHeaders(customHeaders).filter {
                        let key = $0.key.lowercased()
                        return BrowserHeaderFilter.isApprovedForwardedHeader(key) &&
                            key != "cookie" && key != "referer" && key != "user-agent"
                    },
                    source: source
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
            res.isSupported && selectedResourceIDs.contains(res.id)
        }

        guard !targets.isEmpty else { return }

        for resource in targets {
            try await downloadDelegate?.handleDownloadRequest(
                url: resource.url,
                filename: resource.suggestedFilename.isEmpty ? nil : resource.suggestedFilename,
                threadCount: 6,
                speedLimitBytesPerSecond: nil,
                headers: resource.requestContext?.effectiveHeaders(
                    for: resource.url,
                    includeCredentials: useBrowserCredentials
                )
            )
        }

        selectedResourceIDs = []
        isShowingResourceInspector = false
        downloadSuccessNotification = "\\(targets.count) download(s) queued successfully."
        onDownloadInitiated?()
    }

    /// Converts one discovered browser resource into a streaming proposal. The
    /// caller owns user confirmation and execution; ordinary HTTP resources keep
    /// using `downloadSelectedResources()` and the existing download delegate.
    public func prepareStreamingProposal(
        for resource: WebpageResource,
        using orchestrator: StreamingDownloadOrchestrator
    ) async throws -> StreamingTransferProposal {
        let candidate = try StreamingManifestCandidate(resource: resource)
        return try await orchestrator.prepare(candidate: candidate)
    }

    public func navigate(to input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let url = BrowserURLResolver.resolve(input: trimmed, searchEngine: selectedSearchEngine) else {
            errorMessage = "Invalid or unsupported web address. Only HTTP and HTTPS are permitted."
            return
        }

        load(url: url)
    }

    public func load(url: URL) {
        errorMessage = nil
        let targetTabID: UUID
        if let existingID = tabManager.activeTabID {
            targetTabID = existingID
        } else {
            targetTabID = tabManager.createTab(select: true)
            publishTabState()
        }
        guard var tab = tabManager.tab(withID: targetTabID) else { return }
        tab.url = url
        tab.isLoading = true
        tab.estimatedProgress = 0
        tab.title = tab.title == "New Tab" ? "Loading…" : tab.title
        _ = tabManager.updateTab(tab)
        publishTabState()
        syncActiveTabState()

        #if canImport(WebKit)
        pendingNavigationURLs[targetTabID] = url
        if let webView {
            _ = consumePendingNavigation(for: targetTabID) { request in
                webView.load(request)
            }
        }
        #endif
    }

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
        publishTabState()
        syncActiveTabState()
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
        let limit: Int64?
        if let kb = Int64(downloadCandidateSpeedLimitKBps), kb > 0 {
            limit = kb * 1024
        } else {
            limit = nil
        }

        try await downloadDelegate?.handleDownloadRequest(
            url: url,
            filename: downloadCandidateFilename.isEmpty ? nil : downloadCandidateFilename,
            threadCount: downloadCandidateThreads,
            speedLimitBytesPerSecond: limit,
            headers: downloadCandidateRequestContext?.effectiveHeaders(
                for: url,
                includeCredentials: useBrowserCredentials
            )
        )

        isShowingDownloadSheet = false
        downloadSuccessNotification = "Download queued: \(downloadCandidateFilename)"
        onDownloadInitiated?()
    }
}

// MARK: - Browser View (SwiftUI)

/// Native in-app web browser interface integrating address bar, navigation controls, and direct engine download handoff.
public struct BrowserView: View {
    @StateObject public var viewModel: BrowserViewModel
    @FocusState private var isAddressBarFocused: Bool

    public init(viewModel: BrowserViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public init(
        downloadDelegate: BrowserDownloadDelegate? = nil,
        magnetDelegate: (any BrowserMagnetDelegate)? = nil,
        onDownloadInitiated: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: BrowserViewModel(
            downloadDelegate: downloadDelegate,
            magnetDelegate: magnetDelegate,
            onDownloadInitiated: onDownloadInitiated
        ))
    }

    public init(viewModel: DownloadManagerViewModel, onDownloadInitiated: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: BrowserViewModel(
            downloadDelegate: viewModel,
            magnetDelegate: viewModel,
            onDownloadInitiated: onDownloadInitiated,
            streamingOrchestrator: StreamingDownloadOrchestrator(downloadCoordinator: viewModel.engine.coordinator),
            streamingDestinationDirectoryURL: viewModel.downloadsDirectoryURL
        ))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Address & Navigation Header
            addressBarHeader

            // Loading Progress Bar
            if viewModel.isLoading {
                ProgressView(value: max(0.05, viewModel.estimatedProgress), total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .frame(height: 2)
            } else {
                Divider()
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
                            .gesture(
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
                            .gesture(
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

            // Bottom Navigation Toolbar
            bottomToolbar
        }
        .sheet(isPresented: $viewModel.isShowingDownloadSheet) {
            BrowserDownloadSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingResourceInspector) {
            BrowserResourceInspectorSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingMagnetSheet) {
            BrowserMagnetConfirmationSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingStreamingConfirmation) {
            BrowserStreamingConfirmationSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingTabSwitcher) {
            BrowserTabSwitcherView(viewModel: viewModel)
        }
        #if canImport(UIKit)
        .background(Color(UIColor.systemBackground))
        #endif
    }

    private var isModalPresented: Bool {
        viewModel.isShowingDownloadSheet ||
        viewModel.isShowingResourceInspector ||
        viewModel.isShowingMagnetSheet ||
        viewModel.isShowingStreamingConfirmation ||
        viewModel.isShowingTabSwitcher
    }

    // MARK: - Address Bar Header

    private var addressBarHeader: some View {
        HStack(spacing: 8) {
            // Address Bar Capsule
            HStack(spacing: 6) {
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

                if viewModel.isLoading {
                    Button {
                        viewModel.stopLoading()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                } else if !viewModel.urlInputText.isEmpty {
                    Button {
                        if viewModel.currentURL != nil {
                            viewModel.reload()
                        } else {
                            viewModel.urlInputText = ""
                        }
                    } label: {
                        Image(systemName: viewModel.currentURL != nil ? "arrow.clockwise" : "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            #if canImport(UIKit)
            .background(Color(UIColor.secondarySystemBackground))
            #else
            .background(Color.secondary.opacity(0.15))
            #endif
            .cornerRadius(10)

            if isAddressBarFocused {
                Button("Go") {
                    viewModel.navigate(to: viewModel.urlInputText)
                    isAddressBarFocused = false
                }
                .font(.body.weight(.semibold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                // Back Button
                Button {
                    viewModel.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 18, weight: .semibold))
                }
                .disabled(!viewModel.canGoBack)
                .frame(maxWidth: .infinity)

                // Forward Button
                Button {
                    viewModel.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 18, weight: .semibold))
                }
                .disabled(!viewModel.canGoForward)
                .frame(maxWidth: .infinity)

                // Home Button
                Button {
                    viewModel.goHome()
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 18))
                }
                .frame(maxWidth: .infinity)

                // Tab overview button; edge gestures are an additional path.
                Button {
                    viewModel.showTabSwitcher()
                } label: {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 18))
                }
                .disabled(viewModel.tabs.isEmpty)
                .frame(maxWidth: .infinity)

                // Find Resources Button
                Button {
                    viewModel.openResourceInspector()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 18))
                        Text("Resources")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(viewModel.currentURL != nil ? .blue : .secondary)
                }
                .disabled(viewModel.currentURL == nil)
                .frame(maxWidth: .infinity)

                // Download Page URL Button
                Button {
                    viewModel.prepareDownloadCurrentURL()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18))
                    }
                    .foregroundColor(viewModel.currentURL != nil ? .white : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(viewModel.currentURL != nil ? Color.blue : Color.gray.opacity(0.2))
                    .cornerRadius(16)
                }
                .disabled(viewModel.currentURL == nil)
                .frame(maxWidth: .infinity)

                // Reload Button
                Button {
                    viewModel.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18))
                }
                .disabled(viewModel.currentURL == nil)
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 10)
            #if canImport(UIKit)
            .background(Color(UIColor.secondarySystemBackground))
            #endif
        }
    }
}

// MARK: - Home / New Tab View

public struct BrowserHomeView: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @State private var quickSearchText: String = ""

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero Branding Card
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 72, height: 72)
                        Image(systemName: "globe")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    .padding(.top, 16)

                    Text("LID In-App Browser")
                        .font(.title2.weight(.bold))

                    Text("Browse the web, inspect links, and send downloads directly to the high-performance multi-threaded download engine.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Quick Search Box
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search the web or type a URL...", text: $quickSearchText)
                            #if canImport(UIKit)
                            .keyboardType(.webSearch)
                            .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .onSubmit {
                                viewModel.navigate(to: quickSearchText)
                            }
                        if !quickSearchText.isEmpty {
                            Button {
                                viewModel.navigate(to: quickSearchText)
                            } label: {
                                Text("Search")
                                    .bold()
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .padding(12)
                    #if canImport(UIKit)
                    .background(Color(UIColor.secondarySystemBackground))
                    #else
                    .background(Color.secondary.opacity(0.15))
                    #endif
                    .cornerRadius(12)

                    // Search engine selection picker
                    HStack {
                        Text("Search with:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Search Engine", selection: $viewModel.selectedSearchEngine) {
                            ForEach(BrowserSearchEngine.allCases) { engine in
                                Text(engine.rawValue).tag(engine)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                }
                .padding(.horizontal, 16)

                // Quick Links Grid
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Access")
                        .font(.headline)
                        .padding(.horizontal, 16)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(BrowserQuickLink.defaults) { link in
                            Button {
                                if let url = URL(string: link.urlString) {
                                    viewModel.load(url: url)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: link.systemImage)
                                        .font(.system(size: 24))
                                        .foregroundColor(.blue)
                                        .frame(width: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(link.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(link.subtitle)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                                #if canImport(UIKit)
                                .background(Color(UIColor.secondarySystemBackground))
                                #else
                                .background(Color.secondary.opacity(0.15))
                                #endif
                                .cornerRadius(12)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Architectural Invariant Card
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Integrated Transfer Engine")
                            .font(.subheadline.weight(.bold))
                        Text("Downloads initiated from this browser automatically reuse the established priority queue, segmented range writer, and persistent checkpoint storage.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(14)
                #if canImport(UIKit)
                .background(Color(UIColor.secondarySystemBackground))
                #else
                .background(Color.secondary.opacity(0.15))
                #endif
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Browser Tab Switcher

public struct BrowserTabSwitcherView: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.tabs) { tab in
                        tabCard(for: tab)
                    }

                    Button {
                        viewModel.createNewTab()
                        dismiss()
                    } label: {
                        Label("New Tab", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
            .navigationTitle("Tabs")
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
        }
    }

    @ViewBuilder
    private func tabCard(for tab: BrowserTabState) -> some View {
        HStack(spacing: 12) {
            Button {
                _ = viewModel.selectTab(tab.id)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if tab.id == viewModel.activeTabID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                        }
                        Text(tab.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }

                    Text(displayURL(for: tab))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                close(tab.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close (tab.displayName)")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tab.id == viewModel.activeTabID ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.1))
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard value.translation.height < -60,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    close(tab.id)
                }
        )
    }

    private func close(_ tabID: UUID) {
        _ = viewModel.closeTab(tabID)
        if viewModel.tabs.isEmpty {
            dismiss()
        }
    }

    private func displayURL(for tab: BrowserTabState) -> String {
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

    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Source URL")) {
                    if let url = viewModel.downloadCandidateURL {
                        Text(BrowserURLResolver.sanitizeURLForDisplay(url))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    } else {
                        Text("No URL")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Destination Filename")) {
                    TextField("filename.ext", text: $viewModel.downloadCandidateFilename)
                        #if canImport(UIKit)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
                }

                if viewModel.downloadCandidateRequestContext != nil {
                    Section(
                        header: Text("Browser Session"),
                        footer: Text("Cookies and authentication headers are limited to the captured resource origin and are not retained in download history.")
                    ) {
                        Toggle("Use browser credentials", isOn: $viewModel.useBrowserCredentials)
                    }
                }

                Section(header: Text("Acceleration & Threads"), footer: Text("The download coordinator will allocate parallel segmented workers if the host server supports HTTP range requests.")) {
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
                }

                if let err = submitErrorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

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
                            Text("Start Download")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || viewModel.downloadCandidateURL == nil)
                }
            }
            .navigationTitle("Download File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    private func submitDownload() {
        submitErrorMessage = nil
        isSubmitting = true

        Task { @MainActor in
            do {
                try await viewModel.executeDownload()
                isSubmitting = false
                presentationMode.wrappedValue.dismiss()
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

    public func makeUIView(context: Context) -> WKWebView {
        let webView = viewModel.webViewSession(for: tabID).webView
        viewModel.attachWebView(webView, for: tabID)
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        // Reattach only to deliver a request that arrived before makeUIView.
        // attachWebView does not reload when there is no pending request.
        viewModel.attachWebView(uiView, for: tabID)
    }
}
#elseif canImport(AppKit)
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

    public func makeNSView(context: Context) -> WKWebView {
        let webView = viewModel.webViewSession(for: tabID).webView
        viewModel.attachWebView(webView, for: tabID)
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        viewModel.attachWebView(nsView, for: tabID)
    }
}
#endif

@MainActor
final class BrowserWebViewSession {
    let tabID: UUID
    let mediaDiscoveryBridge: BrowserMediaDiscoveryBridge
    let webView: WKWebView
    let coordinator: BrowserWebViewCoordinator

    init(tabID: UUID, viewModel: BrowserViewModel) {
        self.tabID = tabID
        let config = WKWebViewConfiguration()
#if os(iOS)
        config.allowsInlineMediaPlayback = true
#endif

        let bridge = BrowserMediaDiscoveryBridge()
        bridge.observationHandler = { [weak viewModel] observation in
            DispatchQueue.main.async {
                viewModel?.handleMediaDiscoveryObservation(observation, tabID: tabID)
            }
        }
        bridge.install(on: config)
        self.mediaDiscoveryBridge = bridge

        let webView = WKWebView(frame: .zero, configuration: config)
        self.webView = webView
        let coordinator = BrowserWebViewCoordinator(viewModel: viewModel, tabID: tabID)
        self.coordinator = coordinator
        webView.navigationDelegate = coordinator
        coordinator.setupProgressObserver(for: webView)
    }
}

// MARK: - WKNavigationDelegate Coordinator

public final class BrowserWebViewCoordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    public weak var viewModel: BrowserViewModel?
    private let tabID: UUID?
    private var progressObserver: NSKeyValueObservation?

    public init(viewModel: BrowserViewModel, tabID: UUID? = nil) {
        self.viewModel = viewModel
        self.tabID = tabID
        super.init()
    }

    deinit {
        progressObserver?.invalidate()
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            if let tabID = self.tabID {
                vm.updateWebViewState(
                    for: tabID,
                    webView: webView,
                    url: webView.url,
                    title: nil,
                    isLoading: true
                )
                vm.resetMediaDiscovery(for: tabID)
                vm.errorMessage = nil
                return
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

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            if let tabID = self.tabID {
                vm.updateWebViewState(
                    for: tabID,
                    webView: webView,
                    url: webView.url,
                    title: webView.title,
                    isLoading: false
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

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error, webView: webView)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error, webView: webView)
    }

    private func handleErrorInternal(_ error: Error) {
        let nsError = error as NSError
        // Ignore NSURLErrorCancelled (-999), emitted on redirection or intentional user stops
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            vm.isLoading = false
            vm.errorMessage = error.localizedDescription
        }
    }

    private func handleNavigationError(_ error: Error, webView: WKWebView) {
        if let tabID {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.handleWebViewError(error, for: tabID, webView: webView)
            }
        } else {
            handleErrorInternal(error)
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

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

        // Allow HTTP, HTTPS, and blank page
        guard BrowserURLResolver.isValidWebNavigationURL(url) else {
            decisionHandler(.cancel)
            return
        }

        // Native download request via HTML5 <a download> attribute
        if #available(iOS 14.5, macOS 11.3, *) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
        }

        // Handle target="_blank" links by navigating in the current web view
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
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

        let classification = BrowserDownloadClassifier.classify(
            url: url,
            statusCode: response.statusCode,
            contentDisposition: disposition,
            mimeType: contentType,
            canShowMIMEType: navigationResponse.canShowMIMEType
        )

        if classification.isDownload {
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
                            suggestedFilename: classification.suggestedFilename,
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

#endif // canImport(WebKit)

#endif // canImport(SwiftUI)
