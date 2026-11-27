import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

extension DownloadCoordinator {
    // MARK: - Single-Stream Fallback

    func runSingleStreamFallback(
        request: DownloadRequest,
        probeResult: HTTPRangeProbeResult,
        progress handler: ProgressHandler?,
        earliestBeginDate: Date? = nil
    ) async throws {
        try await runSingleStreamDownload(
            request: request,
            probeResult: probeResult,
            progress: handler,
            earliestBeginDate: earliestBeginDate
        )
    }

    // MARK: - Linear Single-Stream Download

    func runSingleStreamDownload(
        request: DownloadRequest,
        probeResult: HTTPRangeProbeResult,
        progress handler: ProgressHandler?,
        earliestBeginDate: Date? = nil
    ) async throws {
        try await waitUntilScheduledStart(earliestBeginDate)

        let destinationURL = request.destinationURL
        let parentDir = destinationURL.deletingLastPathComponent()
        do {
            try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(parentDir)
        } catch {
            let nsErr = error as NSError
            PipelineLogger.shared.log("[DownloadCoordinator] Operation: createDirectory, Path: \(parentDir.path), Domain: \(nsErr.domain), Code: \(nsErr.code), Description: \(nsErr.localizedDescription), UserInfo: \(nsErr.userInfo)")
            throw error
        }

        let stagingURL = parentDir.appendingPathComponent(".stage-\(request.id)-\(UUID().uuidString).tmp")
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            do {
                try FileManager.default.removeItem(at: stagingURL)
            } catch {
                PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to clean up existing staging file \(stagingURL.path): \(error.localizedDescription)")
            }
        }
        guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var publicationSucceeded = false
        defer {
            if !publicationSucceeded {
                if FileManager.default.fileExists(atPath: stagingURL.path) {
                    do {
                        try FileManager.default.removeItem(at: stagingURL)
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to clean up uncommitted staging file \(stagingURL.path): \(error.localizedDescription)")
                    }
                }
            }
        }

        let fileHandle = try FileHandle(forWritingTo: stagingURL)
        defer {
            do {
                try fileHandle.synchronize()
            } catch {
                PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to synchronize fileHandle on close: \(error.localizedDescription)")
            }
            do {
                try fileHandle.close()
            } catch {
                PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to close fileHandle: \(error.localizedDescription)")
            }
        }

        // File Preallocation: Preallocate disk space to catch disk-full / quota errors at byte 0
        if let total = probeResult.totalSize, total > 0 {
            do {
                try fileHandle.truncate(atOffset: UInt64(total))
                try fileHandle.seek(toOffset: 0)
            } catch {
                let nsErr = error as NSError
                PipelineLogger.shared.log("[DownloadCoordinator] Disk preallocation warning for \(stagingURL.path) (size \(total) bytes): \(nsErr.localizedDescription). Proceeding with streaming writes.")
            }
        }

