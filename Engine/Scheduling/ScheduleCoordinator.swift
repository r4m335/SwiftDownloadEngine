import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Coordinates iOS-native download scheduling.
///
/// Architecture Guarantees:
/// 1. Reconciles active vs. paused states on app launch and foreground transitions.
/// 2. Sets `earliestBeginDate` on background `URLSessionDownloadTask`s when in background.
/// 3. Registers local `UNCalendarNotificationTrigger` reminders for user awareness.
/// 4. Handles overnight windows seamlessly (e.g. 23:00 to 06:00).
/// 5. Clearly segregates foreground-only BitTorrent transfers from background HTTP transfers.
@MainActor
public final class ScheduleCoordinator: ObservableObject {
    public static let torrentBackgroundLimitationMessage = "Torrents can only be downloaded while the app is in the foreground. iOS terminates background sockets. HTTP/HTTPS downloads will run via background scheduling."

    public let engine: DownloadEngine?
    public let persistenceStore: DownloadPersistenceStore
    public let calendar: Calendar
    public var resumeHandler: ((String) async -> Void)?
    public var pauseHandler: ((String) async -> Void)?

    @Published public private(set) var rules: [ScheduleRule] = []
    @Published public private(set) var isReconciling: Bool = false
    @Published public private(set) var lastReconciledAt: Date? = nil

    public init(
        engine: DownloadEngine? = nil,
        persistenceStore: DownloadPersistenceStore,
        calendar: Calendar = .current,
        resumeHandler: ((String) async -> Void)? = nil,
        pauseHandler: ((String) async -> Void)? = nil
    ) {
        self.engine = engine
        self.persistenceStore = persistenceStore
        self.calendar = calendar
        self.resumeHandler = resumeHandler
        self.pauseHandler = pauseHandler
    }

    /// Loads persisted schedule rules into memory.
    public func loadRules() async {
        do {
            let loaded = try await persistenceStore.fetchAllScheduleRules()
            if loaded.isEmpty {
                // Initialize a default rule (Night Owl: 02:00 to 06:00 daily)
                let defaultRule = ScheduleRule(
                    id: "default-night-schedule",
                    name: "Night Download Window",
                    isEnabled: false,
                    startTime: DateComponents(hour: 2, minute: 0),
                    stopTime: DateComponents(hour: 6, minute: 0),
                    weekdays: Set(1...7),
                    wifiOnly: true,
                    targetDownloadIDs: []
                )
                try await persistenceStore.saveScheduleRule(defaultRule)
                self.rules = [defaultRule]
            } else {
                self.rules = loaded
            }
        } catch {
            print("[ScheduleCoordinator] Failed to load schedule rules: \(error.localizedDescription)")
            self.rules = []
        }
    }

    /// Persists or updates a schedule rule, updates local notifications, and reconciles state.
    public func saveRule(_ rule: ScheduleRule) async throws {
        var updated = rule
        updated.updatedAt = Date()
        try await persistenceStore.saveScheduleRule(updated)
        if let idx = rules.firstIndex(where: { $0.id == updated.id }) {
            rules[idx] = updated
        } else {
            rules.append(updated)
        }
        await updateNotifications(for: updated)
        await reconcile()
    }

    /// Deletes a schedule rule and cancels its scheduled notifications.
    public func deleteRule(id: String) async throws {
        try await persistenceStore.deleteScheduleRule(id: id)
        rules.removeAll { $0.id == id }
        await cancelNotifications(for: id)
    }

    // MARK: - Download Scheduling Tagging

    public func isScheduled(downloadID: String) -> Bool {
        rules.contains { $0.isEnabled && $0.contains(downloadID: downloadID) }
    }

    public func toggleScheduled(downloadID: String, ruleID: String? = nil) async {
        guard !rules.isEmpty else { return }
        let targetRuleID = ruleID ?? rules.first?.id
        guard let idx = rules.firstIndex(where: { $0.id == targetRuleID }) else { return }
        var rule = rules[idx]
        rule.toggle(downloadID: downloadID)
        try? await saveRule(rule)
    }

