import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Represents the origin and trigger of a browser download request context.
public enum BrowserRequestContextSource: String, Sendable, Codable, Hashable {
    case directLink = "Direct Link"
    case webpageResource = "Webpage Resource"
    case nativeInterception = "Native Interception"
}

/// A decoupled, platform-agnostic HTTP cookie model for matching and forwarding session cookies.
public struct BrowserCookie: Sendable, Hashable, Codable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let isSecure: Bool
    public let isHTTPOnly: Bool
    public let isHostOnly: Bool
    public let expiresDate: Date?

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        isSecure: Bool = false,
        isHTTPOnly: Bool = false,
        isHostOnly: Bool = false,
        expiresDate: Date? = nil
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = value
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.domain = trimmedDomain
        self.path = path.isEmpty ? "/" : path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        // If domain explicitly begins with a dot (e.g. .example.com), RFC 6265 defines it as a domain cookie
        if trimmedDomain.hasPrefix(".") {
            self.isHostOnly = false
        } else {
            self.isHostOnly = isHostOnly
        }
        self.expiresDate = expiresDate
    }

    /// Convenience initializer from Foundation `HTTPCookie`.
    public init?(from httpCookie: HTTPCookie) {
        self.init(from: httpCookie, isHostOnly: nil)
    }

    /// Explicit initializer from Foundation `HTTPCookie` with optional host-only override.
    public init?(from httpCookie: HTTPCookie, isHostOnly: Bool?) {
        guard !httpCookie.name.isEmpty else { return nil }
        self.name = httpCookie.name
        self.value = httpCookie.value
        let trimmedDomain = httpCookie.domain.lowercased()
        self.domain = trimmedDomain
        self.path = httpCookie.path.isEmpty ? "/" : httpCookie.path
        self.isSecure = httpCookie.isSecure
        self.isHTTPOnly = httpCookie.isHTTPOnly
        if let explicit = isHostOnly {
            self.isHostOnly = trimmedDomain.hasPrefix(".") ? false : explicit
        } else {
            // In RFC 6265 and WebKit: domain cookies carry a leading dot, while host-only cookies do not
            self.isHostOnly = !trimmedDomain.hasPrefix(".")
        }
        self.expiresDate = httpCookie.expiresDate
    }

    /// Converts back to a Foundation `HTTPCookie` for session injection or URLRequest enrichment.
    public func toHTTPCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: isHostOnly ? (domain.hasPrefix(".") ? String(domain.dropFirst()) : domain) : (domain.hasPrefix(".") ? domain : "." + domain),
            .path: path
        ]
        if isSecure {
            properties[.secure] = "TRUE"
        }
        if let expiresDate {
            properties[.expires] = expiresDate
        }
        return HTTPCookie(properties: properties)
    }

    /// Evaluates if this cookie is eligible to be sent to the target URL per RFC 6265 with WebKit parity.
    public func matches(url: URL, now: Date = Date()) -> Bool {
        // 1. Expiration check
        if let exp = expiresDate, exp < now {
            return false
        }

        // 2. Secure flag check
        let scheme = url.scheme?.lowercased() ?? ""
        if isSecure && scheme != "https" {
            // WebKit and modern browser standards permit secure cookies over localhost / loopback
            let host = url.host?.lowercased() ?? ""
            let isLocalhost = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            if !isLocalhost {
                return false
            }
        }

        // 3. Domain matching (RFC 6265 §5.1.3 & §5.3 step 6)
        guard var host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if host.hasSuffix(".") {
            host = String(host.dropLast())
        }

        var cookieDomain = self.domain.hasPrefix(".") ? String(self.domain.dropFirst()) : self.domain
        if cookieDomain.hasSuffix(".") {
            cookieDomain = String(cookieDomain.dropLast())
        }

        if isHostOnly {
            // RFC 6265 §5.3 step 6: A host-only cookie matches if and only if the request host
            // is identical to the cookie's domain (subdomains are strictly rejected).
            if host != cookieDomain {
                return false
            }
        } else {
            // Domain-scoped cookie: matches exact domain or any valid subdomain
            if host != cookieDomain && !host.hasSuffix("." + cookieDomain) {
                return false
            }
        }

        // 4. Path matching (RFC 6265 §5.1.4)
        var cookiePath = self.path.isEmpty ? "/" : self.path
        if !cookiePath.hasPrefix("/") {
            cookiePath = "/" + cookiePath
        }
        var requestPath = url.path.isEmpty ? "/" : url.path
        // Foundation URL.path strips trailing slash; preserve it if URL path had a trailing slash
        let urlPathWithoutQuery = url.absoluteString.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url.absoluteString
        if urlPathWithoutQuery.hasSuffix("/") && !requestPath.hasSuffix("/") {
            requestPath += "/"
        }

        if cookiePath == "/" || requestPath == cookiePath {
            return true
        }
        // If cookiePath ends with a slash and requestPath equals cookiePath without that slash (e.g. /video/ vs /video)
        if cookiePath.hasSuffix("/") && requestPath == String(cookiePath.dropLast()) {
            return true
        }
        if requestPath.hasPrefix(cookiePath) {
            if cookiePath.hasSuffix("/") {
                return true
            }
            let nextCharIndex = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
            if nextCharIndex < requestPath.endIndex && requestPath[nextCharIndex] == "/" {
                return true
            }
        }
        // WebKit compatibility: Also evaluate percent-decoded paths
        if let decodedReq = requestPath.removingPercentEncoding,
           let decodedCookie = cookiePath.removingPercentEncoding,
           (decodedReq != requestPath || decodedCookie != cookiePath) {
            if decodedReq == decodedCookie {
                return true
            }
            if decodedCookie.hasSuffix("/") && decodedReq == String(decodedCookie.dropLast()) {
                return true
            }
            if decodedReq.hasPrefix(decodedCookie) {
                if decodedCookie.hasSuffix("/") {
                    return true
                }
                let nextCharIndex = decodedReq.index(decodedReq.startIndex, offsetBy: decodedCookie.count)
                if nextCharIndex < decodedReq.endIndex && decodedReq[nextCharIndex] == "/" {
                    return true
                }
            }
        }

        return false
    }

    /// Safe representation that masks the cookie value for logging.
    public var redactedDescription: String {
        "\(name)=[REDACTED; length=\(value.count)]"
    }
}

