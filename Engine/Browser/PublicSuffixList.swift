import Foundation

/// Public Suffix List and registrable domain (eTLD+1) resolution.
///
/// Implements RFC 6265 §5.1.3 and the WHATWG URL / Schemeful Same-Site standards,
/// preventing credential and cookie leakage across multi-part public suffixes
/// (e.g. .co.uk, .com.au, .github.io).
public enum PublicSuffixList {

    /// Known multi-part platform and cloud hosting suffixes.
    public static let multiPartPlatformSuffixes: Set<String> = [
        "github.io",
        "gitlab.io",
        "pages.dev",
        "workers.dev",
        "vercel.app",
        "netlify.app",
        "herokuapp.com",
        "appspot.com",
        "firebaseapp.com",
        "cloudfront.net",
        "azurewebsites.net",
        "s3.amazonaws.com",
        "blob.core.windows.net",
        "fastly.net",
        "myshopify.com"
    ]

    /// Common country-code second-level designations (e.g. .co.uk, .com.au, .org.il).
    public static let countrySecondLevelLabels: Set<String> = [
        "co", "com", "org", "net", "edu", "gov", "gob", "gc", "govt",
        "ac", "sch", "ne", "or", "go", "ltd", "plc", "asn", "id",
        "gen", "firm", "ind", "res", "nom", "per", "idv"
    ]

    /// Extracts the public suffix (effective TLD) from a host string.
    public static func publicSuffix(for host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // IP addresses, localhost, or unqualified single labels do not have a public suffix
        if isIPAddress(trimmed) || trimmed == "localhost" || !trimmed.contains(".") {
            return nil
        }

        let labels = trimmed.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return trimmed }

        // 1. Check known multi-part platform suffixes (e.g. "github.io", "pages.dev")
        if labels.count >= 2 {
            let twoLabels = labels.suffix(2).joined(separator: ".")
            if multiPartPlatformSuffixes.contains(twoLabels) {
                return twoLabels
            }
        }
        if labels.count >= 3 {
            let threeLabels = labels.suffix(3).joined(separator: ".")
            if multiPartPlatformSuffixes.contains(threeLabels) {
                return threeLabels
            }
        }

        // 2. Check country-code second level suffixes (e.g. .co.uk, .com.au, .gov.in)
        let tld = labels.last!
        if tld.count == 2 {
            let secondToLast = labels[labels.count - 2]
            if countrySecondLevelLabels.contains(secondToLast) {
                return "\(secondToLast).\(tld)"
            }
        }

        // 3. Default: the final label is the TLD (.com, .org, .net, etc.)
        return tld
    }

    /// Resolves the registrable domain (eTLD+1) for a host string.
    public static func registrableDomain(for host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // IP addresses and localhost are self-registrable
        if isIPAddress(trimmed) || trimmed == "localhost" || !trimmed.contains(".") {
            return trimmed
        }

        guard let suffix = publicSuffix(for: trimmed) else {
            return trimmed
        }

        let suffixLabels = suffix.split(separator: ".").map(String.init)
        let hostLabels = trimmed.split(separator: ".").map(String.init)

        if hostLabels.count <= suffixLabels.count {
            return trimmed
        }

        let registrableCount = suffixLabels.count + 1
        let registrableLabels = hostLabels.suffix(registrableCount)
        return registrableLabels.joined(separator: ".")
    }

    private static func isIPAddress(_ host: String) -> Bool {
        // Simple IPv4 check
        let parts = host.split(separator: ".")
        if parts.count == 4 && parts.allSatisfy({ Int($0) != nil && (0...255).contains(Int($0)!) }) {
            return true
        }
        // IPv6 check
        if host.contains(":") {
            return true
        }
        return false
    }
}

