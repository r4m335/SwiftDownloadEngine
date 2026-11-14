import Foundation

#if canImport(Combine)
import Combine
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Representation of an audio track/rendition.
public struct LIDAudioTrack: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let languageCode: String?
    public let isDefault: Bool

    public init(id: String, displayName: String, languageCode: String? = nil, isDefault: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
        self.isDefault = isDefault
    }
}

/// Representation of a subtitle / closed caption track (embedded or external).
public struct LIDSubtitleTrack: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let languageCode: String?
    public let isExternal: Bool
    public let externalURL: URL?

    public init(
        id: String,
        displayName: String,
        languageCode: String? = nil,
        isExternal: Bool = false,
        externalURL: URL? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
        self.isExternal = isExternal
        self.externalURL = externalURL
    }

    /// Sentinel representation for disabled subtitles.
    public static let off = LIDSubtitleTrack(id: "off", displayName: "Off")
}

/// Manages embedded and external audio/subtitle tracks, subtitle parsing, delay adjustment, and active cue synchronization.
@MainActor
public final class LIDTrackManager: ObservableObject {

    @Published public private(set) var availableAudioTracks: [LIDAudioTrack] = []
    @Published public private(set) var selectedAudioTrack: LIDAudioTrack?

    @Published public private(set) var availableSubtitleTracks: [LIDSubtitleTrack] = [LIDSubtitleTrack.off]
    @Published public private(set) var selectedSubtitleTrack: LIDSubtitleTrack = .off

    /// Subtitle synchronization delay in seconds (e.g. +1.5s or -0.5s).
    @Published public var subtitleDelay: Double = 0.0

    /// Currently active subtitle cue text to render on screen.
    @Published public private(set) var activeCueText: String?

    private var parsedCues: [LIDSubtitleCue] = []
    private let parser = LIDSubtitleParser()

    #if canImport(AVFoundation)
    private weak var currentItem: AVPlayerItem?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    #endif

    public init() {}

    /// Reset track state when loading new media.
    public func reset() {
        availableAudioTracks = []
        selectedAudioTrack = nil
        availableSubtitleTracks = [LIDSubtitleTrack.off]
        selectedSubtitleTrack = .off
        subtitleDelay = 0.0
        activeCueText = nil
        parsedCues = []
        #if canImport(AVFoundation)
        currentItem = nil
        audibleGroup = nil
        legibleGroup = nil
        #endif
    }

    #if canImport(AVFoundation)
    /// Discover available embedded tracks from the AVPlayerItem.
    public func populateTracks(from item: AVPlayerItem) {
        self.currentItem = item
        let asset = item.asset

        // 1. Audible / Audio Tracks
        if let audible = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            self.audibleGroup = audible
            var audioTracks: [LIDAudioTrack] = []
            let currentSelected = item.currentMediaSelection.selectedMediaOption(in: audible)

            for (idx, option) in audible.options.enumerated() {
                let id = option.locale?.identifier ?? "audio_\(idx)"
                let title = option.displayName.isEmpty ? "Track \(idx + 1)" : option.displayName
                let isDefault = (option == audible.defaultOption)
                let track = LIDAudioTrack(
                    id: id,
                    displayName: title,
                    languageCode: option.extendedLanguageTag ?? option.locale?.languageCode,
                    isDefault: isDefault
                )
                audioTracks.append(track)
                if option == currentSelected || (currentSelected == nil && isDefault) {
                    self.selectedAudioTrack = track
                }
            }
            self.availableAudioTracks = audioTracks
            if selectedAudioTrack == nil, let first = audioTracks.first {
                self.selectedAudioTrack = first
            }
        }

        // 2. Legible / Subtitle Tracks
        var subTracks: [LIDSubtitleTrack] = [LIDSubtitleTrack.off]
        if let legible = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            self.legibleGroup = legible
            let currentSelected = item.currentMediaSelection.selectedMediaOption(in: legible)

            for (idx, option) in legible.options.enumerated() {
                let id = option.locale?.identifier ?? "sub_\(idx)"
                let title = option.displayName.isEmpty ? "Subtitle \(idx + 1)" : option.displayName
                let track = LIDSubtitleTrack(
                    id: id,
                    displayName: title,
                    languageCode: option.extendedLanguageTag ?? option.locale?.languageCode,
                    isExternal: false
                )
                subTracks.append(track)
                if option == currentSelected {
                    self.selectedSubtitleTrack = track
                }
            }
        }
        self.availableSubtitleTracks = subTracks
    }
    #endif

    /// Select an audio track.
    public func selectAudioTrack(_ track: LIDAudioTrack) {
        self.selectedAudioTrack = track
        #if canImport(AVFoundation)
        guard let item = currentItem, let group = audibleGroup else { return }
        for option in group.options {
            let id = option.locale?.identifier ?? ""
            if id == track.id || option.displayName == track.displayName {
                item.select(option, in: group)
                break
            }
        }
        #endif
    }

    /// Select a subtitle track (built-in or external).
    public func selectSubtitleTrack(_ track: LIDSubtitleTrack) {
        self.selectedSubtitleTrack = track

        if track.id == LIDSubtitleTrack.off.id {
            // Turn subtitles off
            #if canImport(AVFoundation)
            if let item = currentItem, let group = legibleGroup {
                item.select(nil, in: group)
            }
            #endif
            parsedCues = []
            activeCueText = nil
            return
        }

        if track.isExternal, let url = track.externalURL {
            // Disable native legible group and use parsed cues
            #if canImport(AVFoundation)
            if let item = currentItem, let group = legibleGroup {
                item.select(nil, in: group)
            }
            #endif
            loadExternalSubtitle(from: url)
        } else {
            // Embedded track
            parsedCues = []
            activeCueText = nil
            #if canImport(AVFoundation)
            guard let item = currentItem, let group = legibleGroup else { return }
            for option in group.options {
                let id = option.locale?.identifier ?? ""
                if id == track.id || option.displayName == track.displayName {
                    item.select(option, in: group)
                    break
                }
            }
            #endif
        }
    }

    /// Add an external subtitle track from a file URL.
    public func addExternalSubtitle(url: URL, displayName: String? = nil) {
        let name = displayName ?? url.deletingPathExtension().lastPathComponent
        let track = LIDSubtitleTrack(
            id: "external_\(url.lastPathComponent)",
            displayName: name,
            languageCode: nil,
            isExternal: true,
            externalURL: url
        )

        if !availableSubtitleTracks.contains(where: { $0.id == track.id }) {
            availableSubtitleTracks.append(track)
        }
        selectSubtitleTrack(track)
    }

    /// Adjust subtitle delay by delta in seconds.
    public func adjustSubtitleDelay(by delta: Double) {
        subtitleDelay = max(-5.0, min(5.0, subtitleDelay + delta))
    }

    /// Update active cue for external subtitles based on current playback timestamp.
    public func updatePosition(_ seconds: Double) {
        guard !parsedCues.isEmpty else { return }
        if let cue = parser.activeCue(in: parsedCues, at: seconds, delay: subtitleDelay) {
            if activeCueText != cue.text {
                activeCueText = cue.text
            }
        } else {
            if activeCueText != nil {
                activeCueText = nil
            }
        }
    }

    // MARK: - Private Helpers

    private func loadExternalSubtitle(from url: URL) {
        do {
            let cues = try parser.parse(fileURL: url)
            self.parsedCues = cues
        } catch {
            print("[LIDTrackManager] Failed to load external subtitle: \(error)")
            self.parsedCues = []
        }
    }
}
