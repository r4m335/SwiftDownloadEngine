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
        durationSeconds: Double,
        selectedAudioTrackId: String? = nil,
        selectedSubtitleTrackId: String? = nil
    ) {
        ensureLoaded()

        let isCompleted = durationSeconds > 0 && (positionSeconds >= (durationSeconds - 5.0) || positionSeconds >= (durationSeconds * 0.97))
        let effectivePosition = isCompleted ? 0.0 : positionSeconds

        let existing = records[mediaIdentifier]
        let audioId = selectedAudioTrackId ?? existing?.selectedAudioTrackId
        let subId = selectedSubtitleTrackId ?? existing?.selectedSubtitleTrackId

        let record = LIDPlaybackRecord(
            mediaIdentifier: mediaIdentifier,
            title: title,
            lastPositionSeconds: effectivePosition,
            durationSeconds: durationSeconds,
            lastPlayedAt: Date(),
            isCompleted: isCompleted,
            selectedAudioTrackId: audioId,
            selectedSubtitleTrackId: subId
        )

        records[mediaIdentifier] = record
        persistToDisk()
    }

    /// Records user-selected audio or subtitle tracks for an asset.
    public func recordSelectedTracks(
        mediaIdentifier: String,
        audioTrackId: String?,
        subtitleTrackId: String?
    ) {
        ensureLoaded()
        guard var existing = records[mediaIdentifier] else { return }
        if let audioId = audioTrackId {
            existing.selectedAudioTrackId = audioId
        }
        if let subId = subtitleTrackId {
            existing.selectedSubtitleTrackId = subId
        }
        records[mediaIdentifier] = existing
        persistToDisk()
    }

    /// Retrieves the full playback record for an asset, if available.
    public func playbackRecord(mediaIdentifier: String) -> LIDPlaybackRecord? {
        ensureLoaded()
        return records[mediaIdentifier]
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

    public struct LIDPlaybackHistoryPayload: Codable, SchemaVersioned {
        public static let currentSchemaVersion: Int = 1
        public var schemaVersion: Int
        public var records: [String: LIDPlaybackRecord]

        public init(schemaVersion: Int = Self.currentSchemaVersion, records: [String: LIDPlaybackRecord]) {
            self.schemaVersion = schemaVersion
            self.records = records
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, records
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            self.records = try container.decode([String: LIDPlaybackRecord].self, forKey: .records)
        }
    }

    private func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true

        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            if let payload = try DurableStorage.load(
                from: storageURL,
                legacyFallback: { data in
                    let legacy = try JSONDecoder().decode([String: LIDPlaybackRecord].self, from: data)
                    return LIDPlaybackHistoryPayload(schemaVersion: 0, records: legacy)
                }
            ) as LIDPlaybackHistoryPayload? {
                self.records = payload.records
            }
        } catch {
            PipelineLogger.shared.log(stage: .persistence, message: "[LIDPlaybackHistoryStore] Corrupt playback history at \(storageURL.path) was quarantined: \(error)")
            self.records = [:]
        }
    }

    private func persistToDisk() {
        let payload = LIDPlaybackHistoryPayload(records: records)
        do {
            let data = try JSONEncoder().encode(payload)
            try DurableStorage.writeAtomically(data, to: storageURL)
        } catch {
            PipelineLogger.shared.log(stage: .persistence, message: "[LIDPlaybackHistoryStore] Failed to persist playback history: \(error)")
        }
    }
}
