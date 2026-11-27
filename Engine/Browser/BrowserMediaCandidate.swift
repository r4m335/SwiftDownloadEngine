import Foundation

/// The strategy suggested by a browser observation. Metadata-only signals are
/// represented explicitly so they cannot accidentally become HTTP downloads.
public enum BrowserMediaCandidateKind: String, Codable, Sendable, Equatable, Hashable {
    case directMedia
    case directFile
    case hlsManifest
    case dashManifest
    case completeBlob
    case mediaSource
    case protectedMedia
    case unknown
}

public enum BrowserMediaCandidateAvailability: String, Codable, Sendable, Equatable, Hashable {
    case downloadable
    case requiresPlanning
    case captureCandidate
    case metadataOnly
    case unsupported
    case uncertain
}

/// Differentiates true in-memory Blob objects from MediaSource streaming buffers.
public enum BlobKind: String, Codable, Sendable, Equatable, Hashable {
    case blob = "Blob"
    case mediaSource = "MediaSource"
    case unknown = "Unknown"
}

/// A unified, sanitized description of a browser media candidate.
///
/// `url` is present only for resources that can be addressed by the existing
/// HTTP/HTTPS transfer paths. Blob, MSE, and protection observations retain
/// their raw signal and metadata without inventing a server URL.
public struct BrowserMediaCandidate: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let url: URL?
    public let rawURL: String
    public let finalURL: URL?
    public let kind: BrowserMediaCandidateKind
    public let blobKind: BlobKind?
    public let mimeType: String?
    public let suggestedFilename: String
    public let estimatedSize: Int64?
    public let availability: BrowserMediaCandidateAvailability
    public let evidence: [String]
    public let documentID: String?
    public let requestContext: BrowserRequestContext?
    public let associatedManifestID: String?
    public let associatedManifestURL: URL?
    public let cachedManifestText: String?
    public let lastObserved: Date
    public let isLive: Bool
    public let width: Int?
    public let height: Int?
    public let duration: Double?
    public let codecs: String?
    public let audioLanguage: String?
    public let documentGeneration: UInt64?
    public let navigationGeneration: UInt64?

    public init(
        id: String,
        url: URL?,
        rawURL: String,
        finalURL: URL? = nil,
        kind: BrowserMediaCandidateKind,
        blobKind: BlobKind? = nil,
        mimeType: String? = nil,
        suggestedFilename: String,
        estimatedSize: Int64? = nil,
        availability: BrowserMediaCandidateAvailability,
        evidence: [String] = [],
        documentID: String? = nil,
        requestContext: BrowserRequestContext? = nil,
        associatedManifestID: String? = nil,
        associatedManifestURL: URL? = nil,
        cachedManifestText: String? = nil,
        lastObserved: Date = Date(),
        isLive: Bool = false,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        codecs: String? = nil,
        audioLanguage: String? = nil,
        documentGeneration: UInt64? = nil,
        navigationGeneration: UInt64? = nil
    ) {
        self.id = id
        self.url = url
        self.rawURL = rawURL
        self.finalURL = finalURL
        self.kind = kind
        self.blobKind = blobKind
        self.mimeType = mimeType
        self.suggestedFilename = suggestedFilename
        self.estimatedSize = estimatedSize
        self.availability = availability
        var uniqueEvidence: [String] = []
        for item in evidence where !uniqueEvidence.contains(item) {
            uniqueEvidence.append(item)
        }
        self.evidence = uniqueEvidence
        self.documentID = documentID
        self.requestContext = requestContext
        self.associatedManifestID = associatedManifestID
        self.associatedManifestURL = associatedManifestURL
        self.cachedManifestText = cachedManifestText
        self.lastObserved = lastObserved
        self.isLive = isLive
        self.width = width
        self.height = height
        self.duration = duration
        self.codecs = codecs
        self.audioLanguage = audioLanguage
        self.documentGeneration = documentGeneration
        self.navigationGeneration = navigationGeneration
    }

    /// Whether this media candidate represents a streaming master playlist or manifest (HLS or DASH).
    public var isStreamingManifest: Bool {
        kind == .hlsManifest || kind == .dashManifest
    }

    fileprivate static let nonMediaAssetExtensions: Set<String> = [
        "js", "mjs", "cjs", "css", "scss", "html", "htm", "xhtml",
        "php", "asp", "aspx", "jsp", "json", "xml", "map",
        "woff", "woff2", "ttf", "otf", "eot", "wasm", "ico", "cur"
    ]

    /// Converts this candidate into a `WebpageResource` preserving media specifications.
    public func toWebpageResource() -> WebpageResource? {
        guard kind != .unknown, availability != .unsupported,
              let targetURL = url ?? URL(string: rawURL) else {
            return nil
        }
        let ext = targetURL.pathExtension.lowercased()
        let lowerMime = mimeType?.lowercased()
        if ext == "ts" || ext == "m4s" { return nil }
        if let mime = lowerMime, mime.contains("mp2t") || mime.contains("iso.segment") {
            return nil
        }
        let hasExplicitMediaMime = lowerMime?.hasPrefix("video/") == true || lowerMime?.hasPrefix("audio/") == true
        if Self.nonMediaAssetExtensions.contains(ext) && !hasExplicitMediaMime && kind != .hlsManifest && kind != .dashManifest {
            return nil
        }
        if kind == .completeBlob, let size = estimatedSize, size > 0 && size < 4096 {
            return nil
        }

        let categorized = WebpageResourceExtractor.categorize(extension: ext, mimeType: mimeType)
        let lowerFilename = suggestedFilename.lowercased()
        let isBinWithoutMediaMime = (ext == "bin" || lowerFilename.hasSuffix(".bin")) && !hasExplicitMediaMime
        let resourceType: WebpageResourceType
        switch kind {
        case .hlsManifest, .dashManifest, .mediaSource, .protectedMedia:
            resourceType = isBinWithoutMediaMime ? .other : .video
        case .directMedia:
            if isBinWithoutMediaMime {
                resourceType = .other
            } else {
                switch categorized {
                case .audio, .image, .document, .archive:
                    resourceType = categorized
                default:
                    resourceType = .video
                }
            }
        case .completeBlob:
            if isBinWithoutMediaMime {
                resourceType = .other
            } else if categorized != .other {
                resourceType = categorized
            } else if let mime = lowerMime, mime.contains("audio") {
                resourceType = .audio
            } else if hasExplicitMediaMime || ["mp4", "webm", "mov", "m4v", "mkv", "avi", "flv"].contains(ext) ||
                        ["mp4", "webm", "mov", "m4v"].contains((lowerFilename as NSString).pathExtension) {
                resourceType = .video
            } else if ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(ext) ||
                        ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains((lowerFilename as NSString).pathExtension) {
                resourceType = .audio
            } else {
                resourceType = .other
            }
        case .directFile:
            if categorized != .other {
                resourceType = categorized
            } else {
                let isAudio = (lowerMime?.contains("audio") == true) ||
                    ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(ext)
                resourceType = isAudio ? .audio : .other
            }
        case .unknown:
            return nil
        }

        let isManifest = kind == .hlsManifest || kind == .dashManifest
        let defaultFilename: String
        if isManifest {
            defaultFilename = kind == .dashManifest ? "stream.mpd" : "stream.m3u8"
        } else {
            defaultFilename = (resourceType == .audio) ? "audio.m4a" : "video.mp4"
        }
        let finalFilename = suggestedFilename.isEmpty ? defaultFilename : suggestedFilename
        let title = suggestedFilename.isEmpty
            ? (isManifest ? (kind == .dashManifest ? "DASH Manifest" : "HLS Master Playlist") : "Media Stream")
            : suggestedFilename
        let effectiveMime = mimeType ?? (isManifest ? (kind == .dashManifest ? "application/dash+xml" : "application/vnd.apple.mpegurl") : "video/mp4")

        let resText: String? = {
            if let w = width, let h = height, w > 0, h > 0 {
                return "\(w)×\(h)"
            }
            return nil
        }()

        return WebpageResource(
            id: id,
            url: targetURL,
            title: title,
            suggestedFilename: finalFilename,
            resourceType: resourceType,
            mimeType: effectiveMime,
            estimatedSize: estimatedSize,
            isSupported: availability == .downloadable || availability == .requiresPlanning || availability == .captureCandidate,
            requestContext: requestContext,
            manifestText: cachedManifestText,
            isDRMProtected: kind == .protectedMedia,
            isLive: isLive || isLiveStream,
            resolutionText: resText,
            duration: duration,
            codecs: codecs,
            audioLanguage: audioLanguage,
            documentGeneration: documentGeneration,
            navigationGeneration: navigationGeneration,
            rawURL: rawURL,
            finalURL: finalURL,
            candidateKind: kind,
            blobKind: blobKind,
            availability: availability,
            evidence: evidence,
            documentID: documentID,
            associatedManifestID: associatedManifestID,
            associatedManifestURL: associatedManifestURL,
            width: width,
            height: height
        )
    }

    /// Evaluates whether this candidate represents a live broadcast, event stream, or dynamic live manifest.
    public var isLiveStream: Bool {
        if isLive { return true }
        if evidence.contains(where: { $0.localizedCaseInsensitiveContains("live") }) { return true }
        if let manifest = cachedManifestText {
            if manifest.contains("#EXT-X-TARGETDURATION") && !manifest.contains("#EXT-X-ENDLIST") {
                return true
            }
        }
        if let targetURL = url ?? finalURL {
            let path = targetURL.path.lowercased()
            if path.contains("/live/") || path.contains("_live") || path.contains("-live") || path.hasPrefix("live") {
                return true
            }
        }
        let fn = suggestedFilename.lowercased()
        if fn.contains("[live]") || fn.contains("_live") || fn.contains("-live") || fn.hasPrefix("live") {
            return true
        }
        return false
    }

    public var isActionable: Bool {
        availability == .downloadable || availability == .requiresPlanning || availability == .captureCandidate
    }

    /// Evaluates whether this candidate's URL has expired based on query parameters.
    public var isExpired: Bool {
        guard let target = url ?? finalURL else { return false }
        return DirectMediaTransferPlanner.isURLExpired(target)
    }

    /// Evaluates whether this candidate's URL will expire within the given threshold (default 300 seconds).
    public func isExpiringSoon(thresholdSeconds: TimeInterval = 300, now: Date = Date()) -> Bool {
        guard let target = url ?? finalURL else { return false }
        return DirectMediaTransferPlanner.isURLExpiringSoon(target, thresholdSeconds: thresholdSeconds, now: now)
    }

    /// Extracted expiration date from signed token parameters if present.
    public var expirationDate: Date? {
        guard let target = url ?? finalURL else { return nil }
        return DirectMediaTransferPlanner.urlExpirationDate(target)
    }

    /// Direct access to the equivalent `WebpageResource` representation.
    public var webpageResource: WebpageResource? {
        toWebpageResource()
    }

    /// Creates a `BrowserMediaCandidate` from a `WebpageResource`.
    public init(resource: WebpageResource, now: Date = Date()) {
        self = BrowserMediaCandidateClassifier.classify(resource: resource, now: now)
    }
}

