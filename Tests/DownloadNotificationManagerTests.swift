import XCTest
import Foundation
@testable import DownloadEngineKit

final class DownloadNotificationManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DownloadNotificationManager.resetNotifiedIDs()
    }

    override func tearDown() {
        DownloadNotificationManager.resetNotifiedIDs()
        super.tearDown()
    }

    func testPostDownloadCompletedNotificationBroadcastsNotificationCenterEvent() {
        let expectedID = "test-download-\(UUID().uuidString)"
        let expectedFilename = "video.mp4"

        let expectation = expectation(description: "NotificationCenter receives download completion event")

        var receivedID: String?
        var receivedFilename: String?

        let observer = NotificationCenter.default.addObserver(
            forName: DownloadNotificationManager.downloadDidCompleteNotification,
            object: nil,
            queue: .main
        ) { notification in
            receivedID = notification.userInfo?[DownloadNotificationManager.downloadIDUserInfoKey] as? String
            receivedFilename = notification.userInfo?[DownloadNotificationManager.filenameUserInfoKey] as? String
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        DownloadNotificationManager.postDownloadCompletedNotification(
            filename: expectedFilename,
            downloadID: expectedID
        )

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedID, expectedID)
        XCTAssertEqual(receivedFilename, expectedFilename)
    }

    func testDownloadCompletedNotificationDeduplication() {
        let testID = "dedup-download-\(UUID().uuidString)"
        let testFilename = "archive.zip"

        var notificationCount = 0

        let observer = NotificationCenter.default.addObserver(
            forName: DownloadNotificationManager.downloadDidCompleteNotification,
            object: nil,
            queue: .main
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Post twice for same download ID
        DownloadNotificationManager.postDownloadCompletedNotification(filename: testFilename, downloadID: testID)
        DownloadNotificationManager.postDownloadCompletedNotification(filename: testFilename, downloadID: testID)

        // Give any asynchronous dispatch time to settle
        let waitExp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waitExp.fulfill()
        }
        wait(for: [waitExp], timeout: 1.0)

        XCTAssertEqual(notificationCount, 1, "Duplicate completion notification for same downloadID must be deduplicated")
    }

    func testResetNotifiedIDsAllowsSubsequentNotifications() {
        let testID = "reset-download-\(UUID().uuidString)"
        let testFilename = "file.iso"

        var notificationCount = 0

        let observer = NotificationCenter.default.addObserver(
            forName: DownloadNotificationManager.downloadDidCompleteNotification,
            object: nil,
            queue: .main
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        DownloadNotificationManager.postDownloadCompletedNotification(filename: testFilename, downloadID: testID)
        XCTAssertEqual(notificationCount, 1)

        // Reset tracking
        DownloadNotificationManager.resetNotifiedIDs()

        // Post again after reset
        DownloadNotificationManager.postDownloadCompletedNotification(filename: testFilename, downloadID: testID)
        XCTAssertEqual(notificationCount, 2, "After resetNotifiedIDs, the same downloadID should be accepted again")
    }

    func testBackgroundSessionManagerExposesDownloadCompletedCallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BGMNotificationTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = try BackgroundDownloadSessionManager(
            sessionIdentifier: "test.notification.\(UUID().uuidString)",
            storageDirectoryURL: tempDir
        )

        var callbackCalled = false
        manager.onDownloadCompleted = { downloadID, destinationURL in
            callbackCalled = true
        }

        XCTAssertNotNil(manager.onDownloadCompleted)
        manager.onDownloadCompleted?("dummy-id", tempDir)
        XCTAssertTrue(callbackCalled)
    }
}
