import XCTest
@testable import DownloadEngineKit

final class BrowserPlaybackRoutingTests: XCTestCase {
    func testHLSIsRecognizedAsStreamingWhileDASHRemainsDASH() {
        let hls = BrowserNavigationResponseClassifier.evaluate(
            url: URL(string: "https://media.example.com/master.m3u8")!,
            statusCode: 200,
            contentType: "application/vnd.apple.mpegurl"
        )
        let dash = BrowserNavigationResponseClassifier.evaluate(
            url: URL(string: "https://media.example.com/manifest.mpd")!,
            statusCode: 200,
            contentType: "application/dash+xml"
        )

        XCTAssertTrue(hls.isStreamingManifest)
        XCTAssertEqual(hls.manifestKind, .hls)
        XCTAssertTrue(dash.isStreamingManifest)
        XCTAssertEqual(dash.manifestKind, .dash)
    }

    #if canImport(SwiftUI)
    @MainActor
    func testOrdinaryFileHandoffPrefillsAddRouteButRejectsStreamingURLs() {
        var handedOffURL: URL?
        let browser = BrowserViewModel(onOpenAddDownload: { handedOffURL = $0 })

        browser.openAddDownload(for: URL(string: "https://example.com/movie.mp4")!)
        XCTAssertEqual(handedOffURL?.absoluteString, "https://example.com/movie.mp4")

        browser.openAddDownload(for: URL(string: "https://example.com/master.m3u8")!)
        XCTAssertEqual(handedOffURL?.absoluteString, "https://example.com/movie.mp4")
    }
    #endif

    // MARK: - 10/10 Action 1: Header and Auth Pass-Through

    func testHeaderAndAuthPassThroughAcrossPlayerSource() {
        let streamURL = URL(string: "https://auth.stream.org/playlist.m3u8")!
        let context = BrowserRequestContext(
            url: streamURL,
            userAgent: "CustomSafari/1.0",
            referer: "https://auth.stream.org/portal",
            cookies: [
                BrowserCookie(name: "session_token", value: "secret123", domain: "auth.stream.org", path: "/")
            ],
            customHeaders: ["Authorization": "Bearer tokenABC"]
        )

        let resource = WebpageResource(
            id: "res-auth-hls",
            url: streamURL,
            title: "Secured HLS",
            suggestedFilename: "playlist.m3u8",
            resourceType: .video,
            isStreamingManifest: true,
            streamingManifestKind: .hls,
            requestContext: context
        )

        guard let source = LIDPlayerSource.make(from: resource) else {
            XCTFail("Failed to create LIDPlayerSource from authenticated WebpageResource")
            return
        }

        XCTAssertTrue(source.isStreaming)
        XCTAssertEqual(source.requestContext?.userAgent, "CustomSafari/1.0")
        XCTAssertEqual(source.requestContext?.referer, "https://auth.stream.org/portal")

        let effectiveHeaders = source.requestContext?.effectiveHeaders(for: streamURL) ?? [:]
        XCTAssertEqual(effectiveHeaders["User-Agent"], "CustomSafari/1.0")
        XCTAssertEqual(effectiveHeaders["Referer"], "https://auth.stream.org/portal")
        XCTAssertTrue(effectiveHeaders["Cookie"]?.contains("session_token=secret123") == true)
        XCTAssertEqual(effectiveHeaders["Authorization"], "Bearer tokenABC")
    }

    // MARK: - 10/10 Action 2: Deterministic Backend Routing

    @MainActor
    func testDeterministicBackendRouting() {
        let engine = LIDPlaybackEngine.shared

        // 1. Native HLS stream without variant preferences -> AVFoundation
        let hlsURL = URL(string: "https://stream.example.com/live.m3u8")!
        let hlsSource = LIDPlayerSource.hlsStream(url: hlsURL, variantPreferences: nil, title: "HLS")
        XCTAssertEqual(engine.selectBackend(for: hlsSource), .avFoundation)

        // 2. HLS stream specifying non-native codec (VP9, AV1, Opus) -> VLCKit
        let vp9Pref = HLSVariantSelectionPreferences(preferredCodecPrefix: "vp09.00.10.08")
        let hlsVP9Source = LIDPlayerSource.hlsStream(url: hlsURL, variantPreferences: vp9Pref, title: "HLS VP9")
        XCTAssertEqual(engine.selectBackend(for: hlsVP9Source), .vlcKit)

        let av1Pref = HLSVariantSelectionPreferences(preferredCodecPrefix: "av01.0.04M.08")
        let hlsAV1Source = LIDPlayerSource.hlsStream(url: hlsURL, variantPreferences: av1Pref, title: "HLS AV1")
        XCTAssertEqual(engine.selectBackend(for: hlsAV1Source), .vlcKit)

        // 3. DASH manifest -> VLCKit
        let dashURL = URL(string: "https://stream.example.com/manifest.mpd")!
        let dashSource = LIDPlayerSource.dashStream(manifestURL: dashURL, selectedRepresentationID: nil, title: "DASH")
        XCTAssertEqual(engine.selectBackend(for: dashSource), .vlcKit)

        // 4. BitTorrent swarm stream -> AVFoundation (resource loader bridge)
        let torrentSource = LIDPlayerSource.torrentSwarm(infoHash: "abcdef0123456789", fileIndex: 0, title: "Torrent Stream")
        XCTAssertEqual(engine.selectBackend(for: torrentSource), .avFoundation)

        // 5. Direct MP4 network stream -> AVFoundation
        let mp4URL = URL(string: "https://stream.example.com/movie.mp4")!
        let mp4Source = LIDPlayerSource.networkStream(url: mp4URL, headers: [:], title: "MP4 Stream")
        XCTAssertEqual(engine.selectBackend(for: mp4Source), .avFoundation)

        // 6. Direct MKV network stream -> VLCKit
        let mkvURL = URL(string: "https://stream.example.com/movie.mkv")!
        let mkvSource = LIDPlayerSource.networkStream(url: mkvURL, headers: [:], title: "MKV Stream")
        XCTAssertEqual(engine.selectBackend(for: mkvSource), .vlcKit)

        // 7. Local media file -> VLCKit
        let localURL = URL(fileURLWithPath: "/tmp/sample.mp4")
        let localSource = LIDPlayerSource.localFile(url: localURL, title: "Local")
        XCTAssertEqual(engine.selectBackend(for: localSource), .vlcKit)
    }

