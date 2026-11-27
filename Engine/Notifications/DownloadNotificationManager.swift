import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Notification Permission Status

public enum NotificationPermissionStatus: String, Sendable, Codable, Equatable {
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral
}

// MARK: - Action & Category Identifiers

public enum DownloadNotificationCategory {
    public static let transferThreadIdentifier = "DownloadEngineKit.transfers"
    public static let activeTransfer = "DownloadEngineKit.category.activeTransfer"
    public static let pausedTransfer = "DownloadEngineKit.category.pausedTransfer"
    public static let failedTransfer = "DownloadEngineKit.category.failedTransfer"
    public static let completedTransfer = "DownloadEngineKit.category.completedTransfer"
    public static let activeLiveRecording = "DownloadEngineKit.category.activeLiveRecording"
}

public enum DownloadNotificationAction {
    public static let open = "DownloadEngineKit.action.open"
    public static let pause = "DownloadEngineKit.action.pause"
    public static let resume = "DownloadEngineKit.action.resume"
    public static let cancel = "DownloadEngineKit.action.cancel"
    public static let retry = "DownloadEngineKit.action.retry"
    public static let remove = "DownloadEngineKit.action.remove"
    public static let openInFiles = "DownloadEngineKit.action.openInFiles"
    public static let openLibraryItem = "DownloadEngineKit.action.openLibraryItem"
    public static let stopRecording = "DownloadEngineKit.action.stopRecording"
}

// MARK: - Action Delegate

public protocol DownloadNotificationActionDelegate: AnyObject, Sendable {
    func handleNotificationAction(actionIdentifier: String, transferID: String, userInfo: [String: Any])
}

// MARK: - Notification Center Transport Protocol (Testable & Decoupled)

public protocol NotificationCenterTransport: Sendable {
    func getNotificationSettings() async -> NotificationPermissionStatus
    #if canImport(UserNotifications)
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func addNotification(request: UNNotificationRequest) async throws
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async
    #endif
    func removePendingNotifications(identifiers: [String]) async
    func removeDeliveredNotifications(identifiers: [String]) async
    func removeAllDeliveredNotifications() async
    func getPendingNotificationIdentifiers() async -> [String]
    func getDeliveredNotificationIdentifiers() async -> [String]
}

// MARK: - System Notification Center Transport

#if canImport(UserNotifications)
public final class SystemNotificationCenterTransport: NotificationCenterTransport {
    public static let shared = SystemNotificationCenterTransport()

    public init() {}

    private var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil &&
        NSClassFromString("XCTest") == nil &&
        !Bundle.main.bundlePath.contains("Developer/usr/bin")
    }

    public func getNotificationSettings() async -> NotificationPermissionStatus {
        guard isSupported else { return .authorized }
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .notDetermined: continuation.resume(returning: .notDetermined)
                case .denied: continuation.resume(returning: .denied)
                case .authorized: continuation.resume(returning: .authorized)
                case .provisional: continuation.resume(returning: .provisional)
                case .ephemeral: continuation.resume(returning: .ephemeral)
                @unknown default: continuation.resume(returning: .authorized)
                }
            }
        }
    }

    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        guard isSupported else { return true }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    public func addNotification(request: UNNotificationRequest) async throws {
        guard isSupported else { return }
        return try await withCheckedThrowingContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async {
        guard isSupported else { return }
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    public func removePendingNotifications(identifiers: [String]) async {
        guard isSupported else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func removeDeliveredNotifications(identifiers: [String]) async {
        guard isSupported else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func removeAllDeliveredNotifications() async {
        guard isSupported else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    public func getPendingNotificationIdentifiers() async -> [String] {
        guard isSupported else { return [] }
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier))
            }
        }
    }

    public func getDeliveredNotificationIdentifiers() async -> [String] {
        guard isSupported else { return [] }
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.map(\.request.identifier))
            }
        }
    }
}
#endif

// MARK: - Mock Notification Center Transport for Unit Tests

public final class MockNotificationCenterTransport: NotificationCenterTransport {
    private let lock = NSLock()
    public var stubbedPermissionStatus: NotificationPermissionStatus = .notDetermined
    public var requestAuthorizationResult: Bool = true
    public private(set) var addedRequests: [Any] = []
    public private(set) var deliveredIdentifiers: [String] = []
    public private(set) var pendingIdentifiers: [String] = []
    public private(set) var removedPendingIdentifiers: [String] = []
    public private(set) var removedDeliveredIdentifiers: [String] = []
    public private(set) var wasRequestedAuthorization: Bool = false
    public private(set) var registeredCategoriesCount: Int = 0

    public init() {}

