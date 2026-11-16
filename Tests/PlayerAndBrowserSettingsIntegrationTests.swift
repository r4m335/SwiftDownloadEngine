import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import DM_Reverse_engineering

final class PlayerAndBrowserSettingsIntegrationTests: XCTestCase {

    // MARK: - 1. Playback Speed & Memory

    func testPlaybackSpeed_DefaultVsRememberedRestoration() {
        var settings = LIDPlayerSettings.default
        settings.defaultPlaybackSpeed = 1.25
        settings.lastSelectedPlaybackSpeed = nil
        settings.rememberPlaybackSpeed = false

        // When remember is false, always defaultPlaybackSpeed
        XCTAssertEqual(settings.effectivePlaybackSpeed, 1.25)

        // Even if lastSelectedPlaybackSpeed has a value, remember=false ignores it
        settings.lastSelectedPlaybackSpeed = 1.75
        XCTAssertEqual(settings.effectivePlaybackSpeed, 1.25)

        // When remember is true, lastSelectedPlaybackSpeed takes precedence
        settings.rememberPlaybackSpeed = true
        XCTAssertEqual(settings.effectivePlaybackSpeed, 1.75)

        // If lastSelectedPlaybackSpeed is nil, fallback to defaultPlaybackSpeed
        settings.lastSelectedPlaybackSpeed = nil
        XCTAssertEqual(settings.effectivePlaybackSpeed, 1.25)
    }

    func testPlaybackSpeed_TemporaryBoostDoesNotOverwriteRememberedSpeed() async {
        let engine = LIDPlaybackEngine.shared
        engine.playbackRate = 1.25

        // Start temporary 2x boost
        engine.startTemporarySpeedBoost(rate: 2.0)
        XCTAssertEqual(engine.playbackRate, 2.0)

        // Cancel temporary boost restores original rate
        engine.cancelTemporarySpeedBoost()
        XCTAssertEqual(engine.playbackRate, 1.25)
    }

    // MARK: - 2. Audio & Subtitle Language Matching

    func testTrackManager_MatchesLanguage() {
        let manager = LIDTrackManager()

        // English matching
        XCTAssertTrue(manager.matchesLanguage(languageCode: "en", displayName: "English", preferredLanguage: "English"))
        XCTAssertTrue(manager.matchesLanguage(languageCode: "eng", displayName: "Track 1", preferredLanguage: "English"))
        XCTAssertTrue(manager.matchesLanguage(languageCode: nil, displayName: "English [Commentary]", preferredLanguage: "English"))
        XCTAssertFalse(manager.matchesLanguage(languageCode: "fr", displayName: "French", preferredLanguage: "English"))

        // Spanish matching
        XCTAssertTrue(manager.matchesLanguage(languageCode: "es", displayName: "Español", preferredLanguage: "Spanish"))
        XCTAssertTrue(manager.matchesLanguage(languageCode: "spa", displayName: "Spanish 5.1", preferredLanguage: "Spanish"))

        // Japanese matching
        XCTAssertTrue(manager.matchesLanguage(languageCode: "ja", displayName: "Japanese Audio", preferredLanguage: "Japanese"))
        XCTAssertTrue(manager.matchesLanguage(languageCode: "jpn", displayName: "Stereo", preferredLanguage: "Japanese"))

        // Any matching
        XCTAssertTrue(manager.matchesLanguage(languageCode: "de", displayName: "German", preferredLanguage: "Any"))
        XCTAssertTrue(manager.matchesLanguage(languageCode: nil, displayName: nil, preferredLanguage: "Any"))
    }

    func testTrackManager_ApplyPreferences() {
        let manager = LIDTrackManager()

        let trackEN = LIDMediaTrack(id: "en_sub", type: .subtitle, title: "English Subtitles", language: "en")
        let trackFR = LIDMediaTrack(id: "fr_sub", type: .subtitle, title: "French Subtitles", language: "fr")
        manager.availableSubtitleTracks = [trackEN, trackFR]

        let audioEN = LIDMediaTrack(id: "en_audio", type: .audio, title: "English 5.1", language: "en")
        let audioJA = LIDMediaTrack(id: "ja_audio", type: .audio, title: "Japanese Stereo", language: "ja")
        manager.availableAudioTracks = [audioEN, audioJA]

        var settings = LIDPlayerSettings.default
        settings.defaultSubtitleLanguage = "French"
        settings.defaultAudioLanguage = "Japanese"

        manager.applyPreferences(settings: settings, historyRecord: nil)

        // Should match preferences
        XCTAssertEqual(manager.selectedSubtitleTrack.id, "fr_sub")
        XCTAssertEqual(manager.selectedAudioTrack.id, "ja_audio")
    }

