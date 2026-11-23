import Foundation

/// Categorizes discovered media and downloadable resources on a webpage.
public enum WebpageResourceType: String, CaseIterable, Identifiable, Sendable {
    case video = "Video"
    case audio = "Audio"
    case document = "Document"
    case archive = "Archive"
    case image = "Image"
    case other = "Other"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .video: return "play.rectangle.fill"
        case .audio: return "music.note"
        case .document: return "doc.fill"
        case .archive: return "archivebox.fill"
        case .image: return "photo.fill"
        case .other: return "arrow.down.circle.fill"
        }
    }
}

/// Explicit sorting options for discovered media and downloadable resources.
public enum ResourceSortOption: String, CaseIterable, Identifiable, Sendable {
    case newest = "Newest"
    case size = "Size"
    case quality = "Quality"
    case name = "Name"
    case type = "Type"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .newest: return "clock"
        case .size: return "arrow.down.circle"
        case .quality: return "sparkles"
        case .name: return "textformat"
        case .type: return "folder"
        }
    }
}

/// Explicit grouping options for discovered media and downloadable resources.
public enum ResourceGroupingOption: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case domain = "Domain"
    case category = "Category"

    public static let type: ResourceGroupingOption = .category

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None (Flat List)"
        case .domain: return "By Domain"
        case .category: return "By Category"
        }
    }

    public var iconName: String {
        switch self {
        case .none: return "list.bullet"
        case .domain: return "globe"
        case .category: return "square.grid.2x2"
        }
    }
}

