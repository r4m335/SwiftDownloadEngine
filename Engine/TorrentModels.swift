import Foundation

/// Lifecycle state for a torrent managed by the torrent subsystem.
public enum TorrentState: String, Codable, Sendable {
    case queued
    case checking
    case downloading
    case finished
    case seeding
    case paused
    case error
    case removed
}

/// Priority scheduling order for queued torrents.
public enum TorrentPriority: Int, Codable, Comparable, CaseIterable, Sendable {
    case low = 1
    case normal = 2
    case high = 3

    public static func < (lhs: TorrentPriority, rhs: TorrentPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Download priority for individual files within a torrent.
public enum TorrentFilePriority: UInt8, Codable, CaseIterable, Sendable {
    case doNotDownload = 0
    case normal = 4
    case high = 7

    public var title: String {
        switch self {
        case .doNotDownload: return "Don't Download"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }
}

/// Metadata and download state for an individual file within a torrent.
public struct TorrentFileInfo: Identifiable, Codable, Equatable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let path: String
    public let name: String
    public let size: Int64
    public var priority: TorrentFilePriority
    public let progressFraction: Double

    public init(
        index: Int,
        path: String,
        size: Int64,
        priority: TorrentFilePriority = .normal,
        progressFraction: Double = 0.0
    ) {
        self.index = index
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.size = max(0, size)
        self.priority = priority
        self.progressFraction = min(1.0, max(0.0, progressFraction))
    }
}

/// Configurable seeding mode for finished torrents.
public enum SeedingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case doNotSeed = "Stop upon Completion"
    case ratio = "Stop at Ratio"
    case duration = "Stop after Duration"
    case indefinitely = "Seed Indefinitely"

    public var id: String { rawValue }
}

/// User preference and enforcement rules for post-download seeding.
public struct SeedingPreference: Codable, Equatable, Sendable {
    public var mode: SeedingMode
    public var targetRatio: Double
    public var targetDurationSeconds: TimeInterval

    public static let `default` = SeedingPreference(mode: .doNotSeed, targetRatio: 1.0, targetDurationSeconds: 3600)

    public init(mode: SeedingMode = .doNotSeed, targetRatio: Double = 1.0, targetDurationSeconds: TimeInterval = 3600) {
        self.mode = mode
        self.targetRatio = targetRatio
        self.targetDurationSeconds = targetDurationSeconds
    }
}

/// Immutable UI-facing progress snapshot for a torrent task.
public struct TorrentProgress: Codable, Equatable, Sendable {
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public let downloadBytesPerSecond: Double
    public let uploadBytesPerSecond: Double
    public let connectedPeers: Int
    public let activeSeeds: Int
    public let progressFraction: Double

    public init(
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        downloadBytesPerSecond: Double = 0,
        uploadBytesPerSecond: Double = 0,
        connectedPeers: Int = 0,
        activeSeeds: Int = 0,
        progressFraction: Double = 0
    ) {
        self.bytesDownloaded = max(0, bytesDownloaded)
        self.totalBytes = max(0, totalBytes)
        self.downloadBytesPerSecond = max(0, downloadBytesPerSecond)
        self.uploadBytesPerSecond = max(0, uploadBytesPerSecond)
        self.connectedPeers = max(0, connectedPeers)
        self.activeSeeds = max(0, activeSeeds)
        self.progressFraction = min(1, max(0, progressFraction))
    }
}

/// Represents a BitTorrent info-hash supporting both BitTorrent v1 (20-byte SHA-1) and BitTorrent v2 (32-byte SHA-256), or Hybrid torrents containing both.
public struct TorrentInfoHash: Sendable, Codable, Equatable, Hashable, CustomStringConvertible {
    public let v1: String?
    public let v2: String?

    public init(v1: String? = nil, v2: String? = nil) {
        self.v1 = v1?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.v2 = v2?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public init(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.count == 64 {
            self.v1 = nil
            self.v2 = clean
        } else {
            self.v1 = clean
            self.v2 = nil
        }
    }

    public var bestIdentifier: String {
        v1 ?? v2 ?? ""
    }

    public var description: String {
        bestIdentifier
    }

    public var isHybrid: Bool {
        v1 != nil && v2 != nil
    }

    public var isV2Only: Bool {
        v1 == nil && v2 != nil
    }

    public var isV1Only: Bool {
        v1 != nil && v2 == nil
    }
}

// MARK: - Torrent Tracker Models & Validation

public enum TorrentTrackerState: String, Codable, CaseIterable, Sendable {
    case notWorking = "Not Working"
    case updating = "Updating..."
    case working = "Working"
    case notContacted = "Not Contacted"
}

public struct TorrentTrackerInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var tier: Int
    public var url: String
    public var state: TorrentTrackerState
    public var numPeers: Int
    public var numSeeds: Int
    public var numDownloaded: Int
    public var message: String?

