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


