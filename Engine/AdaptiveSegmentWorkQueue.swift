import Foundation

/// A transient range used by the foreground scheduler.
///
/// Work items deliberately retain their persisted parent segment ID. Child
/// ranges are never written to the durable record; they only allow a faster
/// worker to claim the remaining half of a slower parent segment.
struct AdaptiveSegmentWorkItem: Sendable, Equatable {
    let id: Int
    let parentSegmentID: Int
    let startOffset: Int64
    let endOffset: Int64
    let splitDepth: Int

    var length: Int64 {
        endOffset - startOffset + 1
    }

    var downloadSegment: DownloadSegment {
        DownloadSegment(
            id: id,
            startOffset: startOffset,
            endOffset: endOffset,
            length: length
        )
    }
}

/// Distributes transient child ranges to whichever worker becomes available.
///
/// The first lease of a sufficiently large parent range splits it in half.
/// The second half remains pending, so a faster worker can steal it after
/// finishing another range. A depth limit prevents unbounded fragmentation.
actor AdaptiveSegmentWorkQueue {
    static let minimumSplitLength: Int64 = 1 * 1024 * 1024

    private var pending: [AdaptiveSegmentWorkItem]
    private var activeByWorker: [Int: AdaptiveSegmentWorkItem] = [:]
    private var nextWorkItemID = 1_000_000

    init(segments: [DownloadSegment], completedBytes: [Int: Int64]) {
        self.pending = []
        self.pending.reserveCapacity(segments.count)

        for segment in segments {
            let completed = min(segment.length, max(0, completedBytes[segment.id] ?? 0))
            guard completed < segment.length else { continue }

            pending.append(
                AdaptiveSegmentWorkItem(
                    id: nextWorkItemID,
                    parentSegmentID: segment.id,
                    startOffset: segment.startOffset + completed,
                    endOffset: segment.endOffset,
                    splitDepth: 0
                )
            )
            nextWorkItemID += 1
        }
    }

    func next(workerID: Int) -> AdaptiveSegmentWorkItem? {
        guard activeByWorker[workerID] == nil, !pending.isEmpty else { return nil }

        // Prefer the largest pending range. This keeps the remaining tail of
        // the slowest parent available for work stealing first.
        let index = pending.indices.max { lhs, rhs in
            pending[lhs].length < pending[rhs].length
        }!
        var item = pending.remove(at: index)

        if item.splitDepth == 0, item.length >= Self.minimumSplitLength * 2 {
            let firstLength = item.length / 2
            let splitOffset = item.startOffset + firstLength
            let second = AdaptiveSegmentWorkItem(
                id: nextWorkItemID,
                parentSegmentID: item.parentSegmentID,
                startOffset: splitOffset,
                endOffset: item.endOffset,
                splitDepth: 1
            )
            nextWorkItemID += 1
            pending.append(second)

            item = AdaptiveSegmentWorkItem(
                id: nextWorkItemID,
                parentSegmentID: item.parentSegmentID,
                startOffset: item.startOffset,
                endOffset: splitOffset - 1,
                splitDepth: 1
            )
            nextWorkItemID += 1
        }

        activeByWorker[workerID] = item
        return item
    }

    func complete(workerID: Int, workItemID: Int) {
        guard activeByWorker[workerID]?.id == workItemID else { return }
        activeByWorker.removeValue(forKey: workerID)
    }
}

/// Aggregates transient child progress back into the persisted parent layout.
actor AdaptiveSegmentProgressAccumulator {
    struct Snapshot: Sendable {
        let bytesReceived: Int64
        let completedSegments: Int
    }

    private let segmentsByID: [Int: DownloadSegment]
    private let initialCompletedByID: [Int: Int64]
    private var completedByID: [Int: Int64]
    private var parentByWorkItem: [Int: Int] = [:]
    private var workLengths: [Int: Int64] = [:]
    private var workCompleted: [Int: Int64] = [:]
    private var lastFlushedBytesByID: [Int: Int64]
    private var lastFlushedTimeByID: [Int: Date]

    init(segments: [DownloadSegment], initialCompletedBytes: [Int: Int64]) {
        self.segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        self.initialCompletedByID = Dictionary(uniqueKeysWithValues: segments.map {
            ($0.id, min($0.length, max(0, initialCompletedBytes[$0.id] ?? 0)))
        })
        self.completedByID = self.initialCompletedByID
        let now = Date()
        self.lastFlushedBytesByID = self.completedByID
        self.lastFlushedTimeByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, now) })
    }

    func register(_ workItem: AdaptiveSegmentWorkItem) {
        parentByWorkItem[workItem.id] = workItem.parentSegmentID
        workLengths[workItem.id] = workItem.length
        workCompleted[workItem.id] = 0
    }

    func update(workItemID: Int, completedBytes: Int64) -> Snapshot {
        guard let parentID = parentByWorkItem[workItemID],
              let workLength = workLengths[workItemID] else {
            return snapshot()
        }

        workCompleted[workItemID] = min(workLength, max(0, completedBytes))
        recalculate(parentID: parentID)
        return snapshot()
    }

    func complete(_ workItem: AdaptiveSegmentWorkItem) -> Snapshot {
        if parentByWorkItem[workItem.id] == nil {
            register(workItem)
        }
        workCompleted[workItem.id] = workItem.length
        recalculate(parentID: workItem.parentSegmentID)
        return snapshot()
    }

    func parentCompletedBytes(_ parentID: Int) -> Int64 {
        completedByID[parentID] ?? 0
    }

    func shouldCheckpoint(segmentID: Int, completedBytes: Int64) -> Bool {
        let lastBytes = lastFlushedBytesByID[segmentID] ?? 0
        let lastTime = lastFlushedTimeByID[segmentID] ?? .distantPast
        let bytesDelta = completedBytes - lastBytes
        let timeDelta = Date().timeIntervalSince(lastTime)

        if bytesDelta >= 256 * 1024 || timeDelta >= 1.0 {
            lastFlushedBytesByID[segmentID] = completedBytes
            lastFlushedTimeByID[segmentID] = Date()
            return true
        }
        return false
    }

    func getCompletedBytes() -> [Int: Int64] {
        completedByID
    }

    func snapshot() -> Snapshot {
        let total = completedByID.values.reduce(Int64(0), +)
        let finished = segmentsByID.values.filter {
            (completedByID[$0.id] ?? 0) >= $0.length
        }.count
        return Snapshot(bytesReceived: total, completedSegments: finished)
    }

    private func recalculate(parentID: Int) {
        guard let parent = segmentsByID[parentID] else { return }
        let initial = initialCompletedByID[parentID] ?? 0
        let childBytes = parentByWorkItem.reduce(Int64(0)) { partial, entry in
            guard entry.value == parentID else { return partial }
            return partial + (workCompleted[entry.key] ?? 0)
        }
        completedByID[parentID] = min(parent.length, initial + childBytes)
    }
}
