import Foundation

#if canImport(WebKit)
import WebKit
#endif

public enum BrowserMediaDiscoverySource: String, Codable, Sendable, Equatable {
    case fetch
    case xmlHttpRequest
    case mediaElement
    case sourceElement
    case domMutation
    case performanceResource
}

/// A discovery event from page JavaScript. `url == nil` is intentional for a
/// `blob:` signal: blob URLs are browser-managed resources and must not be sent
/// to the HTTP download coordinator.
public struct BrowserMediaDiscoveryObservation: Codable, Sendable, Equatable {
    public let url: URL?
    public let rawURL: String
    public let source: BrowserMediaDiscoverySource
    public let tag: String?
    public let declaredType: String?
    public let pageOrigin: URL
    public let frameOrigin: URL
    public let mayUseBrowserCredentials: Bool

    public var isBlobSignal: Bool {
        url == nil && rawURL.lowercased().hasPrefix("blob:")
    }

    public init(
        url: URL?,
        rawURL: String,
        source: BrowserMediaDiscoverySource,
        tag: String? = nil,
        declaredType: String? = nil,
        pageOrigin: URL,
        frameOrigin: URL,
        mayUseBrowserCredentials: Bool
    ) {
        self.url = url
        self.rawURL = rawURL
        self.source = source
        self.tag = tag
        self.declaredType = declaredType
        self.pageOrigin = pageOrigin
        self.frameOrigin = frameOrigin
        self.mayUseBrowserCredentials = mayUseBrowserCredentials
    }
}

public enum BrowserMediaDiscoveryBridgeError: Error, LocalizedError, Equatable, Sendable {
    case malformedMessage
    case invalidPageOrigin
    case invalidFrameOrigin
    case emptyCandidateURL
    case candidateURLTooLong
    case unsupportedCandidateScheme
    case credentialedCandidateURL

    public var errorDescription: String? {
        switch self {
        case .malformedMessage:
            return "The browser media discovery message was malformed."
        case .invalidPageOrigin:
            return "The browser page origin is invalid for media discovery."
        case .invalidFrameOrigin:
            return "The browser frame origin is invalid for media discovery."
        case .emptyCandidateURL:
            return "The browser media discovery message did not contain a URL."
        case .candidateURLTooLong:
            return "The browser media discovery URL exceeded the safety limit."
        case .unsupportedCandidateScheme:
            return "The browser media discovery URL uses an unsupported scheme."
        case .credentialedCandidateURL:
            return "Credential-bearing URLs are not accepted from browser media discovery."
        }
    }
}

/// Validates and deduplicates messages emitted by the page instrumentation.
///
/// The bridge never receives cookies or headers. Browser credentials may only be
/// captured later for a same-origin observation; cross-origin and cross-frame
/// observations are forwarded without credential inheritance.
public final class BrowserMediaDiscoveryBridge: NSObject, @unchecked Sendable {
    public static let messageName = "browserMediaDiscovery"
    public static let maximumCandidateLength = 8_192

