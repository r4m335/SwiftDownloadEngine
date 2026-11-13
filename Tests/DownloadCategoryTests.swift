import XCTest
@testable import DM_Reverse_engineering

final class DownloadCategoryTests: XCTestCase {

    var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CategoryTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. MIME Type Classification

    func testMIMETypeClassification() {
        // Videos
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "video/mp4", filename: nil), .videos)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "video/webm", filename: nil), .videos)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "video/quicktime", filename: nil), .videos)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/x-mpegURL; charset=utf-8", filename: nil), .videos)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/vnd.apple.mpegurl", filename: nil), .videos)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/dash+xml", filename: nil), .videos)

        // Audio
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "audio/mpeg", filename: nil), .audio)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "audio/mp4", filename: nil), .audio)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "audio/flac", filename: nil), .audio)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "audio/wav", filename: nil), .audio)

        // Documents
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/pdf", filename: nil), .documents)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "text/plain", filename: nil), .documents)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/msword", filename: nil), .documents)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", filename: nil), .documents)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/epub+zip", filename: nil), .documents)

        // Archives
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/zip", filename: nil), .archives)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/x-rar-compressed", filename: nil), .archives)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/x-7z-compressed", filename: nil), .archives)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/gzip", filename: nil), .archives)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/x-tar", filename: nil), .archives)

        // Torrents
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/x-bittorrent", filename: nil), .torrents)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/x-torrent", filename: nil), .torrents)

        // Others
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/octet-stream", filename: nil), .others)
    }

    // MARK: - 2. File Extension Classification Fallback

    func testFileExtensionClassificationFallback() {
        // Videos
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "movie.mp4"), .videos)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "clip.mkv"), .videos)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "show.avi"), .videos)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "stream.m3u8"), .videos)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "dash.mpd"), .videos)

        // Audio
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "song.mp3"), .audio)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "track.flac"), .audio)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "podcast.m4a"), .audio)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "audio.wav"), .audio)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "voice.opus"), .audio)

        // Documents
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "book.pdf"), .documents)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "report.docx"), .documents)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "data.xlsx"), .documents)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "notes.txt"), .documents)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "novel.epub"), .documents)

        // Archives
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "package.zip"), .archives)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "bundle.tar.gz"), .archives)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "files.7z"), .archives)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "archive.rar"), .archives)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "installer.dmg"), .archives)

        // Torrents
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "ubuntu-24.04.torrent"), .torrents)

        // Others
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "unknown.bin"), .others)
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: nil, filename: "blob.dat"), .others)
    }

    // MARK: - 3. MIME Precedence Over Extension

    func testMIMEPrecedenceOverExtension() {
        // Server sends video/mp4 MIME even though filename ends in .bin
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "video/mp4", filename: "stream_chunk.bin"), .videos)

        // Server sends audio/mpeg MIME even though filename ends in .dat
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "audio/mpeg", filename: "audio_stream.dat"), .audio)

        // Server sends application/pdf MIME with .download extension
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/pdf", filename: "invoice.download"), .documents)

        // Server sends generic octet-stream MIME; fallback to filename extension
        XCTAssertEqual(DownloadCategoryClassifier.classify(mimeType: "application/octet-stream", filename: "vacation.mp4"), .videos)
    }

    // MARK: - 4. Sandbox Directory Resolution & Hierarchy

    func testCategoryDirectoryResolutionAndHierarchy() throws {
        let baseDir = tempDirectory.appendingPathComponent("Downloads", isDirectory: true)

        // Ensure all category directories are created
        try DownloadsDirectoryManager.ensureAllCategoryDirectoriesExist(baseDirectory: baseDir)

        let fileManager = FileManager.default
        let expectedSubfolders = [
            DownloadCategory.videos: "Videos",
            DownloadCategory.audio: "Music",
            DownloadCategory.documents: "Documents",
            DownloadCategory.archives: "Archives",
            DownloadCategory.torrents: "Torrents",
            DownloadCategory.others: "Others"
        ]

        for (category, subfolder) in expectedSubfolders {
            let catDir = try DownloadsDirectoryManager.categoryDownloadsDirectory(for: category, baseDirectory: baseDir)
            XCTAssertTrue(fileManager.fileExists(atPath: catDir.path), "Directory for \(category) must exist at \(catDir.path)")
            XCTAssertEqual(catDir.lastPathComponent, subfolder)
            XCTAssertEqual(catDir.deletingLastPathComponent().standardizedFileURL, baseDir.standardizedFileURL)
        }
    }

    // MARK: - 5. UnifiedTransfer Category Derivation

    func testUnifiedTransferCategoryDerivation() {
        let dummyURL = URL(fileURLWithPath: "/dummy/path")

        // 1. BitTorrent transfer
        let torrentTransfer = UnifiedTransfer(
            id: "t1",
            name: "ubuntu-iso",
            type: .torrent,
            state: .downloading,
            completedBytes: 100,
            destinationURL: dummyURL,
            source: "magnet:?xt=urn:btih:123"
        )
        XCTAssertEqual(torrentTransfer.category, .torrents)

        // 2. Video HTTP transfer
        let videoTransfer = UnifiedTransfer(
            id: "v1",
            name: "presentation.mp4",
            type: .http,
            state: .completed,
            completedBytes: 500,
            destinationURL: dummyURL,
            source: "https://example.com/presentation.mp4"
        )
        XCTAssertEqual(videoTransfer.category, .videos)

        // 3. Audio HTTP transfer
        let audioTransfer = UnifiedTransfer(
            id: "a1",
            name: "soundtrack.mp3",
            type: .http,
            state: .completed,
            completedBytes: 300,
            destinationURL: dummyURL,
            source: "https://example.com/soundtrack.mp3"
        )
        XCTAssertEqual(audioTransfer.category, .audio)

        // 4. Streaming Video (HLS)
        let hlsVideoTransfer = UnifiedTransfer(
            id: "hls1",
            name: "livestream.mp4",
            type: .hls,
            state: .downloading,
            completedBytes: 400,
            destinationURL: dummyURL,
            source: "https://example.com/stream.m3u8"
        )
        XCTAssertEqual(hlsVideoTransfer.category, .videos)

        // 5. Streaming Audio-Only (HLS)
        let hlsAudioTransfer = UnifiedTransfer(
            id: "hls2",
            name: "livestream.m4a",
            type: .hls,
            state: .downloading,
            completedBytes: 200,
            destinationURL: dummyURL,
            source: "https://example.com/stream.m3u8"
        )
        XCTAssertEqual(hlsAudioTransfer.category, .audio)
    }

    // MARK: - 6. Secondary Filter Matching (Metadata Only)

    func testSecondaryFilterMatching() {
        let dummyURL = URL(fileURLWithPath: "/dummy/path")
        let transfers = [
            UnifiedTransfer(id: "1", name: "v.mp4", type: .http, state: .completed, completedBytes: 10, destinationURL: dummyURL, source: "s1"),
            UnifiedTransfer(id: "2", name: "a.mp3", type: .http, state: .completed, completedBytes: 10, destinationURL: dummyURL, source: "s2"),
            UnifiedTransfer(id: "3", name: "d.pdf", type: .http, state: .completed, completedBytes: 10, destinationURL: dummyURL, source: "s3"),
            UnifiedTransfer(id: "4", name: "z.zip", type: .http, state: .completed, completedBytes: 10, destinationURL: dummyURL, source: "s4"),
            UnifiedTransfer(id: "5", name: "torrent_task", type: .torrent, state: .downloading, completedBytes: 10, destinationURL: dummyURL, source: "s5"),
            UnifiedTransfer(id: "6", name: "data.bin", type: .http, state: .completed, completedBytes: 10, destinationURL: dummyURL, source: "s6")
        ]

        // All filter (category == nil)
        let allFiltered = transfers.filter { item in
            let cat: DownloadCategory? = nil
            if let c = cat { return item.category == c }
            return true
        }
        XCTAssertEqual(allFiltered.count, 6)

        // Videos filter
        let videosFiltered = transfers.filter { $0.category == .videos }
        XCTAssertEqual(videosFiltered.map(\.id), ["1"])

        // Audio filter
        let audioFiltered = transfers.filter { $0.category == .audio }
        XCTAssertEqual(audioFiltered.map(\.id), ["2"])

        // Documents filter
        let docsFiltered = transfers.filter { $0.category == .documents }
        XCTAssertEqual(docsFiltered.map(\.id), ["3"])

        // Archives filter
        let archivesFiltered = transfers.filter { $0.category == .archives }
        XCTAssertEqual(archivesFiltered.map(\.id), ["4"])

        // Torrents filter
        let torrentsFiltered = transfers.filter { $0.category == .torrents }
        XCTAssertEqual(torrentsFiltered.map(\.id), ["5"])

        // Others filter
        let othersFiltered = transfers.filter { $0.category == .others }
        XCTAssertEqual(othersFiltered.map(\.id), ["6"])
    }

    // MARK: - 7. Atomic Organization of Existing Files

    func testAtomicOrganizationOfExistingFiles() throws {
        let fileManager = FileManager.default
        let rootDownloads = tempDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: rootDownloads, withIntermediateDirectories: true)

        // Create completed files directly in root
        let files = [
            "tutorial.mp4": Data("video".utf8),
            "recording.mp3": Data("audio".utf8),
            "handbook.pdf": Data("document".utf8),
            "backup.zip": Data("archive".utf8),
            "unknown_file.bin": Data("other".utf8),
            "active_download.tmp": Data("temp".utf8),
            "chunk.part": Data("partial".utf8)
        ]

        for (filename, data) in files {
            let fileURL = rootDownloads.appendingPathComponent(filename)
            try data.write(to: fileURL)
        }

        // Run organization
        let results = try DownloadsDirectoryManager.organizeUncategorizedFiles(in: rootDownloads)

        // 5 completed files should be organized; .tmp and .part must be ignored
        XCTAssertEqual(results.count, 5)

        // Verify categorized destinations
        let expectedPlacements = [
            "tutorial.mp4": "Videos/tutorial.mp4",
            "recording.mp3": "Music/recording.mp3",
            "handbook.pdf": "Documents/handbook.pdf",
            "backup.zip": "Archives/backup.zip",
            "unknown_file.bin": "Others/unknown_file.bin"
        ]

        for (filename, relativeExpected) in expectedPlacements {
            let expectedURL = rootDownloads.appendingPathComponent(relativeExpected)
            XCTAssertTrue(fileManager.fileExists(atPath: expectedURL.path), "File \(filename) must be moved to \(relativeExpected)")
            let oldURL = rootDownloads.appendingPathComponent(filename)
            XCTAssertFalse(fileManager.fileExists(atPath: oldURL.path), "Original file \(filename) must no longer exist at root")
        }

        // Incomplete files must NOT have been moved
        XCTAssertTrue(fileManager.fileExists(atPath: rootDownloads.appendingPathComponent("active_download.tmp").path))
        XCTAssertTrue(fileManager.fileExists(atPath: rootDownloads.appendingPathComponent("chunk.part").path))
    }
}

