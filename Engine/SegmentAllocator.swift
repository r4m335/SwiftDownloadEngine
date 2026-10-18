import Foundation

/// Reconstructs 1DM+ v18.2's segment-boundary calculation from the
/// supplied decompilation notes. This is intentionally isolated from networking.
public struct DownloadSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let startOffset: Int64
    public let endOffset: Int64
    public let length: Int64

    public var rangeHeaderValue: String {
        "bytes=\(startOffset)-\(endOffset)"
    }

    public init(id: Int, startOffset: Int64, endOffset: Int64, length: Int64) {
        self.id = id
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.length = length
    }
}

public enum SegmentAllocatorError: Error, Equatable, Sendable {
    case invalidFileSize
    case invalidThreadCount
    case invalidSegmentLayout
}

public enum SegmentAllocator {
    public static let defaultThreadCount = 10
    public static let maxThreadCount = 32
    public static let minimumChunkForThreadLimit: Int64 = 2 * 1024 * 1024
    public static let advancedModeThreshold: Int64 = 32 * 1024 * 1024

    /// Reproduces the allocation rules described in the v18.2 source analysis.
    ///
    /// Note: the 2 MiB value limits the number of segments; it does not guarantee
    /// that every segment is at least 2 MiB. The final segment absorbs the remainder.
    public static func makeSegments(
        totalSize: Int64,
        configuredThreadCount: Int,
        advancedMode: Bool
    ) throws -> [DownloadSegment] {
        guard totalSize > 0 else {
            throw SegmentAllocatorError.invalidFileSize
        }

        var count = configuredThreadCount > 0
            ? configuredThreadCount
            : defaultThreadCount
        count = min(count, maxThreadCount)

        if advancedMode && totalSize >= advancedModeThreshold {
            count = min(count * 2, maxThreadCount)
        }

        let maximumSlices = Int(ceil(Double(totalSize) / Double(minimumChunkForThreadLimit)))
        count = min(count, max(1, maximumSlices))

        guard count > 0 else {
            throw SegmentAllocatorError.invalidThreadCount
        }

        // This unusual formula mirrors the recovered 1DM+ allocation logic.
        let base = (totalSize / Int64(count)) - Int64(count)
        var cursor: Int64 = 0
        var result: [DownloadSegment] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            let length: Int64
            let end: Int64

            if index == count - 1 {
                end = totalSize - 1
                length = totalSize - cursor
            } else {
                length = Int64(index) + base
                guard length > 0, cursor <= Int64.max - length else {
                    throw SegmentAllocatorError.invalidSegmentLayout
                }
                end = cursor + length - 1
            }

            guard length > 0, end >= cursor, end < totalSize else {
                throw SegmentAllocatorError.invalidSegmentLayout
            }

            result.append(
                DownloadSegment(
                    id: index,
                    startOffset: cursor,
                    endOffset: end,
                    length: length
                )
            )

            cursor = end + 1
        }

        // Defensive checks: segments must cover [0, totalSize) exactly once.
        guard result.first?.startOffset == 0,
              result.last?.endOffset == totalSize - 1 else {
            throw SegmentAllocatorError.invalidSegmentLayout
        }

        for index in result.indices {
            if result[index].length != result[index].endOffset - result[index].startOffset + 1 {
                throw SegmentAllocatorError.invalidSegmentLayout
            }
            if index > 0,
               result[index].startOffset != result[index - 1].endOffset + 1 {
                throw SegmentAllocatorError.invalidSegmentLayout
            }
        }

        return result
    }
}
