import Foundation

#if canImport(WebKit)
import WebKit
#endif

// BrowserUserScriptInjectionTime, BrowserUserScript, and BrowserUserScriptManager
// are defined in BrowserUserScriptManager.swift.


public enum BrowserMediaDiscoverySource: String, Codable, Sendable, Equatable {
    case fetch
    case xmlHttpRequest
    case mediaElement
    case sourceElement
    case domMutation
    case performanceResource
    case blob
    case mediaSource
    case protection
}

/// A discovery event from page JavaScript. `url == nil` is intentional for a
/// `blob:` signal: blob URLs are browser-managed resources and must not be sent
/// to the HTTP download coordinator.
public struct BrowserMediaDiscoveryObservation: Codable, Sendable, Equatable {
    public let eventID: String?
    public let url: URL?
    public let responseURL: URL?
    public let rawURL: String
    public let source: BrowserMediaDiscoverySource
    public let tag: String?
    public let declaredType: String?
    public let method: String?
    public let statusCode: Int?
    public let contentLength: Int64?
    public let manifestKind: StreamingManifestKind?
    public let manifestPrefix: String?
    public let documentID: String?
    public let appendedByteCount: Int64?
    public let isPotentiallyProtected: Bool
    public let pageOrigin: URL
    public let frameOrigin: URL
    public let mayUseBrowserCredentials: Bool
    public let blobKind: BlobKind?
    public let width: Int?
    public let height: Int?
    public let duration: Double?
    public let codecs: String?

    public var isBlobSignal: Bool {
        url == nil && rawURL.lowercased().hasPrefix("blob:")
    }

    public var isManifestSignal: Bool {
        manifestKind == .hls || manifestKind == .dash
    }

    public var isMetadataOnlySignal: Bool {
        source == .mediaSource || source == .protection
    }

    public init(
        url: URL?,
        rawURL: String,
        source: BrowserMediaDiscoverySource,
        tag: String? = nil,
        declaredType: String? = nil,
        eventID: String? = nil,
        responseURL: URL? = nil,
        method: String? = nil,
        statusCode: Int? = nil,
        contentLength: Int64? = nil,
        manifestKind: StreamingManifestKind? = nil,
        manifestPrefix: String? = nil,
        documentID: String? = nil,
        appendedByteCount: Int64? = nil,
        isPotentiallyProtected: Bool = false,
        pageOrigin: URL,
        frameOrigin: URL,
        mayUseBrowserCredentials: Bool,
        blobKind: BlobKind? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        codecs: String? = nil
    ) {
        self.eventID = eventID
        self.url = url
        self.responseURL = responseURL
        self.rawURL = rawURL
        self.source = source
        self.tag = tag
        self.declaredType = declaredType
        self.method = method
        self.statusCode = statusCode
        self.contentLength = contentLength
        self.manifestKind = manifestKind
        self.manifestPrefix = manifestPrefix
        self.documentID = documentID
        self.appendedByteCount = appendedByteCount
        self.isPotentiallyProtected = isPotentiallyProtected
        self.pageOrigin = pageOrigin
        self.frameOrigin = frameOrigin
        self.mayUseBrowserCredentials = mayUseBrowserCredentials
        self.blobKind = blobKind
        self.width = width
        self.height = height
        self.duration = duration
        self.codecs = codecs
    }
}

public enum BrowserMediaDiscoveryBridgeError: Error, LocalizedError, Equatable, Sendable {
    case malformedMessage
    case invalidPageOrigin
    case invalidFrameOrigin
    case crossOriginFrameRejected
    case emptyCandidateURL
    case candidateURLTooLong
    case unsupportedCandidateScheme
    case credentialedCandidateURL
    case unsupportedHTTPMethod
    case metadataTooLong

    public var errorDescription: String? {
        switch self {
        case .malformedMessage:
            return "The browser media discovery message was malformed."
        case .invalidPageOrigin:
            return "The browser page origin is invalid for media discovery."
        case .invalidFrameOrigin:
            return "The browser frame origin is invalid for media discovery."
        case .crossOriginFrameRejected:
            return "Cross-origin frames cannot report media candidates targeting the page origin."
        case .emptyCandidateURL:
            return "The browser media discovery message did not contain a URL."
        case .candidateURLTooLong:
            return "The browser media discovery URL exceeded the safety limit."
        case .unsupportedCandidateScheme:
            return "The browser media discovery URL uses an unsupported scheme."
        case .credentialedCandidateURL:
            return "Credential-bearing URLs are not accepted from browser media discovery."
        case .unsupportedHTTPMethod:
            return "Only GET resources are eligible for browser media discovery."
        case .metadataTooLong:
            return "Browser media discovery metadata exceeded the safety limit."
        }
    }
}

