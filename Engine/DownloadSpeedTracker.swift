import Foundation

/// Integrity check outcome for a completed file download.
public enum ChecksumOutcome: Equatable, Sendable, Codable {
    case verified(sha256: String)
    case mismatch(expected: String, actual: String)
    case notChecked
}

/// Point-in-time download speed and ETA metrics.
public struct SpeedMetrics: Equatable, Sendable {
    public let currentBytesPerSecond: Double
    public let averageBytesPerSecond: Double
    public let totalBytesReceived: Int64
    public let totalBytesExpected: Int64?
    public let elapsedTime: TimeInterval
    public let estimatedTimeRemaining: TimeInterval?

    public init(
        currentBytesPerSecond: Double,
        averageBytesPerSecond: Double,
        totalBytesReceived: Int64,
        totalBytesExpected: Int64?,
        elapsedTime: TimeInterval,
        estimatedTimeRemaining: TimeInterval?
    ) {
        self.currentBytesPerSecond = currentBytesPerSecond
        self.averageBytesPerSecond = averageBytesPerSecond
        self.totalBytesReceived = totalBytesReceived
        self.totalBytesExpected = totalBytesExpected
        self.elapsedTime = elapsedTime
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }
}

/// High-performance thread-safe speed tracker and ETA calculator.
///
/// **Features:**
/// - Monotonic Timing: Uses `ProcessInfo.processInfo.systemUptime` to measure elapsed duration accurately.
/// - Rolling Window Speed: Computes current instantaneous speed over a 1.0-second sliding window.
/// - Cumulative Average Speed: Tracks overall transfer rate since inception.
/// - Sensible ETA: Reports estimated remaining time only when total size is known, file size > 0,
///   and transfer rate > 0. Returns `nil` for zero-byte or indeterminate-size downloads without inventing numbers.
/// - Non-blocking: Synchronous locked sampling avoids actor hops on high-frequency chunk writes.
public final class DownloadSpeedTracker: @unchecked Sendable {
    private struct ByteSample {
        let timestamp: TimeInterval
        let bytes: Int64
    }

    private let lock = NSLock()
    private let startTime: TimeInterval
    private var samples: [ByteSample] = []
    private var totalBytes: Int64 = 0
    private let windowDuration: TimeInterval

    public init(windowDuration: TimeInterval = 1.0) {
        self.windowDuration = max(0.2, windowDuration)
        self.startTime = ProcessInfo.processInfo.systemUptime
    }

    /// Records transferred bytes from a chunk write.
    public func record(bytes: Int64) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        totalBytes += bytes
        samples.append(ByteSample(timestamp: now, bytes: bytes))

        // Prune samples older than rolling window
        let cutoff = now - windowDuration
        while let first = samples.first, first.timestamp < cutoff {
            samples.removeFirst()
        }
    }

    /// Returns current speed and time metrics snapshot.
    ///
    /// - Parameter expectedTotalBytes: Expected file size from probe, if known.
    public func snapshot(expectedTotalBytes: Int64? = nil) -> SpeedMetrics {
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0.001, now - startTime)

        // Prune older samples
        let cutoff = now - windowDuration
        while let first = samples.first, first.timestamp < cutoff {
            samples.removeFirst()
        }

        // Current rolling speed
        let windowBytes = samples.reduce(Int64(0)) { $0 + $1.bytes }
        let effectiveWindow = min(elapsed, windowDuration)
        let currentSpeed = Double(windowBytes) / max(0.001, effectiveWindow)

        // Overall average speed
        let averageSpeed = Double(totalBytes) / elapsed

        // ETA calculation
        var eta: TimeInterval? = nil
        if let totalExpected = expectedTotalBytes, totalExpected > 0 {
            let remaining = max(0, totalExpected - totalBytes)
            if remaining == 0 {
                eta = 0
            } else if currentSpeed > 0 {
                eta = max(0, Double(remaining) / currentSpeed)
            } else if averageSpeed > 0 {
                eta = max(0, Double(remaining) / averageSpeed)
            }
        }

        return SpeedMetrics(
            currentBytesPerSecond: currentSpeed,
            averageBytesPerSecond: averageSpeed,
            totalBytesReceived: totalBytes,
            totalBytesExpected: expectedTotalBytes,
            elapsedTime: elapsed,
            estimatedTimeRemaining: eta
        )
    }

    /// Resets all samples and counters (e.g. upon resume or restart).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        totalBytes = 0
    }
}
