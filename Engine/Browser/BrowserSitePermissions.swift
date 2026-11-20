import Foundation

/// A persistent record representing an explicit user-granted or denied site permission.
public struct BrowserSitePermissionEntry: Identifiable, Codable, Sendable, Equatable {
    public var id: String { "\(domain)_\(permissionType.rawValue)" }
    public let domain: String
    public let permissionType: BrowserPermissionType
    public var decision: BrowserPermissionDecisionResult
    public let updatedAt: Date

    public init(
        domain: String,
        permissionType: BrowserPermissionType,
        decision: BrowserPermissionDecisionResult,
        updatedAt: Date = Date()
    ) {
        self.domain = BrowserDomainMatcher.normalizeDomain(domain)
        self.permissionType = permissionType
        self.decision = decision
        self.updatedAt = updatedAt
    }
}

/// Thread-safe, persistent store managing per-site hardware permissions (Camera, Microphone, Geolocation, Device Motion).
@MainActor
public final class BrowserSitePermissionsStore {
    public static let shared = BrowserSitePermissionsStore()

    private var entries: [String: BrowserSitePermissionEntry] = [:]
    private let persistenceURL: URL

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.persistenceURL = storageURL
        } else {
            let fileManager = FileManager.default
            let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let appDir = baseDir.appendingPathComponent("SwiftDownloadEngine", isDirectory: true)
            try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.persistenceURL = appDir.appendingPathComponent("lid_site_permissions.json")
        }
        loadFromDisk()
    }

    // MARK: - Query & Mutation

    public func permission(for hostOrURL: String, type: BrowserPermissionType) -> BrowserPermissionDecisionResult? {
        let domain = BrowserDomainMatcher.normalizeDomain(hostOrURL)
        guard !domain.isEmpty else { return nil }

        let key = "\(domain)_\(type.rawValue)"
        if let entry = entries[key] {
            return entry.decision
        }

        // Check if cameraAndMicrophone umbrella permission exists
        if type == .camera || type == .microphone {
            let umbrellaKey = "\(domain)_\(BrowserPermissionType.cameraAndMicrophone.rawValue)"
            if let entry = entries[umbrellaKey] {
                return entry.decision
            }
        }

        return nil
    }

    public func setPermission(
        _ decision: BrowserPermissionDecisionResult,
        for hostOrURL: String,
        type: BrowserPermissionType
    ) {
        let domain = BrowserDomainMatcher.normalizeDomain(hostOrURL)
        guard !domain.isEmpty else { return }

        let entry = BrowserSitePermissionEntry(
            domain: domain,
            permissionType: type,
            decision: decision,
            updatedAt: Date()
        )
        entries[entry.id] = entry
        saveToDisk()
    }

    public func removePermission(for hostOrURL: String, type: BrowserPermissionType) {
        let domain = BrowserDomainMatcher.normalizeDomain(hostOrURL)
        guard !domain.isEmpty else { return }

        let key = "\(domain)_\(type.rawValue)"
        entries.removeValue(forKey: key)
        saveToDisk()
    }

    public func removeAllPermissions(for hostOrURL: String) {
        let domain = BrowserDomainMatcher.normalizeDomain(hostOrURL)
        guard !domain.isEmpty else { return }

        entries = entries.filter { $0.value.domain != domain }
        saveToDisk()
    }

    public func clearAll() {
        entries.removeAll()
        saveToDisk()
    }

    public var allEntries: [BrowserSitePermissionEntry] {
        return Array(entries.values).sorted { $0.domain < $1.domain }
    }

    public func entries(for hostOrURL: String) -> [BrowserSitePermissionEntry] {
        let domain = BrowserDomainMatcher.normalizeDomain(hostOrURL)
        guard !domain.isEmpty else { return [] }

        return entries.values.filter { $0.domain == domain }
    }

    // MARK: - Persistence

    public struct BrowserSitePermissionsPayload: Codable, SchemaVersioned {
        public static let currentSchemaVersion: Int = 1
        public var schemaVersion: Int
        public var entries: [BrowserSitePermissionEntry]

        public init(
            schemaVersion: Int = Self.currentSchemaVersion,
            entries: [BrowserSitePermissionEntry]
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
            self.entries = try container.decode([BrowserSitePermissionEntry].self, forKey: .entries)
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }

        do {
            if let payload = try DurableStorage.load(
                from: persistenceURL,
                legacyFallback: { data in
                    let legacy = try JSONDecoder().decode([BrowserSitePermissionEntry].self, from: data)
                    return BrowserSitePermissionsPayload(schemaVersion: 0, entries: legacy)
                }
            ) as BrowserSitePermissionsPayload? {
                entries = Dictionary(uniqueKeysWithValues: payload.entries.map { ($0.id, $0) })
            }
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "[BrowserSitePermissions] Corrupt site permissions at \(persistenceURL.path) was quarantined: \(error)")
            entries = [:]
        }
    }

    private func saveToDisk() {
        let payload = BrowserSitePermissionsPayload(entries: Array(entries.values))
        do {
            let data = try JSONEncoder().encode(payload)
            try DurableStorage.writeAtomically(data, to: persistenceURL)
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "Failed to persist site permissions: \(error)")
        }
    }
}
