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

    public weak var downloadDelegate: BrowserDownloadDelegate?
    public weak var magnetDelegate: (any BrowserMagnetDelegate)?
    public var onDownloadInitiated: (() -> Void)? = nil

    #if canImport(WebKit)
    public weak var webView: WKWebView?
    #endif

    public init(
        downloadDelegate: BrowserDownloadDelegate? = nil,
        magnetDelegate: (any BrowserMagnetDelegate)? = nil,
        onDownloadInitiated: (() -> Void)? = nil
    ) {
        self.downloadDelegate = downloadDelegate
        self.magnetDelegate = magnetDelegate
        self.onDownloadInitiated = onDownloadInitiated
        super.init()
    }

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
                    self.resourceScanError = "Failed to scan webpage: \\(error.localizedDescription)"
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
                    guard resource.isSupported else { return resource }
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
        currentURL = url
        urlInputText = url.absoluteString

        #if canImport(WebKit)
        let request = URLRequest(url: url)
        webView?.load(request)
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
        #endif
        currentURL = nil
        urlInputText = ""
        pageTitle = ""
        errorMessage = nil
        isLoading = false
        estimatedProgress = 0.0
        canGoBack = false
        canGoForward = false
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
            onDownloadInitiated: onDownloadInitiated
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
                    PlatformWebView(viewModel: viewModel)
                    #else
                    Text("WebKit is not supported in this environment.")
                        .foregroundColor(.secondary)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        #if canImport(UIKit)
        .background(Color(UIColor.systemBackground))
        #endif
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

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public func makeCoordinator() -> BrowserWebViewCoordinator {
        BrowserWebViewCoordinator(viewModel: viewModel)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.setupProgressObserver(for: webView)
        viewModel.webView = webView
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        // Navigation is triggered explicitly via BrowserViewModel to avoid unnecessary re-creation.
    }
}
#elseif canImport(AppKit)
public struct PlatformWebView: NSViewRepresentable {
    @ObservedObject public var viewModel: BrowserViewModel

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public func makeCoordinator() -> BrowserWebViewCoordinator {
        BrowserWebViewCoordinator(viewModel: viewModel)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.setupProgressObserver(for: webView)
        viewModel.webView = webView
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

// MARK: - WKNavigationDelegate Coordinator

public final class BrowserWebViewCoordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    public weak var viewModel: BrowserViewModel?
    private var progressObserver: NSKeyValueObservation?

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    deinit {
        progressObserver?.invalidate()
    }

    public func setupProgressObserver(for webView: WKWebView) {
        progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            DispatchQueue.main.async {
                self?.viewModel?.estimatedProgress = wv.estimatedProgress
            }
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            vm.isLoading = true
            vm.errorMessage = nil
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
        handleNavigationError(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
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

    private func handleNavigationError(_ error: Error) {
        handleErrorInternal(error)
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
                  let browser = vm.webView else { return }
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
