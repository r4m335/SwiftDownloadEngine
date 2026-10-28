import XCTest
@testable import DM_Reverse_engineering

final class SharedRequestBudgetHostTests: XCTestCase {
    func testPerHostCapDoesNotBlockAnotherHost() async throws {
        let budget = SharedRequestBudget(maxGlobalRequests: 2, maxRequestsPerHost: 1)
        try await budget.acquire(downloadID: "first", host: "CDN.Example")

        let sameHostWaiter = Task {
            try await budget.acquire(downloadID: "second", host: "cdn.example")
        }

        for _ in 0..<10 {
            if await budget.waitingCount > 0 { break }
            await Task.yield()
        }
        let activeOnFirstHost = await budget.activeCount(forHost: "cdn.example")
        let waitingCount = await budget.waitingCount
        XCTAssertEqual(activeOnFirstHost, 1)
        XCTAssertEqual(waitingCount, 1)

        try await budget.acquire(downloadID: "other", host: "other.example")
        let activeOnOtherHost = await budget.activeCount(forHost: "other.example")
        XCTAssertEqual(activeOnOtherHost, 1)

        await budget.release(downloadID: "other", host: "other.example")
        await budget.release(downloadID: "first", host: "cdn.example")
        try await sameHostWaiter.value

        let activeAfterRelease = await budget.activeCount(forHost: "cdn.example")
        XCTAssertEqual(activeAfterRelease, 1)
        await budget.release(downloadID: "second", host: "cdn.example")
        let currentGlobalActive = await budget.currentGlobalActive
        XCTAssertEqual(currentGlobalActive, 0)
    }
}