    func testTrackManager_HistoryTakesPrecedenceWhenRememberActive() {
        let manager = LIDTrackManager()

        let trackEN = LIDMediaTrack(id: "en_sub", type: .subtitle, title: "English", language: "en")
        let trackFR = LIDMediaTrack(id: "fr_sub", type: .subtitle, title: "French", language: "fr")
        manager.availableSubtitleTracks = [trackEN, trackFR]

        let audioEN = LIDMediaTrack(id: "en_audio", type: .audio, title: "English", language: "en")
        let audioJA = LIDMediaTrack(id: "ja_audio", type: .audio, title: "Japanese", language: "ja")
        manager.availableAudioTracks = [audioEN, audioJA]

        var settings = LIDPlayerSettings.default
        settings.rememberSubtitleTrack = true
        settings.rememberAudioTrack = true
        settings.defaultSubtitleLanguage = "French"
        settings.defaultAudioLanguage = "Japanese"

        // History recorded English for both
        let history = LIDPlaybackRecord(
            mediaIdentifier: "test_media",
            lastPositionSeconds: 120.0,
            durationSeconds: 300.0,
            lastPlayedAt: Date(),
            playbackRate: 1.0,
            aspectRatio: .original,
            subtitleDelaySeconds: 0.0,
            audioDelaySeconds: 0.0,
            selectedAudioTrackId: "en_audio",
            selectedSubtitleTrackId: "en_sub"
        )

        manager.applyPreferences(settings: settings, historyRecord: history)

        // History should win over defaults when remember is true
        XCTAssertEqual(manager.selectedSubtitleTrack.id, "en_sub")
        XCTAssertEqual(manager.selectedAudioTrack.id, "en_audio")

        // If remember is false, defaults should win
        settings.rememberSubtitleTrack = false
        settings.rememberAudioTrack = false
        manager.applyPreferences(settings: settings, historyRecord: history)

        XCTAssertEqual(manager.selectedSubtitleTrack.id, "fr_sub")
        XCTAssertEqual(manager.selectedAudioTrack.id, "ja_audio")
    }

