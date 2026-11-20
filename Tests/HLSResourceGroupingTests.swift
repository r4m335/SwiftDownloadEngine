import XCTest
@testable import DownloadEngineKit

final class HLSResourceGroupingTests: XCTestCase {
    func testMasterPlaylistGroupsObservedVariantPlaylistsAndListsQualities() {
        let masterURL = URL(string: "https://media.example.com/master.m3u8")!
        let master = WebpageResource(
            id: "master",
            url: masterURL,
            title: "Big Buck Bunny",
            suggestedFilename: "master.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            isSupported: false,
            manifestText: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=426x240
            low.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=854x480
            high.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1920x1080
            hd.m3u8
            """
        )
        let child = WebpageResource(
            id: "high",
            url: URL(string: "https://media.example.com/high.m3u8")!,
            title: "480p",
            suggestedFilename: "high.m3u8",
            resourceType: .video
        )

        XCTAssertEqual(HLSResourceGrouping.qualitySummary(for: master), "240p · 480p · 1080p")
        XCTAssertTrue(HLSResourceGrouping.variantURLs(in: [master, child]).contains(child.url.absoluteString))
    }

    func testExtractVariantStreamItemsAndResourcesWithBadges() {
        let masterURL = URL(string: "https://media.example.com/master.m3u8")!
        let master = WebpageResource(
            id: "master-1",
            url: masterURL,
            title: "Sintel",
            suggestedFilename: "sintel.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-main",NAME="English",DEFAULT=YES,URI="audio/en.m3u8"
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,URI="subs/en.vtt"
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio-main",SUBTITLES="subs"
            1080p.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="audio-main"
            720p.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42e00a,mp4a.40.2"
            360p.m3u8
            """
        )

        let items = HLSResourceGrouping.extractVariantStreamItems(for: master)
        XCTAssertEqual(items.count, 3)

        // 1080p item assertions
        let item1080 = items[0]
        XCTAssertEqual(item1080.qualityLabel, "1080p")
        XCTAssertEqual(item1080.resolutionText, "1920x1080")
        XCTAssertEqual(item1080.bitrateText, "5.0 Mbps")
        XCTAssertTrue(item1080.hasAudio)
        XCTAssertTrue(item1080.hasSubtitles)
        XCTAssertEqual(item1080.videoCodec, "H.264")

        // 720p item assertions
        let item720 = items[1]
        XCTAssertEqual(item720.qualityLabel, "720p")
        XCTAssertEqual(item720.resolutionText, "1280x720")
        XCTAssertEqual(item720.bitrateText, "2.5 Mbps")
        XCTAssertTrue(item720.hasAudio)
        XCTAssertTrue(item720.hasSubtitles) // Master has subtitle renditions

        // 360p item assertions
        let item360 = items[2]
        XCTAssertEqual(item360.qualityLabel, "360p")
        XCTAssertEqual(item360.resolutionText, "640x360")
        XCTAssertEqual(item360.bitrateText, "800 Kbps")
        XCTAssertTrue(item360.hasAudio)

        // Extract individual resources for the grabber list
        let resources = HLSResourceGrouping.extractVariantResources(from: master)
        XCTAssertEqual(resources.count, 3)
        XCTAssertTrue(resources[0].title.contains("1080p"))
        XCTAssertEqual(resources[0].suggestedFilename, "sintel-1080p.mp4")
        XCTAssertEqual(resources[0].hlsVariantPreferences?.maximumHeight, 1080)
        XCTAssertEqual(resources[0].hlsVariantPreferences?.maximumBandwidth, 5000000)

        XCTAssertTrue(resources[1].title.contains("720p"))
        XCTAssertEqual(resources[1].suggestedFilename, "sintel-720p.mp4")
        XCTAssertEqual(resources[1].hlsVariantPreferences?.maximumHeight, 720)
    }

