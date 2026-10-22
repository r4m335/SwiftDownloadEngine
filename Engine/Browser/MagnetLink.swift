import Foundation

public enum MagnetLinkError: Error, LocalizedError, Codable, Sendable, Equatable {
    case invalidScheme
    case invalidStructure
    case missingInfoHash
    case malformedInfoHash
    case unsupportedInfoHash
    case malformedTracker
    case malformedWebSeed
    case invalidContentLength
    case parameterTooLong
    case torrentEngineUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidScheme:
            return "Only magnet links are accepted for torrent handoff."
        case .invalidStructure:
            return "The magnet link structure is invalid."
        case .missingInfoHash:
            return "The magnet link does not contain a supported info-hash."
        case .malformedInfoHash:
            return "The magnet link contains a malformed info-hash."
        case .unsupportedInfoHash:
            return "The magnet link uses an unsupported exact-topic format."
        case .malformedTracker:
            return "The magnet link contains a malformed or unsafe tracker URL."
        case .malformedWebSeed:
            return "The magnet link contains a malformed or unsafe web-seed URL."
        case .invalidContentLength:
            return "The magnet link contains an invalid content length."
        case .parameterTooLong:
            return "The magnet link contains metadata exceeding the supported limit."
        case .torrentEngineUnavailable:
            return "Built-in torrent downloading is unavailable."
        }
    }
}

public enum MagnetInfoHashKind: String, Codable, Sendable, Equatable, Hashable {
    case bitTorrentV1
    case bitTorrentV2
}

public struct MagnetInfoHash: Codable, Sendable, Equatable, Hashable {
    public let kind: MagnetInfoHashKind
    /// V1 values are canonical hexadecimal or uppercase Base32. V2 values are
    /// the canonical hexadecimal multihash beginning with 1220.
    public let value: String

    public init(kind: MagnetInfoHashKind, value: String) {
        self.kind = kind
        self.value = value
    }

    public var displayValue: String { value }
}

public struct MagnetLink: Codable, Sendable, Equatable {
    public let uri: URL
    public let infoHashes: [MagnetInfoHash]
    public let displayName: String?
    public let trackerURLs: [URL]
    public let webSeedURLs: [URL]
    public let contentLength: Int64?

    public init(
        uri: URL,
        infoHashes: [MagnetInfoHash],
        displayName: String? = nil,
        trackerURLs: [URL] = [],
        webSeedURLs: [URL] = [],
        contentLength: Int64? = nil
    ) {
        self.uri = uri
        self.infoHashes = infoHashes
        self.displayName = displayName
        self.trackerURLs = trackerURLs
        self.webSeedURLs = webSeedURLs
        self.contentLength = contentLength
    }

    public var primaryInfoHash: MagnetInfoHash { infoHashes[0] }

    public var identifier: String {
        infoHashes.map(\.displayValue).joined(separator: ", ")
    }

    public var presentationName: String {
        displayName ?? "Torrent \(primaryInfoHash.value.prefix(12))"
    }
}

/// Pure, bounded magnet URI parser. It validates metadata but never resolves,
/// fetches, executes, or logs any referenced URL.
public enum MagnetLinkParser {
    public static let maximumDisplayNameLength = 512
    public static let maximumParameterLength = 4096

