import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension StreamingDownloadOrchestrator {
    public func activeProposal(for id: String) -> StreamingTransferProposal? {
        let parentID = hlsParentID(for: id)
        return proposals[parentID] ?? proposals[id]
    }

    func manifestStatusDescription(for error: Error) -> String {
        if let manifestErr = error as? StreamingManifestLoadError {
            switch manifestErr {
            case .unexpectedStatus(let status):
                return "HTTP \(status)"
            case .authenticationRequired:
                return "HTTP 401/403"
            case .expiredOrMissing:
                return "HTTP 404/410"
            case .invalidResponse:
                return "Invalid Response"
            case .invalidRedirect:
                return "Invalid Redirect"
            case .browserFetchUnavailable:
                return "Browser Fetch Unavailable"
            case .failed(let msg):
                return msg
            }
        }
        return error.localizedDescription
    }

    func browserFetchErrorReason(for error: Error) -> String {
        let nsError = error as NSError
        if let jsMsg = nsError.userInfo["WKErrorJavaScriptExceptionMessageKey"] as? String, !jsMsg.isEmpty {
            return jsMsg
        }
        if let manifestErr = error as? StreamingManifestLoadError {
            return manifestErr.localizedDescription
        }
        return error.localizedDescription
    }

    public static func isHTMLResponse(_ data: Data) -> Bool {
        return HTTPTransportValidator.isHTMLData(data)
    }

    func loadManifestResponse(
        candidate: StreamingManifestCandidate,
        headers: [String: String]
    ) async throws -> StreamingManifestResponse {
        if let cached = validCachedManifestText(
            for: candidate.url,
            requestContext: candidate.browserRequestContext,
            browserSessionSnapshot: candidate.browserSessionSnapshot
        ), !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = cached.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
            let data = Data(normalized.utf8)
            if data.count <= parsingLimits.maxBytes && !Self.isHTMLResponse(data) {
                let classification = StreamingManifestClassifier.classify(
                    url: candidate.url,
                    mimeType: candidate.mimeType,
                    content: data,
                    limits: parsingLimits
                )
                if classification.isManifest {
                    PipelineLogger.shared.log("[HLS Pipeline] Step 1: Using cached manifest text from hook for \(candidate.url.absoluteString) (\(normalized.count) chars). Bypassing network fetch.")
                    return StreamingManifestResponse(
                        data: data,
                        finalURL: candidate.url,
                        mimeType: candidate.mimeType,
                        statusCode: 200,
                        redirectResolvedContext: candidate.browserRequestContext?.redirectResolved(to: candidate.url)
                    )
                }
            }
        }

        do {
            let response = try await manifestLoader.load(
                candidate: candidate,
                headers: headers,
                limits: parsingLimits
            )
            PipelineLogger.shared.log("[HLS Pipeline] Step 1: URLSession manifest fetch (status: \(response.statusCode))")
            if Self.isHTMLResponse(response.data) {
                let htmlSnippet = String(decoding: response.data.prefix(500), as: UTF8.self)
                PipelineLogger.shared.log("[Streaming Pipeline] Server blocked request. Returned HTML instead of manifest. Snippet:\n\(htmlSnippet)")
                throw StreamingManifestLoadError.failed("Server blocked request. Returned HTML instead of manifest.")
            }
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as StreamingDownloadOrchestratorError {
            throw error
        } catch let error as ManifestParserError {
            PipelineLogger.shared.log("[HLS Pipeline] Error: Manifest parser failed: \(error.localizedDescription)")
            throw error
        } catch {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            let status = manifestStatusDescription(for: error)
            PipelineLogger.shared.log("[HLS Pipeline] Step 1: URLSession manifest fetch (status: \(status))")
            if let resolver = self.urlResolver {
                do {
                    let text = try await resolver.fetchManifestText(from: candidate.url, maxBytes: parsingLimits.maxBytes)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        let jsReason = "Empty manifest response"
                        PipelineLogger.shared.log("[HLS Pipeline] Step 1b: JS fetch fallback (status: \(jsReason))")
                        let combinedMessage = "Manifest \(status); browser fetch failed: \(jsReason)"
                        PipelineLogger.shared.log("[HLS Pipeline] Error: \(combinedMessage)")
                        throw StreamingManifestLoadError.failed(combinedMessage)
                    }
                    let data = Data(trimmed.utf8)
                    if data.count > parsingLimits.maxBytes {
                        throw ManifestParserError.inputTooLarge(limit: parsingLimits.maxBytes)
                    }
                    if Self.isHTMLResponse(data) {
                        let htmlSnippet = String(decoding: data.prefix(500), as: UTF8.self)
                        PipelineLogger.shared.log("[Streaming Pipeline] Block page received from JS fallback (first 500 chars):\n\(htmlSnippet)")
                        throw StreamingManifestLoadError.failed("Server blocked request. Returned HTML instead of manifest.")
                    }
                    PipelineLogger.shared.log("[HLS Pipeline] Step 1b: JS fetch fallback (status: 200)")
                    return StreamingManifestResponse(
                        data: data,
                        finalURL: candidate.url,
                        mimeType: candidate.mimeType,
                        statusCode: 200,
                        redirectResolvedContext: candidate.browserRequestContext?.redirectResolved(to: candidate.url)
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let parserErr as ManifestParserError {
                    PipelineLogger.shared.log("[HLS Pipeline] Error: Manifest size limit reached on JS fetch fallback: \(parserErr.localizedDescription)")
                    throw parserErr
                } catch let jsError as StreamingManifestLoadError {
                    if case .failed = jsError {
                        throw jsError
                    }
                    let jsReason = browserFetchErrorReason(for: jsError)
                    PipelineLogger.shared.log("[HLS Pipeline] Step 1b: JS fetch fallback (status: \(jsReason))")
                    let combinedMessage = "Manifest \(status); browser fetch failed: \(jsReason)"
                    PipelineLogger.shared.log("[HLS Pipeline] Error: \(combinedMessage)")
                    throw StreamingManifestLoadError.failed(combinedMessage)
                } catch {
                    guard !Task.isCancelled else {
                        throw CancellationError()
                    }
                    let jsReason = browserFetchErrorReason(for: error)
                    PipelineLogger.shared.log("[HLS Pipeline] Step 1b: JS fetch fallback (status: \(jsReason))")
                    let combinedMessage = "Manifest \(status); browser fetch failed: \(jsReason)"
                    PipelineLogger.shared.log("[HLS Pipeline] Error: \(combinedMessage)")
                    throw StreamingManifestLoadError.failed(combinedMessage)
                }
            } else {
                PipelineLogger.shared.log("[HLS Pipeline] Error: Manifest fetch failed (\(status)) and browser resolver is unavailable.")
                throw error
            }
        }
    }

    func proposalFingerprint(for candidate: StreamingManifestCandidate) -> String {
        let candidateMIME = candidate.mimeType ?? ""
        var fingerprintComponents = [
            candidate.url.absoluteString,
            candidateMIME,
            candidate.dashVideoRepresentationID ?? "",
            candidate.dashAudioRepresentationID ?? "",
            candidate.dashTextRepresentationID ?? "",
            "\(candidate.hlsVariantPreferences.maximumBandwidth ?? -1)|\(candidate.hlsVariantPreferences.maximumWidth ?? -1)|\(candidate.hlsVariantPreferences.maximumHeight ?? -1)|\(candidate.hlsVariantPreferences.exactURI?.absoluteString ?? "")"
        ]
        if let context = candidate.browserRequestContext {
            fingerprintComponents.append(context.userAgent ?? "")
            fingerprintComponents.append(context.referer ?? "")
            let cookieDesc = context.cookies.map { "\($0.name)=\($0.value)" }.sorted().joined(separator: ";")
            fingerprintComponents.append(cookieDesc)
            if !context.customHeaders.isEmpty {
                let headerDesc = context.customHeaders.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }.joined(separator: "\n")
                fingerprintComponents.append(headerDesc)
            }
        }
        if let snapshot = candidate.browserSessionSnapshot {
            fingerprintComponents.append(snapshot.userAgent)
            let cookieDesc = snapshot.allCookies.map { "\($0.name)=\($0.value)" }.sorted().joined(separator: ";")
            fingerprintComponents.append(cookieDesc)
        }
        return EngineSHA256.hash(
            data: Data(fingerprintComponents.joined(separator: "|").utf8)
        )
    }

    public func prepare(candidate: StreamingManifestCandidate) async throws -> StreamingTransferProposal {
        let candidate = candidate.withRefreshedCookies()
        let metadataFingerprint = proposalFingerprint(for: candidate)
        if let existing = proposals[metadataFingerprint] {
            return existing
        }

        let headers = manifestHeaders(for: candidate)
        var parsedManifest: StreamingTransferManifest?
        var manifestData: Data?

        let rawCachedText: String?
        if DirectMediaTransferPlanner.isURLExpired(candidate.url) {
            rawCachedText = nil
        } else {
            let cachedLookupText = validCachedManifestText(
                for: candidate.url,
                requestContext: candidate.browserRequestContext,
                browserSessionSnapshot: candidate.browserSessionSnapshot
            )
            rawCachedText = candidate.cachedManifestText ?? cachedLookupText
        }
        if let rawCachedText, !rawCachedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalizedText = rawCachedText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
            let cachedData = Data(normalizedText.utf8)
            if cachedData.count <= parsingLimits.maxBytes && !Self.isHTMLResponse(cachedData) {
                let classification = StreamingManifestClassifier.classify(
                    url: candidate.url,
                    mimeType: candidate.mimeType,
                    content: cachedData,
                    limits: parsingLimits
                )
                if classification.isManifest {
                    do {
                        PipelineLogger.shared.log("[Streaming Pipeline] Step 1: Using cached manifest text from network hook (\(normalizedText.count) chars). Skipping network fetch.")
                        let manifest = try await parseManifest(
                            data: cachedData,
                            finalURL: candidate.url,
                            mimeType: candidate.mimeType,
                            candidate: candidate,
                            classification: classification
                        )
                        parsedManifest = manifest
                        manifestData = cachedData
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as StreamingDownloadOrchestratorError {
                        throw error
                    } catch let error as HLSVODTransferPlanError {
                        if case .unsupportedEncryption = error {
                            throw StreamingDownloadOrchestratorError.unsupportedEncryption
                        }
                        throw StreamingDownloadOrchestratorError.hlsPlanningFailed(error)
                    } catch let error as DASHVODTransferPlanError {
                        if case .drmProtectedRepresentation = error {
                            throw StreamingDownloadOrchestratorError.unsupportedEncryption
                        }
                        throw StreamingDownloadOrchestratorError.dashPlanningFailed(error)
                    } catch let error as StreamingManifestLoadError {
                        throw error
                    } catch let error as URLError {
                        throw error
                    } catch let error as ManifestParserError {
                        PipelineLogger.shared.log("[Streaming Pipeline] Cached manifest text failed to parse (\(error.localizedDescription)). Falling back to network loader.")
                    } catch {
                        PipelineLogger.shared.log("[Streaming Pipeline] Error during cached manifest processing: \(error.localizedDescription)")
                        throw error
                    }
                } else {
                    PipelineLogger.shared.log("[Streaming Pipeline] Cached manifest text not recognized as valid manifest. Falling back to network loader.")
                }
            } else {
                PipelineLogger.shared.log("[Streaming Pipeline] Cached manifest text was HTML or exceeded byte limits (\(cachedData.count) bytes). Falling back to network loader.")
            }
        }

        if parsedManifest == nil {
            let response: StreamingManifestResponse
            do {
                response = try await loadManifestResponse(
                    candidate: candidate,
                    headers: headers
                )
            } catch let error as ManifestParserError {
                throw StreamingDownloadOrchestratorError.manifestParseFailed(error)
            } catch {
                throw error
            }

            if Self.isHTMLResponse(response.data) {
                let htmlSnippet = String(decoding: response.data.prefix(500), as: UTF8.self)
                PipelineLogger.shared.log("[Streaming Pipeline] Server blocked request. Returned HTML instead of manifest. Snippet:\n\(htmlSnippet)")
                throw StreamingDownloadOrchestratorError.manifestParseFailed(
                    ManifestParserError.malformed(reason: "Server blocked request. Returned HTML instead of manifest.")
                )
            }

            let classification = StreamingManifestClassifier.classify(
                url: response.finalURL,
                mimeType: response.mimeType ?? candidate.mimeType,
                content: response.data,
                limits: parsingLimits
            )
            guard classification.isManifest else {
                if classification.kind == .unsupported {
                    throw StreamingDownloadOrchestratorError.unsupportedManifest(classification.kind)
                }
                throw StreamingDownloadOrchestratorError.manifestNotRecognized
            }

            do {
                let manifest = try await parseManifest(
                    data: response.data,
                    finalURL: response.finalURL,
                    mimeType: response.mimeType ?? candidate.mimeType,
                    candidate: candidate,
                    classification: classification,
                    redirectResolvedContext: response.redirectResolvedContext
                )
                parsedManifest = manifest
                manifestData = response.data
            } catch let error as StreamingDownloadOrchestratorError {
                throw error
            } catch let error as ManifestParserError {
                throw StreamingDownloadOrchestratorError.manifestParseFailed(error)
            } catch let error as HLSVODTransferPlanError {
                if case .unsupportedEncryption = error {
                    throw StreamingDownloadOrchestratorError.unsupportedEncryption
                }
                throw StreamingDownloadOrchestratorError.hlsPlanningFailed(error)
            } catch let error as DASHVODTransferPlanError {
                if case .drmProtectedRepresentation = error {
                    throw StreamingDownloadOrchestratorError.unsupportedEncryption
                }
                throw StreamingDownloadOrchestratorError.dashPlanningFailed(error)
            }
        }

        guard let manifest = parsedManifest, let finalData = manifestData else {
            throw StreamingDownloadOrchestratorError.manifestNotRecognized
        }

        // Derive the parent ID from the candidate URL, not the redirected or
        // signed response URL. A refreshed manifest must recover the same
        // parent even when its CDN query token has changed.
        let transferID = "stream-\(metadataFingerprint.prefix(32))"
        let resources = try makeResources(from: manifest, transferID: transferID)
        guard !resources.isEmpty else {
            throw StreamingDownloadOrchestratorError.noTransferResources
        }
        let proposal = StreamingTransferProposal(
            transferID: transferID,
            manifestID: EngineSHA256.hash(data: finalData),
            manifest: manifest,
            resources: resources,
            estimatedTransferBytes: estimatedBytes(for: manifest),
            transportPolicy: candidate.transportPolicy
        )
        proposals[metadataFingerprint] = proposal
        proposals[proposal.transferID] = proposal
        candidatesByTransfer[proposal.transferID] = candidate
        let masterKey = candidate.url.absoluteString
        let variantKey = proposal.manifest.manifestURL.absoluteString
        registeredTransferIDs[masterKey] = proposal.transferID
        registeredTransferIDs[variantKey] = proposal.transferID
        registeredTransferIDs[proposal.transferID] = proposal.transferID
        return proposal
    }

    struct ResolvedHLSSelection {
        let mediaPlaylist: HLSManifest
        let mediaURL: URL
        let selectedVariant: HLSVariant?
        let selectedVariantBandwidth: Int?
        let videoPlan: HLSVODTransferPlan
        let audioPlan: [HLSPlannedResource]?
        let selectedSubtitleRendition: HLSRendition?
    }

    func resolveCompatibleHLSVariant(
        manifest: HLSManifest,
        baseURL: URL,
        candidate: StreamingManifestCandidate,
        effectiveContext: BrowserRequestContext? = nil,
        depth: Int = 0
    ) async throws -> ResolvedHLSSelection {
        guard depth < 5 else {
            throw StreamingDownloadOrchestratorError.playlistRequiresVariantSelection
        }
        let currentContext = effectiveContext ?? candidate.browserRequestContext?.redirectResolved(to: baseURL)
        guard manifest.playlistType == .master else {
            // Already a media playlist: validate directly
            if manifest.isIFramesOnly {
                PipelineLogger.shared.log("[HLS Pipeline] Rejecting standalone I-frame-only media playlist: I-frame trick-play streams cannot be assembled as a complete video.")
                throw StreamingDownloadOrchestratorError.hlsVariantSelectionFailed(.unsupportedIFrameVariant)
            }
            let videoPlan: HLSVODTransferPlan
            do {
                videoPlan = try HLSTransferPlanner.makeVODPlan(
                    from: manifest,
                    browserRequestContext: currentContext
                )
            } catch let error as HLSVODTransferPlanError {
                if case .unsupportedEncryption = error {
                    throw StreamingDownloadOrchestratorError.unsupportedEncryption
                }
                throw StreamingDownloadOrchestratorError.hlsPlanningFailed(error)
            }
            return ResolvedHLSSelection(
                mediaPlaylist: manifest,
                mediaURL: baseURL,
                selectedVariant: nil,
                selectedVariantBandwidth: nil,
                videoPlan: videoPlan,
                audioPlan: nil,
                selectedSubtitleRendition: nil
            )
        }

        // Direct audio rendition match: when the candidate exactURI matches an audio rendition from master manifest
        if let exactURI = candidate.hlsVariantPreferences.exactURI,
           let matchedAudio = manifest.renditions.first(where: {
               $0.type.uppercased() == "AUDIO" && ($0.uri == exactURI || $0.uri?.absoluteString == exactURI.absoluteString || ($0.uri != nil && $0.uri?.path == exactURI.path))
           }), let audioURI = matchedAudio.uri {
            PipelineLogger.shared.log("[HLS Pipeline] Direct audio rendition match found: \(audioURI.absoluteString)")
            let parentQuery = baseURL.query ?? candidate.url.query
            let effectiveAudioURI = audioURI.mergingParentQuery(parentQuery)

            let audioCachedText = validCachedManifestText(
                for: effectiveAudioURI,
                requestContext: currentContext,
                browserSessionSnapshot: candidate.browserSessionSnapshot
            )
            let audioCandidate = try StreamingManifestCandidate(
                url: effectiveAudioURI,
                mimeType: "application/vnd.apple.mpegurl",
                browserRequestContext: currentContext?.redirectResolved(to: effectiveAudioURI) ?? candidate.browserRequestContext,
                browserSessionSnapshot: candidate.browserSessionSnapshot,
                hlsVariantPreferences: candidate.hlsVariantPreferences,
                cachedManifestText: audioCachedText,
                transportPolicy: candidate.transportPolicy
            ).withRefreshedCookies()
            do {
                let audioSubResponse = try await loadManifestResponse(
                    candidate: audioCandidate,
                    headers: manifestHeaders(for: audioCandidate)
                )
                let parsedAudio = try HLSManifestParser.parse(
                    audioSubResponse.data,
                    baseURL: audioSubResponse.finalURL,
                    limits: parsingLimits
                )
                if parsedAudio.playlistType == .media {
                    let audioContext = audioSubResponse.redirectResolvedContext ?? currentContext?.redirectResolved(to: audioSubResponse.finalURL)
                    let audioPlan = try HLSTransferPlanner.makeVODPlan(
                        from: parsedAudio,
                        browserRequestContext: audioContext
                    )
                    PipelineLogger.shared.log("[HLS Pipeline] Successfully resolved audio-only HLS plan with \(audioPlan.resources.count) segments.")
                    return ResolvedHLSSelection(
                        mediaPlaylist: parsedAudio,
                        mediaURL: audioSubResponse.finalURL,
                        selectedVariant: nil,
                        selectedVariantBandwidth: nil,
                        videoPlan: audioPlan,
                        audioPlan: nil,
                        selectedSubtitleRendition: nil
                    )
                }
            } catch {
                PipelineLogger.shared.log("[HLS Pipeline] Audio-only rendition fetch failed (\(error.localizedDescription)). Falling back to variant evaluation...")
            }
        }

        let rankedVariants: [HLSVariant]
        do {
            rankedVariants = try HLSVariantSelector.rank(
                from: manifest,
                preferences: candidate.hlsVariantPreferences
            )
        } catch let error as HLSVariantSelectionError {
            PipelineLogger.shared.log("[HLS Pipeline] Error during variant ranking: \(error.localizedDescription)")
            throw StreamingDownloadOrchestratorError.hlsVariantSelectionFailed(error)
        }

        PipelineLogger.shared.log("[HLS Pipeline] Master playlist detected [depth=\(depth)]. Discovered \(manifest.variants.count) variants; \(rankedVariants.count) eligible variants ranked by preference.")
        await BrowserDiagnosticLogger.shared.log(
            category: .policy,
            message: "HLS variants discovered and ranked",
            url: baseURL,
            details: [
                "discoveredVariants": "\(manifest.variants.count)",
                "rankedVariants": "\(rankedVariants.count)",
                "depth": "\(depth)"
            ]
        )

        let isExplicitVariantSelection = candidate.hlsVariantPreferences.exactURI != nil
        var sawUnsupportedEncryption = false
        var lastPlanningError: Error? = nil
        var deferredSampleAESSelection: ResolvedHLSSelection? = nil

        for (index, variant) in rankedVariants.enumerated() {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            let variantResolution = variant.resolution.map { "\($0.width)x\($0.height)" } ?? "unknown"
            let variantDesc = "Variant #\(index + 1)/\(rankedVariants.count) [bw=\(variant.bandwidth), res=\(variantResolution), codecs=\(variant.codecs ?? "none")]"
            PipelineLogger.shared.log("[HLS Pipeline] Evaluating \(variantDesc) at \(variant.uri.absoluteString)...")

            if variant.isIFrameOnly {
                PipelineLogger.shared.log("[HLS Pipeline] Skipping I-frame-only variant \(variantDesc): I-frame trick-play streams cannot be assembled as a complete video.")
                let failureError = StreamingDownloadOrchestratorError.hlsVariantSelectionFailed(.unsupportedIFrameVariant)
                if isExplicitVariantSelection {
                    throw failureError
                }
                lastPlanningError = failureError
                continue
            }

            do {
                try HLSVariantSelector.validateAudioLayout(
                    selectedVariant: variant,
                    master: manifest
                )
            } catch {
                PipelineLogger.shared.log("[HLS Pipeline] Audio layout validation failed for \(variantDesc): \(error.localizedDescription)")
                let failureError: Error
                if let selectionError = error as? HLSVariantSelectionError {
                    failureError = StreamingDownloadOrchestratorError.hlsVariantSelectionFailed(selectionError)
                } else {
                    failureError = error
                }
                if isExplicitVariantSelection {
                    throw failureError
                }
                lastPlanningError = failureError
                continue
            }

            let selectedAudioRendition = HLSVariantSelector.selectAudioRendition(
                for: variant,
                master: manifest
            )
            var selectedSubtitleRendition: HLSRendition? = nil
            if let subGroup = variant.subtitlesGroup {
                selectedSubtitleRendition = manifest.renditions.first {
                    $0.type.uppercased() == "SUBTITLES" && $0.groupID == subGroup && $0.uri != nil
                }
            }
            if selectedSubtitleRendition == nil {
                selectedSubtitleRendition = manifest.renditions.first {
                    $0.type.uppercased() == "SUBTITLES" && $0.uri != nil
                }
            }

            let parentQuery = baseURL.query ?? candidate.url.query
            let variantURI = variant.uri.mergingParentQuery(parentQuery)

            let variantCachedText = validCachedManifestText(
                for: variantURI,
                requestContext: currentContext,
                browserSessionSnapshot: candidate.browserSessionSnapshot
            )
            let variantCandidate = try StreamingManifestCandidate(
                url: variantURI,
                mimeType: "application/vnd.apple.mpegurl",
                browserRequestContext: currentContext?.redirectResolved(to: variantURI) ?? candidate.browserRequestContext,
                browserSessionSnapshot: candidate.browserSessionSnapshot,
                hlsVariantPreferences: candidate.hlsVariantPreferences,
                cachedManifestText: variantCachedText,
                transportPolicy: candidate.transportPolicy
            ).withRefreshedCookies()

            let subResponse: StreamingManifestResponse
            do {
                subResponse = try await loadManifestResponse(
                    candidate: variantCandidate,
                    headers: manifestHeaders(for: variantCandidate)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as StreamingManifestLoadError {
                if isExplicitVariantSelection {
                    PipelineLogger.shared.log("[HLS Pipeline] Network/Auth error loading explicitly selected variant playlist: \(error.localizedDescription). Aborting without downgrade.")
                    throw error
                }
                lastPlanningError = error
                PipelineLogger.shared.log("[HLS Pipeline] Network/Auth error loading \(variantDesc): \(error.localizedDescription). Falling back to next eligible variant in master playlist...")
                continue
            } catch let error as URLError {
                if isExplicitVariantSelection {
                    PipelineLogger.shared.log("[HLS Pipeline] URLError loading explicitly selected variant playlist: \(error.localizedDescription). Aborting without downgrade.")
                    throw error
                }
                lastPlanningError = error
                PipelineLogger.shared.log("[HLS Pipeline] URLError loading \(variantDesc): \(error.localizedDescription). Falling back to next eligible variant in master playlist...")
                continue
            } catch {
                if isExplicitVariantSelection {
                    PipelineLogger.shared.log("[HLS Pipeline] Unexpected error loading explicitly selected variant playlist: \(error.localizedDescription). Aborting without downgrade.")
                    throw error
                }
                lastPlanningError = error
                PipelineLogger.shared.log("[HLS Pipeline] Unexpected error loading \(variantDesc): \(error.localizedDescription). Falling back to next eligible variant in master playlist...")
                continue
            }

            let parsedChild: HLSManifest
            do {
                parsedChild = try HLSManifestParser.parse(
                    subResponse.data,
                    baseURL: subResponse.finalURL,
                    limits: parsingLimits
                )
            } catch let error as ManifestParserError {
                if isExplicitVariantSelection {
                    PipelineLogger.shared.log("[HLS Pipeline] Explicitly selected variant playlist failed to parse: \(error.localizedDescription). Aborting without downgrade.")
                    throw StreamingDownloadOrchestratorError.manifestParseFailed(error)
                }
                lastPlanningError = StreamingDownloadOrchestratorError.manifestParseFailed(error)
                PipelineLogger.shared.log("[HLS Pipeline] Child variant playlist failed to parse for \(variantDesc): \(error.localizedDescription). Falling back to next eligible variant...")
                continue
            }

            if parsedChild.playlistType == .master {
                // Nested master playlist: recursively evaluate compatible variant
                do {
                    let nestedContext = subResponse.redirectResolvedContext ?? currentContext?.redirectResolved(to: subResponse.finalURL)
                    let nestedSelection = try await resolveCompatibleHLSVariant(
                        manifest: parsedChild,
                        baseURL: subResponse.finalURL,
                        candidate: variantCandidate,
                        effectiveContext: nestedContext,
                        depth: depth + 1
                    )
                    let isNestedSampleAES = nestedSelection.mediaPlaylist.segments.contains { $0.encryption?.classification == .sampleEncrypted }
                    if isNestedSampleAES && rankedVariants.count > 1 && index < rankedVariants.count - 1 {
                        if deferredSampleAESSelection == nil {
                            deferredSampleAESSelection = nestedSelection
                        }
                        PipelineLogger.shared.log("[HLS Pipeline] \(variantDesc) resolved to Sample-AES nested variant. Deferring in preference of potential Clear/AES-128 variants...")
                        continue
                    }
                    return nestedSelection
                } catch StreamingDownloadOrchestratorError.unsupportedEncryption {
                    sawUnsupportedEncryption = true
                    PipelineLogger.shared.log("[HLS Pipeline] Nested master playlist rejected due to unsupported encryption. Trying next variant...")
                    await BrowserDiagnosticLogger.shared.log(
                        category: .policy,
                        message: "Nested HLS master playlist rejected due to unsupported encryption",
                        url: variantURI,
                        details: [
                            "bandwidth": "\(variant.bandwidth)",
                            "resolution": variantResolution,
                            "decision": "rejected",
                            "reason": "Unsupported encryption in nested master"
                        ]
                    )
                    continue
                } catch {
                    if isExplicitVariantSelection {
                        throw error
                    }
                    lastPlanningError = error
                    PipelineLogger.shared.log("[HLS Pipeline] Nested master playlist failed for \(variantDesc): \(error.localizedDescription). Falling back to next eligible variant...")
                    continue
                }
            }

            guard parsedChild.playlistType == .media else {
                PipelineLogger.shared.log("[HLS Pipeline] Expected media playlist for variant but got \(parsedChild.playlistType). Trying next variant...")
                continue
            }

            // Evaluate download compatibility with HLSTransferPlanner
            let childContext = subResponse.redirectResolvedContext ?? currentContext?.redirectResolved(to: subResponse.finalURL)
            let videoPlan: HLSVODTransferPlan
            do {
                videoPlan = try HLSTransferPlanner.makeVODPlan(
                    from: parsedChild,
                    browserRequestContext: childContext
                )
            } catch let error as HLSVODTransferPlanError {
                if case .unsupportedEncryption(let classification) = error {
                    sawUnsupportedEncryption = true
                    let reason = "Unsupported video encryption: \(classification.rawValue)"
                    PipelineLogger.shared.log("[HLS Pipeline] \(variantDesc) rejected: \(reason). Trying next variant...")
                    await BrowserDiagnosticLogger.shared.log(
                        category: .policy,
                        message: "HLS variant rejected: \(reason)",
                        url: variantURI,
                        details: [
                            "bandwidth": "\(variant.bandwidth)",
                            "resolution": variantResolution,
                            "encryption": classification.rawValue,
                            "decision": "rejected",
                            "reason": reason
                        ]
                    )
                    continue
                }
                lastPlanningError = error
                PipelineLogger.shared.log("[HLS Pipeline] \(variantDesc) planning failed: \(error.localizedDescription) (\(error)). Trying next variant...")
                continue
            }

            // Evaluate audio rendition compatibility if present
            var audioPlan: [HLSPlannedResource]? = nil
            var audioFailedUnsupported = false
            if let audioURI = selectedAudioRendition?.uri {
                PipelineLogger.shared.log("[HLS Pipeline] Separate audio rendition detected for \(variantDesc): \(audioURI.absoluteString). Fetching audio manifest...")
                let parentQuery = subResponse.finalURL.query ?? candidate.url.query
                let audioFinalURI = audioURI.mergingParentQuery(parentQuery)
                let audioCandidate = try StreamingManifestCandidate(
                    url: audioFinalURI,
                    mimeType: "application/vnd.apple.mpegurl",
                    browserRequestContext: childContext?.redirectResolved(to: audioFinalURI) ?? currentContext?.redirectResolved(to: audioFinalURI) ?? candidate.browserRequestContext,
                    browserSessionSnapshot: candidate.browserSessionSnapshot,
                    hlsVariantPreferences: candidate.hlsVariantPreferences,
                    transportPolicy: candidate.transportPolicy
                )
                let audioResponse: StreamingManifestResponse
                do {
                    audioResponse = try await loadManifestResponse(
                        candidate: audioCandidate,
                        headers: manifestHeaders(for: audioCandidate)
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as StreamingManifestLoadError {
                    if isExplicitVariantSelection {
                        PipelineLogger.shared.log("[HLS Pipeline] Explicitly selected variant separate audio failed to load: \(error.localizedDescription). Aborting without downgrade.")
                        throw error
                    }
                    lastPlanningError = error
                    PipelineLogger.shared.log("[HLS Pipeline] Failed to load separate audio playlist for \(variantDesc): \(error.localizedDescription). Falling back to next eligible variant...")
                    continue
                } catch let error as URLError {
                    if isExplicitVariantSelection {
                        PipelineLogger.shared.log("[HLS Pipeline] Explicitly selected variant separate audio network error: \(error.localizedDescription). Aborting without downgrade.")
                        throw error
                    }
                    lastPlanningError = error
                    PipelineLogger.shared.log("[HLS Pipeline] URLError loading separate audio playlist for \(variantDesc): \(error.localizedDescription). Falling back to next eligible variant...")
                    continue
                } catch {
                    if isExplicitVariantSelection {
                        PipelineLogger.shared.log("[HLS Pipeline] Explicitly selected variant separate audio error: \(error.localizedDescription). Aborting without downgrade.")
                        throw error
                    }
                    lastPlanningError = error
                    PipelineLogger.shared.log("[HLS Pipeline] Unexpected error loading separate audio playlist for \(variantDesc): \(error.localizedDescription). Falling back to next eligible variant...")
                    continue
                }

                let parsedAudio: HLSManifest
                do {
                    parsedAudio = try HLSManifestParser.parse(
                        audioResponse.data,
                        baseURL: audioResponse.finalURL,
                        limits: parsingLimits
                    )
                } catch let error as ManifestParserError {
                    if isExplicitVariantSelection {
                        PipelineLogger.shared.log("[HLS Pipeline] Explicitly selected variant separate audio failed to parse: \(error.localizedDescription). Aborting without downgrade.")
                        throw StreamingDownloadOrchestratorError.manifestParseFailed(error)
                    }
                    lastPlanningError = StreamingDownloadOrchestratorError.manifestParseFailed(error)
                    PipelineLogger.shared.log("[HLS Pipeline] Separate audio playlist failed to parse for \(variantDesc): \(error.localizedDescription). Falling back to next eligible variant...")
                    continue
                }

                guard parsedAudio.playlistType == .media else {
                    PipelineLogger.shared.log("[HLS Pipeline] Separate audio playlist is not a media playlist. Trying next variant...")
                    continue
                }

                do {
                    let audioPlanContext = audioResponse.redirectResolvedContext ?? childContext?.redirectResolved(to: audioResponse.finalURL) ?? currentContext?.redirectResolved(to: audioResponse.finalURL)
                    let parsedAudioPlan = try HLSTransferPlanner.makeVODPlan(
                        from: parsedAudio,
                        browserRequestContext: audioPlanContext
                    )
                    audioPlan = parsedAudioPlan.resources
                } catch let error as HLSVODTransferPlanError {
                    if case .unsupportedEncryption(let classification) = error {
                        sawUnsupportedEncryption = true
                        audioFailedUnsupported = true
                        let reason = "Unsupported audio encryption: \(classification.rawValue)"
                        PipelineLogger.shared.log("[HLS Pipeline] \(variantDesc) rejected: \(reason). Trying next variant...")
                        await BrowserDiagnosticLogger.shared.log(
                            category: .policy,
                            message: "HLS variant rejected: \(reason)",
                            url: variantURI,
                            details: [
                                "bandwidth": "\(variant.bandwidth)",
                                "resolution": variantResolution,
                                "encryption": classification.rawValue,
                                "decision": "rejected",
                                "reason": reason
                            ]
                        )
                    } else {
                        lastPlanningError = error
                    }
                }
            }

            if audioFailedUnsupported {
                continue
            }

            // Both video (and separate audio, if present) are compatible!
            let encryptionType = parsedChild.segments.first?.encryption?.classification.rawValue ?? "Clear"
            PipelineLogger.shared.log("[HLS Pipeline] Successfully selected compatible \(variantDesc) [encryption=\(encryptionType)].")
            await BrowserDiagnosticLogger.shared.log(
                category: .policy,
                message: "HLS compatible variant selected",
                url: variantURI,
                details: [
                    "bandwidth": "\(variant.bandwidth)",
                    "resolution": variantResolution,
                    "encryption": encryptionType,
                    "decision": "accepted",
                    "selectedVariant": variantURI.absoluteString
                ]
            )

            let selection = ResolvedHLSSelection(
                mediaPlaylist: parsedChild,
                mediaURL: subResponse.finalURL,
                selectedVariant: variant,
                selectedVariantBandwidth: variant.bandwidth,
                videoPlan: videoPlan,
                audioPlan: audioPlan,
                selectedSubtitleRendition: selectedSubtitleRendition
            )

            let isSampleAES = parsedChild.segments.contains { $0.encryption?.classification == .sampleEncrypted }
            if isSampleAES && rankedVariants.count > 1 && index < rankedVariants.count - 1 {
                if deferredSampleAESSelection == nil {
                    deferredSampleAESSelection = selection
                }
                PipelineLogger.shared.log("[HLS Pipeline] \(variantDesc) uses Sample-AES. Deferring in preference of potential Clear/AES-128 variants...")
                continue
            }

            return selection
        }

        if let deferred = deferredSampleAESSelection {
            PipelineLogger.shared.log("[HLS Pipeline] No Clear or AES-128 variants available; proceeding with compatible Sample-AES variant.")
            return deferred
        }

        if sawUnsupportedEncryption {
            PipelineLogger.shared.log("[HLS Pipeline] All evaluated variants use unsupported encryption.")
            throw StreamingDownloadOrchestratorError.unsupportedEncryption
        }
        if let planErr = lastPlanningError as? HLSVODTransferPlanError {
            throw StreamingDownloadOrchestratorError.hlsPlanningFailed(planErr)
        }
        if let lastErr = lastPlanningError {
            throw lastErr
        }
        throw StreamingDownloadOrchestratorError.playlistRequiresVariantSelection
    }

    func parseManifest(
        data: Data,
        finalURL: URL,
        mimeType: String?,
        candidate: StreamingManifestCandidate,
        classification: StreamingManifestClassification,
        redirectResolvedContext: BrowserRequestContext? = nil
    ) async throws -> StreamingTransferManifest {
        let effectiveContext = redirectResolvedContext ?? candidate.browserRequestContext?.redirectResolved(to: finalURL)
        switch classification.kind {
        case .hls:
            PipelineLogger.shared.log("[HLS Pipeline] 1. Manifest fetched from \(finalURL.absoluteString) (\(data.count) bytes). Parsing with HLSManifestParser...")
            let initialParsed = try HLSManifestParser.parse(
                data,
                baseURL: finalURL,
                limits: parsingLimits
            )
            PipelineLogger.shared.log("[HLS Pipeline] 2. HLSManifestParser initial parse completed: playlistType=\(initialParsed.playlistType), variants=\(initialParsed.variants.count), segments=\(initialParsed.segments.count)")

            let resolved = try await resolveCompatibleHLSVariant(
                manifest: initialParsed,
                baseURL: finalURL,
                candidate: candidate,
                effectiveContext: effectiveContext
            )

            let totalEstimatedBytes: Int64?
            if let videoBytes = resolved.videoPlan.estimatedTransferBytes {
                let audioBytes = resolved.audioPlan?.reduce(Int64(0)) { $0 + ($1.byteRange?.length ?? 0) } ?? 0
                totalEstimatedBytes = videoBytes + audioBytes
            } else if let bw = resolved.selectedVariantBandwidth, bw > 0 {
                let totalDuration = resolved.mediaPlaylist.segments.reduce(0.0) { $0 + $1.duration }
                let effectiveDuration = totalDuration > 0 ? totalDuration : (Double(resolved.mediaPlaylist.segments.count) * 6.0)
                let videoBytes = Int64(Double(bw) / 8.0 * effectiveDuration)
                let audioBytes = resolved.audioPlan?.reduce(Int64(0)) { $0 + ($1.byteRange?.length ?? 0) } ?? 0
                totalEstimatedBytes = videoBytes + audioBytes
            } else {
                totalEstimatedBytes = nil
            }

            var resolvedSubtitleURL: URL? = resolved.selectedSubtitleRendition?.uri
            if let subURI = resolvedSubtitleURL {
                let parentQuery = resolved.mediaURL.query ?? candidate.url.query
                resolvedSubtitleURL = subURI.mergingParentQuery(parentQuery)
                PipelineLogger.shared.log("[HLS Pipeline] Subtitle stream detected: \(resolvedSubtitleURL?.absoluteString ?? "")")
            }

            let plan = HLSVODTransferPlan(
                manifestURL: resolved.videoPlan.manifestURL,
                resources: resolved.videoPlan.resources,
                browserRequestContext: resolved.videoPlan.browserRequestContext ?? effectiveContext,
                estimatedTransferBytes: totalEstimatedBytes,
                audioPlan: resolved.audioPlan,
                subtitleURL: resolvedSubtitleURL
            )
            return .hls(plan)
        case .dash:
            let parsed = try DASHManifestParser.parse(
                data,
                baseURL: finalURL,
                limits: parsingLimits
            )
            var sidxDataMap: [String: Data] = [:]
            for period in parsed.periods {
                for adaptationSet in period.adaptationSets {
                    for rep in adaptationSet.representations {
                        if let base = rep.segmentBase,
                           let indexRange = base.indexRange,
                           let repID = rep.id {
                            let targetURL = rep.baseURL ?? adaptationSet.baseURL ?? period.baseURL ?? parsed.baseURL ?? finalURL
                            if let sidxBytes = try? await fetchByteRange(url: targetURL, rangeString: indexRange, candidate: candidate) {
                                sidxDataMap[repID] = sidxBytes
                            }
                        }
                    }
                }
            }
            let isTextCandidate = candidate.dashTextRepresentationID != nil &&
                                  candidate.dashVideoRepresentationID == nil &&
                                  candidate.dashAudioRepresentationID == nil
            let plan: DASHVODTransferPlan
            do {
                plan = try DASHTransferPlanner.makeVODPlan(
                    from: parsed,
                    videoRepresentationID: candidate.dashVideoRepresentationID,
                    audioRepresentationID: candidate.dashAudioRepresentationID,
                    textRepresentationID: candidate.dashTextRepresentationID,
                    isTextOnly: isTextCandidate,
                    browserRequestContext: effectiveContext,
                    sidxDataByRepresentationID: sidxDataMap
                )
            } catch let error as DASHVODTransferPlanError {
                if case .drmProtectedRepresentation = error {
                    throw StreamingDownloadOrchestratorError.unsupportedEncryption
                }
                throw StreamingDownloadOrchestratorError.dashPlanningFailed(error)
            }
            return .dash(plan)
        case .unknown, .unsupported:
            throw StreamingDownloadOrchestratorError.manifestNotRecognized
        }
    }

    public func execute(
        _ proposal: StreamingTransferProposal,
        approved: Bool,
        destinationDirectory: URL,
        progress: (@Sendable (StreamingTransferProgress) -> Void)? = nil
    ) async throws -> StreamingTransferResult {
        guard approved else { throw StreamingDownloadOrchestratorError.userDeclined }
        if let completed = completedTransfers[proposal.transferID] {
            return completed
        }
        guard runningTransfers.insert(proposal.transferID).inserted else {
            throw StreamingDownloadOrchestratorError.transferAlreadyRunning
        }
        defer {
            runningTransfers.remove(proposal.transferID)
            pausedTransfers.remove(proposal.transferID)
            cancelledTransfers.remove(proposal.transferID)
        }

        let pipelineTag = proposal.manifest.kind == .dash ? "[DASH Pipeline]" : "[HLS Pipeline]"
        let maxConcurrency = 6
        PipelineLogger.shared.log("\(pipelineTag) Step 2: Parallel segment download started (Max concurrency: \(maxConcurrency))")

        // Ensure destination directory exists before preflight and transfers
        try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(destinationDirectory)

        // When transport policy is background and background manager is available,
        // proactively schedule segments into the background URLSession transport so they
        // continue progressing durably across app suspension or termination.
        if proposal.transportPolicy == .background, let bgManager = self.backgroundSessionManager {
            PipelineLogger.shared.log("\(pipelineTag) Proactively scheduling streaming segments in background URLSession...")
            _ = try? await scheduleBackgroundStreaming(
                proposal: proposal,
                destinationDirectory: destinationDirectory,
                backgroundManager: bgManager
            )
        }

        // Preflight disk space verification before downloading streaming segments
        if let estimatedSize = proposal.estimatedTotalBytes, estimatedSize > 0 {
            #if canImport(Darwin)
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
            if let values = try? destinationDirectory.resourceValues(forKeys: keys) {
                let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
                if available > 0 {
                    if available < estimatedSize {
                        PipelineLogger.shared.log("\(pipelineTag) Insufficient disk space for \(destinationDirectory.path): required \(estimatedSize) bytes, available \(available) bytes")
                        throw StreamingDownloadOrchestratorError.insufficientDiskSpace(required: estimatedSize, available: available)
                    } else {
                        PipelineLogger.shared.log("\(pipelineTag) Disk capacity verified: \(available) bytes available (required \(estimatedSize) bytes)")
                    }
                } else {
                    PipelineLogger.shared.log("\(pipelineTag) Disk capacity unavailable from volume for \(destinationDirectory.path); proceeding with transfer")
                }
            } else {
                PipelineLogger.shared.log("\(pipelineTag) Disk capacity query unhandled for \(destinationDirectory.path); proceeding with transfer")
            }
            #else
            let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey]
            if let values = try? destinationDirectory.resourceValues(forKeys: keys) {
                let available = values.volumeAvailableCapacity.map(Int64.init) ?? 0
                if available > 0 {
                    if available < estimatedSize {
                        PipelineLogger.shared.log("\(pipelineTag) Insufficient disk space for \(destinationDirectory.path): required \(estimatedSize) bytes, available \(available) bytes")
                        throw StreamingDownloadOrchestratorError.insufficientDiskSpace(required: estimatedSize, available: available)
                    } else {
                        PipelineLogger.shared.log("\(pipelineTag) Disk capacity verified: \(available) bytes available (required \(estimatedSize) bytes)")
                    }
                } else {
                    PipelineLogger.shared.log("\(pipelineTag) Disk capacity unavailable from volume for \(destinationDirectory.path); proceeding with transfer")
                }
            } else {
                PipelineLogger.shared.log("\(pipelineTag) Disk capacity query unhandled for \(destinationDirectory.path); proceeding with transfer")
            }
            #endif
        }

        let totalSegments = proposal.resources.count
        let parentID = proposal.manifest.kind == .hls ? hlsParentID(for: proposal) : proposal.transferID

        if case .hls(let plan) = proposal.manifest, let persistence = hlsPersistenceStore {
            let existingRecord: HLSTransferRecord?
            do {
                existingRecord = try await persistence.load(id: parentID)
            } catch {
                PipelineLogger.shared.log("[HLS Pipeline] Warning: Failed to load parent record \(parentID): \(error.localizedDescription)")
                existingRecord = nil
            }
            if existingRecord == nil {
                let filename = HLSVODReconstructionPlanner.suggestedFilename(for: plan)
                let initialRecord = HLSTransferRecord(
                    id: parentID,
                    manifestURL: proposal.manifest.manifestURL,
                    outputFilename: filename,
                    outputDestinationURL: destinationDirectory.appendingPathComponent(filename),
                    segmentDirectoryURL: destinationDirectory,
                    totalSegments: totalSegments,
                    completedSegmentOrders: [],
                    state: .downloading,
                    assemblyState: .notStarted
                )
                do {
                    try await persistence.save(initialRecord)
                    guard let verified = try await persistence.load(id: parentID), verified.id == parentID else {
                        throw StreamingDownloadOrchestratorError.persistenceFailed(
                            "Failed to establish durable parent checkpoint for \(parentID): Record verification failed after save"
                        )
                    }
                    PipelineLogger.shared.log("[HLS Pipeline] Durable parent checkpoint created and verified for: \(parentID)")
                } catch {
                    PipelineLogger.shared.log("[HLS Pipeline] Critical: Failed to establish durable parent checkpoint for \(parentID): \(error.localizedDescription)")
                    throw error
                }
            }
        } else if case .dash(let plan) = proposal.manifest, let persistence = dashPersistenceStore {
            let existingRecord: DASHTransferRecord?
            do {
                existingRecord = try await persistence.load(id: parentID)
            } catch {
                PipelineLogger.shared.log("[DASH Pipeline] Warning: Failed to load parent record \(parentID): \(error.localizedDescription)")
                existingRecord = nil
            }
            if existingRecord == nil {
                let isTextOnly = plan.video == nil && plan.audio == nil && plan.text != nil
                let isTTML = plan.text?.codecs?.lowercased().contains("ttml") == true ||
                             plan.text?.codecs?.lowercased().contains("stpp") == true ||
                             plan.text?.codecs?.lowercased().contains("im1t") == true ||
                             plan.text?.resources.contains(where: {
                                 let ext = $0.url.pathExtension.lowercased()
                                 return ext == "ttml" || ext == "xml"
                             }) == true
                let filename: String
                if isTextOnly {
                    let baseName = DASHVODReconstructionPlanner.suggestedFilename(for: plan)
                    let ext = isTTML ? "ttml" : "vtt"
                    filename = (baseName as NSString).deletingPathExtension + "." + ext
                } else {
                    filename = DASHVODReconstructionPlanner.suggestedFilename(for: plan)
                }
                let initialRecord = DASHTransferRecord(
                    id: parentID,
                    manifestURL: proposal.manifest.manifestURL,
                    outputFilename: filename,
                    outputDestinationURL: destinationDirectory.appendingPathComponent(filename),
                    segmentDirectoryURL: destinationDirectory,
                    videoRepresentationID: plan.video?.representationID,
                    audioRepresentationID: plan.audio?.representationID,
                    textRepresentationID: plan.text?.representationID,
                    isTextOnly: isTextOnly,
                    isTTML: isTTML,
                    totalSegments: totalSegments,
                    completedSegmentOrders: [],
                    state: .downloading,
                    assemblyState: .notStarted
                )
                do {
                    try await persistence.save(initialRecord)
                    PipelineLogger.shared.log("[DASH Pipeline] Durable parent checkpoint created and verified for: \(parentID)")
                } catch {
                    PipelineLogger.shared.log("[DASH Pipeline] Critical: Failed to establish durable parent checkpoint for \(parentID): \(error.localizedDescription)")
                    throw error
                }
            }
        }
        var completedIdentities: [StreamingSegmentIdentity?] = Array(repeating: nil, count: totalSegments)
        var localFiles: [URL?] = Array(repeating: nil, count: totalSegments)
        var completedCount: Int = 0
        var actualDownloadedBytes: Int64 = 0
        var lastSpeedCheckTime = Date()
        var lastSpeedCheckBytes: Int64 = 0
        var currentBytesPerSecond: Double = 0.0

        // Rehydrate the durable HLS/DASH checkpoint before creating workers. A
        // completed order is reusable only when its file still exists in the
        // same segment directory (and, for ranged resources, has the expected
        // length). This keeps a stale checkpoint from being treated as a
        // completed segment while avoiding any segment task for valid work.
        var persistedCompletedOrders: Set<Int> = []
        var persistedSegmentDirectory: URL?
        if proposal.manifest.kind == .hls,
           let persistence = hlsPersistenceStore {
            do {
                if let record = try await persistence.load(id: parentID) {
                    persistedCompletedOrders = record.completedSegmentOrders
                    persistedSegmentDirectory = record.segmentDirectoryURL
                }
            } catch {
                throw persistenceFailure(error)
            }
        } else if proposal.manifest.kind == .dash,
                  let persistence = dashPersistenceStore {
            do {
                if let record = try await persistence.load(id: parentID) {
                    persistedCompletedOrders = record.completedSegmentOrders
                    persistedSegmentDirectory = record.segmentDirectoryURL
                }
            } catch {
                throw persistenceFailure(error)
            }
        }

        var pendingIndices: [Int] = []
        for index in proposal.resources.indices {
            let resource = proposal.resources[index]
            var destinationURL = destinationDirectory.appendingPathComponent(
                "\(resource.identity.value).part",
                isDirectory: false
            )

            var fileExists = FileManager.default.fileExists(atPath: destinationURL.path)
            if !fileExists, let altDir = persistedSegmentDirectory {
                let altURL = altDir.appendingPathComponent("\(resource.identity.value).part", isDirectory: false)
                if FileManager.default.fileExists(atPath: altURL.path) {
                    do {
                        try FileManager.default.copyItem(at: altURL, to: destinationURL)
                        PipelineLogger.shared.log("[FileSystem] Recovered segment from \(altURL.path) to \(destinationURL.path)")
                    } catch {
                        let nsErr = error as NSError
                        PipelineLogger.shared.log("[FileSystem] Failed to copy recovered segment from \(altURL.path) to \(destinationURL.path): \(nsErr.localizedDescription) (Domain: \(nsErr.domain), Code: \(nsErr.code))")
                    }
                    fileExists = FileManager.default.fileExists(atPath: destinationURL.path)
                    if !fileExists {
                        destinationURL = altURL
                        fileExists = true
                    }
                }
            }

            guard persistedCompletedOrders.contains(resource.identity.order),
                  fileExists else {
                pendingIndices.append(index)
                continue
            }

            let fileSize = FileManager.default.fileSize(atPath: destinationURL.path) ?? 0
            if let byteRange = resource.byteRange, fileSize != byteRange.length {
                pendingIndices.append(index)
                continue
            }

            completedIdentities[index] = resource.identity
            localFiles[index] = destinationURL
            completedCount += 1
            actualDownloadedBytes += fileSize
        }

        do {
            try await withThrowingTaskGroup(of: DownloadedSegmentResult.self) { group in
                var nextPendingPosition = 0

                // Launch initial concurrency pool up to maxConcurrency
                while nextPendingPosition < pendingIndices.count && nextPendingPosition < maxConcurrency {
                    let indexToDownload = pendingIndices[nextPendingPosition]
                    let resource = proposal.resources[indexToDownload]
                    nextPendingPosition += 1

                    group.addTask {
                        try await self.downloadSegment(
                            resource: resource,
                            index: indexToDownload,
                            proposal: proposal,
                            destinationDirectory: destinationDirectory,
                            pipelineTag: pipelineTag
                        )
                    }
                }

                // Process completions as segments finish (handling out-of-order completion safely)
                while let result = try await group.next() {
                    if isCancelled(transferID: proposal.transferID) || Task.isCancelled {
                        group.cancelAll()
                        PipelineLogger.shared.log("\(pipelineTag) Transfer was cancelled.")
                        throw StreamingDownloadOrchestratorError.cancelled
                    }

                    while isPaused(transferID: proposal.transferID) {
                        try await Task.sleep(nanoseconds: 250_000_000)
                        if isCancelled(transferID: proposal.transferID) || Task.isCancelled {
                            group.cancelAll()
                            PipelineLogger.shared.log("\(pipelineTag) Transfer was cancelled while paused.")
                            throw StreamingDownloadOrchestratorError.cancelled
                        }
                    }

                    // Save segment result to its original, deterministic order index
                    completedIdentities[result.index] = result.identity
                    localFiles[result.index] = result.destinationURL
                    completedCount += 1
                    actualDownloadedBytes += result.downloadedBytes

                    let now = Date()
                    let timeDelta = now.timeIntervalSince(lastSpeedCheckTime)
                    if timeDelta >= 0.5 {
                        currentBytesPerSecond = Double(actualDownloadedBytes - lastSpeedCheckBytes) / timeDelta
                        lastSpeedCheckTime = now
                        lastSpeedCheckBytes = actualDownloadedBytes
                    }

                    let currentFraction = Double(completedCount) / Double(max(1, totalSegments))
                    progress?(StreamingTransferProgress(
                        transferID: proposal.transferID,
                        completedSegments: completedCount,
                        totalSegments: totalSegments,
                        currentOrder: result.identity.order,
                        currentFraction: currentFraction
                    ))

                    if let engine = self.downloadEngine {
                        let estimatedTotal = proposal.estimatedTransferBytes ?? (Int64(totalSegments) * 1_000_000)
                        await engine.updateStreamingDownloadProgress(
                            id: parentID,
                            completedBytes: actualDownloadedBytes,
                            totalBytes: estimatedTotal,
                            bytesPerSecond: currentBytesPerSecond
                        )
                    }

                    // Durably record this segment as completed for crash/restart recovery.
                    if proposal.manifest.kind == .hls, let persistence = hlsPersistenceStore {
                        do {
                            _ = try await persistence.markSegmentCompleted(
                                id: parentID,
                                order: result.identity.order
                            )
                        } catch {
                            PipelineLogger.shared.log(
                                "\(pipelineTag) Checkpoint write failed for order \(result.identity.order): \(error.localizedDescription)"
                            )
                            throw persistenceFailure(error)
                        }
                    } else if proposal.manifest.kind == .dash, let persistence = dashPersistenceStore {
                        do {
                            _ = try await persistence.updateCompletedSegmentOrders(
                                id: parentID,
                                completedOrders: [result.identity.order]
                            )
                        } catch {
                            PipelineLogger.shared.log(
                                "\(pipelineTag) Checkpoint write failed for order \(result.identity.order): \(error.localizedDescription)"
                            )
                            throw persistenceFailure(error)
                        }
                    }

                    // Replenish worker pool with next segment
                    if nextPendingPosition < pendingIndices.count {
                        let indexToDownload = pendingIndices[nextPendingPosition]
                        let resource = proposal.resources[indexToDownload]
                        nextPendingPosition += 1

                        group.addTask {
                            try await self.downloadSegment(
                                resource: resource,
                                index: indexToDownload,
                                proposal: proposal,
                                destinationDirectory: destinationDirectory,
                                pipelineTag: pipelineTag
                            )
                        }
                    }
                }
            }
        } catch is CancellationError {
            PipelineLogger.shared.log("\(pipelineTag) Error: Segment download cancelled.")
            if !isPaused(transferID: parentID) && !isPaused(transferID: proposal.transferID) && !isHandoffInProgress(transferID: parentID) && !isHandoffInProgress(transferID: proposal.transferID) {
                await handleHLSCancellation(
                    parentID: parentID,
                    transferID: proposal.transferID,
                    proposal: proposal.manifest.kind == .hls ? proposal : nil
                )
            }
            throw StreamingDownloadOrchestratorError.cancelled
        } catch let error as StreamingDownloadOrchestratorError {
            PipelineLogger.shared.log("\(pipelineTag) Error: \(error.localizedDescription)")
            if case .cancelled = error {
                if !isPaused(transferID: parentID) && !isPaused(transferID: proposal.transferID) && !isHandoffInProgress(transferID: parentID) && !isHandoffInProgress(transferID: proposal.transferID) {
                    await handleHLSCancellation(
                        parentID: parentID,
                        transferID: proposal.transferID,
                        proposal: proposal.manifest.kind == .hls ? proposal : nil
                    )
                }
            }
            throw error
        } catch {
            PipelineLogger.shared.log("\(pipelineTag) Error: \(error.localizedDescription)")
            throw error
        }

        let orderedCompleted = completedIdentities.compactMap { $0 }
        let orderedLocalFiles = localFiles.compactMap { $0 }
        guard orderedCompleted.count == totalSegments && orderedLocalFiles.count == totalSegments else {
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: -1)
        }

        let result = StreamingTransferResult(
            transferID: proposal.transferID,
            completedSegments: orderedCompleted,
            localFiles: orderedLocalFiles
        )
        completedTransfers[proposal.transferID] = result
        return result
    }

    struct DownloadedSegmentResult: Sendable {
        let index: Int
        let identity: StreamingSegmentIdentity
        let destinationURL: URL
        let downloadedBytes: Int64
    }

    func shouldAttemptTokenRefresh(for error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let orchError = error as? StreamingDownloadOrchestratorError, orchError == .cancelled {
            return false
        }
        if error is CocoaError {
            return false
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return false
        }
        if let coordError = error as? DownloadCoordinatorError {
            switch coordError {
            case .tokenExpired, .accessDenied, .linkExpired:
                return true
            default:
                return false
            }
        }
        if let segError = error as? SegmentDownloaderError {
            switch segError {
            case .tokenExpired, .accessDenied, .linkExpired:
                return true
            default:
                return false
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return shouldAttemptTokenRefresh(for: underlying)
        }
        return false
    }

    func downloadSegment(
        resource: StreamingTransferResource,
        index: Int,
        proposal: StreamingTransferProposal,
        destinationDirectory: URL,
        pipelineTag: String
    ) async throws -> DownloadedSegmentResult {
        let destinationURL = destinationDirectory.appendingPathComponent(
            "\(resource.identity.value).part",
            isDirectory: false
        )

        // A completed HLS segment is atomically written before its parent
        // checkpoint is committed. Reuse it on restart, including ordinary
        // (non-byte-range) HLS segments.
        if let persistence = hlsPersistenceStore,
           proposal.manifest.kind == .hls,
           let record = try? await persistence.load(id: hlsParentID(for: proposal)),
           record.segmentDirectoryURL.standardizedFileURL.path == destinationDirectory.standardizedFileURL.path,
           record.completedSegmentOrders.contains(resource.identity.order),
           FileManager.default.fileExists(atPath: destinationURL.path) {
            let size = FileManager.default.fileSize(atPath: destinationURL.path) ?? 0
            let hasExpectedLength = resource.byteRange.map { $0.length == size } ?? true
            if size > 0 && hasExpectedLength {
                return DownloadedSegmentResult(
                    index: index,
                    identity: resource.identity,
                    destinationURL: destinationURL,
                    downloadedBytes: size
                )
            }
        }

        // A completed DASH segment is atomically written before its parent
        // checkpoint is committed. Reuse it on restart.
        if let persistence = dashPersistenceStore,
           proposal.manifest.kind == .dash,
           let record = try? await persistence.load(id: proposal.transferID),
           record.segmentDirectoryURL.standardizedFileURL.path == destinationDirectory.standardizedFileURL.path,
           record.completedSegmentOrders.contains(resource.identity.order),
           FileManager.default.fileExists(atPath: destinationURL.path) {
            let size = FileManager.default.fileSize(atPath: destinationURL.path) ?? 0
            let hasExpectedLength = resource.byteRange.map { $0.length == size } ?? true
            if size > 0 && hasExpectedLength {
                return DownloadedSegmentResult(
                    index: index,
                    identity: resource.identity,
                    destinationURL: destinationURL,
                    downloadedBytes: size
                )
            }
        }

        if let range = resource.byteRange,
           FileManager.default.fileExists(atPath: destinationURL.path),
           let size = FileManager.default.fileSize(atPath: destinationURL.path),
           size > 0,
           size == range.length {
            return DownloadedSegmentResult(
                index: index,
                identity: resource.identity,
                destinationURL: destinationURL,
                downloadedBytes: size
            )
        }

        let targetURL: URL
        if let urlResolver {
            targetURL = (try? await urlResolver.resolveMediaURL(resource.url)) ?? resource.url
        } else {
            targetURL = resource.url
        }

        let request = StreamingSegmentTransferRequest(
            identity: resource.identity,
            url: targetURL,
            headers: await segmentRequestHeaders(for: resource, manifest: proposal.manifest, transferID: proposal.transferID),
            byteRange: resource.byteRange,
            destinationURL: destinationURL,
            allowedCredentialOrigins: proposal.browserRequestContext?.allowedCredentialOrigins ?? [],
            transportPolicy: proposal.transportPolicy
        )

        var attempts = 0
        let maxAttempts = max(1, (configuration.maxRetryAttempts > 0 ? configuration.maxRetryAttempts + 1 : 3))

        while true {
            try Task.checkCancellation()
            let parentID = hlsParentID(for: proposal)
            if isPaused(transferID: proposal.transferID) || isPaused(transferID: parentID) ||
               isHandoffInProgress(transferID: proposal.transferID) || isHandoffInProgress(transferID: parentID) {
                throw StreamingDownloadOrchestratorError.cancelled
            }
            do {
                try await segmentExecutor.execute(request, progress: nil)
                break
            } catch is CancellationError {
                throw StreamingDownloadOrchestratorError.cancelled
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                throw StreamingDownloadOrchestratorError.cancelled
            } catch let err as StreamingDownloadOrchestratorError where err == .cancelled {
                throw err
            } catch {
                if isPaused(transferID: proposal.transferID) || isPaused(transferID: parentID) ||
                   isCancelled(transferID: proposal.transferID) || isCancelled(transferID: parentID) ||
                   isHandoffInProgress(transferID: proposal.transferID) || isHandoffInProgress(transferID: parentID) {
                    throw StreamingDownloadOrchestratorError.cancelled
                }
                attempts += 1
                if attempts < maxAttempts && HTTPRetryPolicy.isRetryable(error) {
                    PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) encountered transient network error: \(error.localizedDescription). Retrying attempt \(attempts + 1)/\(maxAttempts)...")
                    let backoff = min(2.0, Double(attempts) * 0.5)
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue
                }

                guard shouldAttemptTokenRefresh(for: error) else {
                    PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) failed with non-refreshable error: \(error.localizedDescription)")
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
                }
                // Retry once with refreshed manifest tokens in case the session expired during pause
                PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) encountered authorization/expiration error: \(error.localizedDescription). Attempting token refresh...")
                if let candidate = candidatesByTransfer[proposal.transferID] {
                    let oldFingerprint = proposalFingerprint(for: candidate)
                    proposals.removeValue(forKey: oldFingerprint)
                    proposals.removeValue(forKey: proposal.transferID)

                    // Fetch fresh dynamic cookies and refresh candidate context
                    let dynamicFresh = await DownloadRequestEnricher.dynamicCookies(for: candidate.url)
                    let freshCandidate = candidate.withRefreshedCookies(
                        snapshot: DownloadRequestEnricher.sharedSessionSnapshot.snapshot,
                        freshCookies: dynamicFresh.compactMap(BrowserCookie.init(from:))
                    )
                    candidatesByTransfer[proposal.transferID] = freshCandidate
                    let freshFingerprint = proposalFingerprint(for: freshCandidate)
                    proposals.removeValue(forKey: freshFingerprint)

                    if let freshProposal = try? await prepare(candidate: freshCandidate),
                       let freshResource = freshProposal.resources.first(where: { $0.identity.order == resource.identity.order }) {
                        PipelineLogger.shared.log("\(pipelineTag) Successfully refreshed manifest. Retrying segment \(resource.identity.order)...")
                        let freshHeaders = await segmentRequestHeaders(
                            for: freshResource,
                            manifest: freshProposal.manifest,
                            transferID: proposal.transferID
                        )
                        let freshRequest = StreamingSegmentTransferRequest(
                            identity: freshResource.identity,
                            url: freshResource.url,
                            headers: freshHeaders,
                            byteRange: freshResource.byteRange,
                            destinationURL: destinationURL,
                            allowedCredentialOrigins: freshProposal.browserRequestContext?.allowedCredentialOrigins ?? proposal.browserRequestContext?.allowedCredentialOrigins ?? [],
                            transportPolicy: proposal.transportPolicy
                        )
                        do {
                            try await segmentExecutor.execute(freshRequest, progress: nil)
                            break
                        } catch {
                            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
                        }
                    } else {
                        throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
                    }
                } else {
                    throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
                }
            }
        }

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) destination file missing at \(destinationURL.path)")
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
        }
        let segSize = FileManager.default.fileSize(atPath: destinationURL.path) ?? 0
        guard segSize > 0 else {
            PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) destination file is empty (0 bytes) at \(destinationURL.path)")
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
        }
        if let expectedLength = resource.byteRange?.length, segSize != expectedLength {
            PipelineLogger.shared.log("\(pipelineTag) Segment \(resource.identity.order) size mismatch: expected \(expectedLength), got \(segSize)")
            throw StreamingDownloadOrchestratorError.segmentTransferFailed(order: resource.identity.order)
        }

        return DownloadedSegmentResult(
            index: index,
            identity: resource.identity,
            destinationURL: destinationURL,
            downloadedBytes: segSize
        )
    }

    /// Executes a finite HLS proposal through the existing segment executor and
    /// then reconstructs the downloaded resources into one validated media file.
}
