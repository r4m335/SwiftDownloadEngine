import XCTest
@testable import DownloadEngineKit

final class OpenSourceLicensesTests: XCTestCase {

    func testRegistryContainsAllRequiredComponents() {
        let licenses = OpenSourceLicensesRegistry.allLicenses
        let ids = Set(licenses.map { $0.id })

        XCTAssertTrue(ids.contains("swift-download-engine"), "Missing SwiftDownloadEngine MIT license entry")
        XCTAssertTrue(ids.contains("libtorrent-rasterbar"), "Missing libtorrent BSD-3-Clause license entry")
        XCTAssertTrue(ids.contains("boost-cxx-libraries"), "Missing Boost license entry")
        XCTAssertTrue(ids.contains("vlckit"), "Missing VLCKit LGPL-2.1 license entry")
        XCTAssertTrue(ids.contains("openssl"), "Missing OpenSSL license entry")
    }

    func testLibTorrentMetadataAndObligations() {
        let libtorrent = OpenSourceLicensesRegistry.libtorrent

        XCTAssertEqual(libtorrent.name, "libtorrent-rasterbar")
        XCTAssertEqual(libtorrent.version, "2.0.10")
        XCTAssertEqual(libtorrent.licenseName, "BSD 3-Clause License")
        XCTAssertEqual(libtorrent.spdxIdentifier, "BSD-3-Clause")
        XCTAssertTrue(libtorrent.copyright.contains("Arvid Norberg"))
        XCTAssertTrue(libtorrent.isLinked)
        XCTAssertFalse(libtorrent.isDynamicallyLinked)
        XCTAssertFalse(libtorrent.summary.isEmpty)
        XCTAssertNotNil(libtorrent.sourceURL)
    }

    func testBoostMetadata() {
        let boost = OpenSourceLicensesRegistry.boost

        XCTAssertEqual(boost.name, "Boost C++ Libraries")
        XCTAssertEqual(boost.spdxIdentifier, "BSL-1.0")
        XCTAssertTrue(boost.isLinked)
        XCTAssertTrue(boost.complianceNotes?.contains("Header-only") ?? false)
    }

    func testVLCKitLGPLEmbeddingAndObligations() {
        let vlckit = OpenSourceLicensesRegistry.vlckit

        XCTAssertEqual(vlckit.name, "VLCKit & libVLC")
        XCTAssertEqual(vlckit.spdxIdentifier, "LGPL-2.1-only")
        XCTAssertTrue(vlckit.copyright.contains("VideoLAN"))
        XCTAssertTrue(vlckit.copyright.contains("Free Software Foundation"))

        // VLCKit LGPL Obligations:
        // 1. Dynamic framework linking for user replaceability
        XCTAssertTrue(vlckit.isDynamicallyLinked, "VLCKit must be dynamically linked for user replaceability")
        // 2. Official LGPL build verification
        XCTAssertTrue(vlckit.isOfficialLGPLBuild, "VLCKit must use official LGPL build")
        // 3. Source repository link availability
        XCTAssertEqual(vlckit.sourceURL, "https://code.videolan.org/videolan/VLCKit")
        XCTAssertTrue(vlckit.complianceNotes?.contains("VLCKit.framework") ?? false)
    }

    func testOpenSSLStatusNotLinked() {
        let openssl = OpenSourceLicensesRegistry.openssl

        XCTAssertEqual(openssl.spdxIdentifier, "Apache-2.0")
        XCTAssertFalse(openssl.isLinked, "OpenSSL is not linked into the iOS build")
        XCTAssertTrue(openssl.complianceNotes?.contains("CMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE") ?? false)
    }

    func testLinkedLicensesFilter() {
        let linked = OpenSourceLicensesRegistry.linkedLicenses
        let unlinked = OpenSourceLicensesRegistry.allLicenses.filter { !$0.isLinked }

        XCTAssertEqual(unlinked.count, 1)
        XCTAssertEqual(unlinked.first?.id, "openssl")
        XCTAssertFalse(linked.contains(where: { $0.id == "openssl" }))
        XCTAssertTrue(linked.contains(where: { $0.id == "libtorrent-rasterbar" }))
        XCTAssertTrue(linked.contains(where: { $0.id == "vlckit" }))
        XCTAssertTrue(linked.contains(where: { $0.id == "boost-cxx-libraries" }))
        XCTAssertTrue(linked.contains(where: { $0.id == "swift-download-engine" }))
    }

    func testOpenSourceLicenseCodableRoundTrip() throws {
        let original = OpenSourceLicensesRegistry.vlckit
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpenSourceLicense.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.spdxIdentifier, original.spdxIdentifier)
        XCTAssertEqual(decoded.copyright, original.copyright)
        XCTAssertEqual(decoded.isDynamicallyLinked, original.isDynamicallyLinked)
        XCTAssertEqual(decoded.isOfficialLGPLBuild, original.isOfficialLGPLBuild)
    }
}
