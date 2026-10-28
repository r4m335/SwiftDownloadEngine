import Foundation

/// Represents a user-defined download schedule rule.
///
/// Due to iOS background architecture, exact alarm execution (like Android's AlarmManager) is not supported.
/// Schedule rules are enforced natively on iOS via:
/// 1. App lifecycle reconciliation on launch and foregrounding.
/// 2. Background URLSession `earliestBeginDate` properties on in-flight tasks.
/// 3. Native `UNCalendarNotificationTrigger` local reminders.
public struct ScheduleRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var isEnabled: Bool
    public var startTime: DateComponents
    public var stopTime: DateComponents?
    /// Set of weekdays (1 = Sunday, 2 = Monday, ..., 7 = Saturday matching Apple Calendar convention)
    public var weekdays: Set<Int>
    public var wifiOnly: Bool
    public var targetDownloadIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String = "Download Schedule",
        isEnabled: Bool = true,
        startTime: DateComponents = DateComponents(hour: 2, minute: 0),
        stopTime: DateComponents? = DateComponents(hour: 6, minute: 0),
        weekdays: Set<Int> = Set(1...7),
        wifiOnly: Bool = true,
        targetDownloadIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.startTime = startTime
        self.stopTime = stopTime
        self.weekdays = weekdays
        self.wifiOnly = wifiOnly
        self.targetDownloadIDs = targetDownloadIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func contains(downloadID: String) -> Bool {
        targetDownloadIDs.contains(downloadID)
    }

    public mutating func add(downloadID: String) {
        if !targetDownloadIDs.contains(downloadID) {
            targetDownloadIDs.append(downloadID)
            updatedAt = Date()
        }
    }

    public mutating func remove(downloadID: String) {
        if let idx = targetDownloadIDs.firstIndex(of: downloadID) {
            targetDownloadIDs.remove(at: idx)
            updatedAt = Date()
        }
    }

    public mutating func toggle(downloadID: String) {
        if contains(downloadID: downloadID) {
            remove(downloadID: downloadID)
        } else {
            add(downloadID: downloadID)
        }
    }

    /// Formats startTime as "HH:mm" for UI display.
    public var formattedStartTime: String {
        let hour = startTime.hour ?? 0
        let minute = startTime.minute ?? 0
        return String(format: "%02d:%02d", hour, minute)
    }

    /// Formats optional stopTime as "HH:mm" for UI display.
    public var formattedStopTime: String? {
        guard let stop = stopTime else { return nil }
        let hour = stop.hour ?? 0
        let minute = stop.minute ?? 0
        return String(format: "%02d:%02d", hour, minute)
    }

    /// Short weekday label (e.g., "Daily", "Weekdays", "Weekends", or "Mon, Wed, Fri").
    public var formattedWeekdays: String {
        if weekdays == Set(1...7) {
            return "Daily"
        }
        if weekdays == Set([2, 3, 4, 5, 6]) {
            return "Weekdays"
        }
        if weekdays == Set([1, 7]) {
            return "Weekends"
        }
        let symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let sorted = weekdays.sorted()
        let names = sorted.compactMap { day -> String? in
            guard day >= 1 && day <= 7 else { return nil }
            return symbols[day - 1]
        }
        return names.joined(separator: ", ")
    }

    /// Ordered weekday symbols for calendar/scheduler UI (Mon through Sun)
    public static let orderedWeekdaySymbols: [(day: Int, symbol: String)] = [
        (2, "Mon"),
        (3, "Tue"),
        (4, "Wed"),
        (5, "Thu"),
        (6, "Fri"),
        (7, "Sat"),
        (1, "Sun")
    ]
}
