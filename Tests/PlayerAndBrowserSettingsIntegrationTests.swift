import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import SwiftDownloadEngine

@MainActor
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
        engine.setPlaybackRate(1.25)

        // Start temporary 2x boost
        engine.startTemporarySpeedBoost(rate: 2.0)
        XCTAssertEqual(engine.playbackRate, 2.0)

        // Cancel temporary boost restores original rate
        engine.cancelTemporarySpeedBoost()
        XCTAssertEqual(engine.playbackRate, 1.25)
    }

    // MARK: - 2. Audio & Subtitle Language Matching

    func testTrackManager_MatchesLanguage() {
        // English matching
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "en", displayName: "English", preferredLanguage: "English"))
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "eng", displayName: "Track 1", preferredLanguage: "English"))
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: nil, displayName: "English [Commentary]", preferredLanguage: "English"))
        XCTAssertFalse(LIDTrackManager.matchesLanguage(languageCode: "fr", displayName: "French", preferredLanguage: "English"))

        // Spanish matching
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "es", displayName: "Español", preferredLanguage: "Spanish"))
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "spa", displayName: "Spanish 5.1", preferredLanguage: "Spanish"))

        // Japanese matching
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "ja", displayName: "Japanese Audio", preferredLanguage: "Japanese"))
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "jpn", displayName: "Stereo", preferredLanguage: "Japanese"))

        // Any matching
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: "de", displayName: "German", preferredLanguage: "Any"))
        XCTAssertTrue(LIDTrackManager.matchesLanguage(languageCode: nil, displayName: "", preferredLanguage: "Any"))
    }

    func testTrackManager_ApplyPreferences() {
        let manager = LIDTrackManager()

        let trackEN = LIDSubtitleTrack(id: "en_sub", displayName: "English Subtitles", languageCode: "en")
        let trackFR = LIDSubtitleTrack(id: "fr_sub", displayName: "French Subtitles", languageCode: "fr")
        let audioEN = LIDAudioTrack(id: "en_audio", displayName: "English 5.1", languageCode: "en")
        let audioJA = LIDAudioTrack(id: "ja_audio", displayName: "Japanese Stereo", languageCode: "ja")

        manager.updateAvailableTracks(audioTracks: [audioEN, audioJA], subtitleTracks: [trackEN, trackFR])

        var settings = LIDPlayerSettings.default
        settings.defaultSubtitleLanguage = "French"
        settings.defaultAudioLanguage = "Japanese"

        manager.applyPreferences(settings: settings, historyRecord: nil)

        // Should match preferences
        XCTAssertEqual(manager.selectedSubtitleTrack.id, "fr_sub")
        XCTAssertEqual(manager.selectedAudioTrack?.id, "ja_audio")
    }

    func testTrackManager_HistoryTakesPrecedenceWhenRememberActive() {
        let manager = LIDTrackManager()

        let trackEN = LIDSubtitleTrack(id: "en_sub", displayName: "English", languageCode: "en")
        let trackFR = LIDSubtitleTrack(id: "fr_sub", displayName: "French", languageCode: "fr")
        let audioEN = LIDAudioTrack(id: "en_audio", displayName: "English", languageCode: "en")
        let audioJA = LIDAudioTrack(id: "ja_audio", displayName: "Japanese", languageCode: "ja")

        manager.updateAvailableTracks(audioTracks: [audioEN, audioJA], subtitleTracks: [trackEN, trackFR])

        var settings = LIDPlayerSettings.default
        settings.rememberSubtitleTrack = true
        settings.rememberAudioTrack = true
        settings.defaultSubtitleLanguage = "French"
        settings.defaultAudioLanguage = "Japanese"

        // History recorded English for both
        let history = LIDPlaybackRecord(
            mediaIdentifier: "test_media",
            title: "Test Media",
            lastPositionSeconds: 120.0,
            durationSeconds: 300.0,
            lastPlayedAt: Date(),
            isCompleted: false,
            selectedAudioTrackId: "en_audio",
            selectedSubtitleTrackId: "en_sub"
        )

        manager.applyPreferences(settings: settings, historyRecord: history)

        // History should win over defaults when remember is true
        XCTAssertEqual(manager.selectedSubtitleTrack.id, "en_sub")
        XCTAssertEqual(manager.selectedAudioTrack?.id, "en_audio")

        // If remember is false, defaults should win
        settings.rememberSubtitleTrack = false
        settings.rememberAudioTrack = false
        manager.applyPreferences(settings: settings, historyRecord: history)

        XCTAssertEqual(manager.selectedSubtitleTrack.id, "fr_sub")
        XCTAssertEqual(manager.selectedAudioTrack?.id, "ja_audio")
    }

    func testPlaybackRecord_BackwardCompatibleDecoding() throws {
        // JSON without track IDs (legacy schema)
        let legacyJSON = """
        {
            "mediaIdentifier": "legacy_test",
            "title": "Legacy Test",
            "lastPositionSeconds": 45.0,
            "durationSeconds": 100.0,
            "lastPlayedAt": 1700000000.0,
            "isCompleted": false
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
        XCTAssertEqual(settings.seekIntervalSeconds, 10) // reset to safe default fallback (10)
        XCTAssertEqual(settings.autoHideControlsSeconds, 4) // reset to safe default fallback (4)
        XCTAssertEqual(settings.subtitleDelayStepMs, 100) // reset to safe default fallback (100)
    }

    // MARK: - 4. Orientation Manager

    #if canImport(UIKit)
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
        let resVideo = WebpageResource(
            url: URL(string: "https://example.com/clip.mp4")!,
            title: "clip",
            suggestedFilename: "clip.mp4",
            resourceType: .video,
            mimeType: "video/mp4"
        )
        let resDoc = WebpageResource(
            url: URL(string: "https://example.com/document.pdf")!,
            title: "doc",
            suggestedFilename: "document.pdf",
            resourceType: .document,
            mimeType: "application/pdf"
        )
        let candVideo = BrowserMediaCandidateClassifier.classify(resource: resVideo)
        let candDoc = BrowserMediaCandidateClassifier.classify(resource: resDoc)

        let filter = BrowserSnifferFilter(
            allowedExtensions: ["mp4", "m3u8"],
            allowedMIMETypes: ["video/mp4"],
            isFilterEnabled: true
        )

        let filtered = BrowserMediaDiscoveryBridge.filter(candidates: [candVideo, candDoc], using: filter)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.url, candVideo.url)

        let disabledFilter = BrowserSnifferFilter(
            allowedExtensions: ["mp4"],
            allowedMIMETypes: ["video/mp4"],
            isFilterEnabled: false
        )
        let allPassed = BrowserMediaDiscoveryBridge.filter(candidates: [candVideo, candDoc], using: disabledFilter)
        XCTAssertEqual(allPassed.count, 2)
    }
}
