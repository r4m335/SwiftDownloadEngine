import XCTest
@testable import DM_Reverse_engineering

final class AdaptiveSegmentWorkQueueTests: XCTestCase {
    func testLargeParentIsSplitAndSecondHalfCanBeStolen() async {
        let segment = DownloadSegment(
            id: 7,
            startOffset: 0,
            endOffset: 4 * 1024 * 1024 - 1,
            length: 4 * 1024 * 1024
        )
        let queue = AdaptiveSegmentWorkQueue(segments: [segment], completedBytes: [:])

        let first = await queue.next(workerID: 0)
        let second = await queue.next(workerID: 1)

        guard let first, let second else {
            XCTFail("Expected the large parent range to split into two work items")
            return
        }
        XCTAssertEqual(first.parentSegmentID, 7)
        XCTAssertEqual(second.parentSegmentID, 7)
        XCTAssertEqual(first.endOffset + 1, second.startOffset)
        XCTAssertEqual(first.length + second.length, segment.length)
        XCTAssertNotEqual(first.id, second.id)
        await queue.complete(workerID: 0, workItemID: first.id)
        await queue.complete(workerID: 1, workItemID: second.id)
        let noWork = await queue.next(workerID: 0)
        XCTAssertNil(noWork)
    }

    func testResumeQueueStartsAfterPersistedParentProgress() async {
        let segment = DownloadSegment(id: 3, startOffset: 100, endOffset: 2_099, length: 2_000)
        let queue = AdaptiveSegmentWorkQueue(
            segments: [segment],
            completedBytes: [3: 750]
        )

        let work = await queue.next(workerID: 0)
        XCTAssertEqual(work?.startOffset, 850)
        XCTAssertEqual(work?.endOffset, 2_099)
        XCTAssertEqual(work?.length, 1_250)
    }

    func testProgressAccumulatorAggregatesChildRangesIntoParent() async {
        let segment = DownloadSegment(id: 1, startOffset: 0, endOffset: 1_999, length: 2_000)
        let accumulator = AdaptiveSegmentProgressAccumulator(
            segments: [segment],
            initialCompletedBytes: [1: 500]
        )
        let first = AdaptiveSegmentWorkItem(
            id: 100,
            parentSegmentID: 1,
            startOffset: 500,
            endOffset: 1_249,
            splitDepth: 1
        )
        let second = AdaptiveSegmentWorkItem(
            id: 101,
            parentSegmentID: 1,
            startOffset: 1_250,
            endOffset: 1_999,
            splitDepth: 1
        )

        await accumulator.register(first)
        await accumulator.register(second)
        _ = await accumulator.update(workItemID: first.id, completedBytes: first.length)
        let partialParentBytes = await accumulator.parentCompletedBytes(1)
        XCTAssertEqual(partialParentBytes, 1_250)
        _ = await accumulator.complete(second)
        let completedParentBytes = await accumulator.parentCompletedBytes(1)
        let finalSnapshot = await accumulator.snapshot()
        XCTAssertEqual(completedParentBytes, 2_000)
        XCTAssertEqual(finalSnapshot.completedSegments, 1)
    }
}
