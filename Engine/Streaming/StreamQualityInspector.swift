import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asynchronously parses and inspects HLS and DASH manifests to discover all available
/// streaming quality variants (resolutions, bitrates, audio tracks) for interactive user selection.
public enum StreamQualityInspector {

    /// Inspects an arbitrary streaming candidate to discover all available quality options.
    public static func inspect(
        candidate: StreamingManifestCandidate,
        session: URLSession = .shared
    ) async throws -> [StreamQualityOption] {
        let manifestText = candidate.cachedManifestText ?? ""
        return try await inspect(
            manifestText: manifestText,
            url: candidate.url,
            mimeType: candidate.mimeType,
            requestContext: candidate.browserRequestContext,
            session: session
        )
    }

    /// Asynchronously inspects a stream from manifest text or remote URL, discovering all available
    /// quality options and fetching child media playlists to determine exact duration and size estimates.
    public static func inspect(
        manifestText: String,
        url: URL,
        mimeType: String? = nil,
        requestContext: BrowserRequestContext? = nil,
        session: URLSession = .shared
    ) async throws -> [StreamQualityOption] {
        let cleanText: String
        if manifestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanText = try await loadManifestText(from: url, requestContext: requestContext, session: session)
        } else {
            cleanText = manifestText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
        }

        let classification = StreamingManifestClassifier.classify(
            url: url,
            mimeType: mimeType,
            content: Data(cleanText.utf8)
        )

