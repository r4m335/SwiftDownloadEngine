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
    case bodyLengthMismatch(expected: Int64, actual: Int64)
    case htmlErrorPageReceived(contentType: String)
    case taskNotFound(taskIdentifier: Int)
    case temporaryFileMissing(path: String)
    case fileRelocationFailed(underlyingError: String)
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
        case .bodyLengthMismatch(let expected, let actual):
            return "Downloaded part file size (\(actual) bytes) does not match expected segment length (\(expected) bytes)"
        case .htmlErrorPageReceived(let contentType):
            return "Server returned HTML error/login page instead of binary content (\(contentType))"
        case .taskNotFound(let id):
            return "No persistent mapping found for background task identifier: \(id)"
        case .temporaryFileMissing(let path):
            return "Temporary file provided by URLSession does not exist: \(path)"
        case .fileRelocationFailed(let error):
            return "Failed to safely relocate temporary download file: \(error)"
        case .cancelled:
            return "Background task was cancelled"
        }
    }
}

// MARK: - Persistent Task Record

/// Durable mapping linking an iOS background `URLSessionDownloadTask` to its parent
/// `DownloadRecord` and `SegmentRecord`.
public struct BackgroundDownloadTaskRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { taskIdentifier }
    public let taskIdentifier: Int
    public let downloadID: String
    public let segmentID: Int
    public let originalURL: URL
    public let startOffset: Int64
    public let endOffset: Int64
    public let expectedBytes: Int64
    public let destinationPartURL: URL
    public let createdAt: Date
    public var updatedAt: Date
    public var completedBytes: Int64
    public var isCompleted: Bool
    public var errorDescription: String?

    public init(
        taskIdentifier: Int,
        downloadID: String,
        segmentID: Int,
        originalURL: URL,
        startOffset: Int64,
        endOffset: Int64,
        expectedBytes: Int64,
        destinationPartURL: URL,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedBytes: Int64 = 0,
        isCompleted: Bool = false,
        errorDescription: String? = nil
    ) {
        self.taskIdentifier = taskIdentifier
        self.downloadID = downloadID
        self.segmentID = segmentID
        self.originalURL = originalURL
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.expectedBytes = expectedBytes
        self.destinationPartURL = destinationPartURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedBytes = completedBytes
        self.isCompleted = isCompleted
        self.errorDescription = errorDescription
    }

    /// Task description string embedded directly into the URLSessionTask for system-level persistence.
    public var systemTaskDescription: String {
        "1DM_BG:\(downloadID):\(segmentID)"
    }

    /// Parses embedded task description if present.
    public static func parseSystemTaskDescription(_ desc: String) -> (downloadID: String, segmentID: Int)? {
        let parts = desc.split(separator: ":")
        guard parts.count == 3, parts[0] == "1DM_BG", let segID = Int(parts[2]) else {
            return nil
        }
        return (String(parts[1]), segID)
    }
}

// MARK: - Persistent Task Mapping Store

