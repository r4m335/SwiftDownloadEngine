import Foundation

public extension DownloadEngine {
    @discardableResult
    func importCompletedFile(
        fileURL: URL,
        originalURL: URL,
        filename: String,
        mimeType: String? = nil
    ) async throws -> DownloadSnapshot {
        await attachListeners()
        guard fileURL.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let totalBytes = (attributes[.size] as? NSNumber)?.int64Value,
              totalBytes >= 0 else {
            throw DownloadQueueError.persistenceError("The captured file is missing or has no valid size.")
        }

        let now = Date()
        let record = DownloadRecord(
            originalURL: originalURL,
            resolvedURL: originalURL,
            destinationURL: fileURL,
            totalSize: totalBytes,
            state: .completed,
            storageMode: .directSeek,
            transportPolicy: .foreground,
            suggestedFilename: filename,
            mimeType: mimeType,
            createdAt: now,
            updatedAt: now,
            segments: [
                SegmentRecord(
                    id: 0,
                    startOffset: 0,
                    endOffset: max(0, totalBytes - 1),
                    length: totalBytes,
                    completedBytes: totalBytes
                )
            ]
        )

        do {
            try await persistenceStore.save(record)
            let item = try await queueManager.addCompletedFile(record: record)
            let snapshot = await makeSnapshot(from: item)
            previousStates[item.id] = .completed
            terminalEventsEmitted.insert(item.id)
            broadcast(.added(snapshot))
            broadcast(.completed(snapshot))
            return snapshot
        } catch {
            try? await persistenceStore.delete(tag: record.id)
            if let persistenceError = error as? DownloadQueueError {
                throw persistenceError
            }
            throw DownloadQueueError.persistenceError(error.localizedDescription)
        }
    }
}
