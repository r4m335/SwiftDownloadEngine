import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension StreamingDownloadOrchestrator {
    public func executeAndAssembleHLS(
        _ proposal: StreamingTransferProposal,
        approved: Bool,
        destinationDirectory: URL,
        outputURL: URL,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil,
        runID: String? = nil
    ) async throws -> MediaAssemblyOutput {
        guard case .hls = proposal.manifest else {
            throw StreamingDownloadOrchestratorError.unsupportedManifest(.dash)
        }
        let parentID = runID ?? "stream-run-\(UUID().uuidString.lowercased())"
        guard !runningTransfers.contains(parentID), !activeAssemblyOperations.contains(parentID) else {
            PipelineLogger.shared.log("[HLS Pipeline] Transfer \(parentID) is already actively running or assembling. Ignoring redundant execution request.")
            throw StreamingDownloadOrchestratorError.transferAlreadyRunning
        }
        let runProposal = proposalForRun(proposal, transferID: parentID)
        guard case .hls(let transferPlan) = runProposal.manifest else {
            throw StreamingDownloadOrchestratorError.unsupportedManifest(.dash)
        }
        let finalOutputURL: URL
        #if canImport(AVFoundation)
        finalOutputURL = (outputURL.pathExtension.lowercased() == "ts" && remuxTSToMP4)
            ? outputURL.deletingPathExtension().appendingPathExtension("mp4")
            : outputURL
        #else
        finalOutputURL = outputURL
        #endif
        let originalSourceURL = candidatesByTransfer[proposal.transferID]?.url ?? transferPlan.manifestURL
        if let candidate = candidatesByTransfer[proposal.transferID] {
            candidatesByTransfer[parentID] = candidate
        }
        proposals[parentID] = runProposal
        registeredTransferIDs[originalSourceURL.absoluteString] = parentID
        registeredTransferIDs[transferPlan.manifestURL.absoluteString] = parentID
        registeredTransferIDs[proposal.transferID] = parentID

        guard let engine = self.downloadEngine else {
            let message = "No DownloadEngine is configured by the application composition root."
            PipelineLogger.shared.log("[HLS Pipeline] Failed to register parent stream \(parentID): \(message)")
            proposals.removeValue(forKey: parentID)
            candidatesByTransfer.removeValue(forKey: parentID)
            registeredTransferIDs = registeredTransferIDs.filter {
                $0.key != parentID && $0.value != parentID
            }
            throw StreamingDownloadOrchestratorError.streamingRegistrationFailed(message)
        }

        let estimated = runProposal.estimatedTransferBytes ?? (Int64(runProposal.resources.count) * 1_000_000)
        do {
            _ = try await engine.registerStreamingDownload(
                id: parentID,
                manifestURL: originalSourceURL,
                destinationURL: finalOutputURL,
                filename: finalOutputURL.lastPathComponent,
                totalBytes: estimated,
                mimeType: "video/mp4"
            )
        } catch {
            PipelineLogger.shared.log("[HLS Pipeline] Failed to register parent stream \(parentID): \(error.localizedDescription)")
            proposals.removeValue(forKey: parentID)
            candidatesByTransfer.removeValue(forKey: parentID)
            registeredTransferIDs = registeredTransferIDs.filter {
                $0.key != parentID && $0.value != parentID
            }
            throw StreamingDownloadOrchestratorError.streamingRegistrationFailed(error.localizedDescription)
        }
        await engine.queueManager.resumeStreaming(id: parentID)
        PipelineLogger.shared.log("[HLS Pipeline] Active stream registered with DownloadEngine: \(parentID)")

        var effectiveDestinationDirectory = destinationDirectory

        activeAssemblyOperations.insert(parentID)
        activeAssemblyDirectories[parentID] = effectiveDestinationDirectory
        defer {
            activeAssemblyOperations.remove(parentID)
            activeAssemblyDirectories.removeValue(forKey: parentID)
        }

        // Persist the parent HLS transfer record so it survives app restarts.
        if let persistence = hlsPersistenceStore {
            let previousRecord: HLSTransferRecord?
            do {
                previousRecord = try await persistence.load(id: parentID)
            } catch {
                PipelineLogger.shared.log(
                    "[HLS Pipeline] Failed to load existing transfer record \(parentID): \(error.localizedDescription)"
                )
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
                throw persistenceFailure(error)
            }
            if let previousRecord, FileManager.default.fileExists(atPath: previousRecord.segmentDirectoryURL.path) {
                effectiveDestinationDirectory = previousRecord.segmentDirectoryURL
                activeAssemblyDirectories[parentID] = effectiveDestinationDirectory
            }
            let hlsRecord = HLSTransferRecord(
                id: parentID,
                manifestURL: originalSourceURL,
                outputFilename: finalOutputURL.lastPathComponent,
                outputDestinationURL: finalOutputURL,
                segmentDirectoryURL: effectiveDestinationDirectory,
                totalSegments: runProposal.resources.count,
                completedSegmentOrders: previousRecord?.completedSegmentOrders ?? [],
                state: .downloading,
                assemblyState: .notStarted,
                createdAt: previousRecord?.createdAt ?? Date(),
                updatedAt: Date()
            )
            do {
                try await persistence.save(hlsRecord)
                PipelineLogger.shared.log("[HLS Pipeline] HLS transfer record persisted: \(parentID)")
            } catch {
                PipelineLogger.shared.log(
                    "[HLS Pipeline] Failed to persist transfer record \(parentID): \(error.localizedDescription)"
                )
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
                proposals.removeValue(forKey: parentID)
                candidatesByTransfer.removeValue(forKey: parentID)
                registeredTransferIDs = registeredTransferIDs.filter {
                    $0.key != parentID && $0.value != parentID
                }
                throw persistenceFailure(error)
            }
        }

        let result: StreamingTransferResult
        do {
            result = try await execute(
                runProposal,
                approved: approved,
                destinationDirectory: effectiveDestinationDirectory,
                progress: progress
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            if !isPaused(transferID: parentID) && !isPaused(transferID: proposal.transferID) && !isHandoffInProgress(transferID: parentID) {
                await handleHLSCancellation(
                    parentID: parentID,
                    transferID: parentID,
                    proposal: runProposal
                )
            }
            throw StreamingDownloadOrchestratorError.cancelled
        } catch let error as StreamingDownloadOrchestratorError where error == .cancelled {
            if !isPaused(transferID: parentID) && !isPaused(transferID: proposal.transferID) && !isHandoffInProgress(transferID: parentID) {
                await handleHLSCancellation(
                    parentID: parentID,
                    transferID: parentID,
                    proposal: runProposal
                )
            }
            throw error
        } catch let error as StreamingDownloadOrchestratorError where error == .transferAlreadyRunning {
            PipelineLogger.shared.log("[HLS Pipeline] Duplicate resume request rejected for \(parentID). Preserving active transfer state.")
            throw error
        } catch {
            let isCancelled = self.cancelledTransfers.contains(parentID) ||
                              self.cancelledTransfers.contains(proposal.transferID) ||
                              Task.isCancelled ||
                              (error as? URLError)?.code == .cancelled ||
                              (error as? StreamingDownloadOrchestratorError) == .cancelled ||
                              error is CancellationError
            if isCancelled {
                if !isPaused(transferID: parentID) && !isPaused(transferID: proposal.transferID) && !isHandoffInProgress(transferID: parentID) {
                    await handleHLSCancellation(
                        parentID: parentID,
                        transferID: parentID,
                        proposal: runProposal
                    )
                }
                throw StreamingDownloadOrchestratorError.cancelled
            }
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
            }
            await cleanupHLSChildRecords(proposal: runProposal)
            do {
                try await persistHLSState(id: parentID, state: .failed)
                throw error
            } catch {
                throw error
            }
        }
        let allPlanned = transferPlan.allResources
        let completed = zip(allPlanned, result.localFiles).map {
            HLSCompletedResource(resource: $0.0, fileURL: $0.1)
        }

        // Pre-assembly validation and reconciliation:
        // Verify every completed segment exists on disk and is non-empty.
        // If an unexpected filesystem event or race removed a segment, perform targeted re-download.
        var validatedCompleted: [HLSCompletedResource] = []
        for item in completed {
            let path = item.fileURL.path
            let exists = FileManager.default.fileExists(atPath: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            if exists && size > 0 {
                validatedCompleted.append(item)
            } else {
                PipelineLogger.shared.log("[HLS Reconciliation] Missing or empty segment detected for order \(item.resource.order) at \(path). Performing targeted re-download...")
                guard let transferResource = runProposal.resources.first(where: { $0.identity.order == item.resource.order }) else {
                    PipelineLogger.shared.log("[HLS Reconciliation] Transfer resource not found for order \(item.resource.order).")
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: item.resource.order)
                }
                let redownloaded = try await downloadSegment(
                    resource: transferResource,
                    index: item.resource.order,
                    proposal: runProposal,
                    destinationDirectory: effectiveDestinationDirectory,
                    pipelineTag: "[HLS Reconciliation]"
                )
                let recheckSize = (try? FileManager.default.attributesOfItem(atPath: redownloaded.destinationURL.path)[.size] as? Int64) ?? 0
                guard FileManager.default.fileExists(atPath: redownloaded.destinationURL.path) && recheckSize > 0 else {
                    PipelineLogger.shared.log("[HLS Reconciliation] Targeted re-download failed for segment \(item.resource.order).")
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: item.resource.order)
                }
                validatedCompleted.append(HLSCompletedResource(resource: item.resource, fileURL: redownloaded.destinationURL))
                PipelineLogger.shared.log("[HLS Reconciliation] Successfully recovered missing segment \(item.resource.order) (\(recheckSize) bytes).")
            }
        }

        do {
            // Mark assembly in-progress before calling the reconstructor.
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                throw StreamingDownloadOrchestratorError.cancelled
            }
            try await persistHLSAssemblyState(id: parentID, state: .inProgress)

            let assemblyOutput = try await HLSVODReconstructor.assemble(
                transferPlan: transferPlan,
                completedResources: validatedCompleted,
                destinationURL: finalOutputURL,
                temporaryDirectoryURL: destinationDirectory.appendingPathComponent(
                    ".media-assembly",
                    isDirectory: true
                ),
                remuxTSToMP4: remuxTSToMP4
            )
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                throw StreamingDownloadOrchestratorError.cancelled
            }

            // Step 3: Validate the final published output file before completing download
            let isMPEGTS = transferPlan.allResources.allSatisfy { $0.kind != .initializationMap }
            let isRemuxed = isMPEGTS && assemblyOutput.destinationURL.pathExtension.lowercased() == "mp4"
            let validationReport = MediaIntegrityValidator.validateHLSOutput(
                fileURL: assemblyOutput.destinationURL,
                isRemuxedMPEGTS: isRemuxed
            )
            guard validationReport.outcome.isConfirmedValid else {
                let failureReason = validationReport.outcome.localizedDescription
                PipelineLogger.shared.log("[HLS Pipeline] Final output validation failed: \(failureReason). Preserving downloaded segments for recovery.")
                throw StreamingDownloadOrchestratorError.hlsReconstructionFailed(
                    HLSVODReconstructionError.assemblyFailed(
                        .finalValidationFailed(reason: failureReason)
                    )
                )
            }
            if let engine = self.downloadEngine {
                let finalSize = FileManager.default.fileSize(atPath: assemblyOutput.destinationURL.path) ?? 0
                _ = try await engine.completeStreamingDownload(
                    id: parentID,
                    finalFileURL: assemblyOutput.destinationURL,
                    totalBytes: finalSize
                )
                PipelineLogger.shared.log("[HLS Pipeline] Successfully completed stream in DownloadEngine: \(assemblyOutput.destinationURL.path)")
            }
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                throw StreamingDownloadOrchestratorError.cancelled
            }
            // Mark the HLS record as fully completed.
            try await persistHLSAssemblyState(id: parentID, state: .completed)
            try await persistHLSState(id: parentID, state: .completed)
            let hlsFilename = finalOutputURL.lastPathComponent
            DownloadNotificationManager.postDownloadCompletedNotification(filename: hlsFilename, downloadID: parentID)

            // Segment records and raw files are implementation details. Keep
            // the completed parent record for lifecycle/reconciliation, but
            // remove the child records and raw artifacts after a successful
            // assembly. Failure paths intentionally preserve both.
            await cleanupCompletedStreamingArtifacts(
                proposal: runProposal,
                segmentDirectory: destinationDirectory,
                outputURL: assemblyOutput.destinationURL
            )

            if let subtitleURL = transferPlan.subtitleURL {
                await downloadAndSaveSubtitle(
                    from: subtitleURL,
                    candidate: candidatesByTransfer[runProposal.transferID],
                    finalOutputURL: assemblyOutput.destinationURL
                )
            }
            return assemblyOutput
        } catch is CancellationError {
            await handleHLSCancellation(
                parentID: parentID,
                transferID: parentID,
                proposal: runProposal
            )
            throw StreamingDownloadOrchestratorError.cancelled
        } catch let error as StreamingDownloadOrchestratorError where error == .cancelled {
            await handleHLSCancellation(
                parentID: parentID,
                transferID: parentID,
                proposal: runProposal
            )
            throw error
        } catch let error as HLSVODReconstructionError {
            let failReason: String
            if case .assemblyFailed(let assemblyError) = error {
                failReason = assemblyError.localizedDescription
            } else {
                failReason = error.localizedDescription
            }
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: failReason)
            }
            // Preserve segments for recovery; mark assembly as failed.
            await cleanupHLSChildRecords(proposal: runProposal)
            let failure = StreamingDownloadOrchestratorError.hlsReconstructionFailed(error)
            do {
                try await persistHLSAssemblyState(id: parentID, state: .failed)
                try await persistHLSState(id: parentID, state: .failed)
                throw failure
            } catch {
                throw error
            }
        } catch {
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
            }
            await cleanupHLSChildRecords(proposal: runProposal)
            do {
                try await persistHLSState(id: parentID, state: .failed)
                throw error
            } catch {
                throw error
            }
        }
    }

    /// Removes a parent HLS transfer and all of its durable child state. The
    /// assembled output is deleted only when the caller explicitly requests it.
    public func removePersistedTransfer(id: String, deleteOutputFile: Bool) async {
        guard let persistence = hlsPersistenceStore else { return }
        let parentID = hlsParentID(for: id)
        let record: HLSTransferRecord?
        if let direct = try? await persistence.load(id: parentID) {
            record = direct
        } else if let all = try? await persistence.loadAll() {
            record = all.first { $0.id == id || $0.manifestURL.absoluteString == id }
        } else {
            record = nil
        }
        guard let record else { return }

        cancelledTransfers.insert(record.id)
        await segmentExecutor.cancel(transferID: record.id)
        await purgeInternalStreamingSegmentRecords(in: record.segmentDirectoryURL)

        var fileDeletionFailed = false
        if FileManager.default.fileExists(atPath: record.segmentDirectoryURL.path) {
            do {
                try FileManager.default.removeItem(at: record.segmentDirectoryURL)
                PipelineLogger.shared.log("[HLS Cleanup] Removed segment directory: \(record.segmentDirectoryURL.path)")
            } catch {
                fileDeletionFailed = true
                let nsErr = error as NSError
                PipelineLogger.shared.log("[FileSystem] Operation: removeItem, Path: \(record.segmentDirectoryURL.path), Domain: \(nsErr.domain), Code: \(nsErr.code), Description: \(nsErr.localizedDescription), UserInfo: \(nsErr.userInfo)")
            }
        }
        if deleteOutputFile && FileManager.default.fileExists(atPath: record.outputDestinationURL.path) {
            do {
                try FileManager.default.removeItem(at: record.outputDestinationURL)
                PipelineLogger.shared.log("[HLS Cleanup] Removed output file: \(record.outputDestinationURL.path)")
            } catch {
                fileDeletionFailed = true
                let nsErr = error as NSError
                PipelineLogger.shared.log("[FileSystem] Operation: removeItem, Path: \(record.outputDestinationURL.path), Domain: \(nsErr.domain), Code: \(nsErr.code), Description: \(nsErr.localizedDescription), UserInfo: \(nsErr.userInfo)")
            }
        }

        if !fileDeletionFailed {
            do {
                try await persistence.delete(id: record.id)
                PipelineLogger.shared.log("[HLS Cleanup] Deleted persistence record: \(record.id)")
            } catch {
                PipelineLogger.shared.log("[HLS Cleanup] Warning: Failed to delete persistence record \(record.id): \(error.localizedDescription)")
            }
        } else {
            PipelineLogger.shared.log("[HLS Cleanup] Incomplete deletion for \(record.id): Files remain on disk. Retaining record for future cleanup.")
            var updated = record
            updated.state = .failed
            do {
                try await persistence.save(updated)
            } catch {
                PipelineLogger.shared.log("[HLS Cleanup] Failed to save updated failed state for \(record.id): \(error)")
            }
        }

        registeredTransferIDs = registeredTransferIDs.filter {
            $0.key != record.id && $0.value != record.id
        }
        proposals.removeValue(forKey: record.id)
        candidatesByTransfer.removeValue(forKey: record.id)
    }

    /// Deletes selected completed HLS segment artifacts and removes their
    /// checkpoint orders. The parent output is intentionally untouched.
    ///
    /// Segment filenames are derived from the prepared manifest resource
    /// identity, so a cached proposal is preferred and a fresh manifest load
    /// is used after relaunch when necessary. Incomplete orders have no
    /// completed checkpoint/file and are ignored.
    @discardableResult
    public func deleteHLSSegments(id: String, orders: Set<Int>) async throws -> Int {
        guard let persistence = hlsPersistenceStore else { return 0 }
        guard !orders.isEmpty else { return 0 }

        let parentID = hlsParentID(for: id)
        guard let record = try await persistence.load(id: parentID) else {
            throw HLSPersistenceError.recordNotFound(id: parentID)
        }
        guard record.state != .completed, record.assemblyState != .completed else {
            return 0
        }

        let completedOrders = orders.intersection(record.completedSegmentOrders)
        guard !completedOrders.isEmpty else { return 0 }

        let proposal: StreamingTransferProposal
        if let cached = proposals[parentID] ?? proposals[id], cached.manifest.kind == .hls {
            proposal = cached
        } else {
            let candidate = try StreamingManifestCandidate(url: record.manifestURL)
            let prepared = try await prepare(candidate: candidate)
            guard prepared.manifest.kind == .hls else {
                throw StreamingDownloadOrchestratorError.hlsSegmentMetadataUnavailable
            }
            proposal = prepared
        }

        let resourcesByOrder = Dictionary(uniqueKeysWithValues: proposal.resources.map { ($0.identity.order, $0) })
        let selectedResources = completedOrders.compactMap { resourcesByOrder[$0] }
        guard selectedResources.count == completedOrders.count else {
            throw StreamingDownloadOrchestratorError.hlsSegmentMetadataUnavailable
        }

        let fileManager = FileManager.default
        for resource in selectedResources {
            let segmentURL = record.segmentDirectoryURL
                .appendingPathComponent("\(resource.identity.value).part", isDirectory: false)
            if fileManager.fileExists(atPath: segmentURL.path) {
                do {
                    try fileManager.removeItem(at: segmentURL)
                } catch {
                    PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to remove segment file \(segmentURL.path): \(error)")
                }
            }
            if let engine = downloadEngine {
                do {
                    try await engine.persistenceStore.delete(tag: resource.identity.value)
                } catch {
                    PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to delete segment record \(resource.identity.value): \(error)")
                }
            }
        }

        _ = try await persistence.removeSegments(id: parentID, orders: completedOrders)
        return completedOrders.count
    }

    func proposalForRun(
        _ proposal: StreamingTransferProposal,
        transferID: String
    ) -> StreamingTransferProposal {
        let resources = proposal.resources.map { resource in
            StreamingTransferResource(
                identity: identity(
                    transferID: transferID,
                    order: resource.identity.order,
                    url: resource.url,
                    range: resource.byteRange
                ),
                url: resource.url,
                byteRange: resource.byteRange
            )
        }
        return StreamingTransferProposal(
            transferID: transferID,
            manifestID: proposal.manifestID,
            manifest: proposal.manifest,
            resources: resources,
            estimatedTransferBytes: proposal.estimatedTransferBytes,
            transportPolicy: proposal.transportPolicy
        )
    }

    /// Removes implementation-detail child records while retaining the HLS
    /// parent job record and its completed-order checkpoint.
    func cleanupHLSChildRecords(proposal: StreamingTransferProposal) async {
        guard let engine = downloadEngine else { return }
        for resource in proposal.resources {
            do {
                try await engine.persistenceStore.delete(tag: resource.identity.value)
            } catch {
                PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to delete child segment record \(resource.identity.value): \(error)")
            }
        }
    }

    func cleanupCompletedStreamingArtifacts(
        proposal: StreamingTransferProposal,
        segmentDirectory: URL,
        outputURL: URL
    ) async {
        await cleanupHLSChildRecords(proposal: proposal)

        let fileManager = FileManager.default
        let mediaAssemblyDir = segmentDirectory.appendingPathComponent(".media-assembly", isDirectory: true)
        do {
            try fileManager.removeItem(at: mediaAssemblyDir)
        } catch {
            PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to remove mediaAssemblyDir: \(error)")
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: segmentDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        for child in children {
            if child.pathExtension == "part" || child.lastPathComponent == ".media-assembly" {
                do {
                    try fileManager.removeItem(at: child)
                } catch {
                    PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to remove child \(child.path): \(error)")
                }
            }
        }

        // `downloadHLS` or `downloadDASH` may place the output inside the temporary directory;
        // remove the directory only when doing so cannot remove the final file.
        let directoryPath = segmentDirectory.standardizedFileURL.path
        let outputPath = outputURL.standardizedFileURL.path
        if !outputPath.hasPrefix(directoryPath + "/") {
            let isEmpty: Bool
            do {
                isEmpty = try fileManager.contentsOfDirectory(atPath: segmentDirectory.path).isEmpty
            } catch {
                isEmpty = false
            }
            if isEmpty {
                do {
                    try fileManager.removeItem(at: segmentDirectory)
                } catch {
                    PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to remove segmentDirectory: \(error)")
                }
            }
        }
    }

    /// Executes a finite DASH proposal through the existing segment executor and
    /// then reconstructs clear video/audio resources into a validated output.
    public func executeAndAssembleDASH(
        _ proposal: StreamingTransferProposal,
        approved: Bool,
        destinationDirectory: URL,
        outputURL: URL,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil,
        runID: String? = nil
    ) async throws -> MediaAssemblyOutput {
        guard case .dash(let transferPlan) = proposal.manifest else {
            throw StreamingDownloadOrchestratorError.unsupportedManifest(.hls)
        }
        let isTextOnly = transferPlan.video == nil && transferPlan.audio == nil && transferPlan.text != nil
        let isTTML = transferPlan.text?.codecs?.lowercased().contains("ttml") == true ||
                     transferPlan.text?.codecs?.lowercased().contains("stpp") == true ||
                     transferPlan.text?.codecs?.lowercased().contains("im1t") == true ||
                     transferPlan.text?.resources.contains(where: {
                         let ext = $0.url.pathExtension.lowercased()
                         return ext == "ttml" || ext == "xml"
                     }) == true
        let finalOutputURL: URL
        if isTextOnly && outputURL.pathExtension.lowercased() == "mp4" {
            let ext = isTTML ? "ttml" : "vtt"
            finalOutputURL = outputURL.deletingPathExtension().appendingPathExtension(ext)
        } else {
            finalOutputURL = outputURL
        }
        let originalSourceURL = candidatesByTransfer[proposal.transferID]?.url ?? transferPlan.manifestURL
        let parentID = runID ?? proposal.transferID
        let runProposal = proposalForRun(proposal, transferID: parentID)
        let manifestKey = originalSourceURL.absoluteString
        registeredTransferIDs[manifestKey] = parentID
        registeredTransferIDs[transferPlan.manifestURL.absoluteString] = parentID
        registeredTransferIDs[parentID] = parentID
        proposals[parentID] = runProposal
        proposals[proposal.transferID] = runProposal

        if let engine = self.downloadEngine {
            let estimated = proposal.estimatedTransferBytes ?? (Int64(proposal.resources.count) * 1_000_000)
            let textMime = isTTML ? "application/ttml+xml" : "text/vtt"
            let mimeType = isTextOnly ? textMime : "video/mp4"
            do {
                _ = try await engine.registerStreamingDownload(
                    id: parentID,
                    manifestURL: originalSourceURL,
                    destinationURL: finalOutputURL,
                    filename: finalOutputURL.lastPathComponent,
                    totalBytes: estimated,
                    mimeType: mimeType
                )
                PipelineLogger.shared.log("[DASH Pipeline] Active stream registered with DownloadEngine: \(parentID)")
            } catch {
                PipelineLogger.shared.log("[DASH Pipeline] Failed to register stream \(parentID): \(error.localizedDescription)")
                throw error
            }
        }

        let result: StreamingTransferResult
        do {
            result = try await execute(
                runProposal,
                approved: approved,
                destinationDirectory: destinationDirectory,
                progress: progress
            )
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                throw StreamingDownloadOrchestratorError.cancelled
            }
        } catch {
            let isCancelled = self.cancelledTransfers.contains(parentID) ||
                              self.cancelledTransfers.contains(proposal.transferID) ||
                              Task.isCancelled ||
                              (error as? URLError)?.code == .cancelled ||
                              (error as? StreamingDownloadOrchestratorError) == .cancelled ||
                              error is CancellationError
            if isCancelled {
                await segmentExecutor.cancel(transferID: parentID)
                await cleanupHLSChildRecords(proposal: runProposal)
                await persistDASHState(id: parentID, state: .cancelled)
                if let engine = self.downloadEngine {
                    do {
                        try await engine.cancelDownload(id: parentID)
                    } catch {
                        PipelineLogger.shared.log("[DASH Pipeline] Failed to cancel download \(parentID): \(error)")
                    }
                }
                throw StreamingDownloadOrchestratorError.cancelled
            }
            await persistDASHState(id: parentID, state: .failed)
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
            }
            await cleanupHLSChildRecords(proposal: runProposal)
            throw error
        }

        let completed = zip(transferPlan.resources, result.localFiles).map {
            DASHCompletedResource(resource: $0.0, fileURL: $0.1)
        }
        do {
            await persistDASHAssemblyState(id: parentID, assemblyState: .inProgress)
            let assemblyOutput: MediaAssemblyOutput
            if isTextOnly, let textPlan = transferPlan.text {
                assemblyOutput = try assembleDASHSubtitles(
                    textPlan: textPlan,
                    completedResources: completed,
                    destinationURL: finalOutputURL
                )
            } else {
                assemblyOutput = try await DASHVODReconstructor.assemble(
                    transferPlan: transferPlan,
                    completedResources: completed,
                    destinationURL: finalOutputURL,
                    temporaryDirectoryURL: destinationDirectory.appendingPathComponent(
                        ".media-assembly",
                        isDirectory: true
                    )
                )
                if let textPlan = transferPlan.text {
                    let sidecarExt = isTTML ? "ttml" : "vtt"
                    let sidecarURL = finalOutputURL.deletingPathExtension().appendingPathExtension(sidecarExt)
                    _ = try? assembleDASHSubtitles(
                        textPlan: textPlan,
                        completedResources: completed,
                        destinationURL: sidecarURL
                    )
                }
            }
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                await persistDASHState(id: parentID, state: .cancelled)
                if let engine = self.downloadEngine {
                    do {
                        try await engine.cancelDownload(id: parentID)
                    } catch {
                        PipelineLogger.shared.log("[DASH Pipeline] Failed to cancel download \(parentID): \(error)")
                    }
                }
                throw StreamingDownloadOrchestratorError.cancelled
            }

            // Step 3: Validate the final published output file before completing download
            if !isTextOnly {
                let validationReport = MediaIntegrityValidator.validateDASHOutput(fileURL: assemblyOutput.destinationURL)
                guard validationReport.outcome.isConfirmedValid else {
                    let failureReason = validationReport.outcome.localizedDescription
                    PipelineLogger.shared.log("[DASH Pipeline] Final output validation failed: \(failureReason). Preserving downloaded segments for recovery.")
                    await persistDASHAssemblyState(id: parentID, assemblyState: .failed)
                    throw StreamingDownloadOrchestratorError.dashReconstructionFailed(
                        DASHVODReconstructionError.assemblyFailed(
                            .finalValidationFailed(reason: failureReason)
                        )
                    )
                }
            } else {
                guard FileManager.default.fileExists(atPath: assemblyOutput.destinationURL.path),
                      (FileManager.default.fileSize(atPath: assemblyOutput.destinationURL.path) ?? 0) > 0 else {
                    await persistDASHAssemblyState(id: parentID, assemblyState: .failed)
                    throw StreamingDownloadOrchestratorError.dashReconstructionFailed(
                        DASHVODReconstructionError.assemblyFailed(
                            .finalValidationFailed(reason: "Subtitle file is empty or missing.")
                        )
                    )
                }
            }
            if let engine = self.downloadEngine {
                let finalSize = FileManager.default.fileSize(atPath: assemblyOutput.destinationURL.path) ?? 0
                _ = try await engine.completeStreamingDownload(
                    id: parentID,
                    finalFileURL: assemblyOutput.destinationURL,
                    totalBytes: finalSize
                )
                PipelineLogger.shared.log("[DASH Pipeline] Successfully completed stream in DownloadEngine: \(assemblyOutput.destinationURL.path)")
            }
            await persistDASHState(id: parentID, state: .completed)
            await persistDASHAssemblyState(id: parentID, assemblyState: .completed)
            let dashFilename = assemblyOutput.destinationURL.lastPathComponent
            DownloadNotificationManager.postDownloadCompletedNotification(filename: dashFilename, downloadID: parentID)
            try Task.checkCancellation()
            if isCancelled(transferID: parentID) {
                if let engine = self.downloadEngine {
                    do {
                        try await engine.cancelDownload(id: parentID)
                    } catch {
                        PipelineLogger.shared.log("[DASH Pipeline] Failed to cancel download \(parentID): \(error)")
                    }
                }
                throw StreamingDownloadOrchestratorError.cancelled
            }

            // Segment records and raw files are implementation details.
            // Remove the raw artifacts only after a successful assembly and engine completion.
            // Failure paths intentionally preserve both for recovery.
            await cleanupCompletedStreamingArtifacts(
                proposal: proposal,
                segmentDirectory: destinationDirectory,
                outputURL: assemblyOutput.destinationURL
            )
            return assemblyOutput
        } catch let error as DASHVODReconstructionError {
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
            }
            throw StreamingDownloadOrchestratorError.dashReconstructionFailed(error)
        } catch {
            let isCancelled = self.cancelledTransfers.contains(parentID) ||
                              self.cancelledTransfers.contains(proposal.transferID) ||
                              Task.isCancelled ||
                              (error as? URLError)?.code == .cancelled ||
                              (error as? StreamingDownloadOrchestratorError) == .cancelled ||
                              error is CancellationError
            if isCancelled {
                await segmentExecutor.cancel(transferID: parentID)
                await cleanupHLSChildRecords(proposal: proposal)
                if let engine = self.downloadEngine {
                    do {
                        try await engine.cancelDownload(id: parentID)
                    } catch {
                        PipelineLogger.shared.log("[DASH Pipeline] Failed to cancel download \(parentID): \(error)")
                    }
                }
                throw StreamingDownloadOrchestratorError.cancelled
            }
            if let engine = self.downloadEngine {
                await engine.failStreamingDownload(id: parentID, reason: error.localizedDescription)
            }
            throw error
        }
    }

    /// Convenience method to download an HLS stream directly from a manifest URL,
    /// executing and assembling into the specified output URL (or destination directory).
    @discardableResult
    public func downloadHLS(
        manifestURL: URL,
        destinationDirectory: URL? = nil,
        outputURL: URL? = nil,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil,
        transportPolicy: HTTPTransportPolicy? = nil,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil
    ) async throws -> MediaAssemblyOutput {
        PipelineLogger.shared.log("[HLS Pipeline] downloadHLS started for manifest: \(manifestURL.absoluteString)")
        do {
            let effectivePolicy = transportPolicy ?? .background
            let candidate = try StreamingManifestCandidate(
                url: manifestURL,
                browserSessionSnapshot: browserSessionSnapshot,
                transportPolicy: effectivePolicy
            )
            PipelineLogger.shared.log("[HLS Pipeline] 1. Manifest candidate created. Fetching and preparing proposal...")
            let proposal = try await prepare(candidate: candidate)
            guard case .hls(let transferPlan) = proposal.manifest else {
                let errorMsg = "Prepared proposal is not HLS."
                PipelineLogger.shared.log("[HLS Pipeline] Error: \(errorMsg)")
                throw StreamingDownloadOrchestratorError.unsupportedManifest(.dash)
            }
            PipelineLogger.shared.log("[HLS Pipeline] 3. HLSTransferPlanner generated transfer plan with \(transferPlan.resources.count) segments.")
            let dest = destinationDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let finalOut = outputURL ?? dest.appendingPathComponent(HLSVODReconstructionPlanner.suggestedFilename(for: transferPlan), isDirectory: false)
            PipelineLogger.shared.log("[HLS Pipeline] 4. SegmentDownloader starting downloads. Output destination: \(finalOut.path)")
            let result = try await executeAndAssembleHLS(
                proposal,
                approved: true,
                destinationDirectory: dest,
                outputURL: finalOut,
                progress: progress
            )
            PipelineLogger.shared.log("[HLS Pipeline] downloadHLS successfully completed: \(result.destinationURL.path)")
            return result
        } catch {
            PipelineLogger.shared.log("[HLS Pipeline] Error: \(error.localizedDescription)")
            throw error
        }
    }

    /// Convenience method to download a DASH stream directly from a manifest URL,
    /// executing and assembling into the specified output URL (or destination directory).
    @discardableResult
    public func downloadDASH(
        manifestURL: URL,
        destinationDirectory: URL? = nil,
        outputURL: URL? = nil,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil,
        transportPolicy: HTTPTransportPolicy? = nil,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil
    ) async throws -> MediaAssemblyOutput {
        PipelineLogger.shared.log("[DASH Pipeline] downloadDASH started for manifest: \(manifestURL.absoluteString)")
        do {
            let effectivePolicy = transportPolicy ?? .background
            let candidate = try StreamingManifestCandidate(
                url: manifestURL,
                browserSessionSnapshot: browserSessionSnapshot,
                transportPolicy: effectivePolicy
            )
            PipelineLogger.shared.log("[DASH Pipeline] 1. Manifest candidate created. Fetching and preparing proposal...")
            let proposal = try await prepare(candidate: candidate)
            guard case .dash(let transferPlan) = proposal.manifest else {
                let errorMsg = "Prepared proposal is not DASH."
                PipelineLogger.shared.log("[DASH Pipeline] Error: \(errorMsg)")
                throw StreamingDownloadOrchestratorError.unsupportedManifest(.hls)
            }
            PipelineLogger.shared.log("[DASH Pipeline] 3. DASHTransferPlanner generated transfer plan with \(transferPlan.resources.count) segments.")
            let dest = destinationDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let finalOut = outputURL ?? dest.appendingPathComponent(DASHVODReconstructionPlanner.suggestedFilename(for: transferPlan), isDirectory: false)
            PipelineLogger.shared.log("[DASH Pipeline] 4. SegmentDownloader starting downloads. Output destination: \(finalOut.path)")
            let result = try await executeAndAssembleDASH(
                proposal,
                approved: true,
                destinationDirectory: dest,
                outputURL: finalOut,
                progress: progress
            )
            PipelineLogger.shared.log("[DASH Pipeline] downloadDASH successfully completed: \(result.destinationURL.path)")
            return result
        } catch {
            PipelineLogger.shared.log("[DASH Pipeline] Error: \(error.localizedDescription)")
            throw error
        }
    }

    func manifestHeaders(for candidate: StreamingManifestCandidate) -> [String: String] {
        guard let context = candidate.browserRequestContext else { return [:] }
        let headers = context.effectiveHeaders(for: candidate.url)
        return BrowserHeaderFilter.stripCredentialsOnRedirect(
            headers: headers,
            from: context.url,
            to: candidate.url,
            allowedOrigins: context.allowedCredentialOrigins
        )
    }

    func requestHeaders(
        for resource: StreamingTransferResource,
        manifest: StreamingTransferManifest
    ) -> [String: String] {
        let context: BrowserRequestContext?
        switch manifest {
        case .hls(let plan):
            context = plan.browserRequestContext
        case .dash(let plan):
            context = plan.browserRequestContext
        }
        guard let context else { return [:] }
        let headers: [String: String]
        switch manifest {
        case .hls(let plan):
            guard let planned = plan.allResources.first(where: { $0.url == resource.url && $0.order == resource.identity.order }) else { return [:] }
            headers = plan.requestHeaders(for: planned)
        case .dash(let plan):
            guard let planned = plan.resources.first(where: { $0.url == resource.url && $0.order == resource.identity.order }) else { return [:] }
            headers = plan.requestHeaders(for: planned)
        }
        return BrowserHeaderFilter.stripCredentialsOnRedirect(
            headers: headers,
            from: context.url,
            to: resource.url,
            allowedOrigins: context.allowedCredentialOrigins
        )
    }

    func segmentRequestHeaders(
        for resource: StreamingTransferResource,
        manifest: StreamingTransferManifest,
        transferID: String
    ) async -> [String: String] {
        var headers = requestHeaders(for: resource, manifest: manifest)

        let candidate = candidatesByTransfer[transferID]
        let snapshot = candidate?.browserSessionSnapshot ?? DownloadRequestEnricher.sharedSessionSnapshot.snapshot

        var freshCookies: [BrowserCookie] = []
        if let dynamic = await dynamicCookieProvider?(resource.url), !dynamic.isEmpty {
            freshCookies.append(contentsOf: dynamic)
        } else {
            let cookies = await DownloadRequestEnricher.dynamicCookies(for: resource.url)
            freshCookies.append(contentsOf: cookies.compactMap(BrowserCookie.init(from:)))
        }
        if let snapshot {
            freshCookies.append(contentsOf: snapshot.allCookies.compactMap(BrowserCookie.init(from:)))
        }

        if !freshCookies.isEmpty {
            let matchingFresh = freshCookies.filter { cookie in
                cookie.matches(url: resource.url)
            }
            if !matchingFresh.isEmpty {
                var cookieMap: [String: String] = [:]
                if let existingHeader = headers["Cookie"] {
                    for pair in existingHeader.split(separator: ";") {
                        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                        if parts.count == 2 {
                            cookieMap[parts[0]] = parts[1]
                        }
                    }
                }
                for c in matchingFresh.sorted(by: { $0.path.count > $1.path.count }) {
                    cookieMap[c.name] = c.value
                }
                let mergedCookies = cookieMap.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
                if !mergedCookies.isEmpty {
                    headers["Cookie"] = mergedCookies
                }
            }
        }

        return headers
    }

    func makeResources(
        from manifest: StreamingTransferManifest,
        transferID: String
    ) throws -> [StreamingTransferResource] {
        switch manifest {
        case .hls(let plan):
            var previousEndByURL: [URL: Int64] = [:]
            return try plan.allResources.map { resource in
                let range: StreamingByteRange?
                if let byteRange = resource.byteRange {
                    let start = byteRange.offset ?? ((previousEndByURL[resource.url] ?? -1) + 1)
                    guard start >= 0, byteRange.length > 0,
                          byteRange.length <= Int64.max - start else {
                        throw StreamingDownloadOrchestratorError.invalidByteRange
                    }
                    range = try StreamingByteRange(start: start, end: start + byteRange.length - 1)
                    previousEndByURL[resource.url] = range?.end
                } else {
                    range = nil
                }
                return StreamingTransferResource(
                    identity: identity(transferID: transferID, order: resource.order, url: resource.url, range: range),
                    url: resource.url,
                    byteRange: range
                )
            }
        case .dash(let plan):
            return try plan.resources.map { resource in
                let range = try resource.byteRange.map {
                    try StreamingByteRange(start: $0.start, end: $0.end)
                }
                return StreamingTransferResource(
                    identity: identity(transferID: transferID, order: resource.order, url: resource.url, range: range),
                    url: resource.url,
                    byteRange: range
                )
            }
        }
    }

    func identity(
        transferID: String,
        order: Int,
        url: URL,
        range: StreamingByteRange?
    ) -> StreamingSegmentIdentity {
        let rangeText = range.map { "\($0.start)-\($0.end)" } ?? "full"
        let digest = EngineSHA256.hash(data: Data("\(transferID)|\(order)|\(url.absoluteString)|\(rangeText)".utf8))
        // Segment records are implementation details of the parent HLS/DASH
        // transfer. The queue restore path uses this namespace to avoid
        // exposing them as ordinary Downloads entries.
        return StreamingSegmentIdentity(transferID: transferID, order: order, value: "\(InternalStreamingConstants.segmentIDPrefix)\(digest.prefix(32))")
    }

    func estimatedBytes(for manifest: StreamingTransferManifest) -> Int64? {
        switch manifest {
        case .hls(let plan): return plan.estimatedTransferBytes
        case .dash(let plan): return plan.estimatedTransferBytes
        }
    }

    func fetchByteRange(
        url: URL,
        rangeString: String,
        candidate: StreamingManifestCandidate
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(rangeString)", forHTTPHeaderField: "Range")
        if let context = candidate.browserRequestContext {
            let headers = context.effectiveHeaders(for: url)
            for (key, val) in headers {
                request.setValue(val, forHTTPHeaderField: key)
            }
        }
        let session = ForegroundURLSession.make(maximumConnectionsPerHost: 1)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (httpResponse.statusCode == 200 || httpResponse.statusCode == 206) else {
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: 0)
        }
        return data
    }

    func downloadAndSaveSubtitle(
        from subtitleURL: URL,
        candidate: StreamingManifestCandidate?,
        finalOutputURL: URL,
        customSession: URLSession? = nil
    ) async {
        PipelineLogger.shared.log("[HLS Pipeline] Fetching subtitle from \(subtitleURL.absoluteString)...")
        do {
            let subtitleSession = customSession ?? ForegroundURLSession.make(maximumConnectionsPerHost: 1)
            var request = URLRequest(url: subtitleURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            let effectiveSnapshot = candidate?.browserSessionSnapshot
            request = DownloadRequestEnricher.enrich(request, snapshot: effectiveSnapshot, context: candidate?.browserRequestContext)
            if request.value(forHTTPHeaderField: "User-Agent") == nil,
               let ua = candidate?.browserRequestContext?.userAgent, !ua.isEmpty {
                request.setValue(ua, forHTTPHeaderField: "User-Agent")
            }
            if request.value(forHTTPHeaderField: "Referer") == nil {
                if let ref = candidate?.browserRequestContext?.referer ?? candidate?.browserRequestContext?.pageURL?.absoluteString {
                    let isDowngrade = subtitleURL.scheme?.lowercased() == "http" && (URL(string: ref)?.scheme?.lowercased() == "https")
                    if !isDowngrade {
                        request.setValue(ref, forHTTPHeaderField: "Referer")
                    }
                }
            }
            let (data, response) = try await subtitleSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                PipelineLogger.shared.log("[HLS Pipeline] Subtitle HTTP request returned non-200 code")
                return
            }

            let destinationVTT = finalOutputURL.deletingPathExtension().appendingPathExtension("vtt")
            let contentString = String(decoding: data, as: UTF8.self)

            if contentString.contains("WEBVTT") {
                let singleInput = WebVTTSegmentInput(text: contentString, playlistStartTime: 0.0, duration: 0.0)
                let assembledVTT = HLSWebVTTAssembler.assemble(segments: [singleInput])
                try Data(assembledVTT.utf8).write(to: destinationVTT, options: Data.WritingOptions.atomic)
                PipelineLogger.shared.log("[HLS Pipeline] Subtitle (.vtt) saved successfully to: \(destinationVTT.path)")
                return
            }

            if contentString.contains("#EXTM3U") {
                struct SubtitleSegmentDescriptor {
                    let url: URL
                    let playlistStartTime: Double
                    let duration: Double
                }

                var descriptors: [SubtitleSegmentDescriptor] = []
                let lines = contentString.components(separatedBy: "\n")
                var currentDuration: Double = 10.0
                var targetDuration: Double? = nil
                var cumulativeTime: Double = 0.0

                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("#EXT-X-TARGETDURATION:") {
                        let valStr = trimmed.replacingOccurrences(of: "#EXT-X-TARGETDURATION:", with: "").trimmingCharacters(in: .whitespaces)
                        if let td = Double(valStr) {
                            targetDuration = td
                            currentDuration = td
                        }
                    } else if trimmed.hasPrefix("#EXTINF:") {
                        let valStr = trimmed.replacingOccurrences(of: "#EXTINF:", with: "").trimmingCharacters(in: .whitespaces)
                        let commaIndex = valStr.firstIndex(of: ",") ?? valStr.endIndex
                        let durStr = String(valStr[..<commaIndex]).trimmingCharacters(in: .whitespaces)
                        if let dur = Double(durStr) {
                            currentDuration = dur
                        }
                    } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                        if let segURL = URL(string: trimmed, relativeTo: subtitleURL)?.absoluteURL {
                            descriptors.append(SubtitleSegmentDescriptor(
                                url: segURL,
                                playlistStartTime: cumulativeTime,
                                duration: currentDuration
                            ))
                            cumulativeTime += currentDuration
                            currentDuration = targetDuration ?? 10.0
                        }
                    }
                }

                if !descriptors.isEmpty {
                    var downloadedSegments: [WebVTTSegmentInput] = []
                    for desc in descriptors {
                        var segReq = URLRequest(url: desc.url)
                        segReq.httpMethod = "GET"
                        segReq.timeoutInterval = 30
                        segReq = DownloadRequestEnricher.enrich(segReq, snapshot: effectiveSnapshot, context: candidate?.browserRequestContext)
                        if segReq.value(forHTTPHeaderField: "User-Agent") == nil,
                           let ua = candidate?.browserRequestContext?.userAgent, !ua.isEmpty {
                            segReq.setValue(ua, forHTTPHeaderField: "User-Agent")
                        }
                        if segReq.value(forHTTPHeaderField: "Referer") == nil {
                            let ref = candidate?.browserRequestContext?.referer ?? candidate?.browserRequestContext?.pageURL?.absoluteString ?? subtitleURL.absoluteString
                            let isDowngrade = desc.url.scheme?.lowercased() == "http" && (URL(string: ref)?.scheme?.lowercased() == "https")
                            if !isDowngrade {
                                segReq.setValue(ref, forHTTPHeaderField: "Referer")
                            }
                        }
                        do {
                            let (segData, segResponse) = try await subtitleSession.data(for: segReq)
                            guard let segHTTP = segResponse as? HTTPURLResponse, (200...299).contains(segHTTP.statusCode) else {
                                PipelineLogger.shared.log("[HLS Pipeline] Subtitle segment HTTP failed: \(desc.url.absoluteString)")
                                continue
                            }
                            let segText = String(decoding: segData, as: UTF8.self)
                            downloadedSegments.append(WebVTTSegmentInput(
                                text: segText,
                                playlistStartTime: desc.playlistStartTime,
                                duration: desc.duration
                            ))
                        } catch {
                            PipelineLogger.shared.log("[HLS Pipeline] Subtitle segment fetch error: \(error.localizedDescription)")
                        }
                    }

                    guard !downloadedSegments.isEmpty else {
                        PipelineLogger.shared.log("[HLS Pipeline] All subtitle segments failed to download for: \(subtitleURL.absoluteString)")
                        return
                    }

                    let combinedVTT = HLSWebVTTAssembler.assemble(segments: downloadedSegments)
                    try Data(combinedVTT.utf8).write(to: destinationVTT, options: Data.WritingOptions.atomic)
                    PipelineLogger.shared.log("[HLS Pipeline] Assembled \(downloadedSegments.count)/\(descriptors.count) subtitle segments into: \(destinationVTT.path)")
                    return
                }
            }

            let trimmedLower = contentString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmedLower.isEmpty || trimmedLower.hasPrefix("<!doctype html") || trimmedLower.hasPrefix("<html") {
                PipelineLogger.shared.log("[HLS Pipeline] Subtitle content is HTML or empty, skipping: \(subtitleURL.absoluteString)")
                return
            }

            try data.write(to: destinationVTT, options: Data.WritingOptions.atomic)
            PipelineLogger.shared.log("[HLS Pipeline] Saved raw subtitle to: \(destinationVTT.path)")
        } catch {
            PipelineLogger.shared.log("[HLS Pipeline] Subtitle download skipped (non-fatal): \(error.localizedDescription)")
        }
    }

    func isTTMLContent(
        textPlan: DASHRepresentationTransferPlan,
        completedResources: [DASHCompletedResource],
        rawBuffers: [Data]
    ) -> Bool {
        if let codecs = textPlan.codecs?.lowercased(),
           codecs.contains("ttml") || codecs.contains("stpp") || codecs.contains("im1t") {
            return true
        }
        if completedResources.contains(where: {
            let ext = $0.resource.url.pathExtension.lowercased()
            return ext == "ttml" || ext == "xml"
        }) {
            return true
        }
        for buffer in rawBuffers {
            let sample = String(decoding: buffer.prefix(2048), as: UTF8.self).lowercased()
            if sample.contains("<tt") ||
               sample.contains("http://www.w3.org/ns/ttml") ||
               sample.contains("xmlns:tt") ||
               sample.contains("ebutt") {
                return true
            }
        }
        return false
    }

    func assembleDASHSubtitles(
        textPlan: DASHRepresentationTransferPlan,
        completedResources: [DASHCompletedResource],
        destinationURL: URL
    ) throws -> MediaAssemblyOutput {
        let textCompleted = completedResources.filter { $0.resource.mediaType == .text && $0.resource.kind == .mediaSegment }
        guard !textCompleted.isEmpty else {
            throw DASHVODReconstructionError.noMediaSegments
        }

        let fileManager = FileManager.default
        let parentDir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        var rawContentBuffers: [Data] = []
        for item in textCompleted {
            guard item.fileURL.isFileURL,
                  fileManager.fileExists(atPath: item.fileURL.path),
                  let data = try? Data(contentsOf: item.fileURL),
                  !data.isEmpty else {
                throw DASHVODReconstructionError.invalidResourceFile
            }
            rawContentBuffers.append(data)
        }

        // Handle TTML text tracks: preserve standalone single-document TTML; reject unsupported segmented TTML.
        if isTTMLContent(textPlan: textPlan, completedResources: textCompleted, rawBuffers: rawContentBuffers) {
            if textCompleted.count > 1 {
                PipelineLogger.shared.log("[DASH Pipeline] Segmented TTML subtitle track (\(textCompleted.count) segments) cannot be concatenated or assembled.")
                throw DASHVODReconstructionError.unsupportedSubtitleFormat("TTML")
            }
            let targetURL = destinationURL.pathExtension.lowercased() == "vtt"
                ? destinationURL.deletingPathExtension().appendingPathExtension("ttml")
                : destinationURL
            try rawContentBuffers[0].write(to: targetURL, options: .atomic)
            PipelineLogger.shared.log("[DASH Pipeline] Preserved single TTML subtitle track into: \(targetURL.path)")
            let finalSize = fileManager.fileSize(atPath: targetURL.path) ?? Int64(rawContentBuffers[0].count)
            let validationReport = MediaAssemblyValidationReport(
                container: .ttml,
                trackCount: 1,
                mediaSegmentCount: 1,
                totalInputBytes: finalSize,
                isReadyForAssembly: true,
                isStructurallyValid: true,
                isPlayableConfirmed: true,
                validationDetails: "Preserved standalone TTML subtitle document.",
                state: .assemblyCompleted
            )
            return MediaAssemblyOutput(
                destinationURL: targetURL,
                container: .ttml,
                trackCount: 1,
                byteCount: finalSize,
                validation: validationReport
            )
        }

        var downloadedSegments: [WebVTTSegmentInput] = []
        var cumulativeTime: Double = 0.0
        var isAllWebVTT = true

        for (index, item) in textCompleted.enumerated() {
            let data = rawContentBuffers[index]
            let contentString = String(decoding: data, as: UTF8.self)
            if contentString.contains("WEBVTT") || contentString.contains("-->") {
                let timescale = item.resource.timescale > 0 ? Double(item.resource.timescale) : 1000.0
                let segTime: Double
                if let st = item.resource.segmentTime {
                    let computed = Double(st) / timescale
                    if computed < cumulativeTime && (cumulativeTime - computed) > 1.0 {
                        segTime = cumulativeTime
                    } else {
                        segTime = computed
                    }
                } else {
                    segTime = cumulativeTime
                }
                let dur: Double
                if let d = item.resource.duration {
                    dur = Double(d) / timescale
                } else {
                    dur = 0.0
                }
                downloadedSegments.append(WebVTTSegmentInput(
                    text: contentString,
                    playlistStartTime: segTime,
                    duration: dur
                ))
                cumulativeTime = max(cumulativeTime, segTime + dur)
            } else {
                isAllWebVTT = false
            }
        }

        if !downloadedSegments.isEmpty && (isAllWebVTT || destinationURL.pathExtension.lowercased() == "vtt") {
            let combinedVTT = HLSWebVTTAssembler.assemble(segments: downloadedSegments)
            try Data(combinedVTT.utf8).write(to: destinationURL, options: .atomic)
            PipelineLogger.shared.log("[DASH Pipeline] Assembled \(downloadedSegments.count) subtitle segments into: \(destinationURL.path)")
        } else {
            var combinedData = Data()
            for buffer in rawContentBuffers {
                combinedData.append(buffer)
            }
            try combinedData.write(to: destinationURL, options: .atomic)
            PipelineLogger.shared.log("[DASH Pipeline] Saved \(rawContentBuffers.count) raw text/subtitle segments into: \(destinationURL.path)")
        }

        let finalSize = fileManager.fileSize(atPath: destinationURL.path) ?? 0
        let containerType: MediaAssemblyContainer = (destinationURL.pathExtension.lowercased() == "vtt" || isAllWebVTT) ? .webVTT : .rawText
        let validationReport = MediaAssemblyValidationReport(
            container: containerType,
            trackCount: 1,
            mediaSegmentCount: textCompleted.count,
            totalInputBytes: finalSize,
            isReadyForAssembly: true,
            isStructurallyValid: true,
            isPlayableConfirmed: true,
            validationDetails: containerType == .webVTT ? "Assembled WebVTT subtitle track." : "Saved raw subtitle text.",
            state: .assemblyCompleted
        )
        return MediaAssemblyOutput(
            destinationURL: destinationURL,
            container: containerType,
            trackCount: 1,
            byteCount: finalSize,
            validation: validationReport
        )
    }
}

public struct StreamingTransferResult: Sendable, Equatable {
    public let transferID: String
    public let completedSegments: [StreamingSegmentIdentity]
    public let localFiles: [URL]

    public init(transferID: String, completedSegments: [StreamingSegmentIdentity], localFiles: [URL]) {
        self.transferID = transferID
        self.completedSegments = completedSegments
        self.localFiles = localFiles
    }
}

final class StreamingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let originalURL: URL?
    let headers: [String: String]?
    let snapshot: BrowserSessionSnapshot?
    let context: BrowserRequestContext?

    init(
        originalURL: URL? = nil,
        headers: [String: String]? = nil,
        snapshot: BrowserSessionSnapshot? = nil,
        context: BrowserRequestContext? = nil
    ) {
        self.originalURL = originalURL
        self.headers = headers
        self.snapshot = snapshot
        self.context = context
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
            snapshot: snapshot,
            context: context
        )
        completionHandler(redirected)
    }
}
