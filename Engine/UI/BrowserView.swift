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
    public let serviceName: String

    public init(url: URL, serviceName: String) {
        self.id = url.absoluteString
        self.url = url
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
    @Published public private(set) var tabs: [BrowserTabState] = []
    @Published public private(set) var activeTabID: UUID?
    @Published public var isShowingTabSwitcher: Bool = false
    @Published public var externalAppLinkPrompt: BrowserExternalAppLink?

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
    @Published public private(set) var mediaCandidates: [BrowserMediaCandidate] = []
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

    // Optional MSE capture state (7H.4). Metadata observation remains the
    // default; bytes are retained only while an explicit capture is active.
    @Published public private(set) var mseCaptureSnapshot: BrowserMSECaptureSnapshot?
    @Published public var mseCaptureErrorMessage: String?
    @Published public private(set) var isCapturingMSE: Bool = false
    private var activeMSECaptureID: String?
    private var activeMSECaptureTabID: UUID?

    public weak var downloadDelegate: BrowserDownloadDelegate?
    public weak var magnetDelegate: (any BrowserMagnetDelegate)?
    public var onDownloadInitiated: (() -> Void)? = nil

    private var tabManager = BrowserTabManager()
    private var mediaCandidateCatalogs: [UUID: BrowserMediaCandidateCatalog] = [:]

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
        let orchestrator: StreamingDownloadOrchestrator
        if let streamingOrchestrator {
            orchestrator = streamingOrchestrator
        } else if let vm = downloadDelegate as? DownloadManagerViewModel {
            orchestrator = StreamingDownloadOrchestrator(
                downloadCoordinator: vm.engine.coordinator,
                downloadEngine: vm.engine
            )
        } else if let shared = StreamingDownloadOrchestrator.shared {
            orchestrator = shared
        } else {
            orchestrator = StreamingDownloadOrchestrator.createDefault()
        }
        if let vm = downloadDelegate as? DownloadManagerViewModel {
            Task {
                await vm.engine.setStreamingOrchestrator(orchestrator)
                await orchestrator.setDownloadEngine(vm.engine)
            }
        }
        self.streamingOrchestrator = orchestrator
        StreamingDownloadOrchestrator.shared = orchestrator
        self.streamingDestinationDirectoryURL = streamingDestinationDirectoryURL ??
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Downloads", isDirectory: true) ??
            FileManager.default.temporaryDirectory.appendingPathComponent("LIDDownloads", isDirectory: true)
        super.init()
        Task { await orchestrator.setURLResolver(self) }
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
        publishMediaCandidates()
        isShowingTabSwitcher = false
        return id
    }

    @discardableResult
    public func selectTab(_ id: UUID) -> Bool {
        guard tabManager.selectTab(id) else { return false }
        publishTabState()
        syncActiveTabState()
        publishMediaCandidates()
        isShowingTabSwitcher = false
        errorMessage = nil
        return true
    }

    @discardableResult
    public func closeTab(_ id: UUID) -> UUID? {
        #if canImport(WebKit)
        cancelBlobCapture(for: id)
        cancelMSECapture(for: id)
        pendingNavigationURLs.removeValue(forKey: id)
        tabSessions.removeValue(forKey: id)
        #endif
        mediaCandidateCatalogs.removeValue(forKey: id)
        let replacement = tabManager.closeTab(id)
        publishTabState()
        syncActiveTabState()
        publishMediaCandidates()
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
    nonisolated fileprivate static func externalAppPrompt(
            for url: URL,
            navigationAction: WKNavigationAction,
            currentURL: URL?
        ) -> BrowserExternalAppLink? {
            guard navigationAction.navigationType == .linkActivated,
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  let service = externalAppService(for: host),
                  normalizedHost(host) != normalizedHost(currentURL?.host) else {
                return nil
            }
            return BrowserExternalAppLink(url: url, serviceName: service)
        }
    #endif

        public func continueInBrowser(_ link: BrowserExternalAppLink) {
            externalAppLinkPrompt = nil
            #if canImport(WebKit)
            guard let tabID = activeTabID, let webView = webView(for: tabID) else { return }
            webView.load(URLRequest(url: link.url))
            #endif
        }

        public func openInAssociatedApp(_ link: BrowserExternalAppLink) {
            externalAppLinkPrompt = nil
            #if canImport(UIKit)
            UIApplication.shared.open(
                link.url,
                options: [.universalLinksOnly: true]
            ) { [weak self] opened in
                guard !opened else { return }
                self?.continueInBrowser(link)
            }
            #else
            continueInBrowser(link)
            #endif
        }

    nonisolated private static func externalAppService(for host: String) -> String? {
            let normalizedHost = normalizedHost(host)
            let services: [(String, String)] = [
                ("youtube.com", "YouTube"),
                ("instagram.com", "Instagram"),
                ("tiktok.com", "TikTok"),
                ("reddit.com", "Reddit"),
                ("spotify.com", "Spotify"),
                ("x.com", "X"),
                ("twitter.com", "X")
            ]
            return services.first {
                normalizedHost == $0.0 || normalizedHost.hasSuffix("." + $0.0)
            }?.1
        }

    nonisolated private static func normalizedHost(_ host: String?) -> String {
            guard let host else { return "" }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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
        cancelBlobCapture(for: tabID)
        cancelMSECapture(for: tabID)
        tabSessions[tabID]?.mediaDiscoveryBridge.reset()
        resetMediaCandidateCatalog(for: tabID)
    }

    fileprivate func webView(for tabID: UUID?) -> WKWebView? {
        guard let tabID else { return webView }
        return tabSessions[tabID]?.webView
    }

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
                self.isCapturingBlob = false
                self.activeBlobCaptureID = nil
                self.activeBlobCaptureTabID = nil
                self.activeBlobCaptureSuggestedFilename = nil
            }
        }
        #endif
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
        activeBlobCaptureID = nil
        activeBlobCaptureTabID = nil
        activeBlobCaptureOriginalURL = nil
        activeBlobCaptureMIMEType = nil
        activeBlobCaptureSuggestedFilename = nil
        isCapturingBlob = false
    }

    fileprivate func handleBlobCaptureAcknowledgement(
        _ acknowledgement: BlobCaptureAck,
        tabID: UUID
    ) {
        guard acknowledgement.transferID == activeBlobCaptureID,
              activeBlobCaptureTabID == tabID else { return }

        if let snapshot = acknowledgement.snapshot {
            blobCaptureSnapshot = snapshot
        }
        guard acknowledgement.accepted else {
            blobCaptureErrorMessage = acknowledgement.error?.localizedDescription ??
                "The browser Blob could not be exported."
            isCapturingBlob = false
            activeBlobCaptureID = nil
            activeBlobCaptureTabID = nil
            activeBlobCaptureOriginalURL = nil
            activeBlobCaptureMIMEType = nil
            activeBlobCaptureSuggestedFilename = nil
            return
        }
        if acknowledgement.snapshot?.isComplete == true {
            guard let snapshot = acknowledgement.snapshot,
                  snapshot.bytesWritten > 0,
                  let finalURL = snapshot.finalURL else {
                blobCaptureErrorMessage = "The Blob capture failed: 0 bytes received or no finalized output produced."
                isCapturingBlob = false
                activeBlobCaptureID = nil
                activeBlobCaptureTabID = nil
                activeBlobCaptureOriginalURL = nil
                activeBlobCaptureMIMEType = nil
                activeBlobCaptureSuggestedFilename = nil
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
                isCapturingBlob = false
                activeBlobCaptureID = nil
                activeBlobCaptureTabID = nil
                activeBlobCaptureOriginalURL = nil
                activeBlobCaptureMIMEType = nil
                activeBlobCaptureSuggestedFilename = nil
                return
            }
            let expectedSize = snapshot.expectedSize
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
                        originalURL: self.activeBlobCaptureOriginalURL,
                        mimeType: self.activeBlobCaptureMIMEType
                    )
                    self.isCapturingBlob = false
                    self.activeBlobCaptureID = nil
                    self.activeBlobCaptureTabID = nil
                    self.activeBlobCaptureOriginalURL = nil
                    self.activeBlobCaptureMIMEType = nil
                    self.activeBlobCaptureSuggestedFilename = nil
                    self.downloadSuccessNotification = "Blob download completed: \(filename)"
                    self.onDownloadInitiated?()
                } catch {
                    guard let self else { return }
                    self.blobCaptureErrorMessage = error.localizedDescription
                    self.isCapturingBlob = false
                    self.activeBlobCaptureID = nil
                    self.activeBlobCaptureTabID = nil
                    self.activeBlobCaptureOriginalURL = nil
                    self.activeBlobCaptureMIMEType = nil
                    self.activeBlobCaptureSuggestedFilename = nil
                }
            }
        }
    }

    /// Starts an explicit MSE capture for a supported MediaSource candidate.
    /// Observation remains metadata-only until this method runs.
    public func startMSECapture(_ candidate: BrowserMediaCandidate) {
        guard candidate.kind == .mediaSource,
              candidate.availability == .captureCandidate,
              candidate.rawURL.lowercased().hasPrefix("blob:"),
              let tabID = activeTabID,
              let session = tabSessions[tabID] else {
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
        activeMSECaptureTabID = tabID
        mseCaptureSnapshot = nil
        mseCaptureErrorMessage = nil
        isCapturingMSE = true

        let documentID = candidate.documentID
        let service = session.mseCaptureService
        let webView = session.webView
        let mediaSourceURL = candidate.rawURL
        Task { @MainActor [weak self] in
            await service.register(captureID: captureID, documentID: documentID)
            guard let self,
                  self.activeMSECaptureID == captureID,
                  self.activeMSECaptureTabID == tabID else {
                await service.cancel(captureID: captureID)
                return
            }
            do {
                _ = try await webView.evaluateJavaScript(
                    BrowserMSECapturePrototypeBridge.startCommand(
                        mediaSourceURL: mediaSourceURL,
                        captureID: captureID,
                        documentID: documentID
                    )
                )
            } catch {
                await service.cancel(captureID: captureID)
                self.mseCaptureErrorMessage = "The MediaSource capture could not start."
                self.isCapturingMSE = false
                self.activeMSECaptureID = nil
                self.activeMSECaptureTabID = nil
            }
        }
    }

    /// Stops capture and attempts reconstruction. Success requires validated output.
    public func stopMSECapture() {
        guard let captureID = activeMSECaptureID,
              let tabID = activeMSECaptureTabID,
              let session = tabSessions[tabID] else { return }
        _ = try? session.webView.evaluateJavaScript(
            BrowserMSECapturePrototypeBridge.stopCommand(captureID: captureID)
        )
    }

    public func cancelMSECapture(for tabID: UUID? = nil) {
        guard let captureID = activeMSECaptureID else { return }
        if let tabID, activeMSECaptureTabID != tabID { return }
        let targetTabID = activeMSECaptureTabID
        if let targetTabID, let session = tabSessions[targetTabID] {
            _ = try? session.webView.evaluateJavaScript(
                BrowserMSECapturePrototypeBridge.cancelCommand(captureID: captureID)
            )
            let service = session.mseCaptureService
            Task { await service.cancel(captureID: captureID) }
        }
        activeMSECaptureID = nil
        activeMSECaptureTabID = nil
        isCapturingMSE = false
    }

    fileprivate func handleMSECaptureAcknowledgement(
        _ acknowledgement: BrowserMSECapturePrototypeAck,
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
            return
        }
        if let snapshot = acknowledgement.snapshot, snapshot.isSuccessfullyReconstructed {
            isCapturingMSE = false
            activeMSECaptureID = nil
            activeMSECaptureTabID = nil
            downloadSuccessNotification = "MSE capture reconstructed a validated media file."
        } else if acknowledgement.snapshot?.lifecycle == .cancelled {
            isCapturingMSE = false
            activeMSECaptureID = nil
            activeMSECaptureTabID = nil
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
            if resource.isStreamingManifest || resource.url.pathExtension.lowercased() == "m3u8" || resource.url.pathExtension.lowercased() == "mpd" {
                self.promptStreamingDownload(for: resource)
                return
            }
            if resource.isSegmentChunk {
                self.blobCaptureErrorMessage = "This is a streaming segment chunk. Download the playlist manifest (.m3u8 or .mpd) instead."
                return
            }
            let candidate = BrowserMediaCandidateClassifier.classify(resource: resource)
            if candidate.kind == .hlsManifest || candidate.kind == .dashManifest {
                self.promptStreamingDownload(for: resource)
                return
            }
            if candidate.kind == .completeBlob || candidate.kind == .mediaSource || resource.url.scheme?.lowercased() == "blob" {
                let discoveredCandidate = self.mediaCandidates.first {
                    $0.rawURL.caseInsensitiveCompare(resource.url.absoluteString) == .orderedSame
                }
                let effectiveMIME = (discoveredCandidate?.mimeType ?? candidate.mimeType ?? resource.mimeType)?.lowercased()
                let isMediaSourceMIME = effectiveMIME == "application/x-mediasource"
                let isGenericMIME = effectiveMIME == nil || effectiveMIME?.isEmpty == true || effectiveMIME == "application/octet-stream"
                let isBinOrStreamName = resource.suggestedFilename.lowercased().hasSuffix(".bin") || resource.suggestedFilename.lowercased().hasPrefix("blob_stream")
                let isMediaSource = candidate.blobKind == .mediaSource ||
                    candidate.kind == .mediaSource ||
                    discoveredCandidate?.blobKind == .mediaSource ||
                    discoveredCandidate?.kind == .mediaSource ||
                    resource.isMediaSourceBlob ||
                    isMediaSourceMIME ||
                    (isGenericMIME && isBinOrStreamName)
                if isMediaSource {
                    if let manifestRes = self.discoveredResources.first(where: { $0.isStreamingManifest }) {
                        self.promptStreamingDownload(for: manifestRes)
                    } else if let manifest = discoveredCandidate?.associatedManifestURL ?? candidate.associatedManifestURL {
                        self.promptStreamingDownload(for: WebpageResource(
                            url: manifest,
                            title: resource.title,
                            suggestedFilename: resource.suggestedFilename.isEmpty ? "stream.mp4" : resource.suggestedFilename,
                            resourceType: .video,
                            manifestText: candidate.cachedManifestText ?? discoveredCandidate?.cachedManifestText
                        ))
                    } else {
                        self.blobCaptureErrorMessage = "This site uses MediaSource streaming. You must download the manifest (.m3u8 or .mpd) instead."
                    }
                    return
                }
                var targetCandidate = candidate
                if let discoveredCandidate {
                    targetCandidate = BrowserMediaCandidate(
                        id: targetCandidate.id,
                        url: targetCandidate.url,
                        rawURL: targetCandidate.rawURL,
                        finalURL: targetCandidate.finalURL,
                        kind: targetCandidate.kind,
                        mimeType: discoveredCandidate.mimeType ?? targetCandidate.mimeType,
                        suggestedFilename: resource.suggestedFilename.isEmpty ? targetCandidate.suggestedFilename : resource.suggestedFilename,
                        estimatedSize: discoveredCandidate.estimatedSize ?? targetCandidate.estimatedSize,
                        availability: .captureCandidate,
                        evidence: targetCandidate.evidence + discoveredCandidate.evidence,
                        documentID: discoveredCandidate.documentID ?? targetCandidate.documentID,
                        requestContext: discoveredCandidate.requestContext ?? targetCandidate.requestContext,
                        associatedManifestID: discoveredCandidate.associatedManifestID ?? targetCandidate.associatedManifestID,
                        lastObserved: targetCandidate.lastObserved
                    )
                }
                self.exportBlobCandidate(targetCandidate)
                return
            }
            if candidate.kind == .directMedia {
                do {
                    let plan = try DirectMediaTransferPlanner.makePlan(candidate: candidate)
                    self.promptDownload(
                        for: plan.transferURL,
                        suggestedFilename: plan.filename,
                        requestContext: plan.requestContext
                    )
                } catch {
                    self.resourceScanError = error.localizedDescription
                }
                return
            }

            self.promptDownload(
                for: resource.url,
                suggestedFilename: resource.suggestedFilename,
                requestContext: resource.requestContext
            )
        }
    }

    public func promptStreamingDownload(for resource: WebpageResource) {
        print("[HLS Pipeline] promptStreamingDownload invoked for resource: \(resource.url.absoluteString)")
        guard resource.isStreamingManifest || resource.url.pathExtension.lowercased() == "m3u8" || resource.url.pathExtension.lowercased() == "mpd" else {
            let errorMsg = "This resource is not a recognized HLS or DASH manifest."
            print("[HLS Pipeline] \(errorMsg)")
            streamingErrorMessage = errorMsg
            blobCaptureErrorMessage = errorMsg
            return
        }
        guard let orchestrator = streamingOrchestrator ?? StreamingDownloadOrchestrator.shared else {
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
        downloadSuccessNotification = "Streaming download started"

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                #if canImport(WebKit)
                let sessionSnapshot: BrowserSessionSnapshot?
                if let wv = self.webView {
                    sessionSnapshot = await DownloadRequestEnricher.snapshot(from: wv)
                } else {
                    sessionSnapshot = DownloadRequestEnricher.sharedSessionSnapshot.snapshot
                }
                #else
                let sessionSnapshot = DownloadRequestEnricher.sharedSessionSnapshot.snapshot
                #endif
                print("[HLS Pipeline] Setting active BrowserViewModel as urlResolver on orchestrator...")
                await orchestrator.setURLResolver(self)
                print("[HLS Pipeline] Creating StreamingManifestCandidate and preparing proposal with orchestrator...")
                let candidate = try StreamingManifestCandidate(
                    resource: resource,
                    browserSessionSnapshot: sessionSnapshot
                )
                let proposal = try await orchestrator.prepare(candidate: candidate)
                print("[HLS Pipeline] Proposal prepared successfully. Automatically starting streaming download in background...")
                self.streamingProposal = proposal
                self.isPreparingStreaming = false
                self.executeStreamingProposal()
            } catch {
                let errorMsg = "Streaming preparation failed: \(error.localizedDescription)"
                print("[HLS Pipeline] \(errorMsg)")
                self.streamingErrorMessage = errorMsg
                self.blobCaptureErrorMessage = errorMsg
                self.isPreparingStreaming = false
            }
        }
    }

    public func executeStreamingProposal() {
        guard let proposal = streamingProposal,
              let orchestrator = streamingOrchestrator ?? StreamingDownloadOrchestrator.shared,
              !isExecutingStreaming else { return }

        isExecutingStreaming = true
        streamingErrorMessage = nil
        let destination = streamingDestinationDirectoryURL
        let progressSink: @Sendable (StreamingTransferProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.streamingProgress = progress
            }
        }
        #if canImport(UIKit) && !os(watchOS)
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "SwiftDownloadEngine.streamingDownload") {
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
                try FileManager.default.createDirectory(at: tempAssemblyDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                defer {
                    try? FileManager.default.removeItem(at: tempAssemblyDir)
                }

                switch proposal.manifest {
                case .hls(let transferPlan):
                    let filename = HLSVODReconstructionPlanner.suggestedFilename(for: transferPlan)
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
                    let filename = DASHVODReconstructionPlanner.suggestedFilename(for: transferPlan)
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
                self.isShowingStreamingConfirmation = false
                self.downloadSuccessNotification = completionMessage
                self.onDownloadInitiated?()
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
            resetMediaCandidateCatalog(for: activeTabID)
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
                if (v.src) {
                    var isMSE = (window.__grabberBlobRegistry && window.__grabberBlobRegistry[v.src] === 'MediaSource') ||
                                (v.src.indexOf('blob:') === 0);
                    candidates.push({
                        rawURL: v.src,
                        tag: 'video',
                        text: v.title || v.getAttribute('aria-label') || '',
                        declaredType: isMSE ? 'application/x-mediasource' : null
                    });
                }
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
                    if let manifest = contextualResources.first(where: { $0.isStreamingManifest }) {
                        self.selectedResourceIDs.insert(manifest.id)
                    }
                    self.resetMediaCandidateCatalog(for: self.activeTabID)
                    self.ingestMediaResources(contextualResources, tabID: self.activeTabID)
                }
            }
        }
        #else
        isScanningResources = false
        resourceScanError = "WebKit is not available in this environment."
        #endif
    }

    /// Adds dynamically observed media candidates to the existing resource
    /// classifier. Complete Blobs remain page-owned until the user explicitly
    /// starts the bounded capture workflow.
    fileprivate func handleMediaDiscoveryObservation(
        _ observation: BrowserMediaDiscoveryObservation,
        tabID: UUID? = nil
    ) {
        ingestMediaObservation(observation, tabID: tabID)
        if let tabID, tabID != activeTabID { return }
        guard let discoveredURL = observation.url else { return }
        let resourceURL: URL
        if let responseURL = observation.responseURL,
           BrowserURLResolver.isValidDownloadURL(responseURL) {
            resourceURL = responseURL
        } else {
            resourceURL = discoveredURL
        }

        let rawCandidate = WebpageRawResourceCandidate(
            rawURL: resourceURL.absoluteString,
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
                url: resourceURL,
                title: BrowserURLResolver.suggestedFilename(from: resourceURL),
                suggestedFilename: BrowserURLResolver.suggestedFilename(from: resourceURL),
                resourceType: .video,
                mimeType: observation.declaredType ?? manifestType,
                estimatedSize: observation.contentLength,
                isSupported: false,
                unsupportedReason: "Streaming playlist manifest. Prepare a manifest-aware transfer to continue.",
                manifestText: observation.manifestPrefix
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
                unsupportedReason: "Streaming playlist manifest. Prepare a manifest-aware transfer to continue.",
                manifestText: resource.manifestText ?? observation.manifestPrefix
            )
        } else if resource.manifestText == nil, let prefix = observation.manifestPrefix {
            resource = WebpageResource(
                id: resource.id,
                url: resource.url,
                title: resource.title,
                suggestedFilename: resource.suggestedFilename,
                resourceType: resource.resourceType,
                mimeType: resource.mimeType,
                estimatedSize: resource.estimatedSize,
                isSupported: resource.isSupported,
                unsupportedReason: resource.unsupportedReason,
                requestContext: resource.requestContext,
                manifestText: prefix
            )
        }

        // A resource observed by a cross-origin frame, or a resource hosted on
        // another origin, is deliberately added without browser credentials.
        guard observation.mayUseBrowserCredentials,
              let wv = webView else {
            discoveredResources.append(resource)
            if selectedResourceIDs.isEmpty,
               let manifest = discoveredResources.first(where: { $0.isStreamingManifest }) {
                selectedResourceIDs.insert(manifest.id)
            }
            ingestMediaResource(resource, tabID: tabID ?? activeTabID)
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
            if self.selectedResourceIDs.isEmpty,
               let manifest = self.discoveredResources.first(where: { $0.isStreamingManifest }) {
                self.selectedResourceIDs.insert(manifest.id)
            }
            self.ingestMediaResource(contextualResource, tabID: tabID ?? self.activeTabID)
        }
    }

    private func publishMediaCandidates() {
        guard let activeTabID else {
            mediaCandidates = []
            return
        }
        let rawCandidates = mediaCandidateCatalogs[activeTabID]?.candidates ?? []
        mediaCandidates = BrowserMediaDiscoveryBridge.filter(candidates: rawCandidates)
    }

    private func ingestMediaObservation(
        _ observation: BrowserMediaDiscoveryObservation,
        tabID: UUID?
    ) {
        guard let targetTabID = tabID ?? activeTabID else { return }
        var catalog = mediaCandidateCatalogs[targetTabID] ?? BrowserMediaCandidateCatalog()
        _ = catalog.ingest(observation: observation)
        mediaCandidateCatalogs[targetTabID] = catalog
        if targetTabID == activeTabID { publishMediaCandidates() }
    }

    private func ingestMediaResources(
        _ resources: [WebpageResource],
        tabID: UUID?
    ) {
        guard let targetTabID = tabID ?? activeTabID else { return }
        var catalog = mediaCandidateCatalogs[targetTabID] ?? BrowserMediaCandidateCatalog()
        for resource in resources {
            _ = catalog.ingest(resource: resource)
        }
        mediaCandidateCatalogs[targetTabID] = catalog
        if targetTabID == activeTabID { publishMediaCandidates() }
    }

    private func ingestMediaResource(
        _ resource: WebpageResource,
        tabID: UUID?
    ) {
        ingestMediaResources([resource], tabID: tabID)
    }

    private func resetMediaCandidateCatalog(for tabID: UUID?) {
        guard let tabID else {
            mediaCandidates = mediaCandidates.filter {
                $0.blobKind == .mediaSource || $0.kind == .mediaSource || $0.associatedManifestURL != nil
            }
            return
        }
        let preserved = mediaCandidateCatalogs[tabID]?.candidates.filter {
            $0.blobKind == .mediaSource || $0.kind == .mediaSource || $0.associatedManifestURL != nil
        } ?? []
        var catalog = BrowserMediaCandidateCatalog()
        for cand in preserved {
            catalog.merge(cand)
        }
        mediaCandidateCatalogs[tabID] = catalog
        if tabID == activeTabID { publishMediaCandidates() }
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
            (res.isSupported || res.isStreamingManifest) && selectedResourceIDs.contains(res.id)
        }

        guard !targets.isEmpty else { return }

        #if canImport(WebKit)
        if let wv = self.webView {
            _ = await DownloadRequestEnricher.snapshot(from: wv)
        }
        #endif

        for resource in targets {
            let url = resource.url
            let scheme = url.scheme?.lowercased() ?? ""

            // 1. Intercept streaming playlist manifests upfront
            if resource.isStreamingManifest || url.pathExtension.lowercased() == "m3u8" || url.pathExtension.lowercased() == "mpd" {
                if streamingOrchestrator == nil && StreamingDownloadOrchestrator.shared == nil {
                    let errorMsg = "Streaming downloads are unavailable: StreamingDownloadOrchestrator is nil."
                    print("[HLS Pipeline] \(errorMsg)")
                    blobCaptureErrorMessage = errorMsg
                    streamingErrorMessage = errorMsg
                    return
                }
                promptStreamingDownload(for: resource)
                continue
            }

            // 2. Intercept individual streaming segment chunks
            if resource.isSegmentChunk {
                blobCaptureErrorMessage = "This is a streaming segment chunk. Download the playlist manifest (.m3u8 or .mpd) instead."
                continue
            }

            // 3. Ensure scheme is valid
            guard scheme == "http" || scheme == "https" || scheme == "blob" else {
                blobCaptureErrorMessage = "Unsupported link type: \(scheme.isEmpty ? "unknown" : scheme). Cannot download directly."
                continue
            }

            if scheme == "blob" {
                let candidate = BrowserMediaCandidateClassifier.classify(resource: resource)
                let discoveredCandidate = self.mediaCandidates.first {
                    $0.rawURL.caseInsensitiveCompare(resource.url.absoluteString) == .orderedSame
                }
                let effectiveMIME = (discoveredCandidate?.mimeType ?? candidate.mimeType ?? resource.mimeType)?.lowercased()
                let isMediaSourceMIME = effectiveMIME == "application/x-mediasource"
                let isGenericMIME = effectiveMIME == nil || effectiveMIME?.isEmpty == true || effectiveMIME == "application/octet-stream"
                let isBinOrStreamName = resource.suggestedFilename.lowercased().hasSuffix(".bin") || resource.suggestedFilename.lowercased().hasPrefix("blob_stream")
                let isMediaSource = candidate.blobKind == .mediaSource ||
                    candidate.kind == .mediaSource ||
                    discoveredCandidate?.blobKind == .mediaSource ||
                    discoveredCandidate?.kind == .mediaSource ||
                    resource.isMediaSourceBlob ||
                    isMediaSourceMIME ||
                    (isGenericMIME && isBinOrStreamName)
                if isMediaSource {
                    if let manifest = discoveredCandidate?.associatedManifestURL ?? candidate.associatedManifestURL ?? self.discoveredResources.first(where: { $0.isStreamingManifest })?.url {
                        promptStreamingDownload(for: WebpageResource(
                            url: manifest,
                            title: resource.title,
                            suggestedFilename: resource.suggestedFilename.isEmpty ? "stream.mp4" : resource.suggestedFilename,
                            resourceType: .video
                        ))
                    } else {
                        blobCaptureErrorMessage = "This site uses MediaSource streaming. You must download the manifest (.m3u8 or .mpd) instead."
                    }
                    continue
                }
                var targetCandidate = candidate
                if let discoveredCandidate {
                    targetCandidate = BrowserMediaCandidate(
                        id: targetCandidate.id,
                        url: targetCandidate.url,
                        rawURL: targetCandidate.rawURL,
                        finalURL: targetCandidate.finalURL,
                        kind: targetCandidate.kind,
                        blobKind: targetCandidate.blobKind ?? discoveredCandidate.blobKind,
                        mimeType: discoveredCandidate.mimeType ?? targetCandidate.mimeType,
                        suggestedFilename: resource.suggestedFilename.isEmpty ? targetCandidate.suggestedFilename : resource.suggestedFilename,
                        estimatedSize: discoveredCandidate.estimatedSize ?? targetCandidate.estimatedSize,
                        availability: .captureCandidate,
                        evidence: targetCandidate.evidence + discoveredCandidate.evidence,
                        documentID: discoveredCandidate.documentID ?? targetCandidate.documentID,
                        requestContext: discoveredCandidate.requestContext ?? targetCandidate.requestContext,
                        associatedManifestID: discoveredCandidate.associatedManifestID ?? targetCandidate.associatedManifestID,
                        lastObserved: targetCandidate.lastObserved
                    )
                }
                self.exportBlobCandidate(targetCandidate)
                continue
            }
            if resource.isStreamingManifest {
                promptStreamingDownload(for: resource)
                continue
            }
            let candidate = BrowserMediaCandidateClassifier.classify(resource: resource)
            if candidate.kind == .hlsManifest || candidate.kind == .dashManifest {
                promptStreamingDownload(for: resource)
                continue
            }
            do {
                if candidate.kind == .directMedia {
                    let plan = try DirectMediaTransferPlanner.makePlan(candidate: candidate)
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
                    url: resource.url,
                    filename: resource.suggestedFilename.isEmpty ? nil : resource.suggestedFilename,
                    threadCount: 6,
                    speedLimitBytesPerSecond: nil,
                    headers: resource.requestContext?.effectiveHeaders(
                        for: resource.url,
                        includeCredentials: useBrowserCredentials
                    )
                )
            } catch {
                blobCaptureErrorMessage = "Engine error: \(error.localizedDescription)"
            }
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
        resetMediaCandidateCatalog(for: activeTabID)
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

        let manifestClassification = StreamingManifestClassifier.classify(url: url)
        if manifestClassification.isManifest || url.pathExtension.lowercased() == "m3u8" || url.pathExtension.lowercased() == "mpd" {
            let filename = downloadCandidateFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            promptStreamingDownload(for: WebpageResource(
                url: url,
                title: filename.isEmpty ? url.lastPathComponent : filename,
                suggestedFilename: filename.isEmpty ? url.lastPathComponent : filename,
                resourceType: .video
            ))
            isShowingDownloadSheet = false
            return
        }

        if url.pathExtension.lowercased() == "ts" || url.pathExtension.lowercased() == "m4s" {
            blobCaptureErrorMessage = "This is a streaming segment chunk. Download the playlist manifest (.m3u8 or .mpd) instead."
            isShowingDownloadSheet = false
            return
        }

        if case .mustUseBlobCaptureService = DownloadURLPolicy.classify(url) {
            let filename = downloadCandidateFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = mediaCandidates.first {
                $0.rawURL.caseInsensitiveCompare(url.absoluteString) == .orderedSame
            }
            let resolvedFilename: String = {
                if !filename.isEmpty { return filename }
                if let existing = existing, !existing.suggestedFilename.isEmpty {
                    return existing.suggestedFilename
                }
                return "browser_blob.mp4"
            }()
            let effectiveMIME = existing?.mimeType?.lowercased()
            let isMediaSourceMIME = effectiveMIME == "application/x-mediasource"
            let isGenericMIME = effectiveMIME == nil || effectiveMIME?.isEmpty == true || effectiveMIME == "application/octet-stream"
            let isBinOrStreamName = resolvedFilename.lowercased().hasSuffix(".bin") || resolvedFilename.lowercased().hasPrefix("blob_stream")
            let isMediaSource = existing?.blobKind == .mediaSource ||
                existing?.kind == .mediaSource ||
                isMediaSourceMIME ||
                (isGenericMIME && isBinOrStreamName)
            if isMediaSource {
                if let manifest = existing?.associatedManifestURL ?? discoveredResources.first(where: { $0.isStreamingManifest })?.url {
                    promptStreamingDownload(for: WebpageResource(
                        url: manifest,
                        title: resolvedFilename,
                        suggestedFilename: resolvedFilename.isEmpty ? "stream.mp4" : resolvedFilename,
                        resourceType: .video
                    ))
                    isShowingDownloadSheet = false
                } else {
                    blobCaptureErrorMessage = "This site uses MediaSource streaming. You must download the manifest (.m3u8 or .mpd) instead."
                    isShowingDownloadSheet = false
                }
                return
            }
            let candidate: BrowserMediaCandidate
            if let existing = existing {
                candidate = BrowserMediaCandidate(
                    id: existing.id,
                    url: existing.url,
                    rawURL: existing.rawURL,
                    finalURL: existing.finalURL,
                    kind: .completeBlob,
                    mimeType: existing.mimeType,
                    suggestedFilename: resolvedFilename,
                    estimatedSize: existing.estimatedSize,
                    availability: .captureCandidate,
                    evidence: existing.evidence + ["Blob export requested from download sheet"],
                    documentID: existing.documentID,
                    requestContext: existing.requestContext,
                    associatedManifestID: existing.associatedManifestID,
                    lastObserved: Date()
                )
            } else {
                candidate = BrowserMediaCandidate(
                    id: BrowserMediaCandidateClassifier.stableIdentity(rawURL: url.absoluteString, url: url),
                    url: nil,
                    rawURL: url.absoluteString,
                    finalURL: nil,
                    kind: .completeBlob,
                    mimeType: nil,
                    suggestedFilename: resolvedFilename,
                    estimatedSize: nil,
                    availability: .captureCandidate,
                    evidence: ["Blob export requested from download sheet"],
                    documentID: nil,
                    requestContext: nil,
                    associatedManifestID: nil,
                    lastObserved: Date()
                )
            }

            BrowserDiagnosticLogger.shared.log(
                category: .blobCapture,
                message: "Start Download tapped: routing to Blob capture",
                url: url,
                details: ["filename": resolvedFilename]
            )

            isShowingDownloadSheet = false
            exportBlobCandidate(candidate)
            downloadSuccessNotification = "Blob export started: \(resolvedFilename)"
            onDownloadInitiated?()
            return
        }

        let limit: Int64?
        if let kb = Int64(downloadCandidateSpeedLimitKBps), kb > 0 {
            limit = kb * 1024
        } else {
            limit = nil
        }

        #if canImport(WebKit)
        if let wv = webView {
            _ = await DownloadRequestEnricher.snapshot(from: wv)
        }
        #endif

        do {
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
        } catch {
            blobCaptureErrorMessage = "Engine error: \(error.localizedDescription)"
            isShowingDownloadSheet = false
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
        #if canImport(WebKit)
        let activeWebView = self.webView ?? (activeTabID.flatMap { tabSessions[$0]?.webView })
        guard let activeWebView else {
            throw StreamingManifestLoadError.browserFetchUnavailable
        }
        return try await mediaDiscoveryBridge.fetchManifestText(from: url, on: activeWebView)
        #else
        throw StreamingManifestLoadError.browserFetchUnavailable
        #endif
    }
}

