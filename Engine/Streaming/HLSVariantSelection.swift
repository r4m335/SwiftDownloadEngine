import Foundation

/// Deterministic preferences for selecting one HLS master-playlist variant.
public struct HLSVariantSelectionPreferences: Sendable, Equatable, Hashable {
    public let maximumBandwidth: Int?
    public let maximumWidth: Int?
    public let maximumHeight: Int?
    public let preferredCodecPrefix: String?
    public let exactURI: URL?

    public init(
        maximumBandwidth: Int? = nil,
        maximumWidth: Int? = nil,
        maximumHeight: Int? = nil,
        preferredCodecPrefix: String? = nil,
        exactURI: URL? = nil
    ) {
        self.maximumBandwidth = maximumBandwidth
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.preferredCodecPrefix = preferredCodecPrefix?.lowercased()
        self.exactURI = exactURI
    }
}

public enum HLSVariantSelectionError: Error, LocalizedError, Sendable, Equatable {
    case noVariants
    case noVariantMatchesPreferences
    case separateAudioNotSupported
    case missingAudioRendition(groupID: String)
    case unsupportedIFrameVariant

    public var errorDescription: String? {
        switch self {
        case .noVariants:
            return "The HLS master playlist contains no selectable media variants."
        case .noVariantMatchesPreferences:
            return "No HLS variant matches the requested media preferences."
        case .separateAudioNotSupported:
            return "This HLS reconstruction path does not yet mux a separate audio rendition."
        case .missingAudioRendition(let groupID):
            return "The audio group '\(groupID)' referenced by the selected HLS variant has no accessible audio rendition."
        case .unsupportedIFrameVariant:
            return "I-frame-only trick-play streams cannot be downloaded or assembled as a complete video."
        }
    }
}

public enum HLSVariantSelector {
    /// Returns all eligible variants matching the user preferences, ranked from highest to lowest quality.
    public static func rank(
        from master: HLSManifest,
        preferences: HLSVariantSelectionPreferences = HLSVariantSelectionPreferences(),
        deduplicate: Bool = false
    ) throws -> [HLSVariant] {
        guard master.playlistType == .master, !master.variants.isEmpty else {
            throw HLSVariantSelectionError.noVariants
        }
        let matching = master.variants.filter { variant in
            if let exactURI = preferences.exactURI {
                let matches = variant.uri == exactURI ||
                    variant.uri.absoluteString == exactURI.absoluteString ||
                    variant.uri.path == exactURI.path
                if !matches {
                    return false
                }
            }
            if let maximumBandwidth = preferences.maximumBandwidth, variant.bandwidth > maximumBandwidth {
                return false
            }
            if let maximumWidth = preferences.maximumWidth,
               let width = variant.resolution?.width,
               width > maximumWidth {
                return false
            }
            if let maximumHeight = preferences.maximumHeight,
               let height = variant.resolution?.height,
               height > maximumHeight {
                return false
            }
            if let prefix = preferences.preferredCodecPrefix,
               !(variant.codecs?.lowercased().hasPrefix(prefix) == true) {
                return false
            }
            return true
        }

        var finalMatching = matching
        if finalMatching.isEmpty && preferences.exactURI != nil {
            // Fallback: If exactURI failed to match any variant (e.g. query token rotation),
            // evaluate variants matching quality preferences without the strict exactURI check
            finalMatching = master.variants.filter { variant in
                if let maximumBandwidth = preferences.maximumBandwidth, variant.bandwidth > maximumBandwidth {
                    return false
                }
                if let maximumWidth = preferences.maximumWidth,
                   let width = variant.resolution?.width,
                   width > maximumWidth {
                    return false
                }
                if let maximumHeight = preferences.maximumHeight,
                   let height = variant.resolution?.height,
                   height > maximumHeight {
                    return false
                }
                if let prefix = preferences.preferredCodecPrefix,
                   !(variant.codecs?.lowercased().hasPrefix(prefix) == true) {
                    return false
                }
                return true
            }
            if finalMatching.isEmpty {
                // If quality filters were also too strict, fallback to all variants
                finalMatching = master.variants
            }
        }

        guard !finalMatching.isEmpty else {
            throw HLSVariantSelectionError.noVariantMatchesPreferences
        }

        let sorted = finalMatching.sorted { lhs, rhs in
            if lhs.isIFrameOnly != rhs.isIFrameOnly {
                return !lhs.isIFrameOnly && rhs.isIFrameOnly
            }
            let lhsBandwidth = lhs.averageBandwidth ?? lhs.bandwidth
            let rhsBandwidth = rhs.averageBandwidth ?? rhs.bandwidth
            if lhsBandwidth != rhsBandwidth { return lhsBandwidth > rhsBandwidth }
            let lhsPixels = (lhs.resolution?.width ?? 0) * (lhs.resolution?.height ?? 0)
            let rhsPixels = (rhs.resolution?.width ?? 0) * (rhs.resolution?.height ?? 0)
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }
            return lhs.uri.absoluteString < rhs.uri.absoluteString
        }

