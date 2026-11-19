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
        do {
            let isPlayable = try await asset.load(.isPlayable)
            let tracks = try await asset.load(.tracks)
            if isPlayable || !tracks.isEmpty {
                return true
            }
        } catch {
            PipelineLogger.shared.log(stage: .assembler, message: "AVURLAsset load failed for \(fileURL.lastPathComponent): \(error)")
        }

        if fileURL.pathExtension.lowercased() == "ts" {
            let validation = MediaIntegrityValidator.validateMPEGTS(fileURL: fileURL)
            return validation.isConfirmedValid
        }
        return false
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
