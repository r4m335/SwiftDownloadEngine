import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class DirectMediaTransferPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func resource(
        url: URL,
        filename: String = "fallback.mp4",
        mimeType: String? = "video/mp4",
        requestContext: BrowserRequestContext? = nil,
        estimatedSize: Int64? = nil,
        resourceType: WebpageResourceType = .video,
        isSupported: Bool = true
    ) -> WebpageResource {
        WebpageResource(
            url: url,
            title: "browser media",
            suggestedFilename: filename,
            resourceType: resourceType,
            mimeType: mimeType,
            estimatedSize: estimatedSize,
            isSupported: isSupported,
            requestContext: requestContext
        )
    }

    func testExtensionlessMediaUsesResponseMIMEAndPreservesSignedQuery() throws {
        let url = URL(string: "https://video.example/download?id=42&sig=signed-value")!
        let plan = try DirectMediaTransferPlanner.makePlan(
            resource: resource(url: url, filename: "recording.mp4", mimeType: nil),
            response: DirectMediaResponseMetadata(
                statusCode: 200,
                mimeType: "video/mp4; charset=binary",
                expectedContentLength: 4_096
            ),
            now: now
        )

        XCTAssertEqual(plan.transferURL.absoluteString, url.absoluteString)
        XCTAssertEqual(plan.filename, "recording.mp4")
        XCTAssertEqual(plan.mimeType, "video/mp4")
        XCTAssertEqual(plan.expectedContentLength, 4_096)
        XCTAssertEqual(plan.transferURL.query, "id=42&sig=signed-value")
    }

    func testFinalResponseURLAndMetadataReachDownloadRequest() throws {
        let originalURL = URL(string: "https://video.example/play?id=7")!
        let finalURL = URL(string: "https://video.example/files/episode.mp4")!
        let context = BrowserRequestContext(
            url: originalURL,
            pageURL: URL(string: "https://video.example/watch")!,
            userAgent: "BrowserTest/1.0",
            cookies: [BrowserCookie(name: "session", value: "secret", domain: "video.example")]
        )

        let plan = try DirectMediaTransferPlanner.makePlan(
            candidate: BrowserMediaCandidateClassifier.classify(
                resource: resource(
                    url: originalURL,
                    filename: "episode.mp4",
                    mimeType: nil,
                    requestContext: context
                ),
                now: now
            ),
            response: DirectMediaResponseMetadata(
                finalURL: finalURL,
                statusCode: 200,
                mimeType: "video/mp4",
                expectedContentLength: 8_192
            ),
            now: now
        )

        XCTAssertEqual(plan.transferURL, finalURL)
        XCTAssertEqual(plan.mimeType, "video/mp4")
        XCTAssertEqual(plan.expectedContentLength, 8_192)
        XCTAssertNotNil(plan.requestContext)
        XCTAssertEqual(plan.requestHeaders["Cookie"], "session=secret")

        let request = try plan.makeDownloadRequest(
            destinationURL: URL(fileURLWithPath: "/tmp/episode.mp4"),
            id: "final-url-media-test"
        )
        XCTAssertEqual(request.url, finalURL)
        XCTAssertEqual(request.headers["Cookie"], "session=secret")
    }

    func testContentDispositionTakesPrecedenceOverBrowserFilename() throws {
        let plan = try DirectMediaTransferPlanner.makePlan(
            resource: resource(
                url: URL(string: "https://video.example/media")!,
                filename: "browser-name.mp4"
            ),
            response: DirectMediaResponseMetadata(
                statusCode: 206,
                mimeType: "video/mp4",
                contentDisposition: "attachment; filename=server-name.mp4"
            ),
            now: now
        )

        XCTAssertEqual(plan.filename, "server-name.mp4")
    }

    func testSameOriginContextIsForwardedWithoutDurableCredentialPersistence() throws {
        let url = URL(string: "https://video.example/private/movie.mp4")!
        let context = BrowserRequestContext(
            url: url,
            pageURL: URL(string: "https://video.example/watch")!,
            userAgent: "BrowserTest/1.0",
            cookies: [BrowserCookie(name: "session", value: "secret", domain: "video.example")],
            customHeaders: ["Authorization": "Bearer secret", "X-Trace-ID": "safe"]
        )
        let plan = try DirectMediaTransferPlanner.makePlan(
            candidate: BrowserMediaCandidateClassifier.classify(
                resource: resource(url: url, requestContext: context),
                now: now
            ),
            now: now
        )

        XCTAssertEqual(plan.requestContext, context)
        XCTAssertEqual(plan.requestHeaders["Cookie"], "session=secret")
        XCTAssertEqual(plan.requestHeaders["Authorization"], "Bearer secret")
        XCTAssertEqual(plan.requestHeaders["X-Trace-ID"], "safe")

        let request = try plan.makeDownloadRequest(
            destinationURL: URL(fileURLWithPath: "/tmp/movie.mp4"),
            id: "direct-media-test",
            threadCount: 3
        )
        XCTAssertEqual(request.id, "direct-media-test")
        XCTAssertEqual(request.configuredThreadCount, 3)
        XCTAssertFalse(request.persistSensitiveHeaders)
        XCTAssertEqual(request.headers["Authorization"], "Bearer secret")
    }

    func testCrossOriginFinalURLStripsCredentialsAndContext() throws {
        let originalURL = URL(string: "https://video.example/movie.mp4")!
        let redirectedURL = URL(string: "https://cdn.example/asset")!
        let context = BrowserRequestContext(
            url: originalURL,
            pageURL: URL(string: "https://video.example/watch/private")!,
            cookies: [BrowserCookie(name: "session", value: "secret", domain: "video.example")],
            customHeaders: [
                "Authorization": "Bearer secret",
                "X-Api-Key": "api-secret",
                "X-Trace-ID": "safe"
            ]
        )

        let plan = try DirectMediaTransferPlanner.makePlan(
            candidate: BrowserMediaCandidateClassifier.classify(
                resource: resource(url: originalURL, requestContext: context),
                now: now
            ),
            response: DirectMediaResponseMetadata(
                finalURL: redirectedURL,
                statusCode: 200,
                mimeType: "video/mp4"
            ),
            now: now
        )

        XCTAssertNil(plan.requestContext)
        XCTAssertNil(plan.requestHeaders["Cookie"])
        XCTAssertNil(plan.requestHeaders["Authorization"])
        XCTAssertNil(plan.requestHeaders["X-Api-Key"])
        XCTAssertNil(plan.requestHeaders["Referer"])
        XCTAssertEqual(plan.requestHeaders["X-Trace-ID"], "safe")
    }

    func testPlannerRejectsManifestsHTMLBadStatusAndInvalidLength() {
        let manifest = resource(
            url: URL(string: "https://video.example/playlist.m3u8")!,
            filename: "playlist.m3u8",
            mimeType: "application/vnd.apple.mpegurl"
        )
        XCTAssertThrowsError(try DirectMediaTransferPlanner.makePlan(resource: manifest, now: now)) { error in
            XCTAssertEqual(error as? DirectMediaTransferPlanError, .unsupportedCandidate)
        }

        let media = resource(url: URL(string: "https://video.example/movie.mp4")!)
        XCTAssertThrowsError(try DirectMediaTransferPlanner.makePlan(
            resource: media,
            response: DirectMediaResponseMetadata(statusCode: 404),
            now: now
        )) { error in
            XCTAssertEqual(error as? DirectMediaTransferPlanError, .invalidResponseStatus(404))
            XCTAssertTrue(error.localizedDescription.contains("404"))
        }
        XCTAssertThrowsError(try DirectMediaTransferPlanner.makePlan(
            resource: media,
            response: DirectMediaResponseMetadata(statusCode: 200, mimeType: "text/html"),
            now: now
        )) { error in
            XCTAssertEqual(error as? DirectMediaTransferPlanError, .unsupportedResponseType)
        }
        XCTAssertThrowsError(try DirectMediaTransferPlanner.makePlan(
            resource: media,
            response: DirectMediaResponseMetadata(statusCode: 200, expectedContentLength: -1),
            now: now
        )) { error in
            XCTAssertEqual(error as? DirectMediaTransferPlanError, .invalidContentLength)
        }
    }

    func testPlannerRejectsExpiredSignedURLAndUnsafeDestinations() {
        let expired = resource(
            url: URL(string: "https://video.example/movie.mp4?expires=1699999999&sig=signed")!
        )
        XCTAssertThrowsError(try DirectMediaTransferPlanner.makePlan(resource: expired, now: now)) { error in
            XCTAssertEqual(error as? DirectMediaTransferPlanError, .expiredURL)
        }

        guard let valid = try? DirectMediaTransferPlanner.makePlan(
            resource: resource(url: URL(string: "https://video.example/movie.mp4")!),
            now: now
        ) else {
            return XCTFail("Expected a valid direct media plan")
        }
        XCTAssertThrowsError(try valid.makeDownloadRequest(
            destinationURL: URL(string: "https://video.example/not-local")!
        )) { error in
            XCTAssertEqual(error as? DirectMediaTransferPlanError, .invalidDestination)
        }
    }

    func testUnsupportedSchemeAndInsufficientEvidenceAreRejected() {
        let unsafe = resource(url: URL(string: "ftp://video.example/movie.mp4")!)
        XCTAssertThrowsError(try DirectMediaTransferPlanner.makePlan(resource: unsafe, now: now)) { error in
            XCTAssertEqual(error as? DirectMediaTransferPlanError, .invalidURL)
        }

        let unknown = resource(
            url: URL(string: "https://video.example/resource")!,
            filename: "resource.bin",
            mimeType: nil,
            resourceType: .other
        )
        XCTAssertThrowsError(try DirectMediaTransferPlanner.makePlan(resource: unknown, now: now)) { error in
            XCTAssertEqual(error as? DirectMediaTransferPlanError, .unsupportedCandidate)
        }
    }

    func testExtensionlessDirectVideoPlansWithInferredMP4Extension() throws {
        let url = URL(string: "https://video.example/videoplayback?id=999")!
        let extlessResource = resource(
            url: url,
            filename: "video.bin",
            mimeType: nil,
            resourceType: .video
        )

        let plan = try DirectMediaTransferPlanner.makePlan(
            resource: extlessResource,
            now: now
        )

        XCTAssertEqual(plan.transferURL, url)
        XCTAssertTrue(plan.filename.hasSuffix(".mp4"), "Expected extensionless video to be resolved with .mp4 extension, got \(plan.filename)")
    }

    func testSameSiteSubdomainRedirectPreservesDomainCookies() throws {
        let originalURL = URL(string: "https://video.example/video.mp4")!
        let cdnURL = URL(string: "https://cdn.video.example/stream.mp4")!
        let context = BrowserRequestContext(
            url: originalURL,
            pageURL: URL(string: "https://video.example/watch")!,
            cookies: [
                BrowserCookie(name: "cf_token", value: "valid_session", domain: ".video.example"),
                BrowserCookie(name: "strict_host", value: "host_only", domain: "video.example")
            ],
            customHeaders: [
                "Authorization": "Bearer private_token",
                "X-Trace-ID": "trace-subdomain"
            ]
        )

        let plan = try DirectMediaTransferPlanner.makePlan(
            candidate: BrowserMediaCandidateClassifier.classify(
                resource: resource(url: originalURL, requestContext: context),
                now: now
            ),
            response: DirectMediaResponseMetadata(
                finalURL: cdnURL,
                statusCode: 200,
                mimeType: "video/mp4"
            ),
            now: now
        )

        XCTAssertEqual(plan.transferURL, cdnURL)
        XCTAssertNotNil(plan.requestContext)
        XCTAssertTrue(plan.requestHeaders["Cookie"]?.contains("cf_token=valid_session") == true)
        XCTAssertNil(plan.requestHeaders["Authorization"], "Authorization header must be stripped when crossing subdomains")
        XCTAssertEqual(plan.requestHeaders["X-Trace-ID"], "trace-subdomain")
    }

    func testExtensionlessResourceExtractorInfersMediaFilename() {
        let html = "<video src=\"https://cdn.example.com/videoplayback?id=123\"></video>"
        let resources = WebpageResourceExtractor.extractResources(
            fromHTML: html,
            baseURL: URL(string: "https://cdn.example.com")!
        )

        XCTAssertEqual(resources.count, 1)
        let first = resources[0]
        XCTAssertEqual(first.resourceType, .video)
        XCTAssertTrue(first.suggestedFilename.hasSuffix(".mp4"), "Expected suggested filename to end in .mp4, got \(first.suggestedFilename)")
    }
}

