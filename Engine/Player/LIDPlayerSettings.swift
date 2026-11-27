import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// User-selectable text color for subtitle captions.
public enum LIDPlayerSubtitleColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case white = "White"
    case yellow = "Yellow"
    case green = "Green"
    case cyan = "Cyan"

    public var id: String { rawValue }

    #if canImport(SwiftUI)
    public var swiftUIColor: Color {
        switch self {
        case .white: return .white
        case .yellow: return .yellow
        case .green: return .green
        case .cyan: return .cyan
        }
    }
    #endif
}

/// Preferred screen orientation policy when media player launches.
public enum LIDPlayerOrientationPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "Auto (Sensor)"
    case landscape = "Landscape"
    case portrait = "Portrait"

    public var id: String { rawValue }
}

/// Persistent user-facing preferences for the LID Media Player.
/// Stored independently in UserDefaults under key `DownloadEngineKit.LIDPlayerSettings`.
public struct LIDPlayerSettings: Codable, Sendable, Equatable, SchemaVersioned {
    public static let currentVersion: Int = 1
    public static var currentSchemaVersion: Int { currentVersion }
    public static let userDefaultsKey = "DownloadEngineKit.LIDPlayerSettings"

    public var version: Int
    public var schemaVersion: Int { version }

    // MARK: - Playback Behavior
    public var defaultPlaybackSpeed: Double
    public var rememberPlaybackSpeed: Bool
    public var lastSelectedPlaybackSpeed: Double?
    public var defaultAspectRatio: LIDAspectRatio
    public var seekIntervalSeconds: Int
    public var autoHideControlsSeconds: Int
    public var resumePlaybackPosition: Bool

    /// Resolves the effective initial playback rate for a new session according to user preferences.
    public var effectivePlaybackSpeed: Double {
        if rememberPlaybackSpeed, let last = lastSelectedPlaybackSpeed, last > 0 {
            return max(0.25, min(2.0, last))
        }
        return max(0.25, min(2.0, defaultPlaybackSpeed))
    }

    // MARK: - Subtitles & Captions
    public var autoLoadSubtitles: Bool
    public var autoLoadSiblingSubtitles: Bool {
        get { autoLoadSubtitles }
        set { autoLoadSubtitles = newValue }
    }
    public var rememberSubtitleTrack: Bool
    public var defaultSubtitleLanguage: String
    public var subtitleFontSize: Double
    public var subtitleTextColor: LIDPlayerSubtitleColor
    public var subtitleBackgroundOpacity: Double
    public var subtitleDelayStepMs: Int

    // MARK: - Audio
    public var defaultAudioLanguage: String
    public var rememberAudioTrack: Bool
    public var enableBackgroundAudio: Bool

    // MARK: - Gestures & Controls
    public var enableBrightnessGesture: Bool
    public var enableVolumeGesture: Bool
    public var enableSeekGesture: Bool
    public var enableDoubleTapSeek: Bool
    public var enablePinchToZoom: Bool
    public var enableTwoXSpeedBoostGesture: Bool

    // MARK: - Display & Orientation
    public var defaultOrientation: LIDPlayerOrientationPreference

    public static let `default` = LIDPlayerSettings(
        version: currentVersion,
        defaultPlaybackSpeed: 1.0,
        rememberPlaybackSpeed: true,
        lastSelectedPlaybackSpeed: nil,
        defaultAspectRatio: .original,
        seekIntervalSeconds: 10,
        autoHideControlsSeconds: 4,
        resumePlaybackPosition: true,
        autoLoadSubtitles: true,
        rememberSubtitleTrack: true,
        defaultSubtitleLanguage: "Any",
        subtitleFontSize: 16.0,
        subtitleTextColor: .white,
        subtitleBackgroundOpacity: 0.75,
        subtitleDelayStepMs: 100,
        defaultAudioLanguage: "Any",
        rememberAudioTrack: true,
        enableBackgroundAudio: true,
        enableBrightnessGesture: true,
        enableVolumeGesture: true,
        enableSeekGesture: true,
        enableDoubleTapSeek: true,
        enablePinchToZoom: true,
        enableTwoXSpeedBoostGesture: true,
        defaultOrientation: .auto
    )

