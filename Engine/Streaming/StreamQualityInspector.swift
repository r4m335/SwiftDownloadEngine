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
            return [StreamQualityOption.defaultMedia(url: baseURL, mimeType: "application/vnd.apple.mpegurl", kind: .hls, isLive: isLive, isLowLatency: manifest.isLowLatency)]
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
                    hasSubtitles: opt.hasSubtitles,
                    subtitleText: opt.subtitleText,
                    estimatedSizeBytes: opt.estimatedSizeBytes,
                    estimatedSizeText: opt.estimatedSizeText,
                    uri: opt.uri,
                    manifestKind: opt.manifestKind,
                    hlsVariant: opt.hlsVariant,
                    dashVideoRepresentationID: opt.dashVideoRepresentationID,
                    dashAudioRepresentationID: opt.dashAudioRepresentationID,
                    isLive: opt.isLive,
                    isIFrameOnly: opt.isIFrameOnly,
                    isLowLatency: opt.isLowLatency
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
        guard !manifest.periods.isEmpty else {
            return [StreamQualityOption.defaultMedia(url: baseURL, mimeType: "application/dash+xml", kind: .dash, isLive: isLive)]
        }

        // Compute effective duration across periods if not explicitly provided
        let effectiveDuration: Double? = {
            if let duration = durationSeconds, duration > 0 {
                return duration
            }
            if let mpdDuration = manifest.mediaPresentationDuration, mpdDuration > 0 {
                return mpdDuration
            }
            let sumPeriodDurations = manifest.periods.compactMap(\.duration).reduce(0.0, +)
            if sumPeriodDurations > 0 {
                return sumPeriodDurations
            }
            return nil
        }()

        struct AudioTrackItem {
            let rep: DASHRepresentation
            let adaptationSet: DASHAdaptationSet
            let period: DASHPeriod
            let language: String?
        }

        struct TextTrackItem {
            let rep: DASHRepresentation
            let adaptationSet: DASHAdaptationSet
            let period: DASHPeriod
            let language: String?
            let isClosedCaption: Bool
        }

        var videoReps: [DASHRepresentation] = []
        var seenVideoKeys = Set<String>()
        var audioTracks: [AudioTrackItem] = []
        var seenAudioKeys = Set<String>()
        var textTracks: [TextTrackItem] = []
        var seenTextKeys = Set<String>()

        // Scan all periods
        for period in manifest.periods {
            for adaptation in period.adaptationSets {
                if adaptation.hasContentProtection { continue } // Skip DRM adaptation sets

                let cType = adaptation.contentType?.lowercased() ?? ""
                let mMime = adaptation.mimeType?.lowercased() ?? ""

                let isTextAdaptation = cType == "text"
                    || cType == "caption"
                    || cType == "subtitle"
                    || mMime.contains("vtt")
                    || mMime.contains("ttml")
                    || mMime.contains("stpp")
                    || mMime.contains("wvtt")
                    || mMime.contains("caption")
                    || mMime.contains("sub")

                let isAudioAdaptation = !isTextAdaptation && (cType == "audio" || mMime.contains("audio"))
                let isVideoAdaptation = !isTextAdaptation && !isAudioAdaptation && (cType == "video" || mMime.contains("video"))

                for rep in adaptation.representations {
                    if rep.hasContentProtection { continue } // Skip DRM representations

                    let repMime = rep.mimeType?.lowercased() ?? mMime
                    let repCodecs = rep.codecs?.lowercased() ?? ""

                    let isTextRep = isTextAdaptation
                        || repMime.contains("vtt")
                        || repMime.contains("ttml")
                        || repMime.contains("stpp")
                        || repMime.contains("wvtt")
                        || repCodecs.contains("wvtt")
                        || repCodecs.contains("stpp")
                        || repCodecs.contains("ttml")

                    if isTextRep {
                        let isCC = cType == "caption"
                            || adaptation.id?.lowercased().contains("cc") == true
                            || rep.id?.lowercased().contains("cc") == true
                        let lang = adaptation.language?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let textKey = "\(isCC ? "cc" : "sub")-\(lang?.lowercased() ?? rep.id ?? "text")"
                        if seenTextKeys.insert(textKey).inserted {
                            textTracks.append(TextTrackItem(
                                rep: rep,
                                adaptationSet: adaptation,
                                period: period,
                                language: lang,
                                isClosedCaption: isCC
                            ))
                        }
                    } else if isAudioAdaptation || repMime.contains("audio") {
                        let lang = adaptation.language?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let bw = rep.bandwidth ?? 0
                        let audioKey = "\(lang?.lowercased() ?? "default")-\(rep.id ?? "")-\(bw)-\(rep.codecs ?? "")"
                        if seenAudioKeys.insert(audioKey).inserted {
                            audioTracks.append(AudioTrackItem(
                                rep: rep,
                                adaptationSet: adaptation,
                                period: period,
                                language: lang
                            ))
                        }
                    } else if isVideoAdaptation || repMime.contains("video") || rep.height != nil {
                        let key = "\(rep.width ?? 0)x\(rep.height ?? 0)-\(rep.bandwidth ?? 0)-\(rep.codecs ?? "")"
                        if seenVideoKeys.insert(key).inserted {
                            videoReps.append(rep)
                        }
                    }
                }
            }
        }

        // Determine default audio representation (preferring English or primary/first track)
        let defaultAudio: DASHRepresentation? = {
            let englishTracks = audioTracks.filter {
                guard let lang = $0.language?.lowercased() else { return false }
                return lang.hasPrefix("en") || lang == "eng"
            }
            if !englishTracks.isEmpty {
                return englishTracks.max(by: { ($0.rep.bandwidth ?? 0) < ($1.rep.bandwidth ?? 0) })?.rep
            }
            return audioTracks.first?.rep
        }()

        // Subtitle summary for video options
        let hasSubtitles = !textTracks.isEmpty
        let subtitleSummary: String? = {
            guard hasSubtitles else { return nil }
            var uniqueShortLangs: [String] = []
            for item in textTracks {
                guard let lang = item.language, !lang.isEmpty else { continue }
                let code2 = SubtitleLanguageCatalog.to2LetterCode(lang).uppercased()
                let displayCode = code2.isEmpty ? lang.uppercased() : code2
                if !uniqueShortLangs.contains(displayCode) {
                    uniqueShortLangs.append(displayCode)
                }
            }
            if uniqueShortLangs.isEmpty {
                return "Subtitles"
            } else {
                return "Subtitles (\(uniqueShortLangs.joined(separator: ", ")))"
            }
        }()

        // Sort video reps highest to lowest bandwidth
        videoReps.sort { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) }

        var options: [StreamQualityOption] = videoReps.map { rep in
            StreamQualityOption.from(
                dashRepresentation: rep,
                audioRep: defaultAudio,
                baseURL: baseURL,
                durationSeconds: effectiveDuration,
                hasSubtitles: hasSubtitles,
                subtitleText: subtitleSummary,
                isLive: isLive
            )
        }

        // Disambiguate identical labels (e.g. multiple 1080p tiers at different bitrates)
        let labelCounts = Dictionary(grouping: options, by: \.label).mapValues(\.count)
        if labelCounts.values.contains(where: { $0 > 1 }) {
            options = options.map { opt in
                guard (labelCounts[opt.label] ?? 0) > 1 else { return opt }
                let disambiguated: String
                if let codec = opt.videoCodec {
                    disambiguated = "\(opt.label) (\(codec), \(opt.bitrateText))"
                } else {
                    disambiguated = "\(opt.label) (\(opt.bitrateText))"
                }
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
                    hasSubtitles: opt.hasSubtitles,
                    subtitleText: opt.subtitleText,
                    estimatedSizeBytes: opt.estimatedSizeBytes,
                    estimatedSizeText: opt.estimatedSizeText,
                    uri: opt.uri,
                    manifestKind: opt.manifestKind,
                    dashVideoRepresentationID: opt.dashVideoRepresentationID,
                    dashAudioRepresentationID: opt.dashAudioRepresentationID,
                    isLive: opt.isLive,
                    isIFrameOnly: opt.isIFrameOnly,
                    isLowLatency: opt.isLowLatency
                )
            }
        }

        // Add Audio Only quality options for all distinct audio tracks / alternate languages
        // Group by language if available, or expose each distinct track
        var seenAudioLangKeys = Set<String>()
        var distinctAudioTracks: [AudioTrackItem] = []
        for track in audioTracks {
            let key = track.language?.lowercased() ?? track.rep.id ?? "\(track.rep.bandwidth ?? 0)"
            if seenAudioLangKeys.insert(key).inserted {
                distinctAudioTracks.append(track)
            }
        }

        for item in distinctAudioTracks {
            let audio = item.rep
            let audioBw = audio.bandwidth ?? 128_000
            let estBytes = effectiveDuration.flatMap { StreamQualityOption.estimateSize(bandwidth: audioBw, durationSeconds: $0) }
            let estText = estBytes.map { "~\(StreamQualityOption.formatByteSize($0))" }
            let audioURI = audio.baseURL ?? item.adaptationSet.baseURL ?? item.period.baseURL ?? baseURL
            let uriHash = String(EngineSHA256.hash(data: Data(audioURI.absoluteString.utf8)).prefix(8))
            let aCodec = StreamQualityOption.extractAudioCodec(audio.codecs) ?? "AAC"

            let langName: String? = {
                guard let l = item.language, !l.isEmpty else { return nil }
                let name = SubtitleLanguageCatalog.displayName(for: l)
                return (name != l && !name.isEmpty) ? name : SubtitleLanguageCatalog.to2LetterCode(l).uppercased()
            }()

            let label: String = {
                if let name = langName {
                    return "Audio Only (\(name))"
                } else if distinctAudioTracks.count == 1 {
                    return "Audio Only"
                } else {
                    return "Audio Only (\(aCodec) \(StreamQualityOption.formatBandwidth(audioBw)))"
                }
            }()

            let repID = audio.id ?? "audio-\(item.language ?? "default")-\(audioBw)"
            let audioOption = StreamQualityOption(
                id: "dash-audio-\(repID)-\(uriHash)",
                label: label,
                qualityBadge: "AUDIO",
                resolution: nil,
                resolutionText: nil,
                bandwidth: audioBw,
                bitrateText: StreamQualityOption.formatBandwidth(audioBw),
                codecs: audio.codecs,
                videoCodec: nil,
                audioCodec: aCodec,
                frameRate: nil,
                hasAudio: true,
                hasVideo: false,
                isAudioOnly: true,
                hasSubtitles: false,
                subtitleText: nil,
                estimatedSizeBytes: estBytes,
                estimatedSizeText: estText,
                uri: audioURI,
                manifestKind: .dash,
                dashVideoRepresentationID: nil,
                dashAudioRepresentationID: audio.id,
                isLive: isLive
            )
            if !options.contains(where: { $0.id == audioOption.id }) {
                options.append(audioOption)
            }
        }

        // Add subtitle and closed caption options
        for item in textTracks {
            let rep = item.rep
            let textURI = rep.baseURL ?? item.adaptationSet.baseURL ?? item.period.baseURL ?? baseURL
            let uriHash = String(EngineSHA256.hash(data: Data(textURI.absoluteString.utf8)).prefix(8))
            let lang = item.language ?? ""
            let langDisplayName: String = {
                if !lang.isEmpty {
                    let name = SubtitleLanguageCatalog.displayName(for: lang)
                    if name != lang && !name.isEmpty { return name }
                    let code2 = SubtitleLanguageCatalog.to2LetterCode(lang).uppercased()
                    if !code2.isEmpty { return code2 }
                }
                return "Unknown"
            }()

            let isCC = item.isClosedCaption
            let badge = isCC ? "CC" : "SUB"
            let label: String = {
                if langDisplayName != "Unknown" {
                    return isCC ? "Closed Captions (\(langDisplayName))" : "Subtitles (\(langDisplayName))"
                } else {
                    return isCC ? "Closed Captions" : "Subtitles"
                }
            }()

            let repID = rep.id ?? "text-\(lang)-\(isCC ? "cc" : "sub")"
            let textOption = StreamQualityOption(
                id: "dash-text-\(repID)-\(uriHash)",
                label: label,
                qualityBadge: badge,
                resolution: nil,
                resolutionText: nil,
                bandwidth: rep.bandwidth ?? 0,
                bitrateText: "Text",
                codecs: rep.codecs ?? item.adaptationSet.codecs,
                videoCodec: nil,
                audioCodec: nil,
                frameRate: nil,
                hasAudio: false,
                hasVideo: false,
                isAudioOnly: false,
                hasSubtitles: true,
                subtitleText: langDisplayName != "Unknown" ? langDisplayName : nil,
                estimatedSizeBytes: nil,
                estimatedSizeText: "< 1 MB",
                uri: textURI,
                manifestKind: .dash,
                dashVideoRepresentationID: nil,
                dashAudioRepresentationID: nil,
                isLive: isLive
            )
            if !options.contains(where: { $0.id == textOption.id }) {
                options.append(textOption)
            }
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

