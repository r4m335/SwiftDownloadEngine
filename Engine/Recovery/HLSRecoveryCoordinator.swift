import Foundation

/// Coordinates recovery of HLS streaming downloads with refreshed signed manifests and token URLs.
public final class HLSRecoveryCoordinator: Sendable {
    private let hlsPersistenceStore: HLSPersistenceStore?
    private let streamingOrchestrator: StreamingDownloadOrchestrator?

    public init(
        hlsPersistenceStore: HLSPersistenceStore?,
        streamingOrchestrator: StreamingDownloadOrchestrator?
    ) {
        self.hlsPersistenceStore = hlsPersistenceStore
        self.streamingOrchestrator = streamingOrchestrator
    }

    /// Reconciles an existing HLS download with a refreshed manifest URL.
    /// Preserves completed segments on disk, skips already downloaded parts, and resumes downloading missing parts.
    @discardableResult
    public func recoverHLS(
        id: String,
        newManifestURL: URL,
        expectedResolutionHeight: Int? = nil,
        headers: [String: String]? = nil
    ) async throws -> HLSTransferRecord {
        guard let persistence = hlsPersistenceStore else {
            throw DownloadRecoveryError.streamRecoveryFailed("HLS persistence store unavailable")
        }

        guard var record = try await persistence.load(id: id) else {
            throw DownloadRecoveryError.recordNotFound(id: id)
        }

        // Validate that segment directory exists
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: record.segmentDirectoryURL.path) else {
            throw DownloadRecoveryError.streamRecoveryFailed(
                "Segment cache directory was removed from disk (\(record.segmentDirectoryURL.path)). Clean restart required."
            )
        }

        // Validate existing segment files on disk and reconcile with completed orders
        let existingFiles = (try? fileManager.contentsOfDirectory(atPath: record.segmentDirectoryURL.path)) ?? []
        var verifiedCompletedOrders: Set<Int> = []
        for file in existingFiles where file.hasSuffix(".part") {
            let base = (file as NSString).deletingPathExtension
            if let order = Int(base), record.completedSegmentOrders.contains(order) {
                verifiedCompletedOrders.insert(order)
            }
        }

        // Safety check: if resolution height was explicitly specified and differs from record, flag incompatibility
        if let expectedH = expectedResolutionHeight {
            let name = record.outputFilename.lowercased()
            for res in [2160, 1440, 1080, 720, 480, 360, 288, 240, 184] {
                if name.contains("\(res)p") && res != expectedH {
                    throw DownloadRecoveryError.incompatibleResource(
                        reason: "Selected quality (\(expectedH)p) does not match existing download rendition (\(res)p)."
                    )
                }
            }
        }

        // Update record with refreshed manifest URL and verified completed segment orders
        record = HLSTransferRecord(
            id: record.id,
            manifestURL: newManifestURL,
            outputFilename: record.outputFilename,
            outputDestinationURL: record.outputDestinationURL,
            segmentDirectoryURL: record.segmentDirectoryURL,
            totalSegments: record.totalSegments,
            completedSegmentOrders: verifiedCompletedOrders,
            state: .paused,
            assemblyState: record.assemblyState,
            createdAt: record.createdAt,
            updatedAt: Date()
        )

        try await persistence.save(record)

        // Resume execution via StreamingDownloadOrchestrator if present
        if let orchestrator = streamingOrchestrator {
            try await orchestrator.resume(transferID: id)
        }

        return record
    }
}
