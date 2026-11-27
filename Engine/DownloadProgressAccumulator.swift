import Foundation

/// Thread-safe accumulator computing aggregate progress across concurrent workers.
actor ProgressAccumulator {
    private let segmentsByID: [Int: DownloadSegment]
    private var completedByID: [Int: Int64]
    private var lastFlushedBytesByID: [Int: Int64] = [:]
    private var lastFlushedTimeByID: [Int: Date] = [:]

    init(segments: [DownloadSegment], initialCompletedBytes: [Int: Int64]) {
        self.segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        self.completedByID = initialCompletedBytes
        self.lastFlushedBytesByID = initialCompletedBytes
        let now = Date()
        self.lastFlushedTimeByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, now) })
    }

    func update(
        segmentID: Int,
        completedBytes: Int64
    ) -> (bytesReceived: Int64, completedSegments: Int) {
        guard let segment = segmentsByID[segmentID] else {
            let total = completedByID.values.reduce(0, +)
            return (total, 0)
        }
        completedByID[segmentID] = min(segment.length, max(0, completedBytes))
        let total = completedByID.values.reduce(Int64(0), +)
        let finished = segmentsByID.values.filter {
            (completedByID[$0.id] ?? 0) >= $0.length
        }.count
        return (total, finished)
    }

    func snapshot() -> (bytesReceived: Int64, completedSegments: Int) {
        let total = completedByID.values.reduce(Int64(0), +)
        let finished = segmentsByID.values.filter {
            (completedByID[$0.id] ?? 0) >= $0.length
        }.count
        return (total, finished)
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
}
