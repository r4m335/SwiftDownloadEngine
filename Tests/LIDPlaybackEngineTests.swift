import XCTest
import Foundation
@testable import DM_Reverse_engineering

final class LIDPlaybackEngineTests: XCTestCase {

    // MARK: - 1. Player Source Model Tests

    func testPlayerSourceProperties() {
        let localURL = URL(fileURLWithPath: "/tmp/sample.mp4")
        let localSource = LIDPlayerSource.localFile(url: localURL, title: "Sample Video")
        XCTAssertEqual(localSource.title, "Sample Video")
        XCTAssertEqual(localSource.url, localURL)
        XCTAssertFalse(localSource.isStreaming)

        let streamURL = URL(string: "https://example.com/live/index.m3u8")!
        let streamSource = LIDPlayerSource.hlsStream(url: streamURL, variantPreferences: nil, title: "Live HLS")
        XCTAssertEqual(streamSource.title, "Live HLS")
        XCTAssertEqual(streamSource.url, streamURL)
        XCTAssertTrue(streamSource.isStreaming)

        let httpURL = URL(string: "https://example.com/video.mp4")!
        let httpSource = LIDPlayerSource.networkStream(url: httpURL, headers: ["User-Agent": "LIDPlayer"], title: "HTTP MP4")
        XCTAssertEqual(httpSource.title, "HTTP MP4")
        XCTAssertEqual(httpSource.url, httpURL)
        XCTAssertTrue(httpSource.isStreaming)

        let torrentSource = LIDPlayerSource.torrentSwarm(infoHash: "0123456789abcdef", fileIndex: 0, title: "Big Buck Bunny Torrent")
        XCTAssertEqual(torrentSource.title, "Big Buck Bunny Torrent")
        XCTAssertEqual(torrentSource.url, URL(string: "lidtorrent://0123456789abcdef/0"))
        XCTAssertEqual(torrentSource.mediaIdentifier, "torrent://0123456789abcdef/0")
        XCTAssertTrue(torrentSource.isStreaming)

        let dashURL = URL(string: "https://example.com/manifest.mpd")!
        let dashSource = LIDPlayerSource.dashStream(manifestURL: dashURL, selectedRepresentationID: "video-1080p", title: "DASH VOD")
        XCTAssertEqual(dashSource.title, "DASH VOD")
        XCTAssertEqual(dashSource.url, dashURL)
        XCTAssertEqual(dashSource.mediaIdentifier, "https://example.com/manifest.mpd#video-1080p")
        XCTAssertTrue(dashSource.isStreaming)
    }

    // MARK: - 2. Playable Media Extension Classification

    func testURLIsPlayableMediaDetection() {
        let playableURLs = [
            URL(string: "https://example.com/video.mp4")!,
            URL(string: "https://example.com/clip.m4v")!,
            URL(string: "https://example.com/movie.mov")!,
            URL(string: "https://example.com/film.mkv")!,
            URL(string: "https://example.com/stream.webm")!,
            URL(string: "https://example.com/song.mp3")!,
            URL(string: "https://example.com/audio.m4a")!,
            URL(string: "https://example.com/sound.aac")!,
            URL(string: "https://example.com/voice.wav")!,
            URL(string: "https://example.com/music.flac")!,
            URL(string: "https://example.com/track.ogg")!,
            URL(string: "https://example.com/playlist.m3u8")!
        ]

        for url in playableURLs {
            XCTAssertTrue(url.isPlayableMedia, "Expected \(url.lastPathComponent) to be playable media")
        }

        let nonPlayableURLs = [
            URL(string: "https://example.com/document.pdf")!,
            URL(string: "https://example.com/archive.zip")!,
            URL(string: "https://example.com/page.html")!,
            URL(string: "https://example.com/notes.txt")!,
            URL(string: "https://example.com/installer.dmg")!,
            URL(string: "https://example.com/os.iso")!
        ]

        for url in nonPlayableURLs {
            XCTAssertFalse(url.isPlayableMedia, "Expected \(url.lastPathComponent) not to be playable media")
        }
    }

    // MARK: - 3. Playback History & Resume Position Store Tests

    func testPlaybackHistoryStoreRecordAndResume() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LIDTestHistory_\(UUID().uuidString)")
        let tempFile = tempDir.appendingPathComponent("playback_history.json")
        let store = LIDPlaybackHistoryStore(storageURL: tempFile)