/// Encapsulates request headers, origin-matched session cookies, and navigation context
/// required to download authenticated or session-dependent media resources.
public struct BrowserRequestContext: Sendable, Codable, Hashable {
    public let url: URL
    public let pageURL: URL?
    public let userAgent: String?
    public let cookies: [BrowserCookie]
    public let customHeaders: [String: String]
    public let captureDate: Date
    public let source: BrowserRequestContextSource
    /// Verified allowed origins, hosts, or domain wildcards permitted to receive credentials
    /// (Authorization, session cookies, and custom authentication tokens) even when cross-origin.
    public let allowedCredentialOrigins: Set<String>

    private enum CodingKeys: String, CodingKey {
        case url
        case pageURL
        case userAgent
        case cookies
        case customHeaders
        case captureDate
        case source
        case allowedCredentialOrigins
    }

    public init(
        url: URL,
        pageURL: URL? = nil,
        userAgent: String? = nil,
        cookies: [BrowserCookie] = [],
        customHeaders: [String: String] = [:],
        captureDate: Date = Date(),
        source: BrowserRequestContextSource = .directLink,
        allowedCredentialOrigins: Set<String> = []
    ) {
        self.url = url
        self.pageURL = pageURL
        self.userAgent = userAgent
        self.cookies = cookies
        self.customHeaders = customHeaders
        self.captureDate = captureDate
        self.source = source
        self.allowedCredentialOrigins = allowedCredentialOrigins
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(URL.self, forKey: .url)
        self.pageURL = try container.decodeIfPresent(URL.self, forKey: .pageURL)
        self.userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        self.cookies = try container.decodeIfPresent([BrowserCookie].self, forKey: .cookies) ?? []
        self.customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        self.captureDate = try container.decodeIfPresent(Date.self, forKey: .captureDate) ?? Date()
        self.source = try container.decodeIfPresent(BrowserRequestContextSource.self, forKey: .source) ?? .directLink
        self.allowedCredentialOrigins = try container.decodeIfPresent(Set<String>.self, forKey: .allowedCredentialOrigins) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(pageURL, forKey: .pageURL)
        try container.encodeIfPresent(userAgent, forKey: .userAgent)
        try container.encode(cookies, forKey: .cookies)
        try container.encode(customHeaders, forKey: .customHeaders)
        try container.encode(captureDate, forKey: .captureDate)
        try container.encode(source, forKey: .source)
        try container.encode(allowedCredentialOrigins, forKey: .allowedCredentialOrigins)
    }

