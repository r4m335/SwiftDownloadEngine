import Foundation

#if canImport(WebKit)
import WebKit
#endif

/// Telemetry and diagnostic counters for media and resource discovery.
public struct DiscoveryTelemetry: Sendable, Equatable {
    public var droppedStaleDocumentObservationsCount: Int = 0
    public var deduplicatedCandidatesCount: Int = 0
    public var evictedCandidatesCount: Int = 0
    public var probeTimeoutsCount: Int = 0
    public var prunedCorruptedOrExpiredManifestsCount: Int = 0
    public var totalObservationsReceived: Int = 0
    public var totalCandidatesCataloged: Int = 0

    public init() {}

    public mutating func reset() {
        self = DiscoveryTelemetry()
    }
}

/// Coordinates media discovery across live DOM extraction, script bridge message observations,
/// media candidate cataloging, tab-scoped caches, and adaptive streaming manifest expansion.
///
/// Decouples all discovery, inspection, and catalog synchronization logic from UI view models.
@MainActor
public final class BrowserResourceDiscoveryCoordinator: ObservableObject {
    public let bridge: BrowserMediaDiscoveryBridge
    public let streamManifestExpander: StreamManifestResourceExpander

    // Published discovery state for the active tab
    @Published public var discoveredResources: [WebpageResource] = [] {
        didSet { onStateChanged?() }
    }
    @Published public var variantStreamItems: [String: HLSVariantStreamItem] = [:] {
        didSet { onStateChanged?() }
    }
    @Published public var selectedResourceIDs: Set<String> = [] {
        didSet { onStateChanged?() }
    }
    @Published public var mediaCandidates: [BrowserMediaCandidate] = [] {
        didSet { onStateChanged?() }
    }
    @Published public var isScanningResources: Bool = false {
        didSet { onStateChanged?() }
    }
    @Published public var resourceScanError: String? = nil {
        didSet { onStateChanged?() }
    }
    @Published public var telemetry = DiscoveryTelemetry()

    public var onStateChanged: (() -> Void)?

    // Tab-scoped media grabber candidate & variant caches
    public var tabResourceStates: [UUID: BrowserTabResourceState] = [:]
    public var tabDiscoveredResources: [UUID: [WebpageResource]] = [:]
    public var tabVariantStreamItems: [UUID: [String: HLSVariantStreamItem]] = [:]
    public var tabSelectedResourceIDs: [UUID: Set<String>] = [:]
    public var mediaCandidateCatalogs: [UUID: BrowserMediaCandidateCatalog] = [:]
    private var activeProbeTasks: [UUID: [Task<Void, Never>]] = [:]

    // Document generation and navigation correlation
    public var tabDocumentGenerations: [UUID: UInt64] = [:]
    public var tabNavigationGenerations: [UUID: UInt64] = [:]
    public var tabDocumentIDs: [UUID: String] = [:]

    public init(
        bridge: BrowserMediaDiscoveryBridge? = nil,
        streamManifestExpander: StreamManifestResourceExpander = .shared
    ) {
        self.bridge = bridge ?? BrowserMediaDiscoveryBridge()
        self.streamManifestExpander = streamManifestExpander
    }

    public func setMediaCandidatesForTesting(_ candidates: [BrowserMediaCandidate]) {
        self.mediaCandidates = candidates
    }

    // MARK: - Tab-Scoped State Management

    public func saveTabState(
        for tabID: UUID,
        sortOption: ResourceSortOption = .newest,
        groupingOption: ResourceGroupingOption = .none
    ) {
        tabDiscoveredResources[tabID] = discoveredResources
        tabVariantStreamItems[tabID] = variantStreamItems
        tabSelectedResourceIDs[tabID] = selectedResourceIDs
        tabResourceStates[tabID] = BrowserTabResourceState(
            discoveredResources: discoveredResources,
            variantStreamItems: variantStreamItems,
            selectedResourceIDs: selectedResourceIDs,
            sortOption: sortOption,
            groupingOption: groupingOption
        )
    }

    public func restoreTabState(
        for tabID: UUID?
    ) -> (resources: [WebpageResource], variants: [String: HLSVariantStreamItem], selections: Set<String>, sort: ResourceSortOption, group: ResourceGroupingOption) {
        guard let targetID = tabID else {
            discoveredResources = []
            variantStreamItems = [:]
            selectedResourceIDs = []
            return ([], [:], [], .newest, .none)
        }

        let restoredResources = tabDiscoveredResources[targetID] ?? tabResourceStates[targetID]?.discoveredResources ?? []
        let restoredVariants = tabVariantStreamItems[targetID] ?? tabResourceStates[targetID]?.variantStreamItems ?? [:]
        let restoredSelections = tabSelectedResourceIDs[targetID] ?? tabResourceStates[targetID]?.selectedResourceIDs ?? []
        let sortOpt = tabResourceStates[targetID]?.sortOption ?? .newest
        let groupOpt = tabResourceStates[targetID]?.groupingOption ?? .none

        discoveredResources = restoredResources
        variantStreamItems = restoredVariants
        selectedResourceIDs = restoredSelections

        tabDiscoveredResources[targetID] = restoredResources
        tabVariantStreamItems[targetID] = restoredVariants
        tabSelectedResourceIDs[targetID] = restoredSelections
        tabResourceStates[targetID] = BrowserTabResourceState(
            discoveredResources: restoredResources,
            variantStreamItems: restoredVariants,
            selectedResourceIDs: restoredSelections,
            sortOption: sortOpt,
            groupingOption: groupOpt
        )

        publishMediaCandidates(activeTabID: targetID)
        return (restoredResources, restoredVariants, restoredSelections, sortOpt, groupOpt)
    }