        let mediaID = "https://example.com/movies/interstellar.mp4"
        let title = "Interstellar"

        // Watch 45 seconds of a 120-second clip
        await store.recordPosition(mediaIdentifier: mediaID, title: title, positionSeconds: 45.0, durationSeconds: 120.0)

        let resumeSec = await store.resumePosition(mediaIdentifier: mediaID)
        XCTAssertEqual(resumeSec, 45.0, "Should accurately restore last watched position")

        let allRecords = await store.historyRecords()
        XCTAssertEqual(allRecords.count, 1)
        XCTAssertEqual(allRecords.first?.title, "Interstellar")
        XCTAssertFalse(allRecords.first?.isCompleted ?? true)
        XCTAssertEqual(allRecords.first?.progressFraction ?? 0, 45.0 / 120.0, accuracy: 0.01)

        // Simulate watching to 98% of duration (near completion)
        await store.recordPosition(mediaIdentifier: mediaID, title: title, positionSeconds: 118.0, durationSeconds: 120.0)

        let completedResumeSec = await store.resumePosition(mediaIdentifier: mediaID)
        XCTAssertNil(completedResumeSec, "Completed media should restart from beginning next time")

        let updatedRecords = await store.historyRecords()
        XCTAssertTrue(updatedRecords.first?.isCompleted ?? false)

        // Clear history
        await store.clearAllHistory()
        let clearedRecords = await store.historyRecords()
        XCTAssertTrue(clearedRecords.isEmpty)

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 4. Playback Speed & Aspect Ratio Models

    func testPlaybackSpeedEnum() {
        XCTAssertEqual(LIDPlaybackSpeed.speed0_25.rawValue, 0.25)
        XCTAssertEqual(LIDPlaybackSpeed.speed0_25.label, "0.25×")
        XCTAssertEqual(LIDPlaybackSpeed.speed1_00.rawValue, 1.0)
        XCTAssertEqual(LIDPlaybackSpeed.speed1_00.label, "1.0×")
        XCTAssertEqual(LIDPlaybackSpeed.speed2_00.rawValue, 2.0)
        XCTAssertEqual(LIDPlaybackSpeed.speed2_00.label, "2.0×")
        XCTAssertEqual(LIDPlaybackSpeed.speed4_00.rawValue, 4.0)
        XCTAssertEqual(LIDPlaybackSpeed.speed4_00.label, "4.0×")
        XCTAssertEqual(LIDPlaybackSpeed.allCases.count, 8)
    }

    func testAspectRatioEnum() {
        XCTAssertEqual(LIDAspectRatio.allCases.map(\.rawValue), [
            "Original", "16:9", "4:3", "Fill", "Stretch"
        ])
    }

    // MARK: - 5. Playback Engine State Management

    @MainActor
    func testPlaybackEngineControls() {
        let engine = LIDPlaybackEngine()
        XCTAssertEqual(engine.playbackState, .idle)
        XCTAssertEqual(engine.playbackSpeed, .speed1_00)
        XCTAssertEqual(engine.volume, 1.0)
        XCTAssertFalse(engine.isMuted)

        engine.setPlaybackSpeed(.speed1_50)
        XCTAssertEqual(engine.playbackSpeed, .speed1_50)
        XCTAssertEqual(engine.playbackRate, 1.50, accuracy: 0.001)

        // Continuous numeric rate slider
        engine.setPlaybackRate(1.37)
        XCTAssertEqual(engine.playbackRate, 1.37, accuracy: 0.001)

        // Temporary 2x speed boost and restoration
        engine.startTemporarySpeedBoost(rate: 2.0)
        XCTAssertEqual(engine.playbackRate, 2.0, accuracy: 0.001)
        engine.cancelTemporarySpeedBoost()
        XCTAssertEqual(engine.playbackRate, 1.37, accuracy: 0.001)

        // 0.0x pause behavior
        engine.setPlaybackRate(0.0)
        XCTAssertEqual(engine.playbackRate, 0.0)

        // Unrestricted subtitle delay on engine
        engine.setSubtitleDelay(seconds: -15.0)
        XCTAssertEqual(engine.subtitleDelay, -15.0, accuracy: 0.001)
        engine.setSubtitleDelay(seconds: 15.0)
        XCTAssertEqual(engine.subtitleDelay, 15.0, accuracy: 0.001)

        engine.setVolume(0.65)
        XCTAssertEqual(engine.volume, 0.65, accuracy: 0.001)

        // Clamping check
        engine.setVolume(2.5)
        XCTAssertEqual(engine.volume, 1.0)
        engine.setVolume(-0.5)
        XCTAssertEqual(engine.volume, 0.0)

        engine.toggleMute()
        XCTAssertTrue(engine.isMuted)
        engine.toggleMute()
        XCTAssertFalse(engine.isMuted)
    }

