import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

extension DownloadCoordinator {
    // MARK: - Recovery & Reconciliation

    /// Reconciles system background tasks with persisted manifests and on-disk part files.
    public func reconcileBackgroundTransfers() async throws -> BackgroundReconciliationReport {
        guard let bgManager = self.backgroundSessionManager else {
            return BackgroundReconciliationReport(
                activeTasksCount: 0,
                orphanedTasksCount: 0,
                restoredRecords: [],
                completedRecords: []
            )
        }

        let report = try await bgManager.reconcileActiveTasks()
        let allRecords = try await persistenceStore.fetchAll()

        for record in allRecords where record.transportPolicy == .background && record.state == .downloading {
            var allSegmentsFinished = true
            let sortedSegments = record.segments.sorted { $0.id < $1.id }
            for seg in sortedSegments {
                let partURL = bgManager.partFileURL(downloadID: record.id, segmentID: seg.id)
                let exists = FileManager.default.fileExists(atPath: partURL.path)
                let size = FileManager.default.fileSize(atPath: partURL.path) ?? 0
                if !exists || size != seg.length {
                    allSegmentsFinished = false
                    break
                }
            }

            if allSegmentsFinished && !sortedSegments.isEmpty {
                let partURLs = sortedSegments.map { bgManager.partFileURL(downloadID: record.id, segmentID: $0.id) }
                do {
                    try DownloadFileWriter.mergeFiles(
                        partURLs: partURLs,
                        destinationURL: record.destinationURL,
                        expectedMergedSize: record.totalSize
                    )
                    for partURL in partURLs {
                        do {
                            try FileManager.default.removeItem(at: partURL)
                        } catch {
                            PipelineLogger.shared.log(stage: .coordinator, message: "Recovery failed to remove part file \(partURL.path): \(error)")
                        }
                    }
                    for seg in sortedSegments {
                        do {
                            _ = try await persistenceStore.updateSegmentProgress(tag: record.id, segmentID: seg.id, completedBytes: seg.length)
                        } catch {
                            PipelineLogger.shared.log(stage: .coordinator, message: "Recovery failed to update segment progress for \(record.id) seg \(seg.id): \(error)")
                        }
                    }
                    try await persistenceStore.updateState(tag: record.id, state: .completed)
                    let filename = record.suggestedFilename ?? record.destinationURL.lastPathComponent
                    DownloadNotificationManager.postDownloadCompletedNotification(filename: filename, downloadID: record.id)
                } catch {
                    PipelineLogger.shared.log(stage: .coordinator, message: "[DownloadCoordinator] Recovery merge deferred for \(record.id): \(error)")
                }
            }
        }

        return report
    }

    // MARK: - Helpers

    nonisolated static func isRangeIgnored(_ error: Error) -> Bool {
        if let segError = error as? SegmentDownloaderError,
           case .unexpectedStatus(let expected, let actual) = segError {
            return expected == 206 && actual == 200
        }
        return false
    }

    func mergeValidatorHeaders(
        original: [String: String],
        eTag: String?,
        lastModified: String?
    ) -> [String: String] {
        var result = original
        if let validator = DownloadRequestEnricher.ifRangeValidator(eTag: eTag, lastModified: lastModified) {
            result["If-Range"] = validator
        }
        return result
    }

    nonisolated static func validateSegmentLayout(_ segments: [DownloadSegment], totalSize: Int64) throws {
        guard !segments.isEmpty else {
            throw DownloadCoordinatorError.segmentLayoutInvalid(reason: "Segments list is empty")
        }
        guard segments[0].startOffset == 0 else {
            throw DownloadCoordinatorError.segmentLayoutInvalid(reason: "First segment does not start at byte 0")
        }
        guard let lastSegment = segments.last, lastSegment.endOffset == totalSize - 1 else {
            throw DownloadCoordinatorError.segmentLayoutInvalid(reason: "Last segment does not end at totalSize - 1")
        }
        for i in 1..<segments.count {
            if segments[i].startOffset != segments[i - 1].endOffset + 1 {
                throw DownloadCoordinatorError.segmentLayoutInvalid(
                    reason: "Segment gap or overlap detected between \(segments[i-1].id) and \(segments[i].id)"
                )
            }
        }
        let sumLength = segments.reduce(0) { $0 + $1.length }
        guard sumLength == totalSize else {
            throw DownloadCoordinatorError.segmentLayoutInvalid(
                reason: "Sum of segment lengths (\(sumLength)) does not equal totalSize (\(totalSize))"
            )
        }
    }

    func updateProgress(
        downloadID: String,
        state: DownloadState,
        bytesReceived: Int64,
        totalBytes: Int64?,
        completedSegments: Int,
        totalSegments: Int,
        currentSpeed: Double = 0,
        averageSpeed: Double = 0,
        elapsedTime: TimeInterval = 0,
        eta: TimeInterval? = nil,
        checksumOutcome: ChecksumOutcome? = nil,
        handler: ProgressHandler?
    ) {
        let outcome = checksumOutcome ?? checksumOutcomes[downloadID] ?? .notChecked
        let snapshot = CoordinatorProgress(
            downloadID: downloadID,
            state: state,
            bytesReceived: bytesReceived,
            totalBytes: totalBytes,
            completedSegments: completedSegments,
            totalSegments: totalSegments,
            currentBytesPerSecond: currentSpeed,
            averageBytesPerSecond: averageSpeed,
            elapsedTime: elapsedTime,
            estimatedTimeRemaining: eta,
            checksumOutcome: outcome
        )
        progressByID[downloadID] = snapshot
        handler?(snapshot)
    }