    public init(
        version: Int = currentVersion,
        defaultPlaybackSpeed: Double = 1.0,
        rememberPlaybackSpeed: Bool = true,
        lastSelectedPlaybackSpeed: Double? = nil,
        defaultAspectRatio: LIDAspectRatio = .original,
        seekIntervalSeconds: Int = 10,
        autoHideControlsSeconds: Int = 4,
        resumePlaybackPosition: Bool = true,
        autoLoadSubtitles: Bool = true,
        rememberSubtitleTrack: Bool = true,
        defaultSubtitleLanguage: String = "Any",
        subtitleFontSize: Double = 16.0,
        subtitleTextColor: LIDPlayerSubtitleColor = .white,
        subtitleBackgroundOpacity: Double = 0.75,
        subtitleDelayStepMs: Int = 100,
        defaultAudioLanguage: String = "Any",
        rememberAudioTrack: Bool = true,
        enableBackgroundAudio: Bool = true,
        enableBrightnessGesture: Bool = true,
        enableVolumeGesture: Bool = true,
        enableSeekGesture: Bool = true,
        enableDoubleTapSeek: Bool = true,
        enablePinchToZoom: Bool = true,
        enableTwoXSpeedBoostGesture: Bool = true,
        defaultOrientation: LIDPlayerOrientationPreference = .auto
    ) {
        self.version = version
        self.defaultPlaybackSpeed = defaultPlaybackSpeed
        self.rememberPlaybackSpeed = rememberPlaybackSpeed
        self.lastSelectedPlaybackSpeed = lastSelectedPlaybackSpeed
        self.defaultAspectRatio = defaultAspectRatio
        self.seekIntervalSeconds = seekIntervalSeconds
        self.autoHideControlsSeconds = autoHideControlsSeconds
        self.resumePlaybackPosition = resumePlaybackPosition
        self.autoLoadSubtitles = autoLoadSubtitles
        self.rememberSubtitleTrack = rememberSubtitleTrack
        self.defaultSubtitleLanguage = defaultSubtitleLanguage
        self.subtitleFontSize = subtitleFontSize
        self.subtitleTextColor = subtitleTextColor
        self.subtitleBackgroundOpacity = subtitleBackgroundOpacity
        self.subtitleDelayStepMs = subtitleDelayStepMs
        self.defaultAudioLanguage = defaultAudioLanguage
        self.rememberAudioTrack = rememberAudioTrack
        self.enableBackgroundAudio = enableBackgroundAudio
        self.enableBrightnessGesture = enableBrightnessGesture
        self.enableVolumeGesture = enableVolumeGesture
        self.enableSeekGesture = enableSeekGesture
        self.enableDoubleTapSeek = enableDoubleTapSeek
        self.enablePinchToZoom = enablePinchToZoom
        self.enableTwoXSpeedBoostGesture = enableTwoXSpeedBoostGesture
        self.defaultOrientation = defaultOrientation
        validateAndClamp()
    }

