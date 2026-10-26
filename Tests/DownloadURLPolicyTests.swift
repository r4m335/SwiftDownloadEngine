import XCTest
@testable import DM_Reverse_engineering

final class DownloadURLPolicyTests: XCTestCase {

    func testClassifyDirectHTTPAndHTTPS() {
        let httpURL = URL(string: "http://example.com/file.mp4")!
        let httpsURL = URL(string: "https://cdn.example.com/stream.m3u8")!

        XCTAssertEqual(DownloadURLPolicy.classify(httpURL), .directHTTP(httpURL))
        XCTAssertEqual(DownloadURLPolicy.classify(httpsURL), .directHTTP(httpsURL))
    }

    func testClassifyBlobURLsRequireBlobCaptureService() {
        let blobURL = URL(string: "blob:https://goplay.su/1234-5678-90ab")!
        XCTAssertEqual(DownloadURLPolicy.classify(blobURL), .mustUseBlobCaptureService(blobURL))
    }

    func testClassifyUnsupportedSchemes() {
        let ftpURL = URL(string: "ftp://example.com/file.zip")!
        let dataURL = URL(string: "data:text/plain;base64,SGVsbG8=")!
        let fileURL = URL(string: "file:///var/mobile/file.txt")!

        XCTAssertEqual(DownloadURLPolicy.classify(ftpURL), .unsupported(scheme: "ftp", raw: ftpURL))
        XCTAssertEqual(DownloadURLPolicy.classify(dataURL), .unsupported(scheme: "data", raw: dataURL))
        XCTAssertEqual(DownloadURLPolicy.classify(fileURL), .unsupported(scheme: "file", raw: fileURL))
    }

    func testClassifyEmptyHostIsUnsupported() {
        let noHostURL = URL(string: "http:///path/without/host")!
        XCTAssertEqual(DownloadURLPolicy.classify(noHostURL), .unsupported(scheme: "http", raw: noHostURL))
    }
}
