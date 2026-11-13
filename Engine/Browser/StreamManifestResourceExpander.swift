import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asynchronously inspects HLS and DASH streaming master manifests, caching the results
/// and expanding master manifests into individual selectable video and audio quality resources
/// directly within the browser's Find Resources (Media Grabber) catalog.
public actor StreamManifestResourceExpander {

    public static let shared = StreamManifestResourceExpander()

    public struct ExpansionResult: Sendable {
        public let masterURL: URL
        public let manifestText: String
        public let options: [StreamQualityOption]
        public let variants: [WebpageResource]
        public let variantStreamItems: [HLSVariantStreamItem]
        public let isExpanded: Bool

        public init(
            masterURL: URL,
            manifestText: String,
            options: [StreamQualityOption],
            variants: [WebpageResource],
            variantStreamItems: [HLSVariantStreamItem],
            isExpanded: Bool
        ) {
            self.masterURL = masterURL
            self.manifestText = manifestText
            self.options = options
            self.variants = variants
            self.variantStreamItems = variantStreamItems
            self.isExpanded = isExpanded
        }
    }

    /// In-memory cache of expansion results keyed by normalized manifest URL.
    private var cache: [String: ExpansionResult] = [:]

    /// In-flight expansion tasks keyed by normalized manifest URL to avoid duplicate concurrent network fetches.
    private var inFlight: [String: Task<ExpansionResult, Never>] = [:]

    /// Clears the expansion cache (e.g. on page navigation or tab close).
    public func clearCache() {
        cache.removeAll()
        inFlight.removeAll()
    }

    /// Retrieves cached variant stream item metadata by variant resource ID.
    public func variantItem(for resourceID: String) -> HLSVariantStreamItem? {
        for result in cache.values {
            if let match = result.variantStreamItems.first(where: { $0.id == resourceID }) {
                return match
            }
        }
        return nil
    }

    /// Retrieves cached expansion result for a given manifest URL if available.
    public func cachedResult(for url: URL) -> ExpansionResult? {
        cache[url.absoluteString.lowercased()]
    }

    /// Asynchronously expands a master manifest resource into individual quality variants.
    /// If the manifest is already cached, results return immediately without network latency.
    public func expand(
        manifestResource: WebpageResource,
        session: URLSession = .shared
    ) async -> [WebpageResource] {
        let key = manifestResource.url.absoluteString.lowercased()

        if let existing = cache[key] {
            return existing.variants
        }

        if let pending = inFlight[key] {
            let result = await pending.value
            return result.variants
        }

        let task = Task<ExpansionResult, Never> {
            await self.performExpansion(manifestResource: manifestResource, session: session)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        cache[key] = result
        return result.variants
    }

    private func performExpansion(
        manifestResource: WebpageResource,
        session: URLSession
    ) async -> ExpansionResult {
        let url = manifestResource.url
        let initialText = manifestResource.manifestText ?? ""

        do {
            let options = try await StreamQualityInspector.inspect(
                manifestText: initialText,
                url: url,
                mimeType: manifestResource.mimeType,
                requestContext: manifestResource.requestContext,
                session: session
            )

            // If only 1 option was returned and it's a default/generic media fallback, keep master resource
            if options.isEmpty || (options.count == 1 && (options[0].id.hasPrefix("default-") || (options[0].resolution == nil && options[0].hlsVariant == nil))) {
                return ExpansionResult(
                    masterURL: url,
                    manifestText: initialText,
                    options: options,
                    variants: [manifestResource],
                    variantStreamItems: [],
                    isExpanded: false
                )
            }

            let (variants, items) = Self.buildVariants(
                from: options,
                masterResource: manifestResource,
                manifestText: initialText
            )

            return ExpansionResult(
                masterURL: url,
                manifestText: initialText,
                options: options,
                variants: variants,
                variantStreamItems: items,
                isExpanded: true
            )
        } catch {
            // Graceful fallback on network or parsing error:
            // Attempt to parse existing text without child playlist if text was present
            if !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let options = try? StreamQualityInspector.inspect(
                    manifestText: initialText,
                    url: url,
                    mimeType: manifestResource.mimeType,
                    durationSeconds: nil
                ), options.count > 1 {
                    let (variants, items) = Self.buildVariants(
                        from: options,
                        masterResource: manifestResource,
                        manifestText: initialText
                    )
                    return ExpansionResult(
                        masterURL: url,
                        manifestText: initialText,
                        options: options,
                        variants: variants,
                        variantStreamItems: items,
                        isExpanded: true
                    )
                }
            }

            return ExpansionResult(
                masterURL: url,
                manifestText: initialText,
                options: [],
                variants: [manifestResource],
                variantStreamItems: [],
                isExpanded: false
            )
        }
    }

    /// Converts parsed stream quality options into individual `WebpageResource` candidates
    /// and associated `HLSVariantStreamItem` presentation models.
    public static func buildVariants(
        from options: [StreamQualityOption],
        masterResource: WebpageResource,
        manifestText: String?
    ) -> (variants: [WebpageResource], items: [HLSVariantStreamItem]) {
        let baseStem: String = {
            let raw = (masterResource.suggestedFilename as NSString).deletingPathExtension
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "video" : trimmed
        }()

        var variants: [WebpageResource] = []
        var items: [HLSVariantStreamItem] = []

        for option in options {
            let variantID = "\(masterResource.id)-variant-\(option.id)"
            let qualityLabel = option.qualityBadge
            let filename = "\(baseStem)-\(qualityLabel).mp4"
            let resText = option.resolutionText ?? option.resolution.map { "\($0.width) × \($0.height)" }
            let bitrateText = option.bitrateText

            let sizeText: String = {
                if let bytes = option.estimatedSizeBytes {
                    return "~\(StreamQualityOption.formatByteSize(bytes))"
                } else if let text = option.estimatedSizeText, !text.isEmpty {
                    return text
                } else {
                    return "Size unavailable"
                }
            }()

            let title: String = {
                if option.isAudioOnly {
                    return "HLS Audio (\(option.audioCodec ?? "AAC"))"
                } else {
                    return "HLS \(qualityLabel)"
                }
            }()

            let preferences = HLSVariantSelectionPreferences(
                maximumBandwidth: Int(option.bandwidth),
                maximumWidth: option.resolution?.width,
                maximumHeight: option.resolution?.height,
                exactURI: option.uri
            )

            let resource = WebpageResource(
                id: variantID,
                url: masterResource.url, // Keep pointing to master manifest URL for orchestrator planning
                title: title,
                suggestedFilename: filename,
                resourceType: option.isAudioOnly ? .audio : .video,
                mimeType: masterResource.mimeType ?? "application/vnd.apple.mpegurl",
                estimatedSize: option.estimatedSizeBytes,
                isSupported: true,
                unsupportedReason: nil,
                requestContext: masterResource.requestContext,
                manifestText: manifestText ?? masterResource.manifestText,
                hlsVariantPreferences: preferences,
                dashVideoRepresentationID: option.dashVideoRepresentationID,
                dashAudioRepresentationID: option.dashAudioRepresentationID
            )
            variants.append(resource)

            let item = HLSVariantStreamItem(
                id: variantID,
                masterURL: masterResource.url,
                variantURL: option.uri,
                bandwidth: Int(option.bandwidth),
                resolution: option.resolution,
                qualityLabel: qualityLabel,
                resolutionText: resText,
                bitrateText: bitrateText,
                hasAudio: option.hasAudio,
                audioText: option.audioCodec ?? (option.hasAudio ? "Audio" : nil),
                hasSubtitles: false,
                subtitleText: nil,
                codecs: option.codecs,
                videoCodec: option.videoCodec,
                estimatedSizeBytes: option.estimatedSizeBytes,
                estimatedSizeText: sizeText
            )
            items.append(item)
        }

        return (variants, items)
    }

    /// Synchronously expands a manifest from known manifest text and optional duration.
    public static func expandSynchronously(
        masterResource: WebpageResource,
        manifestText: String,
        durationSeconds: Double? = nil
    ) -> (variants: [WebpageResource], items: [HLSVariantStreamItem]) {
        guard let options = try? StreamQualityInspector.inspect(
            manifestText: manifestText,
            url: masterResource.url,
            mimeType: masterResource.mimeType,
            durationSeconds: durationSeconds
        ), !options.isEmpty else {
            return ([masterResource], [])
        }

        if options.count == 1 && (options[0].id.hasPrefix("default-") || (options[0].resolution == nil && options[0].hlsVariant == nil)) {
            return ([masterResource], [])
        }

        return buildVariants(
            from: options,
            masterResource: masterResource,
            manifestText: manifestText
        )
    }
}
