import XCTest
@testable import DownloadEngineKit

final class DirectHTTPDownloadIntegrityTests: XCTestCase {
    private var tempDirectory: URL!
    private var session: URLSession!
    private var probe: HTTPRangeProbe!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        DownloadCoordinator.credentialRefreshHandler = nil
        DownloadCoordinator.basicAuthChallengeHandler = nil

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        probe = HTTPRangeProbe(session: session)

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectHTTPDownloadIntegrityTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        DownloadCoordinator.credentialRefreshHandler = nil
        DownloadCoordinator.basicAuthChallengeHandler = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        session = nil
        probe = nil
        super.tearDown()
    }

    // MARK: - 1. Probe Cancellation and Bounded Draining

    func testProbeCancelsUnderlyingTaskAndDrainsBoundedByte() async throws {
        let testURL = URL(string: "https://example.com/probe_drain_test.bin")!
        let fullPayload = Data(repeating: 0x42, count: 10_000)

        MockURLProtocol.setHandler(for: testURL) { request in
            let range = request.value(forHTTPHeaderField: "Range")
            XCTAssertTrue(range == "bytes=0-0" || range == "bytes=0-", "Probe must use bounded range")
            let headers = [
                "Content-Range": "bytes 0-0/\(fullPayload.count)",
                "Content-Length": "1",
                "ETag": "\"etag-bounded\""
            ]
            let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, fullPayload.prefix(1))
        }

        let result = try await probe.probe(url: testURL)
        XCTAssertEqual(result.statusCode, 206)
        XCTAssertEqual(result.totalSize, Int64(fullPayload.count))
        XCTAssertTrue(probe.lastProbeTaskCancelled, "Probe must explicitly cancel task to prevent connection / bandwidth leaks")
    }

    // MARK: - 2. Network Policy Independence and Serialization

    func testNetworkPolicyIndependenceAndPresets() throws {
        // Presets
        let anyNet = DownloadNetworkPolicy.anyNetwork
        XCTAssertTrue(anyNet.allowsCellularAccess)
        XCTAssertTrue(anyNet.allowsExpensiveNetworkAccess)
        XCTAssertFalse(anyNet.allowsConstrainedNetworkAccess)

        let wifiOnly = DownloadNetworkPolicy.wifiOnly
        XCTAssertFalse(wifiOnly.allowsCellularAccess)
        XCTAssertFalse(wifiOnly.allowsExpensiveNetworkAccess)
        XCTAssertFalse(wifiOnly.allowsConstrainedNetworkAccess)

        let wifiAllowExpensive = DownloadNetworkPolicy.wifiAllowExpensive
        XCTAssertFalse(wifiAllowExpensive.allowsCellularAccess)
        XCTAssertTrue(wifiAllowExpensive.allowsExpensiveNetworkAccess)
        XCTAssertFalse(wifiAllowExpensive.allowsConstrainedNetworkAccess)

        let unrestricted = DownloadNetworkPolicy.unrestricted
        XCTAssertTrue(unrestricted.allowsCellularAccess)
        XCTAssertTrue(unrestricted.allowsExpensiveNetworkAccess)
        XCTAssertTrue(unrestricted.allowsConstrainedNetworkAccess)

        // Custom combinations
        let customMetered = DownloadNetworkPolicy(
            allowsCellularAccess: true,
            allowsExpensiveNetworkAccess: false,
            allowsConstrainedNetworkAccess: true
        )
        XCTAssertTrue(customMetered.allowsCellularAccess)
        XCTAssertFalse(customMetered.allowsExpensiveNetworkAccess)
        XCTAssertTrue(customMetered.allowsConstrainedNetworkAccess)

        // String backward compatibility decoding
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let anyData = try encoder.encode(DownloadNetworkPolicy.anyNetwork)
        let anyDecoded = try decoder.decode(DownloadNetworkPolicy.self, from: anyData)
        XCTAssertEqual(anyDecoded, DownloadNetworkPolicy.anyNetwork)

        let customData = try encoder.encode(customMetered)
        let customDecoded = try decoder.decode(DownloadNetworkPolicy.self, from: customData)
        XCTAssertEqual(customDecoded, customMetered)

        // Legacy string JSON decoding
        let legacyJSON = "\"wifiOnly\"".data(using: .utf8)!
        let legacyDecoded = try decoder.decode(DownloadNetworkPolicy.self, from: legacyJSON)
        XCTAssertEqual(legacyDecoded, DownloadNetworkPolicy.wifiOnly)
    }

    // MARK: - 3. Conservative Resume Default Rejection vs Compatibility Acceptance

    func testConservativeResumeRejectsValidatorlessResource() {
        let baseRecord = DownloadRecord(
            originalURL: URL(string: "https://example.com/no_validator.dat")!,
            destinationURL: tempDirectory.appendingPathComponent("no_validator.dat"),
            totalSize: 5000,
            eTag: nil,
            lastModified: nil
        )

        // Default policy is conservative
        let defaultResult = baseRecord.validateForResume(
            remoteETag: nil,
            remoteLastModified: nil,
            remoteTotalSize: 5000
        )
        XCTAssertEqual(defaultResult, .unsupportedNonResumable, "Conservative default must reject validator-less resume")

        // Explicit compatibility policy allows it
        let compatResult = baseRecord.validateForResume(
            remoteETag: nil,
            remoteLastModified: nil,
            remoteTotalSize: 5000,
            policy: .compatibility
        )
        XCTAssertEqual(compatResult, .valid, "Compatibility mode permits resume when length matches")
    }

    // MARK: - 4. Single-Stream Metadata Parity & Mutation Detection

    func testSingleStreamRejectsResourceMutationETag() async throws {
        let testURL = URL(string: "https://example.com/mutated_etag.bin")!
        let destURL = tempDirectory.appendingPathComponent("mutated_etag.bin")
        let totalSize: Int64 = 1000

        var requestCount = 0
        MockURLProtocol.setHandler(for: testURL) { req in
            requestCount += 1
            if requestCount == 1 {
                // Probe: return 200 with Accept-Ranges: none (forces single-stream)
                let headers = [
                    "Content-Length": "\(totalSize)",
                    "Accept-Ranges": "none",
                    "ETag": "\"original-etag\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data())
            } else {
                // Single-stream GET: remote ETag changed!
                let headers = [
                    "Content-Length": "\(totalSize)",
                    "ETag": "\"mutated-etag\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data(repeating: 0x99, count: Int(totalSize)))
            }
        }

        let store = try DownloadPersistenceStore(inMemory: true)
        let coordinator = try DownloadCoordinator(session: session, persistenceStore: store)
        let request = DownloadRequest(
            url: testURL,
            destinationURL: destURL,
            transportPolicy: .foreground
        )

        do {
            try await coordinator.start(request)
            XCTFail("Single-stream download must fail when remote resource mutates its ETag")
        } catch let DownloadCoordinatorError.unexpectedSingleStreamError(reason) {
            XCTAssertTrue(reason.contains("Resource mutated"), "Reason should indicate mutation: \(reason)")
        }
    }

    func testSingleStreamRejectsResourceMutationContentLength() async throws {
        let testURL = URL(string: "https://example.com/mutated_len.bin")!
        let destURL = tempDirectory.appendingPathComponent("mutated_len.bin")
        let probeSize: Int64 = 2000

        var requestCount = 0
        MockURLProtocol.setHandler(for: testURL) { req in
            requestCount += 1
            if requestCount == 1 {
                // Probe: length 2000, no ranges
                let headers = [
                    "Content-Length": "\(probeSize)",
                    "Accept-Ranges": "none"
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data())
            } else {
                // Single-stream GET: size changed to 3000!
                let headers = [
                    "Content-Length": "3000"
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data(repeating: 0x55, count: 3000))
            }
        }

        let store = try DownloadPersistenceStore(inMemory: true)
        let coordinator = try DownloadCoordinator(session: session, persistenceStore: store)
        let request = DownloadRequest(
            url: testURL,
            destinationURL: destURL,
            transportPolicy: .foreground
        )

        do {
            try await coordinator.start(request)
            XCTFail("Single-stream download must fail when remote Content-Length mutates")
        } catch let DownloadCoordinatorError.unexpectedSingleStreamError(reason) {
            XCTAssertTrue(reason.contains("Content-Length changed"), "Reason should indicate length change: \(reason)")
        }
    }

    // MARK: - 5. Automatic Mid-Transfer Credential Refresh

    func testSegmentDownloadAutomaticMidTransferCredentialRefresh() async throws {
        let testURL = URL(string: "https://example.com/authed_segmented.bin")!
        let destURL = tempDirectory.appendingPathComponent("authed_segmented.bin")
        let totalSize: Int64 = 600
        let payload = Data((0..<totalSize).map { UInt8($0 % 256) })

        let expiredToken = "Bearer old-expired-token"
        let freshToken = "Bearer fresh-valid-token"

        var tokenRefreshInvoked = false
        DownloadCoordinator.credentialRefreshHandler = { url in
            tokenRefreshInvoked = true
            return ["Authorization": freshToken]
        }

        var segmentHitCount = 0

        MockURLProtocol.setHandler(for: testURL) { req in
            let range = req.value(forHTTPHeaderField: "Range") ?? ""
            if range == "bytes=0-" || range == "bytes=0-0" {
                // Probe succeeds
                let headers = [
                    "Content-Range": "bytes 0-0/\(totalSize)",
                    "Content-Length": "1",
                    "ETag": "\"authed-v1\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data([payload[0]]))
            }

            segmentHitCount += 1
            let authHeader = req.value(forHTTPHeaderField: "Authorization")

            // Simulate token expiring on the first worker attempt
            if segmentHitCount == 1 && authHeader != freshToken {
                let resp = HTTPURLResponse(url: testURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data("Unauthorized".utf8))
            }

            // Once refreshed, accept segment download
            XCTAssertEqual(authHeader, freshToken, "Refreshed segment request must carry refreshed credentials")
            let parts = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
            guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else {
                fatalError("Invalid range: \(range)")
            }
            let slice = payload.subdata(in: start..<(end + 1))
            let headers = [
                "Content-Range": "bytes \(start)-\(end)/\(totalSize)",
                "Content-Length": "\(slice.count)",
                "ETag": "\"authed-v1\""
            ]
            let resp = HTTPURLResponse(url: testURL, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, slice)
        }

        let store = try DownloadPersistenceStore(inMemory: true)
        let coordinator = try DownloadCoordinator(session: session, persistenceStore: store)
        let request = DownloadRequest(
            url: testURL,
            destinationURL: destURL,
            headers: ["Authorization": expiredToken],
            configuredThreadCount: 1,
            retryCount: 2
        )

        try await coordinator.start(request)

        XCTAssertTrue(tokenRefreshInvoked, "Credential refresh handler must be invoked on 401")
        let downloadedData = try Data(contentsOf: destURL)
        XCTAssertEqual(downloadedData, payload, "Downloaded file data must match source after transparent auth refresh")
    }

    func testSingleStreamDownloadAutomaticMidTransferCredentialRefresh() async throws {
        let testURL = URL(string: "https://example.com/authed_single.bin")!
        let destURL = tempDirectory.appendingPathComponent("authed_single.bin")
        let totalSize: Int64 = 500
        let payload = Data(repeating: 0x7E, count: Int(totalSize))

        let freshCookie = "session_id=new-valid-session"
        var refreshCount = 0
        DownloadCoordinator.credentialRefreshHandler = { _ in
            refreshCount += 1
            return ["Cookie": freshCookie]
        }

        var streamRequests = 0
        MockURLProtocol.setHandler(for: testURL) { req in
            let range = req.value(forHTTPHeaderField: "Range")
            if range != nil {
                // Probe: return 200 without Range support
                let headers = [
                    "Content-Length": "\(totalSize)",
                    "Accept-Ranges": "none",
                    "ETag": "\"single-auth-etag\""
                ]
                let resp = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (resp, Data())
            }

            streamRequests += 1
            let cookie = req.value(forHTTPHeaderField: "Cookie")
            if streamRequests == 1 && cookie != freshCookie {
                // First GET returns 403 Forbidden
                let resp = HTTPURLResponse(url: testURL, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (resp, Data("Forbidden".utf8))
            }

            // Retry with refreshed cookie succeeds
            XCTAssertEqual(cookie, freshCookie)
            let headers = [
                "Content-Length": "\(totalSize)",
                "ETag": "\"single-auth-etag\""
            ]
            let resp = HTTPURLResponse(url: testURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (resp, payload)
        }

        let store = try DownloadPersistenceStore(inMemory: true)
        let coordinator = try DownloadCoordinator(session: session, persistenceStore: store)
        let request = DownloadRequest(
            url: testURL,
            destinationURL: destURL,
            headers: ["Cookie": "session_id=stale-session"],
            transportPolicy: .foreground
        )

        try await coordinator.start(request)

        XCTAssertEqual(refreshCount, 1, "Credential refresh handler should be invoked on 403")
        let downloadedData = try Data(contentsOf: destURL)
        XCTAssertEqual(downloadedData, payload, "Single-stream download must succeed after transparent auth refresh")
    }
}
