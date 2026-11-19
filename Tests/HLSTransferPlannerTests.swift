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
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://keys/drm.key",KEYFORMAT="com.apple.streamingkeydelivery"
        #EXTINF:4,
        encrypted.m4s
        #EXT-X-ENDLIST
        """
        let encrypted = try HLSManifestParser.parse(encryptedPlaylist, baseURL: manifestURL)
        XCTAssertThrowsError(try HLSTransferPlanner.makeVODPlan(from: encrypted)) { error in
            XCTAssertEqual(error as? HLSVODTransferPlanError, .unsupportedEncryption(.sampleEncrypted))
            XCTAssertFalse(error.localizedDescription.contains("drm.key"))
        }

        let sampleAESPlaylist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="keys/sample.key"
        #EXTINF:4,
        segment1.ts
        #EXT-X-ENDLIST
        """
        let sampleParsed = try HLSManifestParser.parse(sampleAESPlaylist, baseURL: manifestURL)
        let samplePlan = try HLSTransferPlanner.makeVODPlan(from: sampleParsed)
        XCTAssertEqual(samplePlan.resources.count, 2)
        XCTAssertEqual(samplePlan.resources[0].kind, .encryptionKey)
        XCTAssertEqual(samplePlan.resources[1].kind, .mediaSegment)
        if case let .sampleAES(keyURL, _) = samplePlan.resources[1].encryption {
            XCTAssertEqual(keyURL.lastPathComponent, "sample.key")
        } else {
            XCTFail("Expected sampleAES encryption requirement on segment")
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

    func testManifestAndSegmentURLsWithFragmentsAreSanitized() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="init.mp4#track=video",BYTERANGE="100@0"
        #EXTINF:4.0,
        segment1.m4s#t=0,4
        #EXTINF:4.0,
        https://video.example/path/segment2.m4s#anchor
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest)

        XCTAssertEqual(plan.resources.count, 3)
        XCTAssertEqual(plan.resources[0].url.absoluteString, "https://video.example/path/init.mp4")
        XCTAssertNil(plan.resources[0].url.fragment)
        XCTAssertEqual(plan.resources[1].url.absoluteString, "https://video.example/path/segment1.m4s")
        XCTAssertNil(plan.resources[1].url.fragment)
        XCTAssertEqual(plan.resources[2].url.absoluteString, "https://video.example/path/segment2.m4s")
        XCTAssertNil(plan.resources[2].url.fragment)
    }

    func testVODPlanWithComplexSignedQueryParametersAndSlashesInTokens() throws {
        let complexBaseURL = URL(string: "https://goplay.su/stream/stream_yk.m3u8?k=xXf0U2tNFUz4in+jBUX2jvfxVyWpKN7HAG8C+Arkx34fmHnDQRZ9XGrD//T0g==&d=A32aNbwAHTiYGa6ludk/q7q2bm7Ri6l+hfe7IZcViqH6FvHFaE6qlXvmhno3uXdB2MNwUJCGiutTI8oYfOtofoUtmQ7pz3zp1dCbrBkg/VxwXJjVx9VPaS0Vsj1RM2p1Gi7IdjGSJj61RVCwweiXVZZo2WWIMUQcENDPq0Y1ltnmgJZFSD4JhBXZU2dO43c9zHYW8Lw0Eh4U2fjY64qJj1LBgt34QE2dlzDj22xwKkNQ476O+hiUEPK2IK7UyvUfmmK3uvXCntkGY/j1DZKMuGe+O63fFOae7WGyWSKloG9RP++S1v4z75/Z4Vcae9jYZ48xjAFL1yKEy91u7QlVk01sazwoJhVBkY/jYymqE5w+AJmNQt40WRZozwevpye9msCAnRFdwJ/MsAXtPWebeLctqBvEbMUiPmSxCkVL+a+dE7cmKHSiv2+pRkHLAnrxGdNzqj66I82iEd1l9fjdEYD0ZHw==")!

        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:6.0,
        https://valipl10.cp31.ott.cibntv.net/video_00001.mp4?ccode=0597&vid=XNjU3OTAxNjgxMg%3D%3D&vkey=B4b8b53c6193734983852d2ae09b53ec2
        #EXTINF:6.0,
        video_00002.mp4?ccode=0597&vid=XNjU3OTAxNjgxMg%3D%3D
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: complexBaseURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest)

        XCTAssertEqual(plan.resources.count, 2)
        XCTAssertEqual(plan.resources[0].url.absoluteString, "https://valipl10.cp31.ott.cibntv.net/video_00001.mp4?ccode=0597&vid=XNjU3OTAxNjgxMg%3D%3D&vkey=B4b8b53c6193734983852d2ae09b53ec2")
        XCTAssertTrue(plan.resources[1].url.absoluteString.hasPrefix("https://goplay.su/stream/video_00002.mp4"))
    }
}
