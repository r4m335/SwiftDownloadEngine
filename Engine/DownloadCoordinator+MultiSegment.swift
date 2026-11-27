import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

extension DownloadCoordinator {
    // MARK: - Multi-Segment Download

    func runMultiSegmentDownload(
        request: DownloadRequest,
        probeResult: HTTPRangeProbeResult,
        existingRecord: DownloadRecord?,
        progress handler: ProgressHandler?,
        earliestBeginDate: Date? = nil
    ) async throws {
        try await waitUntilScheduledStart(earliestBeginDate)
        guard let totalSize = probeResult.totalSize, totalSize > 0 else {
            throw DownloadCoordinatorError.invalidRequest(reason: "Invalid file size for ranged download")
        }

        // 1. Allocate segments or restore existing boundaries
        let segments: [DownloadSegment]
        let initialCompletedMap: [Int: Int64]

        if let existingRecord, !existingRecord.segments.isEmpty {
            segments = existingRecord.segments.map { $0.toDownloadSegment() }
            initialCompletedMap = Dictionary(uniqueKeysWithValues: existingRecord.segments.map { ($0.id, $0.completedBytes) })
        } else {
            segments = try SegmentAllocator.makeSegments(
                totalSize: totalSize,
                configuredThreadCount: request.configuredThreadCount,
                advancedMode: request.advancedMode
            )
            initialCompletedMap = [:]
        }

        // Validate segment layout: contiguous boundaries covering 0..<totalSize with no gaps/overlaps
        try Self.validateSegmentLayout(segments, totalSize: totalSize)

        // 2. Prepare persistent record
        let segmentRecords = segments.map { segment in
            SegmentRecord(segment: segment, completedBytes: initialCompletedMap[segment.id] ?? 0)
        }
        let currentRecord = DownloadRecord(
            id: request.id,
            originalURL: request.url,
            resolvedURL: probeResult.finalURL,
            destinationURL: request.destinationURL,
            totalSize: totalSize,
            state: .downloading,
            storageMode: request.storageMode,
            eTag: probeResult.eTag,
            lastModified: probeResult.lastModified,
            suggestedFilename: probeResult.suggestedFilename,
            mimeType: probeResult.mimeType,
            headers: headersForPersistence(request),
            segments: segmentRecords
        )
        try await persistenceStore.save(currentRecord)

        // 3. Initialize file writer
        let writer = try DownloadFileWriter(
            destinationURL: request.destinationURL,
            totalSize: totalSize,
            mode: request.storageMode
        )
        defer {
            Task {
                do {
                    try await writer.close()
                } catch {
                    PipelineLogger.shared.log(stage: .coordinator, message: "Error closing writer: \(error)")
                }
            }
        }

        // 4. Adaptive work queue, progress tracker & limiters
        // Keep the persisted segment count stable, while splitting large
        // unfinished ranges into transient child work items. A worker that
        // finishes early can claim the remaining half of a slower parent.
        let workerCount = max(
            1,
            min(
                segments.count,
                request.maxConcurrentRequests
                    ?? (request.configuredThreadCount > 0
                        ? request.configuredThreadCount
                        : SegmentAllocator.defaultThreadCount)
            )
        )
        let workQueue = AdaptiveSegmentWorkQueue(
            segments: segments,
            completedBytes: initialCompletedMap
        )
        let progressAccumulator = AdaptiveSegmentProgressAccumulator(
            segments: segments,
            initialCompletedBytes: initialCompletedMap
        )
        let initialSnapshot = await progressAccumulator.snapshot()

        let perDownloadLimiter = perDownloadLimiters[request.id]
        let speedTracker = speedTrackers[request.id] ?? DownloadSpeedTracker()
        speedTrackers[request.id] = speedTracker

        updateProgress(
            downloadID: request.id,
            state: .downloading,
            bytesReceived: initialSnapshot.bytesReceived,
            totalBytes: totalSize,
            completedSegments: initialSnapshot.completedSegments,
            totalSegments: segments.count,
            handler: handler
        )

        // 5. Worker downloader
        let downloader = SegmentDownloader(
            session: session,
            writer: writer,
            requestBudget: requestBudget,
            globalBandwidthLimiter: globalBandwidthLimiter,
            perDownloadBandwidthLimiter: perDownloadLimiter,
            speedTracker: speedTracker,
            downloadID: request.id,
            maxConcurrentRequests: request.maxConcurrentRequests
        )

        // 6. Structured concurrent execution with adaptive work stealing
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for workerID in 0..<workerCount {
                    group.addTask {
                        while let workItem = await workQueue.next(workerID: workerID) {
                            await progressAccumulator.register(workItem)
                            var attempt = 0
                            while true {
                                try Task.checkCancellation()
                                if !Self.isLoopbackURL(request.url) {
                                    try await self.connectivityGate.waitUntilAvailable(
                                        networkPolicy: request.networkPolicy
                                    )
                                }
                                let effectiveHeaders = await self.getDynamicHeaders(for: request.id, baseHeaders: request.headers)
                                do {
                                    try await downloader.download(
                                        url: probeResult.finalURL,
                                        segment: workItem.downloadSegment,
                                        completedBytes: 0,
                                        expectedTotalSize: totalSize,
                                        headers: self.mergeValidatorHeaders(
                                            original: effectiveHeaders,
                                            eTag: probeResult.eTag,
                                            lastModified: probeResult.lastModified
                                        ),
                                        eTag: probeResult.eTag,
                                        networkPolicy: request.networkPolicy,
                                        progress: { snapshot in
                                            Task {
                                                let agg = await progressAccumulator.update(
                                                    workItemID: workItem.id,
                                                    completedBytes: snapshot.bytesReceived
                                                )
                                                let parentBytes = await progressAccumulator.parentCompletedBytes(
                                                    workItem.parentSegmentID
                                                )
                                                let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                                                await self.updateProgress(
                                                    downloadID: request.id,
                                                    state: .downloading,
                                                    bytesReceived: agg.bytesReceived,
                                                    totalBytes: totalSize,
                                                    completedSegments: agg.completedSegments,
                                                    totalSegments: segments.count,
                                                    currentSpeed: metrics.currentBytesPerSecond,
                                                    averageSpeed: metrics.averageBytesPerSecond,
                                                    elapsedTime: metrics.elapsedTime,
                                                    eta: metrics.estimatedTimeRemaining,
                                                    handler: handler
                                                )

                                                let needsCheckpoint = await progressAccumulator.shouldCheckpoint(
                                                    segmentID: workItem.parentSegmentID,
                                                    completedBytes: parentBytes
                                                )
                                                if needsCheckpoint {
                                                    do {
                                                        try await writer.synchronize()
                                                        _ = try await self.persistenceStore.updateSegmentProgress(
                                                            tag: request.id,
                                                            segmentID: workItem.parentSegmentID,
                                                            completedBytes: parentBytes
                                                        )
                                                    } catch {
                                                        PipelineLogger.shared.log("[DownloadCoordinator] Intermediate checkpoint failed for \(request.id) segment \(workItem.parentSegmentID): \(error.localizedDescription)")
                                                    }
                                                }
                                            }
                                        }
                                    )
                                    break
                                } catch {
                                    await progressAccumulator.discard(workItemID: workItem.id)
                                    if Task.isCancelled {
                                        throw CancellationError()
                                    }
                                    if case SegmentDownloaderError.tokenExpired = error {
                                        if attempt < request.retryCount,
                                           let _ = await self.attemptCredentialRefresh(for: probeResult.finalURL, downloadID: request.id) {
                                            attempt += 1
                                            PipelineLogger.shared.log("[DownloadCoordinator] Retrying segment after token refresh for \(request.id)")
                                            continue
                                        }
                                        throw DownloadCoordinatorError.tokenExpired(url: request.url)
                                    }
                                    if case SegmentDownloaderError.accessDenied = error {
                                        if attempt < request.retryCount,
                                           let _ = await self.attemptCredentialRefresh(for: probeResult.finalURL, downloadID: request.id) {
                                            attempt += 1
                                            PipelineLogger.shared.log("[DownloadCoordinator] Retrying segment after credential refresh for \(request.id)")
                                            continue
                                        }
                                        let cooldown = Date().addingTimeInterval(300)
                                        throw DownloadCoordinatorError.accessDenied(url: request.url, cooldownUntil: cooldown)
                                    }
                                    if case SegmentDownloaderError.linkExpired = error {
                                        throw DownloadCoordinatorError.linkExpired(url: request.url)
                                    }
                                    if Self.isRangeIgnored(error) {
                                        throw error // Fail-fast to trigger fallback
                                    }
                                    guard HTTPRetryPolicy.isRetryable(error) else {
                                        throw error
                                    }
                                    if HTTPRetryPolicy.shouldWaitForConnectivity(error) && !Self.isLoopbackURL(request.url) {
                                        try await self.connectivityGate.waitUntilAvailable(
                                            networkPolicy: request.networkPolicy
                                        )
                                        continue
                                    }
                                    if attempt >= request.retryCount {
                                        if case SegmentDownloaderError.rateLimited(let retryAfter) = error {
                                            throw DownloadCoordinatorError.rateLimited(url: request.url, retryAfter: retryAfter)
                                        }
                                        throw error
                                    }
                                    attempt += 1
                                    let delaySeconds: Double
                                    if case SegmentDownloaderError.rateLimited(let retryAfter) = error, let sec = retryAfter {
                                        delaySeconds = min(60.0, max(1.0, sec))
                                    } else if case SegmentDownloaderError.rateLimited = error {
                                        delaySeconds = min(30.0, 1.0 * pow(2.0, Double(attempt)))
                                    } else {
                                        delaySeconds = min(15.0, 0.25 * Double(attempt))
                                    }
                                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                                }
                            }

                            let aggregate = await progressAccumulator.complete(workItem)
                            await workQueue.complete(workerID: workerID, workItemID: workItem.id)
                            let parentBytes = await progressAccumulator.parentCompletedBytes(workItem.parentSegmentID)
                            do {
                                try await writer.synchronize()
                                _ = try await self.persistenceStore.updateSegmentProgress(
                                    tag: request.id,
                                    segmentID: workItem.parentSegmentID,
                                    completedBytes: parentBytes
                                )
                            } catch {
                                PipelineLogger.shared.log("[DownloadCoordinator] Work item completion checkpoint failed for \(request.id) segment \(workItem.parentSegmentID): \(error.localizedDescription)")
                            }

                            let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                            await self.updateProgress(
                                downloadID: request.id,
                                state: .downloading,
                                bytesReceived: aggregate.bytesReceived,
                                totalBytes: totalSize,
                                completedSegments: aggregate.completedSegments,
                                totalSegments: segments.count,
                                currentSpeed: metrics.currentBytesPerSecond,
                                averageSpeed: metrics.averageBytesPerSecond,
                                elapsedTime: metrics.elapsedTime,
                                eta: metrics.estimatedTimeRemaining,
                                handler: handler
                            )
                        }
                    }
                }

                try await group.waitForAll()
            }
            if pauseRequested.contains(request.id) || Task.isCancelled {
                // Ensure writer buffers are flushed to disk before recording checkpoint
                var syncSucceeded = false
                do {
                    try await writer.synchronize()
                    syncSucceeded = true
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Writer synchronize failed on pause for \(request.id): \(error.localizedDescription). Segment checkpoints will not be advanced to uncommitted in-memory offsets.")
                }

                if syncSucceeded {
                    let completedMap = await progressAccumulator.getCompletedBytes()
                    for (segID, bytes) in completedMap {
                        do {
                            _ = try await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: segID, completedBytes: bytes)
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Failed to persist segment \(segID) progress on pause for \(request.id): \(error.localizedDescription)")
                        }
                    }
                }