    public func resourceState(
        for tabID: UUID?,
        activeTabID: UUID?,
        sortOption: ResourceSortOption = .newest,
        groupingOption: ResourceGroupingOption = .none
    ) -> BrowserTabResourceState {
        let targetID = tabID ?? activeTabID
        if let targetID, targetID == activeTabID {
            return BrowserTabResourceState(
                discoveredResources: discoveredResources,
                variantStreamItems: variantStreamItems,
                selectedResourceIDs: selectedResourceIDs,
                sortOption: sortOption,
                groupingOption: groupingOption
            )
        } else if let targetID {
            return tabResourceStates[targetID] ?? BrowserTabResourceState(
                discoveredResources: tabDiscoveredResources[targetID] ?? [],
                variantStreamItems: tabVariantStreamItems[targetID] ?? [:],
                selectedResourceIDs: tabSelectedResourceIDs[targetID] ?? [],
                sortOption: sortOption,
                groupingOption: groupingOption
            )
        }
        return BrowserTabResourceState(
            discoveredResources: discoveredResources,
            variantStreamItems: variantStreamItems,
            selectedResourceIDs: selectedResourceIDs,
            sortOption: sortOption,
            groupingOption: groupingOption
        )
    }

    public func discoveredResources(for tabID: UUID?, activeTabID: UUID?) -> [WebpageResource] {
        let targetID = tabID ?? activeTabID
        if let targetID, targetID == activeTabID {
            return discoveredResources
        } else if let targetID {
            return tabDiscoveredResources[targetID] ?? tabResourceStates[targetID]?.discoveredResources ?? []
        }
        return discoveredResources
    }

    public func variantStreamItems(for tabID: UUID?, activeTabID: UUID?) -> [String: HLSVariantStreamItem] {
        let targetID = tabID ?? activeTabID
        if let targetID, targetID == activeTabID {
            return variantStreamItems
        } else if let targetID {
            return tabVariantStreamItems[targetID] ?? tabResourceStates[targetID]?.variantStreamItems ?? [:]
        }
        return variantStreamItems
    }

    public func selectedResourceIDs(for tabID: UUID?, activeTabID: UUID?) -> Set<String> {
        let targetID = tabID ?? activeTabID
        if let targetID, targetID == activeTabID {
            return selectedResourceIDs
        } else if let targetID {
            return tabSelectedResourceIDs[targetID] ?? tabResourceStates[targetID]?.selectedResourceIDs ?? []
        }
        return selectedResourceIDs
    }

    public func setDiscoveredResources(_ resources: [WebpageResource], for tabID: UUID?, activeTabID: UUID?) {
        let targetID = tabID ?? activeTabID
        if targetID == activeTabID {
            discoveredResources = resources
        }
        if let targetID {
            tabDiscoveredResources[targetID] = resources
            tabResourceStates[targetID, default: BrowserTabResourceState()].discoveredResources = resources
        }
    }

    public func setVariantStreamItems(_ items: [HLSVariantStreamItem], for tabID: UUID?, activeTabID: UUID?) {
        let targetID = tabID ?? activeTabID
        var dict: [String: HLSVariantStreamItem] = [:]
        for item in items {
            dict[item.id] = item
        }
        if targetID == activeTabID {
            variantStreamItems = dict
        }
        if let targetID {
            tabVariantStreamItems[targetID] = dict
            tabResourceStates[targetID, default: BrowserTabResourceState()].variantStreamItems = dict
        }
    }

    // MARK: - Resource Selections

    public func isResourceSelected(_ id: String, tabID: UUID?, activeTabID: UUID?) -> Bool {
        selectedResourceIDs(for: tabID, activeTabID: activeTabID).contains(id)
    }

    public func toggleResourceSelection(_ id: String, tabID: UUID?, activeTabID: UUID?) {
        let targetID = tabID ?? activeTabID
        var selections = selectedResourceIDs(for: targetID, activeTabID: activeTabID)
        if selections.contains(id) {
            selections.remove(id)
        } else {
            selections.insert(id)
        }
        if targetID == activeTabID {
            selectedResourceIDs = selections
        }
        if let targetID {
            tabSelectedResourceIDs[targetID] = selections
            tabResourceStates[targetID, default: BrowserTabResourceState()].selectedResourceIDs = selections
        }
    }

    public func selectResource(_ id: String, tabID: UUID?, activeTabID: UUID?) {
        let targetID = tabID ?? activeTabID
        var selections = selectedResourceIDs(for: targetID, activeTabID: activeTabID)
        selections.insert(id)
        if targetID == activeTabID {
            selectedResourceIDs = selections
        }
        if let targetID {
            tabSelectedResourceIDs[targetID] = selections
            tabResourceStates[targetID, default: BrowserTabResourceState()].selectedResourceIDs = selections
        }
    }

    public func deselectResource(_ id: String, tabID: UUID?, activeTabID: UUID?) {
        let targetID = tabID ?? activeTabID
        var selections = selectedResourceIDs(for: targetID, activeTabID: activeTabID)
        selections.remove(id)
        if targetID == activeTabID {
            selectedResourceIDs = selections
        }
        if let targetID {
            tabSelectedResourceIDs[targetID] = selections
            tabResourceStates[targetID, default: BrowserTabResourceState()].selectedResourceIDs = selections
        }
    }

    public func selectAllResources(tabID: UUID?, activeTabID: UUID?) {
        let targetID = tabID ?? activeTabID
        let resources = discoveredResources(for: targetID, activeTabID: activeTabID)
        let allIDs = Set(resources.map { $0.id })
        if targetID == activeTabID {
            selectedResourceIDs = allIDs
        }
        if let targetID {
            tabSelectedResourceIDs[targetID] = allIDs
            tabResourceStates[targetID, default: BrowserTabResourceState()].selectedResourceIDs = allIDs
        }
    }

    public func deselectAllResources(tabID: UUID?, activeTabID: UUID?) {
        let targetID = tabID ?? activeTabID
        if targetID == activeTabID {
            selectedResourceIDs = []
        }
        if let targetID {
            tabSelectedResourceIDs[targetID] = []
            tabResourceStates[targetID, default: BrowserTabResourceState()].selectedResourceIDs = []
        }
    }

