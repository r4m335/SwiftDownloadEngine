import Foundation

/// Classifies navigation responses in the browser to distinguish between streaming
/// manifests (HLS / DASH), ordinary file downloads, and normal navigatable webpages.
public struct BrowserNavigationResponseClassifier: Sendable {

    public struct Outcome: Equatable, Sendable {
        public let isStreamingManifest: Bool
        public let manifestKind: StreamingManifestKind
        public let resource: WebpageResource?
        public let shouldInterceptAsDownload: Bool
        public let suggestedFilename: String?
        public let reason: String

        public init(
            isStreamingManifest: Bool,
            manifestKind: StreamingManifestKind,
            resource: WebpageResource?,
            shouldInterceptAsDownload: Bool,
            suggestedFilename: String?,
            reason: String
        ) {
            self.isStreamingManifest = isStreamingManifest
            self.manifestKind = manifestKind
            self.resource = resource
            self.shouldInterceptAsDownload = shouldInterceptAsDownload
            self.suggestedFilename = suggestedFilename
            self.reason = reason
        }
    }

    /// Evaluates an HTTP navigation response.
    public static func evaluate(
        url: URL,
        statusCode: Int,
        contentDisposition: String? = nil,
        contentType: String? = nil,
        canShowMIMEType: Bool? = nil
    ) -> Outcome {
        // 1. Clean and normalize content type
        let cleanMIME = contentType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // 2. Classify streaming manifest metadata (HLS vs DASH)
        let manifestClassification = StreamingManifestClassifier.classify(
            url: url,
            mimeType: contentType
        )

        let isHLS = manifestClassification.kind == .hls ||
            url.pathExtension.lowercased() == "m3u8" ||
            cleanMIME?.contains("application/vnd.apple.mpegurl") == true ||
            cleanMIME?.contains("application/x-mpegurl") == true ||
            (cleanMIME != nil && StreamingManifestClassifier.hlsMIMETypes.contains(cleanMIME!))

        let isDASH = manifestClassification.kind == .dash ||
            url.pathExtension.lowercased() == "mpd" ||
            cleanMIME?.contains("dash+xml") == true ||
            cleanMIME?.contains("mpeg.dash.mpd") == true ||
            (cleanMIME != nil && StreamingManifestClassifier.dashMIMETypes.contains(cleanMIME!))

        let isStreaming = isHLS || isDASH

        if isStreaming {
            let kind: StreamingManifestKind = isDASH ? .dash : .hls
            let defaultName = isDASH ? "manifest.mpd" : "playlist.m3u8"
            let defaultMIME = isDASH ? "application/dash+xml" : "application/vnd.apple.mpegurl"
            let trimmedName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            let filename = trimmedName.isEmpty ? defaultName : trimmedName

            let resource = WebpageResource(
                url: url,
                title: filename,
                suggestedFilename: filename,
                resourceType: .video,
                mimeType: contentType ?? defaultMIME
            )

            // Streaming manifests must NEVER be intercepted as ordinary flat downloads.
            return Outcome(
                isStreamingManifest: true,
                manifestKind: kind,
                resource: resource,
                shouldInterceptAsDownload: false,
                suggestedFilename: filename,
                reason: isDASH
                    ? "DASH manifest identified (.mpd / dash+xml). Routed to streaming orchestrator."
                    : "HLS manifest identified (.m3u8 / mpegurl). Routed to streaming orchestrator."
            )
        }

        // 3. Not a streaming manifest: evaluate ordinary download classification
        let downloadClassification = BrowserDownloadClassifier.classify(
            url: url,
            statusCode: statusCode,
            contentDisposition: contentDisposition,
            mimeType: contentType,
            canShowMIMEType: canShowMIMEType
        )

        return Outcome(
            isStreamingManifest: false,
            manifestKind: .unknown,
            resource: nil,
            shouldInterceptAsDownload: downloadClassification.isDownload,
            suggestedFilename: downloadClassification.suggestedFilename,
            reason: downloadClassification.reason
        )
    }
}

