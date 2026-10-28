import Foundation

/// Lifecycle states matching 1DM+ download status codes.
public enum DownloadState: Codable, Equatable, Sendable {
    case pending
    case probing
    case downloading
    case paused
    case completed
    case failed(reason: String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled:
            return true
        case .pending, .probing, .downloading, .paused, .failed:
            return false
        }
    }

    public var canResume: Bool {
        switch self {
        case .paused, .failed, .downloading:
            return true
        case .pending, .probing, .completed, .cancelled:
            return false
        }
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

/// Policy governing resumption of downloads when remote origin server provides no validator (no ETag and no Last-Modified).
public enum ResumeIntegrityPolicy: String, Codable, Sendable, CaseIterable {
    /// Compatibility mode: Permits resuming when remote Content-Length matches persisted size, matching 1DM+ behavior.
    /// Note: A remote file could change in content while retaining the exact same size.
    case compatibility

    /// Conservative mode: Requires strict validator presence (ETag or Last-Modified).
    /// If no validator is provided to verify resource identity, forces restarting the download fresh from byte 0.
    case conservative
}

/// Result of pre-resume validation against remote server headers.
public enum ResumeValidationResult: Equatable, Sendable {
    /// Safe to resume partial segment downloads.
    case valid

    /// Remote resource size changed, invalidating prior segment boundaries.
    case sizeMismatch(expected: Int64, actual: Int64)

    /// Remote entity tag or modification date changed; file was modified on server.
    case validatorMismatch(
        persistedETag: String?,
        remoteETag: String?,
        persistedLastModified: String?,
        remoteLastModified: String?
    )

    /// Server does not support Range requests; cannot resume.
    case unsupportedNonResumable
}

/// Explicit transport execution policy for HTTP transfers.
public enum HTTPTransportPolicy: String, Codable, Sendable, CaseIterable {
    /// Foreground / in-process streaming transport via concurrent SegmentDownloader.
    /// Default for interactive, direct-seek, or unsegmented downloads.
    case foreground

    /// System-managed out-of-process background URLSession transport.
    /// Uses BackgroundDownloadSessionManager with partFiles mode.
    case background
}

/// Durable segment progress record corresponding to 1DM+'s `ThreadInfo`.
public struct SegmentRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let startOffset: Int64
    public let endOffset: Int64
    public let length: Int64
    public var completedBytes: Int64

    public var isCompleted: Bool {
        completedBytes >= length
    }

    public var remainingBytes: Int64 {
        max(0, length - completedBytes)
    }

    public var resumeStartOffset: Int64 {
        startOffset + completedBytes
    }

    public init(
        id: Int,
        startOffset: Int64,
        endOffset: Int64,
        length: Int64,
        completedBytes: Int64 = 0
    ) {
        self.id = id
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.length = length
        self.completedBytes = completedBytes
    }

    public init(segment: DownloadSegment, completedBytes: Int64 = 0) {
        self.id = segment.id
        self.startOffset = segment.startOffset
        self.endOffset = segment.endOffset
        self.length = segment.length
        self.completedBytes = completedBytes
    }

    public func toDownloadSegment() -> DownloadSegment {
        DownloadSegment(id: id, startOffset: startOffset, endOffset: endOffset, length: length)
    }
}

