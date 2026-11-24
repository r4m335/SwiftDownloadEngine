import XCTest
import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
@testable import DownloadEngineKit

final class DownloadNotificationManagerTests: XCTestCase {

    private var mockTransport: MockNotificationCenterTransport!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotifTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let customFile = tempDir.appendingPathComponent("notified_downloads.json")
        DownloadNotificationManager.setPersistenceFileURL(customFile)
        DownloadNotificationManager.resetNotifiedIDs()

        mockTransport = MockNotificationCenterTransport()
        DownloadNotificationManager.transport = mockTransport
    }

    override func tearDown() {
        DownloadNotificationManager.resetNotifiedIDs()
        DownloadNotificationManager.actionDelegate = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 1. Permission Request & Settings Flow

    func testPermissionRequestFlow() async {
        mockTransport.stubbedPermissionStatus = .notDetermined
        mockTransport.requestAuthorizationResult = true

        let statusBefore = await DownloadNotificationManager.checkPermissionStatus()
        XCTAssertEqual(statusBefore, .notDetermined)

        let granted = await DownloadNotificationManager.requestPermissionBeforeFirstDownload()
        XCTAssertTrue(granted)
        XCTAssertTrue(mockTransport.wasRequestedAuthorization)

        let statusAfter = await DownloadNotificationManager.checkPermissionStatus()
        XCTAssertEqual(statusAfter, .authorized)
        #if canImport(UserNotifications)
        XCTAssertGreaterThan(mockTransport.registeredCategoriesCount, 0)
        #endif
    }

    func testPermissionRequestDeniedFlow() async {
        mockTransport.stubbedPermissionStatus = .denied
        mockTransport.requestAuthorizationResult = false

        let granted = await DownloadNotificationManager.requestPermissionBeforeFirstDownload()
        XCTAssertFalse(granted)
        XCTAssertFalse(mockTransport.wasRequestedAuthorization, "When already denied, should not prompt again")
    }

    func testOpenSettingsURLIsProvided() {
        let url = DownloadNotificationManager.openSettingsURL
        #if canImport(UIKit) && !os(watchOS)
        XCTAssertNotNil(url)
        #endif
    }

    // MARK: - 2. Complete Lifecycle Notifications: HTTP & Stream Transfers

    func testHTTPDownloadCompleteLifecycleEvents() {
        let downloadID = "http-\(UUID().uuidString)"
        let filename = "sample_video.mp4"

        let events: [Notification.Name] = [
            DownloadNotificationManager.downloadDidQueueNotification,
            DownloadNotificationManager.downloadDidStartNotification,
            DownloadNotificationManager.downloadDidPausedNotification(filename: filename, id: downloadID),
            DownloadNotificationManager.downloadDidResumeNotification,
            DownloadNotificationManager.downloadDidRetryNotification,
            DownloadNotificationManager.downloadDidFailNotification,
            DownloadNotificationManager.downloadDidCancelNotification,
            DownloadNotificationManager.downloadDidCompleteNotification
        ]

        var receivedNames = Set<Notification.Name>()
        var observers: [NSObjectProtocol] = []

        let allNames: [Notification.Name] = [
            DownloadNotificationManager.downloadDidQueueNotification,
            DownloadNotificationManager.downloadDidStartNotification,
            DownloadNotificationManager.downloadDidPauseNotification,
            DownloadNotificationManager.downloadDidResumeNotification,
            DownloadNotificationManager.downloadDidRetryNotification,
            DownloadNotificationManager.downloadDidFailNotification,
            DownloadNotificationManager.downloadDidCancelNotification,
            DownloadNotificationManager.downloadDidCompleteNotification
        ]

        for name in allNames {
            let obs = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                receivedNames.insert(name)
            }
            observers.append(obs)
        }
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        DownloadNotificationManager.postDownloadQueuedNotification(filename: filename, downloadID: downloadID)
        DownloadNotificationManager.postDownloadStartedNotification(filename: filename, downloadID: downloadID)
        DownloadNotificationManager.postDownloadPausedNotification(filename: filename, downloadID: downloadID)
        DownloadNotificationManager.postDownloadResumedNotification(filename: filename, downloadID: downloadID)
        DownloadNotificationManager.postDownloadRetriedNotification(filename: filename, downloadID: downloadID, attempt: 1)
        DownloadNotificationManager.postDownloadFailedNotification(filename: filename, downloadID: downloadID, error: "Network timeout")
        DownloadNotificationManager.postDownloadCancelledNotification(filename: filename, downloadID: downloadID)
        DownloadNotificationManager.postDownloadCompletedNotification(filename: filename, downloadID: downloadID)

        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        for name in allNames {
            XCTAssertTrue(receivedNames.contains(name), "Missing lifecycle event: \(name.rawValue)")
        }
    }

    private static func downloadDidPausedNotification(filename: String, id: String) -> Notification.Name {
        DownloadNotificationManager.downloadDidPauseNotification
    }

    // MARK: - 3. Complete Lifecycle Notifications: Torrent Swarms

    func testTorrentCompleteLifecycleEvents() {
        let infoHash = "0123456789abcdef0123456789abcdef01234567"
        let name = "Ubuntu.iso"

        var receivedNames = Set<Notification.Name>()
        var observers: [NSObjectProtocol] = []

        let allTorrentNames: [Notification.Name] = [
            DownloadNotificationManager.torrentDidStartNotification,
            DownloadNotificationManager.torrentDidPauseNotification,
            DownloadNotificationManager.torrentDidCompleteNotification,
            DownloadNotificationManager.torrentSeedingDidStopNotification,
            DownloadNotificationManager.torrentDidFailNotification,
            DownloadNotificationManager.torrentDiskFullNotification,
            DownloadNotificationManager.torrentTrackerFailedNotification
        ]

        for n in allTorrentNames {
            let obs = NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                receivedNames.insert(n)
            }
            observers.append(obs)
        }
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        DownloadNotificationManager.postTorrentStartedNotification(name: name, infoHash: infoHash)
        DownloadNotificationManager.postTorrentPausedNotification(name: name, infoHash: infoHash)
        DownloadNotificationManager.postTorrentCompletedNotification(name: name, infoHash: infoHash)
        DownloadNotificationManager.postTorrentSeedingStoppedNotification(name: name, infoHash: infoHash, reason: "Ratio 2.0 reached")
        DownloadNotificationManager.postTorrentFailedNotification(name: name, infoHash: infoHash, error: "Piece hash mismatch")
        DownloadNotificationManager.postTorrentDiskFullNotification(name: name, infoHash: infoHash, availableBytes: 1024)
        DownloadNotificationManager.postTorrentTrackerFailedNotification(name: name, infoHash: infoHash, trackerURL: "https://tracker.example.com", error: "Connection refused")

        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        for n in allTorrentNames {
            XCTAssertTrue(receivedNames.contains(n), "Missing torrent lifecycle event: \(n.rawValue)")
        }
    }

    // MARK: - 4. Complete Lifecycle Notifications: Live Stream Recording

    func testLiveRecordingCompleteLifecycleEvents() {
        let sessionID = "live-\(UUID().uuidString)"
        let title = "Breaking News Stream"
        let dest = tempDir.appendingPathComponent("news.mp4")

        var receivedNames = Set<Notification.Name>()
        var observers: [NSObjectProtocol] = []

        let allLiveNames: [Notification.Name] = [
            DownloadNotificationManager.liveRecordingDidStartNotification,
            DownloadNotificationManager.liveRecordingDidInterruptNotification,
            DownloadNotificationManager.liveRecordingDidRecoverNotification,
            DownloadNotificationManager.liveRecordingDidStopNotification,
            DownloadNotificationManager.liveRecordingDidCompleteNotification
        ]

        for n in allLiveNames {
            let obs = NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                receivedNames.insert(n)
            }
            observers.append(obs)
        }
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        DownloadNotificationManager.postLiveRecordingStartedNotification(sessionID: sessionID, title: title)
        DownloadNotificationManager.postLiveRecordingInterruptedNotification(sessionID: sessionID, title: title, reason: "Connection lost")
        DownloadNotificationManager.postLiveRecordingRecoveredNotification(sessionID: sessionID, title: title)
        DownloadNotificationManager.postLiveRecordingStoppedNotification(sessionID: sessionID, title: title, duration: 120.0)
        DownloadNotificationManager.postLiveRecordingCompletedNotification(sessionID: sessionID, title: title, fileURL: dest, duration: 120.0)

        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        for n in allLiveNames {
            XCTAssertTrue(receivedNames.contains(n), "Missing live recording lifecycle event: \(n.rawValue)")
        }
    }

    // MARK: - 5. Actionable Notification Controls

    final class MockActionDelegate: DownloadNotificationActionDelegate, @unchecked Sendable {
        var actions: [(action: String, transferID: String, userInfo: [String: Any])] = []

        func handleNotificationAction(actionIdentifier: String, transferID: String, userInfo: [String: Any]) {
            actions.append((actionIdentifier, transferID, userInfo))
        }
    }

    func testNotificationActionsRouting() {
        let delegate = MockActionDelegate()
        DownloadNotificationManager.actionDelegate = delegate

        let transferID = "test-transfer-123"

        DownloadNotificationManager.handleAction(
            actionIdentifier: DownloadNotificationAction.pause,
            transferID: transferID,
            userInfo: [:]
        )
        DownloadNotificationManager.handleAction(
            actionIdentifier: DownloadNotificationAction.resume,
            transferID: transferID,
            userInfo: [:]
        )
        DownloadNotificationManager.handleAction(
            actionIdentifier: DownloadNotificationAction.cancel,
            transferID: transferID,
            userInfo: [:]
        )
        DownloadNotificationManager.handleAction(
            actionIdentifier: DownloadNotificationAction.retry,
            transferID: transferID,
            userInfo: [:]
        )
        DownloadNotificationManager.handleAction(
            actionIdentifier: DownloadNotificationAction.openInFiles,
            transferID: transferID,
            userInfo: [DownloadNotificationManager.destinationURLUserInfoKey: "/path/to/file.mp4"]
        )
        DownloadNotificationManager.handleAction(
            actionIdentifier: DownloadNotificationAction.openLibraryItem,
            transferID: transferID,
            userInfo: [:]
        )

        XCTAssertEqual(delegate.actions.count, 6)
        XCTAssertEqual(delegate.actions[0].action, DownloadNotificationAction.pause)
        XCTAssertEqual(delegate.actions[1].action, DownloadNotificationAction.resume)
        XCTAssertEqual(delegate.actions[2].action, DownloadNotificationAction.cancel)
        XCTAssertEqual(delegate.actions[3].action, DownloadNotificationAction.retry)
        XCTAssertEqual(delegate.actions[4].action, DownloadNotificationAction.openInFiles)
        XCTAssertEqual(delegate.actions[5].action, DownloadNotificationAction.openLibraryItem)
    }

    // MARK: - 6. Progress Updates & Throttling

    func testThrottledProgressUpdates() async {
        let transferID = "prog-transfer-456"
        let filename = "archive.tar.gz"

        // First update -> Must post
        DownloadNotificationManager.updateTransferProgress(
            transferID: transferID,
            filename: filename,
            progress: 0.10,
            speedBytesPerSecond: 1024 * 1024,
            remainingSeconds: 60,
            stateDescription: "Downloading"
        )

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mockTransport.addedRequests.count, 1)

        // Small progress change (< 5%) immediately -> Throttled!
        DownloadNotificationManager.updateTransferProgress(
            transferID: transferID,
            filename: filename,
            progress: 0.12,
            speedBytesPerSecond: 1024 * 1024,
            remainingSeconds: 58,
            stateDescription: "Downloading"
        )

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mockTransport.addedRequests.count, 1, "Change < 5% within throttle window should be suppressed")

        // Significant progress change (>= 5%) -> Must post!
        DownloadNotificationManager.updateTransferProgress(
            transferID: transferID,
            filename: filename,
            progress: 0.20,
            speedBytesPerSecond: 1024 * 1024,
            remainingSeconds: 50,
            stateDescription: "Downloading"
        )

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mockTransport.addedRequests.count, 2, "Progress jump >= 5% must post notification")

        // State change to Paused -> Must post immediately regardless of progress jump!
        DownloadNotificationManager.updateTransferProgress(
            transferID: transferID,
            filename: filename,
            progress: 0.20,
            speedBytesPerSecond: 0,
            remainingSeconds: nil,
            stateDescription: "Paused"
        )

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mockTransport.addedRequests.count, 3, "State change must trigger immediate notification update")

        // Progress removal
        DownloadNotificationManager.removeProgressNotification(for: transferID)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(mockTransport.removedPendingIdentifiers.contains("transfer-progress-\(transferID)"))
    }

    // MARK: - 7. Reliability: Relaunch Reconciliation & Deduplication

    func testReconciliationRemovesOrphanedProgressNotifications() async {
        let activeID = "active-transfer-1"
        let deadID1 = "dead-transfer-2"
        let deadID2 = "dead-transfer-3"

        DownloadNotificationManager.updateTransferProgress(
            transferID: activeID,
            filename: "file1.bin",
            progress: 0.5,
            speedBytesPerSecond: 500,
            remainingSeconds: 10,
            stateDescription: "Downloading"
        )
        DownloadNotificationManager.updateTransferProgress(
            transferID: deadID1,
            filename: "file2.bin",
            progress: 0.2,
            speedBytesPerSecond: 500,
            remainingSeconds: 10,
            stateDescription: "Downloading"
        )
        DownloadNotificationManager.updateTransferProgress(
            transferID: deadID2,
            filename: "file3.bin",
            progress: 0.8,
            speedBytesPerSecond: 500,
            remainingSeconds: 10,
            stateDescription: "Downloading"
        )

        try? await Task.sleep(nanoseconds: 50_000_000)

        // Reconcile with only activeID known to app
        await DownloadNotificationManager.reconcileActiveNotifications(knownActiveTransferIDs: [activeID])

        XCTAssertTrue(mockTransport.removedPendingIdentifiers.contains("transfer-progress-\(deadID1)"))
        XCTAssertTrue(mockTransport.removedPendingIdentifiers.contains("transfer-progress-\(deadID2)"))
        XCTAssertFalse(mockTransport.removedPendingIdentifiers.contains("transfer-progress-\(activeID)"))
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

        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

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

        DownloadNotificationManager.resetNotifiedIDs()

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