                do {
                    _ = try await persistenceStore.updateState(tag: request.id, state: .paused)
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Failed to persist paused state for \(request.id): \(error.localizedDescription)")
                }
                let snap = await progressAccumulator.snapshot()
                let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                updateProgress(
                    downloadID: request.id,
                    state: .paused,
                    bytesReceived: snap.bytesReceived,
                    totalBytes: totalSize,
                    completedSegments: snap.completedSegments,
                    totalSegments: segments.count,
                    currentSpeed: 0,
                    averageSpeed: metrics.averageBytesPerSecond,
                    elapsedTime: metrics.elapsedTime,
                    eta: nil,
                    handler: handler
                )
                throw CancellationError()
            }
        } catch let error {
            if pauseRequested.contains(request.id) || Task.isCancelled {
                var syncSucceeded = false
                do {
                    try await writer.synchronize()
                    syncSucceeded = true
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Writer synchronize failed on pause for \(request.id): \(error.localizedDescription). Segment checkpoints will not be advanced to uncommitted in-memory offsets.")
                }

                if syncSucceeded {
                    let completedMap = await progressAccumulator.getCompletedBytes()
                    for (segID, bytes) in completedMap {
                        do {
                            _ = try await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: segID, completedBytes: bytes)
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Failed to persist segment \(segID) progress on pause for \(request.id): \(error.localizedDescription)")
                        }
                    }
                }
                do {
                    _ = try await persistenceStore.updateState(tag: request.id, state: .paused)
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Failed to persist paused state for \(request.id): \(error.localizedDescription)")
                }
                let snap = await progressAccumulator.snapshot()
                let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                updateProgress(
                    downloadID: request.id,
                    state: .paused,
                    bytesReceived: snap.bytesReceived,
                    totalBytes: totalSize,
                    completedSegments: snap.completedSegments,
                    totalSegments: segments.count,
                    currentSpeed: 0,
                    averageSpeed: metrics.averageBytesPerSecond,
                    elapsedTime: metrics.elapsedTime,
                    eta: nil,
                    handler: handler
                )
                throw CancellationError()
            }
            if !Self.isRangeIgnored(error) {
                var syncSucceeded = false
                do {
                    try await writer.synchronize()
                    syncSucceeded = true
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Writer synchronize failed on error for \(request.id): \(error.localizedDescription). Segment checkpoints will not be advanced.")
                }

                if syncSucceeded {
                    let completedMap = await progressAccumulator.getCompletedBytes()
                    for (segID, bytes) in completedMap {
                        do {
                            _ = try await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: segID, completedBytes: bytes)
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Failed to persist segment \(segID) progress on error for \(request.id): \(error.localizedDescription)")
                        }
                    }
                }
                do {
                    _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Failed to persist failed state for \(request.id): \(error.localizedDescription)")
                }
                let snap = await progressAccumulator.snapshot()
                let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                updateProgress(
                    downloadID: request.id,
                    state: .failed(reason: error.localizedDescription),
                    bytesReceived: snap.bytesReceived,
                    totalBytes: totalSize,
                    completedSegments: snap.completedSegments,
                    totalSegments: segments.count,
                    currentSpeed: 0,
                    averageSpeed: metrics.averageBytesPerSecond,
                    elapsedTime: metrics.elapsedTime,
                    eta: nil,
                    handler: handler
                )
            }
            throw error
        }

        // 7. Flush and close writer
        try await writer.synchronize()
        try await writer.close()

        // 8. MANDATORY INVARIANT: Physical file validation before marking completed
        let diskAttributes = try FileManager.default.attributesOfItem(atPath: request.destinationURL.path)
        let actualDiskSize = (diskAttributes[.size] as? NSNumber)?.int64Value ?? (diskAttributes[.size] as? Int64)
        guard let actualDiskSize, actualDiskSize == totalSize else {
            let error = SegmentDownloaderError.bodyLengthMismatch(
                expected: totalSize,
                actual: actualDiskSize ?? -1
            )
            do {
                _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            } catch let stateErr {
                PipelineLogger.shared.log("[DownloadCoordinator] Failed updating persistence state to .failed for \(request.id): \(stateErr.localizedDescription)")
            }
            throw error
        }

        // 9. MANDATORY INVARIANT: Verify all segments completed in persistence store
        let finalCompletedMap = await progressAccumulator.getCompletedBytes()
        for (segID, bytes) in finalCompletedMap {
            do {
                _ = try await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: segID, completedBytes: bytes)
            } catch let progErr {
                PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to persist segment \(segID) progress for \(request.id): \(progErr.localizedDescription)")
            }
        }

        guard let finalRecord = try await persistenceStore.fetch(tag: request.id),
              finalRecord.isAllSegmentsCompleted else {
            let error = DownloadCoordinatorError.segmentLayoutInvalid(reason: "Not all segments reported completed")
            do {
                _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            } catch let stateErr {
                PipelineLogger.shared.log("[DownloadCoordinator] Failed updating persistence state to .failed for \(request.id): \(stateErr.localizedDescription)")
            }
            throw error
        }

        // 10. Checksum validation (if provided)
        if let expectedSHA = request.expectedSHA256, !expectedSHA.isEmpty {
            let actualSHA = try FileHasher.sha256(for: request.destinationURL)
            guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
                checksumOutcomes[request.id] = .mismatch(expected: expectedSHA, actual: actualSHA)
                let error = DownloadCoordinatorError.checksumMismatch(expected: expectedSHA, actual: actualSHA)
                do {
                    _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                } catch let stateErr {
                    PipelineLogger.shared.log("[DownloadCoordinator] Failed updating persistence state to .failed for \(request.id): \(stateErr.localizedDescription)")
                }
                throw error
            }
            checksumOutcomes[request.id] = .verified(sha256: actualSHA)
        } else {
            checksumOutcomes[request.id] = .notChecked
        }

        // 11. Finalize completed status
        try await persistenceStore.updateState(tag: request.id, state: .completed)
        let completedFilename = request.destinationURL.lastPathComponent
        DownloadNotificationManager.postDownloadCompletedNotification(filename: completedFilename, downloadID: request.id)
        let finalMetrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
        updateProgress(
            downloadID: request.id,
            state: .completed,
            bytesReceived: totalSize,
            totalBytes: totalSize,
            completedSegments: segments.count,
            totalSegments: segments.count,
            currentSpeed: 0,
            averageSpeed: finalMetrics.averageBytesPerSecond,
            elapsedTime: finalMetrics.elapsedTime,
            eta: 0,
            checksumOutcome: checksumOutcomes[request.id],
            handler: handler
        )
    }


    // MARK: - Multi-Segment Background Download

    enum BackgroundEvent: Sendable {
        case progress(segmentID: Int, completedBytes: Int64, totalBytes: Int64)
        case completed(segmentID: Int, partURL: URL)
        case failed(segmentID: Int, failure: BackgroundFailure)
    }

    struct BackgroundFailure: Sendable {
        let reason: String
        let retryable: Bool
        let statusCode: Int?
    }

    private nonisolated static func classifyBackgroundFailure(_ error: Error) -> BackgroundFailure {
        let status = HTTPRetryPolicy.backgroundHTTPStatusCode(error)
        let retryable: Bool
        if let status {
            if status == 429 || (500...599).contains(status) {
                retryable = true
            } else if (400...499).contains(status) {
                retryable = false
            } else {
                retryable = HTTPRetryPolicy.isRetryableBackground(error)
            }
        } else {
            retryable = HTTPRetryPolicy.isRetryableBackground(error)
        }
        return BackgroundFailure(
            reason: error.localizedDescription,
            retryable: retryable,
            statusCode: status
        )
    }

    private nonisolated static func terminalBackgroundError(
        request: DownloadRequest,
        failure: BackgroundFailure
    ) -> DownloadCoordinatorError {
        switch failure.statusCode {
        case 401:
            return .unauthorized(url: request.url)
        case 403:
            return .forbidden(url: request.url)
        case 404, 410:
            return .linkExpired(url: request.url)
        default:
            return .unexpectedSingleStreamError(reason: failure.reason)
        }
    }

    /// Converts a partially written direct-seek record into the part-file
    /// representation required by background URLSession tasks. This keeps the
    /// handoff lossless for already checkpointed bytes without changing the
    /// persisted record schema.
    func prepareExistingRecordForBackground(
        _ record: DownloadRecord?,
        backgroundManager: BackgroundDownloadSessionManager
    ) throws -> DownloadRecord? {
        guard var record, record.storageMode == .directSeek, !record.segments.isEmpty else {
            return record
        }

        var updatedSegments: [SegmentRecord] = []
        for segment in record.segments {
            let completed = min(max(segment.completedBytes, 0), segment.length)
            let partURL = backgroundManager.partFileURL(downloadID: record.id, segmentID: segment.id)
            if FileManager.default.fileExists(atPath: partURL.path) {
                do {
                    try FileManager.default.removeItem(at: partURL)
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to remove old part file \(partURL.path): \(error.localizedDescription)")
                }
            }

            var updated = segment
            updated.completedBytes = 0

            if completed > 0,
               FileManager.default.fileExists(atPath: record.destinationURL.path) {
                guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let input = try FileHandle(forReadingFrom: record.destinationURL)
                let output = try FileHandle(forWritingTo: partURL)
                defer {
                    do {
                        try input.close()
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to close input handle: \(error.localizedDescription)")
                    }
                    do {
                        try output.close()
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to close output handle: \(error.localizedDescription)")
                    }
                }

                try input.seek(toOffset: UInt64(segment.startOffset))
                var remaining = completed
                while remaining > 0 {
                    let count = Int(min(512 * 1024, remaining))
                    guard let data = try input.read(upToCount: count), !data.isEmpty else {
                        break
                    }
                    try output.write(contentsOf: data)
                    remaining -= Int64(data.count)
                }
                try output.synchronize()
                let copied = completed - remaining
                updated.completedBytes = copied
            }
            updatedSegments.append(updated)
        }

        record.storageMode = .partFiles
        record.transportPolicy = .background
        record.state = .paused
        record.segments = updatedSegments
        record.updatedAt = Date()
        return record
    }

    func runMultiSegmentBackgroundDownload(
        request: DownloadRequest,
        probeResult: HTTPRangeProbeResult,
        existingRecord: DownloadRecord?,
        earliestBeginDate: Date? = nil,
        progress handler: ProgressHandler?
    ) async throws {
        guard let totalSize = probeResult.totalSize, totalSize > 0 else {
            throw DownloadCoordinatorError.invalidRequest(reason: "Invalid file size for ranged background download")
        }

        guard let bgManager = self.backgroundSessionManager else {
            PipelineLogger.shared.log("[DownloadCoordinator] Notice: BackgroundDownloadSessionManager unavailable, falling back to foreground transport.")
            try await waitUntilScheduledStart(earliestBeginDate)
            try await runMultiSegmentDownload(
                request: request,
                probeResult: probeResult,
                existingRecord: existingRecord,
                progress: handler
            )
            return
        }

        // 1. Allocate segments or restore existing boundaries
        let segments: [DownloadSegment]
        var initialCompletedMap: [Int: Int64] = [:]

        let preparedExistingRecord = try prepareExistingRecordForBackground(
            existingRecord,
            backgroundManager: bgManager
        )

        if let preparedExistingRecord, !preparedExistingRecord.segments.isEmpty {
            segments = preparedExistingRecord.segments.map { $0.toDownloadSegment() }
            for seg in preparedExistingRecord.segments {
                initialCompletedMap[seg.id] = seg.completedBytes
            }
        } else {
            segments = try SegmentAllocator.makeSegments(
                totalSize: totalSize,
                configuredThreadCount: request.configuredThreadCount,
                advancedMode: request.advancedMode
            )
        }

        try Self.validateSegmentLayout(segments, totalSize: totalSize)

        // 2. Reconcile existing part files on disk for safe resumption
        var completedSegmentsSet = Set<Int>()
        for seg in segments {
            let partURL = bgManager.partFileURL(downloadID: request.id, segmentID: seg.id)
            if FileManager.default.fileExists(atPath: partURL.path),
               let size = FileManager.default.fileSize(atPath: partURL.path) {
                if size == seg.length {
                    // Segment part file exists on disk and is 100% complete
                    initialCompletedMap[seg.id] = seg.length
                    completedSegmentsSet.insert(seg.id)
                } else if size > 0 && size < seg.length {
                    // Segment was partially downloaded and is resumable
                    initialCompletedMap[seg.id] = size
                } else {
                    // Corrupted/oversized part file: remove and reset
                    initialCompletedMap[seg.id] = 0
                    if FileManager.default.fileExists(atPath: partURL.path) {
                        do {
                            try FileManager.default.removeItem(at: partURL)
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to remove oversized part file \(partURL.path): \(error.localizedDescription)")
                        }
                    }
                }
            } else {
                initialCompletedMap[seg.id] = 0
            }
        }

        // 3. Prepare persistent record with .partFiles mode and .background transportPolicy
        let segmentRecords = segments.map { segment in
            SegmentRecord(segment: segment, completedBytes: initialCompletedMap[segment.id] ?? 0)
        }
        let currentRecord = DownloadRecord(
            id: request.id,
            originalURL: request.url,
            resolvedURL: probeResult.finalURL,
            destinationURL: request.destinationURL,
            totalSize: totalSize,
            state: .downloading,
            storageMode: .partFiles,
            transportPolicy: .background,
            networkPolicy: request.networkPolicy,
            eTag: probeResult.eTag,
            lastModified: probeResult.lastModified,
            suggestedFilename: probeResult.suggestedFilename,
            mimeType: probeResult.mimeType,
            headers: headersForPersistence(request),
            segments: segmentRecords
        )
        try await persistenceStore.save(currentRecord)

        // 4. Progress tracker
        let progressAccumulator = ProgressAccumulator(
            segments: segments,
            initialCompletedBytes: initialCompletedMap
        )
        let initialSnapshot = await progressAccumulator.snapshot()

        let speedTracker = speedTrackers[request.id] ?? DownloadSpeedTracker()
        speedTrackers[request.id] = speedTracker

        updateProgress(
            downloadID: request.id,
            state: .downloading,
            bytesReceived: initialSnapshot.bytesReceived,
            totalBytes: totalSize,
            completedSegments: initialSnapshot.completedSegments,
            totalSegments: segments.count,
            handler: handler
        )

        // 5. If all segments are already completed on disk, skip scheduling and jump straight to merge!
        if completedSegmentsSet.count == segments.count {
            try await finalizeBackgroundMerge(
                request: request,
                segments: segments,
                totalSize: totalSize,
                bgManager: bgManager,
                speedTracker: speedTracker,
                progressAccumulator: progressAccumulator,
                handler: handler
            )
            return
        }

        // 6. Setup asynchronous observer stream
        let (eventStream, eventContinuation) = AsyncStream<BackgroundEvent>.makeStream(bufferingPolicy: .unbounded)
        bgManager.addObserver(
            for: request.id,
            onProgress: { segID, done, total in
                eventContinuation.yield(.progress(segmentID: segID, completedBytes: done, totalBytes: total))
            },
            onCompleted: { segID, url in
                eventContinuation.yield(.completed(segmentID: segID, partURL: url))
            },
            onFailed: { segID, err in
                eventContinuation.yield(
                    .failed(
                        segmentID: segID,
                        failure: Self.classifyBackgroundFailure(err)
                    )
                )
            }
        )
        defer {
            bgManager.removeObservers(for: request.id)
            eventContinuation.finish()
        }

        // 7. Schedule pending segments, preventing duplicates
        let existingTasks = await bgManager.activeTasks(for: request.id)
        let activeSegmentIDs = Set(existingTasks.map { $0.segmentID })

        for segment in segments {
            guard !completedSegmentsSet.contains(segment.id) else { continue }
            guard !activeSegmentIDs.contains(segment.id) else { continue } // Prevent duplicate task

            let completedSoFar = initialCompletedMap[segment.id] ?? 0
            let segRec = SegmentRecord(segment: segment, completedBytes: completedSoFar)
            let mergedHeaders = currentRecord.securedHeaders.merging(request.headers) { (secured, _) in secured }
            try await bgManager.scheduleSegmentDownload(
                download: currentRecord,
                segment: segRec,
                customHeaders: self.mergeValidatorHeaders(
                    original: mergedHeaders,
                    eTag: probeResult.eTag,
                    lastModified: probeResult.lastModified
                ),
                earliestBeginDate: earliestBeginDate
            )
        }

        // 8. Event loop processing progress, completion, failure, pause, and cancellation
        var retryAttempts: [Int: Int] = [:]

        do {
            for await event in eventStream {
                try Task.checkCancellation()
                if pauseRequested.contains(request.id) {
                    throw CancellationError()
                }

                switch event {
                case .progress(let segID, let done, _):
                    let agg = await progressAccumulator.update(segmentID: segID, completedBytes: done)
                    let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                    updateProgress(
                        downloadID: request.id,
                        state: .downloading,
                        bytesReceived: agg.bytesReceived,
                        totalBytes: totalSize,
                        completedSegments: agg.completedSegments,
                        totalSegments: segments.count,
                        currentSpeed: metrics.currentBytesPerSecond,
                        averageSpeed: metrics.averageBytesPerSecond,
                        elapsedTime: metrics.elapsedTime,
                        eta: metrics.estimatedTimeRemaining,
                        handler: handler
                    )

                case .completed(let segID, _):
                    completedSegmentsSet.insert(segID)
                    guard let seg = segments.first(where: { $0.id == segID }) else { continue }
                    let agg = await progressAccumulator.update(segmentID: segID, completedBytes: seg.length)
                    do {
                        _ = try await self.persistenceStore.updateSegmentProgress(
                            tag: request.id,
                            segmentID: segID,
                            completedBytes: seg.length
                        )
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Single stream completion checkpoint failed for \(request.id) segment \(segID): \(error.localizedDescription)")
                    }

                    let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
                    updateProgress(
                        downloadID: request.id,
                        state: .downloading,
                        bytesReceived: agg.bytesReceived,
                        totalBytes: totalSize,
                        completedSegments: agg.completedSegments,
                        totalSegments: segments.count,
                        currentSpeed: metrics.currentBytesPerSecond,
                        averageSpeed: metrics.averageBytesPerSecond,
                        elapsedTime: metrics.elapsedTime,
                        eta: metrics.estimatedTimeRemaining,
                        handler: handler
                    )

                case .failed(let segID, let failure):
                    if let code = failure.statusCode {
                        switch code {
                        case 401:
                            throw DownloadCoordinatorError.unauthorized(url: request.url)
                        case 403:
                            throw DownloadCoordinatorError.forbidden(url: request.url)
                        case 404, 410:
                            throw DownloadCoordinatorError.linkExpired(url: request.url)
                        case 429, 500...599:
                            break // eligible for retry
                        default:
                            if (400...499).contains(code) {
                                throw Self.terminalBackgroundError(request: request, failure: failure)
                            }
                        }
                    }

                    guard failure.retryable else {
                        throw Self.terminalBackgroundError(
                            request: request,
                            failure: failure
                        )
                    }

                    let attempt = retryAttempts[segID, default: 0]
                    if attempt < request.retryCount && !pauseRequested.contains(request.id) && !Task.isCancelled {
                        retryAttempts[segID] = attempt + 1
                        let baseDelay = (failure.statusCode == 429) ? 2.0 : 0.5
                        let delaySeconds = min(30.0, baseDelay * pow(2.0, Double(attempt)))
                        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                        if let seg = segments.first(where: { $0.id == segID }) {
                            let segRec = SegmentRecord(segment: seg, completedBytes: 0)
                            do {
                                let mergedHeaders = currentRecord.securedHeaders.merging(request.headers) { (secured, _) in secured }
                                _ = try await bgManager.scheduleSegmentDownload(
                                    download: currentRecord,
                                    segment: segRec,
                                    customHeaders: self.mergeValidatorHeaders(
                                        original: mergedHeaders,
                                        eTag: probeResult.eTag,
                                        lastModified: probeResult.lastModified
                                    ),
                                    earliestBeginDate: earliestBeginDate
                                )
                            } catch {
                                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to reschedule segment \(segID) for \(request.id): \(error)")
                            }
                        }
                    } else {
                        throw DownloadCoordinatorError.retryLimitExceeded(
                            id: request.id,
                            underlyingError: failure.reason
                        )
                    }
                }

                // Check if all segments are completed
                if completedSegmentsSet.count == segments.count {
                    break
                }
            }

            if pauseRequested.contains(request.id) || Task.isCancelled {
                throw CancellationError()
            }
        } catch is CancellationError {
            await bgManager.cancelTasks(for: request.id)
            // Bug #20: Reconcile each segment's checkpoint strictly to what is committed on disk
            for seg in segments {
                let partURL = bgManager.partFileURL(downloadID: request.id, segmentID: seg.id)
                let diskBytes = FileManager.default.fileSize(atPath: partURL.path) ?? 0
                let committedBytes = min(seg.length, max(0, diskBytes))
                do {
                    _ = try await persistenceStore.updateSegmentProgress(
                        tag: request.id,
                        segmentID: seg.id,
                        completedBytes: committedBytes,
                        allowDecrease: true
                    )
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Failed to persist background segment \(seg.id) progress on pause for \(request.id): \(error.localizedDescription)")
                }
            }
            do {
                _ = try await persistenceStore.updateState(tag: request.id, state: .paused)
            } catch {
                PipelineLogger.shared.log("[DownloadCoordinator] Failed to persist background paused state for \(request.id): \(error.localizedDescription)")
            }
            let committedTotal = segments.reduce(Int64(0)) { sum, seg in
                let partURL = bgManager.partFileURL(downloadID: request.id, segmentID: seg.id)
                let diskBytes = FileManager.default.fileSize(atPath: partURL.path) ?? 0
                return sum + min(seg.length, max(0, diskBytes))
            }
            let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
            updateProgress(
                downloadID: request.id,
                state: .paused,
                bytesReceived: committedTotal,
                totalBytes: totalSize,
                completedSegments: completedSegmentsSet.count,
                totalSegments: segments.count,
                currentSpeed: 0,
                averageSpeed: metrics.averageBytesPerSecond,
                elapsedTime: metrics.elapsedTime,
                eta: nil,
                handler: handler
            )
            throw CancellationError()
        } catch {
            await bgManager.cancelTasks(for: request.id)
            // Bug #20: Reconcile each segment's checkpoint strictly to what is committed on disk
            for seg in segments {
                let partURL = bgManager.partFileURL(downloadID: request.id, segmentID: seg.id)
                let diskBytes = FileManager.default.fileSize(atPath: partURL.path) ?? 0
                let committedBytes = min(seg.length, max(0, diskBytes))
                do {
                    _ = try await persistenceStore.updateSegmentProgress(
                        tag: request.id,
                        segmentID: seg.id,
                        completedBytes: committedBytes,
                        allowDecrease: true
                    )
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Failed to persist background segment \(seg.id) progress on error for \(request.id): \(error.localizedDescription)")
                }
            }
            do {
                _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            } catch {
                PipelineLogger.shared.log("[DownloadCoordinator] Failed to persist background failed state for \(request.id): \(error.localizedDescription)")
            }
            let committedTotal = segments.reduce(Int64(0)) { sum, seg in
                let partURL = bgManager.partFileURL(downloadID: request.id, segmentID: seg.id)
                let diskBytes = FileManager.default.fileSize(atPath: partURL.path) ?? 0
                return sum + min(seg.length, max(0, diskBytes))
            }
            let metrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
            updateProgress(
                downloadID: request.id,
                state: .failed(reason: error.localizedDescription),
                bytesReceived: committedTotal,
                totalBytes: totalSize,
                completedSegments: completedSegmentsSet.count,
                totalSegments: segments.count,
                currentSpeed: 0,
                averageSpeed: metrics.averageBytesPerSecond,
                elapsedTime: metrics.elapsedTime,
                eta: nil,
                handler: handler
            )
            throw error
        }

        // 9. Merge, verify, and finalize completed download
        try await finalizeBackgroundMerge(
            request: request,
            segments: segments,
            totalSize: totalSize,
            bgManager: bgManager,
            speedTracker: speedTracker,
            progressAccumulator: progressAccumulator,
            handler: handler
        )
    }

    func finalizeBackgroundMerge(
        request: DownloadRequest,
        segments: [DownloadSegment],
        totalSize: Int64,
        bgManager: BackgroundDownloadSessionManager,
        speedTracker: DownloadSpeedTracker,
        progressAccumulator: ProgressAccumulator,
        handler: ProgressHandler?
    ) async throws {
        // 1. Gather and verify all part files
        let sortedSegments = segments.sorted { $0.id < $1.id }
        let partURLs = sortedSegments.map { bgManager.partFileURL(downloadID: request.id, segmentID: $0.id) }
        for (idx, seg) in sortedSegments.enumerated() {
            let partURL = partURLs[idx]
            guard FileManager.default.fileExists(atPath: partURL.path) else {
                throw DownloadCoordinatorError.cannotResume(reason: "Missing part file for segment \(seg.id)")
            }
            guard let size = FileManager.default.fileSize(atPath: partURL.path),
                  size == seg.length else {
                throw DownloadCoordinatorError.cannotResume(reason: "Corrupted or incomplete part file for segment \(seg.id)")
            }
        }

        // 2. Safely merge part files using staged replacement
        try DownloadFileWriter.mergeFiles(
            partURLs: partURLs,
            destinationURL: request.destinationURL,
            expectedMergedSize: totalSize
        )

        // 3. Remove part files after successful merge
        for partURL in partURLs {
            do {
                try FileManager.default.removeItem(at: partURL)
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to remove part file \(partURL.path): \(error)")
            }
        }

        // 4. Validate physical disk file attributes
        let diskAttributes = try FileManager.default.attributesOfItem(atPath: request.destinationURL.path)
        let actualDiskSize = (diskAttributes[.size] as? NSNumber)?.int64Value ?? (diskAttributes[.size] as? Int64)
        guard let actualDiskSize, actualDiskSize == totalSize else {
            let error = SegmentDownloaderError.bodyLengthMismatch(
                expected: totalSize,
                actual: actualDiskSize ?? -1
            )
            do {
                _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to persist failed state for \(request.id): \(error)")
            }
            throw error
        }

        // 5. Update persistence store segment records
        for seg in sortedSegments {
            do {
                _ = try await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: seg.id, completedBytes: seg.length)
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to update segment progress for \(request.id) segment \(seg.id): \(error)")
            }
        }

        guard let finalRecord = try await persistenceStore.fetch(tag: request.id),
              finalRecord.isAllSegmentsCompleted else {
            let error = DownloadCoordinatorError.segmentLayoutInvalid(reason: "Not all segments reported completed")
            do {
                _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to persist failed state for \(request.id): \(error)")
            }
            throw error
        }

        // 6. Checksum validation
        if let expectedSHA = request.expectedSHA256, !expectedSHA.isEmpty {
            let actualSHA = try FileHasher.sha256(for: request.destinationURL)
            guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
                checksumOutcomes[request.id] = .mismatch(expected: expectedSHA, actual: actualSHA)
                let error = DownloadCoordinatorError.checksumMismatch(expected: expectedSHA, actual: actualSHA)
                do {
                    _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                } catch {
                    PipelineLogger.shared.log(stage: .coordinator, message: "Failed to persist failed state for \(request.id): \(error)")
                }
                throw error
            }
            checksumOutcomes[request.id] = .verified(sha256: actualSHA)
        } else {
            checksumOutcomes[request.id] = .notChecked
        }

        // 7. Mark download completed
        try await persistenceStore.updateState(tag: request.id, state: .completed)
        let resumedFilename = request.destinationURL.lastPathComponent
        DownloadNotificationManager.postDownloadCompletedNotification(filename: resumedFilename, downloadID: request.id)
        let finalMetrics = speedTracker.snapshot(expectedTotalBytes: totalSize)
        updateProgress(
            downloadID: request.id,
            state: .completed,
            bytesReceived: totalSize,
            totalBytes: totalSize,
            completedSegments: sortedSegments.count,
            totalSegments: sortedSegments.count,
            currentSpeed: 0,
            averageSpeed: finalMetrics.averageBytesPerSecond,
            elapsedTime: finalMetrics.elapsedTime,
            eta: 0,
            checksumOutcome: checksumOutcomes[request.id],
            handler: handler
        )
    }

}
