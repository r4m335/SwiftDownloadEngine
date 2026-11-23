import XCTest
@testable import DownloadEngineKit

final class AppPrivacyTests: XCTestCase {

    func testPrivacyPolicyURLIsValidAndHTTPS() {
        let url = AppPrivacyInfo.privacyPolicyURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasSuffix("PRIVACY_POLICY.md"))
    }

    func testTrackingIsExplicitlyDisabled() {
        XCTAssertFalse(AppPrivacyInfo.isTrackingEnabled, "Application must have tracking disabled")
        XCTAssertTrue(AppPrivacyInfo.trackingSummary.contains("zero advertising SDKs"))
    }

    func testDataCollectionIsOnDeviceOnly() {
        XCTAssertFalse(AppPrivacyInfo.dataCollectionSummary.isEmpty)
        XCTAssertTrue(AppPrivacyInfo.dataCollectionSummary.contains("completely on-device"))
    }

    func testRequiredReasonAPIsCompleteness() {
        let apis = AppPrivacyInfo.accessedAPIs
        let categories = Set(apis.map { $0.category })

        XCTAssertTrue(categories.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        XCTAssertTrue(categories.contains("NSPrivacyAccessedAPICategoryFileTimestamp"))
        XCTAssertTrue(categories.contains("NSPrivacyAccessedAPICategoryDiskSpace"))
        XCTAssertTrue(categories.contains("NSPrivacyAccessedAPICategorySystemBootTime"))

        // Verify specific required reason codes
        if let userDefaultsAPI = apis.first(where: { $0.category == "NSPrivacyAccessedAPICategoryUserDefaults" }) {
            XCTAssertTrue(userDefaultsAPI.reasons.contains("CA92.1"))
        }

        if let timestampAPI = apis.first(where: { $0.category == "NSPrivacyAccessedAPICategoryFileTimestamp" }) {
            XCTAssertTrue(timestampAPI.reasons.contains("C617.1"))
            XCTAssertTrue(timestampAPI.reasons.contains("3B52.1"))
        }

        if let diskAPI = apis.first(where: { $0.category == "NSPrivacyAccessedAPICategoryDiskSpace" }) {
            XCTAssertTrue(diskAPI.reasons.contains("E174.1"))
        }

        if let bootAPI = apis.first(where: { $0.category == "NSPrivacyAccessedAPICategorySystemBootTime" }) {
            XCTAssertTrue(bootAPI.reasons.contains("35F9.1"))
        }
    }

    func testAppStoreNutritionLabelAnswersConfirmNoCollection() {
        let answers = AppPrivacyInfo.appStoreAnswers
        XCTAssertFalse(answers.isEmpty)

        for answer in answers {
            XCTAssertFalse(answer.isCollected, "Category '\(answer.category)' must not be collected")
            XCTAssertFalse(answer.explanation.isEmpty)
        }
    }

    func testAppPrivacyModelsCodableRoundTrip() throws {
        let original = AppPrivacyInfo.accessedAPIs.first!
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PrivacyAccessedAPI.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.category, original.category)
        XCTAssertEqual(decoded.reasons, original.reasons)
        XCTAssertEqual(decoded.purpose, original.purpose)
    }
}