    public static func parse(_ value: String) throws -> MagnetLink {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw MagnetLinkError.invalidStructure
        }
        return try parse(url)
    }

    public static func parse(_ url: URL) throws -> MagnetLink {
        guard url.scheme?.lowercased() == "magnet" else {
            throw MagnetLinkError.invalidScheme
        }
        guard url.host == nil || url.host?.isEmpty == true,
              url.user == nil,
              url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MagnetLinkError.invalidStructure
        }

        let items = components.queryItems ?? []
        let exactTopics = items.compactMap { item -> String? in
            guard item.name.lowercased() == "xt", let value = item.value else { return nil }
            return value
        }
        guard !exactTopics.isEmpty else {
            throw MagnetLinkError.missingInfoHash
        }

        let infoHashes = try exactTopics.map(parseExactTopic)
        guard !infoHashes.isEmpty else {
            throw MagnetLinkError.missingInfoHash
        }

        let displayName = try parseDisplayName(items)
        let trackerURLs = try parseURLs(
            items,
            parameter: "tr",
            allowedSchemes: ["http", "https", "udp"],
            error: .malformedTracker
        )
        let webSeedURLs = try parseURLs(
            items,
            parameter: "ws",
            allowedSchemes: ["http", "https"],
            error: .malformedWebSeed
        )
        let contentLength = try parseContentLength(items)

        return MagnetLink(
            uri: url,
            infoHashes: infoHashes,
            displayName: displayName,
            trackerURLs: trackerURLs,
            webSeedURLs: webSeedURLs,
            contentLength: contentLength
        )
    }

    private static func parseExactTopic(_ value: String) throws -> MagnetInfoHash {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = normalized.firstIndex(of: ":")
        guard let separator else { throw MagnetLinkError.malformedInfoHash }

        let namespace = normalized[..<separator].lowercased()
        let hash = String(normalized[normalized.index(after: separator)...])
        guard !hash.isEmpty, hash.count <= maximumParameterLength else {
            throw MagnetLinkError.malformedInfoHash
        }

        switch namespace {
        case "urn":
            return try parseURN(hash)
        default:
            throw MagnetLinkError.unsupportedInfoHash
        }
    }

    private static func parseURN(_ value: String) throws -> MagnetInfoHash {
        guard let separator = value.firstIndex(of: ":") else {
            throw MagnetLinkError.malformedInfoHash
        }
        let kind = value[..<separator].lowercased()
        let hash = String(value[value.index(after: separator)...])

        switch kind {
        case "btih":
            if isHex(hash, count: 40) {
                return MagnetInfoHash(kind: .bitTorrentV1, value: hash.lowercased())
            }
            if isBase32(hash, count: 32) {
                return MagnetInfoHash(kind: .bitTorrentV1, value: hash.uppercased())
            }
            throw MagnetLinkError.malformedInfoHash
        case "btmh":
            guard isHex(hash, count: 68), hash.lowercased().hasPrefix("1220") else {
                throw MagnetLinkError.malformedInfoHash
            }
            return MagnetInfoHash(kind: .bitTorrentV2, value: hash.lowercased())
        default:
            throw MagnetLinkError.unsupportedInfoHash
        }
    }

    private static func parseDisplayName(_ items: [URLQueryItem]) throws -> String? {
        guard let raw = items.first(where: { $0.name.lowercased() == "dn" })?.value,
              !raw.isEmpty else { return nil }
        guard raw.count <= maximumDisplayNameLength else {
            throw MagnetLinkError.parameterTooLong
        }
        let sanitized = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let name = String(String.UnicodeScalarView(sanitized))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func parseURLs(
        _ items: [URLQueryItem],
        parameter: String,
        allowedSchemes: Set<String>,
        error: MagnetLinkError
    ) throws -> [URL] {
        try items
            .filter { $0.name.lowercased() == parameter }
            .compactMap { item in
                guard let value = item.value, !value.isEmpty,
                      value.count <= maximumParameterLength,
                      let url = URL(string: value),
                      let scheme = url.scheme?.lowercased(),
                      allowedSchemes.contains(scheme),
                      let host = url.host, !host.isEmpty,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      components.user == nil,
                      components.password == nil else {
                    throw error
                }
                return url
            }
    }

    private static func parseContentLength(_ items: [URLQueryItem]) throws -> Int64? {
        guard let value = items.first(where: { $0.name.lowercased() == "xl" })?.value else {
            return nil
        }
        guard let length = Int64(value), length > 0 else {
            throw MagnetLinkError.invalidContentLength
        }
        return length
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func isBase32(_ value: String, count: Int) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567abcdefghijklmnopqrstuvwxyz")
        return value.count == count && value.allSatisfy { allowed.contains($0) }
    }
}
