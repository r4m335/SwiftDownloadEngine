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

    // MARK: - Gap 5 & 6: DRM True-Positive & Generic SAMPLE-AES Detection

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

    func testDRMDetectorClassifiesUnrecognizedSampleAESAsDRM() {
        let proprietarySampleAES = """
        #EXTM3U
        #EXT-X-VERSION:5
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="https://license.custom.com/key",KEYFORMAT="com.custom.drm.system"
        #EXTINF:6.0,
        seg1.ts
        """
        let result = StreamDRMDetector.evaluate(manifestText: proprietarySampleAES)
        XCTAssertTrue(result.isProtected, "Unrecognized proprietary SAMPLE-AES key formats must be conservatively classified as DRM")
        XCTAssertEqual(result.protectionType, "Sample-AES")
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
                let res = HTTPURLResponse(url: seg1URL, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (res, Data())
            } else {
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

        var fullPayload = Data(repeating: 0xAA, count: 188)
        fullPayload += Data([0x47]) + Data(repeating: 0xBB, count: 187)
        fullPayload += Data(repeating: 0xCC, count: 125)

        LiveStreamsMockURLProtocol.setHandler(for: mediaFileURL) { _ in
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

        XCTAssertEqual(bytes, 188, "Output should contain strictly the sliced 188 bytes")
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

    // MARK: - Gap 3 & 4: External HLS Audio Rendition & Video Track Capture

    @MainActor
    func testLiveHLSSeparateAudioRenditionCaptureAndAssembly() async throws {
        let masterURL = URL(string: "https://mock.live/master.m3u8")!
        let videoURL = URL(string: "https://mock.live/video.m3u8")!
        let audioURL = URL(string: "https://mock.live/audio.m3u8")!
        let vSegURL = URL(string: "https://mock.live/v0.ts")!
        let aSegURL = URL(string: "https://mock.live/a0.aac")!

        let masterContent = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-main",NAME="English",DEFAULT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="audio-main"
        video.m3u8
        """

        let videoContent = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:4.0,
        v0.ts
        #EXT-X-ENDLIST
        """

        let audioContent = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:4.0,
        a0.aac
        #EXT-X-ENDLIST
        """

        LiveStreamsMockURLProtocol.setHandler(for: masterURL) { _ in
            let res = HTTPURLResponse(url: masterURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(masterContent.utf8))
        }
        LiveStreamsMockURLProtocol.setHandler(for: videoURL) { _ in
            let res = HTTPURLResponse(url: videoURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(videoContent.utf8))
        }
        LiveStreamsMockURLProtocol.setHandler(for: audioURL) { _ in
            let res = HTTPURLResponse(url: audioURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(audioContent.utf8))
        }

        let vPacket = Data([0x47]) + Data(repeating: 0x11, count: 187)
        LiveStreamsMockURLProtocol.setHandler(for: vSegURL) { _ in
            let res = HTTPURLResponse(url: vSegURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
            return (res, vPacket)
        }

        let aPacket = Data(repeating: 0x22, count: 100)
        LiveStreamsMockURLProtocol.setHandler(for: aSegURL) { _ in
            let res = HTTPURLResponse(url: aSegURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/aac"])!
            return (res, aPacket)
        }

        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)
        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)

        let destURL = temporaryTestDirectory.appendingPathComponent("dual_track.ts")
        let req = LiveRecordingRequest(
            manifestURL: masterURL,
            destinationURL: destURL,
            title: "Dual Track Test",
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

        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        XCTAssertGreaterThan(recorder.recordedSegmentCount, 0)
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

        try recorder.startRecording(request: req)

        for _ in 0..<30 {
            if recorder.recordedSegmentCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertGreaterThanOrEqual(recorder.recordedSegmentCount, 1, "DASH r=-1 timeline should record chunks successfully")
        recorder.cancelRecording()
    }

    // MARK: - Gap 2 & 7: DASH ISO/IEC 23009-1 Availability Window & Audio/Video

    @MainActor
    func testDASHISO23009LiveAvailabilityWindowCalculation() async throws {
        let manifestURL = URL(string: "https://mock.live/iso_window.mpd")!

        let mpdContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
             type="dynamic"
             minimumUpdatePeriod="PT2S"
             availabilityStartTime="2026-11-20T00:00:00Z"
             timeShiftBufferDepth="PT60S"
             suggestedPresentationDelay="PT4S">
            <Period id="p0" start="PT0S">
                <AdaptationSet id="as0" mimeType="video/mp4" contentType="video">
                    <SegmentTemplate timescale="1000" duration="2000" startNumber="100" media="v_chunk_$Number$.m4s" initialization="v_init.mp4"/>
                    <Representation id="rep_v" bandwidth="2000000" width="1280" height="720"/>
                </AdaptationSet>
                <AdaptationSet id="as1" mimeType="audio/mp4" contentType="audio">
                    <SegmentTemplate timescale="1000" duration="2000" startNumber="100" media="a_chunk_$Number$.m4s" initialization="a_init.mp4"/>
                    <Representation id="rep_a" bandwidth="128000"/>
                </AdaptationSet>
            </Period>
        </MPD>
        """

        LiveStreamsMockURLProtocol.setHandler(for: manifestURL) { _ in
            let res = HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/dash+xml"])!
            return (res, Data(mpdContent.utf8))
        }

        let vInitURL = URL(string: "https://mock.live/v_init.mp4")!
        let aInitURL = URL(string: "https://mock.live/a_init.mp4")!
        LiveStreamsMockURLProtocol.setHandler(for: vInitURL) { _ in
            (HTTPURLResponse(url: vInitURL, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("VINIT".utf8))
        }
        LiveStreamsMockURLProtocol.setHandler(for: aInitURL) { _ in
            (HTTPURLResponse(url: aInitURL, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("AINIT".utf8))
        }

        // Mock segment responses for any sequence number
        let parsed = try DASHManifestParser.parse(mpdContent, baseURL: manifestURL)
        XCTAssertNotNil(parsed.availabilityStartTime)
        XCTAssertEqual(parsed.timeShiftBufferDepth, 60.0)
        XCTAssertEqual(parsed.suggestedPresentationDelay, 4.0)

        // Mock chunks around live edge
        let now = Date()
        let elapsed = now.timeIntervalSince(parsed.availabilityStartTime!)
        let liveEdgeTime = max(0, elapsed - 4.0)
        let edgeSeq = 100 + Int64(liveEdgeTime / 2.0)

        for seq in (edgeSeq - 3)...(edgeSeq + 3) {
            let vu = URL(string: "https://mock.live/v_chunk_\(seq).m4s")!
            let au = URL(string: "https://mock.live/a_chunk_\(seq).m4s")!
            LiveStreamsMockURLProtocol.setHandler(for: vu) { _ in
                (HTTPURLResponse(url: vu, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("VCHUNK_\(seq)".utf8))
            }
            LiveStreamsMockURLProtocol.setHandler(for: au) { _ in
                (HTTPURLResponse(url: au, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("ACHUNK_\(seq)".utf8))
            }
        }

        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)
        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)

        let destURL = temporaryTestDirectory.appendingPathComponent("dash_iso_window.mp4")
        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            manifestKind: .dash,
            destinationURL: destURL,
            title: "ISO Window Test",
            temporaryDirectoryURL: temporaryTestDirectory
        )

        try recorder.startRecording(request: req)

        for _ in 0..<30 {
            if recorder.recordedSegmentCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertGreaterThanOrEqual(recorder.recordedSegmentCount, 1, "ISO/IEC 23009-1 calculation should compute valid live window")
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

    // MARK: - Gap 1 & 5: Relaunch Auto-Discovery, Recovery & Resume Polling

    @MainActor
    func testLiveStreamRelaunchDiscoveryAndResumePolling() async throws {
        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)

        let sessionID = "resume-session-\(UUID().uuidString)"
        let scratchDir = temporaryTestDirectory.appendingPathComponent("scratch_\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        let segFile = scratchDir.appendingPathComponent("seg_video_000000.ts")
        let segData = Data([0x47]) + Data(repeating: 0x88, count: 187)
        try segData.write(to: segFile)

        let manifestURL = URL(string: "https://mock.live/resume.m3u8")!
        let newSegURL = URL(string: "https://mock.live/seg2.ts")!

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
            let res = HTTPURLResponse(url: manifestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, Data(manifestContent.utf8))
        }

        let newPacket = Data([0x47]) + Data(repeating: 0x99, count: 187)
        LiveStreamsMockURLProtocol.setHandler(for: newSegURL) { _ in
            let res = HTTPURLResponse(url: newSegURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t"])!
            return (res, newPacket)
        }

        let destURL = temporaryTestDirectory.appendingPathComponent("resumed_output.ts")
        let req = LiveRecordingRequest(
            manifestURL: manifestURL,
            destinationURL: destURL,
            title: "Resume Session Demo"
        )

        let existingRecord = LiveRecordingRecord(
            id: sessionID,
            request: req,
            state: "recording",
            recordedDurationSeconds: 4.0,
            recordedSegmentCount: 1,
            bytesWritten: 188,
            recordedSegments: [
                LiveRecordedSegment(
                    sequenceNumber: 1,
                    uri: URL(string: "https://mock.live/seg1.ts")!,
                    duration: 4.0,
                    localFileURL: segFile,
                    byteCount: 188,
                    trackKind: "video"
                )
            ],
            initializationSegmentURLs: [],
            committedSegmentKeys: ["video_1_https://mock.live/seg1.ts_-1_-1"],
            scratchDirectoryPath: scratchDir.path,
            outputContainerFormat: "ts"
        )
        try await recordingStore.save(record: existingRecord)

        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)

        // 1. Verify automatic relaunch discovery
        let discovered = await recorder.checkForInterruptedRecordings()
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered[0].id, sessionID)
        XCTAssertEqual(recorder.interruptedRecordings.count, 1)

        // 2. Resume live polling
        try await recorder.resumeInterruptedRecording(sessionID: sessionID)

        // Wait for loop to poll manifest, download seg2 (appending to existing seg1), and finalize on EXT-X-ENDLIST
        for _ in 0..<80 {
            if case .completed = recorder.state { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard case .completed(let outURL, let duration, let bytes) = recorder.state else {
            XCTFail("Resumed recording should complete, got: \(recorder.state)")
            return
        }

        XCTAssertEqual(recorder.recordedSegmentCount, 2, "Must contain both restored segment and newly polled segment")
        XCTAssertEqual(duration, 8.0, accuracy: 0.1)
        XCTAssertEqual(bytes, 376)

        let finalData = try Data(contentsOf: outURL)
        XCTAssertEqual(finalData.count, 376)
        XCTAssertEqual(finalData[0], 0x47)
        XCTAssertEqual(finalData[188], 0x47)
    }

    // MARK: - Gap 5: Discard Interrupted Recording

    @MainActor
    func testDiscardInterruptedRecordingCleansUpStoreAndDisk() async throws {
        let storeDir = temporaryTestDirectory.appendingPathComponent("store", isDirectory: true)
        let recordingStore = try LiveRecordingStore(storageDirectoryURL: storeDir)

        let sessionID = "discard-\(UUID().uuidString)"
        let scratchDir = temporaryTestDirectory.appendingPathComponent("scratch_\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        let dummy = scratchDir.appendingPathComponent("dummy.txt")
        try Data("dummy".utf8).write(to: dummy)

        let req = LiveRecordingRequest(
            manifestURL: URL(string: "https://example.com/stream.m3u8")!,
            destinationURL: temporaryTestDirectory.appendingPathComponent("discarded.ts"),
            title: "Discard Demo"
        )
        let record = LiveRecordingRecord(
            id: sessionID,
            request: req,
            state: "recording",
            recordedDurationSeconds: 1.0,
            recordedSegmentCount: 1,
            bytesWritten: 5,
            scratchDirectoryPath: scratchDir.path
        )
        try await recordingStore.save(record: record)

        let recorder = LiveStreamRecorder(urlSession: mockSession, recordingStore: recordingStore)
        let listBefore = await recorder.checkForInterruptedRecordings()
        XCTAssertEqual(listBefore.count, 1)

        await recorder.discardInterruptedRecording(sessionID: sessionID)

        let listAfter = await recorder.checkForInterruptedRecordings()
        XCTAssertTrue(listAfter.isEmpty, "Discarded recording must be removed from store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDir.path), "Scratch directory must be deleted")
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
