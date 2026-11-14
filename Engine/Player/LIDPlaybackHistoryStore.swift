import Foundation

/// Thread-safe persistence store tracking playback progress and resume positions
/// across app sessions for local and network media assets.
public actor LIDPlaybackHistoryStore {

    public static let shared = LIDPlaybackHistoryStore()

    private let storageURL: URL
    private var records: [String: LIDPlaybackRecord] = [:]
    private var isLoaded: Bool = false

    public init(storageURL: URL? = nil) {
        if let customURL = storageURL {
            self.storageURL = customURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = appSupport.appendingPathComponent("SwiftDownloadEngine", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageURL = dir.appendingPathComponent("playback_history.json")
        }
    }

    /// Records current playback progress for an asset.
    /// If playback position is within the final 3% or 5 seconds of the asset, marks it as completed.
    public func recordPosition(
        mediaIdentifier: String,
        title: String,
        positionSeconds: Double,
        durationSeconds: Double
    ) {
        ensureLoaded()

        let isCompleted = durationSeconds > 0 && (positionSeconds >= (durationSeconds - 5.0) || positionSeconds >= (durationSeconds * 0.97))
        let effectivePosition = isCompleted ? 0.0 : positionSeconds

        let record = LIDPlaybackRecord(
            mediaIdentifier: mediaIdentifier,
            title: title,
            lastPositionSeconds: effectivePosition,
            durationSeconds: durationSeconds,
            lastPlayedAt: Date(),
            isCompleted: isCompleted
        )

        records[mediaIdentifier] = record
        persistToDisk()
    }

    /// Retrieves the resume position in seconds for an asset, or nil if none or completed.
    public func resumePosition(mediaIdentifier: String) -> Double? {
        ensureLoaded()
        guard let record = records[mediaIdentifier], !record.isCompleted else {
            return nil
        }
        // Only resume if user had watched more than 3 seconds
        if record.lastPositionSeconds > 3.0 {
            return record.lastPositionSeconds
        }
        return nil
    }

    /// Returns all playback history records sorted by most recently played first.
    public func historyRecords() -> [LIDPlaybackRecord] {
        ensureLoaded()
        return records.values.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }

    /// Clears a specific record or all history.
    public func deleteRecord(mediaIdentifier: String) {
        ensureLoaded()
        records.removeValue(forKey: mediaIdentifier)
        persistToDisk()
    }

    public func clearAllHistory() {
        records.removeAll()
        persistToDisk()
    }

    // MARK: - Internal Storage Management

    private func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true

        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let loaded = try JSONDecoder().decode([String: LIDPlaybackRecord].self, from: data)
            self.records = loaded
        } catch {
            // Non-critical; start with fresh dictionary if corrupted
            self.records = [:]
        }
    }

    private func persistToDisk() {
        do {
            let dir = storageURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(records)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Log silently or ignore
        }
    }
}
