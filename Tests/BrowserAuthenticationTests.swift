import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DM_Reverse_engineering

final class BrowserAuthenticationTests: XCTestCase {
    private let host = "auth.example.com"
    private let testURL = URL(string: "https://auth.example.com/secure")!

    override func setUp() {
        super.setUp()
        KeychainManager.shared.deleteInternetPassword(server: host)
    }

    override func tearDown() {
        KeychainManager.shared.deleteInternetPassword(server: host)
        super.tearDown()
    }

    func testSavedCredentialIsUsedOnFirstAttempt() {
        KeychainManager.shared.storeInternetPassword(
            username: "adminUser",
            password: "adminPassword123",
            server: host,
            protocolType: "https",
            path: "/"
        )

        let handler = BrowserAuthenticationHandler(keychain: .shared)
        let space = URLProtectionSpace(
            host: host,
            port: 443,
            protocol: "https",
            realm: "Protected Area",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DummyChallengeSender()
        )

        let expectation = self.expectation(description: "Challenge handled")
        handler.handleChallenge(challenge, targetPageURL: testURL) { disposition, credential in
            XCTAssertEqual(disposition, .useCredential)
            XCTAssertEqual(credential?.user, "adminUser")
            XCTAssertEqual(credential?.password, "adminPassword123")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2.0)
    }

    func testUserSuppliedCredentialIsUsedAndPersistedWhenNoSavedPassword() {
        final class MockPromptProvider: BrowserAuthenticationProviding, @unchecked Sendable {
            var prompted = false
            func promptForCredentials(
                host: String,
                realm: String?,
                completionHandler: @escaping @Sendable (String?, String?) -> Void
            ) {
                prompted = true
                completionHandler("userFromPrompt", "promptSecret987")
            }
        }

        let provider = MockPromptProvider()
        let handler = BrowserAuthenticationHandler(keychain: .shared, promptProvider: provider)

        let space = URLProtectionSpace(
            host: host,
            port: 443,
            protocol: "https",
            realm: "Prompt Area",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DummyChallengeSender()
        )

        let expectation = self.expectation(description: "Prompt handled")
        handler.handleChallenge(challenge, targetPageURL: testURL) { disposition, credential in
            XCTAssertEqual(disposition, .useCredential)
            XCTAssertEqual(credential?.user, "userFromPrompt")
            XCTAssertEqual(credential?.password, "promptSecret987")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2.0)
        XCTAssertTrue(provider.prompted)

        // Verify stored in Keychain for subsequent attempts
        let saved = KeychainManager.shared.getInternetPassword(server: self.host, path: "/")
        XCTAssertEqual(saved?.username, "userFromPrompt")
        XCTAssertEqual(saved?.password, "promptSecret987")
    }

    func testUserCancellationReturnsCancelDisposition() {
        final class CancellingProvider: BrowserAuthenticationProviding, @unchecked Sendable {
            func promptForCredentials(
                host: String,
                realm: String?,
                completionHandler: @escaping @Sendable (String?, String?) -> Void
            ) {
                completionHandler(nil, nil)
            }
        }

        let handler = BrowserAuthenticationHandler(keychain: .shared, promptProvider: CancellingProvider())
        let space = URLProtectionSpace(
            host: host,
            port: 443,
            protocol: "https",
            realm: "Secure",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 1,
            failureResponse: nil,
            error: nil,
            sender: DummyChallengeSender()
        )

        let expectation = self.expectation(description: "Cancellation handled")
        handler.handleChallenge(challenge, targetPageURL: testURL) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2.0)
    }

    func testServerTrustChallengeUsesDefaultHandling() {
        let handler = BrowserAuthenticationHandler(keychain: .shared)
        let space = URLProtectionSpace(
            host: host,
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: "NSURLAuthenticationMethodServerTrust"
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DummyChallengeSender()
        )

        let expectation = self.expectation(description: "Server trust handled")
        handler.handleChallenge(challenge, targetPageURL: testURL) { disposition, credential in
            XCTAssertEqual(disposition, .performDefaultHandling)
            XCTAssertNil(credential)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2.0)
    }

    func testUnrelatedOriginIsRejectedWithoutExposingCredentials() {
        KeychainManager.shared.storeInternetPassword(
            username: "safeUser",
            password: "safePassword",
            server: "unrelated.attacker.com",
            protocolType: "https",
            path: "/"
        )

        let handler = BrowserAuthenticationHandler(keychain: .shared)
        let space = URLProtectionSpace(
            host: "unrelated.attacker.com",
            port: 443,
            protocol: "https",
            realm: "Attacker Area",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: DummyChallengeSender()
        )

        let pageURL = URL(string: "https://legitimate.example.com/")!
        let expectation = self.expectation(description: "Cross origin challenge cancelled")
        handler.handleChallenge(challenge, targetPageURL: pageURL) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2.0)
    }
}

private final class DummyChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
