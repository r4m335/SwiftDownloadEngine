import Foundation

#if canImport(WebKit)
import WebKit
#endif

// MARK: - WebKit Content Blocker Rule Representation

/// WebKit action types supported by Apple's `WKContentRuleListStore`.
public enum ContentBlockerActionType: String, Codable, Sendable, Equatable, Hashable {
    case block = "block"
    case blockCookies = "block-cookies"
    case cssDisplayNone = "css-display-none"
    case ignorePreviousRules = "ignore-previous-rules"
    case makeHTTPS = "make-https"
}

/// Resource types that can trigger a content blocking rule.
public enum ContentBlockerResourceType: String, Codable, Sendable, Equatable, Hashable {
    case document = "document"
    case image = "image"
    case styleSheet = "style-sheet"
    case script = "script"
    case font = "font"
    case raw = "raw"
    case svgDocument = "svg-document"
    case media = "media"
    case popup = "popup"
}

/// Load context constraint: first-party or third-party.
public enum ContentBlockerLoadType: String, Codable, Sendable, Equatable, Hashable {
    case firstParty = "first-party"
    case thirdParty = "third-party"
}

/// Defines matching conditions for a WebKit content blocker rule.
public struct ContentBlockerTrigger: Codable, Sendable, Equatable, Hashable {
    public let urlFilter: String
    public let urlFilterIsCaseSensitive: Bool?
    public let resourceType: [ContentBlockerResourceType]?
    public let loadType: [ContentBlockerLoadType]?
    public let ifDomain: [String]?
    public let unlessDomain: [String]?
    public let ifTopUrl: [String]?
    public let unlessTopUrl: [String]?

    public init(
        urlFilter: String,
        urlFilterIsCaseSensitive: Bool? = nil,
        resourceType: [ContentBlockerResourceType]? = nil,
        loadType: [ContentBlockerLoadType]? = nil,
        ifDomain: [String]? = nil,
        unlessDomain: [String]? = nil,
        ifTopUrl: [String]? = nil,
        unlessTopUrl: [String]? = nil
    ) {
        self.urlFilter = urlFilter
        self.urlFilterIsCaseSensitive = urlFilterIsCaseSensitive
        self.resourceType = resourceType
        self.loadType = loadType
        self.ifDomain = ifDomain
        self.unlessDomain = unlessDomain
        self.ifTopUrl = ifTopUrl
        self.unlessTopUrl = unlessTopUrl
    }

    enum CodingKeys: String, CodingKey {
        case urlFilter = "url-filter"
        case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
        case resourceType = "resource-type"
        case loadType = "load-type"
        case ifDomain = "if-domain"
        case unlessDomain = "unless-domain"
        case ifTopUrl = "if-top-url"
        case unlessTopUrl = "unless-top-url"
    }
}

/// Defines the action executed by WebKit when a trigger condition matches.
public struct ContentBlockerAction: Codable, Sendable, Equatable, Hashable {
    public let type: ContentBlockerActionType
    public let selector: String?

    public init(type: ContentBlockerActionType, selector: String? = nil) {
        self.type = type
        self.selector = selector
    }

    public static func block() -> ContentBlockerAction {
        ContentBlockerAction(type: .block)
    }

    public static func blockCookies() -> ContentBlockerAction {
        ContentBlockerAction(type: .blockCookies)
    }

    public static func cssDisplayNone(selector: String) -> ContentBlockerAction {
        ContentBlockerAction(type: .cssDisplayNone, selector: selector)
    }

    public static func ignorePreviousRules() -> ContentBlockerAction {
        ContentBlockerAction(type: .ignorePreviousRules)
    }
}

/// A complete WebKit content blocker rule composed of a trigger and an action.
public struct ContentBlockerRule: Codable, Sendable, Equatable, Hashable {
    public let trigger: ContentBlockerTrigger
    public let action: ContentBlockerAction

    public init(trigger: ContentBlockerTrigger, action: ContentBlockerAction) {
        self.trigger = trigger
        self.action = action
    }
}

