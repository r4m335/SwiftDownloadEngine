import Foundation
import XCTest
@testable import DownloadEngineKit

final class StreamQualityPickerTests: XCTestCase {

    private let masterURL = URL(string: "https://cdn.example.com/stream/master.m3u8")!
    private let dashURL = URL(string: "https://cdn.example.com/stream/manifest.mpd")!

    // MARK: - HLS Master Manifest Quality Inspection

    func testHLSQualityInspectionDiscoversAllVariantsRanked() throws {
        let masterPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        360p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.64002a,mp4a.40.2",FRAME-RATE=60.000
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
        720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=854x480,CODECS="avc1.4d401f,mp4a.40.2"
        480p.m3u8
        """

        let options = try StreamQualityInspector.inspectHLS(
            manifestText: masterPlaylist,
            baseURL: masterURL,
            durationSeconds: 120.0
        )

        XCTAssertEqual(options.count, 4)

        // 1. First should be 1080p (highest bandwidth)
        let first = options[0]
        XCTAssertEqual(first.qualityBadge, "1080p")
        XCTAssertEqual(first.label, "1080p Full HD")
        XCTAssertEqual(first.resolution?.width, 1920)
        XCTAssertEqual(first.resolution?.height, 1080)
        XCTAssertEqual(first.resolutionText, "1920 × 1080")
        XCTAssertEqual(first.bandwidth, 5_000_000)
        XCTAssertEqual(first.bitrateText, "5.0 Mbps")
        XCTAssertEqual(first.frameRate, 60.0)
        XCTAssertEqual(first.videoCodec, "H.264")
        XCTAssertEqual(first.audioCodec, "AAC")
        XCTAssertFalse(first.isAudioOnly)
        XCTAssertTrue(first.hasAudio)
        XCTAssertTrue(first.hasVideo)
        XCTAssertNotNil(first.estimatedSizeBytes)

        // 2. Second should be 720p
        let second = options[1]
        XCTAssertEqual(second.qualityBadge, "720p")
        XCTAssertEqual(second.label, "720p HD")
        XCTAssertEqual(second.resolution?.height, 720)
        XCTAssertEqual(second.bandwidth, 2_500_000)

        // 3. Third should be 480p
        let third = options[2]
        XCTAssertEqual(third.qualityBadge, "480p")
        XCTAssertEqual(third.label, "480p SD")
        XCTAssertEqual(third.resolution?.height, 480)

        // 4. Fourth should be 360p
        let fourth = options[3]
        XCTAssertEqual(fourth.qualityBadge, "360p")
        XCTAssertEqual(fourth.resolution?.height, 360)
        XCTAssertEqual(fourth.bandwidth, 800_000)
    }

    func testHLSAudioOnlyOptionExtractedFromRenditions() throws {
        let masterWithAudio = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-aac",NAME="English Audio",LANGUAGE="en",DEFAULT=YES,URI="audio/eng.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,AUDIO="audio-aac"
        video/720p.m3u8
        """

        let options = try StreamQualityInspector.inspectHLS(
            manifestText: masterWithAudio,
            baseURL: masterURL
        )

        XCTAssertEqual(options.count, 2)

        let videoOption = options[0]
        XCTAssertEqual(videoOption.qualityBadge, "720p")
        XCTAssertFalse(videoOption.isAudioOnly)

        let audioOption = options[1]
        XCTAssertEqual(audioOption.qualityBadge, "AUDIO")
        XCTAssertTrue(audioOption.isAudioOnly)
        XCTAssertTrue(audioOption.label.contains("Audio Only"))
        XCTAssertEqual(audioOption.audioCodec, "AAC")
        XCTAssertEqual(audioOption.uri, URL(string: "https://cdn.example.com/stream/audio/eng.m3u8")!)
    }

