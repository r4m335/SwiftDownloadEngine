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
    /// (e.g. .ts, .m4s, video/mp2t) rather than a standalone media file or manifest.
    public var isSegmentChunk: Bool {
        let ext = url.pathExtension.lowercased()
        let isChunkExt = ext == "ts" || ext == "m4s"
        let isChunkMIME = mimeType?.lowercased().contains("mp2t") == true ||
            mimeType?.lowercased().contains("iso.segment") == true
        return isChunkExt || isChunkMIME
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
            return lowerFilename.hasSuffix(".bin") || lowerFilename.hasPrefix("blob_stream") || resourceType == .other || mimeType == nil
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
        requestContext: BrowserRequestContext? = nil
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
    }
}

/// Raw candidate extracted from a DOM element or HTML tag prior to resolution.
public struct WebpageRawResourceCandidate: Sendable, Codable {
    public let rawURL: String
    public let tag: String?
    public let text: String?
    public let declaredType: String?

    public init(rawURL: String, tag: String? = nil, text: String? = nil, declaredType: String? = nil) {
        self.rawURL = rawURL
        self.tag = tag
        self.text = text
        self.declaredType = declaredType
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
            if videoExtensions.contains(e) { return .video }
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
            let isGenericMime = normalizedMIME == nil || normalizedMIME?.isEmpty == true || normalizedMIME == "application/octet-stream" || normalizedMIME == "application/x-mediasource"
            if isGenericMime {
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

        if pathExt == "ts" || pathExt == "m4s" || normalizedMIME?.contains("mp2t") == true || normalizedMIME?.contains("iso.segment") == true {
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
        if let t = tag?.lowercased(), t == "video" || t == "audio" || t == "source" || t == "img" {
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
            default:
                break
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

            results.append(WebpageResource(
                url: resolvedURL,
                title: title,
                suggestedFilename: filename,
                resourceType: type,
                mimeType: declaredMIME,
                isSupported: isSupported,
                unsupportedReason: reason
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