    public init(
        tier: Int = 0,
        url: String,
        state: TorrentTrackerState = .notContacted,
        numPeers: Int = 0,
        numSeeds: Int = 0,
        numDownloaded: Int = 0,
        message: String? = nil
    ) {
        self.id = url
        self.tier = tier
        self.url = url
        self.state = state
        self.numPeers = numPeers
        self.numSeeds = numSeeds
        self.numDownloaded = numDownloaded
        self.message = message
    }
}

public enum TorrentTrackerValidationError: LocalizedError, Equatable {
    case emptyURL
    case invalidURLFormat
    case unsupportedScheme(String)
    case missingHost
    case invalidPort(Int)
    case missingUDPPort

    public var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "Tracker URL cannot be empty."
        case .invalidURLFormat:
            return "Invalid tracker URL format."
        case .unsupportedScheme(let scheme):
            return "Unsupported tracker scheme '\(scheme)'. Supported schemes are http, https, udp, and wss."
        case .missingHost:
            return "Tracker URL is missing a valid host."
        case .invalidPort(let port):
            return "Tracker port \(port) is invalid (must be between 1 and 65535)."
        case .missingUDPPort:
            return "UDP tracker URLs must specify a port (e.g. udp://tracker.example.com:6969/announce)."
        }
    }
}

public struct TorrentTrackerURLValidator {
    public static func validate(_ urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TorrentTrackerValidationError.emptyURL }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw TorrentTrackerValidationError.invalidURLFormat
        }
        let allowed = ["http", "https", "udp", "wss", "ws"]
        guard allowed.contains(scheme) else {
            throw TorrentTrackerValidationError.unsupportedScheme(scheme)
        }
        guard let host = url.host, !host.isEmpty else {
            throw TorrentTrackerValidationError.missingHost
        }
        if let port = url.port {
            guard port > 0 && port <= 65535 else {
                throw TorrentTrackerValidationError.invalidPort(port)
            }
        } else if scheme == "udp" {
            throw TorrentTrackerValidationError.missingUDPPort
        }
        return url
    }
}

/// Pure Swift torrent metadata and bencoding parser that operates across all platforms
/// (iOS device builds, macOS, Linux, and Windows) without requiring native libtorrent symbols.
public struct TorrentMetadataParser: Sendable {

    /// Extracts the 40-character hex (or 32-character base32) info-hash from a magnet URI string.
    public static func extractInfoHash(from magnetURI: String) -> String? {
        guard let components = URLComponents(string: magnetURI),
              let queryItems = components.queryItems else {
            return nil
        }
        for item in queryItems where item.name == "xt" {
            guard let value = item.value?.lowercased() else { continue }
            if value.hasPrefix("urn:btih:") {
                let hash = String(value.dropFirst("urn:btih:".count))
                if hash.count == 40 || hash.count == 32 {
                    return hash
                }
            }
        }
        return nil
    }

