import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class HLSTransferPlannerTests: XCTestCase {

    private let manifestURL = URL(string: "https://video.example/path/index.m3u8?sig=manifest-secret")!

    func testVODPlanPreservesOrderRangesRelativeURLsAndSignedQueries() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="init.mp4?sig=init-signed",BYTERANGE="10@0"
        #EXT-X-BYTERANGE:20@10
        #EXTINF:2.0,
        segments/part.m4s?sig=segment-signed
        #EXT-X-BYTERANGE:30@30
        #EXTINF:2.0,
        segments/part.m4s?sig=segment-signed
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest)

        XCTAssertEqual(plan.resources.map(\.kind), [.initializationMap, .mediaSegment, .mediaSegment])
        XCTAssertEqual(plan.resources.map(\.order), [0, 1, 2])
        XCTAssertEqual(plan.resources[0].url.absoluteString, "https://video.example/path/init.mp4?sig=init-signed")
        XCTAssertEqual(plan.resources[1].url.absoluteString, "https://video.example/path/segments/part.m4s?sig=segment-signed")
        XCTAssertEqual(plan.resources[1].byteRange, HLSByteRange(length: 20, offset: 10))
        XCTAssertEqual(plan.resources[2].byteRange, HLSByteRange(length: 30, offset: 30))
        XCTAssertEqual(plan.resources[1].sequenceNumber, 0)
        XCTAssertEqual(plan.resources[2].sequenceNumber, 1)
        XCTAssertEqual(plan.estimatedTransferBytes, 60)
    }

    func testVODPlanAddsAES128KeyAndPreservesEncryptionRequirement() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-KEY:METHOD=AES-128,URI="keys/content.key?sig=key-signed",IV=0x00000000000000000000000000000001
        #EXTINF:4,
        https://cdn.example/video/one.ts?sig=segment-signed
        #EXT-X-KEY:METHOD=AES-128,URI="keys/content.key?sig=key-signed",IV=0x00000000000000000000000000000002
        #EXTINF:4,
        https://cdn.example/video/two.ts?sig=segment-signed
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest)

        XCTAssertEqual(plan.resources.map(\.kind), [.encryptionKey, .mediaSegment, .mediaSegment])
        XCTAssertEqual(plan.resources[0].url.absoluteString, "https://video.example/path/keys/content.key?sig=key-signed")
        guard case let .aes128(keyURL, iv)? = plan.resources[1].encryption else {
            return XCTFail("Expected AES-128 encryption requirement")
        }
        XCTAssertEqual(keyURL.absoluteString, plan.resources[0].url.absoluteString)
        XCTAssertEqual(iv, "0x00000000000000000000000000000001")
        XCTAssertNil(plan.estimatedTransferBytes)
    }

    func testCrossOriginResourcesStripBrowserCredentials() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:4,
        https://cdn.example/video/one.m4s?sig=segment-signed
        #EXT-X-ENDLIST
        """
        let context = BrowserRequestContext(
            url: manifestURL,
            pageURL: URL(string: "https://video.example/watch")!,
            userAgent: "BrowserTest/1.0",
            cookies: [BrowserCookie(name: "session", value: "cookie-secret", domain: "video.example")],
            customHeaders: ["Authorization": "Bearer header-secret", "X-Trace-ID": "safe"]
        )

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest, browserRequestContext: context)
        let headers = plan.requestHeaders(for: try XCTUnwrap(plan.resources.first))

        XCTAssertNil(headers["Cookie"])
        XCTAssertNil(headers["Authorization"])
        XCTAssertNil(headers["Referer"])
        XCTAssertEqual(headers["X-Trace-ID"], "safe")
        XCTAssertEqual(headers["User-Agent"], "BrowserTest/1.0")
    }

    func testSameOriginResourcesReceiveEligibleBrowserCredentials() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:4,
        segment.m4s
        #EXT-X-ENDLIST
        """
        let context = BrowserRequestContext(
            url: manifestURL,
            cookies: [BrowserCookie(name: "session", value: "cookie-secret", domain: "video.example")],
            customHeaders: ["Authorization": "Bearer header-secret"]
        )

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest, browserRequestContext: context)
        let headers = plan.requestHeaders(for: try XCTUnwrap(plan.resources.first))

        XCTAssertEqual(headers["Cookie"], "session=cookie-secret")
        XCTAssertEqual(headers["Authorization"], "Bearer header-secret")
    }

    func testPlannerRequiresASelectedMediaPlaylist() throws {
        let master = HLSManifest(
            url: manifestURL,
            playlistType: .master,
            lifecycle: .vod,
            variants: [HLSVariant(
                uri: URL(string: "video.m3u8", relativeTo: manifestURL)!.absoluteURL,
                bandwidth: 1_000
            )]
        )

        XCTAssertThrowsError(try HLSTransferPlanner.makeVODPlan(from: master)) { error in
            XCTAssertEqual(error as? HLSVODTransferPlanError, .playlistMustBeMedia)
        }
    }

    func testPlannerRejectsLiveUnsupportedEncryptionUnsafeURLAndMalformedMetadata() throws {
        let livePlaylist = """
        #EXTM3U
        #EXTINF:4,
        live.ts
        """
        let live = try HLSManifestParser.parse(livePlaylist, baseURL: manifestURL)
        XCTAssertThrowsError(try HLSTransferPlanner.makeVODPlan(from: live)) { error in
            XCTAssertEqual(error as? HLSVODTransferPlanError, .livePlaylistNotSupported)
        }

        let encryptedPlaylist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="keys/drm.key"
        #EXTINF:4,
        encrypted.m4s
        #EXT-X-ENDLIST
        """
        let encrypted = try HLSManifestParser.parse(encryptedPlaylist, baseURL: manifestURL)
        XCTAssertThrowsError(try HLSTransferPlanner.makeVODPlan(from: encrypted)) { error in
            XCTAssertEqual(error as? HLSVODTransferPlanError, .unsupportedEncryption(.sampleEncrypted))
            XCTAssertFalse(error.localizedDescription.contains("drm.key"))
        }

        let unsafe = HLSManifest(
            url: manifestURL,
            playlistType: .media,
            lifecycle: .vod,
            segments: [HLSMediaSegment(
                sequenceNumber: 0,
                uri: URL(string: "file:///private/video.m4s")!,
                duration: 4
            )]
        )
        XCTAssertThrowsError(try HLSTransferPlanner.makeVODPlan(from: unsafe)) { error in
            XCTAssertEqual(error as? HLSVODTransferPlanError, .invalidResourceURL)
        }

        let malformed = HLSManifest(
            url: manifestURL,
            playlistType: .media,
            lifecycle: .vod,
            segments: [HLSMediaSegment(
                sequenceNumber: 0,
                uri: URL(string: "segment.m4s")!,
                duration: -1
            )]
        )
        XCTAssertThrowsError(try HLSTransferPlanner.makeVODPlan(from: malformed)) { error in
            XCTAssertEqual(error as? HLSVODTransferPlanError, .invalidSegmentMetadata)
        }
    }
}
