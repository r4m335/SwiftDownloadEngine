import Foundation

/// Public Suffix List and registrable domain (eTLD+1) resolution.
///
/// Implements RFC 6265bis §5.1.3 and the official Public Suffix List specification
/// (https://publicsuffix.org/list/), supporting:
/// 1. Exact rules (e.g. `com`, `co.uk`, `github.io`, `nom.br`)
/// 2. Wildcard rules (e.g. `*.ck`, `*.er`, `*.nom.br`, `*.sch.uk`, `*.tokyo.jp`)
/// 3. Exception rules prefixed with `!` (e.g. `!www.ck`, `!metro.tokyo.jp`, `!city.kawasaki.jp`)
/// 4. Extensible runtime registration of arbitrary PSL rules via `addRule(_:)`.
public final class PublicSuffixList: @unchecked Sendable {

    /// Represents a parsed rule from the Public Suffix List.
    public struct Rule: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case exact
            case wildcard
            case exception
        }

        public let raw: String
        public let kind: Kind
        /// Normalized labels in left-to-right order (excluding '*' or '!' markers).
        public let labels: [String]

        public init?(ruleString: String) {
            let trimmed = ruleString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return nil }
            self.raw = trimmed
            if trimmed.hasPrefix("!") {
                self.kind = .exception
                let remainder = String(trimmed.dropFirst())
                self.labels = remainder.split(separator: ".").map(String.init)
            } else if trimmed.hasPrefix("*.") {
                self.kind = .wildcard
                let remainder = String(trimmed.dropFirst(2))
                self.labels = remainder.split(separator: ".").map(String.init)
            } else {
                self.kind = .exact
                self.labels = trimmed.split(separator: ".").map(String.init)
            }
            guard !labels.isEmpty else { return nil }
        }

        /// Matches the rule against host labels (in left-to-right order).
        /// Returns the number of host labels matched if successful, or nil otherwise.
        public func match(hostLabels: [String]) -> Int? {
            switch kind {
            case .exact:
                guard hostLabels.count >= labels.count else { return nil }
                let suffix = hostLabels.suffix(labels.count)
                return Array(suffix) == labels ? labels.count : nil

            case .wildcard:
                // Wildcard rule "*.b" matches any label under "b".
                // Total matched labels = labels.count + 1 (the wildcard label)
                guard hostLabels.count >= labels.count + 1 else { return nil }
                let suffix = hostLabels.suffix(labels.count)
                return Array(suffix) == labels ? (labels.count + 1) : nil

            case .exception:
                // Exception rule "!a.b" matches host suffix "a.b"
                guard hostLabels.count >= labels.count else { return nil }
                let suffix = hostLabels.suffix(labels.count)
                return Array(suffix) == labels ? labels.count : nil
            }
        }
    }

    /// Shared singleton instance with preloaded standard and platform rules.
    public static let shared = PublicSuffixList()

    private let lock = NSLock()
    private var rules: [Rule] = []

    public init() {
        resetToDefaults()
    }

    /// Resets all rules to the standard built-in PSL rule set.
    public func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        rules.removeAll(keepingCapacity: true)
        for raw in Self.defaultRuleStrings {
            if let rule = Rule(ruleString: raw) {
                rules.append(rule)
            }
        }
    }

    /// Adds an arbitrary PSL rule string (exact, wildcard `*.foo`, or exception `!bar.foo`).
    public func addRule(_ ruleString: String) {
        guard let rule = Rule(ruleString: ruleString) else { return }
        lock.lock()
        defer { lock.unlock() }
        rules.append(rule)
    }

    /// Adds a collection of PSL rule strings.
    public func addRules(_ ruleStrings: [String]) {
        let parsed = ruleStrings.compactMap { Rule(ruleString: $0) }
        lock.lock()
        defer { lock.unlock() }
        rules.append(contentsOf: parsed)
    }

    /// Extracts the public suffix (effective TLD) from a host string.
    public func publicSuffix(for host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // IP addresses, localhost, or single unqualified labels do not have a public suffix
        if Self.isIPAddress(trimmed) || trimmed == "localhost" || !trimmed.contains(".") {
            return nil
        }

        let hostLabels = trimmed.split(separator: ".").map(String.init)
        guard !hostLabels.isEmpty else { return nil }

        lock.lock()
        let currentRules = self.rules
        lock.unlock()

        // Match against all rules
        var matchingRules: [(rule: Rule, matchedCount: Int)] = []
        for rule in currentRules {
            if let count = rule.match(hostLabels: hostLabels) {
                matchingRules.append((rule, count))
            }
        }

        // Determine prevailing rule per PSL specification:
        // 1. If any exception rule matches, the exception rule with the most labels wins.
        // 2. Otherwise, the matching rule (exact or wildcard) with the most labels wins.
        // 3. If no rules match, the prevailing rule is "*" (1 label).
        let prevailingException = matchingRules
            .filter { $0.rule.kind == .exception }
            .max { $0.rule.labels.count < $1.rule.labels.count }

        let suffixLabelCount: Int
        if let exception = prevailingException {
            // "If the prevailing rule is an exception rule, modify it by removing the leftmost label."
            suffixLabelCount = max(1, exception.rule.labels.count - 1)
        } else if let bestMatch = matchingRules.max(by: { $0.matchedCount < $1.matchedCount }) {
            suffixLabelCount = bestMatch.matchedCount
        } else {
            // Default rule: 1 label (e.g. .com, .org)
            suffixLabelCount = 1
        }

        guard hostLabels.count >= suffixLabelCount else {
            return trimmed
        }
        return hostLabels.suffix(suffixLabelCount).joined(separator: ".")
    }

    /// Resolves the registrable domain (eTLD+1) for a host string per RFC 6265bis.
    public func registrableDomain(for host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // IP addresses and localhost are self-registrable
        if Self.isIPAddress(trimmed) || trimmed == "localhost" || !trimmed.contains(".") {
            return trimmed
        }

        guard let suffix = publicSuffix(for: trimmed) else {
            return trimmed
        }

        let suffixLabels = suffix.split(separator: ".").map(String.init)
        let hostLabels = trimmed.split(separator: ".").map(String.init)

        if hostLabels.count <= suffixLabels.count {
            return nil
        }

        let registrableCount = suffixLabels.count + 1
        let registrableLabels = hostLabels.suffix(registrableCount)
        return registrableLabels.joined(separator: ".")
    }

    // MARK: - Static Convenience Accessors

    public static func publicSuffix(for host: String) -> String? {
        shared.publicSuffix(for: host)
    }

    public static func registrableDomain(for host: String) -> String? {
        shared.registrableDomain(for: host)
    }

    public static func isSameRegistrableDomain(_ lhsHost: String, _ rhsHost: String) -> Bool {
        let lhs = lhsHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhs = rhsHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lhs.isEmpty || rhs.isEmpty { return false }
        if lhs == rhs { return true }
        guard let leftReg = registrableDomain(for: lhs),
              let rightReg = registrableDomain(for: rhs) else {
            return false
        }
        return leftReg == rightReg
    }

    public static func isIPAddress(_ host: String) -> Bool {
        var sin = sockaddr_in()
        if host.withCString({ inet_pton(AF_INET, $0, &sin.sin_addr) }) == 1 {
            return true
        }
        var sin6 = sockaddr_in6()
        if host.withCString({ inet_pton(AF_INET6, $0, &sin6.sin6_addr) }) == 1 {
            return true
        }
        return false
    }

    // MARK: - Built-in PSL Rules

    private static let defaultRuleStrings: [String] = [
        // Multi-part cloud and platform hosting providers
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
        "myshopify.com",

        // Common country-code second level domains (ccSLDs)
        "co.uk", "org.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "ac.uk", "gov.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz", "edu.nz",
        "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in", "res.in", "gov.in", "ac.in", "edu.in",
        "co.il", "org.il", "net.il", "ac.il", "gov.il", "k12.il",
        "co.za", "org.za", "net.za", "gov.za", "ac.za", "edu.za",
        "co.jp", "ne.jp", "or.jp", "go.jp", "ac.jp", "ed.jp", "ad.jp", "gr.jp", "lg.jp",
        "com.br", "net.br", "org.br", "gov.br", "edu.br", "art.br", "esp.br", "etc.br",
        "com.sg", "net.sg", "org.sg", "gov.sg", "edu.sg", "per.sg",
        "com.my", "net.my", "org.my", "gov.my", "edu.my", "mil.my",
        "co.kr", "ne.kr", "or.kr", "go.kr", "ac.kr", "re.kr", "es.kr", "ms.kr", "hs.kr",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.tw", "net.tw", "org.tw", "gov.tw", "edu.tw", "idv.tw",
        "com.hk", "net.hk", "org.hk", "gov.hk", "edu.hk", "idv.hk",
        "com.mx", "net.mx", "org.mx", "gob.mx", "edu.mx",
        "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr", "bel.tr", "k12.tr",
        "com.ru", "net.ru", "org.ru", "gov.ru", "edu.ru",

        // Standard PSL Wildcard Rules
        "*.ck",
        "*.er",
        "*.bd",
        "*.nom.br",
        "*.sch.uk",
        "*.tokyo.jp",
        "*.kawasaki.jp",
        "*.kitakyushu.jp",
        "*.kobe.jp",
        "*.nagoya.jp",
        "*.sapporo.jp",
        "*.sendai.jp",
        "*.yokohama.jp",

        // Standard PSL Exception Rules
        "!www.ck",
        "!metro.tokyo.jp",
        "!city.kawasaki.jp",
        "!city.kitakyushu.jp",
        "!city.kobe.jp",
        "!city.nagoya.jp",
        "!city.sapporo.jp",
        "!city.sendai.jp",
        "!city.yokohama.jp"
    ]
}
