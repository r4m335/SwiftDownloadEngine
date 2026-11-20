import XCTest
@testable import DownloadEngineKit

#if canImport(AVFoundation)
import AVFoundation
#endif

final class RuntimeReadinessAndInfoTests: XCTestCase {

    func testInfoPlistBackgroundModesAndPrivacyKeys() throws {
        // Resolve path to iOSApp/Info.plist
        let currentFile = URL(fileURLWithPath: #file)
        let repoRoot = currentFile.deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = repoRoot.appendingPathComponent("iOSApp/Info.plist")

        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            XCTFail("iOSApp/Info.plist not found at path: \(plistURL.path)")
            return
        }

        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            XCTFail("Failed to deserialize iOSApp/Info.plist as dictionary")
            return
        }

        // 1. Verify UIBackgroundModes contains audio and only justified modes
        let bgModes = plist["UIBackgroundModes"] as? [String]
        XCTAssertNotNil(bgModes, "UIBackgroundModes must be present in Info.plist")
        XCTAssertTrue(bgModes?.contains("audio") == true, "UIBackgroundModes must contain 'audio' for background playback and lock-screen routing")
        XCTAssertFalse(bgModes?.contains("fetch") == true, "UIBackgroundModes should not contain 'fetch' unless actively scheduled")
        XCTAssertFalse(bgModes?.contains("processing") == true, "UIBackgroundModes should not contain 'processing' unless actively scheduled")

        // 2. Verify Privacy Permissions for supported features
        let cameraDesc = plist["NSCameraUsageDescription"] as? String
        XCTAssertNotNil(cameraDesc, "NSCameraUsageDescription must be declared for WebKit site camera access")
        XCTAssertFalse(cameraDesc?.isEmpty ?? true, "NSCameraUsageDescription must be non-empty")

        let micDesc = plist["NSMicrophoneUsageDescription"] as? String
        XCTAssertNotNil(micDesc, "NSMicrophoneUsageDescription must be declared for WebKit site microphone access")
        XCTAssertFalse(micDesc?.isEmpty ?? true, "NSMicrophoneUsageDescription must be non-empty")

        let locDesc = plist["NSLocationWhenInUseUsageDescription"] as? String
        XCTAssertNotNil(locDesc, "NSLocationWhenInUseUsageDescription must be declared for WebKit site geolocation access")
        XCTAssertFalse(locDesc?.isEmpty ?? true, "NSLocationWhenInUseUsageDescription must be non-empty")

        let photoDesc = plist["NSPhotoLibraryAddUsageDescription"] as? String
        XCTAssertNotNil(photoDesc, "NSPhotoLibraryAddUsageDescription must be declared for saving downloaded media")
        XCTAssertFalse(photoDesc?.isEmpty ?? true, "NSPhotoLibraryAddUsageDescription must be non-empty")

        let localNetDesc = plist["NSLocalNetworkUsageDescription"] as? String
        XCTAssertNotNil(localNetDesc, "NSLocalNetworkUsageDescription must be declared for BitTorrent local peer discovery")
        XCTAssertFalse(localNetDesc?.isEmpty ?? true, "NSLocalNetworkUsageDescription must be non-empty")

        // 3. Verify Documents & Files app accessibility
        XCTAssertEqual(plist["UIFileSharingEnabled"] as? Bool, true, "UIFileSharingEnabled must be true for Files app visibility")
        XCTAssertEqual(plist["LSSupportsOpeningDocumentsInPlace"] as? Bool, true, "LSSupportsOpeningDocumentsInPlace must be true")
    }

    #if os(iOS) && canImport(AVFoundation)
    func testAudioSessionConfigurationMethods() {
        // Verify audio session configuration and deactivation cycle execute safely
        LIDPlaybackEngine.configureAudioSession()
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .moviePlayback)

        LIDPlaybackEngine.deactivateAudioSession()
    }
    #endif
}
