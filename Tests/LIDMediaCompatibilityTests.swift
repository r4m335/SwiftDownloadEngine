import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class LIDMediaCompatibilityTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LIDMediaTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - 1. Target Format Routing & Media Classification Tests

    func testAllTargetMediaFormatsRouteToVLCKit() async {
        await MainActor.run {
            let engine = LIDPlaybackEngine()

            // 16 target video & audio formats from Milestone A.6 roadmap
            let targetFormats = [
                "mp4", "mkv", "ts", "mov", "avi", "webm", "flv", "mpg",
                "mpeg", "m4v", "3gp", "ogg", "ogv", "wmv", "asf", "vob",
                "mp3", "flac", "aac", "wav", "m4a", "opus"
            ]

            for ext in targetFormats {
                let fileURL = tempDirectory.appendingPathComponent("sample.\(ext)")
                let source = LIDPlayerSource.localFile(url: fileURL, title: "Sample \(ext.uppercased())")

                let selectedBackend = engine.selectBackend(for: source)
                XCTAssertEqual(
                    selectedBackend,
                    .vlcKit,
                    "Format .\(ext) should route to VLCKit for universal playback."
                )
                XCTAssertTrue(
                    fileURL.isPlayableMedia,
                    "Format .\(ext) must be recognized as playable media."
                )
            }
        }
    }

    func testNativeStreamingSourcesRouteToAVFoundation() async {
        await MainActor.run {
            let engine = LIDPlaybackEngine()

            // Native HLS streams
            let hlsURL = URL(string: "https://example.com/live/master.m3u8")!
            let hlsSource = LIDPlayerSource.hlsStream(url: hlsURL, variantPreferences: nil, title: "Master HLS")
            XCTAssertEqual(engine.selectBackend(for: hlsSource), .avFoundation)

            // BitTorrent swarm streaming
            let torrentSource = LIDPlayerSource.torrentSwarm(
                infoHash: "0123456789abcdef0123456789abcdef01234567",
                fileIndex: 0,
                title: "Torrent Stream"
            )
            XCTAssertEqual(engine.selectBackend(for: torrentSource), .avFoundation)
        }
    }

    func testDASHAndDirectNetworkStreamsRouteToVLCKit() async {
        await MainActor.run {
            let engine = LIDPlaybackEngine()

            let dashURL = URL(string: "https://example.com/dash/vod.mpd")!
            let dashSource = LIDPlayerSource.dashStream(manifestURL: dashURL, title: "DASH VOD")
            XCTAssertEqual(engine.selectBackend(for: dashSource), .vlcKit)

            let httpURL = URL(string: "https://example.com/live/stream.flv")!
            let netSource = LIDPlayerSource.networkStream(url: httpURL, headers: [:], title: "Network FLV")
            XCTAssertEqual(engine.selectBackend(for: netSource), .vlcKit)
        }
    }

    // MARK: - 2. MPEG-TS Sync Header Validation

    func testMPEGTSHeaderSyncValidationComprehensive() {
        // 1. Valid 188-byte packet starting with 0x47
        let validTSURL = tempDirectory.appendingPathComponent("valid_single.ts")
        var validPacket = Data([0x47])
        validPacket.append(contentsOf: Array(repeating: UInt8(0x00), count: 187))
        try? validPacket.write(to: validTSURL)
        XCTAssertTrue(LIDPlaybackEngine.validateTSHeader(url: validTSURL))

        // 2. Multi-packet valid TS (3 packets * 188 bytes)
        let validMultiTSURL = tempDirectory.appendingPathComponent("valid_multi.ts")
        var multiPacket = Data()
        for i in 0..<3 {
            multiPacket.append(0x47)
            multiPacket.append(contentsOf: Array(repeating: UInt8(i), count: 187))
        }
        try? multiPacket.write(to: validMultiTSURL)
        XCTAssertTrue(LIDPlaybackEngine.validateTSHeader(url: validMultiTSURL))

        // 3. Invalid packet starting with 0x00 (e.g. MP4 ftyp or random data)
        let invalidTSURL = tempDirectory.appendingPathComponent("invalid.ts")
        let invalidData = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        try? invalidData.write(to: invalidTSURL)
        XCTAssertFalse(LIDPlaybackEngine.validateTSHeader(url: invalidTSURL))

        // 4. Empty file (0 bytes)
        let emptyTSURL = tempDirectory.appendingPathComponent("empty.ts")
        try? Data().write(to: emptyTSURL)
        XCTAssertFalse(LIDPlaybackEngine.validateTSHeader(url: emptyTSURL))

        // 5. Non-existent file
        let nonExistentURL = tempDirectory.appendingPathComponent("does_not_exist.ts")
        XCTAssertFalse(LIDPlaybackEngine.validateTSHeader(url: nonExistentURL))

        // 6. Valid TS with prepended ID3v2 metadata header (standard HLS segment pattern)
        let id3TSURL = tempDirectory.appendingPathComponent("id3_prefixed.ts")
        // "ID3" + version 4.0 + flags 0x00 + 4 synchsafe size bytes representing 4 bytes payload
        var id3Data = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04])
        id3Data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // 4 bytes ID3 tag body
        id3Data.append(0x47) // First TS sync byte at offset 14
        id3Data.append(contentsOf: Array(repeating: UInt8(0xAA), count: 187)) // Rest of TS packet
        try? id3Data.write(to: id3TSURL)
        XCTAssertTrue(LIDPlaybackEngine.validateTSHeader(url: id3TSURL))
    }

    // MARK: - 3. Empty File and Corrupted Media Error Handling

    func testEmptyMediaFileLoadsAsFailedImmediately() async {
        let emptyFileURL = tempDirectory.appendingPathComponent("zero_byte.mp4")
        try? Data().write(to: emptyFileURL)

        await MainActor.run {
            let engine = LIDPlaybackEngine()
            let source = LIDPlayerSource.localFile(url: emptyFileURL, title: "Empty Video")
            engine.load(source: source, autoPlay: false, resumeFromHistory: false)

            guard case .failed(let error) = engine.playbackState else {
                XCTFail("Expected playbackState to be .failed, got \(engine.playbackState)")
                return
            }
            XCTAssertTrue(error.contains("empty") || error.contains("0 bytes"))
        }
    }

    func testNonExistentFileResilience() async {
        let missingURL = tempDirectory.appendingPathComponent("ghost_file.mkv")
        let source = LIDPlayerSource.localFile(url: missingURL, title: "Ghost File")

        await MainActor.run {
            let engine = LIDPlaybackEngine()
            engine.load(source: source, autoPlay: false, resumeFromHistory: false)
            XCTAssertEqual(engine.activeBackendType, .vlcKit)
            engine.stop()
            XCTAssertEqual(engine.playbackState, .idle)
        }
    }

    // MARK: - 4. Playback Controls & Replay Lifecycle

    func testFullPlaybackLifecycleAndReplay() async {
        let testFileURL = tempDirectory.appendingPathComponent("test_playback.ts")
        var data = Data([0x47])
        data.append(contentsOf: Array(repeating: UInt8(0x01), count: 187))
        try? data.write(to: testFileURL)

        await MainActor.run {
            let engine = LIDPlaybackEngine()
            let source = LIDPlayerSource.localFile(url: testFileURL, title: "Lifecycle TS")
            engine.load(source: source, autoPlay: false, resumeFromHistory: false)
            XCTAssertEqual(engine.activeBackendType, .vlcKit)

            // Simulate playing
            engine.play()
            engine.engineDidUpdateState(engine.vlcBackend, state: .playing)
            XCTAssertEqual(engine.playbackState, .playing)

            // Position & duration updates
            engine.engineDidUpdateTime(engine.vlcBackend, currentSeconds: 50.0, durationSeconds: 100.0)
            XCTAssertEqual(engine.currentPositionSeconds, 50.0)
            XCTAssertEqual(engine.durationSeconds, 100.0)

            // Pause
            engine.pause()
            engine.engineDidUpdateState(engine.vlcBackend, state: .paused)
            XCTAssertEqual(engine.playbackState, .paused)

            // Seek
            engine.seek(to: 75.0)
            XCTAssertEqual(engine.currentPositionSeconds, 75.0)

            // Simulate playback completion (ended)
            engine.engineDidUpdateState(engine.vlcBackend, state: .ended)
            XCTAssertEqual(engine.playbackState, .ended)

            // Replay: resets position to 0 and starts playing
            engine.replay()
            XCTAssertEqual(engine.currentPositionSeconds, 0.0)

            // Stop: resets to idle
            engine.stop()
            XCTAssertEqual(engine.playbackState, .idle)
        }
    }

    // MARK: - 5. Playback Speed & Temporary 2x Boost

    func testPlaybackSpeedAndBoost() async {
        await MainActor.run {
            let engine = LIDPlaybackEngine()

            let speeds: [LIDPlaybackSpeed] = [
                .speed0_50, .speed0_75, .speed1_00, .speed1_25, .speed1_50, .speed2_00
            ]

            for speed in speeds {
                engine.setPlaybackSpeed(speed)
                XCTAssertEqual(engine.playbackSpeed, speed)
                XCTAssertEqual(engine.playbackSpeed.rate, Float(speed.rawValue))
            }

            // Test temporary 2x boost toggle
            engine.setPlaybackSpeed(.speed1_00)
            engine.setPlaybackSpeed(.speed2_00)
            XCTAssertEqual(engine.playbackSpeed.rate, 2.0)
            engine.setPlaybackSpeed(.speed1_00)
            XCTAssertEqual(engine.playbackSpeed.rate, 1.0)
        }
    }

    // MARK: - 6. Aspect Ratio Controls

    func testAspectRatioSwitching() async {
        await MainActor.run {
            let engine = LIDPlaybackEngine()

            let ratios: [LIDAspectRatio] = [
                .original, .fit16x9, .fit4x3, .fill, .stretch
            ]

            for ratio in ratios {
                engine.setAspectRatio(ratio)
                XCTAssertEqual(engine.aspectRatio, ratio)
                XCTAssertFalse(ratio.displayName.isEmpty)
            }
        }
    }

    // MARK: - 7. Picture-in-Picture Capability Invariant

    func testPictureInPictureCapabilityInvariant() async {
        await MainActor.run {
            let engine = LIDPlaybackEngine()

            // VLCKit backend must NOT claim PiP support on iOS
            let vlcBackend = LIDVLCKitBackend()
            XCTAssertFalse(vlcBackend.supportsPictureInPicture)

            // When VLC backend is active, engine must report supportsPictureInPicture == false
            let dummyLocal = LIDPlayerSource.localFile(url: URL(fileURLWithPath: "/tmp/sample.mkv"), title: "MKV")
            engine.load(source: dummyLocal, autoPlay: false, resumeFromHistory: false)
            XCTAssertFalse(engine.supportsPictureInPicture)
        }
    }

    // MARK: - 8. Audio and Subtitle Track Synchronization

    func testTrackManagerAudioAndSubtitleHandling() async {
        await MainActor.run {
            let engine = LIDPlaybackEngine()

            let audio1 = LIDAudioTrack(id: "1", displayName: "English", languageCode: "en", isDefault: true)
            let audio2 = LIDAudioTrack(id: "2", displayName: "Spanish (Dub)", languageCode: "es", isDefault: false)

            let sub1 = LIDSubtitleTrack(id: "101", displayName: "English Subtitles", languageCode: "en")
            let sub2 = LIDSubtitleTrack(id: "102", displayName: "French Subtitles", languageCode: "fr")

            engine.trackManager.updateAvailableTracks(
                audioTracks: [audio1, audio2],
                subtitleTracks: [sub1, sub2]
            )

            XCTAssertEqual(engine.trackManager.availableAudioTracks.count, 2)
            XCTAssertEqual(engine.trackManager.availableSubtitleTracks.count, 3) // includes .off sentinel

            // Select audio track
            engine.selectAudioTrack(audio2)
            XCTAssertEqual(engine.trackManager.selectedAudioTrack?.id, "2")

            // Select subtitle track
            engine.selectSubtitleTrack(sub2)
            XCTAssertEqual(engine.trackManager.selectedSubtitleTrack.id, "102")

            // Subtitle delay offsets
            engine.setSubtitleDelay(seconds: 1.5)
            XCTAssertEqual(engine.subtitleDelay, 1.5)

            engine.setSubtitleDelay(seconds: -0.5)
            XCTAssertEqual(engine.subtitleDelay, -0.5)
        }
    }

    // MARK: - 9. External Subtitle Cue Parsing

    func testExternalSubtitleVTTAndSRTParsing() {
        let vttContent = """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        Welcome to the universal player test.

        00:00:05.000 --> 00:00:08.500
        Testing subtitle rendering and synchronization.
        """

        let parser = LIDSubtitleParser()
        let cues = parser.parse(string: vttContent)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startTime, 1.0)
        XCTAssertEqual(cues[0].endTime, 4.0)
        XCTAssertEqual(cues[0].text, "Welcome to the universal player test.")

        XCTAssertEqual(cues[1].startTime, 5.0)
        XCTAssertEqual(cues[1].endTime, 8.5)
        XCTAssertEqual(cues[1].text, "Testing subtitle rendering and synchronization.")
    }

    // MARK: - 10. Playback History Persistence

    func testPlaybackHistoryStorePersistence() async {
        let store = LIDPlaybackHistoryStore()
        let testID = "urn:lid:media:test_\(UUID().uuidString)"

        await store.recordPosition(
            mediaIdentifier: testID,
            title: "Test Movie",
            positionSeconds: 124.5,
            durationSeconds: 3600.0
        )

        let savedPos = await store.resumePosition(mediaIdentifier: testID)
        XCTAssertNotNil(savedPos)
        if let pos = savedPos {
            XCTAssertEqual(pos, 124.5, accuracy: 0.1)
        }
    }
}
