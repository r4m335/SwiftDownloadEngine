import Foundation

/// Defines supported search engines for non-URL queries in the browser.
public enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo = "DuckDuckGo"
    case google = "Google"
    case bing = "Bing"

    public var id: String { rawValue }

    public var queryPrefix: String {
        switch self {
        case .duckDuckGo:
            return "https://duckduckgo.com/?q="
        case .google:
            return "https://www.google.com/search?q="
        case .bing:
            return "https://www.bing.com/search?q="
        }
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

    /// Resolves an arbitrary user text input into a valid HTTP/HTTPS URL or search query URL.
    ///
    /// - Parameters:
    ///   - input: The raw text entered by the user in the address bar.
    ///   - searchEngine: The default search engine to construct queries with.
    /// - Returns: A validated URL, or `nil` if input is empty or specifies an unsafe scheme.
    public static func resolve(
        input: String,
        searchEngine: BrowserSearchEngine = .duckDuckGo
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
            return makeSearchURL(for: trimmed, searchEngine: searchEngine)
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
        return makeSearchURL(for: trimmed, searchEngine: searchEngine)
    }

    /// Verifies if a URL is permitted for normal in-app web navigation.
    ///
    /// Only HTTP, HTTPS, and about:blank are accepted.
    public static func isValidWebNavigationURL(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        if url.absoluteString == "about:blank" { return true }
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
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
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: searchEngine.queryPrefix + encoded)
    }
}