    public func getNotificationSettings() async -> NotificationPermissionStatus {
        lock.lock()
        defer { lock.unlock() }
        return stubbedPermissionStatus
    }

    #if canImport(UserNotifications)
    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        wasRequestedAuthorization = true
        stubbedPermissionStatus = requestAuthorizationResult ? .authorized : .denied
        return requestAuthorizationResult
    }

    public func addNotification(request: UNNotificationRequest) async throws {
        lock.lock()
        defer { lock.unlock() }
        addedRequests.append(request)
        pendingIdentifiers.append(request.identifier)
        deliveredIdentifiers.append(request.identifier)
    }

    public func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async {
        lock.lock()
        defer { lock.unlock() }
        registeredCategoriesCount = categories.count
    }
    #endif

    public func removePendingNotifications(identifiers: [String]) async {
        lock.lock()
        defer { lock.unlock() }
        removedPendingIdentifiers.append(contentsOf: identifiers)
        pendingIdentifiers.removeAll { identifiers.contains($0) }
    }

    public func removeDeliveredNotifications(identifiers: [String]) async {
        lock.lock()
        defer { lock.unlock() }
        removedDeliveredIdentifiers.append(contentsOf: identifiers)
        deliveredIdentifiers.removeAll { identifiers.contains($0) }
    }

    public func removeAllDeliveredNotifications() async {
        lock.lock()
        defer { lock.unlock() }
        deliveredIdentifiers.removeAll()
    }

    public func getPendingNotificationIdentifiers() async -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return pendingIdentifiers
    }

    public func getDeliveredNotificationIdentifiers() async -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return deliveredIdentifiers
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        addedRequests.removeAll()
        deliveredIdentifiers.removeAll()
        pendingIdentifiers.removeAll()
        removedPendingIdentifiers.removeAll()
        removedDeliveredIdentifiers.removeAll()
        wasRequestedAuthorization = false
        registeredCategoriesCount = 0
        stubbedPermissionStatus = .notDetermined
    }
}

// MARK: - Transfer Progress Notification Record

public struct TransferProgressSnapshot: Sendable, Codable, Equatable {
    public let transferID: String
    public let filename: String
    public let progress: Double
    public let speedBytesPerSecond: Double
    public let remainingSeconds: TimeInterval?
    public let stateDescription: String
    public let timestamp: Date

    public init(
        transferID: String,
        filename: String,
        progress: Double,
        speedBytesPerSecond: Double,
        remainingSeconds: TimeInterval?,
        stateDescription: String,
        timestamp: Date = Date()
    ) {
        self.transferID = transferID
        self.filename = filename
        self.progress = progress
        self.speedBytesPerSecond = speedBytesPerSecond
        self.remainingSeconds = remainingSeconds
        self.stateDescription = stateDescription
        self.timestamp = timestamp
    }
}

// MARK: - Comprehensive Download Notification Manager

/// Manages notification permissions, lifecycle dispatches, throttled progress notifications,
/// actionable controls, and relaunch reconciliation across HTTP, torrent, and live recording transfers.
public enum DownloadNotificationManager {

    // MARK: - Notification Names: HTTP & Stream Transfers

    public static let downloadDidQueueNotification = Notification.Name("DownloadEngineKit.DownloadDidQueue")
    public static let downloadDidStartNotification = Notification.Name("DownloadEngineKit.DownloadDidStart")
    public static let downloadDidPauseNotification = Notification.Name("DownloadEngineKit.DownloadDidPause")
    public static let downloadDidResumeNotification = Notification.Name("DownloadEngineKit.DownloadDidResume")
    public static let downloadDidFailNotification = Notification.Name("DownloadEngineKit.DownloadDidFail")
    public static let downloadDidCancelNotification = Notification.Name("DownloadEngineKit.DownloadDidCancel")
    public static let downloadDidCompleteNotification = Notification.Name("DownloadEngineKit.DownloadDidComplete")
    public static let downloadDidRetryNotification = Notification.Name("DownloadEngineKit.DownloadDidRetry")

    // MARK: - Notification Names: Torrent Swarms

    public static let torrentDidStartNotification = Notification.Name("DownloadEngineKit.TorrentDidStart")
    public static let torrentDidPauseNotification = Notification.Name("DownloadEngineKit.TorrentDidPause")
    public static let torrentDidCompleteNotification = Notification.Name("DownloadEngineKit.TorrentDidComplete")
    public static let torrentSeedingDidStopNotification = Notification.Name("DownloadEngineKit.TorrentSeedingDidStop")
    public static let torrentDidFailNotification = Notification.Name("DownloadEngineKit.TorrentDidFail")
    public static let torrentDiskFullNotification = Notification.Name("DownloadEngineKit.TorrentDiskFull")
    public static let torrentTrackerFailedNotification = Notification.Name("DownloadEngineKit.TorrentTrackerFailed")

