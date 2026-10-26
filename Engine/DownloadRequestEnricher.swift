import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(WebKit)
import WebKit
#endif

/// Snapshot of the active browser session containing authentic User-Agent, language, and cookies.
public struct BrowserSessionSnapshot: Sendable, Equatable {
    public let userAgent: String
    public let acceptLanguage: String
    public let cookiesByDomain: [String: String]  // Registrable domain -> Cookie header value

    public init(
        userAgent: String,
        acceptLanguage: String,
        cookiesByDomain: [String: String]
    ) {
        self.userAgent = userAgent
        self.acceptLanguage = acceptLanguage
        self.cookiesByDomain = cookiesByDomain
    }
}

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

    /// Shared session snapshot updated by `BrowserView` when navigations complete.
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

        // Group all cookies by registrable domain
        var grouped: [String: [HTTPCookie]] = [:]
        for c in cookies {
            let key = registrableDomain(c.domain)
            grouped[key, default: []].append(c)
        }
        var headers: [String: String] = [:]
        for (domain, list) in grouped {
            let fields = HTTPCookie.requestHeaderFields(with: list)
            if let value = fields["Cookie"] {
                headers[domain] = value
            }
        }

        let language = Locale.preferredLanguages.first ?? "en-US"

        let snapshot = BrowserSessionSnapshot(
            userAgent: ua,
            acceptLanguage: language,
            cookiesByDomain: headers
        )
        sharedSessionSnapshot.snapshot = snapshot
        return snapshot
    }
    #endif

    /// Applies session snapshot to an outbound URLRequest.
    /// Idempotent. Does NOT overwrite headers already set by the caller.
    public static func enrich(_ request: URLRequest, snapshot: BrowserSessionSnapshot? = nil) -> URLRequest {
        var req = request
        guard let url = req.url, let host = url.host else { return req }

        let effectiveSnapshot = snapshot ?? sharedSessionSnapshot.snapshot

        if let s = effectiveSnapshot {
            if req.value(forHTTPHeaderField: "User-Agent") == nil && !s.userAgent.isEmpty {
                req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
            }
            if req.value(forHTTPHeaderField: "Accept-Language") == nil && !s.acceptLanguage.isEmpty {
                req.setValue(s.acceptLanguage, forHTTPHeaderField: "Accept-Language")
            }
            if req.value(forHTTPHeaderField: "Cookie") == nil {
                let regDomain = registrableDomain(host)
                if let cookieHeader = s.cookiesByDomain[regDomain] {
                    req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                } else if let exactCookie = s.cookiesByDomain[host.lowercased()] {
                    req.setValue(exactCookie, forHTTPHeaderField: "Cookie")
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

    /// Strips leading dots, normalizes to lowercase, and extracts the registrable domain (e.g. cdn.goplay.su -> goplay.su).
    public static func registrableDomain(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix(".") {
            h = String(h.dropFirst())
        }
        let parts = h.split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : h
    }

    /// Writes back any rotated cookies from HTTP response headers (e.g. Set-Cookie) into HTTPCookieStorage.shared.
    public static func recordResponseCookies(headers: [String: String], for url: URL) {
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}
