import Foundation

/// Structured metadata describing an individual variant representation within an HLS master playlist.
public struct HLSVariantStreamItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let masterURL: URL
    public let variantURL: URL
    public let bandwidth: Int
    public let resolution: HLSResolution?
    public let qualityLabel: String // e.g. "1080p", "720p", "480p", "360p"
    public let resolutionText: String? // e.g. "1920x1080"
    public let bitrateText: String // e.g. "5.0 Mbps", "850 Kbps"
    public let hasAudio: Bool
    public let audioText: String? // e.g. "Audio", "AAC"
    public let hasSubtitles: Bool
    public let subtitleText: String? // e.g. "Subtitles", "CC"
    public let codecs: String?
    public let videoCodec: String? // e.g. "H.264", "HEVC", "AV1"

    public init(
        id: String,
        masterURL: URL,
        variantURL: URL,
        bandwidth: Int,
        resolution: HLSResolution? = nil,
        qualityLabel: String,
        resolutionText: String? = nil,
        bitrateText: String,
        hasAudio: Bool = true,
        audioText: String? = "Audio",
        hasSubtitles: Bool = false,
        subtitleText: String? = nil,
        codecs: String? = nil,
        videoCodec: String? = nil
    ) {
        self.id = id
        self.masterURL = masterURL
        self.variantURL = variantURL
        self.bandwidth = bandwidth
        self.resolution = resolution
        self.qualityLabel = qualityLabel
        self.resolutionText = resolutionText
        self.bitrateText = bitrateText
        self.hasAudio = hasAudio
        self.audioText = audioText
        self.hasSubtitles = hasSubtitles
        self.subtitleText = subtitleText
        self.codecs = codecs
        self.videoCodec = videoCodec
    }
}

/// Associates observed HLS media playlists with a parsed master playlist so
/// the resource inspector presents one video and its available qualities.
public enum HLSResourceGrouping {
    public static func variantURLs(in resources: [WebpageResource]) -> Set<String> {
        Set(masterManifests(in: resources).flatMap { $0.variants.map { $0.uri.absoluteString.lowercased() } })
    }

    public static func qualitySummary(for resource: WebpageResource) -> String? {
        guard let text = resource.manifestText,
              let manifest = try? HLSManifestParser.parse(text, baseURL: resource.url),
              manifest.playlistType == .master else { return nil }
        let qualities = manifest.variants.compactMap { $0.resolution?.height }
            .sorted()
            .map { "\($0)p" }
        return qualities.isEmpty ? nil : qualities.joined(separator: " · ")
    }

    /// Extracts rich metadata for every variant in a master playlist (1DM-style).
    public static func extractVariantStreamItems(for resource: WebpageResource) -> [HLSVariantStreamItem] {
        guard let text = resource.manifestText,
              let manifest = try? HLSManifestParser.parse(text, baseURL: resource.url),
              manifest.playlistType == .master,
              !manifest.variants.isEmpty else { return [] }

        let hasMasterSubtitles = manifest.renditions.contains {
            $0.type.uppercased() == "SUBTITLES" || $0.type.uppercased() == "CLOSED-CAPTIONS"
        }
        let hasMasterAudio = manifest.renditions.contains { $0.type.uppercased() == "AUDIO" }

        return manifest.variants.map { variant in
            let height = variant.resolution?.height
            let qualityLabel = height.map { "\($0)p" } ?? formatBandwidthAsQuality(variant.bandwidth)
            let resText = variant.resolution.map { "\($0.width)x\($0.height)" }
            let bwText = formatBandwidth(variant.bandwidth)
            let hasSub = variant.subtitlesGroup != nil || hasMasterSubtitles
            let hasAud = variant.audioGroup != nil || hasMasterAudio || isAudioInCodecs(variant.codecs)
            let vCodec = extractVideoCodecName(variant.codecs)
            let id = "\(resource.id)-variant-\(variant.bandwidth)-\(height ?? 0)"

            return HLSVariantStreamItem(
                id: id,
                masterURL: resource.url,
                variantURL: variant.uri,
                bandwidth: variant.bandwidth,
                resolution: variant.resolution,
                qualityLabel: qualityLabel,
                resolutionText: resText,
                bitrateText: bwText,
                hasAudio: hasAud,
                audioText: hasAud ? "Audio" : nil,
                hasSubtitles: hasSub,
                subtitleText: hasSub ? "Subtitles" : nil,
                codecs: variant.codecs,
                videoCodec: vCodec
            )
        }.sorted { lhs, rhs in
            if lhs.bandwidth != rhs.bandwidth { return lhs.bandwidth > rhs.bandwidth }
            let lPixels = (lhs.resolution?.width ?? 0) * (lhs.resolution?.height ?? 0)
            let rPixels = (rhs.resolution?.width ?? 0) * (rhs.resolution?.height ?? 0)
            return lPixels > rPixels
        }
    }

