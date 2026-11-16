#if canImport(SwiftUI)
import SwiftUI

/// Dedicated sub-settings screen for LID Media Player playback behavior, aspect ratio,
/// subtitles styling, audio track defaults, VLC-style gesture controls, and display orientation.
public struct MediaPlayerSettingsView: View {
    @ObservedObject public var settingsStore: LIDPlayerSettingsStore = .shared

    private let availableSpeeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private let availableSeekIntervals: [Int] = [5, 10, 15, 30]
    private let availableAutoHideIntervals: [(label: String, seconds: Int)] = [
        ("2 seconds", 2),
        ("3 seconds", 3),
        ("4 seconds (Default)", 4),
        ("5 seconds", 5),
        ("8 seconds", 8),
        ("Never", 0)
    ]
    private let commonLanguages: [String] = [
        "Any", "English", "Spanish", "French", "German", "Japanese", "Chinese", "Arabic", "Portuguese", "Russian"
    ]
    private let availableDelaySteps: [Int] = [50, 100, 250, 500]

    public init() {}

    public var body: some View {
        Form {
            // Section 1: Playback Behavior
            Section(
                header: Text("Playback Behavior"),
                footer: Text("Controls default playback rate, aspect ratio framing, seek increments, and HUD timer.")
            ) {
                Picker("Default Playback Speed", selection: $settingsStore.settings.defaultPlaybackSpeed) {
                    ForEach(availableSpeeds, id: \.self) { speed in
                        Text(String(format: "%.2f×", speed)).tag(speed)
                    }
                }

                Toggle("Remember Last Playback Speed", isOn: $settingsStore.settings.rememberPlaybackSpeed)

                Picker("Default Aspect Ratio", selection: $settingsStore.settings.defaultAspectRatio) {
                    ForEach(LIDAspectRatio.allCases, id: \.self) { ratio in
                        Text(ratio.displayName).tag(ratio)
                    }
                }

                Toggle("Resume Playback Position", isOn: $settingsStore.settings.resumePlaybackPosition)

                Picker("Seek Interval", selection: $settingsStore.settings.seekIntervalSeconds) {
                    ForEach(availableSeekIntervals, id: \.self) { interval in
                        Text("\(interval) seconds").tag(interval)
                    }
                }

                Picker("Auto-Hide Controls", selection: $settingsStore.settings.autoHideControlsSeconds) {
                    ForEach(availableAutoHideIntervals, id: \.seconds) { item in
                        Text(item.label).tag(item.seconds)
                    }
                }
            }

            // Section 2: Subtitles & Captions
            Section(
                header: Text("Subtitles & Captions"),
                footer: Text("Customize typography, colors, opacity, and auto-discovery for local and embedded subtitles.")
            ) {
                Toggle("Auto-Load Sibling Subtitles", isOn: $settingsStore.settings.autoLoadSubtitles)

                Toggle("Remember Subtitle Selection", isOn: $settingsStore.settings.rememberSubtitleTrack)

                Picker("Preferred Subtitle Language", selection: $settingsStore.settings.defaultSubtitleLanguage) {
                    ForEach(commonLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }

                Stepper("Subtitle Font Size: \(Int(settingsStore.settings.subtitleFontSize)) pt", value: $settingsStore.settings.subtitleFontSize, in: 12...32, step: 1)

                Picker("Subtitle Text Color", selection: $settingsStore.settings.subtitleTextColor) {
                    ForEach(LIDPlayerSubtitleColor.allCases) { color in
                        Text(color.rawValue).tag(color)
                    }
                }

                HStack {
                    Text("Background Opacity")
                    Spacer()
                    Text("\(Int(settingsStore.settings.subtitleBackgroundOpacity * 100))%")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                Slider(value: $settingsStore.settings.subtitleBackgroundOpacity, in: 0.0...1.0, step: 0.05)

                Picker("Subtitle Delay Step", selection: $settingsStore.settings.subtitleDelayStepMs) {
                    ForEach(availableDelaySteps, id: \.self) { step in
                        Text("\(step) ms").tag(step)
                    }
                }

                // Live Subtitle Preview
                VStack(alignment: .center, spacing: 6) {
                    Text("Live Subtitle Preview")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ZStack {
                        Color.gray.opacity(0.2)
                            .frame(height: 70)
                            .cornerRadius(8)

                        Text("The quick brown fox jumps over the lazy dog.")
                            .font(.system(size: CGFloat(settingsStore.settings.subtitleFontSize), weight: .bold))
                            .foregroundColor(settingsStore.settings.subtitleTextColor.swiftUIColor)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(settingsStore.settings.subtitleBackgroundOpacity))
                            .cornerRadius(6)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 4)
            }

            // Section 3: Audio Tracks
            Section(
                header: Text("Audio Tracks"),
                footer: Text("Configure language selection preferences and background audio playback across iOS.")
            ) {
                Picker("Preferred Audio Language", selection: $settingsStore.settings.defaultAudioLanguage) {
                    ForEach(commonLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }

                Toggle("Remember Audio Track Selection", isOn: $settingsStore.settings.rememberAudioTrack)

                Toggle("Background Audio Playback", isOn: $settingsStore.settings.enableBackgroundAudio)
            }

            // Section 4: Gesture Controls
            Section(
                header: Text("Gestures & Controls"),
                footer: Text("Toggle VLC-style swipe, double-tap, and pinch gestures active on the media viewport.")
            ) {
                Toggle("Brightness Swipe (Left Edge)", isOn: $settingsStore.settings.enableBrightnessGesture)

                Toggle("Volume Swipe (Right Edge)", isOn: $settingsStore.settings.enableVolumeGesture)

                Toggle("Seek Swipe (Horizontal Drag)", isOn: $settingsStore.settings.enableSeekGesture)

                Toggle("Double-Tap to Seek", isOn: $settingsStore.settings.enableDoubleTapSeek)

                Toggle("Pinch to Zoom Video", isOn: $settingsStore.settings.enablePinchToZoom)

                Toggle("2× Speed Boost on Long-Press", isOn: $settingsStore.settings.enableTwoXSpeedBoostGesture)
            }

            // Section 5: Orientation & Display
            Section(
                header: Text("Display & Orientation"),
                footer: Text("Choose the default interface orientation when launching full-screen playback.")
            ) {
                Picker("Default Screen Orientation", selection: $settingsStore.settings.defaultOrientation) {
                    ForEach(LIDPlayerOrientationPreference.allCases) { pref in
                        Text(pref.rawValue).tag(pref)
                    }
                }
            }

            // Section 6: Reset Action
            Section {
                Button(role: .destructive) {
                    settingsStore.resetToDefaults()
                } label: {
                    HStack {
                        Spacer()
                        Text("Reset Player Settings to Defaults")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Media Player Settings")
    }
}
#endif
