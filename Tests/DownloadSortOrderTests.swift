import XCTest
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@testable import DM_Reverse_engineering

final class DownloadSortOrderTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeTransfer(
        id: String,
        name: String,
        type: TransferType = .http,
        state: UnifiedTransferState = .downloading,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        progressFraction: Double = 0.0,
        createdAt: Date = Date(),
        source: String = "https://example.com/test"
    ) -> UnifiedTransfer {
        UnifiedTransfer(
            id: id,
            name: name,
            type: type,
            state: state,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            progressFraction: progressFraction,
            downloadSpeedBytesPerSecond: 0,
            uploadSpeedBytesPerSecond: 0,
            destinationURL: URL(fileURLWithPath: "/tmp/\(name)"),
            source: source,
            createdAt: createdAt
        )
    }

    // MARK: - Enum & Display Name Tests

    func testDownloadSortOrder_EnumProperties() {
        XCTAssertEqual(DownloadSortOrder.allCases.count, 5)

        XCTAssertEqual(DownloadSortOrder.dateAddedDesc.rawValue, "dateAddedDesc")
        XCTAssertEqual(DownloadSortOrder.dateAddedDesc.id, "dateAddedDesc")
        XCTAssertEqual(DownloadSortOrder.dateAddedDesc.displayName, "Date Added — Newest First")

        XCTAssertEqual(DownloadSortOrder.dateAddedAsc.rawValue, "dateAddedAsc")
        XCTAssertEqual(DownloadSortOrder.dateAddedAsc.id, "dateAddedAsc")
        XCTAssertEqual(DownloadSortOrder.dateAddedAsc.displayName, "Date Added — Oldest First")

        XCTAssertEqual(DownloadSortOrder.nameAsc.rawValue, "nameAsc")
        XCTAssertEqual(DownloadSortOrder.nameAsc.id, "nameAsc")
        XCTAssertEqual(DownloadSortOrder.nameAsc.displayName, "Name — A to Z")

        XCTAssertEqual(DownloadSortOrder.sizeDesc.rawValue, "sizeDesc")
        XCTAssertEqual(DownloadSortOrder.sizeDesc.id, "sizeDesc")
        XCTAssertEqual(DownloadSortOrder.sizeDesc.displayName, "Size — Largest First")

        XCTAssertEqual(DownloadSortOrder.progressDesc.rawValue, "progressDesc")
        XCTAssertEqual(DownloadSortOrder.progressDesc.id, "progressDesc")
        XCTAssertEqual(DownloadSortOrder.progressDesc.displayName, "Progress — Highest First")
    }

    func testDownloadSortOrder_CodableRoundTrip() throws {
        for order in DownloadSortOrder.allCases {
            let data = try JSONEncoder().encode(order)
            let decoded = try JSONDecoder().decode(DownloadSortOrder.self, from: data)
            XCTAssertEqual(decoded, order)
        }
    }

    // MARK: - Sorting Tests

    func testSortTransfers_DateAddedDesc() {
        let now = Date()
        let t1 = makeTransfer(id: "1", name: "FileA", createdAt: now.addingTimeInterval(-100))
        let t2 = makeTransfer(id: "2", name: "FileB", createdAt: now.addingTimeInterval(-10))
        let t3 = makeTransfer(id: "3", name: "FileC", createdAt: now.addingTimeInterval(-50))

        let sorted = DownloadManagerViewModel.sortTransfers([t1, t2, t3], by: .dateAddedDesc)
        XCTAssertEqual(sorted.map(\.id), ["2", "3", "1"])
    }

    func testSortTransfers_DateAddedAsc() {
        let now = Date()
        let t1 = makeTransfer(id: "1", name: "FileA", createdAt: now.addingTimeInterval(-100))
        let t2 = makeTransfer(id: "2", name: "FileB", createdAt: now.addingTimeInterval(-10))
        let t3 = makeTransfer(id: "3", name: "FileC", createdAt: now.addingTimeInterval(-50))

        let sorted = DownloadManagerViewModel.sortTransfers([t1, t2, t3], by: .dateAddedAsc)
        XCTAssertEqual(sorted.map(\.id), ["1", "3", "2"])
    }

    func testSortTransfers_NameAsc_CaseInsensitive() {
        let t1 = makeTransfer(id: "1", name: "zebra.zip")
        let t2 = makeTransfer(id: "2", name: "Apple.dmg")
        let t3 = makeTransfer(id: "3", name: "banana.mp4")
        let t4 = makeTransfer(id: "4", name: "apple.iso")

        let sorted = DownloadManagerViewModel.sortTransfers([t1, t2, t3, t4], by: .nameAsc)
        let names = sorted.map(\.name)
        // Case-insensitive comparison places Apple.dmg and apple.iso before banana and zebra
        XCTAssertTrue(names[0].lowercased().hasPrefix("apple"))
        XCTAssertTrue(names[1].lowercased().hasPrefix("apple"))
        XCTAssertEqual(names[2], "banana.mp4")
        XCTAssertEqual(names[3], "zebra.zip")
    }

    func testSortTransfers_SizeDesc_KnownAndUnknownSizes() {
        let now = Date()
        let tSmall = makeTransfer(id: "small", name: "small.txt", totalBytes: 1_000, createdAt: now.addingTimeInterval(-30))
        let tLarge = makeTransfer(id: "large", name: "large.iso", totalBytes: 10_000_000, createdAt: now.addingTimeInterval(-20))
        let tMedium = makeTransfer(id: "medium", name: "med.mp4", totalBytes: 500_000, createdAt: now.addingTimeInterval(-10))
        let tUnknown = makeTransfer(id: "unknown", name: "stream.m3u8", totalBytes: nil, createdAt: now)
        let tZero = makeTransfer(id: "zero", name: "empty.bin", totalBytes: 0, createdAt: now.addingTimeInterval(-5))

        let sorted = DownloadManagerViewModel.sortTransfers([tSmall, tUnknown, tLarge, tZero, tMedium], by: .sizeDesc)
        // Largest (10M) -> Medium (500K) -> Small (1K) -> Zero (0) -> Unknown (-1)
        XCTAssertEqual(sorted.map(\.id), ["large", "medium", "small", "zero", "unknown"])
    }

    func testSortTransfers_ProgressDesc() {
        let now = Date()
        let t0 = makeTransfer(id: "0", name: "zero", progressFraction: 0.0, createdAt: now.addingTimeInterval(-10))
        let t25 = makeTransfer(id: "25", name: "quarter", progressFraction: 0.25, createdAt: now.addingTimeInterval(-20))
        let t100 = makeTransfer(id: "100", name: "done", progressFraction: 1.0, createdAt: now.addingTimeInterval(-30))
        let t75 = makeTransfer(id: "75", name: "three_quarter", progressFraction: 0.75, createdAt: now.addingTimeInterval(-40))
        let tNaN = makeTransfer(id: "nan", name: "invalid", progressFraction: Double.nan, createdAt: now.addingTimeInterval(-50))

        let sorted = DownloadManagerViewModel.sortTransfers([t0, t25, t100, t75, tNaN], by: .progressDesc)
        // 1.0 (100) -> 0.75 (75) -> 0.25 (25) -> 0.0 (0) -> NaN treated as 0.0 (tie-broken by createdAt)
        XCTAssertEqual(sorted[0].id, "100")
        XCTAssertEqual(sorted[1].id, "75")
        XCTAssertEqual(sorted[2].id, "25")
    }

    func testSortTransfers_DeterministicTieBreaking() {
        let date = Date(timeIntervalSince1970: 1700000000)
        // Two transfers with identical names and identical creation dates, different IDs
        let tA = makeTransfer(id: "item_a", name: "SameName", createdAt: date)
        let tB = makeTransfer(id: "item_b", name: "SameName", createdAt: date)

        let sorted1 = DownloadManagerViewModel.sortTransfers([tB, tA], by: .nameAsc)
        let sorted2 = DownloadManagerViewModel.sortTransfers([tA, tB], by: .nameAsc)

        // Strict weak ordering with ID tie-break guarantees identical order regardless of input order
        XCTAssertEqual(sorted1.map(\.id), ["item_a", "item_b"])
        XCTAssertEqual(sorted2.map(\.id), ["item_a", "item_b"])
    }

    // MARK: - ViewModel Live Sorting & Dynamic Updates

    @MainActor
    func testViewModel_UpdateSortOrder_PersistsAndRebuilds() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SortTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("Store", isDirectory: true)
        let store = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        let coord = try DownloadCoordinator(session: .shared, persistenceStore: store)
        let qm = DownloadQueueManager(coordinator: coord, persistenceStore: store, maxConcurrentDownloads: 3)
        let engine = DownloadEngine(queueManager: qm, coordinator: coord, persistenceStore: store)
        let defaults = UserDefaults(suiteName: "test_sort_\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let vm = DownloadManagerViewModel(
            engine: engine,
            downloadsDirectory: tempDir,
            userDefaults: defaults
        )

        // Initial default should be dateAddedDesc
        XCTAssertEqual(vm.selectedSortOrder, .dateAddedDesc)

        // Update sort order to nameAsc
        vm.updateSortOrder(.nameAsc)

        XCTAssertEqual(vm.selectedSortOrder, .nameAsc)
        let savedSettings = AppSettings.load(from: defaults)
        XCTAssertEqual(savedSettings.downloadSortOrder, .nameAsc)
    }

    @MainActor
    func testViewModel_DynamicReSortOnProgressUpdate() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SortProgressTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeURL = tempDir.appendingPathComponent("Store", isDirectory: true)
        let store = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        let coord = try DownloadCoordinator(session: .shared, persistenceStore: store)
        let qm = DownloadQueueManager(coordinator: coord, persistenceStore: store, maxConcurrentDownloads: 3)
        let engine = DownloadEngine(queueManager: qm, coordinator: coord, persistenceStore: store)
        let defaults = UserDefaults(suiteName: "test_sort_progress_\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let vm = DownloadManagerViewModel(
            engine: engine,
            downloadsDirectory: tempDir,
            userDefaults: defaults
        )

        // Set sort order to progressDesc
        vm.updateSortOrder(.progressDesc)

        let snap1 = DownloadSnapshot(
            id: "snap1",
            url: URL(string: "https://example.com/file1.zip")!,
            destinationURL: tempDir.appendingPathComponent("file1.zip"),
            state: .downloading,
            completedBytes: 100,
            totalBytes: 1000,
            progressFraction: 0.1,
            enqueuedAt: Date(timeIntervalSince1970: 1000)
        )
        let snap2 = DownloadSnapshot(
            id: "snap2",
            url: URL(string: "https://example.com/file2.zip")!,
            destinationURL: tempDir.appendingPathComponent("file2.zip"),
            state: .downloading,
            completedBytes: 800,
            totalBytes: 1000,
            progressFraction: 0.8,
            enqueuedAt: Date(timeIntervalSince1970: 2000)
        )

        vm.upsertSnapshotForTesting(snap1)
        vm.upsertSnapshotForTesting(snap2)

        var transfers = vm.unifiedTransfers
        // snap2 (80%) should come before snap1 (10%)
        XCTAssertEqual(transfers.map(\.id), ["snap2", "snap1"])

        // Now update snap1 progress to 95%
        let snap1Updated = DownloadSnapshot(
            id: "snap1",
            url: URL(string: "https://example.com/file1.zip")!,
            destinationURL: tempDir.appendingPathComponent("file1.zip"),
            state: .downloading,
            completedBytes: 950,
            totalBytes: 1000,
            progressFraction: 0.95,
            enqueuedAt: Date(timeIntervalSince1970: 1000)
        )
        vm.upsertSnapshotForTesting(snap1Updated)

        transfers = vm.unifiedTransfers
        // snap1 (95%) should now be first, ahead of snap2 (80%)
        XCTAssertEqual(transfers.map(\.id), ["snap1", "snap2"])
    }
}

