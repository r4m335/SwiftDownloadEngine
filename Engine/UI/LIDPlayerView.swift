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
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller?.delegate = self
        if #available(iOS 14.2, *) {
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        pipController = controller
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
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
            PipelineLogger.shared.logPlayer(
                session: LIDPlaybackEngine.shared.currentSessionId,
                category: "VideoRenderer",
                message: "AVPlayerLayer attached to active player"
            )
        }
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
        uiView.setupPiP()
    }
}

public final class LIDVLCRenderingContainerView: UIView {
    public var onLayoutChange: ((CGRect, Int) -> Void)? = nil

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipsToBounds = true
    }

    public override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.frame = self.bounds
        subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        PipelineLogger.shared.logPlayer(
            session: LIDPlaybackEngine.activeSessionIdForLogging,
            category: "VideoRenderer",
            message: "LIDVLCRenderingContainerView didAddSubview: class=\(type(of: subview)), subviewFrame=\(subview.frame), containerBounds=\(self.bounds)"
        )
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews {
            if subview.frame != self.bounds && self.bounds.width > 0 && self.bounds.height > 0 {
                subview.frame = self.bounds
            }
        }
        onLayoutChange?(self.bounds, subviews.count)
    }
}

/// Native VLCKit rendering view representable bridging VLCMediaPlayer.drawable
public struct LIDVLCPlayerLayerView: UIViewRepresentable {
    public let backend: LIDVLCKitBackend

    public init(backend: LIDVLCKitBackend) {
        self.backend = backend
    }

    public func makeUIView(context: Context) -> LIDVLCRenderingContainerView {
        let view = LIDVLCRenderingContainerView(frame: .zero)
        view.onLayoutChange = { bounds, count in
            PipelineLogger.shared.logPlayer(
                session: LIDPlaybackEngine.activeSessionIdForLogging,
                category: "VideoRenderer",
                message: "ContainerView layoutSubviews: bounds=\(Int(bounds.width))x\(Int(bounds.height)), subviews=\(count)"
            )
        }
        backend.attachRenderingView(view)
        return view
    }

    public func updateUIView(_ uiView: LIDVLCRenderingContainerView, context: Context) {
        backend.attachRenderingView(uiView)
    }
}
#endif

/// Dedicated native VLC-style media player with gesture controls, PiP, audio track selection,
/// external/embedded subtitles, synchronization delay adjustment, and interactive lock mode.
public struct LIDPlayerView: View {
    public let source: LIDPlayerSource
    public var onDismiss: (() -> Void)? = nil

    public var url: URL {
        source.url ?? URL(string: "lidtorrent://\(source.title)")!
    }

    public var title: String {
        source.title
    }

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
    @State private var showSubtitleSearchSheet: Bool = false
    @State private var showDiagnosticsSheet: Bool = false
    @State private var externalSubtitlePathInput: String = ""
    @State private var showExternalSubtitlePrompt: Bool = false
    @State private var sessionId: String = String(UUID().uuidString.prefix(8).uppercased())

    // Gesture state HUD overlays
    @State private var brightnessLevel: Double = 0.5
    @State private var showBrightnessHUD: Bool = false
    @State private var volumeLevel: Double = 1.0
    @State private var showVolumeHUD: Bool = false
    @State private var gestureStartBrightness: Double = 0.5
    @State private var gestureStartVolume: Double = 1.0
    @State private var isDraggingBrightness: Bool = false
    @State private var isDraggingVolume: Bool = false
    @State private var seekGestureOffset: Double = 0.0
    @State private var showSeekHUD: Bool = false
    @State private var seekHUDText: String = ""

    #if canImport(AVFoundation) && canImport(UIKit) && canImport(AVKit)
    @State private var layerViewRef: LIDPlayerLayerView? = nil
    #endif

    public init(source: LIDPlayerSource, onDismiss: (() -> Void)? = nil) {
        self.source = source
        self.onDismiss = onDismiss
    }