    public static func == (lhs: BrowserRequestContext, rhs: BrowserRequestContext) -> Bool {
        lhs.url == rhs.url &&
        lhs.pageURL == rhs.pageURL &&
        lhs.userAgent == rhs.userAgent &&
        lhs.cookies == rhs.cookies &&
        lhs.customHeaders == rhs.customHeaders &&
        lhs.captureDate == rhs.captureDate &&
        lhs.source == rhs.source &&
        lhs.allowedCredentialOrigins == rhs.allowedCredentialOrigins
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(pageURL)
        hasher.combine(userAgent)
        hasher.combine(cookies)
        for entry in customHeaders.sorted(by: { $0.key < $1.key }) {
            hasher.combine(entry.key)
            hasher.combine(entry.value)
        }
        hasher.combine(captureDate)
        hasher.combine(source)
        for origin in allowedCredentialOrigins.sorted() {
            hasher.combine(origin)
        }
    }

    /// Returns a copy of this context with a new set of verified allowed credential origins.
    public func withAllowedCredentialOrigins(_ origins: Set<String>) -> BrowserRequestContext {
        BrowserRequestContext(
            url: url,
            pageURL: pageURL,
            userAgent: userAgent,
            cookies: cookies,
            customHeaders: customHeaders,
            captureDate: captureDate,
            source: source,
            allowedCredentialOrigins: origins
        )
    }

    /// Returns a copy of this context with additional verified allowed credential origins merged in.
    public func addingAllowedCredentialOrigins(_ origins: Set<String>) -> BrowserRequestContext {
        BrowserRequestContext(
            url: url,
            pageURL: pageURL,
            userAgent: userAgent,
            cookies: cookies,
            customHeaders: customHeaders,
            captureDate: captureDate,
            source: source,
            allowedCredentialOrigins: allowedCredentialOrigins.union(origins)
        )
    }