/// A named collection of content blocker rules that compiles to a `WKContentRuleList`.
public struct ContentBlockerList: Codable, Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let version: String
    public let rules: [ContentBlockerRule]

    public init(
        identifier: String,
        name: String,
        version: String = "1.0",
        rules: [ContentBlockerRule]
    ) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.rules = rules
    }

    /// Serializes the rule array to JSON string ready for `WKContentRuleListStore`.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(rules)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ContentBlockerError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode rules to UTF-8"])
        }
        return string
    }
}

// MARK: - EasyList & Custom Filter List Converter

/// Converts standard Adblock Plus / EasyList text format rules into WebKit JSON format.
/// Supports future filter list updates and community blocklists without app updates.
public enum EasyListRuleConverter {

    public static func convert(
        text: String,
        identifier: String = "custom-easylist",
        name: String = "Custom List"
    ) -> ContentBlockerList {
        var rules: [ContentBlockerRule] = []
        let lines = text.components(separatedBy: .newlines)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") {
                continue // Comment or metadata header
            }

            // 1. Element hiding rule: [domains]##selector
            if let separatorRange = line.range(of: "##") {
                let domainPart = String(line[..<separatorRange.lowerBound])
                let selectorPart = String(line[separatorRange.upperBound...])

                if !selectorPart.isEmpty {
                    var ifDomains: [String]? = nil
                    var unlessDomains: [String]? = nil

                    if !domainPart.isEmpty {
                        let domains = domainPart.components(separatedBy: ",")
                        var included: [String] = []
                        var excluded: [String] = []

                        for d in domains {
                            let trimmed = d.trimmingCharacters(in: .whitespaces)
                            if trimmed.hasPrefix("~") {
                                excluded.append(String(trimmed.dropFirst()))
                            } else if !trimmed.isEmpty {
                                included.append(trimmed)
                            }
                        }
                        if !included.isEmpty { ifDomains = included }
                        if !excluded.isEmpty { unlessDomains = excluded }
                    }

                    let trigger = ContentBlockerTrigger(
                        urlFilter: ".*",
                        ifDomain: ifDomains,
                        unlessDomain: unlessDomains
                    )
                    rules.append(ContentBlockerRule(trigger: trigger, action: .cssDisplayNone(selector: selectorPart)))
                    continue
                }
            }

            // 2. Exception rule: @@||domain^
            if line.hasPrefix("@@||") {
                let stripped = String(line.dropFirst(4))
                let domain = stripped.components(separatedBy: "^").first ?? stripped
                if !domain.isEmpty {
                    let escaped = NSRegularExpression.escapedPattern(for: domain)
                    let trigger = ContentBlockerTrigger(urlFilter: ".*" + escaped + ".*")
                    rules.append(ContentBlockerRule(trigger: trigger, action: .ignorePreviousRules()))
                    continue
                }
            }

            // 3. Domain block rule: ||domain^
            if line.hasPrefix("||") {
                let stripped = String(line.dropFirst(2))
                let parts = stripped.components(separatedBy: "$")
                let filterPart = parts[0].components(separatedBy: "^").first ?? parts[0]

                var resourceTypes: [ContentBlockerResourceType]? = nil
                var loadTypes: [ContentBlockerLoadType]? = nil

                if parts.count > 1 {
                    let options = parts[1].components(separatedBy: ",")
                    for opt in options {
                        switch opt.lowercased() {
                        case "image": resourceTypes = (resourceTypes ?? []) + [.image]
                        case "script": resourceTypes = (resourceTypes ?? []) + [.script]
                        case "third-party": loadTypes = [.thirdParty]
                        case "popup": resourceTypes = (resourceTypes ?? []) + [.popup]
                        default: break
                        }
                    }
                }

                if !filterPart.isEmpty {
                    let escaped = NSRegularExpression.escapedPattern(for: filterPart)
                    let trigger = ContentBlockerTrigger(
                        urlFilter: ".*" + escaped + ".*",
                        resourceType: resourceTypes,
                        loadType: loadTypes
                    )
                    rules.append(ContentBlockerRule(trigger: trigger, action: .block()))
                    continue
                }
            }

