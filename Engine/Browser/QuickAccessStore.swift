import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A user-customizable Quick Access / Speed Dial shortcut displayed on the browser New Tab page.
public struct QuickAccessShortcut: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var url: URL
    public var faviconURL: URL?
    public var displayOrder: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        url: URL,
        faviconURL: URL? = nil,
        displayOrder: Int = 0
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.url = url
        self.faviconURL = faviconURL
        self.displayOrder = displayOrder
    }
}

/// Validation errors for user-supplied Quick Access URLs and names.
public enum QuickAccessValidationError: LocalizedError, Equatable, Sendable {
    case emptyName
    case emptyURL
    case invalidScheme
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Website name cannot be empty."
        case .emptyURL:
            return "Website URL cannot be empty."
        case .invalidScheme:
            return "Only HTTP and HTTPS URLs are permitted."
        case .invalidURL:
            return "Please enter a valid website address."
        }
    }
}

/// Validates and normalizes user input for Quick Access shortcuts.
public enum QuickAccessURLValidator {
    /// Normalizes a user-entered URL string, automatically adding https:// if missing.
    public static func normalizeURLString(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }
        // If it starts with another explicit scheme (e.g. ftp://, file://, javascript:, mailto:)
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[..<colonIndex]).lowercased()
            let afterColon = trimmed[trimmed.index(after: colonIndex)...]
            if afterColon.hasPrefix("//") || prefix == "javascript" || prefix == "data" || prefix == "mailto" || prefix == "about" {
                return trimmed
            }
        }
        return "https://" + trimmed
    }

    /// Validates shortcut name and URL, ensuring valid scheme and host domain.
    public static func validate(name: String, urlString: String) -> Result<(name: String, url: URL), QuickAccessValidationError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .failure(.emptyName)
        }

        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return .failure(.emptyURL)
        }

        let normalized = normalizeURLString(trimmedURL)
        guard let url = URL(string: normalized) else {
            return .failure(.invalidURL)
        }

        guard let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") else {
            return .failure(.invalidScheme)
        }

        guard let host = url.host, !host.isEmpty else {
            return .failure(.invalidURL)
        }

        let lowerHost = host.lowercased()
        // Host must contain a period, or be localhost, or valid IP
        if lowerHost != "localhost" && !lowerHost.contains(".") {
            return .failure(.invalidURL)
        }

        return .success((name: trimmedName, url: url))
    }
}

/// Direction for reordering a shortcut relative to adjacent items.
public enum QuickAccessMoveDirection: Sendable {
    case left
    case right
}

/// Thread-safe persistent storage manager for Quick Access shortcuts.
///
/// Designed to be completely independent from BrowserBookmarkStore and BrowserHistoryStore.
public final class QuickAccessStore: @unchecked Sendable {
    public static let shared = QuickAccessStore()
    public static let userDefaultsKey = "com.r4m335.SwiftDownloadEngine.QuickAccessShortcuts"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageURL: URL?

    public init(defaults: UserDefaults = .standard, customStorageURL: URL? = nil) {
        self.defaults = defaults
        self.storageURL = customStorageURL
    }

    /// Sensible default shortcuts provided to new users or when resetting shortcuts.
    public static let defaultShortcuts: [QuickAccessShortcut] = [
        QuickAccessShortcut(
            id: "default-duckduckgo",
            name: "DuckDuckGo",
            url: URL(string: "https://duckduckgo.com")!,
            displayOrder: 0
        ),
        QuickAccessShortcut(
            id: "default-wikipedia",
            name: "Wikipedia",
            url: URL(string: "https://www.wikipedia.org")!,
            displayOrder: 1
        ),
        QuickAccessShortcut(
            id: "default-github",
            name: "GitHub",
            url: URL(string: "https://github.com")!,
            displayOrder: 2
        ),
        QuickAccessShortcut(
            id: "default-archive",
            name: "Internet Archive",
            url: URL(string: "https://archive.org")!,
            displayOrder: 3
        ),
        QuickAccessShortcut(
            id: "default-cloudflare",
            name: "Cloudflare Speed",
            url: URL(string: "https://speed.cloudflare.com")!,
            displayOrder: 4
        ),
        QuickAccessShortcut(
            id: "default-apple",
            name: "Apple",
            url: URL(string: "https://www.apple.com")!,
            displayOrder: 5
        )
    ]

    public struct QuickAccessPayload: Codable, SchemaVersioned {
        public static let currentSchemaVersion: Int = 1
        public var schemaVersion: Int
        public var shortcuts: [QuickAccessShortcut]

        public init(schemaVersion: Int = Self.currentSchemaVersion, shortcuts: [QuickAccessShortcut]) {
            self.schemaVersion = schemaVersion
            self.shortcuts = shortcuts
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, shortcuts
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            self.shortcuts = try container.decode([QuickAccessShortcut].self, forKey: .shortcuts)
        }
    }