    // MARK: - Notification Names: Live Stream Recording

    public static let liveRecordingDidStartNotification = Notification.Name("DownloadEngineKit.LiveRecordingDidStart")
    public static let liveRecordingDidInterruptNotification = Notification.Name("DownloadEngineKit.LiveRecordingDidInterrupt")
    public static let liveRecordingDidRecoverNotification = Notification.Name("DownloadEngineKit.LiveRecordingDidRecover")
    public static let liveRecordingDidStopNotification = Notification.Name("DownloadEngineKit.LiveRecordingDidStop")
    public static let liveRecordingDidCompleteNotification = Notification.Name("DownloadEngineKit.LiveRecordingDidComplete")

    // MARK: - UserInfo Keys

    public static let downloadIDUserInfoKey = "downloadID"
    public static let filenameUserInfoKey = "filename"
    public static let destinationURLUserInfoKey = "destinationURL"
    public static let progressUserInfoKey = "progress"
    public static let errorUserInfoKey = "error"
    public static let retryAttemptUserInfoKey = "attempt"

    public static let torrentInfoHashUserInfoKey = "infoHash"
    public static let torrentNameUserInfoKey = "name"
    public static let torrentReasonUserInfoKey = "reason"
    public static let torrentErrorUserInfoKey = "error"
    public static let torrentAvailableBytesUserInfoKey = "availableBytes"
    public static let torrentTrackerURLUserInfoKey = "trackerURL"

    public static let liveSessionIDUserInfoKey = "sessionID"
    public static let liveTitleUserInfoKey = "title"
    public static let liveDurationUserInfoKey = "duration"
    public static let liveReasonUserInfoKey = "reason"

    // MARK: - Storage & Configuration

    private static let lock = NSLock()
    private static var notifiedIDs: Set<String> = []
    private static var activeTransferSnapshots: [String: TransferProgressSnapshot] = [:]
    private static var isInitialized = false
    private static var customPersistenceFileURL: URL? = nil

    #if canImport(UserNotifications)
    public static var transport: NotificationCenterTransport = SystemNotificationCenterTransport.shared
    #else
    public static var transport: NotificationCenterTransport = MockNotificationCenterTransport()
    #endif

    public static weak var actionDelegate: DownloadNotificationActionDelegate? = nil