/// Pure classification and identity rules shared by DOM and dynamic browser
/// discovery. It never performs network requests or reads browser credentials.
public enum BrowserMediaCandidateClassifier {
    public static func classify(
        observation: BrowserMediaDiscoveryObservation,
        now: Date = Date()
    ) -> BrowserMediaCandidate? {
        let mime = normalizedMIME(observation.declaredType)
        let identity = stableIdentity(rawURL: observation.rawURL, url: observation.url)
        let finalURL = observation.responseURL

        if observation.source == .protection || observation.isPotentiallyProtected {
            return BrowserMediaCandidate(
                id: identity,
                url: nil,
                rawURL: observation.rawURL,
                finalURL: finalURL,
                kind: .protectedMedia,
                mimeType: mime,
                suggestedFilename: "protected_media",
                estimatedSize: observation.contentLength,
                availability: .unsupported,
                evidence: ["possible encrypted-media activity was observed"],
                documentID: observation.documentID,
                lastObserved: now,
                documentGeneration: observation.documentGeneration,
                navigationGeneration: observation.navigationGeneration
            )
        }

        if observation.source == .mediaSource {
            let support = BrowserMSECaptureSupportClassifier.evaluate(
                mimeType: mime,
                isPotentiallyProtected: false
            )
            let availability: BrowserMediaCandidateAvailability
            let evidence: [String]
            let hasMediaSourceObjectURL = observation.rawURL.lowercased().hasPrefix("blob:")
            switch support.status {
            case .capturable:
                if hasMediaSourceObjectURL {
                    availability = .captureCandidate
                    evidence = [
                        support.reason,
                        "MediaSource metadata only until an explicit capture starts"
                    ]
                } else {
                    availability = .metadataOnly
                    evidence = [
                        support.reason,
                        "Waiting for a MediaSource object URL before capture can start"
                    ]
                }
            case .protectedMedia:
                availability = .unsupported
                evidence = [support.reason]
            case .unsupported:
                if mime == nil {
                    availability = .metadataOnly
                    evidence = ["MediaSource activity was observed; wait for SourceBuffer MIME types"]
                } else {
                    availability = .unsupported
                    evidence = [support.reason]
                }
            }
            return BrowserMediaCandidate(
                id: identity,
                url: nil,
                rawURL: observation.rawURL,
                finalURL: finalURL,
                kind: .mediaSource,
                blobKind: .mediaSource,
                mimeType: mime,
                suggestedFilename: "media_source_capture",
                estimatedSize: observation.appendedByteCount ?? observation.contentLength,
                availability: availability,
                evidence: evidence,
                documentID: observation.documentID,
                lastObserved: now,
                documentGeneration: observation.documentGeneration,
                navigationGeneration: observation.navigationGeneration
            )
        }

        if observation.isBlobSignal {
            if observation.blobKind == .mediaSource {
                return BrowserMediaCandidate(
                    id: identity,
                    url: nil,
                    rawURL: observation.rawURL,
                    finalURL: nil,
                    kind: .mediaSource,
                    blobKind: .mediaSource,
                    mimeType: mime,
                    suggestedFilename: "streaming_media.mp4",
                    estimatedSize: nil,
                    availability: .metadataOnly,
                    evidence: ["MediaSource streaming buffer observed (not a downloadable standalone Blob)"],
                    documentID: observation.documentID,
                    associatedManifestURL: nil,
                    lastObserved: now,
                    documentGeneration: observation.documentGeneration,
                    navigationGeneration: observation.navigationGeneration
                )
            }

            let isMediaTag = observation.tag?.lowercased() == "video" ||
                observation.tag?.lowercased() == "audio" ||
                observation.tag?.lowercased() == "media" ||
                observation.tag?.lowercased() == "source"
            let supportedBlob = isSupportedBlobMIME(mime) || (mime == nil && isMediaTag) || observation.source == .blob
            let hasSize = observation.contentLength != nil
            let availability: BrowserMediaCandidateAvailability
            if !supportedBlob {
                availability = .unsupported
            } else {
                availability = .captureCandidate
            }
            let filename: String = {
                if let mime {
                    return blobFilename(mime: mime)
                }
                if observation.tag?.lowercased() == "video" {
                    return "browser_blob.mp4"
                }
                if observation.tag?.lowercased() == "audio" {
                    return "browser_blob.m4a"
                }
                return "browser_blob.bin"
            }()
            return BrowserMediaCandidate(
                id: identity,
                url: nil,
                rawURL: observation.rawURL,
                finalURL: nil,
                kind: .completeBlob,
                blobKind: observation.blobKind ?? .blob,
                mimeType: mime,
                suggestedFilename: filename,
                estimatedSize: observation.contentLength,
                availability: availability,
                evidence: hasSize
                    ? ["Blob metadata reports a supported type and size"]
                    : ["Blob URL was observed; size will be determined at in-browser export"],
                documentID: observation.documentID,
                lastObserved: now,
                documentGeneration: observation.documentGeneration,
                navigationGeneration: observation.navigationGeneration
            )
        }

        guard let url = observation.url,
              BrowserURLResolver.isValidDownloadURL(url) else {
            return nil
        }

        let classification = StreamingManifestClassifier.classify(
            url: finalURL ?? url,
            mimeType: mime,
            content: observation.manifestPrefix?.data(using: .utf8)
        )
        if classification.kind == .hls || observation.manifestKind == .hls {
            return manifestCandidate(
                identity: identity,
                url: url,
                finalURL: finalURL,
                rawURL: observation.rawURL,
                mimeType: mime,
                kind: .hlsManifest,
                reason: classification.reason,
                documentID: observation.documentID,
                cachedManifestText: observation.manifestPrefix,
                lastObserved: now,
                documentGeneration: observation.documentGeneration,
                navigationGeneration: observation.navigationGeneration
            )
        }
        if classification.kind == .dash || observation.manifestKind == .dash {
            return manifestCandidate(
                identity: identity,
                url: url,
                finalURL: finalURL,
                rawURL: observation.rawURL,
                mimeType: mime,
                kind: .dashManifest,
                reason: classification.reason,
                documentID: observation.documentID,
                cachedManifestText: observation.manifestPrefix,
                lastObserved: now,
                documentGeneration: observation.documentGeneration,
                navigationGeneration: observation.navigationGeneration
            )
        }

        let ext = BrowserDownloadClassifier.extractURLExtension(from: finalURL ?? url)?.lowercased() ?? ""
        let hasExplicitMediaMime = mime?.hasPrefix("video/") == true || mime?.hasPrefix("audio/") == true
        if BrowserMediaCandidate.nonMediaAssetExtensions.contains(ext) && !hasExplicitMediaMime {
            return nil
        }

        let type = WebpageResourceExtractor.categorize(
            extension: ext.isEmpty ? nil : ext,
            mimeType: mime
        )
        let isMediaTag = observation.tag?.lowercased() == "video" ||
            observation.tag?.lowercased() == "audio" ||
            observation.tag?.lowercased() == "source"
        let isBinWithoutMediaMime = ext == "bin" && !hasExplicitMediaMime
        let isMedia = !isBinWithoutMediaMime && ((type == .video || type == .audio) ||
            (isMediaTag && type != .image && type != .document && type != .archive))
        let isKnownFile = isMedia || type == .image || type == .document || type == .archive
        guard isKnownFile else { return nil }

        let kind: BrowserMediaCandidateKind = isMedia ? .directMedia : .directFile
        let evidence: [String] = {
            var values: [String] = []
            if let mime, mime.hasPrefix("video/") || mime.hasPrefix("audio/") {
                values.append("supported media MIME type")
            }
            if BrowserDownloadClassifier.extractURLExtension(from: finalURL ?? url) != nil {
                values.append("recognized resource extension")
            }
            if isMediaTag { values.append("media element observation") }
            return values.isEmpty ? ["browser resource observation"] : values
        }()

        let isLive = (observation.duration == nil || observation.duration?.isInfinite == true) &&
            ((observation.manifestPrefix?.contains("#EXT-X-TARGETDURATION") == true && observation.manifestPrefix?.contains("#EXT-X-ENDLIST") == false) ||
             url.absoluteString.localizedCaseInsensitiveContains("/live/") ||
             url.absoluteString.localizedCaseInsensitiveContains("_live"))

        return BrowserMediaCandidate(
            id: identity,
            url: url,
            rawURL: observation.rawURL,
            finalURL: finalURL,
            kind: kind,
            mimeType: mime,
            suggestedFilename: BrowserDownloadClassifier.suggestedFilenameFromURL(finalURL ?? url, mimeType: mime),
            estimatedSize: observation.contentLength,
            availability: .downloadable,
            evidence: evidence,
            documentID: observation.documentID,
            lastObserved: now,
            isLive: isLive,
            width: observation.width,
            height: observation.height,
            duration: observation.duration,
            codecs: observation.codecs,
            documentGeneration: observation.documentGeneration,
            navigationGeneration: observation.navigationGeneration
        )
    }

