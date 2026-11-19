import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// In-memory and disk cache for visual tab thumbnails and website previews.
///
/// Security & Privacy Guarantees:
/// - Incognito tab previews are strictly ephemeral: stored only in memory while the tab
///   is open and NEVER written to persistent disk storage.
/// - When an incognito tab is closed, its memory cache is purged immediately.
public final class BrowserTabPreviewCache: @unchecked Sendable {
    public static let shared = BrowserTabPreviewCache()

    private let lock = NSLock()
    private var memoryCache: [UUID: Data] = [:]
    private let fileManager = FileManager.default
    private let cacheDirectoryURL: URL?

    public init(customCacheDirectoryURL: URL? = nil) {
        if let customCacheDirectoryURL {
            self.cacheDirectoryURL = customCacheDirectoryURL
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            self.cacheDirectoryURL = caches?.appendingPathComponent("TabPreviews", isDirectory: true)
        }

        if let dir = cacheDirectoryURL {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Stores thumbnail preview data for a tab.
    ///
    /// - Parameters:
    ///   - data: Encoded JPEG/PNG image data.
    ///   - tabID: The unique identifier of the tab.
    ///   - isIncognito: If true, preview is strictly kept in memory and never written to disk.
    public func setPreview(_ data: Data, for tabID: UUID, isIncognito: Bool) {
        lock.lock()
        defer { lock.unlock() }

        memoryCache[tabID] = data

        guard !isIncognito, let dir = cacheDirectoryURL else { return }
        let fileURL = dir.appendingPathComponent("\(tabID.uuidString).jpg")
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            PipelineLogger.shared.log(stage: .browser, message: "Failed to write tab preview: \(error)")
        }
    }

    /// Retrieves thumbnail preview data for a tab.
    public func preview(for tabID: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = memoryCache[tabID] {
            return cached
        }

        guard let dir = cacheDirectoryURL else { return nil }
        let fileURL = dir.appendingPathComponent("\(tabID.uuidString).jpg")
        if let diskData = try? Data(contentsOf: fileURL) {
            memoryCache[tabID] = diskData
            return diskData
        }
        return nil
    }

    /// Removes preview data from both memory and disk when a tab is closed.
    public func removePreview(for tabID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        memoryCache.removeValue(forKey: tabID)

        if let dir = cacheDirectoryURL {
            let fileURL = dir.appendingPathComponent("\(tabID.uuidString).jpg")
            do {
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
            } catch {
                PipelineLogger.shared.log(stage: .browser, message: "Failed to remove tab preview: \(error)")
            }
        }
    }

    /// Purges all previews (e.g. when clearing browsing data or app reset).
    public func clearAllPreviews() {
        lock.lock()
        defer { lock.unlock() }

        memoryCache.removeAll()

        if let dir = cacheDirectoryURL {
            do {
                if fileManager.fileExists(atPath: dir.path) {
                    try fileManager.removeItem(at: dir)
                }
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                PipelineLogger.shared.log(stage: .browser, message: "Failed to reset preview cache dir: \(error)")
            }
        }
    }

    public func clearAll() {
        clearAllPreviews()
    }
}