        var urlRequest = URLRequest(url: probeResult.finalURL)
        urlRequest.httpMethod = "GET"
        urlRequest.allowsCellularAccess = request.networkPolicy.allowsCellularAccess
        #if canImport(Darwin)
        if #available(iOS 13.0, macOS 10.15, *) {
            urlRequest.allowsExpensiveNetworkAccess = request.networkPolicy.allowsExpensiveNetworkAccess
            urlRequest.allowsConstrainedNetworkAccess = request.networkPolicy.allowsConstrainedNetworkAccess
        }
        #endif
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let effectiveHeaders = getDynamicHeaders(for: request.id, baseHeaders: request.headers)
        for (name, value) in effectiveHeaders {
            if name.caseInsensitiveCompare("Accept-Encoding") == .orderedSame ||
               name.caseInsensitiveCompare("Range") == .orderedSame {
                continue
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest = DownloadRequestEnricher.enrich(urlRequest)

        let expectedTotal = probeResult.totalSize
        let singleSegment = DownloadSegment(
            id: 0,
            startOffset: 0,
            endOffset: (expectedTotal ?? 1) - 1,
            length: expectedTotal ?? 0
        )
        let record = DownloadRecord(
            id: request.id,
            originalURL: request.url,
            resolvedURL: probeResult.finalURL,
            destinationURL: destinationURL,
            totalSize: expectedTotal ?? 0,
            state: .downloading,
            storageMode: .directSeek,
            networkPolicy: request.networkPolicy,
            eTag: probeResult.eTag,
            lastModified: probeResult.lastModified,
            suggestedFilename: probeResult.suggestedFilename,
            mimeType: probeResult.mimeType,
            headers: headersForPersistence(request),
            segments: [SegmentRecord(segment: singleSegment)]
        )
        try await persistenceStore.save(record)

        let perDownloadLimiter = perDownloadLimiters[request.id]
        let speedTracker = speedTrackers[request.id] ?? DownloadSpeedTracker()
        speedTrackers[request.id] = speedTracker
        speedTracker.reset()

        updateProgress(
            downloadID: request.id,
            state: .downloading,
            bytesReceived: 0,
            totalBytes: expectedTotal,
            completedSegments: 0,
            totalSegments: 1,
            handler: handler
        )

        var acquiredPermit = false
        try await requestBudget.acquire(
            downloadID: request.id,
            maxPerDownload: request.maxConcurrentRequests,
            host: request.url.host
        )
        acquiredPermit = true

        do {
            var chunkStream = URLSessionDataChunkStream(session: session, request: urlRequest)
            defer { chunkStream.cancel() }
            var httpResponse = try await chunkStream.start()

            if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) {
                if let fresh = await attemptCredentialRefresh(for: probeResult.finalURL, downloadID: request.id) {
                    for (k, v) in fresh {
                        urlRequest.setValue(v, forHTTPHeaderField: k)
                    }
                    PipelineLogger.shared.log("[DownloadCoordinator] Retrying single stream download after credential refresh for \(request.id)")
                    chunkStream.cancel()
                    chunkStream = URLSessionDataChunkStream(session: session, request: urlRequest)
                    httpResponse = try await chunkStream.start()
                }
            }

            if httpResponse.statusCode == 429 {
                let retryAfter = HTTPRangeProbe.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                throw SegmentDownloaderError.rateLimited(retryAfterSeconds: retryAfter)
            }
            if httpResponse.statusCode == 401 {
                throw DownloadCoordinatorError.tokenExpired(url: request.url)
            }
            if httpResponse.statusCode == 403 {
                let cooldown = Date().addingTimeInterval(300)
                throw DownloadCoordinatorError.accessDenied(url: request.url, cooldownUntil: cooldown)
            }
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
                throw DownloadCoordinatorError.unexpectedSingleStreamError(
                    reason: "Unexpected HTTP status: \(httpResponse.statusCode)"
                )
            }

            // Validator and content length parity checks against probeResult
            if let probeETag = probeResult.eTag,
               let currentETag = httpResponse.value(forHTTPHeaderField: "ETag") {
                let normProbe = DownloadRecord.normalizeValidator(probeETag)
                let normCurrent = DownloadRecord.normalizeValidator(currentETag)
                if normProbe != normCurrent {
                    throw DownloadCoordinatorError.unexpectedSingleStreamError(
                        reason: "Resource mutated between probe and single-stream download: ETag changed from \(probeETag) to \(currentETag)"
                    )
                }
            }
            if probeResult.eTag == nil,
               let probeLM = probeResult.lastModified,
               let currentLM = httpResponse.value(forHTTPHeaderField: "Last-Modified") {
                if probeLM != currentLM {
                    throw DownloadCoordinatorError.unexpectedSingleStreamError(
                        reason: "Resource mutated between probe and single-stream download: Last-Modified changed from \(probeLM) to \(currentLM)"
                    )
                }
            }
            if let expectedTotal = probeResult.totalSize, expectedTotal > 0 {
                let currentLength = httpResponse.expectedContentLength
                if currentLength > 0 && currentLength != expectedTotal {
                    throw DownloadCoordinatorError.unexpectedSingleStreamError(
                        reason: "Resource mutated between probe and single-stream download: Content-Length changed from \(expectedTotal) to \(currentLength)"
                    )
                }
            }

            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var totalWritten: Int64 = 0
            var lastFlushedSingleStreamBytes: Int64 = 0
            var lastFlushedSingleStreamTime = Date()

            do {
                while let chunk = try await chunkStream.next() {
                    try Task.checkCancellation()
                    buffer.append(chunk)
                    if buffer.count >= 64 * 1024 {
                        try await BandwidthLimiter.throttle(
                            bytes: Int64(buffer.count),
                            global: self.globalBandwidthLimiter,
                            perDownload: perDownloadLimiter
                        )
                        try fileHandle.write(contentsOf: buffer)
                        totalWritten += Int64(buffer.count)
                        speedTracker.record(bytes: Int64(buffer.count))
                        buffer.removeAll(keepingCapacity: true)

                        let metrics = speedTracker.snapshot(expectedTotalBytes: expectedTotal)
                        updateProgress(
                            downloadID: request.id,
                            state: .downloading,
                            bytesReceived: totalWritten,
                            totalBytes: expectedTotal,
                            completedSegments: 0,
                            totalSegments: 1,
                            currentSpeed: metrics.currentBytesPerSecond,
                            averageSpeed: metrics.averageBytesPerSecond,
                            elapsedTime: metrics.elapsedTime,
                            eta: metrics.estimatedTimeRemaining,
                            handler: handler
                        )

                        if totalWritten - lastFlushedSingleStreamBytes >= 256 * 1024 ||
                            Date().timeIntervalSince(lastFlushedSingleStreamTime) >= 1.0 {
                            var flushedSuccessfully = false
                            do {
                                try fileHandle.synchronize()
                                _ = try await persistenceStore.updateSegmentProgress(
                                    tag: request.id,
                                    segmentID: 0,
                                    completedBytes: totalWritten
                                )
                                flushedSuccessfully = true
                            } catch {
                                PipelineLogger.shared.log("[DownloadCoordinator] Single stream intermediate checkpoint failed for \(request.id): \(error.localizedDescription)")
                            }
                            if flushedSuccessfully {
                                lastFlushedSingleStreamBytes = totalWritten
                                lastFlushedSingleStreamTime = Date()
                            }
                        }
                    }
                }

                if !buffer.isEmpty {
                    try Task.checkCancellation()
                    try await BandwidthLimiter.throttle(
                        bytes: Int64(buffer.count),
                        global: self.globalBandwidthLimiter,
                        perDownload: perDownloadLimiter
                    )
                    try fileHandle.write(contentsOf: buffer)
                    totalWritten += Int64(buffer.count)
                    speedTracker.record(bytes: Int64(buffer.count))
                    buffer.removeAll(keepingCapacity: false)
                }
            } catch {
                if pauseRequested.contains(request.id) || Task.isCancelled {
                    var singleStreamSyncSucceeded = false
                    do {
                        try fileHandle.synchronize()
                        singleStreamSyncSucceeded = true
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Single stream synchronize failed on pause for \(request.id): \(error.localizedDescription)")
                    }
                    if singleStreamSyncSucceeded {
                        do {
                            _ = try await persistenceStore.updateSegmentProgress(
                                tag: request.id,
                                segmentID: 0,
                                completedBytes: totalWritten
                            )
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Single stream progress persistence failed on pause for \(request.id): \(error.localizedDescription)")
                        }
                    }
                    do {
                        _ = try await persistenceStore.updateState(tag: request.id, state: .paused)
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Single stream state persistence failed on pause for \(request.id): \(error.localizedDescription)")
                    }
                    let metrics = speedTracker.snapshot(expectedTotalBytes: expectedTotal)
                    updateProgress(
                        downloadID: request.id,
                        state: .paused,
                        bytesReceived: totalWritten,
                        totalBytes: expectedTotal,
                        completedSegments: 0,
                        totalSegments: 1,
                        currentSpeed: 0,
                        averageSpeed: metrics.averageBytesPerSecond,
                        elapsedTime: metrics.elapsedTime,
                        eta: nil,
                        handler: handler
                    )
                    throw CancellationError()
                }
                var singleStreamSyncSucceeded = false
                do {
                    try fileHandle.synchronize()
                    singleStreamSyncSucceeded = true
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Single stream synchronize failed on error for \(request.id): \(error.localizedDescription)")
                }
                if singleStreamSyncSucceeded {
                    do {
                        _ = try await persistenceStore.updateSegmentProgress(
                            tag: request.id,
                            segmentID: 0,
                            completedBytes: totalWritten
                        )
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Single stream progress persistence failed on error for \(request.id): \(error.localizedDescription)")
                    }
                }
                do {
                    _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                } catch {
                    PipelineLogger.shared.log("[DownloadCoordinator] Single stream failed state persistence error for \(request.id): \(error.localizedDescription)")
                }
                updateProgress(
                    downloadID: request.id,
                    state: .failed(reason: error.localizedDescription),
                    bytesReceived: totalWritten,
                    totalBytes: expectedTotal,
                    completedSegments: 0,
                    totalSegments: 1,
                    currentSpeed: 0,
                    averageSpeed: 0,
                    elapsedTime: 0,
                    eta: nil,
                    handler: handler
                )
                throw error
            }

            if let expected = expectedTotal, totalWritten != expected {
                throw SegmentDownloaderError.bodyLengthMismatch(expected: expected, actual: totalWritten)
            }

            try fileHandle.synchronize()

            // Physical file size validation on disk for staging file
            let diskAttributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
            if let expected = expectedTotal {
                let actualDiskSize = (diskAttributes[.size] as? NSNumber)?.int64Value ?? (diskAttributes[.size] as? Int64)
                guard let actualDiskSize, actualDiskSize == expected else {
                    let error = SegmentDownloaderError.bodyLengthMismatch(
                        expected: expected,
                        actual: actualDiskSize ?? -1
                    )
                    do {
                        _ = try await persistenceStore.updateState(tag: request.id, state: .failed(reason: error.localizedDescription))
                    } catch {
                        PipelineLogger.shared.log(stage: .coordinator, message: "Failed to persist failed state for \(request.id): \(error)")
                    }
                    throw error
                }
            }

            // Checksum validation on staging file (if provided)
            if let expectedSHA = request.expectedSHA256, !expectedSHA.isEmpty {
                let actualSHA = try FileHasher.sha256(for: stagingURL)
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

            // Atomically publish staged download to final destinationURL
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                #if canImport(Darwin)
                do {
                    _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL, backupItemName: nil, options: .withoutDeletingBackupItem)
                } catch {
                    // Non-destructive fallback: preserve existing destination if move fails
                    let backupURL = destinationURL.deletingLastPathComponent()
                        .appendingPathComponent(".backup-\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
                    try FileManager.default.moveItem(at: destinationURL, to: backupURL)
                    do {
                        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
                        do {
                            try FileManager.default.removeItem(at: backupURL)
                        } catch {
                            PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to clean up backup file \(backupURL.path): \(error.localizedDescription)")
                        }
                    } catch {
                        do {
                            try FileManager.default.moveItem(at: backupURL, to: destinationURL)
                        } catch let restoreErr {
                            PipelineLogger.shared.log("[DownloadCoordinator] CRITICAL: Failed to restore backup to \(destinationURL.path): \(restoreErr.localizedDescription)")
                        }
                        throw error
                    }
                }
                #else
                let backupURL = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".backup-\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
                try FileManager.default.moveItem(at: destinationURL, to: backupURL)
                do {
                    try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
                    do {
                        try FileManager.default.removeItem(at: backupURL)
                    } catch {
                        PipelineLogger.shared.log("[DownloadCoordinator] Warning: Failed to clean up backup file \(backupURL.path): \(error.localizedDescription)")
                    }
                } catch {
                    do {
                        try FileManager.default.moveItem(at: backupURL, to: destinationURL)
                    } catch let restoreErr {
                        PipelineLogger.shared.log("[DownloadCoordinator] CRITICAL: Failed to restore backup to \(destinationURL.path): \(restoreErr.localizedDescription)")
                    }
                    throw error
                }
                #endif
            } else {
                try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
            }
            publicationSucceeded = true

            try await persistenceStore.updateSegmentProgress(tag: request.id, segmentID: 0, completedBytes: totalWritten)
            try await persistenceStore.updateState(tag: request.id, state: .completed)
            let fallbackFilename = request.destinationURL.lastPathComponent
            DownloadNotificationManager.postDownloadCompletedNotification(filename: fallbackFilename, downloadID: request.id)

            let finalMetrics = speedTracker.snapshot(expectedTotalBytes: expectedTotal)
            updateProgress(
                downloadID: request.id,
                state: .completed,
                bytesReceived: totalWritten,
                totalBytes: expectedTotal ?? totalWritten,
                completedSegments: 1,
                totalSegments: 1,
                currentSpeed: 0,
                averageSpeed: finalMetrics.averageBytesPerSecond,
                elapsedTime: finalMetrics.elapsedTime,
                eta: 0,
                checksumOutcome: checksumOutcomes[request.id],
                handler: handler
            )

            if acquiredPermit {
                await requestBudget.release(downloadID: request.id, host: request.url.host)
                acquiredPermit = false
            }
        } catch {
            if acquiredPermit {
                await requestBudget.release(downloadID: request.id, host: request.url.host)
                acquiredPermit = false
            }
            throw error
        }
    }

    /// Delays a foreground fallback until its scheduled start without blocking
    /// the actor. Task cancellation interrupts `Task.sleep`, so cancelling a
    /// queued download cannot create a file or issue a foreground request.
    func waitUntilScheduledStart(_ date: Date?) async throws {
        guard let date else { return }

        while true {
            try Task.checkCancellation()
            let remaining = date.timeIntervalSinceNow
            guard remaining > 0 else { return }

            let sleepSeconds = min(remaining, 60.0)
            try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
    }

}
