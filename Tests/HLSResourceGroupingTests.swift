import XCTest
@testable import DM_Reverse_engineering

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
}