    func testHLSVariantWithMissingAudioGroupHasAudioFalseAndNilAudioCodec() throws {
        let masterWithMissingAudio = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,CODECS="avc1.640028",AUDIO="nonexistent-group"
        video/720p.m3u8
        """

        let options = try StreamQualityInspector.inspectHLS(
            manifestText: masterWithMissingAudio,
            baseURL: masterURL
        )

        XCTAssertEqual(options.count, 1)
        let option = options[0]
        XCTAssertEqual(option.qualityBadge, "720p")
        XCTAssertEqual(option.videoCodec, "H.264")
        XCTAssertFalse(option.hasAudio, "Variant referencing nonexistent audio group must not be marked hasAudio=true")
        XCTAssertNil(option.audioCodec, "Variant with unresolvable audio group must have nil audioCodec")
    }

    // MARK: - DASH MPD Quality Inspection

    func testDASHQualityInspectionDiscoversVideoAndAudioReps() throws {
        let mpd = """
        <?xml version="1.0" encoding="utf-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT60S">
          <Period id="0">
            <AdaptationSet mimeType="video/mp4" contentType="video">
              <Representation id="v-1080p" bandwidth="4500000" width="1920" height="1080" codecs="avc1.64002a">
                <SegmentTemplate media="chunk-$Number$.m4s" timescale="1000" duration="2000" />
              </Representation>
              <Representation id="v-720p" bandwidth="2200000" width="1280" height="720" codecs="avc1.4d401f">
                <SegmentTemplate media="chunk-$Number$.m4s" timescale="1000" duration="2000" />
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4" contentType="audio">
              <Representation id="a-en" bandwidth="128000" codecs="mp4a.40.2">
                <SegmentTemplate media="audio-$Number$.m4s" timescale="1000" duration="2000" />
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let options = try StreamQualityInspector.inspectDASH(
            manifestText: mpd,
            baseURL: dashURL,
            durationSeconds: 60.0
        )

        // 2 video representations + 1 audio-only representation
        XCTAssertEqual(options.count, 3)

        let rep1080 = options[0]
        XCTAssertEqual(rep1080.qualityBadge, "1080p")
        XCTAssertEqual(rep1080.label, "1080p Full HD")
        XCTAssertEqual(rep1080.resolutionText, "1920 × 1080")
        XCTAssertEqual(rep1080.bandwidth, 4_500_000)
        XCTAssertEqual(rep1080.dashVideoRepresentationID, "v-1080p")
        XCTAssertEqual(rep1080.dashAudioRepresentationID, "a-en")
        XCTAssertFalse(rep1080.isAudioOnly)

        let rep720 = options[1]
        XCTAssertEqual(rep720.qualityBadge, "720p")
        XCTAssertEqual(rep720.label, "720p HD")
        XCTAssertEqual(rep720.dashVideoRepresentationID, "v-720p")

        let audioOnly = options[2]
        XCTAssertEqual(audioOnly.qualityBadge, "AUDIO")
        XCTAssertTrue(audioOnly.isAudioOnly)
        XCTAssertEqual(audioOnly.dashAudioRepresentationID, "a-en")
        XCTAssertNil(audioOnly.dashVideoRepresentationID)
    }

