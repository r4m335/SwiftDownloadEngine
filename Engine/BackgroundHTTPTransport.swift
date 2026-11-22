import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Background Transport Errors

/// Errors raised by the background HTTP transport layer.
public enum BackgroundTransportError: Error, LocalizedError, Equatable, Sendable {
    case invalidHTTPResponse
    case unexpectedStatus(expected: Int, actual: Int)
    case invalidContentRange
    case contentRangeMismatch(expectedStart: Int64, expectedEnd: Int64, actualStart: Int64, actualEnd: Int64)
    case totalSizeMismatch(expected: Int64, actual: Int64)
    case contentRangeWildcardTotalRejected(rangeHeader: String)
    case bodyLengthMismatch(expected: Int64, actual: Int64)
    case htmlErrorPageReceived(contentType: String)
    case taskNotFound(sessionIdentifier: String, taskIdentifier: Int)
    case temporaryFileMissing(path: String)
    case fileRelocationFailed(underlyingError: String)
    case corruptedMappingStore(path: String, underlyingError: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "Server returned a non-HTTP response"
        case .unexpectedStatus(let expected, let actual):
            return "Unexpected HTTP status: expected \(expected), received \(actual)"
        case .invalidContentRange:
            return "Missing or malformed Content-Range response header"
        case .contentRangeMismatch(let expS, let expE, let actS, let actE):
            return "Content-Range boundary mismatch: requested \(expS)-\(expE), received \(actS)-\(actE)"
        case .totalSizeMismatch(let expected, let actual):
            return "Content-Range total size (\(actual)) does not match expected size (\(expected))"
        case .contentRangeWildcardTotalRejected(let header):
            return "Server returned wildcard total (*) in Content-Range header when exact size is known: \(header)"
        case .bodyLengthMismatch(let expected, let actual):
            return "Downloaded part file size (\(actual) bytes) does not match expected segment length (\(expected) bytes)"
        case .htmlErrorPageReceived(let contentType):
            return "Server returned HTML error/login page instead of binary content (\(contentType))"
        case .taskNotFound(let sess, let id):
            return "No persistent mapping found for background task [\(sess):\(id)]"
        case .temporaryFileMissing(let path):
            return "Temporary file provided by URLSession does not exist: \(path)"
        case .fileRelocationFailed(let error):
            return "Failed to safely relocate temporary download file: \(error)"
        case .corruptedMappingStore(let path, let underlying):
            return "Corrupted background task mapping store at \(path): \(underlying)"
        case .cancelled:
            return "Background task was cancelled"
        }
    }
}

// MARK: - Persistent Task Record

/// Durable mapping linking an iOS background `URLSessionDownloadTask` to its parent
/// `DownloadRecord` and `SegmentRecord`.
public struct BackgroundDownloadTaskRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(sessionIdentifier):\(taskIdentifier)" }
    public let sessionIdentifier: String
    public let taskIdentifier: Int
    public let downloadID: String
    public let segmentID: Int
    public let originalURL: URL
    public let startOffset: Int64
    public let endOffset: Int64
    public let expectedBytes: Int64
    public let initialSegmentCompletedBytes: Int64
    public let segmentLength: Int64
    public let destinationPartURL: URL
    public let createdAt: Date
    public var updatedAt: Date
    public var completedBytes: Int64
    public var isCompleted: Bool
    public var errorDescription: String?
    public var retryCount: Int

    public init(
        sessionIdentifier: String,
        taskIdentifier: Int,
        downloadID: String,
        segmentID: Int,
        originalURL: URL,
        startOffset: Int64,
        endOffset: Int64,
        expectedBytes: Int64,
        initialSegmentCompletedBytes: Int64 = 0,
        segmentLength: Int64,
        destinationPartURL: URL,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedBytes: Int64 = 0,
        isCompleted: Bool = false,
        errorDescription: String? = nil,
        retryCount: Int = 0
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
        self.downloadID = downloadID
        self.segmentID = segmentID
        self.originalURL = originalURL
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.expectedBytes = expectedBytes
        self.initialSegmentCompletedBytes = initialSegmentCompletedBytes
        self.segmentLength = segmentLength
        self.destinationPartURL = destinationPartURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedBytes = completedBytes
        self.isCompleted = isCompleted
        self.errorDescription = errorDescription
        self.retryCount = retryCount
    }

    enum CodingKeys: String, CodingKey {
        case sessionIdentifier, taskIdentifier, downloadID, segmentID, originalURL
        case startOffset, endOffset, expectedBytes, initialSegmentCompletedBytes
        case segmentLength, destinationPartURL, createdAt, updatedAt, completedBytes
        case isCompleted, errorDescription, retryCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionIdentifier = try container.decode(String.self, forKey: .sessionIdentifier)
        self.taskIdentifier = try container.decode(Int.self, forKey: .taskIdentifier)
        self.downloadID = try container.decode(String.self, forKey: .downloadID)
        self.segmentID = try container.decode(Int.self, forKey: .segmentID)
        self.originalURL = try container.decode(URL.self, forKey: .originalURL)
        self.startOffset = try container.decode(Int64.self, forKey: .startOffset)
        self.endOffset = try container.decode(Int64.self, forKey: .endOffset)
        self.expectedBytes = try container.decode(Int64.self, forKey: .expectedBytes)
        self.initialSegmentCompletedBytes = try container.decodeIfPresent(Int64.self, forKey: .initialSegmentCompletedBytes) ?? 0
        self.segmentLength = try container.decode(Int64.self, forKey: .segmentLength)
        self.destinationPartURL = try container.decode(URL.self, forKey: .destinationPartURL)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.completedBytes = try container.decode(Int64.self, forKey: .completedBytes)
        self.isCompleted = try container.decode(Bool.self, forKey: .isCompleted)
        self.errorDescription = try container.decodeIfPresent(String.self, forKey: .errorDescription)
        self.retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionIdentifier, forKey: .sessionIdentifier)
        try container.encode(taskIdentifier, forKey: .taskIdentifier)
        try container.encode(downloadID, forKey: .downloadID)
        try container.encode(segmentID, forKey: .segmentID)
        try container.encode(originalURL, forKey: .originalURL)
        try container.encode(startOffset, forKey: .startOffset)
        try container.encode(endOffset, forKey: .endOffset)
        try container.encode(expectedBytes, forKey: .expectedBytes)
        try container.encode(initialSegmentCompletedBytes, forKey: .initialSegmentCompletedBytes)
        try container.encode(segmentLength, forKey: .segmentLength)
        try container.encode(destinationPartURL, forKey: .destinationPartURL)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(completedBytes, forKey: .completedBytes)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encodeIfPresent(errorDescription, forKey: .errorDescription)
        try container.encode(retryCount, forKey: .retryCount)
    }

    /// Task description string embedded directly into the URLSessionTask for system-level persistence.
    public var systemTaskDescription: String {
        "SDE_BG:\(sessionIdentifier):\(downloadID):\(segmentID)"
    }

    /// Parses embedded task description if present.
    public static func parseSystemTaskDescription(_ desc: String) -> (sessionIdentifier: String, downloadID: String, segmentID: Int)? {
        let parts = desc.split(separator: ":")
        guard parts.count == 4, (parts[0] == "SDE_BG" || parts[0].hasSuffix("_BG")), let segID = Int(parts[3]) else {
            return nil
        }
        return (String(parts[1]), String(parts[2]), segID)
    }
}