    /// Converts an HLS master resource into individual selectable video items in the grabber list.
    public static func extractVariantResources(from masterResource: WebpageResource) -> [WebpageResource] {
        let items = extractVariantStreamItems(for: masterResource)
        guard !items.isEmpty else { return [masterResource] }

        return items.map { item in
            let baseFilename = (masterResource.suggestedFilename as NSString).deletingPathExtension
            let filename = "\(baseFilename)-\(item.qualityLabel).mp4"
            let resSuffix = item.resolutionText.map { " (\($0))" } ?? ""
            let title = "\(masterResource.title) · \(item.qualityLabel)\(resSuffix)"

            let preferences = HLSVariantSelectionPreferences(
                maximumBandwidth: item.bandwidth,
                maximumWidth: item.resolution?.width,
                maximumHeight: item.resolution?.height
            )

            return WebpageResource(
                id: item.id,
                url: masterResource.url, // Points to master manifest so orchestrator plans with variant preferences
                title: title,
                suggestedFilename: filename,
                resourceType: .video,
                mimeType: masterResource.mimeType ?? "application/vnd.apple.mpegurl",
                estimatedSize: nil,
                isSupported: true,
                requestContext: masterResource.requestContext,
                manifestText: masterResource.manifestText,
                hlsVariantPreferences: preferences
            )
        }
    }

    public static func formatBandwidth(_ bandwidth: Int) -> String {
        if bandwidth >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000.0)
        } else {
            return "\(bandwidth / 1_000) Kbps"
        }
    }

    public static func formatBandwidthAsQuality(_ bandwidth: Int) -> String {
        if bandwidth >= 6_000_000 { return "1080p" }
        if bandwidth >= 3_000_000 { return "720p" }
        if bandwidth >= 1_500_000 { return "480p" }
        if bandwidth >= 800_000 { return "360p" }
        return "240p"
    }

    public static func isAudioInCodecs(_ codecs: String?) -> Bool {
        guard let codecs = codecs?.lowercased() else { return true }
        return codecs.contains("mp4a") || codecs.contains("aac") || codecs.contains("ac-3") || codecs.contains("ec-3")
    }

    public static func extractVideoCodecName(_ codecs: String?) -> String? {
        guard let codecs = codecs?.lowercased() else { return nil }
        if codecs.contains("avc1") || codecs.contains("h264") { return "H.264" }
        if codecs.contains("hvc1") || codecs.contains("hev1") || codecs.contains("h265") { return "HEVC" }
        if codecs.contains("av01") { return "AV1" }
        if codecs.contains("vp9") { return "VP9" }
        return nil
    }

    private static func masterManifests(in resources: [WebpageResource]) -> [HLSManifest] {
        resources.compactMap { resource in
            guard let text = resource.manifestText,
                  let manifest = try? HLSManifestParser.parse(text, baseURL: resource.url),
                  manifest.playlistType == .master else { return nil }
            return manifest
        }
    }
}
