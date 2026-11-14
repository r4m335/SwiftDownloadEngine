import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class FindResourcesAndAddDownloadModernizationTests: XCTestCase {

    // MARK: - 1. Filename & Extension Helper Tests

    func testFilenameExtensionHelperSplit() {
        let (base1, ext1) = FilenameExtensionHelper.split(filename: "ubuntu-22.04.iso")
        XCTAssertEqual(base1, "ubuntu-22.04")
        XCTAssertEqual(ext1, "iso")

        let (base2, ext2) = FilenameExtensionHelper.split(filename: "document_without_ext")
        XCTAssertEqual(base2, "document_without_ext")
        XCTAssertEqual(ext2, "")

        let (base3, ext3) = FilenameExtensionHelper.split(filename: ".hiddenfile")
        XCTAssertEqual(base3, ".hiddenfile")
        XCTAssertEqual(ext3, "")

        let (base4, ext4) = FilenameExtensionHelper.split(filename: "archive.tar.gz")
        XCTAssertEqual(base4, "archive.tar")
        XCTAssertEqual(ext4, "gz")
    }

    func testFilenameExtensionHelperCombineAndDuplicatePrevention() {
        // Standard combination
        let combined = FilenameExtensionHelper.combine(base: "MyVideo", ext: "mp4")
        XCTAssertEqual(combined, "MyVideo.mp4")

        // Leading dot in extension should be stripped
        let dotExt = FilenameExtensionHelper.combine(base: "report", ext: ".pdf")
        XCTAssertEqual(dotExt, "report.pdf")

        // Duplicate extension prevention: base already ends with .ext
        let noDuplicate = FilenameExtensionHelper.combine(base: "movie.mp4", ext: "mp4")
        XCTAssertEqual(noDuplicate, "movie.mp4", "Should prevent movie.mp4.mp4 duplicate extensions")

        // Case-insensitive duplicate extension prevention
        let caseInsensitiveDup = FilenameExtensionHelper.combine(base: "document.PDF", ext: "pdf")
        XCTAssertEqual(caseInsensitiveDup.lowercased(), "document.pdf")

        // Empty extension
        let emptyExt = FilenameExtensionHelper.combine(base: "just_name", ext: "")
        XCTAssertEqual(emptyExt, "just_name")
    }

    func testFilenameSanitization() {
        let dirty = "my/illegal:file*name?with\"bad<chars>|test.mp4"
        let clean = FilenameExtensionHelper.sanitizeFilename(dirty)
        XCTAssertFalse(clean.contains("/"))
        XCTAssertFalse(clean.contains("\\"))
        XCTAssertFalse(clean.contains(":"))
        XCTAssertFalse(clean.contains("*"))
        XCTAssertFalse(clean.contains("?"))
        XCTAssertFalse(clean.contains("\""))
        XCTAssertFalse(clean.contains("<"))
        XCTAssertFalse(clean.contains(">"))
        XCTAssertFalse(clean.contains("|"))
    }

    func testMediaContainerCompatibility() {
        // Changing mp4 to m4v or mov is compatible
        XCTAssertTrue(FilenameExtensionHelper.isCompatibleExtensionChange(originalExtension: "mp4", newExtension: "m4v"))
        XCTAssertTrue(FilenameExtensionHelper.isCompatibleExtensionChange(originalExtension: "mp4", newExtension: "mov"))

        // Changing mp4 to zip or exe is not compatible
        XCTAssertFalse(FilenameExtensionHelper.isCompatibleExtensionChange(originalExtension: "mp4", newExtension: "zip"))
        XCTAssertFalse(FilenameExtensionHelper.isCompatibleExtensionChange(originalExtension: "mp4", newExtension: "exe"))

        // Audio formats
        XCTAssertTrue(FilenameExtensionHelper.isCompatibleExtensionChange(originalExtension: "m4a", newExtension: "aac"))
        XCTAssertFalse(FilenameExtensionHelper.isCompatibleExtensionChange(originalExtension: "mp3", newExtension: "pdf"))
    }

    func testExtensionDetectionFromMIMEAndURL() {
        // MIME takes precedence
        let extFromMime = FilenameExtensionHelper.detectExtension(
            from: URL(string: "https://example.com/stream?token=abc"),
            mimeType: "video/mp4"
        )
        XCTAssertEqual(extFromMime, "mp4")

        let extFromM3U8Mime = FilenameExtensionHelper.detectExtension(
            from: URL(string: "https://example.com/playlist"),
            mimeType: "application/vnd.apple.mpegurl"
        )
        XCTAssertEqual(extFromM3U8Mime, "mp4", "HLS reconstructed media should produce mp4")

        // Fallback to URL path extension
        let extFromURL = FilenameExtensionHelper.detectExtension(
            from: URL(string: "https://example.com/downloads/archive.zip"),
            mimeType: nil
        )
        XCTAssertEqual(extFromURL, "zip")
    }

    // MARK: - 2. URL Inspector Tests

    func testURLInspectorPlayableMedia() async {
        let videoURL = URL(string: "https://example.com/media/clip.mp4")!
        let result = await URLInspector.shared.inspect(url: videoURL)

        XCTAssertEqual(result.suggestedExtension, "mp4")
        XCTAssertEqual(result.suggestedBaseFilename, "clip")
        if case .playableMedia(let url, let filename, let ext, _, _) = result.kind {
            XCTAssertEqual(url, videoURL)
            XCTAssertEqual(filename, "clip.mp4")
            XCTAssertEqual(ext, "mp4")
        } else {
            XCTFail("Expected .playableMedia but got \(result.kind)")
        }
    }

    func testURLInspectorStreamingManifest() async {
        let hlsURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        let result = await URLInspector.shared.inspect(url: hlsURL)

        XCTAssertEqual(result.suggestedExtension, "mp4", "HLS streams reconstruct into MP4 containers")
        if case .streamingManifest(let kind, let url, _, _) = result.kind {
            XCTAssertEqual(kind, .hls)
            XCTAssertEqual(url, hlsURL)
        } else {
            XCTFail("Expected .streamingManifest(.hls) but got \(result.kind)")
        }

        let dashURL = URL(string: "https://example.com/video/manifest.mpd")!
        let dashResult = await URLInspector.shared.inspect(url: dashURL)
        if case .streamingManifest(let kind, _, _, _) = dashResult.kind {
            XCTAssertEqual(kind, .dash)
        } else {
            XCTFail("Expected .streamingManifest(.dash) but got \(dashResult.kind)")
        }
    }

    func testURLInspectorDirectDownload() async {
        let zipURL = URL(string: "https://example.com/releases/tool-v1.0.tar.gz")!
        let result = await URLInspector.shared.inspect(url: zipURL)

        XCTAssertEqual(result.suggestedExtension, "gz")
        if case .directDownload(let filename, let ext, _, _) = result.kind {
            XCTAssertEqual(filename, "tool-v1.0.tar.gz")
            XCTAssertEqual(ext, "gz")
        } else {
            XCTFail("Expected .directDownload but got \(result.kind)")
        }
    }

    func testURLInspectorOrdinaryWebpage() async {
        let webURL = URL(string: "https://example.com/articles/index.html")!
        let result = await URLInspector.shared.inspect(url: webURL)

        if case .ordinaryWebpage(let url, _) = result.kind {
            XCTAssertEqual(url, webURL)
        } else {
            XCTFail("Expected .ordinaryWebpage but got \(result.kind)")
        }
    }

    func testURLInspectorUnsupportedScheme() async {
        let ftpURL = URL(string: "ftp://example.com/file.bin")!
        let result = await URLInspector.shared.inspect(url: ftpURL)

        if case .unknown = result.kind {
            // Success: ftp is not supported
        } else {
            XCTFail("Expected .unknown for ftp scheme")
        }
    }

    // MARK: - 3. Torrent Metadata Parser Tests

    func testTorrentMetadataParserMagnetURI() {
        let magnet = "magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=Ubuntu%20Linux%2022.04.iso"
        let hash = TorrentMetadataParser.extractInfoHash(from: magnet)
        XCTAssertEqual(hash?.lowercased(), "da39a3ee5e6b4b0d3255bfef95601890afd80709")

        let dn = TorrentMetadataParser.extractDisplayName(from: magnet)
        XCTAssertEqual(dn, "Ubuntu Linux 22.04.iso")

        // Split single-file torrent name
        let (base, ext) = FilenameExtensionHelper.split(filename: dn!)
        XCTAssertEqual(base, "Ubuntu Linux 22.04")
        XCTAssertEqual(ext, "iso")
    }

    func testTorrentMetadataParserSingleVsMultiFile() {
        // Construct minimal synthetic single-file bencoded torrent dictionary:
        // d4:infod6:lengthi1024e4:name13:singlefile.xteee (length of "singlefile.xt" is 13)
        let singleFileTorrent = "d4:infod6:lengthi1024e4:name13:singlefile.xteee"
        let singleData = Data(singleFileTorrent.utf8)
        let singleParsed = TorrentMetadataParser.extractBencodedInfo(from: singleData)
        XCTAssertNotNil(singleParsed)
        XCTAssertEqual(singleParsed?.name, "singlefile.xt")
        XCTAssertFalse(singleParsed?.isMultiFile ?? true, "Torrent without 'files' key must be single file")

        // Construct minimal synthetic multi-file bencoded torrent dictionary:
        // d4:infod5:filesld6:lengthi512e4:pathl5:a.txteee4:name9:root_foldeee (length of "root_fold" is 9)
        let multiFileTorrent = "d4:infod5:filesld6:lengthi512e4:pathl5:a.txteee4:name9:root_foldeee"
        let multiData = Data(multiFileTorrent.utf8)
        let multiParsed = TorrentMetadataParser.extractBencodedInfo(from: multiData)
        XCTAssertNotNil(multiParsed)
        XCTAssertEqual(multiParsed?.name, "root_fold")
        XCTAssertTrue(multiParsed?.isMultiFile ?? false, "Torrent with 'files' list must be multi file")
    }

    // MARK: - 4. Find Resources Modernization Tests

    func testWebpageResourceHLSVariantMetadataPreservation() {
        let masterURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        let variantPref = HLSVariantSelectionPreferences(
            maximumBandwidth: 6221600,
            maximumWidth: 1920,
            maximumHeight: 1080
        )

        let resource = WebpageResource(
            id: UUID().uuidString,
            url: masterURL,
            title: "Mux Stream 1080p",
            suggestedFilename: "Mux Stream 1080p.mp4",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            estimatedSize: 150_000_000,
            hlsVariantPreferences: variantPref
        )

        XCTAssertEqual(resource.hlsVariantPreferences?.maximumWidth, 1920)
        XCTAssertEqual(resource.hlsVariantPreferences?.maximumBandwidth, 6221600)
        XCTAssertEqual(resource.resourceType, .video)
    }

    func testWebpageResourceAudioIndicatorSemantics() {
        let videoResource = WebpageResource(
            id: UUID().uuidString,
            url: URL(string: "https://example.com/video.mp4")!,
            title: "Video",
            suggestedFilename: "video.mp4",
            resourceType: .video,
            mimeType: "video/mp4"
        )
        XCTAssertEqual(videoResource.resourceType, .video)

        let audioResource = WebpageResource(
            id: UUID().uuidString,
            url: URL(string: "https://example.com/track.mp3")!,
            title: "Track",
            suggestedFilename: "track.mp3",
            resourceType: .audio,
            mimeType: "audio/mpeg"
        )
        XCTAssertEqual(audioResource.resourceType, .audio)
    }

    // MARK: - 5. Add Download Input Mode Architecture Tests

    func testAddDownloadInputModes() {
        // Top-level types: HTTP and BitTorrent
        XCTAssertEqual(AddDownloadType.allCases.map(\.rawValue), ["HTTP", "BitTorrent"])

        // Inner HTTP modes
        XCTAssertEqual(
            HTTPInputMode.allCases.map(\.rawValue),
            ["Single URL", "Multiple URLs / Text Import", "URL Pattern"]
        )
    }

    // MARK: - 6. URL Inspector HEAD Rejection Fallback Tests

    func testURLInspectorFallbackRangeGETWhenHEADReturns405() async throws {
        // Register custom protocol that rejects HEAD with 405 Method Not Allowed
        // but succeeds on GET with 206 Partial Content and video/mp4
        HEADRejectionMockProtocol.reset()
        HEADRejectionMockProtocol.mockMIMEType = "video/mp4"
        HEADRejectionMockProtocol.mockContentLength = 25_000_000

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HEADRejectionMockProtocol.self]
        let session = URLSession(configuration: config)

        let ambiguousMediaURL = URL(string: "https://cdn.example.com/api/v1/stream_asset?id=999")!
        let result = await URLInspector.shared.inspect(url: ambiguousMediaURL, session: session)

        XCTAssertTrue(HEADRejectionMockProtocol.receivedHEAD, "Must have attempted HEAD probe first")
        XCTAssertTrue(HEADRejectionMockProtocol.receivedGET, "Must have executed fallback GET probe after HEAD 405 rejection")

        if case .playableMedia(let url, _, let ext, let mime, let size) = result.kind {
            XCTAssertEqual(url, ambiguousMediaURL)
            XCTAssertEqual(ext, "mp4")
            XCTAssertEqual(mime, "video/mp4")
            XCTAssertEqual(size, 25_000_000)
        } else {
            XCTFail("Expected .playableMedia after fallback GET probe, got \(result.kind)")
        }
    }

    func testURLInspectorFallbackRangeGETWhenHEADFailsWithDirectDownload() async throws {
        HEADRejectionMockProtocol.reset()
        HEADRejectionMockProtocol.mockMIMEType = "application/zip"
        HEADRejectionMockProtocol.mockContentLength = 100_000_000

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HEADRejectionMockProtocol.self]
        let session = URLSession(configuration: config)

        let ambiguousDownloadURL = URL(string: "https://download.example.com/get_package?build=latest")!
        let result = await URLInspector.shared.inspect(url: ambiguousDownloadURL, session: session)

        XCTAssertTrue(HEADRejectionMockProtocol.receivedHEAD)
        XCTAssertTrue(HEADRejectionMockProtocol.receivedGET)

        if case .directDownload(_, let ext, let mime, let size) = result.kind {
            XCTAssertEqual(ext, "zip")
            XCTAssertEqual(mime, "application/zip")
            XCTAssertEqual(size, 100_000_000)
        } else {
            XCTFail("Expected .directDownload after fallback GET probe, got \(result.kind)")
        }
    }

    // MARK: - 7. LID Player HTML & Infrastructure Tests

    func testBrowserHLSInlinePlayerSupportsDirectVideoAndAudio() {
        // Direct MP4 Video
        let videoURL = URL(string: "https://example.com/videos/nature.mp4")!
        let videoHTML = BrowserHLSInlinePlayer.html(for: videoURL, title: "Nature Video")
        XCTAssertTrue(BrowserHLSInlinePlayer.isInlinePlayerHTML(videoHTML))
        XCTAssertTrue(videoHTML.contains("Video Stream"), "Badge should show Video Stream for mp4")
        XCTAssertTrue(videoHTML.contains("type=\"video/mp4\""))
        XCTAssertTrue(videoHTML.contains("#0b0f19"), "Must preserve LID dark theme")
        XCTAssertTrue(videoHTML.contains("playsinline"))

        // Direct MP3 Audio
        let audioURL = URL(string: "https://example.com/audio/podcast.mp3")!
        let audioHTML = BrowserHLSInlinePlayer.html(for: audioURL, title: "Podcast Episode 1")
        XCTAssertTrue(BrowserHLSInlinePlayer.isInlinePlayerHTML(audioHTML))
        XCTAssertTrue(audioHTML.contains("Audio Stream"), "Badge should show Audio Stream for mp3")
        XCTAssertTrue(audioHTML.contains("type=\"audio/mpeg\""))

        // HLS Stream (.m3u8)
        let hlsURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        let hlsHTML = BrowserHLSInlinePlayer.html(for: hlsURL, title: "HLS Stream")
        XCTAssertTrue(hlsHTML.contains("HLS Stream"))
        XCTAssertTrue(hlsHTML.contains("application/vnd.apple.mpegurl"))
    }
}

// MARK: - Mock URLProtocol for HEAD Rejection

final class HEADRejectionMockProtocol: URLProtocol {
    nonisolated(unsafe) static var receivedHEAD = false
    nonisolated(unsafe) static var receivedGET = false
    nonisolated(unsafe) static var mockMIMEType = "application/octet-stream"
    nonisolated(unsafe) static var mockContentLength: Int64 = 1024

    static func reset() {
        receivedHEAD = false
        receivedGET = false
        mockMIMEType = "application/octet-stream"
        mockContentLength = 1024
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let method = request.httpMethod?.uppercased() ?? "GET"

        if method == "HEAD" {
            Self.receivedHEAD = true
            // Server disallows HEAD with 405 Method Not Allowed
            let response = HTTPURLResponse(
                url: url,
                statusCode: 405,
                httpVersion: "HTTP/1.1",
                headerFields: ["Allow": "GET, POST"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else if method == "GET" {
            Self.receivedGET = true
            let headers: [String: String] = [
                "Content-Type": Self.mockMIMEType,
                "Content-Range": "bytes 0-0/\(Self.mockContentLength)",
                "Content-Length": "1",
                "Accept-Ranges": "bytes"
            ]
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0x00]))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 501, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
