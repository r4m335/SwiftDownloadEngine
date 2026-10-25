import Foundation

/// The strategy suggested by a browser observation. Metadata-only signals are
/// represented explicitly so they cannot accidentally become HTTP downloads.
public enum BrowserMediaCandidateKind: String, Codable, Sendable, Equatable, Hashable {
    case directMedia
    case directFile
    case hlsManifest
    case dashManifest
    case completeBlob
    case mediaSource
    case protectedMedia
    case unknown
}

public enum BrowserMediaCandidateAvailability: String, Codable, Sendable, Equatable, Hashable {
    case downloadable
    case requiresPlanning
    case captureCandidate
    case metadataOnly
    case unsupported
    case uncertain
}

/// A unified, sanitized description of a browser media candidate.
///
/// `url` is present only for resources that can be addressed by the existing
/// HTTP/HTTPS transfer paths. Blob, MSE, and protection observations retain
/// their raw signal and metadata without inventing a server URL.
public struct BrowserMediaCandidate: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let url: URL?
    public let rawURL: String
    public let finalURL: URL?
    public let kind: BrowserMediaCandidateKind
    public let mimeType: String?
    public let suggestedFilename: String
    public let estimatedSize: Int64?
    public let availability: BrowserMediaCandidateAvailability
    public let evidence: [String]
    public let documentID: String?
    public let requestContext: BrowserRequestContext?
    public let associatedManifestID: String?
    public let lastObserved: Date

    public init(
        id: String,
        url: URL?,
        rawURL: String,
        finalURL: URL? = nil,
        kind: BrowserMediaCandidateKind,
        mimeType: String? = nil,
        suggestedFilename: String,
        estimatedSize: Int64? = nil,
        availability: BrowserMediaCandidateAvailability,
        evidence: [String] = [],
        documentID: String? = nil,
        requestContext: BrowserRequestContext? = nil,
        associatedManifestID: String? = nil,
        lastObserved: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.rawURL = rawURL
        self.finalURL = finalURL
        self.kind = kind
        self.mimeType = mimeType
        self.suggestedFilename = suggestedFilename
        self.estimatedSize = estimatedSize
        self.availability = availability
        var uniqueEvidence: [String] = []
        for item in evidence where !uniqueEvidence.contains(item) {
            uniqueEvidence.append(item)
        }
        self.evidence = uniqueEvidence
        self.documentID = documentID
        self.requestContext = requestContext
        self.associatedManifestID = associatedManifestID
        self.lastObserved = lastObserved
    }

    public var isActionable: Bool {
        availability == .downloadable || availability == .requiresPlanning || availability == .captureCandidate
    }
}

