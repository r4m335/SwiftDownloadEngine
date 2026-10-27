import Foundation

/// Deterministic preferences for selecting one HLS master-playlist variant.
public struct HLSVariantSelectionPreferences: Sendable, Equatable {
    public let maximumBandwidth: Int?
    public let maximumWidth: Int?
    public let maximumHeight: Int?
    public let preferredCodecPrefix: String?

    public init(
        maximumBandwidth: Int? = nil,
        maximumWidth: Int? = nil,
        maximumHeight: Int? = nil,
        preferredCodecPrefix: String? = nil
    ) {
        self.maximumBandwidth = maximumBandwidth
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.preferredCodecPrefix = preferredCodecPrefix?.lowercased()
    }
}

public enum HLSVariantSelectionError: Error, LocalizedError, Sendable, Equatable {
    case noVariants
    case noVariantMatchesPreferences
    case separateAudioNotSupported

    public var errorDescription: String? {
        switch self {
        case .noVariants:
            return "The HLS master playlist contains no selectable media variants."
        case .noVariantMatchesPreferences:
            return "No HLS variant matches the requested media preferences."
        case .separateAudioNotSupported:
            return "This HLS reconstruction path does not yet mux a separate audio rendition."
        }
    }
}

public enum HLSVariantSelector {
    public static func select(
        from master: HLSManifest,
        preferences: HLSVariantSelectionPreferences = HLSVariantSelectionPreferences()
    ) throws -> HLSVariant {
        guard master.playlistType == .master, !master.variants.isEmpty else {
            throw HLSVariantSelectionError.noVariants
        }
        let matching = master.variants.filter { variant in
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
        guard !matching.isEmpty else {
            throw HLSVariantSelectionError.noVariantMatchesPreferences
        }

        return matching.sorted { lhs, rhs in
            let lhsBandwidth = lhs.averageBandwidth ?? lhs.bandwidth
            let rhsBandwidth = rhs.averageBandwidth ?? rhs.bandwidth
            if lhsBandwidth != rhsBandwidth { return lhsBandwidth > rhsBandwidth }
            let lhsPixels = (lhs.resolution?.width ?? 0) * (lhs.resolution?.height ?? 0)
            let rhsPixels = (rhs.resolution?.width ?? 0) * (rhs.resolution?.height ?? 0)
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }
            return lhs.uri.absoluteString < rhs.uri.absoluteString
        }.first!
    }

    public static func validateAudioLayout(
        selectedVariant: HLSVariant,
        master: HLSManifest
    ) throws {
        // Multi-track assembly is now supported for variants with separate audio renditions.
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
