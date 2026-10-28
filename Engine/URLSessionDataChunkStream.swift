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

    deinit {
        delegateSession?.invalidateAndCancel()
    }

    func start() async throws -> HTTPURLResponse {
        guard let delegateSession else {
            throw URLError(.cancelled)
        }
        let dataTask = delegateSession.dataTask(with: request)
        lock.lock()
        task = dataTask
        lock.unlock()
        dataTask.resume()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                var result: Result<HTTPURLResponse, Error>?
                lock.lock()
                if let response {
                    result = .success(response)
                } else if let responseError {
                    result = .failure(responseError)
                } else {
                    responseContinuation = continuation
                }
                lock.unlock()

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
                var result: Result<Data?, Error>?
                var taskToResume: URLSessionDataTask?

                lock.lock()
                if !bufferedChunks.isEmpty {
                    let chunk = bufferedChunks.removeFirst()
                    bufferedBytes -= chunk.count
                    if suspendedForBackpressure && bufferedBytes <= Self.lowWaterMark {
                        suspendedForBackpressure = false
                        taskToResume = task
                    }
                    result = .success(chunk)
                } else if let terminalError {
                    result = .failure(terminalError)
                } else if finished {
                    result = .success(nil)
                } else {
                    nextContinuation = continuation
                }
                lock.unlock()

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

        lock.lock()
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
        let dataTask = task
        lock.unlock()

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
        lock.lock()
        if finished {
            shouldCancel = true
        } else {
            self.response = httpResponse
            responseToResume = responseContinuation
            responseContinuation = nil
        }
        lock.unlock()

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
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }

        if let nextContinuation {
            continuation = nextContinuation
            self.nextContinuation = nil
        } else {
            bufferedChunks.append(data)
            bufferedBytes += data.count
            if bufferedBytes >= Self.highWaterMark && !suspendedForBackpressure {
                suspendedForBackpressure = true
                taskToSuspend = task
            }
        }
        lock.unlock()

        taskToSuspend?.suspend()
        continuation?.resume(returning: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var responseToFail: CheckedContinuation<HTTPURLResponse, Error>?
        var nextToResume: CheckedContinuation<Data?, Error>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }

        finished = true
        if response == nil {
            let responseFailure = error ?? URLError(.badServerResponse)
            responseError = responseFailure
            responseToFail = responseContinuation
            responseContinuation = nil
        }
        if let error {
            terminalError = error
            nextToResume = nextContinuation
            nextContinuation = nil
        } else {
            nextToResume = nextContinuation
            nextContinuation = nil
        }
        lock.unlock()

        responseToFail?.resume(throwing: error ?? URLError(.badServerResponse))
        if let error {
            nextToResume?.resume(throwing: error)
        } else {
            nextToResume?.resume(returning: nil)
        }
    }

    private func fail(_ error: Error) {
        var responseToFail: CheckedContinuation<HTTPURLResponse, Error>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        responseError = error
        terminalError = error
        responseToFail = responseContinuation
        responseContinuation = nil
        lock.unlock()
        responseToFail?.resume(throwing: error)
    }
}