/// Represents an identifiable resource discovered within a webpage's HTML or DOM tree.
public struct WebpageResource: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let title: String
    public let suggestedFilename: String
    public let resourceType: WebpageResourceType
    public let mimeType: String?
    public let estimatedSize: Int64?
    public let isSupported: Bool
    public let unsupportedReason: String?
    /// Request context captured from the page that exposed this resource.
    /// Credentials are filtered again when headers are assembled for a target URL.
    public let requestContext: BrowserRequestContext?
    /// Raw manifest body text captured from in-page network discovery (XHR/Fetch hook).
    public let manifestText: String?
    /// Optional variant selection preferences for multi-variant streaming manifests (e.g. 1080p, 720p).
    public let hlsVariantPreferences: HLSVariantSelectionPreferences?
    /// Optional DASH video representation ID selected by the user.
    public let dashVideoRepresentationID: String?
    /// Optional DASH audio representation ID selected by the user.
    public let dashAudioRepresentationID: String?
    /// Optional DASH text/subtitle representation ID selected by the user.
    public let dashTextRepresentationID: String?
    /// Whether this resource or streaming manifest was detected to contain DRM protection (FairPlay, Widevine, PlayReady).
    public let isDRMProtected: Bool
    /// Identified DRM encryption system if protected (e.g. "FairPlay", "Widevine", "PlayReady", "Sample-AES").
    public let drmProtectionType: String?
    /// Timestamp when this resource was discovered or captured.
    public let discoveredAt: Date
    /// Whether this resource represents a live broadcast or event stream (requiring continuous live recording rather than finite VOD transfer).
    public let isLive: Bool
    /// Resolution string if known (e.g. "1080p", "1920×1080").
    public let resolutionText: String?
    /// Media duration in seconds if known.
    public let duration: TimeInterval?
    /// Codecs string if known (e.g. "H.264", "avc1.640028,mp4a.40.2").
    public let codecs: String?
    /// Audio language code or name if known (e.g. "en", "English").
    public let audioLanguage: String?
    /// Whether this media stream represents an audio-video split representation requiring muxing.
    public let isAudioVideoSplit: Bool

    /// Formatted duration string for display (e.g. "03:45", "1:15:20").
    public var formattedDuration: String? {
        guard let duration, duration > 0, !duration.isNaN, !duration.isInfinite else { return nil }
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// Manifest candidates are intentionally kept outside the ordinary
    /// `isSupported` download path. They require planning and coordinator-
    /// backed execution before they can be offered as a stream download.
    public var isStreamingManifest: Bool {
        let classification = StreamingManifestClassifier.classify(
            url: url,
            mimeType: mimeType
        )
        return classification.kind == .hls || classification.kind == .dash
    }

    /// Indicates whether this resource is an internal transport stream segment or media chunk
    /// (e.g. .ts, .m4s, video/mp2t, or fragmented DASH audio/video segments like bbb_a64k_24.m4a) rather than a standalone media file or manifest.
    public var isSegmentChunk: Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "ts" || ext == "m4s" { return true }
        if let mime = mimeType?.lowercased() {
            if mime.contains("mp2t") || mime.contains("iso.segment") {
                return true
            }
        }

        // Segment chunks in fragmented containers (.m4a, .mp4, .m4v, .webm)
        if ext == "m4a" || ext == "mp4" || ext == "m4v" || ext == "webm" {
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            // 1. Initialization segments
            if stem == "init" || stem.hasPrefix("init-") || stem.hasPrefix("init_") ||
               stem.hasSuffix("-init") || stem.hasSuffix("_init") || stem.contains("_init_") {
                return true
            }
            // 2. Explicit chunk/segment markers in filename
            if stem.range(of: #"(?:^|[-_.])(?:chunk|segment|frag|fragment|part|seq|sq)[-_.]?\d+"#, options: .regularExpression) != nil {
                return true
            }
            // 3. Segment parameters in query
            if let query = url.query?.lowercased() {
                if query.contains("range=") || query.contains("segment=") || query.contains("sq=") ||
                   query.contains("chunk=") || query.contains("byterange=") {
                    return true
                }
            }
            // 4. Typical streaming paths (e.g. /dash/, /segments/, /fragments/) with numbered segment
            let lowerPath = url.path.lowercased()
            let hasStreamingPath = lowerPath.contains("/dash/") || lowerPath.contains("/segments/") ||
                lowerPath.contains("/fragments/") || lowerPath.contains("/chunks/")
            let hasNumberedSuffix = stem.range(of: #"[-_.]\d{1,6}$"#, options: .regularExpression) != nil
            if hasStreamingPath && hasNumberedSuffix {
                return true
            }
            // 5. Typical adaptive streaming representation naming with segment numbers
            // e.g. bbb_a64k_24, bbb_30fps_3840x2160_1200k_1, track_audio_64k_1
            if stem.range(of: #"[a-z0-9]+(?:k|fps|p|\d+x\d+)[-_.]\d{1,6}$"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Identifies resources backed by active browser session memory (Blob URLs).
    /// These are exported through the bounded in-page Blob capture pipeline rather than HTTP.
    public var isBlobResource: Bool {
        url.scheme?.lowercased() == "blob"
    }

    /// Identifies whether this blob resource represents an unplayable MediaSource streaming buffer
    /// (empty or generic application/octet-stream MIME type, with fallback .bin / stream name) rather than a complete downloadable file.
    public var isMediaSourceBlob: Bool {
        guard isBlobResource else { return false }
        let cleanMime = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        if cleanMime == "application/x-mediasource" { return true }
        let isGenericMime = cleanMime == nil || cleanMime?.isEmpty == true || cleanMime == "application/octet-stream"
        if isGenericMime {
            let lowerFilename = suggestedFilename.lowercased()
            return lowerFilename.hasSuffix(".bin") || lowerFilename.hasPrefix("blob_stream") || resourceType == .other
        }
        return false
    }

    /// Determines if a URL represents a supported downloadable candidate.
    public static func evaluateSupport(
        for url: URL,
        rawURL: String,
        mimeType: String? = nil
    ) -> (isSupported: Bool, reason: String?) {
        WebpageResourceExtractor.evaluateSupport(for: url, rawURL: rawURL, mimeType: mimeType)
    }

    public init(
        id: String = UUID().uuidString,
        url: URL,
        title: String,
        suggestedFilename: String,
        resourceType: WebpageResourceType,
        mimeType: String? = nil,
        estimatedSize: Int64? = nil,
        isSupported: Bool = true,
        unsupportedReason: String? = nil,
        requestContext: BrowserRequestContext? = nil,
        manifestText: String? = nil,
        hlsVariantPreferences: HLSVariantSelectionPreferences? = nil,
        dashVideoRepresentationID: String? = nil,
        dashAudioRepresentationID: String? = nil,
        dashTextRepresentationID: String? = nil,
        isDRMProtected: Bool = false,
        drmProtectionType: String? = nil,
        discoveredAt: Date = Date(),
        isLive: Bool = false,
        resolutionText: String? = nil,
        duration: TimeInterval? = nil,
        codecs: String? = nil,
        audioLanguage: String? = nil,
        isAudioVideoSplit: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.suggestedFilename = suggestedFilename
        self.resourceType = resourceType
        self.mimeType = mimeType
        self.estimatedSize = estimatedSize
        self.isSupported = isSupported
        self.unsupportedReason = unsupportedReason
        self.requestContext = requestContext
        self.manifestText = manifestText
        self.hlsVariantPreferences = hlsVariantPreferences
        self.dashVideoRepresentationID = dashVideoRepresentationID
        self.dashAudioRepresentationID = dashAudioRepresentationID
        self.dashTextRepresentationID = dashTextRepresentationID
        self.isDRMProtected = isDRMProtected
        self.drmProtectionType = drmProtectionType
        self.discoveredAt = discoveredAt
        self.isLive = isLive
        self.resolutionText = resolutionText
        self.duration = duration
        self.codecs = codecs
        self.audioLanguage = audioLanguage
        self.isAudioVideoSplit = isAudioVideoSplit
    }

    /// Evaluates whether this resource URL or its signed variant URL has already passed its signed expiration timestamp.
    public func isExpired(now: Date = Date()) -> Bool {
        if let exactURI = hlsVariantPreferences?.exactURI, DirectMediaTransferPlanner.isURLExpired(exactURI, now: now) {
            return true
        }
        return DirectMediaTransferPlanner.isURLExpired(url, now: now)
    }

    /// Evaluates whether this resource URL or its signed variant URL will expire soon (default within 300 seconds).
    public func isExpiringSoon(thresholdSeconds: TimeInterval = 300, now: Date = Date()) -> Bool {
        if let exactURI = hlsVariantPreferences?.exactURI, DirectMediaTransferPlanner.isURLExpiringSoon(exactURI, thresholdSeconds: thresholdSeconds, now: now) {
            return true
        }
        return DirectMediaTransferPlanner.isURLExpiringSoon(url, thresholdSeconds: thresholdSeconds, now: now)
    }

    /// Computed expiration date extracted from signed URL query parameters if present,
    /// returning the earliest expiration deadline among the master manifest and variant URLs.
    public var expirationDate: Date? {
        let masterExp = DirectMediaTransferPlanner.urlExpirationDate(url)
        let variantExp = hlsVariantPreferences?.exactURI.flatMap { DirectMediaTransferPlanner.urlExpirationDate($0) }
        switch (masterExp, variantExp) {
        case let (m?, v?): return min(m, v)
        case let (m?, nil): return m
        case let (nil, v?): return v
        case (nil, nil): return nil
        }
    }

    public var suggestedExtension: String {
        let ext = FilenameExtensionHelper.split(filename: suggestedFilename).ext
        if !ext.isEmpty {
            return ext
        }
        return FilenameExtensionHelper.detectExtension(from: url, mimeType: mimeType)
    }
}

/// Raw candidate extracted from a DOM element or HTML tag prior to resolution.
public struct WebpageRawResourceCandidate: Sendable, Codable {
    public let rawURL: String
    public let tag: String?
    public let text: String?
    public let declaredType: String?
    public let width: Int?
    public let height: Int?
    public let duration: Double?

    public init(
        rawURL: String,
        tag: String? = nil,
        text: String? = nil,
        declaredType: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil
    ) {
        self.rawURL = rawURL
        self.tag = tag
        self.text = text
        self.declaredType = declaredType
        self.width = width
        self.height = height
        self.duration = duration
    }
}

/// Pure Swift resource discovery engine that extracts, resolves, deduplicates,
/// and categorizes media assets and downloadable links from webpage HTML or DOM structures.
public struct WebpageResourceExtractor {

    // Known media & file extensions by category
    public static let videoExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "webm", "m4v", "flv", "wmv", "3gp", "ts", "m4s", "m3u8", "mpd"
    ]

    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "flac", "aac", "ogg", "oga", "opus", "wma", "aiff"
    ]

    public static let documentExtensions: Set<String> = [
        "pdf", "epub", "mobi", "djvu", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv"
    ]

    public static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "tbz2", "dmg", "pkg",
        "iso", "img", "exe", "msi", "apk", "ipa", "deb", "rpm", "torrent", "bin"
    ]

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "tiff"
    ]

    /// Categorizes a resource based on its file extension or declared MIME type.
    public static func categorize(extension ext: String?, mimeType: String?) -> WebpageResourceType {
        let cleanExt = ext?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMime = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()

        if let m = cleanMime {
            if m == "application/vnd.apple.mpegurl" ||
                m == "application/x-mpegurl" ||
                m == "audio/mpegurl" ||
                m == "application/dash+xml" ||
                m == "video/mp2t" ||
                m == "video/iso.segment" {
                return .video
            }
            if m.hasPrefix("video/") { return .video }
            if m.hasPrefix("audio/") { return .audio }
            if m.hasPrefix("image/") { return .image }
            if m == "application/pdf" || m.contains("word") || m.contains("excel") || m.contains("powerpoint") {
                return .document
            }
            if m.contains("zip") || m.contains("tar") || m.contains("compressed") || m.contains("diskimage") || m.contains("bittorrent") {
                return .archive
            }
        }

        if let e = cleanExt {
            if videoExtensions.contains(e) || e == "blob" {
                if let m = cleanMime {
                    if m.hasPrefix("audio/") { return .audio }
                    if m.hasPrefix("image/") { return .image }
                }
                return .video
            }
            if audioExtensions.contains(e) { return .audio }
            if documentExtensions.contains(e) { return .document }
            if archiveExtensions.contains(e) { return .archive }
            if imageExtensions.contains(e) { return .image }
        }

        return .other
    }

    /// Resolves an arbitrary raw URL string against a base URL, removing fragments.
    public static func resolveURL(_ rawString: String, baseURL: URL) -> URL? {
        var trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Handle data: URIs directly
        if trimmed.lowercased().hasPrefix("data:") {
            return URL(string: trimmed)
        }

        // Handle blob: URLs directly
        if trimmed.lowercased().hasPrefix("blob:") {
            return URL(string: trimmed)
        }

        // Strip HTML fragments (e.g. video.mp4#t=10s)
        if let hashIdx = trimmed.firstIndex(of: "#") {
            trimmed = String(trimmed[..<hashIdx])
        }
        guard !trimmed.isEmpty else { return nil }

        // Handle protocol-relative URLs (e.g. //cdn.example.com/asset.mp4)
        if trimmed.hasPrefix("//") {
            let scheme = baseURL.scheme ?? "https"
            return URL(string: "\(scheme):\(trimmed)")
        }

        // Handle absolute or relative URLs
        if let url = URL(string: trimmed, relativeTo: baseURL) {
            return url.absoluteURL
        }
        return nil
    }

    /// Extracts MIME type from a data URI (e.g. "data:image/png;base64,...")
    public static func extractDataURIMIMEType(_ rawURL: String) -> String? {
        guard rawURL.lowercased().hasPrefix("data:") else { return nil }
        let afterData = rawURL.dropFirst(5)
        if let semicolonIdx = afterData.firstIndex(of: ";") {
            let mime = String(afterData[..<semicolonIdx]).trimmingCharacters(in: .whitespaces)
            return mime.isEmpty ? nil : mime
        } else if let commaIdx = afterData.firstIndex(of: ",") {
            let mime = String(afterData[..<commaIdx]).trimmingCharacters(in: .whitespaces)
            return mime.isEmpty ? nil : mime
        }
        return nil
    }

    /// Determines if a URL represents a supported downloadable candidate.
    public static func evaluateSupport(
        for url: URL,
        rawURL: String,
        mimeType: String? = nil
    ) -> (isSupported: Bool, reason: String?) {
        let scheme = url.scheme?.lowercased() ?? ""
        let lowerRaw = rawURL.lowercased()
        let normalizedMIME = mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if scheme == "blob" || lowerRaw.hasPrefix("blob:") {
            if normalizedMIME == "application/x-mediasource" {
                return (false, "This site uses MediaSource streaming. You must download the manifest (.m3u8 or .mpd) instead.")
            }
            // Blob URLs are memory-backed in the active browser session and are supported
            // through the bounded in-page Blob capture pipeline.
            return (true, nil)
        }

        if scheme == "data" || lowerRaw.hasPrefix("data:") {
            return (false, "Data URIs are embedded inline into the page and are not hosted on an external server.")
        }

        let pathExt = url.pathExtension.lowercased()
        let manifestClassification = StreamingManifestClassifier.classify(
            url: url,
            mimeType: normalizedMIME
        )
        if manifestClassification.kind == .hls || manifestClassification.kind == .dash ||
            manifestClassification.kind == .unsupported ||
            lowerRaw.hasPrefix("data:application/vnd.apple.mpegurl") {
            let manifestName = pathExt.isEmpty ? "manifest" : pathExt.uppercased()
            if manifestClassification.kind == .unsupported {
                return (false, "Streaming manifest metadata conflicts (\(manifestName)); it cannot be downloaded safely.")
            }
            return (false, "Streaming playlist manifest (\(manifestName)). Use the manifest-aware streaming workflow.")
        }

        let isChunkExt = pathExt == "ts" || pathExt == "m4s"
        let isChunkMIME = normalizedMIME?.contains("mp2t") == true || normalizedMIME?.contains("iso.segment") == true
        let isDASHChunk = (pathExt == "m4a" || pathExt == "mp4" || pathExt == "m4v" || pathExt == "webm") &&
            WebpageResourceExtractor.isSegmentFilenamePattern(url.deletingPathExtension().lastPathComponent) &&
            (url.path.lowercased().contains("/dash/") || url.query?.lowercased().contains("range=") == true || url.query?.lowercased().contains("segment=") == true || url.deletingPathExtension().lastPathComponent.lowercased().range(of: #"[a-z0-9]+(?:k|fps|p|\d+x\d+)[-_.]\d{1,6}$"#, options: .regularExpression) != nil)

        if isChunkExt || isChunkMIME || isDASHChunk {
            let chunkName = pathExt.isEmpty ? "segment" : pathExt.uppercased()
            return (false, "Streaming segment chunk (\(chunkName)). Download the playlist manifest (.m3u8 or .mpd) instead.")
        }

        if scheme != "http" && scheme != "https" {
            return (false, "Unsupported URL scheme: \(scheme)")
        }

        return (true, nil)
    }

    /// Evaluates if a raw candidate is a relevant media or downloadable resource.
    public static func isRelevantResource(
        url: URL,
        tag: String?,
        resourceType: WebpageResourceType,
        mediaOnly: Bool = false
    ) -> Bool {
        if mediaOnly {
            return resourceType == .video || resourceType == .audio
        }

        // Direct media elements and images are always relevant
        if let t = tag?.lowercased(), t == "video" || t == "audio" || t == "source" || t == "img" || t == "mediasource" || t == "blob" {
            return true
        }

        // Known media, document, and archive types are always relevant
        if resourceType != .other {
            return true
        }

        // For links (<a href="...">), only include if the extension is recognized as a download
        let ext = BrowserDownloadClassifier.extractURLExtension(from: url)
        if let ext = ext, BrowserDownloadClassifier.downloadableExtensions.contains(ext) {
            return true
        }

        return false
    }

    /// Extracts and categorizes resources from a list of raw DOM candidates.
    public static func extractFromRawCandidates(
        _ candidates: [WebpageRawResourceCandidate],
        baseURL: URL,
        mediaOnly: Bool = false
    ) -> [WebpageResource] {
        var results: [WebpageResource] = []
        var seenURLs = Set<String>()

        for candidate in candidates {
            guard let resolvedURL = resolveURL(candidate.rawURL, baseURL: baseURL) else {
                continue
            }

            let normalizedKey = resolvedURL.absoluteString.lowercased()
            if seenURLs.contains(normalizedKey) {
                continue
            }

            let ext = BrowserDownloadClassifier.extractURLExtension(from: resolvedURL)
            let declaredMIME = candidate.declaredType ?? extractDataURIMIMEType(candidate.rawURL)
            var type = categorize(extension: ext, mimeType: declaredMIME)
            switch candidate.tag?.lowercased() {
            case "video":
                type = .video
            case "audio":
                type = .audio
            case "source" where declaredMIME?.lowercased().hasPrefix("video/") == true:
                type = .video
            case "source" where declaredMIME?.lowercased().hasPrefix("audio/") == true:
                type = .audio
            case "mediasource", "sourcebuffer", "blob":
                if declaredMIME?.lowercased().hasPrefix("audio/") == true {
                    type = .audio
                } else {
                    type = .video
                }
            default:
                if resolvedURL.scheme?.lowercased() == "blob" || ext?.lowercased() == "blob" {
                    if declaredMIME?.lowercased().hasPrefix("audio/") == true {
                        type = .audio
                    } else if declaredMIME?.lowercased().hasPrefix("image/") == true {
                        type = .image
                    } else {
                        type = .video
                    }
                }
            }

            // Filter out ordinary web navigation links that are not downloads or media
            if !isRelevantResource(
                url: resolvedURL,
                tag: candidate.tag,
                resourceType: type,
                mediaOnly: mediaOnly
            ) {
                continue
            }

            seenURLs.insert(normalizedKey)

            let (isSupported, reason) = evaluateSupport(
                for: resolvedURL,
                rawURL: candidate.rawURL,
                mimeType: declaredMIME
            )
            let filename: String
            if resolvedURL.scheme?.lowercased() == "data" {
                let subExt = declaredMIME?.split(separator: "/").last.map(String.init) ?? "bin"
                filename = "embedded_resource.\(subExt)"
            } else if resolvedURL.scheme?.lowercased() == "blob" {
                filename = blobFilename(candidateTitle: candidate.text, mimeType: declaredMIME, type: type)
            } else if type == .video || type == .audio {
                let candidateName = BrowserDownloadClassifier.suggestedFilenameFromURL(resolvedURL, mimeType: declaredMIME)
                let ext = (candidateName as NSString).pathExtension.lowercased()
                if ext == "bin" || ext.isEmpty {
                    let mediaExt = (type == .video) ? "mp4" : "m4a"
                    if let rawTitle = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty {
                        let sanitized = sanitizeTitleForFilename(rawTitle)
                        filename = sanitized.isEmpty ? (type == .video ? "video.\(mediaExt)" : "audio.\(mediaExt)") : "\(sanitized).\(mediaExt)"
                    } else {
                        let stem = (candidateName as NSString).deletingPathExtension
                        let safeStem = (stem.isEmpty || stem == "download" || stem.hasPrefix("download_")) ? (type == .video ? "video" : "audio") : stem
                        filename = "\(safeStem).\(mediaExt)"
                    }
                } else {
                    filename = candidateName
                }
            } else {
                filename = BrowserDownloadClassifier.suggestedFilenameFromURL(resolvedURL, mimeType: declaredMIME)
            }

            let title: String
            if let trimmed = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                title = trimmed
            } else {
                title = filename
            }

            let resText: String? = {
                if let w = candidate.width, let h = candidate.height, w > 0, h > 0 {
                    return "\(w)×\(h)"
                }
                return nil
            }()

            results.append(WebpageResource(
                url: resolvedURL,
                title: title,
                suggestedFilename: filename,
                resourceType: type,
                mimeType: declaredMIME,
                isSupported: isSupported,
                unsupportedReason: reason,
                resolutionText: resText,
                duration: candidate.duration
            ))
        }

        return results
    }

    private static func blobFilename(
        candidateTitle: String? = nil,
        mimeType: String? = nil,
        type: WebpageResourceType = .video
    ) -> String {
        let extensionName: String
        switch mimeType?.lowercased() {
        case "video/mp4": extensionName = "mp4"
        case "video/webm": extensionName = "webm"
        case "audio/mpeg": extensionName = "mp3"
        case "audio/mp4", "audio/x-m4a": extensionName = "m4a"
        case "audio/webm": extensionName = "webm"
        case "audio/ogg": extensionName = "ogg"
        case "image/png": extensionName = "png"
        case "image/jpeg": extensionName = "jpg"
        case "image/webp": extensionName = "webp"
        default:
            if type == .video {
                extensionName = "mp4"
            } else if type == .audio {
                extensionName = "m4a"
            } else if type == .image {
                extensionName = "png"
            } else {
                extensionName = "bin"
            }
        }

        if let rawTitle = candidateTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty {
            let sanitized = sanitizeTitleForFilename(rawTitle)
            if !sanitized.isEmpty {
                if sanitized.lowercased().hasSuffix(".\(extensionName)") {
                    return sanitized
                }
                return "\(sanitized).\(extensionName)"
            }
        }
        return "blob_stream.\(extensionName)"
    }

    /// Checks if a filename stem matches typical media segment chunk patterns.
    public static func isSegmentFilenamePattern(_ stem: String) -> Bool {
        let lower = stem.lowercased()
        if lower == "init" || lower.hasPrefix("init-") || lower.hasPrefix("init_") ||
           lower.hasSuffix("-init") || lower.hasSuffix("_init") || lower.contains("_init_") {
            return true
        }
        if lower.range(of: #"(?:^|[-_.])(?:chunk|segment|frag|fragment|part|seq|sq)[-_.]?\d+"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"[a-z0-9]+(?:k|fps|p|\d+x\d+)[-_.]\d{1,6}$"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"[-_.]\d{1,6}$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Detects sequential segment chunks across a collection of resources sharing a common base stem and host.
    public static func detectSequentialSegmentChunks(in resources: [WebpageResource]) -> Set<String> {
        var groups: [String: [WebpageResource]] = [:]
        for res in resources {
            let ext = res.url.pathExtension.lowercased()
            guard ext == "m4a" || ext == "mp4" || ext == "m4v" || ext == "webm" || ext == "ts" || ext == "m4s" else { continue }
            let stem = res.url.deletingPathExtension().lastPathComponent.lowercased()
            guard let match = stem.range(of: #"[-_.]\d{1,6}$"#, options: .regularExpression) else { continue }
            let basePrefix = String(stem[..<match.lowerBound])
            let host = res.url.host?.lowercased() ?? ""
            let key = "\(host)|\(res.url.deletingLastPathComponent().path)|\(basePrefix)"
            groups[key, default: []].append(res)
        }
        var chunkIDs = Set<String>()
        for (_, items) in groups where items.count >= 2 {
            for item in items {
                chunkIDs.insert(item.id)
            }
        }
        return chunkIDs
    }

    private static func sanitizeTitleForFilename(_ title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = title.components(separatedBy: invalidCharacters).joined(separator: " ")
        let collapsed = cleaned.split(separator: " ").joined(separator: " ")
        return String(collapsed.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pure Swift HTML parser extracting resource candidates using regex scanning.
    public static func extractResources(fromHTML html: String, baseURL: URL) -> [WebpageResource] {
        var candidates: [WebpageRawResourceCandidate] = []

        // 1. Scan for <video src="..."> and <video><source src="..."></video>
        let videoSrcPattern = "<video[^>]+src=[\"']([^\"']+)[\"'][^>]*>"
        findMatches(pattern: videoSrcPattern, in: html) { match in
            candidates.append(WebpageRawResourceCandidate(rawURL: match, tag: "video"))
        }

        // 2. Scan for <audio src="...">
        let audioSrcPattern = "<audio[^>]+src=[\"']([^\"']+)[\"'][^>]*>"
        findMatches(pattern: audioSrcPattern, in: html) { match in
            candidates.append(WebpageRawResourceCandidate(rawURL: match, tag: "audio"))
        }

        // 3. Scan for <source src="..." type="...">
        let sourcePattern = "<source[^>]+src=[\"']([^\"']+)[\"'](?:[^>]+type=[\"']([^\"']+)[\"'])?[^>]*>"
        findMatchesWithGroup(pattern: sourcePattern, in: html) { url, type in
            candidates.append(WebpageRawResourceCandidate(rawURL: url, tag: "source", declaredType: type))
        }

        // 4. Scan for <a href="...">text</a>
        let anchorPattern = "<a[^>]+href=[\"']([^\"']+)[\"'][^>]*>(.*?)<\\/a>"
        findMatchesWithGroup(pattern: anchorPattern, in: html) { href, innerText in
            let cleanText = innerText?
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(WebpageRawResourceCandidate(rawURL: href, tag: "a", text: cleanText))
        }

        // 5. Scan for <img src="..." alt="...">
        let imgPattern = "<img[^>]+src=[\"']([^\"']+)[\"'](?:[^>]+alt=[\"']([^\"']+)[\"'])?[^>]*>"
        findMatchesWithGroup(pattern: imgPattern, in: html) { src, alt in
            candidates.append(WebpageRawResourceCandidate(rawURL: src, tag: "img", text: alt))
        }

        return extractFromRawCandidates(candidates, baseURL: baseURL)
    }

    // MARK: - Regex Helpers

    private static func findMatches(pattern: String, in text: String, onMatch: (String) -> Void) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return
        }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            if match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                if range.location != NSNotFound {
                    onMatch(nsString.substring(with: range))
                }
            }
        }
    }

    private static func findMatchesWithGroup(pattern: String, in text: String, onMatch: (String, String?) -> Void) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return
        }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            if match.numberOfRanges > 1 {
                let range1 = match.range(at: 1)
                if range1.location != NSNotFound {
                    let val1 = nsString.substring(with: range1)
                    var val2: String? = nil
                    if match.numberOfRanges > 2 {
                        let range2 = match.range(at: 2)
                        if range2.location != NSNotFound {
                            val2 = nsString.substring(with: range2)
                        }
                    }
                    onMatch(val1, val2)
                }
            }
        }
    }
}

