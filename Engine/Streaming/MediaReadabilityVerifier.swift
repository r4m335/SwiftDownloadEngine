import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Protocol for verifying that a completed media download can be parsed and played.
/// Decouples media validation from test-framework checks via dependency injection.
public protocol MediaReadabilityVerifier: Sendable {
    func isMediaReadable(at fileURL: URL) async -> Bool
}

/// Default production verifier using AVFoundation asset track loading and MPEG-TS sync validation.
public struct DefaultMediaReadabilityVerifier: MediaReadabilityVerifier {
    public init() {}

    public func isMediaReadable(at fileURL: URL) async -> Bool {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: fileURL)
        let sema = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["tracks", "playable"]) {
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 3.0)
        var isReadable = false
        if #available(macOS 12.0, iOS 15.0, *) {
            isReadable = asset.isPlayable || !asset.tracks.isEmpty
        } else {
            isReadable = !asset.tracks.isEmpty
        }
        if !isReadable && fileURL.pathExtension.lowercased() == "ts" {
            if let size = FileManager.default.fileSize(atPath: fileURL.path), size > 0, size % 188 == 0 {
                isReadable = true
            }
        }
        return isReadable
        #else
        return true
        #endif
    }
}

/// Mock media verifier for testing custom pass/fail behavior without depending on disk media.
public struct MockMediaReadabilityVerifier: MediaReadabilityVerifier {
    public let result: Bool

    public init(result: Bool = true) {
        self.result = result
    }

    public func isMediaReadable(at fileURL: URL) async -> Bool {
        result
    }
}
