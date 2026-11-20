import Foundation

/// Parses HLS master and media playlists without loading referenced resources.
public enum HLSManifestParser {

    public static func parse(
        _ data: Data,
        baseURL: URL,
        limits: ManifestParsingLimits = .default
    ) throws -> HLSManifest {
        guard data.count <= limits.maxBytes else {
            throw ManifestParserError.inputTooLarge(limit: limits.maxBytes)
        }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            text = latin1
        } else if let ascii = String(data: data, encoding: .ascii) {
            text = ascii
        } else {
            throw ManifestParserError.malformed(reason: "Playlist is not valid text.")
        }
        return try parse(text, baseURL: baseURL, inputByteCount: data.count, limits: limits)
    }

    public static func parse(
        _ text: String,
        baseURL: URL,
        limits: ManifestParsingLimits = .default
    ) throws -> HLSManifest {
        try parse(text, baseURL: baseURL, inputByteCount: text.utf8.count, limits: limits)
    }

    private static func parse(
        _ text: String,
        baseURL: URL,
        inputByteCount: Int,
        limits: ManifestParsingLimits
    ) throws -> HLSManifest {
        guard isHTTPURL(baseURL) else {
            throw ManifestParserError.invalidURL
        }
        guard inputByteCount <= limits.maxBytes else {
            throw ManifestParserError.inputTooLarge(limit: limits.maxBytes)
        }

        let deadline = Date().addingTimeInterval(limits.maxParsingDuration)
        var lines = text.components(separatedBy: .newlines)
        if let first = lines.first, first.hasPrefix("\u{FEFF}") {
            lines[0] = String(first.dropFirst())
        }

        if let firstMeaningful = lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let trimmedLower = firstMeaningful.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmedLower.hasPrefix("<html") || trimmedLower.hasPrefix("<!doctype html") || (trimmedLower.hasPrefix("<!doctype") && trimmedLower.contains("html")) {
                let snippet = String(text.prefix(500))
                PipelineLogger.shared.log("[HLS Pipeline] Server returned HTML block page instead of manifest. Snippet: \(snippet)")
                throw ManifestParserError.malformed(reason: "Server blocked request. Returned HTML instead of manifest.")
            }
        }

        guard let firstMeaningful = lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              firstMeaningful.trimmingCharacters(in: .whitespacesAndNewlines) == "#EXTM3U" else {
            throw ManifestParserError.malformed(reason: "Playlist must begin with #EXTM3U.")
        }

        var version: Int?
        var independentSegments = false
        var isIFramesOnly = false
        var serverControl: HLSServerControl?
        var partTargetDuration: Double?
        var pendingParts: [HLSPartialSegment] = []
        var allParts: [HLSPartialSegment] = []
        var preloadHints: [HLSPreloadHint] = []
        var lastPartURI: URL?
        var lastPartByteRange: HLSByteRange?
        var playlistTypeTag: HLSPlaylistLifecycle?
        var endList = false
        var mediaSequence: Int64 = 0
        var sawMediaTag = false
        var sawMasterTag = false
        var pendingVariantAttributes: [String: String]?
        var pendingSegment: (duration: Double, title: String?)?
        var pendingByteRange: HLSByteRange?
        var currentMap: HLSInitializationMap?
        var currentEncryption: HLSEncryption?
        var currentEncryptionClass: HLSKeyClassification = .clear
        var targetDuration: Double? = nil
        var pendingDiscontinuity = false
        var pendingProgramDate: Date?
        var variants: [HLSVariant] = []
        var renditions: [HLSRendition] = []
        var segments: [HLSMediaSegment] = []
        var lastSegmentURI: URL?
        var lastSegmentByteRange: HLSByteRange?

        for (index, rawLine) in lines.enumerated() {
            guard Date() <= deadline else { throw ManifestParserError.parsingTimedOut }
            guard index < limits.maxElements else {
                throw ManifestParserError.elementLimitExceeded(limit: limits.maxElements)
            }

            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line != "#EXTM3U" else { continue }

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                sawMasterTag = true
                guard pendingVariantAttributes == nil else {
                    throw ManifestParserError.malformed(reason: "A variant is missing its URI.")
                }
                pendingVariantAttributes = try parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                continue
            }

            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                guard pendingVariantAttributes == nil else {
                    throw ManifestParserError.malformed(reason: "A variant is missing its URI.")
                }
                sawMasterTag = true
                let attributes = try parseAttributes(String(line.dropFirst("#EXT-X-I-FRAME-STREAM-INF:".count)))
                guard let uriString = attributes["URI"],
                      let uri = try resolveVariantURL(uriString, against: baseURL) else {
                    throw ManifestParserError.malformed(reason: "EXT-X-I-FRAME-STREAM-INF requires a valid URI attribute.")
                }
                guard let bandwidthText = attributes["BANDWIDTH"],
                      let bandwidth = positiveInt(bandwidthText) else {
                    throw ManifestParserError.malformed(reason: "EXT-X-I-FRAME-STREAM-INF requires a positive BANDWIDTH.")
                }
                let resolution = try parseResolution(attributes["RESOLUTION"])
                let frameRate = try optionalPositiveDouble(attributes["FRAME-RATE"], name: "FRAME-RATE")
                let averageBandwidth = try optionalPositiveInt(attributes["AVERAGE-BANDWIDTH"], name: "AVERAGE-BANDWIDTH")

                variants.append(HLSVariant(
                    uri: uri,
                    bandwidth: bandwidth,
                    averageBandwidth: averageBandwidth,
                    resolution: resolution,
                    codecs: attributes["CODECS"],
                    frameRate: frameRate,
                    audioGroup: nil,
                    videoGroup: attributes["VIDEO"],
                    subtitlesGroup: nil,
                    isIFrameOnly: true
                ))
                continue
            }

            if line.hasPrefix("#EXT-X-MEDIA:") {
                sawMasterTag = true
                let attributes = try parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard let type = attributes["TYPE"],
                      let groupID = attributes["GROUP-ID"],
                      let name = attributes["NAME"] else {
                    throw ManifestParserError.malformed(reason: "EXT-X-MEDIA requires TYPE, GROUP-ID, and NAME.")
                }
                let uri = try resolveRenditionURL(attributes["URI"], baseURL: baseURL)
                renditions.append(HLSRendition(
                    type: type,
                    groupID: groupID,
                    name: name,
                    uri: uri,
                    language: attributes["LANGUAGE"],
                    isDefault: attributes["DEFAULT"]?.uppercased() == "YES",
                    isAutoSelect: attributes["AUTOSELECT"]?.uppercased() == "YES"
                ))
                continue
            }

            if let attributes = pendingVariantAttributes, !line.hasPrefix("#") {
                guard let bandwidthText = attributes["BANDWIDTH"],
                      let bandwidth = positiveInt(bandwidthText) else {
                    throw ManifestParserError.malformed(reason: "EXT-X-STREAM-INF requires a positive BANDWIDTH.")
                }
                let resolution = try parseResolution(attributes["RESOLUTION"])
                let frameRate = try optionalPositiveDouble(attributes["FRAME-RATE"], name: "FRAME-RATE")
                guard let uri = try resolveVariantURL(line, against: baseURL) else {
                    throw ManifestParserError.invalidURL
                }
                variants.append(HLSVariant(
                    uri: uri,
                    bandwidth: bandwidth,
                    averageBandwidth: try optionalPositiveInt(attributes["AVERAGE-BANDWIDTH"], name: "AVERAGE-BANDWIDTH"),
                    resolution: resolution,
                    codecs: attributes["CODECS"],
                    frameRate: frameRate,
                    audioGroup: attributes["AUDIO"],
                    videoGroup: attributes["VIDEO"],
                    subtitlesGroup: attributes["SUBTITLES"]
                ))
                pendingVariantAttributes = nil
                continue
            }

            if let segment = pendingSegment, !line.hasPrefix("#") {
                guard let uri = try resolveSegmentURL(line, against: baseURL) else {
                    throw ManifestParserError.invalidURL
                }

                let resolvedByteRange: HLSByteRange?
                if let pbr = pendingByteRange {
                    let offset: Int64
                    if let explicitOffset = pbr.offset {
                        offset = explicitOffset
                    } else if let lastRange = lastSegmentByteRange,
                              let lastOffset = lastRange.offset,
                              let lastURI = lastSegmentURI,
                              lastURI == uri {
                        guard lastOffset <= Int64.max - lastRange.length else {
                            throw ManifestParserError.malformed(reason: "Byte range offset overflow.")
                        }
                        offset = lastOffset + lastRange.length
                    } else {
                        offset = 0
                    }
                    let resolved = HLSByteRange(length: pbr.length, offset: offset)
                    resolvedByteRange = resolved
                    lastSegmentByteRange = resolved
                    lastSegmentURI = uri
                } else {
                    resolvedByteRange = nil
                    lastSegmentByteRange = nil
                    lastSegmentURI = uri
                }

                segments.append(HLSMediaSegment(
                    sequenceNumber: mediaSequence + Int64(segments.count),
                    uri: uri,
                    duration: segment.duration,
                    title: segment.title,
                    byteRange: resolvedByteRange,
                    initializationMap: currentMap,
                    encryption: currentEncryption,
                    isDiscontinuity: pendingDiscontinuity,
                    programDateTime: pendingProgramDate,
                    parts: pendingParts
                ))
                pendingParts.removeAll()
                pendingSegment = nil
                pendingByteRange = nil
                pendingDiscontinuity = false
                pendingProgramDate = nil
                continue
            }

            guard line.hasPrefix("#") else {
                throw ManifestParserError.malformed(reason: "Unexpected URI without a preceding HLS tag.")
            }

            if line.hasPrefix("#EXT-X-VERSION:") {
                version = try requiredNonNegativeInt(String(line.dropFirst("#EXT-X-VERSION:".count)), name: "EXT-X-VERSION")
            } else if line == "#EXT-X-INDEPENDENT-SEGMENTS" {
                independentSegments = true
            } else if line == "#EXT-X-ENDLIST" {
                endList = true
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                let value = String(line.dropFirst("#EXT-X-PLAYLIST-TYPE:".count)).uppercased()
                switch value {
                case "VOD": playlistTypeTag = .vod
                case "EVENT": playlistTypeTag = .event
                default: throw ManifestParserError.unsupported(reason: "Unknown HLS playlist type.")
                }
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = try requiredNonNegativeInt64(String(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)), name: "EXT-X-MEDIA-SEQUENCE")
            } else if line.hasPrefix("#EXTINF:") {
                guard pendingSegment == nil else {
                    throw ManifestParserError.malformed(reason: "A media segment is missing its URI.")
                }
                let value = String(line.dropFirst("#EXTINF:".count))
                let parts = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                guard let duration = Double(parts[0].trimmingCharacters(in: .whitespaces)), duration.isFinite, duration >= 0 else {
                    throw ManifestParserError.malformed(reason: "EXTINF contains an invalid duration.")
                }
                let title = parts.count > 1 ? String(parts[1]) : nil
                pendingSegment = (duration, title)
                sawMediaTag = true
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                let td = try requiredNonNegativeInt(String(line.dropFirst("#EXT-X-TARGETDURATION:".count)), name: "EXT-X-TARGETDURATION")
                targetDuration = Double(td)
                sawMediaTag = true
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = try parseByteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
                sawMediaTag = true
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = try parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uriValue = attributes["URI"], let uri = try resolveSegmentURL(uriValue, against: baseURL) else {
                    throw ManifestParserError.malformed(reason: "EXT-X-MAP requires a valid URI.")
                }
                currentMap = HLSInitializationMap(uri: uri, byteRange: try optionalByteRange(attributes["BYTERANGE"]))
                sawMediaTag = true
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = try parseAttributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                guard let method = attributes["METHOD"], !method.isEmpty else {
                    throw ManifestParserError.malformed(reason: "EXT-X-KEY requires METHOD.")
                }
                if method.uppercased() == "NONE" {
                    currentEncryption = nil
                    currentEncryptionClass = maxEncryption(currentEncryptionClass, .clear)
                } else {
                    let keyURL = try resolveKeyURL(attributes["URI"], method: method, baseURL: baseURL)
                    let encryption = HLSEncryption(
                        method: method,
                        keyURL: keyURL,
                        iv: attributes["IV"],
                        keyFormat: attributes["KEYFORMAT"],
                        keyFormatVersions: attributes["KEYFORMATVERSIONS"]
                    )
                    currentEncryption = encryption
                    currentEncryptionClass = maxEncryption(currentEncryptionClass, encryption.classification)
                }
                sawMediaTag = true
            } else if line == "#EXT-X-DISCONTINUITY" {
                pendingDiscontinuity = true
                sawMediaTag = true
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                let value = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
                guard let date = ISO8601DateFormatter().date(from: value) else {
                    throw ManifestParserError.malformed(reason: "EXT-X-PROGRAM-DATE-TIME contains an invalid date.")
                }
                pendingProgramDate = date
                sawMediaTag = true
            } else if line == "#EXT-X-I-FRAMES-ONLY" {
                isIFramesOnly = true
                sawMediaTag = true
            } else if line.hasPrefix("#EXT-X-SERVER-CONTROL:") {
                guard pendingVariantAttributes == nil else {
                    throw ManifestParserError.malformed(reason: "A variant is missing its URI.")
                }
                guard pendingSegment == nil else {
                    throw ManifestParserError.malformed(reason: "A media segment is missing its URI.")
                }
                let attributes = try parseAttributes(String(line.dropFirst("#EXT-X-SERVER-CONTROL:".count)))
                let canBlock = attributes["CAN-BLOCK-RELOAD"]?.uppercased() == "YES"
                let canSkipDate = attributes["CAN-SKIP-DATE-RANGES"]?.uppercased() == "YES"
                let canSkipUntil = try optionalPositiveDouble(attributes["CAN-SKIP-UNTIL"], name: "CAN-SKIP-UNTIL")
                let holdBack = try optionalPositiveDouble(attributes["HOLD-BACK"], name: "HOLD-BACK")
                let partHoldBack = try optionalPositiveDouble(attributes["PART-HOLD-BACK"], name: "PART-HOLD-BACK")
                serverControl = HLSServerControl(
                    canBlockReload: canBlock,
                    canSkipUntil: canSkipUntil,
                    canSkipDateRanges: canSkipDate,
                    holdBack: holdBack,
                    partHoldBack: partHoldBack
                )
                if !sawMasterTag {
                    sawMediaTag = true
                }
            } else if line.hasPrefix("#EXT-X-PART-INF:") {
                guard pendingVariantAttributes == nil else {
                    throw ManifestParserError.malformed(reason: "A variant is missing its URI.")
                }
                guard pendingSegment == nil else {
                    throw ManifestParserError.malformed(reason: "A media segment is missing its URI.")
                }
                let attributes = try parseAttributes(String(line.dropFirst("#EXT-X-PART-INF:".count)))
                guard let targetText = attributes["PART-TARGET"],
                      let target = Double(targetText), target > 0, target.isFinite else {
                    throw ManifestParserError.malformed(reason: "EXT-X-PART-INF requires a positive PART-TARGET.")
                }
                partTargetDuration = target
                sawMediaTag = true
            } else if line.hasPrefix("#EXT-X-PART:") {
                guard pendingVariantAttributes == nil else {
                    throw ManifestParserError.malformed(reason: "A variant is missing its URI.")
                }
                guard pendingSegment == nil else {
                    throw ManifestParserError.malformed(reason: "A media segment is missing its URI.")
                }
                let attributes = try parseAttributes(String(line.dropFirst("#EXT-X-PART:".count)))
                guard let uriValue = attributes["URI"],
                      let uri = try resolveSegmentURL(uriValue, against: baseURL) else {
                    throw ManifestParserError.malformed(reason: "EXT-X-PART requires a valid URI attribute.")
                }
                guard let durationText = attributes["DURATION"],
                      let duration = Double(durationText), duration >= 0, duration.isFinite else {
                    throw ManifestParserError.malformed(reason: "EXT-X-PART requires a non-negative DURATION.")
                }
                let isIndependent = attributes["INDEPENDENT"]?.uppercased() == "YES"
                let isGap = attributes["GAP"]?.uppercased() == "YES"

                let resolvedByteRange: HLSByteRange?
                if let rangeText = attributes["BYTERANGE"] {
                    let parsed = try parseByteRange(rangeText, defaultOffset: nil)
                    if let offset = parsed.offset {
                        resolvedByteRange = parsed
                    } else {
                        let contOffset: Int64
                        if lastPartURI == uri, let lastRange = lastPartByteRange {
                            contOffset = (lastRange.offset ?? 0) + lastRange.length
                        } else {
                            contOffset = 0
                        }
                        resolvedByteRange = HLSByteRange(length: parsed.length, offset: contOffset)
                    }
                    lastPartURI = uri
                    lastPartByteRange = resolvedByteRange
                } else {
                    resolvedByteRange = nil
                    lastPartURI = nil
                    lastPartByteRange = nil
                }

                let part = HLSPartialSegment(
                    uri: uri,
                    duration: duration,
                    isIndependent: isIndependent,
                    byteRange: resolvedByteRange,
                    isGap: isGap
                )
                pendingParts.append(part)
                allParts.append(part)
                sawMediaTag = true
            } else if line.hasPrefix("#EXT-X-PRELOAD-HINT:") {
                guard pendingVariantAttributes == nil else {
                    throw ManifestParserError.malformed(reason: "A variant is missing its URI.")
                }
                guard pendingSegment == nil else {
                    throw ManifestParserError.malformed(reason: "A media segment is missing its URI.")
                }
                let attributes = try parseAttributes(String(line.dropFirst("#EXT-X-PRELOAD-HINT:".count)))
                guard let typeText = attributes["TYPE"]?.uppercased(),
                      let hintType = HLSPreloadHintType(rawValue: typeText) else {
                    throw ManifestParserError.malformed(reason: "EXT-X-PRELOAD-HINT requires a valid TYPE (PART or MAP).")
                }
                guard let uriValue = attributes["URI"],
                      let uri = try resolveSegmentURL(uriValue, against: baseURL) else {
                    throw ManifestParserError.malformed(reason: "EXT-X-PRELOAD-HINT requires a valid URI attribute.")
                }
                let start = try optionalNonNegativeInt64(attributes["BYTERANGE-START"], name: "BYTERANGE-START")
                let length = try optionalPositiveInt64(attributes["BYTERANGE-LENGTH"], name: "BYTERANGE-LENGTH")
                preloadHints.append(HLSPreloadHint(
                    type: hintType,
                    uri: uri,
                    byteRangeStart: start,
                    byteRangeLength: length
                ))
                sawMediaTag = true
            }
        }

        if pendingVariantAttributes != nil {
            throw ManifestParserError.malformed(reason: "A variant is missing its URI.")
        }
        if pendingSegment != nil {
            throw ManifestParserError.malformed(reason: "A media segment is missing its URI.")
        }

        if sawMasterTag {
            guard !variants.isEmpty || !renditions.isEmpty else {
                throw ManifestParserError.malformed(reason: "Master playlist contains no variants or renditions.")
            }
            let lifecycle: HLSPlaylistLifecycle = playlistTypeTag ?? (endList ? .vod : .vod)
            return HLSManifest(
                url: baseURL,
                playlistType: .master,
                lifecycle: lifecycle,
                version: version,
                independentSegments: independentSegments,
                isIFramesOnly: isIFramesOnly,
                serverControl: serverControl,
                partTargetDuration: partTargetDuration,
                parts: allParts,
                preloadHints: preloadHints,
                variants: variants,
                renditions: renditions
            )
        }

        var finalSegments = segments
        var hasSynthesized = false
        if finalSegments.isEmpty && !allParts.isEmpty {
            // Low-Latency HLS playlist containing only partial segments (no complete media segments yet)
            for (index, part) in allParts.enumerated() {
                finalSegments.append(HLSMediaSegment(
                    sequenceNumber: mediaSequence + Int64(index),
                    uri: part.uri,
                    duration: part.duration,
                    title: nil,
                    byteRange: part.byteRange,
                    initializationMap: currentMap,
                    encryption: currentEncryption,
                    isDiscontinuity: false,
                    programDateTime: nil,
                    parts: [part]
                ))
            }
            hasSynthesized = true
        } else if finalSegments.isEmpty && allParts.isEmpty && !preloadHints.isEmpty {
            for (index, hint) in preloadHints.enumerated() where hint.type == .part {
                let range: HLSByteRange?
                if let len = hint.byteRangeLength {
                    range = HLSByteRange(length: len, offset: hint.byteRangeStart ?? 0)
                } else {
                    range = nil
                }
                finalSegments.append(HLSMediaSegment(
                    sequenceNumber: mediaSequence + Int64(index),
                    uri: hint.uri,
                    duration: partTargetDuration ?? targetDuration ?? 1.0,
                    title: nil,
                    byteRange: range,
                    initializationMap: currentMap,
                    encryption: currentEncryption,
                    isDiscontinuity: false,
                    programDateTime: nil,
                    parts: []
                ))
            }
            if !finalSegments.isEmpty {
                hasSynthesized = true
            }
        }

        guard sawMediaTag, !finalSegments.isEmpty else {
            throw ManifestParserError.malformed(reason: "Playlist contains no media segments or master variants.")
        }
        let lifecycle: HLSPlaylistLifecycle = endList ? .vod : (playlistTypeTag ?? .live)
        return HLSManifest(
            url: baseURL,
            playlistType: .media,
            lifecycle: lifecycle,
            version: version,
            independentSegments: independentSegments,
            isIFramesOnly: isIFramesOnly,
            serverControl: serverControl,
            partTargetDuration: partTargetDuration,
            parts: allParts,
            preloadHints: preloadHints,
            segments: finalSegments,
            encryption: currentEncryptionClass,
            targetDuration: targetDuration,
            hasSynthesizedSegmentsFromParts: hasSynthesized
        )
    }

    private static func parseAttributes(_ value: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var token = ""
        var quoted = false
        var quote: Character = "\""
        var tokens: [String] = []

        for character in value {
            if character == "\"" || character == "'" {
                if quoted && character == quote {
                    quoted = false
                } else if !quoted {
                    quoted = true
                    quote = character
                }
            }
            if character == "," && !quoted {
                tokens.append(token)
                token = ""
            } else {
                token.append(character)
            }
        }
        tokens.append(token)

        for item in tokens {
            guard let equals = item.firstIndex(of: "=") else {
                throw ManifestParserError.malformed(reason: "Invalid attribute without '='.")
            }
            let key = item[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            var value = String(item[item.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines))
            if value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { throw ManifestParserError.malformed(reason: "Empty attribute name.") }
            result[key] = value
        }
        return result
    }

    private static func parseResolution(_ value: String?) throws -> HLSResolution? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: "x", omittingEmptySubsequences: true)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            throw ManifestParserError.malformed(reason: "RESOLUTION must be positive WIDTHxHEIGHT values.")
        }
        return HLSResolution(width: width, height: height)
    }

    private static func parseByteRange(_ value: String, defaultOffset: Int64? = nil) throws -> HLSByteRange {
        let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let length = Int64(parts[0]), length > 0 else {
            throw ManifestParserError.malformed(reason: "BYTERANGE length must be positive.")
        }
        let offset: Int64?
        if parts.count == 2 {
            guard let parsed = Int64(parts[1]), parsed >= 0 else {
                throw ManifestParserError.malformed(reason: "BYTERANGE offset must be non-negative.")
            }
            offset = parsed
        } else {
            offset = defaultOffset
        }
        return HLSByteRange(length: length, offset: offset)
    }

    private static func optionalByteRange(_ value: String?) throws -> HLSByteRange? {
        guard let value else { return nil }
        return try parseByteRange(value, defaultOffset: 0)
    }

    private static func resolveURL(_ value: String, against baseURL: URL) throws -> URL? {
        guard !value.isEmpty else { throw ManifestParserError.invalidURL }
        if let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL, isHTTPURL(resolved) {
            return resolved
        }
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlQueryAllowed).union(.urlPathAllowed)),
           let resolved = URL(string: encoded, relativeTo: baseURL)?.absoluteURL, isHTTPURL(resolved) {
            return resolved
        }
        throw ManifestParserError.invalidURL
    }

    private static func resolveVariantURL(_ value: String, against baseURL: URL) throws -> URL? {
        guard let resolved = try resolveURL(value, against: baseURL) else { return nil }
        if let baseQuery = baseURL.query, !baseQuery.isEmpty {
            return resolved.mergingParentQuery(baseQuery)
        }
        return resolved
    }

    private static func resolveRenditionURL(_ value: String?, baseURL: URL) throws -> URL? {
        guard let value else { return nil }
        guard let resolved = try resolveURL(value, against: baseURL) else { return nil }
        if let baseQuery = baseURL.query, !baseQuery.isEmpty {
            return resolved.mergingParentQuery(baseQuery)
        }
        return resolved
    }

    private static func resolveSegmentURL(_ value: String, against baseURL: URL) throws -> URL? {
        guard let resolved = try resolveURL(value, against: baseURL) else { return nil }
        let isRelative = !value.hasPrefix("http://") && !value.hasPrefix("https://") && !value.hasPrefix("//")
        if isRelative, let baseQuery = baseURL.query, !baseQuery.isEmpty {
            return resolved.mergingParentQuery(baseQuery)
        }
        return resolved
    }

    private static func optionalURL(_ value: String?, baseURL: URL) throws -> URL? {
        guard let value else { return nil }
        return try resolveURL(value, against: baseURL)
    }

    private static func resolveKeyURL(_ value: String?, method: String, baseURL: URL) throws -> URL? {
        guard let value else { return nil }
        guard var resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              let scheme = resolved.scheme?.lowercased(), !scheme.isEmpty else {
            throw ManifestParserError.invalidURL
        }
        let isRelative = !value.hasPrefix("http://") && !value.hasPrefix("https://") && !value.hasPrefix("//")
        if isRelative, let baseQuery = baseURL.query, !baseQuery.isEmpty {
            resolved = resolved.mergingParentQuery(baseQuery)
        }
        if method.uppercased() == "AES-128" && !isHTTPURL(resolved) {
            throw ManifestParserError.invalidURL
        }
        return resolved
    }

    private static func extractHost(from url: URL) -> String? {
        if let host = url.host, !host.isEmpty {
            return host
        }
        if let compHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host, !compHost.isEmpty {
            return compHost
        }
        let str = url.absoluteString
        guard let schemeEnd = str.range(of: "://")?.upperBound else { return nil }
        let afterScheme = str[schemeEnd...]
        let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let hostPart = authority.split(separator: "@").last ?? authority[...]
        let hostWithoutPort = hostPart.split(separator: ":").first ?? hostPart[...]
        let trimmed = hostWithoutPort.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
              let host = extractHost(from: url), !host.isEmpty else { return false }
        return true
    }

    private static func positiveInt(_ value: String) -> Int? {
        guard let result = Int(value), result > 0 else { return nil }
        return result
    }

    private static func optionalPositiveInt(_ value: String?, name: String) throws -> Int? {
        guard let value else { return nil }
        guard let result = positiveInt(value) else {
            throw ManifestParserError.malformed(reason: "\(name) must be a positive integer.")
        }
        return result
    }

    private static func optionalPositiveDouble(_ value: String?, name: String) throws -> Double? {
        guard let value else { return nil }
        guard let result = Double(value), result.isFinite, result > 0 else {
            throw ManifestParserError.malformed(reason: "\(name) must be a positive number.")
        }
        return result
    }

    private static func requiredNonNegativeInt(_ value: String, name: String) throws -> Int {
        guard let result = Int(value), result >= 0 else {
            throw ManifestParserError.malformed(reason: "\(name) must be a non-negative integer.")
        }
        return result
    }

    private static func requiredNonNegativeInt64(_ value: String, name: String) throws -> Int64 {
        guard let result = Int64(value), result >= 0 else {
            throw ManifestParserError.malformed(reason: "\(name) must be a non-negative integer.")
        }
        return result
    }

    private static func optionalNonNegativeInt64(_ value: String?, name: String) throws -> Int64? {
        guard let value else { return nil }
        guard let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed >= 0 else {
            throw ManifestParserError.malformed(reason: "\(name) must be a non-negative integer.")
        }
        return parsed
    }

    private static func optionalPositiveInt64(_ value: String?, name: String) throws -> Int64? {
        guard let value else { return nil }
        guard let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else {
            throw ManifestParserError.malformed(reason: "\(name) must be a positive integer.")
        }
        return parsed
    }

    private static func maxEncryption(_ lhs: HLSKeyClassification, _ rhs: HLSKeyClassification) -> HLSKeyClassification {
        let rank: [HLSKeyClassification: Int] = [.clear: 0, .aes128: 1, .sampleEncrypted: 2, .unsupported: 3]
        return (rank[rhs] ?? 0) > (rank[lhs] ?? 0) ? rhs : lhs
    }

    /// Extracts all subtitle renditions with their URIs from an HLS manifest.
    public static func extractSubtitles(from manifest: HLSManifest) -> [HLSRendition] {
        return manifest.subtitleRenditions
    }

    /// Parses an HLS manifest and extracts all subtitle renditions.
    public static func extractSubtitles(
        from data: Data,
        baseURL: URL,
        limits: ManifestParsingLimits = .default
    ) throws -> [HLSRendition] {
        let manifest = try parse(data, baseURL: baseURL, limits: limits)
        return manifest.subtitleRenditions
    }
}