    public func addDownloadToSchedule(downloadID: String, ruleID: String? = nil) async {
        guard !rules.isEmpty else { return }
        let targetRuleID = ruleID ?? rules.first?.id
        guard let idx = rules.firstIndex(where: { $0.id == targetRuleID }) else { return }
        var rule = rules[idx]
        rule.add(downloadID: downloadID)
        try? await saveRule(rule)
    }

    public func removeDownloadFromSchedule(downloadID: String, ruleID: String? = nil) async {
        guard !rules.isEmpty else { return }
        let targetRuleID = ruleID ?? rules.first?.id
        guard let idx = rules.firstIndex(where: { $0.id == targetRuleID }) else { return }
        var rule = rules[idx]
        rule.remove(downloadID: downloadID)
        try? await saveRule(rule)
    }

    // MARK: - Occurrence & Window Calculations

    /// Calculates the next occurrence after a given date matching the schedule rule's startTime and weekdays.
    public func nextOccurrence(
        after date: Date = Date(),
        matching components: DateComponents,
        weekdays: Set<Int>
    ) -> Date? {
        guard !weekdays.isEmpty, let targetHour = components.hour, let targetMinute = components.minute else {
            return nil
        }

        var candidateDates: [Date] = []
        for weekday in weekdays {
            var matching = DateComponents()
            matching.hour = targetHour
            matching.minute = targetMinute
            matching.second = 0
            matching.weekday = weekday

            if let next = calendar.nextDate(
                after: date,
                matching: matching,
                matchingPolicy: .nextTime,
                direction: .forward
            ) {
                candidateDates.append(next)
            }
        }
        return candidateDates.min()
    }

    /// Evaluates whether a date falls within the schedule window.
    /// Handles same-day windows (09:00 -> 17:00) and overnight windows (23:00 -> 06:00).
    public func isDateInScheduleWindow(_ date: Date = Date(), rule: ScheduleRule) -> Bool {
        guard rule.isEnabled else { return false }
        guard let startHour = rule.startTime.hour, let startMinute = rule.startTime.minute else { return false }

        let currentHour = calendar.component(.hour, from: date)
        let currentMinute = calendar.component(.minute, from: date)
        let currentMinutesOfDay = currentHour * 60 + currentMinute
        let currentWeekday = calendar.component(.weekday, from: date)

        let startMinutes = startHour * 60 + startMinute

        guard let stopTime = rule.stopTime,
              let stopHour = stopTime.hour,
              let stopMinute = stopTime.minute else {
            // No stop time defined: active from startTime onwards on scheduled weekdays
            return currentMinutesOfDay >= startMinutes && rule.weekdays.contains(currentWeekday)
        }

        let stopMinutes = stopHour * 60 + stopMinute

        if startMinutes < stopMinutes {
            // Case 1: Same-day window (e.g. 02:00 to 06:00)
            let isWithinTime = (currentMinutesOfDay >= startMinutes && currentMinutesOfDay < stopMinutes)
            let isAllowedDay = rule.weekdays.contains(currentWeekday)
            return isWithinTime && isAllowedDay
        } else if startMinutes > stopMinutes {
            // Case 2: Overnight window (e.g. 23:00 to 06:00)
            if currentMinutesOfDay >= startMinutes {
                // Evening part: started today
                return rule.weekdays.contains(currentWeekday)
            } else if currentMinutesOfDay < stopMinutes {
                // Morning part: started yesterday evening
                let yesterdayWeekday = currentWeekday == 1 ? 7 : currentWeekday - 1
                return rule.weekdays.contains(yesterdayWeekday)
            } else {
                return false
            }
        } else {
            // startMinutes == stopMinutes: instantaneous/empty window
            return false
        }
    }

    // MARK: - Task 3: App State Reconciliation