// MARK: - Persistent Task Mapping Store

/// Thread-safe actor persisting and managing active background task mappings on disk.
/// Guarantees atomic writes and scopes tasks by composite `(sessionIdentifier, taskIdentifier)` identity.
public actor BackgroundDownloadTaskMappingStore {
    public let storeFileURL: URL
    public let storageDirectoryURL: URL

    private var cache: [String: BackgroundDownloadTaskRecord] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(storageDirectoryURL: URL) throws {
        self.storageDirectoryURL = storageDirectoryURL
        try FileManager.default.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        self.storeFileURL = storageDirectoryURL.appendingPathComponent("background_tasks_v1.json")

        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = jsonEncoder

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        self.decoder = jsonDecoder

        var initialCache: [String: BackgroundDownloadTaskRecord] = [:]
        if FileManager.default.fileExists(atPath: self.storeFileURL.path) {
            do {
                if let size = FileManager.default.fileSize(atPath: self.storeFileURL.path), size > 50 * 1024 * 1024 {
                    throw BackgroundTransportError.corruptedMappingStore(
                        path: self.storeFileURL.path,
                        underlyingError: "Store file exceeds maximum allowed size (50MB): \(size) bytes"
                    )
                }
                let data = try Data(contentsOf: self.storeFileURL, options: .alwaysMapped)
                let records = try jsonDecoder.decode([BackgroundDownloadTaskRecord].self, from: data)
                for r in records {
                    initialCache[r.id] = r
                }
            } catch {
                // Quarantine corrupted manifest instead of silently wiping it out
                let timestamp = Int(Date().timeIntervalSince1970)
                let quarantineURL = storageDirectoryURL.appendingPathComponent("background_tasks_v1.json.corrupt-\(timestamp)")
                do {
                    try FileManager.default.moveItem(at: self.storeFileURL, to: quarantineURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to quarantine corrupted mapping store: \(error)")
                }
                throw BackgroundTransportError.corruptedMappingStore(
                    path: quarantineURL.path,
                    underlyingError: error.localizedDescription
                )
            }
        }
        self.cache = initialCache
    }

    public func save(record: BackgroundDownloadTaskRecord) throws {
        var updated = record
        updated.updatedAt = Date()
        cache[record.id] = updated
        try persistToDisk()
    }

    public func record(sessionIdentifier: String, taskIdentifier: Int) -> BackgroundDownloadTaskRecord? {
        let key = "\(sessionIdentifier):\(taskIdentifier)"
        return cache[key]
    }

    public func records(forDownloadID downloadID: String) -> [BackgroundDownloadTaskRecord] {
        cache.values.filter { $0.downloadID == downloadID }
    }

    public func records(forSessionIdentifier sessionIdentifier: String) -> [BackgroundDownloadTaskRecord] {
        cache.values.filter { $0.sessionIdentifier == sessionIdentifier }
    }

    public func record(forDownloadID downloadID: String, segmentID: Int) -> BackgroundDownloadTaskRecord? {
        cache.values.first { $0.downloadID == downloadID && $0.segmentID == segmentID }
    }

    public func allRecords() -> [BackgroundDownloadTaskRecord] {
        Array(cache.values)
    }

    public func updateProgress(sessionIdentifier: String, taskIdentifier: Int, taskBytesWritten: Int64) throws {
        let key = "\(sessionIdentifier):\(taskIdentifier)"
        guard var rec = cache[key] else { return }
        rec.completedBytes = min(rec.expectedBytes, max(0, taskBytesWritten))
        rec.updatedAt = Date()
        cache[key] = rec
        try persistToDisk()
    }

    public func markCompleted(sessionIdentifier: String, taskIdentifier: Int, finalBytes: Int64) throws {
        let key = "\(sessionIdentifier):\(taskIdentifier)"
        guard var rec = cache[key] else { return }
        rec.completedBytes = finalBytes
        rec.isCompleted = true
        rec.errorDescription = nil
        rec.updatedAt = Date()
        cache[key] = rec
        try persistToDisk()
    }

    public func markFailed(sessionIdentifier: String, taskIdentifier: Int, error: String) throws {
        let key = "\(sessionIdentifier):\(taskIdentifier)"
        guard var rec = cache[key] else { return }
        rec.errorDescription = error
        rec.updatedAt = Date()
        cache[key] = rec
        try persistToDisk()
    }

    public func remove(sessionIdentifier: String, taskIdentifier: Int) throws {
        let key = "\(sessionIdentifier):\(taskIdentifier)"
        cache.removeValue(forKey: key)
        try persistToDisk()
    }

    public func removeRecords(forDownloadID downloadID: String) throws {
        let keysToRemove = cache.filter { $0.value.downloadID == downloadID }.map { $0.key }
        for k in keysToRemove {
            cache.removeValue(forKey: k)
        }
        try persistToDisk()
    }

    private func persistToDisk() throws {
        let records = Array(cache.values)
        let data = try encoder.encode(records)
        let tempURL = storeFileURL.deletingLastPathComponent()
            .appendingPathComponent("background_tasks_\(UUID().uuidString).tmp")

        try data.write(to: tempURL, options: .atomic)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: storeFileURL.path) {
            #if canImport(Darwin)
            do {
                _ = try fileManager.replaceItemAt(storeFileURL, withItemAt: tempURL, backupItemName: nil, options: .withoutDeletingBackupItem)
            } catch {
                let backupURL = storeFileURL.deletingLastPathComponent()
                    .appendingPathComponent(".backup-\(UUID().uuidString)-\(storeFileURL.lastPathComponent)")
                try fileManager.moveItem(at: storeFileURL, to: backupURL)
                do {
                    try fileManager.moveItem(at: tempURL, to: storeFileURL)
                    do {
                        try fileManager.removeItem(at: backupURL)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to remove mapping store backup at \(backupURL.path): \(error)")
                    }
                } catch {
                    do {
                        try fileManager.moveItem(at: backupURL, to: storeFileURL)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to restore mapping store backup from \(backupURL.path): \(error)")
                    }
                    throw error
                }
            }
            #else
            let backupURL = storeFileURL.deletingLastPathComponent()
                .appendingPathComponent(".backup-\(UUID().uuidString)-\(storeFileURL.lastPathComponent)")
            try fileManager.moveItem(at: storeFileURL, to: backupURL)
            do {
                try fileManager.moveItem(at: tempURL, to: storeFileURL)
                do {
                    try fileManager.removeItem(at: backupURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to remove mapping store backup at \(backupURL.path): \(error)")
                }
            } catch {
                do {
                    try fileManager.moveItem(at: backupURL, to: storeFileURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to restore mapping store backup from \(backupURL.path): \(error)")
                }
                throw error
            }
            #endif
        } else {
            try fileManager.moveItem(at: tempURL, to: storeFileURL)
        }
    }
}

// MARK: - Background HTTP Response Validator

/// Validates HTTP status codes, byte-range boundaries, and mime-types from background download tasks.
public enum BackgroundResponseValidator {

    public static func validate(
        response: URLResponse?,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotalSize: Int64? = nil
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackgroundTransportError.invalidHTTPResponse
        }

        // 1. Status Code Validation
        // Range requests MUST return 206 Partial Content.
        // A 200 OK means the remote server ignored the byte range and sent the entire file from byte 0.
        if httpResponse.statusCode != 206 {
            throw BackgroundTransportError.unexpectedStatus(expected: 206, actual: httpResponse.statusCode)
        }

        // 2. HTML Error / Login Page Detection
        let contentType = httpResponse.value(forCaseInsensitiveField: "Content-Type")
        if HTTPTransportValidator.isHTMLResponse(contentType: contentType) {
            throw BackgroundTransportError.htmlErrorPageReceived(contentType: contentType ?? "text/html")
        }

        // 3. Content-Range Header Validation
        guard let contentRange = httpResponse.value(forCaseInsensitiveField: "Content-Range") else {
            throw BackgroundTransportError.invalidContentRange
        }

        do {
            try HTTPTransportValidator.validateContentRange(
                contentRange,
                expectedStart: expectedStart,
                expectedEnd: expectedEnd,
                expectedTotalSize: expectedTotalSize,
                allowWildcardTotal: false
            )
        } catch let error as HTTPTransportValidator.Error {
            switch error {
            case .invalidContentRange:
                throw BackgroundTransportError.invalidContentRange
            case .contentRangeMismatch(let expS, let expE, let actS, let actE):
                throw BackgroundTransportError.contentRangeMismatch(
                    expectedStart: expS,
                    expectedEnd: expE,
                    actualStart: actS,
                    actualEnd: actE
                )
            case .wildcardTotalRejected(let header):
                throw BackgroundTransportError.contentRangeWildcardTotalRejected(rangeHeader: header)
            case .totalSizeMismatch(let exp, let act):
                throw BackgroundTransportError.totalSizeMismatch(expected: exp, actual: act)
            default:
                throw BackgroundTransportError.invalidContentRange
            }
        }
    }

    public static func parseContentRange(_ header: String) throws -> (start: Int64, end: Int64, total: Int64?) {
        do {
            return try HTTPTransportValidator.parseContentRange(header)
        } catch {
            throw BackgroundTransportError.invalidContentRange
        }
    }
}


// MARK: - Crash-Safe File Handler

/// Relocates temporary files delivered by `URLSessionDownloadDelegate` safely and atomically.
public enum BackgroundDownloadFileHandler {

    /// Moves a downloaded temporary file into its durable part-file destination using a staging-and-replace
    /// procedure that preserves any existing destination file until the replacement is verified.
    @discardableResult
    public static func relocateTemporaryFile(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedBytes: Int64? = nil
    ) throws -> Int64 {
        try relocateOrAppendTemporaryFile(
            from: sourceURL,
            to: destinationURL,
            expectedNewBytes: expectedBytes,
            expectedFinalTotalBytes: expectedBytes,
            append: false
        )
    }

    /// Relocates or appends downloaded temporary bytes into destination part file safely and atomically.
    /// If `append == true` and destination file exists, appends the newly downloaded bytes to destination (via safe staging)
    /// and verifies that the final merged file equals `expectedFinalTotalBytes`.
    @discardableResult
    public static func relocateOrAppendTemporaryFile(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedNewBytes: Int64? = nil,
        expectedFinalTotalBytes: Int64? = nil,
        append: Bool = false
    ) throws -> Int64 {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw BackgroundTransportError.temporaryFileMissing(path: sourceURL.path)
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            throw BackgroundTransportError.fileRelocationFailed(underlyingError: "Failed to create destination directory: \(error.localizedDescription)")
        }

        // Stage into a temporary file alongside destination
        let stagingURL = parentDir
            .appendingPathComponent("staging-\(UUID().uuidString).tmp")

        if let expectedNew = expectedNewBytes {
            let sourceAttrs = try fileManager.attributesOfItem(atPath: sourceURL.path)
            guard let sourceSize = sourceAttrs[.size] as? Int64 else {
                throw BackgroundTransportError.fileRelocationFailed(underlyingError: "Cannot determine source file size")
            }
            if sourceSize != expectedNew {
                do {
                    try fileManager.removeItem(at: sourceURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to remove mismatched sourceURL \(sourceURL.path): \(error)")
                }
                throw BackgroundTransportError.bodyLengthMismatch(expected: expectedNew, actual: sourceSize)
            }
        }

        if append && fileManager.fileExists(atPath: destinationURL.path) {
            if let expectedFinal = expectedFinalTotalBytes, let expectedNew = expectedNewBytes {
                let expectedPrefix = expectedFinal - expectedNew
                if expectedPrefix >= 0 {
                    let destAttrs = try fileManager.attributesOfItem(atPath: destinationURL.path)
                    let destSize = (destAttrs[.size] as? Int64) ?? 0
                    if destSize != expectedPrefix {
                        throw BackgroundTransportError.bodyLengthMismatch(expected: expectedPrefix, actual: destSize)
                    }
                }
            }

            // Copy existing partial destination to staging, then append new bytes from sourceURL
            do {
                try fileManager.copyItem(at: destinationURL, to: stagingURL)
            } catch {
                throw BackgroundTransportError.fileRelocationFailed(underlyingError: "Failed to copy partial destination to staging: \(error.localizedDescription)")
            }

            do {
                let writeHandle = try FileHandle(forWritingTo: stagingURL)
                defer {
                    do {
                        try writeHandle.close()
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to close writeHandle: \(error)")
                    }
                }
                try writeHandle.seekToEnd()

                let readHandle = try FileHandle(forReadingFrom: sourceURL)
                defer {
                    do {
                        try readHandle.close()
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to close readHandle: \(error)")
                    }
                }

                let bufferSize = 256 * 1024
                while true {
                    let chunk = readHandle.readData(ofLength: bufferSize)
                    if chunk.isEmpty { break }
                    writeHandle.write(chunk)
                }
                // Bug #20: Explicitly synchronize appended staging data and propagate errors
                try writeHandle.synchronize()
                do {
                    try fileManager.removeItem(at: sourceURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to remove sourceURL \(sourceURL.path): \(error)")
                }
            } catch {
                do {
                    try fileManager.removeItem(at: stagingURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
                }
                throw BackgroundTransportError.fileRelocationFailed(underlyingError: "Failed to append downloaded bytes: \(error.localizedDescription)")
            }
        } else {
            do {
                try fileManager.moveItem(at: sourceURL, to: stagingURL)
            } catch {
                throw BackgroundTransportError.fileRelocationFailed(underlyingError: "Failed to stage temporary file: \(error.localizedDescription)")
            }
        }

        // Verify size of staged file before touching destination
        let attrs = try fileManager.attributesOfItem(atPath: stagingURL.path)
        guard let fileSize = attrs[.size] as? Int64 else {
            do {
                try fileManager.removeItem(at: stagingURL)
            } catch {
                PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
            }
            throw BackgroundTransportError.fileRelocationFailed(underlyingError: "Cannot determine staged file size")
        }

        if let expected = expectedFinalTotalBytes, fileSize != expected {
            // Corrupt or truncated file: remove staging and throw. Existing destination is preserved!
            do {
                try fileManager.removeItem(at: stagingURL)
            } catch {
                PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
            }
            throw BackgroundTransportError.bodyLengthMismatch(expected: expected, actual: fileSize)
        }

        // Safely commit staging to destinationURL atomically using non-destructive backup swap
        if fileManager.fileExists(atPath: destinationURL.path) {
            #if canImport(Darwin)
            do {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL, backupItemName: nil, options: [])
            } catch {
                let backupURL = parentDir.appendingPathComponent(".backup-\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
                do {
                    try fileManager.moveItem(at: destinationURL, to: backupURL)
                } catch {
                    do {
                        try fileManager.removeItem(at: stagingURL)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
                    }
                    throw BackgroundTransportError.fileRelocationFailed(underlyingError: "Failed to backup existing destination: \(error.localizedDescription)")
                }
                do {
                    try fileManager.moveItem(at: stagingURL, to: destinationURL)
                    do {
                        try fileManager.removeItem(at: backupURL)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to remove backupURL \(backupURL.path): \(error)")
                    }
                } catch {
                    do {
                        try fileManager.moveItem(at: backupURL, to: destinationURL)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to restore backupURL \(backupURL.path): \(error)")
                    }
                    do {
                        try fileManager.removeItem(at: stagingURL)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
                    }
                    throw BackgroundTransportError.fileRelocationFailed(underlyingError: error.localizedDescription)
                }
            }
            #else
            let backupURL = parentDir.appendingPathComponent(".backup-\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
            do {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
            } catch {
                do {
                    try fileManager.removeItem(at: stagingURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
                }
                throw BackgroundTransportError.fileRelocationFailed(underlyingError: "Failed to backup existing destination: \(error.localizedDescription)")
            }
            do {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
                do {
                    try fileManager.removeItem(at: backupURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to remove backupURL \(backupURL.path): \(error)")
                }
            } catch {
                do {
                    try fileManager.moveItem(at: backupURL, to: destinationURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to restore backupURL \(backupURL.path): \(error)")
                }
                do {
                    try fileManager.removeItem(at: stagingURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
                }
                throw BackgroundTransportError.fileRelocationFailed(underlyingError: error.localizedDescription)
            }
            #endif
        } else {
            do {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            } catch {
                do {
                    try fileManager.removeItem(at: stagingURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
                }
                throw BackgroundTransportError.fileRelocationFailed(underlyingError: error.localizedDescription)
            }
        }

        // Bug #20: Explicitly synchronize committed destination file before declaring success
        do {
            let destHandle = try FileHandle(forWritingTo: destinationURL)
            defer {
                do {
                    try destHandle.close()
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to close destHandle: \(error)")
                }
            }
            try destHandle.synchronize()
        } catch {
            throw BackgroundTransportError.fileRelocationFailed(
                underlyingError: "Failed to synchronize committed destination file: \(error.localizedDescription)"
            )
        }

        return fileSize
    }
}

// MARK: - Background Reconciliation Report

/// Summary of active background tasks reconciled on app relaunch or session reconnection.
public struct BackgroundReconciliationReport: Equatable, Sendable {
    public let activeTasksCount: Int
    public let orphanedTasksCount: Int
    public let restoredRecords: [BackgroundDownloadTaskRecord]
    public let completedRecords: [BackgroundDownloadTaskRecord]

    public init(
        activeTasksCount: Int,
        orphanedTasksCount: Int,
        restoredRecords: [BackgroundDownloadTaskRecord],
        completedRecords: [BackgroundDownloadTaskRecord]
    ) {
        self.activeTasksCount = activeTasksCount
        self.orphanedTasksCount = orphanedTasksCount
        self.restoredRecords = restoredRecords
        self.completedRecords = completedRecords
    }
}

// MARK: - Background Download Session Manager

/// Standalone manager for system-managed out-of-process background HTTP transfers.
///
/// Design Guarantees (Milestone 6A.1):
/// 1. Uses `"com.r4m335.DownloadEngineKit.background-http"` consistently.
/// 2. Scopes persistent task mappings by composite `(sessionIdentifier, taskIdentifier)`.
/// 3. Correctly accounts for segment progress relative to `SegmentRecord.length` (never absolute file offsets).
/// 4. Validates HTTP 206 Partial Content, Content-Range headers, and expected total file size.
/// 5. Uses crash-safe staging-and-replace file handling preserving destination on failure.
/// 6. Feeds completed segment progress directly into `DownloadPersistenceStore` (no competing truth).
public final class BackgroundDownloadSessionManager: NSObject, @unchecked Sendable {

    public static let defaultSessionIdentifier = "com.r4m335.DownloadEngineKit.background-http"

    public let sessionIdentifier: String
    public let mappingStore: BackgroundDownloadTaskMappingStore
    public let persistenceStore: DownloadPersistenceStore?
    public let temporaryDirectoryURL: URL

    private var session: URLSession!
    private let delegateQueue: OperationQueue

    /// Optional completion handler provided by UIKit's `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public var backgroundEventsCompletionHandler: (@Sendable () -> Void)?

    /// Progress notification hook: (downloadID, segmentID, segmentCompletedBytes, segmentLength)
    public var onSegmentProgress: (@Sendable (String, Int, Int64, Int64) -> Void)?

    /// Completion notification hook: (downloadID, segmentID, partFileURL)
    public var onSegmentCompleted: (@Sendable (String, Int, URL) -> Void)?

    /// Failure notification hook: (downloadID, segmentID, error)
    /// Failure notification hook: (downloadID, segmentID, error)
    public var onSegmentFailed: (@Sendable (String, Int, Error) -> Void)?

    // MARK: - In-Flight Task Tracking & Callback Ordering
    private let eventLock = NSLock()
    private var inFlightDelegateTasks = 0
    private var pendingDrainContinuations: [CheckedContinuation<Void, Never>] = []

    // Per-download observer callbacks for coordinator integration
    private var progressObservers: [String: [@Sendable (Int, Int64, Int64) -> Void]] = [:]
    private var completionObservers: [String: [@Sendable (Int, URL) -> Void]] = [:]
    private var failureObservers: [String: [@Sendable (Int, Error) -> Void]] = [:]

    /// Registers per-download lifecycle observers for coordinator integration.
    public func addObserver(
        for downloadID: String,
        onProgress: (@Sendable (Int, Int64, Int64) -> Void)? = nil,
        onCompleted: (@Sendable (Int, URL) -> Void)? = nil,
        onFailed: (@Sendable (Int, Error) -> Void)? = nil
    ) {
        eventLock.lock()
        defer { eventLock.unlock() }
        if let onProgress { progressObservers[downloadID, default: []].append(onProgress) }
        if let onCompleted { completionObservers[downloadID, default: []].append(onCompleted) }
        if let onFailed { failureObservers[downloadID, default: []].append(onFailed) }
    }

    /// Removes all observers registered for a download.
    public func removeObservers(for downloadID: String) {
        eventLock.lock()
        defer { eventLock.unlock() }
        progressObservers.removeValue(forKey: downloadID)
        completionObservers.removeValue(forKey: downloadID)
        failureObservers.removeValue(forKey: downloadID)
    }

    internal func trackDelegateTaskStarted() {
        eventLock.lock()
        defer { eventLock.unlock() }
        inFlightDelegateTasks += 1
    }

    internal func trackDelegateTaskFinished() {
        eventLock.lock()
        inFlightDelegateTasks -= 1
        if inFlightDelegateTasks <= 0 {
            inFlightDelegateTasks = 0
            let continuations = pendingDrainContinuations
            pendingDrainContinuations.removeAll()
            eventLock.unlock()
            for c in continuations {
                c.resume()
            }
            return
        }
        eventLock.unlock()
    }

    /// Awaits all active delegate async work (file moves, validations, persistence writes) to settle.
    public func waitForInFlightEvents() async {
        let needsWait: Bool = {
            eventLock.lock()
            defer { eventLock.unlock() }
            return inFlightDelegateTasks > 0
        }()
        guard needsWait else { return }

        await withCheckedContinuation { continuation in
            eventLock.lock()
            if inFlightDelegateTasks == 0 {
                eventLock.unlock()
                continuation.resume()
            } else {
                pendingDrainContinuations.append(continuation)
                eventLock.unlock()
            }
        }
    }

    internal func notifyProgress(downloadID: String, segmentID: Int, completedBytes: Int64, totalBytes: Int64) {
        self.onSegmentProgress?(downloadID, segmentID, completedBytes, totalBytes)
        let observers: [@Sendable (Int, Int64, Int64) -> Void] = {
            eventLock.lock()
            defer { eventLock.unlock() }
            return progressObservers[downloadID] ?? []
        }()
        for obs in observers {
            obs(segmentID, completedBytes, totalBytes)
        }
    }

    internal func notifyCompleted(downloadID: String, segmentID: Int, partURL: URL) {
        self.onSegmentCompleted?(downloadID, segmentID, partURL)
        let observers: [@Sendable (Int, URL) -> Void] = {
            eventLock.lock()
            defer { eventLock.unlock() }
            return completionObservers[downloadID] ?? []
        }()
        for obs in observers {
            obs(segmentID, partURL)
        }
    }

    internal func notifyFailed(downloadID: String, segmentID: Int, error: Error) {
        self.onSegmentFailed?(downloadID, segmentID, error)
        let observers: [@Sendable (Int, Error) -> Void] = {
            eventLock.lock()
            defer { eventLock.unlock() }
            return failureObservers[downloadID] ?? []
        }()
        for obs in observers {
            obs(segmentID, error)
        }
    }

    public init(
        sessionIdentifier: String = BackgroundDownloadSessionManager.defaultSessionIdentifier,
        storageDirectoryURL: URL,
        persistenceStore: DownloadPersistenceStore? = nil,
        temporaryDirectoryURL: URL? = nil
    ) throws {
        self.sessionIdentifier = sessionIdentifier
        self.mappingStore = try BackgroundDownloadTaskMappingStore(storageDirectoryURL: storageDirectoryURL)
        self.persistenceStore = persistenceStore
        self.temporaryDirectoryURL = temporaryDirectoryURL
            ?? storageDirectoryURL.appendingPathComponent("PartStaging", isDirectory: true)

        let queue = OperationQueue()
        queue.name = "com.r4m335.background-http.delegate-queue"
        queue.maxConcurrentOperationCount = 1
        self.delegateQueue = queue

        super.init()

        try FileManager.default.createDirectory(at: self.temporaryDirectoryURL, withIntermediateDirectories: true)
        self.session = createSession(identifier: sessionIdentifier)
    }

    private func createSession(identifier: String) -> URLSession {
#if canImport(Darwin)
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.shouldUseExtendedBackgroundIdleMode = true
        config.timeoutIntervalForRequest = 60
        // Set maximum connections per host to manage socket concurrency in the daemon
        config.httpMaximumConnectionsPerHost = 6
        // Set resource timeout to 7 days (system default) rather than 24 hours to prevent cutting off slow large transfers
        config.timeoutIntervalForResource = 604800
#else
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForResource = 604800
#endif
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    // MARK: - Public Scheduling API

    /// Enqueues an HTTP byte-range segment for background downloading.
    @discardableResult
    public func scheduleSegmentDownload(
        download: DownloadRecord,
        segment: SegmentRecord,
        customHeaders: [String: String]? = nil,
        earliestBeginDate: Date? = nil
    ) async throws -> BackgroundDownloadTaskRecord {
        let targetURL = download.resolvedURL ?? download.originalURL
        var request = URLRequest(url: targetURL)
        request.allowsCellularAccess = download.networkPolicy.allowsCellularAccess
        #if canImport(Darwin)
        if #available(iOS 13.0, macOS 10.15, *) {
            request.allowsExpensiveNetworkAccess = download.networkPolicy.allowsExpensiveNetworkAccess
            request.allowsConstrainedNetworkAccess = download.networkPolicy.allowsConstrainedNetworkAccess
        }
        #endif

        if let headers = customHeaders ?? (download.securedHeaders.isEmpty ? nil : download.securedHeaders) {
            for (k, v) in headers {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }

        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request = DownloadRequestEnricher.enrich(request)

        let resumeOffset = segment.resumeStartOffset
        let expectedBytes = segment.endOffset - resumeOffset + 1
        guard expectedBytes > 0 else {
            // Segment already complete
            let existingRecord = await mappingStore.record(forDownloadID: download.id, segmentID: segment.id)
            if let existingRecord { return existingRecord }
            let completedRecord = BackgroundDownloadTaskRecord(
                sessionIdentifier: sessionIdentifier,
                taskIdentifier: -1,
                downloadID: download.id,
                segmentID: segment.id,
                originalURL: targetURL,
                startOffset: segment.startOffset,
                endOffset: segment.endOffset,
                expectedBytes: segment.length,
                initialSegmentCompletedBytes: segment.completedBytes,
                segmentLength: segment.length,
                destinationPartURL: partFileURL(downloadID: download.id, segmentID: segment.id),
                completedBytes: segment.length,
                isCompleted: true
            )
            try await mappingStore.save(record: completedRecord)
            return completedRecord
        }

        let rangeHeader = "bytes=\(resumeOffset)-\(segment.endOffset)"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")

        if let validator = DownloadRequestEnricher.ifRangeValidator(eTag: download.eTag, lastModified: download.lastModified) {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }

        let partURL = partFileURL(downloadID: download.id, segmentID: segment.id)
        let resumeURL = resumeDataURL(downloadID: download.id, segmentID: segment.id)
        let task: URLSessionDownloadTask
        if FileManager.default.fileExists(atPath: resumeURL.path),
           let resumeData = try? Data(contentsOf: resumeURL) {
            task = session.downloadTask(withResumeData: resumeData)
            try? FileManager.default.removeItem(at: resumeURL)
            PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Resumed download task with resumeData for download \(download.id), segment \(segment.id)")
        } else {
            task = session.downloadTask(with: request)
        }
        // This scheduling hint is reliable only when assigned before resume().
        #if canImport(Darwin)
        if #available(iOS 11.0, macOS 10.13, *) {
            task.earliestBeginDate = earliestBeginDate
        }
        #endif

        let taskRecord = BackgroundDownloadTaskRecord(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: task.taskIdentifier,
            downloadID: download.id,
            segmentID: segment.id,
            originalURL: targetURL,
            startOffset: resumeOffset,
            endOffset: segment.endOffset,
            expectedBytes: expectedBytes,
            initialSegmentCompletedBytes: segment.completedBytes,
            segmentLength: segment.length,
            destinationPartURL: partURL,
            completedBytes: 0
        )

        task.taskDescription = taskRecord.systemTaskDescription
        try await mappingStore.save(record: taskRecord)
        task.resume()

        return taskRecord
    }

    /// Schedules an individual streaming segment chunk using the background URLSession.
    @discardableResult
    public func scheduleStreamingSegment(
        transferID: String,
        order: Int,
        url: URL,
        destinationURL: URL,
        headers: [String: String]? = nil,
        byteRange: (start: Int64, end: Int64)? = nil,
        earliestBeginDate: Date? = nil
    ) async throws -> BackgroundDownloadTaskRecord {
        if let existing = mappingStore.record(forDownloadID: transferID, segmentID: order),
           existing.state == .downloading || existing.state == .pending {
            return existing
        }

        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let headers {
            for (k, v) in headers {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }
        request = DownloadRequestEnricher.enrich(request)

        let expectedBytes: Int64
        if let byteRange {
            let rangeHeader = "bytes=\(byteRange.start)-\(byteRange.end)"
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            expectedBytes = max(0, byteRange.end - byteRange.start + 1)
        } else {
            expectedBytes = 0
        }

        let resumeURL = resumeDataURL(downloadID: transferID, segmentID: order)
        let task: URLSessionDownloadTask
        if FileManager.default.fileExists(atPath: resumeURL.path),
           let resumeData = try? Data(contentsOf: resumeURL) {
            task = session.downloadTask(withResumeData: resumeData)
            try? FileManager.default.removeItem(at: resumeURL)
            PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Resumed streaming segment task with resumeData for \(transferID), order \(order)")
        } else {
            task = session.downloadTask(with: request)
        }

        #if canImport(Darwin)
        if #available(iOS 11.0, macOS 10.13, *) {
            task.earliestBeginDate = earliestBeginDate
        }
        #endif

        let taskRecord = BackgroundDownloadTaskRecord(
            sessionIdentifier: sessionIdentifier,
            taskIdentifier: task.taskIdentifier,
            downloadID: transferID,
            segmentID: order,
            originalURL: url,
            startOffset: byteRange?.start ?? 0,
            endOffset: byteRange?.end ?? 0,
            expectedBytes: expectedBytes,
            initialSegmentCompletedBytes: 0,
            segmentLength: expectedBytes,
            destinationPartURL: destinationURL,
            completedBytes: 0
        )

        task.taskDescription = taskRecord.systemTaskDescription
        try await mappingStore.save(record: taskRecord)
        task.resume()

        return taskRecord
    }

    /// Cancels a specific background task.
    public func cancelTask(taskIdentifier: Int) async {
        let task = await findTask(withIdentifier: taskIdentifier)
        task?.cancel()
        if let rec = await mappingStore.record(sessionIdentifier: sessionIdentifier, taskIdentifier: taskIdentifier) {
            await reconcileSegmentWithDisk(downloadID: rec.downloadID, segmentID: rec.segmentID, partURL: rec.destinationPartURL)
        }
        do {
            try await mappingStore.remove(sessionIdentifier: sessionIdentifier, taskIdentifier: taskIdentifier)
        } catch {
            PipelineLogger.shared.log(stage: .transport, message: "Failed to remove mapping task \(taskIdentifier): \(error)")
        }
    }

    /// Cancels all background tasks associated with a given download.
    public func cancelTasks(for downloadID: String) async {
        let records = await mappingStore.records(forDownloadID: downloadID)
        for r in records {
            let task = await findTask(withIdentifier: r.taskIdentifier)
            task?.cancel()
            await reconcileSegmentWithDisk(downloadID: r.downloadID, segmentID: r.segmentID, partURL: r.destinationPartURL)
            do {
                try await mappingStore.remove(sessionIdentifier: r.sessionIdentifier, taskIdentifier: r.taskIdentifier)
            } catch {
                PipelineLogger.shared.log(stage: .transport, message: "Failed to remove mapping task \(r.taskIdentifier): \(error)")
            }
        }
    }

    /// Reconciles a segment's persisted checkpoint strictly to the bytes actually committed to disk.
    private func reconcileSegmentWithDisk(downloadID: String, segmentID: Int, partURL: URL) async {
        guard let persistence = self.persistenceStore else { return }
        let currentSize = FileManager.default.fileSize(atPath: partURL.path) ?? 0
        do {
            _ = try await persistence.updateSegmentProgress(
                tag: downloadID,
                segmentID: segmentID,
                completedBytes: max(0, currentSize),
                allowDecrease: true
            )
        } catch {
            PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Warning: failed to reconcile task with disk size: \(error)")
        }
    }

    /// Best-effort compatibility method for tasks created by older builds.
    /// New tasks must receive the date through `scheduleSegmentDownload` before resume().
    public func setEarliestBeginDate(_ date: Date?, for downloadID: String? = nil) async {
        let tasks = await activeSessionTasks()
        if let targetID = downloadID {
            let records = await mappingStore.records(forDownloadID: targetID)
            let matchingTaskIDs = Set(records.map { $0.taskIdentifier })
            for task in tasks where matchingTaskIDs.contains(task.taskIdentifier) {
                #if canImport(Darwin)
                if #available(iOS 11.0, macOS 10.13, *) {
                    task.earliestBeginDate = date
                }
                #endif
            }
        } else {
            for task in tasks {
                #if canImport(Darwin)
                if #available(iOS 11.0, macOS 10.13, *) {
                    task.earliestBeginDate = date
                }
                #endif
            }
        }
    }

    /// Queries all active tasks for a download that are currently running in the system URLSession.
    public func activeTasks(for downloadID: String) async -> [BackgroundDownloadTaskRecord] {
        let allTasks = await activeSessionTasks()
        let taskIDsInSession = Set(allTasks.map { $0.taskIdentifier })
        let records = await mappingStore.records(forDownloadID: downloadID)
        return records.filter { taskIDsInSession.contains($0.taskIdentifier) && !$0.isCompleted }
    }

    /// Reconciles system URLSession tasks with persisted mappings upon app launch / reactivation.
    /// Updates both `mappingStore` and `DownloadPersistenceStore` consistently.
    ///
    /// Completion invariant: A background download segment is complete if and only if
    /// its physical part file exists on disk and its byte size strictly equals the absolute `segmentLength`.
    /// `expectedBytes` represents only the response body length for this particular HTTP request slice,
    /// which for a resumed request (`initialSegmentCompletedBytes > 0`) is strictly less than `segmentLength`.
    /// Under no circumstance may a partial file of size `expectedBytes < segmentLength` be marked complete.
    public func reconcileActiveTasks() async throws -> BackgroundReconciliationReport {
        let allTasks = await activeSessionTasks()
        let taskIDsInSession = Set(allTasks.map { $0.taskIdentifier })
        let persistedRecords = await mappingStore.records(forSessionIdentifier: sessionIdentifier)

        var restored: [BackgroundDownloadTaskRecord] = []
        var completed: [BackgroundDownloadTaskRecord] = []
        var orphanedCount = 0

        for r in persistedRecords {
            if taskIDsInSession.contains(r.taskIdentifier) {
                restored.append(r)
            } else {
                // Task is no longer running in system session.
                let partPath = r.destinationPartURL.path
                if FileManager.default.fileExists(atPath: partPath) {
                    let size = FileManager.default.fileSize(atPath: partPath) ?? 0

                    let isIndeterminate = r.segmentLength <= 0
                    let isCompleted = isIndeterminate ? (size > 0) : (size == r.segmentLength && r.segmentLength > 0)
                    let isOversized = !isIndeterminate && (size > r.segmentLength)

                    if isCompleted {
                        // Invariant holds: part file strictly equals absolute segment length (or non-empty for streaming)
                        let finalBytes = isIndeterminate ? size : r.segmentLength
                        try await mappingStore.markCompleted(
                            sessionIdentifier: r.sessionIdentifier,
                            taskIdentifier: r.taskIdentifier,
                            finalBytes: finalBytes
                        )

                        // Reconcile DownloadPersistenceStore segment record.
                        // Do not silently swallow persistence failures that could cause false completion.
                        if let persistence = self.persistenceStore {
                            _ = try await persistence.updateSegmentProgress(
                                tag: r.downloadID,
                                segmentID: r.segmentID,
                                completedBytes: finalBytes
                            )
                        }

                        self.notifyCompleted(downloadID: r.downloadID, segmentID: r.segmentID, partURL: r.destinationPartURL)
                        completed.append(r)
                        continue
                    } else if isOversized {
                        // Corrupted or oversized part file: purge corrupted file safely
                        do {
                            try FileManager.default.removeItem(at: r.destinationPartURL)
                        } catch {
                            PipelineLogger.shared.log(stage: .transport, message: "Failed to remove oversized part file \(r.destinationPartURL.path): \(error)")
                        }
                        if let persistence = self.persistenceStore {
                            do {
                                _ = try await persistence.updateSegmentProgress(
                                    tag: r.downloadID,
                                    segmentID: r.segmentID,
                                    completedBytes: 0,
                                    allowDecrease: true
                                )
                            } catch {
                                PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Warning: failed to reset corrupted segment in persistence: \(error)")
                            }
                        }
                    } else {
                        // Partial file is smaller than segmentLength (even if size == r.expectedBytes).
                        // Must remain incomplete! Reconcile persistence with validated on-disk size.
                        if let persistence = self.persistenceStore {
                            do {
                                _ = try await persistence.updateSegmentProgress(
                                    tag: r.downloadID,
                                    segmentID: r.segmentID,
                                    completedBytes: max(0, size),
                                    allowDecrease: true
                                )
                            } catch {
                                PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Warning: failed to reconcile partial segment progress: \(error)")
                            }
                        }
                    }
                } else {
                    // Part file is missing on disk: reset persistence segment completed bytes
                    if let persistence = self.persistenceStore {
                        do {
                            _ = try await persistence.updateSegmentProgress(
                                tag: r.downloadID,
                                segmentID: r.segmentID,
                                completedBytes: 0,
                                allowDecrease: true
                            )
                        } catch {
                            PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Warning: failed to reset missing segment progress: \(error)")
                        }
                    }
                }

                // Dead or incomplete task: clean up orphaned mapping from store so it does not block future task scheduling
                try await mappingStore.remove(sessionIdentifier: r.sessionIdentifier, taskIdentifier: r.taskIdentifier)
                orphanedCount += 1
            }
        }

        let knownTaskIDs = Set(persistedRecords.map { $0.taskIdentifier })
        for t in allTasks {
            if !knownTaskIDs.contains(t.taskIdentifier) {
                t.cancel()
            }
        }

        return BackgroundReconciliationReport(
            activeTasksCount: restored.count,
            orphanedTasksCount: orphanedCount,
            restoredRecords: restored,
            completedRecords: completed
        )
    }

    public func setEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        self.backgroundEventsCompletionHandler = handler
    }

    public func partFileURL(downloadID: String, segmentID: Int) -> URL {
        temporaryDirectoryURL
            .appendingPathComponent("\(downloadID)_segment-\(segmentID).part")
    }

    public func resumeDataURL(downloadID: String, segmentID: Int) -> URL {
        temporaryDirectoryURL
            .appendingPathComponent("\(downloadID)_segment-\(segmentID).resumeData")
    }

    private func findTask(withIdentifier id: Int) async -> URLSessionTask? {
        let tasks = await activeSessionTasks()
        return tasks.first { $0.taskIdentifier == id }
    }

    // Internal for regression tests that verify task scheduling metadata before
    // the system-managed task is allowed to begin.
    internal func activeSessionTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate Conformance

extension BackgroundDownloadSessionManager: URLSessionDownloadDelegate {

    private func isTransientNetworkError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorCallIsActive,
             NSURLErrorDataNotAllowed:
            return true
        default:
            return false
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let enriched = DownloadRequestEnricher.handleRedirect(
            task: task,
            response: response,
            newRequest: request
        )
        completionHandler(enriched)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        let sessID = self.sessionIdentifier

        trackDelegateTaskStarted()
        Task { [self] in
            defer { self.trackDelegateTaskFinished() }
            guard let record = await self.mappingStore.record(sessionIdentifier: sessID, taskIdentifier: taskID) else { return }

            do {
                try await self.mappingStore.updateProgress(sessionIdentifier: sessID, taskIdentifier: taskID, taskBytesWritten: totalBytesWritten)
            } catch {
                PipelineLogger.shared.log(stage: .transport, message: "Failed to update mappingStore progress for task \(taskID): \(error)")
            }

            // Segment-relative progress accounting:
            // segmentTotalCompleted = initialSegmentCompletedBytes + totalBytesWritten (clamped to segmentLength)
            let segmentTotalCompleted = min(record.segmentLength, record.initialSegmentCompletedBytes + totalBytesWritten)

            // CRITICAL (Bug #20): Stop treating daemon-side in-flight bytes as durable persisted progress.
            // In background downloads, in-flight bytes reside solely within Apple's system daemon
            // (nsurlsessiond) temporary staging storage and are NOT committed to the destination
            // part file on disk until didFinishDownloadingTo validates, relocates/appends, and flushes them.
            // Persisting in-flight progress here corrupts durable checkpoints if the task is interrupted,
            // cancelled, or fails. UI progress notifications remain fully active via notifyProgress.

            self.notifyProgress(
                downloadID: record.downloadID,
                segmentID: record.segmentID,
                completedBytes: segmentTotalCompleted,
                totalBytes: record.segmentLength
            )
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        let sessID = self.sessionIdentifier
        let response = downloadTask.response

        guard let desc = downloadTask.taskDescription,
              let parsed = BackgroundDownloadTaskRecord.parseSystemTaskDescription(desc) else {
            PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Warning: missing or unparseable taskDescription on task \(taskID)")
            return
        }

        let downloadID = parsed.downloadID
        let segmentID = parsed.segmentID
        let destination = self.partFileURL(downloadID: downloadID, segmentID: segmentID)

        trackDelegateTaskStarted()

        // 1. Relocate to an intermediate staging file synchronously before iOS deletes `location`
        let parentDir = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            PipelineLogger.shared.log(stage: .transport, message: "Failed to create directory \(parentDir.path): \(error)")
        }
        let stagingURL = parentDir.appendingPathComponent("incoming_\(taskID)_\(UUID().uuidString).tmp")

        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
        } catch {
            PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Error staging downloaded file: \(error)")
            Task { [self] in
                defer { self.trackDelegateTaskFinished() }
                do {
                    try await self.mappingStore.markFailed(sessionIdentifier: sessID, taskIdentifier: taskID, error: error.localizedDescription)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to markFailed in mappingStore for task \(taskID): \(error)")
                }
                self.notifyFailed(downloadID: downloadID, segmentID: segmentID, error: error)
            }
            return
        }

        // 2. Validate response, verify expected size, and update stores asynchronously
        Task { [self] in
            defer { self.trackDelegateTaskFinished() }
            guard let record = await self.mappingStore.record(sessionIdentifier: sessID, taskIdentifier: taskID) else {
                PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Warning: missing task record for task \(taskID)")
                do {
                    try FileManager.default.removeItem(at: stagingURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
                }
                return
            }

            // Fetch download record to obtain known total size for response validation
            var knownTotalSize: Int64? = nil
            if let persistence = self.persistenceStore {
                do {
                    let dlRec = try await persistence.fetch(tag: downloadID)
                    knownTotalSize = dlRec?.totalSize
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to fetch download record for \(downloadID): \(error)")
                }
            }

            if let resp = response {
                do {
                    try BackgroundResponseValidator.validate(
                        response: resp,
                        expectedStart: record.startOffset,
                        expectedEnd: record.endOffset,
                        expectedTotalSize: knownTotalSize
                    )
                } catch {
                    do {
                        try FileManager.default.removeItem(at: stagingURL)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
                    }
                    do {
                        try FileManager.default.removeItem(at: destination)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to remove destination \(destination.path): \(error)")
                    }
                    do {
                        try await self.mappingStore.markFailed(sessionIdentifier: sessID, taskIdentifier: taskID, error: error.localizedDescription)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to markFailed in mappingStore for task \(taskID): \(error)")
                    }
                    if let persistence = self.persistenceStore {
                        do {
                            _ = try await persistence.updateSegmentProgress(tag: downloadID, segmentID: segmentID, completedBytes: 0, allowDecrease: true)
                        } catch {
                            PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Warning: failed to reset segment progress on response error: \(error)")
                        }
                    }
                    self.notifyFailed(downloadID: downloadID, segmentID: segmentID, error: error)
                    return
                }
            }

            let shouldAppend = record.initialSegmentCompletedBytes > 0
            let expectedFinalBytes = record.segmentLength
            let finalSize: Int64
            do {
                finalSize = try BackgroundDownloadFileHandler.relocateOrAppendTemporaryFile(
                    from: stagingURL,
                    to: destination,
                    expectedNewBytes: record.expectedBytes,
                    expectedFinalTotalBytes: expectedFinalBytes,
                    append: shouldAppend
                )
            } catch {
                PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Error committing downloaded file: \(error)")
                do {
                    try FileManager.default.removeItem(at: stagingURL)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to remove stagingURL \(stagingURL.path): \(error)")
                }
                do {
                    try await self.mappingStore.markFailed(sessionIdentifier: sessID, taskIdentifier: taskID, error: error.localizedDescription)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to markFailed in mappingStore for task \(taskID): \(error)")
                }
                if let persistence = self.persistenceStore {
                    let currentSize = FileManager.default.fileSize(atPath: destination.path) ?? 0
                    do {
                        _ = try await persistence.updateSegmentProgress(tag: downloadID, segmentID: segmentID, completedBytes: currentSize, allowDecrease: true)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Warning: failed to reconcile segment progress after commit error: \(error)")
                    }
                }
                self.notifyFailed(downloadID: downloadID, segmentID: segmentID, error: error)
                return
            }

            guard finalSize > 0 else {
                let errorMsg = "Final file size is 0 bytes for task \(taskID)"
                PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Error: \(errorMsg)")
                do {
                    try await self.mappingStore.markFailed(sessionIdentifier: sessID, taskIdentifier: taskID, error: errorMsg)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to markFailed in mappingStore for task \(taskID): \(error)")
                }
                self.notifyFailed(
                    downloadID: downloadID,
                    segmentID: segmentID,
                    error: BackgroundTransportError.bodyLengthMismatch(expected: record.segmentLength, actual: finalSize)
                )
                return
            }

            guard record.segmentLength <= 0 || finalSize == record.segmentLength else {
                let errorMsg = "Final file size mismatch: expected \(record.segmentLength), got \(finalSize)"
                PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Error: \(errorMsg)")
                do {
                    try await self.mappingStore.markFailed(sessionIdentifier: sessID, taskIdentifier: taskID, error: errorMsg)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to markFailed in mappingStore for task \(taskID): \(error)")
                }
                if let persistence = self.persistenceStore {
                    do {
                        _ = try await persistence.updateSegmentProgress(tag: downloadID, segmentID: segmentID, completedBytes: finalSize, allowDecrease: true)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Warning: failed to persist final size on mismatch: \(error)")
                    }
                }
                self.notifyFailed(
                    downloadID: downloadID,
                    segmentID: segmentID,
                    error: BackgroundTransportError.bodyLengthMismatch(expected: record.segmentLength, actual: finalSize)
                )
                return
            }

            do {
                try await self.mappingStore.markCompleted(sessionIdentifier: sessID, taskIdentifier: taskID, finalBytes: finalSize)
            } catch {
                PipelineLogger.shared.log(stage: .transport, message: "Failed to markCompleted in mappingStore for task \(taskID): \(error)")
            }

            // Segment completion: mark segment completed with full segmentLength
            if let persistence = self.persistenceStore {
                do {
                    _ = try await persistence.updateSegmentProgress(
                        tag: downloadID,
                        segmentID: segmentID,
                        completedBytes: record.segmentLength
                    )
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Warning: failed to mark segment completed in persistence: \(error)")
                    do {
                        try await self.mappingStore.markFailed(sessionIdentifier: sessID, taskIdentifier: taskID, error: error.localizedDescription)
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "Failed to markFailed in mappingStore for task \(taskID): \(error)")
                    }
                    self.notifyFailed(downloadID: downloadID, segmentID: segmentID, error: error)
                    return
                }
            }

            self.notifyCompleted(downloadID: downloadID, segmentID: segmentID, partURL: destination)
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = task.taskIdentifier
        let sessID = self.sessionIdentifier
        guard let rawError = error else { return }

        let finalError: Error
        if let httpResponse = task.response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            finalError = BackgroundTransportError.unexpectedStatus(expected: 206, actual: httpResponse.statusCode)
        } else {
            finalError = rawError
        }

        trackDelegateTaskStarted()
        Task { [self] in
            defer { self.trackDelegateTaskFinished() }
            if let rec = await self.mappingStore.record(sessionIdentifier: sessID, taskIdentifier: taskID) {
                let nsError = rawError as NSError
                if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    let resumeURL = self.resumeDataURL(downloadID: rec.downloadID, segmentID: rec.segmentID)
                    do {
                        try resumeData.write(to: resumeURL)
                        PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Saved resumeData for download \(rec.downloadID), segment \(rec.segmentID) (\(resumeData.count) bytes)")
                    } catch {
                        PipelineLogger.shared.log(stage: .transport, message: "[BackgroundDownloadSessionManager] Failed to save resumeData for task \(taskID): \(error.localizedDescription)")
                    }
                }

                do {
                    try await self.mappingStore.markFailed(sessionIdentifier: sessID, taskIdentifier: taskID, error: finalError.localizedDescription)
                } catch {
                    PipelineLogger.shared.log(stage: .transport, message: "Failed to markFailed in mappingStore for task \(taskID): \(error)")
                }
                // Bug #20: Reconcile persisted progress against actual committed file on disk when a task fails
                await reconcileSegmentWithDisk(downloadID: rec.downloadID, segmentID: rec.segmentID, partURL: rec.destinationPartURL)
                self.notifyFailed(downloadID: rec.downloadID, segmentID: rec.segmentID, error: finalError)
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { [weak self] in
            guard let self = self else { return }
            // Await all in-flight file operations, validations, and persistence writes before calling completionHandler
            await self.waitForInFlightEvents()
            await MainActor.run {
                self.backgroundEventsCompletionHandler?()
                self.backgroundEventsCompletionHandler = nil
            }
        }
    }
}