            // 4. Fallback keyword filter
            if !line.contains("#") && !line.contains("$") && line.count > 3 {
                let escaped = NSRegularExpression.escapedPattern(for: line)
                let trigger = ContentBlockerTrigger(urlFilter: ".*" + escaped + ".*")
                rules.append(ContentBlockerRule(trigger: trigger, action: .block()))
            }
        }

        return ContentBlockerList(identifier: identifier, name: name, rules: rules)
    }
}

// MARK: - Built-in High Performance Rule Sets

public enum ContentBlockerDefaultRules {

    /// Standard EasyList-compatible rules targeting invasive ad servers, banners, and popunders.
    public static func makeAdBlockList(whitelistedDomains: [String] = []) -> ContentBlockerList {
        let unless = whitelistedDomains.isEmpty ? nil : whitelistedDomains

        var rules: [ContentBlockerRule] = []

        // 1. High-frequency advertising networks & ad exchanges
        let adDomains = [
            "*doubleclick.net*",
            "*googleadservices.com*",
            "*googlesyndication.com*",
            "*adservice.google.*",
            "*admob.com*",
            "*taboola.com*",
            "*outbrain.com*",
            "*popads.net*",
            "*propellerads.com*",
            "*exoclick.com*",
            "*adsterra.com*",
            "*popcash.net*",
            "*trafficjunky.net*",
            "*clickadu.com*",
            "*yllix.com*",
            "*mgid.com*",
            "*revcontent.com*",
            "*adcolony.com*",
            "*vungle.com*",
            "*applovin.com*",
            "*inmobi.com*",
            "*chartboost.com*",
            "*unityads.unity3d.com*",
            "*adnxs.com*",
            "*criteo.com*",
            "*openx.net*",
            "*rubiconproject.com*",
            "*pubmatic.com*",
            "*serving-sys.com*",
            "*zergnet.com*"
        ]

        for domainPattern in adDomains {
            rules.append(ContentBlockerRule(
                trigger: ContentBlockerTrigger(
                    urlFilter: domainPattern,
                    unlessDomain: unless
                ),
                action: .block()
            ))
        }

        // 2. URL keyword and query patterns indicative of banner / popup traffic
        let urlKeywords = [
            ".*[&?/](ad_unit|ad_type|adserver|adzone|affiliate|bannerid|popunder|sponsor).*",
            ".*/(ads|banners|popups)/.*\\.(js|gif|png|jpg).*"
        ]

        for pattern in urlKeywords {
            rules.append(ContentBlockerRule(
                trigger: ContentBlockerTrigger(
                    urlFilter: pattern,
                    loadType: [.thirdParty],
                    unlessDomain: unless
                ),
                action: .block()
            ))
        }

        // 3. Cosmetic element hiding: suppress aggressive empty ad boxes and floating overlays
        let cosmeticSelectors = [
            ".ad, .ads, .ad-banner, .ad-container, .ad-wrapper, .ad-box, .advertisement",
            "[id^='ad-'], [id^='ad_'], [class^='ad-'], [class^='ad_']",
            "[id*='popunder'], [class*='popunder'], [id*='interstitial']",
            ".sponsored-content, .promoted-post, .taboola-ad, .outbrain-ad",
            "iframe[src*='doubleclick'], iframe[src*='googleads']"
        ]

        for selector in cosmeticSelectors {
            rules.append(ContentBlockerRule(
                trigger: ContentBlockerTrigger(
                    urlFilter: ".*",
                    unlessDomain: unless
                ),
                action: .cssDisplayNone(selector: selector)
            ))
        }

        return ContentBlockerList(
            identifier: "lid-adblock-standard",
            name: "LID Standard Ad Blocker",
            version: "1.0",
            rules: rules
        )
    }

