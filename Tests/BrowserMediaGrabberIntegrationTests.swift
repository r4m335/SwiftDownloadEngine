import XCTest
@testable import DM_Reverse_engineering

final class BrowserMediaGrabberIntegrationTests: XCTestCase {

    // MARK: - 1. Manifest Quality Variant Expansion

    func testHLSManifestQualityVariantExpansion() {
        let masterManifest = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        1080p/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
        720p/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=854x480,CODECS="avc1.4d401e,mp4a.40.2"
        480p/index.m3u8
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="audio/eng.m3u8"
        """

        let masterURL = URL(string: "https://video.example.com/hls/master.m3u8")!
        let masterResource = WebpageResource(
            id: "master-1",
            url: masterURL,
            title: "Big Buck Bunny HLS",
            suggestedFilename: "big_buck_bunny.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: masterManifest
        )

        let (variants, items) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: masterResource,
            manifestText: masterManifest,
            durationSeconds: 600.0 // 10 minutes
        )

        XCTAssertFalse(variants.isEmpty)
        XCTAssertGreaterThanOrEqual(variants.count, 3)

        // 1080p Variant Verification
        let v1080 = try! XCTUnwrap(variants.first { $0.title.contains("1080p") })
        XCTAssertEqual(v1080.resourceType, .video)
        XCTAssertEqual(v1080.suggestedFilename, "big_buck_bunny-1080p.mp4")
        XCTAssertEqual(v1080.hlsVariantPreferences?.maximumWidth, 1920)
        XCTAssertEqual(v1080.hlsVariantPreferences?.maximumHeight, 1080)
        XCTAssertEqual(v1080.hlsVariantPreferences?.maximumBandwidth, 6000000)
        XCTAssertFalse(v1080.isDRMProtected)

        // 720p Variant Verification
        let v720 = try! XCTUnwrap(variants.first { $0.title.contains("720p") })
        XCTAssertEqual(v720.hlsVariantPreferences?.maximumWidth, 1280)
        XCTAssertEqual(v720.hlsVariantPreferences?.maximumHeight, 720)

        // Presentation items verification
        let i1080 = try! XCTUnwrap(items.first { $0.qualityLabel == "1080p" })
        XCTAssertEqual(i1080.resolutionText, "1920 × 1080")
        XCTAssertTrue(i1080.hasAudio)
        XCTAssertFalse(i1080.hasSubtitles)
        XCTAssertNotNil(i1080.estimatedSizeBytes)
        XCTAssertTrue(i1080.estimatedSizeText?.contains("MB") == true || i1080.estimatedSizeText?.contains("GB") == true)
    }

    // MARK: - 2. DRM Stream Detection & Protection Flagging

    func testDRMStreamDetectionFairPlayAndSampleAES() {
        let fairplayManifest = """
        #EXTM3U
        #EXT-X-VERSION:5
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fps.example.com/key",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        segment1.ts
        """

        let result = StreamDRMDetector.evaluate(manifestText: fairplayManifest)
        XCTAssertTrue(result.isProtected)
        XCTAssertEqual(result.protectionType, "FairPlay")
        XCTAssertTrue(result.reason?.contains("FairPlay") == true)

        let sampleAESManifest = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="https://auth.example.com/key"
        #EXTINF:4.0,
        segment1.ts
        """
        let sampleResult = StreamDRMDetector.evaluate(manifestText: sampleAESManifest)
        XCTAssertFalse(sampleResult.isProtected)
    }