    // MARK: - Candidate Catalog Synchronization

    public func publishMediaCandidates(activeTabID: UUID?) {
        guard let activeTabID else {
            mediaCandidates = []
            return
        }
        let rawCandidates = mediaCandidateCatalogs[activeTabID]?.candidates ?? []
        mediaCandidates = BrowserMediaDiscoveryBridge.filter(candidates: rawCandidates)
        syncMediaCandidatesToDiscoveredResources(for: activeTabID, activeTabID: activeTabID)
    }

    public nonisolated static func isPreservedCandidateOnRescan(_ candidate: BrowserMediaCandidate) -> Bool {
        candidate.blobKind == .mediaSource ||
        candidate.kind == .mediaSource ||
        candidate.blobKind == .blob ||
        candidate.kind == .completeBlob ||
        candidate.associatedManifestURL != nil ||
        candidate.isLive ||
        candidate.isLiveStream ||
        candidate.kind == .hlsManifest ||
        candidate.kind == .dashManifest ||
        candidate.evidence.contains(where: { $0.localizedCaseInsensitiveContains("live") })
    }

    public func resetMediaCandidateCatalog(for tabID: UUID? = nil, activeTabID: UUID? = nil) {
        let targetID = tabID ?? activeTabID
        guard let targetID else {
            mediaCandidates = mediaCandidates.filter {
                Self.isPreservedCandidateOnRescan($0)
            }
            return
        }
        let preserved = mediaCandidateCatalogs[targetID]?.candidates.filter {
            Self.isPreservedCandidateOnRescan($0)
        } ?? []
        var catalog = BrowserMediaCandidateCatalog()
        for cand in preserved {
            catalog.merge(cand)
        }
        mediaCandidateCatalogs[targetID] = catalog
        let effectiveActive = activeTabID ?? targetID
        if targetID == effectiveActive { publishMediaCandidates(activeTabID: effectiveActive) }
    }

    public func syncMediaCandidatesToDiscoveredResources(for tabID: UUID? = nil, activeTabID: UUID? = nil) {
        let targetTabID = tabID ?? activeTabID
        guard let targetTabID else { return }

        let catalog = mediaCandidateCatalogs[targetTabID] ?? BrowserMediaCandidateCatalog()
        guard !catalog.candidates.isEmpty else { return }

        var currentResources = (targetTabID == activeTabID)
            ? discoveredResources
            : (tabDiscoveredResources[targetTabID] ?? tabResourceStates[targetTabID]?.discoveredResources ?? [])

        var seenURLs = Set(currentResources.map { $0.url })
        let knownVariants = HLSResourceGrouping.variantURLs(in: currentResources)
        var newResources: [WebpageResource] = []

        for candidate in catalog.candidates {
            if candidate.kind == .hlsManifest || candidate.kind == .dashManifest {
                guard let candidateURL = candidate.url else { continue }
                if let idx = currentResources.firstIndex(where: { $0.url == candidateURL }) {
                    let existing = currentResources[idx]
                    if let p = candidate.cachedManifestText, !p.isEmpty, existing.manifestText == nil {
                        var updatedTitle = existing.title
                        if p.contains("#EXT-X-STREAM-INF") && !updatedTitle.contains("Master Playlist") {
                            updatedTitle = "\(updatedTitle) (Master Playlist)"
                        } else if p.contains("#EXT-X-TARGETDURATION") && !updatedTitle.contains("Media Playlist") {
                            updatedTitle = "\(updatedTitle) (Media Playlist)"
                        }
                        currentResources[idx] = WebpageResource(
                            id: existing.id,
                            url: existing.url,
                            title: updatedTitle,
                            suggestedFilename: existing.suggestedFilename,
                            resourceType: existing.resourceType,
                            mimeType: existing.mimeType,
                            estimatedSize: existing.estimatedSize,
                            isSupported: existing.isSupported,
                            unsupportedReason: existing.unsupportedReason,
                            requestContext: existing.requestContext,
                            manifestText: p,
                            hlsVariantPreferences: existing.hlsVariantPreferences,
                            dashVideoRepresentationID: existing.dashVideoRepresentationID,
                            dashAudioRepresentationID: existing.dashAudioRepresentationID,
                            dashTextRepresentationID: existing.dashTextRepresentationID,
                            isDRMProtected: existing.isDRMProtected,
                            drmProtectionType: existing.drmProtectionType,
                            discoveredAt: existing.discoveredAt,
                            isLive: existing.isLive
                        )
                    }
                    continue
                }
            }

            guard let res = candidate.toWebpageResource() else { continue }
            if !seenURLs.contains(res.url) {
                if res.hlsVariantPreferences == nil && HLSResourceGrouping.isVariantOrRenditionURL(res.url, matchingVariantURLs: knownVariants) {
                    continue
                }
                seenURLs.insert(res.url)
                newResources.append(res)
            }
        }

        if !newResources.isEmpty {
            currentResources.insert(contentsOf: newResources, at: 0)
        }

        tabDiscoveredResources[targetTabID] = currentResources
        tabResourceStates[targetTabID, default: BrowserTabResourceState()].discoveredResources = currentResources
        if targetTabID == activeTabID {
            discoveredResources = currentResources
        }
    }

    // MARK: - Document & Navigation Generation Management

    @discardableResult
    public func nextDocumentGeneration(for tabID: UUID, documentID: String? = nil) -> UInt64 {
        let next = tabDocumentGenerations[tabID, default: 0] &+ 1
        tabDocumentGenerations[tabID] = next
        if let documentID {
            tabDocumentIDs[tabID] = documentID
        }
        return next
    }

    public func currentDocumentGeneration(for tabID: UUID) -> UInt64 {
        tabDocumentGenerations[tabID, default: 0]
    }