    /// Privacy and tracker protection rules targeting telemetry beacons, hotjars, and fingerprinters.
    public static func makeTrackerBlockList(whitelistedDomains: [String] = []) -> ContentBlockerList {
        let unless = whitelistedDomains.isEmpty ? nil : whitelistedDomains

        var rules: [ContentBlockerRule] = []

        let trackerDomains = [
            "*google-analytics.com*",
            "*googletagmanager.com*",
            "*hotjar.com*",
            "*scorecardresearch.com*",
            "*quantserve.com*",
            "*statcounter.com*",
            "*crazyegg.com*",
            "*branch.io*",
            "*segment.com*",
            "*mixpanel.com*",
            "*newrelic.com*",
            "*datadoghq-browser-agent.com*",
            "*yandex.ru/metrika*",
            "*mc.yandex.ru*",
            "*clarity.ms*"
        ]

        for domain in trackerDomains {
            rules.append(ContentBlockerRule(
                trigger: ContentBlockerTrigger(
                    urlFilter: domain,
                    unlessDomain: unless
                ),
                action: .block()
            ))
            rules.append(ContentBlockerRule(
                trigger: ContentBlockerTrigger(
                    urlFilter: domain,
                    unlessDomain: unless
                ),
                action: .blockCookies()
            ))
        }

        // Malicious crypto-miners
        let minerDomains = [
            "*coinhive.com*",
            "*coin-hive.com*",
            "*authedmine.com*",
            "*cryptoloot.pro*",
            "*webminepool.com*"
        ]

        for domain in minerDomains {
            rules.append(ContentBlockerRule(
                trigger: ContentBlockerTrigger(
                    urlFilter: domain,
                    unlessDomain: unless
                ),
                action: .block()
            ))
        }

        return ContentBlockerList(
            identifier: "lid-tracker-protection",
            name: "LID Tracker & Privacy Protection",
            version: "1.0",
            rules: rules
        )
    }
}

// MARK: - Domain Normalization & Whitelisting Helpers

public enum BrowserDomainMatcher {

    /// Extracts and normalizes a root or registered domain from a given URL or string.
    public static func normalizeDomain(_ raw: String) -> String {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: str), let host = url.host {
            str = host
        }
        if str.hasPrefix("www.") {
            str = String(str.dropFirst(4))
        }
        return str
    }

    /// Checks whether a given host or URL is contained in or a subdomain of a whitelisted domain list.
    public static func isDomainWhitelisted(_ hostOrURL: String, in whitelistedDomains: [String]) -> Bool {
        let domain = normalizeDomain(hostOrURL)
        guard !domain.isEmpty else { return false }

        for entry in whitelistedDomains {
            let normalizedEntry = normalizeDomain(entry)
            guard !normalizedEntry.isEmpty else { continue }
            if domain == normalizedEntry || domain.hasSuffix("." + normalizedEntry) {
                return true
            }
        }
        return false
    }
}

// MARK: - Native WebKit Content Blocker Manager

#if canImport(WebKit)
/// Central coordinator managing compilation, caching, and lifecycle attachment of Apple's `WKContentRuleListStore`.
@MainActor
public final class BrowserContentBlocker: ObservableObject {
    public static let shared = BrowserContentBlocker()

    public static let adBlockListID = "lid-adblock-standard"
    public static let trackerBlockListID = "lid-tracker-protection"

    @Published public private(set) var isCompiling: Bool = false
    @Published public private(set) var compiledRuleLists: [String: WKContentRuleList] = [:]
    @Published public private(set) var registeredCustomLists: [String: ContentBlockerList] = [:]
    @Published public private(set) var lastCompilationError: String? = nil

    private init() {}

    // MARK: - Rule Compilation & Preparation

