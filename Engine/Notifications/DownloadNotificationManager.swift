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

    /// Notification name broadcast via NotificationCenter when a torrent download finishes.
    public static let torrentDidCompleteNotification = Notification.Name("DownloadEngineKit.TorrentDidComplete")

    /// Notification name broadcast via NotificationCenter when a torrent finishes its seeding ratio/duration.
    public static let torrentSeedingDidStopNotification = Notification.Name("DownloadEngineKit.TorrentSeedingDidStop")

    /// Notification name broadcast via NotificationCenter when a torrent fails.
    public static let torrentDidFailNotification = Notification.Name("DownloadEngineKit.TorrentDidFail")

    public static let torrentInfoHashUserInfoKey = "infoHash"
    public static let torrentNameUserInfoKey = "name"
    public static let torrentReasonUserInfoKey = "reason"
    public static let torrentErrorUserInfoKey = "error"

    private static let lock = NSLock()
    private static var notifiedIDs: Set<String> = []
    private static var isInitialized = false
    private static var customPersistenceFileURL: URL? = nil

    private static var persistenceFileURL: URL? {
        if let custom = customPersistenceFileURL {
            return custom
        }
        let fileManager = FileManager.default
        let baseDir: URL
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            baseDir = appSupport.appendingPathComponent("SwiftDownloadEngine", isDirectory: true)
        } else {
            baseDir = fileManager.temporaryDirectory.appendingPathComponent("SwiftDownloadEngine", isDirectory: true)
        }
        try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        return baseDir.appendingPathComponent("notified_downloads.json")
    }

    /// Sets an explicit URL for durable notification tracking storage (useful for tests or custom store dirs).
    public static func setPersistenceFileURL(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        customPersistenceFileURL = url
        isInitialized = false
        notifiedIDs.removeAll()
        ensureLoadedLocked()
    }

    private static func ensureLoadedLocked() {
        guard !isInitialized else { return }
        isInitialized = true
        guard let url = persistenceFileURL,
              let data = try? Data(contentsOf: url),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        notifiedIDs = Set(array)
    }

    private static func savePersistedNotifiedIDsLocked() {
        guard let url = persistenceFileURL else { return }
        if let data = try? JSONEncoder().encode(Array(notifiedIDs)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Returns whether a given download ID has already been notified.
    public static func isNotified(downloadID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        return notifiedIDs.contains(downloadID)
    }

    /// Clears a single download ID from the notified set if needed.
    public static func clearNotifiedID(downloadID: String) {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        notifiedIDs.remove(downloadID)
        savePersistedNotifiedIDsLocked()
    }

    /// Dispatches a local user notification and broadcasts an in-process notification when a download completes.
    public static func postDownloadCompletedNotification(filename: String, downloadID: String) {
        lock.lock()
        ensureLoadedLocked()
        if notifiedIDs.contains(downloadID) {
            lock.unlock()
            return
        }
        notifiedIDs.insert(downloadID)
        savePersistedNotifiedIDsLocked()
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

    /// Dispatches a local user notification and broadcasts when a torrent finishes downloading.
    public static func postTorrentCompletedNotification(name: String, infoHash: String) {
        let key = "torrent-completed-\(infoHash.lowercased())"
        lock.lock()
        ensureLoadedLocked()
        if notifiedIDs.contains(key) {
            lock.unlock()
            return
        }
        notifiedIDs.insert(key)
        savePersistedNotifiedIDsLocked()
        lock.unlock()

        NotificationCenter.default.post(
            name: torrentDidCompleteNotification,
            object: nil,
            userInfo: [
                torrentInfoHashUserInfoKey: infoHash,
                torrentNameUserInfoKey: name
            ]
        )

        #if canImport(UserNotifications)
        guard Bundle.main.bundleIdentifier != nil,
              NSClassFromString("XCTest") == nil,
              !Bundle.main.bundlePath.contains("Developer/usr/bin") else {
            return
        }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Torrent Complete"
        content.body = name
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: key,
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error {
                PipelineLogger.shared.log(stage: .coordinator, message: "[DownloadNotificationManager] Failed to post torrent notification for \(infoHash): \(error.localizedDescription)")
            }
        }
        #endif
    }

    /// Dispatches a local user notification and broadcasts when a torrent stops seeding.
    public static func postTorrentSeedingStoppedNotification(name: String, infoHash: String, reason: String) {
        let key = "torrent-seeding-stopped-\(infoHash.lowercased())"
        lock.lock()
        ensureLoadedLocked()
        if notifiedIDs.contains(key) {
            lock.unlock()
            return
        }
        notifiedIDs.insert(key)
        savePersistedNotifiedIDsLocked()
        lock.unlock()

        NotificationCenter.default.post(
            name: torrentSeedingDidStopNotification,
            object: nil,
            userInfo: [
                torrentInfoHashUserInfoKey: infoHash,
                torrentNameUserInfoKey: name,
                torrentReasonUserInfoKey: reason
            ]
        )

        #if canImport(UserNotifications)
        guard Bundle.main.bundleIdentifier != nil,
              NSClassFromString("XCTest") == nil,
              !Bundle.main.bundlePath.contains("Developer/usr/bin") else {
            return
        }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Seeding Finished"
        content.body = "\(name): \(reason)"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: key,
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error {
                PipelineLogger.shared.log(stage: .coordinator, message: "[DownloadNotificationManager] Failed to post seeding stopped notification for \(infoHash): \(error.localizedDescription)")
            }
        }
        #endif
    }

    /// Dispatches a local user notification and broadcasts when a torrent fails.
    public static func postTorrentFailedNotification(name: String, infoHash: String, error: String) {
        let key = "torrent-failed-\(infoHash.lowercased())"
        lock.lock()
        ensureLoadedLocked()
        if notifiedIDs.contains(key) {
            lock.unlock()
            return
        }
        notifiedIDs.insert(key)
        savePersistedNotifiedIDsLocked()
        lock.unlock()

        NotificationCenter.default.post(
            name: torrentDidFailNotification,
            object: nil,
            userInfo: [
                torrentInfoHashUserInfoKey: infoHash,
                torrentNameUserInfoKey: name,
                torrentErrorUserInfoKey: error
            ]
        )
    }

    /// Resets the notified download tracking (primarily for unit tests).
    public static func resetNotifiedIDs() {
        lock.lock()
        defer { lock.unlock() }
        notifiedIDs.removeAll()
        savePersistedNotifiedIDsLocked()
    }
}
