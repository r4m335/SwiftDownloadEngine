import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Combine)
import Combine
#else
/// Cross-platform fallback for Combine's ObservableObject on non-Apple environments.
public protocol ObservableObject: AnyObject {}

/// Cross-platform fallback for Combine's @Published property wrapper on non-Apple environments.
@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public var projectedValue: Published<Value> {
        get { self }
        set { self = newValue }
    }
}
#endif

/// UI filter options for the download manager list.
public enum DownloadFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case active = "Downloading"
    case paused = "Paused"
    case completed = "Completed"
    case failed = "Failed"
    case liveRecordings = "Live Recordings"
    case torrents = "Torrents"
    case http = "HTTP"
    case hls = "HLS"
    case dash = "DASH"
    case archived = "Archived"

    public static let downloading = DownloadFilter.active
    public var id: String { rawValue }

    public var next: DownloadFilter? {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx + 1 < all.count else { return nil }
        return all[idx + 1]
    }

    public var previous: DownloadFilter? {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx > 0 else { return nil }
        return all[idx - 1]
    }
}

/// Real-time aggregate count summary for download statuses across all unified transfers (HTTP & BitTorrent).
public struct DownloadStatusCounts: Equatable, Sendable {
    public var all: Int
    public var active: Int
    public var paused: Int
    public var completed: Int
    public var failed: Int
    public var liveRecordings: Int
    public var torrents: Int
    public var http: Int
    public var hls: Int
    public var dash: Int
    public var archived: Int

    public init(
        all: Int,
        active: Int,
        paused: Int,
        completed: Int,
        failed: Int,
        liveRecordings: Int = 0,
        torrents: Int = 0,
        http: Int = 0,
        hls: Int = 0,
        dash: Int = 0,
        archived: Int = 0
    ) {
        self.all = all
        self.active = active
        self.paused = paused
        self.completed = completed
        self.failed = failed
        self.liveRecordings = liveRecordings
        self.torrents = torrents
        self.http = http
        self.hls = hls
        self.dash = dash
        self.archived = archived
    }

    public func count(for filter: DownloadFilter) -> Int {
        switch filter {
        case .all: return all
        case .active: return active
        case .paused: return paused
        case .completed: return completed
        case .failed: return failed
        case .liveRecordings: return liveRecordings
        case .torrents: return torrents
        case .http: return http
        case .hls: return hls
        case .dash: return dash
        case .archived: return archived
        }
    }
}

/// Defensive manager for resolving, creating, and validating the downloads directory across the application.
public enum DownloadsDirectoryManager: Sendable {
    public enum Error: LocalizedError, Equatable, Sendable {
        case unwritableDirectory(path: String, underlyingError: String)
        case directoryIsAFile(path: String)
        case allCandidatesFailed(testedPaths: [String], lastError: String)

        public var errorDescription: String? {
            switch self {
            case .unwritableDirectory(let path, let underlyingError):
                return "Downloads directory at '\(path)' is not writable: \(underlyingError)"
            case .directoryIsAFile(let path):
                return "Downloads destination at '\(path)' already exists as a regular file, not a directory."
            case .allCandidatesFailed(let paths, let lastError):
                return "Failed to initialize a writable downloads directory (tested: \(paths.joined(separator: ", "))): \(lastError)"
            }
        }
    }

