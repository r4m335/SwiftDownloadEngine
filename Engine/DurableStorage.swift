import Foundation

/// Defines a versioned persistence contract for durable schema evolution and migrations.
public protocol SchemaVersioned: Codable {
    /// The current schema version supported by this build of the application.
    static var currentSchemaVersion: Int { get }

    /// The schema version of this instance stored in persistent JSON data.
    var schemaVersion: Int { get }
}

/// Errors raised during persistent state operations.
public enum PersistenceStorageError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedFutureVersion(found: Int, supported: Int)
    case corruptedData(url: URL, underlyingError: String)
    case writeFailed(url: URL, underlyingError: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFutureVersion(found, supported):
            return "Unsupported schema version \(found). Maximum supported version is \(supported)."
        case let .corruptedData(url, underlyingError):
            return "Corrupted persistent storage at \(url.path): \(underlyingError)"
        case let .writeFailed(url, underlyingError):
            return "Failed to write persistent storage to \(url.path): \(underlyingError)"
        }
    }
}

/// Unified, crash-resilient storage primitives with schema migration and corruption quarantine.
public enum DurableStorage {
    /// Atomically writes data to the destination URL, guaranteeing integrity against crashes or app suspension.
    public static func writeAtomically(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let tempURL = parentDir.appendingPathComponent(".tmp.\(UUID().uuidString)", isDirectory: false)
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            throw PersistenceStorageError.writeFailed(url: destinationURL, underlyingError: error.localizedDescription)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            #if canImport(Darwin)
            do {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: .withoutDeletingBackupItem
                )
            } catch {
                let backupURL = parentDir.appendingPathComponent(".backup-\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
                do {
                    try fileManager.moveItem(at: destinationURL, to: backupURL)
                } catch {
                    try? fileManager.removeItem(at: tempURL)
                    throw PersistenceStorageError.writeFailed(url: destinationURL, underlyingError: "Failed to create backup: \(error.localizedDescription)")
                }
                do {
                    try fileManager.moveItem(at: tempURL, to: destinationURL)
                    try? fileManager.removeItem(at: backupURL)
                } catch {
                    try? fileManager.moveItem(at: backupURL, to: destinationURL)
                    try? fileManager.removeItem(at: tempURL)
                    throw PersistenceStorageError.writeFailed(url: destinationURL, underlyingError: error.localizedDescription)
                }
            }
            #else
            let backupURL = parentDir.appendingPathComponent(".backup-\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
            do {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
            } catch {
                try? fileManager.removeItem(at: tempURL)
                throw PersistenceStorageError.writeFailed(url: destinationURL, underlyingError: "Failed to create backup: \(error.localizedDescription)")
            }
            do {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
                try? fileManager.removeItem(at: backupURL)
            } catch {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
                try? fileManager.removeItem(at: tempURL)
                throw PersistenceStorageError.writeFailed(url: destinationURL, underlyingError: error.localizedDescription)
            }
            #endif
        } else {
            do {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            } catch {
                try? fileManager.removeItem(at: tempURL)
                throw PersistenceStorageError.writeFailed(url: destinationURL, underlyingError: error.localizedDescription)
            }
        }
    }

    /// Quarantines a corrupted persistence file by moving it to `<name>.corrupt.<timestamp>.<ext>`.
    @discardableResult
    public static func quarantineCorruptFile(
        at url: URL,
        error: Error? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let dir = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        let timestamp = Int(Date().timeIntervalSince1970)
        let corruptURL = dir.appendingPathComponent("\(baseName).corrupt.\(timestamp).\(ext)")
        do {
            try fileManager.moveItem(at: url, to: corruptURL)
            PipelineLogger.shared.log(
                stage: .persistence,
                message: "[DurableStorage] Quarantined corrupted storage file \(url.path) to \(corruptURL.path). Error: \(error?.localizedDescription ?? "unknown")"
            )
            return corruptURL
        } catch {
            PipelineLogger.shared.log(
                stage: .persistence,
                message: "[DurableStorage] Failed to quarantine corrupt file \(url.path): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Loads and decodes a model from disk, performing schema validation and optional migration.
    /// If data is corrupted, the file is quarantined and an error is logged.
    public static func load<T: Codable>(
        from url: URL,
        decoder: JSONDecoder = JSONDecoder(),
        fileManager: FileManager = .default,
        legacyFallback: ((Data) throws -> T)? = nil
    ) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            if let fileSize = fileManager.fileSize(atPath: url.path), fileSize > 100 * 1024 * 1024 {
                throw PersistenceStorageError.corruptedData(
                    url: url,
                    underlyingError: "Persistence file exceeds maximum supported size (100MB): \(fileSize) bytes"
                )
            }
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            PipelineLogger.shared.log(
                stage: .persistence,
                message: "[DurableStorage] Failed to read file at \(url.path): \(error.localizedDescription)"
            )
            throw PersistenceStorageError.corruptedData(url: url, underlyingError: error.localizedDescription)
        }

        // Try primary decoding
        do {
            let decoded = try decoder.decode(T.self, from: data)
            if let versioned = decoded as? (any SchemaVersioned) {
                let dynamicType = type(of: versioned)
                if versioned.schemaVersion > dynamicType.currentSchemaVersion {
                    throw PersistenceStorageError.unsupportedFutureVersion(
                        found: versioned.schemaVersion,
                        supported: dynamicType.currentSchemaVersion
                    )
                }
            }
            return decoded
        } catch let futureErr as PersistenceStorageError {
            PipelineLogger.shared.log(
                stage: .persistence,
                message: "[DurableStorage] Future schema version detected at \(url.path): \(futureErr.localizedDescription)"
            )
            throw futureErr
        } catch let primaryError {
            // Attempt legacy fallback if provided
            if let legacyFallback {
                do {
                    let migrated = try legacyFallback(data)
                    PipelineLogger.shared.log(
                        stage: .persistence,
                        message: "[DurableStorage] Successfully migrated legacy data format at \(url.path) to \(T.self)"
                    )
                    return migrated
                } catch {
                    PipelineLogger.shared.log(
                        stage: .persistence,
                        message: "[DurableStorage] Legacy fallback decoding failed for \(url.path): \(error.localizedDescription)"
                    )
                }
            }

            // Both primary and legacy fallback failed: quarantine corrupt file
            let quarantinedAt = quarantineCorruptFile(at: url, error: primaryError, fileManager: fileManager)
            let desc = "Quarantined at \(quarantinedAt?.path ?? "unknown"): \(primaryError.localizedDescription)"
            throw PersistenceStorageError.corruptedData(url: url, underlyingError: desc)
        }
    }
}