    /// Extracts the display name from the `dn=` parameter of a magnet URI string.
    public static func extractDisplayName(from magnetURI: String) -> String? {
        guard let components = URLComponents(string: magnetURI),
              let queryItems = components.queryItems else {
            return nil
        }
        for item in queryItems where item.name == "dn" {
            if let name = item.value, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// Extracts bencoded torrent info: the computed infoHash, the suggested name,
    /// and whether it contains multiple files (`isMultiFile`).
    public static func extractBencodedInfo(from data: Data) -> (infoHash: String, name: String?, isMultiFile: Bool)? {
        guard let infoRange = data.range(of: Data("4:info".utf8)) else { return nil }
        let infoStart = infoRange.upperBound
        guard infoStart < data.count, data[infoStart] == 0x64 else { return nil }

        var depth = 0
        var idx = infoStart
        var inString = false
        var stringLength = 0

        while idx < data.count {
            let b = data[idx]
            if inString {
                stringLength -= 1
                if stringLength == 0 { inString = false }
                idx += 1
                continue
            }
            if b >= 0x30 && b <= 0x39 {
                var lenStr = ""
                while idx < data.count && data[idx] >= 0x30 && data[idx] <= 0x39 {
                    lenStr.append(Character(UnicodeScalar(data[idx])))
                    idx += 1
                }
                if idx < data.count && data[idx] == 0x3a {
                    idx += 1
                    if let len = Int(lenStr), len > 0 {
                        inString = true
                        stringLength = len
                    }
                }
                continue
            }
            if b == 0x64 || b == 0x6c {
                depth += 1
                idx += 1
            } else if b == 0x69 {
                idx += 1
                while idx < data.count && data[idx] != 0x65 { idx += 1 }
                if idx < data.count { idx += 1 }
            } else if b == 0x65 {
                depth -= 1
                idx += 1
                if depth == 0 {
                    let infoSlice = data.subdata(in: infoStart..<idx)
                    var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE, h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
                    var msg = infoSlice
                    let bitLength = UInt64(infoSlice.count) * 8
                    msg.append(0x80)
                    while (msg.count % 64) != 56 { msg.append(0x00) }
                    var bigEndianBits = bitLength.bigEndian
                    msg.append(Data(bytes: &bigEndianBits, count: 8))
                    for chunkStart in stride(from: 0, to: msg.count, by: 64) {
                        var w = [UInt32](repeating: 0, count: 80)
                        for i in 0..<16 {
                            let off = chunkStart + i * 4
                            w[i] = UInt32(msg[off]) << 24 | UInt32(msg[off + 1]) << 16 | UInt32(msg[off + 2]) << 8 | UInt32(msg[off + 3])
                        }
                        for i in 16..<80 {
                            let val = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                            w[i] = (val << 1) | (val >> 31)
                        }
                        var a = h0, b = h1, c = h2, d = h3, e = h4
                        for i in 0..<80 {
                            var f: UInt32 = 0, k: UInt32 = 0
                            if i < 20 { f = (b & c) | ((~b) & d); k = 0x5A827999 }
                            else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1 }
                            else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC }
                            else { f = b ^ c ^ d; k = 0xCA62C1D6 }
                            let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
                        }
                        h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
                    }
                    var result = Data()
                    let parts = [h0.bigEndian, h1.bigEndian, h2.bigEndian, h3.bigEndian, h4.bigEndian]
                    for var p in parts { result.append(Data(bytes: &p, count: 4)) }
                    let hashHex = result.map { String(format: "%02x", $0) }.joined()

                    var parsedName: String? = nil
                    if let nameRange = infoSlice.range(of: Data("4:name".utf8)) {
                        let nameStart = nameRange.upperBound
                        if let colonIdx = (nameStart..<min(nameStart + 10, infoSlice.count)).first(where: { infoSlice[$0] == 0x3a }),
                           let len = Int(String(data: infoSlice.subdata(in: nameStart..<colonIdx), encoding: .utf8) ?? ""),
                           colonIdx + 1 + len <= infoSlice.count {
                            parsedName = String(data: infoSlice.subdata(in: (colonIdx + 1)..<(colonIdx + 1 + len)), encoding: .utf8)
                        }
                    }

                    let isMultiFile = infoSlice.range(of: Data("5:files".utf8)) != nil
                    return (hashHex, parsedName, isMultiFile)
                }
            } else {
                idx += 1
            }
        }
        return nil
    }
}