    func testExtractVariantStreamItemsWithMissingOrUnrelatedAudio() {
        let masterURL = URL(string: "https://media.example.com/master.m3u8")!
        let master = WebpageResource(
            id: "master-test-audio",
            url: masterURL,
            title: "Test Audio Validation",
            suggestedFilename: "test.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-valid",NAME="English",DEFAULT=YES,URI="audio/en.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028",AUDIO="audio-valid"
            1080p.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.4d401f",AUDIO="audio-ghost"
            720p.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42e00a"
            360p.m3u8
            """
        )

        let items = HLSResourceGrouping.extractVariantStreamItems(for: master)
        XCTAssertEqual(items.count, 3)

        // 1080p: points to audio-valid which exists with URI
        let item1080 = items[0]
        XCTAssertEqual(item1080.qualityLabel, "1080p")
        XCTAssertTrue(item1080.hasAudio)
        XCTAssertEqual(item1080.audioText, "English")

        // 720p: points to audio-ghost which does not exist in master renditions
        let item720 = items[1]
        XCTAssertEqual(item720.qualityLabel, "720p")
        XCTAssertFalse(item720.hasAudio, "Ghost audio group must not be marked hasAudio=true")
        XCTAssertNil(item720.audioText, "Ghost audio group must have nil audioText")

        // 360p: video-only codec without audioGroup, must NOT inherit audio from unrelated audio renditions in master
        let item360 = items[2]
        XCTAssertEqual(item360.qualityLabel, "360p")
        XCTAssertFalse(item360.hasAudio, "Video-only variant must not inherit hasAudio=true from master audio renditions")
        XCTAssertNil(item360.audioText)
    }

    func testQualitySummaryAndVariantItemsDeduplicateMirrorVariants() {
        let masterURL = URL(string: "https://media.example.com/master.m3u8")!
        let master = WebpageResource(
            id: "master-mirrors",
            url: masterURL,
            title: "Mirrored Streams",
            suggestedFilename: "video.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
            https://cdn1.example.com/1080p.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
            https://cdn2.example.com/1080p.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
            https://cdn1.example.com/720p.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
            https://cdn2.example.com/720p.m3u8
            """
        )

        // 1. qualitySummary must not repeat "1080p · 1080p"
        let summary = HLSResourceGrouping.qualitySummary(for: master)
        XCTAssertEqual(summary, "720p · 1080p")

        // 2. extractVariantStreamItems must deduplicate redundant variants
        let items = HLSResourceGrouping.extractVariantStreamItems(for: master)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].qualityLabel, "1080p")
        XCTAssertEqual(items[1].qualityLabel, "720p")

        // 3. IDs must be unique
        XCTAssertNotEqual(items[0].id, items[1].id)

        // 4. extractVariantResources must produce unique resources
        let resources = HLSResourceGrouping.extractVariantResources(from: master)
        XCTAssertEqual(resources.count, 2)
        XCTAssertNotEqual(resources[0].id, resources[1].id)
        XCTAssertNotEqual(resources[0].suggestedFilename, resources[1].suggestedFilename)
    }

    func testVariantIDsDoNotCollideForIdenticalBandwidthAndResolution() {
        let masterURL = URL(string: "https://media.example.com/master.m3u8")!
        let master = WebpageResource(
            id: "master-distinct-codecs",
            url: masterURL,
            title: "Multi Codec",
            suggestedFilename: "video.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028"
            avc/1080p.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="hvc1.2.4.L153.B0"
            hevc/1080p.m3u8
            """
        )

        let items = HLSResourceGrouping.extractVariantStreamItems(for: master)
        XCTAssertEqual(items.count, 2)
        XCTAssertNotEqual(items[0].id, items[1].id, "Variant IDs must not collide even when bandwidth and resolution are identical")

        let resources = HLSResourceGrouping.extractVariantResources(from: master)
        XCTAssertEqual(resources.count, 2)
        XCTAssertNotEqual(resources[0].id, resources[1].id)
        XCTAssertNotEqual(resources[0].suggestedFilename, resources[1].suggestedFilename, "Filenames must be disambiguated when sharing quality label")
    }

    func testLiveMasterStreamIsDisabledForNormalVODDownloadAndLabeled() {
        let liveMasterURL = URL(string: "https://media.example.com/live/master.m3u8")!
        let liveMaster = WebpageResource(
            id: "live-master",
            url: liveMasterURL,
            title: "Live Broadcast 24/7",
            suggestedFilename: "live.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: """
            #EXTM3U
            #EXT-X-PLAYLIST-TYPE:EVENT
            #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
            1080p.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
            720p.m3u8
            """
        )

        // Quality summary must include LIVE indicator
        let summary = HLSResourceGrouping.qualitySummary(for: liveMaster)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("LIVE") == true, "Quality summary for live stream must contain LIVE badge")

        // Items metadata
        let items = HLSResourceGrouping.extractVariantStreamItems(for: liveMaster)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.isLive }, "Extracted variant stream items must be marked isLive")
        XCTAssertEqual(items[0].estimatedSizeText, "Live Broadcast")

        // Extracted variant resources for grabber
        let resources = HLSResourceGrouping.extractVariantResources(from: liveMaster)
        XCTAssertEqual(resources.count, 2)
        for res in resources {
            XCTAssertTrue(res.isLive, "Live variant resource must have isLive=true")
            XCTAssertFalse(res.isSupported, "Live stream must be disabled for finite VOD downloads")
            XCTAssertNotNil(res.unsupportedReason)
            XCTAssertTrue(res.unsupportedReason?.contains("Live stream recording required") == true)
            XCTAssertTrue(res.title.hasPrefix("[LIVE]"), "Live variant resource title must have [LIVE] prefix")
        }
    }

    func testLiveMediaPlaylistWithoutEndlistIsDisabledAndLabeled() {
        let liveMediaURL = URL(string: "https://media.example.com/live/index.m3u8")!
        let liveMedia = WebpageResource(
            id: "live-media",
            url: liveMediaURL,
            title: "Live Sports Game",
            suggestedFilename: "index.m3u8",
            resourceType: .video,
            mimeType: "application/vnd.apple.mpegurl",
            manifestText: """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:6
            #EXT-X-MEDIA-SEQUENCE:100
            #EXTINF:6.0,
            seg100.ts
            #EXTINF:6.0,
            seg101.ts
            """
        )

        let resources = HLSResourceGrouping.extractVariantResources(from: liveMedia)
        XCTAssertEqual(resources.count, 1)
        let res = resources[0]
        XCTAssertTrue(res.isLive, "Single media live stream must have isLive=true")
        XCTAssertFalse(res.isSupported, "Single media live stream must have isSupported=false")
        XCTAssertNotNil(res.unsupportedReason)
        XCTAssertTrue(res.title.hasPrefix("[LIVE]"))
    }
}