        if classification.kind == .dash || url.pathExtension.lowercased() == "mpd" || cleanText.contains("<MPD") {
            return try inspectDASH(manifestText: cleanText, baseURL: url, durationSeconds: nil)
        } else {
            var durationSeconds: Double? = nil
            if let manifest = try? HLSManifestParser.parse(cleanText, baseURL: url) {
                if manifest.playlistType == .media {
                    let totalSec = manifest.segments.reduce(0.0) { $0 + $1.duration }
                    if totalSec > 0 { durationSeconds = totalSec }
                }
            }
            return try inspectHLS(manifestText: cleanText, baseURL: url, durationSeconds: durationSeconds)
        }
    }

    /// Inspects a stream from raw manifest text and URL.
    public static func inspect(
        manifestText: String,
        url: URL,
        mimeType: String? = nil,
        durationSeconds: Double? = nil
    ) throws -> [StreamQualityOption] {
        let cleanText = manifestText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
        let classification = StreamingManifestClassifier.classify(
            url: url,
            mimeType: mimeType,
            content: Data(cleanText.utf8)
        )

        if classification.kind == .dash || url.pathExtension.lowercased() == "mpd" || cleanText.contains("<MPD") {
            return try inspectDASH(manifestText: cleanText, baseURL: url, durationSeconds: durationSeconds)
        } else {
            return try inspectHLS(manifestText: cleanText, baseURL: url, durationSeconds: durationSeconds)
        }
    }

    /// Parses an HLS manifest text into ranked stream quality options.
    public static func inspectHLS(
        manifestText: String,
        baseURL: URL,
        durationSeconds: Double? = nil
    ) throws -> [StreamQualityOption] {
        let manifest = try HLSManifestParser.parse(manifestText, baseURL: baseURL)
        let isLive = manifest.lifecycle == .live || manifest.lifecycle == .event

        guard manifest.playlistType == .master, !manifest.variants.isEmpty else {
            // Media playlist (single variant)
            return [StreamQualityOption.defaultMedia(url: baseURL, mimeType: "application/vnd.apple.mpegurl", kind: .hls, isLive: isLive)]
        }

        // Rank variants highest to lowest and deduplicate redundant quality tiers
        let ranked = try HLSVariantSelector.rank(from: manifest)
        let deduplicated = HLSVariantSelector.deduplicate(ranked)
        var options: [StreamQualityOption] = deduplicated.map { variant in
            let selectedAudio = HLSVariantSelector.selectAudioRendition(for: variant, master: manifest)
            return StreamQualityOption.from(
                variant: variant,
                master: manifest,
                selectedAudioRendition: selectedAudio,
                masterURL: baseURL,
                durationSeconds: durationSeconds,
                isLive: isLive
            )
        }

        // Disambiguate duplicate labels if multiple distinct variants share the same label
        var labelCounts: [String: Int] = [:]
        for opt in options {
            labelCounts[opt.label, default: 0] += 1
        }
        if labelCounts.values.contains(where: { $0 > 1 }) {
            options = options.map { opt in
                guard labelCounts[opt.label, default: 0] > 1 else { return opt }
                var tags: [String] = []
                if let fps = opt.frameRate {
                    tags.append("\(Int(fps.rounded()))fps")
                }
                if let vCodec = opt.videoCodec {
                    tags.append(vCodec)
                }
                tags.append(opt.bitrateText)
                let disambiguated = "\(opt.label) (\(tags.joined(separator: ", ")))"
                return StreamQualityOption(
                    id: opt.id,
                    label: disambiguated,
                    qualityBadge: opt.qualityBadge,
                    resolution: opt.resolution,
                    resolutionText: opt.resolutionText,
                    bandwidth: opt.bandwidth,
                    bitrateText: opt.bitrateText,
                    codecs: opt.codecs,
                    videoCodec: opt.videoCodec,
                    audioCodec: opt.audioCodec,
                    frameRate: opt.frameRate,
                    hasAudio: opt.hasAudio,
                    hasVideo: opt.hasVideo,
                    isAudioOnly: opt.isAudioOnly,
                    estimatedSizeBytes: opt.estimatedSizeBytes,
                    estimatedSizeText: opt.estimatedSizeText,
                    uri: opt.uri,
                    manifestKind: opt.manifestKind,
                    hlsVariant: opt.hlsVariant,
                    dashVideoRepresentationID: opt.dashVideoRepresentationID,
                    dashAudioRepresentationID: opt.dashAudioRepresentationID,
                    isLive: opt.isLive
                )
            }
        }

        // Discover separate audio-only renditions if present
        let audioRenditions = manifest.renditions.filter {
            $0.type.uppercased() == "AUDIO" && $0.uri != nil
        }
        for audio in audioRenditions {
            let audioOption = StreamQualityOption.audioOnly(
                rendition: audio,
                masterURL: baseURL,
                durationSeconds: durationSeconds,
                isLive: isLive
            )
            // Prevent duplicate audio IDs
            if !options.contains(where: { $0.id == audioOption.id }) {
                options.append(audioOption)
            }
        }

        return options
    }

    /// Parses a DASH manifest text into ranked stream quality options.
    public static func inspectDASH(
        manifestText: String,
        baseURL: URL,
        durationSeconds: Double? = nil
    ) throws -> [StreamQualityOption] {
        let manifest = try DASHManifestParser.parse(Data(manifestText.utf8), baseURL: baseURL)
        let isLive = manifest.presentationType == .dynamicPresentation
        guard let period = manifest.periods.first else {
            return [StreamQualityOption.defaultMedia(url: baseURL, mimeType: "application/dash+xml", kind: .dash, isLive: isLive)]
        }

        // Find video adaptation sets and audio adaptation sets
        var videoReps: [DASHRepresentation] = []
        var audioReps: [DASHRepresentation] = []

        for adaptation in period.adaptationSets {
            let isVideo = adaptation.contentType?.lowercased() == "video" || adaptation.mimeType?.lowercased().contains("video") == true
            let isAudio = adaptation.contentType?.lowercased() == "audio" || adaptation.mimeType?.lowercased().contains("audio") == true

            for rep in adaptation.representations {
                if rep.hasContentProtection { continue } // Skip DRM representations
                let repMime = rep.mimeType?.lowercased() ?? adaptation.mimeType?.lowercased() ?? ""
                if isVideo || repMime.contains("video") || rep.height != nil {
                    videoReps.append(rep)
                } else if isAudio || repMime.contains("audio") {
                    audioReps.append(rep)
                }
            }
        }

        // Sort video reps highest to lowest bandwidth and deduplicate identical quality tiers
        videoReps.sort { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) }
        var seenVideoKeys = Set<String>()
        videoReps = videoReps.filter { rep in
            let key = "\(rep.width ?? 0)x\(rep.height ?? 0)-\(rep.bandwidth ?? 0)-\(rep.codecs ?? "")"
            return seenVideoKeys.insert(key).inserted
        }
        let defaultAudio = audioReps.first

        var options: [StreamQualityOption] = videoReps.map { rep in
            StreamQualityOption.from(
                dashRepresentation: rep,
                audioRep: defaultAudio,
                baseURL: baseURL,
                durationSeconds: durationSeconds,
                isLive: isLive
            )
        }

        // Add Audio Only option if audio representations exist
        if let audio = defaultAudio {
            let audioBw = audio.bandwidth ?? 128_000
            let estBytes = durationSeconds.flatMap { StreamQualityOption.estimateSize(bandwidth: audioBw, durationSeconds: $0) }
            let estText = estBytes.map { "~\(StreamQualityOption.formatByteSize($0))" }
            let audioURI = audio.baseURL ?? baseURL
            let uriHash = String(EngineSHA256.hash(data: Data(audioURI.absoluteString.utf8)).prefix(8))

            let audioOption = StreamQualityOption(
                id: "dash-audio-\(audio.id ?? "default")-\(uriHash)",
                label: "Audio Only",
                qualityBadge: "AUDIO",
                resolution: nil,
                resolutionText: nil,
                bandwidth: audioBw,
                bitrateText: StreamQualityOption.formatBandwidth(audioBw),
                codecs: audio.codecs,
                videoCodec: nil,
                audioCodec: "AAC",
                frameRate: nil,
                hasAudio: true,
                hasVideo: false,
                isAudioOnly: true,
                estimatedSizeBytes: estBytes,
                estimatedSizeText: estText,
                uri: audio.baseURL ?? baseURL,
                manifestKind: .dash,
                dashVideoRepresentationID: nil,
                dashAudioRepresentationID: audio.id,
                isLive: isLive
            )
            options.append(audioOption)
        }

        if options.isEmpty {
            return [StreamQualityOption.defaultMedia(url: baseURL, mimeType: "application/dash+xml", kind: .dash, isLive: isLive)]
        }

        return options
    }

    // MARK: - Private Network Helper

    public static func loadManifestText(
        from url: URL,
        requestContext: BrowserRequestContext? = nil,
        session: URLSession = .shared
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15.0

        if let context = requestContext {
            let headers = context.effectiveHeaders(for: url)
            for (headerKey, headerValue) in headers {
                request.setValue(headerValue, forHTTPHeaderField: headerKey)
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ManifestParserError.malformed(reason: "HTTP error fetching manifest (Status \(status)).")
        }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        } else {
            throw ManifestParserError.malformed(reason: "Manifest text could not be decoded as text.")
        }
    }
}