/// Thread-safe actor persisting and managing active background task mappings on disk.
/// Guarantees atomic writes so state is never corrupted during sudden process suspension.
public actor BackgroundDownloadTaskMappingStore {
    public let storeFileURL: URL

    private var cache: [Int: BackgroundDownloadTaskRecord] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(storageDirectoryURL: URL) throws {
        try FileManager.default.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        self.storeFileURL = storageDirectoryURL.appendingPathComponent("background_tasks_v1.json")

        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = jsonEncoder

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        self.decoder = jsonDecoder

        var initialCache: [Int: BackgroundDownloadTaskRecord] = [:]
        if FileManager.default.fileExists(atPath: self.storeFileURL.path),
           let data = try? Data(contentsOf: self.storeFileURL),
           let records = try? jsonDecoder.decode([BackgroundDownloadTaskRecord].self, from: data) {
            for r in records {
                initialCache[r.taskIdentifier] = r
            }
        }
        self.cache = initialCache
    }

    public func save(record: BackgroundDownloadTaskRecord) throws {
        var updated = record
        updated.updatedAt = Date()
        cache[record.taskIdentifier] = updated
        try persistToDisk()
    }

    public func record(forTaskIdentifier id: Int) -> BackgroundDownloadTaskRecord? {
        cache[id]
    }

    public func records(forDownloadID downloadID: String) -> [BackgroundDownloadTaskRecord] {
        cache.values.filter { $0.downloadID == downloadID }
    }

    public func record(forDownloadID downloadID: String, segmentID: Int) -> BackgroundDownloadTaskRecord? {
        cache.values.first { $0.downloadID == downloadID && $0.segmentID == segmentID }
    }

    public func allRecords() -> [BackgroundDownloadTaskRecord] {
        Array(cache.values)
    }

    public func updateProgress(taskIdentifier: Int, completedBytes: Int64) throws {
        guard var rec = cache[taskIdentifier] else { return }
        rec.completedBytes = min(rec.expectedBytes, max(0, completedBytes))
        rec.updatedAt = Date()
        cache[taskIdentifier] = rec
        try persistToDisk()
    }

    public func markCompleted(taskIdentifier: Int, finalBytes: Int64) throws {
        guard var rec = cache[taskIdentifier] else { return }
        rec.completedBytes = finalBytes
        rec.isCompleted = true
        rec.errorDescription = nil
        rec.updatedAt = Date()
        cache[taskIdentifier] = rec
        try persistToDisk()
    }

    public func markFailed(taskIdentifier: Int, error: String) throws {
        guard var rec = cache[taskIdentifier] else { return }
        rec.errorDescription = error
        rec.updatedAt = Date()
        cache[taskIdentifier] = rec
        try persistToDisk()
    }

    public func remove(taskIdentifier: Int) throws {
        cache.removeValue(forKey: taskIdentifier)
        try persistToDisk()
    }

    public func removeRecords(forDownloadID downloadID: String) throws {
        let keysToRemove = cache.filter { $0.value.downloadID == downloadID }.map { $0.key }
        for k in keysToRemove {
            cache.removeValue(forKey: k)
        }
        try persistToDisk()
    }

    private func loadFromDisk() throws {
        guard FileManager.default.fileExists(atPath: storeFileURL.path) else { return }
        let data = try Data(contentsOf: storeFileURL)
        let records = try decoder.decode([BackgroundDownloadTaskRecord].self, from: data)
        for r in records {
            cache[r.taskIdentifier] = r
        }
    }

    private func persistToDisk() throws {
        let records = Array(cache.values)
        let data = try encoder.encode(records)
        let tempURL = storeFileURL.deletingLastPathComponent()
            .appendingPathComponent("background_tasks_\(UUID().uuidString).tmp")

        try data.write(to: tempURL, options: .atomic)
        _ = try? FileManager.default.removeItem(at: storeFileURL)
        try FileManager.default.moveItem(at: tempURL, to: storeFileURL)
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
            if httpResponse.statusCode == 200 {
                throw BackgroundTransportError.unexpectedStatus(expected: 206, actual: 200)
            }
            throw BackgroundTransportError.unexpectedStatus(expected: 206, actual: httpResponse.statusCode)
        }

        // 2. HTML Error / Login Page Detection
        if let contentType = httpResponse.value(forCaseInsensitiveField: "Content-Type"),
           contentType.lowercased().contains("text/html") {
            throw BackgroundTransportError.htmlErrorPageReceived(contentType: contentType)
        }

        // 3. Content-Range Header Validation
        guard let contentRange = httpResponse.value(forCaseInsensitiveField: "Content-Range") else {
            throw BackgroundTransportError.invalidContentRange
        }

        // Parse: "bytes <start>-<end>/<total>"
        let parsed = try parseContentRange(contentRange)
        if parsed.start != expectedStart || parsed.end != expectedEnd {
            throw BackgroundTransportError.contentRangeMismatch(
                expectedStart: expectedStart,
                expectedEnd: expectedEnd,
                actualStart: parsed.start,
                actualEnd: parsed.end
            )
        }

        if let expectedTotal = expectedTotalSize, let actualTotal = parsed.total {
            if actualTotal != expectedTotal {
                throw BackgroundTransportError.totalSizeMismatch(expected: expectedTotal, actual: actualTotal)
            }
        }
    }

    public static func parseContentRange(_ header: String) throws -> (start: Int64, end: Int64, total: Int64?) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else {
            throw BackgroundTransportError.invalidContentRange
        }

        let rangePart = String(trimmed.dropFirst(6)) // drops "bytes "
        let components = rangePart.split(separator: "/")
        guard components.count == 2 else {
            throw BackgroundTransportError.invalidContentRange
        }

        let bounds = components[0].split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start <= end else {
            throw BackgroundTransportError.invalidContentRange
        }

        let totalStr = String(components[1])
        let total = totalStr == "*" ? nil : Int64(totalStr)

        return (start: start, end: end, total: total)
    }
}