    /// Directory creation attributes ensuring standard POSIX permissions (0755) and
    /// completeUntilFirstUserAuthentication file protection on Apple platforms so background/locked writes succeed.
    public static var defaultDirectoryAttributes: [FileAttributeKey: Any] {
        var attrs: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o755))
        ]
        #if canImport(Darwin)
        attrs[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        return attrs
    }

    /// Verifies that a directory exists and is writable.
    /// Checks for file-vs-directory collision, applies completeUntilFirstUserAuthentication
    /// file protection on iOS, and runs a live write probe.
    @discardableResult
    public static func ensureDirectoryExistsAndWritable(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                let msg = "A non-directory file already exists at downloads path: \(directory.path)"
                PipelineLogger.shared.log("[FileSystem] Error: \(msg)")
                throw Error.directoryIsAFile(path: directory.path)
            }
            #if canImport(Darwin)
            if let attrs = try? fileManager.attributesOfItem(atPath: directory.path),
               let protection = attrs[.protectionKey] as? FileProtectionType,
               protection == .complete {
                PipelineLogger.shared.log("[FileSystem] Warning: Directory at \(directory.path) has restrictive NSFileProtectionComplete. Upgrading to completeUntilFirstUserAuthentication.")
                do {
                    try fileManager.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: directory.path
                    )
                } catch {
                    let nsErr = error as NSError
                    PipelineLogger.shared.log("[FileSystem] Operation: setAttributes, Path: \(directory.path), Domain: \(nsErr.domain), Code: \(nsErr.code), Description: \(nsErr.localizedDescription), UserInfo: \(nsErr.userInfo)")
                }
            }
            #endif
        } else {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: defaultDirectoryAttributes
                )
                PipelineLogger.shared.log("[FileSystem] Successfully created downloads directory at: \(directory.path)")
            } catch {
                let nsErr = error as NSError
                let logMsg = "[FileSystem] Operation: createDirectory, Path: \(directory.path), Domain: \(nsErr.domain), Code: \(nsErr.code), Description: \(nsErr.localizedDescription), UserInfo: \(nsErr.userInfo)"
                PipelineLogger.shared.log(logMsg)
                throw Error.unwritableDirectory(
                    path: directory.path,
                    underlyingError: "\(nsErr.localizedDescription) (Domain: \(nsErr.domain), Code: \(nsErr.code))"
                )
            }
        }

        // Live write probe verification
        let probeFile = directory.appendingPathComponent(".probe_\(UUID().uuidString).tmp", isDirectory: false)
        do {
            let probeData = Data("probe".utf8)
            try probeData.write(to: probeFile, options: .atomic)
            try fileManager.removeItem(at: probeFile)
        } catch {
            let nsErr = error as NSError
            let logMsg = "[FileSystem] Operation: writeProbe, Path: \(probeFile.path), Domain: \(nsErr.domain), Code: \(nsErr.code), Description: \(nsErr.localizedDescription), UserInfo: \(nsErr.userInfo)"
            PipelineLogger.shared.log(logMsg)
            throw Error.unwritableDirectory(
                path: directory.path,
                underlyingError: "\(nsErr.localizedDescription) (Domain: \(nsErr.domain), Code: \(nsErr.code))"
            )
        }

        return directory
    }

    /// Resolves and validates a writable downloads directory by checking primary and fallback sandbox locations.
    /// Throws if no candidate directory can be created or written to.
    public static func validatedDownloadsDirectory(fileManager: FileManager = .default) throws -> URL {
        var candidates: [URL] = []

        // 1. Primary: Documents/Downloads
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs.appendingPathComponent("Downloads", isDirectory: true))
            // 2. Direct fallback: Documents directory directly
            candidates.append(docs)
        }

        // 3. Fallback: Application Support/Downloads (durable non-purgeable sandbox storage)
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("SwiftDownloadEngine/Downloads", isDirectory: true))
        }

        var testedPaths: [String] = []
        var lastError: Swift.Error?

        for candidate in candidates {
            testedPaths.append(candidate.path)
            do {
                let validated = try ensureDirectoryExistsAndWritable(candidate, fileManager: fileManager)
                PipelineLogger.shared.log("[FileSystem] Validated writable downloads directory: \(validated.path)")
                return validated
            } catch {
                lastError = error
                PipelineLogger.shared.log("[FileSystem] Candidate directory '\(candidate.path)' failed validation (\(error.localizedDescription)). Testing next candidate...")
            }
        }

        let failure = Error.allCandidatesFailed(
            testedPaths: testedPaths,
            lastError: lastError?.localizedDescription ?? "All sandbox directory candidates failed write probe"
        )
        PipelineLogger.shared.log("[FileSystem] Critical: \(failure.localizedDescription)")
        throw failure
    }

    /// Resolves and ensures the writable category subfolder within the downloads directory.
    @discardableResult
    public static func categoryDownloadsDirectory(
        for category: DownloadCategory,
        customSubfolderName: String? = nil,
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try (baseDirectory ?? validatedDownloadsDirectory(fileManager: fileManager))
        let subfolder = customSubfolderName ?? category.defaultSubfolderName
        let categoryDir = base.appendingPathComponent(subfolder, isDirectory: true)
        return try ensureDirectoryExistsAndWritable(categoryDir, fileManager: fileManager)
    }

    /// Pre-creates all standard category subdirectories in the downloads directory.
    public static func ensureAllCategoryDirectoriesExist(
        baseDirectory: URL? = nil,
        categoryFolderMappings: [DownloadCategory: String]? = nil,
        fileManager: FileManager = .default
    ) throws {
        let base = try (baseDirectory ?? validatedDownloadsDirectory(fileManager: fileManager))
        for category in DownloadCategory.allCases {
            let subfolder = categoryFolderMappings?[category] ?? category.defaultSubfolderName
            let categoryDir = base.appendingPathComponent(subfolder, isDirectory: true)
            _ = try ensureDirectoryExistsAndWritable(categoryDir, fileManager: fileManager)
        }
    }

    public struct OrganizedFileResult: Sendable, Equatable {
        public let originalURL: URL
        public let newURL: URL
        public let category: DownloadCategory

        public init(originalURL: URL, newURL: URL, category: DownloadCategory) {
            self.originalURL = originalURL
            self.newURL = newURL
            self.category = category
        }
    }

    /// Atomically moves completed files located directly in the root downloads directory
    /// into their corresponding category subfolders.
    /// Preserves existing subdirectories and ignores temporary/in-progress files (.tmp, .part).
    public static func organizeUncategorizedFiles(
        in rootDirectory: URL,
        categoryFolderMappings: [DownloadCategory: String]? = nil,
        fileManager: FileManager = .default
    ) throws -> [OrganizedFileResult] {
        var results: [OrganizedFileResult] = []
        let contents = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        for item in contents {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                // Do not move existing subdirectories (Videos, Music, Documents, etc.)
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let ext = item.pathExtension.lowercased()
            // Never move active segment/temporary/metadata files
            if ext == "tmp" || ext == "part" || ext == "json" || ext == "meta" || item.lastPathComponent.hasPrefix(".") {
                continue
            }

            let category = DownloadCategoryClassifier.classify(url: item, mimeType: nil)
            let subfolderName = categoryFolderMappings?[category] ?? category.defaultSubfolderName
            let categoryDir = rootDirectory.appendingPathComponent(subfolderName, isDirectory: true)
            _ = try ensureDirectoryExistsAndWritable(categoryDir, fileManager: fileManager)

            let targetURL = FileConflictResolver.uniqueDestinationURL(desiredFilename: item.lastPathComponent, directory: categoryDir)

            // Atomic move
            try fileManager.moveItem(at: item, to: targetURL)
            results.append(OrganizedFileResult(originalURL: item, newURL: targetURL, category: category))
            PipelineLogger.shared.log("[FileSystem] Atomically organized '\(item.lastPathComponent)' into '\(subfolderName)/\(targetURL.lastPathComponent)'")
        }

        return results
    }

    /// Resolves the default destination downloads directory with defensive validation and surfaces any temporary-directory fallback error.
    public static func resolveDefaultDownloadsDirectory() -> (url: URL, fallbackError: String?) {
        do {
            return (try validatedDownloadsDirectory(), nil)
        } catch {
            let emergencyURL = FileManager.default.temporaryDirectory.appendingPathComponent("EmergencyDownloads", isDirectory: true)
            _ = try? FileManager.default.createDirectory(at: emergencyURL, withIntermediateDirectories: true, attributes: defaultDirectoryAttributes)
            let msg = "Downloads folder could not be accessed (\(error.localizedDescription)). Using temporary storage — files may be purged by the system."
            PipelineLogger.shared.log("[FileSystem] \(msg)")
            return (emergencyURL, msg)
        }
    }

    /// Resolves the default destination downloads directory with defensive validation and fallback cascades.
    public static func defaultDownloadsDirectory() -> URL {
        resolveDefaultDownloadsDirectory().url
    }
}