    /// Pre-compiles built-in rule lists into WebKit's native store and caches them in memory.
    public func prepareRuleLists(whitelistedDomains: [String] = []) async {
        isCompiling = true
        lastCompilationError = nil
        defer { isCompiling = false }

        do {
            let adList = ContentBlockerDefaultRules.makeAdBlockList(whitelistedDomains: whitelistedDomains)
            let adJSON = try adList.jsonString()
            let compiledAds = try await compileRuleList(identifier: Self.adBlockListID, json: adJSON)
            compiledRuleLists[Self.adBlockListID] = compiledAds

            let trackerList = ContentBlockerDefaultRules.makeTrackerBlockList(whitelistedDomains: whitelistedDomains)
            let trackerJSON = try trackerList.jsonString()
            let compiledTrackers = try await compileRuleList(identifier: Self.trackerBlockListID, json: trackerJSON)
            compiledRuleLists[Self.trackerBlockListID] = compiledTrackers

            for (id, customList) in registeredCustomLists {
                if let customJSON = try? customList.jsonString() {
                    let compiled = try await compileRuleList(identifier: id, json: customJSON)
                    compiledRuleLists[id] = compiled
                }
            }
        } catch {
            lastCompilationError = error.localizedDescription
        }
    }

    /// Compiles an individual rule list using `WKContentRuleListStore.default()`.
    private func compileRuleList(identifier: String, json: String) async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else {
            throw NSError(domain: "BrowserContentBlocker", code: 2, userInfo: [NSLocalizedDescriptionKey: "WKContentRuleListStore is unavailable on this device."])
        }

        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { ruleList, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let ruleList = ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(throwing: NSError(domain: "BrowserContentBlocker", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown error compiling content rule list"]))
                }
            }
        }
    }

    // MARK: - WebKit Configuration Lifecycle Attachment

    /// Injects active content rule lists into a `WKWebViewConfiguration`.
    public func apply(
        to configuration: WKWebViewConfiguration,
        isEnabled: Bool,
        isCurrentDomainWhitelisted: Bool
    ) {
        let userContentController = configuration.userContentController
        userContentController.removeAllContentRuleLists()

        guard isEnabled, !isCurrentDomainWhitelisted else { return }

        for (_, ruleList) in compiledRuleLists {
            userContentController.add(ruleList)
        }
    }

    /// Dynamically enables or disables content rules for a live `WKWebView` instance.
    public func update(
        for webView: WKWebView,
        isEnabled: Bool,
        isCurrentDomainWhitelisted: Bool
    ) {
        apply(
            to: webView.configuration,
            isEnabled: isEnabled,
            isCurrentDomainWhitelisted: isCurrentDomainWhitelisted
        )
    }

    // MARK: - Extensible Filter Lists (Future Updates & Subscriptions)

    /// Registers a custom EasyList/ABP text blocklist or community URL feed.
    public func registerCustomEasyList(identifier: String, name: String, rawText: String) async throws {
        let parsed = EasyListRuleConverter.convert(text: rawText, identifier: identifier, name: name)
        registeredCustomLists[identifier] = parsed
        let json = try parsed.jsonString()
        let compiled = try await compileRuleList(identifier: identifier, json: json)
        compiledRuleLists[identifier] = compiled
    }

    /// Registers custom JSON rules directly.
    public func registerCustomJSONList(identifier: String, name: String, json: String) async throws {
        let compiled = try await compileRuleList(identifier: identifier, json: json)
        compiledRuleLists[identifier] = compiled
    }

    /// Removes a custom rule list.
    public func removeCustomList(identifier: String) async {
        registeredCustomLists.removeValue(forKey: identifier)
        compiledRuleLists.removeValue(forKey: identifier)
        if let store = WKContentRuleListStore.default() {
            _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.removeContentRuleList(forIdentifier: identifier) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }
}
#endif

// MARK: - Redirect & Popup Confirmation Models

/// Identifies the motivation for asking user confirmation on a redirect or popup.
public enum BrowserRedirectReason: String, Sendable, Equatable, Codable {
    case automaticWindowOpen = "JavaScript opened a new window"
    case automaticCrossDomainRedirect = "Automatic cross-domain redirect"
    case suspiciousExternalRedirect = "Suspicious external website redirect"
    case externalAppScheme = "External application request"
}

