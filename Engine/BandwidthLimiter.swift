import Foundation

/// Asynchronous token-bucket bandwidth rate limiter.
///
/// **What this limits:**
/// This throttles **successfully received and written response-body bytes** (the exact payload data
/// transferred to the file writer). It does not charge headers or failed/retried byte ranges against the quota.
///
/// **Features:**
/// - Cancellation-Aware: Suspensions use `Task.sleep` which aborts immediately upon task cancellation or pause.
/// - Dynamic Limit Adjustment: Changing rate limits immediately updates the refill rate and capacity.
/// - Deadlock-Free Multi-Limiter Throttling: `throttle(bytes:global:perDownload:)` evaluates reservations
///   atomically without holding cross-limiter locks.
/// - Configurable Burst: Permits small bursts up to `burstCapacity` while enforcing sustained average rate.
public actor BandwidthLimiter {
    public private(set) var bytesPerSecond: Int64?
    public private(set) var burstCapacity: Int64

    private var availableTokens: Double
    private var lastRefillTime: TimeInterval

    public init(bytesPerSecond: Int64?, burstCapacity: Int64? = nil) {
        self.bytesPerSecond = bytesPerSecond
        if let explicitBurst = burstCapacity {
            self.burstCapacity = max(1, explicitBurst)
        } else if let rate = bytesPerSecond, rate > 0 {
            // Default burst is 1 second worth of bandwidth, or at least 64 KiB
            self.burstCapacity = max(64 * 1024, rate)
        } else {
            self.burstCapacity = 64 * 1024
        }
        self.availableTokens = Double(self.burstCapacity)
        self.lastRefillTime = ProcessInfo.processInfo.systemUptime
    }

    /// Dynamically updates the bandwidth limit.
    /// - Parameter newLimit: Target bytes per second, or `nil` for unrestricted speed.
    public func setRateLimit(_ newLimit: Int64?) {
        refillTokens()
        self.bytesPerSecond = newLimit
        if let rate = newLimit, rate > 0 {
            self.burstCapacity = max(64 * 1024, rate)
        }
        self.availableTokens = min(Double(self.burstCapacity), self.availableTokens)
    }

    /// Calculates required sleep duration for consuming `bytes` without holding actor locks during sleep.
    ///
    /// - Parameter bytes: Number of response body bytes to allocate.
    /// - Returns: TimeInterval in seconds to sleep before writing.
    public func reserve(bytes: Int64) -> TimeInterval {
        guard let rate = bytesPerSecond, rate > 0 else {
            return 0
        }

        refillTokens()

        let needed = Double(bytes)
        if availableTokens >= needed {
            availableTokens -= needed
            return 0
        }

        let deficit = needed - availableTokens
        availableTokens = -deficit
        let waitSeconds = deficit / Double(rate)
        return max(0, waitSeconds)
    }

    private func refillTokens() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, now - lastRefillTime)
        lastRefillTime = now

        guard let rate = bytesPerSecond, rate > 0 else {
            availableTokens = Double(burstCapacity)
            return
        }

        let refilled = elapsed * Double(rate)
        availableTokens = min(Double(burstCapacity), availableTokens + refilled)
    }

    /// High-level multi-limiter coordination method.
    ///
    /// Evaluates both per-download and global limiters without nested actor calls or lock ordering issues.
    /// Suspends for the maximum required delay across both limiters.
    public static func throttle(
        bytes: Int64,
        global: BandwidthLimiter?,
        perDownload: BandwidthLimiter?
    ) async throws {
        guard bytes > 0 else { return }

        var maxDelay: TimeInterval = 0

        if let perDownload = perDownload {
            let delay = await perDownload.reserve(bytes: bytes)
            maxDelay = max(maxDelay, delay)
        }

        if let global = global {
            let delay = await global.reserve(bytes: bytes)
            maxDelay = max(maxDelay, delay)
        }

        if maxDelay > 0 {
            let nanos = UInt64(maxDelay * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanos)
        }
    }
}