        return deduplicate ? Self.deduplicate(sorted) : sorted
    }

    /// Deduplicates variants that represent the same media quality tier.
    ///
    /// Preserves the highest-quality / first ranked variant when multiple variants share
    /// the same resolution (and codec family, if specified) or identical bandwidth/URI,
    /// preventing duplicate quality options in the UI and grabber lists.
    public static func deduplicate(_ variants: [HLSVariant]) -> [HLSVariant] {
        var seenKeys = Set<String>()
        var seenURIs = Set<String>()
        var deduplicated: [HLSVariant] = []

        for variant in variants {
            let normalizedURI = variant.uri.absoluteString.lowercased()
            if seenURIs.contains(normalizedURI) {
                continue
            }

            let vCodec = extractVideoCodecFamily(variant.codecs)
            let fpsKey = variant.frameRate.map { "\(Int($0.rounded()))fps" } ?? "anyfps"
            let iframeKey = variant.isIFrameOnly ? ":iframe" : ""
            let qualityKey: String
            if let res = variant.resolution {
                qualityKey = "res:\(res.width)x\(res.height):\(vCodec ?? "any"):\(fpsKey)\(iframeKey)"
            } else {
                qualityKey = "bw:\(variant.bandwidth):\(vCodec ?? "any"):\(fpsKey)\(iframeKey)"
            }

            if seenKeys.contains(qualityKey) {
                continue
            }

            seenKeys.insert(qualityKey)
            seenURIs.insert(normalizedURI)
            deduplicated.append(variant)
        }

        return deduplicated
    }

    public static func extractVideoCodecFamily(_ codecs: String?) -> String? {
        guard let codecs = codecs?.lowercased() else { return nil }
        if codecs.contains("avc1") || codecs.contains("h264") { return "h264" }
        if codecs.contains("hvc1") || codecs.contains("hev1") || codecs.contains("h265") { return "hevc" }
        if codecs.contains("av01") { return "av1" }
        if codecs.contains("vp9") { return "vp9" }
        return nil
    }

    public static func select(
        from master: HLSManifest,
        preferences: HLSVariantSelectionPreferences = HLSVariantSelectionPreferences()
    ) throws -> HLSVariant {
        let ranked = try rank(from: master, preferences: preferences)
        guard let selected = ranked.first else {
            throw HLSVariantSelectionError.noVariantMatchesPreferences
        }
        return selected
    }

    public static func isAudioInCodecs(_ codecs: String?) -> Bool {
        guard let codecs = codecs?.lowercased() else { return false }
        return codecs.contains("mp4a") ||
               codecs.contains("aac") ||
               codecs.contains("ac-3") ||
               codecs.contains("ac3") ||
               codecs.contains("ec-3") ||
               codecs.contains("eac3") ||
               codecs.contains("opus") ||
               codecs.contains("mp3") ||
               codecs.contains("flac") ||
               codecs.contains("alac") ||
               codecs.contains("vorbis")
    }

    public static func validateAudioLayout(
        selectedVariant: HLSVariant,
        master: HLSManifest
    ) throws {
        guard let groupID = selectedVariant.audioGroup else { return }
        let candidates = master.renditions.filter {
            $0.type.uppercased() == "AUDIO" && $0.groupID == groupID
        }
        guard !candidates.isEmpty else {
            throw HLSVariantSelectionError.missingAudioRendition(groupID: groupID)
        }
        let hasSelectable = candidates.contains { $0.uri != nil }
        let hasMuxed = isAudioInCodecs(selectedVariant.codecs)
        if !hasSelectable && !hasMuxed {
            if selectedVariant.codecs == nil && candidates.contains(where: { $0.uri == nil }) {
                return
            }
            throw HLSVariantSelectionError.missingAudioRendition(groupID: groupID)
        }
    }

    public static func selectAudioRendition(
        for variant: HLSVariant,
        master: HLSManifest,
        preferredLanguage: String? = nil
    ) -> HLSRendition? {
        guard let groupID = variant.audioGroup else { return nil }
        let candidates = master.renditions.filter {
            $0.type.uppercased() == "AUDIO" && $0.groupID == groupID && $0.uri != nil
        }
        guard !candidates.isEmpty else { return nil }
        if let lang = preferredLanguage?.lowercased() {
            if let matched = candidates.first(where: { $0.language?.lowercased() == lang }) {
                return matched
            }
        }
        return candidates.first(where: { $0.isDefault })
            ?? candidates.first(where: { $0.isAutoSelect })
            ?? candidates.first
    }
}
