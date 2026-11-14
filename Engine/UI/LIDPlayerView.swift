import Foundation

#if canImport(SwiftUI)
import SwiftUI

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(WebKit)
import WebKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AVFoundation) && canImport(UIKit)
/// Custom UIView whose backing CoreAnimation layer is an AVPlayerLayer.
public final class LIDPlayerLayerView: UIView {
    override public class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    public var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

/// Hardware-accelerated native AVPlayerLayer representable.
public struct LIDNativePlayerLayerView: UIViewRepresentable {
    public let player: AVPlayer?
    public let videoGravity: AVLayerVideoGravity

    public init(player: AVPlayer?, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.player = player
        self.videoGravity = videoGravity
    }

    public func makeUIView(context: Context) -> LIDPlayerLayerView {
        let view = LIDPlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    public func updateUIView(_ uiView: LIDPlayerLayerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }
}
#endif

/// Dedicated native VLC-style media player with gesture controls (volume/brightness swipes,
/// horizontal seek, double-tap 10s skip, aspect ratio cycling, and speed adjustment).
public struct LIDPlayerView: View {
    public let url: URL
    public let title: String
    public var onDismiss: (() -> Void)? = nil

    @StateObject private var engine = LIDPlaybackEngine.shared
    @Environment(\.presentationMode) private var presentationMode

    @State private var showControls: Bool = true
    @State private var controlsTimer: Timer? = nil
    @State private var aspectRatio: LIDAspectRatio = .original
    @State private var isDraggingScrubber: Bool = false
    @State private var scrubPosition: Double = 0.0

    // Gesture state HUD overlays
    @State private var brightnessLevel: Double = 0.5
    @State private var showBrightnessHUD: Bool = false
    @State private var volumeLevel: Double = 1.0
    @State private var showVolumeHUD: Bool = false
    @State private var seekGestureOffset: Double = 0.0
    @State private var showSeekHUD: Bool = false
    @State private var isLongPressingSpeedBoost: Bool = false
    @State private var previousSpeedBeforeBoost: LIDPlaybackSpeed = .speed1_00

    public init(url: URL, title: String? = nil, onDismiss: (() -> Void)? = nil) {
        self.url = url
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            self.title = title
        } else {
            let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            self.title = last.isEmpty ? (url.host ?? "LID Media Player") : last
        }
        self.onDismiss = onDismiss
    }

    private var videoGravity: AVLayerVideoGravity {
        #if canImport(AVFoundation)
        switch aspectRatio {
        case .original, .fit16x9, .fit4x3:
            return .resizeAspect
        case .fill, .stretch:
            return .resizeAspectFill
        }
        #else
        return .resizeAspect
        #endif
    }

    public var body: some View {
        ZStack {
            Color.black
                .edgesIgnoringSafeArea(.all)

            #if canImport(AVFoundation) && canImport(UIKit)
            // Native Hardware-Accelerated Video Layer
            LIDNativePlayerLayerView(player: engine.player, videoGravity: videoGravity)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    toggleControlsVisibility()
                }
            #else
            fallbackView
            #endif

            // Gesture Detection Layer (Splits left/right half for vertical gestures)
            gestureOverlayView

            // HUD Feedback Overlays (Brightness, Volume, Seek, 2x Boost)
            hudOverlayView

            // VLC-style Controls Overlay
            if showControls {
                controlsOverlayView
                    .transition(.opacity)
            }
        }
        .onAppear {
            let source: LIDPlayerSource = url.pathExtension.lowercased() == "m3u8"
                ? .hlsStream(url: url, variantPreferences: nil, title: title)
                : (url.isFileURL ? .localFile(url: url, title: title) : .networkStream(url: url, headers: [:], title: title))
            engine.load(source: source, autoPlay: true, resumeFromHistory: true)
            resetControlsTimer()
        }
        .onDisappear {
            engine.stop()
            controlsTimer?.invalidate()
        }
    }

    // MARK: - Gesture Overlay Layer

