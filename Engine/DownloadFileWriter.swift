import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Storage strategy recovered from the 1DM+ investigation notes.
public enum DownloadStorageMode: String, Codable, Sendable {
    /// Standard HTTP downloads write segments directly to their absolute offsets
    /// in one pre-sized destination file.
    case directSeek

    /// HLS/split-style downloads write separate temporary part files that are
    /// merged after all parts have completed.
    case partFiles
}

public enum DownloadFileWriterError: Error, Equatable {
    case invalidTotalSize
    case insufficientDiskSpace(required: Int64, available: Int64)
    case missingPartFile(segmentID: Int)
    case unsupportedOperationForMode
    case invalidOffset
    case mergeLengthMismatch(expected: Int64, actual: Int64)
}

/// Disk-space information used by the preflight check.
public struct DiskSpaceReport: Equatable, Sendable {
    public let requiredBytes: Int64
    public let availableBytes: Int64
    public let isCapacityDetermined: Bool

    public var hasEnoughSpace: Bool {
        if !isCapacityDetermined {
            // Indeterminate capacity: allow caller to proceed to write attempt
            return true
        }
        return availableBytes >= requiredBytes
    }

    public init(requiredBytes: Int64, availableBytes: Int64, isCapacityDetermined: Bool = true) {
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
        self.isCapacityDetermined = isCapacityDetermined
    }
}