    func testMultiPeriodDASHQualityInspectionDiscoversRepsAcrossAllPeriods() throws {
        let multiPeriodMPD = """
        <?xml version="1.0" encoding="utf-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
          <Period id="p1" duration="PT15S">
            <AdaptationSet mimeType="video/mp4" contentType="video">
              <Representation id="p1-v-720p" bandwidth="2200000" width="1280" height="720" codecs="avc1.4d401f">
                <SegmentTemplate media="p1-v-$Number$.m4s" timescale="1000" duration="1000" />
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4" contentType="audio" lang="en">
              <Representation id="p1-a-en" bandwidth="128000" codecs="mp4a.40.2">
                <SegmentTemplate media="p1-a-$Number$.m4s" timescale="1000" duration="1000" />
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p2" duration="PT45S">
            <AdaptationSet mimeType="video/mp4" contentType="video">
              <Representation id="p2-v-1080p" bandwidth="5000000" width="1920" height="1080" codecs="avc1.64002a">
                <SegmentTemplate media="p2-v-$Number$.m4s" timescale="1000" duration="1000" />
              </Representation>
              <Representation id="p2-v-720p" bandwidth="2200000" width="1280" height="720" codecs="avc1.4d401f">
                <SegmentTemplate media="p2-v720-$Number$.m4s" timescale="1000" duration="1000" />
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4" contentType="audio" lang="en">
              <Representation id="p2-a-en" bandwidth="128000" codecs="mp4a.40.2">
                <SegmentTemplate media="p2-a-$Number$.m4s" timescale="1000" duration="1000" />
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let options = try StreamQualityInspector.inspectDASH(
            manifestText: multiPeriodMPD,
            baseURL: dashURL
        )

        // Should find 1080p (from Period 2), 720p (deduplicated across periods), and 1 Audio Only option
        XCTAssertEqual(options.count, 3)

        let rep1080 = options[0]
        XCTAssertEqual(rep1080.qualityBadge, "1080p")
        XCTAssertEqual(rep1080.bandwidth, 5_000_000)
        // Duration sum is 15s + 45s = 60s
        XCTAssertNotNil(rep1080.estimatedSizeBytes)
        // 5,000,000 bps * 60s / 8 = 37,500,000 bytes (~35.7 MB)
        XCTAssertTrue(rep1080.estimatedSizeText?.contains("MB") == true)

        let rep720 = options[1]
        XCTAssertEqual(rep720.qualityBadge, "720p")
        XCTAssertEqual(rep720.bandwidth, 2_200_000)

        let audio = options[2]
        XCTAssertTrue(audio.isAudioOnly)
        XCTAssertEqual(audio.qualityBadge, "AUDIO")
        XCTAssertEqual(audio.label, "Audio Only (English)")
    }

    func testDASHQualityInspectionDiscoversAlternateAudioLanguages() throws {
        let multiAudioMPD = """
        <?xml version="1.0" encoding="utf-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT120S">
          <Period id="0">
            <AdaptationSet mimeType="video/mp4" contentType="video">
              <Representation id="v1" bandwidth="3000000" width="1280" height="720" codecs="avc1.4d401f">
                <SegmentTemplate media="v-$Number$.m4s" timescale="1000" duration="2000" />
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4" contentType="audio" lang="en">
              <Representation id="a-en" bandwidth="128000" codecs="mp4a.40.2">
                <SegmentTemplate media="a-en-$Number$.m4s" timescale="1000" duration="2000" />
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4" contentType="audio" lang="es">
              <Representation id="a-es" bandwidth="128000" codecs="mp4a.40.2">
                <SegmentTemplate media="a-es-$Number$.m4s" timescale="1000" duration="2000" />
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4" contentType="audio" lang="fr">
              <Representation id="a-fr" bandwidth="128000" codecs="mp4a.40.2">
                <SegmentTemplate media="a-fr-$Number$.m4s" timescale="1000" duration="2000" />
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let options = try StreamQualityInspector.inspectDASH(
            manifestText: multiAudioMPD,
            baseURL: dashURL
        )

        // 1 video + 3 audio-only representations (en, es, fr)
        XCTAssertEqual(options.count, 4)

        let video = options[0]
        XCTAssertEqual(video.qualityBadge, "720p")
        // English preferred as default audio pair
        XCTAssertEqual(video.dashAudioRepresentationID, "a-en")

        let audioOptions = options.filter { $0.isAudioOnly }
        XCTAssertEqual(audioOptions.count, 3)

        let englishAudio = audioOptions.first { $0.label.contains("English") }
        XCTAssertNotNil(englishAudio)
        XCTAssertEqual(englishAudio?.dashAudioRepresentationID, "a-en")

        let spanishAudio = audioOptions.first { $0.label.contains("Spanish") }
        XCTAssertNotNil(spanishAudio)
        XCTAssertEqual(spanishAudio?.dashAudioRepresentationID, "a-es")

        let frenchAudio = audioOptions.first { $0.label.contains("French") }
        XCTAssertNotNil(frenchAudio)
        XCTAssertEqual(frenchAudio?.dashAudioRepresentationID, "a-fr")
    }

