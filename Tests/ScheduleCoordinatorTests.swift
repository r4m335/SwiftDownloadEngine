import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class ScheduleCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var persistenceStore: DownloadPersistenceStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScheduleCoordinatorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Task 1: Data Model Tests

    func testScheduleRuleCodableSerialization() throws {
        let original = ScheduleRule(
            id: "sched-test-1",
            name: "Night Owls",
            isEnabled: true,
            startTime: DateComponents(hour: 2, minute: 30),
            stopTime: DateComponents(hour: 6, minute: 45),
            weekdays: [2, 3, 4, 5, 6],
            wifiOnly: true,
            targetDownloadIDs: ["dl-1", "dl-2"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduleRule.self, from: data)

        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.name, decoded.name)
        XCTAssertEqual(original.isEnabled, decoded.isEnabled)
        XCTAssertEqual(original.startTime.hour, decoded.startTime.hour)
        XCTAssertEqual(original.startTime.minute, decoded.startTime.minute)
        XCTAssertEqual(original.stopTime?.hour, decoded.stopTime?.hour)
        XCTAssertEqual(original.stopTime?.minute, decoded.stopTime?.minute)
        XCTAssertEqual(original.weekdays, decoded.weekdays)
        XCTAssertEqual(original.wifiOnly, decoded.wifiOnly)
        XCTAssertEqual(original.targetDownloadIDs, decoded.targetDownloadIDs)
    }

    func testScheduleRuleMutationHelpers() {
        var rule = ScheduleRule(id: "r1")
        XCTAssertFalse(rule.contains(downloadID: "itemA"))

        rule.add(downloadID: "itemA")
        XCTAssertTrue(rule.contains(downloadID: "itemA"))
        XCTAssertEqual(rule.targetDownloadIDs, ["itemA"])

        // Adding duplicate is no-op
        rule.add(downloadID: "itemA")
        XCTAssertEqual(rule.targetDownloadIDs.count, 1)

        rule.toggle(downloadID: "itemB")
        XCTAssertTrue(rule.contains(downloadID: "itemB"))

        rule.toggle(downloadID: "itemA")
        XCTAssertFalse(rule.contains(downloadID: "itemA"))

        rule.remove(downloadID: "itemB")
        XCTAssertFalse(rule.contains(downloadID: "itemB"))
        XCTAssertTrue(rule.targetDownloadIDs.isEmpty)
    }

    func testScheduleRuleFormatting() {
        let rule = ScheduleRule(
            startTime: DateComponents(hour: 3, minute: 5),
            stopTime: DateComponents(hour: 17, minute: 45),
            weekdays: [2, 3, 4, 5, 6]
        )

        XCTAssertEqual(rule.formattedStartTime, "03:05")
        XCTAssertEqual(rule.formattedStopTime, "17:45")
        XCTAssertEqual(rule.formattedWeekdays, "Weekdays")

        let dailyRule = ScheduleRule(weekdays: Set(1...7))
        XCTAssertEqual(dailyRule.formattedWeekdays, "Daily")

        let weekendRule = ScheduleRule(weekdays: [1, 7])
        XCTAssertEqual(weekendRule.formattedWeekdays, "Weekends")

        let customRule = ScheduleRule(weekdays: [2, 4, 6])
        XCTAssertEqual(customRule.formattedWeekdays, "Mon, Wed, Fri")
    }

    // MARK: - Task 1: Persistence Store Tests

    func testPersistenceStoreScheduleRuleCRUD() async throws {
        let rule1 = ScheduleRule(id: "rule-1", name: "Morning", targetDownloadIDs: ["d1"])
        let rule2 = ScheduleRule(id: "rule-2", name: "Evening", targetDownloadIDs: ["d2", "d3"])

        try await persistenceStore.saveScheduleRule(rule1)
        try await persistenceStore.saveScheduleRule(rule2)

        let fetched1 = try await persistenceStore.fetchScheduleRule(id: "rule-1")
        XCTAssertNotNil(fetched1)
        XCTAssertEqual(fetched1?.name, "Morning")
        XCTAssertEqual(fetched1?.targetDownloadIDs, ["d1"])

        let all = try await persistenceStore.fetchAllScheduleRules()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains(where: { $0.id == "rule-1" }))
        XCTAssertTrue(all.contains(where: { $0.id == "rule-2" }))

        try await persistenceStore.deleteScheduleRule(id: "rule-1")
        let fetchedDeleted = try await persistenceStore.fetchScheduleRule(id: "rule-1")
        XCTAssertNil(fetchedDeleted)
        let allAfter = try await persistenceStore.fetchAllScheduleRules()
        XCTAssertEqual(allAfter.count, 1)
    }

    // MARK: - Task 2: Schedule Window Calculation Tests

    @MainActor
    func testScheduleWindowSameDay() {
        let coordinator = ScheduleCoordinator(persistenceStore: persistenceStore)

        // Mon-Fri: 02:00 to 06:00
        let rule = ScheduleRule(
            isEnabled: true,
            startTime: DateComponents(hour: 2, minute: 0),
            stopTime: DateComponents(hour: 6, minute: 0),
            weekdays: [2, 3, 4, 5, 6] // Mon=2 ... Fri=6
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // Create a Monday date at 01:59:00
        var comps = DateComponents(year: 2026, month: 10, day: 26, hour: 1, minute: 59, second: 0) // Oct 26, 2026 is Monday
        var testDate = calendar.date(from: comps)!
        XCTAssertFalse(coordinator.isDateInScheduleWindow(testDate, rule: rule, calendar: calendar))

        // Monday at 02:00:00 (exact start)
        comps.minute = 0
        comps.hour = 2
        testDate = calendar.date(from: comps)!
        XCTAssertTrue(coordinator.isDateInScheduleWindow(testDate, rule: rule, calendar: calendar))

        // Monday at 04:30:00 (middle)
        comps.hour = 4
        comps.minute = 30
        testDate = calendar.date(from: comps)!
        XCTAssertTrue(coordinator.isDateInScheduleWindow(testDate, rule: rule, calendar: calendar))

        // Monday at 05:59:59 (just before stop)
        comps.hour = 5
        comps.minute = 59
        testDate = calendar.date(from: comps)!
        XCTAssertTrue(coordinator.isDateInScheduleWindow(testDate, rule: rule, calendar: calendar))

        // Monday at 06:00:00 (exact stop -> outside)
        comps.hour = 6
        comps.minute = 0
        testDate = calendar.date(from: comps)!
        XCTAssertFalse(coordinator.isDateInScheduleWindow(testDate, rule: rule, calendar: calendar))

        // Sunday at 03:00:00 (Sunday = 1, not in rule weekdays)
        comps = DateComponents(year: 2026, month: 10, day: 25, hour: 3, minute: 0, second: 0) // Oct 25, 2026 is Sunday
        testDate = calendar.date(from: comps)!
        XCTAssertFalse(coordinator.isDateInScheduleWindow(testDate, rule: rule, calendar: calendar))
    }

    @MainActor
    func testScheduleWindowOvernight() {
        let coordinator = ScheduleCoordinator(persistenceStore: persistenceStore)

        // Mon-Fri: 23:00 to 06:00 (crosses midnight)
        let rule = ScheduleRule(
            isEnabled: true,
            startTime: DateComponents(hour: 23, minute: 0),
            stopTime: DateComponents(hour: 6, minute: 0),
            weekdays: [2, 3, 4, 5, 6] // Mon=2 ... Fri=6
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // Monday Oct 26 at 23:30 (Monday night) -> In window
        var comps = DateComponents(year: 2026, month: 10, day: 26, hour: 23, minute: 30, second: 0)
        var testDate = calendar.date(from: comps)!
        XCTAssertTrue(coordinator.isDateInScheduleWindow(testDate, rule: rule, calendar: calendar))

        // Tuesday Oct 27 at 03:00 (Started Monday night) -> In window because Monday was active
        comps = DateComponents(year: 2026, month: 10, day: 27, hour: 3, minute: 0, second: 0)
        testDate = calendar.date(from: comps)!
        XCTAssertTrue(coordinator.isDateInScheduleWindow(testDate, rule: rule, calendar: calendar))

        // Tuesday Oct 27 at 06:01 -> Outside window
        comps = DateComponents(year: 2026, month: 10, day: 27, hour: 6, minute: 1, second: 0)
        testDate = calendar.date(from: comps)!
        XCTAssertFalse(coordinator.isDateInScheduleWindow(testDate, rule: rule, calendar: calendar))

        // Monday Oct 26 at 03:00 -> Previous day was Sunday (1), not in rule weekdays -> Outside window
        comps = DateComponents(year: 2026, month: 10, day: 26, hour: 3, minute: 0, second: 0)
        testDate = calendar.date(from: comps)!
        XCTAssertFalse(coordinator.isDateInScheduleWindow(testDate, rule: rule, calendar: calendar))
    }

    @MainActor
    func testScheduleWindowStopBeforeStartUsesPreviousWeekday() {
        let coordinator = ScheduleCoordinator(persistenceStore: persistenceStore)
        let rule = ScheduleRule(
            isEnabled: true,
            startTime: DateComponents(hour: 22, minute: 0),
            stopTime: DateComponents(hour: 6, minute: 0),
            weekdays: [2] // Monday starts; Tuesday morning is the continuation.
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let mondayLate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 23, minute: 0))!
        let tuesdayMorning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 5, minute: 0))!
        let tuesdayLate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 23, minute: 0))!

        XCTAssertTrue(coordinator.isDateInScheduleWindow(mondayLate, rule: rule, calendar: calendar))
        XCTAssertTrue(coordinator.isDateInScheduleWindow(tuesdayMorning, rule: rule, calendar: calendar))
        XCTAssertFalse(coordinator.isDateInScheduleWindow(tuesdayLate, rule: rule, calendar: calendar))
    }

    @MainActor
    func testScheduleWindowDisabledRuleReturnsFalse() {
        let coordinator = ScheduleCoordinator(persistenceStore: persistenceStore)
        let rule = ScheduleRule(isEnabled: false, weekdays: Set(1...7))
        XCTAssertFalse(coordinator.isDateInScheduleWindow(Date(), rule: rule))
    }

    // MARK: - Task 2: Next Occurrence Calculation

    @MainActor
    func testNextOccurrenceCalculation() {
        let coordinator = ScheduleCoordinator(persistenceStore: persistenceStore)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // Base date: Monday Oct 26, 2026 at 10:00:00
        let baseDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 10, minute: 0, second: 0))!

        // Target: 14:00 today (Monday Oct 26)
        let targetComp = DateComponents(hour: 14, minute: 0)
        let nextDate = coordinator.nextOccurrence(after: baseDate, matching: targetComp, weekdays: [2], calendar: calendar)

        XCTAssertNotNil(nextDate)
        if let next = nextDate {
            let nextHour = calendar.component(.hour, from: next)
            let nextDay = calendar.component(.day, from: next)
            let nextWeekday = calendar.component(.weekday, from: next)
            XCTAssertEqual(nextHour, 14)
            XCTAssertEqual(nextDay, 26)
            XCTAssertEqual(nextWeekday, 2)
        }

        // Target: 08:00 (earlier than 10:00, with weekdays [2] only -> next Monday Nov 2)
        let earlierComp = DateComponents(hour: 8, minute: 0)
        let nextWeekDate = coordinator.nextOccurrence(after: baseDate, matching: earlierComp, weekdays: [2], calendar: calendar)
        XCTAssertNotNil(nextWeekDate)
        if let nextWeek = nextWeekDate {
            let nextDay = calendar.component(.day, from: nextWeek)
            XCTAssertEqual(nextDay, 2) // Nov 2, 2026
        }
    }

    // MARK: - Task 3: Reconciliation Tests

    @MainActor
    func testScheduleReconciliationTriggersResumeAndPause() async throws {
        var resumedIDs = [String]()
        var pausedIDs = [String]()

        let coordinator = ScheduleCoordinator(
            persistenceStore: persistenceStore,
            resumeHandler: { id in resumedIDs.append(id) },
            pauseHandler: { id in pausedIDs.append(id) }
        )

        // Create rule: 02:00 to 06:00 daily with target "dl-100"
        let rule = ScheduleRule(
            id: "sched-reconcile",
            isEnabled: true,
            startTime: DateComponents(hour: 2, minute: 0),
            stopTime: DateComponents(hour: 6, minute: 0),
            weekdays: Set(1...7),
            targetDownloadIDs: ["dl-100"]
        )
        try await persistenceStore.saveScheduleRule(rule)
        await coordinator.loadRules()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // Case 1: Time is 03:00 (inside window) -> dl-100 should be resumed
        let insideDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 3, minute: 0))!
        await coordinator.reconcile(now: insideDate)
        XCTAssertEqual(resumedIDs, ["dl-100"])
        XCTAssertTrue(pausedIDs.isEmpty)

        resumedIDs.removeAll()
        pausedIDs.removeAll()

        // Case 2: Time is 07:00 (outside window) -> dl-100 should be paused
        let outsideDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 7, minute: 0))!
        await coordinator.reconcile(now: outsideDate)
        XCTAssertTrue(resumedIDs.isEmpty)
        XCTAssertEqual(pausedIDs, ["dl-100"])
    }

    @MainActor
    func testScheduleTaggingHelpers() async throws {
        let coordinator = ScheduleCoordinator(persistenceStore: persistenceStore)
        await coordinator.loadRules()

        // The app's default rule is intentionally disabled. Enable it here so
        // this test exercises the tagging helper's enabled-rule semantics.
        var defaultRule = try XCTUnwrap(coordinator.rules.first)
        defaultRule.isEnabled = true
        try await coordinator.saveRule(defaultRule)

        XCTAssertFalse(coordinator.isScheduled(downloadID: "task-abc"))

        await coordinator.toggleScheduled(downloadID: "task-abc")
        XCTAssertTrue(coordinator.isScheduled(downloadID: "task-abc"))

        await coordinator.toggleScheduled(downloadID: "task-abc")
        XCTAssertFalse(coordinator.isScheduled(downloadID: "task-abc"))
    }
}