/// A single actor owns file handles and serializes all seek/write/merge operations.
///
/// For direct mode, each write is placed at an absolute offset.
/// For part-file mode, each segment is written to its own temporary file; the
/// coordinator can merge those files once every segment has completed.
public actor DownloadFileWriter {
    public let destinationURL: URL
    public let temporaryDirectoryURL: URL
    public let mode: DownloadStorageMode
    public let totalSize: Int64

    private var destinationHandle: FileHandle?
    private var partHandles: [Int: FileHandle] = [:]

    public init(
        destinationURL: URL,
        totalSize: Int64,
        mode: DownloadStorageMode = .directSeek,
        temporaryDirectoryURL: URL? = nil
    ) throws {
        guard totalSize > 0 else {
            throw DownloadFileWriterError.invalidTotalSize
        }

        self.destinationURL = destinationURL
        self.totalSize = totalSize
        self.mode = mode
        let parentDir = destinationURL.deletingLastPathComponent()
        self.temporaryDirectoryURL = temporaryDirectoryURL
            ?? parentDir.appendingPathComponent(".tmp", isDirectory: true)

        try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(parentDir)
        try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(self.temporaryDirectoryURL)

        if mode == .directSeek {
            let fileExisted = FileManager.default.fileExists(atPath: destinationURL.path)
            if !fileExisted {
                guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            do {
                let handle = try FileHandle(forWritingTo: destinationURL)
                do {
                    try handle.truncate(atOffset: UInt64(totalSize))
                    self.destinationHandle = handle
                } catch {
                    try? handle.close()
                    if !fileExisted {
                        try? FileManager.default.removeItem(at: destinationURL)
                    }
                    throw error
                }
            } catch {
                if !fileExisted {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                throw error
            }
        }
    }

    deinit {
        try? destinationHandle?.close()
        for handle in partHandles.values {
            try? handle.close()
        }
    }

    /// Check capacity before creating/preallocating the download destination.
    ///
    /// `reserveBytes` is an optional safety margin for metadata, filesystem
    /// overhead, and application-specific temporary data.
    public static func checkDiskSpace(
        for destinationURL: URL,
        requiredBytes: Int64,
        reserveBytes: Int64 = 64 * 1024 * 1024
    ) throws -> DiskSpaceReport {
        guard requiredBytes > 0 else {
            throw DownloadFileWriterError.invalidTotalSize
        }

        let parent = destinationURL.deletingLastPathComponent()
        try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(parent)

#if canImport(Darwin)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let values = try? parent.resourceValues(forKeys: keys)
        var capacity = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map(Int64.init)
#else
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey]
        let values = try? parent.resourceValues(forKeys: keys)
        var capacity: Int64? = values?.volumeAvailableCapacity.map(Int64.init)
#endif

        if capacity == nil {
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
            var stat = statvfs()
            let statResult = parent.withUnsafeFileSystemRepresentation { ptr -> Int32 in
                guard let ptr else { return -1 }
                return statvfs(ptr, &stat)
            }
            if statResult == 0 && stat.f_frsize > 0 {
                let freeBytes = Int64(stat.f_bavail) * Int64(stat.f_frsize)
                capacity = max(0, freeBytes)
            }
            #endif
        }

        let requiredWithReserve = requiredBytes + max(0, reserveBytes)
        guard let capacity else {
            // If the filesystem cannot report capacity, do not fabricate a false failure.
            // Returning an indeterminate report lets the caller attempt writing safely.
            return DiskSpaceReport(
                requiredBytes: requiredWithReserve,
                availableBytes: 0,
                isCapacityDetermined: false
            )
        }

        return DiskSpaceReport(
            requiredBytes: requiredWithReserve,
            availableBytes: capacity,
            isCapacityDetermined: true
        )
    }

    public static func requireSufficientDiskSpace(
        for destinationURL: URL,
        requiredBytes: Int64,
        reserveBytes: Int64 = 64 * 1024 * 1024
    ) throws -> DiskSpaceReport {
        let report = try checkDiskSpace(
            for: destinationURL,
            requiredBytes: requiredBytes,
            reserveBytes: reserveBytes
        )
        guard report.hasEnoughSpace else {
            throw DownloadFileWriterError.insufficientDiskSpace(
                required: report.requiredBytes,
                available: report.availableBytes
            )
        }
        return report
    }

    /// Write bytes in direct-seek mode at an absolute destination offset.
    public func writeDirect(_ data: Data, at offset: Int64) throws {
        guard mode == .directSeek else {
            throw DownloadFileWriterError.unsupportedOperationForMode
        }
        guard offset >= 0, offset + Int64(data.count) <= totalSize else {
            throw DownloadFileWriterError.invalidOffset
        }
        guard let handle = destinationHandle else {
            throw CocoaError(.fileWriteUnknown)
        }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    /// Append a chunk to one segment's temporary part file.
    public func appendPart(_ data: Data, segmentID: Int) throws {
        guard mode == .partFiles else {
            throw DownloadFileWriterError.unsupportedOperationForMode
        }

        let handle: FileHandle
        if let existing = partHandles[segmentID] {
            handle = existing
        } else {
            let url = partFileURL(segmentID: segmentID)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            partHandles[segmentID] = handle
        }

        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Merge part files in the supplied order. The caller is responsible for
    /// supplying the correct order and verifying each part's expected length.
    public func mergePartFiles(
        orderedSegmentIDs: [Int],
        expectedMergedSize: Int64? = nil,
        bufferSize: Int = 8 * 1024
    ) throws {
        guard mode == .partFiles else {
            throw DownloadFileWriterError.unsupportedOperationForMode
        }
        guard !orderedSegmentIDs.isEmpty else {
            throw DownloadFileWriterError.unsupportedOperationForMode
        }
        guard bufferSize > 0 else {
            throw DownloadFileWriterError.invalidOffset
        }

        try closePartHandles()

        for id in orderedSegmentIDs {
            let partURL = partFileURL(segmentID: id)
            guard FileManager.default.fileExists(atPath: partURL.path) else {
                throw DownloadFileWriterError.missingPartFile(segmentID: id)
            }
        }

        let partURLs = orderedSegmentIDs.map { partFileURL(segmentID: $0) }
        try Self.mergeFiles(
            partURLs: partURLs,
            destinationURL: destinationURL,
            expectedMergedSize: expectedMergedSize,
            bufferSize: bufferSize
        )
    }

    /// Merges an arbitrary list of part file URLs sequentially into destinationURL.
    public static func mergeFiles(
        partURLs: [URL],
        destinationURL: URL,
        expectedMergedSize: Int64? = nil,
        bufferSize: Int = 64 * 1024
    ) throws {
        guard !partURLs.isEmpty else {
            throw DownloadFileWriterError.unsupportedOperationForMode
        }
        guard bufferSize > 0 else {
            throw DownloadFileWriterError.invalidOffset
        }

        let fileManager = FileManager.default
        let parentDir = destinationURL.deletingLastPathComponent()
        try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(parentDir, fileManager: fileManager)

        // Stage into a temporary file in the destination directory to protect existing files from partial write failures
        let stagingURL = parentDir.appendingPathComponent(".merge-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: stagingURL) }

        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: stagingURL)
        defer { try? output.close() }

        var mergedBytes: Int64 = 0
        for partURL in partURLs {
            guard fileManager.fileExists(atPath: partURL.path) else {
                throw CocoaError(.fileNoSuchFile)
            }

            let input = try FileHandle(forReadingFrom: partURL)
            defer { try? input.close() }

            while true {
                let data = try input.read(upToCount: bufferSize) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                mergedBytes += Int64(data.count)
            }
        }

        try output.synchronize()
        try output.close()

        if let expectedMergedSize, mergedBytes != expectedMergedSize {
            throw DownloadFileWriterError.mergeLengthMismatch(
                expected: expectedMergedSize,
                actual: mergedBytes
            )
        }

        // Atomically replace destination only after the merged file has been fully validated
        if fileManager.fileExists(atPath: destinationURL.path) {
            #if canImport(Darwin)
            do {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL, backupItemName: nil, options: [])
            } catch {
                // Non-destructive fallback: preserve existing destination if move fails
                let backupURL = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".backup-\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                do {
                    try fileManager.moveItem(at: stagingURL, to: destinationURL)
                    _ = try? fileManager.removeItem(at: backupURL)
                } catch {
                    _ = try? fileManager.moveItem(at: backupURL, to: destinationURL)
                    throw error
                }
            }
            #else
            let backupURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".backup-\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
            try fileManager.moveItem(at: destinationURL, to: backupURL)
            do {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
                _ = try? fileManager.removeItem(at: backupURL)
            } catch {
                _ = try? fileManager.moveItem(at: backupURL, to: destinationURL)
                throw error
            }
            #endif
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }

        // Ensure merged destination file is physically flushed to disk
        do {
            let destHandle = try FileHandle(forWritingTo: destinationURL)
            defer { try? destHandle.close() }
            try destHandle.synchronize()
        } catch {
            throw error
        }
    }

    public func synchronize() throws {
        if let destinationHandle {
            try destinationHandle.synchronize()
        }
        for handle in partHandles.values {
            try handle.synchronize()
        }
    }

    public func close() throws {
        try closePartHandles()
        if let destinationHandle {
            try destinationHandle.close()
            self.destinationHandle = nil
        }
    }

    public func cleanupPartFiles(segmentIDs: [Int]? = nil) throws {
        try closePartHandles()
        let ids = segmentIDs ?? discoverPartIDs()
        for id in ids {
            let url = partFileURL(segmentID: id)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func partFileURL(segmentID: Int) -> URL {
        temporaryDirectoryURL.appendingPathComponent("segment-\(segmentID).part")
    }

    private func closePartHandles() throws {
        for handle in partHandles.values {
            try handle.close()
        }
        partHandles.removeAll()
    }

    private func discoverPartIDs() -> [Int] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard url.pathExtension == "part",
                  url.lastPathComponent.hasPrefix("segment-") else { return nil }
            let raw = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "segment-", with: "")
            return Int(raw)
        }
    }
}

extension FileManager {
    /// Safely resolves physical file size across Darwin (NSNumber) and Linux/POSIX (Int64/Int).
    public func fileSize(atPath path: String) -> Int64? {
        guard let attributes = try? attributesOfItem(atPath: path),
              let sizeValue = attributes[.size] else { return nil }
        return (sizeValue as? NSNumber)?.int64Value ?? (sizeValue as? Int64)
    }

    /// Safely resolves physical file size across Darwin (NSNumber) and Linux/POSIX (Int64/Int).
    public func fileSize(at url: URL) -> Int64? {
        fileSize(atPath: url.path)
    }
}
