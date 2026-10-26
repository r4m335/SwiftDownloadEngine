import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(WebKit)
import WebKit
#endif

// MARK: - HTTPCookie URL Matching (RFC 6265)

extension HTTPCookie {
    /// Evaluates whether this cookie should be sent to the target URL based on RFC 6265 domain, path, secure, and expiry rules.
    public func matches(url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }

        // Domain matching (RFC 6265 §5.1.3)
        var cookieDomain = domain.lowercased()
        if cookieDomain.hasPrefix(".") {
            cookieDomain = String(cookieDomain.dropFirst())
        }
        let domainMatches = (host == cookieDomain) || host.hasSuffix("." + cookieDomain)
        guard domainMatches else { return false }

        // Secure matching (RFC 6265 §5.4)
        if isSecure {
            let scheme = url.scheme?.lowercased() ?? "http"
            guard scheme == "https" else { return false }
        }

        // Path matching (RFC 6265 §5.1.4)
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = path.isEmpty ? "/" : path
        if cookiePath != "/" {
            guard requestPath.hasPrefix(cookiePath) else { return false }
        }

        // Expiry matching
        if let expires = expiresDate {
            guard expires > Date() else { return false }
        }

        return true
    }
}

// MARK: - BrowserSessionSnapshot

/// Snapshot of the active browser session containing authentic User-Agent, language, and uncollapsed cookies.
public struct BrowserSessionSnapshot: Sendable, Equatable {
    public let userAgent: String
    public let acceptLanguage: String
    public let allCookies: [HTTPCookie]

    public init(
        userAgent: String,
        acceptLanguage: String,
        allCookies: [HTTPCookie] = []
    ) {
        self.userAgent = userAgent
        self.acceptLanguage = acceptLanguage
        self.allCookies = allCookies
    }
}

// MARK: - DownloadRequestEnricher

/// Enriches outbound engine requests with authentic browser session headers and Cloudflare verification tokens.
public enum DownloadRequestEnricher {

    /// Thread-safe holder for the latest active browser session snapshot.
    public final class SnapshotHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _snapshot: BrowserSessionSnapshot?

        public init(snapshot: BrowserSessionSnapshot? = nil) {
            self._snapshot = snapshot
        }

        public var snapshot: BrowserSessionSnapshot? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _snapshot
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _snapshot = newValue
            }
        }
    }

    /// Shared session snapshot updated by `BrowserView` when navigations complete or when downloads start.
    public static let sharedSessionSnapshot = SnapshotHolder()

    #if canImport(WebKit)
    /// Captures the authentic User-Agent, preferred language, and all cookies from the WKWebView.
    @MainActor
    public static func snapshot(from webView: WKWebView) async -> BrowserSessionSnapshot {
        let ua: String
        if let custom = webView.customUserAgent, !custom.isEmpty {
            ua = custom
        } else if let evaluated = try? await webView.evaluateJavaScript("navigator.userAgent") as? String, !evaluated.isEmpty {
            ua = evaluated
        } else {
            ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        }

        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }

        // Synchronize all cookies to HTTPCookieStorage.shared as a fallback cache
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        let language = Locale.preferredLanguages.first ?? "en-US"

        let snapshot = BrowserSessionSnapshot(
            userAgent: ua,
            acceptLanguage: language,
            allCookies: cookies
        )
        sharedSessionSnapshot.snapshot = snapshot
        return snapshot
    }
    #endif

    /// Applies session snapshot to an outbound URLRequest using RFC 6265 cookie matching per URL.
    /// Idempotent. Does NOT overwrite headers already set by the caller.
    public static func enrich(_ request: URLRequest, snapshot: BrowserSessionSnapshot? = nil) -> URLRequest {
        var req = request
        guard let url = req.url, let _ = url.host else { return req }

        let effectiveSnapshot = snapshot ?? sharedSessionSnapshot.snapshot

        if let s = effectiveSnapshot {
            if req.value(forHTTPHeaderField: "User-Agent") == nil && !s.userAgent.isEmpty {
                req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
            }
            if req.value(forHTTPHeaderField: "Accept-Language") == nil && !s.acceptLanguage.isEmpty {
                req.setValue(s.acceptLanguage, forHTTPHeaderField: "Accept-Language")
            }
            if req.value(forHTTPHeaderField: "Cookie") == nil && !s.allCookies.isEmpty {
                let matching = s.allCookies.filter { $0.matches(url: url) }
                if !matching.isEmpty {
                    let fields = HTTPCookie.requestHeaderFields(with: matching)
                    if let cookieValue = fields["Cookie"] {
                        req.setValue(cookieValue, forHTTPHeaderField: "Cookie")
                    }
                }
            }
        }

        // Fallback: if Cookie header is still absent, consult HTTPCookieStorage.shared
        if req.value(forHTTPHeaderField: "Cookie") == nil {
            if let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
                let fields = HTTPCookie.requestHeaderFields(with: cookies)
                if let cookieValue = fields["Cookie"] {
                    req.setValue(cookieValue, forHTTPHeaderField: "Cookie")
                }
            }
        }

        return req
    }

    /// Writes back any rotated cookies from HTTP response headers (e.g. Set-Cookie) into HTTPCookieStorage.shared.
    public static func recordResponseCookies(headers: [String: String], for url: URL) {
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}
