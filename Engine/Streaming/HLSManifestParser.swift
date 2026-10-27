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

        guard let firstMeaningful = lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              firstMeaningful.trimmingCharacters(in: .whitespacesAndNewlines) == "#EXTM3U" else {
            throw ManifestParserError.malformed(reason: "Playlist must begin with #EXTM3U.")
        }

        var version: Int?
        var independentSegments = false
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
        var pendingDiscontinuity = false
        var pendingProgramDate: Date?
        var variants: [HLSVariant] = []
        var renditions: [HLSRendition] = []
        var segments: [HLSMediaSegment] = []

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

            if line.hasPrefix("#EXT-X-MEDIA:") {
                sawMasterTag = true
                let attributes = try parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard let type = attributes["TYPE"],
                      let groupID = attributes["GROUP-ID"],
                      let name = attributes["NAME"] else {
                    throw ManifestParserError.malformed(reason: "EXT-X-MEDIA requires TYPE, GROUP-ID, and NAME.")
                }
                let uri = try optionalURL(attributes["URI"], baseURL: baseURL)
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
                guard let uri = try resolveURL(line, against: baseURL) else {
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
                guard let uri = try resolveURL(line, against: baseURL) else {
                    throw ManifestParserError.invalidURL
                }
                segments.append(HLSMediaSegment(
                    sequenceNumber: mediaSequence + Int64(segments.count),
                    uri: uri,
                    duration: segment.duration,
                    title: segment.title,
                    byteRange: pendingByteRange,
                    initializationMap: currentMap,
                    encryption: currentEncryption,
                    isDiscontinuity: pendingDiscontinuity,
                    programDateTime: pendingProgramDate
                ))
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
                _ = try requiredNonNegativeInt(String(line.dropFirst("#EXT-X-TARGETDURATION:".count)), name: "EXT-X-TARGETDURATION")
                sawMediaTag = true
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = try parseByteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
                sawMediaTag = true
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = try parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uriValue = attributes["URI"], let uri = try resolveURL(uriValue, against: baseURL) else {
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
            return HLSManifest(
                url: baseURL,
                playlistType: .master,
                lifecycle: .vod,
                version: version,
                independentSegments: independentSegments,
                variants: variants,
                renditions: renditions
            )
        }

        guard sawMediaTag, !segments.isEmpty else {
            throw ManifestParserError.malformed(reason: "Playlist contains no media segments or master variants.")
        }
        let lifecycle: HLSPlaylistLifecycle = endList ? .vod : (playlistTypeTag ?? .live)
        return HLSManifest(
            url: baseURL,
            playlistType: .media,
            lifecycle: lifecycle,
            version: version,
            independentSegments: independentSegments,
            segments: segments,
            encryption: currentEncryptionClass
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

    private static func parseByteRange(_ value: String) throws -> HLSByteRange {
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
            offset = nil
        }
        return HLSByteRange(length: length, offset: offset)
    }

    private static func optionalByteRange(_ value: String?) throws -> HLSByteRange? {
        guard let value else { return nil }
        return try parseByteRange(value)
    }

    private static func resolveURL(_ value: String, against baseURL: URL) throws -> URL? {
        guard !value.isEmpty, let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL, isHTTPURL(resolved) else {
            throw ManifestParserError.invalidURL
        }
        // If the child URL has no query parameters, but the baseURL has query parameters (e.g. ?token=... or ?expires=...),
        // inherit the query parameters so that authentication tokens are not stripped on sub-variants or segments.
        if (resolved.query == nil || resolved.query?.isEmpty == true),
           let baseQuery = baseURL.query, !baseQuery.isEmpty,
           var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) {
            components.query = baseQuery
            return components.url ?? resolved
        }
        return resolved
    }

    private static func optionalURL(_ value: String?, baseURL: URL) throws -> URL? {
        guard let value else { return nil }
        return try resolveURL(value, against: baseURL)
    }

    private static func resolveKeyURL(_ value: String?, method: String, baseURL: URL) throws -> URL? {
        guard let value else { return nil }
        guard let resolved = try resolveURL(value, against: baseURL) else {
            throw ManifestParserError.invalidURL
        }
        if method.uppercased() == "AES-128" && !isHTTPURL(resolved) {
            throw ManifestParserError.invalidURL
        }
        return resolved
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else { return false }
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

    private static func maxEncryption(_ lhs: HLSKeyClassification, _ rhs: HLSKeyClassification) -> HLSKeyClassification {
        let rank: [HLSKeyClassification: Int] = [.clear: 0, .aes128: 1, .sampleEncrypted: 2, .unsupported: 3]
        return (rank[rhs] ?? 0) > (rank[lhs] ?? 0) ? rhs : lhs
    }
}