    func testPlaybackRecord_BackwardCompatibleDecoding() throws {
        // JSON without track IDs (legacy schema)
        let legacyJSON = """
        {
            "mediaIdentifier": "legacy_test",
            "lastPositionSeconds": 45.0,
            "durationSeconds": 100.0,
            "lastPlayedAt": 1700000000.0,
            "playbackRate": 1.0,
            "aspectRatio": "original",
            "subtitleDelaySeconds": 0.0,
            "audioDelaySeconds": 0.0
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(LIDPlaybackRecord.self, from: legacyJSON)
        XCTAssertEqual(record.mediaIdentifier, "legacy_test")
        XCTAssertEqual(record.lastPositionSeconds, 45.0)
        XCTAssertNil(record.selectedAudioTrackId)
        XCTAssertNil(record.selectedSubtitleTrackId)
    }

    // MARK: - 3. Settings Validation & Clamping

    func testSettings_ValidationAndClamping() {
        var settings = LIDPlayerSettings.default
        settings.defaultPlaybackSpeed = 5.0
        settings.subtitleFontSize = 50.0
        settings.subtitleBackgroundOpacity = 2.0
        settings.seekIntervalSeconds = 99
        settings.autoHideControlsSeconds = 42
        settings.subtitleDelayStepMs = 999

        settings.validateAndClamp()

        XCTAssertEqual(settings.defaultPlaybackSpeed, 2.0)
        XCTAssertEqual(settings.subtitleFontSize, 32.0)
        XCTAssertEqual(settings.subtitleBackgroundOpacity, 1.0)
        XCTAssertEqual(settings.seekIntervalSeconds, 30) // snapped to closest valid (30)
        XCTAssertEqual(settings.autoHideControlsSeconds, 8) // snapped to closest valid (8)
        XCTAssertEqual(settings.subtitleDelayStepMs, 500) // snapped to closest valid (500)
    }

    // MARK: - 4. Orientation Manager

    #if canImport(UIKit)
    @MainActor
    func testOrientationManager_ApplyPreference() {
        let orientationManager = LIDOrientationManager.shared

        // Applying landscape
        orientationManager.applyOrientationPreference(.landscape, session: "test_session")
        XCTAssertEqual(orientationManager.activeOrientationPreference, .landscape)
        XCTAssertTrue(orientationManager.isPlayerActive)

        // Applying portrait
        orientationManager.applyOrientationPreference(.portrait, session: "test_session")
        XCTAssertEqual(orientationManager.activeOrientationPreference, .portrait)
        XCTAssertTrue(orientationManager.isPlayerActive)

        // Applying auto
        orientationManager.applyOrientationPreference(.auto, session: "test_session")
        XCTAssertEqual(orientationManager.activeOrientationPreference, .auto)
        XCTAssertTrue(orientationManager.isPlayerActive)
    }
    #endif

    // MARK: - 5. Audio Session Category Selection

    #if os(iOS) && canImport(AVFoundation)
    func testPlaybackEngine_ConfigureAudioSessionCategory() {
        let catEnabled = LIDPlaybackEngine.targetAudioSessionCategory(enableBackgroundAudio: true)
        XCTAssertEqual(catEnabled, .playback)

        let catDisabled = LIDPlaybackEngine.targetAudioSessionCategory(enableBackgroundAudio: false)
        XCTAssertEqual(catDisabled, .ambient)
    }
    #endif

    // MARK: - 6. Browser Settings Runtime Synchronization

    @MainActor
    func testBrowserViewModel_ReloadSettingsUpdatesRuntimeState() {
        let vm = BrowserViewModel()

        var customSettings = AppSettings.load()
        customSettings.isAdBlockerEnabled = false
        customSettings.isTrackerBlockerEnabled = false
        customSettings.isAnnoyanceBlockerEnabled = false
        customSettings.cookiePolicy = .blockAll
        customSettings.isPopupBlockerEnabled = false
        customSettings.adBlockerWhitelistedDomains = ["example.com", "trusted.org"]
        customSettings.browserSearchEngine = .duckDuckGo
        customSettings.browserHomepage = "https://example.com/custom_home"
        customSettings.restoreTabsOnLaunch = false
        customSettings.readerTheme = .sepia
        customSettings.readerFontFamily = .serif
        customSettings.readerFontSize = 24.0

        vm.reloadSettings(from: customSettings)

        XCTAssertFalse(vm.isAdBlockerEnabled)
        XCTAssertFalse(vm.isTrackerBlockerEnabled)
        XCTAssertFalse(vm.isAnnoyanceBlockerEnabled)
        XCTAssertEqual(vm.cookiePolicy, .blockAll)
        XCTAssertFalse(vm.isPopupBlockerEnabled)
        XCTAssertEqual(vm.adBlockerWhitelistedDomains, Set(["example.com", "trusted.org"]))
        XCTAssertEqual(vm.selectedSearchEngine, .duckDuckGo)
        XCTAssertEqual(vm.browserHomepage, "https://example.com/custom_home")
        XCTAssertFalse(vm.restoreTabsOnLaunch)
        XCTAssertEqual(vm.readerSettings.theme, .sepia)
        XCTAssertEqual(vm.readerSettings.fontFamily, .serif)
        XCTAssertEqual(vm.readerSettings.fontSize, 24.0)
    }

    func testBrowserSnifferFilter_FiltersCandidatesCorrectly() {
        let candidate1 = BrowserMediaCandidate(
            url: URL(string: "https://example.com/video.mp4")!,
            mimeType: "video/mp4",
            sourcePageURL: nil,
            contentLength: 1024,
            duration: 60.0
        )
        let candidate2 = BrowserMediaCandidate(
            url: URL(string: "https://example.com/image.png")!,
            mimeType: "image/png",
            sourcePageURL: nil,
            contentLength: 512,
            duration: nil
        )

        // Filter enabled: only mp4 should pass
        let filter = BrowserSnifferFilter(
            allowedExtensions: ["mp4", "m3u8"],
            allowedMIMETypes: ["video/mp4", "application/x-mpegurl"],
            isFilterEnabled: true
        )

        let filtered = BrowserMediaCandidateManager.filter(candidates: [candidate1, candidate2], using: filter)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.url, candidate1.url)

        // Filter disabled: all should pass
        let disabledFilter = BrowserSnifferFilter(
            allowedExtensions: ["mp4"],
            allowedMIMETypes: ["video/mp4"],
            isFilterEnabled: false
        )
        let allPassed = BrowserMediaCandidateManager.filter(candidates: [candidate1, candidate2], using: disabledFilter)
        XCTAssertEqual(allPassed.count, 2)
    }
}
