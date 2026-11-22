import XCTest
import Foundation
@testable import DownloadEngineKit

final class LIDSubtitleDiscoveryTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LIDSubTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - 1. Filename Metadata Parser Tests

    func testFilenameMetadataParserTVShow() {
        let input = "Breaking.Bad.S02E05.1080p.WEB-DL.DDP5.1.Atmos.H.264-FLUX.mkv"
        let parsed = LIDFilenameMetadataParser.parse(input)

        XCTAssertEqual(parsed.title, "Breaking Bad")
        XCTAssertEqual(parsed.season, 2)
        XCTAssertEqual(parsed.episode, 5)
        XCTAssertEqual(parsed.resolution, "1080p")
        XCTAssertEqual(parsed.sourceRip, "WEB-DL")
        XCTAssertEqual(parsed.releaseGroup, "FLUX")
        XCTAssertEqual(parsed.fullSearchString, "Breaking Bad S02E05")
    }

    func testFilenameMetadataParserMovieWithYear() {
        let input = "The.Matrix.1999.2160p.UHD.BluRay.x265-TERMINAL.mp4"
        let parsed = LIDFilenameMetadataParser.parse(input)

        XCTAssertEqual(parsed.title, "The Matrix")
        XCTAssertEqual(parsed.year, 1999)
        XCTAssertNil(parsed.season)
        XCTAssertNil(parsed.episode)
        XCTAssertEqual(parsed.resolution, "2160p")
        XCTAssertEqual(parsed.sourceRip, "BLURAY")
        XCTAssertEqual(parsed.releaseGroup, "TERMINAL")
        XCTAssertEqual(parsed.fullSearchString, "The Matrix 1999")
    }

    func testFilenameMetadataParserAlternateEpisodeFormat() {
        let input = "Game.of.Thrones.1x01.Winter.Is.Coming.720p.HDTV.x264.mkv"
        let parsed = LIDFilenameMetadataParser.parse(input)

        XCTAssertEqual(parsed.title, "Game of Thrones")
        XCTAssertEqual(parsed.season, 1)
        XCTAssertEqual(parsed.episode, 1)
        XCTAssertEqual(parsed.resolution, "720p")
        XCTAssertEqual(parsed.sourceRip, "HDTV")
    }

    func testFilenameMetadataParserSimpleFilename() {
        let input = "sample_video.ts"
        let parsed = LIDFilenameMetadataParser.parse(input)

        XCTAssertEqual(parsed.title, "sample video")
        XCTAssertNil(parsed.season)
        XCTAssertNil(parsed.episode)
        XCTAssertNil(parsed.year)
    }

    // MARK: - 2. Subtitle Models & Language Catalog

    func testLanguageCatalogMappings() {
        XCTAssertEqual(SubtitleLanguageCatalog.displayName(for: "en"), "English")
        XCTAssertEqual(SubtitleLanguageCatalog.displayName(for: "eng"), "English")
        XCTAssertEqual(SubtitleLanguageCatalog.displayName(for: "es"), "Spanish")
        XCTAssertEqual(SubtitleLanguageCatalog.displayName(for: "spa"), "Spanish")
        XCTAssertEqual(SubtitleLanguageCatalog.displayName(for: "fre"), "French")
        XCTAssertEqual(SubtitleLanguageCatalog.displayName(for: "fra"), "French")
        XCTAssertEqual(SubtitleLanguageCatalog.displayName(for: "ger"), "German")
        XCTAssertEqual(SubtitleLanguageCatalog.displayName(for: "ara"), "Arabic")
        XCTAssertEqual(SubtitleLanguageCatalog.displayName(for: "hin"), "Hindi")

        XCTAssertEqual(SubtitleLanguageCatalog.to2LetterCode("eng"), "en")
        XCTAssertEqual(SubtitleLanguageCatalog.to2LetterCode("spa"), "es")
        XCTAssertEqual(SubtitleLanguageCatalog.to2LetterCode("ger"), "de")
        XCTAssertEqual(SubtitleLanguageCatalog.to2LetterCode("en"), "en")
    }

    func testMatchQualityPriorities() {
        XCTAssertGreaterThan(SubtitleMatchQuality.exactHash.badgePriority, SubtitleMatchQuality.exactRelease.badgePriority)
        XCTAssertGreaterThan(SubtitleMatchQuality.exactRelease.badgePriority, SubtitleMatchQuality.exactEpisode.badgePriority)
        XCTAssertGreaterThan(SubtitleMatchQuality.exactEpisode.badgePriority, SubtitleMatchQuality.titleAndYear.badgePriority)
        XCTAssertGreaterThan(SubtitleMatchQuality.titleAndYear.badgePriority, SubtitleMatchQuality.keywordMatch.badgePriority)
    }

    // MARK: - 3. Multi-Provider Aggregation & Fail-Soft Resilience

    func testSearchManagerAggregationAndFailSoft() async {
        // Mock Provider 1: Returns successful results
        let provider1 = MockSubtitleProvider(
            name: "Mock Provider 1",
            results: [
                SubtitleSearchResult(
                    id: "mock1_1",
                    providerName: "Mock Provider 1",
                    title: "Breaking Bad",
                    releaseName: "Breaking.Bad.S02E05.1080p.WEB-DL-FLUX",
                    languageCode: "en",
                    languageDisplayName: "English",
                    format: "srt",
                    downloadURL: URL(string: "https://example.com/sub1.srt")!,
                    matchQuality: .exactRelease,
                    score: 90
                ),
                SubtitleSearchResult(
                    id: "mock1_2",
                    providerName: "Mock Provider 1",
                    title: "Breaking Bad",
                    releaseName: "Breaking.Bad.S02E05.HDTV-Generic",
                    languageCode: "es",
                    languageDisplayName: "Spanish",
                    format: "srt",
                    downloadURL: URL(string: "https://example.com/sub2.srt")!,
                    matchQuality: .exactEpisode,
                    score: 75
                )
            ]
        )

        // Mock Provider 2: Throws network failure
        let provider2 = MockFailingSubtitleProvider(name: "Mock Failing Provider")

        let manager = LIDSubtitleSearchManager(providers: [provider1, provider2])
        let query = SubtitleSearchQuery(
            query: "Breaking Bad",
            season: 2,
            episode: 5,
            releaseGroup: "FLUX",
            language: "all"
        )

        // Search must succeed despite provider2 failing
        let results = await manager.search(query: query, bypassCache: true)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.releaseName, "Breaking.Bad.S02E05.1080p.WEB-DL-FLUX")
        XCTAssertEqual(results.first?.matchQuality, .exactRelease)
    }

    func testSearchManagerDeduplication() async {
        // Two providers returning duplicate release in same language
        let subA = SubtitleSearchResult(
            id: "provA_1",
            providerName: "Provider A",
            title: "The Matrix",
            releaseName: "The.Matrix.1999.1080p.BluRay",
            languageCode: "en",
            languageDisplayName: "English",
            format: "srt",
            downloadURL: URL(string: "https://example.com/a.srt")!,
            matchQuality: .titleAndYear,
            score: 60
        )
        let subB = SubtitleSearchResult(
            id: "provB_1",
            providerName: "Provider B",
            title: "The Matrix",
            releaseName: "The.Matrix.1999.1080p.BluRay",
            languageCode: "en",
            languageDisplayName: "English",
            format: "srt",
            downloadURL: URL(string: "https://example.com/b.srt")!,
            matchQuality: .titleAndYear,
            score: 60
        )

        let pA = MockSubtitleProvider(name: "Provider A", results: [subA])
        let pB = MockSubtitleProvider(name: "Provider B", results: [subB])

        let manager = LIDSubtitleSearchManager(providers: [pA, pB])
        let query = SubtitleSearchQuery(query: "The Matrix", year: 1999)

        let results = await manager.search(query: query, bypassCache: true)
        // Must be deduplicated to exactly 1 result
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - 4. Subtitle Store Validation & Encoding Transcoding

    func testSubtitleStoreValidUTF8SaveAndValidation() async throws {
        let store = LIDSubtitleStore(storageDirectory: tempDirectory)

        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello, this is a valid subtitle test.

        2
        00:00:05,000 --> 00:00:08,000
        Second subtitle line.
        """
        let data = Data(srtContent.utf8)

        let savedURL = try await store.saveSubtitle(
            data: data,
            mediaTitle: "Breaking Bad S02E05",
            languageCode: "en",
            releaseName: "FLUX"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        let savedContent = try String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertTrue(savedContent.contains("Hello, this is a valid subtitle test."))

        // Verify listing
        let list = await store.listDownloadedSubtitles(for: "Breaking Bad S02E05")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.externalURL?.standardizedFileURL.path, savedURL.standardizedFileURL.path)
        XCTAssertEqual(list.first?.externalURL?.lastPathComponent, savedURL.lastPathComponent)

        // Verify deletion
        try await store.deleteSubtitle(at: savedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
    }

    func testSubtitleStoreEncodingFallbackLatin1() async throws {
        let store = LIDSubtitleStore(storageDirectory: tempDirectory)

        // Subtitle with non-ASCII accented characters encoded as ISO-Latin-1
        let textWithAccents = """
        1
        00:00:01,000 --> 00:00:03,000
        ¡Hola Señor! Café y crème brûlée.
        """
        guard let latin1Data = textWithAccents.data(using: .isoLatin1) else {
            XCTFail("Failed to encode as Latin-1")
            return
        }

        let savedURL = try await store.saveSubtitle(
            data: latin1Data,
            mediaTitle: "Spanish Film",
            languageCode: "es",
            releaseName: "CustomRip"
        )

        // Store must transcode it to valid UTF-8
        let utf8Content = try String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertTrue(utf8Content.contains("¡Hola Señor!"))
        XCTAssertTrue(utf8Content.contains("Café y crème brûlée."))
    }

    func testSubtitleStoreRejectsCorruptedOrEmptyInput() async {
        let store = LIDSubtitleStore(storageDirectory: tempDirectory)

        // 1. Empty data
        do {
            _ = try await store.saveSubtitle(data: Data(), mediaTitle: "Test", languageCode: "en", releaseName: "Rel")
            XCTFail("Expected store to throw on empty data")
        } catch {
            XCTAssertTrue(true)
        }

        // 2. Binary garbage without timestamps
        let garbage = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x12])
        do {
            _ = try await store.saveSubtitle(data: garbage, mediaTitle: "Test", languageCode: "en", releaseName: "Rel")
            XCTFail("Expected store to throw on garbage data")
        } catch {
            XCTAssertTrue(true)
        }
    }

    // MARK: - 5. LIDPlaybackEngine Integration & Cue Synchronization

    func testPlaybackEngineDownloadAndApplyIntegration() async throws {
        let srtData = Data("""
        1
        00:00:01,000 --> 00:00:05,000
        Testing live subtitle cue synchronization.
        """.utf8)

        let mockResult = SubtitleSearchResult(
            id: "apply_test_1",
            providerName: "Mock Sub Provider",
            title: "Test Movie",
            releaseName: "Test.Release.1080p",
            languageCode: "en",
            languageDisplayName: "English",
            format: "srt",
            downloadURL: URL(string: "https://example.com/mock.srt")!,
            matchQuality: .exactRelease,
            score: 95
        )

        let mockProvider = MockSubtitleProvider(name: "Mock Sub Provider", results: [mockResult], mockData: srtData)
        let customManager = LIDSubtitleSearchManager(providers: [mockProvider])

        let engine = await MainActor.run {
            let eng = LIDPlaybackEngine()
            let dummyURL = tempDirectory.appendingPathComponent("movie.mp4")
            try? Data([0x00, 0x00, 0x00, 0x20]).write(to: dummyURL)
            eng.load(source: .localFile(url: dummyURL, title: "Test Movie"), autoPlay: false, resumeFromHistory: false)
            return eng
        }

        // Download and apply subtitle
        let data = try await customManager.download(result: mockResult)
        let store = LIDSubtitleStore(storageDirectory: self.tempDirectory)
        let savedURL = try await store.saveSubtitle(
            data: data,
            mediaTitle: "Test Movie",
            languageCode: mockResult.languageCode,
            releaseName: mockResult.releaseName
        )

        await MainActor.run {
            engine.addExternalSubtitle(url: savedURL, displayName: mockResult.displayTitle)
            XCTAssertTrue(engine.trackManager.selectedSubtitleTrack.isExternal)

            // Verify cue position lookup at 2.5s
            engine.trackManager.updatePosition(2.5)
            XCTAssertEqual(engine.trackManager.activeCueText, "Testing live subtitle cue synchronization.")

            // Position after 5.0s should clear cue
            engine.trackManager.updatePosition(6.0)
            XCTAssertNil(engine.trackManager.activeCueText)
        }
    }
}

// MARK: - Test Doubles / Mock Providers

private struct MockSubtitleProvider: SubtitleProvider {
    let providerName: String
    let results: [SubtitleSearchResult]
    var mockData: Data? = nil

    init(name: String, results: [SubtitleSearchResult], mockData: Data? = nil) {
        self.providerName = name
        self.results = results
        self.mockData = mockData
    }

    func search(query: SubtitleSearchQuery) async throws -> [SubtitleSearchResult] {
        return results
    }

    func download(result: SubtitleSearchResult) async throws -> Data {
        return mockData ?? Data("1\n00:00:01,000 --> 00:00:04,000\nMock Cue\n".utf8)
    }
}

private struct MockFailingSubtitleProvider: SubtitleProvider {
    let providerName: String

    init(name: String) {
        self.providerName = name
    }

    func search(query: SubtitleSearchQuery) async throws -> [SubtitleSearchResult] {
        throw NSError(domain: "MockError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Simulated network failure"])
    }

    func download(result: SubtitleSearchResult) async throws -> Data {
        throw NSError(domain: "MockError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Simulated network failure"])
    }
}