    /// Returns a new `BrowserRequestContext` with fresh cookies merged in.
    /// If an updated cookie has matching name, domain, and path, the newer value is used.
    /// New cookies (including third-party cookies) are appended.
    public func updatingCookies(with freshCookies: [BrowserCookie]) -> BrowserRequestContext {
        guard !freshCookies.isEmpty else { return self }
        var cookieMap: [String: BrowserCookie] = [:]
        for c in self.cookies {
            let key = "\(c.name.lowercased())@\(c.domain.lowercased())\(c.path)"
            cookieMap[key] = c
        }
        for c in freshCookies {
            let key = "\(c.name.lowercased())@\(c.domain.lowercased())\(c.path)"
            cookieMap[key] = c
        }
        var result: [BrowserCookie] = []
        var seenKeys = Set<String>()
        for c in self.cookies {
            let key = "\(c.name.lowercased())@\(c.domain.lowercased())\(c.path)"
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                result.append(cookieMap[key] ?? c)
            }
        }
        for c in freshCookies {
            let key = "\(c.name.lowercased())@\(c.domain.lowercased())\(c.path)"
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                result.append(c)
            }
        }
        return BrowserRequestContext(
            url: url,
            pageURL: pageURL,
            userAgent: userAgent,
            cookies: result,
            customHeaders: customHeaders,
            captureDate: Date(),
            source: source,
            allowedCredentialOrigins: allowedCredentialOrigins
        )
    }

    /// Returns a new `BrowserRequestContext` updated with cookies from a `BrowserSessionSnapshot`.
    public func updatingCookies(from snapshot: BrowserSessionSnapshot?) -> BrowserRequestContext {
        guard let snapshot, !snapshot.allCookies.isEmpty else { return self }
        let fresh = snapshot.allCookies.compactMap { BrowserCookie(from: $0) }
        return updatingCookies(with: fresh)
    }

    /// Evaluates whether a destination URL is eligible to receive credentials under this context
    /// (either because it is same-origin with the context's URL or page URL, or is explicitly allowlisted).
    public func isAllowedCredentialOrigin(_ targetURL: URL) -> Bool {
        if BrowserHeaderFilter.sameOrigin(url, targetURL) { return true }
        if let pageURL, BrowserHeaderFilter.sameOrigin(pageURL, targetURL) { return true }
        return BrowserHeaderFilter.isOriginAllowed(targetURL, allowedOrigins: allowedCredentialOrigins)
    }

    /// Returns a new `BrowserRequestContext` resolved after an HTTP redirect to `targetURL`,
    /// updating `url` to `targetURL` and sanitizing credentials, headers, and cookies
    /// according to cross-origin redirect and allowlist rules.
    public func redirectResolved(to targetURL: URL) -> BrowserRequestContext {
        guard targetURL != url else { return self }

        let isSameOrigin = BrowserHeaderFilter.sameOrigin(url, targetURL)
        let isSamePageOrigin = pageURL.map { BrowserHeaderFilter.sameOrigin($0, targetURL) } ?? false
        let isAllowed = BrowserHeaderFilter.isOriginAllowed(targetURL, allowedOrigins: allowedCredentialOrigins)
        let isDowngrade = (url.scheme?.lowercased() == "https") && (targetURL.scheme?.lowercased() == "http")

        let strippedHeaders = BrowserHeaderFilter.stripCredentialsOnRedirect(
            headers: customHeaders,
            from: url,
            to: targetURL,
            allowedOrigins: allowedCredentialOrigins
        )

        let safeCookies: [BrowserCookie]
        if isDowngrade {
            safeCookies = []
        } else if isSameOrigin || isSamePageOrigin || isAllowed {
            safeCookies = cookies
        } else {
            safeCookies = cookies.filter { $0.matches(url: targetURL) }
        }

        return BrowserRequestContext(
            url: targetURL,
            pageURL: pageURL,
            userAgent: userAgent,
            cookies: safeCookies,
            customHeaders: strippedHeaders,
            captureDate: captureDate,
            source: source,
            allowedCredentialOrigins: allowedCredentialOrigins
        )
    }

    /// Computes the valid `Referer` header value according to RFC 7231 / Referrer-Policy.
    public var referer: String? {
        guard let page = pageURL else { return nil }

        // Security: Omit Referer on HTTPS -> HTTP downgrade
        let pageScheme = page.scheme?.lowercased() ?? ""
        let targetScheme = url.scheme?.lowercased() ?? ""
        if pageScheme == "https" && targetScheme == "http" {
            return nil
        }

        // Strip fragments and credentials
        guard var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        components.user = nil
        components.password = nil

        return components.url?.absoluteString
    }

    /// Computes the valid `Origin` header value for CORS/CDN verification.
    public var origin: String? {
        guard let page = pageURL ?? Optional(url), let scheme = page.scheme, let host = page.host else { return nil }
        if let port = page.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Assembles the final, sanitized header dictionary for the target URL.
    ///
    /// Filters cookies to only those matching the target URL origin, appends Referer and User-Agent,
    /// and excludes forbidden hop-by-hop or stack-managed headers.
    public func effectiveHeaders(
        for targetURL: URL? = nil,
        includeCredentials: Bool = true
    ) -> [String: String] {
        let dest = targetURL ?? self.url
        var headers: [String: String] = [:]

        // 1. Origin-matched Cookie header
        let isSameOrigin = BrowserHeaderFilter.sameOrigin(url, dest)
        let isPageOrigin = pageURL.map { BrowserHeaderFilter.sameOrigin($0, dest) } ?? false
        let isDestAllowedOrigin = BrowserHeaderFilter.isOriginAllowed(dest, allowedOrigins: allowedCredentialOrigins)
        let isContextAllowedOrigin = BrowserHeaderFilter.isOriginAllowed(url, allowedOrigins: allowedCredentialOrigins)
        let isDowngrade: Bool = {
            let srcHTTPS = (url.scheme?.lowercased() == "https") || (pageURL?.scheme?.lowercased() == "https")
            return srcHTTPS && (dest.scheme?.lowercased() == "http")
        }()

        let matchingCookies: [BrowserCookie] = {
            guard includeCredentials && !isDowngrade else { return [] }
            return cookies.filter { cookie in
                // 1. Direct RFC 6265 match (exact host or domain-scoped subdomain match)
                if cookie.matches(url: dest) {
                    return true
                }
                // 2. Verified allowlist cross-origin match: Forward cookies belonging to this context
                if isDestAllowedOrigin && (cookie.matches(url: self.url) || (self.pageURL != nil && cookie.matches(url: self.pageURL!))) {
                    if let exp = cookie.expiresDate, exp < Date() { return false }
                    if cookie.isSecure && (dest.scheme?.lowercased() ?? "") != "https" { return false }
                    return true
                }
                // 3. Redirect-resolved allowlisted context: Context is on an allowlisted origin, forward to same-origin or allowlisted dest
                if isContextAllowedOrigin && (isSameOrigin || isDestAllowedOrigin) {
                    if let exp = cookie.expiresDate, exp < Date() { return false }
                    if cookie.isSecure && (dest.scheme?.lowercased() ?? "") != "https" { return false }
                    return true
                }
                return false
            }
        }()
        if !matchingCookies.isEmpty {
            // Deduplicate by name, preferring most specific path
            var cookieMap: [String: String] = [:]
            for c in matchingCookies.sorted(by: { $0.path.count > $1.path.count }) {
                guard cookieMap[c.name] == nil else { continue }
                cookieMap[c.name] = c.value
            }
            var cookieParts: [String] = []
            var emittedNames = Set<String>()
            for cookie in matchingCookies.sorted(by: { $0.path.count > $1.path.count }) {
                guard !emittedNames.contains(cookie.name), let value = cookieMap[cookie.name] else { continue }
                emittedNames.insert(cookie.name)
                cookieParts.append("\(cookie.name)=\(value)")
            }
            let cookieHeader = cookieParts.joined(separator: "; ")
            headers["Cookie"] = cookieHeader
        }

        // 2. Referer (RFC 7231 §5.5.2: Omit Referer on HTTPS -> HTTP downgrade)
        if let ref = self.referer {
            let isRefererHTTPS = URL(string: ref)?.scheme?.lowercased() == "https"
            let isDestHTTP = dest.scheme?.lowercased() == "http"
            if !(isRefererHTTPS && isDestHTTP) {
                headers["Referer"] = ref
            }
        }

        // 2b. Origin (Suppress HTTPS Origin on HTTP downgrade)
        if let orig = self.origin {
            let isOriginHTTPS = orig.lowercased().hasPrefix("https:")
            let isDestHTTP = dest.scheme?.lowercased() == "http"
            if !(isOriginHTTPS && isDestHTTP) {
                headers["Origin"] = orig
            }
        }

        // 3. User-Agent
        if let ua = userAgent, !ua.isEmpty {
            headers["User-Agent"] = ua
        }

        // 4. Approved custom headers (filtered against forbidden names)
        let isDestHTTP = dest.scheme?.lowercased() == "http"
        let isSameSite = BrowserHeaderFilter.isSchemefulSameSite(url, dest) || (pageURL != nil && BrowserHeaderFilter.isSchemefulSameSite(pageURL!, dest))
        let canForwardCredentials = includeCredentials && !isDowngrade && (isSameOrigin || isPageOrigin || isDestAllowedOrigin || isContextAllowedOrigin || isSameSite)
        for (k, v) in customHeaders {
            let lowerName = k.trimmingCharacters(in: .whitespaces).lowercased()
            if !BrowserHeaderFilter.isForbiddenHeader(k) &&
                lowerName != "cookie" &&
                lowerName != "referer" &&
                lowerName != "user-agent" &&
                (canForwardCredentials || !BrowserHeaderFilter.isSensitiveHeader(k)) {
                if lowerName == "origin" && isDestHTTP && v.lowercased().hasPrefix("https:") {
                    continue
                }
                headers[k] = v
            }
        }

        return headers
    }

    /// A diagnostic representation that never includes cookie or token values.
    public var redactedDescription: String {
        let safeHeaders = BrowserHeaderFilter.redactSensitiveHeaders(
            effectiveHeaders(for: url)
        )
        return "BrowserRequestContext(url: \(BrowserURLResolver.sanitizeURLForLogging(url)), headers: \(safeHeaders), source: \(source.rawValue))"
    }
}

