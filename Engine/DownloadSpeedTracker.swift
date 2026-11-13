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

// MARK: - Milestone 4.3: Bandwidth History & Aggregated Speed Tracking

/// An individual timestamped bandwidth measurement for aggregate download and upload rates.
public struct BandwidthSample: Identifiable, Equatable, Sendable, Codable {
    public var id: TimeInterval { timestamp }
    public let timestamp: TimeInterval // Unix epoch seconds
    public let downloadBytesPerSecond: Double
    public let uploadBytesPerSecond: Double

    public init(timestamp: TimeInterval, downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
        self.timestamp = timestamp
        self.downloadBytesPerSecond = max(0, downloadBytesPerSecond)
        self.uploadBytesPerSecond = max(0, uploadBytesPerSecond)
    }

    public init(date: Date = Date(), downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
        self.init(
            timestamp: date.timeIntervalSince1970,
            downloadBytesPerSecond: downloadBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond
        )
    }
}

/// Bounded, thread-safe rolling-window bandwidth history tracker.
///
/// **Features:**
/// - Maintains timestamped download and upload speed samples up to `maxDuration` seconds (default 60.0s).
/// - Automatically expires samples older than `maxDuration`.
/// - Enforces a strict upper bound on sample capacity (`maxCapacity`) to prevent memory growth.
/// - Calculates peak download and upload rates across the active window.
/// - Thread-safe via NSLock.
public final class BandwidthHistoryTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [BandwidthSample] = []
    public let maxDuration: TimeInterval
    public let maxCapacity: Int

    public init(maxDuration: TimeInterval = 60.0, maxCapacity: Int = 120) {
        self.maxDuration = max(10.0, maxDuration)
        self.maxCapacity = max(60, maxCapacity)
    }

    /// Records an aggregated bandwidth sample at the given timestamp.
    public func record(downloadSpeed: Double, uploadSpeed: Double, timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        let t = timestamp.timeIntervalSince1970
        let sample = BandwidthSample(
            timestamp: t,
            downloadBytesPerSecond: max(0, downloadSpeed),
            uploadBytesPerSecond: max(0, uploadSpeed)
        )
        samples.append(sample)

        // Expire samples older than maxDuration relative to this sample
        let cutoff = t - maxDuration
        while let first = samples.first, first.timestamp < cutoff {
            samples.removeFirst()
        }

        // Bounded capacity safeguard
        if samples.count > maxCapacity {
            let overflow = samples.count - maxCapacity
            samples.removeFirst(overflow)
        }
    }

    /// Returns the current snapshot of active history within the rolling window.
    public func history(asOf date: Date = Date()) -> [BandwidthSample] {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = date.timeIntervalSince1970 - maxDuration
        return samples.filter { $0.timestamp >= cutoff }
    }

    /// Returns the most recent recorded sample, if any.
    public var latestSample: BandwidthSample? {
        lock.lock()
        defer { lock.unlock() }
        return samples.last
    }

    /// Returns the highest download speed recorded within the current active window.
    public func peakDownloadSpeed(asOf date: Date = Date()) -> Double {
        let current = history(asOf: date)
        return current.map(\.downloadBytesPerSecond).max() ?? 0.0
    }

    /// Returns the highest upload speed recorded within the current active window.
    public func peakUploadSpeed(asOf date: Date = Date()) -> Double {
        let current = history(asOf: date)
        return current.map(\.uploadBytesPerSecond).max() ?? 0.0
    }

    /// Clears all recorded samples.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
    }
}
