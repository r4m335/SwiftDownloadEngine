import Foundation

/// Encapsulates persistent browser tab state saved across app lifecycles.
public struct BrowserSavedSession: Codable, Sendable, Equatable, SchemaVersioned {
    public static let currentSchemaVersion: Int = 3
    public var schemaVersion: Int
    public var activeTabID: UUID?
    public var tabs: [BrowserTabState]
    public var groups: [BrowserTabGroup]
    public var savedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        activeTabID: UUID? = nil,
        tabs: [BrowserTabState] = [],
        groups: [BrowserTabGroup] = [],
        savedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.activeTabID = activeTabID
        // Invariant: Incognito tabs are strictly never persisted in saved sessions.
        self.tabs = Self.sanitizeTabs(tabs.filter { !$0.isIncognito })
        let validGroupIDs = Set(self.tabs.compactMap(\.groupID))
        self.groups = groups.filter { validGroupIDs.contains($0.id) }
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, activeTabID, tabs, groups, savedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
        let rawTabs = try container.decode([BrowserTabState].self, forKey: .tabs)
        self.tabs = Self.sanitizeTabs(rawTabs.filter { !$0.isIncognito })
        self.groups = try container.decodeIfPresent([BrowserTabGroup].self, forKey: .groups) ?? []
        self.savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
    }

    /// Sanitizes tab list by validating URL schemes. Tabs with unsupported, malicious,
    /// or dangerous schemes (e.g. javascript:, data:) are sanitized to safe clean tabs.
    public static func sanitizeTabs(_ tabs: [BrowserTabState]) -> [BrowserTabState] {
        tabs.map { tab in
            guard let url = tab.url else { return tab }
            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https", "about"].contains(scheme) else {
                var cleanTab = tab
                cleanTab.url = nil
                cleanTab.title = "New Tab"
                return cleanTab
            }
            return tab
        }
    }
}

/// Thread-safe storage managing tab session serialization, backup recovery, and schema migrations.
@MainActor
public final class BrowserSessionStore {
    public static let shared = BrowserSessionStore()

    public let fileURL: URL
    public var backupFileURL: URL {
        fileURL.appendingPathExtension("bak")
    }

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = baseDir.appendingPathComponent("lid_browser_session.json")
        }
    }

    public convenience init(directory: URL) {
        self.init(fileURL: directory.appendingPathComponent("lid_browser_session.json"))
    }

    /// Persists the active tabs to disk, strictly filtering out any incognito/ephemeral tabs.
    /// Rotates the previous valid session to a backup file to guarantee zero data loss.
    public func saveSession(tabs: [BrowserTabState], groups: [BrowserTabGroup] = [], activeTabID: UUID?) {
        // Enforce privacy invariant: private tabs must never be written to persistent storage.
        let nonIncognito = tabs.filter { !$0.isIncognito }
        let effectiveActiveID = (activeTabID != nil && nonIncognito.contains(where: { $0.id == activeTabID }))
            ? activeTabID
            : nonIncognito.first?.id

        let session = BrowserSavedSession(
            schemaVersion: BrowserSavedSession.currentSchemaVersion,
            activeTabID: effectiveActiveID,
            tabs: nonIncognito,
            groups: groups,
            savedAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(session)

            // Maintain rolling backup of the last valid session file
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let existingData = try? Data(contentsOf: fileURL) {
                    try? existingData.write(to: backupFileURL, options: .atomic)
                }
            }

            try DurableStorage.writeAtomically(data, to: fileURL)
            PipelineLogger.shared.log(stage: .browser, message: "[BrowserSessionStore] Successfully persisted session with \(nonIncognito.count) tabs (schema v\(session.schemaVersion)).")
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "[BrowserSessionStore] Failed to persist browser session: \(error.localizedDescription)")
        }
    }

    /// Loads the previously saved session from disk, performing schema migration and automatic
    /// failover recovery from the backup file if the primary file is corrupted.
    public func loadSession() -> BrowserSavedSession? {
        // 1. Attempt primary load
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                if let session = try DurableStorage.load(
                    from: fileURL,
                    legacyFallback: { data in
                        try Self.decodeLegacySession(from: data)
                    }
                ) as BrowserSavedSession? {
                    return Self.processLoadedSession(session)
                }
            } catch {
                PipelineLogger.shared.log(
                    stage: .browser,
                    message: "[BrowserSessionStore] Primary session corrupted at \(fileURL.path): \(error.localizedDescription). Attempting recovery from backup..."
                )
            }
        }

        // 2. Failover: Attempt recovery from backup
        if FileManager.default.fileExists(atPath: backupFileURL.path) {
            do {
                if let backupData = try? Data(contentsOf: backupFileURL) {
                    let decoder = JSONDecoder()
                    let recoveredSession: BrowserSavedSession
                    if let direct = try? decoder.decode(BrowserSavedSession.self, from: backupData) {
                        recoveredSession = direct
                    } else {
                        recoveredSession = try Self.decodeLegacySession(from: backupData)
                    }
                    PipelineLogger.shared.log(
                        stage: .browser,
                        message: "[BrowserSessionStore] Successfully recovered browser session from backup at \(backupFileURL.path)."
                    )
                    return Self.processLoadedSession(recoveredSession)
                }
            } catch {
                PipelineLogger.shared.log(
                    stage: .browser,
                    message: "[BrowserSessionStore] Backup session recovery failed: \(error.localizedDescription)"
                )
            }
        }

        PipelineLogger.shared.log(stage: .browser, message: "[BrowserSessionStore] No readable browser session found. Starting fresh.")
        return nil
    }

    /// Decodes older v0 or v1 session representations into current schema.
    private static func decodeLegacySession(from data: Data) throws -> BrowserSavedSession {
        struct LegacySavedSessionV0: Codable {
            var activeTabID: UUID?
            var tabs: [BrowserTabState]
            var savedAt: Date
        }

        struct LegacySavedSessionV1: Codable {
            var schemaVersion: Int?
            var activeTabID: UUID?
            var tabs: [BrowserTabState]
            var savedAt: Date
        }

        if let v1 = try? JSONDecoder().decode(LegacySavedSessionV1.self, from: data) {
            return BrowserSavedSession(
                schemaVersion: 1,
                activeTabID: v1.activeTabID,
                tabs: v1.tabs,
                savedAt: v1.savedAt
            )
        }

        let legacy = try JSONDecoder().decode(LegacySavedSessionV0.self, from: data)
        return BrowserSavedSession(
            schemaVersion: 0,
            activeTabID: legacy.activeTabID,
            tabs: legacy.tabs,
            savedAt: legacy.savedAt
        )
    }

    private static func processLoadedSession(_ session: BrowserSavedSession) -> BrowserSavedSession {
        let safeTabs = BrowserSavedSession.sanitizeTabs(session.tabs.filter { !$0.isIncognito })
        let safeActiveID = (session.activeTabID != nil && safeTabs.contains(where: { $0.id == session.activeTabID }))
            ? session.activeTabID
            : safeTabs.first?.id

        return BrowserSavedSession(
            schemaVersion: session.schemaVersion,
            activeTabID: safeActiveID,
            tabs: safeTabs,
            savedAt: session.savedAt
        )
    }

    /// Clears both primary and backup session files from disk.
    public func clearSession() {
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL)
        try? fm.removeItem(at: backupFileURL)
        PipelineLogger.shared.log(stage: .browser, message: "[BrowserSessionStore] Cleared session files.")
    }
}
