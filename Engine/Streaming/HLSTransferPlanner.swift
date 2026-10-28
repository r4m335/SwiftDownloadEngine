import Foundation

/// The kind of resource an HLS VOD plan asks the download coordinator to fetch.
public enum HLSPlannedResourceKind: String, Codable, Sendable, Equatable {
    case initializationMap
    case encryptionKey
    case mediaSegment
}

/// Encryption that must be understood by the future media-transfer executor.
public enum HLSTransferEncryptionRequirement: Sendable, Equatable {
    case clear
    case aes128(keyURL: URL, iv: String?)
}

/// One ordered, validated resource in an HLS VOD transfer plan.
public struct HLSPlannedResource: Sendable, Equatable {
    public let order: Int
    public let kind: HLSPlannedResourceKind
    public let url: URL
    public let byteRange: HLSByteRange?
    public let sequenceNumber: Int64?
    public let duration: Double?
    public let encryption: HLSTransferEncryptionRequirement?

    public init(
        order: Int,
        kind: HLSPlannedResourceKind,
        url: URL,
        byteRange: HLSByteRange? = nil,
        sequenceNumber: Int64? = nil,
        duration: Double? = nil,
        encryption: HLSTransferEncryptionRequirement? = nil
    ) {
        self.order = order
        self.kind = kind
        self.url = url
        self.byteRange = byteRange
        self.sequenceNumber = sequenceNumber
        self.duration = duration
        self.encryption = encryption
    }
}

public enum HLSVODTransferPlanError: Error, LocalizedError, Codable, Sendable, Equatable {
    case playlistMustBeMedia
    case livePlaylistNotSupported
    case noMediaSegments
    case invalidResourceURL
    case invalidByteRange
    case invalidSegmentMetadata
    case missingEncryptionKey
    case unsupportedEncryption(HLSKeyClassification)

    public var errorDescription: String? {
        switch self {
        case .playlistMustBeMedia:
            return "HLS transfer planning requires a media playlist."
        case .livePlaylistNotSupported:
            return "Live HLS playlists are identified but are not supported for finite transfer planning."
        case .noMediaSegments:
            return "HLS VOD playlist contains no media segments."
        case .invalidResourceURL:
            return "HLS playlist contains an invalid or unsupported transfer URL."
        case .invalidByteRange:
            return "HLS playlist contains an invalid byte range."
        case .invalidSegmentMetadata:
            return "HLS playlist contains invalid media segment metadata."
        case .missingEncryptionKey:
            return "HLS AES-128 media is missing its key URL."
        case .unsupportedEncryption(let classification):
            return "HLS encryption is unsupported: \(classification.rawValue)."
        }
    }
}

/// A validated, ordered HLS VOD plan. It contains no download state and performs
/// no network requests. Browser credentials remain transient in the request context
/// and are evaluated per resource by `requestHeaders(for:)`.
public struct HLSVODTransferPlan: Sendable, Equatable {
    public let manifestURL: URL
    public let resources: [HLSPlannedResource]
    public let browserRequestContext: BrowserRequestContext?
    public let estimatedTransferBytes: Int64?
    public let audioPlan: [HLSPlannedResource]?
    public let subtitleURL: URL?

    public init(
        manifestURL: URL,
        resources: [HLSPlannedResource],
        browserRequestContext: BrowserRequestContext? = nil,
        estimatedTransferBytes: Int64? = nil,
        audioPlan: [HLSPlannedResource]? = nil,
        subtitleURL: URL? = nil
    ) {
        self.manifestURL = manifestURL
        self.resources = resources
        self.browserRequestContext = browserRequestContext
        self.estimatedTransferBytes = estimatedTransferBytes
        self.audioPlan = audioPlan
        self.subtitleURL = subtitleURL
    }

    public var allResources: [HLSPlannedResource] {
        guard let audioPlan, !audioPlan.isEmpty else { return resources }
        var result = resources
        let offset = resources.count
        for item in audioPlan {
            result.append(HLSPlannedResource(
                order: offset + item.order,
                kind: item.kind,
                url: item.url,
                byteRange: item.byteRange,
                sequenceNumber: item.sequenceNumber,
                duration: item.duration,
                encryption: item.encryption
            ))
        }
        return result
    }

    /// Returns headers eligible for this resource. Sensitive credentials are removed
    /// automatically when the resource is on a different origin from the manifest.
    public func requestHeaders(for resource: HLSPlannedResource) -> [String: String] {
        guard let browserRequestContext else { return [:] }
        let headers = browserRequestContext.effectiveHeaders(for: resource.url)
        return BrowserHeaderFilter.stripCredentialsOnRedirect(
            headers: headers,
            from: manifestURL,
            to: resource.url
        )
    }
}

/// Converts a parsed HLS media playlist into a finite transfer plan.
///
/// This planner only validates and orders resources. It does not fetch playlists,
/// keys, segments, or redirects, and it does not modify download state.
public enum HLSTransferPlanner {

