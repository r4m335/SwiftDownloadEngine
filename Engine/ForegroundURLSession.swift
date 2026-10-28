import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds the foreground URLSession used by range downloads.
///
/// Foreground downloads attach browser/session cookies to each request
/// themselves, so URLSession must not maintain an independent cookie jar.
/// The cache is also disabled because a cached response cannot safely satisfy
/// a byte-range request whose validator or byte offsets may have changed.
enum ForegroundURLSession {
    static let maximumRangeWorkers = SegmentAllocator.maxThreadCount

    static func make(maximumConnectionsPerHost: Int = maximumRangeWorkers) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = max(1, maximumConnectionsPerHost)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30.0
        configuration.timeoutIntervalForResource = 300.0
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }
}
