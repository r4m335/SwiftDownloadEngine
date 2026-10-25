import Foundation

/// Provides standardized browser User-Agent strings for WebKit sessions.
///
/// Ensures the in-app browser presents consistent, standard Safari identification
/// so that verification systems (such as Cloudflare Turnstile and challenge services)
/// recognize a legitimate WebKit browser environment rather than an unidentified
/// or restricted embedded client.
public struct BrowserUserAgentHelper: Sendable {

    /// Standard Safari User-Agent matching the host platform and operating system version.
    public static var standardSafariUserAgent: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let osString = "\(os.majorVersion)_\(os.minorVersion)"
        let versionString = "\(os.majorVersion).\(os.minorVersion)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osString) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(versionString) Mobile/15E148 Safari/604.1"
        #elseif os(macOS)
        let versionString = "\(os.majorVersion).\(os.minorVersion)"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(versionString) Safari/605.1.15"
        #else
        return "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        #endif
    }

    /// Verifies whether a given User-Agent string contains standard Safari tokens.
    public static func isStandardSafariUserAgent(_ ua: String) -> Bool {
        let lower = ua.lowercased()
        return lower.contains("safari/") && lower.contains("applewebkit/")
    }
}
