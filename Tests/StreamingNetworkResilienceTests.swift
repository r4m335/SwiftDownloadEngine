import XCTest
@testable import DM_Reverse_engineering

final class StreamingNetworkResilienceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    func testTransientNetworkErrorCodesAreRecognizedAsRetryable() {
        let codes: [(URLError.Code, String)] = [
            (.networkConnectionLost, "network connection lost (-1005)"),
            (.timedOut, "timed out (-1001)"),
            (.cannotConnectToHost, "cannot connect to host (-1004)"),
            (.notConnectedToInternet, "not connected to internet (-1009)"),
            (.dnsLookupFailed, "dns lookup failed (-1006)"),
            (.cannotFindHost, "cannot find host (-1003)"),
            (.cannotLoadFromNetwork, "cannot load from network (-2000)"),
            (.secureConnectionFailed, "secure connection failed (-1200)")
        ]

        for (code, name) in codes {
            let error = NSError(
                domain: NSURLErrorDomain,
                code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Simulated \(name)"]
            )
            XCTAssertTrue(
                HTTPRetryPolicy.isRetryable(error),
                "Expected \(name) to be recognized as retryable"
            )
        }
    }

    func testFatalErrorsAreNotRetryable() {
        let dummyURL = URL(string: "https://example.com/segment.ts")!
        let fatalErrors: [Error] = [
            CancellationError(),
            DownloadCoordinatorError.tokenExpired(url: dummyURL),
            DownloadCoordinatorError.accessDenied(url: dummyURL, cooldownUntil: Date()),
            DownloadCoordinatorError.linkExpired(url: dummyURL),
            DownloadCoordinatorError.invalidRequest(reason: "bad request"),
            HTTPRangeProbeError.resourceNotFound(dummyURL),
            HTTPRangeProbeError.unauthorized(dummyURL),
            HTTPRangeProbeError.forbidden(dummyURL),
            NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
        ]

        for err in fatalErrors {
            XCTAssertFalse(
                HTTPRetryPolicy.isRetryable(err),
                "Expected \(err) to NOT be retryable"
            )
        }
    }

    func testOrchestratorFailsWhenTransientRetriesExhausted() async throws {
        let manifestURL = URL(string: "https://video.example/exhausted.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        segment1.ts
        #EXT-X-ENDLIST
        """
        let loader = RecordingManifestLoader(
            data: Data(playlist.utf8),
            finalURL: manifestURL,
            mimeType: "application/vnd.apple.mpegurl"
        )
        // Inject 10 failures (exceeds max attempts of 3/4)
        let persistentNetworkError = NSError(
            domain: NSURLErrorDomain,
            code: -1005,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )
        let executor = MockTransientFaultExecutor(failureCount: 10, errorToThrow: persistentNetworkError)
        let orchestrator = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)

        let candidate = try StreamingManifestCandidate(url: manifestURL)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        let destination = tempDirectory.appendingPathComponent("output")

        do {
            _ = try await orchestrator.execute(proposal, approved: true, destinationDirectory: destination)
            XCTFail("Expected orchestrator.execute to fail when retries are exhausted")
        } catch {
            guard case StreamingDownloadOrchestratorError.segmentTransferFailed(let order) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(order, 0)
        }

        let calls = await executor.executeCalls
        XCTAssertGreaterThanOrEqual(calls, 2, "Expected at least 2 attempts before failing")
    }

    func testMultipleTransientFailuresRecoverCleanly() async throws {
        let manifestURL = URL(string: "https://video.example/multi-recover.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:2,
        seg0.ts
        #EXTINF:2,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let loader = RecordingManifestLoader(
            data: Data(playlist.utf8),
            finalURL: manifestURL,
            mimeType: "application/vnd.apple.mpegurl"
        )
        // Segment 0 fails once with -1005 then succeeds; Segment 1 succeeds on first try
        let executor = MockPerSegmentFaultExecutor(faultsByOrder: [
            0: NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."])
        ])
        let orchestrator = StreamingDownloadOrchestrator(manifestLoader: loader, segmentExecutor: executor)

        let candidate = try StreamingManifestCandidate(url: manifestURL)
        let proposal = try await orchestrator.prepare(candidate: candidate)
        let destination = tempDirectory.appendingPathComponent("multi_output")

        let result = try await orchestrator.execute(proposal, approved: true, destinationDirectory: destination)
        XCTAssertEqual(result.completedSegments.count, 2)

        let attemptsForSeg0 = await executor.callsForSegment(order: 0)
        let attemptsForSeg1 = await executor.callsForSegment(order: 1)
        XCTAssertEqual(attemptsForSeg0, 2, "Segment 0 should have been attempted twice (1 retry)")
        XCTAssertEqual(attemptsForSeg1, 1, "Segment 1 should have succeeded on first attempt")
    }
}

// MARK: - Mock Manifest Loader and Segment Executors

private actor RecordingManifestLoader: StreamingManifestLoader {
    private let data: Data
    private let finalURL: URL
    private let mimeType: String?
    private(set) var loadCount = 0

    init(data: Data, finalURL: URL, mimeType: String? = "application/vnd.apple.mpegurl") {
        self.data = data
        self.finalURL = finalURL
        self.mimeType = mimeType
    }

    func load(
        candidate: StreamingManifestCandidate,
        headers: [String: String],
        limits: ManifestParsingLimits
    ) async throws -> StreamingManifestResponse {
        loadCount += 1
        return StreamingManifestResponse(data: data, finalURL: finalURL, mimeType: mimeType)
    }
}

private actor MockTransientFaultExecutor: StreamingSegmentExecutor {
    private var failureCount: Int
    private let errorToThrow: Error
    private(set) var executeCalls = 0

    init(failureCount: Int, errorToThrow: Error) {
        self.failureCount = failureCount
        self.errorToThrow = errorToThrow
    }

    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        executeCalls += 1
        if failureCount > 0 {
            failureCount -= 1
            throw errorToThrow
        }
        let payload = Data(repeating: 0x47, count: 188)
        try? FileManager.default.createDirectory(at: request.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: request.destinationURL)
        progress?(1.0)
    }

    func cancel(transferID: String) async {}
}

private actor MockPerSegmentFaultExecutor: StreamingSegmentExecutor {
    private var faultsRemaining: [Int: Error]
    private var callsPerOrder: [Int: Int] = [:]

    init(faultsByOrder: [Int: Error]) {
        self.faultsRemaining = faultsByOrder
    }

    func execute(
        _ request: StreamingSegmentTransferRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let order = request.identity.order
        callsPerOrder[order, default: 0] += 1

        if let error = faultsRemaining.removeValue(forKey: order) {
            throw error
        }

        let payload = Data(repeating: 0x47, count: 188)
        try? FileManager.default.createDirectory(at: request.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: request.destinationURL)
        progress?(1.0)
    }

    func callsForSegment(order: Int) -> Int {
        callsPerOrder[order, default: 0]
    }

    func cancel(transferID: String) async {}
}