    public static var isUserNotificationsAvailable: Bool {
        #if canImport(UserNotifications)
        if transport is MockNotificationCenterTransport {
            return true
        }
        return Bundle.main.bundleIdentifier != nil &&
               NSClassFromString("XCTest") == nil &&
               !Bundle.main.bundlePath.contains("Developer/usr/bin")
        #else
        return false
        #endif
    }

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
        do {
            try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        } catch {
            PipelineLogger.shared.log(stage: .persistence, message: "[DownloadNotificationManager] Failed to create notification directory \(baseDir.path): \(error.localizedDescription)")
        }
        return baseDir.appendingPathComponent("notified_downloads.json")
    }

    private static var activeNotificationFileURL: URL? {
        persistenceFileURL?.deletingLastPathComponent().appendingPathComponent("active_transfer_notifications.json")
    }

    public static func setPersistenceFileURL(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        customPersistenceFileURL = url
        isInitialized = false
        notifiedIDs.removeAll()
        activeTransferSnapshots.removeAll()
        ensureLoadedLocked()
    }

    private static func ensureLoadedLocked() {
        guard !isInitialized else { return }
        isInitialized = true
        if let url = persistenceFileURL {
            do {
                if let array: [String] = try DurableStorage.load(from: url) {
                    notifiedIDs = Set(array)
                }
            } catch {
                PipelineLogger.shared.log(stage: .persistence, message: "[DownloadNotificationManager] Failed to load notified IDs from \(url.path): \(error.localizedDescription)")
            }
        }
        if let url = activeNotificationFileURL {
            do {
                if let map: [String: TransferProgressSnapshot] = try DurableStorage.load(from: url) {
                    activeTransferSnapshots = map
                }
            } catch {
                PipelineLogger.shared.log(stage: .persistence, message: "[DownloadNotificationManager] Failed to load active notification snapshots from \(url.path): \(error.localizedDescription)")
            }
        }
    }

    #if canImport(UserNotifications)
    private static func dispatchNotification(_ request: UNNotificationRequest) {
        Task {
            do {
                try await transport.addNotification(request: request)
            } catch {
                PipelineLogger.shared.log(stage: .persistence, message: "[DownloadNotificationManager] Failed to dispatch notification '\(request.identifier)': \(error.localizedDescription)")
            }
        }
    }
    #endif

    private static func savePersistedNotifiedIDsLocked() {
        guard let url = persistenceFileURL else { return }
        do {
            let data = try JSONEncoder().encode(Array(notifiedIDs))
            try DurableStorage.writeAtomically(data, to: url)
        } catch {
            PipelineLogger.shared.log(
                stage: .persistence,
                message: "[DownloadNotificationManager] Failed to persist notified IDs to \(url.path): \(error.localizedDescription)"
            )
        }
    }

    private static func savePersistedActiveSnapshotsLocked() {
        guard let url = activeNotificationFileURL else { return }
        do {
            let data = try JSONEncoder().encode(activeTransferSnapshots)
            try DurableStorage.writeAtomically(data, to: url)
        } catch {
            PipelineLogger.shared.log(
                stage: .persistence,
                message: "[DownloadNotificationManager] Failed to persist active notification snapshots to \(url.path): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Permission Request & Settings Flow

    public static var openSettingsURL: URL? {
        #if canImport(UIKit) && !os(watchOS)
        return URL(string: UIApplication.openSettingsURLString)
        #elseif canImport(AppKit)
        return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        #else
        return nil
        #endif
    }

    public static func checkPermissionStatus() async -> NotificationPermissionStatus {
        await transport.getNotificationSettings()
    }

    @discardableResult
    public static func requestPermissionBeforeFirstDownload() async -> Bool {
        let status = await transport.getNotificationSettings()
        if status == .authorized || status == .provisional {
            return true
        }
        if status == .denied {
            return false
        }
        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return true }
        do {
            let granted = try await transport.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                await registerNotificationCategories()
            }
            return granted
        } catch {
            PipelineLogger.shared.log(stage: .coordinator, message: "[DownloadNotificationManager] Authorization request failed: \(error.localizedDescription)")
            return false
        }
        #else
        return true
        #endif
    }

    // MARK: - Actionable Categories Registration

    public static func registerNotificationCategories() async {
        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let openAction = UNNotificationAction(
            identifier: DownloadNotificationAction.open,
            title: "Open",
            options: [.foreground]
        )
        let pauseAction = UNNotificationAction(
            identifier: DownloadNotificationAction.pause,
            title: "Pause",
            options: []
        )
        let resumeAction = UNNotificationAction(
            identifier: DownloadNotificationAction.resume,
            title: "Resume",
            options: []
        )
        let cancelAction = UNNotificationAction(
            identifier: DownloadNotificationAction.cancel,
            title: "Cancel",
            options: [.destructive]
        )
        let retryAction = UNNotificationAction(
            identifier: DownloadNotificationAction.retry,
            title: "Retry",
            options: [.foreground]
        )
        let removeAction = UNNotificationAction(
            identifier: DownloadNotificationAction.remove,
            title: "Remove",
            options: [.destructive]
        )
        let openInFilesAction = UNNotificationAction(
            identifier: DownloadNotificationAction.openInFiles,
            title: "Open in Files",
            options: [.foreground]
        )
        let openLibraryItemAction = UNNotificationAction(
            identifier: DownloadNotificationAction.openLibraryItem,
            title: "Open Library Item",
            options: [.foreground]
        )
        let stopRecordingAction = UNNotificationAction(
            identifier: DownloadNotificationAction.stopRecording,
            title: "Stop Recording",
            options: [.destructive]
        )

        let activeCategory = UNNotificationCategory(
            identifier: DownloadNotificationCategory.activeTransfer,
            actions: [pauseAction, cancelAction],
            intentIdentifiers: [],
            options: []
        )
        let pausedCategory = UNNotificationCategory(
            identifier: DownloadNotificationCategory.pausedTransfer,
            actions: [resumeAction, cancelAction],
            intentIdentifiers: [],
            options: []
        )
        let failedCategory = UNNotificationCategory(
            identifier: DownloadNotificationCategory.failedTransfer,
            actions: [retryAction, removeAction],
            intentIdentifiers: [],
            options: []
        )
        let completedCategory = UNNotificationCategory(
            identifier: DownloadNotificationCategory.completedTransfer,
            actions: [openInFilesAction, openLibraryItemAction, openAction],
            intentIdentifiers: [],
            options: []
        )
        let activeLiveCategory = UNNotificationCategory(
            identifier: DownloadNotificationCategory.activeLiveRecording,
            actions: [stopRecordingAction],
            intentIdentifiers: [],
            options: []
        )

        let categories: Set<UNNotificationCategory> = [
            activeCategory,
            pausedCategory,
            failedCategory,
            completedCategory,
            activeLiveCategory
        ]
        await transport.setNotificationCategories(categories)
        #endif
    }

    // MARK: - Action Handling Dispatcher

    public static func handleAction(actionIdentifier: String, transferID: String, userInfo: [String: Any]) {
        actionDelegate?.handleNotificationAction(
            actionIdentifier: actionIdentifier,
            transferID: transferID,
            userInfo: userInfo
        )
    }

    // MARK: - Progress Updates (Single Stable Throttled Notification per Transfer)

    public static func progressNotificationIdentifier(for transferID: String) -> String {
        "transfer-progress-\(transferID)"
    }

    public static func updateTransferProgress(
        transferID: String,
        filename: String,
        progress: Double,
        speedBytesPerSecond: Double,
        remainingSeconds: TimeInterval?,
        stateDescription: String
    ) {
        lock.lock()
        ensureLoadedLocked()
        let previous = activeTransferSnapshots[transferID]
        let now = Date()

        // Throttling Rule:
        // Update only when:
        // 1. First time
        // 2. Progress jumped >= 5% (0.05)
        // 3. State description changed (e.g. Downloading -> Paused -> Failed)
        // 4. At least 2.5 seconds have elapsed since the last notification
        let shouldUpdate: Bool
        if let prev = previous {
            let progressJump = abs(progress - prev.progress) >= 0.05
            let stateChanged = stateDescription != prev.stateDescription
            let timeElapsed = now.timeIntervalSince(prev.timestamp) >= 2.5
            shouldUpdate = progressJump || stateChanged || timeElapsed
        } else {
            shouldUpdate = true
        }

        if !shouldUpdate {
            lock.unlock()
            return
        }

        let snapshot = TransferProgressSnapshot(
            transferID: transferID,
            filename: filename,
            progress: progress,
            speedBytesPerSecond: speedBytesPerSecond,
            remainingSeconds: remainingSeconds,
            stateDescription: stateDescription,
            timestamp: now
        )
        activeTransferSnapshots[transferID] = snapshot
        savePersistedActiveSnapshotsLocked()
        lock.unlock()

        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = filename
        content.threadIdentifier = DownloadNotificationCategory.transferThreadIdentifier
        let percent = Int(progress * 100)
        let speedText = speedBytesPerSecond > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSecond), countStyle: .file) + "/s"
            : ""
        let etaText = formatETA(remainingSeconds)

        var parts: [String] = []
        if !stateDescription.isEmpty && stateDescription.lowercased() != "downloading" {
            parts.append(stateDescription)
        }
        parts.append("\(percent)%")
        if !speedText.isEmpty { parts.append(speedText) }
        if !etaText.isEmpty { parts.append(etaText) }
        content.body = parts.joined(separator: " • ")

        if stateDescription.lowercased().contains("paused") {
            content.categoryIdentifier = DownloadNotificationCategory.pausedTransfer
        } else if stateDescription.lowercased().contains("failed") {
            content.categoryIdentifier = DownloadNotificationCategory.failedTransfer
        } else {
            content.categoryIdentifier = DownloadNotificationCategory.activeTransfer
        }
        content.userInfo = [
            downloadIDUserInfoKey: transferID,
            filenameUserInfoKey: filename,
            progressUserInfoKey: progress
        ]

        let identifier = progressNotificationIdentifier(for: transferID)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        dispatchNotification(request)
        #endif
    }

    public static func removeProgressNotification(for transferID: String) {
        lock.lock()
        ensureLoadedLocked()
        activeTransferSnapshots.removeValue(forKey: transferID)
        savePersistedActiveSnapshotsLocked()
        lock.unlock()

        let identifier = progressNotificationIdentifier(for: transferID)
        Task {
            await transport.removePendingNotifications(identifiers: [identifier])
            await transport.removeDeliveredNotifications(identifiers: [identifier])
        }
    }

    public static func removeAllNotifications(for transferID: String) {
        removeProgressNotification(for: transferID)
        let completionID = "download-completed-\(transferID)"
        let torrentCompID = "torrent-completed-\(transferID.lowercased())"
        Task {
            await transport.removePendingNotifications(identifiers: [completionID, torrentCompID])
            await transport.removeDeliveredNotifications(identifiers: [completionID, torrentCompID])
        }
    }

    // MARK: - Relaunch Reconciliation

    public static func reconcileActiveNotifications(knownActiveTransferIDs: Set<String>) async {
        lock.lock()
        ensureLoadedLocked()
        var orphanedIDs: [String] = []
        for id in activeTransferSnapshots.keys {
            if !knownActiveTransferIDs.contains(id) {
                orphanedIDs.append(id)
            }
        }
        for id in orphanedIDs {
            activeTransferSnapshots.removeValue(forKey: id)
        }
        savePersistedActiveSnapshotsLocked()
        lock.unlock()

        let orphanedProgressIdentifiers = orphanedIDs.map { progressNotificationIdentifier(for: $0) }
        if !orphanedProgressIdentifiers.isEmpty {
            await transport.removePendingNotifications(identifiers: orphanedProgressIdentifiers)
            await transport.removeDeliveredNotifications(identifiers: orphanedProgressIdentifiers)
        }
    }

    // MARK: - Helper Formatting

    private static func formatETA(_ remaining: TimeInterval?) -> String {
        guard let remaining = remaining, remaining > 0, remaining.isFinite else { return "" }
        let total = Int(remaining)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s left"
        } else {
            return "\(seconds)s left"
        }
    }

    // MARK: - Deduplication & ID Tracking (Backward Compatible)

    public static func isNotified(downloadID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        return notifiedIDs.contains(downloadID)
    }

    public static func clearNotifiedID(downloadID: String) {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        notifiedIDs.remove(downloadID)
        savePersistedNotifiedIDsLocked()
    }

    public static func resetNotifiedIDs() {
        lock.lock()
        defer { lock.unlock() }
        notifiedIDs.removeAll()
        activeTransferSnapshots.removeAll()
        savePersistedNotifiedIDsLocked()
        savePersistedActiveSnapshotsLocked()
    }

    // MARK: - Lifecycle Dispatches: HTTP & Stream Transfers

    public static func postDownloadQueuedNotification(filename: String, downloadID: String) {
        NotificationCenter.default.post(
            name: downloadDidQueueNotification,
            object: nil,
            userInfo: [downloadIDUserInfoKey: downloadID, filenameUserInfoKey: filename]
        )
    }

    public static func postDownloadStartedNotification(filename: String, downloadID: String) {
        NotificationCenter.default.post(
            name: downloadDidStartNotification,
            object: nil,
            userInfo: [downloadIDUserInfoKey: downloadID, filenameUserInfoKey: filename]
        )
    }

    public static func postDownloadPausedNotification(filename: String, downloadID: String) {
        NotificationCenter.default.post(
            name: downloadDidPauseNotification,
            object: nil,
            userInfo: [downloadIDUserInfoKey: downloadID, filenameUserInfoKey: filename]
        )
        updateTransferProgress(
            transferID: downloadID,
            filename: filename,
            progress: activeTransferSnapshots[downloadID]?.progress ?? 0,
            speedBytesPerSecond: 0,
            remainingSeconds: nil,
            stateDescription: "Paused"
        )
    }

    public static func postDownloadResumedNotification(filename: String, downloadID: String) {
        NotificationCenter.default.post(
            name: downloadDidResumeNotification,
            object: nil,
            userInfo: [downloadIDUserInfoKey: downloadID, filenameUserInfoKey: filename]
        )
    }

    public static func postDownloadFailedNotification(filename: String, downloadID: String, error: String) {
        removeProgressNotification(for: downloadID)
        NotificationCenter.default.post(
            name: downloadDidFailNotification,
            object: nil,
            userInfo: [
                downloadIDUserInfoKey: downloadID,
                filenameUserInfoKey: filename,
                errorUserInfoKey: error
            ]
        )

        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download Failed"
        content.body = "\(filename): \(error)"
        content.sound = .default
        content.threadIdentifier = DownloadNotificationCategory.transferThreadIdentifier
        content.categoryIdentifier = DownloadNotificationCategory.failedTransfer
        content.userInfo = [
            downloadIDUserInfoKey: downloadID,
            filenameUserInfoKey: filename,
            errorUserInfoKey: error
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "download-failed-\(downloadID)",
            content: content,
            trigger: trigger
        )
        dispatchNotification(request)
        #endif
    }

    public static func postAllDownloadsCompletedNotification(completedCount: Int) {
        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable, completedCount > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "All Downloads Complete"
        content.body = completedCount == 1
            ? "1 download finished."
            : "\(completedCount) downloads finished."
        content.sound = .default
        content.threadIdentifier = DownloadNotificationCategory.transferThreadIdentifier
        content.categoryIdentifier = DownloadNotificationCategory.completedTransfer

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "downloads-all-complete",
            content: content,
            trigger: trigger
        )
        dispatchNotification(request)
        #endif
    }

    public static func postDownloadCancelledNotification(filename: String, downloadID: String) {
        removeProgressNotification(for: downloadID)
        NotificationCenter.default.post(
            name: downloadDidCancelNotification,
            object: nil,
            userInfo: [downloadIDUserInfoKey: downloadID, filenameUserInfoKey: filename]
        )
    }

    public static func postDownloadCompletedNotification(
        filename: String,
        downloadID: String,
        destinationURL: URL? = nil
    ) {
        lock.lock()
        ensureLoadedLocked()
        if notifiedIDs.contains(downloadID) {
            lock.unlock()
            return
        }
        notifiedIDs.insert(downloadID)
        savePersistedNotifiedIDsLocked()
        lock.unlock()

        removeProgressNotification(for: downloadID)

        var userInfo: [String: Any] = [
            downloadIDUserInfoKey: downloadID,
            filenameUserInfoKey: filename
        ]
        if let destinationURL = destinationURL {
            userInfo[destinationURLUserInfoKey] = destinationURL.path
        }

        NotificationCenter.default.post(
            name: downloadDidCompleteNotification,
            object: nil,
            userInfo: userInfo
        )

        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = filename
        content.sound = .default
        content.categoryIdentifier = DownloadNotificationCategory.completedTransfer
        content.threadIdentifier = DownloadNotificationCategory.transferThreadIdentifier
        content.userInfo = userInfo

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "download-completed-\(downloadID)",
            content: content,
            trigger: trigger
        )
        dispatchNotification(request)
        #endif
    }

    public static func postDownloadRetriedNotification(filename: String, downloadID: String, attempt: Int) {
        NotificationCenter.default.post(
            name: downloadDidRetryNotification,
            object: nil,
            userInfo: [
                downloadIDUserInfoKey: downloadID,
                filenameUserInfoKey: filename,
                retryAttemptUserInfoKey: attempt
            ]
        )
    }

    // MARK: - Lifecycle Dispatches: Torrent Swarms

    public static func postTorrentStartedNotification(name: String, infoHash: String) {
        NotificationCenter.default.post(
            name: torrentDidStartNotification,
            object: nil,
            userInfo: [torrentInfoHashUserInfoKey: infoHash, torrentNameUserInfoKey: name]
        )
    }

    public static func postTorrentPausedNotification(name: String, infoHash: String) {
        NotificationCenter.default.post(
            name: torrentDidPauseNotification,
            object: nil,
            userInfo: [torrentInfoHashUserInfoKey: infoHash, torrentNameUserInfoKey: name]
        )
        updateTransferProgress(
            transferID: infoHash,
            filename: name,
            progress: activeTransferSnapshots[infoHash]?.progress ?? 0,
            speedBytesPerSecond: 0,
            remainingSeconds: nil,
            stateDescription: "Paused"
        )
    }

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

        removeProgressNotification(for: infoHash)

        NotificationCenter.default.post(
            name: torrentDidCompleteNotification,
            object: nil,
            userInfo: [
                torrentInfoHashUserInfoKey: infoHash,
                torrentNameUserInfoKey: name
            ]
        )

        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Torrent Complete"
        content.body = name
        content.sound = .default
        content.categoryIdentifier = DownloadNotificationCategory.completedTransfer
        content.userInfo = [
            torrentInfoHashUserInfoKey: infoHash,
            torrentNameUserInfoKey: name
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: key, content: content, trigger: trigger)
        dispatchNotification(request)
        #endif
    }

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
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Seeding Finished"
        content.body = "\(name): \(reason)"
        content.sound = .default
        content.userInfo = [
            torrentInfoHashUserInfoKey: infoHash,
            torrentNameUserInfoKey: name,
            torrentReasonUserInfoKey: reason
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: key, content: content, trigger: trigger)
        dispatchNotification(request)
        #endif
    }

    public static func postTorrentFailedNotification(name: String, infoHash: String, error: String) {
        removeProgressNotification(for: infoHash)
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

        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Torrent Error"
        content.body = "\(name): \(error)"
        content.sound = .default
        content.categoryIdentifier = DownloadNotificationCategory.failedTransfer
        content.userInfo = [
            torrentInfoHashUserInfoKey: infoHash,
            torrentNameUserInfoKey: name,
            torrentErrorUserInfoKey: error
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: key, content: content, trigger: trigger)
        dispatchNotification(request)
        #endif
    }

    public static func postTorrentDiskFullNotification(name: String, infoHash: String, availableBytes: Int64) {
        NotificationCenter.default.post(
            name: torrentDiskFullNotification,
            object: nil,
            userInfo: [
                torrentInfoHashUserInfoKey: infoHash,
                torrentNameUserInfoKey: name,
                torrentAvailableBytesUserInfoKey: availableBytes
            ]
        )

        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Disk Space Critical"
        let availStr = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
        content.body = "\(name) paused: insufficient storage (\(availStr) free)."
        content.sound = .default
        content.categoryIdentifier = DownloadNotificationCategory.failedTransfer
        content.userInfo = [
            torrentInfoHashUserInfoKey: infoHash,
            torrentNameUserInfoKey: name
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: "torrent-diskfull-\(infoHash.lowercased())", content: content, trigger: trigger)
        dispatchNotification(request)
        #endif
    }

    public static func postTorrentTrackerFailedNotification(name: String, infoHash: String, trackerURL: String, error: String) {
        NotificationCenter.default.post(
            name: torrentTrackerFailedNotification,
            object: nil,
            userInfo: [
                torrentInfoHashUserInfoKey: infoHash,
                torrentNameUserInfoKey: name,
                torrentTrackerURLUserInfoKey: trackerURL,
                torrentErrorUserInfoKey: error
            ]
        )
    }

    // MARK: - Lifecycle Dispatches: Live Stream Recording

    public static func postLiveRecordingStartedNotification(sessionID: String, title: String) {
        NotificationCenter.default.post(
            name: liveRecordingDidStartNotification,
            object: nil,
            userInfo: [liveSessionIDUserInfoKey: sessionID, liveTitleUserInfoKey: title]
        )

        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Live Recording Started"
        content.body = title
        content.sound = .default
        content.categoryIdentifier = DownloadNotificationCategory.activeLiveRecording
        content.userInfo = [liveSessionIDUserInfoKey: sessionID, liveTitleUserInfoKey: title]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: "live-started-\(sessionID)", content: content, trigger: trigger)
        dispatchNotification(request)
        #endif
    }

    public static func postLiveRecordingInterruptedNotification(sessionID: String, title: String, reason: String) {
        NotificationCenter.default.post(
            name: liveRecordingDidInterruptNotification,
            object: nil,
            userInfo: [
                liveSessionIDUserInfoKey: sessionID,
                liveTitleUserInfoKey: title,
                liveReasonUserInfoKey: reason
            ]
        )

        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Live Recording Interrupted"
        content.body = "\(title): \(reason)"
        content.sound = .default
        content.categoryIdentifier = DownloadNotificationCategory.failedTransfer
        content.userInfo = [liveSessionIDUserInfoKey: sessionID, liveTitleUserInfoKey: title]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: "live-interrupted-\(sessionID)", content: content, trigger: trigger)
        dispatchNotification(request)
        #endif
    }

    public static func postLiveRecordingRecoveredNotification(sessionID: String, title: String) {
        NotificationCenter.default.post(
            name: liveRecordingDidRecoverNotification,
            object: nil,
            userInfo: [liveSessionIDUserInfoKey: sessionID, liveTitleUserInfoKey: title]
        )

        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Live Recording Resumed"
        content.body = "Recovered recording for \(title)"
        content.sound = .default
        content.categoryIdentifier = DownloadNotificationCategory.activeLiveRecording
        content.userInfo = [liveSessionIDUserInfoKey: sessionID, liveTitleUserInfoKey: title]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: "live-recovered-\(sessionID)", content: content, trigger: trigger)
        dispatchNotification(request)
        #endif
    }

    public static func postLiveRecordingStoppedNotification(sessionID: String, title: String, duration: TimeInterval) {
        NotificationCenter.default.post(
            name: liveRecordingDidStopNotification,
            object: nil,
            userInfo: [
                liveSessionIDUserInfoKey: sessionID,
                liveTitleUserInfoKey: title,
                liveDurationUserInfoKey: duration
            ]
        )
    }

    public static func postLiveRecordingCompletedNotification(sessionID: String, title: String, fileURL: URL, duration: TimeInterval) {
        NotificationCenter.default.post(
            name: liveRecordingDidCompleteNotification,
            object: nil,
            userInfo: [
                liveSessionIDUserInfoKey: sessionID,
                liveTitleUserInfoKey: title,
                destinationURLUserInfoKey: fileURL.path,
                liveDurationUserInfoKey: duration
            ]
        )

        #if canImport(UserNotifications)
        guard isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Recording Complete"
        let durStr = formatETA(duration)
        content.body = "\(title) (\(durStr.isEmpty ? "Saved" : durStr))"
        content.sound = .default
        content.categoryIdentifier = DownloadNotificationCategory.completedTransfer
        content.userInfo = [
            liveSessionIDUserInfoKey: sessionID,
            liveTitleUserInfoKey: title,
            destinationURLUserInfoKey: fileURL.path
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: "live-complete-\(sessionID)", content: content, trigger: trigger)
        dispatchNotification(request)
        #endif
    }
}