// MARK: - BrowserMediaCandidate Bridging

extension WebpageResource {
    /// Initializes a `WebpageResource` from a `BrowserMediaCandidate`.
    public init?(candidate: BrowserMediaCandidate) {
        guard let res = candidate.toWebpageResource() else { return nil }
        self = res
    }

    /// Converts this resource into its canonical `BrowserMediaCandidate` representation.
    public func toMediaCandidate(now: Date = Date()) -> BrowserMediaCandidate {
        BrowserMediaCandidateClassifier.classify(resource: self, now: now)
    }

    /// Associated `BrowserMediaCandidate` representation.
    public var mediaCandidate: BrowserMediaCandidate {
        toMediaCandidate()
    }
}

// MARK: - Explicit Resource Grouping

extension WebpageResource {
    /// Groups resources by their URL host domain, sorted alphabetically by domain.
    public static func groupedByDomain(_ resources: [WebpageResource]) -> [(domain: String, resources: [WebpageResource])] {
        let dict = Dictionary(grouping: resources) { res in
            res.url.host?.lowercased() ?? "Other Domains"
        }
        return dict.map { (domain: $0.key, resources: $0.value) }
            .sorted { $0.domain < $1.domain }
    }

    /// Groups resources by category (WebpageResourceType), ordered by category cases.
    public static func groupedByCategory(_ resources: [WebpageResource]) -> [(category: WebpageResourceType, resources: [WebpageResource])] {
        let dict = Dictionary(grouping: resources) { $0.resourceType }
        return WebpageResourceType.allCases.compactMap { cat in
            guard let list = dict[cat], !list.isEmpty else { return nil }
            return (category: cat, resources: list)
        }
    }
}

