import Foundation

/// Defines the actionable execution route for a browser media candidate or webpage resource.
public enum BrowserDownloadAction: Sendable, Equatable {
    /// Ranged or direct HTTP/HTTPS download via DownloadEngine
    case direct(
        url: URL,
        suggestedFilename: String,
        mimeType: String?,
        estimatedSize: Int64?,
        requestContext: BrowserRequestContext?
    )

    /// Streaming manifest (HLS or DASH) via StreamingDownloadOrchestrator
    case streaming(
        manifestURL: URL,
        manifestKind: StreamingManifestKind,
        suggestedFilename: String,
        cachedManifestText: String?,
        requestContext: BrowserRequestContext?
    )

    /// Bounded in-browser export of an in-memory Blob via BrowserBlobCaptureService
    case blobExport(
        candidate: BrowserMediaCandidate
    )

    /// Native fragmented-MP4 capture of MediaSource appends via BrowserMSECapturePrototype
    case mseCapture(
        candidate: BrowserMediaCandidate
    )

    /// DRM-protected stream (e.g. FairPlay, Widevine, PlayReady, EME) - strictly rejected
    case protectedMedia(
        reason: String
    )

    /// Unsupported format, streaming chunk, or incomplete metadata
    case unsupported(
        reason: String
    )
}

/// The result of evaluating a candidate or resource through the decision pipeline.
public struct BrowserDownloadDecision: Sendable, Equatable {
    public let action: BrowserDownloadAction
    public let candidate: BrowserMediaCandidate
    public let associatedManifestURL: URL?
    public let reason: String

    public init(
        action: BrowserDownloadAction,
        candidate: BrowserMediaCandidate,
        associatedManifestURL: URL? = nil,
        reason: String
    ) {
        self.action = action
        self.candidate = candidate
        self.associatedManifestURL = associatedManifestURL
        self.reason = reason
    }
}

/// A centralized, deterministic decision engine that connects all browser media discoveries
/// (Direct HTTP, HLS, DASH, Blob, MSE, and DRM) into a single reliable execution pipeline.
public enum BrowserDownloadDecisionPipeline {
    /// Evaluates a candidate within the current page and candidate catalog context,
    /// resolving the single authoritative download action.
    public static func decide(
        candidate: BrowserMediaCandidate,
        availableResources: [WebpageResource] = [],
        availableCandidates: [BrowserMediaCandidate] = [],
        preferManifestIfAvailable: Bool = true
    ) -> BrowserDownloadDecision {
        // 1. DRM / Protected Media: Strict upfront rejection
        if candidate.kind == .protectedMedia ||
           candidate.evidence.contains(where: {
               let lower = $0.lowercased()
               return lower.contains("protected") || lower.contains("drm") || lower.contains("encrypted")
           }) {
            let reason = candidate.evidence.first(where: {
                let lower = $0.lowercased()
                return lower.contains("protected") || lower.contains("drm") || lower.contains("encrypted")
            }) ?? "This media stream is DRM-protected and cannot be downloaded or captured."
            return BrowserDownloadDecision(
                action: .protectedMedia(reason: reason),
                candidate: candidate,
                reason: reason
            )
        }

        // 2. Streaming Manifests (HLS / DASH)
        if candidate.kind == .hlsManifest {
            guard let url = candidate.url ?? URL(string: candidate.rawURL),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return BrowserDownloadDecision(
                    action: .unsupported(reason: "HLS manifest URL is missing or has an unsupported scheme."),
                    candidate: candidate,
                    reason: "Invalid HLS manifest URL"
                )
            }
            return BrowserDownloadDecision(
                action: .streaming(
                    manifestURL: url,
                    manifestKind: .hls,
                    suggestedFilename: candidate.suggestedFilename,
                    cachedManifestText: candidate.cachedManifestText,
                    requestContext: candidate.requestContext
                ),
                candidate: candidate,
                associatedManifestURL: url,
                reason: "Direct HLS manifest transfer via StreamingDownloadOrchestrator"
            )
        }

