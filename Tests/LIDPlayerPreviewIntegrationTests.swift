import XCTest
@testable import DownloadEngineKit

final class LIDPlayerPreviewIntegrationTests: XCTestCase {

    private var temporaryFileURLs: [URL] = []

    override func tearDown() {
        for url in temporaryFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFileURLs.removeAll()
        super.tearDown()
    }

    private func createTempFile(name: String, content: Data) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(UUID().uuidString)_\(name)")
        try! content.write(to: fileURL)
        temporaryFileURLs.append(fileURL)
        return fileURL
    }

    // MARK: - 1. Local File Preflight Validation

    func testLocalFilePreflightValidation() {
        // 1. Non-existent file
        let nonExistentURL = URL(fileURLWithPath: "/tmp/non_existent_media_\(UUID().uuidString).mp4")
        let nonExistentResult = LIDPreviewPreflight.preflight(localFileURL: nonExistentURL)
        if case .failure(let error) = nonExistentResult {
            XCTAssertEqual(error, .fileNotFound(nonExistentURL))
        } else {
            XCTFail("Expected .fileNotFound error for missing file")
        }

        // 2. Empty file (0 bytes)
        let emptyURL = createTempFile(name: "empty.mp4", content: Data())
        let emptyResult = LIDPreviewPreflight.preflight(localFileURL: emptyURL)
        if case .failure(let error) = emptyResult {
            XCTAssertEqual(error, .fileEmpty(emptyURL))
        } else {
            XCTFail("Expected .fileEmpty error for 0-byte file")
        }

        // 3. Valid MP4 file
        let validData = "sample valid video payload".data(using: .utf8)!
        let validURL = createTempFile(name: "video.mp4", content: validData)
        let validResult = LIDPreviewPreflight.preflight(localFileURL: validURL, title: "Custom Video Title")
        if case .success(let source) = validResult {
            XCTAssertEqual(source.title, "Custom Video Title")
            XCTAssertEqual(source.url, validURL)
            if case .localFile(let url, let title) = source {
                XCTAssertEqual(url, validURL)
                XCTAssertEqual(title, "Custom Video Title")
            } else {
                XCTFail("Expected .localFile source")
            }
        } else {
            XCTFail("Expected successful preflight for valid local file")
        }

        // 4. Corrupt MPEG-TS file (missing 0x47 sync byte)
        let corruptTSURL = createTempFile(name: "corrupt.ts", content: Data([0x00, 0x01, 0x02, 0x03]))
        let corruptTSResult = LIDPreviewPreflight.preflight(localFileURL: corruptTSURL)
        if case .failure(let error) = corruptTSResult {
            if case .invalidContainerHeader(let url, _) = error {
                XCTAssertEqual(url, corruptTSURL)
            } else {
                XCTFail("Expected .invalidContainerHeader error for invalid TS file")
            }
        } else {
            XCTFail("Expected failure for corrupt TS file")
        }

        // 5. Valid MPEG-TS file (starts with 0x47 sync byte)
        var validTSData = Data([0x47])
        validTSData.append(contentsOf: Array(repeating: UInt8(0x00), count: 187))
        validTSData.append(0x47)
        let validTSURL = createTempFile(name: "valid.ts", content: validTSData)
        let validTSResult = LIDPreviewPreflight.preflight(localFileURL: validTSURL)
        XCTAssertTrue(validTSResult.isSuccess)
    }

    // MARK: - 2. DRM, Blob & Segment-Chunk Blocking

    func testWebpageResourceDRMBlobAndSegmentBlocking() {
        // 1. DRM Protected Resource
        let drmResource = WebpageResource(
            url: URL(string: "https://example.com/protected/master.m3u8")!,
            title: "Encrypted Stream",
            suggestedFilename: "master.m3u8",
            resourceType: .streamManifest,
            isDRMProtected: true,
            drmProtectionType: "FairPlay"
        )
        let drmResult = LIDPreviewPreflight.preflight(resource: drmResource)
        if case .failure(let error) = drmResult {
            XCTAssertEqual(error, .drmProtected(type: "FairPlay"))
        } else {
            XCTFail("Expected DRM protection rejection")
        }

        // 2. Blob URL
        let blobResource = WebpageResource(
            url: URL(string: "blob:https://example.com/a1b2c3d4-e5f6")!,
            title: "Blob Video",
            suggestedFilename: "blob_video.mp4",
            resourceType: .video
        )
        let blobResult = LIDPreviewPreflight.preflight(resource: blobResource)
        if case .failure(let error) = blobResult {
            XCTAssertEqual(error, .blobResourceUnsupported)
        } else {
            XCTFail("Expected blob resource rejection")
        }

        // 3. Segment Chunk Resource
        let segmentResource = WebpageResource(
            url: URL(string: "https://example.com/hls/segment_0001.ts")!,
            title: "Segment 1",
            suggestedFilename: "segment_0001.ts",
            resourceType: .video
        )
        let segmentResult = LIDPreviewPreflight.preflight(resource: segmentResource)
        if case .failure(let error) = segmentResult {
            XCTAssertEqual(error, .segmentChunkUnsupported)
        } else {
            XCTFail("Expected segment chunk rejection")
        }
    }

    // MARK: - 3. Signed URL Token Expiration Check

    func testSignedURLTokenExpiration() {
        let referenceDate = Date(timeIntervalSince1970: 1700000000)

        // URL expired in the past (expires=1600000000 < 1700000000)
        let expiredURL = URL(string: "https://cdn.example.com/video.mp4?expires=1600000000&sig=abc")!
        let expiredResource = WebpageResource(
            url: expiredURL,
            title: "Expired Video",
            suggestedFilename: "video.mp4",
            resourceType: .video
        )
        let expiredResult = LIDPreviewPreflight.preflight(resource: expiredResource, now: referenceDate)
        if case .failure(let error) = expiredResult {
            XCTAssertEqual(error, .tokenExpired(expiredURL))
        } else {
            XCTFail("Expected token expired failure")
        }

        // URL with future expiration (expires=1800000000 > 1700000000)
        let validExpURL = URL(string: "https://cdn.example.com/video.mp4?expires=1800000000&sig=abc")!
        let validExpResource = WebpageResource(
            url: validExpURL,
            title: "Valid Video",
            suggestedFilename: "video.mp4",
            resourceType: .video
        )
        let validExpResult = LIDPreviewPreflight.preflight(resource: validExpResource, now: referenceDate)
        XCTAssertTrue(validExpResult.isSuccess)
    }

    // MARK: - 4. Request Context Cookie Propagation

    func testRequestContextCookiePropagation() {
        let cookieURL = URL(string: "https://auth.stream.com/media/master.m3u8")!
        let cookie = BrowserCookie(
            name: "SESSION_AUTH",
            value: "TOKEN_SECRET_98765",
            domain: "auth.stream.com",
            path: "/",
            isSecure: true,
            isHTTPOnly: true
        )

        let context = BrowserRequestContext(
            url: cookieURL,
            userAgent: "LIDCustomAgent/1.0",
            cookies: [cookie],
            customHeaders: ["Authorization": "Bearer TOKEN_SECRET_98765"]
        )

        let resource = WebpageResource(
            url: cookieURL,
            title: "Auth Stream",
            suggestedFilename: "master.m3u8",
            resourceType: .streamManifest,
            requestContext: context
        )

        let result = LIDPreviewPreflight.preflight(resource: resource)
        XCTAssertTrue(result.isSuccess)

        // Verify cookie was installed into HTTPCookieStorage.shared
        let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL) ?? []
        let matched = cookies.first(where: { $0.name == "SESSION_AUTH" })
        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.value, "TOKEN_SECRET_98765")
    }

    // MARK: - 5. Player Session Generation & Stale Callback Dropping

    @MainActor
    func testSessionGenerationStaleCallbackDropping() {
        let engine = LIDPlaybackEngine()
        XCTAssertEqual(engine.sessionGeneration, 0)

        // 1. Load Session 1
        let dummy1 = createTempFile(name: "test1.mp4", content: "data1".data(using: .utf8)!)
        let source1 = LIDPlayerSource.localFile(url: dummy1, title: "Test 1")
        engine.load(source: source1, autoPlay: false, resumeFromHistory: false)

        XCTAssertEqual(engine.sessionGeneration, 1)
        XCTAssertEqual(engine.vlcBackend.activeSessionGeneration, 1)

        // Update from matching generation 1 should succeed
        engine.engineDidUpdateTime(engine.vlcBackend, currentSeconds: 10.0, durationSeconds: 60.0)
        XCTAssertEqual(engine.currentPositionSeconds, 10.0)

        // 2. Load Session 2
        let dummy2 = createTempFile(name: "test2.mp4", content: "data2".data(using: .utf8)!)
        let source2 = LIDPlayerSource.localFile(url: dummy2, title: "Test 2")
        engine.load(source: source2, autoPlay: false, resumeFromHistory: false)

        XCTAssertEqual(engine.sessionGeneration, 2)
        XCTAssertEqual(engine.vlcBackend.activeSessionGeneration, 2)
        XCTAssertEqual(engine.currentPositionSeconds, 0.0)

        // 3. Simulate stale callback from session 1 (generation 1)
        engine.vlcBackend.activeSessionGeneration = 1
        engine.engineDidUpdateTime(engine.vlcBackend, currentSeconds: 45.0, durationSeconds: 60.0)
        // Position MUST NOT update because generation 1 != current engine generation 2
        XCTAssertEqual(engine.currentPositionSeconds, 0.0)

        // 4. Update with matching generation 2 should succeed
        engine.vlcBackend.activeSessionGeneration = 2
        engine.engineDidUpdateTime(engine.vlcBackend, currentSeconds: 22.0, durationSeconds: 100.0)
        XCTAssertEqual(engine.currentPositionSeconds, 22.0)
        XCTAssertEqual(engine.durationSeconds, 100.0)

        // 5. Stop engine -> generation increments to 3, backends reset to 0
        engine.stop()
        XCTAssertEqual(engine.sessionGeneration, 3)
        XCTAssertEqual(engine.vlcBackend.activeSessionGeneration, 0)
        XCTAssertEqual(engine.playbackState, .idle)

        // Stale callback after stop MUST be ignored
        engine.vlcBackend.activeSessionGeneration = 2
        engine.engineDidUpdateState(engine.vlcBackend, state: .playing)
        XCTAssertEqual(engine.playbackState, .idle)
    }

    // MARK: - 6. Deterministic AVFoundation to VLCKit Fallback

    @MainActor
    func testDeterministicBackendFallback() {
        let engine = LIDPlaybackEngine()
        let netURL = URL(string: "https://example.com/video.mp4")!
        let netSource = LIDPlayerSource.networkStream(url: netURL, headers: [:], title: "Network Video")

        // MP4 network stream routes initially to AVFoundation
        engine.load(source: netSource, autoPlay: false, resumeFromHistory: false)
        XCTAssertEqual(engine.activeBackendType, .avFoundation)
        let currentGen = engine.sessionGeneration

        // Simulate AVFoundation failure
        engine.engineDidFail(engine.avBackend, error: "AVPlayerItemStatusFailed (HTTP 403 Forbidden)")

        // Must automatically fall back to VLCKit while retaining the session generation
        XCTAssertEqual(engine.activeBackendType, .vlcKit)
        XCTAssertEqual(engine.playbackState, .loading)
        XCTAssertEqual(engine.vlcBackend.activeSessionGeneration, currentGen)
        XCTAssertEqual(engine.avBackend.activeSessionGeneration, 0)

        // Stale callback from failing AVFoundation must be dropped
        engine.engineDidUpdateTime(engine.avBackend, currentSeconds: 50.0, durationSeconds: 100.0)
        XCTAssertEqual(engine.currentPositionSeconds, 0.0)
    }

    // MARK: - 7. Media Extension and URL Classification

    func testMediaExtensionAndURLClassification() {
        let mediaExtensions = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "flv", "ts", "mp3", "m4a", "aac", "wav", "flac", "m3u8", "mpd"]
        for ext in mediaExtensions {
            XCTAssertTrue(LIDPreviewPreflight.isMediaExtension(ext), "\(ext) should be recognized as media")
            let fileURL = URL(fileURLWithPath: "/documents/sample.\(ext)")
            XCTAssertTrue(LIDPreviewPreflight.isMediaURL(fileURL), "URL for \(ext) should be recognized as media URL")
        }

        let nonMediaExtensions = ["pdf", "txt", "docx", "xlsx", "zip", "png", "jpg", "html", "json"]
        for ext in nonMediaExtensions {
            XCTAssertFalse(LIDPreviewPreflight.isMediaExtension(ext), "\(ext) should not be recognized as media")
            let fileURL = URL(fileURLWithPath: "/documents/document.\(ext)")
            XCTAssertFalse(LIDPreviewPreflight.isMediaURL(fileURL), "URL for \(ext) should not be recognized as media URL")
        }
    }

    // MARK: - 8. Standalone DASH Preview Parity

    func testStandaloneDASHPreviewParity() {
        let manifestURL = URL(string: "https://dash.example.com/stream.mpd")!

        // Clear DASH Manifest
        let clearMPD = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" minBufferTime="PT1.5S" type="static" mediaPresentationDuration="PT30S">
          <Period id="1">
            <AdaptationSet mimeType="video/mp4" contentType="video">
              <Representation id="video_1080" bandwidth="4000000" width="1920" height="1080"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """.data(using: .utf8)!

        let clearResult = LIDPreviewPreflight.preflightDASH(
            manifestURL: manifestURL,
            manifestData: clearMPD,
            title: "Clear DASH Stream"
        )
        if case .success(let source) = clearResult {
            if case .dashStream(let url, let repID, let title, _) = source {
                XCTAssertEqual(url, manifestURL)
                XCTAssertEqual(repID, "video_1080")
                XCTAssertEqual(title, "Clear DASH Stream")
            } else {
                XCTFail("Expected .dashStream source")
            }
        } else {
            XCTFail("Expected successful DASH preflight for clear manifest")
        }

        // DRM Protected DASH Manifest (ContentProtection)
        let drmMPD = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" minBufferTime="PT1.5S" type="static" mediaPresentationDuration="PT30S">
          <Period id="1">
            <AdaptationSet mimeType="video/mp4" contentType="video">
              <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
              <Representation id="video_encrypted" bandwidth="4000000"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """.data(using: .utf8)!

        let drmResult = LIDPreviewPreflight.preflightDASH(
            manifestURL: manifestURL,
            manifestData: drmMPD,
            title: "DRM DASH Stream"
        )
        if case .failure(let error) = drmResult {
            if case .drmProtected = error {
                // Expected
            } else {
                XCTFail("Expected .drmProtected error, got: \(error)")
            }
        } else {
            XCTFail("Expected failure for DRM protected DASH stream")
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