    private var gestureOverlayView: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                // Left Half: Brightness Swipe & Double-Tap Rewind
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 15)
                            .onChanged { value in
                                showControls = false
                                showBrightnessHUD = true
                                let delta = -Double(value.translation.height) / Double(proxy.size.height)
                                brightnessLevel = max(0.0, min(1.0, brightnessLevel + delta * 0.05))
                                #if canImport(UIKit)
                                UIScreen.main.brightness = CGFloat(brightnessLevel)
                                #endif
                            }
                            .onEnded { _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    showBrightnessHUD = false
                                }
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            engine.seekBy(offsetSeconds: -10)
                            showTemporaryHUD("⏪ 10s")
                        }
                    )

                // Right Half: Volume Swipe & Double-Tap Forward
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 15)
                            .onChanged { value in
                                showControls = false
                                showVolumeHUD = true
                                let delta = -Double(value.translation.height) / Double(proxy.size.height)
                                volumeLevel = max(0.0, min(1.0, volumeLevel + delta * 0.05))
                                engine.setVolume(Float(volumeLevel))
                            }
                            .onEnded { _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    showVolumeHUD = false
                                }
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            engine.seekBy(offsetSeconds: 10)
                            showTemporaryHUD("⏩ 10s")
                        }
                    )
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.6)
                    .onChanged { _ in
                        if !isLongPressingSpeedBoost {
                            isLongPressingSpeedBoost = true
                            previousSpeedBeforeBoost = engine.playbackSpeed
                            engine.setPlaybackSpeed(.speed2_00)
                        }
                    }
                    .onEnded { _ in
                        isLongPressingSpeedBoost = false
                        engine.setPlaybackSpeed(previousSpeedBeforeBoost)
                    }
            )
        }
    }

    // MARK: - HUD Feedback Overlays

    private var hudOverlayView: some View {
        VStack {
            if isLongPressingSpeedBoost {
                HStack(spacing: 8) {
                    Image(systemName: "forward.fill")
                    Text("2× Speed Boost")
                        .font(.subheadline.bold())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.75))
                .foregroundColor(.yellow)
                .cornerRadius(20)
                .padding(.top, 50)
            }

            if showBrightnessHUD {
                hudPill(icon: "sun.max.fill", label: "Brightness", value: brightnessLevel)
            }

            if showVolumeHUD {
                hudPill(icon: volumeLevel > 0 ? "speaker.wave.3.fill" : "speaker.slash.fill", label: "Volume", value: volumeLevel)
            }

            if showSeekHUD {
                Text(seekHUDText)
                    .font(.headline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(12)
            }
        }
    }

    private func hudPill(icon: String, label: String, value: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.white)
            ProgressView(value: value, total: 1.0)
                .accentColor(.blue)
                .frame(width: 120)
            Text("\(Int(value * 100))%")
                .font(.caption.bold())
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.8))
        .cornerRadius(20)
    }

    @State private var temporaryHUDText: String? = nil
    private func showTemporaryHUD(_ text: String) {
        temporaryHUDText = text
        showSeekHUD = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showSeekHUD = false
        }
    }

    private var seekHUDText: String {
        temporaryHUDText ?? "\(formatTime(engine.currentPositionSeconds)) / \(formatTime(engine.durationSeconds))"
    }

    // MARK: - Controls Overlay View

    private var controlsOverlayView: some View {
        VStack {
            // Header Bar
            HStack(spacing: 16) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                // Aspect Ratio Selector Button
                Button {
                    cycleAspectRatio()
                } label: {
                    Text(aspectRatio.rawValue)
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.2))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }

                // Close / Done
                Button("Done") {
                    dismiss()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.7), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()

            // Center Play / Pause & 10s Skip
            HStack(spacing: 40) {
                Button {
                    engine.seekBy(offsetSeconds: -10)
                    resetControlsTimer()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }

                if engine.playbackState.isBuffering {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.6)
                } else {
                    Button {
                        engine.togglePlayPause()
                        resetControlsTimer()
                    } label: {
                        Image(systemName: engine.playbackState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.white)
                    }
                }

                Button {
                    engine.seekBy(offsetSeconds: 10)
                    resetControlsTimer()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }
            }

            Spacer()

            // Footer Timeline & Speed Bar
            VStack(spacing: 6) {
                // Interactive Scrubber
                HStack(spacing: 12) {
                    Text(formatTime(isDraggingScrubber ? scrubPosition : engine.currentPositionSeconds))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)

                    Slider(
                        value: Binding(
                            get: { isDraggingScrubber ? scrubPosition : engine.currentPositionSeconds },
                            set: { newValue in
                                isDraggingScrubber = true
                                scrubPosition = newValue
                            }
                        ),
                        in: 0...max(1.0, engine.durationSeconds),
                        onEditingChanged: { editing in
                            if !editing {
                                engine.seek(to: scrubPosition)
                                isDraggingScrubber = false
                                resetControlsTimer()
                            }
                        }
                    )
                    .accentColor(.blue)

                    Text(formatTime(engine.durationSeconds))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }

                // Speed, Mute, and Specs Bar
                HStack(spacing: 16) {
                    // Playback Speed Button
                    Button {
                        cyclePlaybackSpeed()
                        resetControlsTimer()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "gauge.with.needle")
                                .font(.system(size: 12))
                            Text(engine.playbackSpeed.label)
                                .font(.system(size: 12, weight: .bold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.18))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }

                    // Mute / Unmute
                    Button {
                        engine.toggleMute()
                        resetControlsTimer()
                    } label: {
                        Image(systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }

                    Spacer()

                    if let res = engine.metadata.naturalWidth, let h = engine.metadata.naturalHeight {
                        Text("\(Int(res))×\(Int(h))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .background(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.8)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var fallbackView: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            Text(url.absoluteString)
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(2)
        }
        .padding()
    }

    // MARK: - Actions

    private func dismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }

    private func toggleControlsVisibility() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls {
            resetControlsTimer()
        }
    }

    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                if engine.playbackState.isPlaying {
                    showControls = false
                }
            }
        }
    }

    private func cycleAspectRatio() {
        let all = LIDAspectRatio.allCases
        if let idx = all.firstIndex(of: aspectRatio) {
            let next = all[(idx + 1) % all.count]
            aspectRatio = next
            showTemporaryHUD(next.rawValue)
        }
    }

    private func cyclePlaybackSpeed() {
        let speeds = LIDPlaybackSpeed.allCases
        if let idx = speeds.firstIndex(of: engine.playbackSpeed) {
            let next = speeds[(idx + 1) % speeds.count]
            engine.setPlaybackSpeed(next)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && !seconds.isNaN && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}

extension View {
    /// Presents the full-screen LID Player on iOS, falling back to sheet presentation on macOS.
    @ViewBuilder
    public func lidPlayerPresentation(url: Binding<URL?>, title: String) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: Binding<IdentifiableURL?>(
            get: { url.wrappedValue.map { IdentifiableURL(url: $0) } },
            set: { url.wrappedValue = $0?.url }
        )) { item in
            LIDPlayerView(url: item.url, title: title) {
                url.wrappedValue = nil
            }
        }
        #else
        self.sheet(item: Binding<IdentifiableURL?>(
            get: { url.wrappedValue.map { IdentifiableURL(url: $0) } },
            set: { url.wrappedValue = $0?.url }
        )) { item in
            LIDPlayerView(url: item.url, title: title) {
                url.wrappedValue = nil
            }
        }
        #endif
    }
}
#endif