extension BrowserViewModel: @unchecked Sendable, BrowserMediaURLResolver {}

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
            streamingOrchestrator: StreamingDownloadOrchestrator(
                downloadCoordinator: viewModel.engine.coordinator,
                downloadEngine: viewModel.engine
            ),
            streamingDestinationDirectoryURL: viewModel.downloadsDirectoryURL
        ))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Keep one navigation menu at the top, like a compact browser toolbar.
            topNavigationToolbar

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
        .sheet(isPresented: $viewModel.isShowingMagnetSheet) {
            BrowserMagnetConfirmationSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingTabSwitcher) {
            BrowserTabSwitcherView(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingDiagnosticLogs) {
            DiagnosticLogView()
        }
        .alert(item: $viewModel.externalAppLinkPrompt) { link in
            Alert(
                title: Text("Open in App?"),
                message: Text("\(link.serviceName) may open an installed app. Choose whether to open the app or continue in the browser."),
                primaryButton: .default(Text("Open App")) {
                    viewModel.openInAssociatedApp(link)
                },
                secondaryButton: .cancel(Text("Continue in Browser")) {
                    viewModel.continueInBrowser(link)
                }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            addressBarHeader
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
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
                if let error = viewModel.blobCaptureErrorMessage {
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
                            withAnimation { viewModel.blobCaptureErrorMessage = nil }
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
        }
        #if canImport(UIKit)
        .background(Color(UIColor.systemBackground))
        #endif
    }

    private var isModalPresented: Bool {
        viewModel.isShowingDownloadSheet ||
        viewModel.isShowingResourceInspector ||
        viewModel.isShowingMagnetSheet ||
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
                .frame(minWidth: 44, minHeight: 44)

                // Forward Button
                Button {
                    viewModel.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 18, weight: .semibold))
                }
                .accessibilityLabel("Forward")
                .disabled(!viewModel.canGoForward)
                .frame(minWidth: 44, minHeight: 44)

                // Home Button
                Button {
                    viewModel.goHome()
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 18))
                }
                .accessibilityLabel("Home")
                .frame(minWidth: 44, minHeight: 44)

                // Tab overview button; edge gestures are an additional path.
                Button {
                    viewModel.showTabSwitcher()
                } label: {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 18))
                }
                .accessibilityLabel("Tabs")
                .disabled(viewModel.tabs.isEmpty)
                .frame(minWidth: 44, minHeight: 44)

                // Find Resources Button
                Button {
                    viewModel.openResourceInspector()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 18))
                        .foregroundColor(viewModel.currentURL != nil ? .blue : .secondary)
                }
                .accessibilityLabel("Resources")
                .disabled(viewModel.currentURL == nil)
                .frame(minWidth: 44, minHeight: 44)

                // Reload Button
                Button {
                    viewModel.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18))
                }
                .accessibilityLabel("Reload")
                .disabled(viewModel.currentURL == nil)
                .frame(minWidth: 44, minHeight: 44)
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
}