extension URL {
    /// Merges missing parent query parameters into this URL while preserving existing query parameters,
    /// order, and fragments without mutating percent-encoding of path/userinfo.
    public func mergingParentQuery(_ parentQuery: String?) -> URL {
        guard let rawParent = parentQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawParent.isEmpty else {
            return self
        }
        let cleanParent = rawParent.hasPrefix("?") ? String(rawParent.dropFirst()) : rawParent
        guard !cleanParent.isEmpty else { return self }

        let urlString = self.absoluteString
        let hashIndex = urlString.firstIndex(of: "#")
        let urlWithoutHash = hashIndex != nil ? String(urlString[..<hashIndex!]) : urlString
        let fragment = hashIndex != nil ? String(urlString[hashIndex!...]) : ""

        if let questionIndex = urlWithoutHash.firstIndex(of: "?") {
            let existingQuery = String(urlWithoutHash[urlWithoutHash.index(after: questionIndex)...])
            let existingKeys: Set<String> = Set(existingQuery.split(separator: "&").compactMap { param in
                let key = param.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                let trimmed = String(key).trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            })

            let parentParams = cleanParent.split(separator: "&")
            var paramsToAppend: [String] = []
            for param in parentParams {
                let trimmed = param.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let key = String(trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces)
                if !existingKeys.contains(key) {
                    paramsToAppend.append(trimmed)
                }
            }

            if paramsToAppend.isEmpty {
                return self
            }
            let mergedParams = paramsToAppend.joined(separator: "&")
            let sep = existingQuery.isEmpty ? "" : "&"
            let newURLString = "\(urlWithoutHash)\(sep)\(mergedParams)\(fragment)"
            return URL(string: newURLString) ?? self
        } else {
            let newURLString = "\(urlWithoutHash)?\(cleanParent)\(fragment)"
            return URL(string: newURLString) ?? self
        }
    }
}
