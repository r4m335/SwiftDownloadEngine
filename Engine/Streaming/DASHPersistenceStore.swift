import Foundation

// MARK: - DASH Persistence Store Errors

/// Errors raised by `DASHPersistenceStore`.
public enum DASHPersistenceError: Error, LocalizedError, Equatable, Sendable {
    case recordNotFound(id: String)
    case directoryCreationFailed(path: String, underlyingError: String)
    case serializationFailed(underlyingError: String)
    case corruptedRecord(id: String, underlyingError: String)

    public var errorDescription: String? {
        switch self {
        case .recordNotFound(let id):
            return "DASH transfer record not found for id: \(id)"
        case .directoryCreationFailed(let path, let underlying):
            return "Failed to create DASH metadata directory at \(path): \(underlying)"
        case .serializationFailed(let underlying):
            return "Failed to encode/decode DASH transfer record: \(underlying)"
        case .corruptedRecord(let id, let underlying):
            return "Corrupted DASH record for id \(id): \(underlying)"
        }
    }
}

// MARK: - DASH Persistence Store

/// Thread-safe actor managing durable `DASHTransferRecord` snapshots on disk.
///
/// Records are written as individual JSON files under:
/// `<storageDirectoryURL>/DASHTransfers/<id>.json`
public actor DASHPersistenceStore {
    // MARK: - Storage

    /// Root directory for all DASH transfer records.
    public let storageDirectoryURL: URL

    private var cache: [String: DASHTransferRecord] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Initializers

    /// Designated initializer.
    /// - Parameter storageDirectoryURL: Parent directory for the DASH metadata sub-folder.
    public init(storageDirectoryURL: URL? = nil) throws {
        let baseURL: URL
        if let custom = storageDirectoryURL {
            baseURL = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let fallback = FileManager.default.temporaryDirectory
            baseURL = (appSupport ?? fallback).appendingPathComponent("DownloadsEngine/Metadata", isDirectory: true)
        }
        let dashDir = baseURL.appendingPathComponent("DASHTransfers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dashDir, withIntermediateDirectories: true)
        } catch {
            throw DASHPersistenceError.directoryCreationFailed(
                path: dashDir.path,
                underlyingError: error.localizedDescription
            )
        }
        self.storageDirectoryURL = dashDir

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
            .appendingPathComponent("DASHTransfers_\(UUID().uuidString)", isDirectory: true)
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

    /// Persists or updates a DASH transfer record atomically.
    public func save(_ record: DASHTransferRecord) throws {
        try writeToDisk(record)
        cache[record.id] = record
    }

    /// Returns the record for `id`, or `nil` if it does not exist.
    public func load(id: String) throws -> DASHTransferRecord? {
        if let cached = cache[id] { return cached }
        let fileURL = recordFileURL(id: id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            if let record = try DurableStorage.load(from: fileURL, decoder: decoder) as DASHTransferRecord? {
                cache[record.id] = record
                return record
            }
            return nil
        } catch {
            throw DASHPersistenceError.corruptedRecord(
                id: id,
                underlyingError: error.localizedDescription
            )
        }
    }

    /// Returns all persisted DASH transfer records, sorted newest-first.
    public func loadAll() throws -> [DASHTransferRecord] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: storageDirectoryURL.path, isDirectory: &isDir) else {
            return []
        }
        guard isDir.boolValue else {
            let error = CocoaError(.fileReadCorruptFile)
            PipelineLogger.shared.log("[DASHPersistenceStore] Critical: Storage directory path is not a directory: \(storageDirectoryURL.path)")
            throw error
        }

        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: storageDirectoryURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ).filter { $0.pathExtension == "json" }
        } catch {
            let nsErr = error as NSError
            PipelineLogger.shared.log("[DASHPersistenceStore] Critical: Failed to enumerate transfer records directory at \(storageDirectoryURL.path): \(nsErr.localizedDescription) (Domain: \(nsErr.domain), Code: \(nsErr.code))")
            throw error
        }

        var records: [DASHTransferRecord] = []
        for fileURL in fileURLs {
            do {
                if let record = try DurableStorage.load(from: fileURL, decoder: decoder) as DASHTransferRecord? {
                    cache[record.id] = record
                    records.append(record)
                }
            } catch {
                let fallbackID = fileURL.deletingPathExtension().lastPathComponent
                PipelineLogger.shared.log(
                    stage: .persistence,
                    message: "[DASHPersistenceStore] Quarantined corrupted record at \(fileURL.path): \(error.localizedDescription)"
                )
                try? quarantineCorruptedFile(fileURL)
                _ = fallbackID
            }
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    /// Deletes the record for `id` from disk and cache.
    public func delete(id: String) throws {
        cache.removeValue(forKey: id)
        let fileURL = recordFileURL(id: id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Deletes all persisted DASH transfer records.
    public func deleteAll() throws {
        cache.removeAll()
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "json" }

        for fileURL in fileURLs {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Atomic Mutators

    /// Adds newly completed segment orders to the record.
    @discardableResult
    public func updateCompletedSegmentOrders(
        id: String,
        completedOrders: [Int]
    ) throws -> DASHTransferRecord {
        guard var record = try load(id: id) else {
            throw DASHPersistenceError.recordNotFound(id: id)
        }
        record.completedSegmentOrders.formUnion(completedOrders)
        record.updatedAt = Date()
        try save(record)
        return record
    }

    /// Updates the high-level transfer lifecycle state.
    @discardableResult
    public func updateState(
        id: String,
        state: HLSTransferState
    ) throws -> DASHTransferRecord {
        guard var record = try load(id: id) else {
            throw DASHPersistenceError.recordNotFound(id: id)
        }
        record.state = state
        record.updatedAt = Date()
        try save(record)
        return record
    }

    /// Updates the assembly state.
    @discardableResult
    public func updateAssemblyState(
        id: String,
        assemblyState: HLSAssemblyState
    ) throws -> DASHTransferRecord {
        guard var record = try load(id: id) else {
            throw DASHPersistenceError.recordNotFound(id: id)
        }
        record.assemblyState = assemblyState
        record.updatedAt = Date()
        try save(record)
        return record
    }

    // MARK: - Private Helpers

    public func recordFileURL(id: String) -> URL {
        let safeName = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return storageDirectoryURL.appendingPathComponent("\(safeName).json", isDirectory: false)
    }

    private func writeToDisk(_ record: DASHTransferRecord) throws {
        let destination = recordFileURL(id: record.id)
        try DurableStorage.writeAtomically(record, to: destination, encoder: encoder)
    }

    private func quarantineCorruptedFile(_ fileURL: URL) throws {
        let quarantineDir = storageDirectoryURL.appendingPathComponent("Corrupted", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        let destination = quarantineDir.appendingPathComponent(
            "\(fileURL.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))"
        )
        try FileManager.default.moveItem(at: fileURL, to: destination)
    }
}
