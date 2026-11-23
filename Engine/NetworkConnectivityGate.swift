import Foundation

#if canImport(Network)
import Network
#endif

/// Waits for a usable network path before a foreground request is attempted
/// again. URLSession still owns the active transfer and waitsForConnectivity;
/// this gate prevents retry loops from spending attempts while offline.
public actor NetworkConnectivityGate {
    public static let shared = NetworkConnectivityGate()

#if canImport(Network)
    private struct WaiterPolicy: Sendable {
        let allowsCellular: Bool
        let allowsExpensive: Bool
        let allowsConstrained: Bool
    }

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "DownloadEngineKit.network-path")
    private var latestPath: NWPath?
    private var waiters: [UUID: (policy: WaiterPolicy, continuation: CheckedContinuation<Void, Error>)] = [:]

    public init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.start(queue: monitorQueue)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task {
                await self.pathDidChange(path)
            }
        }
    }

    deinit {
        monitor.cancel()
    }
#else
    public init() {}
#endif

    func waitUntilAvailable(
        allowsCellular: Bool,
        allowsExpensive: Bool = true,
        allowsConstrained: Bool = false
    ) async throws {
#if canImport(Network)
        try Task.checkCancellation()

        let policy = WaiterPolicy(
            allowsCellular: allowsCellular,
            allowsExpensive: allowsExpensive,
            allowsConstrained: allowsConstrained
        )

        if let latestPath, Self.isUsable(latestPath, policy: policy) {
            return
        }

        // If latestPath is nil (monitor initializing), give it a brief window to report initial status
        if latestPath == nil {
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 50_000_000)
                if let path = latestPath {
                    if Self.isUsable(path, policy: policy) {
                        return
                    }
                    break
                }
            }
            // If still nil after 500ms (e.g. CLI process or loopback environment), proceed without blocking
            if latestPath == nil {
                return
            }
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let latestPath, Self.isUsable(latestPath, policy: policy) {
                    continuation.resume()
                } else {
                    waiters[waiterID] = (policy: policy, continuation: continuation)
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
#else
        _ = allowsCellular
        _ = allowsExpensive
        _ = allowsConstrained
        try Task.checkCancellation()
#endif
    }

    func waitUntilAvailable(networkPolicy: DownloadNetworkPolicy) async throws {
        try await waitUntilAvailable(
            allowsCellular: networkPolicy.allowsCellularAccess,
            allowsExpensive: networkPolicy.allowsExpensiveNetworkAccess,
            allowsConstrained: networkPolicy.allowsConstrainedNetworkAccess
        )
    }

#if canImport(Network)
    private func pathDidChange(_ path: NWPath) {
        latestPath = path
        guard path.status == .satisfied else { return }

        let readyIDs = waiters.compactMap { id, waiter in
            Self.isUsable(path, policy: waiter.policy) ? id : nil
        }
        for id in readyIDs {
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            waiter.continuation.resume()
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private static func isUsable(_ path: NWPath, policy: WaiterPolicy) -> Bool {
        guard path.status == .satisfied else { return false }
        guard !path.usesInterfaceType(.cellular) || policy.allowsCellular else {
            return false
        }
        guard !path.isExpensive || policy.allowsExpensive else {
            return false
        }
        guard !path.isConstrained || policy.allowsConstrained else {
            return false
        }
        return true
    }
#endif
}