    public func setNavigationGeneration(_ generation: UInt64, for tabID: UUID) {
        tabNavigationGenerations[tabID] = generation
    }

    public func currentNavigationGeneration(for tabID: UUID) -> UInt64 {
        tabNavigationGenerations[tabID, default: 0]
    }

    public func isObservationValidForCurrentDocument(
        _ observation: BrowserMediaDiscoveryObservation,
        tabID: UUID
    ) -> Bool {
        if let obsNavGen = observation.navigationGeneration,
           let currentNavGen = tabNavigationGenerations[tabID],
           obsNavGen < currentNavGen {
            return false
        }

        if let obsDocGen = observation.documentGeneration,
           let currentDocGen = tabDocumentGenerations[tabID],
           obsDocGen < currentDocGen {
            let isPreserved = observation.isManifestSignal ||
                              observation.blobKind == .mediaSource ||
                              observation.source == .mediaSource
            if !isPreserved {
                return false
            }
        }

        if let obsDocID = observation.documentID,
           let currentDocID = tabDocumentIDs[tabID],
           obsDocID != currentDocID {
            let isPreserved = observation.isManifestSignal ||
                              observation.blobKind == .mediaSource ||
                              observation.source == .mediaSource
            if !isPreserved {
                return false
            }
        }

        return true
    }

    @discardableResult
    public func pruneExpiredAndCorruptManifests(for tabID: UUID? = nil, activeTabID: UUID? = nil) -> Int {
        let targetID = tabID ?? activeTabID
        guard let targetID else { return 0 }
        guard var catalog = mediaCandidateCatalogs[targetID] else { return 0 }

        var prunedCount = 0
        var validCandidates: [BrowserMediaCandidate] = []

        for candidate in catalog.candidates {
            if candidate.isExpired {
                prunedCount += 1
                continue
            }

            if let manifestText = candidate.cachedManifestText {
                if candidate.kind == .hlsManifest {
                    if !manifestText.contains("#EXTM3U") {
                        prunedCount += 1
                        continue
                    }
                } else if candidate.kind == .dashManifest {
                    if !manifestText.contains("<MPD") && !manifestText.contains("<mpd") {
                        prunedCount += 1
                        continue
                    }
                }
            }
            validCandidates.append(candidate)
        }

        if prunedCount > 0 {
            catalog.reset()
            for cand in validCandidates {
                catalog.merge(cand)
            }
            mediaCandidateCatalogs[targetID] = catalog
            telemetry.prunedCorruptedOrExpiredManifestsCount += prunedCount
            if targetID == activeTabID {
                publishMediaCandidates(activeTabID: activeTabID)
            }
        }
        return prunedCount
    }

    public func recordProbeTimeout(for tabID: UUID? = nil) {
        telemetry.probeTimeoutsCount += 1
    }

    public func ingestMediaObservation(
        _ observation: BrowserMediaDiscoveryObservation,
        tabID: UUID?,
        activeTabID: UUID?
    ) {
        guard let targetTabID = tabID ?? activeTabID else { return }
        telemetry.totalObservationsReceived += 1

        if !isObservationValidForCurrentDocument(observation, tabID: targetTabID) {
            telemetry.droppedStaleDocumentObservationsCount += 1
            BrowserDiagnosticLogger.shared.log(
                category: .discovery,
                message: "Rejected stale observation from superseded document/navigation generation (docGen: \(observation.documentGeneration ?? 0), navGen: \(observation.navigationGeneration ?? 0))",
                url: observation.url,
                tabID: targetTabID
            )
            return
        }

        var catalog = mediaCandidateCatalogs[targetTabID] ?? BrowserMediaCandidateCatalog()
        if let candidate = catalog.ingest(observation: observation) {
            telemetry.deduplicatedCandidatesCount += catalog.deduplicatedCandidatesCount
            telemetry.evictedCandidatesCount += catalog.evictedCandidatesCount
            catalog.deduplicatedCandidatesCount = 0
            catalog.evictedCandidatesCount = 0

            mediaCandidateCatalogs[targetTabID] = catalog
            telemetry.totalCandidatesCataloged = catalog.candidates.count
            if targetTabID == activeTabID { publishMediaCandidates(activeTabID: activeTabID) }
            if let resource = candidate.toWebpageResource() {
                ingestMediaResource(resource, tabID: targetTabID, activeTabID: activeTabID)
            }
        }
    }

    public func ingestMediaResources(
        _ resources: [WebpageResource],
        tabID: UUID? = nil,
        activeTabID: UUID? = nil,
        updateCatalog: Bool = true
    ) {
        guard let targetTabID = tabID ?? activeTabID else { return }
        if updateCatalog {
            var catalog = mediaCandidateCatalogs[targetTabID] ?? BrowserMediaCandidateCatalog()
            for resource in resources {
                _ = catalog.ingest(resource: resource)
            }
            mediaCandidateCatalogs[targetTabID] = catalog
        }

        var targetResources = (targetTabID == activeTabID)
            ? discoveredResources
            : (tabDiscoveredResources[targetTabID] ?? tabResourceStates[targetTabID]?.discoveredResources ?? [])

        var seenURLs = Set(targetResources.map { $0.url })
        let knownVariants = HLSResourceGrouping.variantURLs(in: targetResources)
        var newToInsert: [WebpageResource] = []

        for resource in resources {
            if !seenURLs.contains(resource.url) {
                if resource.hlsVariantPreferences == nil && HLSResourceGrouping.isVariantOrRenditionURL(resource.url, matchingVariantURLs: knownVariants) {
                    continue
                }
                seenURLs.insert(resource.url)
                newToInsert.append(resource)
            }
        }

        if !newToInsert.isEmpty {
            targetResources.insert(contentsOf: newToInsert, at: 0)
            tabDiscoveredResources[targetTabID] = targetResources
            tabResourceStates[targetTabID, default: BrowserTabResourceState()].discoveredResources = targetResources
            if targetTabID == activeTabID {
                discoveredResources = targetResources
            }
        }

        var targetSelections = (targetTabID == activeTabID)
            ? selectedResourceIDs
            : (tabSelectedResourceIDs[targetTabID] ?? tabResourceStates[targetTabID]?.selectedResourceIDs ?? [])

        if targetSelections.isEmpty,
           let manifest = targetResources.first(where: { $0.isStreamingManifest }) {
            targetSelections.insert(manifest.id)
            tabSelectedResourceIDs[targetTabID] = targetSelections
            tabResourceStates[targetTabID, default: BrowserTabResourceState()].selectedResourceIDs = targetSelections
            if targetTabID == activeTabID {
                selectedResourceIDs = targetSelections
            }
        }

        if targetTabID == activeTabID { publishMediaCandidates(activeTabID: activeTabID) }
        if resources.contains(where: { $0.isStreamingManifest && $0.hlsVariantPreferences == nil && $0.dashVideoRepresentationID == nil }) {
            expandStreamingManifests(in: resources, tabID: targetTabID, activeTabID: activeTabID)
        }
    }