/// Pure classification and identity rules shared by DOM and dynamic browser
/// discovery. It never performs network requests or reads browser credentials.
public enum BrowserMediaCandidateClassifier {
    public static func classify(
        observation: BrowserMediaDiscoveryObservation,
        now: Date = Date()
    ) -> BrowserMediaCandidate? {
        let mime = normalizedMIME(observation.declaredType)
        let identity = stableIdentity(rawURL: observation.rawURL, url: observation.url)
        let finalURL = observation.responseURL

        if observation.source == .protection || observation.isPotentiallyProtected {
            return BrowserMediaCandidate(
                id: identity,
                url: nil,
                rawURL: observation.rawURL,
                finalURL: finalURL,
                kind: .protectedMedia,
                mimeType: mime,
                suggestedFilename: "protected_media",
                estimatedSize: observation.contentLength,
                availability: .unsupported,
                evidence: ["possible encrypted-media activity was observed"],
                documentID: observation.documentID,
                lastObserved: now
            )
        }

        if observation.source == .mediaSource {
            let support = BrowserMSECaptureSupportClassifier.evaluate(
                mimeType: mime,
                isPotentiallyProtected: false
            )
            let availability: BrowserMediaCandidateAvailability
            let evidence: [String]
            let hasMediaSourceObjectURL = observation.rawURL.lowercased().hasPrefix("blob:")
            switch support.status {
            case .capturable:
                if hasMediaSourceObjectURL {
                    availability = .captureCandidate
                    evidence = [
                        support.reason,
                        "MediaSource metadata only until an explicit capture starts"
                    ]
                } else {
                    availability = .metadataOnly
                    evidence = [
                        support.reason,
                        "Waiting for a MediaSource object URL before capture can start"
                    ]
                }
            case .protectedMedia:
                availability = .unsupported
                evidence = [support.reason]
            case .unsupported:
                if mime == nil {
                    availability = .metadataOnly
                    evidence = ["MediaSource activity was observed; wait for SourceBuffer MIME types"]
                } else {
                    availability = .unsupported
                    evidence = [support.reason]
                }
            }
            return BrowserMediaCandidate(
                id: identity,
                url: nil,
                rawURL: observation.rawURL,
                finalURL: finalURL,
                kind: .mediaSource,
                mimeType: mime,
                suggestedFilename: "media_source_capture",
                estimatedSize: observation.appendedByteCount ?? observation.contentLength,
                availability: availability,
                evidence: evidence,
                documentID: observation.documentID,
                lastObserved: now
            )
        }

        if observation.isBlobSignal {
            let isMediaTag = observation.tag?.lowercased() == "video" ||
                observation.tag?.lowercased() == "audio" ||
                observation.tag?.lowercased() == "media" ||
                observation.tag?.lowercased() == "source"
            let supportedBlob = isSupportedBlobMIME(mime) || (mime == nil && isMediaTag) || observation.source == .blob
            let hasSize = observation.contentLength != nil
            let availability: BrowserMediaCandidateAvailability
            if !supportedBlob {
                availability = .unsupported
            } else {
                availability = .captureCandidate
            }
            let filename: String = {
                if let mime {
                    return blobFilename(mime: mime)
                }
                if observation.tag?.lowercased() == "video" {
                    return "browser_blob.mp4"
                }
                if observation.tag?.lowercased() == "audio" {
                    return "browser_blob.m4a"
                }
                return "browser_blob.bin"
            }()
            return BrowserMediaCandidate(
                id: identity,
                url: nil,
                rawURL: observation.rawURL,
                finalURL: nil,
                kind: .completeBlob,
                mimeType: mime,
                suggestedFilename: filename,
                estimatedSize: observation.contentLength,
                availability: availability,
                evidence: hasSize
                    ? ["Blob metadata reports a supported type and size"]
                    : ["Blob URL was observed; size will be determined at in-browser export"],
                documentID: observation.documentID,
                lastObserved: now
            )
        }

        guard let url = observation.url,
              BrowserURLResolver.isValidDownloadURL(url) else {
            return nil
        }

        let classification = StreamingManifestClassifier.classify(
            url: finalURL ?? url,
            mimeType: mime,
            content: observation.manifestPrefix?.data(using: .utf8)
        )
        if classification.kind == .hls || observation.manifestKind == .hls {
            return manifestCandidate(
                identity: identity,
                url: url,
                finalURL: finalURL,
                rawURL: observation.rawURL,
                mimeType: mime,
                kind: .hlsManifest,
                reason: classification.reason,
                documentID: observation.documentID,
                lastObserved: now
            )
        }
        if classification.kind == .dash || observation.manifestKind == .dash {
            return manifestCandidate(
                identity: identity,
                url: url,
                finalURL: finalURL,
                rawURL: observation.rawURL,
                mimeType: mime,
                kind: .dashManifest,
                reason: classification.reason,
                documentID: observation.documentID,
                lastObserved: now
            )
        }

        let type = WebpageResourceExtractor.categorize(
            extension: BrowserDownloadClassifier.extractURLExtension(from: finalURL ?? url),
            mimeType: mime
        )
        let isMediaTag = observation.tag?.lowercased() == "video" ||
            observation.tag?.lowercased() == "audio" ||
            observation.tag?.lowercased() == "source"
        let isMedia = type == .video || type == .audio || isMediaTag
        let isKnownFile = isMedia || type == .image || type == .document || type == .archive
        guard isKnownFile else { return nil }

        let kind: BrowserMediaCandidateKind = isMedia ? .directMedia : .directFile
        let evidence: [String] = {
            var values: [String] = []
            if let mime, mime.hasPrefix("video/") || mime.hasPrefix("audio/") {
                values.append("supported media MIME type")
            }
            if BrowserDownloadClassifier.extractURLExtension(from: finalURL ?? url) != nil {
                values.append("recognized resource extension")
            }
            if isMediaTag { values.append("media element observation") }
            return values.isEmpty ? ["browser resource observation"] : values
        }()

        return BrowserMediaCandidate(
            id: identity,
            url: url,
            rawURL: observation.rawURL,
            finalURL: finalURL,
            kind: kind,
            mimeType: mime,
            suggestedFilename: BrowserDownloadClassifier.suggestedFilenameFromURL(finalURL ?? url, mimeType: mime),
            estimatedSize: observation.contentLength,
            availability: .downloadable,
            evidence: evidence,
            documentID: observation.documentID,
            lastObserved: now
        )
    }

