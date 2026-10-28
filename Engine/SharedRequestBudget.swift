import Foundation

/// Errors related to request budgeting and slot allocation.
public enum RequestBudgetError: Error, LocalizedError, Equatable, Sendable {
    case invalidLimit(Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidLimit(let limit):
            return "Request budget limit must be greater than zero, got: \(limit)"
        case .cancelled:
            return "Request budget permit acquisition was cancelled"
        }
    }
}

/// Shared asynchronous HTTP request budget manager across downloads and segment workers.
///
/// **What this limits:**
/// This controls the number of **active in-flight HTTP requests** (e.g. concurrent HTTP byte-range segment
/// workers and single-stream transfers). It coordinates request dispatch across `URLSession` tasks to prevent
/// connection explosion and thread pool starvation. It does NOT claim to manage OS kernel-level TCP socket
/// lifecycles directly, which are managed by `URLSession`'s internal HTTP connection pool.
///
/// **Features:**
/// - Global Active-Request Limit (default 12).
/// - Optional Per-Download Request Limit (prevents one download from consuming all global permits).
/// - Per-Host Request Limit (prevents one server from consuming the whole global budget).
/// - Fair Scheduling: FIFO queue across requests with per-download and per-host cap awareness.
/// - Cancellation-Aware: Cancelling a waiting task immediately removes it from the queue without permit leaks.
/// - Leak-Proof: Releases permits on completion, error, timeout, or cancellation.
public actor SharedRequestBudget {
    private struct Waiter {
        let id: UUID
        let downloadID: String
        let maxPerDownload: Int?
        let host: String?
        let continuation: CheckedContinuation<Void, Error>
    }

    public private(set) var maxGlobalRequests: Int
    public private(set) var maxRequestsPerHost: Int
    public private(set) var currentGlobalActive: Int = 0
    public private(set) var activeByDownload: [String: Int] = [:]
    public private(set) var activeByHost: [String: Int] = [:]
    private var activeHostsByDownload: [String: [String: Int]] = [:]
    private var waiters: [Waiter] = []

    public init(maxGlobalRequests: Int = 12, maxRequestsPerHost: Int = 8) {
        self.maxGlobalRequests = max(1, maxGlobalRequests)
        self.maxRequestsPerHost = max(1, maxRequestsPerHost)
    }

    /// Dynamically updates the global active request limit.
    /// If increased, immediately grants permits to eligible waiting requests.
    public func setMaxGlobalRequests(_ newLimit: Int) throws {
        guard newLimit >= 1 else {
            throw RequestBudgetError.invalidLimit(newLimit)
        }
        maxGlobalRequests = newLimit
        drainWaiters()
    }

    /// Dynamically updates the maximum number of active requests targeting one host.
    public func setMaxRequestsPerHost(_ newLimit: Int) throws {
        guard newLimit >= 1 else {
            throw RequestBudgetError.invalidLimit(newLimit)
        }
        maxRequestsPerHost = newLimit
        drainWaiters()
    }

    /// Number of requests currently waiting for a permit.
    public var waitingCount: Int {
        waiters.count
    }

    /// Number of active requests for a specific download ID.
    public func activeCount(for downloadID: String) -> Int {
        activeByDownload[downloadID] ?? 0
    }

    /// Number of active requests targeting a host.
    public func activeCount(forHost host: String) -> Int {
        activeByHost[Self.normalizeHost(host)] ?? 0
    }

    /// Acquires a permit to launch an active HTTP request.
    ///
    /// Suspends if `currentGlobalActive >= maxGlobalRequests` or if the download has reached its `maxPerDownload` cap.
    /// If cancelled while suspended, removes the waiter and throws `CancellationError`.
    public func acquire(
        downloadID: String,
        maxPerDownload: Int? = nil,
        host: String? = nil
    ) async throws {
        try Task.checkCancellation()
        let normalizedHost = host.map(Self.normalizeHost)

        if canGrantImmediately(downloadID: downloadID, maxPerDownload: maxPerDownload, host: normalizedHost) {
            grant(downloadID: downloadID, host: normalizedHost)
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(
                    id: waiterID,
                    downloadID: downloadID,
                    maxPerDownload: maxPerDownload,
                    host: normalizedHost,
                    continuation: continuation
                )
                waiters.append(waiter)
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    /// Releases a previously acquired permit and wakes up the next eligible waiter.
    public func release(downloadID: String, host: String? = nil) {
        currentGlobalActive = max(0, currentGlobalActive - 1)
        if let count = activeByDownload[downloadID] {
            if count <= 1 {
                activeByDownload.removeValue(forKey: downloadID)
            } else {
                activeByDownload[downloadID] = count - 1
            }
        }
        let normalizedHost = host.map(Self.normalizeHost)
        let hostToRelease = normalizedHost ?? activeHostsByDownload[downloadID]?.first(where: { $0.value > 0 })?.key
        if let hostToRelease {
            decrementHost(hostToRelease, downloadID: downloadID)
        }
        drainWaiters()
    }

    /// Cancels all waiting requests for a specific download.
    public func cancelWaiters(for downloadID: String) {
        let matching = waiters.filter { $0.downloadID == downloadID }
        waiters.removeAll { $0.downloadID == downloadID }
        for w in matching {
            w.continuation.resume(throwing: CancellationError())
        }
    }

    /// Cancels an individual waiter by ID when its task is cancelled.
    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            drainWaiters()
        }
    }

    private func canGrantImmediately(downloadID: String, maxPerDownload: Int?, host: String?) -> Bool {
        guard currentGlobalActive < maxGlobalRequests else { return false }
        if let maxPer = maxPerDownload {
            let currentForDownload = activeByDownload[downloadID] ?? 0
            if currentForDownload >= maxPer {
                return false
            }
        }
        if let host, (activeByHost[host] ?? 0) >= maxRequestsPerHost {
            return false
        }
        return true
    }

    private func grant(downloadID: String, host: String? = nil) {
        currentGlobalActive += 1
        activeByDownload[downloadID, default: 0] += 1
        if let host {
            activeByHost[host, default: 0] += 1
            var hostCounts = activeHostsByDownload[downloadID] ?? [:]
            hostCounts[host, default: 0] += 1
            activeHostsByDownload[downloadID] = hostCounts
        }
    }

    private func decrementHost(_ host: String, downloadID: String) {
        if let count = activeByHost[host] {
            if count <= 1 {
                activeByHost.removeValue(forKey: host)
            } else {
                activeByHost[host] = count - 1
            }
        }

        guard var hosts = activeHostsByDownload[downloadID], let count = hosts[host] else { return }
        if count <= 1 {
            hosts.removeValue(forKey: host)
        } else {
            hosts[host] = count - 1
        }
        if hosts.isEmpty {
            activeHostsByDownload.removeValue(forKey: downloadID)
        } else {
            activeHostsByDownload[downloadID] = hosts
        }
    }

    private func drainWaiters() {
        guard currentGlobalActive < maxGlobalRequests else { return }

        var index = 0
        while index < waiters.count && currentGlobalActive < maxGlobalRequests {
            let waiter = waiters[index]
            if !canGrantImmediately(
                downloadID: waiter.downloadID,
                maxPerDownload: waiter.maxPerDownload,
                host: waiter.host
            ) {
                // This download or host is at capacity; skip to next waiter to keep capacity utilized fairly.
                index += 1
                continue
            }

            // Grant permit to this waiter
            waiters.remove(at: index)
            grant(downloadID: waiter.downloadID, host: waiter.host)
            waiter.continuation.resume()
        }
    }

    private static func normalizeHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
