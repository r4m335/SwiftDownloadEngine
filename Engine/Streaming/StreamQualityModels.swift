import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

/// Represents an available stream rendition/variant (e.g. 1080p, 720p, 480p, Audio Only)
/// for interactive user selection before initiating a streaming download.
public struct StreamQualityOption: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let label: String
    public let qualityBadge: String
    public let resolution: HLSResolution?
    public let resolutionText: String?
    public let bandwidth: Int64
    public let bitrateText: String
    public let codecs: String?
    public let videoCodec: String?
    public let audioCodec: String?
    public let frameRate: Double?
    public let hasAudio: Bool
    public let hasVideo: Bool
    public let isAudioOnly: Bool
    public let hasSubtitles: Bool
    public let subtitleText: String?
    public let estimatedSizeBytes: Int64?
    public let estimatedSizeText: String?
    public let uri: URL
    public let manifestKind: StreamingManifestKind
    public let hlsVariant: HLSVariant?
    public let dashVideoRepresentationID: String?
    public let dashAudioRepresentationID: String?
    public let isLive: Bool
    public let isIFrameOnly: Bool
    public let isLowLatency: Bool

    public init(
        id: String,
        label: String,
        qualityBadge: String,
        resolution: HLSResolution? = nil,
        resolutionText: String? = nil,
        bandwidth: Int64,
        bitrateText: String,
        codecs: String? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        frameRate: Double? = nil,
        hasAudio: Bool = true,
        hasVideo: Bool = true,
        isAudioOnly: Bool = false,
        hasSubtitles: Bool = false,
        subtitleText: String? = nil,
        estimatedSizeBytes: Int64? = nil,
        estimatedSizeText: String? = nil,
        uri: URL,
        manifestKind: StreamingManifestKind = .hls,
        hlsVariant: HLSVariant? = nil,
        dashVideoRepresentationID: String? = nil,
        dashAudioRepresentationID: String? = nil,
        isLive: Bool = false,
        isIFrameOnly: Bool = false,
        isLowLatency: Bool = false
    ) {
        self.id = id
        self.label = label
        self.qualityBadge = qualityBadge
        self.resolution = resolution
        self.resolutionText = resolutionText
        self.bandwidth = bandwidth
        self.bitrateText = bitrateText
        self.codecs = codecs
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.frameRate = frameRate
        self.hasAudio = hasAudio
        self.hasVideo = hasVideo
        self.isAudioOnly = isAudioOnly
        self.hasSubtitles = hasSubtitles
        self.subtitleText = subtitleText
        self.estimatedSizeBytes = estimatedSizeBytes
        self.estimatedSizeText = estimatedSizeText
        self.uri = uri
        self.manifestKind = manifestKind
        self.hlsVariant = hlsVariant
        self.dashVideoRepresentationID = dashVideoRepresentationID
        self.dashAudioRepresentationID = dashAudioRepresentationID
        self.isLive = isLive
        self.isIFrameOnly = isIFrameOnly
        self.isLowLatency = isLowLatency
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: StreamQualityOption, rhs: StreamQualityOption) -> Bool {
        lhs.id == rhs.id
    }

    /// Color representation for the resolution badge in SwiftUI views.
    #if canImport(SwiftUI)
    public var badgeColor: Color {
        if isAudioOnly {
            return .orange
        }
        if hasSubtitles && !hasVideo && !hasAudio {
            return .teal
        }
        guard let height = resolution?.height else {
            return .blue
        }
        if height >= 2160 { return .purple }
        if height >= 1080 { return .blue }
        if height >= 720 { return .green }
        if height >= 480 { return .yellow }
        return .secondary
    }
    #endif

    /// Formats bandwidth in bits-per-second to human-readable string (e.g. "4.8 Mbps", "850 Kbps").
    public static func formatBandwidth(_ bps: Int64) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000.0)
        } else if bps >= 1_000 {
            return "\(bps / 1_000) Kbps"
        } else {
            return "\(bps) bps"
        }
    }

    /// Formats estimated byte size into readable size (e.g. "~142 MB").
    public static func formatByteSize(_ bytes: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: bytes)
    }

    /// Estimates file size in bytes from bandwidth and duration in seconds.
    public static func estimateSize(bandwidth: Int64, durationSeconds: Double) -> Int64? {
        guard durationSeconds > 0, bandwidth > 0 else { return nil }
        return Int64(Double(bandwidth) * durationSeconds / 8.0)
    }

    /// Creates a quality option from an HLS variant in a master playlist.
    public static func from(
        variant: HLSVariant,
        master: HLSManifest? = nil,
        selectedAudioRendition: HLSRendition? = nil,
        masterURL: URL,
        durationSeconds: Double? = nil,
        isLive: Bool = false,
        isLowLatency: Bool = false
    ) -> StreamQualityOption {
        let effectiveLowLatency = isLowLatency || (master?.isLowLatency ?? false)
        let height = variant.resolution?.height
        let baseBadge: String = {
            if let h = height { return "\(h)p" }
            return formatBandwidth(Int64(variant.bandwidth))
        }()
        let qualityBadge = variant.isIFrameOnly ? "\(baseBadge) (I-Frame)" : baseBadge

        let label: String = {
            if variant.isIFrameOnly {
                if let h = height {
                    return "\(h)p (I-Frame Only)"
                }
                return "\(baseBadge) (I-Frame Only)"
            }
            if let h = height {
                if h >= 2160 { return "4K Ultra HD (\(h)p)" }
                if h >= 1440 { return "2K Quad HD (\(h)p)" }
                if h >= 1080 { return "1080p Full HD" }
                if h >= 720 { return "720p HD" }
                if h >= 480 { return "480p SD" }
                return "\(h)p"
            }
            return "\(qualityBadge) Stream"
        }()

        let resText = variant.resolution.map { "\($0.width) × \($0.height)" }
        let bwText = formatBandwidth(Int64(variant.bandwidth))
        let vCodec = extractVideoCodec(variant.codecs)
        let aCodec = extractAudioCodec(variant.codecs)

        let resolvedAudioRendition = selectedAudioRendition ?? master.flatMap {
            HLSVariantSelector.selectAudioRendition(for: variant, master: $0)
        }

        let hasMuxedAudio: Bool
        if let codecs = variant.codecs {
            hasMuxedAudio = aCodec != nil || HLSVariantSelector.isAudioInCodecs(codecs)
        } else {
            hasMuxedAudio = (variant.audioGroup == nil)
        }

        let hasAudio: Bool
        if variant.isIFrameOnly {
            hasAudio = false
        } else if let _ = master {
            hasAudio = (resolvedAudioRendition != nil) || hasMuxedAudio
        } else if let _ = selectedAudioRendition {
            hasAudio = true
        } else {
            hasAudio = (variant.audioGroup != nil) || hasMuxedAudio
        }

        let effectiveAudioCodec: String? = {
            if !hasAudio { return nil }
            if let aCodec = aCodec { return aCodec }
            if let name = resolvedAudioRendition?.name, !name.isEmpty { return name }
            return (hasMuxedAudio && variant.codecs == nil) ? "Audio" : nil
        }()

        let estBytes: Int64? = durationSeconds.flatMap { estimateSize(bandwidth: Int64(variant.bandwidth), durationSeconds: $0) }
        let estText = estBytes.map { "~\(formatByteSize($0))" } ?? "Size unavailable"

        let filename = variant.uri.lastPathComponent.isEmpty ? "stream" : variant.uri.lastPathComponent
        let uriHash = String(EngineSHA256.hash(data: Data(variant.uri.absoluteString.utf8)).prefix(8))
        let iframePrefix = variant.isIFrameOnly ? "hls-iframe-" : "hls-"
        let id = "\(iframePrefix)\(variant.bandwidth)-\(height ?? 0)-\(filename)-\(uriHash)"

        return StreamQualityOption(
            id: id,
            label: label,
            qualityBadge: qualityBadge,
            resolution: variant.resolution,
            resolutionText: resText,
            bandwidth: Int64(variant.bandwidth),
            bitrateText: bwText,
            codecs: variant.codecs,
            videoCodec: vCodec,
            audioCodec: effectiveAudioCodec,
            frameRate: variant.frameRate,
            hasAudio: hasAudio,
            hasVideo: true,
            isAudioOnly: false,
            hasSubtitles: variant.subtitlesGroup != nil,
            subtitleText: variant.subtitlesGroup != nil ? "Subtitles" : nil,
            estimatedSizeBytes: estBytes,
            estimatedSizeText: estText,
            uri: variant.uri,
            manifestKind: .hls,
            hlsVariant: variant,
            isLive: isLive,
            isIFrameOnly: variant.isIFrameOnly,
            isLowLatency: effectiveLowLatency
        )
    }

    /// Creates an audio-only quality option from an HLS rendition.
    public static func audioOnly(
        rendition: HLSRendition,
        masterURL: URL,
        bandwidth: Int64 = 128_000,
        durationSeconds: Double? = nil,
        isLive: Bool = false
    ) -> StreamQualityOption {
        let estBytes = durationSeconds.flatMap { estimateSize(bandwidth: bandwidth, durationSeconds: $0) }
        let estText = estBytes.map { "~\(formatByteSize($0))" } ?? "Size unavailable"
        let targetURI = rendition.uri ?? masterURL
        let langSuffix = rendition.language.map { " (\($0.uppercased()))" } ?? ""
        let uriHash = String(EngineSHA256.hash(data: Data(targetURI.absoluteString.utf8)).prefix(8))

        return StreamQualityOption(
            id: "hls-audio-\(rendition.groupID)-\(rendition.name)-\(uriHash)",
            label: "Audio Only\(langSuffix)",
            qualityBadge: "AUDIO",
            resolution: nil,
            resolutionText: nil,
            bandwidth: bandwidth,
            bitrateText: formatBandwidth(bandwidth),
            codecs: "mp4a.40.2",
            videoCodec: nil,
            audioCodec: "AAC",
            frameRate: nil,
            hasAudio: true,
            hasVideo: false,
            isAudioOnly: true,
            estimatedSizeBytes: estBytes,
            estimatedSizeText: estText,
            uri: targetURI,
            manifestKind: .hls,
            hlsVariant: nil,
            isLive: isLive
        )
    }

    /// Creates a quality option from a DASH representation.
    public static func from(
        dashRepresentation rep: DASHRepresentation,
        audioRep: DASHRepresentation? = nil,
        baseURL: URL,
        durationSeconds: Double? = nil,
        hasSubtitles: Bool = false,
        subtitleText: String? = nil,
        isLive: Bool = false
    ) -> StreamQualityOption {
        let bw = rep.bandwidth ?? 1_000_000
        let height = rep.height
        let res: HLSResolution? = {
            if let w = rep.width, let h = rep.height {
                return HLSResolution(width: w, height: h)
            }
            return nil
        }()

        let qualityBadge: String = {
            if let h = height { return "\(h)p" }
            return formatBandwidth(bw)
        }()

        let label: String = {
            if let h = height {
                if h >= 2160 { return "4K Ultra HD (\(h)p)" }
                if h >= 1080 { return "1080p Full HD" }
                if h >= 720 { return "720p HD" }
                if h >= 480 { return "480p SD" }
                return "\(h)p"
            }
            return "\(qualityBadge) Stream"
        }()

        let resText = res.map { "\($0.width) × \($0.height)" }
        let bwText = formatBandwidth(bw)
        let vCodec = extractVideoCodec(rep.codecs)
        let aCodec = extractAudioCodec(audioRep?.codecs ?? rep.codecs)

        let estBytes = durationSeconds.flatMap { estimateSize(bandwidth: bw, durationSeconds: $0) }
        let estText = estBytes.map { "~\(formatByteSize($0))" } ?? "Size unavailable"

        let targetURL = rep.baseURL ?? baseURL
        let uriHash = String(EngineSHA256.hash(data: Data(targetURL.absoluteString.utf8)).prefix(8))
        let repID = rep.id ?? "\(bw)-\(height ?? 0)-\(uriHash)"

        return StreamQualityOption(
            id: "dash-\(repID)",
            label: label,
            qualityBadge: qualityBadge,
            resolution: res,
            resolutionText: resText,
            bandwidth: bw,
            bitrateText: bwText,
            codecs: rep.codecs,
            videoCodec: vCodec,
            audioCodec: aCodec,
            frameRate: nil,
            hasAudio: audioRep != nil || aCodec != nil,
            hasVideo: true,
            isAudioOnly: false,
            hasSubtitles: hasSubtitles,
            subtitleText: subtitleText,
            estimatedSizeBytes: estBytes,
            estimatedSizeText: estText,
            uri: targetURL,
            manifestKind: .dash,
            dashVideoRepresentationID: rep.id,
            dashAudioRepresentationID: audioRep?.id,
            isLive: isLive
        )
    }

    /// Fallback default quality option when only a single media playlist or stream is discovered.
    public static func defaultMedia(
        url: URL,
        mimeType: String? = nil,
        bandwidth: Int64 = 2_500_000,
        kind: StreamingManifestKind = .hls,
        isLive: Bool = false,
        isLowLatency: Bool = false
    ) -> StreamQualityOption {
        StreamQualityOption(
            id: "default-\(url.absoluteString)",
            label: isLowLatency ? "Default LL-HLS Stream Quality" : "Default Stream Quality",
            qualityBadge: isLowLatency ? "LL-HLS" : "HD",
            resolution: nil,
            resolutionText: nil,
            bandwidth: bandwidth,
            bitrateText: formatBandwidth(bandwidth),
            codecs: nil,
            videoCodec: "H.264",
            audioCodec: "AAC",
            frameRate: nil,
            hasAudio: true,
            hasVideo: true,
            isAudioOnly: false,
            hasSubtitles: false,
            subtitleText: nil,
            estimatedSizeBytes: nil,
            estimatedSizeText: "Size unavailable",
            uri: url,
            manifestKind: kind,
            isLive: isLive,
            isLowLatency: isLowLatency
        )
    }

    // MARK: - Codec & Badge Helpers

    public static func formatBandwidthAsBadge(_ bandwidth: Int64) -> String {
        formatBandwidth(bandwidth)
    }

    public static func extractVideoCodec(_ codecs: String?) -> String? {
        guard let codecs = codecs?.lowercased() else { return nil }
        if codecs.contains("avc1") || codecs.contains("h264") { return "H.264" }
        if codecs.contains("hvc1") || codecs.contains("hev1") || codecs.contains("h265") { return "HEVC" }
        if codecs.contains("av01") { return "AV1" }
        if codecs.contains("vp9") { return "VP9" }
        return nil
    }

    public static func extractAudioCodec(_ codecs: String?) -> String? {
        guard let codecs = codecs?.lowercased() else { return nil }
        if codecs.contains("mp4a") || codecs.contains("aac") { return "AAC" }
        if codecs.contains("ac-3") || codecs.contains("ac3") { return "AC-3" }
        if codecs.contains("ec-3") || codecs.contains("eac3") { return "E-AC-3" }
        if codecs.contains("opus") { return "Opus" }
        if codecs.contains("mp3") { return "MP3" }
        if codecs.contains("flac") { return "FLAC" }
        if codecs.contains("alac") { return "ALAC" }
        if codecs.contains("vorbis") { return "Vorbis" }
        return nil
    }
}

