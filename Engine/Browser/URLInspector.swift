import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Classification outcome of inspecting a user-supplied URL prior to initiating a download.
public struct URLInspectionResult: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Direct downloadable file (e.g. zip, pdf, dmg, apk).
        case directDownload(filename: String, ext: String, mimeType: String?, size: Int64?)
        /// Playable video or audio file (e.g. mp4, mp3, m4a, webm).
        case playableMedia(url: URL, filename: String, ext: String, mimeType: String?, size: Int64?)
        /// Adaptive streaming manifest (HLS .m3u8 or DASH .mpd).
        case streamingManifest(kind: StreamingManifestKind, url: URL, variantsCount: Int, qualitySummary: String?)
        /// Normal navigatable HTML web page (should be opened in browser, not downloaded).
        case ordinaryWebpage(url: URL, title: String?)
        /// Unsupported or unidentifiable URL scheme/resource.
        case unknown(url: URL, reason: String)
    }

    public let url: URL
    public let kind: Kind
    public let suggestedBaseFilename: String
    public let suggestedExtension: String
    public let estimatedSize: Int64?
    public let mimeType: String?

    public init(
        url: URL,
        kind: Kind,
        suggestedBaseFilename: String,
        suggestedExtension: String,
        estimatedSize: Int64? = nil,
        mimeType: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.suggestedBaseFilename = suggestedBaseFilename
        self.suggestedExtension = suggestedExtension
        self.estimatedSize = estimatedSize
        self.mimeType = mimeType
    }
}

