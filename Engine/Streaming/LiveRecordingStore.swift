import Foundation

/// Durable persisted metadata snapshot of an active or interrupted live stream recording session.
public struct LiveRecordingRecord: Codable, Identifiable, Sendable {
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
        let stagingURL = folder.appendingPathComponent("session.json.tmp")
        try data.write(to: stagingURL, options: .atomic)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: fileURL)
    }

    public func load(sessionID: String) async -> LiveRecordingRecord? {
        if let cached = cache[sessionID] {
            return cached
        }
        let fileURL = sessionFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let record = try? decoder.decode(LiveRecordingRecord.self, from: data) else {
            return nil
        }
        cache[sessionID] = record
        return record
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
