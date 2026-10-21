import Foundation

/// Result of evaluating whether a browser resource represents a downloadable file.
public struct DownloadClassification: Equatable {
    public enum Confidence: String, Equatable {
        case high     // Explicit Content-Disposition: attachment
        case medium   // Recognised binary/installer extension or binary MIME
        case low      // Generic media MIME or ambiguous extension
        case none     // Normal webpage or non-download resource
    }

    public let isDownload: Bool
    public let confidence: Confidence
    public let suggestedFilename: String?
    public let mimeType: String?
    public let reason: String

    public init(
        isDownload: Bool,
        confidence: Confidence,
        suggestedFilename: String?,
        mimeType: String?,
        reason: String
    ) {
        self.isDownload = isDownload
        self.confidence = confidence
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.reason = reason
    }
}

/// Pure Swift classifier that inspects URLs, HTTP response headers, and MIME types
/// to identify downloadable resources without platform-specific dependencies.
public struct BrowserDownloadClassifier {

    /// Extensions commonly recognized as downloadable files.
    public static let downloadableExtensions: Set<String> = [
        // Archives & Compressed files
        "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "tbz2", "z", "lz", "lzma", "cab",
        // Documents & Books
        "pdf", "epub", "mobi", "djvu", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        // Installers & Executables & Packages
        "apk", "ipa", "exe", "msi", "dmg", "pkg", "deb", "rpm", "appx", "msix",
        // Disk & VM Images
        "iso", "img", "vmdk", "vdi", "qcow2",
        // Audio
        "mp3", "m4a", "wav", "flac", "aac", "ogg", "oga", "opus", "wma", "aiff",
        // Video
        "mp4", "mkv", "avi", "mov", "webm", "m4v", "flv", "wmv", "3gp", "ts",
        // Torrents
        "torrent",
        // Binary payloads
        "bin", "dat", "cue"
    ]

