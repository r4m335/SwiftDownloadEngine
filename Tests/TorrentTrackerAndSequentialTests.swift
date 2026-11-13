import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class TorrentTrackerAndSequentialTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TorrentTrackerSeqTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    // MARK: - 1. TorrentTrackerURLValidator Tests

    func testValidatorAcceptsValidSchemes() throws {
        let validURLs = [
            "http://tracker.example.com:8080/announce",
            "https://tracker.secure.org/announce",
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://9.rarbg.to:2710/announce",
            "ws://tracker.btorrent.xyz",
            "wss://tracker.openwebtorrent.com:443/announce"
        ]

        for urlString in validURLs {
            let validated = try TorrentTrackerURLValidator.validate(urlString)
            XCTAssertNotNil(validated.scheme)
            XCTAssertNotNil(validated.host)
        }
    }

    func testValidatorRejectsUDPWithoutPort() {
        let udpNoPort = "udp://tracker.opentrackr.org/announce"
        XCTAssertThrowsError(try TorrentTrackerURLValidator.validate(udpNoPort)) { error in
            guard case TorrentTrackerValidationError.missingUDPPort = error else {
                XCTFail("Expected missingUDPPort error but got: \(error)")
                return
            }
        }
    }

    func testValidatorRejectsUnsupportedSchemes() {
        let invalidSchemes = [
            "ftp://tracker.example.com/announce",
            "file:///etc/tracker",
            "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        ]

        for urlString in invalidSchemes {
            XCTAssertThrowsError(try TorrentTrackerURLValidator.validate(urlString)) { error in
                guard case TorrentTrackerValidationError.unsupportedScheme = error else {
                    XCTFail("Expected unsupportedScheme for \(urlString) but got: \(error)")
                    return
                }
            }
        }
    }

    func testValidatorRejectsInvalidHostsAndMalformedURLs() {
        let malformed = [
            "http://",
            "not a url",
            "udp://:1337/announce"
        ]

        for urlString in malformed {
            XCTAssertThrowsError(try TorrentTrackerURLValidator.validate(urlString))
        }
    }

    // MARK: - 2. TorrentModels & JSON Backward Compatibility

    func testTorrentRecordBackwardCompatibilityDecoding() throws {
        // Legacy JSON without isSequentialDownload or customTrackers
        let legacyJSON = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "infoHash": "0123456789abcdef0123456789abcdef01234567",
            "source": "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            "name": "TestTorrent",
            "savePath": "/tmp/downloads/TestTorrent",
            "priority": 1,
            "state": "downloading",
            "isExplicitlyPaused": false,
            "createdAt": 1698000000.0,
            "updatedAt": 1698000000.0
        }
        """

        let decoder = JSONDecoder()
        let record = try decoder.decode(TorrentRecord.self, from: Data(legacyJSON.utf8))

        XCTAssertFalse(record.isSequentialDownload)
        XCTAssertNil(record.customTrackers)
        XCTAssertEqual(record.name, "TestTorrent")
    }

    func testTorrentRecordEncodesAndDecodesSequentialAndTrackers() throws {
        let original = TorrentRecord(
            id: UUID(),
            infoHash: "0123456789abcdef0123456789abcdef01234567",
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            name: "SequentialTorrent",
            savePath: tempDirectory.appendingPathComponent("Seq"),
            state: .downloading,
            priority: .high,
            isExplicitlyPaused: false,
            isSequentialDownload: true,
            customTrackers: ["udp://tracker.opentrackr.org:1337/announce"]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TorrentRecord.self, from: data)

        XCTAssertTrue(decoded.isSequentialDownload)
        XCTAssertEqual(decoded.customTrackers, ["udp://tracker.opentrackr.org:1337/announce"])
        XCTAssertEqual(decoded.name, "SequentialTorrent")
    }

    // MARK: - 3. UnifiedTransfer Mapping Tests

    func testUnifiedTransferMapsSequentialFlag() {
        let task = TorrentTask(
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            name: "SampleTorrent",
            savePath: tempDirectory.appendingPathComponent("Sample"),
            state: .downloading,
            infoHash: "0123456789abcdef0123456789abcdef01234567",
            isSequentialDownload: true
        )

        let transfer = UnifiedTransfer(from: task)
        XCTAssertTrue(transfer.isSequentialDownload)
        XCTAssertTrue(transfer.isTorrent)
    }

    // MARK: - 4. TorrentEngine Sequential & Tracker Operations (Fallback)

    func testTorrentEngineSequentialDownloadMode() async throws {
        let engine = try TorrentEngine(storageDirectoryURL: tempDirectory, maxConcurrentTorrents: 2)
        try await engine.start()

        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=SequentialTest"
        let task = try await engine.addTorrent(magnetURI: magnet, isSequential: true)

        XCTAssertTrue(task.isSequentialDownload)
        let isSeq = await engine.isSequentialDownload(for: task.infoHash)
        XCTAssertTrue(isSeq)

        // Toggle to false
        try await engine.setSequentialDownload(false, for: task.infoHash)
        let updatedIsSeq = await engine.isSequentialDownload(for: task.infoHash)
        XCTAssertFalse(updatedIsSeq)

        // Toggle back to true
        try await engine.setSequentialDownload(true, for: task.infoHash)
        let toggledBack = await engine.isSequentialDownload(for: task.infoHash)
        XCTAssertTrue(toggledBack)

        await engine.stop()
    }

    func testTorrentEngineTrackerManagement() async throws {
        let engine = try TorrentEngine(storageDirectoryURL: tempDirectory, maxConcurrentTorrents: 2)
        try await engine.start()

        let magnet = "magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98&dn=TrackerTest"
        let task = try await engine.addTorrent(magnetURI: magnet)

        // Add custom tracker
        let customTracker = "udp://tracker.custom-swarms.org:6969/announce"
        try await engine.addTracker(url: customTracker, tier: 1, for: task.infoHash)

        var trackers = await engine.trackers(for: task.infoHash)
        XCTAssertTrue(trackers.contains(where: { $0.url == customTracker }))

        // Trigger reannounce
        try await engine.forceReannounce(for: task.infoHash)
        trackers = await engine.trackers(for: task.infoHash)
        if let tracker = trackers.first(where: { $0.url == customTracker }) {
            XCTAssertEqual(tracker.state, .updating)
        }

        // Remove tracker
        try await engine.removeTracker(url: customTracker, for: task.infoHash)
        trackers = await engine.trackers(for: task.infoHash)
        XCTAssertFalse(trackers.contains(where: { $0.url == customTracker }))

        await engine.stop()
    }

    // MARK: - 5. DownloadManagerViewModel Delegation Tests

    func testViewModelDelegatesSequentialAndTrackers() async throws {
        let engine = try TorrentEngine(storageDirectoryURL: tempDirectory, maxConcurrentTorrents: 2)
        try await engine.start()

        let downloadEngine = try DownloadEngine(storageDirectoryURL: tempDirectory, maxConcurrentDownloads: 2)
        let vm = await MainActor.run {
            DownloadManagerViewModel(
                engine: downloadEngine,
                torrentEngine: engine,
                downloadsDirectory: tempDirectory
            )
        }

        let magnet = "magnet:?xt=urn:btih:111122223333444455556666777788889999aaaa&dn=VMTest"
        let transfer = try await vm.addTorrent(magnetURI: magnet, isSequential: true)
        XCTAssertTrue(transfer.isSequentialDownload)

        guard let hash = transfer.infoHash else {
            XCTFail("Expected infoHash for torrent transfer")
            return
        }

        // Add tracker through VM
        let trackerURL = "wss://tracker.openwebtorrent.com:443/announce"
        try await vm.addTracker(url: trackerURL, tier: 0, for: hash)

        let fetchedTrackers = await vm.fetchTrackers(for: hash)
        XCTAssertTrue(fetchedTrackers.contains(where: { $0.url == trackerURL }))

        // Force reannounce through VM
        try await vm.forceReannounce(for: hash)

        // Toggle sequential mode through VM
        try await vm.setSequentialDownload(false, for: hash)
        let isSeq = await engine.isSequentialDownload(for: hash)
        XCTAssertFalse(isSeq)

        // Remove tracker through VM
        try await vm.removeTracker(url: trackerURL, for: hash)
        let afterRemoveTrackers = await vm.fetchTrackers(for: hash)
        XCTAssertFalse(afterRemoveTrackers.contains(where: { $0.url == trackerURL }))

        await engine.stop()
    }
}