    public static func classify(
        resource: WebpageResource,
        now: Date = Date()
    ) -> BrowserMediaCandidate {
        let identity = stableIdentity(rawURL: resource.url.absoluteString, url: resource.url)
        let mime = normalizedMIME(resource.mimeType)
        let manifest = StreamingManifestClassifier.classify(url: resource.url, mimeType: mime)
        let kind: BrowserMediaCandidateKind
        let availability: BrowserMediaCandidateAvailability
        var evidence: [String] = []

        if resource.url.scheme?.lowercased() == "blob" {
            kind = .completeBlob
            availability = .captureCandidate
            evidence = ["Blob data can be exported through the active browser session"]
        } else if manifest.kind == .hls {
            kind = .hlsManifest
            availability = .requiresPlanning
            evidence = ["HLS manifest metadata was recognized"]
        } else if manifest.kind == .dash {
            kind = .dashManifest
            availability = .requiresPlanning
            evidence = ["DASH manifest metadata was recognized"]
        } else if resource.resourceType == .video || resource.resourceType == .audio {
            kind = .directMedia
            availability = resource.isSupported ? .downloadable : .unsupported
            evidence = ["direct media resource classification"]
        } else if resource.isSupported {
            kind = .directFile
            availability = .downloadable
            evidence = ["supported downloadable resource classification"]
        } else {
            kind = .unknown
            availability = .unsupported
            evidence = [resource.unsupportedReason ?? "resource is not currently supported"]
        }

        return BrowserMediaCandidate(
            id: identity,
            url: resource.url,
            rawURL: resource.url.absoluteString,
            kind: kind,
            mimeType: mime,
            suggestedFilename: resource.suggestedFilename,
            estimatedSize: resource.estimatedSize,
            availability: availability,
            evidence: evidence,
            requestContext: safeRequestContext(resource.requestContext, for: resource.url),
            lastObserved: now
        )
    }

    public static func stableIdentity(rawURL: String, url: URL?) -> String {
        if rawURL.lowercased().hasPrefix("blob:") {
            return "blob:\(rawURL)"
        }
        guard let url else { return "raw:\(rawURL)" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return "url:\(components?.url?.absoluteString ?? url.absoluteString)"
    }

    private static func manifestCandidate(
        identity: String,
        url: URL,
        finalURL: URL?,
        rawURL: String,
        mimeType: String?,
        kind: BrowserMediaCandidateKind,
        reason: String,
        documentID: String?,
        lastObserved: Date
    ) -> BrowserMediaCandidate {
        BrowserMediaCandidate(
            id: identity,
            url: url,
            rawURL: rawURL,
            finalURL: finalURL,
            kind: kind,
            mimeType: mimeType,
            suggestedFilename: BrowserDownloadClassifier.suggestedFilenameFromURL(finalURL ?? url, mimeType: mimeType),
            availability: .requiresPlanning,
            evidence: ["streaming manifest recognized", reason],
            documentID: documentID,
            lastObserved: lastObserved
        )
    }

    private static func normalizedMIME(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return result?.isEmpty == false ? result : nil
    }

    private static func isSupportedBlobMIME(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.hasPrefix("image/")
    }

    private static func blobFilename(mime: String?) -> String {
        let extensionName: String
        switch mime {
        case "video/mp4": extensionName = "mp4"
        case "video/webm": extensionName = "webm"
        case "audio/mpeg": extensionName = "mp3"
        case "audio/mp4": extensionName = "m4a"
        case "image/png": extensionName = "png"
        case "image/jpeg": extensionName = "jpg"
        default: extensionName = "bin"
        }
        return "browser_blob.\(extensionName)"
    }

    private static func safeRequestContext(
        _ context: BrowserRequestContext?,
        for targetURL: URL
    ) -> BrowserRequestContext? {
        guard let context,
              originKey(context.url) == originKey(targetURL) else {
            return nil
        }
        return context
    }

    private static func originKey(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port.map(String.init) ?? ""
        return "\(scheme)://\(host):\(port)"
    }
}

/// Ordered, deterministic candidate catalog used to merge DOM and dynamic
/// observations without creating a second download coordinator.
public struct BrowserMediaCandidateCatalog: Sendable, Equatable {
    private var orderedIDs: [String] = []
    private var values: [String: BrowserMediaCandidate] = [:]