/// Validates and deduplicates messages emitted by the page instrumentation.
///
/// The bridge never receives cookies or headers. Browser credentials may only be
/// captured later for a same-origin observation; cross-origin and cross-frame
/// observations are forwarded without credential inheritance.
@MainActor
public final class BrowserMediaDiscoveryBridge: NSObject {
    public typealias UserScript = BrowserUserScript
    public typealias UserScriptInjectionTime = BrowserUserScriptInjectionTime
    public typealias UserScriptManager = BrowserUserScriptManager

    public static var defaultURLResolutionScript: String {
        BrowserMediaDiscoveryScripts.defaultURLResolutionScript
    }

    public static var urlResolutionHookScript: String {
        BrowserMediaDiscoveryScripts.urlResolutionHookScript
    }

    public static var observerScript: String {
        BrowserMediaDiscoveryScripts.observerScript
    }

    public static let messageName = "browserMediaDiscovery"
    public static let maximumCandidateLength = 8_192
    public static let maximumMetadataLength = 524_288

        public var observationHandler: ((BrowserMediaDiscoveryObservation) -> Void)?
    public var errorHandler: ((BrowserMediaDiscoveryBridgeError) -> Void)?
    public let userScriptManager: UserScriptManager

    private var seenKeys: Set<String> = []
    private var seenKeysWithPrefix: Set<String> = []

    @MainActor
    public init(userScriptManager: UserScriptManager) {
        self.userScriptManager = userScriptManager
        super.init()
    }

    @MainActor
    public override convenience init() {
        self.init(userScriptManager: UserScriptManager())
    }

    public func reset() {
        seenKeys.removeAll(keepingCapacity: true)
        seenKeysWithPrefix.removeAll(keepingCapacity: true)
    }

    /// Decodes and validates a message body without requiring WebKit. This is
    /// the deterministic boundary used by unit tests and by the WebKit handler.
    @discardableResult
    public func accept(
        payload: Any,
        pageURL: URL,
        frameURL: URL? = nil,
        isMainFrame: Bool? = nil
    ) throws -> BrowserMediaDiscoveryObservation? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let message = try? JSONDecoder().decode(Message.self, from: data) else {
            throw BrowserMediaDiscoveryBridgeError.malformedMessage
        }

        guard let pageOrigin = Self.originURL(for: pageURL) else {
            throw BrowserMediaDiscoveryBridgeError.invalidPageOrigin
        }
        let effectiveFrameURL = frameURL ?? pageURL
        guard let frameOrigin = Self.originURL(for: effectiveFrameURL) else {
            throw BrowserMediaDiscoveryBridgeError.invalidFrameOrigin
        }

        let isFrameSameOrigin = Self.originKey(for: frameOrigin) == Self.originKey(for: pageOrigin)
        if let isMain = isMainFrame, isMain && !isFrameSameOrigin {
            throw BrowserMediaDiscoveryBridgeError.invalidFrameOrigin
        }

