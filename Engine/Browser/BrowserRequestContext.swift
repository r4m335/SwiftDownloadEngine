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
    public let expiresDate: Date?

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        isSecure: Bool = false,
        isHTTPOnly: Bool = false,
        expiresDate: Date? = nil
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = value
        self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.path = path.isEmpty ? "/" : path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.expiresDate = expiresDate
    }

    /// Convenience initializer from Foundation `HTTPCookie`.
    public init?(from httpCookie: HTTPCookie) {
        guard !httpCookie.name.isEmpty else { return nil }
        self.name = httpCookie.name
        self.value = httpCookie.value
        self.domain = httpCookie.domain.lowercased()
        self.path = httpCookie.path.isEmpty ? "/" : httpCookie.path
        self.isSecure = httpCookie.isSecure
        self.isHTTPOnly = httpCookie.isHTTPOnly
        self.expiresDate = httpCookie.expiresDate
    }

    /// Converts back to a Foundation `HTTPCookie` for session injection or URLRequest enrichment.
    public func toHTTPCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
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

    /// Evaluates if this cookie is eligible to be sent to the target URL per RFC 6265.
    public func matches(url: URL, now: Date = Date()) -> Bool {
        // 1. Expiration check
        if let exp = expiresDate, exp < now {
            return false
        }

        // 2. Secure flag check
        let scheme = url.scheme?.lowercased() ?? ""
        if isSecure && scheme != "https" {
            return false
        }

        // 3. Domain matching (RFC 6265 §5.1.3)
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }

        let cookieDomain = self.domain.hasPrefix(".") ? String(self.domain.dropFirst()) : self.domain
        if host != cookieDomain {
            // Must be a subdomain separated by a dot
            if !host.hasSuffix("." + cookieDomain) {
                return false
            }
        }

        // 4. Path matching (RFC 6265 §5.1.4)
        let requestPath = url.path.isEmpty ? "/" : url.path
        if self.path == "/" {
            return true
        }
        if requestPath == self.path {
            return true
        }
        if requestPath.hasPrefix(self.path) {
            if self.path.hasSuffix("/") {
                return true
            }
            let nextCharIndex = requestPath.index(requestPath.startIndex, offsetBy: self.path.count)
            if nextCharIndex < requestPath.endIndex && requestPath[nextCharIndex] == "/" {
                return true
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

    public init(
        url: URL,
        pageURL: URL? = nil,
        userAgent: String? = nil,
        cookies: [BrowserCookie] = [],
        customHeaders: [String: String] = [:],
        captureDate: Date = Date(),
        source: BrowserRequestContextSource = .directLink
    ) {
        self.url = url
        self.pageURL = pageURL
        self.userAgent = userAgent
        self.cookies = cookies
        self.customHeaders = customHeaders
        self.captureDate = captureDate
        self.source = source
    }

    public static func == (lhs: BrowserRequestContext, rhs: BrowserRequestContext) -> Bool {
        lhs.url == rhs.url &&
        lhs.pageURL == rhs.pageURL &&
        lhs.userAgent == rhs.userAgent &&
        lhs.cookies == rhs.cookies &&
        lhs.customHeaders == rhs.customHeaders &&
        lhs.captureDate == rhs.captureDate &&
        lhs.source == rhs.source
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
        let matchingCookies = includeCredentials ? cookies.filter { $0.matches(url: dest) } : []
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

        // 2. Referer
        if let ref = self.referer {
            headers["Referer"] = ref
        }

        // 3. User-Agent
        if let ua = userAgent, !ua.isEmpty {
            headers["User-Agent"] = ua
        }

        // 4. Approved custom headers (filtered against forbidden names)
        for (k, v) in customHeaders {
            let lowerName = k.trimmingCharacters(in: .whitespaces).lowercased()
            if !BrowserHeaderFilter.isForbiddenHeader(k) &&
                lowerName != "cookie" &&
                lowerName != "referer" &&
                lowerName != "user-agent" &&
                (includeCredentials || !BrowserHeaderFilter.isSensitiveHeader(k)) {
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

    public static func isApprovedForwardedHeader(_ name: String) -> Bool {
        approvedForwardedHeaders.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public static func isSensitiveHeader(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        if sensitiveHeaderNames.contains(lower) { return true }
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

    /// Strips session cookies and authorization credentials when an HTTP redirect crosses origins.
    ///
    /// Per RFC 7235 and modern browser security standards, sensitive credentials must never be
    /// forwarded to an untrusted or unrelated domain during redirect resolution.
    public static func stripCredentialsOnRedirect(
        headers: [String: String],
        from originalURL: URL,
        to redirectURL: URL
    ) -> [String: String] {
        if sameOrigin(originalURL, redirectURL) {
            return headers
        }

        let sameSite = isSameSiteOrSubdomain(originalURL, redirectURL)
        var stripped: [String: String] = [:]
        for (k, v) in headers {
            let lower = k.trimmingCharacters(in: .whitespaces).lowercased()
            // Retain domain-scoped cookies when redirecting to a same-site/subdomain host
            if lower == "cookie" {
                if sameSite {
                    stripped[k] = v
                }
                continue
            }
            if isSensitiveHeader(lower) {
                continue
            }
            // The captured page URL can contain private paths or query values;
            // do not carry it across an origin boundary unless same-site.
            if lower == "referer" && !sameSite {
                continue
            }
            stripped[k] = v
        }

        return stripped
    }

    public static func isSameSiteOrSubdomain(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased(),
              !lhsHost.isEmpty, !rhsHost.isEmpty else {
            return false
        }
        if lhsHost == rhsHost { return true }
        if lhsHost.hasSuffix("." + rhsHost) || rhsHost.hasSuffix("." + lhsHost) {
            return true
        }
        let lhsParts = lhsHost.split(separator: ".")
        let rhsParts = rhsHost.split(separator: ".")
        if lhsParts.count >= 2 && rhsParts.count >= 2 {
            let lhsRoot = lhsParts.suffix(2).joined(separator: ".")
            let rhsRoot = rhsParts.suffix(2).joined(separator: ".")
            if lhsRoot == rhsRoot {
                return true
            }
        }
        return false
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
