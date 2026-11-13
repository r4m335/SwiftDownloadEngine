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
        let manifestText: String
        if let cached = candidate.cachedManifestText, !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manifestText = cached
        } else {
            manifestText = try await loadManifestText(from: candidate.url, requestContext: candidate.browserRequestContext, session: session)
        }

        return try inspect(
            manifestText: manifestText,
            url: candidate.url,
            mimeType: candidate.mimeType
        )
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

        guard manifest.playlistType == .master, !manifest.variants.isEmpty else {
            // Media playlist (single variant)
            return [StreamQualityOption.defaultMedia(url: baseURL, mimeType: "application/vnd.apple.mpegurl", kind: .hls)]
        }

        // Rank variants highest to lowest
        let ranked = try HLSVariantSelector.rank(from: manifest)
        var options: [StreamQualityOption] = ranked.map { variant in
            StreamQualityOption.from(
                variant: variant,
                masterURL: baseURL,
                durationSeconds: durationSeconds
            )
        }

        // Discover separate audio-only renditions if present
        let audioRenditions = manifest.renditions.filter {
            $0.type.uppercased() == "AUDIO" && $0.uri != nil
        }
        for audio in audioRenditions {
            let audioOption = StreamQualityOption.audioOnly(
                rendition: audio,
                masterURL: baseURL,
                durationSeconds: durationSeconds
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
        guard let period = manifest.periods.first else {
            return [StreamQualityOption.defaultMedia(url: baseURL, mimeType: "application/dash+xml", kind: .dash)]
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

        // Sort video reps highest to lowest bandwidth
        videoReps.sort { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) }
        let defaultAudio = audioReps.first

        var options: [StreamQualityOption] = videoReps.map { rep in
            StreamQualityOption.from(
                dashRepresentation: rep,
                audioRep: defaultAudio,
                baseURL: baseURL,
                durationSeconds: durationSeconds
            )
        }

        // Add Audio Only option if audio representations exist
        if let audio = defaultAudio {
            let audioBw = audio.bandwidth ?? 128_000
            let estBytes = durationSeconds.flatMap { StreamQualityOption.estimateSize(bandwidth: audioBw, durationSeconds: $0) }
            let estText = estBytes.map { "~\(StreamQualityOption.formatByteSize($0))" }

            let audioOption = StreamQualityOption(
                id: "dash-audio-\(audio.id ?? "default")",
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
                dashAudioRepresentationID: audio.id
            )
            options.append(audioOption)
        }

        if options.isEmpty {
            return [StreamQualityOption.defaultMedia(url: baseURL, mimeType: "application/dash+xml", kind: .dash)]
        }

        return options
    }

    // MARK: - Private Network Helper

    private static func loadManifestText(
        from url: URL,
        requestContext: BrowserRequestContext?,
        session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15.0

        if let context = requestContext {
            if let ua = context.userAgent, !ua.isEmpty {
                request.setValue(ua, forHTTPHeaderField: "User-Agent")
            }
            if let ref = context.referer, !ref.isEmpty {
                request.setValue(ref, forHTTPHeaderField: "Referer")
            }
            let cookieHeader = context.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            if !cookieHeader.isEmpty {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
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