/// Persistent identity and user-visible state for one torrent.
public struct TorrentTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let source: String
    public var name: String
    public let savePath: URL
    public var state: TorrentState
    public var progress: TorrentProgress
    public var errorMessage: String?
    public let createdAt: Date
    public let infoHash: String
    public var infoHashV1: String?
    public var infoHashV2: String?
    public var priority: TorrentPriority
    public var isExplicitlyPaused: Bool
    public var isSequentialDownload: Bool
    public var filePriorities: [Int: TorrentFilePriority]?
    public var seedingPreference: SeedingPreference?
    public var trackers: [TorrentTrackerInfo]?

    public var structuredInfoHash: TorrentInfoHash {
        TorrentInfoHash(v1: infoHashV1 ?? (infoHash.count == 40 ? infoHash : nil),
                        v2: infoHashV2 ?? (infoHash.count == 64 ? infoHash : nil))
    }

    public init(
        id: UUID = UUID(),
        source: String,
        name: String,
        savePath: URL,
        state: TorrentState = .queued,
        progress: TorrentProgress = TorrentProgress(),
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        infoHash: String = "",
        infoHashV1: String? = nil,
        infoHashV2: String? = nil,
        priority: TorrentPriority = .normal,
        isExplicitlyPaused: Bool = false,
        isSequentialDownload: Bool = false,
        filePriorities: [Int: TorrentFilePriority]? = nil,
        seedingPreference: SeedingPreference? = nil,
        trackers: [TorrentTrackerInfo]? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.savePath = savePath
        self.state = state
        self.progress = progress
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        let cleanHash = infoHash.lowercased()
        self.infoHash = cleanHash
        self.infoHashV1 = infoHashV1?.lowercased() ?? (cleanHash.count == 40 ? cleanHash : nil)
        self.infoHashV2 = infoHashV2?.lowercased() ?? (cleanHash.count == 64 ? cleanHash : nil)
        self.priority = priority
        self.isExplicitlyPaused = isExplicitlyPaused
        self.isSequentialDownload = isSequentialDownload
        self.filePriorities = filePriorities
        self.seedingPreference = seedingPreference
        self.trackers = trackers
    }
}

