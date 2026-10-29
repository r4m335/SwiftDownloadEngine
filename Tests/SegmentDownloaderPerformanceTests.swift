import Foundation
import XCTest
@testable import DM_Reverse_engineering

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Repeatable local benchmark for the transport change in SegmentDownloader.
/// Run this on a simulator and a real iPhone; XCTest reports elapsed time and
/// CPU, while the test log reports the derived MB/s for each implementation.
final class SegmentDownloaderPerformanceTests: XCTestCase {
    private enum Mode {
        case byteIteration
        case dataChunks

        var label: String {
            switch self {
            case .byteIteration: return "before/byte-loop"
            case .dataChunks: return "after/data-chunks"
            }
        }
    }

    private let payloadSize = 8 * 1024 * 1024
    private var server: LocalHTTPRangeServer!
    private var payload: Data!

    override func setUpWithError() throws {
        try super.setUpWithError()
        payload = Data((0..<payloadSize).map { UInt8($0 % 251) })
        server = LocalHTTPRangeServer()
        server.register(path: "/benchmark.bin", data: payload, eTag: "\"benchmark-v1\"")
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        payload = nil
        try super.tearDownWithError()
    }

    func testBeforeByteIterationPerformance() throws {
        try requireOptInPerformanceRun()
        try measureBenchmark(mode: .byteIteration)
    }

    func testAfterDataChunkPerformance() throws {
        try requireOptInPerformanceRun()
        try measureBenchmark(mode: .dataChunks)
    }

    private func requireOptInPerformanceRun() throws {
        guard ProcessInfo.processInfo.environment["SDE_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Transport benchmarks are opt-in; set SDE_RUN_PERFORMANCE_TESTS=1 to run them.")
        }
    }

    private func measureBenchmark(mode: Mode) throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        #if canImport(Darwin)
        let metrics: [XCTMetric] = [XCTClockMetric(), XCTCPUMetric()]
        #else
        let metrics: [XCTMetric] = [XCTClockMetric()]
        #endif

        measure(metrics: metrics, options: options) {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<BenchmarkResult, Error>!

            Task {
                do {
                    result = .success(try await self.runBenchmark(mode: mode))
                } catch {
                    result = .failure(error)
                }
                semaphore.signal()
            }

            semaphore.wait()
            switch result {
            case .success(let benchmark):
                print(
                    "SegmentDownloader \(mode.label): " +
                    String(format: "%.2f MB/s (%.3f s, %lld bytes)", benchmark.megabytesPerSecond, benchmark.elapsed, benchmark.bytesWritten)
                )
            case .failure(let error):
                XCTFail("Benchmark failed: \(error)")
            case .none:
                XCTFail("Benchmark did not produce a result")
            }
        }
    }

    private struct BenchmarkResult {
        let elapsed: TimeInterval
        let bytesWritten: Int64

        var megabytesPerSecond: Double {
            guard elapsed > 0 else { return 0 }
            return Double(bytesWritten) / elapsed / 1_048_576.0
        }
    }

    private func runBenchmark(mode: Mode) async throws -> BenchmarkResult {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("segment-benchmark-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let writer = try DownloadFileWriter(destinationURL: fileURL, totalSize: Int64(payloadSize))

        let url = server.url(for: "/benchmark.bin")
        let segment = DownloadSegment(
            id: 0,
            startOffset: 0,
            endOffset: Int64(payloadSize - 1),
            length: Int64(payloadSize)
        )
        let session = ForegroundURLSession.make(maximumConnectionsPerHost: 1)
        defer { session.invalidateAndCancel() }
        let started = Date()

        switch mode {
        case .dataChunks:
            let downloader = SegmentDownloader(session: session, writer: writer)
            try await downloader.download(
                url: url,
                segment: segment,
                expectedTotalSize: Int64(payloadSize),
                eTag: "\"benchmark-v1\""
            )

        case .byteIteration:
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("bytes=0-\(payloadSize - 1)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("\"benchmark-v1\"", forHTTPHeaderField: "If-Range")

            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 206 else {
                throw URLError(.badServerResponse)
            }

            var offset: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try await writer.writeDirect(buffer, at: offset)
                    offset += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try await writer.writeDirect(buffer, at: offset)
                offset += Int64(buffer.count)
            }
        }

        try await writer.synchronize()
        let elapsed = max(Date().timeIntervalSince(started), 0.000_001)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let bytesWritten = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(bytesWritten, Int64(payloadSize))
        try await writer.close()
        return BenchmarkResult(elapsed: elapsed, bytesWritten: bytesWritten)
    }
}
