import Foundation

/// Canonical classification of a URL for downloading.
public enum DownloadURLClassification: Sendable, Equatable {
    /// Standard direct HTTP/HTTPS resource that can be probed and downloaded via network range streams.
    case directHTTP(URL)
    /// In-memory browser Blob URL that cannot be retrieved over HTTP and must use `BrowserBlobCaptureService`.
    case mustUseBlobCaptureService(URL)
    /// Unsupported or missing scheme.
    case unsupported(scheme: String, raw: URL)
}

/// Single source of truth for URL scheme and destination routing across all engine and UI layers.
public enum DownloadURLPolicy {
    public static func classify(_ url: URL) -> DownloadURLClassification {
        guard let scheme = url.scheme?.lowercased() else {
            return .unsupported(scheme: "", raw: url)
        }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else {
                return .unsupported(scheme: scheme, raw: url)
            }
            return .directHTTP(url)
        case "blob":
            return .mustUseBlobCaptureService(url)
        default:
            return .unsupported(scheme: scheme, raw: url)
        }
    }
}