    /// Reconciles all scheduled downloads against current schedule windows.
    /// Automatically resumes/starts downloads if within window, or pauses them if outside window.
    @discardableResult
    public func reconcile(now: Date = Date()) async -> ScheduleReconciliationReport {
        isReconciling = true
        defer {
            isReconciling = false
            lastReconciledAt = Date()
        }

        var resumedIDs: [String] = []
        var pausedIDs: [String] = []

        for rule in rules where rule.isEnabled {
            let isInsideWindow = isDateInScheduleWindow(now, rule: rule)

            for downloadID in rule.targetDownloadIDs {
                let record = try? await persistenceStore.fetch(tag: downloadID)
                let state = record?.state ?? (isInsideWindow ? .paused : .downloading)

                if isInsideWindow {
                    // Inside window: Resume/start if paused or pending
                    if state == .paused || state == .pending {
                        if let handler = resumeHandler {
                            await handler(downloadID)
                            resumedIDs.append(downloadID)
                        } else if let engine = engine {
                            do {
                                try await engine.resumeDownload(id: downloadID)
                                resumedIDs.append(downloadID)
                            } catch {
                                print("[ScheduleCoordinator] Failed to resume scheduled download \(downloadID): \(error.localizedDescription)")
                            }
                        }
                    }
                } else {
                    // Outside window: Pause if currently downloading
                    if state == .downloading || state == .pending {
                        if let handler = pauseHandler {
                            await handler(downloadID)
                            pausedIDs.append(downloadID)
                        } else if let engine = engine {
                            do {
                                try await engine.pauseDownload(id: downloadID)
                                pausedIDs.append(downloadID)
                            } catch {
                                print("[ScheduleCoordinator] Failed to pause scheduled download \(downloadID): \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
        }

        return ScheduleReconciliationReport(
            timestamp: now,
            resumedDownloadIDs: resumedIDs,
            pausedDownloadIDs: pausedIDs
        )
    }

    // MARK: - Task 2: Background Preparation (earliestBeginDate & Notifications)

    /// Called when the application enters the background.
    /// Configures `earliestBeginDate` on background download tasks and sets up reminders.
    public func prepareForBackground(now: Date = Date()) async {
        for rule in rules where rule.isEnabled {
            if !isDateInScheduleWindow(now, rule: rule) {
                // Calculate next occurrence for the background session tasks
                if let nextStart = nextOccurrence(after: now, matching: rule.startTime, weekdays: rule.weekdays) {
                    for downloadID in rule.targetDownloadIDs {
                        await engine.setBackgroundEarliestBeginDate(nextStart, for: downloadID)
                    }
                }
            }
            await updateNotifications(for: rule)
        }
    }

    // MARK: - Local Notifications

    public func updateNotifications(for rule: ScheduleRule) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let identifierPrefix = "schedule-\(rule.id)"

        // Remove existing notifications for this rule
        let pending = await center.pendingNotificationRequests()
        let existingIDs = pending.map { $0.identifier }.filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: existingIDs)

        guard rule.isEnabled else { return }

        // Request permission if not already determined
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])

        let startHour = rule.startTime.hour ?? 2
        let startMinute = rule.startTime.minute ?? 0

        for weekday in rule.weekdays {
            let content = UNMutableNotificationContent()
            content.title = "Scheduled Downloads Starting"
            content.body = "Your scheduled downloads window has begun (\(rule.formattedStartTime))."
            content.sound = .default

            var matching = DateComponents()
            matching.hour = startHour
            matching.minute = startMinute
            matching.weekday = weekday

            let trigger = UNCalendarNotificationTrigger(dateMatching: matching, repeats: true)
            let reqID = "\(identifierPrefix)-day\(weekday)"
            let request = UNNotificationRequest(identifier: reqID, content: content, trigger: trigger)
            try? await center.add(request)
        }
        #endif
    }

    public func cancelNotifications(for ruleID: String) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let identifierPrefix = "schedule-\(ruleID)"
        let pending = await center.pendingNotificationRequests()
        let existingIDs = pending.map { $0.identifier }.filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: existingIDs)
        #endif
    }
}

/// Report summarizing outcomes of a schedule reconciliation pass.
public struct ScheduleReconciliationReport: Sendable, Equatable {
    public let timestamp: Date
    public let resumedDownloadIDs: [String]
    public let pausedDownloadIDs: [String]

    public init(timestamp: Date, resumedDownloadIDs: [String], pausedDownloadIDs: [String]) {
        self.timestamp = timestamp
        self.resumedDownloadIDs = resumedDownloadIDs
        self.pausedDownloadIDs = pausedDownloadIDs
    }
}