/// Security utility for header allowlisting, sensitive value redaction, and cross-origin redirect protection.
public struct BrowserHeaderFilter {

    /// Headers that may be copied from a WebKit request. Fetch metadata,
    /// connection details, and browser-generated bookkeeping are intentionally
    /// excluded even when WebKit exposes them.
    public static let approvedForwardedHeaders: Set<String> = [
        "accept",
        "accept-language",
        "cache-control",
        "content-type",
        "if-match",
        "if-none-match",
        "if-modified-since",
        "if-unmodified-since",
        "authorization",
        "origin",
        "referer",
        "x-api-key",
        "x-auth-token",
        "x-session-token",
        "x-csrf-token",
        "x-requested-with"
    ]

    /// Hop-by-hop and transport-managed headers that must never be set explicitly.
    public static let forbiddenHeaders: Set<String> = [
        "content-length",
        "accept-encoding",
        "host",
        "range",
        "connection",
        "transfer-encoding",
        "upgrade",
        "te",
        "keep-alive",
        "proxy-authorization",
        "proxy-authenticate"
    ]

    /// Sensitive header names whose values must be redacted from logs and diagnostic descriptions.
    public static let sensitiveHeaderNames: Set<String> = [
        "cookie",
        "set-cookie",
        "authorization",
        "proxy-authorization",
        "x-auth-token",
        "x-api-key",
        "x-session-token",
        "token",
        "secret"
    ]

