import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Manages local user notifications for completed downloads.
public enum DownloadNotificationManager: Sendable {
    /// Dispatches a local user notification when a download completes.
    public static func postDownloadCompletedNotification(filename: String, downloadID: String) {
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
}