    func testDASHQualityInspectionDiscoversSubtitlesAndCaptions() throws {
        let subMPD = """
        <?xml version="1.0" encoding="utf-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT90S">
          <Period id="0">
            <AdaptationSet mimeType="video/mp4" contentType="video">
              <Representation id="v1" bandwidth="4000000" width="1920" height="1080" codecs="avc1.64002a">
                <SegmentTemplate media="v-$Number$.m4s" timescale="1000" duration="2000" />
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4" contentType="audio" lang="en">
              <Representation id="a1" bandwidth="128000" codecs="mp4a.40.2">
                <SegmentTemplate media="a-$Number$.m4s" timescale="1000" duration="2000" />
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="text/vtt" contentType="text" lang="en">
              <Representation id="sub-en" bandwidth="1000">
                <SegmentTemplate media="sub-en-$Number$.vtt" timescale="1000" duration="2000" />
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="application/ttml+xml" contentType="caption" lang="es">
              <Representation id="cc-es" bandwidth="1000">
                <SegmentTemplate media="cc-es-$Number$.ttml" timescale="1000" duration="2000" />
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let options = try StreamQualityInspector.inspectDASH(
            manifestText: subMPD,
            baseURL: dashURL
        )

        // 1 video + 1 audio + 2 text tracks (sub + cc) = 4 options
        XCTAssertEqual(options.count, 4)

        let video = options[0]
        XCTAssertEqual(video.qualityBadge, "1080p")
        XCTAssertTrue(video.hasSubtitles)
        XCTAssertEqual(video.subtitleText, "Subtitles (EN, ES)")

        let audio = options[1]
        XCTAssertTrue(audio.isAudioOnly)
        XCTAssertEqual(audio.label, "Audio Only (English)")

        let subOption = options.first { $0.qualityBadge == "SUB" }
        XCTAssertNotNil(subOption)
        XCTAssertEqual(subOption?.label, "Subtitles (English)")
        XCTAssertTrue(subOption?.hasSubtitles == true)
        XCTAssertFalse(subOption?.hasVideo == true)
        XCTAssertFalse(subOption?.hasAudio == true)

        let ccOption = options.first { $0.qualityBadge == "CC" }
        XCTAssertNotNil(ccOption)
        XCTAssertEqual(ccOption?.label, "Closed Captions (Spanish)")
        XCTAssertTrue(ccOption?.hasSubtitles == true)
    }

    // MARK: - Single Media Playlist Fallback

    func testSingleMediaPlaylistProducesDefaultStreamQuality() throws {
        let mediaPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:10.0,
        seg1.ts
        #EXTINF:10.0,
        seg2.ts
        #EXT-X-ENDLIST
        """

        let options = try StreamQualityInspector.inspectHLS(
            manifestText: mediaPlaylist,
            baseURL: URL(string: "https://cdn.example.com/video/index.m3u8")!
        )

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].label, "Default Stream Quality")
        XCTAssertEqual(options[0].qualityBadge, "HD")
    }

    // MARK: - Exact Variant Preference Filtering

    func testExactURIInHLSVariantSelectionPreferencesPinsSelection() throws {
        let masterPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
        720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=854x480
        480p.m3u8
        """

        let manifest = try HLSManifestParser.parse(masterPlaylist, baseURL: masterURL)

        // Select the 720p variant specifically
        let target720pURL = URL(string: "https://cdn.example.com/stream/720p.m3u8")!
        let prefs = HLSVariantSelectionPreferences(exactURI: target720pURL)

        let ranked = try HLSVariantSelector.rank(from: manifest, preferences: prefs)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].uri, target720pURL)
        XCTAssertEqual(ranked[0].resolution?.height, 720)
    }

    // MARK: - Size Estimation & Formatting

    func testEstimatedSizeCalculations() {
        // 5 Mbps stream for 60 seconds = 300,000,000 bits = 37,500,000 bytes (~37.5 MB)
        let estBytes = StreamQualityOption.estimateSize(bandwidth: 5_000_000, durationSeconds: 60)
        XCTAssertNotNil(estBytes)
        XCTAssertEqual(estBytes!, 37_500_000)

        let formatted = StreamQualityOption.formatByteSize(37_500_000)
        XCTAssertTrue(formatted.contains("37.5") || formatted.contains("38") || formatted.contains("MB"))

        let bwFormatted = StreamQualityOption.formatBandwidth(5_000_000)
        XCTAssertEqual(bwFormatted, "5.0 Mbps")

        let kbpsFormatted = StreamQualityOption.formatBandwidth(850_000)
        XCTAssertEqual(kbpsFormatted, "850 Kbps")
    }

    // MARK: - Mux 5-Variant Master Stream & Size Fallback

    func testMuxMasterPlaylistDiscoversFiveVariantsAndSizeFallback() throws {
        // Matches the 5-variant Mux test stream from the physical device execution logs:
        // https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
        let muxManifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=6221600,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        url_0/1920x1080.m3u8
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=3361600,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
        url_2/1280x720.m3u8
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=1961600,RESOLUTION=960x540,CODECS="avc1.4d401f,mp4a.40.2"
        url_4/960x540.m3u8
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=1161600,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        url_6/640x360.m3u8
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=694400,RESOLUTION=416x234,CODECS="avc1.42c00d,mp4a.40.2"
        url_8/416x234.m3u8
        """

        let options = try StreamQualityInspector.inspectHLS(
            manifestText: muxManifest,
            baseURL: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        )

        XCTAssertEqual(options.count, 5)

        // 1. Highest: 1080p
        XCTAssertEqual(options[0].qualityBadge, "1080p")
        XCTAssertEqual(options[0].resolution?.width, 1920)
        XCTAssertEqual(options[0].resolution?.height, 1080)
        XCTAssertEqual(options[0].bandwidth, 6_221_600)
        XCTAssertEqual(options[0].estimatedSizeText, "Size unavailable")

        // 2. 720p
        XCTAssertEqual(options[1].qualityBadge, "720p")
        XCTAssertEqual(options[1].resolution?.height, 720)
        XCTAssertEqual(options[1].bandwidth, 3_361_600)

        // 3. 540p (SD)
        XCTAssertEqual(options[2].resolution?.height, 540)
        XCTAssertEqual(options[2].bandwidth, 1_961_600)

        // 4. 360p
        XCTAssertEqual(options[3].qualityBadge, "360p")
        XCTAssertEqual(options[3].resolution?.height, 360)

        // 5. 234p
        XCTAssertEqual(options[4].resolution?.height, 234)
        XCTAssertEqual(options[4].bandwidth, 694_400)

        // When duration is supplied (e.g. 10 minutes = 600s), size is accurately computed
        let optionsWithDuration = try StreamQualityInspector.inspectHLS(
            manifestText: muxManifest,
            baseURL: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!,
            durationSeconds: 600.0
        )
        XCTAssertEqual(optionsWithDuration.count, 5)
        XCTAssertNotNil(optionsWithDuration[0].estimatedSizeBytes)
        XCTAssertNotEqual(optionsWithDuration[0].estimatedSizeText, "Size unavailable")
        XCTAssertTrue(optionsWithDuration[0].estimatedSizeText?.contains("MB") == true)
    }

    // MARK: - Quality Selection Filename Extension Adjustment

    #if canImport(SwiftUI)
    @MainActor
    func testSelectQualityOptionAdjustsFilenameExtension() throws {
        let vm = BrowserViewModel()
        vm.qualityPickerFilename = "SummerVacation.mp4"

        let videoOption = StreamQualityOption(
            id: "opt-720",
            label: "720p HD",
            qualityBadge: "720p",
            bandwidth: 2_500_000,
            bitrateText: "2.5 Mbps",
            uri: masterURL
        )

        let audioOption = StreamQualityOption(
            id: "opt-audio",
            label: "Audio Only",
            qualityBadge: "AUDIO",
            bandwidth: 128_000,
            bitrateText: "128 Kbps",
            isAudioOnly: true,
            uri: masterURL
        )

        // Select Audio Only: should change .mp4 to .m4a
        vm.selectQualityOption(audioOption)
        XCTAssertEqual(vm.qualityPickerFilename, "SummerVacation.m4a")

        // Switch back to video option: should change back to .mp4
        vm.selectQualityOption(videoOption)
        XCTAssertEqual(vm.qualityPickerFilename, "SummerVacation.mp4")
    }

    @MainActor
    func testPromptStreamingDownloadTriggersQualityPickerForMultiVariantStream() async throws {
        let orchestrator = StreamingDownloadOrchestrator(segmentExecutor: URLSessionStreamingSegmentExecutor())
        let vm = BrowserViewModel(streamingOrchestrator: orchestrator)
        let muxManifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=6221600,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3361600,RESOLUTION=1280x720
        720p.m3u8
        """
        let resource = WebpageResource(
            url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!,
            title: "Mux Big Buck Bunny",
            suggestedFilename: "bunny.mp4",
            resourceType: .video,
            manifestText: muxManifest,
            hlsVariantPreferences: nil
        )

        vm.promptStreamingDownload(for: resource)

        // Allow MainActor task cooperative cycles to inspect options
        for _ in 0..<50 {
            if vm.isShowingQualityPicker && !vm.qualityPickerOptions.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(vm.isShowingQualityPicker)
        XCTAssertEqual(vm.qualityPickerOptions.count, 2)
        XCTAssertEqual(vm.selectedQualityOption?.qualityBadge, "1080p")
        XCTAssertFalse(vm.isExecutingStreaming)
    }

    @MainActor
    func testPromptStreamingDownloadSkipsQualityPickerWhenVariantPreferencesPreselected() async throws {
        let orchestrator = StreamingDownloadOrchestrator(segmentExecutor: URLSessionStreamingSegmentExecutor())
        let vm = BrowserViewModel(streamingOrchestrator: orchestrator)
        let muxManifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=6221600,RESOLUTION=1920x1080
        1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=848x480
        480p.m3u8
        """
        let prefs = HLSVariantSelectionPreferences(
            maximumBandwidth: 1400000,
            maximumWidth: 848,
            maximumHeight: 480,
            exactURI: URL(string: "https://test-streams.mux.dev/x36xhzz/480p.m3u8")
        )
        let resource = WebpageResource(
            url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!,
            title: "HLS 480p",
            suggestedFilename: "x36xhzz-480p.mp4",
            resourceType: .video,
            manifestText: muxManifest,
            hlsVariantPreferences: prefs
        )

        vm.promptStreamingDownload(for: resource)

        // Allow cooperative cycles
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // Quality picker must NOT be shown when variant is already preselected
        XCTAssertFalse(vm.isShowingQualityPicker, "Preselected variant must skip redundant StreamQualityPickerSheet")
    }

    @MainActor
    func testExecuteDownloadFastPathPreservesPreSelectedVariantPreferencesAndFilename() async throws {
        let orchestrator = StreamingDownloadOrchestrator(segmentExecutor: URLSessionStreamingSegmentExecutor())
        let vm = BrowserViewModel(streamingOrchestrator: orchestrator)
        let masterURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        let prefs = HLSVariantSelectionPreferences(
            maximumBandwidth: 1400000,
            maximumWidth: 848,
            maximumHeight: 480,
            exactURI: URL(string: "https://test-streams.mux.dev/x36xhzz/480p.m3u8")
        )
        let resource = WebpageResource(
            id: "test-resource-480p",
            url: masterURL,
            title: "HLS 480p",
            suggestedFilename: "x36xhzz-480p.mp4",
            resourceType: .video,
            manifestText: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=848x480\n480p.m3u8\n",
            hlsVariantPreferences: prefs
        )

        vm.activeDownloadResource = resource
        vm.downloadCandidateURL = masterURL
        vm.downloadCandidateFilename = "custom_renamed_480p.mp4"

        try await vm.executeDownload()

        // Verify quality picker was not triggered
        XCTAssertFalse(vm.isShowingQualityPicker)
        XCTAssertFalse(vm.isShowingDownloadSheet)
        XCTAssertEqual(vm.activeStreamingFilename, "custom_renamed_480p.mp4")
    }

    func testAudioRenditionExactURIFallbackInVariantRanking() throws {
        let masterPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,AUDIO="audio"
        720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=854x480,AUDIO="audio"
        480p.m3u8
        """
        let manifest = try HLSManifestParser.parse(masterPlaylist, baseURL: masterURL)
        let audioURI = URL(string: "https://cdn.example.com/stream/audio.m3u8")!
        let prefs = HLSVariantSelectionPreferences(exactURI: audioURI)

        // When exactURI targets audio rendition, HLSVariantSelector.rank gracefully falls back rather than throwing
        let ranked = try HLSVariantSelector.rank(from: manifest, preferences: prefs)
        XCTAssertFalse(ranked.isEmpty)
        XCTAssertEqual(ranked.first?.resolution?.height, 720)
    }

    @MainActor
    func testPlayerBackendSelectionForNetworkStream() {
        let engine = LIDPlaybackEngine()
        let mp4URL = URL(string: "https://cdn.example.com/video.mp4")!
        let mkvURL = URL(string: "https://cdn.example.com/video.mkv")!

        let mp4Source = LIDPlayerSource.networkStream(url: mp4URL, headers: [:], title: "MP4 Video")
        let mkvSource = LIDPlayerSource.networkStream(url: mkvURL, headers: [:], title: "MKV Video")

        XCTAssertEqual(engine.selectBackend(for: mp4Source), .avFoundation)
        XCTAssertEqual(engine.selectBackend(for: mkvSource), .vlcKit)
    }

    func testLIDPlayerSourceRejectsBlobResources() {
        let blobResource = WebpageResource(
            id: "blob-123",
            url: URL(string: "blob:https://example.com/1234-5678")!,
            title: "Blob Stream",
            suggestedFilename: "stream.blob",
            resourceType: .video
        )
        let source = LIDPlayerSource.make(from: blobResource)
        XCTAssertNil(source)
    }
    #endif

    func testDeduplicateVariantsWithSameResolutionAndBitrateAcrossDifferentURIs() throws {
        let masterWithMirrors = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        https://cdn-1.example.com/1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        https://cdn-2.example.com/1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        https://cdn-1.example.com/720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        https://cdn-2.example.com/720p.m3u8
        """

        let options = try StreamQualityInspector.inspectHLS(
            manifestText: masterWithMirrors,
            baseURL: masterURL
        )

        // Deduplication must collapse the 4 variants into 2 distinct quality tiers
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].qualityBadge, "1080p")
        XCTAssertEqual(options[0].uri, URL(string: "https://cdn-1.example.com/1080p.m3u8")!)
        XCTAssertEqual(options[1].qualityBadge, "720p")
        XCTAssertEqual(options[1].uri, URL(string: "https://cdn-1.example.com/720p.m3u8")!)
    }

    func testVariantIDsDoNotCollideWhenFilenameBandwidthAndResolutionMatch() throws {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        https://cdn-a.example.com/live/stream.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        https://cdn-b.example.com/live/stream.m3u8
        """

        let parsed = try HLSManifestParser.parse(manifest, baseURL: masterURL)
        let ranked = try HLSVariantSelector.rank(from: parsed, deduplicate: false)
        XCTAssertEqual(ranked.count, 2)

        let optA = StreamQualityOption.from(variant: ranked[0], masterURL: masterURL)
        let optB = StreamQualityOption.from(variant: ranked[1], masterURL: masterURL)

        XCTAssertNotEqual(optA.id, optB.id, "Variant IDs must not collide even if bandwidth, resolution, and filename are identical")
    }

    func testVariantsWithSameResolutionDisambiguateLabelsWhenRetained() throws {
        let masterWithDifferentCodecs = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="avc1.640028"
        1080p_avc.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="hvc1.2.4.L153.B0"
        1080p_hevc.m3u8
        """

        let options = try StreamQualityInspector.inspectHLS(
            manifestText: masterWithDifferentCodecs,
            baseURL: masterURL
        )

        XCTAssertEqual(options.count, 2)
        XCTAssertNotEqual(options[0].label, options[1].label, "Variants sharing resolution must have disambiguated labels")
        XCTAssertTrue(options[0].label.contains("H.264") || options[0].label.contains("6.0 Mbps"))
        XCTAssertTrue(options[1].label.contains("HEVC") || options[1].label.contains("4.0 Mbps"))
    }

    func testHLSQualityInspectionDiscoversIFrameVariants() throws {
        let masterWithIFrames = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        1080p.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1920x1080,URI="iframe_1080p.m3u8"
        """

        let options = try StreamQualityInspector.inspectHLS(
            manifestText: masterWithIFrames,
            baseURL: masterURL
        )

        XCTAssertEqual(options.count, 2)
        XCTAssertFalse(options[0].isIFrameOnly)
        XCTAssertEqual(options[0].qualityBadge, "1080p")
        XCTAssertTrue(options[0].hasAudio)

        XCTAssertTrue(options[1].isIFrameOnly)
        XCTAssertEqual(options[1].qualityBadge, "1080p (I-Frame)")
        XCTAssertFalse(options[1].hasAudio)
        XCTAssertTrue(options[1].id.contains("iframe"))
    }

    func testBandwidthOnlyVariantsRetainBitrateBadgeWithoutInferredResolution() throws {
        let masterBandwidthOnly = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,CODECS="avc1.640028,mp4a.40.2"
        high.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401e,mp4a.40.2"
        low.m3u8
        """

        let options = try StreamQualityInspector.inspectHLS(
            manifestText: masterBandwidthOnly,
            baseURL: masterURL
        )

        XCTAssertEqual(options.count, 2)

        // 1. 6 Mbps variant must NOT be assigned fake "1080p"
        let first = options[0]
        XCTAssertEqual(first.bandwidth, 6_000_000)
        XCTAssertEqual(first.qualityBadge, "6.0 Mbps")
        XCTAssertEqual(first.label, "6.0 Mbps Stream")
        XCTAssertNil(first.resolution)
        XCTAssertNil(first.resolutionText)
        XCTAssertFalse(first.label.contains("1080p"))
        XCTAssertFalse(first.qualityBadge.contains("1080p"))

        // 2. 800 Kbps variant must NOT be assigned fake "360p"
        let second = options[1]
        XCTAssertEqual(second.bandwidth, 800_000)
        XCTAssertEqual(second.qualityBadge, "800 Kbps")
        XCTAssertEqual(second.label, "800 Kbps Stream")
        XCTAssertNil(second.resolution)
        XCTAssertNil(second.resolutionText)
        XCTAssertFalse(second.label.contains("360p"))
        XCTAssertFalse(second.qualityBadge.contains("360p"))
    }

    func testUnusualBitrateHierarchyDoesNotConflateBitrateWithResolution() throws {
        // High bitrate 720p (8 Mbps) and low bitrate 1080p (1.5 Mbps) plus resolution-less 4 Mbps
        let unusualMaster = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"
        720p_high.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.4d401f,mp4a.40.2"
        unrated_mid.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1920x1080,CODECS="av01.0.08M.08,mp4a.40.2"
        1080p_av1.m3u8
        """

        let options = try StreamQualityInspector.inspectHLS(
            manifestText: unusualMaster,
            baseURL: masterURL
        )

        XCTAssertEqual(options.count, 3)

        // 1. Highest bandwidth: 8 Mbps 720p
        XCTAssertEqual(options[0].bandwidth, 8_000_000)
        XCTAssertEqual(options[0].qualityBadge, "720p")
        XCTAssertEqual(options[0].resolution?.height, 720)

        // 2. Middle bandwidth: 4 Mbps without resolution -> badge "4.0 Mbps", NOT "720p"
        XCTAssertEqual(options[1].bandwidth, 4_000_000)
        XCTAssertEqual(options[1].qualityBadge, "4.0 Mbps")
        XCTAssertEqual(options[1].label, "4.0 Mbps Stream")
        XCTAssertNil(options[1].resolution)

        // 3. Lowest bandwidth: 1.5 Mbps 1080p
        XCTAssertEqual(options[2].bandwidth, 1_500_000)
        XCTAssertEqual(options[2].qualityBadge, "1080p")
        XCTAssertEqual(options[2].resolution?.height, 1080)
    }
}