    public func ingestMediaResource(
        _ resource: WebpageResource,
        tabID: UUID? = nil,
        activeTabID: UUID? = nil
    ) {
        ingestMediaResources([resource], tabID: tabID, activeTabID: activeTabID, updateCatalog: true)
    }

    public func ingestMediaCandidates(
        _ candidates: [BrowserMediaCandidate],
        tabID: UUID? = nil,
        activeTabID: UUID? = nil
    ) {
        guard let targetTabID = tabID ?? activeTabID else { return }
        var catalog = mediaCandidateCatalogs[targetTabID] ?? BrowserMediaCandidateCatalog()
        for cand in candidates {
            _ = catalog.merge(cand)
        }
        mediaCandidateCatalogs[targetTabID] = catalog
        if targetTabID == activeTabID { publishMediaCandidates(activeTabID: activeTabID) }

        let resources = candidates.compactMap { $0.toWebpageResource() }
        if !resources.isEmpty {
            ingestMediaResources(resources, tabID: targetTabID, activeTabID: activeTabID, updateCatalog: false)
        }
    }

    public func ingestMediaCandidate(
        _ candidate: BrowserMediaCandidate,
        tabID: UUID? = nil,
        activeTabID: UUID? = nil
    ) {
        ingestMediaCandidates([candidate], tabID: tabID, activeTabID: activeTabID)
    }

    // MARK: - Streaming Manifest Expansion