    // Resilient decoder with safe fallbacks and range validation for each field
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.defaultPlaybackSpeed = try container.decodeIfPresent(Double.self, forKey: .defaultPlaybackSpeed) ?? 1.0
        self.rememberPlaybackSpeed = try container.decodeIfPresent(Bool.self, forKey: .rememberPlaybackSpeed) ?? true
        self.lastSelectedPlaybackSpeed = try container.decodeIfPresent(Double.self, forKey: .lastSelectedPlaybackSpeed)
        self.defaultAspectRatio = try container.decodeIfPresent(LIDAspectRatio.self, forKey: .defaultAspectRatio) ?? .original
        self.seekIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .seekIntervalSeconds) ?? 10
        self.autoHideControlsSeconds = try container.decodeIfPresent(Int.self, forKey: .autoHideControlsSeconds) ?? 4
        self.resumePlaybackPosition = try container.decodeIfPresent(Bool.self, forKey: .resumePlaybackPosition) ?? true

        self.autoLoadSubtitles = try container.decodeIfPresent(Bool.self, forKey: .autoLoadSubtitles) ?? true
        self.rememberSubtitleTrack = try container.decodeIfPresent(Bool.self, forKey: .rememberSubtitleTrack) ?? true
        self.defaultSubtitleLanguage = try container.decodeIfPresent(String.self, forKey: .defaultSubtitleLanguage) ?? "Any"
        self.subtitleFontSize = try container.decodeIfPresent(Double.self, forKey: .subtitleFontSize) ?? 16.0
        self.subtitleTextColor = try container.decodeIfPresent(LIDPlayerSubtitleColor.self, forKey: .subtitleTextColor) ?? .white
        self.subtitleBackgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .subtitleBackgroundOpacity) ?? 0.75
        self.subtitleDelayStepMs = try container.decodeIfPresent(Int.self, forKey: .subtitleDelayStepMs) ?? 100

        self.defaultAudioLanguage = try container.decodeIfPresent(String.self, forKey: .defaultAudioLanguage) ?? "Any"
        self.rememberAudioTrack = try container.decodeIfPresent(Bool.self, forKey: .rememberAudioTrack) ?? true
        self.enableBackgroundAudio = try container.decodeIfPresent(Bool.self, forKey: .enableBackgroundAudio) ?? true

        self.enableBrightnessGesture = try container.decodeIfPresent(Bool.self, forKey: .enableBrightnessGesture) ?? true
        self.enableVolumeGesture = try container.decodeIfPresent(Bool.self, forKey: .enableVolumeGesture) ?? true
        self.enableSeekGesture = try container.decodeIfPresent(Bool.self, forKey: .enableSeekGesture) ?? true
        self.enableDoubleTapSeek = try container.decodeIfPresent(Bool.self, forKey: .enableDoubleTapSeek) ?? true
        self.enablePinchToZoom = try container.decodeIfPresent(Bool.self, forKey: .enablePinchToZoom) ?? true
        self.enableTwoXSpeedBoostGesture = try container.decodeIfPresent(Bool.self, forKey: .enableTwoXSpeedBoostGesture) ?? true

        self.defaultOrientation = try container.decodeIfPresent(LIDPlayerOrientationPreference.self, forKey: .defaultOrientation) ?? .auto
        validateAndClamp()
    }

    /// Validates and clamps persisted values to safe runtime engine ranges.
    public mutating func validateAndClamp() {
        self.defaultPlaybackSpeed = max(0.25, min(2.0, self.defaultPlaybackSpeed))
        if let last = self.lastSelectedPlaybackSpeed {
            self.lastSelectedPlaybackSpeed = max(0.25, min(2.0, last))
        }
        self.subtitleFontSize = max(12.0, min(32.0, self.subtitleFontSize))
        self.subtitleBackgroundOpacity = max(0.0, min(1.0, self.subtitleBackgroundOpacity))
        if ![5, 10, 15, 30].contains(self.seekIntervalSeconds) {
            self.seekIntervalSeconds = 10
        }
        if ![0, 2, 3, 4, 5, 8].contains(self.autoHideControlsSeconds) {
            self.autoHideControlsSeconds = 4
        }
        if ![50, 100, 250, 500].contains(self.subtitleDelayStepMs) {
            self.subtitleDelayStepMs = 100
        }
    }
}

/// Observable store managing persistence and reactive state for `LIDPlayerSettings`.
@MainActor
public final class LIDPlayerSettingsStore: ObservableObject {
    public static let shared = LIDPlayerSettingsStore()

    @Published public var settings: LIDPlayerSettings {
        didSet {
            save()
        }
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.settings = DurableStorage.loadFromUserDefaults(
            LIDPlayerSettings.self,
            forKey: LIDPlayerSettings.userDefaultsKey,
            defaults: userDefaults,
            migrate: { decoded in
                var migrated = decoded
                migrated.version = LIDPlayerSettings.currentVersion
                return migrated
            }
        ) ?? .default
    }

    public func save() {
        DurableStorage.saveToUserDefaults(settings, forKey: LIDPlayerSettings.userDefaultsKey, defaults: userDefaults)
    }

    public func resetToDefaults() {
        self.settings = .default
    }
}
