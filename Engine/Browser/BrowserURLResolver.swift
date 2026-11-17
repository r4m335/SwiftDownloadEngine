import Foundation

/// Defines supported search engines for non-URL queries in the browser.
public enum BrowserSearchEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case duckDuckGo = "DuckDuckGo"
    case google = "Google"
    case bing = "Bing"
    case brave = "Brave"

    public var id: String { rawValue }

    public var displayName: String { rawValue }

    public var queryPrefix: String {
        switch self {
        case .duckDuckGo:
            return "https://duckduckgo.com/?q="
        case .google:
            return "https://www.google.com/search?q="
        case .bing:
            return "https://www.bing.com/search?q="
        case .brave:
            return "https://search.brave.com/search?q="
        }
    }

    /// Complete URL template containing the `%s` search query placeholder.
    public var urlTemplate: String {
        queryPrefix + "%s"
    }
}

/// User-defined custom search engine.
public struct CustomSearchEngine: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var urlTemplate: String
    public var searchDescription: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        urlTemplate: String,
        searchDescription: String? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.urlTemplate = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        self.searchDescription = searchDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Validation errors for user-supplied search URL templates.
public enum SearchURLValidationError: LocalizedError, Equatable, Sendable {
    case emptyName
    case emptyTemplate
    case missingHTTPS
    case invalidHost
    case missingPlaceholder
    case multiplePlaceholders
    case invalidCharacters
    case malformedURL

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Engine name cannot be empty."
        case .emptyTemplate:
            return "Search URL template cannot be empty."
        case .missingHTTPS:
            return "Search URL template must use the secure https:// protocol."
        case .invalidHost:
            return "Search URL template must include a valid host domain."
        case .missingPlaceholder:
            return "Search URL template must include exactly one '%s' query placeholder."
        case .multiplePlaceholders:
            return "Search URL template cannot contain more than one '%s' placeholder."
        case .invalidCharacters:
            return "Search URL template contains invalid characters or unsafe schemes."
        case .malformedURL:
            return "Search URL template is not a valid URL format."
        }
    }
}

/// Validates search URL templates and constructs percent-encoded search query URLs.
public struct SearchURLBuilder: Sendable {
    /// Validates that a user-provided template conforms to HTTPS, contains a valid host, and has exactly one `%s`.
    public static func validateTemplate(_ template: String) -> Result<Void, SearchURLValidationError> {
        if template.rangeOfCharacter(from: .newlines) != nil {
            return .failure(.invalidCharacters)
        }

        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyTemplate)
        }

        if trimmed.rangeOfCharacter(from: .controlCharacters) != nil {
            return .failure(.invalidCharacters)
        }

        let placeholder = "%s"
        let components = trimmed.components(separatedBy: placeholder)
        let count = components.count - 1
        if count == 0 {
            return .failure(.missingPlaceholder)
        } else if count > 1 {
            return .failure(.multiplePlaceholders)
        }

        // Test placeholder replacement with a dummy keyword to validate URL structure
        let testString = trimmed.replacingOccurrences(of: "%s", with: "test_query")
        guard let url = URL(string: testString) else {
            return .failure(.malformedURL)
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            return .failure(.missingHTTPS)
        }

        guard let host = url.host, !host.isEmpty, host.contains(".") else {
            return .failure(.invalidHost)
        }

        return .success(())
    }

    /// Safely substitutes the percent-encoded query into the `%s` template placeholder.
    public static func buildURL(query: String, template: String) -> URL? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        // Remove +, &, =, #, ?, / from allowed query characters so special characters in searches
        // (e.g. "C++", "AT&T", "x=y", "#swift") are strictly percent-encoded.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#/?")

        guard let encodedQuery = trimmedQuery.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }

        let fullURLString = template.replacingOccurrences(of: "%s", with: encodedQuery)
        return URL(string: fullURLString)
    }
}

/// Pure Swift URL parser, validator, and sanitizer for browser navigation and download interception.
///
/// Designed with zero platform-specific dependencies so it executes identically
/// on iOS, macOS, and Linux SPM environments.
public struct BrowserURLResolver {

    private static let sensitiveQueryParamKeys: Set<String> = [
        "token", "access_token", "auth", "authorization", "key", "api_key",
        "secret", "signature", "sig", "password", "pwd", "credential",
        "credentials", "expires", "x-amz-signature", "x-amz-credential",
        "x-amz-security-token", "x-amz-date", "awsaccesskeyid"
    ]

    private static let disallowedSchemes: Set<String> = [
        "file", "ftp", "javascript", "data", "blob", "vbscript"
    ]