    public static func classify(
        resource: WebpageResource,
        now: Date = Date()
    ) -> BrowserMediaCandidate {
        let identity = stableIdentity(rawURL: resource.url.absoluteString, url: resource.url)
        let mime = normalizedMIME(resource.mimeType)
        let manifest = StreamingManifestClassifier.classify(url: resource.url, mimeType: mime)
        let kind: BrowserMediaCandidateKind
        let availability: BrowserMediaCandidateAvailability
        var evidence: [String] = []

        let blobKind: BlobKind?
        if resource.url.scheme?.lowercased() == "blob" {
            let isGenericOrMissingMIME = mime == nil || mime?.isEmpty == true || mime == "application/octet-stream" || mime == "application/x-mediasource"
            let isMediaSource = mime == "application/x-mediasource" || resource.isMediaSourceBlob || (isGenericOrMissingMIME && (resource.suggestedFilename.hasSuffix(".bin") || resource.suggestedFilename.hasPrefix("blob_stream") || resource.resourceType == .other))
            if isMediaSource {
                kind = .mediaSource
                let isGenericOrMediaSourceMIME = mime == nil || mime?.isEmpty == true || mime == "application/x-mediasource" || mime == "application/octet-stream"
                if isGenericOrMediaSourceMIME {
                    availability = .metadataOnly
                    evidence = ["MediaSource streaming buffer observed (empty or generic MIME type; not a downloadable standalone Blob)"]
                } else {
                    let support = BrowserMSECaptureSupportClassifier.evaluate(
                        mimeType: mime,
                        isPotentiallyProtected: false
                    )
                    switch support.status {
                    case .capturable:
                        availability = .captureCandidate
                        evidence = [support.reason, "Clear MediaSource stream eligible for capture"]
                    case .protectedMedia:
                        availability = .unsupported
                        evidence = [support.reason]
                    case .unsupported:
                        availability = .unsupported
                        evidence = [support.reason]
                    }
                }
                blobKind = .mediaSource
            } else {
                kind = .completeBlob
                availability = .captureCandidate
                evidence = ["Blob data can be exported through the active browser session"]
                blobKind = .blob
            }
        } else if manifest.kind == .hls {
            kind = .hlsManifest
            availability = resource.isSupported ? .requiresPlanning : .unsupported
            evidence = resource.isSupported ? ["HLS manifest metadata was recognized"] : [resource.unsupportedReason ?? "HLS stream variant is unsupported for full download"]
            blobKind = nil
        } else if manifest.kind == .dash {
            kind = .dashManifest
            availability = resource.isSupported ? .requiresPlanning : .unsupported
            evidence = resource.isSupported ? ["DASH manifest metadata was recognized"] : [resource.unsupportedReason ?? "DASH stream variant is unsupported for full download"]
            blobKind = nil
        } else if resource.resourceType == .video || resource.resourceType == .audio {
            kind = .directMedia
            availability = resource.isSupported ? .downloadable : .unsupported
            evidence = ["direct media resource classification"]
            blobKind = nil
        } else if resource.isSupported {
            kind = .directFile
            availability = .downloadable
            evidence = ["supported downloadable resource classification"]
            blobKind = nil
        } else {
            kind = .unknown
            availability = .unsupported
            evidence = [resource.unsupportedReason ?? "resource is not currently supported"]
            blobKind = nil
        }

        let w = resource.hlsVariantPreferences?.maximumWidth ?? resource.resolutionText.flatMap { text -> Int? in
            let parts = text.split(separator: "×")
            if parts.count == 2, let width = Int(parts[0].trimmingCharacters(in: .whitespaces)) { return width }
            return nil
        }
        let h = resource.hlsVariantPreferences?.maximumHeight ?? resource.resolutionText.flatMap { text -> Int? in
            let parts = text.split(separator: "×")
            if parts.count == 2, let height = Int(parts[1].trimmingCharacters(in: .whitespaces)) { return height }
            return nil
        }

        let isLive = resource.isLive || (resource.manifestText.flatMap {
            $0.contains("#EXT-X-TARGETDURATION") && !$0.contains("#EXT-X-ENDLIST")
        } ?? false) || resource.title.hasPrefix("[LIVE]")

        return BrowserMediaCandidate(
            id: identity,
            url: resource.url,
            rawURL: resource.url.absoluteString,
            kind: kind,
            blobKind: blobKind,
            mimeType: mime,
            suggestedFilename: resource.suggestedFilename,
            estimatedSize: resource.estimatedSize,
            availability: availability,
            evidence: evidence,
            requestContext: safeRequestContext(resource.requestContext, for: resource.url),
            cachedManifestText: resource.manifestText,
            lastObserved: now,
            isLive: isLive,
            width: w,
            height: h,
            duration: resource.duration,
            codecs: resource.codecs,
            audioLanguage: resource.audioLanguage,
            documentGeneration: resource.documentGeneration,
            navigationGeneration: resource.navigationGeneration
        )
    }