        let rawURL = message.rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            throw BrowserMediaDiscoveryBridgeError.emptyCandidateURL
        }
        guard rawURL.utf8.count <= Self.maximumCandidateLength else {
            throw BrowserMediaDiscoveryBridgeError.candidateURLTooLong
        }

        guard let resolved = WebpageResourceExtractor.resolveURL(rawURL, baseURL: effectiveFrameURL) else {
            throw BrowserMediaDiscoveryBridgeError.unsupportedCandidateScheme
        }

        let metadataOnly = message.source == .mediaSource || message.source == .protection

        let method = (message.method ?? "GET").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard method == "GET" else {
            throw BrowserMediaDiscoveryBridgeError.unsupportedHTTPMethod
        }

        if let eventID = message.eventID,
           eventID.utf8.count > 128 {
            throw BrowserMediaDiscoveryBridgeError.metadataTooLong
        }
        if let documentID = message.documentID,
           documentID.utf8.count > 128 {
            throw BrowserMediaDiscoveryBridgeError.metadataTooLong
        }
        if let prefix = message.manifestPrefix,
           prefix.utf8.count > Self.maximumMetadataLength {
            throw BrowserMediaDiscoveryBridgeError.metadataTooLong
        }
        if let statusCode = message.status,
           !(100...599).contains(statusCode) {
            throw BrowserMediaDiscoveryBridgeError.malformedMessage
        }
        if let contentLength = message.contentLength,
           contentLength < 0 {
            throw BrowserMediaDiscoveryBridgeError.malformedMessage
        }
        if let appendedByteCount = message.appendedByteCount,
           appendedByteCount < 0 {
            throw BrowserMediaDiscoveryBridgeError.malformedMessage
        }

        let lowerScheme = resolved.scheme?.lowercased() ?? ""
        let isBlob = lowerScheme == "blob"
        if !isBlob {
            guard lowerScheme == "http" || lowerScheme == "https",
                  BrowserURLResolver.isValidDownloadURL(resolved) else {
                throw BrowserMediaDiscoveryBridgeError.unsupportedCandidateScheme
            }
            guard let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
                  components.user == nil,
                  components.password == nil else {
                throw BrowserMediaDiscoveryBridgeError.credentialedCandidateURL
            }
        }

        let candidateOriginMatchesPage: Bool
        if isBlob {
            candidateOriginMatchesPage = false
        } else {
            candidateOriginMatchesPage = Self.originKey(for: resolved) == Self.originKey(for: pageOrigin)
        }

        if !isFrameSameOrigin && candidateOriginMatchesPage {
            throw BrowserMediaDiscoveryBridgeError.crossOriginFrameRejected
        }

        let responseURL: URL?
        if let rawResponseURL = message.responseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawResponseURL.isEmpty {
            guard rawResponseURL.utf8.count <= Self.maximumCandidateLength,
                  let candidateResponseURL = WebpageResourceExtractor.resolveURL(rawResponseURL, baseURL: effectiveFrameURL),
                  let responseScheme = candidateResponseURL.scheme?.lowercased(),
                  responseScheme == "http" || responseScheme == "https",
                  BrowserURLResolver.isValidDownloadURL(candidateResponseURL),
                  let responseComponents = URLComponents(url: candidateResponseURL, resolvingAgainstBaseURL: false),
                  responseComponents.user == nil,
                  responseComponents.password == nil else {
                throw BrowserMediaDiscoveryBridgeError.unsupportedCandidateScheme
            }
            if !isFrameSameOrigin && Self.originKey(for: candidateResponseURL) == Self.originKey(for: pageOrigin) {
                throw BrowserMediaDiscoveryBridgeError.crossOriginFrameRejected
            }
            responseURL = candidateResponseURL
        } else {
            responseURL = nil
        }

        let trustedFrame = isFrameSameOrigin
        let mayUseCredentials = !isBlob && !metadataOnly && trustedFrame && candidateOriginMatchesPage
        let dedupeKey: String
        if metadataOnly {
            // Metadata events are observations, not resource candidates. Keep
            // their event identity so multiple MSE buffers are not collapsed.
            dedupeKey = "metadata:\(message.eventID ?? UUID().uuidString)"
        } else {
            dedupeKey = isBlob ? "blob:\(rawURL)" : resolved.absoluteString
        }

        let key = dedupeKey.lowercased()
        let hasPrefix = message.manifestPrefix != nil && !message.manifestPrefix!.isEmpty

        let isAlreadySeen = seenKeys.contains(key)
        let isAlreadySeenWithPrefix = seenKeysWithPrefix.contains(key)
        let shouldAccept: Bool
        if hasPrefix {
            if isAlreadySeenWithPrefix {
                shouldAccept = false
            } else {
                seenKeysWithPrefix.insert(key)
                seenKeys.insert(key)
                shouldAccept = true
            }
        } else {
            if isAlreadySeen {
                shouldAccept = false
            } else {
                seenKeys.insert(key)
                shouldAccept = true
            }
        }

        guard shouldAccept else { return nil }

        let declaredType = Self.normalizedMetadata(message.declaredType)
        let manifestPrefix = message.manifestPrefix.map {
            String($0.prefix(Self.maximumMetadataLength))
        }
        let classifiedKind: StreamingManifestKind?
        if let manifestPrefix,
           let prefixData = manifestPrefix.data(using: .utf8) {
            let classification = StreamingManifestClassifier.classify(
                url: resolved,
                mimeType: declaredType,
                content: prefixData,
                limits: ManifestParsingLimits(maxBytes: Self.maximumMetadataLength)
            )
            classifiedKind = classification.kind == .hls || classification.kind == .dash
                ? classification.kind
                : nil
        } else if let advertisedKind = message.manifestKind,
                  let kind = StreamingManifestKind(rawValue: advertisedKind),
                  kind == .hls || kind == .dash {
            classifiedKind = kind
        } else {
            let fallback = StreamingManifestClassifier.classify(
                url: resolved,
                mimeType: declaredType
            )
            classifiedKind = fallback.kind == .hls || fallback.kind == .dash
                ? fallback.kind
                : nil
        }

        let observationBlobKind: BlobKind?
        if let rawBlobKind = message.blobKind {
            observationBlobKind = BlobKind(rawValue: rawBlobKind) ?? .unknown
        } else if isBlob && message.source == .mediaSource {
            observationBlobKind = .mediaSource
        } else if isBlob && message.source == .blob {
            observationBlobKind = .blob
        } else if isBlob {
            observationBlobKind = .unknown
        } else {
            observationBlobKind = nil
        }

        return BrowserMediaDiscoveryObservation(
            url: isBlob || metadataOnly ? nil : resolved,
            rawURL: rawURL,
            source: message.source,
            tag: Self.normalizedMetadata(message.tag),
            declaredType: declaredType,
            eventID: Self.normalizedMetadata(message.eventID),
            responseURL: responseURL,
            method: method,
            statusCode: message.status,
            contentLength: message.contentLength,
            manifestKind: classifiedKind,
            manifestPrefix: manifestPrefix,
            documentID: Self.normalizedMetadata(message.documentID),
            appendedByteCount: message.appendedByteCount,
            isPotentiallyProtected: message.isPotentiallyProtected == true || message.source == .protection,
            pageOrigin: pageOrigin,
            frameOrigin: frameOrigin,
            mayUseBrowserCredentials: mayUseCredentials,
            blobKind: observationBlobKind,
            width: message.width,
            height: message.height,
            duration: message.duration,
            codecs: message.codecs
        )
    }

    #if canImport(WebKit)
    public func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.urlResolutionHookScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        userScriptManager.inject(into: configuration)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.observerScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.add(self, name: Self.messageName)
    }

    /// Evaluates client-side URL transformation in the given webview.
    /// Uses `window.resolvePlayerURL(url)` if defined (e.g. by custom user scripts or the page),
    /// and gracefully falls back to returning the original `rawURL` if no custom script is loaded,
    /// if the evaluation fails or throws, or if the returned string is not a valid download URL.
    @MainActor
    public func resolveMediaURL(_ rawURL: URL, on webView: WKWebView) async -> URL {
        let rawString = rawURL.absoluteString
        let escaped = rawString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let script = """
        (function(raw) {
            try {
                if (typeof window.resolvePlayerURL === 'function') {
                    return window.resolvePlayerURL(raw);
                }
                if (typeof window.__resolveMediaURL === 'function') {
                    return window.__resolveMediaURL(raw);
                }
                if (window.ytplayer && window.ytplayer.config && typeof window.ytplayer.config.resolveURL === 'function') {
                    return window.ytplayer.config.resolveURL(raw);
                }
                return raw;
            } catch (e) {
                return raw;
            }
        })("\(escaped)")
        """
        guard let result = try? await webView.evaluateJavaScript(script) as? String,
              let resolved = URL(string: result),
              BrowserURLResolver.isValidDownloadURL(resolved) else {
            return rawURL
        }
        return resolved
    }

    /// Evaluates a JavaScript `fetch()` request directly in the given webview using `callAsyncJavaScript`.
    /// This properly awaits asynchronous Promises and bypasses URLSession to guarantee the exact
    /// browser TLS fingerprint, cookies, and session authentication are used to retrieve the manifest text.
    /// Safely bounds the response reading to `maxBytes` to prevent unbounded memory growth in the WebContent process.
    @MainActor
    public func fetchManifestText(
        from url: URL,
        on webView: WKWebView,
        maxBytes: Int = 1_048_576
    ) async throws -> String {
        let rawString = url.absoluteString

        let asyncScript = """
        let acceptHeader = '*/*';
        const lowerUrl = String(url || '').toLowerCase();
        if (lowerUrl.includes('.mpd')) {
            acceptHeader = 'application/dash+xml, application/xml, text/xml, */*';
        } else if (lowerUrl.includes('.m3u8')) {
            acceptHeader = 'application/vnd.apple.mpegurl, application/x-mpegURL, */*';
        }
        const limit = Number(maxBytes) || 1048576;
        let response;
        try {
            response = await fetch(url, {
                method: 'GET',
                credentials: 'include',
                headers: {
                    'Accept': acceptHeader
                }
            });
        } catch (e1) {
            // If credentials: 'include' fails (e.g. CORS restrictions on wildcards Access-Control-Allow-Origin: *),
            // fallback to credentials: 'omit' so the manifest can still be retrieved.
            try {
                response = await fetch(url, {
                    method: 'GET',
                    credentials: 'omit',
                    headers: {
                        'Accept': acceptHeader
                    }
                });
            } catch (e2) {
                const errMsg = (e2 && e2.name ? (e2.name + ': ' + (e2.message || '')) : String(e2));
                return { error: errMsg || 'Unknown fetch error' };
            }
        }
        try {
            if (!response.ok) {
                return { error: 'HTTP ' + response.status + (response.statusText ? ' ' + response.statusText : '') };
            }
            const clHeader = response.headers.get('content-length');
            if (clHeader !== null) {
                const cl = parseInt(clHeader, 10);
                if (!isNaN(cl) && cl > limit) {
                    return { error: 'Manifest exceeds size limit of ' + limit + ' bytes (Content-Length: ' + cl + ')' };
                }
            }
            if (response.body && typeof response.body.getReader === 'function') {
                const reader = response.body.getReader();
                const decoder = new TextDecoder();
                let bytesRead = 0;
                let textResult = '';
                while (true) {
                    const { done, value } = await reader.read();
                    if (done) break;
                    if (value && value.byteLength > 0) {
                        const remaining = limit - bytesRead;
                        if (remaining <= 0) {
                            try { await reader.cancel(); } catch (_) {}
                            return { error: 'Manifest exceeds size limit of ' + limit + ' bytes' };
                        }
                        const slice = value.byteLength > remaining ? value.subarray(0, remaining) : value;
                        bytesRead += slice.byteLength;
                        textResult += decoder.decode(slice, { stream: bytesRead < limit });
                        if (bytesRead >= limit) {
                            try { await reader.cancel(); } catch (_) {}
                            return { error: 'Manifest exceeds size limit of ' + limit + ' bytes' };
                        }
                    }
                }
                textResult += decoder.decode();
                return { text: textResult };
            } else {
                return { error: 'ReadableStream reader not available to safely bound manifest download' };
            }
        } catch (e) {
            const errMsg = (e && e.name ? (e.name + ': ' + (e.message || '')) : String(e));
            return { error: errMsg || 'Unknown fetch error' };
        }
        """

        do {
            return try await executeAsyncJavaScript(
                asyncScript,
                arguments: ["url": rawString, "maxBytes": maxBytes],
                on: webView,
                contentWorld: .page
            )
        } catch let pageError {
            PipelineLogger.shared.log("[BrowserMediaDiscoveryBridge] .page contentWorld fetch failed for \(rawString): \(pageError.localizedDescription). Trying .defaultClient...")
            // Attempt in .defaultClient world if .page fails (e.g. CSP restrictions)
            do {
                return try await executeAsyncJavaScript(
                    asyncScript,
                    arguments: ["url": rawString, "maxBytes": maxBytes],
                    on: webView,
                    contentWorld: .defaultClient
                )
            } catch {
                PipelineLogger.shared.log("[BrowserMediaDiscoveryBridge] .defaultClient fetch also failed for \(rawString): \(error.localizedDescription)")
                throw pageError
            }
        }
    }

    @MainActor
    private func executeAsyncJavaScript(
        _ script: String,
        arguments: [String: Any],
        on webView: WKWebView,
        contentWorld: WKContentWorld
    ) async throws -> String {
        guard webView.url != nil else {
            throw StreamingManifestLoadError.browserFetchUnavailable
        }

        let rawTargetURL = (arguments["url"] as? String) ?? "unknown"
        let maxLimit = (arguments["maxBytes"] as? Int) ?? 1_048_576

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    webView.callAsyncJavaScript(
                        script,
                        arguments: arguments,
                        in: nil,
                        in: contentWorld
                    ) { (result: Result<Any, Error>) in
                        switch result {
                        case .success(let anyValue):
                            if let dict = anyValue as? [String: Any] {
                                if let errorMsg = dict["error"] as? String, !errorMsg.isEmpty {
                                    PipelineLogger.shared.log("[BrowserMediaDiscoveryBridge] JS fetch error for \(rawTargetURL): \(errorMsg)")
                                    if errorMsg.contains("Manifest exceeds size limit") {
                                        continuation.resume(throwing: ManifestParserError.inputTooLarge(limit: maxLimit))
                                        return
                                    }
                                    continuation.resume(throwing: StreamingManifestLoadError.failed(errorMsg))
                                    return
                                }
                                if let text = dict["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    continuation.resume(returning: text)
                                    return
                                }
                            }
                            if let text = anyValue as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                continuation.resume(returning: text)
                            } else {
                                continuation.resume(throwing: StreamingManifestLoadError.invalidResponse)
                            }
                        case .failure(let error):
                            let nsError = error as NSError
                            let detail = (nsError.userInfo["WKJavaScriptExceptionMessageErrorKey"] as? String)
                                ?? (nsError.userInfo["WKErrorJavaScriptExceptionMessageKey"] as? String)
                                ?? (nsError.userInfo["WKJavaScriptExceptionMessage"] as? String)
                                ?? error.localizedDescription
                            PipelineLogger.shared.log("[BrowserMediaDiscoveryBridge] JS evaluation failed for \(rawTargetURL): \(detail)")
                            continuation.resume(throwing: StreamingManifestLoadError.failed(detail))
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw StreamingManifestLoadError.failed("Browser manifest fetch timed out after 15 seconds")
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw StreamingManifestLoadError.failed("Browser manifest fetch completed without result")
            }
            group.cancelAll()
            return result
        }
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName,
              let webView = message.webView,
              let pageURL = webView.url else {
            errorHandler?(.malformedMessage)
            return
        }

        let frame = message.frameInfo
        let securityOrigin = frame.securityOrigin
        let originProtocol = securityOrigin.protocol.lowercased()
        guard (originProtocol == "http" || originProtocol == "https"),
              !securityOrigin.host.isEmpty else {
            errorHandler?(.invalidFrameOrigin)
            return
        }

        let portSuffix = securityOrigin.port != 0 ? ":\(securityOrigin.port)" : ""
        guard let frameURL = URL(string: "\(originProtocol)://\(securityOrigin.host)\(portSuffix)") else {
            errorHandler?(.invalidFrameOrigin)
            return
        }

        do {
            let observation = try accept(
                payload: message.body,
                pageURL: pageURL,
                frameURL: frameURL,
                isMainFrame: frame.isMainFrame
            )
            if let observation {
                observationHandler?(observation)
            }
        } catch let error as BrowserMediaDiscoveryBridgeError {
            errorHandler?(error)
        } catch {
            errorHandler?(.malformedMessage)
        }
    }
    #else
    public func resolveMediaURL(_ rawURL: URL, on webView: AnyObject? = nil) async -> URL {
        return rawURL
    }
    #endif

    private struct Message: Codable {
        let rawURL: String
        let source: BrowserMediaDiscoverySource
        let tag: String?
        let declaredType: String?
        let eventID: String?
        let responseURL: String?
        let method: String?
        let status: Int?
        let contentLength: Int64?
        let manifestKind: String?
        let manifestPrefix: String?
        let documentID: String?
        let appendedByteCount: Int64?
        let isPotentiallyProtected: Bool?
        let blobKind: String?
        let width: Int?
        let height: Int?
        let duration: Double?
        let codecs: String?
    }

    private static func normalizedMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(128))
    }

    private static func originURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host.lowercased()
        if let port = url.port,
           !((scheme == "http" && port == 80) || (scheme == "https" && port == 443)) {
            components.port = port
        }
        return components.url
    }

    private static func originKey(for url: URL) -> String? {
        guard let origin = originURL(for: url) else { return nil }
        return origin.absoluteString.lowercased()
    }

    /// Filters a list of media candidates based on user-configured sniffer filters.
    public nonisolated static func filter(
        candidates: [BrowserMediaCandidate],
        using filter: BrowserSnifferFilter = BrowserSnifferFilter.load()
    ) -> [BrowserMediaCandidate] {
        guard filter.isFilterEnabled else { return candidates }
        return candidates.filter { filter.matches(candidate: $0) }
    }
}


#if canImport(WebKit)
extension BrowserMediaDiscoveryBridge: WKScriptMessageHandler {}
#endif
