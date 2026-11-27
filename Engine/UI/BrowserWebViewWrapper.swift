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


// MARK: - Platform WebView Wrapper (WebKit)

#if canImport(WebKit)

#if canImport(UIKit)
public final class BrowserContainerView: UIView {
    var currentWebView: WKWebView?

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
    var currentWebView: WKWebView?

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
    static let standardProcessPool = WKProcessPool()
    static let incognitoProcessPool = WKProcessPool()

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
    let tabID: UUID?
    var progressObserver: NSKeyValueObservation?
    let redirectLoopDetector = BrowserRedirectLoopDetector()
    var lastScrollOffsetY: CGFloat = 0

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
                vm.discoveryCoordinator.cancelInFlightProbes(for: tabID)
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

    func handleErrorInternal(_ error: Error) {
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

    func handleNavigationError(_ error: Error, webView: WKWebView, generation: UInt64? = nil) {
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

#endif