    func testDRMStreamDetectionDASHWidevineAndPlayReady() {
        let widevineMPD = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" minBufferTime="PT1.5S">
            <Period id="1">
                <AdaptationSet mimeType="video/mp4" contentType="video">
                    <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>
                    <Representation id="v1" bandwidth="2000000" width="1280" height="720"/>
                </AdaptationSet>
            </Period>
        </MPD>
        """

        let widevineResult = StreamDRMDetector.evaluate(manifestText: widevineMPD)
        XCTAssertTrue(widevineResult.isProtected)
        XCTAssertEqual(widevineResult.protectionType, "Widevine")

        let playReadyMPD = """
        <MPD>
            <Period>
                <AdaptationSet>
                    <ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95"/>
                    <Representation id="v1" bandwidth="1500000"/>
                </AdaptationSet>
            </Period>
        </MPD>
        """
        let playReadyResult = StreamDRMDetector.evaluate(manifestText: playReadyMPD)
        XCTAssertTrue(playReadyResult.isProtected)
        XCTAssertEqual(playReadyResult.protectionType, "PlayReady")
    }

    func testDRMStreamDetectionSessionKeyAndURLPath() {
        let sessionKeyMaster = """
        #EXTM3U
        #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://fps.key"
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080
        variant.m3u8
        """
        let sessionResult = StreamDRMDetector.evaluate(manifestText: sessionKeyMaster)
        XCTAssertTrue(sessionResult.isProtected)
        XCTAssertEqual(sessionResult.protectionType, "FairPlay")

        let drmURL = URL(string: "https://vikiplatform.akamaized.net/1274303v/hls/hls_drm/1274303v_video_high_480p_fd49d6_2611170410.m3u8")!
        let urlResult = StreamDRMDetector.evaluate(manifestText: "", url: drmURL)
        XCTAssertTrue(urlResult.isProtected)
        XCTAssertEqual(urlResult.protectionType, "DRM")
    }

    func testDRMManifestFlaggingDuringExpanderWorkflow() {
        let fairplayMaster = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080
        variant.m3u8
        #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://fps.key"
        """

        let master = WebpageResource(
            id: "drm-hls-1",
            url: URL(string: "https://secure.example.com/fairplay.m3u8")!,
            title: "Encrypted FairPlay Stream",
            suggestedFilename: "protected.m3u8",
            resourceType: .video,
            manifestText: fairplayMaster
        )

        let (variants, _) = StreamManifestResourceExpander.expandSynchronously(
            masterResource: master,
            manifestText: fairplayMaster
        )

        XCTAssertFalse(variants.isEmpty)
        for variant in variants {
            XCTAssertTrue(variant.isDRMProtected)
            XCTAssertEqual(variant.drmProtectionType, "FairPlay")
            XCTAssertFalse(variant.isSupported)
            XCTAssertNotNil(variant.unsupportedReason)
        }
    }

    // MARK: - 3. Expiring Signed URLs & Expiration Evaluation

    func testExpiringURLDetectionWithUnixTimestamps() {
        let now = Date(timeIntervalSince1970: 1700000000)

        // 1. Expired URL (timestamp is in the past: 1699990000 < 1700000000)
        let expiredURL = URL(string: "https://cdn.example.com/video.mp4?expires=1699990000&sig=abc")!
        XCTAssertTrue(DirectMediaTransferPlanner.isURLExpired(expiredURL, now: now))
        XCTAssertFalse(DirectMediaTransferPlanner.isURLExpiringSoon(expiredURL, thresholdSeconds: 300, now: now))

        // 2. Expiring soon URL (expires in 120 seconds: 1700000120)
        let expiringSoonURL = URL(string: "https://cdn.example.com/video.mp4?exp=1700000120&token=xyz")!
        XCTAssertFalse(DirectMediaTransferPlanner.isURLExpired(expiringSoonURL, now: now))
        XCTAssertTrue(DirectMediaTransferPlanner.isURLExpiringSoon(expiringSoonURL, thresholdSeconds: 300, now: now))

        // 3. Valid future URL (expires in 24 hours: 1700086400)
        let futureURL = URL(string: "https://cdn.example.com/video.mp4?expires=1700086400&sig=valid")!
        XCTAssertFalse(DirectMediaTransferPlanner.isURLExpired(futureURL, now: now))
        XCTAssertFalse(DirectMediaTransferPlanner.isURLExpiringSoon(futureURL, thresholdSeconds: 300, now: now))

        // 4. URL without expiration parameters
        let unexpiringURL = URL(string: "https://cdn.example.com/static_video.mp4")!
        XCTAssertFalse(DirectMediaTransferPlanner.isURLExpired(unexpiringURL, now: now))
        XCTAssertFalse(DirectMediaTransferPlanner.isURLExpiringSoon(unexpiringURL, thresholdSeconds: 300, now: now))
    }