    // MARK: - 6. MPEG-TS Container Validation & Error Handling

    func testTSHeaderValidation() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TSValidationTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Valid TS file (starts with 0x47 sync byte)
        let validTSURL = tempDir.appendingPathComponent("valid.ts")
        var validData = Data([0x47])
        validData.append(Data(repeating: 0x00, count: 187))
        try validData.write(to: validTSURL)
        XCTAssertTrue(LIDPlaybackEngine.validateTSHeader(url: validTSURL), "File starting with 0x47 should be recognized as TS")

        // 2. Corrupt / HTML error page saved with .ts extension (e.g. starts with "<!DOCTYPE html>")
        let invalidTSURL = tempDir.appendingPathComponent("invalid.ts")
        let htmlData = "<!DOCTYPE html><html><body>Error 404</body></html>".data(using: .utf8)!
        try htmlData.write(to: invalidTSURL)
        XCTAssertFalse(LIDPlaybackEngine.validateTSHeader(url: invalidTSURL), "Non-0x47 file must fail TS sync byte validation")

        // 3. Non-existent file
        let missingURL = tempDir.appendingPathComponent("missing.ts")
        XCTAssertFalse(LIDPlaybackEngine.validateTSHeader(url: missingURL), "Missing file should fail validation")
    }

    // MARK: - 7. Playback State Helpers & Error Reporting

    @MainActor
    func testPlaybackStateHelpersAndFailureReporting() {
        let idle = LIDPlaybackState.idle
        XCTAssertFalse(idle.isLoading)
        XCTAssertFalse(idle.isBuffering)
        XCTAssertFalse(idle.isPlaying)
        XCTAssertFalse(idle.isFailed)
        XCTAssertNil(idle.errorMessage)

        let loading = LIDPlaybackState.loading
        XCTAssertTrue(loading.isLoading)
        XCTAssertFalse(loading.isPlaying)
        XCTAssertFalse(loading.isFailed)

        let buffering = LIDPlaybackState.buffering(progress: 0.5)
        XCTAssertTrue(buffering.isBuffering)
        XCTAssertFalse(buffering.isFailed)

        let failed = LIDPlaybackState.failed(error: "MPEG-2 Transport Stream (.ts) could not be decoded.")
        XCTAssertTrue(failed.isFailed)
        XCTAssertFalse(failed.isPlaying)
        XCTAssertEqual(failed.errorMessage, "MPEG-2 Transport Stream (.ts) could not be decoded.")
    }

    // MARK: - 8. Local Missing & Invalid TS File Loading

    @MainActor
    func testLocalFileLoadingErrorHandling() {
        let engine = LIDPlaybackEngine()

        // 1. Load non-existent local file
        let missingURL = URL(fileURLWithPath: "/tmp/non_existent_file_\(UUID().uuidString).mp4")
        engine.load(source: .localFile(url: missingURL, title: "Missing Video"))
        XCTAssertTrue(engine.playbackState.isFailed, "Loading missing local file must transition to failed state")
        XCTAssertTrue(engine.playbackState.errorMessage?.contains("does not exist") ?? false)

        // 2. Load invalid TS file
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LIDTestInvalidTS_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let invalidTS = tempDir.appendingPathComponent("corrupted.ts")
        try? "Not a TS file".data(using: .utf8)?.write(to: invalidTS)

        engine.load(source: .localFile(url: invalidTS, title: "Corrupted TS"))
        XCTAssertTrue(engine.playbackState.isFailed, "Loading corrupted TS must transition to failed state")
        XCTAssertTrue(engine.playbackState.errorMessage?.contains("0x47") ?? false)
    }
}
