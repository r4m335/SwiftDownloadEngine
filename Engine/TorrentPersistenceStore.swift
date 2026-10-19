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
            rootURL = base.appendingPathComponent("1DMDownloads/TorrentMetadata", isDirectory: true)
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
        var updatedRecords = cachedManifest.records
        if let idx = updatedRecords.firstIndex(where: { $0.infoHash.lowercased() == key }) {
            updatedRecords[idx] = record
        } else {
            updatedRecords.append(record)
        }
        cachedManifest.records = updatedRecords
        try writeDataAtomically(try encoder.encode(cachedManifest), to: manifestFileURL)
    }

    /// Saves or updates multiple torrent records in a single atomic disk write.
    public func saveRecords(_ records: [TorrentRecord]) throws {
        for record in records {
            guard record.schemaVersion <= TorrentRecord.currentSchemaVersion else {
                throw TorrentEngineError.unsupportedSchemaVersion(record.schemaVersion)
            }
            let key = record.infoHash.lowercased()
            if let idx = cachedManifest.records.firstIndex(where: { $0.infoHash.lowercased() == key }) {
                cachedManifest.records[idx] = record
            } else {
                cachedManifest.records.append(record)
            }
        }
        try writeDataAtomically(try encoder.encode(cachedManifest), to: manifestFileURL)
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
        cachedManifest.records.removeAll(where: { $0.infoHash.lowercased() == key })
        try writeDataAtomically(try encoder.encode(cachedManifest), to: manifestFileURL)
        try? deleteResumeData(for: key)
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
        return try? Data(contentsOf: fileURL)
    }

    /// Deletes the fast-resume file for a given info-hash.
    public func deleteResumeData(for infoHash: String) throws {
        let fileURL = resumeDataURL(for: infoHash)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    // MARK: - Helper Methods

    public func resumeDataURL(for infoHash: String) -> URL {
        let key = infoHash.lowercased()
        return resumeDataDirectoryURL.appendingPathComponent("\(key).fastresume", isDirectory: false)
    }

    private func writeDataAtomically(_ data: Data, to destinationURL: URL) throws {
        try Self.writeDataAtomically(data, to: destinationURL, fileManager: fileManager)
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
            try? writeDataAtomically(try encoder.encode(initial), to: manifestFileURL, fileManager: fileManager)
            return initial
        }

        do {
            let data = try Data(contentsOf: manifestFileURL)
            let manifest = try decoder.decode(TorrentQueueManifest.self, from: data)
            if manifest.schemaVersion > TorrentQueueManifest.currentSchemaVersion {
                throw TorrentEngineError.unsupportedSchemaVersion(manifest.schemaVersion)
            }
            return manifest
        } catch let engineErr as TorrentEngineError {
            throw engineErr
        } catch {
            let timestamp = Int(Date().timeIntervalSince1970)
            let corruptBackupURL = storageDirectoryURL.appendingPathComponent("torrent_manifest.corrupt.\(timestamp).json")
            try? fileManager.moveItem(at: manifestFileURL, to: corruptBackupURL)

            let fresh = TorrentQueueManifest()
            try? writeDataAtomically(try encoder.encode(fresh), to: manifestFileURL, fileManager: fileManager)
            return fresh
        }
    }

    private static func writeDataAtomically(_ data: Data, to destinationURL: URL, fileManager: FileManager) throws {
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp.\(UUID().uuidString)", isDirectory: false)
        try data.write(to: tempURL, options: .atomic)
        _ = try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: tempURL, to: destinationURL)
    }
}