    public static func stableIdentity(rawURL: String, url: URL?) -> String {
        if rawURL.lowercased().hasPrefix("blob:") {
            return "blob:\(rawURL)"
        }
        guard let url else { return "raw:\(rawURL)" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return "url:\(components?.url?.absoluteString ?? url.absoluteString)"
    }

    /// Computes a canonical media identity that normalizes away ephemeral, session-specific,
    /// or cache-busting query parameters while preserving structural media identity.
    public static func canonicalMediaIdentity(rawURL: String, url: URL?) -> String {
        if rawURL.lowercased().hasPrefix("blob:") {
            return "blob:\(rawURL)"
        }
        guard let url = url ?? URL(string: rawURL) else { return "raw:\(rawURL)" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "url:\(url.absoluteString)"
        }
        components.fragment = nil
        let volatileParams: Set<String> = [
            "_nocache", "nocache", "cb", "rnd", "ts", "timestamp", "t", "_",
            "sig", "signature", "token", "auth_token", "jwt", "session_id", "sessionid",
            "expires", "expire", "expiry", "nonce", "random", "cachebuster", "v"
        ]
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let filteredItems = queryItems.filter { item in
                let lower = item.name.lowercased()
                return !volatileParams.contains(lower) && !lower.hasPrefix("utm_")
            }
            components.queryItems = filteredItems.isEmpty ? nil : filteredItems.sorted(by: { $0.name < $1.name })
        }
        if components.path.count > 1 && components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        let scheme = components.scheme?.lowercased() ?? "http"
        let host = components.host?.lowercased() ?? ""
        let path = components.path
        let query = components.query.map { "?\($0)" } ?? ""
        return "canonical:\(scheme)://\(host)\(path)\(query)"
    }

    private static func manifestCandidate(
        identity: String,
        url: URL,
        finalURL: URL?,
        rawURL: String,
        mimeType: String?,
        kind: BrowserMediaCandidateKind,
        reason: String,
        documentID: String?,
        cachedManifestText: String? = nil,
        lastObserved: Date,
        documentGeneration: UInt64? = nil,
        navigationGeneration: UInt64? = nil
    ) -> BrowserMediaCandidate {
        let isLive = (cachedManifestText?.contains("#EXT-X-TARGETDURATION") == true && cachedManifestText?.contains("#EXT-X-ENDLIST") == false) ||
            url.absoluteString.localizedCaseInsensitiveContains("/live/") ||
            url.absoluteString.localizedCaseInsensitiveContains("_live") ||
            (finalURL?.absoluteString.localizedCaseInsensitiveContains("/live/") == true)
        return BrowserMediaCandidate(
            id: identity,
            url: url,
            rawURL: rawURL,
            finalURL: finalURL,
            kind: kind,
            mimeType: mimeType,
            suggestedFilename: BrowserDownloadClassifier.suggestedFilenameFromURL(finalURL ?? url, mimeType: mimeType),
            availability: .requiresPlanning,
            evidence: ["streaming manifest recognized", reason] + (isLive ? ["live stream detected"] : []),
            documentID: documentID,
            cachedManifestText: cachedManifestText,
            lastObserved: lastObserved,
            isLive: isLive,
            documentGeneration: documentGeneration,
            navigationGeneration: navigationGeneration,
            rawURL: rawURL,
            finalURL: finalURL,
            candidateKind: kind,
            blobKind: blobKind,
            availability: availability,
            evidence: evidence,
            documentID: documentID,
            associatedManifestID: associatedManifestID,
            associatedManifestURL: associatedManifestURL,
            width: width,
            height: height
        )
    }

