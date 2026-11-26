import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Visual status dot for Resource Grabber items matching an existing transfer.
/// Strictly minimal: 🟢 downloading, 🔴 failed, 🟠 paused, 🔵 completed, nil if new.
public enum DownloadStatusDot: String, Equatable, Sendable {
    case downloading
    case failed
    case paused
    case completed

    #if canImport(SwiftUI)
    public var color: Color {
        switch self {
        case .downloading:
            return Color.green
        case .failed:
            return Color.red
        case .paused:
            return Color.orange
        case .completed:
            return Color.blue
        }
    }
    #endif
}

public enum MatchConfidence: String, Equatable, Sendable {
    case exactURL
    case normalizedURL
    case renditionAndFilename
    case filenameAndOrigin
}

public struct DownloadMatchResult: Equatable, Sendable {
    public let transferID: String
    public let statusDot: DownloadStatusDot
    public let confidence: MatchConfidence

    public init(
        transferID: String,
        statusDot: DownloadStatusDot,
        confidence: MatchConfidence
    ) {
        self.transferID = transferID
        self.statusDot = statusDot
        self.confidence = confidence
    }
}

/// Matches captured browser resources against existing active and persisted downloads.
/// Handles dynamic signed URLs, ephemeral tokens, and HLS variant renditions.
public struct BrowserDownloadMatcher: Sendable {
    private static let ephemeralQueryKeys: Set<String> = [
        "exp", "expires", "token", "sig", "signature", "key", "auth",
        "Expires", "Signature", "Key-Pair-Id", "h", "t", "ttl", "v", "tid",
        "se", "sp", "sv", "sr", "st"
    ]

    public init() {}

    /// Evaluates a WebpageResource against a list of unified transfers to find existing download records.
    public func match(
        resource: WebpageResource,
        transfers: [UnifiedTransfer]
    ) -> DownloadMatchResult? {
        // Exclude internal segment chunks from matching parent transfers
        if resource.isSegmentChunk { return nil }

        for transfer in transfers {
            // Check 1: Exact URL match
            if let transferURL = URL(string: transfer.source) {
                if transferURL.absoluteString.caseInsensitiveCompare(resource.url.absoluteString) == .orderedSame {
                    let dot = dotForState(transfer.state)
                    return DownloadMatchResult(transferID: transfer.id, statusDot: dot, confidence: .exactURL)
                }

                // Check 2: Normalized URL match (scheme + host + path, ignoring ephemeral signed tokens)
                if areNormalizedURLsEqual(transferURL, resource.url) {
                    // For HLS variants, also verify rendition/quality match
                    if transfer.type == .hls || resource.isStreamingManifest {
                        if matchesHLSRendition(resource: resource, transfer: transfer) {
                            let dot = dotForState(transfer.state)
                            return DownloadMatchResult(transferID: transfer.id, statusDot: dot, confidence: .normalizedURL)
                        }
                    } else {
                        let dot = dotForState(transfer.state)
                        return DownloadMatchResult(transferID: transfer.id, statusDot: dot, confidence: .normalizedURL)
                    }
                }
            }

            // Check 3: HLS Rendition & Filename matching (when URLs differ due to refreshed master manifest)
            if (transfer.type == .hls || resource.isStreamingManifest),
               let transferURL = URL(string: transfer.source),
               let tHost = transferURL.host?.lowercased(),
               let rHost = resource.url.host?.lowercased(),
               tHost == rHost,
               !isGenericMediaStem(resource.suggestedFilename),
               matchesHLSRendition(resource: resource, transfer: transfer) {
                let dot = dotForState(transfer.state)
                return DownloadMatchResult(transferID: transfer.id, statusDot: dot, confidence: .renditionAndFilename)
            }

            // Check 4: Filename and Host matching for ordinary HTTP media
            if transfer.type == .http && !resource.isStreamingManifest {
                if matchesFilenameAndHost(resource: resource, transfer: transfer) {
                    let dot = dotForState(transfer.state)
                    return DownloadMatchResult(transferID: transfer.id, statusDot: dot, confidence: .filenameAndOrigin)
                }
            }
        }

        return nil
    }

