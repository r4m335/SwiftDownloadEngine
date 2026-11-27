import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor StreamingDownloadOrchestrator {
    public static func createDefault() -> StreamingDownloadOrchestrator {
        StreamingDownloadOrchestrator(segmentExecutor: URLSessionStreamingSegmentExecutor())
    }

    /// Deprecated mutable global. Retained for backwards binary compatibility only;
    /// all production and test architectures must inject orchestrator via AppCompositionRoot.
    @available(*, deprecated, message: "Use AppCompositionRoot or dependency injection instead of global mutable shared")
    @MainActor public static var shared: StreamingDownloadOrchestrator?

    let manifestLoader: any StreamingManifestLoader
    let segmentExecutor: any StreamingSegmentExecutor
    let parsingLimits: ManifestParsingLimits
    public var urlResolver: (any BrowserMediaURLResolver)?
    public var downloadEngine: DownloadEngine?
    /// Durable store for HLS parent-transfer records. `nil` when persistence is unavailable.
    public var hlsPersistenceStore: HLSPersistenceStore?
    /// Durable store for DASH parent-transfer records. `nil` when persistence is unavailable.
    public var dashPersistenceStore: DASHPersistenceStore?
    public nonisolated let backgroundSessionManager: BackgroundDownloadSessionManager?
    /// Optional dynamic cookie provider for refreshing session cookies on subresource/segment requests.
    public var dynamicCookieProvider: (@Sendable (URL) async -> [BrowserCookie])?
    var proposals: [String: StreamingTransferProposal] = [:]
    var runningTransfers: Set<String> = []
    var activeAssemblyOperations: Set<String> = []
    var activeAssemblyDirectories: [String: URL] = [:]
    var completedTransfers: [String: StreamingTransferResult] = [:]
    var pausedTransfers: Set<String> = []
    var cancelledTransfers: Set<String> = []
    var handoffInProgressTransfers: Set<String> = []
    var registeredTransferIDs: [String: String] = [:]
    var candidatesByTransfer: [String: StreamingManifestCandidate] = [:]
    public struct CachedManifestEntry: Sendable {
        public let text: String
        public let cachedAt: Date
        public let expirationDate: Date?

        public init(text: String, cachedAt: Date = Date(), expirationDate: Date? = nil) {
            self.text = text
            self.cachedAt = cachedAt
            self.expirationDate = expirationDate
        }

        public func isExpired(now: Date = Date(), maxTTL: TimeInterval = 300) -> Bool {
            if let exp = expirationDate, now >= exp {
                return true
            }
            return now.timeIntervalSince(cachedAt) > maxTTL
        }
    }

    var cachedManifestTextsByURL: [String: CachedManifestEntry] = [:]

    public func recordCachedManifest(
        text: String,
        for url: URL,
        requestContext: BrowserRequestContext? = nil,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil,
        cachedAt: Date = Date(),
        expirationDate: Date? = nil
    ) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
        guard !normalized.isEmpty else { return }

        let expDate = expirationDate ?? DirectMediaTransferPlanner.urlExpirationDate(url)
        let entry = CachedManifestEntry(text: normalized, cachedAt: cachedAt, expirationDate: expDate)

        if entry.isExpired() {
            return
        }

        let key = BrowserRequestContext.manifestCacheKey(
            for: url,
            requestContext: requestContext,
            browserSessionSnapshot: browserSessionSnapshot
        )
        cachedManifestTextsByURL[key] = entry
        if requestContext == nil && browserSessionSnapshot == nil {
            let canonical = BrowserRequestContext.canonicalURLString(for: url)
            cachedManifestTextsByURL[canonical] = entry
            cachedManifestTextsByURL[url.absoluteString] = entry
        }
    }

    public func clearCachedManifests(
        for url: URL? = nil,
        requestContext: BrowserRequestContext? = nil,
        browserSessionSnapshot: BrowserSessionSnapshot? = nil
    ) {
        if let url = url {
            let key = BrowserRequestContext.manifestCacheKey(
                for: url,
                requestContext: requestContext,
                browserSessionSnapshot: browserSessionSnapshot
            )
            cachedManifestTextsByURL.removeValue(forKey: key)
            if requestContext == nil && browserSessionSnapshot == nil {
                let canonical = BrowserRequestContext.canonicalURLString(for: url)
                cachedManifestTextsByURL.removeValue(forKey: canonical)
                cachedManifestTextsByURL.removeValue(forKey: url.absoluteString)
            }
        } else {
            cachedManifestTextsByURL.removeAll()
        }
    }

    func validCachedManifestText(
        for url: URL,
        requestContext: BrowserRequestContext?,
        browserSessionSnapshot: BrowserSessionSnapshot?
    ) -> String? {
        let key = BrowserRequestContext.manifestCacheKey(
            for: url,
            requestContext: requestContext,
            browserSessionSnapshot: browserSessionSnapshot
        )
        if let entry = cachedManifestTextsByURL[key] {
            if entry.isExpired() || DirectMediaTransferPlanner.isURLExpired(url) {
                cachedManifestTextsByURL.removeValue(forKey: key)
                return nil
            }
            return entry.text
        }
        if requestContext == nil && browserSessionSnapshot == nil {
            let canonical = BrowserRequestContext.canonicalURLString(for: url)
            for fallbackKey in [canonical, url.absoluteString] {
                if let entry = cachedManifestTextsByURL[fallbackKey] {
                    if entry.isExpired() || DirectMediaTransferPlanner.isURLExpired(url) {
                        cachedManifestTextsByURL.removeValue(forKey: fallbackKey)
                    } else {
                        return entry.text
                    }
                }
            }
        }
        return nil
    }

    /// HLS uses the proposal transfer ID as its durable parent ID. Proposal
    /// IDs are deterministic digests and therefore safe for queue and metadata
    /// filenames; manifest URLs are not.
    func hlsParentID(for proposal: StreamingTransferProposal) -> String {
        proposal.transferID
    }

    func hlsParentID(for transferID: String) -> String {
        registeredTransferIDs[transferID] ?? transferID
    }

    func persistenceFailure(_ error: Error) -> StreamingDownloadOrchestratorError {
        .persistenceFailed(error.localizedDescription)
    }

    func persistHLSState(
        id: String,
        state: HLSTransferState
    ) async throws {
        guard let persistence = hlsPersistenceStore else { return }
        do {
            _ = try await persistence.updateState(id: id, state: state)
        } catch {
            if let mapped = registeredTransferIDs[id], mapped != id, (try? await persistence.updateState(id: mapped, state: state)) != nil {
                return
            }
            for (k, v) in registeredTransferIDs where v == id {
                if (try? await persistence.updateState(id: k, state: state)) != nil {
                    return
                }
            }
            PipelineLogger.shared.log(
                "[HLS Pipeline] Failed to persist state \(state) for \(id): \(error.localizedDescription)"
            )
            throw persistenceFailure(error)
        }
    }

    func persistHLSAssemblyState(
        id: String,
        state: HLSAssemblyState
    ) async throws {
        guard let persistence = hlsPersistenceStore else { return }
        do {
            _ = try await persistence.updateAssemblyState(id: id, assemblyState: state)
        } catch {
            PipelineLogger.shared.log(
                "[HLS Pipeline] Failed to persist assembly state \(state) for \(id): \(error.localizedDescription)"
            )
            throw persistenceFailure(error)
        }
    }

    func persistHLSStateBestEffort(
        id: String,
        state: HLSTransferState,
        context: String
    ) async {
        do {
            try await persistHLSState(id: id, state: state)
        } catch {
            PipelineLogger.shared.log(
                "[HLS Pipeline] Could not persist \(context) for \(id): \(error.localizedDescription)"
            )
        }
    }

    func handleHLSCancellation(
        parentID: String,
        transferID: String,
        proposal: StreamingTransferProposal? = nil
    ) async {
        await segmentExecutor.cancel(transferID: transferID)
        await persistHLSStateBestEffort(
            id: parentID,
            state: .cancelled,
            context: "cancellation state"
        )
        if let proposal {
            await cleanupHLSChildRecords(proposal: proposal)
        }
        if let persistence = hlsPersistenceStore {
            do {
                if let record = try await persistence.load(id: parentID) {
                    await purgeInternalStreamingSegmentRecords(in: record.segmentDirectoryURL)
                }
            } catch {
                PipelineLogger.shared.log(
                    "[HLS Pipeline] Could not load cancelled transfer \(parentID) for child cleanup: \(error.localizedDescription)"
                )
            }
        }
    }

    public func isManaging(id: String) -> Bool {
        return runningTransfers.contains(id) ||
               pausedTransfers.contains(id) ||
               completedTransfers[id] != nil ||
               registeredTransferIDs[id] != nil ||
               registeredTransferIDs.values.contains(id)
    }

    /// Indicates whether any streaming transfers are actively downloading or assembling.
    public func hasActiveTransfers() -> Bool {
        return !runningTransfers.isEmpty || !activeAssemblyOperations.isEmpty
    }

    public func pause(transferID: String) async throws {
        runningTransfers.remove(transferID)
        pausedTransfers.insert(transferID)
        if let mapped = registeredTransferIDs[transferID] {
            runningTransfers.remove(mapped)
            pausedTransfers.insert(mapped)
        }
        for (k, v) in registeredTransferIDs where v == transferID {
            runningTransfers.remove(k)
            pausedTransfers.insert(k)
        }
        let parentID = hlsParentID(for: transferID)

        // 1. Cancel in-flight segment tasks in the executor and await their termination
        await segmentExecutor.cancel(transferID: transferID)
        if let mapped = registeredTransferIDs[transferID] {
            await segmentExecutor.cancel(transferID: mapped)
        }
        if parentID != transferID {
            await segmentExecutor.cancel(transferID: parentID)
        }

        // 2. Reconcile committed checkpoints with disk before completing pause
        if let hlsRec = try? await hlsPersistenceStore?.load(id: parentID) {
            await reconcileCompletedSegmentsWithDisk(transferID: parentID, directory: hlsRec.segmentDirectoryURL)
        } else if let dashRec = try? await dashPersistenceStore?.load(id: transferID) {
            await reconcileDASHCompletedSegmentsWithDisk(transferID: transferID, directory: dashRec.segmentDirectoryURL)
        }

        // 3. Persist paused state
        await persistDASHState(id: transferID, state: .paused)
        try await persistHLSState(
            id: parentID,
            state: .paused
        )
        PipelineLogger.shared.log("[HLS Pipeline] Paused transfer: \(transferID)")
    }

    func persistDASHState(id: String, state: HLSTransferState) async {
        guard let dashStore = dashPersistenceStore else { return }
        do {
            _ = try await dashStore.updateState(id: id, state: state)
        } catch {
            PipelineLogger.shared.log("[DASH Pipeline] Failed to persist state \(state) for \(id): \(error.localizedDescription)")
        }
    }

    func persistDASHAssemblyState(id: String, assemblyState: HLSAssemblyState) async {
        guard let dashStore = dashPersistenceStore else { return }
        do {
            _ = try await dashStore.updateAssemblyState(id: id, assemblyState: assemblyState)
        } catch {
            PipelineLogger.shared.log("[DASH Pipeline] Failed to persist assembly state \(assemblyState) for \(id): \(error.localizedDescription)")
        }
    }

    public func resume(transferID: String) async throws {
        pausedTransfers.remove(transferID)
        runningTransfers.insert(transferID)
        if let mapped = registeredTransferIDs[transferID] {
            pausedTransfers.remove(mapped)
            runningTransfers.insert(mapped)
        }
        for (k, v) in registeredTransferIDs where v == transferID {
            pausedTransfers.remove(k)
            runningTransfers.insert(k)
        }
        try await persistHLSState(
            id: hlsParentID(for: transferID),
            state: .downloading
        )
        await persistDASHState(id: transferID, state: .downloading)
        PipelineLogger.shared.log("[HLS Pipeline] Resumed transfer: \(transferID)")
    }

    public func cancel(transferID: String) async {
        runningTransfers.remove(transferID)
        pausedTransfers.remove(transferID)
        cancelledTransfers.insert(transferID)
        if let mapped = registeredTransferIDs[transferID] {
            runningTransfers.remove(mapped)
            pausedTransfers.remove(mapped)
            cancelledTransfers.insert(mapped)
        }
        for (k, v) in registeredTransferIDs where v == transferID {
            runningTransfers.remove(k)
            pausedTransfers.remove(k)
            cancelledTransfers.insert(k)
        }
        let parentID = hlsParentID(for: transferID)
        let proposal = proposals[parentID] ?? proposals[transferID]
        await handleHLSCancellation(
            parentID: parentID,
            transferID: parentID,
            proposal: proposal
        )
        await persistDASHState(id: transferID, state: .cancelled)
        PipelineLogger.shared.log("[HLS Pipeline] Cancelled transfer: \(transferID)")
    }

    public func pauseAll() async {
        let running = Array(runningTransfers)
        for id in running {
            try? await pause(transferID: id)
        }
    }

    public func resumeAll() async {
        let paused = Array(pausedTransfers)
        for id in paused {
            try? await resume(transferID: id)
        }
    }

    public func cancelAll() async {
        var targets = runningTransfers.union(pausedTransfers)
        for id in registeredTransferIDs.values {
            if completedTransfers[id] == nil && !cancelledTransfers.contains(id) {
                targets.insert(id)
            }
        }
        for id in targets {
            await cancel(transferID: id)
        }
    }

    public func isPaused(transferID: String) -> Bool {
        if pausedTransfers.contains(transferID) { return true }
        if let mapped = registeredTransferIDs[transferID], pausedTransfers.contains(mapped) { return true }
        return false
    }

    public func isCancelled(transferID: String) -> Bool {
        if cancelledTransfers.contains(transferID) { return true }
        if let mapped = registeredTransferIDs[transferID], cancelledTransfers.contains(mapped) { return true }
        return false
    }

    public func isHandoffInProgress(transferID: String) -> Bool {
        if handoffInProgressTransfers.contains(transferID) { return true }
        if let mapped = registeredTransferIDs[transferID], handoffInProgressTransfers.contains(mapped) { return true }
        let parentID = hlsParentID(for: transferID)
        if handoffInProgressTransfers.contains(parentID) { return true }
        return false
    }

    /// Reconciles committed segments with disk and marks any missing completed checkpoints in the HLS persistence store.
    func reconcileCompletedSegmentsWithDisk(transferID: String, directory: URL) async {
        guard let persistence = hlsPersistenceStore else { return }
        guard let record = try? await persistence.load(id: transferID) else { return }
        let proposal = proposals[transferID]
        if let resources = proposal?.resources {
            for res in resources {
                let dest = directory.appendingPathComponent("\(res.identity.value).part")
                let size = FileManager.default.fileSize(atPath: dest.path) ?? 0
                if size > 0 && !record.completedSegmentOrders.contains(res.identity.order) {
                    do {
                        _ = try await persistence.markSegmentCompleted(id: transferID, order: res.identity.order)
                    } catch {
                        PipelineLogger.shared.log("[HLS Pipeline] Failed to mark segment \(res.identity.order) completed for \(transferID): \(error.localizedDescription)")
                    }
                }
            }
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        let partFiles = files.filter { $0.pathExtension.lowercased() == "part" }
        for file in partFiles {
            let baseName = file.deletingPathExtension().lastPathComponent
            let components = baseName.split(separator: "_")
            if let first = components.first, let order = Int(first) {
                let size = FileManager.default.fileSize(atPath: file.path) ?? 0
                if size > 0 && !record.completedSegmentOrders.contains(order) {
                    do {
                        _ = try await persistence.markSegmentCompleted(id: transferID, order: order)
                    } catch {
                        PipelineLogger.shared.log("[HLS Pipeline] Failed to mark segment \(order) completed for \(transferID): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Reconciles committed segments with disk and marks any missing completed checkpoints in the DASH persistence store.
    func reconcileDASHCompletedSegmentsWithDisk(transferID: String, directory: URL) async {
        guard let persistence = dashPersistenceStore else { return }
        guard let record = try? await persistence.load(id: transferID) else { return }
        var newlyCompleted: Set<Int> = []
        let proposal = proposals[transferID]
        if let resources = proposal?.resources {
            for res in resources {
                let dest = directory.appendingPathComponent("\(res.identity.value).part")
                let size = FileManager.default.fileSize(atPath: dest.path) ?? 0
                if size > 0 && !record.completedSegmentOrders.contains(res.identity.order) {
                    newlyCompleted.insert(res.identity.order)
                }
            }
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            let partFiles = files.filter { $0.pathExtension.lowercased() == "part" }
            for file in partFiles {
                let baseName = file.deletingPathExtension().lastPathComponent
                let components = baseName.split(separator: "_")
                if let first = components.first, let order = Int(first) {
                    let size = FileManager.default.fileSize(atPath: file.path) ?? 0
                    if size > 0 && !record.completedSegmentOrders.contains(order) {
                        newlyCompleted.insert(order)
                    }
                }
            }
        }
        if !newlyCompleted.isEmpty {
            do {
                _ = try await persistence.updateCompletedSegmentOrders(id: transferID, completedOrders: Array(newlyCompleted))
            } catch {
                PipelineLogger.shared.log("[DASH Pipeline] Failed to update completed segments for \(transferID): \(error.localizedDescription)")
            }
        }
    }

    public private(set) var configuration: EngineConfiguration
    public let remuxTSToMP4: Bool

    public init(
        configuration: EngineConfiguration = .default,
        manifestLoader: any StreamingManifestLoader = URLSessionStreamingManifestLoader(),
        segmentExecutor: any StreamingSegmentExecutor,
        parsingLimits: ManifestParsingLimits = .default,
        urlResolver: (any BrowserMediaURLResolver)? = nil,
        downloadEngine: DownloadEngine? = nil,
        hlsPersistenceStore: HLSPersistenceStore? = nil,
        dashPersistenceStore: DASHPersistenceStore? = nil,
        remuxTSToMP4: Bool = true,
        backgroundSessionManager: BackgroundDownloadSessionManager? = nil
    ) {
        self.configuration = configuration
        self.manifestLoader = manifestLoader
        self.segmentExecutor = segmentExecutor
        self.parsingLimits = parsingLimits
        self.urlResolver = urlResolver
        self.downloadEngine = downloadEngine
        self.hlsPersistenceStore = hlsPersistenceStore
        self.dashPersistenceStore = dashPersistenceStore
        self.remuxTSToMP4 = remuxTSToMP4
        self.backgroundSessionManager = backgroundSessionManager
    }

    public init(
        configuration: EngineConfiguration = .default,
        downloadCoordinator: DownloadCoordinator,
        downloadEngine: DownloadEngine? = nil,
        manifestLoader: any StreamingManifestLoader = URLSessionStreamingManifestLoader(),
        parsingLimits: ManifestParsingLimits = .default,
        retryCount: Int? = nil,
        urlResolver: (any BrowserMediaURLResolver)? = nil,
        hlsPersistenceStore: HLSPersistenceStore? = nil,
        dashPersistenceStore: DASHPersistenceStore? = nil,
        remuxTSToMP4: Bool = true,
        backgroundSessionManager: BackgroundDownloadSessionManager? = nil
    ) {
        self.init(
            configuration: configuration,
            manifestLoader: manifestLoader,
            segmentExecutor: DownloadCoordinatorSegmentExecutor(
                coordinator: downloadCoordinator,
                retryCount: retryCount ?? configuration.maxRetryAttempts,
                backgroundSessionManager: backgroundSessionManager
            ),
            parsingLimits: parsingLimits,
            urlResolver: urlResolver,
            downloadEngine: downloadEngine,
            hlsPersistenceStore: hlsPersistenceStore,
            dashPersistenceStore: dashPersistenceStore,
            remuxTSToMP4: remuxTSToMP4,
            backgroundSessionManager: backgroundSessionManager
        )
    }

    public func updateConfiguration(_ newConfig: EngineConfiguration) {
        self.configuration = newConfig
    }

    public func setURLResolver(_ resolver: (any BrowserMediaURLResolver)?) {
        self.urlResolver = resolver
    }

    public func setDownloadEngine(_ engine: DownloadEngine?) {
        self.downloadEngine = engine
    }

    public func setHLSPersistenceStore(_ store: HLSPersistenceStore?) {
        self.hlsPersistenceStore = store
    }

    public func setDASHPersistenceStore(_ store: DASHPersistenceStore?) {
        self.dashPersistenceStore = store
    }

    func purgeInternalStreamingSegmentRecords(in directory: URL? = nil) async {
        guard let engine = downloadEngine else { return }
        let records: [DownloadRecord]
        do {
            records = try await engine.persistenceStore.fetchAll()
        } catch {
            PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to fetch records for purging: \(error)")
            return
        }
        let directoryPath = directory?.standardizedFileURL.path
        for record in records where record.isStreamingSegment {
            if let directoryPath,
               !record.destinationURL.standardizedFileURL.path.hasPrefix(directoryPath + "/") {
                continue
            }
            do {
                try await engine.persistenceStore.delete(tag: record.id)
            } catch {
                PipelineLogger.shared.log("[StreamingDownloadOrchestrator] Failed to delete internal segment record \(record.id): \(error)")
            }
        }
    }

    func purgeOrphanAssemblyDirectories(records: [HLSTransferRecord]) async {
        let fileManager = FileManager.default
        var activeDirectories = Set(
            records
                .filter { $0.state == .downloading || $0.state == .paused }
                .map { $0.segmentDirectoryURL.standardizedFileURL.path }
        )
        for url in activeAssemblyDirectories.values {
            activeDirectories.insert(url.standardizedFileURL.path)
        }
        for runId in runningTransfers {
            if let record = records.first(where: { $0.id == runId }) {
                activeDirectories.insert(record.segmentDirectoryURL.standardizedFileURL.path)
            }
        }
        for runId in activeAssemblyOperations {
            if let record = records.first(where: { $0.id == runId }) {
                activeDirectories.insert(record.segmentDirectoryURL.standardizedFileURL.path)
            }
        }

        let parentDirectories = Set(records.map {
            $0.segmentDirectoryURL.deletingLastPathComponent().standardizedFileURL
        })

        for parent in parentDirectories {
            guard let children = try? fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }
            for child in children where child.lastPathComponent.hasPrefix(".assembly_temp_") {
                let path = child.standardizedFileURL.path
                guard !activeDirectories.contains(path) else {
                    PipelineLogger.shared.log("[HLS Recovery] Preserving active assembly directory: \(path)")
                    continue
                }

                // Minimum age grace period: do not delete directories created or modified within 2 hours (7200 seconds)
                let attrs = try? fileManager.attributesOfItem(atPath: child.path)
                let modDate = (attrs?[.modificationDate] as? Date) ?? (attrs?[.creationDate] as? Date) ?? Date.distantPast
                let age = Date().timeIntervalSince(modDate)
                guard age > 7200 else {
                    PipelineLogger.shared.log("[HLS Recovery] Assembly directory \(path) was modified recently (\(Int(age))s ago < 7200s grace period). Preserving.")
                    continue
                }

                do {
                    try fileManager.removeItem(at: child)
                    PipelineLogger.shared.log("[HLS Recovery] Removed orphaned assembly directory: \(path)")
                } catch {
                    PipelineLogger.shared.log("[HLS Recovery] Failed to remove orphaned assembly directory \(path): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - HLS Startup Recovery

    /// Restores durable HLS transfer records into the `DownloadEngine` after an app restart.
    ///
    /// Call this once during app startup, **after** `DownloadEngine` has been injected
    /// and the queue has been restored via `DownloadEngine.restoreQueue()`.
    ///
    /// For each active HLS record (`downloading` or `paused` state) whose parent
    /// download entry is no longer present in the engine queue, this method re-registers
    /// the parent entry so the Downloads UI shows one video, not nothing.
    ///
    /// Records in `completed`, `failed`, or `cancelled` state are not re-added to the
    /// active queue; they remain visible via the standard `DownloadRecord` in
    /// `DownloadPersistenceStore`.
    public func restoreHLSTransfers(resumeInterrupted: Bool = false) async {
        guard let persistence = hlsPersistenceStore else { return }
        guard let engine = downloadEngine else { return }

        let records: [HLSTransferRecord]
        do {
            records = try await persistence.loadAll()
        } catch {
            PipelineLogger.shared.log("[HLS Recovery] Failed to load HLS records: \(error.localizedDescription)")
            return
        }

        // Segment requests are implementation details. The parent HLS job
        // checkpoint is sufficient to resume them, so never restore child
        // DownloadRecord entries into the durable download store.
        await purgeInternalStreamingSegmentRecords()
        await purgeOrphanAssemblyDirectories(records: records)

        PipelineLogger.shared.log("[HLS Recovery] Found \(records.count) persisted HLS record(s).")

        for record in records {
            let manifestKey = record.manifestURL.absoluteString
            registeredTransferIDs[manifestKey] = record.id
            registeredTransferIDs[record.id] = record.id
        }

        for record in records where record.state == .downloading || record.state == .paused {
            // Check whether the parent download is already in the engine queue.
            let existingSnap = await engine.snapshot(for: record.id)
            if existingSnap != nil {
                // Already present — restore our in-memory registeredTransferIDs so
                // pause/resume/cancel routing still works.
                let manifestKey = record.manifestURL.absoluteString
                registeredTransferIDs[manifestKey] = record.id
                registeredTransferIDs[record.id] = record.id
                PipelineLogger.shared.log("[HLS Recovery] Transfer \(record.id) already in engine queue. Skipping re-registration.")
                if resumeInterrupted, record.state == .downloading {
                    let isRunningInMemory = runningTransfers.contains(record.id) || activeAssemblyOperations.contains(record.id)
                    let isEngineActive = existingSnap?.state == .downloading || existingSnap?.state == .pending || existingSnap?.state == .probing
                    if isRunningInMemory || isEngineActive {
                        PipelineLogger.shared.log("[HLS Recovery] Transfer \(record.id) is currently actively executing (engine state: \(String(describing: existingSnap?.state))). Skipping duplicate resume.")
                    } else {
                        Task { await self.resumePersistedHLS(record) }
                    }
                }
                continue
            }

            // Re-register the parent download entry so the UI shows one video row.
            do {
                let estimatedTotal = Int64(record.totalSegments) * 1_000_000
                _ = try await engine.registerStreamingDownload(
                    id: record.id,
                    manifestURL: record.manifestURL,
                    destinationURL: record.outputDestinationURL,
                    filename: record.outputFilename,
                    totalBytes: estimatedTotal,
                    mimeType: "video/mp4"
                )

                // Wire routing so orchestrator can route pause/resume/cancel.
                let manifestKey = record.manifestURL.absoluteString
                registeredTransferIDs[manifestKey] = record.id
                registeredTransferIDs[record.id] = record.id

                // If it was paused, mark that immediately.
                if record.state == .paused {
                    await engine.queueManager.pauseStreaming(id: record.id)
                    pausedTransfers.insert(record.id)
                }

                let segsDone = record.completedSegmentOrders.count
                let segsTotal = record.totalSegments
                PipelineLogger.shared.log("[HLS Recovery] Re-registered \(record.outputFilename) (\(segsDone)/\(segsTotal) segments).")
                if resumeInterrupted, record.state == .downloading {
                    let isRunningInMemory = runningTransfers.contains(record.id) || activeAssemblyOperations.contains(record.id)
                    if isRunningInMemory {
                        PipelineLogger.shared.log("[HLS Recovery] Transfer \(record.id) is already running in memory. Skipping duplicate resume.")
                    } else {
                        Task { await self.resumePersistedHLS(record) }
                    }
                }
            } catch {
                PipelineLogger.shared.log("[HLS Recovery] Failed to re-register \(record.id): \(error.localizedDescription)")
            }
        }

        // Cleanup records for transfers that have been completed/cancelled/failed and
        // whose output file has already been removed from disk by the user.
        for record in records where record.state == .completed {
            if !FileManager.default.fileExists(atPath: record.outputDestinationURL.path) {
                do {
                    try await persistence.delete(id: record.id)
                    PipelineLogger.shared.log("[HLS Recovery] Pruned stale completed record: \(record.id)")
                } catch {
                    PipelineLogger.shared.log("[HLS Recovery] Warning: Failed to prune stale completed record \(record.id): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Rebuilds the in-memory proposal from the durable manifest URL and
    /// resumes an interrupted parent using its original segment directory and
    /// output destination. Browser credentials are intentionally not loaded
    /// from disk; the normal loader/keychain path supplies them when available.
    func resumePersistedHLS(_ record: HLSTransferRecord) async {
        guard !runningTransfers.contains(record.id), !activeAssemblyOperations.contains(record.id) else {
            PipelineLogger.shared.log("[HLS Recovery] Transfer \(record.id) is already running or assembling. Aborting duplicate resume.")
            return
        }
        do {
            let policy: HTTPTransportPolicy = (backgroundSessionManager != nil) ? .background : .foreground
            let candidate = try StreamingManifestCandidate(url: record.manifestURL, transportPolicy: policy)
            let proposal = try await prepare(candidate: candidate)
            guard case .hls = proposal.manifest else { return }
            _ = try await executeAndAssembleHLS(
                proposal,
                approved: true,
                destinationDirectory: record.segmentDirectoryURL,
                outputURL: record.outputDestinationURL,
                runID: record.id
            )
        } catch {
            PipelineLogger.shared.log("[HLS Recovery] Could not resume \(record.id): \(error.localizedDescription)")
        }
    }

    // MARK: - DASH Startup Recovery

    /// Restores durable DASH transfer records into the `DownloadEngine` after an app restart.
    public func restoreDASHTransfers(resumeInterrupted: Bool = false) async {
        guard let persistence = dashPersistenceStore else { return }
        guard let engine = downloadEngine else { return }

        let records: [DASHTransferRecord]
        do {
            records = try await persistence.loadAll()
        } catch {
            PipelineLogger.shared.log("[DASH Recovery] Failed to load DASH records: \(error.localizedDescription)")
            return
        }

        await purgeInternalStreamingSegmentRecords()

        PipelineLogger.shared.log("[DASH Recovery] Found \(records.count) persisted DASH record(s).")

        for record in records {
            let manifestKey = record.manifestURL.absoluteString
            registeredTransferIDs[manifestKey] = record.id
            registeredTransferIDs[record.id] = record.id
        }

        for record in records where record.state == .downloading || record.state == .paused {
            let existingSnap = await engine.snapshot(for: record.id)
            if existingSnap != nil {
                let manifestKey = record.manifestURL.absoluteString
                registeredTransferIDs[manifestKey] = record.id
                registeredTransferIDs[record.id] = record.id
                PipelineLogger.shared.log("[DASH Recovery] Transfer \(record.id) already in engine queue. Skipping re-registration.")
                if resumeInterrupted, record.state == .downloading {
                    let isRunningInMemory = runningTransfers.contains(record.id) || activeAssemblyOperations.contains(record.id)
                    let isEngineActive = existingSnap?.state == .downloading || existingSnap?.state == .pending || existingSnap?.state == .probing
                    if isRunningInMemory || isEngineActive {
                        PipelineLogger.shared.log("[DASH Recovery] Transfer \(record.id) is currently actively executing. Skipping duplicate resume.")
                    } else {
                        Task { await self.resumePersistedDASH(record) }
                    }
                }
                continue
            }

            // Re-register the parent download entry so the UI shows one row.
            do {
                let estimatedTotal = Int64(record.totalSegments) * 1_000_000
                let mimeType = record.isTextOnly ? (record.isTTML ? "application/ttml+xml" : "text/vtt") : "video/mp4"
                _ = try await engine.registerStreamingDownload(
                    id: record.id,
                    manifestURL: record.manifestURL,
                    destinationURL: record.outputDestinationURL,
                    filename: record.outputFilename,
                    totalBytes: estimatedTotal,
                    mimeType: mimeType
                )

                let manifestKey = record.manifestURL.absoluteString
                registeredTransferIDs[manifestKey] = record.id
                registeredTransferIDs[record.id] = record.id

                if record.state == .paused {
                    await engine.queueManager.pauseStreaming(id: record.id)
                    pausedTransfers.insert(record.id)
                }

                let segsDone = record.completedSegmentOrders.count
                let segsTotal = record.totalSegments
                PipelineLogger.shared.log("[DASH Recovery] Re-registered \(record.outputFilename) (\(segsDone)/\(segsTotal) segments).")
                if resumeInterrupted, record.state == .downloading {
                    let isRunningInMemory = runningTransfers.contains(record.id) || activeAssemblyOperations.contains(record.id)
                    if isRunningInMemory {
                        PipelineLogger.shared.log("[DASH Recovery] Transfer \(record.id) is already running in memory. Skipping duplicate resume.")
                    } else {
                        Task { await self.resumePersistedDASH(record) }
                    }
                }
            } catch {
                PipelineLogger.shared.log("[DASH Recovery] Failed to re-register \(record.id): \(error.localizedDescription)")
            }
        }

        // Cleanup records for transfers that have been completed and whose output file has been removed
        for record in records where record.state == .completed {
            if !FileManager.default.fileExists(atPath: record.outputDestinationURL.path) {
                do {
                    try await persistence.delete(id: record.id)
                    PipelineLogger.shared.log("[DASH Recovery] Pruned stale completed record: \(record.id)")
                } catch {
                    PipelineLogger.shared.log("[DASH Recovery] Warning: Failed to prune stale completed record \(record.id): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Rebuilds the in-memory proposal from the durable DASH manifest URL and representations.
    func resumePersistedDASH(_ record: DASHTransferRecord) async {
        guard !runningTransfers.contains(record.id), !activeAssemblyOperations.contains(record.id) else {
            PipelineLogger.shared.log("[DASH Recovery] Transfer \(record.id) is already running or assembling. Aborting duplicate resume.")
            return
        }
        do {
            let policy: HTTPTransportPolicy = (backgroundSessionManager != nil) ? .background : .foreground
            let candidate = try StreamingManifestCandidate(
                url: record.manifestURL,
                dashVideoRepresentationID: record.videoRepresentationID,
                dashAudioRepresentationID: record.audioRepresentationID,
                dashTextRepresentationID: record.textRepresentationID,
                transportPolicy: policy
            )
            let proposal = try await prepare(candidate: candidate)
            guard case .dash = proposal.manifest else { return }
            _ = try await executeAndAssembleDASH(
                proposal,
                approved: true,
                destinationDirectory: record.segmentDirectoryURL,
                outputURL: record.outputDestinationURL,
                runID: record.id
            )
        } catch {
            PipelineLogger.shared.log("[DASH Recovery] Could not resume \(record.id): \(error.localizedDescription)")
        }
    }

    /// Restores all durable streaming transfers (both HLS and DASH).
    public func restoreStreamingTransfers(resumeInterrupted: Bool = false) async {
        await restoreHLSTransfers(resumeInterrupted: resumeInterrupted)
        await restoreDASHTransfers(resumeInterrupted: resumeInterrupted)
    }

    /// Handles asynchronous background segment completion from BackgroundDownloadSessionManager.
    /// Checkpoints completed chunk into persistent store and triggers assembly when all segments are present.
    public func handleSegmentCompleted(transferID: String, order: Int, partURL: URL) async {
        // 1. Check HLS Store
        if let persistence = hlsPersistenceStore {
            let directOrParentID: String
            if (try? await persistence.load(id: transferID)) != nil {
                directOrParentID = transferID
            } else if let mapped = registeredTransferIDs[transferID], (try? await persistence.load(id: mapped)) != nil {
                directOrParentID = mapped
            } else {
                directOrParentID = hlsParentID(for: transferID)
            }
            if var record = try? await persistence.load(id: directOrParentID) {
                if !record.completedSegmentOrders.contains(order) {
                    do {
                        _ = try await persistence.markSegmentCompleted(id: directOrParentID, order: order)
                    } catch {
                        PipelineLogger.shared.log("[HLS Background] Failed to mark segment \(order) completed for \(directOrParentID): \(error.localizedDescription)")
                    }
                    record.completedSegmentOrders.insert(order)
                }
                if let engine = self.downloadEngine {
                    let estimatedTotal = Int64(record.totalSegments) * 1_000_000
                    let completedBytes = Int64(record.completedSegmentOrders.count) * 1_000_000
                    await engine.updateStreamingDownloadProgress(
                        id: directOrParentID,
                        completedBytes: completedBytes,
                        totalBytes: estimatedTotal
                    )
                }
                if record.completedSegmentOrders.count >= record.totalSegments,
                   !runningTransfers.contains(record.id),
                   !activeAssemblyOperations.contains(record.id),
                   !isHandoffInProgress(transferID: record.id) {
                    PipelineLogger.shared.log("[HLS Background] All \(record.totalSegments) segments downloaded for \(record.id). Triggering assembly...")
                    await self.resumePersistedHLS(record)
                }
                return
            }
        }

        // 2. Check DASH Store
        if let persistence = dashPersistenceStore {
            let targetID: String
            if (try? await persistence.load(id: transferID)) != nil {
                targetID = transferID
            } else if let mapped = registeredTransferIDs[transferID], (try? await persistence.load(id: mapped)) != nil {
                targetID = mapped
            } else {
                targetID = transferID
            }
            if var record = try? await persistence.load(id: targetID) {
                if !record.completedSegmentOrders.contains(order) {
                    do {
                        _ = try await persistence.updateCompletedSegmentOrders(id: targetID, completedOrders: [order])
                    } catch {
                        PipelineLogger.shared.log("[DASH Background] Failed to mark segment \(order) completed for \(targetID): \(error.localizedDescription)")
                    }
                    record.completedSegmentOrders.insert(order)
                }
                if let engine = self.downloadEngine {
                    let estimatedTotal = Int64(record.totalSegments) * 1_000_000
                    let completedBytes = Int64(record.completedSegmentOrders.count) * 1_000_000
                    await engine.updateStreamingDownloadProgress(
                        id: targetID,
                        completedBytes: completedBytes,
                        totalBytes: estimatedTotal
                    )
                }
                if record.completedSegmentOrders.count >= record.totalSegments,
                   !runningTransfers.contains(record.id),
                   !activeAssemblyOperations.contains(record.id),
                   !isHandoffInProgress(transferID: record.id) {
                    PipelineLogger.shared.log("[DASH Background] All \(record.totalSegments) segments downloaded for \(record.id). Triggering assembly...")
                    await self.resumePersistedDASH(record)
                }
                return
            }
        }
    }

    /// Schedules all segments of a streaming proposal using the background URLSession transport.
    @discardableResult
    public func scheduleBackgroundStreaming(
        proposal: StreamingTransferProposal,
        destinationDirectory: URL,
        backgroundManager: BackgroundDownloadSessionManager? = nil
    ) async throws -> [BackgroundDownloadTaskRecord] {
        guard let manager = backgroundManager ?? self.backgroundSessionManager else {
            throw StreamingDownloadOrchestratorError.persistenceFailed("No backgroundSessionManager available")
        }
        try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(destinationDirectory)

        let parentHLS = hlsParentID(for: proposal)
        let hlsRec = try? await hlsPersistenceStore?.load(id: parentHLS)
        let dashRec = try? await dashPersistenceStore?.load(id: proposal.transferID)
        let completedOrders = hlsRec?.completedSegmentOrders ?? dashRec?.completedSegmentOrders ?? []

        var records: [BackgroundDownloadTaskRecord] = []
        for resource in proposal.resources {
            let destURL = destinationDirectory.appendingPathComponent("\(resource.identity.value).part", isDirectory: false)
            if completedOrders.contains(resource.identity.order) && FileManager.default.fileExists(atPath: destURL.path) {
                continue
            }
            let headers = await segmentRequestHeaders(for: resource, manifest: proposal.manifest, transferID: proposal.transferID)
            let rec = try await manager.scheduleStreamingSegment(
                transferID: proposal.transferID,
                order: resource.identity.order,
                url: resource.url,
                destinationURL: destURL,
                headers: headers,
                byteRange: resource.byteRange.map { ($0.start, $0.end) }
            )
            records.append(rec)
        }
        return records
    }

    /// Hands off all active foreground streaming downloads to the background URLSession transport
    /// so they continue progressing seamlessly when the app enters inactive or background states.
    public func handoffActiveStreamingToBackground() async {
        guard let manager = self.backgroundSessionManager else {
            PipelineLogger.shared.log("[StreamingOrchestrator] No backgroundSessionManager available for handoff.")
            return
        }
        let activeIDs = Array(runningTransfers)
        for id in activeIDs {
            let parentID = hlsParentID(for: id)
            guard var proposal = proposals[parentID] ?? proposals[id] else { continue }
            guard proposal.transportPolicy == .foreground else { continue }

            var segmentDir: URL? = nil
            if let hlsRec = try? await hlsPersistenceStore?.load(id: parentID) {
                segmentDir = hlsRec.segmentDirectoryURL
            } else if let hlsRec = try? await hlsPersistenceStore?.load(id: id) {
                segmentDir = hlsRec.segmentDirectoryURL
            } else if let dashRec = try? await dashPersistenceStore?.load(id: proposal.transferID) {
                segmentDir = dashRec.segmentDirectoryURL
            }
            guard let dir = segmentDir else { continue }

            do {
                // 1. Mark handoff in progress
                self.handoffInProgressTransfers.insert(parentID)
                self.handoffInProgressTransfers.insert(id)
                self.handoffInProgressTransfers.insert(proposal.transferID)

                // 2. Cancel active foreground segment executor tasks and await full termination/detachment
                await self.segmentExecutor.cancel(transferID: id)
                if parentID != id {
                    await self.segmentExecutor.cancel(transferID: parentID)
                }
                if proposal.transferID != id && proposal.transferID != parentID {
                    await self.segmentExecutor.cancel(transferID: proposal.transferID)
                }

                // 3. Reconcile completed segments from disk before scheduling remaining resources
                if proposal.manifest.kind == .hls {
                    await reconcileCompletedSegmentsWithDisk(transferID: parentID, directory: dir)
                } else if proposal.manifest.kind == .dash {
                    await reconcileDASHCompletedSegmentsWithDisk(transferID: proposal.transferID, directory: dir)
                }

                // 4. Update proposal policy to background
                proposal.transportPolicy = .background
                self.proposals[parentID] = proposal
                self.proposals[id] = proposal
                self.proposals[proposal.transferID] = proposal

                // 5. Schedule remaining uncompleted segments in background transport
                let scheduled = try await scheduleBackgroundStreaming(
                    proposal: proposal,
                    destinationDirectory: dir,
                    backgroundManager: manager
                )

                // 6. Transition out of handoffInProgress to background running
                self.handoffInProgressTransfers.remove(parentID)
                self.handoffInProgressTransfers.remove(id)
                self.handoffInProgressTransfers.remove(proposal.transferID)

                PipelineLogger.shared.log("[StreamingOrchestrator] Successfully handed off streaming transfer \(id) (\(scheduled.count) segments) to background transport.")
            } catch {
                self.handoffInProgressTransfers.remove(parentID)
                self.handoffInProgressTransfers.remove(id)
                self.handoffInProgressTransfers.remove(proposal.transferID)
                PipelineLogger.shared.log("[StreamingOrchestrator] Failed to hand off streaming transfer \(id) to background: \(error.localizedDescription)")
            }
        }
    }

    /// Returns the cached active proposal for a given transfer ID.
}
