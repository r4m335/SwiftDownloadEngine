import Foundation

/// Durable persisted metadata snapshot of an active or interrupted live stream recording session.
public struct LiveRecordingRecord: Codable, Identifiable, Sendable, SchemaVersioned {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public let id: String
    public let request: LiveRecordingRequest
    public var state: String
    public var recordedDurationSeconds: Double
    public var recordedSegmentCount: Int
    public var bytesWritten: Int64
    public var recordedSegments: [LiveRecordedSegment]
    public var initializationSegmentURLs: [URL]
    public var committedSegmentKeys: [String]
    public var scratchDirectoryPath: String
    public var outputContainerFormat: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: Int = LiveRecordingRecord.currentSchemaVersion,
        id: String,
        request: LiveRecordingRequest,
        state: String,
        recordedDurationSeconds: Double,
        recordedSegmentCount: Int,
        bytesWritten: Int64,
        recordedSegments: [LiveRecordedSegment] = [],
        initializationSegmentURLs: [URL] = [],
        committedSegmentKeys: [String] = [],
        scratchDirectoryPath: String,
        outputContainerFormat: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.request = request
        self.state = state
        self.recordedDurationSeconds = recordedDurationSeconds
        self.recordedSegmentCount = recordedSegmentCount
        self.bytesWritten = bytesWritten
        self.recordedSegments = recordedSegments
        self.initializationSegmentURLs = initializationSegmentURLs
        self.committedSegmentKeys = committedSegmentKeys
        self.scratchDirectoryPath = scratchDirectoryPath
        self.outputContainerFormat = outputContainerFormat
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, request, state, recordedDurationSeconds, recordedSegmentCount
        case bytesWritten, recordedSegments, initializationSegmentURLs, committedSegmentKeys
        case scratchDirectoryPath, outputContainerFormat, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.id = try c.decode(String.self, forKey: .id)
        self.request = try c.decode(LiveRecordingRequest.self, forKey: .request)
        self.state = try c.decode(String.self, forKey: .state)
        self.recordedDurationSeconds = try c.decode(Double.self, forKey: .recordedDurationSeconds)
        self.recordedSegmentCount = try c.decode(Int.self, forKey: .recordedSegmentCount)
        self.bytesWritten = try c.decode(Int64.self, forKey: .bytesWritten)
        self.recordedSegments = try c.decode([LiveRecordedSegment].self, forKey: .recordedSegments)
        self.initializationSegmentURLs = try c.decode([URL].self, forKey: .initializationSegmentURLs)
        self.committedSegmentKeys = try c.decode([String].self, forKey: .committedSegmentKeys)
        self.scratchDirectoryPath = try c.decode(String.self, forKey: .scratchDirectoryPath)
        self.outputContainerFormat = try c.decodeIfPresent(String.self, forKey: .outputContainerFormat)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// Lightweight summary for discovered interrupted recordings that can be resumed or finalized.
public struct LiveRecordingRecoverySummary: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let manifestURL: URL
    public let destinationURL: URL
    public let recordedDurationSeconds: Double
    public let recordedSegmentCount: Int
    public let bytesWritten: Int64
    public let scratchDirectoryURL: URL
    public let createdAt: Date
    public let updatedAt: Date

    public init(record: LiveRecordingRecord) {
        self.id = record.id
        self.title = record.request.title
        self.manifestURL = record.request.manifestURL
        self.destinationURL = record.request.destinationURL
        self.recordedDurationSeconds = record.recordedDurationSeconds
        self.recordedSegmentCount = record.recordedSegmentCount
        self.bytesWritten = record.bytesWritten
        self.scratchDirectoryURL = URL(fileURLWithPath: record.scratchDirectoryPath)
        self.createdAt = record.createdAt
        self.updatedAt = record.updatedAt
    }
}

/// Thread-safe actor managing durable live recording sessions on disk.
/// Persisted under: `<storageDirectoryURL>/LiveRecordings/<sessionID>/session.json`.
public actor LiveRecordingStore {
    public let storageDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cache: [String: LiveRecordingRecord] = [:]

    public init(storageDirectoryURL: URL? = nil) throws {
        let baseURL: URL
        if let custom = storageDirectoryURL {
            baseURL = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let fallback = FileManager.default.temporaryDirectory
            baseURL = (appSupport ?? fallback).appendingPathComponent("SwiftDownloadEngine/LiveRecordings", isDirectory: true)
        }
        self.storageDirectoryURL = baseURL

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        try FileManager.default.createDirectory(at: self.storageDirectoryURL, withIntermediateDirectories: true)
    }

    private func sessionFolder(for sessionID: String) -> URL {
        storageDirectoryURL.appendingPathComponent(sessionID, isDirectory: true)
    }

    private func sessionFileURL(for sessionID: String) -> URL {
        sessionFolder(for: sessionID).appendingPathComponent("session.json")
    }

    public func save(record: LiveRecordingRecord) async throws {
        var rec = record
        rec.updatedAt = Date()
        cache[record.id] = rec

        let folder = sessionFolder(for: record.id)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let fileURL = sessionFileURL(for: record.id)
        let data = try encoder.encode(rec)
        try DurableStorage.writeAtomically(data, to: fileURL)
    }

    public func load(sessionID: String) async -> LiveRecordingRecord? {
        if let cached = cache[sessionID] {
            return cached
        }
        let fileURL = sessionFileURL(for: sessionID)
        do {
            guard let record = try DurableStorage.load(from: fileURL, decoder: decoder) as LiveRecordingRecord? else {
                return nil
            }
            cache[sessionID] = record
            return record
        } catch {
            PipelineLogger.shared.log(
                stage: .persistence,
                message: "[LiveRecordingStore] Failed to load session \(sessionID) at \(fileURL.path): \(error.localizedDescription)"
            )
            return nil
        }
    }

    public func delete(sessionID: String) async throws {
        cache.removeValue(forKey: sessionID)
        let folder = sessionFolder(for: sessionID)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public func allInterruptedRecords() async -> [LiveRecordingRecord] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var results: [LiveRecordingRecord] = []
        for folder in folders {
            let sessionID = folder.lastPathComponent
            if let rec = await load(sessionID: sessionID) {
                if rec.state == "recording" || rec.state == "preparing" || rec.state == "paused" {
                    results.append(rec)
                }
            }
        }
        return results.sorted(by: { $0.updatedAt > $1.updatedAt })
    }
}