    private static func normalizedMIME(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return result?.isEmpty == false ? result : nil
    }

    private static func isSupportedBlobMIME(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.hasPrefix("image/")
    }

    private static func blobFilename(mime: String?) -> String {
        let extensionName: String
        switch mime {
        case "video/mp4": extensionName = "mp4"
        case "video/webm": extensionName = "webm"
        case "audio/mpeg": extensionName = "mp3"
        case "audio/mp4": extensionName = "m4a"
        case "image/png": extensionName = "png"
        case "image/jpeg": extensionName = "jpg"
        default: extensionName = "bin"
        }
        return "browser_blob.\(extensionName)"
    }

    private static func safeRequestContext(
        _ context: BrowserRequestContext?,
        for targetURL: URL
    ) -> BrowserRequestContext? {
        guard let context else { return nil }
        if originKey(context.url) == originKey(targetURL) {
            return context
        }
        if BrowserHeaderFilter.isSameSiteOrSubdomain(context.url, targetURL) {
            return context
        }
        if context.cookies.contains(where: { $0.matches(url: targetURL) }) {
            return context
        }
        return nil
    }

    private static func originKey(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port.map(String.init) ?? ""
        return "\(scheme)://\(host):\(port)"
    }
}

/// Ordered, deterministic candidate catalog used to merge DOM and dynamic
/// observations without creating a second download coordinator.
public struct BrowserMediaCandidateCatalog: Sendable, Equatable {
    private var orderedIDs: [String] = []
    private var values: [String: BrowserMediaCandidate] = [:]
    private var canonicalAliases: [String: String] = [:]

    public var maxTotalCandidates: Int = 150
    public var maxCandidatesPerDomain: Int = 25
    public var evictedCandidatesCount: Int = 0
    public var deduplicatedCandidatesCount: Int = 0

    public init(maxTotalCandidates: Int = 150, maxCandidatesPerDomain: Int = 25) {
        self.maxTotalCandidates = maxTotalCandidates
        self.maxCandidatesPerDomain = maxCandidatesPerDomain
    }

    public var candidates: [BrowserMediaCandidate] {
        orderedIDs.compactMap { values[$0] }
    }

    public func candidate(forID id: String) -> BrowserMediaCandidate? {
        values[id] ?? canonicalAliases[id].flatMap { values[$0] }
    }

    public func candidateCanonicalKey(_ candidate: BrowserMediaCandidate) -> String {
        BrowserMediaCandidateClassifier.canonicalMediaIdentity(
            rawURL: candidate.rawURL,
            url: candidate.url ?? candidate.finalURL
        )
    }

    private func findExistingCandidateID(for candidate: BrowserMediaCandidate) -> String? {
        if values[candidate.id] != nil {
            return candidate.id
        }
        if let canonicalID = canonicalAliases[candidate.id], values[canonicalID] != nil {
            return canonicalID
        }
        let canonicalKey = candidateCanonicalKey(candidate)
        if let canonicalID = canonicalAliases[canonicalKey], values[canonicalID] != nil {
            return canonicalID
        }
        if let match = values.values.first(where: { candidateCanonicalKey($0) == canonicalKey }) {
            return match.id
        }
        return nil
    }

    private func candidateRetentionScore(_ candidate: BrowserMediaCandidate) -> Int {
        if candidate.isExpired { return -10000 }
        var score = 0
        if candidate.isStreamingManifest { score += 10000 }
        if candidate.isLive || candidate.isLiveStream { score += 5000 }
        if candidate.blobKind == .mediaSource || candidate.kind == .mediaSource { score += 3000 }
        if candidate.blobKind == .blob || candidate.kind == .completeBlob { score += 2000 }
        if candidate.isActionable { score += 1000 }
        if let w = candidate.width, let h = candidate.height, w > 0, h > 0 { score += 500 }
        if (candidate.duration ?? 0) > 0 { score += 300 }
        if candidate.cachedManifestText != nil { score += 200 }
        let ageMinutes = max(0, -candidate.lastObserved.timeIntervalSinceNow / 60.0)
        score -= Int(min(500, ageMinutes))
        return score
    }

    public mutating func enforceRetentionCaps() {
        guard values.count > maxTotalCandidates || hasDomainExceedingCap() else { return }

        let candidatesList = candidates
        var domainCounts: [String: Int] = [:]
        for candidate in candidatesList {
            let domain = candidate.url?.host?.lowercased() ?? "unknown"
            domainCounts[domain, default: 0] += 1
        }

        var toEvictIDs = Set<String>()

        // 1. Evict expired first if over total or domain cap
        for candidate in candidatesList where candidate.isExpired && !candidate.isStreamingManifest && !candidate.isLiveStream {
            toEvictIDs.insert(candidate.id)
        }

        // 2. Enforce per-domain cap
        for (domain, count) in domainCounts where count > maxCandidatesPerDomain && domain != "unknown" {
            let domainCandidates = candidatesList
                .filter { ($0.url?.host?.lowercased() ?? "unknown") == domain && !toEvictIDs.contains($0.id) }
                .sorted { candidateRetentionScore($0) < candidateRetentionScore($1) }

            let excess = count - maxCandidatesPerDomain
            for c in domainCandidates.prefix(excess) {
                if !BrowserResourceDiscoveryCoordinator.isPreservedCandidateOnRescan(c) {
                    toEvictIDs.insert(c.id)
                }
            }
        }

        // 3. Enforce global total cap
        let remainingCandidates = candidatesList.filter { !toEvictIDs.contains($0.id) }
        if remainingCandidates.count > maxTotalCandidates {
            let excess = remainingCandidates.count - maxTotalCandidates
            let sortedRemaining = remainingCandidates.sorted { candidateRetentionScore($0) < candidateRetentionScore($1) }
            for c in sortedRemaining.prefix(excess) {
                if !BrowserResourceDiscoveryCoordinator.isPreservedCandidateOnRescan(c) {
                    toEvictIDs.insert(c.id)
                }
            }
        }

        for id in toEvictIDs {
            values.removeValue(forKey: id)
            orderedIDs.removeAll(where: { $0 == id })
            evictedCandidatesCount += 1
        }
    }