// MARK: - Home / New Tab View

public struct BrowserHomeView: View {
    @ObservedObject public var viewModel: BrowserViewModel

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
    private static let sharedProcessPool = WKProcessPool()

    let tabID: UUID
    let mediaDiscoveryBridge: BrowserMediaDiscoveryBridge
    let blobCaptureService: BrowserBlobCaptureService
    let mseCaptureService: BrowserMSECaptureService
    let webView: WKWebView
    let coordinator: BrowserWebViewCoordinator

    init(tabID: UUID, viewModel: BrowserViewModel) {
        self.tabID = tabID
        let config = WKWebViewConfiguration()
        config.processPool = Self.sharedProcessPool
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
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
        let mseHandler = BrowserMSECapturePrototypeWebKitHandler(
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

        let webView = WKWebView(frame: .zero, configuration: config)
        // Keep the native Safari User-Agent untouched to ensure consistency
        // with device hardware and Client Hints, preventing Cloudflare Turnstile rejection.
        self.webView = webView
        let coordinator = BrowserWebViewCoordinator(viewModel: viewModel, tabID: tabID)
        self.coordinator = coordinator
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.setupProgressObserver(for: webView)
    }
}

// MARK: - WKNavigationDelegate & WKUIDelegate Coordinator

public final class BrowserWebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
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
        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Provisional navigation started",
            url: webView.url,
            tabID: tabID
        )
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
        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Navigation content committed",
            url: webView.url,
            tabID: tabID
        )
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let currentURL = webView.url
        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Navigation finished: \(webView.title ?? "")",
            url: currentURL,
            tabID: tabID,
            details: ["title": webView.title ?? ""]
        )

        // Inspect and capture session snapshot (User-Agent, language, and all cookies by domain)
        Task { @MainActor [weak self] in
            let snapshot = await DownloadRequestEnricher.snapshot(from: webView)
            BrowserDiagnosticLogger.shared.log(
                category: .cookie,
                message: "Browser session snapshot captured with \(snapshot.allCookies.count) cookies across \(snapshot.cookiesByDomain.count) domains and UA: \(snapshot.userAgent)",
                url: currentURL,
                tabID: self?.tabID,
                details: ["domains": snapshot.cookiesByDomain.keys.joined(separator: ", ")]
            )
        }

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
        let nsError = error as NSError
        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Navigation failed: \(error.localizedDescription)",
            url: webView.url,
            tabID: tabID,
            details: [
                "domain": nsError.domain,
                "code": "\(nsError.code)",
                "isCancelled": "\(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)"
            ]
        )
        handleNavigationError(error, webView: webView)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "Provisional navigation failed: \(error.localizedDescription)",
            url: webView.url,
            tabID: tabID,
            details: [
                "domain": nsError.domain,
                "code": "\(nsError.code)",
                "isCancelled": "\(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)"
            ]
        )
        handleNavigationError(error, webView: webView)
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
            self.viewModel?.cancelBlobCapture(for: tabID)
            self.viewModel?.blobCaptureErrorMessage = "The webpage process was terminated by iOS (likely memory pressure)."
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

    // MARK: - WKUIDelegate

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        BrowserDiagnosticLogger.shared.log(
            category: .navigation,
            message: "createWebViewWith requested by page",
            url: navigationAction.request.url,
            tabID: tabID,
            details: [
                "targetFrame": navigationAction.targetFrame == nil ? "nil" : "non-nil",
                "navigationType": "\(navigationAction.navigationType.rawValue)"
            ]
        )
        // If a user tapped a link opening in a new tab/window, load it in the current web view.
        // Automated script windows (e.g. challenge popups) are allowed to evaluate without
        // forcibly resetting the primary web view.
        if navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
        }
        return nil
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

        // Allow HTTP, HTTPS, and internal browser pseudo-schemes (about:blank, about:srcdoc)
        guard BrowserURLResolver.isValidWebNavigationURL(url) else {
            decisionHandler(.cancel)
            return
        }

        if let link = BrowserViewModel.externalAppPrompt(
            for: url,
            navigationAction: navigationAction,
            currentURL: webView.url
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

        // Handle target="_blank" links by navigating in the current web view only when activated by user
        if navigationAction.targetFrame == nil {
            if navigationAction.navigationType == .linkActivated {
                BrowserDiagnosticLogger.shared.log(
                    category: .policy,
                    message: "Navigating user target=_blank link in current webView",
                    url: url,
                    tabID: tabID,
                    details: ["method": navigationAction.request.httpMethod ?? "GET"]
                )
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            } else {
                decisionHandler(.allow)
                return
            }
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
