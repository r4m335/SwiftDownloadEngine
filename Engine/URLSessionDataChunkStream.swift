import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bridges URLSession's delegate callbacks to an async sequence of Data
/// chunks. The URLSession task is suspended while the bounded queue is full,
/// providing backpressure without creating a per-byte async suspension.
final class URLSessionDataChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let highWaterMark = 1 * 1024 * 1024
    private static let lowWaterMark = 256 * 1024

    private let request: URLRequest
    private let lock = NSLock()

    private var delegateSession: URLSession?
    private var task: URLSessionDataTask?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var response: HTTPURLResponse?
    private var responseError: Error?

    private var bufferedChunks: [Data] = []
    private var bufferedBytes = 0
    private var nextContinuation: CheckedContinuation<Data?, Error>?
    private var terminalError: Error?
    private var finished = false
    private var suspendedForBackpressure = false

    init(session: URLSession, request: URLRequest) {
        self.request = request
        self.delegateSession = nil
        super.init()
        self.delegateSession = URLSession(
            configuration: session.configuration,
            delegate: self,
            delegateQueue: nil
        )
    }

    deinit {}

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func start() async throws -> HTTPURLResponse {
        guard let delegateSession else {
            throw URLError(.cancelled)
        }
        let dataTask = delegateSession.dataTask(with: request)
        withLock { task = dataTask }
        dataTask.resume()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let result: Result<HTTPURLResponse, Error>? = self.withLock {
                    if let response = self.response {
                        return .success(response)
                    } else if let responseError = self.responseError {
                        return .failure(responseError)
                    } else {
                        self.responseContinuation = continuation
                        return nil
                    }
                }

                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                var taskToResume: URLSessionDataTask?
                let result: Result<Data?, Error>? = self.withLock {
                    if !self.bufferedChunks.isEmpty {
                        let chunk = self.bufferedChunks.removeFirst()
                        self.bufferedBytes -= chunk.count
                        if self.suspendedForBackpressure && self.bufferedBytes <= Self.lowWaterMark {
                            self.suspendedForBackpressure = false
                            taskToResume = self.task
                        }
                        return .success(chunk)
                    } else if let terminalError = self.terminalError {
                        return .failure(terminalError)
                    } else if self.finished {
                        return .success(nil)
                    } else {
                        self.nextContinuation = continuation
                        return nil
                    }
                }

                taskToResume?.resume()
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        var responseToFail: CheckedContinuation<HTTPURLResponse, Error>?
        var nextToFail: CheckedContinuation<Data?, Error>?
        let cancellation = URLError(.cancelled)
        var shouldCancelTask = false
        var dataTask: URLSessionDataTask?

        withLock {
            if !finished {
                shouldCancelTask = true
                finished = true
                bufferedChunks.removeAll(keepingCapacity: false)
                bufferedBytes = 0
                responseError = cancellation
                terminalError = cancellation
                responseToFail = responseContinuation
                nextToFail = nextContinuation
                responseContinuation = nil
                nextContinuation = nil
            }
            dataTask = task
        }

        if shouldCancelTask {
            dataTask?.cancel()
        }
        delegateSession?.invalidateAndCancel()
        responseToFail?.resume(throwing: cancellation)
        nextToFail?.resume(throwing: cancellation)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            fail(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }

        var responseToResume: CheckedContinuation<HTTPURLResponse, Error>?
        var shouldCancel = false
        withLock {
            if finished {
                shouldCancel = true
            } else {
                self.response = httpResponse
                responseToResume = responseContinuation
                responseContinuation = nil
            }
        }

        if shouldCancel {
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
            responseToResume?.resume(returning: httpResponse)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }

        var continuation: CheckedContinuation<Data?, Error>?
        var taskToSuspend: URLSessionDataTask?
        let shouldProcess: Bool = withLock {
            guard !finished else { return false }
            if let next = nextContinuation {
                continuation = next
                self.nextContinuation = nil
            } else {
                bufferedChunks.append(data)
                bufferedBytes += data.count
                if bufferedBytes >= Self.highWaterMark && !suspendedForBackpressure {
                    suspendedForBackpressure = true
                    taskToSuspend = task
                }
            }
            return true
        }

        guard shouldProcess else { return }
        taskToSuspend?.suspend()
        continuation?.resume(returning: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var responseToFail: CheckedContinuation<HTTPURLResponse, Error>?
        var nextToResume: CheckedContinuation<Data?, Error>?
        let shouldProcess: Bool = withLock {
            guard !finished else { return false }
            finished = true
            if response == nil {
                let responseFailure = error ?? URLError(.badServerResponse)
                responseError = responseFailure
                responseToFail = responseContinuation
                responseContinuation = nil
            }
            terminalError = error
            nextToResume = nextContinuation
            nextContinuation = nil
            return true
        }

        guard shouldProcess else { return }
        session.invalidateAndCancel()
        responseToFail?.resume(throwing: error ?? URLError(.badServerResponse))
        if let error {
            nextToResume?.resume(throwing: error)
        } else {
            nextToResume?.resume(returning: nil)
        }
    }

    private func fail(_ error: Error) {
        var responseToFail: CheckedContinuation<HTTPURLResponse, Error>?
        var nextToResume: CheckedContinuation<Data?, Error>?
        var taskToCancel: URLSessionDataTask?
        let shouldProcess: Bool = withLock {
            guard !finished else { return false }
            finished = true
            responseError = error
            terminalError = error
            responseToFail = responseContinuation
            responseContinuation = nil
            nextToResume = nextContinuation
            nextContinuation = nil
            taskToCancel = task
            return true
        }

        guard shouldProcess else { return }
        taskToCancel?.cancel()
        delegateSession?.invalidateAndCancel()
        responseToFail?.resume(throwing: error)
        nextToResume?.resume(throwing: error)
    }
}