/// Pure Swift URL inspector that analyzes incoming user URLs without starting a download,
/// distinguishing between playable media, adaptive streams, direct downloads, and ordinary web pages.
public actor URLInspector {

    public static let shared = URLInspector()

    private static let directPlayableExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "avi",
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"
    ]

    private static let webPageExtensions: Set<String> = [
        "html", "htm", "shtml", "php", "asp", "aspx", "jsp"
    ]

    /// Inspects a URL asynchronously using extension heuristics, manifest classifiers,
    /// and a lightweight probe if needed.
    public func inspect(url: URL, session: URLSession = .shared) async -> URLInspectionResult {
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        let (base, _) = FilenameExtensionHelper.split(filename: filename)
        let safeBase = base.isEmpty ? "download" : base

        // 1. Check scheme
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" || scheme == "blob" else {
            return URLInspectionResult(
                url: url,
                kind: .unknown(url: url, reason: "Unsupported protocol '\(scheme)'. Supported: http, https, blob."),
                suggestedBaseFilename: safeBase,
                suggestedExtension: ext
            )
        }

        // 2. Check for HLS or DASH manifests by extension
        let manifestClassification = StreamingManifestClassifier.classify(url: url)
        if manifestClassification.isManifest || ext == "m3u8" || ext == "mpd" {
            let kind: StreamingManifestKind = (ext == "mpd" || manifestClassification.kind == .dash) ? .dash : .hls
            // Quick synchronous / shallow inspection
            let qualitySummary: String? = {
                if ext == "m3u8" || kind == .hls {
                    return "Multi-quality HLS stream"
                } else {
                    return "MPEG-DASH stream"
                }
            }()
            return URLInspectionResult(
                url: url,
                kind: .streamingManifest(kind: kind, url: url, variantsCount: 1, qualitySummary: qualitySummary),
                suggestedBaseFilename: safeBase,
                suggestedExtension: "mp4", // Reconstructed container
                mimeType: kind == .hls ? "application/vnd.apple.mpegurl" : "application/dash+xml"
            )
        }

        // 3. Check for direct playable media by extension
        if Self.directPlayableExtensions.contains(ext) {
            return URLInspectionResult(
                url: url,
                kind: .playableMedia(url: url, filename: filename, ext: ext, mimeType: nil, size: nil),
                suggestedBaseFilename: safeBase,
                suggestedExtension: ext
            )
        }

        // 4. Check for direct downloadable archive or document by extension
        if BrowserDownloadClassifier.downloadableExtensions.contains(ext) {
            return URLInspectionResult(
                url: url,
                kind: .directDownload(filename: filename, ext: ext, mimeType: nil, size: nil),
                suggestedBaseFilename: safeBase,
                suggestedExtension: ext
            )
        }

        // 5. Check for explicit HTML webpage extension
        if Self.webPageExtensions.contains(ext) {
            return URLInspectionResult(
                url: url,
                kind: .ordinaryWebpage(url: url, title: nil),
                suggestedBaseFilename: safeBase,
                suggestedExtension: ext
            )
        }

        // 6. For URLs without clear extension (e.g. root domains, API endpoints), perform a probe with short timeout
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 2.5
        request = DownloadRequestEnricher.enrich(request)

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                let mime = http.mimeType?.lowercased() ?? ""
                let length = http.expectedContentLength > 0 ? http.expectedContentLength : nil

                // Content-Disposition check
                let disposition = http.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                let isAttachment = disposition.lowercased().contains("attachment")

                if mime.contains("text/html") || mime.contains("application/xhtml") {
                    if !isAttachment {
                        return URLInspectionResult(
                            url: url,
                            kind: .ordinaryWebpage(url: url, title: nil),
                            suggestedBaseFilename: safeBase,
                            suggestedExtension: "html",
                            estimatedSize: length,
                            mimeType: mime
                        )
                    }
                }

                if mime.contains("mpegurl") || mime.contains("m3u8") {
                    return URLInspectionResult(
                        url: url,
                        kind: .streamingManifest(kind: .hls, url: url, variantsCount: 1, qualitySummary: "HLS Stream"),
                        suggestedBaseFilename: safeBase,
                        suggestedExtension: "mp4",
                        estimatedSize: length,
                        mimeType: mime
                    )
                }

                if mime.contains("dash") || mime.contains("mpd") {
                    return URLInspectionResult(
                        url: url,
                        kind: .streamingManifest(kind: .dash, url: url, variantsCount: 1, qualitySummary: "DASH Stream"),
                        suggestedBaseFilename: safeBase,
                        suggestedExtension: "mp4",
                        estimatedSize: length,
                        mimeType: mime
                    )
                }

                if mime.hasPrefix("video/") || mime.hasPrefix("audio/") {
                    let inferredExt = FilenameExtensionHelper.detectExtension(from: url, mimeType: mime)
                    return URLInspectionResult(
                        url: url,
                        kind: .playableMedia(url: url, filename: filename, ext: inferredExt.isEmpty ? "mp4" : inferredExt, mimeType: mime, size: length),
                        suggestedBaseFilename: safeBase,
                        suggestedExtension: inferredExt.isEmpty ? "mp4" : inferredExt,
                        estimatedSize: length,
                        mimeType: mime
                    )
                }

                if isAttachment || BrowserDownloadClassifier.downloadableMIMETypes.contains(mime) {
                    let inferredExt = FilenameExtensionHelper.detectExtension(from: url, mimeType: mime)
                    return URLInspectionResult(
                        url: url,
                        kind: .directDownload(filename: filename, ext: inferredExt, mimeType: mime, size: length),
                        suggestedBaseFilename: safeBase,
                        suggestedExtension: inferredExt,
                        estimatedSize: length,
                        mimeType: mime
                    )
                }
            }
        } catch {
            // Head probe failed or timed out; fall back gracefully
        }

        // If URL has no path extension and looks like a website (e.g. https://example.com/some-page)
        if ext.isEmpty {
            return URLInspectionResult(
                url: url,
                kind: .ordinaryWebpage(url: url, title: nil),
                suggestedBaseFilename: safeBase,
                suggestedExtension: ""
            )
        }

        return URLInspectionResult(
            url: url,
            kind: .unknown(url: url, reason: "Resource format could not be verified automatically."),
            suggestedBaseFilename: safeBase,
            suggestedExtension: ext
        )
    }
}