    /// This script observes page-owned resource signals only. It does not read
    /// cookies, request bodies, response bodies, or authorization headers.
    public static let observerScript = #"""
    (function() {
        "use strict";
        if (window.__lidMediaDiscoveryInstalled) { return; }
        window.__lidMediaDiscoveryInstalled = true;

        var handler = window.webkit && window.webkit.messageHandlers &&
            window.webkit.messageHandlers.browserMediaDiscovery;
        if (!handler) { return; }

        function absoluteURL(value) {
            if (value === null || value === undefined) { return null; }
            var text = String(value).trim();
            if (!text || text.length > 8192) { return null; }
            try { return new URL(text, document.baseURI).href; } catch (_) { return null; }
        }

        function emit(value, source, tag, declaredType) {
            var url = absoluteURL(value);
            if (!url) { return; }
            try {
                handler.postMessage({
                    rawURL: url,
                    source: source,
                    tag: tag || null,
                    declaredType: declaredType || null
                });
            } catch (_) {}
        }

        function inspectElement(element, source) {
            if (!element || !element.tagName) { return; }
            var name = element.tagName.toLowerCase();
            var tag = (name === "video" || name === "audio") ? name : "source";
            var type = element.getAttribute("type") || null;
            if (element.currentSrc) { emit(element.currentSrc, source, tag, type); }
            if (element.src) { emit(element.src, source, tag, type); }
            var raw = element.getAttribute("src");
            if (raw) { emit(raw, source, tag, type); }
        }

        function inspectTree(root) {
            if (!root || !root.querySelectorAll) { return; }
            if (root.tagName) { inspectElement(root, "domMutation"); }
            root.querySelectorAll("video, audio, source").forEach(function(element) {
                inspectElement(element, "domMutation");
            });
        }

        try {
            var mediaPrototype = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
            var mediaSourceDescriptor = mediaPrototype &&
                Object.getOwnPropertyDescriptor(mediaPrototype, "src");
            if (mediaSourceDescriptor && mediaSourceDescriptor.set && mediaSourceDescriptor.get) {
                Object.defineProperty(mediaPrototype, "src", {
                    configurable: mediaSourceDescriptor.configurable,
                    enumerable: mediaSourceDescriptor.enumerable,
                    get: mediaSourceDescriptor.get,
                    set: function(value) {
                        var tag = this.tagName ? this.tagName.toLowerCase() : "media";
                        emit(value, "mediaElement", tag, null);
                        return mediaSourceDescriptor.set.call(this, value);
                    }
                });
            }
        } catch (_) {}

        try {
            var originalFetch = window.fetch;
            if (typeof originalFetch === "function") {
                window.fetch = function(input) {
                    var requestURL = input && input.url ? input.url : input;
                    var promise = originalFetch.apply(this, arguments);
                    return promise.then(function(response) {
                        var type = null;
                        try { type = response.headers.get("content-type"); } catch (_) {}
                        emit(requestURL, "fetch", null, type);
                        return response;
                    });
                };
            }
        } catch (_) {}

        try {
            var originalOpen = XMLHttpRequest.prototype.open;
            var originalSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                this.__lidMediaURL = url;
                return originalOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
                var request = this;
                this.addEventListener("loadend", function() {
                    var type = null;
                    try { type = request.getResponseHeader("content-type"); } catch (_) {}
                    emit(request.__lidMediaURL, "xmlHttpRequest", null, type);
                }, { once: true });
                return originalSend.apply(this, arguments);
            };
        } catch (_) {}

        try {
            if (window.PerformanceObserver) {
                var observer = new PerformanceObserver(function(list) {
                    list.getEntries().forEach(function(entry) {
                        if (entry && entry.name) { emit(entry.name, "performanceResource", null, null); }
                    });
                });
                observer.observe({ type: "resource", buffered: true });
            }
        } catch (_) {}

        try {
            var mutations = new MutationObserver(function(records) {
                records.forEach(function(record) {
                    if (record.type === "attributes" && record.target) {
                        inspectElement(record.target, "domMutation");
                    }
                    if (record.addedNodes) {
                        record.addedNodes.forEach(function(node) { inspectTree(node); });
                    }
                });
            });
            mutations.observe(document.documentElement || document, {
                subtree: true,
                childList: true,
                attributes: true,
                attributeFilter: ["src", "type"]
            });
        } catch (_) {}

        try { inspectTree(document); } catch (_) {}
    })();
    """#

    public var observationHandler: ((BrowserMediaDiscoveryObservation) -> Void)?
    public var errorHandler: ((BrowserMediaDiscoveryBridgeError) -> Void)?

    private let lock = NSLock()
    private var seenKeys: Set<String> = []

    public override init() {
        super.init()
    }

    public func reset() {
        lock.lock()
        seenKeys.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Decodes and validates a message body without requiring WebKit. This is
    /// the deterministic boundary used by unit tests and by the WebKit handler.
    @discardableResult
    public func accept(
        payload: Any,
        pageURL: URL,
        frameURL: URL? = nil
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

        let rawURL = message.rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            throw BrowserMediaDiscoveryBridgeError.emptyCandidateURL
        }
        guard rawURL.utf8.count <= Self.maximumCandidateLength else {
            throw BrowserMediaDiscoveryBridgeError.candidateURLTooLong
        }

        guard let resolved = WebpageResourceExtractor.resolveURL(rawURL, baseURL: pageURL) else {
            throw BrowserMediaDiscoveryBridgeError.unsupportedCandidateScheme
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
            candidateOriginMatchesPage = Self.originKey(for: resolved) == Self.originKey(for: pageURL)
        }
        let trustedFrame = Self.originKey(for: frameOrigin) == Self.originKey(for: pageOrigin)
        let mayUseCredentials = !isBlob && trustedFrame && candidateOriginMatchesPage
        let dedupeKey = isBlob ? "blob:\(rawURL)" : resolved.absoluteString

        lock.lock()
        let isNew = seenKeys.insert(dedupeKey.lowercased()).inserted
        lock.unlock()
        guard isNew else { return nil }

        return BrowserMediaDiscoveryObservation(
            url: isBlob ? nil : resolved,
            rawURL: rawURL,
            source: message.source,
            tag: normalizedMetadata(message.tag),
            declaredType: normalizedMetadata(message.declaredType),
            pageOrigin: pageOrigin,
            frameOrigin: frameOrigin,
            mayUseBrowserCredentials: mayUseCredentials
        )
    }

    #if canImport(WebKit)
    public func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.observerScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.add(self, name: Self.messageName)
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

        do {
            let observation = try accept(
                payload: message.body,
                pageURL: pageURL,
                frameURL: message.frameInfo.request.url
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
    #endif

    private struct Message: Codable {
        let rawURL: String
        let source: BrowserMediaDiscoverySource
        let tag: String?
        let declaredType: String?
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
}

#if canImport(WebKit)
extension BrowserMediaDiscoveryBridge: WKScriptMessageHandler {}
#endif
