import Foundation

public struct BrowserHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var url: URL
    public var visitDate: Date
    public var visitCount: Int

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        visitDate: Date = Date(),
        visitCount: Int = 1
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.visitDate = visitDate
        self.visitCount = visitCount
    }
}

public final class BrowserHistoryStore: @unchecked Sendable {
    public static let shared = BrowserHistoryStore()
    public static let didChangeNotification = Notification.Name("BrowserHistoryStoreDidChangeNotification")

    private let lock = NSLock()
    private var entries: [BrowserHistoryEntry] = []
    private let storageURL: URL?

    public init(customStorageURL: URL? = nil) {
        if let customStorageURL {
            self.storageURL = customStorageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let dir = appSupport?.appendingPathComponent("Browser", isDirectory: true)
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.storageURL = dir?.appendingPathComponent("history.json")
        }
        load()
    }

    public struct BrowserHistoryPayload: Codable, SchemaVersioned {
        public static let currentSchemaVersion: Int = 1
        public var schemaVersion: Int
        public var entries: [BrowserHistoryEntry]

        public init(
            schemaVersion: Int = Self.currentSchemaVersion,
            entries: [BrowserHistoryEntry]
        ) {
            self.schemaVersion = schemaVersion
            self.entries = entries
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, entries
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            self.entries = try container.decode([BrowserHistoryEntry].self, forKey: .entries)
        }
    }

    public func load() {
        lock.lock()
        defer { lock.unlock() }

        guard let storageURL else { return }
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }

        do {
            if let payload = try DurableStorage.load(
                from: storageURL,
                legacyFallback: { data in
                    let legacyEntries = try JSONDecoder().decode([BrowserHistoryEntry].self, from: data)
                    return BrowserHistoryPayload(schemaVersion: 0, entries: legacyEntries)
                }
            ) as BrowserHistoryPayload? {
                self.entries = payload.entries
            }
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "Failed to load history at \(storageURL.path): \(error)")
            self.entries = []
        }
    }

    public func save() {
        lock.lock()
        guard let storageURL else {
            lock.unlock()
            return
        }
        let payload = BrowserHistoryPayload(entries: entries)
        do {
            let data = try JSONEncoder().encode(payload)
            try DurableStorage.writeAtomically(data, to: storageURL)
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "Failed to persist history: \(error)")
        }
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Records a page visit into persistent history.
    ///
    /// Invariant: Incognito visits are strictly ignored and never persisted.
    public func recordVisit(url: URL, title: String, isIncognito: Bool) {
        guard !isIncognito else { return }
        let clean = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "about:blank" else { return }

        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (url.host ?? clean)
            : title

        lock.lock()
        let calendar = Calendar.current
        let now = Date()

        if let index = entries.firstIndex(where: {
            $0.url.absoluteString == url.absoluteString &&
            calendar.isDate($0.visitDate, inSameDayAs: now)
        }) {
            entries[index].title = displayTitle
            entries[index].visitDate = now
            entries[index].visitCount += 1
            // Bring to top
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
        } else {
            let entry = BrowserHistoryEntry(
                title: displayTitle,
                url: url,
                visitDate: now,
                visitCount: 1
            )
            entries.insert(entry, at: 0)
        }

        // Cap history to 1000 most recent entries
        if entries.count > 1000 {
            entries = Array(entries.prefix(1000))
        }
        lock.unlock()

        save()
    }

    public func deleteEntry(id: UUID) {
        lock.lock()
        entries.removeAll(where: { $0.id == id })
        lock.unlock()
        save()
    }

    public func clearAllHistory() {
        clearHistory(since: nil)
    }

    public func clearHistory(since date: Date? = nil) {
        lock.lock()
        if let date {
            entries.removeAll(where: { $0.visitDate >= date })
        } else {
            entries.removeAll()
        }
        lock.unlock()
        save()
    }

    public func searchHistory(query: String) -> [BrowserHistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allEntries }

        lock.lock()
        defer { lock.unlock() }
        return entries.filter {
            $0.title.lowercased().contains(q) || $0.url.absoluteString.lowercased().contains(q)
        }
    }

    public var allEntries: [BrowserHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public struct HistoryGroup: Identifiable, Sendable {
        public var id: String { sectionTitle }
        public let sectionTitle: String
        public let entries: [BrowserHistoryEntry]
    }

    /// Returns history partitioned into chronological sections (Today, Yesterday, Last 7 Days, Older).
    public func groupedChronologically() -> [HistoryGroup] {
        let items = allEntries
        let calendar = Calendar.current
        let now = Date()

        var today: [BrowserHistoryEntry] = []
        var yesterday: [BrowserHistoryEntry] = []
        var last7Days: [BrowserHistoryEntry] = []
        var older: [BrowserHistoryEntry] = []

        for item in items {
            if calendar.isDateInToday(item.visitDate) {
                today.append(item)
            } else if calendar.isDateInYesterday(item.visitDate) {
                yesterday.append(item)
            } else if let diff = calendar.dateComponents([.day], from: item.visitDate, to: now).day, diff <= 7 {
                last7Days.append(item)
            } else {
                older.append(item)
            }
        }

        var groups: [HistoryGroup] = []
        if !today.isEmpty { groups.append(HistoryGroup(sectionTitle: "Today", entries: today)) }
        if !yesterday.isEmpty { groups.append(HistoryGroup(sectionTitle: "Yesterday", entries: yesterday)) }
        if !last7Days.isEmpty { groups.append(HistoryGroup(sectionTitle: "Last 7 Days", entries: last7Days)) }
        if !older.isEmpty { groups.append(HistoryGroup(sectionTitle: "Older", entries: older)) }

        return groups
    }
}