    /// Checks if a header is forbidden from explicit configuration.
    public static func isForbiddenHeader(_ name: String) -> Bool {
        forbiddenHeaders.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Evaluates whether a header is a custom authorization header or credential token
    /// commonly used in CDN or API authentication contracts (e.g. X-Custom-Auth, X-Access-Token, X-Signature).
    public static func isCustomAuthorizationHeader(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        if lower == "authorization" || lower == "proxy-authorization" {
            return true
        }
        if lower.hasPrefix("x-") {
            return lower.contains("auth") ||
                lower.contains("token") ||
                lower.contains("key") ||
                lower.contains("secret") ||
                lower.contains("sig") ||
                lower.contains("cred") ||
                lower.contains("session") ||
                lower.contains("bearer") ||
                lower.contains("pass")
        }
        return false
    }

    public static func isApprovedForwardedHeader(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        if approvedForwardedHeaders.contains(lower) { return true }
        return isCustomAuthorizationHeader(lower)
    }

    public static func isSensitiveHeader(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        if sensitiveHeaderNames.contains(lower) { return true }
        if isCustomAuthorizationHeader(lower) { return true }
        return lower.contains("token") ||
            lower.contains("secret") ||
            lower.contains("api-key") ||
            lower.contains("apikey")
    }

    /// Strips forbidden and stack-managed headers from a header dictionary.
    public static func sanitizeHeaders(_ headers: [String: String]) -> [String: String] {
        var clean: [String: String] = [:]
        for (k, v) in headers {
            if !isForbiddenHeader(k) {
                clean[k] = v
            }
        }
        return clean
    }

    /// Returns a copy of the headers dictionary with sensitive credentials redacted for secure logging.
    public static func redactSensitiveHeaders(_ headers: [String: String]) -> [String: String] {
        var redacted: [String: String] = [:]
        for (k, v) in headers {
            let lowerKey = k.trimmingCharacters(in: .whitespaces).lowercased()
            if lowerKey == "cookie" {
                let count = v.split(separator: ";").count
                redacted[k] = "[REDACTED_COOKIE; count=\(count)]"
            } else if isSensitiveHeader(lowerKey) {
                redacted[k] = "[REDACTED]"
            } else {
                redacted[k] = v
            }
        }
        return redacted
    }

    /// Evaluates whether a given URL matches a set of verified allowed credential origins, hosts, or domain wildcards.
    public static func isOriginAllowed(_ url: URL, allowedOrigins: Set<String>) -> Bool {
        guard !allowedOrigins.isEmpty else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let scheme = url.scheme?.lowercased() ?? "https"
        let port = url.port

        let originWithPort = port != nil ? "\(scheme)://\(host):\(port!)" : "\(scheme)://\(host)"
        let originDefault = "\(scheme)://\(host)"

        for rawAllowed in allowedOrigins {
            let allowed = rawAllowed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !allowed.isEmpty else { continue }

            // 1. Exact origin match (e.g. "https://cdn.example.com" or "https://cdn.example.com:8443")
            if allowed == originWithPort || allowed == originDefault {
                return true
            }

            // 2. Exact host match (e.g. "cdn.example.com" or "cdn.example.com:8443")
            if allowed == host || (port != nil && allowed == "\(host):\(port!)") {
                return true
            }

            // 3. If allowed is a URL with scheme/host/path
            if allowed.contains("://") {
                if let allowedURL = URL(string: allowed), let allowedHost = allowedURL.host?.lowercased() {
                    let allowedScheme = allowedURL.scheme?.lowercased()
                    if allowedScheme == nil || allowedScheme == scheme {
                        if allowedURL.port == nil || allowedURL.port == port {
                            let clean = allowedHost.hasPrefix("*.") ? String(allowedHost.dropFirst(2)) : (allowedHost.hasPrefix(".") ? String(allowedHost.dropFirst(1)) : allowedHost)
                            if host == clean || host.hasSuffix("." + clean) {
                                return true
                            }
                        }
                    }
                }
                continue
            }

            // 4. Wildcard or domain suffix match
            let cleanDomain: String
            if allowed.hasPrefix("*.") {
                cleanDomain = String(allowed.dropFirst(2))
            } else if allowed.hasPrefix(".") {
                cleanDomain = String(allowed.dropFirst(1))
            } else {
                cleanDomain = allowed
            }

            // Domain suffix match (e.g. host "cdn.example.com" matches cleanDomain "example.com")
            if host == cleanDomain || host.hasSuffix("." + cleanDomain) {
                return true
            }
        }

        return false
    }

    /// Strips session cookies and authorization credentials when an HTTP redirect crosses origins,
    /// unless the destination is verified in `allowedOrigins`.
    ///
    /// Per RFC 7235 §2.2, RFC 9110 §15.4, and modern browser security standards, sensitive credentials
    /// (such as Authorization) must NEVER be forwarded across origins, and cookies are restricted
    /// to schemeful same-site boundaries, unless explicitly permitted via a verified allowlist.
    /// Under all circumstances, credentials are never forwarded over an HTTPS -> HTTP downgrade.
    public static func stripCredentialsOnRedirect(
        headers: [String: String],
        from originalURL: URL,
        to redirectURL: URL,
        allowedOrigins: Set<String> = []
    ) -> [String: String] {
        let isSameOrigin = sameOrigin(originalURL, redirectURL)
        let isAllowedOrigin = isOriginAllowed(redirectURL, allowedOrigins: allowedOrigins)

        if isSameOrigin {
            return headers
        }

        let isSameSite = isSchemefulSameSite(originalURL, redirectURL)
        let isOriginalHTTPS = originalURL.scheme?.lowercased() == "https"
        let isRedirectHTTP = redirectURL.scheme?.lowercased() == "http"
        let isDowngrade = isOriginalHTTPS && isRedirectHTTP

        var stripped: [String: String] = [:]
        for (k, v) in headers {
            let lower = k.trimmingCharacters(in: .whitespaces).lowercased()
            // 1. Authorization & Proxy-Authorization: stripped across origins unless target origin is verified in allowlist (without downgrade)
            if !isSameOrigin && (lower == "authorization" || lower == "proxy-authorization") {
                if isAllowedOrigin && !isDowngrade {
                    stripped[k] = v
                }
                continue
            }
            // 2. Retain domain-scoped cookies when redirecting to a schemeful same-site host without downgrade, or for verified allowlisted origins
            if lower == "cookie" {
                if (isSameSite || isAllowedOrigin) && !isDowngrade {
                    stripped[k] = v
                }
                continue
            }
            // 3. Custom authorization headers & sensitive tokens: preserved across same-site subdomains (CDN contract on same site) or verified allowlisted CDN origins without downgrade
            if !isSameOrigin && isSensitiveHeader(lower) {
                if (isSameSite || isAllowedOrigin) && !isDowngrade {
                    stripped[k] = v
                }
                continue
            }
            // 4. Omit Referer on HTTPS -> HTTP downgrade or cross-site redirect (unless allowlisted)
            if lower == "referer" && ((!isSameSite && !isAllowedOrigin) || isDowngrade) {
                continue
            }
            // 5. Suppress secure Origin on downgrade or cross-site redirect (unless allowlisted)
            if lower == "origin" && ((!isSameSite && !isAllowedOrigin) || isDowngrade) {
                continue
            }
            stripped[k] = v
        }

        return stripped
    }

    public static func stripCredentialsOnRedirect(
        headers: [String: String],
        from originalURL: URL,
        to redirectURL: URL
    ) -> [String: String] {
        stripCredentialsOnRedirect(headers: headers, from: originalURL, to: redirectURL, allowedOrigins: [])
    }

    /// Evaluates whether two URLs belong to the same schemeful site (same scheme and registrable domain).
    ///
    /// Uses Public Suffix List logic to distinguish multi-part public suffixes such as `.co.uk`,
    /// `.com.au`, and `.github.io` from registrable domains.
    public static func isSchemefulSameSite(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              lhsScheme == rhsScheme else {
            return false
        }
        return isSameRegistrableDomain(lhs, rhs)
    }

    /// Evaluates whether two URLs share the same registrable domain (eTLD+1), ignoring scheme.
    public static func isSameRegistrableDomain(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased(),
              !lhsHost.isEmpty, !rhsHost.isEmpty else {
            return false
        }
        if lhsHost == rhsHost { return true }
        guard let lhsDomain = PublicSuffixList.registrableDomain(for: lhsHost),
              let rhsDomain = PublicSuffixList.registrableDomain(for: rhsHost) else {
            return false
        }
        return lhsDomain == rhsDomain
    }

    /// Backwards-compatible alias for schemeful same-site evaluation.
    public static func isSameSiteOrSubdomain(_ lhs: URL, _ rhs: URL) -> Bool {
        isSchemefulSameSite(lhs, rhs)
    }

    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else {
            return false
        }

        func effectivePort(for url: URL, scheme: String) -> Int? {
            if let port = url.port { return port }
            return scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        }

        return lhsScheme == rhsScheme &&
            lhsHost == rhsHost &&
            effectivePort(for: lhs, scheme: lhsScheme) == effectivePort(for: rhs, scheme: rhsScheme)
    }
}

