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
        public let cachedAt: Date
        public let expirationDate: Date?

        public func isExpired(now: Date = Date(), maxTTL: TimeInterval = 300) -> Bool {
            if let exp = expirationDate, now >= exp {
                return true
            }
            return now.timeIntervalSince(cachedAt) > maxTTL
        }

        public init(
            masterURL: URL,
            manifestText: String,
            options: [StreamQualityOption],
            variants: [WebpageResource],
            variantStreamItems: [HLSVariantStreamItem],
            isExpanded: Bool,
            cachedAt: Date = Date(),
            expirationDate: Date? = nil
        ) {
            self.masterURL = masterURL
            self.manifestText = manifestText
            self.options = options
            self.variants = variants
            self.variantStreamItems = variantStreamItems
            self.isExpanded = isExpanded
            self.cachedAt = cachedAt
            if let expirationDate = expirationDate {
                self.expirationDate = expirationDate
            } else {
                let masterExp = DirectMediaTransferPlanner.urlExpirationDate(masterURL)
                let variantExpirations = variants.compactMap { $0.expirationDate }
                let earliestVariant = variantExpirations.min()
                switch (masterExp, earliestVariant) {
                case let (m?, v?): self.expirationDate = min(m, v)
                case let (m?, nil): self.expirationDate = m
                case let (nil, v?): self.expirationDate = v
                case (nil, nil): self.expirationDate = nil
                }
            }
        }
    }

    /// In-memory cache of expansion results keyed by normalized manifest URL and browser context fingerprint.
    private var cache: [String: ExpansionResult] = [:]

    /// In-flight expansion tasks keyed by normalized manifest URL and browser context fingerprint
    /// to avoid duplicate concurrent network fetches while isolating different contexts.
    private var inFlight: [String: Task<ExpansionResult, Never>] = [:]

    /// Clears the expansion cache and cancels all active in-flight expansion tasks.
    public func clearCache(
        for url: URL? = nil,
        requestContext: BrowserRequestContext? = nil
    ) {
        if let url = url {
            let key = BrowserRequestContext.manifestCacheKey(for: url, requestContext: requestContext)
            cache.removeValue(forKey: key)
            if let task = inFlight.removeValue(forKey: key) {
                task.cancel()
            }
            if requestContext == nil {
                let bare = url.absoluteString.lowercased()
                cache.removeValue(forKey: bare)
                if let task = inFlight.removeValue(forKey: bare) {
                    task.cancel()
                }
            }
        } else {
            for task in inFlight.values {
                task.cancel()
            }
            cache.removeAll()
            inFlight.removeAll()
        }
    }

    /// Retrieves cached variant stream item metadata by variant resource ID.
    public func variantItem(for resourceID: String) -> HLSVariantStreamItem? {
        for result in cache.values {
            if !result.isExpired(), let match = result.variantStreamItems.first(where: { $0.id == resourceID }) {
                return match
            }
        }
        return nil
    }

    /// Retrieves cached expansion result for a given manifest URL and optional browser context if available and unexpired.
    public func cachedResult(
        for url: URL,
        requestContext: BrowserRequestContext? = nil
    ) -> ExpansionResult? {
        let key = BrowserRequestContext.manifestCacheKey(for: url, requestContext: requestContext)
        if let direct = cache[key] {
            if direct.isExpired() || DirectMediaTransferPlanner.isURLExpired(url) {
                cache.removeValue(forKey: key)
                return nil
            }
            return direct
        }
        if requestContext == nil {
            let bareKey = url.absoluteString.lowercased()
            if let bare = cache[bareKey] {
                if bare.isExpired() || DirectMediaTransferPlanner.isURLExpired(url) {
                    cache.removeValue(forKey: bareKey)
                    return nil
                }
                return bare
            }
        }
        return nil
    }

    /// Asynchronously expands a master manifest resource into individual quality variants.
    /// If the manifest is already cached for the given browser context and unexpired, results return immediately without network latency.
    public func expand(
        manifestResource: WebpageResource,
        session: URLSession = .shared
    ) async -> [WebpageResource] {
        let key = BrowserRequestContext.manifestCacheKey(
            for: manifestResource.url,
            requestContext: manifestResource.requestContext
        )

        if let existing = cache[key] {
            if existing.isExpired() || manifestResource.isExpired() {
                cache.removeValue(forKey: key)
            } else {
                return existing.variants
            }
        }

        if let pending = inFlight[key] {
            let result = await pending.value
            if !result.isExpired() {
                return result.variants
            }
        }

        let task = Task<ExpansionResult, Never> {
            await self.performExpansion(manifestResource: manifestResource, session: session)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        if !result.isExpired() {
            cache[key] = result
        }
        return result.variants
    }

    private func performExpansion(
        manifestResource: WebpageResource,
        session: URLSession
    ) async -> ExpansionResult {
        if Task.isCancelled {
            return ExpansionResult(
                masterURL: manifestResource.url,
                manifestText: "",
                options: [],
                variants: [],
                variantStreamItems: [],
                isExpanded: false
            )
        }
        let url = manifestResource.url
        var effectiveText = manifestResource.manifestText ?? ""

        // If manifest text was not captured during interception, load it using origin request context
        if effectiveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let loaded = try? await StreamQualityInspector.loadManifestText(
                from: url,
                requestContext: manifestResource.requestContext,
                session: session
            ) {
                effectiveText = loaded
            }
        }

        do {
            let options = try await StreamQualityInspector.inspect(
                manifestText: effectiveText,
                url: url,
                mimeType: manifestResource.mimeType,
                requestContext: manifestResource.requestContext,
                session: session
            )

            // If only 1 option was returned and it's a default/generic media fallback,
            // check if this is an HLS media playlist containing #EXT-X-TARGETDURATION
            if options.isEmpty || (options.count == 1 && (options[0].id.hasPrefix("default-") || (options[0].resolution == nil && options[0].hlsVariant == nil))) {
                let isMediaPlaylist = effectiveText.contains("#EXT-X-TARGETDURATION")
                let isLive = options.first?.isLive ?? (manifestResource.isLive || (isMediaPlaylist && !effectiveText.contains("#EXT-X-ENDLIST")))
                let updatedTitle: String
                if isLive {
                    let base = manifestResource.title.isEmpty ? manifestResource.suggestedFilename : manifestResource.title
                    let cleanedBase = base.hasPrefix("[LIVE]") ? base : "[LIVE] \(base)"
                    if isMediaPlaylist && !cleanedBase.contains("Media Playlist") {
                        updatedTitle = "\(cleanedBase) (Media Playlist)"
                    } else {
                        updatedTitle = cleanedBase
                    }
                } else if isMediaPlaylist && !manifestResource.title.contains("Media Playlist") {
                    let base = manifestResource.title.isEmpty ? manifestResource.suggestedFilename : manifestResource.title
                    updatedTitle = "\(base) (Media Playlist)"
                } else {
                    updatedTitle = manifestResource.title
                }

                let mediaResource = WebpageResource(
                    id: manifestResource.id,
                    url: manifestResource.url,
                    title: updatedTitle,
                    suggestedFilename: manifestResource.suggestedFilename,
                    resourceType: manifestResource.resourceType,
                    mimeType: manifestResource.mimeType,
                    estimatedSize: isLive ? nil : manifestResource.estimatedSize,
                    isSupported: !isLive,
                    unsupportedReason: isLive ? "Live stream recording required; VOD download unsupported for live/event manifests" : nil,
                    requestContext: manifestResource.requestContext,
                    manifestText: effectiveText.isEmpty ? manifestResource.manifestText : effectiveText,
                    discoveredAt: manifestResource.discoveredAt,
                    isLive: isLive
                )

                return ExpansionResult(
                    masterURL: url,
                    manifestText: effectiveText,
                    options: options,
                    variants: [mediaResource],
                    variantStreamItems: [],
                    isExpanded: false
                )
            }

            let (variants, items) = Self.buildVariants(
                from: options,
                masterResource: manifestResource,
                manifestText: effectiveText
            )

            return ExpansionResult(
                masterURL: url,
                manifestText: effectiveText,
                options: options,
                variants: variants,
                variantStreamItems: items,
                isExpanded: true
            )
        } catch {
            // Graceful fallback on network or parsing error:
            // Attempt to parse existing text without child playlist if text was present
            if !effectiveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let options = try? StreamQualityInspector.inspect(
                    manifestText: effectiveText,
                    url: url,
                    mimeType: manifestResource.mimeType,
                    durationSeconds: nil
                ), options.count > 1 {
                    let (variants, items) = Self.buildVariants(
                        from: options,
                        masterResource: manifestResource,
                        manifestText: effectiveText
                    )
                    return ExpansionResult(
                        masterURL: url,
                        manifestText: effectiveText,
                        options: options,
                        variants: variants,
                        variantStreamItems: items,
                        isExpanded: true
                    )
                }
            }

            return ExpansionResult(
                masterURL: url,
                manifestText: effectiveText,
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

        let effectiveText = manifestText ?? masterResource.manifestText ?? ""
        var drmResult = StreamDRMDetector.evaluate(manifestText: effectiveText, url: masterResource.url)
        if !drmResult.isProtected {
            for option in options {
                let optDrm = StreamDRMDetector.evaluate(manifestText: "", url: option.uri)
                if optDrm.isProtected {
                    drmResult = optDrm
                    break
                }
            }
        }

        var variants: [WebpageResource] = []
        var items: [HLSVariantStreamItem] = []
        var seenFilenames = Set<String>()

        for option in options {
            let isLive = option.isLive || masterResource.isLive
            let variantID = "\(masterResource.id)-variant-\(option.id)"
            let qualityLabel = option.qualityBadge
            var filename = "\(baseStem)-\(qualityLabel).mp4"
            if seenFilenames.contains(filename.lowercased()) {
                let disambiguator = option.bitrateText.replacingOccurrences(of: " ", with: "")
                filename = "\(baseStem)-\(qualityLabel)-\(disambiguator).mp4"
            }
            seenFilenames.insert(filename.lowercased())
            let resText = option.resolutionText ?? option.resolution.map { "\($0.width) × \($0.height)" }
            let bitrateText = option.bitrateText

            let sizeText: String = {
                if isLive {
                    return "Live Broadcast"
                } else if let bytes = option.estimatedSizeBytes {
                    return "~\(StreamQualityOption.formatByteSize(bytes))"
                } else if let text = option.estimatedSizeText, !text.isEmpty {
                    return text
                } else {
                    return "Size unavailable"
                }
            }()

            let title: String = {
                let livePrefix = isLive ? "[LIVE] " : ""
                if option.isAudioOnly {
                    return "\(livePrefix)HLS Audio (\(option.audioCodec ?? "AAC"))"
                } else {
                    return "\(livePrefix)HLS \(qualityLabel)"
                }
            }()

            let preferences = HLSVariantSelectionPreferences(
                maximumBandwidth: Int(option.bandwidth),
                maximumWidth: option.resolution?.width,
                maximumHeight: option.resolution?.height,
                exactURI: option.uri
            )

            let optionDrm = drmResult.isProtected ? drmResult : StreamDRMDetector.evaluate(manifestText: "", url: option.uri)
            let isSupported = !optionDrm.isProtected && !isLive
            let unsupportedReason: String? = {
                if optionDrm.isProtected {
                    return optionDrm.reason
                }
                if isLive {
                    return "Live stream recording required; VOD download unsupported for live/event manifests"
                }
                return nil
            }()

            let resource = WebpageResource(
                id: variantID,
                url: masterResource.url, // Keep pointing to master manifest URL for orchestrator planning
                title: title,
                suggestedFilename: filename,
                resourceType: option.isAudioOnly ? .audio : .video,
                mimeType: masterResource.mimeType ?? "application/vnd.apple.mpegurl",
                estimatedSize: isLive ? nil : option.estimatedSizeBytes,
                isSupported: isSupported,
                unsupportedReason: unsupportedReason,
                requestContext: masterResource.requestContext,
                manifestText: effectiveText,
                hlsVariantPreferences: preferences,
                dashVideoRepresentationID: option.dashVideoRepresentationID,
                dashAudioRepresentationID: option.dashAudioRepresentationID,
                isDRMProtected: optionDrm.isProtected,
                drmProtectionType: optionDrm.protectionType,
                discoveredAt: masterResource.discoveredAt,
                isLive: isLive
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
                estimatedSizeBytes: isLive ? nil : option.estimatedSizeBytes,
                estimatedSizeText: sizeText,
                isLive: isLive
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
            let singleOption = options[0]
            if singleOption.isLive || masterResource.isLive {
                let liveTitle = masterResource.title.hasPrefix("[LIVE]") ? masterResource.title : "[LIVE] \(masterResource.title)"
                let liveResource = WebpageResource(
                    id: masterResource.id,
                    url: masterResource.url,
                    title: liveTitle,
                    suggestedFilename: masterResource.suggestedFilename,
                    resourceType: masterResource.resourceType,
                    mimeType: masterResource.mimeType,
                    estimatedSize: nil,
                    isSupported: false,
                    unsupportedReason: "Live stream recording required; VOD download unsupported for live/event manifests",
                    requestContext: masterResource.requestContext,
                    manifestText: manifestText,
                    hlsVariantPreferences: masterResource.hlsVariantPreferences,
                    dashVideoRepresentationID: masterResource.dashVideoRepresentationID,
                    dashAudioRepresentationID: masterResource.dashAudioRepresentationID,
                    isDRMProtected: masterResource.isDRMProtected,
                    drmProtectionType: masterResource.drmProtectionType,
                    discoveredAt: masterResource.discoveredAt,
                    isLive: true
                )
                return ([liveResource], [])
            }
            return ([masterResource], [])
        }

        return buildVariants(
            from: options,
            masterResource: masterResource,
            manifestText: manifestText
        )
    }
}
