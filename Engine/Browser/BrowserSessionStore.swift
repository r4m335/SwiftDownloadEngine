import Foundation

/// Encapsulates persistent browser tab state saved across app lifecycles.
public struct BrowserSavedSession: Codable, Sendable, Equatable {
    public var activeTabID: UUID?
    public var tabs: [BrowserTabState]
    public var savedAt: Date

    public init(activeTabID: UUID? = nil, tabs: [BrowserTabState] = [], savedAt: Date = Date()) {
        self.activeTabID = activeTabID
        // Invariant: Incognito tabs are strictly never persisted in saved sessions.
        self.tabs = tabs.filter { !$0.isIncognito }
        self.savedAt = savedAt
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
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Failures to save state should not crash the app
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
            let data = try Data(contentsOf: fileURL)
            let session = try JSONDecoder().decode(BrowserSavedSession.self, from: data)
            // Double-check privacy invariant upon load
            let safeTabs = session.tabs.filter { !$0.isIncognito }
            let safeActiveID = (session.activeTabID != nil && safeTabs.contains(where: { $0.id == session.activeTabID }))
                ? session.activeTabID
                : safeTabs.first?.id

            return BrowserSavedSession(
                activeTabID: safeActiveID,
                tabs: safeTabs,
                savedAt: session.savedAt
            )
        } catch {
            return nil
        }
    }

    /// Clears the saved session file from disk.
    public func clearSession() {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.removeItem(at: fileURL)
    }
}