/// Comprehensive persistent download record reproducing 1DM+'s `DownloadInfo`.
public struct DownloadRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var tag: String { id }
    public let originalURL: URL
    public var resolvedURL: URL?
    public let destinationURL: URL
    public let totalSize: Int64
    public var state: DownloadState
    public var storageMode: DownloadStorageMode
    public var transportPolicy: HTTPTransportPolicy
    public var networkPolicy: DownloadNetworkPolicy
    public var eTag: String?
    public var lastModified: String?
    public var suggestedFilename: String?
    public var mimeType: String?
    public var headers: [String: String]
    public var createdAt: Date
    public var updatedAt: Date
    public var segments: [SegmentRecord]

    public var completedBytes: Int64 {
        segments.reduce(0) { $0 + $1.completedBytes }
    }

    public var remainingBytes: Int64 {
        max(0, totalSize - completedBytes)
    }

    public var fractionCompleted: Double {
        guard totalSize > 0 else { return 0 }
        return min(1.0, Double(completedBytes) / Double(totalSize))
    }

    public var isAllSegmentsCompleted: Bool {
        !segments.isEmpty && segments.allSatisfy { $0.isCompleted }
    }

    public init(
        id: String = UUID().uuidString,
        originalURL: URL,
        resolvedURL: URL? = nil,
        destinationURL: URL,
        totalSize: Int64,
        state: DownloadState = .pending,
        storageMode: DownloadStorageMode = .directSeek,
        transportPolicy: HTTPTransportPolicy = .foreground,
        networkPolicy: DownloadNetworkPolicy = .anyNetwork,
        eTag: String? = nil,
        lastModified: String? = nil,
        suggestedFilename: String? = nil,
        mimeType: String? = nil,
        headers: [String: String] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        segments: [SegmentRecord] = []
    ) {
        self.id = id
        self.originalURL = originalURL
        self.resolvedURL = resolvedURL
        self.destinationURL = destinationURL
        self.totalSize = totalSize
        self.state = state
        self.storageMode = storageMode
        self.transportPolicy = transportPolicy
        self.networkPolicy = networkPolicy
        self.eTag = eTag
        self.lastModified = lastModified
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        var sanitizedHeaders: [String: String] = [:]
        for (k, v) in headers {
            let lower = k.lowercased()
            if lower == "cookie" || lower == "authorization" || lower == "proxy-authorization" {
                if let host = originalURL.host {
                    KeychainManager.shared.storeGenericSecret(key: lower, account: host, data: Data(v.utf8))
                }
            } else {
                sanitizedHeaders[k] = v
            }
        }
        self.headers = sanitizedHeaders
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case id, originalURL, resolvedURL, destinationURL, totalSize, state, storageMode, transportPolicy, networkPolicy
        case eTag, lastModified, suggestedFilename, mimeType, headers, createdAt, updatedAt, segments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.originalURL = try container.decode(URL.self, forKey: .originalURL)
        self.resolvedURL = try container.decodeIfPresent(URL.self, forKey: .resolvedURL)
        self.destinationURL = try container.decode(URL.self, forKey: .destinationURL)
        self.totalSize = try container.decode(Int64.self, forKey: .totalSize)
        self.state = try container.decode(DownloadState.self, forKey: .state)
        self.storageMode = try container.decode(DownloadStorageMode.self, forKey: .storageMode)
        self.transportPolicy = try container.decodeIfPresent(HTTPTransportPolicy.self, forKey: .transportPolicy) ?? .foreground
        self.networkPolicy = try container.decodeIfPresent(DownloadNetworkPolicy.self, forKey: .networkPolicy) ?? .anyNetwork
        self.eTag = try container.decodeIfPresent(String.self, forKey: .eTag)
        self.lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
        self.suggestedFilename = try container.decodeIfPresent(String.self, forKey: .suggestedFilename)
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        self.headers = try container.decode([String: String].self, forKey: .headers)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.segments = try container.decode([SegmentRecord].self, forKey: .segments)
    }

    /// Evaluates remote server headers before resuming an interrupted download.
    /// Matches 1DM+'s consistency checks (e.java:L7331).
    public func validateForResume(
        remoteETag: String?,
        remoteLastModified: String?,
        remoteTotalSize: Int64?,
        policy: ResumeIntegrityPolicy = .compatibility
    ) -> ResumeValidationResult {
        // 1. File size consistency
        if let remoteTotalSize, remoteTotalSize != totalSize {
            return .sizeMismatch(expected: totalSize, actual: remoteTotalSize)
        }

        // 2. Strong validator check (ETag)
        if let persistedETag = eTag, let remoteETag = remoteETag {
            let normalizedPersisted = normalizeValidator(persistedETag)
            let normalizedRemote = normalizeValidator(remoteETag)
            if normalizedPersisted != normalizedRemote {
                return .validatorMismatch(
                    persistedETag: persistedETag,
                    remoteETag: remoteETag,
                    persistedLastModified: lastModified,
                    remoteLastModified: remoteLastModified
                )
            }
        }

        // 3. Weak validator fallback (Last-Modified) when ETag is absent
        if eTag == nil, let persistedLM = lastModified, let remoteLM = remoteLastModified {
            if persistedLM != remoteLM {
                return .validatorMismatch(
                    persistedETag: eTag,
                    remoteETag: remoteETag,
                    persistedLastModified: persistedLM,
                    remoteLastModified: remoteLM
                )
            }
        }

        // 4. Validator-absent evaluation
        let hasPersistedValidator = (eTag != nil || lastModified != nil)
        let hasRemoteValidator = (remoteETag != nil || remoteLastModified != nil)

        if !hasPersistedValidator && !hasRemoteValidator {
            switch policy {
            case .compatibility:
                return .valid
            case .conservative:
                return .unsupportedNonResumable
            }
        }

        return .valid
    }

    public mutating func updateSegmentProgress(segmentID: Int, completedBytes: Int64) {
        if let index = segments.firstIndex(where: { $0.id == segmentID }) {
            segments[index].completedBytes = min(segments[index].length, max(0, completedBytes))
            updatedAt = Date()
        }
    }

    public mutating func transition(to newState: DownloadState) {
        if state == .completed && newState != .completed {
            if case .failed = newState {
                self.state = newState
                self.updatedAt = Date()
                return
            }
            return
        }
        if state == .cancelled && newState != .cancelled {
            return
        }
        self.state = newState
        self.updatedAt = Date()
    }

    private func normalizeValidator(_ validator: String) -> String {
        var trimmed = validator.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("W/") || trimmed.hasPrefix("w/") {
            trimmed = String(trimmed.dropFirst(2))
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

/// Errors raised by `DownloadPersistenceStore`.
public enum DownloadPersistenceError: Error, LocalizedError, Equatable, Sendable {
    case recordNotFound(tag: String)
    case segmentNotFound(tag: String, segmentID: Int)
    case invalidCompletedBytes(provided: Int64, segmentLength: Int64)
    case directoryCreationFailed(path: String, underlyingError: String)
    case serializationFailed(underlyingError: String)
    case corruptedRecord(tag: String, underlyingError: String)

    public var errorDescription: String? {
        switch self {
        case .recordNotFound(let tag):
            return "Download record not found for tag: \(tag)"
        case .segmentNotFound(let tag, let segmentID):
            return "Segment \(segmentID) not found in download record: \(tag)"
        case .invalidCompletedBytes(let provided, let segmentLength):
            return "Completed bytes (\(provided)) exceeds segment length (\(segmentLength))"
        case .directoryCreationFailed(let path, let underlying):
            return "Failed to create storage directory at \(path): \(underlying)"
        case .serializationFailed(let underlying):
            return "Failed to encode/decode download record: \(underlying)"
        case .corruptedRecord(let tag, let underlying):
            return "Corrupted record for tag \(tag): \(underlying)"
        }
    }
}

/// Thread-safe actor managing persistent download records on disk.
///
/// Features:
/// - Atomic disk writes preventing corrupt state during crashes or power cuts.
/// - In-memory cache for high-throughput progress updates without repetitive filesystem scans.
/// - ISO 8601 date serialization matching standard interchange formats.
/// - Segment-level progress persistence matching 1DM+'s `threads` SQLite table.
public actor DownloadPersistenceStore {
    public let storageDirectoryURL: URL

    private var cache: [String: DownloadRecord] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(storageDirectoryURL: URL? = nil) throws {
        let directoryURL: URL
        if let customURL = storageDirectoryURL {
            directoryURL = customURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let fallback = FileManager.default.temporaryDirectory
            let base = appSupport ?? fallback
            directoryURL = base.appendingPathComponent("1DMDownloads/Metadata", isDirectory: true)
        }

        self.storageDirectoryURL = directoryURL

        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = jsonEncoder

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        self.decoder = jsonDecoder

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw DownloadPersistenceError.directoryCreationFailed(
                path: directoryURL.path,
                underlyingError: error.localizedDescription
            )
        }
    }

    /// Safe fallback initializer that ensures storage is allocated without throwing.
    public init(inMemory: Bool) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("1DMDownloads_Mem_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        self.storageDirectoryURL = tempURL
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = jsonEncoder
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        self.decoder = jsonDecoder
    }

    /// Persists or updates a download record atomically.
    public func save(_ record: DownloadRecord) throws {
        cache[record.id] = record
        try writeRecordToDisk(record)
    }

    /// Atomically updates a single segment's completed byte count.
    /// By default, completed bytes are monotonic (`max(existing, completedBytes)`).
    /// If `allowDecrease == true`, explicitly sets the byte count (e.g. during disk reconciliation or reset).
    @discardableResult
    public func updateSegmentProgress(
        tag: String,
        segmentID: Int,
        completedBytes: Int64,
        allowDecrease: Bool = false
    ) throws -> DownloadRecord {
        guard var record = try fetch(tag: tag) else {
            throw DownloadPersistenceError.recordNotFound(tag: tag)
        }

        guard let segmentIndex = record.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw DownloadPersistenceError.segmentNotFound(tag: tag, segmentID: segmentID)
        }

        let segment = record.segments[segmentIndex]
        guard completedBytes <= segment.length else {
            throw DownloadPersistenceError.invalidCompletedBytes(
                provided: completedBytes,
                segmentLength: segment.length
            )
        }

        if allowDecrease {
            record.segments[segmentIndex].completedBytes = max(0, completedBytes)
        } else {
            record.segments[segmentIndex].completedBytes = max(record.segments[segmentIndex].completedBytes, max(0, completedBytes))
        }
        record.updatedAt = Date()

        if record.isAllSegmentsCompleted && record.state == .downloading {
            record.state = .completed
        }

        cache[record.id] = record
        try writeRecordToDisk(record)
        return record
    }

    /// Updates the overall state of a download record.
    @discardableResult
    public func updateState(tag: String, state: DownloadState) throws -> DownloadRecord {
        guard var record = try fetch(tag: tag) else {
            throw DownloadPersistenceError.recordNotFound(tag: tag)
        }

        record.transition(to: state)
        cache[record.id] = record
        try writeRecordToDisk(record)
        return record
    }

    /// Updates the network usage policy of a download record.
    @discardableResult
    public func updateNetworkPolicy(tag: String, policy: DownloadNetworkPolicy) throws -> DownloadRecord {
        guard var record = try fetch(tag: tag) else {
            throw DownloadPersistenceError.recordNotFound(tag: tag)
        }
        record.networkPolicy = policy
        record.updatedAt = Date()
        cache[record.id] = record
        try writeRecordToDisk(record)
        return record
    }

    /// Fetches a download record by its unique tag/ID.
    public func fetch(tag: String) throws -> DownloadRecord? {
        if let cached = cache[tag] {
            return cached
        }

        let fileURL = recordFileURL(tag: tag)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let record = try decoder.decode(DownloadRecord.self, from: data)
            cache[record.id] = record
            return record
        } catch {
            throw DownloadPersistenceError.corruptedRecord(
                tag: tag,
                underlyingError: error.localizedDescription
            )
        }
    }

    /// Fetches all persisted download records found in storage.
    public func fetchAll() throws -> [DownloadRecord] {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "json" }

        var results: [DownloadRecord] = []
        for fileURL in fileURLs {
            let tag = fileURL.deletingPathExtension().lastPathComponent
            if let cached = cache[tag] {
                results.append(cached)
                continue
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let record = try decoder.decode(DownloadRecord.self, from: data)
                cache[record.id] = record
                results.append(record)
            } catch {
                // Keep resilient against single corrupt file
                continue
            }
        }

        return results.sorted { $0.createdAt > $1.createdAt }
    }

    /// Deletes a download record from memory and disk.
    public func delete(tag: String) throws {
        cache.removeValue(forKey: tag)
        KeychainManager.shared.deleteCredentials(forDownloadId: tag)
        let fileURL = recordFileURL(tag: tag)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Deletes all persisted download records.
    public func deleteAll() throws {
        cache.removeAll()
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        for fileURL in fileURLs {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Exports a record as raw JSON data.
    public func exportToData(tag: String) throws -> Data {
        guard let record = try fetch(tag: tag) else {
            throw DownloadPersistenceError.recordNotFound(tag: tag)
        }
        return try encoder.encode(record)
    }

    /// Imports and persists a record from raw JSON data.
    public func importFromData(_ data: Data) throws -> DownloadRecord {
        do {
            let record = try decoder.decode(DownloadRecord.self, from: data)
            try save(record)
            return record
        } catch {
            throw DownloadPersistenceError.serializationFailed(underlyingError: error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    private func recordFileURL(tag: String) -> URL {
        storageDirectoryURL.appendingPathComponent("\(tag).json")
    }

    private func writeRecordToDisk(_ record: DownloadRecord) throws {
        let fileURL = recordFileURL(tag: record.id)
        let parentDir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw DownloadPersistenceError.serializationFailed(underlyingError: error.localizedDescription)
        }

        // Atomic write to prevent partial/corrupt files on unexpected crash
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - File Collision & Conflict Resolver (1DM+ Architecture)

/// Manages filename sanitization and non-destructive duplicate resolution (e.g. "video (1).mp4").
public enum FileConflictResolver {
    /// Sanitizes filename by stripping illegal characters (/, \, :, *, ?, ", <, >, |).
    public static func sanitizeFilename(_ name: String) -> String {
        let illegalCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var sanitized = name.components(separatedBy: illegalCharacters).joined(separator: "_")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty {
            sanitized = "download"
        }
        return sanitized
    }

    /// Resolves file collisions: if `directory/filename` already exists on disk,
    /// automatically produces `directory/filename (1).ext`, `directory/filename (2).ext`, etc.
    public static func uniqueDestinationURL(
        desiredFilename: String,
        directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let sanitized = sanitizeFilename(desiredFilename)
        let destination = directory.appendingPathComponent(sanitized, isDirectory: false)
        if !fileManager.fileExists(atPath: destination.path) {
            return destination
        }

        let baseName = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension

        var counter = 1
        while true {
            let numberedName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            let candidateURL = directory.appendingPathComponent(numberedName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            counter += 1
        }
    }
}
