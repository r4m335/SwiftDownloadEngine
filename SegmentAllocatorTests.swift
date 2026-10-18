import XCTest
@testable import DM_Reverse_engineering

final class SegmentAllocatorTests: XCTestCase {
    func testSmallFileUsesOneSegment() throws {
        let segments = try SegmentAllocator.makeSegments(
            totalSize: 1_500_000,
            configuredThreadCount: 10,
            advancedMode: false
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startOffset, 0)
        XCTAssertEqual(segments[0].endOffset, 1_499_999)
        XCTAssertEqual(segments[0].length, 1_500_000)
    }

    func testThreeMiBUsesTwoSegmentsAndCoversEveryByte() throws {
        let total: Int64 = 3 * 1024 * 1024
        let segments = try SegmentAllocator.makeSegments(
            totalSize: total,
            configuredThreadCount: 10,
            advancedMode: false
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?.startOffset, 0)
        XCTAssertEqual(segments.last?.endOffset, total - 1)
        XCTAssertEqual(segments.reduce(Int64(0)) { $0 + $1.length }, total)
        XCTAssertEqual(segments[0].endOffset + 1, segments[1].startOffset)
    }

    func testThreadCountIsCappedAtThirtyTwo() throws {
        let segments = try SegmentAllocator.makeSegments(
            totalSize: 256 * 1024 * 1024,
            configuredThreadCount: 100,
            advancedMode: false
        )
        XCTAssertLessThanOrEqual(segments.count, 32)
    }

    func testAdvancedModeDoublesRequestedCountAtThreshold() throws {
        let total: Int64 = 64 * 1024 * 1024
        let normal = try SegmentAllocator.makeSegments(
            totalSize: total,
            configuredThreadCount: 4,
            advancedMode: false
        )
        let advanced = try SegmentAllocator.makeSegments(
            totalSize: total,
            configuredThreadCount: 4,
            advancedMode: true
        )

        XCTAssertEqual(normal.count, 4)
        XCTAssertEqual(advanced.count, 8)
    }

    func testSegmentsAreContiguousAndNonOverlapping() throws {
        let sizes: [Int64] = [
            2_097_153,
            3_145_728,
            10_000_003,
            33_554_432,
            100_000_007
        ]

        for size in sizes {
            let segments = try SegmentAllocator.makeSegments(
                totalSize: size,
                configuredThreadCount: 7,
                advancedMode: true
            )
            XCTAssertEqual(segments.first?.startOffset, 0)
            XCTAssertEqual(segments.last?.endOffset, size - 1)
            XCTAssertEqual(segments.reduce(Int64(0)) { $0 + $1.length }, size)

            for index in 1..<segments.count {
                XCTAssertEqual(segments[index].startOffset, segments[index - 1].endOffset + 1)
            }
        }
    }

    func testInvalidFileSizeThrows() {
        XCTAssertThrowsError(
            try SegmentAllocator.makeSegments(
                totalSize: 0,
                configuredThreadCount: 4,
                advancedMode: false
            )
        )
    }
}
