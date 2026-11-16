import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import DM_Reverse_engineering

final class LIDPlayerSettingsTests: XCTestCase {

    func testLIDPlayerSettings_DefaultValues() {
        let settings = LIDPlayerSettings.default
        XCTAssertEqual(settings.version, LIDPlayerSettings.currentVersion)
        XCTAssertEqual(settings.defaultPlaybackSpeed, 1.0)
        XCTAssertTrue(settings.rememberPlaybackSpeed)
        XCTAssertEqual(settings.defaultAspectRatio, .original)
        XCTAssertEqual(settings.seekIntervalSeconds, 10)
        XCTAssertEqual(settings.autoHideControlsSeconds, 4)
        XCTAssertTrue(settings.resumePlaybackPosition)

        XCTAssertTrue(settings.autoLoadSubtitles)
        XCTAssertTrue(settings.rememberSubtitleTrack)
        XCTAssertEqual(settings.defaultSubtitleLanguage, "Any")
        XCTAssertEqual(settings.subtitleFontSize, 16.0)
        XCTAssertEqual(settings.subtitleTextColor, .white)
        XCTAssertEqual(settings.subtitleBackgroundOpacity, 0.75)
        XCTAssertEqual(settings.subtitleDelayStepMs, 100)

        XCTAssertEqual(settings.defaultAudioLanguage, "Any")
        XCTAssertTrue(settings.rememberAudioTrack)
        XCTAssertTrue(settings.enableBackgroundAudio)

        XCTAssertTrue(settings.enableBrightnessGesture)
        XCTAssertTrue(settings.enableVolumeGesture)
        XCTAssertTrue(settings.enableSeekGesture)
        XCTAssertTrue(settings.enableDoubleTapSeek)
        XCTAssertTrue(settings.enablePinchToZoom)
        XCTAssertTrue(settings.enableTwoXSpeedBoostGesture)

        XCTAssertEqual(settings.defaultOrientation, .auto)
    }

    func testLIDPlayerSettings_JSONRoundTrip() throws {
        var original = LIDPlayerSettings.default
        original.defaultPlaybackSpeed = 1.5
        original.rememberPlaybackSpeed = false
        original.defaultAspectRatio = .fit16x9
        original.seekIntervalSeconds = 15
        original.autoHideControlsSeconds = 8
        original.resumePlaybackPosition = false

        original.autoLoadSubtitles = false
        original.rememberSubtitleTrack = false
        original.defaultSubtitleLanguage = "Spanish"
        original.subtitleFontSize = 22.0
        original.subtitleTextColor = .yellow
        original.subtitleBackgroundOpacity = 0.50
        original.subtitleDelayStepMs = 250

        original.defaultAudioLanguage = "Japanese"
        original.rememberAudioTrack = false
        original.enableBackgroundAudio = false

        original.enableBrightnessGesture = false
        original.enableVolumeGesture = false
        original.enableSeekGesture = false
        original.enableDoubleTapSeek = false
        original.enablePinchToZoom = false
        original.enableTwoXSpeedBoostGesture = false

        original.defaultOrientation = .landscape

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LIDPlayerSettings.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.defaultPlaybackSpeed, 1.5)
        XCTAssertFalse(decoded.rememberPlaybackSpeed)
        XCTAssertEqual(decoded.defaultAspectRatio, .fit16x9)
        XCTAssertEqual(decoded.seekIntervalSeconds, 15)
        XCTAssertEqual(decoded.autoHideControlsSeconds, 8)
        XCTAssertFalse(decoded.resumePlaybackPosition)

        XCTAssertFalse(decoded.autoLoadSubtitles)
        XCTAssertFalse(decoded.rememberSubtitleTrack)
        XCTAssertEqual(decoded.defaultSubtitleLanguage, "Spanish")
        XCTAssertEqual(decoded.subtitleFontSize, 22.0)
        XCTAssertEqual(decoded.subtitleTextColor, .yellow)
        XCTAssertEqual(decoded.subtitleBackgroundOpacity, 0.50)
        XCTAssertEqual(decoded.subtitleDelayStepMs, 250)

        XCTAssertEqual(decoded.defaultAudioLanguage, "Japanese")
        XCTAssertFalse(decoded.rememberAudioTrack)
        XCTAssertFalse(decoded.enableBackgroundAudio)

        XCTAssertFalse(decoded.enableBrightnessGesture)
        XCTAssertFalse(decoded.enableVolumeGesture)
        XCTAssertFalse(decoded.enableSeekGesture)
        XCTAssertFalse(decoded.enableDoubleTapSeek)
        XCTAssertFalse(decoded.enablePinchToZoom)
        XCTAssertFalse(decoded.enableTwoXSpeedBoostGesture)