    /// Normalizes URLs by comparing scheme, host, and path while removing common signed query tokens.
    public func areNormalizedURLsEqual(_ urlA: URL, _ urlB: URL) -> Bool {
        guard urlA.scheme?.lowercased() == urlB.scheme?.lowercased(),
              urlA.host?.lowercased() == urlB.host?.lowercased(),
              urlA.path.lowercased() == urlB.path.lowercased() else {
            return false
        }

        // Compare non-ephemeral query items
        let queryA = filteredQueryItems(from: urlA)
        let queryB = filteredQueryItems(from: urlB)
        return queryA == queryB
    }

    private func filteredQueryItems(from url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return [:]
        }
        var dict: [String: String] = [:]
        for item in items {
            let key = item.name.lowercased()
            if !Self.ephemeralQueryKeys.contains(key) && !Self.ephemeralQueryKeys.contains(item.name) {
                dict[key] = item.value ?? ""
            }
        }
        return dict
    }

    /// Validates whether a resource's HLS variant quality matches a transfer.
    /// Crucial safety rule: Never match 1080p if existing download is 480p!
    private func matchesHLSRendition(resource: WebpageResource, transfer: UnifiedTransfer) -> Bool {
        let transferName = transfer.name.lowercased()

        // Extract quality height from candidate resource
        var candidateHeight: Int? = nil
        if let hlsPrefs = resource.hlsVariantPreferences {
            candidateHeight = hlsPrefs.maximumHeight
        }

        // Extract quality height from existing transfer filename (e.g. "video-480p.mp4")
        var transferHeight: Int? = nil
        for resolution in [2160, 1440, 1080, 720, 480, 360, 288, 240, 184] {
            if transferName.contains("\(resolution)p") || transferName.contains("\(resolution)x") {
                transferHeight = resolution
                break
            }
        }

        if let cHeight = candidateHeight, let tHeight = transferHeight {
            if cHeight == tHeight {
                // Same quality resolution match
                return matchesFilenameStem(candidate: resource.suggestedFilename, existing: transfer.name)
            } else {
                // Different quality variant — must NOT match!
                return false
            }
        }

        // If neither specifies height explicitly, fallback to filename stem comparison
        return matchesFilenameStem(candidate: resource.suggestedFilename, existing: transfer.name)
    }

    private func matchesFilenameAndHost(resource: WebpageResource, transfer: UnifiedTransfer) -> Bool {
        guard let transferURL = URL(string: transfer.source),
              let candidateHost = resource.url.host?.lowercased(),
              let transferHost = transferURL.host?.lowercased() else {
            return false
        }

        if candidateHost != transferHost {
            return false
        }

        return matchesFilenameStem(candidate: resource.suggestedFilename, existing: transfer.name)
    }

    private func matchesFilenameStem(candidate: String, existing: String) -> Bool {
        let stemC = (candidate as NSString).deletingPathExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let stemE = (existing as NSString).deletingPathExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !stemC.isEmpty && !stemE.isEmpty && stemC != "download" && stemE != "download" else {
            return false
        }

        if stemC == stemE {
            return true
        }

        // Check if one is a prefix/suffix variant (e.g. "x36xhzz-480p" vs "x36xhzz-480p (1)")
        if stemC.contains(stemE) || stemE.contains(stemC) {
            return true
        }

        return false
    }

    private func isGenericMediaStem(_ filename: String) -> Bool {
        var stem = (filename as NSString).deletingPathExtension
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = stem.range(of: #"(?:[-_](?:\d{3,4}p|\d+x\d+|audio|subtitles?|thumbnails?))+$"#, options: .regularExpression) {
            stem.removeSubrange(range)
        }
        let genericStems: Set<String> = [
            "", "stream", "video", "audio", "media", "master", "playlist",
            "index", "manifest", "chunklist", "prog_index", "hls", "dash", "download"
        ]
        return genericStems.contains(stem)
    }

    private func dotForState(_ state: UnifiedTransferState) -> DownloadStatusDot {
        switch state {
        case .downloading, .queued:
            return .downloading
        case .paused:
            return .paused
        case .completed, .seeding:
            return .completed
        case .failed:
            return .failed
        }
    }
}
