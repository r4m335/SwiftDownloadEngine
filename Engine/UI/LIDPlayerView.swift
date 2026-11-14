import Foundation

#if canImport(SwiftUI)
import SwiftUI

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVKit)
import AVKit
#endif

#if canImport(WebKit)
import WebKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AVFoundation) && canImport(UIKit) && canImport(AVKit)
/// Custom UIView whose backing CoreAnimation layer is an AVPlayerLayer with PiP support.
public final class LIDPlayerLayerView: UIView, AVPictureInPictureControllerDelegate {
    override public class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    public var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    public private(set) var pipController: AVPictureInPictureController?

    public func setupPiP() {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController?.delegate = self
    }

    public func togglePiP() {
        setupPiP()
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }
}

/// Hardware-accelerated native AVPlayerLayer representable with PiP handle.
public struct LIDNativePlayerLayerView: UIViewRepresentable {
    public let player: AVPlayer?
    public let videoGravity: AVLayerVideoGravity
    public let onLayerReady: ((LIDPlayerLayerView) -> Void)?

    public init(
        player: AVPlayer?,
        videoGravity: AVLayerVideoGravity = .resizeAspect,
        onLayerReady: ((LIDPlayerLayerView) -> Void)? = nil
    ) {
        self.player = player
        self.videoGravity = videoGravity
        self.onLayerReady = onLayerReady
    }

    public func makeUIView(context: Context) -> LIDPlayerLayerView {
        let view = LIDPlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.setupPiP()
        onLayerReady?(view)
        return view
    }

    public func updateUIView(_ uiView: LIDPlayerLayerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
        uiView.setupPiP()
    }
}
#endif

/// Dedicated native VLC-style media player with gesture controls, PiP, audio track selection,
/// external/embedded subtitles, synchronization delay adjustment, and interactive lock mode.
public struct LIDPlayerView: View {
    public let url: URL
    public let title: String
    public var onDismiss: (() -> Void)? = nil

    @StateObject private var engine = LIDPlaybackEngine.shared
    @Environment(\.presentationMode) private var presentationMode

    // Controls state
    @State private var showControls: Bool = true
    @State private var controlsTimer: Timer? = nil
    @State private var isControlsLocked: Bool = false
    @State private var aspectRatio: LIDAspectRatio = .original
    @State private var isDraggingScrubber: Bool = false
    @State private var scrubPosition: Double = 0.0
    @State private var showRemainingTime: Bool = false
    @State private var zoomScale: CGFloat = 1.0

    // Sheet presentations
    @State private var showTrackSelectionSheet: Bool = false
    @State private var showSubtitleSyncSheet: Bool = false
    @State private var externalSubtitlePathInput: String = ""
    @State private var showExternalSubtitlePrompt: Bool = false

    // Gesture state HUD overlays
    @State private var brightnessLevel: Double = 0.5
    @State private var showBrightnessHUD: Bool = false
    @State private var volumeLevel: Double = 1.0
    @State private var showVolumeHUD: Bool = false
    @State private var seekGestureOffset: Double = 0.0
    @State private var showSeekHUD: Bool = false
    @State private var seekHUDText: String = ""
    @State private var isLongPressingSpeedBoost: Bool = false
    @State private var previousSpeedBeforeBoost: LIDPlaybackSpeed = .speed1_00

    #if canImport(AVFoundation) && canImport(UIKit) && canImport(AVKit)
    @State private var layerViewRef: LIDPlayerLayerView? = nil
    #endif

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

            #if canImport(AVFoundation) && canImport(UIKit) && canImport(AVKit)
            // Native Hardware-Accelerated Video Layer with Interactive Zoom
            LIDNativePlayerLayerView(player: engine.player, videoGravity: videoGravity) { layer in
                self.layerViewRef = layer
            }
            .scaleEffect(zoomScale)
            .edgesIgnoringSafeArea(.all)
            .gesture(
                MagnificationGesture()
                    .onChanged { scale in
                        zoomScale = max(0.8, min(3.0, scale))
                    }
                    .onEnded { _ in
                        if zoomScale < 1.05 && zoomScale > 0.95 {
                            zoomScale = 1.0
                        }
                    }
            )
            .onTapGesture {
                if !isControlsLocked {
                    toggleControlsVisibility()
                }
            }
            #else
            fallbackView
            #endif

            // Subtitle Display Overlay
            if let cueText = engine.trackManager.activeCueText, !cueText.isEmpty {
                VStack {
                    Spacer()
                    Text(cueText)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(8)
                        .padding(.horizontal, 24)
                        .padding(.bottom, showControls && !isControlsLocked ? 95 : 32)
                }
                .allowsHitTesting(false)
            }

            // Gesture Detection Layer (Disabled when locked)
            if !isControlsLocked {
                gestureOverlayView
            }

            // HUD Feedback Overlays (Brightness, Volume, Seek, 2x Boost)
            hudOverlayView

            // Controls Overlay
            if showControls && !isControlsLocked {
                controlsOverlayView
                    .transition(.opacity)
            }

