import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class BrowserContentBlockerTests: XCTestCase {

    // MARK: - Rule Model & JSON Serialization Tests

    func testContentBlockerRuleJSONEncodingConformsToWebKitSchema() throws {
        let trigger = ContentBlockerTrigger(
            urlFilter: ".*doubleclick\\.net.*",
            urlFilterIsCaseSensitive: false,
            resourceType: [.script, .image],
            loadType: [.thirdParty],
            ifDomain: ["*example.com"],
            unlessDomain: ["*whitelisted.com"]
        )
        let action = ContentBlockerAction(type: .block)
        let rule = ContentBlockerRule(trigger: trigger, action: action)
        let list = ContentBlockerList(identifier: "test-list", name: "Test List", rules: [rule])

        let json = try list.jsonString()

        // Verify JSON contains Apple WebKit kebab-case keys
        XCTAssertTrue(json.contains("\"url-filter\""))
        XCTAssertTrue(json.contains("\"resource-type\""))
        XCTAssertTrue(json.contains("\"load-type\""))
        XCTAssertTrue(json.contains("\"if-domain\""))
        XCTAssertTrue(json.contains("\"unless-domain\""))
        XCTAssertTrue(json.contains("\"type\" : \"block\"") || json.contains("\"type\": \"block\"") || json.contains("\"type\":\"block\""))

        // Verify JSON can be deserialized back into raw JSON object
        let data = json.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertNotNil(object)
        XCTAssertEqual(object?.count, 1)

        let first = object?[0]
        let parsedTrigger = first?["trigger"] as? [String: Any]
        let parsedAction = first?["action"] as? [String: Any]

        XCTAssertEqual(parsedTrigger?["url-filter"] as? String, ".*doubleclick\\.net.*")
        XCTAssertEqual(parsedAction?["type"] as? String, "block")
    }

    func testCSSDisplayNoneRuleJSONSerialization() throws {
        let trigger = ContentBlockerTrigger(urlFilter: ".*")
        let action = ContentBlockerAction.cssDisplayNone(selector: ".ad-banner, [id^='ad-']")
        let rule = ContentBlockerRule(trigger: trigger, action: action)
        let list = ContentBlockerList(identifier: "cosmetic-list", name: "Cosmetic List", rules: [rule])

        let json = try list.jsonString()
        XCTAssertTrue(json.contains("\"css-display-none\""))
        XCTAssertTrue(json.contains("\"selector\""))
        XCTAssertTrue(json.contains(".ad-banner"))
    }

    // MARK: - Built-in Rule Sets Generation

    func testBuiltInAdBlockListContainsHighFrequencyNetworks() {
        let adList = ContentBlockerDefaultRules.makeAdBlockList()
        XCTAssertEqual(adList.identifier, "lid-adblock-standard")
        XCTAssertFalse(adList.rules.isEmpty)

        // Verify major ad networks are covered
        let allPatterns = adList.rules.map { $0.trigger.urlFilter }
        XCTAssertTrue(allPatterns.contains("*doubleclick.net*"))
        XCTAssertTrue(allPatterns.contains("*googleadservices.com*"))
        XCTAssertTrue(allPatterns.contains("*popads.net*"))
        XCTAssertTrue(allPatterns.contains("*taboola.com*"))
        XCTAssertTrue(allPatterns.contains("*outbrain.com*"))

        // Verify cosmetic hiding rules are included
        let cosmeticRules = adList.rules.filter { $0.action.type == .cssDisplayNone }
        XCTAssertFalse(cosmeticRules.isEmpty)
        let hasAdBannerSelector = cosmeticRules.contains { $0.action.selector?.contains(".ad-banner") == true }
        XCTAssertTrue(hasAdBannerSelector)
    }

    func testBuiltInTrackerBlockListContainsTelemetryAndCookies() {
        let trackerList = ContentBlockerDefaultRules.makeTrackerBlockList()
        XCTAssertEqual(trackerList.identifier, "lid-tracker-protection")
        XCTAssertFalse(trackerList.rules.isEmpty)

        let allPatterns = trackerList.rules.map { $0.trigger.urlFilter }
        XCTAssertTrue(allPatterns.contains("*google-analytics.com*"))
        XCTAssertTrue(allPatterns.contains("*hotjar.com*"))
        XCTAssertTrue(allPatterns.contains("*coinhive.com*")) // crypto miner

        // Verify block-cookies actions are present
        let cookieBlockRules = trackerList.rules.filter { $0.action.type == .blockCookies }
        XCTAssertFalse(cookieBlockRules.isEmpty)
    }

    func testWhitelistedDomainsInjectedIntoUnlessDomain() {
        let whitelisted = ["news.ycombinator.com", "trusted-stream.org"]
        let adList = ContentBlockerDefaultRules.makeAdBlockList(whitelistedDomains: whitelisted)

        for rule in adList.rules {
            XCTAssertEqual(rule.trigger.unlessDomain, whitelisted)
        }
    }

    // MARK: - Domain Normalization & Whitelist Matching

    func testDomainMatcherNormalization() {
        XCTAssertEqual(BrowserDomainMatcher.normalizeDomain("https://WWW.Example.COM/path?query=1"), "example.com")
        XCTAssertEqual(BrowserDomainMatcher.normalizeDomain("HTTP://Subdomain.Test.Org:8080/"), "subdomain.test.org")
        XCTAssertEqual(BrowserDomainMatcher.normalizeDomain("   www.NYTimes.com   "), "nytimes.com")
        XCTAssertEqual(BrowserDomainMatcher.normalizeDomain("raw-domain.io"), "raw-domain.io")
    }

    func testDomainMatcherWhitelistingHierarchy() {
        let whitelisted = ["example.com", "trusted-partner.org"]

        // Exact match
        XCTAssertTrue(BrowserDomainMatcher.isDomainWhitelisted("example.com", in: whitelisted))
        XCTAssertTrue(BrowserDomainMatcher.isDomainWhitelisted("https://example.com/stream", in: whitelisted))

        // Subdomain match
        XCTAssertTrue(BrowserDomainMatcher.isDomainWhitelisted("sub.example.com", in: whitelisted))
        XCTAssertTrue(BrowserDomainMatcher.isDomainWhitelisted("cdn.video.example.com", in: whitelisted))

        // Negative matches
        XCTAssertFalse(BrowserDomainMatcher.isDomainWhitelisted("notexample.com", in: whitelisted))
        XCTAssertFalse(BrowserDomainMatcher.isDomainWhitelisted("malicious-example.com", in: whitelisted))
        XCTAssertFalse(BrowserDomainMatcher.isDomainWhitelisted("google.com", in: whitelisted))
        XCTAssertFalse(BrowserDomainMatcher.isDomainWhitelisted("", in: whitelisted))
    }

    // MARK: - EasyList / ABP Rule Converter Tests

    func testEasyListConverterParsesVariousRuleFormats() {
        let easylistText = """
        ! Title: EasyList Test
        ! Description: Test rules for converter
        [Adblock Plus 2.0]

        ! 1. Simple domain block
        ||adserver.com^

        ! 2. Block with options
        ||tracking.net^$third-party,script

        ! 3. Whitelist exception
        @@||safe-site.com^

        ! 4. Cosmetic element hiding (global)
        ##.ad-box

        ! 5. Cosmetic element hiding with domain constraints
        example.com,~bad.com##.sponsored-banner
        """

        let list = EasyListRuleConverter.convert(text: easylistText, identifier: "test-easylist", name: "Converted EasyList")

        XCTAssertEqual(list.identifier, "test-easylist")
        XCTAssertEqual(list.name, "Converted EasyList")
        XCTAssertEqual(list.rules.count, 5)

        // 1. Simple domain block
        let rule1 = list.rules[0]
        XCTAssertEqual(rule1.action.type, .block)
        XCTAssertTrue(rule1.trigger.urlFilter.contains("adserver\\.com"))

        // 2. Block with third-party and script
        let rule2 = list.rules[1]
        XCTAssertEqual(rule2.action.type, .block)
        XCTAssertEqual(rule2.trigger.loadType, [.thirdParty])
        XCTAssertEqual(rule2.trigger.resourceType, [.script])

        // 3. Whitelist exception
        let rule3 = list.rules[2]
        XCTAssertEqual(rule3.action.type, .ignorePreviousRules)
        XCTAssertTrue(rule3.trigger.urlFilter.contains("safe-site\\.com"))

        // 4. Cosmetic global
        let rule4 = list.rules[3]
        XCTAssertEqual(rule4.action.type, .cssDisplayNone)
        XCTAssertEqual(rule4.action.selector, ".ad-box")

        // 5. Cosmetic domain constrained
        let rule5 = list.rules[4]
        XCTAssertEqual(rule5.action.type, .cssDisplayNone)
        XCTAssertEqual(rule5.action.selector, ".sponsored-banner")
        XCTAssertEqual(rule5.trigger.ifDomain, ["example.com"])
        XCTAssertEqual(rule5.trigger.unlessDomain, ["bad.com"])
    }

    // MARK: - Popup & Redirect Policy Tests

    func testBrowserPopupPolicyEvaluator() {
        // 1. When popup blocker is enabled:
        // Unsolicited script popup is BLOCKED
        let blockUnsolicited = BrowserPopupPolicyEvaluator.shouldAllowPopup(
            navigationType: 5, // other
            isUserInitiated: false,
            targetFrameIsNil: true,
            isPopupBlockerEnabled: true
        )
        XCTAssertFalse(blockUnsolicited)

        // User link click with target=_blank is ALLOWED
        let allowUserClick = BrowserPopupPolicyEvaluator.shouldAllowPopup(
            navigationType: 0, // linkActivated
            isUserInitiated: true,
            targetFrameIsNil: true,
            isPopupBlockerEnabled: true
        )
        XCTAssertTrue(allowUserClick)

        // 2. When popup blocker is disabled:
        let allowAllWhenDisabled = BrowserPopupPolicyEvaluator.shouldAllowPopup(
            navigationType: 5,
            isUserInitiated: false,
            targetFrameIsNil: true,
            isPopupBlockerEnabled: false
        )
        XCTAssertTrue(allowAllWhenDisabled)
    }

    func testSuspiciousExternalRedirectDefense() {
        // Standard web navigation: NOT suspicious
        XCTAssertFalse(BrowserPopupPolicyEvaluator.isSuspiciousExternalRedirect(url: URL(string: "https://example.com")!))
        XCTAssertFalse(BrowserPopupPolicyEvaluator.isSuspiciousExternalRedirect(url: URL(string: "http://example.com/page")!))
        XCTAssertFalse(BrowserPopupPolicyEvaluator.isSuspiciousExternalRedirect(url: URL(string: "about:blank")!))
        XCTAssertFalse(BrowserPopupPolicyEvaluator.isSuspiciousExternalRedirect(url: URL(string: "blob:https://example.com/uuid")!))
        XCTAssertFalse(BrowserPopupPolicyEvaluator.isSuspiciousExternalRedirect(url: URL(string: "magnet:?xt=urn:btih:abc")!))

        // Malicious app store hijack and spam schemes: SUSPICIOUS
        XCTAssertTrue(BrowserPopupPolicyEvaluator.isSuspiciousExternalRedirect(url: URL(string: "itms-appss://apps.apple.com/app/id123")!))
        XCTAssertTrue(BrowserPopupPolicyEvaluator.isSuspiciousExternalRedirect(url: URL(string: "facetime://user@example.com")!))
        XCTAssertTrue(BrowserPopupPolicyEvaluator.isSuspiciousExternalRedirect(url: URL(string: "sms:+1234567890")!))
        XCTAssertTrue(BrowserPopupPolicyEvaluator.isSuspiciousExternalRedirect(url: URL(string: "tel:+1234567890")!))
    }

    // MARK: - Navigation & Redirect Decision Tests

    func testEvaluateWindowOpen_UserInitiatedOpensInNewTab() {
        let decision = BrowserPopupPolicyEvaluator.evaluateWindowOpen(
            destinationURL: URL(string: "https://example.com/page")!,
            currentURL: URL(string: "https://origin.com")!,
            isUserInitiated: true,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(decision, .openInNewTab)
    }

    func testEvaluateWindowOpen_UnsolicitedAdPopunderBlocked() {
        let decision = BrowserPopupPolicyEvaluator.evaluateWindowOpen(
            destinationURL: URL(string: "https://popads.net/serve?id=123")!,
            currentURL: URL(string: "https://origin.com")!,
            isUserInitiated: false,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(decision, .blockPopunder)
    }

    func testEvaluateWindowOpen_UnsolicitedLegitimatePopupPromptsConfirmation() {
        let decision = BrowserPopupPolicyEvaluator.evaluateWindowOpen(
            destinationURL: URL(string: "https://partner-portal.com/view")!,
            currentURL: URL(string: "https://origin.com")!,
            isUserInitiated: false,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(decision, .promptConfirmation(reason: .automaticWindowOpen, isSuspicious: false))
    }

    func testEvaluateWindowOpen_SuspiciousExternalRedirectPromptsWarning() {
        let decision = BrowserPopupPolicyEvaluator.evaluateWindowOpen(
            destinationURL: URL(string: "itms-appss://apps.apple.com/app/id999")!,
            currentURL: URL(string: "https://origin.com")!,
            isUserInitiated: false,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(decision, .promptConfirmation(reason: .suspiciousExternalRedirect, isSuspicious: true))
    }

    func testEvaluateNavigation_UserLinkActivatedAllowsSameTab() {
        let decision = BrowserPopupPolicyEvaluator.evaluateNavigation(
            destinationURL: URL(string: "https://articles.org/read")!,
            currentURL: URL(string: "https://origin.com")!,
            navigationType: 0, // linkActivated
            isTargetFrameNil: false,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(decision, .allowSameTab)
    }

    func testEvaluateNavigation_UserLinkTargetBlankOpensInNewTab() {
        let decision = BrowserPopupPolicyEvaluator.evaluateNavigation(
            destinationURL: URL(string: "https://articles.org/read")!,
            currentURL: URL(string: "https://origin.com")!,
            navigationType: 0, // linkActivated
            isTargetFrameNil: true,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(decision, .openInNewTab)
    }

    func testEvaluateNavigation_AutomaticCrossDomainPromptsConfirmation() {
        let decision = BrowserPopupPolicyEvaluator.evaluateNavigation(
            destinationURL: URL(string: "https://different-destination.com")!,
            currentURL: URL(string: "https://origin.com")!,
            navigationType: 5, // other
            isTargetFrameNil: false,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(decision, .promptConfirmation(reason: .automaticCrossDomainRedirect, isSuspicious: false))
    }

    func testEvaluateNavigation_SameSiteRedirectAllowed() {
        // Same domain
        let sameDomain = BrowserPopupPolicyEvaluator.evaluateNavigation(
            destinationURL: URL(string: "https://origin.com/login")!,
            currentURL: URL(string: "https://origin.com/home")!,
            navigationType: 5,
            isTargetFrameNil: false,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(sameDomain, .allowSameTab)

        // Subdomain to main domain
        let subToMain = BrowserPopupPolicyEvaluator.evaluateNavigation(
            destinationURL: URL(string: "https://origin.com/dashboard")!,
            currentURL: URL(string: "https://auth.origin.com/callback")!,
            navigationType: 5,
            isTargetFrameNil: false,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(subToMain, .allowSameTab)
    }

    func testEvaluateNavigation_AuthReturnRedirectAllowedViaOriginChain() {
        // Origin chain includes the original initiating domain
        let originChain: Set<String> = ["myapp.com", "accounts.google.com"]
        let decision = BrowserPopupPolicyEvaluator.evaluateNavigation(
            destinationURL: URL(string: "https://myapp.com/oauth/complete")!,
            currentURL: URL(string: "https://accounts.google.com/signin")!,
            navigationType: 5, // other
            isTargetFrameNil: false,
            isPopupBlockerEnabled: true,
            originChain: originChain
        )
        XCTAssertEqual(decision, .allowSameTab)
    }

    func testEvaluateNavigation_AdRedirectBlocked() {
        let decision = BrowserPopupPolicyEvaluator.evaluateNavigation(
            destinationURL: URL(string: "https://adservice.google.com/ads")!,
            currentURL: URL(string: "https://news.com")!,
            navigationType: 5,
            isTargetFrameNil: false,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(decision, .blockPopunder)
    }

    func testEvaluateNavigation_ExternalAppSchemePromptsConfirmation() {
        // Standard external app scheme: prompt confirmation
        let customScheme = BrowserPopupPolicyEvaluator.evaluateNavigation(
            destinationURL: URL(string: "whatsapp://send?text=hello")!,
            currentURL: URL(string: "https://news.com")!,
            navigationType: 0,
            isTargetFrameNil: false,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(customScheme, .promptExternalScheme(isSuspicious: false))

        // Aggressive app store hijack scheme: prompt with warning
        let suspiciousScheme = BrowserPopupPolicyEvaluator.evaluateNavigation(
            destinationURL: URL(string: "itms-appss://apps.apple.com/app/id123")!,
            currentURL: URL(string: "https://news.com")!,
            navigationType: 5,
            isTargetFrameNil: false,
            isPopupBlockerEnabled: true
        )
        XCTAssertEqual(customScheme, .promptExternalScheme(isSuspicious: false))
        XCTAssertEqual(suspiciousScheme, .promptExternalScheme(isSuspicious: true))
    }

    // MARK: - BrowserViewModel Shield Controls Tests

    #if canImport(SwiftUI)
    @MainActor
    func testBrowserViewModelShieldTogglesAndPersistence() {
        let vm = BrowserViewModel()
        vm.currentURL = URL(string: "https://www.testsite.com/video")!

        // Initial state
        XCTAssertTrue(vm.isAdBlockerEnabled)
        XCTAssertTrue(vm.isPopupBlockerEnabled)
        XCTAssertFalse(vm.isCurrentSiteWhitelisted)
        XCTAssertEqual(vm.currentDomainDisplayName, "testsite.com")

        // Whitelist current site
        vm.toggleShieldForCurrentSite()
        XCTAssertTrue(vm.isCurrentSiteWhitelisted)
        XCTAssertTrue(vm.adBlockerWhitelistedDomains.contains("testsite.com"))

        // Subdomain inherits whitelist
        vm.currentURL = URL(string: "https://sub.testsite.com/other")!
        XCTAssertTrue(vm.isCurrentSiteWhitelisted)

        // Reset to main domain and un-whitelist
        vm.currentURL = URL(string: "https://www.testsite.com/video")!
        vm.toggleShieldForCurrentSite()
        XCTAssertFalse(vm.isCurrentSiteWhitelisted)
        XCTAssertFalse(vm.adBlockerWhitelistedDomains.contains("testsite.com"))

        // Disable ad blocker globally
        vm.setAdBlockerEnabled(false)
        XCTAssertFalse(vm.isAdBlockerEnabled)

        // Disable popup blocker globally
        vm.setPopupBlockerEnabled(false)
        XCTAssertFalse(vm.isPopupBlockerEnabled)
    }

    @MainActor
    func testBrowserViewModelRedirectPromptLifecycle() {
        let vm = BrowserViewModel()
        let dest = URL(string: "https://redirect-target.com/page")!
        let origin = URL(string: "https://source-site.com")!

        XCTAssertNil(vm.redirectPrompt)

        // Present prompt
        vm.promptRedirectConfirmation(
            destinationURL: dest,
            originURL: origin,
            sourceTabID: nil,
            reason: .automaticCrossDomainRedirect,
            isSuspicious: false
        )

        XCTAssertNotNil(vm.redirectPrompt)
        XCTAssertEqual(vm.redirectPrompt?.destinationHost, "redirect-target.com")
        XCTAssertEqual(vm.redirectPrompt?.originHost, "source-site.com")
        XCTAssertEqual(vm.redirectPrompt?.reason, .automaticCrossDomainRedirect)

        // Cancel prompt
        vm.cancelRedirectPrompt()
        XCTAssertNil(vm.redirectPrompt)
    }
    #endif
}

