import Foundation
import XCTest
@testable import DM_Reverse_engineering

final class MagnetLinkTests: XCTestCase {

    func testParsesV1MagnetMetadataAndPreservesTrackerQuery() throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let magnet = "magnet:?xt=urn:btih:\(hash)&dn=Example%20Movie&xl=123456&tr=https%3A%2F%2Ftracker.example%2Fannounce%3Ftoken%3Dprivate&ws=https%3A%2F%2Fcdn.example%2Fmovie.iso"

        let parsed = try MagnetLinkParser.parse(magnet)

        XCTAssertEqual(parsed.primaryInfoHash.kind, .bitTorrentV1)
        XCTAssertEqual(parsed.primaryInfoHash.value, hash)
        XCTAssertEqual(parsed.displayName, "Example Movie")
        XCTAssertEqual(parsed.contentLength, 123456)
        XCTAssertEqual(parsed.trackerURLs.first?.absoluteString, "https://tracker.example/announce?token=private")
        XCTAssertEqual(parsed.webSeedURLs.first?.absoluteString, "https://cdn.example/movie.iso")
        XCTAssertEqual(parsed.presentationName, "Example Movie")
    }

    func testParsesMultipleV1AndV2ExactTopics() throws {
        let v1 = "0123456789abcdef0123456789abcdef01234567"
        let v2 = "1220" + String(repeating: "ab", count: 32)
        let parsed = try MagnetLinkParser.parse(
            "magnet:?xt=urn:btih:\(v1)&xt=urn:btmh:\(v2)&dn=Multi"
        )

        XCTAssertEqual(parsed.infoHashes.map(\.kind), [.bitTorrentV1, .bitTorrentV2])
        XCTAssertEqual(parsed.infoHashes[1].value, v2)
    }

    func testParsesBase32V1HashWithoutDisplayName() throws {
        let parsed = try MagnetLinkParser.parse(
            "magnet:?xt=urn:btih:ABCDEFGHIJKLMNOP234567ABCDEFGHEF"
        )

        XCTAssertEqual(parsed.primaryInfoHash.kind, .bitTorrentV1)
        XCTAssertEqual(parsed.primaryInfoHash.value, "ABCDEFGHIJKLMNOP234567ABCDEFGHEF")
        XCTAssertTrue(parsed.presentationName.hasPrefix("Torrent "))
    }

    func testRejectsMissingMalformedAndUnsupportedHashes() {
        let cases = [
            "magnet:?dn=NoHash",
            "magnet:?xt=urn:btih:not-a-hash",
            "magnet:?xt=urn:btpk:0123456789abcdef"
        ]

        for value in cases {
            XCTAssertThrowsError(try MagnetLinkParser.parse(value)) { error in
                XCTAssertFalse(error.localizedDescription.contains("NoHash"))
                XCTAssertFalse(error.localizedDescription.contains("not-a-hash"))
            }
        }
    }

    func testRejectsUnsupportedSchemeAndUnsafeTrackerCredentials() {
        XCTAssertThrowsError(try MagnetLinkParser.parse("https://example.com/file")) { error in
            XCTAssertEqual(error as? MagnetLinkError, .invalidScheme)
        }

        let unsafeTracker = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=https%3A%2F%2Fuser%3Asecret%40tracker.example%2Fannounce"
        XCTAssertThrowsError(try MagnetLinkParser.parse(unsafeTracker)) { error in
            XCTAssertEqual(error as? MagnetLinkError, .malformedTracker)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testRejectsMalformedWebSeedAndContentLength() {
        let invalidWebSeed = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&ws=ftp%3A%2F%2Fcdn.example%2Ffile"
        XCTAssertThrowsError(try MagnetLinkParser.parse(invalidWebSeed)) { error in
            XCTAssertEqual(error as? MagnetLinkError, .malformedWebSeed)
        }

        let invalidLength = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&xl=-1"
        XCTAssertThrowsError(try MagnetLinkParser.parse(invalidLength)) { error in
            XCTAssertEqual(error as? MagnetLinkError, .invalidContentLength)
        }
    }

    func testMetadataLengthIsBounded() {
        let longName = String(repeating: "x", count: MagnetLinkParser.maximumDisplayNameLength + 1)
        let encodedName = longName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=\(encodedName)"

        XCTAssertThrowsError(try MagnetLinkParser.parse(magnet)) { error in
            XCTAssertEqual(error as? MagnetLinkError, .parameterTooLong)
        }
    }

    #if canImport(SwiftUI)
    @MainActor
    func testBrowserConfirmationHandsValidatedMagnetToTorrentDelegate() async throws {
        let delegate = MockMagnetDelegate()
        let viewModel = BrowserViewModel(magnetDelegate: delegate)
        let magnet = try MagnetLinkParser.parse(
            "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Demo"
        )

        viewModel.presentMagnetLink(
            magnet,
            sourcePageURL: URL(string: "https://torrent.example/details")
        )
        XCTAssertTrue(viewModel.isShowingMagnetSheet)
        XCTAssertEqual(viewModel.magnetCandidate?.presentationName, "Demo")

        try await viewModel.confirmMagnetLink()

        XCTAssertFalse(viewModel.isShowingMagnetSheet)
        XCTAssertEqual(delegate.received?.uri, magnet.uri)
    }

    @MainActor
    private final class MockMagnetDelegate: BrowserMagnetDelegate {
        let isTorrentEngineAvailable = true
        var received: MagnetLink?

        func handleMagnetLink(_ magnet: MagnetLink) async throws {
            received = magnet
        }
    }
    #endif
}
