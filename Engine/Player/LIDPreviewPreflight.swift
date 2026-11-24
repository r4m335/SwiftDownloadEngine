import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Comprehensive preflight validation errors with actionable diagnostic descriptions.
public enum LIDPreviewPreflightError: LocalizedError, Equatable, Sendable {
    case fileNotFound(URL)
    case fileEmpty(URL)
    case invalidContainerHeader(URL, reason: String)
    case blobResourceUnsupported
    case segmentChunkUnsupported
    case drmProtected(type: String)
    case tokenExpired(URL)
    case unsupportedFormat(String)
    case invalidManifest(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Media file does not exist on disk: \(url.lastPathComponent)"
        case .fileEmpty(let url):
            return "Media file is empty (0 bytes): \(url.lastPathComponent)"
        case .invalidContainerHeader(let url, let reason):
            return "Media container corrupted in \(url.lastPathComponent): \(reason)"
        case .blobResourceUnsupported:
            return "Browser blob media cannot be previewed in external player. Please download it directly."
        case .segmentChunkUnsupported:
            return "This is a streaming segment chunk. Download the playlist manifest (.m3u8 or .mpd) instead."
        case .drmProtected(let type):
            return "This media stream is encrypted with Digital Rights Management (\(type)) and cannot be played directly."
        case .tokenExpired:
            return "The signed access token or stream authorization for this media has expired. Refreshing token..."
        case .unsupportedFormat(let format):
            return "Unsupported media format for preview: \(format)"
        case .invalidManifest(let reason):
            return "Invalid stream manifest: \(reason)"
        }
    }
}

/// Dedicated preflight validation and context propagation engine for media playback and preview.
/// Validates file integrity, DRM protection, segment classification, signed URL token freshness,
/// and synchronizes origin-matched session cookies across the entire media request graph.
public enum LIDPreviewPreflight {

