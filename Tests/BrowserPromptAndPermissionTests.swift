import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class BrowserPromptAndPermissionTests: XCTestCase {

    // MARK: - Prompt Handler Tests

    func testPromptHandlerDefaultsToNilWhenNoProvider() {
        let handler = BrowserPromptHandler(provider: nil)
        let expectation = self.expectation(description: "Prompt handled with nil")

        handler.handlePrompt(
            prompt: "Please enter your name",
            defaultText: "John Doe",
            frameURL: URL(string: "https://example.com/page")!
        ) { result in
            XCTAssertNil(result, "Prompt must default strictly to nil/cancellation without a provider")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2.0)
    }

    func testPromptHandlerReturnsProviderResult() {
        final class MockPromptProvider: BrowserPromptProviding, @unchecked Sendable {
            func prompt(
                message: String,
                defaultText: String?,
                frameURL: URL?,
                completionHandler: @escaping @Sendable (String?) -> Void
            ) {
                if message.contains("passcode") {
                    completionHandler("1234")
                } else {
                    completionHandler(nil)
                }
            }
        }

        let provider = MockPromptProvider()
        let handler = BrowserPromptHandler(provider: provider)

        let exp1 = self.expectation(description: "Prompt returns value")
        handler.handlePrompt(
            prompt: "Enter passcode",
            defaultText: nil,
            frameURL: nil
        ) { result in
            XCTAssertEqual(result, "1234")
            exp1.fulfill()
        }

        let exp2 = self.expectation(description: "Prompt returns nil on cancel")
        handler.handlePrompt(
            prompt: "Enter email",
            defaultText: nil,
            frameURL: nil
        ) { result in
            XCTAssertNil(result)
            exp2.fulfill()
        }

        waitForExpectations(timeout: 2.0)
    }

    // MARK: - Permission Coordinator Tests

    func testPermissionCoordinatorDefaultsStrictlyToDenyWhenNoProvider() {
        let coordinator = BrowserPermissionCoordinator(provider: nil)

        for permType in BrowserPermissionType.allCases {
            let expectation = self.expectation(description: "Permission \(permType.rawValue) denied")
            coordinator.decidePermission(
                type: permType,
                originHost: "media.example.com",
                frameURL: URL(string: "https://media.example.com/stream")!
            ) { decision in
                XCTAssertEqual(decision, .deny, "Permission for \(permType.rawValue) must default to .deny")
                expectation.fulfill()
            }
            waitForExpectations(timeout: 2.0)
        }
    }

    func testPermissionCoordinatorDelegatesToProvider() {
        final class SelectivePermissionProvider: BrowserPermissionProviding, @unchecked Sendable {
            func requestPermission(
                type: BrowserPermissionType,
                originHost: String,
                frameURL: URL?,
                completionHandler: @escaping @Sendable (BrowserPermissionDecisionResult) -> Void
            ) {
                if originHost == "trusted.example.com" && type == .microphone {
                    completionHandler(.grant)
                } else if type == .camera {
                    completionHandler(.prompt)
                } else {
                    completionHandler(.deny)
                }
            }
        }

        let provider = SelectivePermissionProvider()
        let coordinator = BrowserPermissionCoordinator(provider: provider)

        let expGrant = self.expectation(description: "Mic granted for trusted host")
        coordinator.decidePermission(
            type: .microphone,
            originHost: "trusted.example.com",
            frameURL: nil
        ) { decision in
            XCTAssertEqual(decision, .grant)
            expGrant.fulfill()
        }

        let expPrompt = self.expectation(description: "Camera prompts user")
        coordinator.decidePermission(
            type: .camera,
            originHost: "trusted.example.com",
            frameURL: nil
        ) { decision in
            XCTAssertEqual(decision, .prompt)
            expPrompt.fulfill()
        }

        let expDeny = self.expectation(description: "Geolocation denied")
        coordinator.decidePermission(
            type: .geolocation,
            originHost: "trusted.example.com",
            frameURL: nil
        ) { decision in
            XCTAssertEqual(decision, .deny)
            expDeny.fulfill()
        }

        waitForExpectations(timeout: 2.0)
    }
}
