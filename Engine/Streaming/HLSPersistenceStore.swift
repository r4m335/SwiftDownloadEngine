import Foundation

// MARK: - HLS Persistence Store Errors

/// Errors raised by `HLSPersistenceStore`.
public enum HLSPersistenceError: Error, LocalizedError, Equatable, Sendable {
    case recordNotFound(id: String)
    case directoryCreationFailed(path: String, underlyingError: String)
    case serializationFailed(underlyingError: String)
    case corruptedRecord(id: String, underlyingError: String)

    public var errorDescription: String? {
        switch self {
        case .recordNotFound(let id):
            return "HLS transfer record not found for id: \(id)"
        case .directoryCreationFailed(let path, let underlying):
            return "Failed to create HLS metadata directory at \(path): \(underlying)"
        case .serializationFailed(let underlying):
            return "Failed to encode/decode HLS transfer record: \(underlying)"
        case .corruptedRecord(let id, let underlying):
            return "Corrupted HLS record for id \(id): \(underlying)"
        }
    }
}
// MARK: - HLS Persistence Store

/// Thread-safe actor managing durable `HLSTransferRecord` snapshots on disk.
///
/// Records are written as individual JSON files under:
/// `<storageDirectoryURL>/HLSTransfers/<id>.json`
///
/// Design principles:
/// - Atomic disk writes prevent partial files on crash.
/// - In-memory cache keeps hot reads out of the filesystem.
/// - Credentials are never stored (enforced at the call-site via `BrowserHeaderFilter`).
/// - A missing record is returned as `nil` (not thrown), matching `DownloadPersistenceStore` convention.
public actor HLSPersistenceStore {
    // MARK: - Storage

    /// Root directory for all HLS transfer records.
    public let storageDirectoryURL: URL

    private var cache: [String: HLSTransferRecord] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Initializers

    /// Designated initializer.
    /// - Parameter storageDirectoryURL: Parent directory for the HLS metadata sub-folder.
    ///   Defaults to the same ApplicationSupport location used by `DownloadPersistenceStore`.
    public init(storageDirectoryURL: URL? = nil) throws {
        let baseURL: URL
        if let custom = storageDirectoryURL {
            baseURL = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let fallback = FileManager.default.temporaryDirectory
            baseURL = (appSupport ?? fallback).appendingPathComponent("1DMDownloads/Metadata", isDirectory: true)
        }
        let hlsDir = baseURL.appendingPathComponent("HLSTransfers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: hlsDir, withIntermediateDirectories: true)
        } catch {
            throw HLSPersistenceError.directoryCreationFailed(
                path: hlsDir.path,
                underlyingError: error.localizedDescription
            )
        }
        self.storageDirectoryURL = hlsDir

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// In-memory only store for testing.
    public init(inMemory: Bool) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("1DMHLSTransfers_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        self.storageDirectoryURL = tempURL

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - CRUD Operations

    /// Persists or updates an HLS transfer record atomically.
    public func save(_ record: HLSTransferRecord) throws {
        cache[record.id] = record
        try writeToDisk(record)
    }

    /// Returns the record for `id`, or `nil` if it does not exist.
    public func load(id: String) throws -> HLSTransferRecord? {
        if let cached = cache[id] { return cached }
        let fileURL = recordFileURL(id: id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let record = try decoder.decode(HLSTransferRecord.self, from: data)
            cache[record.id] = record
            return record
        } catch {
            throw HLSPersistenceError.corruptedRecord(
                id: id,
                underlyingError: error.localizedDescription
            )
        }
    }

    /// Returns all persisted HLS transfer records, sorted newest-first.
    public func loadAll() throws -> [HLSTransferRecord] {
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: storageDirectoryURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ).filter { $0.pathExtension == "json" }
        } catch {
            return Array(cache.values).sorted { $0.createdAt > $1.createdAt }
        }

        var results: [HLSTransferRecord] = []
        for fileURL in fileURLs {
            let id = fileURL.deletingPathExtension().lastPathComponent
            if let cached = cache[id] {
                results.append(cached)
                continue
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let record = try decoder.decode(HLSTransferRecord.self, from: data)
                cache[record.id] = record
                results.append(record)
            } catch {
                // Keep resilient against a single corrupted file
                continue
            }
        }
        return results.sorted { $0.createdAt > $1.createdAt }
    }

    /// Removes the record for `id` from memory and disk.
    public func delete(id: String) throws {
        cache.removeValue(forKey: id)
        let fileURL = recordFileURL(id: id)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Targeted Mutation Helpers

    /// Updates only the `state` field, preserving all other fields.
    @discardableResult
    public func updateState(id: String, state: HLSTransferState) throws -> HLSTransferRecord {
        guard var record = try load(id: id) else {
            throw HLSPersistenceError.recordNotFound(id: id)
        }
        record.state = state
        record.updatedAt = Date()
        try save(record)
        return record
    }

    /// Updates only the `assemblyState` field, preserving all other fields.
    @discardableResult
    public func updateAssemblyState(id: String, assemblyState: HLSAssemblyState) throws -> HLSTransferRecord {
        guard var record = try load(id: id) else {
            throw HLSPersistenceError.recordNotFound(id: id)
        }
        record.assemblyState = assemblyState
        record.updatedAt = Date()
        try save(record)
        return record
    }

    /// Marks a single segment `order` as completed, idempotently.
    /// Returns the updated record.
    @discardableResult
    public func markSegmentCompleted(id: String, order: Int) throws -> HLSTransferRecord {
        guard var record = try load(id: id) else {
            throw HLSPersistenceError.recordNotFound(id: id)
        }
        record.completedSegmentOrders.insert(order)
        record.updatedAt = Date()
        try save(record)
        return record
    }

    /// Batch-marks multiple segment orders as completed in a single atomic write.
    @discardableResult
    public func markSegmentsCompleted(id: String, orders: Set<Int>) throws -> HLSTransferRecord {
        guard var record = try load(id: id) else {
            throw HLSPersistenceError.recordNotFound(id: id)
        }
        record.completedSegmentOrders.formUnion(orders)
        record.updatedAt = Date()
        try save(record)
        return record
    }

    /// Removes completed segment orders from the durable checkpoint.
    ///
    /// The caller is responsible for removing the corresponding segment files
    /// before invoking this method. Keeping this mutation in the persistence
    /// actor makes bulk segment deletion use the same atomic record write as
    /// normal completion checkpoints.
    @discardableResult
    public func removeSegments(id: String, orders: Set<Int>) throws -> HLSTransferRecord {
        guard var record = try load(id: id) else {
            throw HLSPersistenceError.recordNotFound(id: id)
        }
        record.completedSegmentOrders.subtract(orders)
        record.updatedAt = Date()
        try save(record)
        return record
    }

    // MARK: - Private Helpers

    private func recordFileURL(id: String) -> URL {
        // HLS IDs are normally already safe (the orchestrator uses a stable
        // digest), but keep the store robust for callers and older records
        // that may contain URL characters such as `/` or `:`.
        let safeID = id.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar)
        }
        let filename = safeID ? id : "hls-\(EngineSHA256.hash(data: Data(id.utf8)).prefix(32))"
        return storageDirectoryURL.appendingPathComponent("\(filename).json")
    }

    private func writeToDisk(_ record: HLSTransferRecord) throws {
        let fileURL = recordFileURL(id: record.id)
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw HLSPersistenceError.serializationFailed(underlyingError: error.localizedDescription)
        }
        // Atomic write prevents partial/corrupt files on crash or power-cut
        try data.write(to: fileURL, options: .atomic)
    }
}