    private func hasDomainExceedingCap() -> Bool {
        var domainCounts: [String: Int] = [:]
        for candidate in candidates {
            guard let host = candidate.url?.host?.lowercased() else { continue }
            domainCounts[host, default: 0] += 1
            if domainCounts[host]! > maxCandidatesPerDomain {
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func ingest(
        observation: BrowserMediaDiscoveryObservation,
        now: Date = Date()
    ) -> BrowserMediaCandidate? {
        guard let candidate = BrowserMediaCandidateClassifier.classify(observation: observation, now: now) else {
            return nil
        }
        return merge(candidate)
    }

    @discardableResult
    public mutating func ingest(
        resource: WebpageResource,
        now: Date = Date()
    ) -> BrowserMediaCandidate {
        merge(BrowserMediaCandidateClassifier.classify(resource: resource, now: now))
    }

    @discardableResult
    public mutating func ingest(
        candidate: BrowserMediaCandidate
    ) -> BrowserMediaCandidate {
        merge(candidate)
    }

    public mutating func associateManifestSegments(
        manifestID: String,
        segmentURLs: [URL]
    ) {
        let segmentKeys = Set(segmentURLs.map { identityURL($0) })
        for id in orderedIDs {
            guard var candidate = values[id],
                  let candidateURL = candidate.url,
                  segmentKeys.contains(identityURL(candidateURL)) else { continue }
            candidate = BrowserMediaCandidate(
                id: candidate.id,
                url: candidate.url,
                rawURL: candidate.rawURL,
                finalURL: candidate.finalURL,
                kind: candidate.kind,
                blobKind: candidate.blobKind,
                mimeType: candidate.mimeType,
                suggestedFilename: candidate.suggestedFilename,
                estimatedSize: candidate.estimatedSize,
                availability: candidate.availability,
                evidence: candidate.evidence + ["associated with a recognized manifest"],
                documentID: candidate.documentID,
                requestContext: candidate.requestContext,
                associatedManifestID: manifestID,
                associatedManifestURL: candidate.associatedManifestURL,
                cachedManifestText: candidate.cachedManifestText,
                lastObserved: candidate.lastObserved,
                isLive: candidate.isLive,
                width: candidate.width,
                height: candidate.height,
                duration: candidate.duration,
                codecs: candidate.codecs,
                audioLanguage: candidate.audioLanguage,
                documentGeneration: candidate.documentGeneration,
                navigationGeneration: candidate.navigationGeneration
            )
            values[id] = candidate
        }
    }

    public mutating func reset() {
        orderedIDs.removeAll(keepingCapacity: true)
        values.removeAll(keepingCapacity: true)
        canonicalAliases.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func merge(_ candidate: BrowserMediaCandidate) -> BrowserMediaCandidate {
        let canonicalKey = candidateCanonicalKey(candidate)
        let matchedID = findExistingCandidateID(for: candidate)

        guard let matchedID, let existing = values[matchedID] else {
            var newCandidate = candidate
            if (newCandidate.kind == .mediaSource || newCandidate.blobKind == .mediaSource), newCandidate.associatedManifestURL == nil {
                if let manifestURL = values.values.first(where: { $0.kind == .hlsManifest || $0.kind == .dashManifest })?.url {
                    let manifestCachedText = newCandidate.cachedManifestText ?? values.values.first(where: { $0.url == manifestURL })?.cachedManifestText
                    newCandidate = BrowserMediaCandidate(
                        id: newCandidate.id,
                        url: newCandidate.url,
                        rawURL: newCandidate.rawURL,
                        finalURL: newCandidate.finalURL,
                        kind: newCandidate.kind,
                        blobKind: newCandidate.blobKind,
                        mimeType: newCandidate.mimeType,
                        suggestedFilename: newCandidate.suggestedFilename,
                        estimatedSize: newCandidate.estimatedSize,
                        availability: newCandidate.availability,
                        evidence: newCandidate.evidence,
                        documentID: newCandidate.documentID,
                        requestContext: newCandidate.requestContext,
                        associatedManifestID: newCandidate.associatedManifestID,
                        associatedManifestURL: manifestURL,
                        cachedManifestText: manifestCachedText,
                        lastObserved: newCandidate.lastObserved,
                        isLive: newCandidate.isLive,
                        width: newCandidate.width,
                        height: newCandidate.height,
                        duration: newCandidate.duration,
                        codecs: newCandidate.codecs,
                        audioLanguage: newCandidate.audioLanguage,
                        documentGeneration: newCandidate.documentGeneration,
                        navigationGeneration: newCandidate.navigationGeneration
                    )
                }
            }

            orderedIDs.append(newCandidate.id)
            values[newCandidate.id] = newCandidate
            canonicalAliases[newCandidate.id] = newCandidate.id
            canonicalAliases[canonicalKey] = newCandidate.id
            if let finalURL = newCandidate.finalURL {
                let finalCanonical = BrowserMediaCandidateClassifier.canonicalMediaIdentity(rawURL: finalURL.absoluteString, url: finalURL)
                canonicalAliases[finalCanonical] = newCandidate.id
            }

            if (newCandidate.kind == .hlsManifest || newCandidate.kind == .dashManifest), let manifestURL = newCandidate.url {
                for (id, val) in values where (val.kind == .mediaSource || val.blobKind == .mediaSource) && val.associatedManifestURL == nil {
                    values[id] = BrowserMediaCandidate(
                        id: val.id,
                        url: val.url,
                        rawURL: val.rawURL,
                        finalURL: val.finalURL,
                        kind: val.kind,
                        blobKind: val.blobKind,
                        mimeType: val.mimeType,
                        suggestedFilename: val.suggestedFilename,
                        estimatedSize: val.estimatedSize,
                        availability: val.availability,
                        evidence: val.evidence,
                        documentID: val.documentID,
                        requestContext: val.requestContext,
                        associatedManifestID: val.associatedManifestID,
                        associatedManifestURL: manifestURL,
                        cachedManifestText: val.cachedManifestText ?? newCandidate.cachedManifestText,
                        lastObserved: val.lastObserved,
                        isLive: val.isLive,
                        width: val.width,
                        height: val.height,
                        duration: val.duration,
                        codecs: val.codecs,
                        audioLanguage: val.audioLanguage,
                        documentGeneration: val.documentGeneration,
                        navigationGeneration: val.navigationGeneration
                    )
                }
            }
            enforceRetentionCaps()
            return newCandidate
        }

        if candidate.id != existing.id || canonicalKey != candidateCanonicalKey(existing) {
            deduplicatedCandidatesCount += 1
            canonicalAliases[candidate.id] = existing.id
            canonicalAliases[canonicalKey] = existing.id
        }

        // Deterministic evidence merge: unique and sorted
        var uniqueEvidence: [String] = []
        for item in (existing.evidence + candidate.evidence) where !uniqueEvidence.contains(item) {
            uniqueEvidence.append(item)
        }
        uniqueEvidence.sort()

        let isCandidateNetwork = candidate.evidence.contains(where: {
            $0.contains("network") || $0.contains("fetch") || $0.contains("xhr") || $0.contains("manifest")
        })

        // Precedence: Network authority for URL, MIME type, and Content-Length
        let mergedURL: URL? = {
            if isCandidateNetwork && candidate.url != nil { return candidate.url }
            return existing.url ?? candidate.url
        }()

        let mergedMIME: String? = {
            if isCandidateNetwork && candidate.mimeType != nil { return candidate.mimeType }
            return existing.mimeType ?? candidate.mimeType
        }()

        let mergedSize: Int64? = {
            if isCandidateNetwork && candidate.estimatedSize != nil { return candidate.estimatedSize }
            return existing.estimatedSize ?? candidate.estimatedSize
        }()

        // Upgrade dimensions: prefer larger/known values
        let mergedWidth: Int? = {
            let ew = existing.width ?? 0
            let cw = candidate.width ?? 0
            if cw > ew { return candidate.width }
            return ew > 0 ? existing.width : candidate.width
        }()

        let mergedHeight: Int? = {
            let eh = existing.height ?? 0
            let ch = candidate.height ?? 0
            if ch > eh { return candidate.height }
            return eh > 0 ? existing.height : candidate.height
        }()

        // Upgrade duration: prefer known non-zero
        let mergedDuration: Double? = {
            if let cd = candidate.duration, cd > 0 { return cd }
            return existing.duration
        }()

        // Upgrade filename: if existing filename is generic and candidate offers a descriptive name
        let mergedFilename: String = {
            let genericNames = ["browser_blob.bin", "videoplayback", "video.mp4", "stream.m3u8", "media_source_capture"]
            if genericNames.contains(existing.suggestedFilename) && !candidate.suggestedFilename.isEmpty && !genericNames.contains(candidate.suggestedFilename) {
                return candidate.suggestedFilename
            }
            return existing.suggestedFilename
        }()

        let isMediaSource = candidate.blobKind == .mediaSource || existing.blobKind == .mediaSource ||
            candidate.kind == .mediaSource || existing.kind == .mediaSource
        let mergedKind: BrowserMediaCandidateKind
        if isMediaSource {
            mergedKind = .mediaSource
        } else if existing.kind == .unknown {
            mergedKind = candidate.kind
        } else {
            mergedKind = existing.kind
        }

        var associatedManifestURL = candidate.associatedManifestURL ?? existing.associatedManifestURL
        if associatedManifestURL == nil && isMediaSource {
            associatedManifestURL = values.values.first(where: { $0.kind == .hlsManifest || $0.kind == .dashManifest })?.url
        }

        let mergedAvailability: BrowserMediaCandidateAvailability = {
            if isMediaSource {
                let effectiveMIME = existing.mimeType ?? candidate.mimeType
                let support = BrowserMSECaptureSupportClassifier.evaluate(
                    mimeType: effectiveMIME,
                    isPotentiallyProtected: false
                )
                switch support.status {
                case .capturable:
                    return .captureCandidate
                case .protectedMedia:
                    return .unsupported
                case .unsupported:
                    return effectiveMIME == nil ? .metadataOnly : .unsupported
                }
            }
            return preferredAvailability(existing.availability, candidate.availability)
        }()

        let mergedIsLive = candidate.isLive || existing.isLive || candidate.isLiveStream || existing.isLiveStream
        let mergedDocGen = max(existing.documentGeneration ?? 0, candidate.documentGeneration ?? 0)
        let mergedNavGen = max(existing.navigationGeneration ?? 0, candidate.navigationGeneration ?? 0)

        let merged = BrowserMediaCandidate(
            id: existing.id,
            url: mergedURL,
            rawURL: existing.rawURL,
            finalURL: candidate.finalURL ?? existing.finalURL,
            kind: mergedKind,
            blobKind: candidate.blobKind ?? existing.blobKind,
            mimeType: mergedMIME,
            suggestedFilename: mergedFilename,
            estimatedSize: mergedSize,
            availability: mergedAvailability,
            evidence: uniqueEvidence,
            documentID: candidate.documentID ?? existing.documentID,
            requestContext: existing.requestContext ?? candidate.requestContext,
            associatedManifestID: existing.associatedManifestID ?? candidate.associatedManifestID,
            associatedManifestURL: associatedManifestURL,
            cachedManifestText: candidate.cachedManifestText ?? existing.cachedManifestText,
            lastObserved: max(existing.lastObserved, candidate.lastObserved),
            isLive: mergedIsLive,
            width: mergedWidth,
            height: mergedHeight,
            duration: mergedDuration,
            codecs: candidate.codecs ?? existing.codecs,
            audioLanguage: candidate.audioLanguage ?? existing.audioLanguage,
            documentGeneration: mergedDocGen > 0 ? mergedDocGen : nil,
            navigationGeneration: mergedNavGen > 0 ? mergedNavGen : nil
        )
        values[existing.id] = merged
        canonicalAliases[candidate.id] = existing.id
        canonicalAliases[canonicalKey] = existing.id

        if (merged.kind == .hlsManifest || merged.kind == .dashManifest), let manifestURL = merged.url {
            for (id, val) in values where (val.kind == .mediaSource || val.blobKind == .mediaSource) && val.associatedManifestURL == nil {
                values[id] = BrowserMediaCandidate(
                    id: val.id,
                    url: val.url,
                    rawURL: val.rawURL,
                    finalURL: val.finalURL,
                    kind: val.kind,
                    blobKind: val.blobKind,
                    mimeType: val.mimeType,
                    suggestedFilename: val.suggestedFilename,
                    estimatedSize: val.estimatedSize,
                    availability: val.availability,
                    evidence: val.evidence,
                    documentID: val.documentID,
                    requestContext: val.requestContext,
                    associatedManifestID: val.associatedManifestID,
                    associatedManifestURL: manifestURL,
                    cachedManifestText: val.cachedManifestText ?? merged.cachedManifestText,
                    lastObserved: val.lastObserved,
                    isLive: val.isLive,
                    width: val.width,
                    height: val.height,
                    duration: val.duration,
                    codecs: val.codecs,
                    audioLanguage: val.audioLanguage,
                    documentGeneration: val.documentGeneration,
                    navigationGeneration: val.navigationGeneration
                )
            }
        }
        return merged
    }

    private func preferredAvailability(
        _ lhs: BrowserMediaCandidateAvailability,
        _ rhs: BrowserMediaCandidateAvailability
    ) -> BrowserMediaCandidateAvailability {
        let priority: [BrowserMediaCandidateAvailability] = [
            .downloadable, .requiresPlanning, .captureCandidate, .uncertain, .metadataOnly, .unsupported
        ]
        return (priority.firstIndex(of: rhs) ?? Int.max) < (priority.firstIndex(of: lhs) ?? Int.max) ? rhs : lhs
    }

    private func identityURL(_ url: URL) -> String {
        BrowserMediaCandidateClassifier.stableIdentity(rawURL: url.absoluteString, url: url)
    }
}

// MARK: - Explicit Candidate Sorting

extension BrowserMediaCandidate {
    /// Sorts an array of media candidates according to an explicit `ResourceSortOption`.
    public static func sorted(
        _ candidates: [BrowserMediaCandidate],
        by sortOption: ResourceSortOption,
        variantMetadataMap: [String: HLSVariantStreamItem] = [:]
    ) -> [BrowserMediaCandidate] {
        switch sortOption {
        case .newest:
            return candidates.sorted { (lhs: BrowserMediaCandidate, rhs: BrowserMediaCandidate) -> Bool in
                if lhs.lastObserved != rhs.lastObserved {
                    return lhs.lastObserved > rhs.lastObserved
                }
                if lhs.isStreamingManifest != rhs.isStreamingManifest {
                    return lhs.isStreamingManifest && !rhs.isStreamingManifest
                }
                let fn0 = lhs.suggestedFilename ?? ""
                let fn1 = rhs.suggestedFilename ?? ""
                return fn0.localizedCaseInsensitiveCompare(fn1) == .orderedAscending
            }
        case .size:
            return candidates.sorted { (lhs: BrowserMediaCandidate, rhs: BrowserMediaCandidate) -> Bool in
                let s0 = variantMetadataMap[lhs.id]?.estimatedSizeBytes ?? lhs.estimatedSize ?? 0
                let s1 = variantMetadataMap[rhs.id]?.estimatedSizeBytes ?? rhs.estimatedSize ?? 0
                if s0 != s1 {
                    return s0 > s1
                }
                if lhs.lastObserved != rhs.lastObserved {
                    return lhs.lastObserved > rhs.lastObserved
                }
                let fn0 = lhs.suggestedFilename ?? ""
                let fn1 = rhs.suggestedFilename ?? ""
                return fn0.localizedCaseInsensitiveCompare(fn1) == .orderedAscending
            }
        case .name:
            return candidates.sorted { (lhs: BrowserMediaCandidate, rhs: BrowserMediaCandidate) -> Bool in
                let fn0 = lhs.suggestedFilename ?? ""
                let fn1 = rhs.suggestedFilename ?? ""
                let cmp = fn0.localizedCaseInsensitiveCompare(fn1)
                if cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
                return lhs.lastObserved > rhs.lastObserved
            }
        case .quality:
            return candidates.sorted { (lhs: BrowserMediaCandidate, rhs: BrowserMediaCandidate) -> Bool in
                let h0 = variantMetadataMap[lhs.id]?.resolution?.height ?? lhs.height ?? 0
                let h1 = variantMetadataMap[rhs.id]?.resolution?.height ?? rhs.height ?? 0
                if h0 != h1 {
                    return h0 > h1
                }
                let bw0 = variantMetadataMap[lhs.id]?.bandwidth ?? 0
                let bw1 = variantMetadataMap[rhs.id]?.bandwidth ?? 0
                if bw0 != bw1 {
                    return bw0 > bw1
                }
                if lhs.lastObserved != rhs.lastObserved {
                    return lhs.lastObserved > rhs.lastObserved
                }
                let fn0 = lhs.suggestedFilename ?? ""
                let fn1 = rhs.suggestedFilename ?? ""
                return fn0.localizedCaseInsensitiveCompare(fn1) == .orderedAscending
            }
        case .resolution:
            return candidates.sorted { (lhs: BrowserMediaCandidate, rhs: BrowserMediaCandidate) -> Bool in
                let h0 = variantMetadataMap[lhs.id]?.resolution?.height ?? lhs.height ?? 0
                let h1 = variantMetadataMap[rhs.id]?.resolution?.height ?? rhs.height ?? 0
                if h0 != h1 { return h0 > h1 }
                let w0 = variantMetadataMap[lhs.id]?.resolution?.width ?? lhs.width ?? 0
                let w1 = variantMetadataMap[rhs.id]?.resolution?.width ?? rhs.width ?? 0
                if w0 != w1 { return w0 > w1 }
                return lhs.lastObserved > rhs.lastObserved
            }
        case .bitrate:
            return candidates.sorted { (lhs: BrowserMediaCandidate, rhs: BrowserMediaCandidate) -> Bool in
                let bw0 = variantMetadataMap[lhs.id]?.bandwidth ?? 0
                let bw1 = variantMetadataMap[rhs.id]?.bandwidth ?? 0
                if bw0 != bw1 { return bw0 > bw1 }
                return lhs.lastObserved > rhs.lastObserved
            }
        case .duration:
            return candidates.sorted { (lhs: BrowserMediaCandidate, rhs: BrowserMediaCandidate) -> Bool in
                let d0 = lhs.duration ?? 0
                let d1 = rhs.duration ?? 0
                if d0 != d1 { return d0 > d1 }
                return lhs.lastObserved > rhs.lastObserved
            }
        case .domain:
            return candidates.sorted { (lhs: BrowserMediaCandidate, rhs: BrowserMediaCandidate) -> Bool in
                let dom0 = lhs.url?.host ?? ""
                let dom1 = rhs.url?.host ?? ""
                let cmp = dom0.localizedCaseInsensitiveCompare(dom1)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.lastObserved > rhs.lastObserved
            }
        case .type:
            return candidates.sorted { (lhs: BrowserMediaCandidate, rhs: BrowserMediaCandidate) -> Bool in
                if lhs.kind.rawValue != rhs.kind.rawValue {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.lastObserved > rhs.lastObserved
            }
        }
    }
}

// MARK: - Explicit Candidate Grouping

extension BrowserMediaCandidate {
    /// The mapped category of this candidate.
    public var resourceType: WebpageResourceType {
        switch kind {
        case .hlsManifest, .dashManifest, .mediaSource, .protectedMedia:
            return .video
        case .directMedia:
            let ext = url?.pathExtension.lowercased() ?? ""
            let fnExt = (suggestedFilename ?? "").split(separator: ".").last.map(String.init)?.lowercased() ?? ""
            let isAudio = (mimeType?.lowercased().contains("audio") == true) ||
                ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(ext) ||
                ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(fnExt)
            return isAudio ? .audio : .video
        case .completeBlob:
            if let mime = mimeType?.lowercased(), mime.contains("audio") {
                return .audio
            } else {
                return .video
            }
        case .directFile:
            let ext = url?.pathExtension.lowercased() ?? ""
            let fnExt = (suggestedFilename ?? "").split(separator: ".").last.map(String.init)?.lowercased() ?? ""
            let isAudio = (mimeType?.lowercased().contains("audio") == true) ||
                ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(ext) ||
                ["mp3", "m4a", "aac", "wav", "flac", "ogg"].contains(fnExt)
            return isAudio ? .audio : .other
        case .unknown:
            return .other
        }
    }

    /// Groups candidates by their URL host domain, sorted alphabetically by domain.
    public static func groupedByDomain(_ candidates: [BrowserMediaCandidate]) -> [(domain: String, candidates: [BrowserMediaCandidate])] {
        let dict = Dictionary(grouping: candidates) { cand in
            cand.url?.host?.lowercased() ?? "Other Domains"
        }
        return dict.map { (domain: $0.key, candidates: $0.value) }
            .sorted { $0.domain < $1.domain }
    }

    /// Groups candidates by category (WebpageResourceType), ordered by category cases.
    public static func groupedByCategory(_ candidates: [BrowserMediaCandidate]) -> [(category: WebpageResourceType, candidates: [BrowserMediaCandidate])] {
        let dict = Dictionary(grouping: candidates) { cand in
            cand.resourceType
        }
        return WebpageResourceType.allCases.compactMap { cat in
            guard let list = dict[cat], !list.isEmpty else { return nil }
            return (category: cat, candidates: list)
        }
    }
}