private extension HTTPURLResponse {
    func value(forCaseInsensitiveField field: String) -> String? {
        if #available(iOS 13.0, macOS 10.15, *) {
            return value(forHTTPHeaderField: field)
        } else {
            let lower = field.lowercased()
            for (key, val) in allHeaderFields {
                if let k = key as? String, k.lowercased() == lower, let v = val as? String {
                    return v
                }
            }
            return nil
        }
    }
}

// MARK: - Crash-Safe File Handler

/// Relocates temporary files delivered by `URLSessionDownloadDelegate` safely and atomically.
public enum BackgroundDownloadFileHandler {

    /// Moves a downloaded temporary file into its durable part-file destination,
    /// atomically replacing any previous partial file and validating byte counts.
    @discardableResult
    public static func relocateTemporaryFile(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedBytes: Int64? = nil
    ) throws -> Int64 {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw BackgroundTransportError.temporaryFileMissing(path: sourceURL.path)
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Verify size before moving
        let attrs = try fileManager.attributesOfItem(atPath: sourceURL.path)
        guard let fileSize = attrs[.size] as? Int64 else {
            throw BackgroundTransportError.fileRelocationFailed(underlyingError: "Cannot determine file size")
        }

        if let expected = expectedBytes, fileSize != expected {
            try? fileManager.removeItem(at: sourceURL)
            throw BackgroundTransportError.bodyLengthMismatch(expected: expected, actual: fileSize)
        }

        // Atomic replacement or move
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            throw BackgroundTransportError.fileRelocationFailed(underlyingError: error.localizedDescription)
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
/// Design Guarantees (Milestone 6A):
/// 1. Uses `URLSessionConfiguration.background(withIdentifier:)` on Darwin.
/// 2. Maintains an atomic disk-persisted mapping between background task IDs and segment records.
/// 3. Validates HTTP 206 Partial Content, Content-Range headers, and exact byte counts.
/// 4. Synchronously moves temporary download files to durable part files before delegate returns.
/// 5. Feeds completed segment progress directly into `DownloadPersistenceStore` (no competing truth).
/// 6. Fully independent from existing foreground `SegmentDownloader` and BitTorrent engines.
public final class BackgroundDownloadSessionManager: NSObject, @unchecked Sendable {

    public let sessionIdentifier: String
    public let mappingStore: BackgroundDownloadTaskMappingStore
    public let persistenceStore: DownloadPersistenceStore?
    public let temporaryDirectoryURL: URL

    private var session: URLSession!
    private let delegateQueue: OperationQueue

    /// Optional completion handler provided by UIKit's `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public var backgroundEventsCompletionHandler: (@Sendable () -> Void)?

    /// Progress notification hook: (downloadID, segmentID, completedBytes, expectedBytes)
    public var onSegmentProgress: (@Sendable (String, Int, Int64, Int64) -> Void)?

    /// Completion notification hook: (downloadID, segmentID, partFileURL)
    public var onSegmentCompleted: (@Sendable (String, Int, URL) -> Void)?

    /// Failure notification hook: (downloadID, segmentID, error)
    public var onSegmentFailed: (@Sendable (String, Int, Error) -> Void)?

    public init(
        sessionIdentifier: String = "com.lid.downloadmanager.background-http",
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
        queue.name = "com.lid.background-http.delegate-queue"
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
        config.timeoutIntervalForResource = 86400 // 24 hours
#else
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86400
#endif
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    // MARK: - Public Scheduling API

    /// Enqueues an HTTP byte-range segment for background downloading.
    @discardableResult
    public func scheduleSegmentDownload(
        download: DownloadRecord,
        segment: SegmentRecord,
        customHeaders: [String: String]? = nil
    ) async throws -> BackgroundDownloadTaskRecord {
        let targetURL = download.resolvedURL ?? download.originalURL
        var request = URLRequest(url: targetURL)

        // Set custom headers
        if let headers = customHeaders ?? (download.headers.isEmpty ? nil : download.headers) {
            for (k, v) in headers {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }

        // Prevent gzip compression distortion
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        // Construct Range header
        let resumeOffset = segment.resumeStartOffset
        let expectedBytes = segment.endOffset - resumeOffset + 1
        guard expectedBytes > 0 else {
            // Already completed
            let existingRecord = await mappingStore.record(forDownloadID: download.id, segmentID: segment.id)
            if let existingRecord { return existingRecord }
            let completedRecord = BackgroundDownloadTaskRecord(
                taskIdentifier: -1,
                downloadID: download.id,
                segmentID: segment.id,
                originalURL: targetURL,
                startOffset: segment.startOffset,
                endOffset: segment.endOffset,
                expectedBytes: segment.length,
                destinationPartURL: partFileURL(downloadID: download.id, segmentID: segment.id),
                completedBytes: segment.length,
                isCompleted: true
            )
            try await mappingStore.save(record: completedRecord)
            return completedRecord
        }

        let rangeHeader = "bytes=\(resumeOffset)-\(segment.endOffset)"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")

        // If validator is present, add conditional headers
        if let eTag = download.eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-Range")
        } else if let lm = download.lastModified {
            request.setValue(lm, forHTTPHeaderField: "If-Range")
        }

        let task = session.downloadTask(with: request)
        let partURL = partFileURL(downloadID: download.id, segmentID: segment.id)

        let taskRecord = BackgroundDownloadTaskRecord(
            taskIdentifier: task.taskIdentifier,
            downloadID: download.id,
            segmentID: segment.id,
            originalURL: targetURL,
            startOffset: resumeOffset,
            endOffset: segment.endOffset,
            expectedBytes: expectedBytes,
            destinationPartURL: partURL,
            completedBytes: segment.completedBytes
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
        try? await mappingStore.remove(taskIdentifier: taskIdentifier)
    }

    /// Cancels all background tasks associated with a given download.
    public func cancelTasks(for downloadID: String) async {
        let records = await mappingStore.records(forDownloadID: downloadID)
        for r in records {
            let task = await findTask(withIdentifier: r.taskIdentifier)
            task?.cancel()
            try? await mappingStore.remove(taskIdentifier: r.taskIdentifier)
        }
    }

    /// Queries all active tasks for a download.
    public func activeTasks(for downloadID: String) async -> [BackgroundDownloadTaskRecord] {
        await mappingStore.records(forDownloadID: downloadID)
    }

    /// Reconciles system URLSession tasks with persisted mappings upon app launch / reactivation.
    public func reconcileActiveTasks() async throws -> BackgroundReconciliationReport {
        let allTasks = await activeSessionTasks()
        let taskIDsInSession = Set(allTasks.map { $0.taskIdentifier })
        let persistedRecords = await mappingStore.allRecords()

        var restored: [BackgroundDownloadTaskRecord] = []
        var completed: [BackgroundDownloadTaskRecord] = []
        var orphanedCount = 0

        for r in persistedRecords {
            if taskIDsInSession.contains(r.taskIdentifier) {
                // Task is actively running in system background daemon
                restored.append(r)
            } else {
                // Task is no longer running in session. Check if destination part file is complete.
                if FileManager.default.fileExists(atPath: r.destinationPartURL.path) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: r.destinationPartURL.path)
                    let size = (attrs?[.size] as? Int64) ?? 0
                    if size == r.expectedBytes {
                        try await mappingStore.markCompleted(taskIdentifier: r.taskIdentifier, finalBytes: size)
                        completed.append(r)
                        continue
                    }
                }
                // Incomplete and lost from session: record as orphaned
                orphanedCount += 1
            }
        }

        // Cancel any unrecognized tasks in session not in our mapping store
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

    public func partFileURL(downloadID: String, segmentID: Int) -> URL {
        temporaryDirectoryURL
            .appendingPathComponent("\(downloadID)_segment-\(segmentID).part")
    }

    private func findTask(withIdentifier id: Int) async -> URLSessionTask? {
        let tasks = await activeSessionTasks()
        return tasks.first { $0.taskIdentifier == id }
    }

    private func activeSessionTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate Conformance

extension BackgroundDownloadSessionManager: URLSessionDownloadDelegate {

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier

        Task { [weak self] in
            guard let self = self else { return }
            guard let record = await self.mappingStore.record(forTaskIdentifier: taskID) else { return }

            try? await self.mappingStore.updateProgress(taskIdentifier: taskID, completedBytes: totalBytesWritten)

            // Feed directly into persistence store without creating competing state
            if let persistence = self.persistenceStore {
                _ = try? await persistence.updateSegmentProgress(
                    tag: record.downloadID,
                    segmentID: record.segmentID,
                    completedBytes: record.startOffset + totalBytesWritten
                )
            }

            self.onSegmentProgress?(record.downloadID, record.segmentID, totalBytesWritten, record.expectedBytes)
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        let response = downloadTask.response

        // Parse task description (immutable constants)
        guard let desc = downloadTask.taskDescription,
              let parsed = BackgroundDownloadTaskRecord.parseSystemTaskDescription(desc) else {
            print("[BackgroundDownloadSessionManager] Warning: missing or unparseable taskDescription on finished task \(taskID)")
            return
        }

        let downloadID = parsed.downloadID
        let segmentID = parsed.segmentID
        let destination = self.partFileURL(downloadID: downloadID, segmentID: segmentID)

        // 1. Relocate file immediately to destination before iOS removes `location`
        do {
            try BackgroundDownloadFileHandler.relocateTemporaryFile(from: location, to: destination)
        } catch {
            print("[BackgroundDownloadSessionManager] Error relocating temporary download file: \(error)")
            Task { [weak self] in
                guard let self = self else { return }
                try? await self.mappingStore.markFailed(taskIdentifier: taskID, error: error.localizedDescription)
                self.onSegmentFailed?(downloadID, segmentID, error)
            }
            return
        }

        // 2. Validate response, verify expected size, and update stores asynchronously
        Task { [weak self] in
            guard let self = self else { return }
            let record = await self.mappingStore.record(forTaskIdentifier: taskID)

            // Validate response headers if available
            if let resp = response, let rec = record {
                do {
                    try BackgroundResponseValidator.validate(
                        response: resp,
                        expectedStart: rec.startOffset,
                        expectedEnd: rec.endOffset
                    )
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    try? await self.mappingStore.markFailed(taskIdentifier: taskID, error: error.localizedDescription)
                    self.onSegmentFailed?(downloadID, segmentID, error)
                    return
                }
            }

            // Verify actual file size on disk against expected bytes
            let finalSize: Int64
            if let rec = record {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
                      let size = attrs[.size] as? Int64,
                      size == rec.expectedBytes else {
                    let actualSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
                    let err = BackgroundTransportError.bodyLengthMismatch(expected: rec.expectedBytes, actual: actualSize)
                    try? FileManager.default.removeItem(at: destination)
                    try? await self.mappingStore.markFailed(taskIdentifier: taskID, error: err.localizedDescription)
                    self.onSegmentFailed?(downloadID, segmentID, err)
                    return
                }
                finalSize = size
            } else {
                let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
                finalSize = (attrs?[.size] as? Int64) ?? 0
            }

            try? await self.mappingStore.markCompleted(taskIdentifier: taskID, finalBytes: finalSize)

            if let persistence = self.persistenceStore {
                _ = try? await persistence.updateSegmentProgress(
                    tag: downloadID,
                    segmentID: segmentID,
                    completedBytes: finalSize
                )
            }

            self.onSegmentCompleted?(downloadID, segmentID, destination)
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = task.taskIdentifier
        guard let error = error else { return }

        Task { [weak self] in
            guard let self = self else { return }
            if let rec = await self.mappingStore.record(forTaskIdentifier: taskID) {
                try? await self.mappingStore.markFailed(taskIdentifier: taskID, error: error.localizedDescription)
                self.onSegmentFailed?(rec.downloadID, rec.segmentID, error)
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.backgroundEventsCompletionHandler?()
            self.backgroundEventsCompletionHandler = nil
        }
    }
}
