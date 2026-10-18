#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif

import Foundation

#if !canImport(Darwin)
/// Linux compatibility shim providing `AsyncBytes` for `FoundationNetworking.URLSession`
public struct AsyncBytes: AsyncSequence, Sendable {
    public typealias Element = UInt8

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let data: Data
        private var index: Data.Index

        init(data: Data) {
            self.data = data
            self.index = data.startIndex
        }

        public mutating func next() async throws -> UInt8? {
            guard index < data.endIndex else { return nil }
            let byte = data[index]
            index = data.index(after: index)
            return byte
        }
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(data: data)
    }
}

public extension URLSession {
    typealias AsyncBytes = DM_Reverse_engineering.AsyncBytes

    func bytes(
        for request: URLRequest,
        delegate: URLSessionTaskDelegate? = nil
    ) async throws -> (AsyncBytes, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let response = response else {
                    continuation.resume(throwing: URLError(.unknown))
                    return
                }
                continuation.resume(returning: (AsyncBytes(data: data ?? Data()), response))
            }
            task.resume()
        }
    }
}
#endif