    /// Extensions that represent high-priority binary archives or system installers.
    public static let highPriorityBinaryExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "tbz2",
        "dmg", "pkg", "iso", "img", "exe", "msi", "apk", "ipa", "deb", "rpm",
        "torrent"
    ]

    /// MIME types that signify downloadable files/archives.
    public static let downloadableMIMETypes: Set<String> = [
        "application/octet-stream",
        "application/zip",
        "application/x-zip-compressed",
        "application/x-7z-compressed",
        "application/x-rar-compressed",
        "application/vnd.rar",
        "application/x-tar",
        "application/gzip",
        "application/x-gzip",
        "application/x-bzip2",
        "application/x-xz",
        "application/pdf",
        "application/epub+zip",
        "application/vnd.android.package-archive",
        "application/x-ios-app",
        "application/x-apple-diskimage",
        "application/x-msdownload",
        "application/x-msdos-program",
        "application/x-bittorrent",
        "application/x-iso9660-image"
    ]

    /// MIME types for normal web documents that must NOT be treated as downloads unless attachment disposition is present.
    public static let webDocumentMIMETypes: Set<String> = [
        "text/html",
        "application/xhtml+xml",
        "text/plain",
        "text/css",
        "text/javascript",
        "application/javascript",
        "application/x-javascript",
        "application/json",
        "application/xml",
        "text/xml",
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/webp",
        "image/svg+xml",
        "image/x-icon",
        "image/bmp"
    ]

    /// Evaluates whether a network resource represents a downloadable file based on
    /// URL structure, HTTP status code, Content-Disposition headers, and MIME type.
    public static func classify(
        url: URL,
        statusCode: Int? = nil,
        contentDisposition: String? = nil,
        mimeType: String? = nil,
        canShowMIMEType: Bool? = nil
    ) -> DownloadClassification {
        // 1. URL Scheme Check: only HTTP and HTTPS are valid download targets
        guard BrowserURLResolver.isValidDownloadURL(url) else {
            return DownloadClassification(
                isDownload: false,
                confidence: .none,
                suggestedFilename: nil,
                mimeType: mimeType,
                reason: "Unsupported or non-HTTP URL scheme"
            )
        }

        // 2. HTTP Status Code Check: redirects and error pages must not be intercepted
        if let code = statusCode {
            if (300...399).contains(code) {
                return DownloadClassification(
                    isDownload: false,
                    confidence: .none,
                    suggestedFilename: nil,
                    mimeType: mimeType,
                    reason: "HTTP redirect status: \(code)"
                )
            }
            if code == 204 || code == 205 {
                return DownloadClassification(
                    isDownload: false,
                    confidence: .none,
                    suggestedFilename: nil,
                    mimeType: mimeType,
                    reason: "No-content status: \(code)"
                )
            }
            if code >= 400 {
                return DownloadClassification(
                    isDownload: false,
                    confidence: .none,
                    suggestedFilename: nil,
                    mimeType: mimeType,
                    reason: "HTTP error status: \(code)"
                )
            }
        }

        // 3. Content-Disposition Evidence (Highest Priority)
        if let disposition = contentDisposition, !disposition.trimmingCharacters(in: .whitespaces).isEmpty {
            let (isAttachment, parsedName) = parseContentDisposition(disposition)
            if isAttachment {
                let finalFilename = parsedName ?? suggestedFilenameFromURL(url, mimeType: mimeType)
                return DownloadClassification(
                    isDownload: true,
                    confidence: .high,
                    suggestedFilename: finalFilename,
                    mimeType: mimeType,
                    reason: "Content-Disposition header specifies attachment"
                )
            }
        }

        // Clean MIME type (strip parameters such as charset)
        let cleanMime: String? = mimeType?
            .split(separator: ";")
            .first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        // 4. Web Document Protection
        if let mime = cleanMime, webDocumentMIMETypes.contains(mime) {
            return DownloadClassification(
                isDownload: false,
                confidence: .none,
                suggestedFilename: nil,
                mimeType: mime,
                reason: "Web document MIME type: \(mime)"
            )
        }

        // 5. Downloadable MIME Type Evidence
        if let mime = cleanMime {
            if mime == "application/octet-stream" {
                let ext = extractURLExtension(from: url)
                if let ext = ext, downloadableExtensions.contains(ext) {
                    return DownloadClassification(
                        isDownload: true,
                        confidence: .medium,
                        suggestedFilename: suggestedFilenameFromURL(url, mimeType: mime),
                        mimeType: mime,
                        reason: "Binary octet-stream with downloadable extension: .\(ext)"
                    )
                }
                if canShowMIMEType == false {
                    return DownloadClassification(
                        isDownload: true,
                        confidence: .medium,
                        suggestedFilename: suggestedFilenameFromURL(url, mimeType: mime),
                        mimeType: mime,
                        reason: "Binary octet-stream cannot be rendered by browser"
                    )
                }
            } else if downloadableMIMETypes.contains(mime) {
                // If it's an archive or installer, it is definitely a download
                if mime.contains("zip") || mime.contains("tar") || mime.contains("gzip") ||
                   mime.contains("rar") || mime.contains("7z") || mime.contains("diskimage") ||
                   mime.contains("bittorrent") || mime.contains("package") || mime.contains("executable") {
                    return DownloadClassification(
                        isDownload: true,
                        confidence: .medium,
                        suggestedFilename: suggestedFilenameFromURL(url, mimeType: mime),
                        mimeType: mime,
                        reason: "Downloadable archive/installer MIME type: \(mime)"
                    )
                }
                if canShowMIMEType == false {
                    return DownloadClassification(
                        isDownload: true,
                        confidence: .medium,
                        suggestedFilename: suggestedFilenameFromURL(url, mimeType: mime),
                        mimeType: mime,
                        reason: "Downloadable MIME type cannot be rendered by browser: \(mime)"
                    )
                }
            }
        }

        // 6. URL Extension Evidence
        if let ext = extractURLExtension(from: url) {
            if highPriorityBinaryExtensions.contains(ext) {
                if canShowMIMEType != true {
                    return DownloadClassification(
                        isDownload: true,
                        confidence: .medium,
                        suggestedFilename: suggestedFilenameFromURL(url, mimeType: cleanMime),
                        mimeType: cleanMime,
                        reason: "High-priority downloadable file extension: .\(ext)"
                    )
                }
            } else if downloadableExtensions.contains(ext) {
                if canShowMIMEType == false {
                    return DownloadClassification(
                        isDownload: true,
                        confidence: .medium,
                        suggestedFilename: suggestedFilenameFromURL(url, mimeType: cleanMime),
                        mimeType: cleanMime,
                        reason: "Downloadable file extension: .\(ext)"
                    )
                }
            }
        }

        // 7. Default: Ordinary Navigatable Page
        return DownloadClassification(
            isDownload: false,
            confidence: .none,
            suggestedFilename: nil,
            mimeType: cleanMime,
            reason: "Standard navigatable resource"
        )
    }

    // MARK: - RFC 6266 & RFC 5987 Content-Disposition Parser

    /// Parses a Content-Disposition header string to extract attachment status and filename.
    ///
    /// Implements RFC 6266 section 4.3 precedence (filename* takes precedence over filename).
    public static func parseContentDisposition(_ disposition: String) -> (isAttachment: Bool, filename: String?) {
        let trimmed = disposition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, nil) }

        // Determine if disposition type is attachment
        let lower = trimmed.lowercased()
        let isAttachment = lower.contains("attachment")

        // 1. Check for filename*=charset'lang'encoded_value (RFC 5987 / 6266)
        var parsedStarFilename: String? = nil
        if let starRange = trimmed.range(of: "filename\\*\\s*=\\s*([^;]+)", options: .regularExpression) {
            let match = String(trimmed[starRange])
            if let equalsIdx = match.firstIndex(of: "=") {
                var rawValue = String(match[match.index(after: equalsIdx)...]).trimmingCharacters(in: .whitespaces)
                // Format: UTF-8''encoded_value or utf-8'en'encoded_value
                if let firstQuote = rawValue.firstIndex(of: "'"),
                   let secondQuote = rawValue[rawValue.index(after: firstQuote)...].firstIndex(of: "'") {
                    rawValue = String(rawValue[rawValue.index(after: secondQuote)...])
                }
                rawValue = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let decoded = rawValue.removingPercentEncoding, !decoded.isEmpty {
                    parsedStarFilename = sanitizeFilename(decoded)
                } else if !rawValue.isEmpty {
                    parsedStarFilename = sanitizeFilename(rawValue)
                }
            }
        }

        // 2. Check for standard filename="value" or filename=value
        var parsedStandardFilename: String? = nil
        if let stdRange = trimmed.range(of: "filename\\s*=\\s*(\"[^\"]+\"|[^;\\s]+)", options: .regularExpression) {
            let match = String(trimmed[stdRange])
            if let equalsIdx = match.firstIndex(of: "=") {
                var rawValue = String(match[match.index(after: equalsIdx)...]).trimmingCharacters(in: .whitespaces)
                rawValue = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let decoded = rawValue.removingPercentEncoding, !decoded.isEmpty {
                    parsedStandardFilename = sanitizeFilename(decoded)
                } else if !rawValue.isEmpty {
                    parsedStandardFilename = sanitizeFilename(rawValue)
                }
            }
        }

        // RFC 6266 section 4.3: filename* MUST take precedence over filename
        let resolvedFilename = parsedStarFilename ?? parsedStandardFilename
        return (isAttachment, resolvedFilename)
    }

    // MARK: - Extension & Filename Helpers

    /// Extracts the lowercase file extension from a URL, stripping query parameters.
    public static func extractURLExtension(from url: URL) -> String? {
        let path = url.path
        guard !path.isEmpty && path != "/" else { return nil }

        let lastComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dotIndex = lastComponent.lastIndex(of: "."),
              dotIndex != lastComponent.startIndex,
              dotIndex != lastComponent.index(before: lastComponent.endIndex) else {
            return nil
        }

        let ext = String(lastComponent[lastComponent.index(after: dotIndex)...])
        let cleanExt = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleanExt.isEmpty ? nil : cleanExt
    }

    /// Sanitizes a filename, removing illegal filesystem characters and directory traversal attempts.
    public static func sanitizeFilename(_ name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove path traversal (e.g. ../../file.zip)
        cleaned = cleaned.replacingOccurrences(of: "\\", with: "/")
        if let lastPart = cleaned.split(separator: "/").last {
            cleaned = String(lastPart)
        }

        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\":<>")
            .union(.controlCharacters)
            .union(.newlines)

        let components = cleaned.components(separatedBy: invalidCharacters)
        cleaned = components.filter { !$0.isEmpty }.joined(separator: "_")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "download.bin" : cleaned
    }

    /// Generates a suggested filename from URL path and optional MIME type.
    public static func suggestedFilenameFromURL(_ url: URL, mimeType: String?) -> String {
        let lastComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastComponent.isEmpty && lastComponent != "/" && lastComponent.contains(".") {
            let sanitized = sanitizeFilename(lastComponent)
            if !sanitized.isEmpty && sanitized != "download.bin" {
                return sanitized
            }
        }

        // Fallback to MIME type extension
        if let mime = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
           let ext = fileExtension(forMimeType: mime) {
            let base = !lastComponent.isEmpty && lastComponent != "/" ? sanitizeFilename(lastComponent) : "download"
            return "\(base).\(ext)"
        }

        if let host = url.host, !host.isEmpty {
            let cleanHost = host.replacingOccurrences(of: ".", with: "_")
            return "download_\(cleanHost).bin"
        }

        return "download.bin"
    }

    /// Maps common downloadable MIME types to default file extensions.
    public static func fileExtension(forMimeType mimeType: String) -> String? {
        let mapping: [String: String] = [
            "application/zip": "zip",
            "application/x-zip-compressed": "zip",
            "application/x-7z-compressed": "7z",
            "application/x-rar-compressed": "rar",
            "application/vnd.rar": "rar",
            "application/x-tar": "tar",
            "application/gzip": "gz",
            "application/x-gzip": "gz",
            "application/x-bzip2": "bz2",
            "application/x-xz": "xz",
            "application/pdf": "pdf",
            "application/epub+zip": "epub",
            "application/vnd.android.package-archive": "apk",
            "application/x-apple-diskimage": "dmg",
            "application/x-msdownload": "exe",
            "application/x-msdos-program": "exe",
            "application/x-bittorrent": "torrent",
            "application/x-iso9660-image": "iso",
            "video/mp4": "mp4",
            "video/x-matroska": "mkv",
            "video/webm": "webm",
            "video/quicktime": "mov",
            "video/x-msvideo": "avi",
            "audio/mpeg": "mp3",
            "audio/mp4": "m4a",
            "audio/x-wav": "wav",
            "audio/flac": "flac",
            "audio/aac": "aac",
            "audio/ogg": "ogg"
        ]
        return mapping[mimeType]
    }
}