/// A structured model describing a redirect or popup event awaiting user confirmation.
public struct BrowserRedirectPrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let destinationURL: URL
    public let originURL: URL?
    public let sourceTabID: UUID?
    public let reason: BrowserRedirectReason
    public let isSuspicious: Bool

    public init(
        id: UUID = UUID(),
        destinationURL: URL,
        originURL: URL?,
        sourceTabID: UUID? = nil,
        reason: BrowserRedirectReason,
        isSuspicious: Bool
    ) {
        self.id = id
        self.destinationURL = destinationURL
        self.originURL = originURL
        self.sourceTabID = sourceTabID
        self.reason = reason
        self.isSuspicious = isSuspicious
    }

    public var destinationHost: String {
        guard let host = destinationURL.host, !host.isEmpty else {
            return destinationURL.absoluteString
        }
        return host
    }

    public var originHost: String {
        guard let host = originURL?.host, !host.isEmpty else {
            return "Current Website"
        }
        return host
    }
}

/// The actionable disposition for a web navigation action or popup request.
public enum BrowserNavigationDecision: Equatable, Sendable {
    case allowSameTab
    case openInNewTab
    case blockPopunder
    case promptConfirmation(reason: BrowserRedirectReason, isSuspicious: Bool)
    case promptExternalScheme(isSuspicious: Bool)
}

// MARK: - Popup & Aggressive Navigation Policy Evaluator

public enum BrowserPopupPolicyEvaluator {

    /// Determines whether a `createWebViewWith` popup or secondary window should be allowed.
    /// Unsolicited script popups and ad triggers are rejected when the blocker is enabled.
    public static func shouldAllowPopup(
        navigationType: Int,
        isUserInitiated: Bool,
        targetFrameIsNil: Bool,
        isPopupBlockerEnabled: Bool
    ) -> Bool {
        guard isPopupBlockerEnabled else {
            return true // Blocker disabled: default WebKit behaviour
        }

        // Link clicks explicitly triggered by user tap (navigationType == 0)
        if navigationType == 0 && isUserInitiated {
            return true
        }

        // Disallow unsolicited window.open or target=_blank script popups
        if targetFrameIsNil && !isUserInitiated {
            return false
        }

        return false
    }

    /// Evaluates whether a redirect URL represents an aggressive external app-store hijack or scheme spam.
    public static func isSuspiciousExternalRedirect(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }

        // Allowed standard web schemes
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "blob" || scheme == "data" || scheme == "magnet" {
            return false
        }