    /// Loads shortcuts sorted by their display order. If none exist, returns default shortcuts.
    public func load() -> [QuickAccessShortcut] {
        lock.lock()
        defer { lock.unlock() }

        if let storageURL {
            do {
                if let payload = try DurableStorage.load(
                    from: storageURL,
                    legacyFallback: { data in
                        let list = try JSONDecoder().decode([QuickAccessShortcut].self, from: data)
                        return QuickAccessPayload(schemaVersion: 0, shortcuts: list)
                    }
                ) as QuickAccessPayload? {
                    return payload.shortcuts.sorted { $0.displayOrder < $1.displayOrder }
                }
            } catch {
                PipelineLogger.shared.log(stage: .browser, message: "[QuickAccessStore] Corrupted shortcuts at \(storageURL.path) was quarantined: \(error)")
            }
        }

        if let data = defaults.data(forKey: Self.userDefaultsKey) {
            if let payload = try? JSONDecoder().decode(QuickAccessPayload.self, from: data) {
                return payload.shortcuts.sorted { $0.displayOrder < $1.displayOrder }
            } else if let legacy = try? JSONDecoder().decode([QuickAccessShortcut].self, from: data) {
                return legacy.sorted { $0.displayOrder < $1.displayOrder }
            }
        }

        return Self.defaultShortcuts
    }

    /// Saves shortcuts atomically to persistent storage.
    public func save(_ shortcuts: [QuickAccessShortcut]) {
        lock.lock()
        defer { lock.unlock() }

        // Normalize display orders sequentially
        var normalized: [QuickAccessShortcut] = []
        for (index, item) in shortcuts.enumerated() {
            var updated = item
            updated.displayOrder = index
            normalized.append(updated)
        }

        do {
            let payload = QuickAccessPayload(shortcuts: normalized)
            let data = try JSONEncoder().encode(payload)
            defaults.set(data, forKey: Self.userDefaultsKey)
            if let storageURL {
                try DurableStorage.writeAtomically(data, to: storageURL)
            }
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "Failed to persist quick access shortcuts: \(error)")
        }
    }

    /// Adds a new shortcut to the end of the collection.
    @discardableResult
    public func add(name: String, url: URL, faviconURL: URL? = nil) -> QuickAccessShortcut {
        var current = load()
        let newShortcut = QuickAccessShortcut(
            id: UUID().uuidString,
            name: name,
            url: url,
            faviconURL: faviconURL,
            displayOrder: current.count
        )
        current.append(newShortcut)
        save(current)
        return newShortcut
    }

    /// Updates an existing shortcut by its stable unique ID.
    public func update(_ shortcut: QuickAccessShortcut) {
        var current = load()
        if let index = current.firstIndex(where: { $0.id == shortcut.id }) {
            current[index] = shortcut
            save(current)
        }
    }

    /// Deletes a shortcut by its ID without touching bookmarks or history.
    public func delete(id: String) {
        var current = load()
        current.removeAll { $0.id == id }
        save(current)
    }

    /// Moves a shortcut by shifting it left or right in the display order.
    public func move(id: String, direction: QuickAccessMoveDirection) {
        var current = load()
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }

        switch direction {
        case .left:
            guard index > 0 else { return }
            current.swapAt(index, index - 1)
        case .right:
            guard index < current.count - 1 else { return }
            current.swapAt(index, index + 1)
        }

        save(current)
    }

    /// Moves shortcuts using index offsets.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var current = load()
        current.move(fromOffsets: source, toOffset: destination)
        save(current)
    }

    /// Resets shortcuts back to the factory defaults.
    public func resetToDefaults() {
        save(Self.defaultShortcuts)
    }
}

/// Lightweight, resilient service for fetching and caching website favicons.
public final class FaviconService: @unchecked Sendable {
    public static let shared = FaviconService()

    private let cache = NSCache<NSString, NSData>()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func defaultFaviconURL(for host: String) -> URL? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanHost.isEmpty else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(cleanHost).ico")
    }

    public func cachedFaviconData(for host: String) -> Data? {
        let key = host.lowercased() as NSString
        return cache.object(forKey: key) as Data?
    }

    public func setCachedFaviconData(_ data: Data, for host: String) {
        let key = host.lowercased() as NSString
        cache.setObject(data as NSData, forKey: key)
    }

    public func fetchFaviconData(for url: URL) async -> Data? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if let cached = cachedFaviconData(for: host) {
            return cached
        }

        guard let faviconURL = Self.defaultFaviconURL(for: host) else { return nil }
        var request = URLRequest(url: faviconURL)
        request.timeoutInterval = 4.0
        request.cachePolicy = .returnCacheDataElseLoad

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty {
                setCachedFaviconData(data, for: host)
                return data
            }
        } catch {
            // Gracefully ignore fetch errors and fall back to monogram
        }
        return nil
    }
}