        if candidate.kind == .dashManifest {
            guard let url = candidate.url ?? URL(string: candidate.rawURL),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return BrowserDownloadDecision(
                    action: .unsupported(reason: "DASH manifest URL is missing or has an unsupported scheme."),
                    candidate: candidate,
                    reason: "Invalid DASH manifest URL"
                )
            }
            return BrowserDownloadDecision(
                action: .streaming(
                    manifestURL: url,
                    manifestKind: .dash,
                    suggestedFilename: candidate.suggestedFilename,
                    cachedManifestText: candidate.cachedManifestText,
                    requestContext: candidate.requestContext
                ),
                candidate: candidate,
                associatedManifestURL: url,
                reason: "Direct DASH manifest transfer via StreamingDownloadOrchestrator"
            )
        }

        // 3. MediaSource (MSE)
        let isMediaSource = candidate.kind == .mediaSource || candidate.blobKind == .mediaSource
        if isMediaSource {
            // Check manifest precedence if preference is enabled
            if preferManifestIfAvailable {
                if let manifestURL = findAssociatedManifestURL(candidate: candidate, availableResources: availableResources, availableCandidates: availableCandidates) {
                    let isDash = manifestURL.pathExtension.lowercased() == "mpd"
                    return BrowserDownloadDecision(
                        action: .streaming(
                            manifestURL: manifestURL,
                            manifestKind: isDash ? .dash : .hls,
                            suggestedFilename: candidate.suggestedFilename.isEmpty ? "stream.mp4" : candidate.suggestedFilename,
                            cachedManifestText: candidate.cachedManifestText,
                            requestContext: candidate.requestContext
                        ),
                        candidate: candidate,
                        associatedManifestURL: manifestURL,
                        reason: "Precedence: using associated \(isDash ? "DASH" : "HLS") manifest instead of MSE stream buffer"
                    )
                }
            }

            // Fallback or explicit MSE capture
            let support = BrowserMSECaptureSupportClassifier.evaluate(
                mimeType: candidate.mimeType,
                isPotentiallyProtected: false
            )
            switch support.status {
            case .capturable:
                guard candidate.rawURL.lowercased().hasPrefix("blob:") else {
                    return BrowserDownloadDecision(
                        action: .unsupported(reason: "Waiting for MediaSource object URL before capture can begin."),
                        candidate: candidate,
                        reason: "MediaSource object URL not yet bound"
                    )
                }
                return BrowserDownloadDecision(
                    action: .mseCapture(candidate: candidate),
                    candidate: candidate,
                    reason: "Clear fragmented-MP4 MediaSource capturable via BrowserMSECapturePrototype"
                )
            case .protectedMedia:
                return BrowserDownloadDecision(
                    action: .protectedMedia(reason: support.reason),
                    candidate: candidate,
                    reason: support.reason
                )
            case .unsupported:
                let reason = candidate.mimeType == nil
                    ? "MediaSource observed without known MIME type. Waiting for SourceBuffer metadata."
                    : support.reason
                return BrowserDownloadDecision(
                    action: .unsupported(reason: reason),
                    candidate: candidate,
                    reason: reason
                )
            }
        }

        // 4. Standalone Blob (.completeBlob)
        if candidate.kind == .completeBlob {
            guard candidate.rawURL.lowercased().hasPrefix("blob:") else {
                return BrowserDownloadDecision(
                    action: .unsupported(reason: "Blob candidate has invalid URL scheme."),
                    candidate: candidate,
                    reason: "Invalid Blob URL"
                )
            }
            if candidate.availability == .unsupported {
                return BrowserDownloadDecision(
                    action: .unsupported(reason: "Blob resource is unsupported or exceeds browser limits."),
                    candidate: candidate,
                    reason: "Unsupported Blob"
                )
            }
            return BrowserDownloadDecision(
                action: .blobExport(candidate: candidate),
                candidate: candidate,
                reason: "In-memory Blob export via BrowserBlobCaptureService"
            )
        }

        // 5. Direct Media / Direct File
        if candidate.kind == .directMedia || candidate.kind == .directFile {
            guard let url = candidate.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return BrowserDownloadDecision(
                    action: .unsupported(reason: "Resource URL is missing or has an unsupported scheme."),
                    candidate: candidate,
                    reason: "Invalid HTTP(S) URL"
                )
            }

            // Check if this direct resource is a segment chunk of a known manifest
            if isSegmentChunk(candidate: candidate, availableResources: availableResources) {
                if let manifestURL = findAssociatedManifestURL(candidate: candidate, availableResources: availableResources, availableCandidates: availableCandidates) {
                    let isDash = manifestURL.pathExtension.lowercased() == "mpd"
                    return BrowserDownloadDecision(
                        action: .streaming(
                            manifestURL: manifestURL,
                            manifestKind: isDash ? .dash : .hls,
                            suggestedFilename: candidate.suggestedFilename,
                            cachedManifestText: nil,
                            requestContext: candidate.requestContext
                        ),
                        candidate: candidate,
                        associatedManifestURL: manifestURL,
                        reason: "Segment chunk redirected to parent streaming manifest"
                    )
                }
                return BrowserDownloadDecision(
                    action: .unsupported(reason: "This is an internal streaming segment chunk (.ts/.m4s). Download the playlist manifest (.m3u8/.mpd) instead."),
                    candidate: candidate,
                    reason: "Standalone segment chunk cannot be played independently"
                )
            }

            return BrowserDownloadDecision(
                action: .direct(
                    url: url,
                    suggestedFilename: candidate.suggestedFilename,
                    mimeType: candidate.mimeType,
                    estimatedSize: candidate.estimatedSize,
                    requestContext: candidate.requestContext
                ),
                candidate: candidate,
                reason: "Direct HTTP transfer via DownloadEngine"
            )
        }

        // 6. Fallback
        return BrowserDownloadDecision(
            action: .unsupported(reason: "Candidate kind '\(candidate.kind.rawValue)' cannot be resolved to a downloadable route."),
            candidate: candidate,
            reason: "Unknown candidate kind"
        )
    }

    /// Resolves a decision from a WebpageResource, looking up any existing catalog candidate or classifying on the fly.
    public static func decide(
        resource: WebpageResource,
        availableResources: [WebpageResource] = [],
        availableCandidates: [BrowserMediaCandidate] = [],
        preferManifestIfAvailable: Bool = true
    ) -> BrowserDownloadDecision {
        let matchedCandidate = availableCandidates.first { cand in
            cand.id == resource.id ||
            cand.rawURL.caseInsensitiveCompare(resource.url.absoluteString) == .orderedSame ||
            (cand.url != nil && cand.url == resource.url)
        }
        let candidate: BrowserMediaCandidate
        if let matchedCandidate {
            candidate = matchedCandidate
        } else {
            candidate = BrowserMediaCandidateClassifier.classify(resource: resource)
        }
        return decide(
            candidate: candidate,
            availableResources: availableResources,
            availableCandidates: availableCandidates,
            preferManifestIfAvailable: preferManifestIfAvailable
        )
    }

    private static func findAssociatedManifestURL(
        candidate: BrowserMediaCandidate,
        availableResources: [WebpageResource],
        availableCandidates: [BrowserMediaCandidate]
    ) -> URL? {
        if let url = candidate.associatedManifestURL {
            return url
        }
        if let matchingCand = availableCandidates.first(where: {
            $0.associatedManifestURL != nil && ($0.id == candidate.id || $0.rawURL.caseInsensitiveCompare(candidate.rawURL) == .orderedSame)
        })?.associatedManifestURL {
            return matchingCand
        }
        if let manifestCandidate = availableCandidates.first(where: {
            ($0.kind == .hlsManifest || $0.kind == .dashManifest) && $0.url != nil
        }), let url = manifestCandidate.url {
            return url
        }
        if let manifestResource = availableResources.first(where: { $0.isStreamingManifest }) {
            return manifestResource.url
        }
        return nil
    }

    private static func isSegmentChunk(
        candidate: BrowserMediaCandidate,
        availableResources: [WebpageResource]
    ) -> Bool {
        if let res = availableResources.first(where: { $0.id == candidate.id || (candidate.url != nil && $0.url == candidate.url) }) {
            if res.isSegmentChunk { return true }
        }
        guard let url = candidate.url else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "ts" || ext == "m4s" { return true }
        if let mime = candidate.mimeType?.lowercased(), mime.contains("mp2t") || mime.contains("iso.segment") {
            return true
        }
        return false
    }
}