    // MARK: - 10/10 Action 3: Stream Quality Rendition Tracking and Selection

    @MainActor
    func testStreamQualityOptionTrackingAndEngineSelection() {
        let engine = LIDPlaybackEngine.shared
        let trackManager = engine.trackManager
        trackManager.reset()

        XCTAssertTrue(trackManager.availableQualityOptions.isEmpty)
        XCTAssertNil(trackManager.selectedQualityOption)

        let opt1080 = StreamQualityOption(
            id: "quality-1080p",
            label: "1080p Full HD",
            qualityBadge: "1080p",
            resolution: HLSResolution(width: 1920, height: 1080),
            bandwidth: 4_500_000,
            bitrateText: "4.5 Mbps",
            uri: URL(string: "https://stream.example.com/1080p.m3u8")!
        )

        let opt720 = StreamQualityOption(
            id: "quality-720p",
            label: "720p HD",
            qualityBadge: "720p",
            resolution: HLSResolution(width: 1280, height: 720),
            bandwidth: 2_200_000,
            bitrateText: "2.2 Mbps",
            uri: URL(string: "https://stream.example.com/720p.m3u8")!
        )

        trackManager.setAvailableQualityOptions([opt1080, opt720])
        XCTAssertEqual(trackManager.availableQualityOptions.count, 2)

        // Explicit selection
        engine.selectQualityOption(opt1080)
        XCTAssertEqual(trackManager.selectedQualityOption?.id, "quality-1080p")
        XCTAssertEqual(trackManager.selectedQualityOption?.bandwidth, 4_500_000)

        // Switch to 720p
        engine.selectQualityOption(opt720)
        XCTAssertEqual(trackManager.selectedQualityOption?.id, "quality-720p")
        XCTAssertEqual(trackManager.selectedQualityOption?.bandwidth, 2_200_000)

        // Switch to auto (nil)
        engine.selectQualityOption(nil)
        XCTAssertNil(trackManager.selectedQualityOption)

        // Reset clears quality options
        trackManager.reset()
        XCTAssertTrue(trackManager.availableQualityOptions.isEmpty)
        XCTAssertNil(trackManager.selectedQualityOption)
    }

    // MARK: - 10/10 Action 4: Audio Track and Subtitle Preservation

    @MainActor
    func testAudioAndSubtitleTrackPreservation() {
        let engine = LIDPlaybackEngine.shared
        let trackManager = engine.trackManager
        trackManager.reset()

        let audioEn = LIDAudioTrack(id: "en", displayName: "English", languageCode: "en", isDefault: true)
        let audioFr = LIDAudioTrack(id: "fr", displayName: "French", languageCode: "fr", isDefault: false)

        let subEn = LIDSubtitleTrack(id: "sub-en", displayName: "English [CC]", languageCode: "en")
        let subEs = LIDSubtitleTrack(id: "sub-es", displayName: "Spanish", languageCode: "es")

        trackManager.updateAvailableTracks(
            audioTracks: [audioEn, audioFr],
            subtitleTracks: [subEn, subEs]
        )

        // Initial default audio is selected
        XCTAssertEqual(trackManager.selectedAudioTrack?.id, "en")
        XCTAssertEqual(trackManager.selectedSubtitleTrack.id, "off")

        // User selects French audio and English subtitles
        engine.selectAudioTrack(audioFr)
        engine.selectSubtitleTrack(subEn)

        XCTAssertEqual(trackManager.selectedAudioTrack?.id, "fr")
        XCTAssertEqual(trackManager.selectedSubtitleTrack.id, "sub-en")

        // Simulating second track update (e.g. orientation redraw or stream format refresh) retains selection
        trackManager.updateAvailableTracks(
            audioTracks: [audioEn, audioFr],
            subtitleTracks: [subEn, subEs]
        )

        XCTAssertEqual(trackManager.selectedAudioTrack?.id, "fr", "Selected audio track must be preserved across updates")
        XCTAssertEqual(trackManager.selectedSubtitleTrack.id, "sub-en", "Selected subtitle track must be preserved across updates")
    }
}
