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
        mayUseBrowserCredentials: Bool
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
public final class BrowserMediaDiscoveryBridge: NSObject, @unchecked Sendable {
    public static let messageName = "browserMediaDiscovery"
    public static let maximumCandidateLength = 8_192
    public static let maximumMetadataLength = 65_536

    /// This script observes page-owned resource signals only. It does not read
    /// cookies, request bodies, or authorization headers. Possible manifests get
    /// only a bounded text prefix from a cloned response; ordinary responses are
    /// never copied or inspected.
    public static let observerScript = #"""
    (function() {
        "use strict";
        if (window.__lidMediaDiscoveryInstalled) { return; }
        window.__lidMediaDiscoveryInstalled = true;

        // Never instrument Cloudflare challenge platform domains, Turnstile frames, or challenge endpoints
        try {
            var host = (window.location && window.location.hostname) ? window.location.hostname.toLowerCase() : "";
            var path = (window.location && window.location.pathname) ? window.location.pathname.toLowerCase() : "";
            var href = (window.location && window.location.href) ? window.location.href.toLowerCase() : "";
            if (host.indexOf("cloudflare.com") !== -1 ||
                host.indexOf("challenges.cloudflare.com") !== -1 ||
                path.indexOf("/cdn-cgi/") !== -1 ||
                href.indexOf("/cdn-cgi/") !== -1 ||
                href.indexOf("challenges.cloudflare.com") !== -1) {
                return;
            }
            if (document.getElementById("challenge-stage") ||
                document.getElementById("challenge-form") ||
                document.getElementById("challenge-running") ||
                document.querySelector(".cf-turnstile-wrapper") ||
                document.querySelector("iframe[src*='challenges.cloudflare.com']") ||
                document.querySelector("iframe[src*='turnstile']") ||
                document.querySelector("script[src*='/cdn-cgi/challenge-platform']")) {
                return;
            }
        } catch (_) {}

        var handler = window.webkit && window.webkit.messageHandlers &&
            window.webkit.messageHandlers.browserMediaDiscovery;
        if (!handler) { return; }

        var documentID = "document-" + Math.random().toString(36).slice(2) + "-" + Date.now().toString(36);
        try {
            if (window.crypto && typeof window.crypto.randomUUID === "function") {
                documentID = window.crypto.randomUUID();
            }
        } catch (_) {}
        try { window.__lidMediaDocumentID = documentID; } catch (_) {}
        var mediaSourceObjectURLs = typeof WeakMap === "function" ? new WeakMap() : null;
        var sourceBufferMediaSourceURLs = typeof WeakMap === "function" ? new WeakMap() : null;

        function absoluteURL(value) {
            if (value === null || value === undefined) { return null; }
            var text = String(value).trim();
            if (!text || text.length > 8192) { return null; }
            try { return new URL(text, document.baseURI).href; } catch (_) { return null; }
        }

        var nextEventID = 0;
        var MAX_INSPECTION_BYTES = 65536;

        function manifestKindFor(url, declaredType, prefix) {
            var mime = declaredType ? String(declaredType).toLowerCase().split(";", 1)[0].trim() : "";
            var lowerURL = url ? String(url).toLowerCase() : "";
            var urlPath = lowerURL;
            try { urlPath = new URL(lowerURL).pathname.toLowerCase(); } catch (_) {}
            var text = prefix ? String(prefix).replace(/^\uFEFF/, "").trim() : "";
            var hls = text.indexOf("#EXTM3U") === 0 ||
                mime.indexOf("mpegurl") >= 0 || /(?:^|[./])m3u8$/.test(urlPath);
            var dash = /<\s*(?:[a-z_][a-z0-9_.-]*:)?mpd(?:\s|>)/i.test(text) ||
                mime === "application/dash+xml" || mime === "video/vnd.mpeg.dash.mpd" ||
                /(?:^|[./])mpd$/.test(urlPath);
            if (hls && dash) { return "unsupported"; }
            if (hls) { return "hls"; }
            if (dash) { return "dash"; }
            return null;
        }

        function shouldInspect(url, declaredType) {
            return manifestKindFor(url, declaredType, null) !== null;
        }

        function headerContentLength(headers) {
            try {
                var value = headers && headers.get ? headers.get("content-length") : null;
                var parsed = value === null ? NaN : Number(value);
                return isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : null;
            } catch (_) { return null; }
        }

        function inspectResponsePrefix(response) {
            if (!response || !response.clone || !response.body || !window.TextDecoder) {
                return Promise.resolve(null);
            }
            var clone;
            try { clone = response.clone(); } catch (_) { return Promise.resolve(null); }
            var reader;
            try { reader = clone.body.getReader(); } catch (_) { return Promise.resolve(null); }
            var decoder = new TextDecoder();
            var text = "";
            var total = 0;
            function readNext() {
                return reader.read().then(function(part) {
                    if (!part || part.done) { return text; }
                    var bytes = part.value || new Uint8Array(0);
                    var remaining = MAX_INSPECTION_BYTES - total;
                    if (remaining <= 0) {
                        try { reader.cancel(); } catch (_) {}
                        return text;
                    }
                    if (bytes.byteLength > remaining) { bytes = bytes.slice(0, remaining); }
                    total += bytes.byteLength;
                    text += decoder.decode(bytes);
                    if (total >= MAX_INSPECTION_BYTES) {
                        try { reader.cancel(); } catch (_) {}
                        return text;
                    }
                    return readNext();
                }).catch(function() { return text || null; });
            }
            return readNext();
        }

        function emit(value, source, metadata) {
            var url = absoluteURL(value);
            if (!url) { return; }
            metadata = metadata || {};
            var eventID = metadata.eventID || (source + "-" + (++nextEventID));
            var declaredType = metadata.declaredType || null;
            var prefix = metadata.manifestPrefix || null;
            var kind = metadata.manifestKind || manifestKindFor(url, declaredType, prefix);
            try {
                var message = {
                    eventID: eventID,
                    rawURL: url,
                    source: source,
                    tag: metadata.tag || null,
                    declaredType: declaredType,
                responseURL: metadata.responseURL || null,
                method: metadata.method || "GET",
                status: metadata.status === undefined ? null : metadata.status,
                contentLength: metadata.contentLength === undefined ? null : metadata.contentLength,
                documentID: metadata.documentID || documentID,
                appendedByteCount: metadata.appendedByteCount === undefined ? null : metadata.appendedByteCount,
                isPotentiallyProtected: metadata.isPotentiallyProtected === true,
                manifestKind: kind,
                manifestPrefix: prefix
            };
                handler.postMessage(message);
            } catch (_) {}
        }

        function emitResponse(response, requestURL, source, method) {
            var type = null;
            var responseURL = null;
            var status = null;
            var contentLength = null;
            try { type = response.headers.get("content-type"); } catch (_) {}
            try { responseURL = response.url || null; } catch (_) {}
            try { status = response.status; } catch (_) {}
            try { contentLength = headerContentLength(response.headers); } catch (_) {}
            var metadata = {
                method: method || "GET",
                declaredType: type,
                responseURL: responseURL,
                status: status,
                contentLength: contentLength
            };
            if (!shouldInspect(requestURL, type)) {
                emit(requestURL, source, metadata);
                return;
            }
            inspectResponsePrefix(response).then(function(prefix) {
                metadata.manifestPrefix = prefix ? String(prefix).slice(0, MAX_INSPECTION_BYTES) : null;
                metadata.manifestKind = manifestKindFor(requestURL, type, metadata.manifestPrefix);
                emit(requestURL, source, metadata);
            });
        }

        function inspectElement(element, source) {
            if (!element || !element.tagName) { return; }
            var name = element.tagName.toLowerCase();
            var tag = (name === "video" || name === "audio") ? name : "source";
            var type = element.getAttribute("type") || null;
            if (element.currentSrc) { emit(element.currentSrc, source, { tag: tag, declaredType: type, method: "GET" }); }
            if (element.src) { emit(element.src, source, { tag: tag, declaredType: type, method: "GET" }); }
            var raw = element.getAttribute("src");
            if (raw) { emit(raw, source, { tag: tag, declaredType: type, method: "GET" }); }
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
                        emit(value, "mediaElement", { tag: tag, method: "GET" });
                        return mediaSourceDescriptor.set.call(this, value);
                    }
                });
            }
        } catch (_) {}

        try {
            var originalSetAttribute = Element.prototype.setAttribute;
            if (typeof originalSetAttribute === "function") {
                Element.prototype.setAttribute = function(name, value) {
                    try {
                        if (String(name || "").toLowerCase() === "src") {
                            var tag = this.tagName ? this.tagName.toLowerCase() : "";
                            if (tag === "video" || tag === "audio" || tag === "source") {
                                emit(String(value), "mediaElement", { tag: tag, method: "GET" });
                            }
                        }
                    } catch (_) {}
                    return originalSetAttribute.apply(this, arguments);
                };
            }
        } catch (_) {}

        // Blob object URLs are reported as metadata only. The page-local
        // registry retains the opaque Blob object, never its bytes, so an
        // explicit capture can read bounded slices later without relying on
        // fetch() to expose Content-Length. MediaSource entries retain the
        // object handle for optional capture without retaining append payloads.
        try {
            window.__lidBlobRegistry = window.__lidBlobRegistry || Object.create(null);
            var blobRegistry = window.__lidBlobRegistry;
            if (window.URL && typeof window.URL.createObjectURL === "function") {
                var originalCreateObjectURL = window.URL.createObjectURL;
                window.URL.createObjectURL = function(object) {
                    var objectURL = originalCreateObjectURL.apply(this, arguments);
                    try {
                        if (window.Blob && object instanceof window.Blob) {
                            blobRegistry[objectURL] = {
                                kind: "blob",
                                blob: object,
                                size: isFinite(object.size) ? Math.floor(object.size) : null,
                                type: object.type || null,
                                documentID: documentID
                            };
                            emit(objectURL, "blob", {
                                tag: "blob",
                                declaredType: object.type || null,
                                contentLength: isFinite(object.size) ? Math.floor(object.size) : null,
                                method: "GET"
                            });
                        } else if (window.MediaSource && object instanceof window.MediaSource) {
                            if (mediaSourceObjectURLs) { mediaSourceObjectURLs.set(object, objectURL); }
                            blobRegistry[objectURL] = {
                                kind: "mediaSource",
                                mediaSource: object,
                                documentID: documentID
                            };
                            emit(objectURL, "mediaSource", {
                                tag: "mediaSource",
                                method: "GET"
                            });
                        }
                    } catch (_) {}
                    return objectURL;
                };
            }
            if (window.URL && typeof window.URL.revokeObjectURL === "function") {
                var originalRevokeObjectURL = window.URL.revokeObjectURL;
                window.URL.revokeObjectURL = function(objectURL) {
                    try { delete blobRegistry[String(objectURL)]; } catch (_) {}
                    return originalRevokeObjectURL.apply(this, arguments);
                };
            }
        } catch (_) {}

        // EME is an observation of possible protection, not proof that every
        // resource on the page is DRM protected. Never inspect key-system
        // configuration or license data here.
        try {
            if (navigator && typeof navigator.requestMediaKeySystemAccess === "function") {
                var originalRequestMediaKeySystemAccess = navigator.requestMediaKeySystemAccess;
                navigator.requestMediaKeySystemAccess = function(keySystem, configurations) {
                    try {
                        emit(window.location.href, "protection", {
                            tag: "eme",
                            declaredType: String(keySystem || "unknown").slice(0, 128),
                            isPotentiallyProtected: true,
                            method: "GET"
                        });
                    } catch (_) {}
                    return originalRequestMediaKeySystemAccess.apply(this, arguments);
                };
            }
        } catch (_) {}

        // MSE instrumentation records buffer metadata only. It does not copy
        // or retain appendBuffer payloads, so playback remains the page's job.
        // Optional capture lives in a separate bridge and copies bytes only
        // after an explicit user start.
        try {
            var sourceBufferBytes = typeof WeakMap === "function" ? new WeakMap() : null;
            if (window.MediaSource && window.MediaSource.prototype) {
                var originalAddSourceBuffer = window.MediaSource.prototype.addSourceBuffer;
                if (typeof originalAddSourceBuffer === "function") {
                    window.MediaSource.prototype.addSourceBuffer = function(mimeType) {
                        var buffer = originalAddSourceBuffer.apply(this, arguments);
                        var objectURL = null;
                        try {
                            objectURL = mediaSourceObjectURLs ? mediaSourceObjectURLs.get(this) : null;
                            if (sourceBufferMediaSourceURLs && objectURL) {
                                sourceBufferMediaSourceURLs.set(buffer, objectURL);
                            }
                        } catch (_) {}
                        emit(objectURL || window.location.href, "mediaSource", {
                            tag: "sourceBuffer",
                            declaredType: String(mimeType || "").slice(0, 128),
                            method: "GET"
                        });
                        return buffer;
                    };
                }
            }
            if (window.SourceBuffer && window.SourceBuffer.prototype) {
                var originalAppendBuffer = window.SourceBuffer.prototype.appendBuffer;
                if (typeof originalAppendBuffer === "function") {
                    window.SourceBuffer.prototype.appendBuffer = function(data) {
                        var chunkBytes = data && typeof data.byteLength === "number" ? data.byteLength : 0;
                        var totalBytes = chunkBytes;
                        if (sourceBufferBytes) {
                            totalBytes += sourceBufferBytes.get(this) || 0;
                            sourceBufferBytes.set(this, totalBytes);
                        }
                        try {
                            var objectURL = sourceBufferMediaSourceURLs ? sourceBufferMediaSourceURLs.get(this) : null;
                            emit(objectURL || window.location.href, "mediaSource", {
                                tag: "appendBuffer",
                                declaredType: this.type || null,
                                contentLength: chunkBytes,
                                appendedByteCount: totalBytes,
                                method: "GET"
                            });
                        } catch (_) {}
                        return originalAppendBuffer.apply(this, arguments);
                    };
                }
            }
        } catch (_) {}

        try {
            var originalFetch = window.fetch;
            if (typeof originalFetch === "function") {
                var wrappedFetch = function(input, init) {
                    var requestURL = input && input.url ? input.url : input;
                    var reqStr = String(requestURL || "").toLowerCase();
                    if (reqStr.indexOf("/cdn-cgi/") !== -1 ||
                        reqStr.indexOf("challenges.cloudflare.com") !== -1 ||
                        reqStr.indexOf("turnstile") !== -1) {
                        return originalFetch.apply(this, arguments);
                    }
                    var method = (input && input.method) || (init && init.method) || "GET";
                    var promise = originalFetch.apply(this, arguments);
                    return promise.then(function(response) {
                        emitResponse(response, requestURL, "fetch", method);
                        return response;
                    });
                };
                try {
                    wrappedFetch.toString = function() { return "function fetch() { [native code] }"; };
                    Object.defineProperty(wrappedFetch, "name", { value: "fetch", configurable: true });
                } catch (_) {}
                window.fetch = wrappedFetch;
            }
        } catch (_) {}

        try {
            var originalOpen = XMLHttpRequest.prototype.open;
            var originalSend = XMLHttpRequest.prototype.send;
            var xhrMeta = typeof WeakMap === "function" ? new WeakMap() : null;

            var wrappedOpen = function(method, url) {
                if (xhrMeta) {
                    xhrMeta.set(this, { url: url, method: method || "GET" });
                }
                return originalOpen.apply(this, arguments);
            };
            try {
                wrappedOpen.toString = function() { return "function open() { [native code] }"; };
                Object.defineProperty(wrappedOpen, "name", { value: "open", configurable: true });
            } catch (_) {}
            XMLHttpRequest.prototype.open = wrappedOpen;

            var wrappedSend = function() {
                var request = this;
                var meta = xhrMeta ? xhrMeta.get(request) : null;
                var reqURL = meta ? meta.url : null;
                var reqStr = String(reqURL || "").toLowerCase();
                if (reqStr.indexOf("/cdn-cgi/") !== -1 ||
                    reqStr.indexOf("challenges.cloudflare.com") !== -1 ||
                    reqStr.indexOf("turnstile") !== -1) {
                    return originalSend.apply(this, arguments);
                }
                var reqMethod = meta ? meta.method : "GET";
                if (reqURL) {
                    this.addEventListener("loadend", function() {
                        var type = null;
                        try { type = request.getResponseHeader("content-type"); } catch (_) {}
                        var prefix = null;
                        try {
                            if ((request.responseType === "" || request.responseType === "text") && shouldInspect(reqURL, type)) {
                                prefix = String(request.responseText || "").slice(0, MAX_INSPECTION_BYTES);
                            }
                        } catch (_) {}
                        emit(reqURL, "xmlHttpRequest", {
                            method: reqMethod || "GET",
                            declaredType: type,
                            responseURL: request.responseURL || null,
                            status: request.status,
                            contentLength: headerContentLength({ get: function(name) { return request.getResponseHeader(name); } }),
                            manifestPrefix: prefix,
                            manifestKind: manifestKindFor(reqURL, type, prefix)
                        });
                    }, { once: true });
                }
                return originalSend.apply(this, arguments);
            };
            try {
                wrappedSend.toString = function() { return "function send() { [native code] }"; };
                Object.defineProperty(wrappedSend, "name", { value: "send", configurable: true });
            } catch (_) {}
            XMLHttpRequest.prototype.send = wrappedSend;
        } catch (_) {}

        try {
            if (window.PerformanceObserver) {
                var observer = new PerformanceObserver(function(list) {
                    list.getEntries().forEach(function(entry) {
                        if (entry && entry.name) { emit(entry.name, "performanceResource", { method: "GET" }); }
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

        let responseURL: URL?
        if let rawResponseURL = message.responseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawResponseURL.isEmpty {
            guard rawResponseURL.utf8.count <= Self.maximumCandidateLength,
                  let candidateResponseURL = WebpageResourceExtractor.resolveURL(rawResponseURL, baseURL: pageURL),
                  let responseScheme = candidateResponseURL.scheme?.lowercased(),
                  responseScheme == "http" || responseScheme == "https",
                  BrowserURLResolver.isValidDownloadURL(candidateResponseURL),
                  let responseComponents = URLComponents(url: candidateResponseURL, resolvingAgainstBaseURL: false),
                  responseComponents.user == nil,
                  responseComponents.password == nil else {
                throw BrowserMediaDiscoveryBridgeError.unsupportedCandidateScheme
            }
            responseURL = candidateResponseURL
        } else {
            responseURL = nil
        }

        let candidateOriginMatchesPage: Bool
        if isBlob {
            candidateOriginMatchesPage = false
        } else {
            candidateOriginMatchesPage = Self.originKey(for: resolved) == Self.originKey(for: pageURL)
        }
        let trustedFrame = Self.originKey(for: frameOrigin) == Self.originKey(for: pageOrigin)
        let mayUseCredentials = !isBlob && !metadataOnly && trustedFrame && candidateOriginMatchesPage
        let dedupeKey: String
        if metadataOnly {
            // Metadata events are observations, not resource candidates. Keep
            // their event identity so multiple MSE buffers are not collapsed.
            dedupeKey = "metadata:\(message.eventID ?? UUID().uuidString)"
        } else {
            dedupeKey = isBlob ? "blob:\(rawURL)" : resolved.absoluteString
        }

        lock.lock()
        let isNew = seenKeys.insert(dedupeKey.lowercased()).inserted
        lock.unlock()
        guard isNew else { return nil }

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
