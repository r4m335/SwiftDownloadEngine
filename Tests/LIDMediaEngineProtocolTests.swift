import XCTest
@testable import DownloadEngineKit

final class LIDMediaEngineProtocolTests: XCTestCase {

    func testBackendTypeEnum() {
        XCTAssertEqual(LIDMediaEngineBackendType.vlcKit.rawValue, "VLCKit")
        XCTAssertEqual(LIDMediaEngineBackendType.avFoundation.rawValue, "AVFoundation")
        XCTAssertEqual(LIDMediaEngineBackendType.vlcKit.displayName, "VLCKit (libVLC)")
        XCTAssertEqual(LIDMediaEngineBackendType.avFoundation.displayName, "AVFoundation (Native)")
    }

    @MainActor
    func testBackendRoutingDecisions() {
        let engine = LIDPlaybackEngine()

        // Local media files (especially TS, MKV, AVI, etc.) MUST route to VLCKit
        let tsURL = URL(fileURLWithPath: "/tmp/sample.ts")
        let tsSource = LIDPlayerSource.localFile(url: tsURL, title: "Test TS")
        XCTAssertEqual(engine.selectBackend(for: tsSource), .vlcKit)

        let mkvURL = URL(fileURLWithPath: "/tmp/movie.mkv")
        let mkvSource = LIDPlayerSource.localFile(url: mkvURL, title: "Movie MKV")
        XCTAssertEqual(engine.selectBackend(for: mkvSource), .vlcKit)

        let aviURL = URL(fileURLWithPath: "/tmp/video.avi")
        let aviSource = LIDPlayerSource.localFile(url: aviURL, title: "Video AVI")
        XCTAssertEqual(engine.selectBackend(for: aviSource), .vlcKit)

        let mp4URL = URL(fileURLWithPath: "/tmp/clip.mp4")
        let mp4Source = LIDPlayerSource.localFile(url: mp4URL, title: "Clip MP4")
        XCTAssertEqual(engine.selectBackend(for: mp4Source), .vlcKit)

        // Native HLS manifests MUST route to AVFoundation
        let hlsURL = URL(string: "https://example.com/live/master.m3u8")!
        let hlsSource = LIDPlayerSource.hlsStream(url: hlsURL, variantPreferences: nil, title: "Live HLS")
        XCTAssertEqual(engine.selectBackend(for: hlsSource), .avFoundation)

        // BitTorrent swarm streaming MUST route to AVFoundation adapter initially
        let torrentSource = LIDPlayerSource.torrentSwarm(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: 0, title: "Torrent Stream")
        XCTAssertEqual(engine.selectBackend(for: torrentSource), .avFoundation)

        // DASH manifests route to VLCKit
        let dashURL = URL(string: "https://example.com/dash/manifest.mpd")!
        let dashSource = LIDPlayerSource.dashStream(manifestURL: dashURL, title: "DASH Video")
        XCTAssertEqual(engine.selectBackend(for: dashSource), .vlcKit)
    }

    @MainActor
    func testVLCKitBackendStubOperations() {
        final class FailSpy: LIDMediaEngineDelegate {
            var lastError: String?
            var states: [LIDPlaybackState] = []
            func engineDidUpdateState(_ engine: LIDMediaEngineProtocol, state: LIDPlaybackState) { states.append(state) }
            func engineDidUpdateTime(_ engine: LIDMediaEngineProtocol, currentSeconds: Double, durationSeconds: Double) {}
            func engineDidUpdateBuffering(_ engine: LIDMediaEngineProtocol, bufferedSeconds: Double) {}
            func engineDidUpdateMetadata(_ engine: LIDMediaEngineProtocol, metadata: LIDMediaMetadata) {}
            func engineDidFail(_ engine: LIDMediaEngineProtocol, error: String) { lastError = error }
        }

        let backend = LIDVLCKitBackend()
        let spy = FailSpy()
        backend.delegate = spy
        XCTAssertEqual(backend.backendType, .vlcKit)
        XCTAssertEqual(backend.playbackState, .idle)

        let dummySource = LIDPlayerSource.localFile(url: URL(fileURLWithPath: "/tmp/test.ts"), title: "Test")
        backend.load(source: dummySource, autoPlay: false)
        XCTAssertEqual(backend.playbackState, .failed(LIDVLCKitBackend.unavailableMessage))
        XCTAssertEqual(spy.lastError, LIDVLCKitBackend.unavailableMessage)

        backend.play()
        XCTAssertEqual(backend.playbackState, .failed(LIDVLCKitBackend.unavailableMessage))

        backend.seek(to: 42.0)
        XCTAssertEqual(backend.currentPositionSeconds, 42.0)

        backend.playbackSpeed = .speed2_00
        XCTAssertEqual(backend.playbackSpeed, .speed2_00)

        backend.volume = 0.8
        XCTAssertEqual(backend.volume, 0.8)

        backend.isMuted = true
        XCTAssertTrue(backend.isMuted)

        backend.stop()
        XCTAssertEqual(backend.playbackState, .idle)
    }

    @MainActor
    func testControllerDelegateHandling() {
        let engine = LIDPlaybackEngine()
        XCTAssertEqual(engine.playbackState, .idle)

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("sample_\(UUID().uuidString).ts")
        var tsData = Data([0x47])
        tsData.append(contentsOf: Array(repeating: UInt8(0x00), count: 187))
        tsData.append(0x47)
        try? tsData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let testSource = LIDPlayerSource.localFile(url: tempFile, title: "Sample")
        engine.load(source: testSource, autoPlay: false, resumeFromHistory: false)
        XCTAssertEqual(engine.activeBackendType, .vlcKit)

        // Simulate delegate events from active backend
        engine.engineDidUpdateState(engine.vlcBackend, state: .playing)
        XCTAssertEqual(engine.playbackState, .playing)

        engine.engineDidUpdateTime(engine.vlcBackend, currentSeconds: 15.5, durationSeconds: 120.0)
        XCTAssertEqual(engine.currentPositionSeconds, 15.5)
        XCTAssertEqual(engine.durationSeconds, 120.0)

        engine.engineDidUpdateBuffering(engine.vlcBackend, bufferedSeconds: 45.0)
        XCTAssertEqual(engine.bufferedDurationSeconds, 45.0)

        engine.engineDidFail(engine.vlcBackend, error: "Decoder initialization failure")
        XCTAssertEqual(engine.playbackState, .failed(error: "Decoder initialization failure"))

        engine.stop()
        XCTAssertEqual(engine.playbackState, .idle)
    }

    func testMPEGTSHeaderSyncValidation() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let validTS = tempDir.appendingPathComponent("valid_\(UUID().uuidString).ts")
        let invalidTS = tempDir.appendingPathComponent("invalid_\(UUID().uuidString).ts")

        defer {
            try? FileManager.default.removeItem(at: validTS)
            try? FileManager.default.removeItem(at: invalidTS)
        }

        // Standard MPEG-TS packet starts with 0x47
        var validData = Data([0x47])
        validData.append(contentsOf: Array(repeating: UInt8(0x00), count: 187))
        try validData.write(to: validTS)

        // Invalid packet (e.g. MP4 ftyp or corrupted file)
        var invalidData = Data([0x00, 0x00, 0x00, 0x20])
        invalidData.append(Data("ftypisom".utf8))
        try invalidData.write(to: invalidTS)

        XCTAssertTrue(LIDPlaybackEngine.validateTSHeader(url: validTS))
        XCTAssertFalse(LIDPlaybackEngine.validateTSHeader(url: invalidTS))
    }
}