    func testExpiringURLDetectionWithAWSSignatureV4() {
        // x-amz-date: 20231114T100000Z, x-amz-expires: 900 (15 minutes)
        let s3URL = URL(string: "https://s3.amazonaws.com/bucket/asset.mp4?x-amz-date=20231114T100000Z&x-amz-expires=900&x-amz-signature=deadbeef")!

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let startDate = formatter.date(from: "20231114T100000Z")!

        // Exactly at expiration (startDate + 900s)
        let expiredTime = startDate.addingTimeInterval(901)
        XCTAssertTrue(DirectMediaTransferPlanner.isURLExpired(s3URL, now: expiredTime))

        // 200 seconds before expiration
        let activeTime = startDate.addingTimeInterval(700)
        XCTAssertFalse(DirectMediaTransferPlanner.isURLExpired(s3URL, now: activeTime))
        XCTAssertTrue(DirectMediaTransferPlanner.isURLExpiringSoon(s3URL, thresholdSeconds: 300, now: activeTime))
    }

    // MARK: - 4. LID Media Player Handoff from Discovered Resources

    func testLIDPlayerSourceCreationWithPreservedHeadersAndContext() {
        let targetURL = URL(string: "https://media.example.com/protected/stream.m3u8")!
        let pageURL = URL(string: "https://site.example.com/watch/123")!

        let cookie = BrowserCookie(
            name: "session_token",
            value: "secret_xyz",
            domain: "media.example.com",
            path: "/"
        )

        let requestContext = BrowserRequestContext(
            url: targetURL,
            pageURL: pageURL,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X)",
            cookies: [cookie],
            customHeaders: ["X-Playback-Session-ID": "session-456"]
        )

        let preferences = HLSVariantSelectionPreferences(
            maximumBandwidth: 4500000,
            maximumWidth: 1920,
            maximumHeight: 1080,
            exactURI: URL(string: "https://media.example.com/protected/1080p.m3u8")!
        )

        let hlsResource = WebpageResource(
            id: "res-hls-1",
            url: targetURL,
            title: "HLS 1080p Stream",
            suggestedFilename: "stream-1080p.mp4",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            requestContext: requestContext,
            hlsVariantPreferences: preferences
        )

        let playerSource = LIDPlayerSource.make(from: hlsResource, title: "Custom Title")
        XCTAssertNotNil(playerSource)

        guard case .hlsStream(let url, let variantPreferences, let title, let ctx) = playerSource else {
            XCTFail("Expected .hlsStream source")
            return
        }

        XCTAssertEqual(url, targetURL)
        XCTAssertEqual(variantPreferences, preferences)
        XCTAssertEqual(title, "Custom Title")
        XCTAssertEqual(ctx?.userAgent, "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X)")
        XCTAssertEqual(ctx?.referer, "https://site.example.com/watch/123")
        XCTAssertEqual(ctx?.cookies.first?.name, "session_token")
    }

    func testLIDPlayerSourceCreationForDirectMedia() {
        let directURL = URL(string: "https://cdn.example.com/trailer.mp4")!
        let pageURL = URL(string: "https://cinema.example.com/movie/abc")!

        let cookie = BrowserCookie(
            name: "cdn_auth",
            value: "token_123",
            domain: "cdn.example.com",
            path: "/"
        )

        let requestContext = BrowserRequestContext(
            url: directURL,
            pageURL: pageURL,
            userAgent: "LIDBrowser/2.0",
            cookies: [cookie]
        )

        let directResource = WebpageResource(
            id: "res-direct-1",
            url: directURL,
            title: "Official Trailer",
            suggestedFilename: "trailer.mp4",
            resourceType: .video,
            mimeType: "video/mp4",
            requestContext: requestContext
        )

        let source = LIDPlayerSource.make(from: directResource)
        XCTAssertNotNil(source)

        guard case .networkStream(let url, let headers, let title) = source else {
            XCTFail("Expected .networkStream source")
            return
        }

        XCTAssertEqual(url, directURL)
        XCTAssertEqual(title, "trailer.mp4")
        XCTAssertEqual(headers["User-Agent"], "LIDBrowser/2.0")
        XCTAssertEqual(headers["Referer"], "https://cinema.example.com/movie/abc")
        XCTAssertEqual(headers["Cookie"], "cdn_auth=token_123")
    }
}
