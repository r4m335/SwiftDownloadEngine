import Foundation

#if canImport(UIKit)
import UIKit
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

    public var hasEnoughSpace: Bool { availableBytes >= requiredBytes }
    
    public init(requiredBytes: Int64, availableBytes: Int64) {
        self.requiredBytes = requiredBytes
        self.availableBytes = availableBytes
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
        self.temporaryDirectoryURL = temporaryDirectoryURL
            ?? destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".tmp", isDirectory: true)

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: self.temporaryDirectoryURL,
            withIntermediateDirectories: true
        )

        if mode == .directSeek {
            if !FileManager.default.fileExists(atPath: destinationURL.path) {
                guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: destinationURL)
            try handle.truncate(atOffset: UInt64(totalSize))
            self.destinationHandle = handle
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
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

#if canImport(Darwin)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let values = try parent.resourceValues(forKeys: keys)
        let capacity = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
#else
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey]
        let values = try? parent.resourceValues(forKeys: keys)
        let capacity: Int64? = values?.volumeAvailableCapacity.map(Int64.init)
#endif

        guard let capacity else {
            // If the filesystem cannot report capacity, do not fabricate a
            // value. Returning zero makes the caller decide whether to proceed.
            return DiskSpaceReport(requiredBytes: requiredBytes + max(0, reserveBytes), availableBytes: 0)
        }

        let requiredWithReserve = requiredBytes + max(0, reserveBytes)
        return DiskSpaceReport(
            requiredBytes: requiredWithReserve,
            availableBytes: Int64(capacity)
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
        guard bufferSize > 0 else {
            throw DownloadFileWriterError.invalidOffset
        }

        try closePartHandles()

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        var mergedBytes: Int64 = 0
        for id in orderedSegmentIDs {
            let partURL = partFileURL(segmentID: id)
            guard FileManager.default.fileExists(atPath: partURL.path) else {
                throw DownloadFileWriterError.missingPartFile(segmentID: id)
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
        if let expectedMergedSize, mergedBytes != expectedMergedSize {
            throw DownloadFileWriterError.mergeLengthMismatch(
                expected: expectedMergedSize,
                actual: mergedBytes
            )
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