    // MARK: - Disk Reconciliation

    /// Reconciles the partial destination file on disk with persisted segment metadata before resumption.
    /// Ensures the partial file, persisted byte offset, and subsequent HTTP Range request all agree.
    public static func reconcilePartialFile(
        destinationURL: URL,
        record: DownloadRecord,
        backgroundSessionManager: BackgroundDownloadSessionManager? = nil
    ) -> DownloadRecord {
        var reconciled = record
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard let fileSize = fileManager.fileSize(atPath: destinationURL.path) else {
                return reconciled
            }

            if record.storageMode == .directSeek {
                // Direct seek files are preallocated to totalSize
                let total = record.totalSize
                if total > 0 {
                    if fileSize < total {
                        // File on disk is smaller than expected totalSize: re-truncate or reset
                        do {
                            let handle = try FileHandle(forWritingTo: destinationURL)
                            do {
                                try handle.truncate(atOffset: UInt64(total))
                            } catch {
                                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to truncate destinationURL \(destinationURL.path) to \(total): \(error)")
                            }
                            do {
                                try handle.close()
                            } catch {
                                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to close handle for \(destinationURL.path): \(error)")
                            }
                        } catch {
                            PipelineLogger.shared.log(stage: .coordinator, message: "Failed to open FileHandle for truncation: \(error)")
                            reconciled.segments = record.segments.map { seg in
                                var s = seg
                                s.completedBytes = 0
                                return s
                            }
                        }
                    }
                }
            } else {
                // Non-directSeek mode with existing destination file (e.g. linear single-stream mode)
                let savedCompleted = record.completedBytes
                if fileSize > savedCompleted {
                    // File contains more data than saved checkpoint (e.g. 90 MB on disk vs 25 MB checkpointed)
                    // Truncate to saved checkpoint so subsequent HTTP Range request and disk file align perfectly
                    do {
                        let handle = try FileHandle(forWritingTo: destinationURL)
                        do {
                            try handle.truncate(atOffset: UInt64(savedCompleted))
                        } catch {
                            PipelineLogger.shared.log(stage: .coordinator, message: "Failed to truncate destinationURL \(destinationURL.path) to \(savedCompleted): \(error)")
                        }
                        do {
                            try handle.close()
                        } catch {
                            PipelineLogger.shared.log(stage: .coordinator, message: "Failed to close handle for \(destinationURL.path): \(error)")
                        }
                    } catch {
                        PipelineLogger.shared.log(stage: .coordinator, message: "Failed to open FileHandle for truncation: \(error)")
                    }
                } else if fileSize < savedCompleted {
                    // Disk file has fewer bytes than checkpoint: clamp completedBytes to actual disk size
                    if !reconciled.segments.isEmpty {
                        reconciled.segments[0].completedBytes = max(0, fileSize)
                    }
                }
            }
            return reconciled
        }

        // Destination file does not exist on disk:
        if record.storageMode == .partFiles || record.transportPolicy == .background {
            // For .partFiles or .background transport, progress is stored in individual segment part files.
            // The final destination file does not exist until merge at completion.
            reconciled.segments = record.segments.map { seg in
                var s = seg
                let partURL: URL = {
                    if let bg = backgroundSessionManager {
                        return bg.partFileURL(downloadID: record.id, segmentID: seg.id)
                    } else {
                        return destinationURL.deletingPathExtension().appendingPathExtension("part\(seg.id)")
                    }
                }()

                guard fileManager.fileExists(atPath: partURL.path),
                      let fileSize = fileManager.fileSize(atPath: partURL.path) else {
                    s.completedBytes = 0
                    return s
                }

                if fileSize == seg.length {
                    s.completedBytes = seg.length
                } else if fileSize > 0 && fileSize < seg.length {
                    s.completedBytes = fileSize
                } else {
                    // Invalid or corrupted size (e.g. exceeds segment length): purge corrupted file
                    do {
                        try fileManager.removeItem(at: partURL)
                    } catch {
                        PipelineLogger.shared.log(stage: .coordinator, message: "Failed to remove corrupted part file \(partURL.path): \(error)")
                    }
                    s.completedBytes = 0
                }
                return s
            }
            return reconciled
        }

        // Destination file is missing for directSeek: reset all segments to byte 0
        reconciled.segments = record.segments.map { seg in
            var s = seg
            s.completedBytes = 0
            return s
        }
        return reconciled
    }
}