    /// Recognized media format file extensions supported by AVFoundation or VLCKit.
    public static let supportedMediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "flv", "vob", "ogv", "ogg", "wmv",
        "3gp", "3g2", "ts", "mts", "m2ts", "mp3", "m4a", "aac", "wav", "flac", "alac",
        "aiff", "caf", "opus", "wma", "m3u8", "mpd"
    ]

    /// Returns whether the provided file extension represents playable media.
    public static func isMediaExtension(_ ext: String) -> Bool {
        let lower = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return supportedMediaExtensions.contains(lower)
    }

    /// Returns whether the given file or remote URL corresponds to playable media.
    public static func isMediaURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if isMediaExtension(ext) { return true }
        let pathLower = url.path.lowercased()
        if pathLower.hasSuffix(".m3u8") || pathLower.hasSuffix(".mpd") { return true }
        return false
    }

    // MARK: - Request Context Propagation

    /// Propagates origin-matched session cookies from `BrowserRequestContext` into `HTTPCookieStorage.shared`.
    /// This ensures child variant playlists, encryption key requests, alternate audio/caption tracks,
    /// and transport stream segments inherit valid session credentials across redirects and sub-requests.
    public static func propagateRequestContext(_ context: BrowserRequestContext?, targetURL: URL? = nil) {
        guard let context = context, !context.cookies.isEmpty else { return }
        let cookieStorage = HTTPCookieStorage.shared

        for cookie in context.cookies {
            if let httpCookie = cookie.toHTTPCookie() {
                cookieStorage.setCookie(httpCookie)
            }
        }
    }

    // MARK: - WebpageResource Preflight

    /// Validates a discovered `WebpageResource` prior to opening in the native player.
    /// Checks DRM protection, blob containment, segment chunk status, token expiration,
    /// manifest validity, and propagates session cookies to the shared HTTP storage.
    public static func preflight(
        resource: WebpageResource,
        title: String? = nil,
        now: Date = Date()
    ) -> Result<LIDPlayerSource, LIDPreviewPreflightError> {
        // 1. DRM Protection Check
        if resource.isDRMProtected {
            let drmType = resource.drmProtectionType ?? "DRM"
            return .failure(.drmProtected(type: drmType))
        }

        // 2. Blob URL Check
        if resource.isBlobResource {
            return .failure(.blobResourceUnsupported)
        }

        // 3. Segment Chunk Check
        if resource.isSegmentChunk {
            return .failure(.segmentChunkUnsupported)
        }

        // 4. Token Expiration Check
        if resource.isExpired(now: now) {
            return .failure(.tokenExpired(resource.url))
        }

        // 5. Manifest DRM & Syntax Inspection
        if resource.isStreamingManifest {
            let ext = resource.url.pathExtension.lowercased()
            let mime = resource.mimeType?.lowercased() ?? ""
            let isDASH = ext == "mpd" || mime.contains("dash")

            if isDASH {
                if let manifestText = resource.manifestText, let data = manifestText.data(using: .utf8) {
                    if let inspection = try? LIDDASHStreamAdapter.inspect(
                        manifestData: data,
                        baseURL: resource.url,
                        preferredRepresentationID: resource.dashVideoRepresentationID
                    ) {
                        if inspection.hasDRM {
                            let details = inspection.drmDetails ?? "DASH ContentProtection"
                            return .failure(.drmProtected(type: details))
                        }
                    }
                }
            } else {
                // HLS Manifest Check
                if let manifestText = resource.manifestText {
                    if manifestText.contains("#EXT-X-KEY:") {
                        let upper = manifestText.uppercased()
                        if upper.contains("METHOD=SAMPLE-AES") || upper.contains("KEYFORMAT=\"COM.APPLE.STREAMINGKEYDELIVERY\"") || upper.contains("WIDEVINE") {
                            return .failure(.drmProtected(type: "FairPlay / Sample-AES DRM"))
                        }
                    }
                }
            }
        }

        // 6. Propagate cookies to shared storage for native AVPlayer / VLCKit stack
        propagateRequestContext(resource.requestContext, targetURL: resource.url)

        // 7. Assemble Player Source
        let displayTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? title!
            : (!resource.suggestedFilename.isEmpty ? resource.suggestedFilename : resource.title)

        guard let source = LIDPlayerSource.make(from: resource, title: displayTitle) else {
            return .failure(.unsupportedFormat(resource.mimeType ?? resource.resourceType.rawValue))
        }

        return .success(source)
    }

    // MARK: - BrowserMediaCandidate Preflight

    /// Validates a raw `BrowserMediaCandidate` prior to preview, converting to `WebpageResource` if needed.
    public static func preflight(
        candidate: BrowserMediaCandidate,
        title: String? = nil,
        now: Date = Date()
    ) -> Result<LIDPlayerSource, LIDPreviewPreflightError> {
        if candidate.isDRMProtected || candidate.kind == .protectedMedia {
            return .failure(.drmProtected(type: candidate.drmScheme ?? "DRM"))
        }

        if candidate.isBlob {
            return .failure(.blobResourceUnsupported)
        }

        if candidate.isExpired {
            let targetURL = candidate.finalURL ?? candidate.url ?? URL(string: candidate.rawURL) ?? URL(fileURLWithPath: "/")
            return .failure(.tokenExpired(targetURL))
        }

        guard let resource = candidate.toWebpageResource() else {
            return .failure(.unsupportedFormat("Unconvertible candidate"))
        }

        return preflight(resource: resource, title: title, now: now)
    }

    // MARK: - Local File Preflight

    /// Validates a local file URL on disk for existence, non-zero size, and valid container headers.
    public static func preflight(
        localFileURL: URL,
        title: String? = nil
    ) -> Result<LIDPlayerSource, LIDPreviewPreflightError> {
        let path = localFileURL.path
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: path) else {
            return .failure(.fileNotFound(localFileURL))
        }

        if let attrs = try? fileManager.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64, size == 0 {
            return .failure(.fileEmpty(localFileURL))
        }

        if localFileURL.pathExtension.lowercased() == "ts" {
            if !LIDPlaybackEngine.validateTSHeader(url: localFileURL) {
                return .failure(.invalidContainerHeader(localFileURL, reason: "Missing MPEG-2 TS 0x47 sync byte stride."))
            }
        }

        let displayTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? title!
            : localFileURL.lastPathComponent

        return .success(.localFile(url: localFileURL, title: displayTitle))
    }

    // MARK: - Standalone DASH Preflight

    /// Validates DASH manifest playback independently of download pipeline assembly.
    public static func preflightDASH(
        manifestURL: URL,
        manifestData: Data? = nil,
        selectedRepresentationID: String? = nil,
        requestContext: BrowserRequestContext? = nil,
        title: String? = nil
    ) -> Result<LIDPlayerSource, LIDPreviewPreflightError> {
        propagateRequestContext(requestContext, targetURL: manifestURL)

        if let data = manifestData {
            do {
                let inspection = try LIDDASHStreamAdapter.inspect(
                    manifestData: data,
                    baseURL: manifestURL,
                    preferredRepresentationID: selectedRepresentationID
                )
                if inspection.hasDRM {
                    return .failure(.drmProtected(type: inspection.drmDetails ?? "Widevine/PlayReady"))
                }
            } catch {
                return .failure(.invalidManifest(error.localizedDescription))
            }
        }

        let displayTitle = title ?? manifestURL.lastPathComponent
        return .success(.dashStream(
            manifestURL: manifestURL,
            selectedRepresentationID: selectedRepresentationID,
            title: displayTitle,
            requestContext: requestContext
        ))
    }
}
