import Foundation

/// Encapsulates persistent browser tab state saved across app lifecycles.
public struct BrowserSavedSession: Codable, Sendable, Equatable, SchemaVersioned {
    public static let currentSchemaVersion: Int = 1
    public var schemaVersion: Int
    public var activeTabID: UUID?
    public var tabs: [BrowserTabState]
    public var savedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        activeTabID: UUID? = nil,
        tabs: [BrowserTabState] = [],
        savedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.activeTabID = activeTabID
        // Invariant: Incognito tabs are strictly never persisted in saved sessions.
        self.tabs = tabs.filter { !$0.isIncognito }
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, activeTabID, tabs, savedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        self.activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
        let rawTabs = try container.decode([BrowserTabState].self, forKey: .tabs)
        self.tabs = rawTabs.filter { !$0.isIncognito }
        self.savedAt = try container.decode(Date.self, forKey: .savedAt)
    }
}

/// Thread-safe storage managing tab session serialization and restoration.
public final class BrowserSessionStore: @unchecked Sendable {
    public static let shared = BrowserSessionStore()

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = baseDir.appendingPathComponent("lid_browser_session.json")
        }
    }

    /// Persists the active tabs to disk, strictly filtering out any incognito/ephemeral tabs.
    public func saveSession(tabs: [BrowserTabState], activeTabID: UUID?) {
        lock.lock()
        defer { lock.unlock() }

        // Enforce privacy invariant: private tabs must never be written to persistent storage.
        let nonIncognito = tabs.filter { !$0.isIncognito }
        let effectiveActiveID = (activeTabID != nil && nonIncognito.contains(where: { $0.id == activeTabID }))
            ? activeTabID
            : nonIncognito.first?.id

        let session = BrowserSavedSession(
            activeTabID: effectiveActiveID,
            tabs: nonIncognito,
            savedAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(session)
            try DurableStorage.writeAtomically(data, to: fileURL)
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "Failed to persist browser session: \(error)")
        }
    }

    /// Loads the previously saved session from disk.
    public func loadSession() -> BrowserSavedSession? {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            guard let session = try DurableStorage.load(
                from: fileURL,
                legacyFallback: { data in
                    struct LegacySavedSession: Codable {
                        var activeTabID: UUID?
                        var tabs: [BrowserTabState]
                        var savedAt: Date
                    }
                    let legacy = try JSONDecoder().decode(LegacySavedSession.self, from: data)
                    return BrowserSavedSession(
                        schemaVersion: 0,
                        activeTabID: legacy.activeTabID,
                        tabs: legacy.tabs,
                        savedAt: legacy.savedAt
                    )
                }
            ) as BrowserSavedSession? else {
                return nil
            }
            // Double-check privacy invariant upon load
            let safeTabs = session.tabs.filter { !$0.isIncognito }
            let safeActiveID = (session.activeTabID != nil && safeTabs.contains(where: { $0.id == session.activeTabID }))
                ? session.activeTabID
                : safeTabs.first?.id

            return BrowserSavedSession(
                schemaVersion: session.schemaVersion,
                activeTabID: safeActiveID,
                tabs: safeTabs,
                savedAt: session.savedAt
            )
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "[BrowserSessionStore] Corrupt browser session at \(fileURL.path) was quarantined: \(error)")
            return nil
        }
    }

    /// Clears the saved session file from disk.
    public func clearSession() {
        lock.lock()
        defer { lock.unlock() }

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "Failed to remove session file \(fileURL.path): \(error)")
        }
    }
}