    public func expandStreamingManifests(
        in resources: [WebpageResource]? = nil,
        tabID: UUID? = nil,
        activeTabID: UUID? = nil
    ) {
        let targetTabID = tabID ?? activeTabID
        let currentResources = (targetTabID == activeTabID)
            ? discoveredResources
            : (targetTabID.flatMap { tabDiscoveredResources[$0] ?? tabResourceStates[$0]?.discoveredResources } ?? [])
        let targets = (resources ?? currentResources).filter {
            $0.isStreamingManifest && $0.hlsVariantPreferences == nil && $0.dashVideoRepresentationID == nil && $0.dashTextRepresentationID == nil
        }
        guard !targets.isEmpty else { return }

        let expansionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer {
                if let targetTabID {
                    self.activeProbeTasks[targetTabID]?.removeAll { $0.isCancelled }
                }
            }
            for manifest in targets {
                if Task.isCancelled { break }
                let expanded = await self.streamManifestExpander.expand(manifestResource: manifest, tabID: targetTabID)
                if Task.isCancelled { break }
                guard expanded.count > 1 || (expanded.count == 1 && expanded[0].id != manifest.id) else {
                    continue
                }

                if let targetTabID {
                    var tabVariants = self.tabVariantStreamItems[targetTabID] ?? self.tabResourceStates[targetTabID]?.variantStreamItems ?? [:]
                    for variant in expanded {
                        if let item = await self.streamManifestExpander.variantItem(for: variant.id) {
                            tabVariants[variant.id] = item
                            if targetTabID == activeTabID {
                                self.variantStreamItems[variant.id] = item
                            }
                        }
                    }
                    self.tabVariantStreamItems[targetTabID] = tabVariants
                    self.tabResourceStates[targetTabID, default: BrowserTabResourceState()].variantStreamItems = tabVariants
                } else {
                    for variant in expanded {
                        if let item = await self.streamManifestExpander.variantItem(for: variant.id) {
                            self.variantStreamItems[variant.id] = item
                        }
                    }
                }

                var childURLs = Set<String>()
                for v in expanded {
                    if let exact = v.hlsVariantPreferences?.exactURI {
                        childURLs.insert(exact.absoluteString)
                        childURLs.insert(exact.absoluteString.lowercased())
                        childURLs.insert(HLSResourceGrouping.urlWithoutQuery(exact))
                    }
                }
                if let text = manifest.manifestText ?? expanded.first?.manifestText,
                   let manifestObj = try? HLSManifestParser.parse(text, baseURL: manifest.url) {
                    for v in manifestObj.variants {
                        childURLs.insert(v.uri.absoluteString)
                        childURLs.insert(v.uri.absoluteString.lowercased())
                        childURLs.insert(HLSResourceGrouping.urlWithoutQuery(v.uri))
                    }
                    for r in manifestObj.renditions {
                        if let rURI = r.uri {
                            childURLs.insert(rURI.absoluteString)
                            childURLs.insert(rURI.absoluteString.lowercased())
                            childURLs.insert(HLSResourceGrouping.urlWithoutQuery(rURI))
                        }
                    }
                }
                let baseResources = (targetTabID == activeTabID)
                    ? self.discoveredResources
                    : (targetTabID.flatMap { self.tabDiscoveredResources[$0] ?? self.tabResourceStates[$0]?.discoveredResources } ?? [])
                childURLs.formUnion(HLSResourceGrouping.variantURLs(in: baseResources))

                var updated: [WebpageResource] = []
                var inserted = false
                for res in baseResources {
                    if res.id == manifest.id || (res.url == manifest.url && res.hlsVariantPreferences == nil && res.dashVideoRepresentationID == nil) {
                        if !inserted {
                            for v in expanded {
                                if !updated.contains(where: { $0.id == v.id }) {
                                    updated.append(v)
                                }
                            }
                            let isMasterLive = expanded.first?.isLive == true || res.isLive
                            let isMasterDRM = res.isDRMProtected || expanded.contains(where: { $0.isDRMProtected })
                            let drmType = res.drmProtectionType ?? expanded.first(where: { $0.isDRMProtected })?.drmProtectionType
                            let isSupported = !isMasterDRM && !isMasterLive
                            let unsupportedReason: String? = {
                                if isMasterDRM {
                                    if let resReason = res.unsupportedReason, res.isDRMProtected { return resReason }
                                    if let varReason = expanded.first(where: { $0.isDRMProtected })?.unsupportedReason { return varReason }
                                    return "Protected stream is DRM encrypted. Direct export is unavailable."
                                }
                                if isMasterLive { return "Live streaming manifests require active stream capture." }
                                return nil
                            }()

                            let cleanTitle = res.title.replacingOccurrences(of: " (Master Playlist)", with: "")
                            let baseTitle = "\(cleanTitle) (Master Playlist)"
                            let parentTitle = (isMasterLive && !baseTitle.hasPrefix("[LIVE]")) ? "[LIVE] \(baseTitle)" : baseTitle
                            let masterWithVariants = WebpageResource(
                                id: res.id,
                                url: res.url,
                                title: parentTitle,
                                suggestedFilename: res.suggestedFilename,
                                resourceType: res.resourceType,
                                mimeType: res.mimeType,
                                estimatedSize: res.estimatedSize,
                                isSupported: isSupported,
                                unsupportedReason: unsupportedReason,
                                requestContext: res.requestContext,
                                manifestText: manifest.manifestText ?? expanded.first?.manifestText,
                                hlsVariantPreferences: nil,
                                isDRMProtected: isMasterDRM,
                                drmProtectionType: drmType,
                                discoveredAt: manifest.discoveredAt,
                                isLive: isMasterLive
                            )
                            if !updated.contains(where: { $0.id == masterWithVariants.id }) {
                                updated.append(masterWithVariants)
                            }
                            inserted = true
                        }
                    } else if !HLSResourceGrouping.isVariantOrRenditionURL(res.url, matchingVariantURLs: childURLs) {
                        updated.append(res)
                    }
                }

                // Final prune: ensure no raw child playlist matching childURLs remains in updated
                updated.removeAll { res in
                    res.hlsVariantPreferences == nil && HLSResourceGrouping.isVariantOrRenditionURL(res.url, matchingVariantURLs: childURLs)
                }

                if inserted {
                    if targetTabID == activeTabID {
                        self.discoveredResources = updated
                    }
                    if let targetTabID {
                        self.tabDiscoveredResources[targetTabID] = updated
                        self.tabResourceStates[targetTabID, default: BrowserTabResourceState()].discoveredResources = updated
                    }
                }
            }
        }
        if let targetTabID {
            activeProbeTasks[targetTabID, default: []].append(expansionTask)
        }
    }

    /// Cancels all in-flight media probe and manifest expansion tasks associated with a tab.
    public func cancelInFlightProbes(for tabID: UUID) {
        if let tasks = activeProbeTasks.removeValue(forKey: tabID) {
            for task in tasks {
                task.cancel()
            }
            telemetry.probeTimeoutsCount += tasks.count
        }
        tabDocumentGenerations.removeValue(forKey: tabID)
        tabNavigationGenerations.removeValue(forKey: tabID)
        tabDocumentIDs.removeValue(forKey: tabID)
        Task { [expander = streamManifestExpander] in
            await expander.cancelInFlight(for: tabID)
        }
    }

    // MARK: - DOM Resource Inspection

    public func inspectCurrentPageResources(
        currentURL: URL?,
        activeTabID: UUID?,
        includeNonVideo: Bool = false,
        evaluateScript: ((String, @escaping (Any?, Error?) -> Void) -> Void)? = nil,
        captureContexts: (([WebpageResource], URL, @escaping ([WebpageResource]) -> Void) -> Void)? = nil
    ) {
        guard let url = currentURL else {
            resourceScanError = "No active webpage is currently loaded."
            resetMediaCandidateCatalog(for: activeTabID, activeTabID: activeTabID)
            if let activeTabID {
                let liveResources = (tabDiscoveredResources[activeTabID] ?? []).filter {
                    $0.isLive || $0.isStreamingManifest || $0.isBlobResource || $0.isMediaSourceBlob
                }
                let liveVariants = (tabVariantStreamItems[activeTabID] ?? [:]).filter { $1.isLive }
                let preservedIDs = Set(liveResources.map { $0.id })
                let selectedIDs = (tabSelectedResourceIDs[activeTabID] ?? []).filter { preservedIDs.contains($0) }
                tabDiscoveredResources[activeTabID] = liveResources
                tabVariantStreamItems[activeTabID] = liveVariants
                tabSelectedResourceIDs[activeTabID] = selectedIDs
                tabResourceStates[activeTabID] = BrowserTabResourceState(
                    discoveredResources: liveResources,
                    variantStreamItems: liveVariants,
                    selectedResourceIDs: selectedIDs
                )
                discoveredResources = liveResources
                variantStreamItems = liveVariants
                selectedResourceIDs = selectedIDs
            } else {
                discoveredResources = []
                selectedResourceIDs = []
            }
            return
        }

        isScanningResources = true
        resourceScanError = nil

        guard let evaluateScript else {
            isScanningResources = false
            resourceScanError = "Web browser engine is not ready."
            return
        }

        let jsScript = BrowserMediaDiscoveryScripts.domExtractionScript(includeNonVideo: includeNonVideo)

        evaluateScript(jsScript) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isScanningResources = false

                if let error = error {
                    self.resourceScanError = "Failed to scan webpage: \(error.localizedDescription)"
                    return
                }

                guard let jsonStr = result as? String,
                      let data = jsonStr.data(using: .utf8),
                      let rawCandidates = try? JSONDecoder().decode([WebpageRawResourceCandidate].self, from: data) else {
                    self.resourceScanError = "Unable to process resources from webpage."
                    return
                }

                let resources = WebpageResourceExtractor.extractFromRawCandidates(rawCandidates, baseURL: url)
                let processContextual: ([WebpageResource]) -> Void = { [weak self] contextualResources in
                    guard let self = self else { return }
                    var newToInsert: [WebpageResource] = []
                    var seenURLs = Set(self.discoveredResources.map { $0.url.absoluteString.lowercased() })
                    for newRes in contextualResources {
                        let lower = newRes.url.absoluteString.lowercased()
                        if !seenURLs.contains(lower) {
                            seenURLs.insert(lower)
                            newToInsert.append(newRes)
                        }
                    }
                    if !newToInsert.isEmpty {
                        self.discoveredResources.insert(contentsOf: newToInsert, at: 0)
                        if let tabID = activeTabID {
                            self.tabDiscoveredResources[tabID] = self.discoveredResources
                            self.tabResourceStates[tabID, default: BrowserTabResourceState()].discoveredResources = self.discoveredResources
                        }
                    }
                    if self.selectedResourceIDs.isEmpty,
                       let manifest = self.discoveredResources.first(where: { $0.isStreamingManifest }) {
                        self.selectedResourceIDs.insert(manifest.id)
                        if let tabID = activeTabID {
                            self.tabSelectedResourceIDs[tabID] = self.selectedResourceIDs
                            self.tabResourceStates[tabID, default: BrowserTabResourceState()].selectedResourceIDs = self.selectedResourceIDs
                        }
                    }
                    self.ingestMediaResources(contextualResources, tabID: activeTabID, activeTabID: activeTabID)
                    self.expandStreamingManifests(in: contextualResources, tabID: activeTabID, activeTabID: activeTabID)
                }

                if let captureContexts {
                    captureContexts(resources, url, processContextual)
                } else {
                    processContextual(resources)
                }
            }
        }
    }

    // MARK: - Dynamic Bridge Observation Processing

    public func handleMediaDiscoveryObservation(
        _ observation: BrowserMediaDiscoveryObservation,
        tabID: UUID? = nil,
        activeTabID: UUID?,
        currentURL: URL?,
        streamingOrchestrator: StreamingDownloadOrchestrator? = nil
    ) {
        ingestMediaObservation(observation, tabID: tabID, activeTabID: activeTabID)
        if let tabID, tabID != activeTabID { return }
        guard let discoveredURL = observation.url else { return }
        let resourceURL: URL
        if let responseURL = observation.responseURL,
           BrowserURLResolver.isValidDownloadURL(responseURL) {
            resourceURL = responseURL
        } else {
            resourceURL = discoveredURL
        }

        if let prefix = observation.manifestPrefix, !prefix.isEmpty {
            let pageURL = currentURL ?? observation.pageOrigin
            Task { [weak streamingOrchestrator] in
                let context = BrowserRequestContext(
                    url: resourceURL,
                    pageURL: pageURL,
                    userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                    cookies: [],
                    source: .webpageResource
                )
                await streamingOrchestrator?.recordCachedManifest(
                    text: prefix,
                    for: resourceURL,
                    requestContext: context
                )
            }
        }

        let rawCandidate = WebpageRawResourceCandidate(
            rawURL: resourceURL.absoluteString,
            tag: observation.tag ?? (observation.isManifestSignal ? "video" : nil),
            declaredType: observation.declaredType,
            width: observation.width,
            height: observation.height,
            duration: observation.duration
        )
        let baseURL = currentURL ?? observation.pageOrigin
        var resources = WebpageResourceExtractor.extractFromRawCandidates(
            [rawCandidate],
            baseURL: baseURL
        )

        if resources.isEmpty, observation.isManifestSignal {
            let manifestType = observation.manifestKind == .dash
                ? "application/dash+xml"
                : "application/vnd.apple.mpegurl"
            let baseName = BrowserURLResolver.suggestedFilename(from: resourceURL)
            let manifestTitle: String
            if let prefix = observation.manifestPrefix {
                if prefix.contains("#EXT-X-STREAM-INF") {
                    manifestTitle = "\(baseName) (Master Playlist)"
                } else if prefix.contains("#EXT-X-TARGETDURATION") {
                    manifestTitle = "\(baseName) (Media Playlist)"
                } else {
                    manifestTitle = baseName
                }
            } else {
                manifestTitle = baseName
            }
            resources = [WebpageResource(
                url: resourceURL,
                title: manifestTitle,
                suggestedFilename: baseName,
                resourceType: .video,
                mimeType: observation.declaredType ?? manifestType,
                estimatedSize: observation.contentLength,
                isSupported: false,
                unsupportedReason: "Streaming playlist manifest. Prepare a manifest-aware transfer to continue.",
                manifestText: observation.manifestPrefix
            )]
        }
        guard var resource = resources.first else { return }

        if let existingIndex = discoveredResources.firstIndex(where: {
            $0.url.absoluteString.lowercased() == resource.url.absoluteString.lowercased()
        }) {
            if let prefix = observation.manifestPrefix, !prefix.isEmpty {
                let existing = discoveredResources[existingIndex]
                if existing.manifestText == nil || existing.manifestText?.isEmpty == true {
                    let updatedTitle: String
                    if prefix.contains("#EXT-X-STREAM-INF") && !existing.title.contains("Master Playlist") {
                        updatedTitle = "\(existing.title) (Master Playlist)"
                    } else if prefix.contains("#EXT-X-TARGETDURATION") && !existing.title.contains("Media Playlist") {
                        updatedTitle = "\(existing.title) (Media Playlist)"
                    } else {
                        updatedTitle = existing.title
                    }
                    let updated = WebpageResource(
                        id: existing.id,
                        url: existing.url,
                        title: updatedTitle,
                        suggestedFilename: existing.suggestedFilename,
                        resourceType: existing.resourceType,
                        mimeType: existing.mimeType ?? observation.declaredType,
                        estimatedSize: existing.estimatedSize ?? observation.contentLength,
                        isSupported: existing.isSupported,
                        unsupportedReason: existing.unsupportedReason,
                        requestContext: existing.requestContext,
                        manifestText: prefix,
                        hlsVariantPreferences: existing.hlsVariantPreferences,
                        dashVideoRepresentationID: existing.dashVideoRepresentationID,
                        dashAudioRepresentationID: existing.dashAudioRepresentationID,
                        dashTextRepresentationID: existing.dashTextRepresentationID,
                        isDRMProtected: existing.isDRMProtected,
                        drmProtectionType: existing.drmProtectionType,
                        discoveredAt: existing.discoveredAt,
                        isLive: existing.isLive
                    )
                    discoveredResources[existingIndex] = updated
                    ingestMediaResource(updated, tabID: tabID ?? activeTabID, activeTabID: activeTabID)
                }
            }
            return
        }

        if observation.isManifestSignal && !resource.isStreamingManifest {
            let manifestType = observation.manifestKind == .dash
                ? "application/dash+xml"
                : "application/vnd.apple.mpegurl"
            let prefix = resource.manifestText ?? observation.manifestPrefix
            let dynamicTitle: String
            if let p = prefix {
                if p.contains("#EXT-X-STREAM-INF") && !resource.title.contains("Master Playlist") {
                    dynamicTitle = "\(resource.title) (Master Playlist)"
                } else if p.contains("#EXT-X-TARGETDURATION") && !resource.title.contains("Media Playlist") {
                    dynamicTitle = "\(resource.title) (Media Playlist)"
                } else {
                    dynamicTitle = resource.title
                }
            } else {
                dynamicTitle = resource.title
            }
            resource = WebpageResource(
                id: resource.id,
                url: resource.url,
                title: dynamicTitle,
                suggestedFilename: resource.suggestedFilename,
                resourceType: .video,
                mimeType: resource.mimeType ?? observation.declaredType ?? manifestType,
                estimatedSize: observation.contentLength ?? resource.estimatedSize,
                isSupported: false,
                unsupportedReason: "Streaming playlist manifest. Prepare a manifest-aware transfer to continue.",
                requestContext: resource.requestContext,
                manifestText: prefix,
                hlsVariantPreferences: resource.hlsVariantPreferences,
                dashVideoRepresentationID: resource.dashVideoRepresentationID,
                dashAudioRepresentationID: resource.dashAudioRepresentationID,
                dashTextRepresentationID: resource.dashTextRepresentationID,
                isDRMProtected: resource.isDRMProtected,
                drmProtectionType: resource.drmProtectionType,
                discoveredAt: resource.discoveredAt,
                isLive: resource.isLive
            )
        }

        let effectivePageURL = currentURL ?? observation.pageOrigin
        let fallbackContext = BrowserRequestContext(
            url: resource.url,
            pageURL: effectivePageURL,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            cookies: [],
            source: .webpageResource
        )
        let immediateResource = WebpageResource(
            id: resource.id,
            url: resource.url,
            title: resource.title,
            suggestedFilename: resource.suggestedFilename,
            resourceType: resource.resourceType,
            mimeType: resource.mimeType,
            estimatedSize: resource.estimatedSize,
            isSupported: resource.isSupported,
            unsupportedReason: resource.unsupportedReason,
            requestContext: resource.requestContext ?? fallbackContext,
            manifestText: resource.manifestText,
            hlsVariantPreferences: resource.hlsVariantPreferences,
            dashVideoRepresentationID: resource.dashVideoRepresentationID,
            dashAudioRepresentationID: resource.dashAudioRepresentationID,
            dashTextRepresentationID: resource.dashTextRepresentationID,
            isDRMProtected: resource.isDRMProtected,
            drmProtectionType: resource.drmProtectionType,
            discoveredAt: resource.discoveredAt,
            isLive: resource.isLive
        )

        let knownVariants = HLSResourceGrouping.variantURLs(in: discoveredResources)
        let isRawChildOfKnownMaster = HLSResourceGrouping.isVariantOrRenditionURL(immediateResource.url, matchingVariantURLs: knownVariants)
        if !isRawChildOfKnownMaster && !discoveredResources.contains(where: {
            $0.url.absoluteString.lowercased() == immediateResource.url.absoluteString.lowercased()
        }) {
            discoveredResources.insert(immediateResource, at: 0)
            if let targetTabID = tabID ?? activeTabID {
                tabDiscoveredResources[targetTabID] = discoveredResources
                tabResourceStates[targetTabID, default: BrowserTabResourceState()].discoveredResources = discoveredResources
            }
            if selectedResourceIDs.isEmpty,
               let manifest = discoveredResources.first(where: { $0.isStreamingManifest }) {
                selectedResourceIDs.insert(manifest.id)
                if let targetTabID = tabID ?? activeTabID {
                    tabSelectedResourceIDs[targetTabID] = selectedResourceIDs
                    tabResourceStates[targetTabID, default: BrowserTabResourceState()].selectedResourceIDs = selectedResourceIDs
                }
            }
            ingestMediaResource(immediateResource, tabID: tabID ?? activeTabID, activeTabID: activeTabID)
        }
    }
}
