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


extension BrowserViewModel {
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

    func handleMediaDiscoveryObservation(
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

    func publishMediaCandidates() {
        discoveryCoordinator.publishMediaCandidates(activeTabID: activeTabID)
    }

    func ingestMediaObservation(
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
    func captureRequestContexts(
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
#endif
