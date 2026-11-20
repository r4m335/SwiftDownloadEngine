import Foundation

/// Thread-safe actor managing persistent torrent task records and fast-resume binary files on disk.
///
/// Features:
/// - Atomic disk writes preventing corrupt states during crashes or sudden app suspension.
/// - Separation of concerns: High-level task metadata lives in `torrent_manifest.json`, while
///   large binary fast-resume data files are stored separately as `<info_hash>.fastresume`.
/// - Explicit schema versioning and recovery from corrupted manifest files.
/// - Dependency injection supporting custom storage locations for deterministic isolated unit testing.
public actor TorrentPersistenceStore {
    public let storageDirectoryURL: URL
    public let resumeDataDirectoryURL: URL
    public let manifestFileURL: URL

    private var cachedManifest: TorrentQueueManifest
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager = FileManager.default

    public init(storageDirectoryURL: URL? = nil) throws {
        let rootURL: URL
        if let customURL = storageDirectoryURL {
            rootURL = customURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let fallback = FileManager.default.temporaryDirectory
            let base = appSupport ?? fallback
            rootURL = base.appendingPathComponent("DownloadsEngine/TorrentMetadata", isDirectory: true)
        }

        self.storageDirectoryURL = rootURL
        self.resumeDataDirectoryURL = rootURL.appendingPathComponent("ResumeData", isDirectory: true)
        self.manifestFileURL = rootURL.appendingPathComponent("torrent_manifest.json", isDirectory: false)

        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = jsonEncoder

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        self.decoder = jsonDecoder

        // Ensure directories exist
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: self.resumeDataDirectoryURL, withIntermediateDirectories: true)

        // Load existing manifest or initialize fresh via static helper (pure Swift 6 isolation)
        self.cachedManifest = try Self.loadOrRecoverManifest(
            manifestFileURL: self.manifestFileURL,
            storageDirectoryURL: rootURL,
            decoder: jsonDecoder,
            encoder: jsonEncoder,
            fileManager: fileManager
        )
    }

    // MARK: - Manifest Operations

    /// Loads the persisted manifest, recovering gracefully from missing or corrupt files.
    public func loadManifest() -> TorrentQueueManifest {
        return cachedManifest
    }

    /// Persists the full manifest atomically to disk.
    public func saveManifest(_ manifest: TorrentQueueManifest) throws {
        guard manifest.schemaVersion <= TorrentQueueManifest.currentSchemaVersion else {
            throw TorrentEngineError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        self.cachedManifest = manifest
        try writeDataAtomically(try encoder.encode(manifest), to: manifestFileURL)
    }

    // MARK: - Record Operations

    /// Saves or updates a single torrent record.
    public func saveRecord(_ record: TorrentRecord) throws {
        guard record.schemaVersion <= TorrentRecord.currentSchemaVersion else {
            throw TorrentEngineError.unsupportedSchemaVersion(record.schemaVersion)
        }
        let key = record.infoHash.lowercased()
        var updated = cachedManifest
        if let idx = updated.records.firstIndex(where: { $0.infoHash.lowercased() == key }) {
            updated.records[idx] = record
        } else {
            updated.records.append(record)
        }
        try writeDataAtomically(try encoder.encode(updated), to: manifestFileURL)
        cachedManifest = updated
    }

    /// Saves or updates multiple torrent records in a single atomic disk write.
    public func saveRecords(_ records: [TorrentRecord]) throws {
        var updated = cachedManifest
        for record in records {
            guard record.schemaVersion <= TorrentRecord.currentSchemaVersion else {
                throw TorrentEngineError.unsupportedSchemaVersion(record.schemaVersion)
            }
            let key = record.infoHash.lowercased()
            if let idx = updated.records.firstIndex(where: { $0.infoHash.lowercased() == key }) {
                updated.records[idx] = record
            } else {
                updated.records.append(record)
            }
        }
        try writeDataAtomically(try encoder.encode(updated), to: manifestFileURL)
        cachedManifest = updated
    }

    /// Returns the persisted record for an info-hash, if present.
    public func loadRecord(infoHash: String) -> TorrentRecord? {
        let key = infoHash.lowercased()
        return cachedManifest.records.first(where: { $0.infoHash.lowercased() == key })
    }

    /// Returns all persisted torrent records.
    public func loadAllRecords() -> [TorrentRecord] {
        return cachedManifest.records
    }

    /// Removes a torrent record and its associated fast-resume file from disk.
    public func deleteRecord(infoHash: String) throws {
        let key = infoHash.lowercased()
        var updated = cachedManifest
        updated.records.removeAll(where: { $0.infoHash.lowercased() == key })
        try writeDataAtomically(try encoder.encode(updated), to: manifestFileURL)
        cachedManifest = updated
        do {
            try deleteResumeData(for: key)
        } catch {
            PipelineLogger.shared.log(stage: .persistence, message: "Failed to delete resume data for \(key): \(error)")
        }
    }

    // MARK: - Fast-Resume Data Operations

    /// Persists raw fast-resume binary bytes atomically to `<infoHash>.fastresume`.
    public func saveResumeData(_ data: Data, for infoHash: String) throws {
        let key = infoHash.lowercased()
        let fileURL = resumeDataURL(for: key)
        try writeDataAtomically(data, to: fileURL)

        // Update record fastResumeFileName reference if record exists
        if var record = loadRecord(infoHash: key) {
            record.fastResumeFileName = fileURL.lastPathComponent
            record.updatedAt = Date()
            try saveRecord(record)
        }
    }

    /// Reads raw fast-resume binary bytes for a given info-hash.
    public func loadResumeData(for infoHash: String) -> Data? {
        let fileURL = resumeDataURL(for: infoHash)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            if let size = fileManager.fileSize(atPath: fileURL.path), size > 20 * 1024 * 1024 {
                PipelineLogger.shared.log(stage: .persistence, message: "[TorrentPersistenceStore] Resume data at \(fileURL.path) exceeds 20MB: \(size)")
                return nil
            }
            return try Data(contentsOf: fileURL, options: .alwaysMapped)
        } catch {
            PipelineLogger.shared.log(stage: .persistence, message: "[TorrentPersistenceStore] Failed to read resume data at \(fileURL.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Deletes the fast-resume file for a given info-hash.
    public func deleteResumeData(for infoHash: String) throws {
        let fileURL = resumeDataURL(for: infoHash)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    // MARK: - Helper Methods

    #if DEBUG
    public var simulatedWriteError: Error?
    public func setSimulatedWriteError(_ error: Error?) {
        self.simulatedWriteError = error
    }
    #endif

    public func resumeDataURL(for infoHash: String) -> URL {
        let key = infoHash.lowercased()
        return resumeDataDirectoryURL.appendingPathComponent("\(key).fastresume", isDirectory: false)
    }

    private func writeDataAtomically(_ data: Data, to destinationURL: URL) throws {
        #if DEBUG
        if let error = simulatedWriteError {
            throw error
        }
        #endif
        try DurableStorage.writeAtomically(data, to: destinationURL, fileManager: fileManager)
    }

    private static func loadOrRecoverManifest(
        manifestFileURL: URL,
        storageDirectoryURL: URL,
        decoder: JSONDecoder,
        encoder: JSONEncoder,
        fileManager: FileManager
    ) throws -> TorrentQueueManifest {
        guard fileManager.fileExists(atPath: manifestFileURL.path) else {
            let initial = TorrentQueueManifest()
            try DurableStorage.writeAtomically(try encoder.encode(initial), to: manifestFileURL, fileManager: fileManager)
            return initial
        }

        do {
            if let size = fileManager.fileSize(atPath: manifestFileURL.path), size > 50 * 1024 * 1024 {
                throw TorrentEngineError.invalidTorrentFile("Manifest file exceeds 50MB: \(size)")
            }
            let data = try Data(contentsOf: manifestFileURL, options: .alwaysMapped)
            let manifest = try decoder.decode(TorrentQueueManifest.self, from: data)
            if manifest.schemaVersion > TorrentQueueManifest.currentSchemaVersion {
                throw TorrentEngineError.unsupportedSchemaVersion(manifest.schemaVersion)
            }
            return manifest
        } catch let engineErr as TorrentEngineError {
            throw engineErr
        } catch {
            DurableStorage.quarantineCorruptFile(at: manifestFileURL, error: error, fileManager: fileManager)
            let fresh = TorrentQueueManifest()
            try DurableStorage.writeAtomically(try encoder.encode(fresh), to: manifestFileURL, fileManager: fileManager)
            return fresh
        }
    }
}
