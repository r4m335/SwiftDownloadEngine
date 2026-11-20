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
    public let estimatedSizeBytes: Int64?
    public let estimatedSizeText: String?

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
        videoCodec: String? = nil,
        estimatedSizeBytes: Int64? = nil,
        estimatedSizeText: String? = nil
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
        self.estimatedSizeBytes = estimatedSizeBytes
        self.estimatedSizeText = estimatedSizeText
    }
}

/// Associates observed HLS media playlists with a parsed master playlist so
/// the resource inspector presents one video and its available qualities.
public enum HLSResourceGrouping {
    private final class ManifestBox {
        let manifest: HLSManifest
        init(_ manifest: HLSManifest) { self.manifest = manifest }
    }
    private static let manifestCache = NSCache<NSString, ManifestBox>()

    private static func cachedParse(text: String, baseURL: URL) -> HLSManifest? {
        let key = "\(baseURL.absoluteString)|\(text.hashValue)" as NSString
        if let cached = manifestCache.object(forKey: key) {
            return cached.manifest
        }
        guard let manifest = try? HLSManifestParser.parse(text, baseURL: baseURL) else { return nil }
        manifestCache.setObject(ManifestBox(manifest), forKey: key)
        return manifest
    }

    public static func variantURLs(in resources: [WebpageResource]) -> Set<String> {
        Set(masterManifests(in: resources).flatMap { $0.variants.map { $0.uri.absoluteString.lowercased() } })
    }

    public static func qualitySummary(for resource: WebpageResource) -> String? {
        guard let text = resource.manifestText,
              let manifest = cachedParse(text: text, baseURL: resource.url),
              manifest.playlistType == .master else { return nil }
        let deduplicated = HLSVariantSelector.deduplicate(manifest.variants)
        var seenHeights = Set<Int>()
        var seenBadges = Set<String>()
        var qualityBadges: [String] = []

        let sorted = deduplicated.sorted { lhs, rhs in
            let lRes = (lhs.resolution?.width ?? 0) * (lhs.resolution?.height ?? 0)
            let rRes = (rhs.resolution?.width ?? 0) * (rhs.resolution?.height ?? 0)
            if lRes != rRes { return lRes < rRes }
            return lhs.bandwidth < rhs.bandwidth
        }

        for variant in sorted {
            if let h = variant.resolution?.height {
                if seenHeights.insert(h).inserted {
                    qualityBadges.append("\(h)p")
                }
            } else {
                let badge = formatBandwidthAsQuality(variant.bandwidth)
                if seenBadges.insert(badge).inserted {
                    qualityBadges.append(badge)
                }
            }
        }
        return qualityBadges.isEmpty ? nil : qualityBadges.joined(separator: " · ")
    }

    /// Extracts rich metadata for every variant in a master playlist.
    public static func extractVariantStreamItems(for resource: WebpageResource) -> [HLSVariantStreamItem] {
        guard let text = resource.manifestText,
              let manifest = cachedParse(text: text, baseURL: resource.url),
              manifest.playlistType == .master,
              !manifest.variants.isEmpty else { return [] }

        let hasMasterSubtitles = manifest.renditions.contains {
            $0.type.uppercased() == "SUBTITLES" || $0.type.uppercased() == "CLOSED-CAPTIONS"
        }

        let sorted = manifest.variants.sorted { lhs, rhs in
            let lhsBandwidth = lhs.averageBandwidth ?? lhs.bandwidth
            let rhsBandwidth = rhs.averageBandwidth ?? rhs.bandwidth
            if lhsBandwidth != rhsBandwidth { return lhsBandwidth > rhsBandwidth }
            let lhsPixels = (lhs.resolution?.width ?? 0) * (lhs.resolution?.height ?? 0)
            let rhsPixels = (rhs.resolution?.width ?? 0) * (rhs.resolution?.height ?? 0)
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }
            return lhs.uri.absoluteString < rhs.uri.absoluteString
        }
        let deduplicated = HLSVariantSelector.deduplicate(sorted)

        return deduplicated.map { variant in
            let height = variant.resolution?.height
            let qualityLabel = height.map { "\($0)p" } ?? formatBandwidthAsQuality(variant.bandwidth)
            let resText = variant.resolution.map { "\($0.width)x\($0.height)" }
            let bwText = formatBandwidth(variant.bandwidth)
            let hasSub = variant.subtitlesGroup != nil || hasMasterSubtitles

            let selectedAudio = HLSVariantSelector.selectAudioRendition(for: variant, master: manifest)
            let muxedInCodecs = isAudioInCodecs(variant.codecs)
            let legacyMuxed = (variant.codecs == nil && variant.audioGroup == nil)
            let hasInStreamAudioRendition = (variant.codecs == nil) && manifest.renditions.contains {
                $0.type.uppercased() == "AUDIO" && $0.groupID == variant.audioGroup && $0.uri == nil
            }
            let hasAud = (selectedAudio != nil) || muxedInCodecs || legacyMuxed || hasInStreamAudioRendition
            let audioText: String? = {
                if !hasAud { return nil }
                if let audioName = selectedAudio?.name, !audioName.isEmpty {
                    return audioName
                }
                return "Audio"
            }()

            let vCodec = extractVideoCodecName(variant.codecs)
            let uriHash = String(EngineSHA256.hash(data: Data(variant.uri.absoluteString.utf8)).prefix(8))
            let id = "\(resource.id)-variant-\(variant.bandwidth)-\(height ?? 0)-\(uriHash)"

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
                audioText: audioText,
                hasSubtitles: hasSub,
                subtitleText: hasSub ? "Subtitles" : nil,
                codecs: variant.codecs,
                videoCodec: vCodec
            )
        }
    }

    /// Converts an HLS master resource into individual selectable video items in the grabber list.
    public static func extractVariantResources(from masterResource: WebpageResource) -> [WebpageResource] {
        let items = extractVariantStreamItems(for: masterResource)
        guard !items.isEmpty else { return [masterResource] }

        var seenFilenames = Set<String>()
        return items.map { item in
            let baseFilename = (masterResource.suggestedFilename as NSString).deletingPathExtension
            var filename = "\(baseFilename)-\(item.qualityLabel).mp4"
            var title = "HLS \(item.qualityLabel)"
            if seenFilenames.contains(filename.lowercased()) {
                let disambiguator = item.bitrateText.replacingOccurrences(of: " ", with: "")
                filename = "\(baseFilename)-\(item.qualityLabel)-\(disambiguator).mp4"
                title = "HLS \(item.qualityLabel) (\(item.bitrateText))"
            }
            seenFilenames.insert(filename.lowercased())

            let preferences = HLSVariantSelectionPreferences(
                maximumBandwidth: item.bandwidth,
                maximumWidth: item.resolution?.width,
                maximumHeight: item.resolution?.height,
                exactURI: item.variantURL
            )

            return WebpageResource(
                id: item.id,
                url: masterResource.url, // Points to master manifest so orchestrator plans with variant preferences
                title: title,
                suggestedFilename: filename,
                resourceType: .video,
                mimeType: masterResource.mimeType ?? "application/vnd.apple.mpegurl",
                estimatedSize: item.estimatedSizeBytes,
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
        HLSVariantSelector.isAudioInCodecs(codecs)
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
                  let manifest = cachedParse(text: text, baseURL: resource.url),
                  manifest.playlistType == .master else { return nil }
            return manifest
        }
    }
}
