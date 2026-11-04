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
            if requestPath != cookiePath {
                guard requestPath.hasPrefix(cookiePath) else { return false }
                if !cookiePath.hasSuffix("/") {
                    let nextIndex = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
                    guard nextIndex < requestPath.endIndex && requestPath[nextIndex] == "/" else {
                        return false
                    }
                }
            }
        }

        // Expiry matching
        if let expires = expiresDate {
            guard expires > Date() else { return false }
        }

        return true
    }
}

// MARK: - BrowserSessionSnapshot

/// Snapshot of the active browser session containing authentic User-Agent, language, origin, and uncollapsed cookies.
public struct BrowserSessionSnapshot: Sendable, Equatable {
    public let userAgent: String
    public let acceptLanguage: String
    public let allCookies: [HTTPCookie]
    public let pageURL: URL?

    public var pageOrigin: String? {
        guard let pageURL, let scheme = pageURL.scheme, let host = pageURL.host else { return nil }
        if let port = pageURL.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    public var cookiesByDomain: [String: [HTTPCookie]] {
        Dictionary(grouping: allCookies, by: { $0.domain.lowercased() })
    }

    public init(
        userAgent: String,
        acceptLanguage: String,
        allCookies: [HTTPCookie] = [],
        pageURL: URL? = nil
    ) {
        self.userAgent = userAgent
        self.acceptLanguage = acceptLanguage
        self.allCookies = allCookies
        self.pageURL = pageURL
    }
}

// MARK: - DownloadRequestEnricher

/// Enriches outbound engine requests with authentic browser session headers, context metadata, and Cloudflare verification tokens.
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
    /// Captures the authentic User-Agent, preferred language, current page URL, and all cookies from the WKWebView.
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
            allCookies: cookies,
            pageURL: webView.url
        )
        sharedSessionSnapshot.snapshot = snapshot
        print("[DownloadRequestEnricher] Snapshot captured: \(cookies.count) cookies, User-Agent: '\(ua)', pageURL: \(webView.url?.absoluteString ?? "nil")")
        return snapshot
    }

    /// Fetches the freshest cookies directly from WKWebsiteDataStore.default().httpCookieStore.getAllCookies()
    /// and filters them by RFC 6265 rules (domain, path, security, and expiry) for the target URL.
    @MainActor
    public static func fetchDynamicCookies(for url: URL) async -> [HTTPCookie] {
        let allCookies: [HTTPCookie] = await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }
        let matching = allCookies.filter { $0.matches(url: url) }
        for cookie in matching {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        if let host = url.host {
            KeychainManager.shared.storeCookies(matching, domain: host)
        }
        return matching
    }
    #endif

    /// Asynchronously fetches dynamic cookies from the browser data store right before dispatching a network request.
    /// Falls back to KeychainManager or HTTPCookieStorage.shared if WebKit is unavailable.
    public static func dynamicCookies(for url: URL) async -> [HTTPCookie] {
        #if canImport(WebKit)
        let cookies = await fetchDynamicCookies(for: url)
        if !cookies.isEmpty {
            return cookies
        }
        #endif

        if let host = url.host {
            let keychainCookies = KeychainManager.shared.getCookies(domain: host)
            let matchingKeychain = keychainCookies.filter { $0.matches(url: url) }
            if !matchingKeychain.isEmpty {
                return matchingKeychain
            }
        }

        if let shared = HTTPCookieStorage.shared.cookies(for: url), !shared.isEmpty {
            return shared.filter { $0.matches(url: url) }
        }

        return []
    }

    /// Asynchronously enriches outbound engine requests with dynamically fetched cookies from WKWebsiteDataStore
    /// right before a network request is dispatched, preventing failures when tokens rotate mid-download.
    public static func enrichAsync(
        _ request: URLRequest,
        snapshot: BrowserSessionSnapshot? = nil,
        context: BrowserRequestContext? = nil
    ) async -> URLRequest {
        var req = enrich(request, snapshot: snapshot, context: context)
        guard let url = req.url else { return req }

        let freshCookies = await dynamicCookies(for: url)
        if !freshCookies.isEmpty {
            let fields = HTTPCookie.requestHeaderFields(with: freshCookies)
            if let cookieHeader = fields["Cookie"], !cookieHeader.isEmpty {
                req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
        }
        return req
    }

    /// Applies session snapshot to an outbound URLRequest using RFC 6265 cookie matching and authentic browser context headers.
    /// Idempotent. Does NOT overwrite headers already set by the caller.
    public static func enrich(
        _ request: URLRequest,
        snapshot: BrowserSessionSnapshot? = nil,
        context: BrowserRequestContext? = nil
    ) -> URLRequest {
        var req = request
        guard let url = req.url, let host = url.host else { return req }

        let effectiveSnapshot = snapshot ?? (context != nil ? nil : sharedSessionSnapshot.snapshot)

        if let s = effectiveSnapshot {
            if req.value(forHTTPHeaderField: "User-Agent") == nil && !s.userAgent.isEmpty {
                req.setValue(s.userAgent, forHTTPHeaderField: "User-Agent")
            }
            if req.value(forHTTPHeaderField: "Accept-Language") == nil && !s.acceptLanguage.isEmpty {
                req.setValue(s.acceptLanguage, forHTTPHeaderField: "Accept-Language")
            }
            if req.value(forHTTPHeaderField: "Accept") == nil {
                req.setValue("*/*", forHTTPHeaderField: "Accept")
            }
            let isDowngrade: Bool = {
                guard let page = s.pageURL,
                      let pageScheme = page.scheme?.lowercased(),
                      let targetScheme = url.scheme?.lowercased() else { return false }
                return pageScheme == "https" && targetScheme == "http"
            }()

            if req.value(forHTTPHeaderField: "Origin") == nil, let origin = s.pageOrigin, !isDowngrade {
                req.setValue(origin, forHTTPHeaderField: "Origin")
            }
            if req.value(forHTTPHeaderField: "Referer") == nil, let page = s.pageURL, !isDowngrade {
                req.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
            }
            if req.value(forHTTPHeaderField: "Sec-Fetch-Dest") == nil {
                req.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
            }
            if req.value(forHTTPHeaderField: "Sec-Fetch-Mode") == nil {
                req.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            }
            if req.value(forHTTPHeaderField: "Sec-Fetch-Site") == nil, let page = s.pageURL, let pageHost = page.host {
                if host.lowercased() == pageHost.lowercased() {
                    req.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
                } else if BrowserHeaderFilter.isSameSiteOrSubdomain(page, url) {
                    req.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
                } else {
                    req.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
                }
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

        if let ctx = context {
            if req.value(forHTTPHeaderField: "User-Agent") == nil, let ua = ctx.userAgent, !ua.isEmpty {
                req.setValue(ua, forHTTPHeaderField: "User-Agent")
            }
            let isDowngrade: Bool = {
                guard let page = ctx.pageURL,
                      let pageScheme = page.scheme?.lowercased(),
                      let targetScheme = url.scheme?.lowercased() else { return false }
                return pageScheme == "https" && targetScheme == "http"
            }()

            if req.value(forHTTPHeaderField: "Origin") == nil, let origin = ctx.origin, !isDowngrade {
                req.setValue(origin, forHTTPHeaderField: "Origin")
            }
            if req.value(forHTTPHeaderField: "Referer") == nil, !isDowngrade {
                if let ref = ctx.referer {
                    if let refURL = URL(string: ref), refURL.scheme?.lowercased() == "https" && url.scheme?.lowercased() == "http" {
                        // Suppress downgrade referer
                    } else {
                        req.setValue(ref, forHTTPHeaderField: "Referer")
                    }
                } else if let pageStr = ctx.pageURL?.absoluteString {
                    req.setValue(pageStr, forHTTPHeaderField: "Referer")
                }
            }
            if req.value(forHTTPHeaderField: "Cookie") == nil {
                let matching = ctx.cookies.filter { $0.matches(url: url) }
                if !matching.isEmpty {
                    let httpCookies = matching.compactMap { $0.toHTTPCookie() }
                    let fields = HTTPCookie.requestHeaderFields(with: httpCookies)
                    if let cookieValue = fields["Cookie"] {
                        req.setValue(cookieValue, forHTTPHeaderField: "Cookie")
                    }
                }
            }
        }

        // Fallback: if Cookie header is still absent and no explicit context was provided, consult HTTPCookieStorage.shared
        if req.value(forHTTPHeaderField: "Cookie") == nil && context == nil {
            if let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
                let fields = HTTPCookie.requestHeaderFields(with: cookies)
                if let cookieValue = fields["Cookie"] {
                    req.setValue(cookieValue, forHTTPHeaderField: "Cookie")
                }
            }
        }

        return req
    }

    /// Prepares an enriched redirect request for URLSessionTaskDelegate redirection callbacks,
    /// preserving Range headers, injecting authentic browser context and cookies for the redirect target.
    /// Strips Authorization and sensitive headers on cross-origin redirects, and isolates cookies (RFC 7235 / RFC 6265).
    public static func handleRedirect(
        task: URLSessionTask,
        response: HTTPURLResponse,
        newRequest: URLRequest,
        snapshot: BrowserSessionSnapshot? = nil
    ) -> URLRequest {
        var req = newRequest
        let sourceURL = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url

        if let sourceURL, let targetURL = req.url {
            let isSameOrigin = BrowserHeaderFilter.sameOrigin(sourceURL, targetURL)
            let isSameSite = BrowserHeaderFilter.isSameSiteOrSubdomain(sourceURL, targetURL)

            // 1. Cross-origin credential stripping (RFC 7235 §2.2 / RFC 9110 §15.4)
            if !isSameOrigin {
                req.setValue(nil, forHTTPHeaderField: "Authorization")
                req.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
                if let allHeaders = req.allHTTPHeaderFields {
                    for (k, _) in allHeaders {
                        if BrowserHeaderFilter.isSensitiveHeader(k) {
                            req.setValue(nil, forHTTPHeaderField: k)
                        }
                    }
                }
            }

            // 2. Cookie isolation across domains (RFC 6265 §5.4):
            // If redirecting cross-site, clear stale/sensitive origin cookies so target domain cookies can be applied.
            if !isSameSite {
                req.setValue(nil, forHTTPHeaderField: "Cookie")
            }

            // 3. Referer security: strip on HTTPS -> HTTP downgrade or cross-site redirect (RFC 7231 §5.5.2)
            if let srcScheme = sourceURL.scheme?.lowercased(),
               let dstScheme = targetURL.scheme?.lowercased(),
               (srcScheme == "https" && dstScheme == "http") || !isSameSite {
                req.setValue(nil, forHTTPHeaderField: "Referer")
            }
        }

        var enriched = enrich(req, snapshot: snapshot)

        // Preserve Range across redirect if present on the original request
        if let originalRange = task.originalRequest?.value(forHTTPHeaderField: "Range"),
           enriched.value(forHTTPHeaderField: "Range") == nil {
            enriched.setValue(originalRange, forHTTPHeaderField: "Range")
        }

        // Record any Set-Cookie headers from the redirect response for cookie rotation
        if let url = response.url ?? task.currentRequest?.url {
            var stringHeaders: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    stringHeaders[k] = v
                } else if let k = key as? String {
                    stringHeaders[k] = String(describing: value)
                }
            }
            if !stringHeaders.isEmpty {
                recordResponseCookies(headers: stringHeaders, for: url)
            }
        }

        return enriched
    }

    /// Evaluates ETag and Last-Modified to produce a compliant `If-Range` header value (RFC 7233 §3.2, RFC 9110 §13.1.5).
    ///
    /// RFC 7233 §3.2 states:
    /// "A client MUST NOT generate an If-Range header field containing a weak entity tag."
    /// "An origin server MUST NOT use a weak validator for range requests..."
    /// "If the client has only a weak entity tag for the representation, it MUST NOT use it in an If-Range header field.
    /// It MAY use a 1-second-resolution Last-Modified date instead, if available."
    public static func ifRangeValidator(eTag: String?, lastModified: String?) -> String? {
        if let rawETag = eTag?.trimmingCharacters(in: .whitespacesAndNewlines), !rawETag.isEmpty {
            let isWeak = rawETag.hasPrefix("W/") || rawETag.hasPrefix("w/")
            if !isWeak {
                return rawETag
            }
        }
        if let lm = lastModified?.trimmingCharacters(in: .whitespacesAndNewlines), !lm.isEmpty {
            return lm
        }
        return nil
    }

    /// Writes back any rotated cookies from HTTP response headers (e.g. Set-Cookie) into HTTPCookieStorage.shared and Keychain.
    public static func recordResponseCookies(headers: [String: String], for url: URL) {
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !cookies.isEmpty else { return }
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        if let host = url.host {
            KeychainManager.shared.storeCookies(cookies, domain: host)
        }
    }
}