        XCTAssertEqual(decoded.defaultOrientation, .landscape)
    }

    func testLIDPlayerSettings_ResilientDecodingFromEmptyJSON() throws {
        let emptyJSON = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LIDPlayerSettings.self, from: emptyJSON)

        XCTAssertEqual(decoded.version, LIDPlayerSettings.currentVersion)
        XCTAssertEqual(decoded.defaultPlaybackSpeed, 1.0)
        XCTAssertTrue(decoded.rememberPlaybackSpeed)
        XCTAssertEqual(decoded.defaultAspectRatio, .original)
        XCTAssertEqual(decoded.seekIntervalSeconds, 10)
        XCTAssertEqual(decoded.autoHideControlsSeconds, 4)
        XCTAssertTrue(decoded.resumePlaybackPosition)
        XCTAssertTrue(decoded.autoLoadSubtitles)
        XCTAssertEqual(decoded.subtitleTextColor, .white)
        XCTAssertEqual(decoded.defaultOrientation, .auto)
    }

    @MainActor
    func testLIDPlayerSettingsStore_PersistenceAndReset() {
        let suiteName = "LIDPlayerSettingsTests_\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create test UserDefaults")
            return
        }
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        let store = LIDPlayerSettingsStore(userDefaults: testDefaults)
        XCTAssertEqual(store.settings, LIDPlayerSettings.default)

        store.settings.defaultPlaybackSpeed = 1.75
        store.settings.subtitleTextColor = .green
        store.settings.seekIntervalSeconds = 30
        store.settings.defaultOrientation = .portrait
        store.save()

        // Create second instance reading the same store
        let store2 = LIDPlayerSettingsStore(userDefaults: testDefaults)
        XCTAssertEqual(store2.settings.defaultPlaybackSpeed, 1.75)
        XCTAssertEqual(store2.settings.subtitleTextColor, .green)
        XCTAssertEqual(store2.settings.seekIntervalSeconds, 30)
        XCTAssertEqual(store2.settings.defaultOrientation, .portrait)

        // Test reset to defaults
        store2.resetToDefaults()
        XCTAssertEqual(store2.settings, LIDPlayerSettings.default)
    }

    func testLIDPlayerSubtitleColor_DisplayAndSwiftUIColor() {
        XCTAssertEqual(LIDPlayerSubtitleColor.white.rawValue, "White")
        XCTAssertEqual(LIDPlayerSubtitleColor.yellow.rawValue, "Yellow")
        XCTAssertEqual(LIDPlayerSubtitleColor.green.rawValue, "Green")
        XCTAssertEqual(LIDPlayerSubtitleColor.cyan.rawValue, "Cyan")

        #if canImport(SwiftUI)
        XCTAssertEqual(LIDPlayerSubtitleColor.white.swiftUIColor, .white)
        XCTAssertEqual(LIDPlayerSubtitleColor.yellow.swiftUIColor, .yellow)
        XCTAssertEqual(LIDPlayerSubtitleColor.green.swiftUIColor, .green)
        XCTAssertEqual(LIDPlayerSubtitleColor.cyan.swiftUIColor, .cyan)
        #endif
    }

    func testLIDPlayerOrientationPreference_Cases() {
        XCTAssertEqual(LIDPlayerOrientationPreference.auto.rawValue, "Auto (Sensor)")
        XCTAssertEqual(LIDPlayerOrientationPreference.landscape.rawValue, "Landscape")
        XCTAssertEqual(LIDPlayerOrientationPreference.portrait.rawValue, "Portrait")
    }

    @MainActor
    func testSettingsViewCategoriesInitialization() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try DownloadPersistenceStore(storageDirectoryURL: tempDir)
        let coordinator = try DownloadCoordinator(session: .shared, persistenceStore: store)
        let queueManager = DownloadQueueManager(coordinator: coordinator, persistenceStore: store)
        let engine = DownloadEngine(queueManager: queueManager, coordinator: coordinator, persistenceStore: store)
        let vm = DownloadManagerViewModel(engine: engine, downloadsDirectory: tempDir)

        let rootSettings = SettingsView(viewModel: vm)
        XCTAssertNotNil(rootSettings)

        let downloaderSettings = DownloaderSettingsView(viewModel: vm)
        XCTAssertNotNil(downloaderSettings)

        let browserSettings = BrowserSettingsView(viewModel: vm)
        XCTAssertNotNil(browserSettings)

        let mediaPlayerSettings = MediaPlayerSettingsView()
        XCTAssertNotNil(mediaPlayerSettings)
    }
}