/// Durable persisted metadata for a torrent download in the manifest.
public struct TorrentRecord: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public let id: UUID
    public let infoHash: String
    public let source: String
    public var name: String
    public let savePath: URL
    public let createdAt: Date
    public var updatedAt: Date
    public var state: TorrentState
    public var progress: TorrentProgress
    public var priority: TorrentPriority
    public var sequenceIndex: Int64
    public var isExplicitlyPaused: Bool
    public var isSequentialDownload: Bool
    public var seedRatioLimit: Double?
    public var fastResumeFileName: String?
    public var filePriorities: [Int: TorrentFilePriority]?
    public var seedingPreference: SeedingPreference?
    public var customTrackers: [String]?
    public var schemaVersion: Int
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        infoHash: String,
        source: String,
        name: String,
        savePath: URL,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        state: TorrentState = .queued,
        progress: TorrentProgress = TorrentProgress(),
        priority: TorrentPriority = .normal,
        sequenceIndex: Int64 = 0,
        isExplicitlyPaused: Bool = false,
        isSequentialDownload: Bool = false,
        seedRatioLimit: Double? = nil,
        fastResumeFileName: String? = nil,
        filePriorities: [Int: TorrentFilePriority]? = nil,
        seedingPreference: SeedingPreference? = nil,
        customTrackers: [String]? = nil,
        schemaVersion: Int = TorrentRecord.currentSchemaVersion,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.infoHash = infoHash.lowercased()
        self.source = source
        self.name = name
        self.savePath = savePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.progress = progress
        self.priority = priority
        self.sequenceIndex = sequenceIndex
        self.isExplicitlyPaused = isExplicitlyPaused
        self.isSequentialDownload = isSequentialDownload
        self.seedRatioLimit = seedRatioLimit
        self.fastResumeFileName = fastResumeFileName
        self.filePriorities = filePriorities
        self.seedingPreference = seedingPreference
        self.customTrackers = customTrackers
        self.schemaVersion = schemaVersion
        self.errorMessage = errorMessage
    }

    enum CodingKeys: String, CodingKey {
        case id, infoHash, source, name, savePath, createdAt, updatedAt, state, progress, priority, sequenceIndex, isExplicitlyPaused, isSequentialDownload, seedRatioLimit, fastResumeFileName, filePriorities, seedingPreference, customTrackers, schemaVersion, errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        infoHash = try container.decode(String.self, forKey: .infoHash)
        source = try container.decode(String.self, forKey: .source)
        name = try container.decode(String.self, forKey: .name)
        savePath = try container.decode(URL.self, forKey: .savePath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        state = try container.decode(TorrentState.self, forKey: .state)
        progress = try container.decodeIfPresent(TorrentProgress.self, forKey: .progress) ?? TorrentProgress()
        priority = try container.decodeIfPresent(TorrentPriority.self, forKey: .priority) ?? .normal
        sequenceIndex = try container.decodeIfPresent(Int64.self, forKey: .sequenceIndex) ?? 0
        isExplicitlyPaused = try container.decodeIfPresent(Bool.self, forKey: .isExplicitlyPaused) ?? false
        isSequentialDownload = try container.decodeIfPresent(Bool.self, forKey: .isSequentialDownload) ?? false
        seedRatioLimit = try container.decodeIfPresent(Double.self, forKey: .seedRatioLimit)
        fastResumeFileName = try container.decodeIfPresent(String.self, forKey: .fastResumeFileName)
        filePriorities = try container.decodeIfPresent([Int: TorrentFilePriority].self, forKey: .filePriorities)
        seedingPreference = try container.decodeIfPresent(SeedingPreference.self, forKey: .seedingPreference)
        customTrackers = try container.decodeIfPresent([String].self, forKey: .customTrackers)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

/// Durable root manifest storing the persistent queue state of all tracked torrents.
public struct TorrentQueueManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var maxConcurrentTorrents: Int
    public var sequenceCounter: Int64
    public var records: [TorrentRecord]

    public init(
        schemaVersion: Int = TorrentQueueManifest.currentSchemaVersion,
        maxConcurrentTorrents: Int = 3,
        sequenceCounter: Int64 = 0,
        records: [TorrentRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.maxConcurrentTorrents = max(1, maxConcurrentTorrents)
        self.sequenceCounter = sequenceCounter
        self.records = records
    }
}

/// Point-in-time snapshot of the overall torrent queue state and scheduling distribution.
public struct TorrentQueueSnapshot: Sendable, Equatable {
    public let totalTorrents: Int
    public let activeCount: Int
    public let queuedCount: Int
    public let pausedCount: Int
    public let completedCount: Int
    public let seedingCount: Int
    public let failedCount: Int
    public let records: [TorrentRecord]

    public init(
        totalTorrents: Int,
        activeCount: Int,
        queuedCount: Int,
        pausedCount: Int,
        completedCount: Int,
        seedingCount: Int,
        failedCount: Int,
        records: [TorrentRecord]
    ) {
        self.totalTorrents = totalTorrents
        self.activeCount = activeCount
        self.queuedCount = queuedCount
        self.pausedCount = pausedCount
        self.completedCount = completedCount
        self.seedingCount = seedingCount
        self.failedCount = failedCount
        self.records = records
    }
}

/// Current health and listener state of the native libtorrent session.
public struct TorrentSessionStatus: Equatable, Sendable {
    public let isRunning: Bool
    public let isListening: Bool
    public let listenPort: UInt
    public let portRange: ClosedRange<UInt>
    public let libtorrentVersion: String

    public init(
        isRunning: Bool,
        isListening: Bool,
        listenPort: UInt,
        portRange: ClosedRange<UInt> = 6881...6891,
        libtorrentVersion: String
    ) {
        self.isRunning = isRunning
        self.isListening = isListening
        self.listenPort = listenPort
        self.portRange = portRange
        self.libtorrentVersion = libtorrentVersion
    }
}

/// Errors produced by torrent management, persistence, and transfer operations.
public enum TorrentEngineError: LocalizedError, Equatable, Sendable {
    case sessionNotRunning
    case torrentNotFound
    case bridgeError(String)
    case resumeDataGenerationFailed(String)
    case resumeDataCorrupt(String)
    case persistenceError(String)
    case unsupportedSchemaVersion(Int)
    case duplicateTorrent(String)
    case invalidMagnetURI(String)
    case invalidTorrentFile(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotRunning:
            return "The torrent engine session is not running."
        case .torrentNotFound:
            return "The specified torrent was not found."
        case .bridgeError(let msg):
            return msg
        case .resumeDataGenerationFailed(let msg):
            return "Failed to generate fast-resume data: \(msg)"
        case .resumeDataCorrupt(let msg):
            return "Corrupted or incompatible fast-resume data: \(msg)"
        case .persistenceError(let msg):
            return "Persistence error: \(msg)"
        case .unsupportedSchemaVersion(let ver):
            return "Unsupported persistence schema version: \(ver)"
        case .duplicateTorrent(let hash):
            return "Torrent with info-hash \(hash) already exists."
        case .invalidMagnetURI:
            return "Invalid magnet URI."
        case .invalidTorrentFile(let msg):
            return "Invalid .torrent file: \(msg)"
        }
    }
}
