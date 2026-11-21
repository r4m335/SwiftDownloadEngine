import Foundation
import XCTest
@testable import DownloadEngineKit

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

    func testCrossOriginResourcesWithVerifiedAllowlistReceiveCredentials() throws {
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
            customHeaders: ["Authorization": "Bearer header-secret", "X-Trace-ID": "safe"],
            allowedCredentialOrigins: ["cdn.example"]
        )

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest, browserRequestContext: context)
        let headers = plan.requestHeaders(for: try XCTUnwrap(plan.resources.first))

        XCTAssertEqual(headers["Cookie"], "session=cookie-secret")
        XCTAssertEqual(headers["Authorization"], "Bearer header-secret")
        XCTAssertEqual(headers["X-Trace-ID"], "safe")
        XCTAssertEqual(headers["User-Agent"], "BrowserTest/1.0")
    }

    func testCrossOriginResourcesWithUnmatchedAllowlistDoNotReceiveCredentials() throws {
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
            customHeaders: ["Authorization": "Bearer header-secret", "X-Trace-ID": "safe"],
            allowedCredentialOrigins: ["other.example"]
        )

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest, browserRequestContext: context)
        let headers = plan.requestHeaders(for: try XCTUnwrap(plan.resources.first))

        XCTAssertNil(headers["Cookie"])
        XCTAssertNil(headers["Authorization"])
        XCTAssertEqual(headers["X-Trace-ID"], "safe")
        XCTAssertEqual(headers["User-Agent"], "BrowserTest/1.0")
    }

    func testCrossOriginResourcesHTTPSDowngradeToHTTPRejectsCredentialsEvenIfAllowlisted() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:4,
        http://cdn.example/video/one.m4s
        #EXT-X-ENDLIST
        """
        let context = BrowserRequestContext(
            url: manifestURL, // https://video.example/...
            pageURL: URL(string: "https://video.example/watch")!,
            userAgent: "BrowserTest/1.0",
            cookies: [BrowserCookie(name: "session", value: "cookie-secret", domain: "video.example")],
            customHeaders: ["Authorization": "Bearer header-secret"],
            allowedCredentialOrigins: ["cdn.example"]
        )

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest, browserRequestContext: context)
        let headers = plan.requestHeaders(for: try XCTUnwrap(plan.resources.first))

        XCTAssertNil(headers["Cookie"], "Must not forward cookies over unencrypted HTTP downgrade")
        XCTAssertNil(headers["Authorization"], "Must not forward authorization over unencrypted HTTP downgrade")
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

    func testRedirectedManifestResolvesContextForSegmentRequests() throws {
        let initialMasterURL = URL(string: "https://auth.example.com/stream/master.m3u8")!
        let redirectedMediaURL = URL(string: "https://edge.cdn-streaming.net/hls/720p.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:4,
        seg0.ts
        #EXT-X-ENDLIST
        """
        let context = BrowserRequestContext(
            url: initialMasterURL,
            pageURL: URL(string: "https://example.com/watch")!,
            userAgent: "BrowserTest/1.0",
            cookies: [
                BrowserCookie(name: "master_auth", value: "master-val", domain: "auth.example.com", isSecure: true)
            ],
            customHeaders: [
                "Authorization": "Bearer master-token",
                "X-Trace-ID": "trace-seg"
            ],
            allowedCredentialOrigins: ["*.cdn-streaming.net"]
        )

        let manifest = try HLSManifestParser.parse(playlist, baseURL: redirectedMediaURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest, browserRequestContext: context)

        XCTAssertEqual(plan.browserRequestContext?.url, redirectedMediaURL)

        let segment = try XCTUnwrap(plan.resources.first)
        let headers = plan.requestHeaders(for: segment)
        XCTAssertEqual(headers["Authorization"], "Bearer master-token")
        XCTAssertEqual(headers["Cookie"], "master_auth=master-val")
        XCTAssertEqual(headers["X-Trace-ID"], "trace-seg")
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

        let cleanBaseURL = URL(string: "https://video.example/path/index.m3u8")!
        let manifest = try HLSManifestParser.parse(playlist, baseURL: cleanBaseURL)
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

    func testVODPlanWithUnderscoreHostUserinfoAndEncryptedKeyPreservation() throws {
        let complexBaseURL = URL(string: "https://stream_yk.goplay.su/stream/playlist.m3u8?token=xyz//123==&sig=abc/def")!

        let playlist = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:4.0,
        https://token_auth@cdn_node1.goplay.su/segment_001.ts
        #EXTINF:4.0,
        segment_002.ts
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: complexBaseURL)
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest)

        XCTAssertEqual(plan.resources.count, 3)
        // Key resource
        XCTAssertEqual(plan.resources[0].kind, .encryptionKey)
        XCTAssertTrue(plan.resources[0].url.absoluteString.contains("token=xyz//123=="))
        // Segment 1 with underscore host and userinfo
        XCTAssertEqual(plan.resources[1].kind, .mediaSegment)
        XCTAssertEqual(plan.resources[1].url.absoluteString, "https://token_auth@cdn_node1.goplay.su/segment_001.ts")
        // Segment 2 relative resolution
        XCTAssertEqual(plan.resources[2].kind, .mediaSegment)
        XCTAssertTrue(plan.resources[2].url.absoluteString.hasPrefix("https://stream_yk.goplay.su/stream/segment_002.ts"))
    }

    // MARK: - Implicit HLS Byte-Range Continuation Tests

    func testImplicitHLSByteRangeOffsetsContinuation() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-TARGETDURATION:10
        #EXT-X-BYTERANGE:500
        #EXTINF:10.0,
        main.mp4
        #EXT-X-BYTERANGE:300
        #EXTINF:10.0,
        main.mp4
        #EXT-X-BYTERANGE:200
        #EXTINF:10.0,
        main.mp4
        #EXT-X-BYTERANGE:400@2000
        #EXTINF:10.0,
        main.mp4
        #EXT-X-BYTERANGE:100
        #EXTINF:10.0,
        main.mp4
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        XCTAssertEqual(manifest.segments.count, 5)

        // 1. First segment without @offset starts at 0
        XCTAssertEqual(manifest.segments[0].byteRange, HLSByteRange(length: 500, offset: 0))

        // 2. Second segment without @offset continues after first (0 + 500 = 500)
        XCTAssertEqual(manifest.segments[1].byteRange, HLSByteRange(length: 300, offset: 500))

        // 3. Third segment without @offset continues after second (500 + 300 = 800)
        XCTAssertEqual(manifest.segments[2].byteRange, HLSByteRange(length: 200, offset: 800))

        // 4. Fourth segment with explicit @offset (2000)
        XCTAssertEqual(manifest.segments[3].byteRange, HLSByteRange(length: 400, offset: 2000))

        // 5. Fifth segment without @offset continues after fourth (2000 + 400 = 2400)
        XCTAssertEqual(manifest.segments[4].byteRange, HLSByteRange(length: 100, offset: 2400))

        // Verify planned transfer resources in HLSTransferPlanner
        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest)
        XCTAssertEqual(plan.resources.count, 5)
        XCTAssertEqual(plan.resources[0].byteRange, HLSByteRange(length: 500, offset: 0))
        XCTAssertEqual(plan.resources[1].byteRange, HLSByteRange(length: 300, offset: 500))
        XCTAssertEqual(plan.resources[2].byteRange, HLSByteRange(length: 200, offset: 800))
        XCTAssertEqual(plan.resources[3].byteRange, HLSByteRange(length: 400, offset: 2000))
        XCTAssertEqual(plan.resources[4].byteRange, HLSByteRange(length: 100, offset: 2400))
        XCTAssertEqual(plan.estimatedTransferBytes, 1500)
    }

    func testImplicitHLSByteRangeResetsOnResourceURIChangeOrNonByteRange() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-TARGETDURATION:10
        #EXT-X-BYTERANGE:500
        #EXTINF:10.0,
        fileA.ts
        #EXT-X-BYTERANGE:300
        #EXTINF:10.0,
        fileB.ts
        #EXTINF:10.0,
        fileB.ts
        #EXT-X-BYTERANGE:200
        #EXTINF:10.0,
        fileB.ts
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        XCTAssertEqual(manifest.segments.count, 4)

        // Segment 0: fileA.ts starts at 0
        XCTAssertEqual(manifest.segments[0].byteRange, HLSByteRange(length: 500, offset: 0))

        // Segment 1: fileB.ts (different URI) resets to 0
        XCTAssertEqual(manifest.segments[1].byteRange, HLSByteRange(length: 300, offset: 0))

        // Segment 2: fileB.ts has no byte range tag
        XCTAssertNil(manifest.segments[2].byteRange)

        // Segment 3: fileB.ts following a non-byte-range segment resets to 0
        XCTAssertEqual(manifest.segments[3].byteRange, HLSByteRange(length: 200, offset: 0))

        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest)
        XCTAssertEqual(plan.resources[0].byteRange, HLSByteRange(length: 500, offset: 0))
        XCTAssertEqual(plan.resources[1].byteRange, HLSByteRange(length: 300, offset: 0))
        XCTAssertNil(plan.resources[2].byteRange)
        XCTAssertEqual(plan.resources[3].byteRange, HLSByteRange(length: 200, offset: 0))
    }

    func testImplicitHLSByteRangeForInitializationMapWithoutOffset() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="720"
        #EXT-X-BYTERANGE:1000
        #EXTINF:10.0,
        main.mp4
        #EXT-X-ENDLIST
        """

        let manifest = try HLSManifestParser.parse(playlist, baseURL: manifestURL)
        // Init map without @offset must default to offset 0 per RFC 8216 Section 4.3.2.5
        XCTAssertEqual(manifest.segments[0].initializationMap?.byteRange, HLSByteRange(length: 720, offset: 0))
        XCTAssertEqual(manifest.segments[0].byteRange, HLSByteRange(length: 1000, offset: 0))

        let plan = try HLSTransferPlanner.makeVODPlan(from: manifest)
        XCTAssertEqual(plan.resources[0].kind, .initializationMap)
        XCTAssertEqual(plan.resources[0].byteRange, HLSByteRange(length: 720, offset: 0))
        XCTAssertEqual(plan.resources[1].kind, .mediaSegment)
        XCTAssertEqual(plan.resources[1].byteRange, HLSByteRange(length: 1000, offset: 0))
    }
}
