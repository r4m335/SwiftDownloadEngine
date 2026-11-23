import Foundation

/// Centralized client-side JavaScript source strings utilized by the browser media
/// discovery engine, user script injection subsystem, and DOM resource scanner.
public enum BrowserMediaDiscoveryScripts {
    /// Injects a generic client-side URL resolution hook into the page context.
    /// Platforms that dynamically generate or rewrite media URLs can define or
    /// override `window.resolvePlayerURL(url)` to return authorized segment URLs.
    public static let urlResolutionHookScript = #"""
    (function() {
        "use strict";
        if (typeof window.resolvePlayerURL !== "function") {
            window.resolvePlayerURL = function(url) {
                return url;
            };
        }
    })();
    """#

    /// Default user script loaded at .atDocumentStart to intercept and resolve
    /// dynamically signed media and segment URLs (e.g. signature and n-parameter transformation).
    public static let defaultURLResolutionScript = #"""
    (function() {
        "use strict";

        function parseQueryParams(urlString) {
            var params = {};
            try {
                var qIdx = urlString.indexOf("?");
                if (qIdx === -1) return params;
                var hashIdx = urlString.indexOf("#", qIdx);
                var query = hashIdx === -1 ? urlString.slice(qIdx + 1) : urlString.slice(qIdx + 1, hashIdx);
                var pairs = query.split("&");
                for (var i = 0; i < pairs.length; i++) {
                    if (!pairs[i]) continue;
                    var eqIdx = pairs[i].indexOf("=");
                    var key = eqIdx === -1 ? pairs[i] : pairs[i].slice(0, eqIdx);
                    var val = eqIdx === -1 ? "" : pairs[i].slice(eqIdx + 1);
                    params[decodeURIComponent(key)] = decodeURIComponent(val);
                }
            } catch (_) {}
            return params;
        }

        function updateQueryParam(urlString, key, newValue) {
            try {
                var base = (window.location && window.location.href) ? window.location.href : "https://localhost/";
                var url = new URL(urlString, base);
                url.searchParams.set(key, newValue);
                return url.href;
            } catch (_) {
                var regex = new RegExp("([?&])" + key + "=([^&#]*)");
                if (regex.test(urlString)) {
                    return urlString.replace(regex, "$1" + key + "=" + encodeURIComponent(newValue));
                } else {
                    var separator = urlString.indexOf("?") === -1 ? "?" : "&";
                    return urlString + separator + key + "=" + encodeURIComponent(newValue);
                }
            }
        }

        function removeQueryParam(urlString, key) {
            try {
                var base = (window.location && window.location.href) ? window.location.href : "https://localhost/";
                var url = new URL(urlString, base);
                url.searchParams.delete(key);
                return url.href;
            } catch (_) {
                var regex = new RegExp("([?&])" + key + "(=[^&#]*)?(&|$)");
                var res = urlString.replace(regex, function(match, p1, p2, p3) {
                    return p3 === "&" ? p1 : "";
                });
                return res.replace(/[?&]$/, "");
            }
        }

        function findPlatformTransformFunctions() {
            var sigFunc = null;
            var nFunc = null;

            if (typeof window.__transformMediaSignature === "function") {
                sigFunc = window.__transformMediaSignature;
            }
            if (typeof window.__transformMediaNParam === "function") {
                nFunc = window.__transformMediaNParam;
            }

            var candidates = [
                window.ytplayer && window.ytplayer.config,
                window._playerConfig,
                window.yt && window.yt.config_,
                window.playerConfig,
                window.__PLAYER_CONFIG__,
                window.ytplayer
            ];

            for (var i = 0; i < candidates.length; i++) {
                var cfg = candidates[i];
                if (!cfg || typeof cfg !== "object") continue;

                if (!sigFunc) {
                    if (typeof cfg.transformSignature === "function") sigFunc = cfg.transformSignature;
                    else if (typeof cfg.signatureTransform === "function") sigFunc = cfg.signatureTransform;
                    else if (typeof cfg.decodeSignature === "function") sigFunc = cfg.decodeSignature;
                    else if (typeof cfg.sigTransform === "function") sigFunc = cfg.sigTransform;
                    else if (typeof cfg.resolveSignature === "function") sigFunc = cfg.resolveSignature;
                    else if (cfg.args && typeof cfg.args.signatureTransform === "function") sigFunc = cfg.args.signatureTransform;
                    else if (cfg.args && typeof cfg.args.transformSignature === "function") sigFunc = cfg.args.transformSignature;
                }

                if (!nFunc) {
                    if (typeof cfg.transformNParam === "function") nFunc = cfg.transformNParam;
                    else if (typeof cfg.nTransform === "function") nFunc = cfg.nTransform;
                    else if (typeof cfg.resolveNParam === "function") nFunc = cfg.resolveNParam;
                    else if (typeof cfg.decodeN === "function") nFunc = cfg.decodeN;
                    else if (cfg.args && typeof cfg.args.nTransform === "function") nFunc = cfg.args.nTransform;
                    else if (cfg.args && typeof cfg.args.transformNParam === "function") nFunc = cfg.args.transformNParam;
                }
            }

            return { sig: sigFunc, n: nFunc };
        }

        window.resolvePlayerURL = function(url) {
            if (!url || typeof url !== "string") {
                return url;
            }

            try {
                var transforms = findPlatformTransformFunctions();
                if (!transforms.sig && !transforms.n) {
                    return url;
                }

                var params = parseQueryParams(url);
                var modified = url;
                var transformed = false;

                // Handle 'sig' or obfuscated 's' signature parameter
                var rawSig = params.sig || params.s;
                if (rawSig && typeof transforms.sig === "function") {
                    try {
                        var resolvedSig = transforms.sig(rawSig);
                        if (resolvedSig && typeof resolvedSig === "string") {
                            if (params.s) {
                                modified = removeQueryParam(modified, "s");
                            }
                            modified = updateQueryParam(modified, "sig", resolvedSig);
                            transformed = true;
                        }
                    } catch (errSig) {
                        console.warn("[UserScript] Failed to transform signature:", errSig);
                    }
                }

                // Handle 'n' parameter
                var rawN = params.n;
                if (rawN && typeof transforms.n === "function") {
                    try {
                        var resolvedN = transforms.n(rawN);
                        if (resolvedN && typeof resolvedN === "string") {
                            modified = updateQueryParam(modified, "n", resolvedN);
                            transformed = true;
                        }
                    } catch (errN) {
                        console.warn("[UserScript] Failed to transform n-parameter:", errN);
                    }
                }

                return transformed ? modified : url;
            } catch (err) {
                console.warn("[UserScript] resolvePlayerURL execution error:", err);
                return url;
            }
        };
    })();
    """#

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
        window.__grabberBlobRegistry = window.__grabberBlobRegistry || {};

        function blobKind(url) {
            if (!url || typeof url !== "string" || url.indexOf("blob:") !== 0) { return null; }
            try {
                var fromGrabber = (window.__grabberBlobRegistry || {})[url];
                if (fromGrabber) { return fromGrabber; }
                var entry = (window.__lidBlobRegistry || {})[url];
                if (entry) {
                    if (entry.kind === "mediaSource") { return "MediaSource"; }
                    if (entry.kind === "blob") { return "Blob"; }
                }
            } catch (_) {}
            return "Unknown";
        }

        function absoluteURL(value) {
            if (value === null || value === undefined) { return null; }
            var text = String(value).trim();
            if (!text || text.length > 8192) { return null; }
            try { return new URL(text, document.baseURI).href; } catch (_) { return null; }
        }

        var nextEventID = 0;
        var MAX_INSPECTION_BYTES = 524288;

        function manifestKindFor(url, declaredType, prefix) {
            var mime = declaredType ? String(declaredType).toLowerCase().split(";", 1)[0].trim() : "";
            var lowerURL = url ? String(url).toLowerCase() : "";
            var urlPath = lowerURL;
            try { urlPath = new URL(lowerURL).pathname.toLowerCase(); } catch (_) {}
            var text = prefix ? String(prefix).replace(/^\uFEFF/, "").trim() : "";
            var hls = text.indexOf("#EXTM3U") === 0 ||
                mime.indexOf("mpegurl") >= 0 ||
                /(?:^|[./])m3u8(?:$|[?#&;])/.test(urlPath) ||
                lowerURL.indexOf(".m3u8") !== -1;
            var dash = /<\s*(?:[a-z_][a-z0-9_.-]*:)?mpd(?:\s|>)/i.test(text) ||
                mime === "application/dash+xml" || mime === "video/vnd.mpeg.dash.mpd" ||
                mime === "audio/dash+xml" || mime === "video/dash+xml" ||
                /(?:^|[./?=&#])mpd(?:$|[?#&;])/.test(lowerURL) ||
                lowerURL.indexOf(".mpd") !== -1 ||
                lowerURL.indexOf("format=mpd") !== -1 ||
                lowerURL.indexOf("type=mpd") !== -1;
            if (hls && dash) { return "unsupported"; }
            if (hls) { return "hls"; }
            if (dash) { return "dash"; }
            return null;
        }

        function shouldInspect(url, declaredType) {
            if (manifestKindFor(url, declaredType, null) !== null) { return true; }
            var mime = declaredType ? String(declaredType).toLowerCase().split(";", 1)[0].trim() : "";
            var lowerURL = url ? String(url).toLowerCase() : "";
            var isPotentialManifestMime = mime === "application/xml" || mime === "text/xml" ||
                mime === "text/plain" || mime === "application/octet-stream" ||
                mime.indexOf("dash") !== -1 || mime.indexOf("mpegurl") !== -1;
            var isPotentialManifestURL = lowerURL.indexOf("mpd") !== -1 ||
                lowerURL.indexOf("m3u8") !== -1 ||
                lowerURL.indexOf("manifest") !== -1 ||
                lowerURL.indexOf("playlist") !== -1 ||
                lowerURL.indexOf("/dash/") !== -1 ||
                lowerURL.indexOf("dash") !== -1;
            return isPotentialManifestMime && isPotentialManifestURL;
        }

        function headerContentLength(headers) {
            try {
                var value = headers && headers.get ? headers.get("content-length") : null;
                var parsed = value === null ? NaN : Number(value);
                return isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : null;
            } catch (_) { return null; }
        }

        function inspectResponsePrefix(response) {
            if (!response || !response.clone) {
                return Promise.resolve(null);
            }
            try {
                var cl = headerContentLength(response.headers);
                if (cl !== null && cl > MAX_INSPECTION_BYTES) {
                    return Promise.resolve(null);
                }
                var ct = "";
                try { ct = (response.headers && response.headers.get ? response.headers.get("content-type") : "") || ""; } catch (_) {}
                var ctLower = ct.toLowerCase();
                // Never clone or stream-inspect binary video or audio chunks to prevent WebKit stream stalls
                if (ctLower.indexOf("video/") === 0 || ctLower.indexOf("audio/") === 0) {
                    return Promise.resolve(null);
                }
                var clone = response.clone();
                if (clone.body && typeof clone.body.getReader === "function") {
                    var reader = clone.body.getReader();
                    var decoder = new TextDecoder();
                    var accumulated = "";
                    var bytesRead = 0;
                    function readNextChunk() {
                        return reader.read().then(function(result) {
                            if (!result || result.done) {
                                return accumulated.length > 0 ? accumulated : null;
                            }
                            var chunk = result.value;
                            if (chunk && chunk.byteLength > 0) {
                                var remaining = MAX_INSPECTION_BYTES - bytesRead;
                                if (remaining <= 0) {
                                    try { reader.cancel().catch(function() {}); } catch (_) {}
                                    return accumulated;
                                }
                                var slice = chunk.byteLength > remaining ? chunk.subarray(0, remaining) : chunk;
                                bytesRead += slice.byteLength;
                                accumulated += decoder.decode(slice, { stream: bytesRead < MAX_INSPECTION_BYTES });
                                if (bytesRead >= MAX_INSPECTION_BYTES) {
                                    try { reader.cancel().catch(function() {}); } catch (_) {}
                                    return accumulated;
                                }
                            }
                            return readNextChunk();
                        }).catch(function() {
                            try { reader.cancel().catch(function() {}); } catch (_) {}
                            return accumulated.length > 0 ? accumulated : null;
                        });
                    }
                    return readNextChunk();
                }
                return Promise.resolve(null);
            } catch (_) {}
            return Promise.resolve(null);
        }

        function emit(value, source, metadata) {
            var url = absoluteURL(value);
            if (!url) { return; }
            metadata = metadata || {};
            var eventID = metadata.eventID || (source + "-" + (++nextEventID));
            var declaredType = metadata.declaredType || null;
            var prefix = metadata.manifestPrefix || null;
            var kind = metadata.manifestKind || manifestKindFor(url, declaredType, prefix);
            var bKind = metadata.blobKind || blobKind(url);
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
                    manifestPrefix: prefix,
                    blobKind: bKind,
                    width: metadata.width || null,
                    height: metadata.height || null,
                    duration: metadata.duration || null,
                    codecs: metadata.codecs || null
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
            var w = (element.videoWidth !== undefined && element.videoWidth > 0) ? element.videoWidth : null;
            var h = (element.videoHeight !== undefined && element.videoHeight > 0) ? element.videoHeight : null;
            var d = (element.duration !== undefined && !isNaN(element.duration) && isFinite(element.duration) && element.duration > 0) ? element.duration : null;
            var meta = { tag: tag, declaredType: type, method: "GET", width: w, height: h, duration: d };
            if (element.currentSrc) { emit(element.currentSrc, source, meta); }
            if (element.src) { emit(element.src, source, meta); }
            var raw = element.getAttribute("src");
            if (raw) { emit(raw, source, meta); }
        }

        function attachMediaListeners(element) {
            if (!element || !element.addEventListener || element.__lidListenersAttached) { return; }
            element.__lidListenersAttached = true;
            function onMediaReady() {
                inspectElement(element, "mediaElement");
            }
            element.addEventListener("loadedmetadata", onMediaReady, { passive: true });
            element.addEventListener("canplay", onMediaReady, { passive: true });
        }

        function inspectTree(root) {
            if (!root || !root.querySelectorAll) { return; }
            if (root.tagName) {
                inspectElement(root, "domMutation");
                attachMediaListeners(root);
            }
            root.querySelectorAll("video, audio, source").forEach(function(element) {
                inspectElement(element, "domMutation");
                attachMediaListeners(element);
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

        try {
            window.__lidBlobRegistry = window.__lidBlobRegistry || Object.create(null);
            var blobRegistry = window.__lidBlobRegistry;
            if (window.URL && typeof window.URL.createObjectURL === "function") {
                var originalCreateObjectURL = window.URL.createObjectURL;
                window.URL.createObjectURL = function(object) {
                    var objectURL = originalCreateObjectURL.apply(this, arguments);
                    try {
                        var k = (typeof MediaSource !== "undefined" && object instanceof MediaSource) ? "MediaSource" :
                                (typeof Blob !== "undefined" && object instanceof Blob) ? "Blob" : "Unknown";
                        window.__grabberBlobRegistry = window.__grabberBlobRegistry || {};
                        window.__grabberBlobRegistry[objectURL] = k;

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
                                method: "GET",
                                blobKind: "Blob"
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
                                method: "GET",
                                blobKind: "MediaSource"
                            });
                        }
                    } catch (_) {}
                    return objectURL;
                };
            }
            if (window.URL && typeof window.URL.revokeObjectURL === "function") {
                var originalRevokeObjectURL = window.URL.revokeObjectURL;
                window.URL.revokeObjectURL = function(objectURL) {
                    try {
                        delete blobRegistry[String(objectURL)];
                        delete (window.__grabberBlobRegistry || {})[String(objectURL)];
                    } catch (_) {}
                    return originalRevokeObjectURL.apply(this, arguments);
                };
            }
        } catch (_) {}

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
                    var captured = false;
                    var onComplete = function() {
                        if (captured) { return; }
                        if (request.readyState !== 4) { return; }
                        captured = true;
                        var type = null;
                        try { type = request.getResponseHeader("content-type"); } catch (_) {}
                        var prefix = null;
                        try {
                            if ((request.responseType === "" || request.responseType === "text") && shouldInspect(reqURL, type)) {
                                prefix = String(request.responseText || "").slice(0, MAX_INSPECTION_BYTES);
                            } else if (request.responseType === "document" && request.responseXML && shouldInspect(reqURL, type)) {
                                try {
                                    prefix = new XMLSerializer().serializeToString(request.responseXML).slice(0, MAX_INSPECTION_BYTES);
                                } catch (_) {}
                            } else if (request.responseType === "arraybuffer" && request.response instanceof ArrayBuffer && shouldInspect(reqURL, type)) {
                                prefix = new TextDecoder().decode(new Uint8Array(request.response.slice(0, MAX_INSPECTION_BYTES)));
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
                    };
                    request.addEventListener("readystatechange", onComplete, false);
                    request.addEventListener("loadend", onComplete, { once: true });
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

    /// Constructs the DOM resource extraction JavaScript string executed on a loaded webpage.
    public static func domExtractionScript(includeNonVideo: Bool) -> String {
        let nonVideoClause = includeNonVideo ? """
            document.querySelectorAll('a[href]').forEach(function(a) {
                var href = a.getAttribute('href');
                if (href && !href.startsWith('#') && !href.startsWith('javascript:')) {
                    add(href, 'a', (a.innerText || a.textContent || '').trim(), a.getAttribute('type') || null);
                }
            });
            document.querySelectorAll('img[src]').forEach(function(img) {
                var src = img.getAttribute('src');
                if (src && !src.startsWith('data:')) {
                    add(src, 'img', (img.getAttribute('alt') || '').trim(), null);
                }
            });
        """ : """
            var mediaExts = /\\.(mp4|m3u8|mpd|mkv|webm|mov|flv|ts|avi|m4v|3gp|mp3|aac|flac|wav|m4a)($|\\?|#)/i;
            document.querySelectorAll('a[href]').forEach(function(a) {
                var href = a.getAttribute('href');
                if (href && mediaExts.test(href)) {
                    add(href, 'a', (a.innerText || a.textContent || '').trim(), a.getAttribute('type') || null);
                }
            });
        """

        return """
        (function() {
            var candidates = [];
            var seen = {};
            function add(u, tag, text, type, w, h, d) {
                if (!u || seen[u]) return;
                seen[u] = true;
                candidates.push({
                    rawURL: u,
                    tag: tag,
                    text: text || '',
                    declaredType: type || null,
                    width: (w && w > 0) ? w : null,
                    height: (h && h > 0) ? h : null,
                    duration: (d && !isNaN(d) && isFinite(d) && d > 0) ? d : null
                });
            }
            document.querySelectorAll('video').forEach(function(v) {
                if (v.src) {
                    var isMSE = (window.__grabberBlobRegistry && window.__grabberBlobRegistry[v.src] === 'MediaSource') ||
                                (v.src.indexOf('blob:') === 0);
                    var w = (v.videoWidth && v.videoWidth > 0) ? v.videoWidth : null;
                    var h = (v.videoHeight && v.videoHeight > 0) ? v.videoHeight : null;
                    var d = (v.duration && !isNaN(v.duration) && isFinite(v.duration) && v.duration > 0) ? v.duration : null;
                    add(v.src, 'video', v.title || v.getAttribute('aria-label') || '', isMSE ? 'application/x-mediasource' : null, w, h, d);
                }
            });
            document.querySelectorAll('audio').forEach(function(a) {
                if (a.src) {
                    var d = (a.duration && !isNaN(a.duration) && isFinite(a.duration) && a.duration > 0) ? a.duration : null;
                    add(a.src, 'audio', a.title || a.getAttribute('aria-label') || '', null, null, null, d);
                }
            });
            document.querySelectorAll('source').forEach(function(s) {
                if (s.src) add(s.src, 'source', '', s.type || null, null, null, null);
            });
            \(nonVideoClause)
            return JSON.stringify(candidates);
        })()
        """
    }
}