    public init() {}

    public var candidates: [BrowserMediaCandidate] {
        orderedIDs.compactMap { values[$0] }
    }

    @discardableResult
    public mutating func ingest(
        observation: BrowserMediaDiscoveryObservation,
        now: Date = Date()
    ) -> BrowserMediaCandidate? {
        guard let candidate = BrowserMediaCandidateClassifier.classify(observation: observation, now: now) else {
            return nil
        }
        return merge(candidate)
    }

    @discardableResult
    public mutating func ingest(
        resource: WebpageResource,
        now: Date = Date()
    ) -> BrowserMediaCandidate {
        merge(BrowserMediaCandidateClassifier.classify(resource: resource, now: now))
    }

    public mutating func associateManifestSegments(
        manifestID: String,
        segmentURLs: [URL]
    ) {
        let segmentKeys = Set(segmentURLs.map { identityURL($0) })
        for id in orderedIDs {
            guard var candidate = values[id],
                  let candidateURL = candidate.url,
                  segmentKeys.contains(identityURL(candidateURL)) else { continue }
            candidate = BrowserMediaCandidate(
                id: candidate.id,
                url: candidate.url,
                rawURL: candidate.rawURL,
                finalURL: candidate.finalURL,
                kind: candidate.kind,
                mimeType: candidate.mimeType,
                suggestedFilename: candidate.suggestedFilename,
                estimatedSize: candidate.estimatedSize,
                availability: candidate.availability,
                evidence: candidate.evidence + ["associated with a recognized manifest"],
                documentID: candidate.documentID,
                requestContext: candidate.requestContext,
                associatedManifestID: manifestID,
                lastObserved: candidate.lastObserved
            )
            values[id] = candidate
        }
    }

    public mutating func reset() {
        orderedIDs.removeAll(keepingCapacity: true)
        values.removeAll(keepingCapacity: true)
    }

    @discardableResult
    private mutating func merge(_ candidate: BrowserMediaCandidate) -> BrowserMediaCandidate {
        guard let existing = values[candidate.id] else {
            orderedIDs.append(candidate.id)
            values[candidate.id] = candidate
            return candidate
        }

        var uniqueEvidence: [String] = []
        for item in existing.evidence + candidate.evidence where !uniqueEvidence.contains(item) {
            uniqueEvidence.append(item)
        }

        let merged = BrowserMediaCandidate(
            id: existing.id,
            url: existing.url ?? candidate.url,
            rawURL: existing.rawURL,
            finalURL: candidate.finalURL ?? existing.finalURL,
            kind: existing.kind == .unknown ? candidate.kind : existing.kind,
            mimeType: existing.mimeType ?? candidate.mimeType,
            suggestedFilename: existing.suggestedFilename == "browser_blob.bin" ? candidate.suggestedFilename : existing.suggestedFilename,
            estimatedSize: candidate.estimatedSize ?? existing.estimatedSize,
            availability: preferredAvailability(existing.availability, candidate.availability),
            evidence: uniqueEvidence,
            documentID: candidate.documentID ?? existing.documentID,
            requestContext: existing.requestContext ?? candidate.requestContext,
            associatedManifestID: existing.associatedManifestID ?? candidate.associatedManifestID,
            lastObserved: max(existing.lastObserved, candidate.lastObserved)
        )
        values[candidate.id] = merged
        return merged
    }

    private func preferredAvailability(
        _ lhs: BrowserMediaCandidateAvailability,
        _ rhs: BrowserMediaCandidateAvailability
    ) -> BrowserMediaCandidateAvailability {
        let priority: [BrowserMediaCandidateAvailability] = [
            .downloadable, .requiresPlanning, .captureCandidate, .uncertain, .metadataOnly, .unsupported
        ]
        return (priority.firstIndex(of: rhs) ?? Int.max) < (priority.firstIndex(of: lhs) ?? Int.max) ? rhs : lhs
    }

    private func identityURL(_ url: URL) -> String {
        BrowserMediaCandidateClassifier.stableIdentity(rawURL: url.absoluteString, url: url)
    }
}
