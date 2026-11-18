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

    /// Normalizes and updates available audio and subtitle tracks from any active backend (VLCKit or AVFoundation).
    public func updateAvailableTracks(audioTracks: [LIDAudioTrack], subtitleTracks: [LIDSubtitleTrack]) {
        self.availableAudioTracks = audioTracks
        if let current = selectedAudioTrack, audioTracks.contains(where: { $0.id == current.id }) {
            // Retain selected track
        } else {
            self.selectedAudioTrack = audioTracks.first(where: { $0.isDefault }) ?? audioTracks.first
        }

        var combined: [LIDSubtitleTrack] = [LIDSubtitleTrack.off]
        for s in subtitleTracks where s.id != LIDSubtitleTrack.off.id {
            if !combined.contains(where: { $0.id == s.id }) {
                combined.append(s)
            }
        }
        for ext in availableSubtitleTracks where ext.isExternal {
            if !combined.contains(where: { $0.id == ext.id }) {
                combined.append(ext)
            }
        }
        self.availableSubtitleTracks = combined
    }

    // MARK: - Language & Preference Resolution

    /// Determines if a track matches the user's preferred language string (e.g. "English", "Spanish", "Any").
    nonisolated public static func matchesLanguage(languageCode: String?, displayName: String, preferredLanguage: String) -> Bool {
        let pref = preferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pref.isEmpty, pref != "any" else { return true }

        let code = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch pref {
        case "english":
            return code.hasPrefix("en") || code == "eng" || name.contains("english") || name.contains("eng")
        case "spanish":
            return code.hasPrefix("es") || code == "spa" || name.contains("spanish") || name.contains("español") || name.contains("espanol")
        case "french":
            return code.hasPrefix("fr") || code == "fra" || code == "fre" || name.contains("french") || name.contains("français") || name.contains("francais")
        case "german":
            return code.hasPrefix("de") || code == "deu" || code == "ger" || name.contains("german") || name.contains("deutsch")
        case "japanese":
            return code.hasPrefix("ja") || code == "jpn" || name.contains("japanese") || name.contains("nihongo") || name.contains("日本語")
        case "chinese":
            return code.hasPrefix("zh") || code == "zho" || code == "chi" || name.contains("chinese") || name.contains("mandarin") || name.contains("中文")
        case "arabic":
            return code.hasPrefix("ar") || code == "ara" || name.contains("arabic") || name.contains("العربية")
        case "portuguese":
            return code.hasPrefix("pt") || code == "por" || name.contains("portuguese") || name.contains("português") || name.contains("portugues")
        case "russian":
            return code.hasPrefix("ru") || code == "rus" || name.contains("russian") || name.contains("русский")
        default:
            return code.hasPrefix(pref) || name.contains(pref)
        }
    }

    /// Automatically selects audio and subtitle tracks according to user settings and optional history record.
    public func applyPreferences(
        settings: LIDPlayerSettings,
        historyRecord: LIDPlaybackRecord? = nil
    ) {
        // 1. Audio Track Preference Resolution
        if settings.rememberAudioTrack,
           let rememberedAudioId = historyRecord?.selectedAudioTrackId,
           let matched = availableAudioTracks.first(where: { $0.id == rememberedAudioId || $0.displayName == rememberedAudioId }) {
            selectAudioTrack(matched)
        } else if settings.defaultAudioLanguage.lowercased() != "any",
                  let langMatched = availableAudioTracks.first(where: { Self.matchesLanguage(languageCode: $0.languageCode, displayName: $0.displayName, preferredLanguage: settings.defaultAudioLanguage) }) {
            selectAudioTrack(langMatched)
        } else if selectedAudioTrack == nil {
            if let def = availableAudioTracks.first(where: { $0.isDefault }) ?? availableAudioTracks.first {
                selectAudioTrack(def)
            }
        }

        // 2. Subtitle Track Preference Resolution
        if settings.rememberSubtitleTrack,
           let rememberedSubId = historyRecord?.selectedSubtitleTrackId {
            if rememberedSubId == LIDSubtitleTrack.off.id {
                selectSubtitleTrack(.off)
            } else if let matched = availableSubtitleTracks.first(where: { $0.id == rememberedSubId || $0.displayName == rememberedSubId }) {
                selectSubtitleTrack(matched)
            }
        } else if settings.defaultSubtitleLanguage.lowercased() != "any",
                  let langMatched = availableSubtitleTracks.first(where: { $0.id != LIDSubtitleTrack.off.id && Self.matchesLanguage(languageCode: $0.languageCode, displayName: $0.displayName, preferredLanguage: settings.defaultSubtitleLanguage) }) {
            selectSubtitleTrack(langMatched)
        }
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
    public func addExternalSubtitle(url: URL, displayName: String? = nil, autoSelect: Bool = true) {
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
        if autoSelect {
            selectSubtitleTrack(track)
        }
    }

    /// Remove an external subtitle track from the available list.
    public func removeExternalSubtitle(url: URL) {
        let trackId = "external_\(url.lastPathComponent)"
        availableSubtitleTracks.removeAll(where: { $0.id == trackId })
        if selectedSubtitleTrack.id == trackId {
            selectSubtitleTrack(.off)
        }
    }

    /// Adjust subtitle delay by delta in seconds (unrestricted positive or negative offset).
    public func adjustSubtitleDelay(by delta: Double) {
        subtitleDelay += delta
    }

    /// Set subtitle delay to an exact value in seconds.
    public func setSubtitleDelay(_ delay: Double) {
        subtitleDelay = delay
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
