import XCTest
@testable import DM_Reverse_engineering

final class LIDTrackAndSubtitleTests: XCTestCase {

    func testSRTSubtitleParsing() {
        let parser = LIDSubtitleParser()
        let srtContent = """
        1
        00:00:01,500 --> 00:00:04,000
        Hello, <i>world</i>!
        Welcome to LID Player.

        2
        00:00:05,200 --> 00:00:08,750
        <b>Second cue</b> with styling.
        """

        let cues = parser.parse(string: srtContent)
        XCTAssertEqual(cues.count, 2)

        XCTAssertEqual(cues[0].startTime, 1.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].endTime, 4.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Hello, world!\nWelcome to LID Player.")

        XCTAssertEqual(cues[1].startTime, 5.2, accuracy: 0.001)
        XCTAssertEqual(cues[1].endTime, 8.75, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "Second cue with styling.")
    }

    func testWebVTTSubtitleParsing() {
        let parser = LIDSubtitleParser()
        let vttContent = """
        WEBVTT

        00:01.000 --> 00:03.500 position:50% line:80%
        Short timestamp cue

        01:15:02.100 --> 01:15:05.900
        Long timestamp cue with <font color="#ff0000">color</font>
        """

        let cues = parser.parse(string: vttContent)
        XCTAssertEqual(cues.count, 2)

        XCTAssertEqual(cues[0].startTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].endTime, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Short timestamp cue")

        XCTAssertEqual(cues[1].startTime, (3600.0 + 15.0 * 60.0 + 2.1), accuracy: 0.001)
        XCTAssertEqual(cues[1].endTime, (3600.0 + 15.0 * 60.0 + 5.9), accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "Long timestamp cue with color")
    }

    func testActiveCueLookupAndDelayAdjustment() {
        let parser = LIDSubtitleParser()
        let cues = [
            LIDSubtitleCue(startTime: 10.0, endTime: 15.0, text: "Scene 1"),
            LIDSubtitleCue(startTime: 20.0, endTime: 25.0, text: "Scene 2")
        ]

        // Exact hits
        XCTAssertNil(parser.activeCue(in: cues, at: 5.0))
        XCTAssertEqual(parser.activeCue(in: cues, at: 12.0)?.text, "Scene 1")
        XCTAssertNil(parser.activeCue(in: cues, at: 17.0))
        XCTAssertEqual(parser.activeCue(in: cues, at: 22.0)?.text, "Scene 2")
        XCTAssertNil(parser.activeCue(in: cues, at: 30.0))

        // Delay adjustment: delay = +2.0 means subtitle was displayed 2s earlier than intended,
        // so at video time 12s, adjusted time = 10s -> hits Scene 1
        XCTAssertEqual(parser.activeCue(in: cues, at: 12.0, delay: 2.0)?.text, "Scene 1")
        XCTAssertEqual(parser.activeCue(in: cues, at: 16.5, delay: 2.0)?.text, "Scene 1")
    }

    func testTrackManagerAudioAndSubtitles() async {
        await MainActor.run {
            let manager = LIDTrackManager()
            XCTAssertEqual(manager.availableSubtitleTracks.count, 1)
            XCTAssertEqual(manager.selectedSubtitleTrack, .off)

            // Select audio track
            let audio1 = LIDAudioTrack(id: "en", displayName: "English [Stereo]")
            let audio2 = LIDAudioTrack(id: "es", displayName: "Spanish [5.1]")
            manager.selectAudioTrack(audio1)
            XCTAssertEqual(manager.selectedAudioTrack?.id, "en")
            manager.selectAudioTrack(audio2)
            XCTAssertEqual(manager.selectedAudioTrack?.id, "es")

            // Subtitle delay adjustments
            XCTAssertEqual(manager.subtitleDelay, 0.0)
            manager.adjustSubtitleDelay(by: 0.5)
            XCTAssertEqual(manager.subtitleDelay, 0.5, accuracy: 0.001)
            manager.adjustSubtitleDelay(by: -1.0)
            XCTAssertEqual(manager.subtitleDelay, -0.5, accuracy: 0.001)

            // Delay bounds (-5.0 to +5.0)
            manager.adjustSubtitleDelay(by: 10.0)
            XCTAssertEqual(manager.subtitleDelay, 5.0, accuracy: 0.001)
            manager.adjustSubtitleDelay(by: -20.0)
            XCTAssertEqual(manager.subtitleDelay, -5.0, accuracy: 0.001)
        }
    }

    func testTrackManagerExternalSubtitleFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let srtFile = tempDir.appendingPathComponent("test_sub_\(UUID().uuidString).srt")

        let content = """
        1
        00:00:02,000 --> 00:00:05,000
        Action cue text
        """
        try content.write(to: srtFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srtFile) }

        await MainActor.run {
            let manager = LIDTrackManager()
            manager.addExternalSubtitle(url: srtFile, displayName: "Custom English")
            XCTAssertEqual(manager.selectedSubtitleTrack.displayName, "Custom English")
            XCTAssertTrue(manager.selectedSubtitleTrack.isExternal)

            // Update position: at 1s no cue, at 3s cue active
            manager.updatePosition(1.0)
            XCTAssertNil(manager.activeCueText)

            manager.updatePosition(3.0)
            XCTAssertEqual(manager.activeCueText, "Action cue text")

            manager.updatePosition(6.0)
            XCTAssertNil(manager.activeCueText)
        }
    }

    func testNowPlayingCoordinatorLifecycle() async {
        await MainActor.run {
            let coordinator = LIDNowPlayingCoordinator()
            var played = false
            var paused = false

            coordinator.setupRemoteCommands(
                onPlay: { played = true },
                onPause: { paused = true },
                onTogglePlayPause: {},
                onSeekTo: { _ in },
                onSkip: { _ in }
            )

            coordinator.updateNowPlaying(title: "Sample Movie", duration: 120.0, currentTime: 15.0, playbackRate: 1.0)
            coordinator.clearNowPlaying()
            XCTAssertFalse(played)
            XCTAssertFalse(paused)
        }
    }
}
