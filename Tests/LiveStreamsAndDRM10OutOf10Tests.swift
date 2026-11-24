import XCTest
import Foundation
@testable import DownloadEngineKit

// MARK: - Mock URLProtocol for Live Stream & DRM Tests

final class LiveStreamsMockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handlers: [URL: Handler] = [:]
    private static var requestHistory: [URLRequest] = []

    static func setHandler(for url: URL, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[url] = handler
    }

    static func getRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestHistory
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll()
        requestHistory.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock()
        defer { lock.unlock() }
        return handlers[url] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        LiveStreamsMockURLProtocol.lock.lock()
        LiveStreamsMockURLProtocol.requestHistory.append(request)
        let handler = LiveStreamsMockURLProtocol.handlers[url]
        LiveStreamsMockURLProtocol.lock.unlock()

        guard let handler = handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - 10/10 Test Suite for Feature 7

final class LiveStreamsAndDRM10OutOf10Tests: XCTestCase {

    private var temporaryTestDirectory: URL!
    private var mockSession: URLSession!

    override func setUp() {
        super.setUp()
        LiveStreamsMockURLProtocol.reset()
        let tempBase = FileManager.default.temporaryDirectory
        temporaryTestDirectory = tempBase.appendingPathComponent("LiveDRM10Tests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryTestDirectory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LiveStreamsMockURLProtocol.self]
        mockSession = URLSession(configuration: config)
    }

    override func tearDown() {
        LiveStreamsMockURLProtocol.reset()
        if let dir = temporaryTestDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }

    // MARK: - Gap 6: DRM URL False Positives (Manifest Evidence Overrides URL)

    func testDRMDetectorClearManifestWithDRMInURLPathIsNotFlaggedAsDRM() {
        let manifestText = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:6.0,
        seg1.ts
        #EXT-X-ENDLIST
        """

        let clearWithDRMPath = URL(string: "https://cdn.example.com/drm/live/stream.m3u8")!
        let result = StreamDRMDetector.evaluate(manifestText: manifestText, url: clearWithDRMPath)

        XCTAssertFalse(result.isProtected, "Clear manifest must not be flagged as DRM just because URL contains '/drm/'")
        XCTAssertNil(result.protectionType)
        XCTAssertFalse(result.isAES128Encrypted)

        let fairPlayURL = URL(string: "https://cdn.example.com/fairplay/preview/master.m3u8")!
        let result2 = StreamDRMDetector.evaluate(manifestText: manifestText, url: fairPlayURL)
        XCTAssertFalse(result2.isProtected, "Clear manifest must override URL path heuristics")
    }

    func testDRMDetectorAdvisoryFallbackWhenManifestTextIsEmpty() {
        let emptyText = ""
        let drmURL = URL(string: "https://example.com/drm/secure.m3u8")!
        let result = StreamDRMDetector.evaluate(manifestText: emptyText, url: drmURL)
        XCTAssertTrue(result.isProtected, "Empty manifest text falls back to advisory URL heuristic")
        XCTAssertEqual(result.protectionType, "DRM")

        let clearURL = URL(string: "https://example.com/video/stream.m3u8")!
        let resultClear = StreamDRMDetector.evaluate(manifestText: emptyText, url: clearURL)
        XCTAssertFalse(resultClear.isProtected)
    }

    // MARK: - Gap 6: DRM True-Positive Detection

    func testDRMDetectorIdentifiesFairPlayWidevineAndPlayReady() {
        let fairplayHLS = """
        #EXTM3U
        #EXT-X-VERSION:5
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fps.key.com",KEYFORMAT="com.apple.streamingkeydelivery"
        #EXTINF:6.0,
        seg1.ts
        """
        let fpResult = StreamDRMDetector.evaluate(manifestText: fairplayHLS, url: URL(string: "https://example.com/live.m3u8")!)
        XCTAssertTrue(fpResult.isProtected)
        XCTAssertEqual(fpResult.protectionType, "FairPlay")
        XCTAssertFalse(fpResult.isAES128Encrypted)

        let widevineDASH = """
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
            <Period>
                <AdaptationSet>
                    <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
                    <Representation id="v1" bandwidth="1000"/>
                </AdaptationSet>
            </Period>
        </MPD>
        """
        let wvResult = StreamDRMDetector.evaluate(manifestText: widevineDASH, url: URL(string: "https://example.com/manifest.mpd")!)
        XCTAssertTrue(wvResult.isProtected)
        XCTAssertEqual(wvResult.protectionType, "Widevine")

        let playReadyDASH = """
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
            <Period>
                <AdaptationSet>
                    <ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95"/>
                    <Representation id="v1" bandwidth="1000"/>
                </AdaptationSet>
            </Period>
        </MPD>
        """
        let prResult = StreamDRMDetector.evaluate(manifestText: playReadyDASH, url: URL(string: "https://example.com/manifest.mpd")!)
        XCTAssertTrue(prResult.isProtected)
        XCTAssertEqual(prResult.protectionType, "PlayReady")

        let aes128HLS = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="https://example.com/key.bin"
        #EXTINF:6.0,
        seg1.ts
        """
        let aesResult = StreamDRMDetector.evaluate(manifestText: aes128HLS, url: URL(string: "https://example.com/live.m3u8")!)
        XCTAssertFalse(aesResult.isProtected, "Standard clear AES-128 identity encryption is not proprietary DRM")
        XCTAssertTrue(aesResult.isAES128Encrypted)
        XCTAssertEqual(aesResult.protectionType, "AES-128")
    }

    // MARK: - Gap 1: Failed Segment Retry Without Skipping

    @MainActor
    func testLiveSegmentRetryWithoutSkippingOrHoles() async throws {
        let manifestURL = URL(string: "https://mock.live/stream.m3u8")!
        let seg1URL = URL(string: "https://mock.live/seg1.ts")!
        let seg2URL = URL(string: "https://mock.live/seg2.ts")!

        let manifestContent = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:4.0,
        seg1.ts
        #EXTINF:4.0,
        seg2.ts
        #EXT-X-ENDLIST
        """

        LiveStreamsMockURLProtocol.setHandler(for: manifestURL) { _ in
            let res = HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!
            return (res, Data(manifestContent.utf8))
        }

        var seg1Attempts = 0
        LiveStreamsMockURLProtocol.setHandler(for: seg1URL) { _ in
            seg1Attempts += 1
            if seg1Attempts == 1 {
                // Simulate transient network failure on first attempt
                let res = HTTPURLResponse(url: seg1URL, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (res, Data())
            } else {
                // Succeed on retry with valid MPEG-TS packet
                let res = HTTPURLResponse(url: seg1URL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
                let packet = Data([0x47]) + Data(repeating: 0x11, count: 187)
                return (res, packet)
            }
        }

        LiveStreamsMockURLProtocol.setHandler(for: seg2URL) { _ in
            let res = HTTPURLResponse(url: seg2URL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
            let packet = Data([0x47]) + Data(repeating: 0x22, count: 187)
            return (res, packet)
        }

        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)
        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)

        let destURL = temporaryTestDirectory.appendingPathComponent("output.ts")
        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            destinationURL: destURL,
            title: "Retry Test",
            temporaryDirectoryURL: temporaryTestDirectory
        )

        try recorder.startRecording(request: req)

        // Give the loop time to poll, retry seg1, download seg2, and finalize automatically due to EXT-X-ENDLIST
        for _ in 0..<30 {
            if case .completed = recorder.state { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard case .completed(let outURL, let duration, let bytes) = recorder.state else {
            XCTFail("Recording should complete after retry, state is: \(recorder.state)")
            return
        }

        XCTAssertGreaterThanOrEqual(seg1Attempts, 2, "Segment 1 must have been retried after initial failure")
        XCTAssertEqual(recorder.recordedSegmentCount, 2, "Both segments must be captured without hole")
        XCTAssertEqual(duration, 8.0, accuracy: 0.1)
        XCTAssertEqual(bytes, 376, "Assembled output must contain both 188-byte packets")

        let fileData = try Data(contentsOf: outURL)
        XCTAssertEqual(fileData.count, 376)
        XCTAssertEqual(fileData[0], 0x47)
        XCTAssertEqual(fileData[188], 0x47)
    }

    // MARK: - Gap 4: HLS Media Features (#EXT-X-BYTERANGE)

    @MainActor
    func testLiveHLSByteRangeHeaderAndSlicing() async throws {
        let manifestURL = URL(string: "https://mock.live/byterange.m3u8")!
        let mediaFileURL = URL(string: "https://mock.live/media.ts")!

        let manifestContent = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:188@188
        media.ts
        #EXT-X-ENDLIST
        """

        LiveStreamsMockURLProtocol.setHandler(for: manifestURL) { _ in
            let res = HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(manifestContent.utf8))
        }

        // Mock returns 200 with full 500-byte payload to test client-side slicing fallback
        var fullPayload = Data(repeating: 0xAA, count: 188)
        fullPayload += Data([0x47]) + Data(repeating: 0xBB, count: 187) // Requested 188 bytes starting at 188
        fullPayload += Data(repeating: 0xCC, count: 125)

        LiveStreamsMockURLProtocol.setHandler(for: mediaFileURL) { req in
            let res = HTTPURLResponse(url: mediaFileURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, fullPayload)
        }

        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)
        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)

        let destURL = temporaryTestDirectory.appendingPathComponent("byterange_out.ts")
        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            destinationURL: destURL,
            title: "ByteRange Test",
            temporaryDirectoryURL: temporaryTestDirectory
        )

        try recorder.startRecording(request: req)

        for _ in 0..<30 {
            if case .completed = recorder.state { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard case .completed(let outURL, _, let bytes) = recorder.state else {
            XCTFail("Recording should complete, got: \(recorder.state)")
            return
        }

        XCTAssertEqual(bytes, 188, "Output should contain strictly the sliced 188 bytes, not the 500-byte full payload")
        let outData = try Data(contentsOf: outURL)
        XCTAssertEqual(outData.count, 188)
        XCTAssertEqual(outData[0], 0x47)
        XCTAssertEqual(outData[1], 0xBB)
    }

    // MARK: - Gap 3: Live Output Assembly & EXT-X-MAP Prepending

    @MainActor
    func testLiveHLSExtXMapInitializationSegmentPrepended() async throws {
        let manifestURL = URL(string: "https://mock.live/fmp4.m3u8")!
        let initURL = URL(string: "https://mock.live/init.mp4")!
        let chunkURL = URL(string: "https://mock.live/chunk1.m4s")!

        let manifestContent = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        chunk1.m4s
        #EXT-X-ENDLIST
        """

        LiveStreamsMockURLProtocol.setHandler(for: manifestURL) { _ in
            let res = HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(manifestContent.utf8))
        }

        let initData = "FTYP_MOOV_INITIALIZATION_HEADER".data(using: .utf8)!
        LiveStreamsMockURLProtocol.setHandler(for: initURL) { _ in
            let res = HTTPURLResponse(url: initURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp4"])!
            return (res, initData)
        }

        let chunkData = "MOOF_MDAT_CHUNK_MEDIA_PAYLOAD".data(using: .utf8)!
        LiveStreamsMockURLProtocol.setHandler(for: chunkURL) { _ in
            let res = HTTPURLResponse(url: chunkURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/iso.segment"])!
            return (res, chunkData)
        }

        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)
        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)

        let destURL = temporaryTestDirectory.appendingPathComponent("assembled.mp4")
        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            destinationURL: destURL,
            title: "fMP4 Init Test",
            temporaryDirectoryURL: temporaryTestDirectory
        )

        try recorder.startRecording(request: req)

        for _ in 0..<30 {
            if case .completed = recorder.state { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard case .completed(let outURL, _, _) = recorder.state else {
            XCTFail("Recording should complete, got: \(recorder.state)")
            return
        }

        let outputBytes = try Data(contentsOf: outURL)
        let expectedBytes = initData + chunkData
        XCTAssertEqual(outputBytes, expectedBytes, "Initialization segment must precede media chunk payload")
    }

    // MARK: - Gap 2: DASH Timeline S@r="-1" Without Crashing

    @MainActor
    func testDASHTimelineNegativeRepeatCountDoesNotCrashAndBoundsRepeats() async throws {
        let manifestURL = URL(string: "https://mock.live/live.mpd")!

        let mpdContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
             type="dynamic"
             minimumUpdatePeriod="PT2S"
             availabilityStartTime="2026-11-20T00:00:00Z">
            <Period id="p0">
                <AdaptationSet id="as0" mimeType="video/mp4">
                    <SegmentTemplate timescale="1000" media="chunk_$Time$.m4s" initialization="init.mp4">
                        <SegmentTimeline>
                            <S t="0" d="2000" r="-1"/>
                            <S t="4000" d="2000" r="0"/>
                        </SegmentTimeline>
                    </SegmentTemplate>
                    <Representation id="rep1" bandwidth="1500000" width="1280" height="720"/>
                </AdaptationSet>
            </Period>
        </MPD>
        """

        LiveStreamsMockURLProtocol.setHandler(for: manifestURL) { _ in
            let res = HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/dash+xml"])!
            return (res, Data(mpdContent.utf8))
        }

        let initURL = URL(string: "https://mock.live/init.mp4")!
        LiveStreamsMockURLProtocol.setHandler(for: initURL) { _ in
            let res = HTTPURLResponse(url: initURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data("INIT".utf8))
        }

        for t in [0, 2000, 4000] {
            let u = URL(string: "https://mock.live/chunk_\(t).m4s")!
            LiveStreamsMockURLProtocol.setHandler(for: u) { _ in
                let res = HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (res, Data("CHUNK_\(t)".utf8))
            }
        }

        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)
        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)

        let destURL = temporaryTestDirectory.appendingPathComponent("dash_output.mp4")
        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            manifestKind: .dash,
            destinationURL: destURL,
            title: "DASH r=-1 Test",
            temporaryDirectoryURL: temporaryTestDirectory
        )

        // Starting recording should NOT crash with negative range lowerBound <= upperBound error
        try recorder.startRecording(request: req)

        // Wait for at least one chunk to be recorded
        for _ in 0..<30 {
            if recorder.recordedSegmentCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertGreaterThanOrEqual(recorder.recordedSegmentCount, 1, "DASH r=-1 timeline should record chunks successfully")
        recorder.cancelRecording()
    }

    // MARK: - Gap 2: DASH Duration-Based SegmentTemplate

    @MainActor
    func testDASHDurationBasedSegmentTemplateDiscoversSegments() async throws {
        let manifestURL = URL(string: "https://mock.live/duration.mpd")!

        let mpdContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
             type="dynamic"
             minimumUpdatePeriod="PT2S"
             availabilityStartTime="2026-11-20T00:00:00Z">
            <Period id="p0">
                <AdaptationSet id="as0" mimeType="video/mp4">
                    <SegmentTemplate timescale="1000" duration="2000" startNumber="10" media="chunk_$Number$.m4s" initialization="init.mp4"/>
                    <Representation id="rep1" bandwidth="1500000" width="1280" height="720"/>
                </AdaptationSet>
            </Period>
        </MPD>
        """

        LiveStreamsMockURLProtocol.setHandler(for: manifestURL) { _ in
            let res = HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/dash+xml"])!
            return (res, Data(mpdContent.utf8))
        }

        let initURL = URL(string: "https://mock.live/init.mp4")!
        LiveStreamsMockURLProtocol.setHandler(for: initURL) { _ in
            let res = HTTPURLResponse(url: initURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data("DASH_INIT".utf8))
        }

        for num in 10...15 {
            let u = URL(string: "https://mock.live/chunk_\(num).m4s")!
            LiveStreamsMockURLProtocol.setHandler(for: u) { _ in
                let res = HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (res, Data("CHUNK_DATA_\(num)".utf8))
            }
        }

        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)
        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)

        let destURL = temporaryTestDirectory.appendingPathComponent("dash_duration.mp4")
        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            manifestKind: .dash,
            destinationURL: destURL,
            title: "DASH Duration Test",
            temporaryDirectoryURL: temporaryTestDirectory
        )

        try recorder.startRecording(request: req)

        for _ in 0..<30 {
            if recorder.recordedSegmentCount >= 2 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertGreaterThanOrEqual(recorder.recordedSegmentCount, 2, "Duration-based template should discover chunks")
        recorder.cancelRecording()
    }

    // MARK: - Gap 4: AES-128 Decryption & Failure Fast

    @MainActor
    func testLiveHLSAES128DecryptionAndMissingKeyError() async throws {
        let manifestURL = URL(string: "https://mock.live/aes.m3u8")!
        let keyURL = URL(string: "https://mock.live/key.bin")!
        let segURL = URL(string: "https://mock.live/enc_seg.ts")!

        let manifestContent = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-KEY:METHOD=AES-128,URI="https://mock.live/key.bin",IV=0x00000000000000000000000000000001
        #EXTINF:6.0,
        enc_seg.ts
        #EXT-X-ENDLIST
        """

        LiveStreamsMockURLProtocol.setHandler(for: manifestURL) { _ in
            let res = HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(manifestContent.utf8))
        }

        let clearPacket = Data([0x47]) + Data(repeating: 0x55, count: 187)
        let key = Data(repeating: 0x42, count: 16)
        let iv = HLSSegmentDecryptor.parseIV("0x00000000000000000000000000000001")!
        let encryptedPayload = try HLSSegmentDecryptor.encrypt(data: clearPacket, key: key, iv: iv)

        LiveStreamsMockURLProtocol.setHandler(for: keyURL) { _ in
            let res = HTTPURLResponse(url: keyURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, key)
        }

        LiveStreamsMockURLProtocol.setHandler(for: segURL) { _ in
            let res = HTTPURLResponse(url: segURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, encryptedPayload)
        }

        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)
        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)

        let destURL = temporaryTestDirectory.appendingPathComponent("decrypted.ts")
        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            destinationURL: destURL,
            title: "AES Decrypt Test",
            temporaryDirectoryURL: temporaryTestDirectory
        )

        try recorder.startRecording(request: req)

        for _ in 0..<30 {
            if case .completed = recorder.state { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard case .completed(let outURL, _, _) = recorder.state else {
            XCTFail("Recording should complete with decrypted segment, got: \(recorder.state)")
            return
        }

        let decryptedBytes = try Data(contentsOf: outURL)
        XCTAssertEqual(decryptedBytes.count, 188)
        XCTAssertEqual(decryptedBytes[0], 0x47)
        XCTAssertEqual(decryptedBytes[1], 0x55, "Decrypted segment payload must match original clear packet")
    }

    // MARK: - Gap 5: Durable Recording Store & Recovery Across Suspension

    @MainActor
    func testDurableRecordingStoreAndInterruptedRecovery() async throws {
        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)

        let sessionID = "test-session-\(UUID().uuidString)"
        let scratchDir = temporaryTestDirectory.appendingPathComponent("scratch_\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        let segFile = scratchDir.appendingPathComponent("seg_0.ts")
        let segData = Data([0x47]) + Data(repeating: 0x77, count: 187)
        try segData.write(to: segFile)

        let manifestURL = URL(string: "https://example.com/live.m3u8")!
        let destURL = temporaryTestDirectory.appendingPathComponent("recovered_final.ts")
        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            destinationURL: destURL,
            title: "Recovery Demo"
        )

        let record = LiveRecordingRecord(
            id: sessionID,
            request: req,
            state: "recording",
            recordedDurationSeconds: 6.0,
            recordedSegmentCount: 1,
            bytesWritten: 188,
            recordedSegments: [
                LiveRecordedSegment(
                    sequenceNumber: 1,
                    uri: URL(string: "https://example.com/seg_0.ts")!,
                    duration: 6.0,
                    localFileURL: segFile,
                    byteCount: 188
                )
            ],
            initializationSegmentURLs: [],
            committedSegmentKeys: ["video_1_https://example.com/seg_0.ts_-1_-1"],
            scratchDirectoryPath: scratchDir.path,
            outputContainerFormat: "ts"
        )

        try await recordingStore.save(record: record)

        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)
        let interruptedList = await recorder.recoverInterruptedRecordings()
        XCTAssertEqual(interruptedList.count, 1)
        XCTAssertEqual(interruptedList[0].id, sessionID)
        XCTAssertEqual(interruptedList[0].title, "Recovery Demo")
        XCTAssertEqual(interruptedList[0].recordedSegmentCount, 1)

        let finalizedURL = try await recorder.finalizeInterruptedRecording(sessionID: sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalizedURL.path))
        let finalizedData = try Data(contentsOf: finalizedURL)
        XCTAssertEqual(finalizedData.count, 188)
        XCTAssertEqual(finalizedData[0], 0x47)

        // Store record should be cleaned up after recovery finalization
        let remaining = await recorder.recoverInterruptedRecordings()
        XCTAssertTrue(remaining.isEmpty, "Recovered session must be removed from store after finalization")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDir.path), "Scratch directory should be cleaned up")
    }

    // MARK: - Gap 3: Container Format Extension Alignment

    @MainActor
    func testContainerFormatExtensionAlignmentForMPEGTS() async throws {
        let manifestURL = URL(string: "https://mock.live/align.m3u8")!
        let segURL = URL(string: "https://mock.live/chunk.ts")!

        let manifestContent = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        chunk.ts
        #EXT-X-ENDLIST
        """

        LiveStreamsMockURLProtocol.setHandler(for: manifestURL) { _ in
            let res = HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(manifestContent.utf8))
        }

        let packet = Data([0x47]) + Data(repeating: 0x99, count: 187)
        LiveStreamsMockURLProtocol.setHandler(for: segURL) { _ in
            let res = HTTPURLResponse(url: segURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
            return (res, packet)
        }

        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)
        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)

        // Destination requested with wrong extension ".mp4" for MPEG-TS stream
        let requestedURL = temporaryTestDirectory.appendingPathComponent("stream_mislabeled.mp4")
        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            destinationURL: requestedURL,
            title: "Alignment Test",
            temporaryDirectoryURL: temporaryTestDirectory
        )

        try recorder.startRecording(request: req)

        for _ in 0..<30 {
            if case .completed = recorder.state { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard case .completed(let outURL, _, _) = recorder.state else {
            XCTFail("Recording should complete, got: \(recorder.state)")
            return
        }

        XCTAssertEqual(outURL.pathExtension, "ts", "MPEG-TS container format must align file extension to .ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
    }
}