// MARK: - Manifest Cache Key Discriminator

extension BrowserRequestContext {
    /// Normalizes a URL for caching purposes per RFC 3986 by lowercasing only
    /// the scheme and host (which are case-insensitive) while strictly preserving
    /// the case of the path, query string, and fragment (which are case-sensitive).
    public static func canonicalURLString(for url: URL) -> String {
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if let string = components.string {
                return string
            }
        }

        // Robust fallback if URLComponents fails to reconstruct string
        let raw = url.absoluteString
        guard let schemeSeparator = raw.range(of: "://") else {
            return raw
        }
        let scheme = raw[..<schemeSeparator.lowerBound].lowercased()
        let rest = raw[schemeSeparator.upperBound...]
        let pathStart = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let hostAndPort = rest[..<pathStart].lowercased()
        let remainder = rest[pathStart...]
        return "\(scheme)://\(hostAndPort)\(remainder)"
    }

    /// Computes a deterministic cache key for a media manifest URL and its associated browser context.
    /// Incorporates cookies, headers, page origin, and user agent to prevent cross-tab, cross-user,
    /// or private-browsing cache pollution for signed or authenticated streaming manifests.
    /// Preserves case-sensitivity of signed paths and query tokens according to RFC 3986.
    public static func manifestCacheKey(
        for url: URL,
        requestContext: BrowserRequestContext? = nil,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil
    ) -> String {
        let normalizedURL = canonicalURLString(for: url)
        var components: [String] = [normalizedURL]

        if let context = requestContext {
            if let page = context.pageURL {
                components.append("page:\(canonicalURLString(for: page))")
            }
            if let ua = context.userAgent, !ua.isEmpty {
                components.append("ua:\(ua)")
            }
            let matchingCookies = context.cookies.filter { $0.matches(url: url) }
            let targetCookies = matchingCookies.isEmpty ? context.cookies : matchingCookies
            if !targetCookies.isEmpty {
                let cookieStr = targetCookies
                    .map { "\($0.name)=\($0.value)@\($0.domain.lowercased())\($0.path)" }
                    .sorted()
                    .joined(separator: ";")
                components.append("cookies:\(cookieStr)")
            }
            if !context.customHeaders.isEmpty {
                let headerStr = context.customHeaders
                    .sorted(by: { $0.key.lowercased() < $1.key.lowercased() })
                    .map { "\($0.key.lowercased()):\($0.value)" }
                    .joined(separator: "\n")
                components.append("headers:\(headerStr)")
            }
        }

        if let snapshot = browserSessionSnapshot {
            if let page = snapshot.pageURL {
                components.append("snapshot_page:\(canonicalURLString(for: page))")
            }
            if !snapshot.userAgent.isEmpty {
                components.append("snapshot_ua:\(snapshot.userAgent)")
            }
            let matching = snapshot.allCookies.filter { cookie in
                if let host = url.host?.lowercased() {
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return host == domain || host.hasSuffix("." + domain)
                }
                return true
            }
            let targetCookies = matching.isEmpty ? snapshot.allCookies : matching
            if !targetCookies.isEmpty {
                let cookieStr = targetCookies
                    .map { "\($0.name)=\($0.value)@\($0.domain.lowercased())\($0.path)" }
                    .sorted()
                    .joined(separator: ";")
                components.append("snapshot_cookies:\(cookieStr)")
            }
        }

        if components.count == 1 {
            return normalizedURL
        }

        let digest = EngineSHA256.hash(data: Data(components.joined(separator: "|").utf8))
        return "\(normalizedURL)#ctx-\(digest.prefix(16))"
    }
}