/// Redirect delegate used by exact ranged resource transfers. It preserves the
/// coordinator's existing origin rule even though the transfer is issued as a
/// single URLSession request rather than through SegmentDownloader.
final class DownloadResourceRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let originalURL: URL
    private let headers: [String: String]
    private let allowedOrigins: Set<String>

    init(originalURL: URL, headers: [String: String], allowedOrigins: Set<String> = []) {
        self.originalURL = originalURL
        self.headers = headers
        self.allowedOrigins = allowedOrigins
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let redirected = DownloadRequestEnricher.handleRedirect(
            task: task,
            response: response,
            newRequest: request,
            allowedOrigins: allowedOrigins
        )
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let host = space.host

        if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
           space.authenticationMethod == NSURLAuthenticationMethodDefault ||
           space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            if let saved = KeychainManager.shared.getInternetPassword(server: host, path: "/") {
                completionHandler(.useCredential, URLCredential(user: saved.username, password: saved.password, persistence: .none))
                return
            }
            if let provider = DownloadCoordinator.basicAuthChallengeHandler {
                Task {
                    if let cred = await provider(host, space.realm ?? "") {
                        KeychainManager.shared.storeInternetPassword(
                            username: cred.username,
                            password: cred.password,
                            server: host
                        )
                        completionHandler(.useCredential, URLCredential(user: cred.username, password: cred.password, persistence: .none))
                    } else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                    }
                }
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

/// Standard, zero-dependency SHA-256 implementation ensuring portable digest validation across all platforms.
public enum EngineSHA256 {
    public static func hash(data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]

        var bytes = Array(data)
        let bitLength = UInt64(data.count) * 8
        bytes.append(0x80)
        while (bytes.count % 64) != 56 {
            bytes.append(0x00)
        }
        for i in (0..<8).reversed() {
            bytes.append(UInt8((bitLength >> (i * 8)) & 0xff))
        }

        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let idx = chunkStart + i * 4
                w[i] = (UInt32(bytes[idx]) << 24) |
                       (UInt32(bytes[idx + 1]) << 16) |
                       (UInt32(bytes[idx + 2]) << 8) |
                       UInt32(bytes[idx + 3])
            }
            for i in 16..<64 {
                let s0 = (w[i-15] >> 7 | w[i-15] << 25) ^ (w[i-15] >> 18 | w[i-15] << 14) ^ (w[i-15] >> 3)
                let s1 = (w[i-2] >> 17 | w[i-2] << 15) ^ (w[i-2] >> 19 | w[i-2] << 13) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hVal = h[7]
            for i in 0..<64 {
                let s1 = (e >> 6 | e << 26) ^ (e >> 11 | e << 21) ^ (e >> 25 | e << 7)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hVal &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = (a >> 2 | a << 30) ^ (a >> 13 | a << 19) ^ (a >> 22 | a << 10)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hVal = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hVal
        }

        return h.map { String(format: "%08x", $0) }.joined()
        #endif
    }
}

// MARK: - Streaming File Hasher
#if canImport(CryptoKit)
public enum FileHasher {
    public static func sha256(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try fileHandle.close()
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to close fileHandle in sha256: \(error)")
            }
        }
        let totalSize: Int64 = FileManager.default.fileSize(atPath: url.path) ?? 0
        var hasher = SHA256()
        let bufferSize = 256 * 1024
        var processed: Int64 = 0

        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if totalSize > 0, let progress = progress {
                let frac = min(1.0, max(0.0, Double(processed) / Double(totalSize)))
                progress(frac)
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func computeSHA256(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try fileHandle.close()
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to close fileHandle in sha256: \(error)")
            }
        }
        let totalSize: Int64 = FileManager.default.fileSize(atPath: url.path) ?? 0
        var hasher = SHA256()
        let bufferSize = 256 * 1024
        var processed: Int64 = 0

        while true {
            try Task.checkCancellation()
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if totalSize > 0, let progress = progress {
                let frac = min(1.0, max(0.0, Double(processed) / Double(totalSize)))
                progress(frac)
            }
            await Task.yield()
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#else
public enum FileHasher {
    public static func sha256(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try fileHandle.close()
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to close fileHandle in sha256: \(error)")
            }
        }
        let totalSize: Int64 = FileManager.default.fileSize(atPath: url.path) ?? 0
        var hasher = EngineSHA256Hasher()
        let bufferSize = 256 * 1024
        var processed: Int64 = 0

        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if totalSize > 0, let progress = progress {
                let frac = min(1.0, max(0.0, Double(processed) / Double(totalSize)))
                progress(frac)
            }
        }
        return hasher.finalize()
    }

    public static func computeSHA256(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try fileHandle.close()
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to close fileHandle in sha256: \(error)")
            }
        }
        let totalSize: Int64 = FileManager.default.fileSize(atPath: url.path) ?? 0
        var hasher = EngineSHA256Hasher()
        let bufferSize = 256 * 1024
        var processed: Int64 = 0

        while true {
            try Task.checkCancellation()
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if totalSize > 0, let progress = progress {
                let frac = min(1.0, max(0.0, Double(processed) / Double(totalSize)))
                progress(frac)
            }
            await Task.yield()
        }
        return hasher.finalize()
    }
}
#endif
