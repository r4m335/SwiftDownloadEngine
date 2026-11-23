import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Manages local user notifications and system broadcast events for completed downloads.
public enum DownloadNotificationManager: Sendable {
    /// Notification name broadcast via NotificationCenter when any download completes in the download/transport layer.
    public static let downloadDidCompleteNotification = Notification.Name("DownloadEngineKit.DownloadDidComplete")

    /// Key in Notification userInfo containing the download identifier.
    public static let downloadIDUserInfoKey = "downloadID"

    /// Key in Notification userInfo containing the final filename.
    public static let filenameUserInfoKey = "filename"

    private static let lock = NSLock()
    private static var notifiedIDs: Set<String> = []

    /// Dispatches a local user notification and broadcasts an in-process notification when a download completes.
    public static func postDownloadCompletedNotification(filename: String, downloadID: String) {
        lock.lock()
        if notifiedIDs.contains(downloadID) {
            lock.unlock()
            return
        }
        notifiedIDs.insert(downloadID)
        lock.unlock()

        // Broadcast in-process notification for UI, observers, and integration tests
        NotificationCenter.default.post(
            name: downloadDidCompleteNotification,
            object: nil,
            userInfo: [
                downloadIDUserInfoKey: downloadID,
                filenameUserInfoKey: filename
            ]
        )

        #if canImport(UserNotifications)
        // Guard against CLI test runners (e.g. xctest or swift test) where UNUserNotificationCenter throws NSInternalInconsistencyException
        guard Bundle.main.bundleIdentifier != nil,
              NSClassFromString("XCTest") == nil,
              !Bundle.main.bundlePath.contains("Developer/usr/bin") else {
            return
        }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = filename
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "download-completed-\(downloadID)",
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error {
                PipelineLogger.shared.log(stage: .coordinator, message: "[DownloadNotificationManager] Failed to post completion notification for \(downloadID): \(error.localizedDescription)")
            }
        }
        #endif
    }

    /// Resets the notified download tracking (primarily for unit tests).
    public static func resetNotifiedIDs() {
        lock.lock()
        defer { lock.unlock() }
        notifiedIDs.removeAll()
    }
}