    public static func makeVODPlan(
        from manifest: HLSManifest,
        browserRequestContext: BrowserRequestContext? = nil
    ) throws -> HLSVODTransferPlan {
        guard manifest.playlistType == .media else {
            throw HLSVODTransferPlanError.playlistMustBeMedia
        }
        guard manifest.lifecycle == .vod else {
            throw HLSVODTransferPlanError.livePlaylistNotSupported
        }
        guard !manifest.segments.isEmpty else {
            throw HLSVODTransferPlanError.noMediaSegments
        }

        let resolvedManifestURL = try validatedURL(manifest.url, against: manifest.url)
        var resources: [HLSPlannedResource] = []
        var seenResources = Set<ResourceIdentity>()

        // Collect initialization map resources first so they are planned and downloaded before media segments
        for segment in manifest.segments {
            if let map = segment.initializationMap {
                let mapURL = try validatedURL(map.uri, against: resolvedManifestURL)
                appendIfNeeded(
                    HLSPlannedResource(
                        order: resources.count,
                        kind: .initializationMap,
                        url: mapURL,
                        byteRange: try validatedByteRange(map.byteRange)
                    ),
                    to: &resources,
                    seen: &seenResources
                )
            }
        }

        for segment in manifest.segments {
            guard segment.duration.isFinite, segment.duration >= 0 else {
                throw HLSVODTransferPlanError.invalidSegmentMetadata
            }
            let segmentURL = try validatedURL(segment.uri, against: resolvedManifestURL)
            let encryption = try encryptionRequirement(for: segment.encryption, baseURL: resolvedManifestURL)

            if case let .aes128(keyURL, _) = encryption {
                appendIfNeeded(
                    HLSPlannedResource(
                        order: resources.count,
                        kind: .encryptionKey,
                        url: keyURL
                    ),
                    to: &resources,
                    seen: &seenResources
                )
            }

            resources.append(
                HLSPlannedResource(
                    order: resources.count,
                    kind: .mediaSegment,
                    url: segmentURL,
                    byteRange: try validatedByteRange(segment.byteRange),
                    sequenceNumber: segment.sequenceNumber,
                    duration: segment.duration,
                    encryption: encryption
                )
            )
        }

        guard resources.contains(where: { $0.kind == .mediaSegment }) else {
            throw HLSVODTransferPlanError.noMediaSegments
        }

        let estimatedBytes: Int64?
        if resources.allSatisfy({ $0.byteRange != nil }) {
            estimatedBytes = resources.reduce(Int64(0)) { total, resource in
                total + (resource.byteRange?.length ?? 0)
            }
        } else {
            estimatedBytes = nil
        }

        let orderedResources = resources.enumerated().map { index, resource in
            HLSPlannedResource(
                order: index,
                kind: resource.kind,
                url: resource.url,
                byteRange: resource.byteRange,
                sequenceNumber: resource.sequenceNumber,
                duration: resource.duration,
                encryption: resource.encryption
            )
        }

        return HLSVODTransferPlan(
            manifestURL: resolvedManifestURL,
            resources: orderedResources,
            browserRequestContext: browserRequestContext,
            estimatedTransferBytes: estimatedBytes
        )
    }

    private static func encryptionRequirement(
        for encryption: HLSEncryption?,
        baseURL: URL
    ) throws -> HLSTransferEncryptionRequirement {
        guard let encryption else { return .clear }
        switch encryption.classification {
        case .clear:
            return .clear
        case .aes128:
            guard let keyURL = encryption.keyURL else {
                throw HLSVODTransferPlanError.missingEncryptionKey
            }
            return .aes128(
                keyURL: try validatedURL(keyURL, against: baseURL),
                iv: encryption.iv
            )
        case .sampleEncrypted, .unsupported:
            throw HLSVODTransferPlanError.unsupportedEncryption(encryption.classification)
        }
    }

    private static func validatedByteRange(_ range: HLSByteRange?) throws -> HLSByteRange? {
        guard let range else { return nil }
        guard range.length > 0, range.offset == nil || range.offset! >= 0 else {
            throw HLSVODTransferPlanError.invalidByteRange
        }
        return range
    }

    private static func validatedURL(_ rawURL: URL, against baseURL: URL) throws -> URL {
        guard let resolved = URL(string: rawURL.absoluteString, relativeTo: baseURL)?.absoluteURL,
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw HLSVODTransferPlanError.invalidResourceURL
        }
        return resolved
    }

    private static func appendIfNeeded(
        _ resource: HLSPlannedResource,
        to resources: inout [HLSPlannedResource],
        seen: inout Set<ResourceIdentity>
    ) {
        let identity = ResourceIdentity(url: resource.url, byteRange: resource.byteRange, kind: resource.kind)
        guard seen.insert(identity).inserted else { return }
        resources.append(resource)
    }
}

private struct ResourceIdentity: Hashable {
    let url: URL
    let byteRange: HLSByteRange?
    let kind: HLSPlannedResourceKind
}