    /// Resolves an arbitrary user text input into a valid HTTP/HTTPS URL or search query URL using a URL template.
    ///
    /// - Parameters:
    ///   - input: The raw text entered by the user in the address bar.
    ///   - template: The search URL template containing a `%s` placeholder.
    /// - Returns: A validated URL, or `nil` if input is empty or specifies an unsafe scheme.
    public static func resolve(
        input: String,
        template: String
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Special case: blank page
        if trimmed.lowercased() == "about:blank" {
            return URL(string: "about:blank")
        }

        // Check for explicit scheme
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let schemeCandidate = String(trimmed[..<colonIndex]).lowercased()

            // Disallow known insecure or local schemes
            if disallowedSchemes.contains(schemeCandidate) {
                return nil
            }

            // HTTP / HTTPS handling
            if schemeCandidate == "http" || schemeCandidate == "https" {
                if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
                    return url
                }
            }
        }

        // Input does not have an http/https scheme.
        // If it contains spaces, it's definitely a search query.
        if trimmed.contains(" ") {
            return SearchURLBuilder.buildURL(query: trimmed, template: template)
        }

        // Check if it's localhost (e.g. localhost, localhost:8080, localhost/path)
        let lower = trimmed.lowercased()
        if lower == "localhost" || lower.hasPrefix("localhost:") || lower.hasPrefix("localhost/") {
            return URL(string: "http://" + trimmed)
        }

        // Check if it's an IP address or domain name
        if isLikelyDomainOrIP(trimmed) {
            if let url = URL(string: "https://" + trimmed), let host = url.host, !host.isEmpty {
                return url
            }
        }

        // Fallback: search query
        return SearchURLBuilder.buildURL(query: trimmed, template: template)
    }

    /// Resolves user text input using a built-in search engine.
    public static func resolve(
        input: String,
        searchEngine: BrowserSearchEngine = .duckDuckGo
    ) -> URL? {
        return resolve(input: input, template: searchEngine.urlTemplate)
    }

    /// Resolves user text input against either a custom or built-in search engine ID.
    public static func resolve(
        input: String,
        engineID: String,
        customEngines: [CustomSearchEngine] = []
    ) -> URL? {
        if let custom = customEngines.first(where: { $0.id == engineID }) {
            return resolve(input: input, template: custom.urlTemplate)
        }
        if let builtIn = BrowserSearchEngine(rawValue: engineID) {
            return resolve(input: input, template: builtIn.urlTemplate)
        }
        return resolve(input: input, template: BrowserSearchEngine.duckDuckGo.urlTemplate)
    }

    /// Verifies if a URL is permitted for normal in-app web navigation.
    ///
    /// Accepts HTTP, HTTPS, and internal browser pseudo-schemes (about:blank, about:srcdoc)
    /// required by iframes and challenge verification widgets (e.g. Cloudflare Turnstile).
    public static func isValidWebNavigationURL(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        let urlString = url.absoluteString.lowercased()
        if urlString == "about:blank" || urlString == "about:srcdoc" { return true }
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        guard (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }

    /// Validates whether a URL represents an acceptable target for the download engine.
    ///
    /// Only explicit HTTP and HTTPS URLs with a valid non-empty host are eligible.
    public static func isValidDownloadURL(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        if sensitiveQueryParamKeys.contains(lower) { return true }
        if lower.contains("token") || lower.contains("secret") || lower.contains("signature") ||
           lower.contains("password") || lower.contains("accesskey") || lower.contains("auth") ||
           lower.contains("credential") {
            return true
        }
        return false
    }

    /// Redacts sensitive query parameters (e.g. signed tokens, auth keys, passwords)
    /// to prevent credential leakage in logs and telemetry.
    public static func sanitizeURLForLogging(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "\(url.scheme ?? "http")://\(url.host ?? "redacted")\(url.path)"
        }

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.map { item in
                if isSensitiveKey(item.name) {
                    return URLQueryItem(name: item.name, value: "REDACTED")
                }
                return item
            }
        }

        return components.string ?? "\(url.scheme ?? "http")://\(url.host ?? "redacted")\(url.path)"
    }

    /// Sanitizes a URL for safe presentation in user-facing UI dialogs,
    /// masking signed query tokens, auth keys, and credentials.
    public static func sanitizeURLForDisplay(_ url: URL) -> String {
        return sanitizeURLForLogging(url)
    }

    /// Proposes a user-friendly destination filename based on URL path components.
    public static func suggestedFilename(from url: URL) -> String {
        let lastComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastComponent.isEmpty && lastComponent != "/" && lastComponent.contains(".") {
            // Strip invalid filesystem characters
            let sanitized = lastComponent.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            if !sanitized.isEmpty {
                return sanitized
            }
        }

        // Host-based fallback
        if let host = url.host, !host.isEmpty {
            let cleanHost = host.replacingOccurrences(of: ".", with: "_")
            return "download_\(cleanHost).bin"
        }

        return "download.bin"
    }

    // MARK: - Private Helpers

    private static func isLikelyDomainOrIP(_ text: String) -> Bool {
        // Must contain at least one dot
        guard let firstDot = text.firstIndex(of: "."),
              let lastDot = text.lastIndex(of: ".") else {
            return false
        }

        // Cannot start or end with a dot
        if firstDot == text.startIndex || lastDot == text.index(before: text.endIndex) {
            return false
        }

        // Extract host part (before any path / or port :)
        let hostPart: String
        let withoutSlash = text.split(separator: "/").first.map(String.init) ?? text
        let withoutPort = withoutSlash.split(separator: ":").first.map(String.init) ?? withoutSlash
        hostPart = withoutPort

        // Verify host part has valid characters and dot
        guard hostPart.contains(".") else { return false }
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "-."))
        guard CharacterSet(charactersIn: hostPart).isSubset(of: allowed) else {
            return false
        }

        // Check TLD / last segment: must be at least 2 characters (e.g. .com, .io, .uk, or numeric IP)
        guard let tld = hostPart.split(separator: ".").last else { return false }
        if tld.count >= 2 {
            return true
        }

        return false
    }

    private static func makeSearchURL(for query: String, searchEngine: BrowserSearchEngine) -> URL? {
        SearchURLBuilder.buildURL(query: query, template: searchEngine.urlTemplate)
    }
}
