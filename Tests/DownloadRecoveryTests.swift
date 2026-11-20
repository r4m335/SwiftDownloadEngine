import XCTest
import Foundation
@testable import DownloadEngineKit

final class DownloadRecoveryTests: XCTestCase {
    private var session: URLSession!
    private var tempDirectory: URL!
    private var persistenceStore: DownloadPersistenceStore!
    private var coordinator: DownloadCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LID_Recovery_Tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let storeDir = tempDirectory.appendingPathComponent("Store", isDirectory: true)
        persistenceStore = try DownloadPersistenceStore(storageDirectoryURL: storeDir)
        coordinator = try DownloadCoordinator(session: session, persistenceStore: persistenceStore)
    }

    override func tearDown() async throws {
        session?.invalidateAndCancel()
        MockURLProtocol.reset()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        session = nil
        coordinator = nil
        persistenceStore = nil
        try await super.tearDown()
    }

    // MARK: - 1. DownloadIdentityVerifier Tests

    func testIdentityVerifierCompatibleMatch() {
        let verifier = DownloadIdentityVerifier()
        let destination = tempDirectory.appendingPathComponent("sample.mp4")

        let record = DownloadRecord(
            id: "id_compat",
            originalURL: URL(string: "https://example.com/video.mp4?token=old123")!,
            resolvedURL: URL(string: "https://example.com/video.mp4?token=old123")!,
            destinationURL: destination,
            totalSize: 5_000_000,
            state: .failed(reason: "HTTP 403"),
            storageMode: .directSeek,
            eTag: "\"etag-v1\"",
            lastModified: "Mon, 16 Nov 2026 12:00:00 GMT",
            headers: [:],
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 2_499_999, length: 2_500_000, completedBytes: 2_500_000),
                SegmentRecord(id: 1, startOffset: 2_500_000, endOffset: 4_999_999, length: 2_500_000, completedBytes: 0)
            ]
        )

        let probe = DownloadIdentityVerifier.ProbeMetadata(
            finalURL: URL(string: "https://example.com/video.mp4?token=new456")!,
            totalSize: 5_000_000,
            eTag: "W/\"etag-v1\"",
            lastModified: "Mon, 16 Nov 2026 12:00:00 GMT",
            supportsRange: true,
            mimeType: "video/mp4",
            statusCode: 200,
            isRedirected: false,
            canResume: true
        )

        let outcome = verifier.verify(record: record, probe: probe)
        XCTAssertTrue(outcome.isCompatible)
        if case .compatible(let reasons) = outcome {
            XCTAssertTrue(reasons.contains { $0.contains("Exact file size match") })
            XCTAssertTrue(reasons.contains { $0.contains("ETag validator match") })
        } else {
            XCTFail("Expected compatible outcome")
        }
    }

    func testIdentityVerifierSizeMismatchIncompatible() {
        let verifier = DownloadIdentityVerifier()
        let destination = tempDirectory.appendingPathComponent("sample.mp4")

        let record = DownloadRecord(
            id: "id_size_mismatch",
            originalURL: URL(string: "https://example.com/video.mp4")!,
            resolvedURL: URL(string: "https://example.com/video.mp4")!,
            destinationURL: destination,
            totalSize: 5_000_000,
            state: .failed(reason: "interrupted"),
            storageMode: .directSeek,
            headers: [:],
            segments: []
        )

        let probe = DownloadIdentityVerifier.ProbeMetadata(
            finalURL: URL(string: "https://example.com/video_different.mp4")!,
            totalSize: 7_500_000,
            eTag: nil,
            lastModified: nil,
            supportsRange: true,
            mimeType: "video/mp4",
            statusCode: 200,
            isRedirected: false,
            canResume: true
        )

        let outcome = verifier.verify(record: record, probe: probe)
        XCTAssertTrue(outcome.isIncompatible)
        if case .incompatible(let reason) = outcome {
            XCTAssertTrue(reason.contains("File size mismatch"))
        } else {
            XCTFail("Expected incompatible outcome")
        }
    }

    func testIdentityVerifierETagMismatchIncompatible() {
        let verifier = DownloadIdentityVerifier()
        let destination = tempDirectory.appendingPathComponent("sample.mp4")

        let record = DownloadRecord(
            id: "id_etag_mismatch",
            originalURL: URL(string: "https://example.com/video.mp4")!,
            resolvedURL: URL(string: "https://example.com/video.mp4")!,
            destinationURL: destination,
            totalSize: 5_000_000,
            state: .failed(reason: "interrupted"),
            storageMode: .directSeek,
            eTag: "\"version-1\"",
            headers: [:],
            segments: []
        )

        let probe = DownloadIdentityVerifier.ProbeMetadata(
            finalURL: URL(string: "https://example.com/video.mp4")!,
            totalSize: 5_000_000,
            eTag: "\"version-2\"",
            lastModified: nil,
            supportsRange: true,
            mimeType: "video/mp4",
            statusCode: 200,
            isRedirected: false,
            canResume: true
        )

        let outcome = verifier.verify(record: record, probe: probe)
        XCTAssertTrue(outcome.isIncompatible)
        if case .incompatible(let reason) = outcome {
            XCTAssertTrue(reason.contains("ETag mismatch"))
        } else {
            XCTFail("Expected incompatible outcome")
        }
    }

    func testIdentityVerifierNoRangesRequiresRestart() {
        let verifier = DownloadIdentityVerifier()
        let destination = tempDirectory.appendingPathComponent("sample.mp4")

        let record = DownloadRecord(
            id: "id_no_ranges",
            originalURL: URL(string: "https://example.com/video.mp4")!,
            resolvedURL: URL(string: "https://example.com/video.mp4")!,
            destinationURL: destination,
            totalSize: 5_000_000,
            state: .failed(reason: "timeout"),
            storageMode: .directSeek,
            headers: [:],
            segments: [
                SegmentRecord(id: 0, startOffset: 0, endOffset: 2_499_999, length: 2_500_000, completedBytes: 1_000_000)
            ]
        )

        let probe = DownloadIdentityVerifier.ProbeMetadata(
            finalURL: URL(string: "https://example.com/video.mp4")!,
            totalSize: 5_000_000,
            eTag: nil,
            lastModified: nil,
            supportsRange: false,
            mimeType: "video/mp4",
            statusCode: 200,
            isRedirected: false,
            canResume: false
        )

        let outcome = verifier.verify(record: record, probe: probe)
        XCTAssertTrue(outcome.isRequiresRestart)
        if case .requiresRestart(let reason) = outcome {
            XCTAssertTrue(reason.contains("does not support HTTP Range"))
        } else {
            XCTFail("Expected requiresRestart outcome")
        }
    }

    // MARK: - 2. BrowserDownloadMatcher Tests

    func testBrowserDownloadMatcherExactURL() {
        let matcher = BrowserDownloadMatcher()
        let url = URL(string: "https://cdn.example.com/movies/video.mp4")!
        let resource = WebpageResource(
            id: "res_exact",
            url: url,
            title: "Sample Video",
            suggestedFilename: "video.mp4",
            resourceType: .video,
            mimeType: "video/mp4"
        )

        let transfer = UnifiedTransfer(
            id: "t_exact",
            name: "video.mp4",
            type: .http,
            state: .failed(reason: "HTTP 403"),
            completedBytes: 10_000,
            totalBytes: 50_000,
            progressFraction: 0.2,
            downloadSpeedBytesPerSecond: 0,
            uploadSpeedBytesPerSecond: 0,
            destinationURL: tempDirectory.appendingPathComponent("video.mp4"),
            source: url.absoluteString,
            createdAt: Date(),
            failureReason: "HTTP 403"
        )

        let match = matcher.match(resource: resource, transfers: [transfer])
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.transferID, "t_exact")
        XCTAssertEqual(match?.statusDot, .failed)
        XCTAssertEqual(match?.confidence, .exactURL)
    }

    func testBrowserDownloadMatcherNormalizedSignedURL() {
        let matcher = BrowserDownloadMatcher()
        let oldURL = URL(string: "https://cdn.example.com/video.mp4?token=exp111&sig=abc")!
        let newURL = URL(string: "https://cdn.example.com/video.mp4?token=exp222&sig=def")!

        let resource = WebpageResource(
            id: "res_signed",
            url: newURL,
            title: "Video",
            suggestedFilename: "video.mp4",
            resourceType: .video,
            mimeType: "video/mp4"
        )

        let transfer = UnifiedTransfer(
            id: "t_signed",
            name: "video.mp4",
            type: .http,
            state: .downloading,
            completedBytes: 25_000,
            totalBytes: 50_000,
            progressFraction: 0.5,
            downloadSpeedBytesPerSecond: 1024,
            uploadSpeedBytesPerSecond: 0,
            destinationURL: tempDirectory.appendingPathComponent("video.mp4"),
            source: oldURL.absoluteString,
            createdAt: Date(),
            failureReason: nil
        )

        let match = matcher.match(resource: resource, transfers: [transfer])
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.transferID, "t_signed")
        XCTAssertEqual(match?.statusDot, .downloading)
        XCTAssertEqual(match?.confidence, .normalizedURL)
    }

    func testBrowserDownloadMatcherHLSRenditionSafety() {
        let matcher = BrowserDownloadMatcher()

        // Existing transfer is 480p
        let transfer480p = UnifiedTransfer(
            id: "t_480p",
            name: "stream-480p.mp4",
            type: .hls,
            state: .failed(reason: "HTTP 403"),
            completedBytes: 100,
            totalBytes: 200,
            progressFraction: 0.5,
            downloadSpeedBytesPerSecond: 0,
            uploadSpeedBytesPerSecond: 0,
            destinationURL: tempDirectory.appendingPathComponent("stream-480p.mp4"),
            source: "https://stream.example.com/master.m3u8?token=old",
            createdAt: Date(),
            failureReason: "HTTP 403"
        )

        // Captured resource 1: 1080p variant
        let resource1080p = WebpageResource(
            id: "res_1080p",
            url: URL(string: "https://stream.example.com/variant_1080p.m3u8?token=new")!,
            title: "stream 1080p",
            suggestedFilename: "stream-1080p.mp4",
            resourceType: .video,
            mimeType: "application/x-mpegurl",
            hlsVariantPreferences: HLSVariantSelectionPreferences(maximumHeight: 1080)
        )

        // Captured resource 2: 480p variant
        let resource480p = WebpageResource(
            id: "res_480p",
            url: URL(string: "https://stream.example.com/variant_480p.m3u8?token=new")!,
            title: "stream 480p",
            suggestedFilename: "stream-480p.mp4",
            resourceType: .video,
            mimeType: "application/x-mpegurl",
            hlsVariantPreferences: HLSVariantSelectionPreferences(maximumHeight: 480)
        )

        // 1080p should NOT match 480p transfer!
        let match1080 = matcher.match(resource: resource1080p, transfers: [transfer480p])
        XCTAssertNil(match1080, "1080p must not match existing 480p transfer")

        // 480p MUST match 480p transfer!
        let match480 = matcher.match(resource: resource480p, transfers: [transfer480p])
        XCTAssertNotNil(match480)
        XCTAssertEqual(match480?.transferID, "t_480p")
        XCTAssertEqual(match480?.statusDot, .failed)
    }

    func testBrowserDownloadMatcherStatusDotVariations() {
        let matcher = BrowserDownloadMatcher()

        func makeTransfer(id: String, state: UnifiedTransferState) -> UnifiedTransfer {
            UnifiedTransfer(
                id: id,
                name: "\(id).mp4",
                type: .http,
                state: state,
                completedBytes: 10,
                totalBytes: 20,
                progressFraction: 0.5,
                downloadSpeedBytesPerSecond: 0,
                uploadSpeedBytesPerSecond: 0,
                destinationURL: tempDirectory.appendingPathComponent("\(id).mp4"),
                source: "https://cdn.example.com/\(id).mp4",
                createdAt: Date(),
                failureReason: nil
            )
        }

        let downloading = makeTransfer(id: "down", state: .downloading)
        let paused = makeTransfer(id: "pause", state: .paused)
        let completed = makeTransfer(id: "comp", state: .completed)
        let failed = makeTransfer(id: "fail", state: .failed(reason: "err"))

        let allTransfers = [downloading, paused, completed, failed]

        let resDown = WebpageResource(id: "1", url: URL(string: "https://cdn.example.com/down.mp4")!, title: "", suggestedFilename: "down.mp4", resourceType: .video)
        let resPause = WebpageResource(id: "2", url: URL(string: "https://cdn.example.com/pause.mp4")!, title: "", suggestedFilename: "pause.mp4", resourceType: .video)
        let resComp = WebpageResource(id: "3", url: URL(string: "https://cdn.example.com/comp.mp4")!, title: "", suggestedFilename: "comp.mp4", resourceType: .video)
        let resFail = WebpageResource(id: "4", url: URL(string: "https://cdn.example.com/fail.mp4")!, title: "", suggestedFilename: "fail.mp4", resourceType: .video)
        let resNew = WebpageResource(id: "5", url: URL(string: "https://cdn.example.com/unrelated.mp4")!, title: "", suggestedFilename: "unrelated.mp4", resourceType: .video)

        XCTAssertEqual(matcher.match(resource: resDown, transfers: allTransfers)?.statusDot, .downloading)
        XCTAssertEqual(matcher.match(resource: resPause, transfers: allTransfers)?.statusDot, .paused)
        XCTAssertEqual(matcher.match(resource: resComp, transfers: allTransfers)?.statusDot, .completed)
        XCTAssertEqual(matcher.match(resource: resFail, transfers: allTransfers)?.statusDot, .failed)
        XCTAssertNil(matcher.match(resource: resNew, transfers: allTransfers))
    }

    // MARK: - 3. DownloadLinkRefresher Tests

    func testDownloadLinkRefresherSuccessPreservesSegments() async throws {
        let destination = tempDirectory.appendingPathComponent("refresh_target.mp4")
        let oldURL = URL(string: "https://media.example.com/video.mp4?sig=expired")!
        let newURL = URL(string: "https://media.example.com/video.mp4?sig=fresh")!

        let seg0 = SegmentRecord(id: 0, startOffset: 0, endOffset: 499, length: 500, completedBytes: 500)
        let seg1 = SegmentRecord(id: 1, startOffset: 500, endOffset: 999, length: 500, completedBytes: 0)

        let initialRecord = DownloadRecord(
            id: "target_id",
            originalURL: oldURL,
            resolvedURL: oldURL,
            destinationURL: destination,
            totalSize: 1000,
            state: .failed(reason: "HTTP 403"),
            storageMode: .directSeek,
            eTag: "\"v1\"",
            headers: ["Referer": "https://media.example.com/player"],
            segments: [seg0, seg1]
        )
        try await persistenceStore.save(initialRecord)

        // Mock probe response for fresh URL
        MockURLProtocol.setHandler(for: newURL) { req in
            let resp = HTTPURLResponse(
                url: newURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "1000",
                    "Accept-Ranges": "bytes",
                    "ETag": "\"v1\"",
                    "Content-Type": "video/mp4"
                ]
            )!
            return (resp, Data(repeating: 0x41, count: 1000))
        }

        let refresher = DownloadLinkRefresher(session: session, persistenceStore: persistenceStore)
        let (updated, outcome) = try await refresher.refresh(
            id: "target_id",
            newURL: newURL,
            newHeaders: ["Referer": "https://media.example.com/player", "Cookie": "sid=123"]
        )

        XCTAssertTrue(outcome.isCompatible)
        XCTAssertEqual(updated.originalURL, newURL)
        XCTAssertEqual(updated.resolvedURL, newURL)
        XCTAssertEqual(updated.segments.count, 2)
        XCTAssertEqual(updated.segments[0].completedBytes, 500, "Compatible completed segment bytes must be preserved")
        XCTAssertEqual(updated.segments[1].completedBytes, 0)
        XCTAssertEqual(updated.headers["Cookie"], "sid=123")
    }

    func testDownloadLinkRefresherRejectsIncompatibleFileWithoutWiping() async throws {
        let destination = tempDirectory.appendingPathComponent("target_incompat.mp4")
        let oldURL = URL(string: "https://media.example.com/file1.mp4")!
        let newURL = URL(string: "https://media.example.com/file2.mp4")!

        let seg0 = SegmentRecord(id: 0, startOffset: 0, endOffset: 499, length: 500, completedBytes: 500)
        let initialRecord = DownloadRecord(
            id: "id_incompat",
            originalURL: oldURL,
            resolvedURL: oldURL,
            destinationURL: destination,
            totalSize: 1000,
            state: .failed(reason: "HTTP 404"),
            storageMode: .directSeek,
            headers: [:],
            segments: [seg0]
        )
        try await persistenceStore.save(initialRecord)

        // Probe returns different size (2000 instead of 1000)
        MockURLProtocol.setHandler(for: newURL) { req in
            let resp = HTTPURLResponse(
                url: newURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": "2000",
                    "Accept-Ranges": "bytes",
                    "Content-Type": "video/mp4"
                ]
            )!
            return (resp, Data(repeating: 0x42, count: 2000))
        }

        let refresher = DownloadLinkRefresher(session: session, persistenceStore: persistenceStore)

        do {
            _ = try await refresher.refresh(id: "id_incompat", newURL: newURL)
            XCTFail("Must reject incompatible resource with different size")
        } catch let err as DownloadRecoveryError {
            if case .incompatibleResource(let reason) = err {
                XCTAssertTrue(reason.contains("File size mismatch"))
            } else {
                XCTFail("Expected incompatibleResource error")
            }
        }

        // Verify that existing record in store was NOT modified or wiped
        let preserved = try await persistenceStore.fetch(tag: "id_incompat")
        XCTAssertEqual(preserved?.originalURL, oldURL)
        XCTAssertEqual(preserved?.segments.first?.completedBytes, 500, "Old progress must remain untouched upon rejection")
    }

    // MARK: - 4. HLSRecoveryCoordinator Tests

    func testHLSRecoveryCoordinatorReconcilesCompletedSegments() async throws {
        let hlsStoreDir = tempDirectory.appendingPathComponent("HLSStore", isDirectory: true)
        let hlsStore = try HLSPersistenceStore(storageDirectoryURL: hlsStoreDir)

        let segmentDir = tempDirectory.appendingPathComponent("HLSSegments", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)

        let outputURL = tempDirectory.appendingPathComponent("video-480p.mp4")

        // Create mock completed segment files on disk: 0.part and 1.part
        try Data("seg0".utf8).write(to: segmentDir.appendingPathComponent("0.part"))
        try Data("seg1".utf8).write(to: segmentDir.appendingPathComponent("1.part"))

        let initialRecord = HLSTransferRecord(
            id: "hls_target",
            manifestURL: URL(string: "https://stream.example.com/variant-480p.m3u8?token=old")!,
            outputFilename: "video-480p.mp4",
            outputDestinationURL: outputURL,
            segmentDirectoryURL: segmentDir,
            totalSegments: 4,
            completedSegmentOrders: [0, 1],
            state: .failed,
            assemblyState: .notStarted
        )
        try await hlsStore.save(initialRecord)

        let coordinator = HLSRecoveryCoordinator(hlsPersistenceStore: hlsStore, streamingOrchestrator: nil)
        let freshManifestURL = URL(string: "https://stream.example.com/variant-480p.m3u8?token=fresh")!

        let updated = try await coordinator.recoverHLS(
            id: "hls_target",
            newManifestURL: freshManifestURL,
            expectedResolutionHeight: 480
        )

        XCTAssertEqual(updated.manifestURL, freshManifestURL)
        XCTAssertEqual(updated.completedSegmentOrders, [0, 1], "Completed segments on disk must be preserved")
        XCTAssertEqual(updated.totalSegments, 4)

        // Negative test: attempt to recover 480p transfer with 1080p requested
        do {
            _ = try await coordinator.recoverHLS(
                id: "hls_target",
                newManifestURL: freshManifestURL,
                expectedResolutionHeight: 1080
            )
            XCTFail("Must reject incompatible resolution rendition")
        } catch let err as DownloadRecoveryError {
            if case .incompatibleResource(let reason) = err {
                XCTAssertTrue(reason.contains("Selected quality (1080p) does not match"))
            } else {
                XCTFail("Expected incompatibleResource error")
            }
        }
    }
}