            // Floating Lock / Unlock Button when locked
            if isControlsLocked {
                VStack {
                    HStack {
                        Button {
                            withAnimation {
                                isControlsLocked = false
                                showControls = true
                                resetControlsTimer()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill")
                                Text("Locked (Tap to Unlock)")
                                    .font(.caption.bold())
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.8))
                            .foregroundColor(.yellow)
                            .cornerRadius(20)
                        }
                        .padding(.leading, 20)
                        .padding(.top, 24)

                        Spacer()
                    }
                    Spacer()
                }
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
        .sheet(isPresented: $showTrackSelectionSheet) {
            trackSelectionSheetView
        }
        .sheet(isPresented: $showSubtitleSyncSheet) {
            subtitleSyncSheetView
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
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(12)
                    .padding(.top, 60)
            }

            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func hudPill(icon: String, label: String, value: Double) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                Text(label)
                    .font(.caption.bold())
                    .foregroundColor(.white)
            }
            GeometryReader { p in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 6)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(0, min(CGFloat(value) * p.size.width, p.size.width)), height: 6)
                }
            }
            .frame(width: 140, height: 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.75))
        .cornerRadius(14)
        .padding(.top, 60)
    }

    // MARK: - VLC-Style Controls Overlay

    private var controlsOverlayView: some View {
        VStack {
            // Header Bar
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
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

                // Picture-in-Picture Button
                #if canImport(AVFoundation) && canImport(UIKit) && canImport(AVKit)
                if AVPictureInPictureController.isPictureInPictureSupported() {
                    Button {
                        layerViewRef?.togglePiP()
                    } label: {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                }
                #endif

                // Subtitles & Audio Track Selector
                Button {
                    showTrackSelectionSheet = true
                } label: {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Circle())
                }

                // Subtitle Delay / Sync Adjuster
                Button {
                    showSubtitleSyncSheet = true
                } label: {
                    Image(systemName: "timer")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Circle())
                }

                // Lock Controls Button
                Button {
                    withAnimation {
                        isControlsLocked = true
                        showControls = false
                    }
                } label: {
                    Image(systemName: "lock")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Circle())
                }

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

                    // Toggle duration between total time and remaining time
                    Button {
                        showRemainingTime.toggle()
                    } label: {
                        if showRemainingTime {
                            let rem = max(0.0, engine.durationSeconds - (isDraggingScrubber ? scrubPosition : engine.currentPositionSeconds))
                            Text("-" + formatTime(rem))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                        } else {
                            Text(formatTime(engine.durationSeconds))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
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

    // MARK: - Track Selection Sheet

    private var trackSelectionSheetView: some View {
        NavigationView {
            List {
                // Audio Tracks Section
                Section(header: Text("Audio Tracks")) {
                    if engine.trackManager.availableAudioTracks.isEmpty {
                        Text("Default Audio Track")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(engine.trackManager.availableAudioTracks) { track in
                            Button {
                                engine.trackManager.selectAudioTrack(track)
                            } label: {
                                HStack {
                                    Text(track.displayName)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if engine.trackManager.selectedAudioTrack?.id == track.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                }

                // Subtitle Tracks Section
                Section(header: Text("Subtitles")) {
                    ForEach(engine.trackManager.availableSubtitleTracks) { track in
                        Button {
                            engine.trackManager.selectSubtitleTrack(track)
                        } label: {
                            HStack {
                                Text(track.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if engine.trackManager.selectedSubtitleTrack.id == track.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }

                    // Add External Subtitle Action
                    Button {
                        showExternalSubtitlePrompt = true
                    } label: {
                        Label("Add External Subtitle (.srt / .vtt)", systemImage: "plus.circle")
                            .foregroundColor(.blue)
                    }
                }

                // Subtitle Delay Quick Access
                Section {
                    Button {
                        showTrackSelectionSheet = false
                        showSubtitleSyncSheet = true
                    } label: {
                        HStack {
                            Label("Adjust Subtitle Sync", systemImage: "timer")
                            Spacer()
                            Text(String(format: "%+.1fs", engine.trackManager.subtitleDelay))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Audio & Subtitles")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showTrackSelectionSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Subtitle Delay Synchronization Sheet

    private var subtitleSyncSheetView: some View {
        NavigationView {
            VStack(spacing: 24) {
                Text("Subtitle Delay Offset")
                    .font(.headline)
                    .padding(.top, 20)

                Text(String(format: "%+.1f s", engine.trackManager.subtitleDelay))
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundColor(engine.trackManager.subtitleDelay == 0 ? .primary : .blue)

                Text(engine.trackManager.subtitleDelay > 0 ? "Subtitles appear later" : (engine.trackManager.subtitleDelay < 0 ? "Subtitles appear earlier" : "Synchronized"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button("-0.5s") {
                        engine.trackManager.adjustSubtitleDelay(by: -0.5)
                    }
                    .buttonStyle(.bordered)

                    Button("-0.1s") {
                        engine.trackManager.adjustSubtitleDelay(by: -0.1)
                    }
                    .buttonStyle(.bordered)

                    Button("Reset") {
                        engine.trackManager.subtitleDelay = 0.0
                    }
                    .buttonStyle(.borderedProminent)

                    Button("+0.1s") {
                        engine.trackManager.adjustSubtitleDelay(by: 0.1)
                    }
                    .buttonStyle(.bordered)

                    Button("+0.5s") {
                        engine.trackManager.adjustSubtitleDelay(by: 0.5)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Subtitle Sync")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showSubtitleSyncSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Helper Views & Methods

    private var fallbackView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundColor(.white)
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundColor(.gray)
        }
    }

    private func dismiss() {
        engine.stop()
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }

    private func toggleControlsVisibility() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showControls.toggle()
        }
        if showControls {
            resetControlsTimer()
        } else {
            controlsTimer?.invalidate()
        }
    }

    private func showTemporaryHUD(_ text: String) {
        seekHUDText = text
        showSeekHUD = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showSeekHUD = false
        }
    }

    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                if engine.playbackState.isPlaying && !isControlsLocked {
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
            zoomScale = 1.0
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