    public init(url: URL, title: String? = nil, onDismiss: (() -> Void)? = nil) {
        let rawTitle: String
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            rawTitle = title
        } else {
            let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            rawTitle = last.isEmpty ? (url.host ?? "LID Media Player") : last
        }

        let s: LIDPlayerSource
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" {
            s = .hlsStream(url: url, variantPreferences: nil, title: rawTitle)
        } else if ext == "mpd" {
            s = .dashStream(manifestURL: url, selectedRepresentationID: nil, title: rawTitle)
        } else if url.scheme == "lidtorrent" {
            let hash = url.host ?? ""
            let idx = Int(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? 0
            s = .torrentSwarm(infoHash: hash, fileIndex: idx, title: rawTitle)
        } else if url.isFileURL {
            s = .localFile(url: url, title: rawTitle)
        } else {
            s = .networkStream(url: url, headers: [:], title: rawTitle)
        }
        self.init(source: s, onDismiss: onDismiss)
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
            // Multi-Backend Hardware-Accelerated Video Layer (VLCKit / AVFoundation)
            Group {
                if engine.activeBackendType == .avFoundation {
                    LIDNativePlayerLayerView(player: engine.player, videoGravity: videoGravity) { layer in
                        self.layerViewRef = layer
                    }
                } else {
                    LIDVLCPlayerLayerView(backend: engine.vlcBackend)
                }
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
            #else
            fallbackView
            #endif

            // Loading / Buffering Spinner
            if engine.playbackState.isLoading || engine.playbackState.isBuffering {
                loadingOverlayView
            }

            // Error Overlay View (Displays real errors with prominent Close button)
            if case .failed(let error) = engine.playbackState {
                errorOverlayView(error: error)
            }

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

            // Gesture Detection Layer (Disabled when locked or in error state)
            if !isControlsLocked && !engine.playbackState.isFailed {
                gestureOverlayView
            }

            // HUD Feedback Overlays (Brightness, Volume, Seek, 2x Boost)
            hudOverlayView

            // Controls Overlay
            if showControls && !isControlsLocked && !engine.playbackState.isFailed {
                controlsOverlayView
                    .transition(.opacity)
            }

            // Subtle fallback close button when controls are auto-hidden (so the user is never trapped)
            if !showControls && !isControlsLocked && !engine.playbackState.isFailed {
                VStack {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(9)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                        }
                        .padding(.leading, 18)
                        .padding(.top, 18)
                        Spacer()
                    }
                    Spacer()
                }
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
                            PipelineLogger.shared.logPlayer(
                                session: sessionId,
                                category: "PlayerGesture",
                                message: "Controls unlocked by user"
                            )
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
            #if canImport(UIKit)
            brightnessLevel = Double(UIScreen.main.brightness)
            #endif
            volumeLevel = Double(engine.volume)
            PipelineLogger.shared.logPlayer(
                session: sessionId,
                category: "PlayerLifecycle",
                message: "LIDPlayerView appeared for media '\(title)', url: \(url.lastPathComponent)"
            )
            engine.load(source: source, autoPlay: true, resumeFromHistory: true, sessionId: sessionId)
            if case .localFile(let localURL, _) = source {
                autoDiscoverSiblingSubtitles(for: localURL)
            }
            resetControlsTimer()
        }
        .onDisappear {
            PipelineLogger.shared.logPlayer(
                session: sessionId,
                category: "PlayerLifecycle",
                message: "LIDPlayerView disappeared, stopping engine"
            )
            engine.stop()
            #if canImport(UIKit)
            engine.vlcBackend.detachRenderingView()
            #endif
            controlsTimer?.invalidate()
        }
        .sheet(isPresented: $showTrackSelectionSheet) {
            trackSelectionSheetView
        }
        .sheet(isPresented: $showSubtitleSyncSheet) {
            subtitleSyncSheetView
        }
        .sheet(isPresented: $showSubtitleSearchSheet) {
            LIDSubtitleSearchView(mediaTitle: engine.currentSource?.title ?? "", engine: engine)
        }
        .sheet(isPresented: $showDiagnosticsSheet) {
            DiagnosticLogView()
        }
    }

    // MARK: - Loading & Error Overlays

    private var loadingOverlayView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.3)
            Text(engine.playbackState.isBuffering ? "Buffering..." : "Loading media...")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(20)
        .background(Color.black.opacity(0.6))
        .cornerRadius(12)
        .allowsHitTesting(false)
    }

    private func errorOverlayView(error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundColor(.yellow)
            Text("Playback Error")
                .font(.headline)
                .foregroundColor(.white)
            Text(error)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            HStack(spacing: 16) {
                Button {
                    engine.load(source: source, autoPlay: true, resumeFromHistory: false)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(8)
                }
                Button {
                    dismiss()
                } label: {
                    Label("Close Player", systemImage: "xmark")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(8)
                }
            }
        }
        .padding(24)
        .background(Color.black.opacity(0.88))
        .cornerRadius(16)
        .padding(32)
    }

    // MARK: - Gesture Overlay Layer

    private var gestureOverlayView: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                // Left 50%: Brightness Drag + Double-tap Rewind (-10s) + Single-tap Controls
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: proxy.size.width * 0.5)
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onChanged { value in
                                guard !isControlsLocked else { return }
                                if !isDraggingBrightness {
                                    isDraggingBrightness = true
                                    controlsTimer?.invalidate()
                                    #if canImport(UIKit)
                                    gestureStartBrightness = Double(UIScreen.main.brightness)
                                    #else
                                    gestureStartBrightness = brightnessLevel
                                    #endif
                                    PipelineLogger.shared.logPlayer(
                                        session: sessionId,
                                        category: "PlayerGesture",
                                        message: "Brightness drag started at \(Int(gestureStartBrightness * 100))%"
                                    )
                                }
                                showControls = false
                                showBrightnessHUD = true
                                let delta = -Double(value.translation.height) / Double(proxy.size.height * 0.7)
                                let newLevel = max(0.0, min(1.0, gestureStartBrightness + delta))
                                brightnessLevel = newLevel
                                #if canImport(UIKit)
                                UIScreen.main.brightness = CGFloat(newLevel)
                                #endif
                            }
                            .onEnded { _ in
                                isDraggingBrightness = false
                                PipelineLogger.shared.logPlayer(
                                    session: sessionId,
                                    category: "PlayerGesture",
                                    message: "Brightness drag ended -> \(Int(brightnessLevel * 100))%"
                                )
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    showBrightnessHUD = false
                                }
                                resetControlsTimer()
                            }
                    )
                    .onTapGesture(count: 2) {
                        guard !isControlsLocked && !isDraggingBrightness else { return }
                        PipelineLogger.shared.logPlayer(
                            session: sessionId,
                            category: "PlayerGesture",
                            message: "Double-tap left zone -> rewind -10s"
                        )
                        engine.seekBy(offsetSeconds: -10)
                        showTemporaryHUD("⏪ 10s")
                        resetControlsTimer()
                    }
                    .onTapGesture(count: 1) {
                        guard !isControlsLocked && !isDraggingBrightness else { return }
                        PipelineLogger.shared.logPlayer(
                            session: sessionId,
                            category: "PlayerGesture",
                            message: "Single-tap left zone -> toggle controls (was \(showControls))"
                        )
                        toggleControlsVisibility()
                    }

                // Right 50%: Volume Drag + Double-tap Forward (+10s) + Single-tap Controls
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: proxy.size.width * 0.5)
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onChanged { value in
                                guard !isControlsLocked else { return }
                                if !isDraggingVolume {
                                    isDraggingVolume = true
                                    controlsTimer?.invalidate()
                                    gestureStartVolume = Double(engine.volume)
                                    PipelineLogger.shared.logPlayer(
                                        session: sessionId,
                                        category: "PlayerGesture",
                                        message: "Volume drag started at \(Int(gestureStartVolume * 100))%"
                                    )
                                }
                                showControls = false
                                showVolumeHUD = true
                                let delta = -Double(value.translation.height) / Double(proxy.size.height * 0.7)
                                let newLevel = max(0.0, min(1.0, gestureStartVolume + delta))
                                volumeLevel = newLevel
                                engine.setVolume(Float(newLevel))
                            }
                            .onEnded { _ in
                                isDraggingVolume = false
                                PipelineLogger.shared.logPlayer(
                                    session: sessionId,
                                    category: "PlayerGesture",
                                    message: "Volume drag ended -> \(Int(volumeLevel * 100))%"
                                )
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    showVolumeHUD = false
                                }
                                resetControlsTimer()
                            }
                    )
                    .onTapGesture(count: 2) {
                        guard !isControlsLocked && !isDraggingVolume else { return }
                        PipelineLogger.shared.logPlayer(
                            session: sessionId,
                            category: "PlayerGesture",
                            message: "Double-tap right zone -> forward +10s"
                        )
                        engine.seekBy(offsetSeconds: 10)
                        showTemporaryHUD("⏩ 10s")
                        resetControlsTimer()
                    }
                    .onTapGesture(count: 1) {
                        guard !isControlsLocked && !isDraggingVolume else { return }
                        PipelineLogger.shared.logPlayer(
                            session: sessionId,
                            category: "PlayerGesture",
                            message: "Single-tap right zone -> toggle controls (was \(showControls))"
                        )
                        toggleControlsVisibility()
                    }
            }
        }
    }

    // MARK: - HUD Feedback Overlays

    private var hudOverlayView: some View {
        VStack {
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

                if engine.streamContext.isLive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text(engine.streamContext.isDVRSeekable ? "LIVE DVR" : "LIVE")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(4)
                }

                if let speed = engine.streamContext.swarmDownloadSpeed, speed > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                        Text(formatSwarmSpeed(speed))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        if let peers = engine.streamContext.swarmConnectedPeers, peers > 0 {
                            Text("· \(peers)p")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(4)
                }

                Spacer()

                // Picture-in-Picture Button
                #if canImport(AVFoundation) && canImport(UIKit) && canImport(AVKit)
                if engine.supportsPictureInPicture {
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
                    PipelineLogger.shared.logPlayer(
                        session: sessionId,
                        category: "PlayerGesture",
                        message: "Controls locked by user"
                    )
                } label: {
                    Image(systemName: "lock")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Circle())
                }

                // Diagnostics Log Viewer Button
                Button {
                    showDiagnosticsSheet = true
                } label: {
                    Image(systemName: "stethoscope")
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
                        if engine.playbackState.isEnded {
                            engine.replay()
                        } else {
                            engine.togglePlayPause()
                        }
                        resetControlsTimer()
                    } label: {
                        Image(systemName: engine.playbackState.isEnded ? "arrow.counterclockwise.circle.fill" : (engine.playbackState.isPlaying ? "pause.circle.fill" : "play.circle.fill"))
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
                                engine.selectAudioTrack(track)
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
                            engine.selectSubtitleTrack(track)
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

                    // Download Subtitles Online Action
                    Button {
                        showTrackSelectionSheet = false
                        showSubtitleSearchSheet = true
                    } label: {
                        Label("Download Subtitles...", systemImage: "arrow.down.circle")
                            .foregroundColor(.blue)
                    }

                    // Add External Subtitle Action
                    Button {
                        showExternalSubtitlePrompt = true
                    } label: {
                        Label("Load Subtitle File (.srt / .vtt)", systemImage: "doc.badge.plus")
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
            .alert("Add External Subtitle", isPresented: $showExternalSubtitlePrompt) {
                TextField("File path or URL (e.g. /path/to/sub.srt)", text: $externalSubtitlePathInput)
                Button("Add") {
                    let trimmed = externalSubtitlePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let fileURL = trimmed.hasPrefix("/") ? URL(fileURLWithPath: trimmed) : URL(string: trimmed)
                        if let targetURL = fileURL {
                            engine.addExternalSubtitle(url: targetURL)
                        }
                    }
                    externalSubtitlePathInput = ""
                }
                Button("Cancel", role: .cancel) {
                    externalSubtitlePathInput = ""
                }
            } message: {
                Text("Enter the local file path or URL for an external SRT or WebVTT subtitle file.")
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
                        let newDelay = max(-5.0, min(5.0, engine.trackManager.subtitleDelay - 0.5))
                        engine.setSubtitleDelay(seconds: newDelay)
                    }
                    .buttonStyle(.bordered)

                    Button("-0.1s") {
                        let newDelay = max(-5.0, min(5.0, engine.trackManager.subtitleDelay - 0.1))
                        engine.setSubtitleDelay(seconds: newDelay)
                    }
                    .buttonStyle(.bordered)

                    Button("Reset") {
                        engine.setSubtitleDelay(seconds: 0.0)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("+0.1s") {
                        let newDelay = max(-5.0, min(5.0, engine.trackManager.subtitleDelay + 0.1))
                        engine.setSubtitleDelay(seconds: newDelay)
                    }
                    .buttonStyle(.bordered)

                    Button("+0.5s") {
                        let newDelay = max(-5.0, min(5.0, engine.trackManager.subtitleDelay + 0.5))
                        engine.setSubtitleDelay(seconds: newDelay)
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
        controlsTimer?.invalidate()
        if let onDismiss = onDismiss {
            onDismiss()
        }
        presentationMode.wrappedValue.dismiss()
    }

    private func toggleControlsVisibility() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showControls.toggle()
        }
        PipelineLogger.shared.logPlayer(
            session: sessionId,
            category: "PlayerControls",
            message: "toggleControlsVisibility -> showControls = \(showControls)"
        )
        if showControls {
            resetControlsTimer()
        } else {
            controlsTimer?.invalidate()
        }
    }

    private func autoDiscoverSiblingSubtitles(for mediaURL: URL) {
        let baseName = mediaURL.deletingPathExtension().lastPathComponent
        let dir = mediaURL.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files {
            let ext = f.pathExtension.lowercased()
            if (ext == "srt" || ext == "vtt") && f.lastPathComponent.lowercased().contains(baseName.lowercased()) {
                let shouldSelect = engine.trackManager.selectedSubtitleTrack == .off
                engine.addExternalSubtitle(url: f, displayName: f.lastPathComponent, autoSelect: shouldSelect)
            }
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
        guard !isDraggingBrightness && !isDraggingVolume else { return }
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.3)) {
                    if engine.playbackState.isPlaying && !isControlsLocked && !isDraggingBrightness && !isDraggingVolume {
                        showControls = false
                        PipelineLogger.shared.logPlayer(
                            session: sessionId,
                            category: "PlayerControls",
                            message: "Controls auto-hidden after timeout"
                        )
                    }
                }
            }
        }
    }

    private func cycleAspectRatio() {
        let all = LIDAspectRatio.allCases
        if let idx = all.firstIndex(of: aspectRatio) {
            let next = all[(idx + 1) % all.count]
            aspectRatio = next
            engine.setAspectRatio(next)
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

    private func formatSwarmSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
        } else if bytesPerSecond >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        } else {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
    }
}

public struct IdentifiablePlayerSource: Identifiable, Sendable {
    public var id: String { source.mediaIdentifier }
    public let source: LIDPlayerSource

    public init(source: LIDPlayerSource) {
        self.source = source
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

    /// Presents the full-screen LID Player configured with any `LIDPlayerSource` (file, HLS, DASH, or torrent).
    @ViewBuilder
    public func lidPlayerPresentation(source: Binding<LIDPlayerSource?>) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: Binding<IdentifiablePlayerSource?>(
            get: { source.wrappedValue.map { IdentifiablePlayerSource(source: $0) } },
            set: { source.wrappedValue = $0?.source }
        )) { item in
            LIDPlayerView(source: item.source) {
                source.wrappedValue = nil
            }
        }
        #else
        self.sheet(item: Binding<IdentifiablePlayerSource?>(
            get: { source.wrappedValue.map { IdentifiablePlayerSource(source: $0) } },
            set: { source.wrappedValue = $0?.source }
        )) { item in
            LIDPlayerView(source: item.source) {
                source.wrappedValue = nil
            }
        }
        #endif
    }
}
#endif