        // Aggressive app store hijacks often executed without user consent
        let suspiciousSchemes = ["itms-appss", "itms-services", "facetime", "sms", "tel"]
        return suspiciousSchemes.contains(scheme)
    }

    /// Checks whether a host belongs to known aggressive ad or popunder networks.
    public static func isKnownAdOrPopunderDomain(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        let knownAdPatterns = [
            "doubleclick",
            "googleadservices",
            "googlesyndication",
            "adservice.google",
            "taboola",
            "outbrain",
            "popads",
            "propellerads",
            "exoclick",
            "adsterra",
            "popcash",
            "trafficjunky",
            "clickadu",
            "yllix",
            "mgid",
            "revcontent",
            "criteo",
            "adnxs",
            "openx",
            "rubiconproject",
            "pubmatic",
            "zergnet",
            "popunder"
        ]
        for pattern in knownAdPatterns {
            if host.contains(pattern) {
                return true
            }
        }
        return false
    }

    /// Checks whether two URLs belong to the same registered site or domain hierarchy.
    public static func isSameSite(currentURL: URL?, destinationURL: URL) -> Bool {
        guard let currentURL = currentURL,
              let currentHost = currentURL.host?.lowercased(),
              !currentHost.isEmpty,
              currentURL.scheme != "about" else {
            // Initial load or blank page
            return true
        }

        guard let destHost = destinationURL.host?.lowercased(), !destHost.isEmpty else {
            return true
        }

        let normCurrent = BrowserDomainMatcher.normalizeDomain(currentHost)
        let normDest = BrowserDomainMatcher.normalizeDomain(destHost)

        if normCurrent == normDest {
            return true
        }

        if normDest.hasSuffix("." + normCurrent) || normCurrent.hasSuffix("." + normDest) {
            return true
        }

        return false
    }

    /// Evaluates a `createWebViewWith` window.open or secondary window request.
    public static func evaluateWindowOpen(
        destinationURL: URL?,
        currentURL: URL?,
        isUserInitiated: Bool,
        isPopupBlockerEnabled: Bool
    ) -> BrowserNavigationDecision {
        guard isPopupBlockerEnabled else {
            return isUserInitiated ? .openInNewTab : .allowSameTab
        }

        // 1. User clicked a link with target="_blank" -> Open in new tab
        if isUserInitiated {
            return .openInNewTab
        }

        // 2. Unsolicited script popup
        guard let destinationURL = destinationURL else {
            return .blockPopunder
        }

        // 3. Ad network popunder -> block
        if isKnownAdOrPopunderDomain(host: destinationURL.host) {
            return .blockPopunder
        }

        // 4. Suspicious redirect / external scheme -> prompt with warning
        if isSuspiciousExternalRedirect(url: destinationURL) {
            return .promptConfirmation(reason: .suspiciousExternalRedirect, isSuspicious: true)
        }

        // 5. JavaScript window.open -> prompt user for confirmation
        return .promptConfirmation(reason: .automaticWindowOpen, isSuspicious: false)
    }

    /// Evaluates navigation requests inside `decidePolicyFor navigationAction`.
    public static func evaluateNavigation(
        destinationURL: URL,
        currentURL: URL?,
        navigationType: Int,
        isTargetFrameNil: Bool,
        isPopupBlockerEnabled: Bool,
        originChain: Set<String> = []
    ) -> BrowserNavigationDecision {
        let scheme = destinationURL.scheme?.lowercased() ?? ""

        // 1. External custom app scheme (e.g. tel:, sms:, itms-appss:, whatsapp:)
        if scheme != "http" && scheme != "https" && scheme != "about" && scheme != "blob" && scheme != "data" && scheme != "magnet" {
            let isSuspicious = isSuspiciousExternalRedirect(url: destinationURL)
            return .promptExternalScheme(isSuspicious: isSuspicious)
        }

        // 2. User-initiated link click (navigationType == 0 is .linkActivated)
        if navigationType == 0 {
            if isTargetFrameNil {
                // User tapped a link with target="_blank" -> Open in a new tab
                return .openInNewTab
            }
            return .allowSameTab
        }

        // 3. User form submission (1/2), Back/Forward (2), or Reload (3)
        if navigationType != 5 { // 5 is .other (script redirects, meta refreshes, HTTP 3xx)
            return .allowSameTab
        }

        // 4. Initial load or blank page -> always allow without prompting
        guard let currentURL = currentURL,
              let currentHost = currentURL.host,
              !currentHost.isEmpty,
              currentURL.scheme != "about" else {
            return .allowSameTab
        }

        // If popup blocker is disabled, allow navigation
        guard isPopupBlockerEnabled else {
            return .allowSameTab
        }

        // 5. Ad network redirect or popunder -> block
        if isKnownAdOrPopunderDomain(host: destinationURL.host) {
            return .blockPopunder
        }

        // 6. Same site / subdomain navigation -> allow
        if isSameSite(currentURL: currentURL, destinationURL: destinationURL) {
            return .allowSameTab
        }

        // 7. Legitimate auth/return navigation (matches an origin in the active tab's chain)
        if let destHost = destinationURL.host {
            let normDest = BrowserDomainMatcher.normalizeDomain(destHost)
            for origin in originChain {
                let normOrigin = BrowserDomainMatcher.normalizeDomain(origin)
                if normDest == normOrigin || normDest.hasSuffix("." + normOrigin) {
                    return .allowSameTab
                }
            }
        }

        // 8. Suspicious redirect -> prompt with warning
        if isSuspiciousExternalRedirect(url: destinationURL) {
            return .promptConfirmation(reason: .suspiciousExternalRedirect, isSuspicious: true)
        }

        // 9. Unsolicited cross-domain redirect -> ask for confirmation
        return .promptConfirmation(reason: .automaticCrossDomainRedirect, isSuspicious: false)
    }
}
