import Foundation

#if canImport(Network)
import Network
#endif

/// Waits for a usable network path before a foreground request is attempted
/// again. URLSession still owns the active transfer and waitsForConnectivity;
/// this gate prevents retry loops from spending attempts while offline.
actor NetworkConnectivityGate {
    static let shared = NetworkConnectivityGate()

#if canImport(Network)
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "SwiftDownloadEngine.network-path")
    private var latestPath: NWPath?
    private var waiters: [UUID: (allowsCellular: Bool, continuation: CheckedContinuation<Void, Error>)] = [:]

    init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            Task {
                await NetworkConnectivityGate.shared.pathDidChange(path)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
    }
#else
    init() {}
#endif

    func waitUntilAvailable(allowsCellular: Bool) async throws {
#if canImport(Network)
        try Task.checkCancellation()

        if let latestPath, Self.isUsable(latestPath, allowsCellular: allowsCellular) {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let latestPath, Self.isUsable(latestPath, allowsCellular: allowsCellular) {
                    continuation.resume()
                } else {
                    waiters[waiterID] = (allowsCellular: allowsCellular, continuation: continuation)
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
#else
        _ = allowsCellular
        try Task.checkCancellation()
#endif
    }

#if canImport(Network)
    private func pathDidChange(_ path: NWPath) {
        latestPath = path
        guard path.status == .satisfied else { return }

        let readyIDs = waiters.compactMap { id, waiter in
            Self.isUsable(path, allowsCellular: waiter.allowsCellular) ? id : nil
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

    private static func isUsable(_ path: NWPath, allowsCellular: Bool) -> Bool {
        guard path.status == .satisfied else { return false }
        guard !path.usesInterfaceType(.cellular) || allowsCellular else {
            return false
        }
        return true
    }
#endif
}
