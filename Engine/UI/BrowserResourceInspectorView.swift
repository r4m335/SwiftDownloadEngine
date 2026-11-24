#if canImport(SwiftUI)
import Foundation
import SwiftUI

public struct MediaPreviewItem: Identifiable {
    public let id = UUID()
    public let url: URL
    public let title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

/// Sheet displaying media assets, documents, and downloadable files discovered inside the active webpage.
public struct BrowserResourceInspectorSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode

    @State private var selectedCategory: WebpageResourceType? = nil
    @State private var selectedTrackType: ResourceTrackType? = nil
    @State private var showsAllResources = false
    @State private var searchText: String = ""
    @State private var activePlaybackSource: LIDPlayerSource? = nil
    @State private var drmWarningAlert: String? = nil
    @State private var sortOption: ResourceSortOption = .newest
    @State private var sortDirection: SortDirection = .descending
    @State private var groupingOption: ResourceGroupingOption = .none
    @State private var isSelectionMode: Bool = false
    @State private var selectedResourceIDs: Set<String> = []
    @State private var collapsedSections: Set<String> = []
    @State private var lastScanTimestamp: Date = .distantPast

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
        _sortOption = State(initialValue: viewModel.resourceSortOption)
        _sortDirection = State(initialValue: viewModel.resourceSortDirection)
        _groupingOption = State(initialValue: viewModel.resourceGroupingOption)
    }

    private var variantMetadataMap: [String: HLSVariantStreamItem] {
        var map = viewModel.variantStreamItems
        for res in viewModel.discoveredResources {
            let items = HLSResourceGrouping.extractVariantStreamItems(for: res)
            for item in items {
                if map[item.id] == nil {
                    map[item.id] = item
                }
            }
        }
        return map
    }

    public static func eligibleResources(
        in discoveredResources: [WebpageResource],
        variantURLs: Set<String>? = nil,
        showsAllResources: Bool = false
    ) -> [WebpageResource] {
        let hasStreamingManifest = discoveredResources.contains(where: { $0.isStreamingManifest })
        let sequentialChunkIDs = WebpageResourceExtractor.detectSequentialSegmentChunks(in: discoveredResources)
        let resolvedVariantURLs = variantURLs ?? HLSResourceGrouping.variantURLs(in: discoveredResources)
        let expandedMasterIDs: Set<String> = {
            var ids = Set<String>()
            for res in discoveredResources {
                if res.hlsVariantPreferences != nil || res.dashVideoRepresentationID != nil {
                    if let range = res.id.range(of: "-variant-") {
                        let masterID = String(res.id[..<range.lowerBound])
                        ids.insert(masterID)
                    }
                }
            }
            return ids
        }()
        let expandedMasterURLs: Set<URL> = {
            var urls = Set<URL>()
            for res in discoveredResources {
                if res.hlsVariantPreferences != nil || res.dashVideoRepresentationID != nil {
                    urls.insert(res.url)
                }
            }
            return urls
        }()
        var expanded: [WebpageResource] = []

        for res in discoveredResources {
            let isChunk = res.isSegmentChunk || sequentialChunkIDs.contains(res.id)
            // Discard raw .ts/.m4s/.m4a segment chunks when an .m3u8/.mpd manifest is present or in standard media view,
            // as they are internal segment chunks that cannot be played standalone.
            if isChunk && (hasStreamingManifest || !showsAllResources) {
                continue
            }
            // Discard redundant MediaSource stream buffer blobs when an .m3u8/.mpd manifest is present
            // in standard media view, guiding the user to download the actual manifest instead.
            if res.isMediaSourceBlob && hasStreamingManifest && !showsAllResources {
                continue
            }
            // Discard raw child playlist URLs discovered separately without metadata
            if HLSResourceGrouping.isVariantOrRenditionURL(res.url, matchingVariantURLs: resolvedVariantURLs) && res.hlsVariantPreferences == nil {
                continue
            }

            let isUnexpandedMaster = res.isStreamingManifest && res.hlsVariantPreferences == nil && res.dashVideoRepresentationID == nil
            let hasOwnExpandedVariants = isUnexpandedMaster && (expandedMasterIDs.contains(res.id) || expandedMasterURLs.contains(res.url))

            // In standard "Media" view, when a master manifest has already been expanded into its own quality variants,
            // hide this specific parent master manifest so users only see the individual video qualities.
            // Under "All", the parent master is visible alongside its variants.
            if hasOwnExpandedVariants && !showsAllResources {
                continue
            }

            // Expand master playlist synchronously if text is present and it hasn't already been expanded into discoveredResources
            if isUnexpandedMaster && !hasOwnExpandedVariants,
               let text = res.manifestText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let syncResult = StreamManifestResourceExpander.expandSynchronously(masterResource: res, manifestText: text)
                if !syncResult.variants.isEmpty && (syncResult.variants.count > 1 || syncResult.variants[0].id != res.id) {
                    expanded.append(contentsOf: syncResult.variants)
                    if showsAllResources {
                        expanded.append(res)
                    }
                    continue
                }
            }

            expanded.append(res)
        }

        // Final pass: ensure no raw child playlists survive in expanded, regardless of discovery order or showsAllResources
        let allKnownVariantURLs = HLSResourceGrouping.variantURLs(in: expanded)
        let combinedVariantURLs = resolvedVariantURLs.union(allKnownVariantURLs)
        if !combinedVariantURLs.isEmpty {
            expanded.removeAll { res in
                res.hlsVariantPreferences == nil && HLSResourceGrouping.isVariantOrRenditionURL(res.url, matchingVariantURLs: combinedVariantURLs)
            }
        }
        return expanded
    }

    private var eligibleResources: [WebpageResource] {
        Self.eligibleResources(
            in: viewModel.discoveredResources,
            variantURLs: knownHLSVariantURLs,
            showsAllResources: showsAllResources
        )
    }

    private var hlsMasterQualitySummaries: [String: String] {
        Dictionary(uniqueKeysWithValues: viewModel.discoveredResources.compactMap {
            guard let summary = HLSResourceGrouping.qualitySummary(for: $0) else { return nil }
            return ($0.id, summary)
        })
    }

    private var knownHLSVariantURLs: Set<String> {
        HLSResourceGrouping.variantURLs(in: viewModel.discoveredResources)
    }

    public static func filteredResources(
        in discoveredResources: [WebpageResource],
        variantURLs: Set<String>? = nil,
        selectedCategory: WebpageResourceType? = nil,
        selectedTrackType: ResourceTrackType? = nil,
        showsAllResources: Bool = false,
        searchText: String = "",
        sortOption: ResourceSortOption = .newest,
        sortDirection: SortDirection = .descending,
        variantMetadataMap: [String: HLSVariantStreamItem] = [:]
    ) -> [WebpageResource] {
        let base = eligibleResources(in: discoveredResources, variantURLs: variantURLs, showsAllResources: showsAllResources)
        let hasStreamingManifest = base.contains(where: { $0.isStreamingManifest })
        let cleanSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resources = base.filter { res in
            let matchesCategory = selectedCategory == nil || res.resourceType == selectedCategory
            let matchesTrackType = selectedTrackType == nil || res.trackType == selectedTrackType
            let matchesDefaultMedia = showsAllResources ||
                selectedCategory != nil ||
                selectedTrackType != nil ||
                (res.resourceType == .video && (!res.isMediaSourceBlob || !hasStreamingManifest)) ||
                res.resourceType == .audio
            let matchesSearch = cleanSearch.isEmpty ||
                res.title.localizedCaseInsensitiveContains(cleanSearch) ||
                res.suggestedFilename.localizedCaseInsensitiveContains(cleanSearch) ||
                res.url.absoluteString.localizedCaseInsensitiveContains(cleanSearch) ||
                (res.url.host?.localizedCaseInsensitiveContains(cleanSearch) == true) ||
                (res.codecs?.localizedCaseInsensitiveContains(cleanSearch) == true) ||
                (res.resolutionText?.localizedCaseInsensitiveContains(cleanSearch) == true) ||
                (res.audioLanguage?.localizedCaseInsensitiveContains(cleanSearch) == true) ||
                (res.container?.localizedCaseInsensitiveContains(cleanSearch) == true)
            return matchesCategory && matchesTrackType && matchesDefaultMedia && matchesSearch
        }
        return sortedResources(resources, sortOption: sortOption, direction: sortDirection, variantMetadataMap: variantMetadataMap)
    }

    public static func filteredResources(
        in discoveredResources: [WebpageResource],
        variantURLs: Set<String>? = nil,
        selectedCategory: WebpageResourceType? = nil,
        showsAllResources: Bool = false,
        searchText: String = "",
        sortOption: ResourceSortOption = .newest,
        variantMetadataMap: [String: HLSVariantStreamItem] = [:]
    ) -> [WebpageResource] {
        filteredResources(
            in: discoveredResources,
            variantURLs: variantURLs,
            selectedCategory: selectedCategory,
            selectedTrackType: nil,
            showsAllResources: showsAllResources,
            searchText: searchText,
            sortOption: sortOption,
            sortDirection: .descending,
            variantMetadataMap: variantMetadataMap
        )
    }

    public var filteredResources: [WebpageResource] {
        Self.filteredResources(
            in: viewModel.discoveredResources,
            variantURLs: knownHLSVariantURLs,
            selectedCategory: selectedCategory,
            selectedTrackType: selectedTrackType,
            showsAllResources: showsAllResources,
            searchText: searchText,
            sortOption: sortOption,
            sortDirection: sortDirection,
            variantMetadataMap: variantMetadataMap
        )
    }

    public var displayedSortedResources: [WebpageResource] {
        filteredResources
    }

    /// Associated `BrowserMediaCandidate` representations for all displayed resources.
    public var displayedCandidates: [BrowserMediaCandidate] {
        displayedSortedResources.map { $0.toMediaCandidate() }
    }

    /// Associated `BrowserMediaCandidate` representations for all eligible resources.
    public var eligibleCandidates: [BrowserMediaCandidate] {
        eligibleResources.map { $0.toMediaCandidate() }
    }

    private static func extractHeight(from resource: WebpageResource, variantMetadataMap: [String: HLSVariantStreamItem]) -> Int {
        if let h = variantMetadataMap[resource.id]?.resolution?.height, h > 0 {
            return h
        }
        if let h = resource.hlsVariantPreferences?.maximumHeight, h > 0 {
            return h
        }
        if let text = resource.resolutionText {
            let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if let last = digits.last, let parsed = Int(last), parsed > 0 {
                return parsed
            }
        }
        return 0
    }

    public static func sortedResources(
        _ resources: [WebpageResource],
        sortOption: ResourceSortOption,
        direction: SortDirection = .descending,
        variantMetadataMap: [String: HLSVariantStreamItem] = [:]
    ) -> [WebpageResource] {
        let sorted: [WebpageResource]
        switch sortOption {
        case .newest:
            sorted = resources.sorted { (lhs: WebpageResource, rhs: WebpageResource) -> Bool in
                if lhs.discoveredAt != rhs.discoveredAt {
                    return lhs.discoveredAt > rhs.discoveredAt
                }
                if lhs.isStreamingManifest != rhs.isStreamingManifest {
                    return lhs.isStreamingManifest && !rhs.isStreamingManifest
                }
                return lhs.suggestedFilename.localizedCaseInsensitiveCompare(rhs.suggestedFilename) == .orderedAscending
            }
        case .size:
            sorted = resources.sorted { (lhs: WebpageResource, rhs: WebpageResource) -> Bool in
                let size0 = variantMetadataMap[lhs.id]?.estimatedSizeBytes ?? lhs.estimatedSize ?? 0
                let size1 = variantMetadataMap[rhs.id]?.estimatedSizeBytes ?? rhs.estimatedSize ?? 0
                if size0 != size1 {
                    return size0 > size1
                }
                if lhs.discoveredAt != rhs.discoveredAt {
                    return lhs.discoveredAt > rhs.discoveredAt
                }
                return lhs.suggestedFilename.localizedCaseInsensitiveCompare(rhs.suggestedFilename) == .orderedAscending
            }
        case .name:
            sorted = resources.sorted { (lhs: WebpageResource, rhs: WebpageResource) -> Bool in
                let cmp = lhs.suggestedFilename.localizedCaseInsensitiveCompare(rhs.suggestedFilename)
                if cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
                return lhs.discoveredAt > rhs.discoveredAt
            }
        case .quality:
            sorted = resources.sorted { (lhs: WebpageResource, rhs: WebpageResource) -> Bool in
                let h0 = extractHeight(from: lhs, variantMetadataMap: variantMetadataMap)
                let h1 = extractHeight(from: rhs, variantMetadataMap: variantMetadataMap)
                if h0 != h1 {
                    return h0 > h1
                }
                let bw0 = variantMetadataMap[lhs.id]?.bandwidth ?? lhs.hlsVariantPreferences?.maximumBandwidth ?? 0
                let bw1 = variantMetadataMap[rhs.id]?.bandwidth ?? rhs.hlsVariantPreferences?.maximumBandwidth ?? 0
                if bw0 != bw1 {
                    return bw0 > bw1
                }
                if lhs.discoveredAt != rhs.discoveredAt {
                    return lhs.discoveredAt > rhs.discoveredAt
                }
                return lhs.suggestedFilename.localizedCaseInsensitiveCompare(rhs.suggestedFilename) == .orderedAscending
            }
        case .resolution:
            sorted = resources.sorted { (lhs: WebpageResource, rhs: WebpageResource) -> Bool in
                let h0 = extractHeight(from: lhs, variantMetadataMap: variantMetadataMap)
                let h1 = extractHeight(from: rhs, variantMetadataMap: variantMetadataMap)
                if h0 != h1 { return h0 > h1 }
                let w0 = variantMetadataMap[lhs.id]?.resolution?.width ?? 0
                let w1 = variantMetadataMap[rhs.id]?.resolution?.width ?? 0
                if w0 != w1 { return w0 > w1 }
                return lhs.discoveredAt > rhs.discoveredAt
            }
        case .bitrate:
            sorted = resources.sorted { (lhs: WebpageResource, rhs: WebpageResource) -> Bool in
                let bw0 = variantMetadataMap[lhs.id]?.bandwidth ?? lhs.bitrate ?? lhs.hlsVariantPreferences?.maximumBandwidth ?? 0
                let bw1 = variantMetadataMap[rhs.id]?.bandwidth ?? rhs.bitrate ?? rhs.hlsVariantPreferences?.maximumBandwidth ?? 0
                if bw0 != bw1 { return bw0 > bw1 }
                return lhs.discoveredAt > rhs.discoveredAt
            }
        case .duration:
            sorted = resources.sorted { (lhs: WebpageResource, rhs: WebpageResource) -> Bool in
                let d0 = lhs.duration ?? 0
                let d1 = rhs.duration ?? 0
                if d0 != d1 { return d0 > d1 }
                return lhs.discoveredAt > rhs.discoveredAt
            }
        case .domain:
            sorted = resources.sorted { (lhs: WebpageResource, rhs: WebpageResource) -> Bool in
                let dom0 = lhs.url.host ?? ""
                let dom1 = rhs.url.host ?? ""
                let cmp = dom0.localizedCaseInsensitiveCompare(dom1)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.discoveredAt > rhs.discoveredAt
            }
        case .type:
            sorted = resources.sorted { (lhs: WebpageResource, rhs: WebpageResource) -> Bool in
                if lhs.resourceType.rawValue != rhs.resourceType.rawValue {
                    return lhs.resourceType.rawValue < rhs.resourceType.rawValue
                }
                return lhs.discoveredAt > rhs.discoveredAt
            }
        }

        if direction == .ascending {
            return sorted.reversed()
        }
        return sorted
    }

    public static func sortedResources(
        _ resources: [WebpageResource],
        sortOption: ResourceSortOption,
        variantMetadataMap: [String: HLSVariantStreamItem] = [:]
    ) -> [WebpageResource] {
        sortedResources(resources, sortOption: sortOption, direction: .descending, variantMetadataMap: variantMetadataMap)
    }

    private struct InspectorSection: Identifiable {
        let id: String
        let title: String
        let iconName: String
        let resources: [WebpageResource]
    }

    private var groupedSections: [InspectorSection] {
        switch groupingOption {
        case .none:
            return []
        case .domain:
            return WebpageResource.groupedByDomain(displayedSortedResources).map {
                InspectorSection(id: "dom-\($0.domain)", title: $0.domain, iconName: "globe", resources: $0.resources)
            }
        case .category:
            return WebpageResource.groupedByCategory(displayedSortedResources).map {
                InspectorSection(id: "cat-\($0.category.rawValue)", title: $0.category.rawValue, iconName: $0.category.systemImage, resources: $0.resources)
            }
        case .manifest:
            return WebpageResource.groupedByManifest(displayedSortedResources).map {
                InspectorSection(id: "man-\($0.manifest)", title: $0.manifest, iconName: "doc.on.doc", resources: $0.resources)
            }
        case .streamType:
            return WebpageResource.groupedByStreamType(displayedSortedResources).map {
                InspectorSection(id: "str-\($0.streamType)", title: $0.streamType, iconName: "play.tv", resources: $0.resources)
            }
        case .trackType:
            return WebpageResource.groupedByTrackType(displayedSortedResources).map {
                InspectorSection(id: "trk-\($0.trackType.rawValue)", title: $0.trackType.rawValue, iconName: $0.trackType.iconName, resources: $0.resources)
            }
        case .quality:
            return WebpageResource.groupedByQuality(displayedSortedResources, variantMetadataMap: variantMetadataMap).map {
                InspectorSection(id: "q-\($0.quality)", title: $0.quality, iconName: "sparkles", resources: $0.resources)
            }
        }
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Category Filter Pills
                categoryFilterBar

                // Search Bar
                searchAndSelectionHeader

                // Explicit Sort Controls
                sortControlBar

                // Explicit Grouping Controls
                groupingControlBar

                // Main Content: List, Loading, Empty, or Error
                if !filteredResources.isEmpty {
                    VStack(spacing: 0) {
                        if viewModel.isScanningResources {
                            ProgressView()
                                .progressViewStyle(LinearProgressViewStyle())
                                .padding(.horizontal)
                        }
                        resourceList

                        if isSelectionMode {
                            bulkActionBar
                        }
                    }
                } else if viewModel.isScanningResources {
                    loadingView
                } else if let error = viewModel.resourceScanError {
                    errorView(error)
                } else {
                    emptyView
                }
            }
            .navigationTitle("Find Resources")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isSelectionMode ? "Cancel" : "Done") {
                        if isSelectionMode {
                            isSelectionMode = false
                            selectedResourceIDs.removeAll()
                        } else {
                            viewModel.isScanningResources = false
                            viewModel.isShowingResourceInspector = false
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        if !filteredResources.isEmpty {
                            Button(isSelectionMode ? "Done" : "Select") {
                                isSelectionMode.toggle()
                                if !isSelectionMode {
                                    selectedResourceIDs.removeAll()
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                        }

                        Button {
                            let now = Date()
                            guard now.timeIntervalSince(lastScanTimestamp) > 1.0 else { return }
                            lastScanTimestamp = now
                            viewModel.inspectCurrentPageResources(includeNonVideo: showsAllResources || (selectedCategory != nil && selectedCategory != .video && selectedCategory != .audio))
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(viewModel.isScanningResources)
                    }
                }
            }
            .onAppear {
                viewModel.expandStreamingManifests()
            }
            .lidPlayerPresentation(source: $activePlaybackSource)
            .alert(isPresented: Binding<Bool>(
                get: { drmWarningAlert != nil },
                set: { if !$0 { drmWarningAlert = nil } }
            )) {
                Alert(
                    title: Text("Playback Notice"),
                    message: Text(drmWarningAlert ?? "This stream cannot be played directly."),
                    dismissButton: .default(Text("OK"))
                )
            }
            .onChange(of: sortOption) { newOption in
                viewModel.resourceSortOption = newOption
            }
            .onChange(of: sortDirection) { newDir in
                viewModel.resourceSortDirection = newDir
            }
            .onChange(of: groupingOption) { newOption in
                viewModel.resourceGroupingOption = newOption
            }
            .onChange(of: viewModel.resourceSortOption) { newOption in
                if sortOption != newOption {
                    sortOption = newOption
                }
            }
            .onChange(of: viewModel.resourceSortDirection) { newDir in
                if sortDirection != newDir {
                    sortDirection = newDir
                }
            }
            .onChange(of: viewModel.resourceGroupingOption) { newOption in
                if groupingOption != newOption {
                    groupingOption = newOption
                }
            }
        }
    }

    // MARK: - Explicit Sort & Grouping Controls

    private var sortControlBar: some View {
        HStack(spacing: 8) {
            Text("Sort:")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            Menu {
                ForEach(ResourceSortOption.allCases) { opt in
                    Button {
                        sortOption = opt
                    } label: {
                        if sortOption == opt {
                            Label(opt.displayName, systemImage: "checkmark")
                        } else {
                            Label(opt.displayName, systemImage: opt.iconName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Label(sortOption.displayName, systemImage: sortOption.iconName)
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(8)
            }

            Spacer()

            Button {
                sortDirection.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: sortDirection.iconName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(sortDirection == .ascending ? "Asc" : "Desc")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(8)
            }
            .accessibilityLabel("Toggle Sort Direction (\(sortDirection.rawValue))")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        #if canImport(UIKit)
        .background(Color(UIColor.secondarySystemBackground))
        #else
        .background(Color.secondary.opacity(0.06))
        #endif
    }

    private var groupingControlBar: some View {
        HStack(spacing: 8) {
            Text("Group:")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            Menu {
                ForEach(ResourceGroupingOption.allCases) { grp in
                    Button {
                        groupingOption = grp
                    } label: {
                        if groupingOption == grp {
                            Label(grp.displayName, systemImage: "checkmark")
                        } else {
                            Label(grp.displayName, systemImage: grp.iconName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Label(groupingOption.displayName, systemImage: groupingOption.iconName)
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(8)
            }

            Spacer()

            if isSelectionMode {
                Button(selectedResourceIDs.count == filteredResources.count ? "Deselect All" : "Select All") {
                    if selectedResourceIDs.count == filteredResources.count {
                        selectedResourceIDs.removeAll()
                    } else {
                        selectedResourceIDs = Set(filteredResources.map(\.id))
                    }
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        #if canImport(UIKit)
        .background(Color(UIColor.secondarySystemBackground))
        #else
        .background(Color.secondary.opacity(0.06))
        #endif
    }

    // MARK: - Category & Track Filter Bar

    private var categoryCounts: (media: Int, total: Int, byType: [WebpageResourceType: Int]) {
        let items = eligibleResources
        var counts: [WebpageResourceType: Int] = [:]
        var mediaCount = 0
        for res in items {
            counts[res.resourceType, default: 0] += 1
            if res.resourceType == .video || res.resourceType == .audio {
                mediaCount += 1
            }
        }
        return (media: mediaCount, total: items.count, byType: counts)
    }

    private var categoryFilterBar: some View {
        let counts = categoryCounts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "Media" Pill
                FilterPill(
                    title: "Media",
                    count: counts.media,
                    isSelected: selectedCategory == nil && selectedTrackType == nil && !showsAllResources
                ) {
                    selectedCategory = nil
                    selectedTrackType = nil
                    showsAllResources = false
                }

                FilterPill(
                    title: "All",
                    count: counts.total,
                    isSelected: selectedCategory == nil && selectedTrackType == nil && showsAllResources
                ) {
                    selectedCategory = nil
                    selectedTrackType = nil
                    showsAllResources = true
                    viewModel.inspectCurrentPageResources(includeNonVideo: true)
                }

                // Per-type Pills
                ForEach(WebpageResourceType.allCases) { cat in
                    let count = counts.byType[cat, default: 0]
                    if count > 0 {
                        FilterPill(
                            title: cat.rawValue,
                            count: count,
                            isSelected: selectedCategory == cat && selectedTrackType == nil
                        ) {
                            selectedCategory = cat
                            selectedTrackType = nil
                            showsAllResources = true
                            if cat != .video && cat != .audio {
                                viewModel.inspectCurrentPageResources(includeNonVideo: true)
                            }
                        }
                    }
                }

                // Track Type Pills: Muxed, Video, Audio, Subtitles
                ForEach(ResourceTrackType.allCases) { track in
                    let trackCount = eligibleResources.filter { $0.trackType == track }.count
                    if trackCount > 0 {
                        FilterPill(
                            title: track.shortLabel,
                            count: trackCount,
                            isSelected: selectedTrackType == track
                        ) {
                            if selectedTrackType == track {
                                selectedTrackType = nil
                            } else {
                                selectedTrackType = track
                                showsAllResources = true
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        #if canImport(UIKit)
        .background(Color(UIColor.secondarySystemBackground))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
    }

    // MARK: - Search Bar

    private var searchAndSelectionHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))

                TextField("Search name, domain, codec, 1080p...", text: $searchText)
                    #if canImport(UIKit)
                    .autocapitalization(.none)
                    #endif
                    .disableAutocorrection(true)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                }
            }
            .padding(8)
            #if canImport(UIKit)
            .background(Color(UIColor.systemBackground))
            #else
            .background(Color.primary.opacity(0.05))
            #endif
            .cornerRadius(8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Resource List

    private var resourceList: some View {
        List {
            if groupingOption == .none {
                ForEach(displayedSortedResources) { resource in
                    rowView(for: resource)
                }
            } else {
                ForEach(groupedSections) { section in
                    Section(header: Button(action: {
                        if collapsedSections.contains(section.id) {
                            collapsedSections.remove(section.id)
                        } else {
                            collapsedSections.insert(section.id)
                        }
                    }) {
                        HStack {
                            Label("\(section.title) (\(section.resources.count))", systemImage: section.iconName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: collapsedSections.contains(section.id) ? "chevron.right" : "chevron.down")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())) {
                        if !collapsedSections.contains(section.id) {
                            ForEach(section.resources) { resource in
                                rowView(for: resource)
                            }
                        }
                    }
                }
            }
        }
        #if canImport(UIKit)
        .listStyle(InsetGroupedListStyle())
        #endif
    }

    @ViewBuilder
    private func rowView(for resource: WebpageResource) -> some View {
        let cand = viewModel.mediaCandidates.first {
            $0.rawURL.caseInsensitiveCompare(resource.url.absoluteString) == .orderedSame
        }
        let quality = hlsMasterQualitySummaries[resource.id]
        let variant = variantMetadataMap[resource.id]
        let statusDot = viewModel.matchingTransferDot(for: resource)

        ResourceRowView(
            resource: resource,
            candidate: cand,
            qualitySummary: quality,
            variantItem: variant,
            statusDot: statusDot,
            isSelectionMode: isSelectionMode,
            isSelected: selectedResourceIDs.contains(resource.id),
            onToggleSelect: {
                if selectedResourceIDs.contains(resource.id) {
                    selectedResourceIDs.remove(resource.id)
                } else {
                    selectedResourceIDs.insert(resource.id)
                }
            },
            onSelect: {
                if isSelectionMode {
                    if selectedResourceIDs.contains(resource.id) {
                        selectedResourceIDs.remove(resource.id)
                    } else {
                        selectedResourceIDs.insert(resource.id)
                    }
                    return
                }
                if resource.isDRMProtected || cand?.kind == .protectedMedia {
                    drmWarningAlert = "This media stream is encrypted with Digital Rights Management (\(resource.drmProtectionType ?? "DRM")) and cannot be downloaded or captured."
                    return
                }
                if resource.isExpired() {
                    viewModel.refreshResourceToken(for: resource)
                    return
                }
                if resource.isSegmentChunk {
                    viewModel.blobCaptureErrorMessage = "This is a streaming segment chunk. Download the playlist manifest (.m3u8 or .mpd) instead."
                } else {
                    if let item = variant {
                        viewModel.variantStreamItems[resource.id] = item
                    }
                    viewModel.promptDownloadFromInspector(for: resource)
                }
            },
            onPreview: {
                let title = resource.suggestedFilename.isEmpty ? resource.title : resource.suggestedFilename
                let preflight = LIDPreviewPreflight.preflight(resource: resource, title: title)
                switch preflight {
                case .success(let source):
                    activePlaybackSource = source
                case .failure(let error):
                    if case .tokenExpired = error {
                        viewModel.refreshResourceToken(for: resource)
                    }
                    drmWarningAlert = error.localizedDescription
                }
            },
            onOpenBrowser: {
                viewModel.isShowingResourceInspector = false
                presentationMode.wrappedValue.dismiss()
                viewModel.load(url: resource.url)
            },
            onOpenAddDownload: {
                viewModel.isShowingResourceInspector = false
                presentationMode.wrappedValue.dismiss()
                viewModel.sendToGlobalAddDownload(for: resource)
            },
            onShare: {
                viewModel.shareURL(resource.url)
            }
        )
    }

    // MARK: - Bulk Action Bar

    private var bulkActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text("\(selectedResourceIDs.count) selected")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)

                Spacer()

                // Preview button (active if exactly 1 playable selected)
                if selectedResourceIDs.count == 1,
                   let singleID = selectedResourceIDs.first,
                   let targetRes = filteredResources.first(where: { $0.id == singleID }) {
                    Button {
                        let title = targetRes.suggestedFilename.isEmpty ? targetRes.title : targetRes.suggestedFilename
                        let preflight = LIDPreviewPreflight.preflight(resource: targetRes, title: title)
                        switch preflight {
                        case .success(let source):
                            activePlaybackSource = source
                        case .failure(let error):
                            drmWarningAlert = error.localizedDescription
                        }
                    } label: {
                        Label("Preview", systemImage: "play.circle")
                            .font(.subheadline.weight(.medium))
                    }
                }

                // Copy URLs button
                Button {
                    let selectedURLs = filteredResources
                        .filter { selectedResourceIDs.contains($0.id) }
                        .map { $0.url.absoluteString }
                        .joined(separator: "\n")
                    #if canImport(UIKit)
                    UIPasteboard.general.string = selectedURLs
                    #endif
                    isSelectionMode = false
                    selectedResourceIDs.removeAll()
                } label: {
                    Label("Copy URLs", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(selectedResourceIDs.isEmpty)

                // Remove from list button
                Button(role: .destructive) {
                    viewModel.discoveredResources.removeAll { selectedResourceIDs.contains($0.id) }
                    selectedResourceIDs.removeAll()
                    isSelectionMode = false
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .disabled(selectedResourceIDs.isEmpty)

                // Bulk Download button
                Button {
                    let targets = filteredResources.filter { selectedResourceIDs.contains($0.id) }
                    for target in targets {
                        guard !target.isDRMProtected && !target.isSegmentChunk else { continue }
                        if let variant = variantMetadataMap[target.id] {
                            viewModel.variantStreamItems[target.id] = variant
                        }
                        viewModel.promptDownloadFromInspector(for: target)
                    }
                    isSelectionMode = false
                    selectedResourceIDs.removeAll()
                } label: {
                    Label("Download (\(selectedResourceIDs.count))", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedResourceIDs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            #if canImport(UIKit)
            .background(Color(UIColor.secondarySystemBackground))
            #else
            .background(Color.secondary.opacity(0.1))
            #endif
        }
    }

    // MARK: - Empty & Loading States

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Scanning webpage for media and downloadable resources...")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Cancel Scan") {
                viewModel.isScanningResources = false
            }
            .font(.subheadline)
            .padding(.top, 4)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Resources Found")
                .font(.headline)

            Text("No downloadable files, media streams, or documents matching the criteria were detected on this page.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Scan Again") {
                viewModel.inspectCurrentPageResources(includeNonVideo: showsAllResources || (selectedCategory != nil && selectedCategory != .video && selectedCategory != .audio))
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)

            Spacer()
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Inspection Failed")
                .font(.headline)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Retry") {
                viewModel.inspectCurrentPageResources()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Spacer()
        }
    }
}

// MARK: - Resource Row Component

public struct ResourceRowView: View {
    public let resource: WebpageResource
    public let candidate: BrowserMediaCandidate?
    public let qualitySummary: String?
    public let variantItem: HLSVariantStreamItem?
    public let statusDot: DownloadStatusDot?
    public let isSelectionMode: Bool
    public let isSelected: Bool
    public let onToggleSelect: (() -> Void)?
    public let onSelect: () -> Void
    public let onPreview: (() -> Void)?
    public let onOpenBrowser: (() -> Void)?
    public let onOpenAddDownload: (() -> Void)?
    public let onShare: (() -> Void)?

    public init(
        resource: WebpageResource,
        candidate: BrowserMediaCandidate? = nil,
        qualitySummary: String? = nil,
        variantItem: HLSVariantStreamItem? = nil,
        statusDot: DownloadStatusDot? = nil,
        isSelectionMode: Bool = false,
        isSelected: Bool = false,
        onToggleSelect: (() -> Void)? = nil,
        onSelect: @escaping () -> Void,
        onPreview: (() -> Void)? = nil,
        onOpenBrowser: (() -> Void)? = nil,
        onOpenAddDownload: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil
    ) {
        self.resource = resource
        self.candidate = candidate
        self.qualitySummary = qualitySummary
        self.variantItem = variantItem
        self.statusDot = statusDot
        self.isSelectionMode = isSelectionMode
        self.isSelected = isSelected
        self.onToggleSelect = onToggleSelect
        self.onSelect = onSelect
        self.onPreview = onPreview
        self.onOpenBrowser = onOpenBrowser
        self.onOpenAddDownload = onOpenAddDownload
        self.onShare = onShare
    }

    /// Backward-compatible initializer for existing callers
    public init(
        resource: WebpageResource,
        candidate: BrowserMediaCandidate? = nil,
        qualitySummary: String? = nil,
        variantItem: HLSVariantStreamItem? = nil,
        statusDot: DownloadStatusDot? = nil,
        onSelect: @escaping () -> Void,
        onPreview: (() -> Void)? = nil,
        onOpenBrowser: (() -> Void)? = nil,
        onOpenAddDownload: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil
    ) {
        self.init(
            resource: resource,
            candidate: candidate,
            qualitySummary: qualitySummary,
            variantItem: variantItem,
            statusDot: statusDot,
            isSelectionMode: false,
            isSelected: false,
            onToggleSelect: nil,
            onSelect: onSelect,
            onPreview: onPreview,
            onOpenBrowser: onOpenBrowser,
            onOpenAddDownload: onOpenAddDownload,
            onShare: onShare
        )
    }

    /// Backward-compatible initializer for existing callers
    public init(
        resource: WebpageResource,
        candidate: BrowserMediaCandidate? = nil,
        qualitySummary: String? = nil,
        variantItem: HLSVariantStreamItem? = nil,
        isSelected: Bool = false,
        onToggleSelect: @escaping () -> Void = {},
        onDownload: @escaping () -> Void,
        onPreview: (() -> Void)? = nil
    ) {
        self.resource = resource
        self.candidate = candidate
        self.qualitySummary = qualitySummary
        self.variantItem = variantItem
        self.isSelectionMode = false
        self.isSelected = isSelected
        self.onToggleSelect = onToggleSelect
        self.onSelect = onDownload
        self.onPreview = onPreview
        self.onOpenBrowser = nil
        self.onOpenAddDownload = nil
        self.onShare = nil
        self.statusDot = nil
    }

    public var fileIconName: String {
        switch resource.resourceType {
        case .video: return "film"
        case .audio: return "music.note"
        case .document: return "doc.text.fill"
        case .archive: return "doc.zipper"
        case .image: return "photo.fill"
        case .other: return "doc.fill"
        }
    }

    private var fileIconColor: Color {
        switch resource.resourceType {
        case .video: return .blue
        case .audio: return .orange
        case .document: return .purple
        case .archive: return .red
        case .image: return .green
        case .other: return .secondary
        }
    }

    public var displayFilename: String {
        if !resource.suggestedFilename.isEmpty {
            return resource.suggestedFilename
        }
        return resource.title.isEmpty ? "download" : resource.title
    }

    public var displayFileSize: String {
        if resource.isLive || variantItem?.isLive == true {
            return "Live Broadcast"
        }
        if let bytes = variantItem?.estimatedSizeBytes {
            return "~\(StreamQualityOption.formatByteSize(bytes))"
        }
        if let text = variantItem?.estimatedSizeText, !text.isEmpty && text != "Size unavailable" {
            return text
        }
        if let size = resource.estimatedSize, size > 0 {
            return StreamQualityOption.formatByteSize(size)
        }
        return "Size unknown"
    }

    public var isPlayable: Bool {
        let isHLS = resource.isStreamingManifest && (resource.url.pathExtension.lowercased() == "m3u8" || resource.mimeType?.lowercased().contains("mpegurl") == true)
        let isPlayableDirect = (resource.resourceType == .video || resource.resourceType == .audio) &&
            !resource.isSegmentChunk &&
            resource.isSupported &&
            resource.url.pathExtension.lowercased() != "mpd"
        return onPreview != nil && (isHLS || isPlayableDirect)
    }

    public var isOrdinaryWebpage: Bool {
        let ext = resource.url.pathExtension.lowercased()
        let mime = resource.mimeType?.lowercased() ?? ""
        return ext == "html" || ext == "htm" || mime.contains("text/html")
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Optional checkbox for Selection Mode
            if isSelectionMode {
                Button {
                    onToggleSelect?()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundColor(isSelected ? .blue : .secondary)
                }
                .buttonStyle(BorderlessButtonStyle())
            }

            // Primary row button: Icon + Filename + Specs + Spacer (opens download config sheet)
            Button(action: onSelect) {
                HStack(alignment: .center, spacing: 12) {
                    // File-type Icon with subtle rounded background
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(fileIconColor.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: fileIconName)
                            .font(.system(size: 20))
                            .foregroundColor(fileIconColor)
                    }

                    // Middle: Filename, Size, Specs & Audio Indicator
                    VStack(alignment: .leading, spacing: 4) {
                        // Line 1: Actual Filename as headline with minimal existing-download status dot
                        HStack(alignment: .center, spacing: 6) {
                            if let dot = statusDot {
                                Circle()
                                    .fill(dot.color)
                                    .frame(width: 8, height: 8)
                            }
                            Text(displayFilename)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        // Line 2: Size & Quality Specifications
                        HStack(spacing: 6) {
                            Text(displayFileSize)
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundColor(.secondary)

                            if let variant = variantItem {
                                Text("•")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                if let resStr = variant.resolutionText ?? variant.resolution.map({ "\($0.width) × \($0.height)" }) {
                                    Text(resStr)
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.secondary)
                                }

                                if !variant.bitrateText.isEmpty {
                                    Text("•")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(variant.bitrateText)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else if let resText = resource.resolutionText {
                                Text("•")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(resText)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.primary)
                            } else if resource.isStreamingManifest {
                                Text("•")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("HLS Stream")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            } else {
                                let detectedExt = FilenameExtensionHelper.split(filename: displayFilename).ext
                                if !detectedExt.isEmpty {
                                    Text("•")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(detectedExt.uppercased())
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Formatted Duration badge if duration is known
                            if let formattedDur = resource.formattedDuration {
                                Text("•")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack(spacing: 2) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 9))
                                    Text(formattedDur)
                                        .font(.caption)
                                }
                                .foregroundColor(.secondary)
                            }

                            // Track type indicator badge (Muxed, Video, Audio, Subtitles, etc.)
                            Text(resource.trackType.shortLabel)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(3)
                                .foregroundColor(.blue)

                            // Audio indicator: Small speaker icon when audio is present
                            if let variant = variantItem, variant.hasAudio {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            } else if resource.resourceType == .video && !resource.isAudioVideoSplit {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }

                            // Subtitle indicator
                            if (variantItem?.hasSubtitles == true) || resource.trackType == .subtitles {
                                Image(systemName: "captions.bubble.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.purple)
                            }

                            // Container badge if known
                            if let container = resource.container, !container.isEmpty {
                                Text(container)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.12))
                                    .cornerRadius(3)
                                    .foregroundColor(.purple)
                            }

                            // Language badge if known
                            if let lang = resource.audioLanguage, !lang.isEmpty {
                                Text(lang.uppercased())
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(3)
                                    .foregroundColor(.secondary)
                            }

                            // Codec badge if known
                            if let codec = resource.codecs ?? variantItem?.videoCodec, !codec.isEmpty {
                                Text(codec)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(3)
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Line 3: Format Badge, DRM, Expiration, & Host
                        HStack(spacing: 6) {
                            if resource.isDRMProtected || candidate?.kind == .protectedMedia {
                                HStack(spacing: 3) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 8))
                                    Text(resource.drmProtectionType ?? "DRM")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.85))
                                .cornerRadius(4)
                            } else if resource.isLive || variantItem?.isLive == true {
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 5, height: 5)
                                    Text("LIVE")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .cornerRadius(4)
                            } else if resource.isExpired() {
                                HStack(spacing: 3) {
                                    Image(systemName: "exclamationmark.clock.fill")
                                        .font(.system(size: 8))
                                    Text("Expired")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .cornerRadius(4)
                            } else if resource.isExpiringSoon() {
                                HStack(spacing: 3) {
                                    Image(systemName: "clock.badge.exclamationmark")
                                        .font(.system(size: 8))
                                    Text("Expiring")
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundColor(.orange)
                            }

                            if let variant = variantItem {
                                Text(variant.qualityLabel)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background((variant.isLive || resource.isLive) ? Color.red : Color.blue)
                                    .cornerRadius(4)
                            } else if let qualitySummary {
                                Text(qualitySummary)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                            }

                            if let host = resource.url.host {
                                Text(host)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // Trailing Contextual Actions: Independent hit areas disjoint from row selection button
            HStack(spacing: 10) {
                if isPlayable && !resource.isDRMProtected && candidate?.kind != .protectedMedia {
                    Button {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                        onPreview?()
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }

                if isOrdinaryWebpage, let onOpenBrowser {
                    Button {
                        onOpenBrowser()
                    } label: {
                        Image(systemName: "safari.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }

                Button {
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                    onSelect()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !resource.isDRMProtected && candidate?.kind != .protectedMedia {
                Button {
                    onSelect()
                } label: {
                    if resource.isLive || variantItem?.isLive == true {
                        Label("Record Live Stream", systemImage: "record.circle")
                    } else {
                        Label("Configure Download", systemImage: "arrow.down.circle")
                    }
                }

                if let onOpenAddDownload {
                    Button {
                        onOpenAddDownload()
                    } label: {
                        Label("Open in Add Download", systemImage: "plus.circle")
                    }
                }

                if isPlayable {
                    Button {
                        onPreview?()
                    } label: {
                        Label("Play in LID Player", systemImage: "play.circle")
                    }
                }
            }

            Button {
                #if canImport(UIKit)
                UIPasteboard.general.url = resource.url
                #endif
            } label: {
                Label("Copy Stream URL", systemImage: "doc.on.doc")
            }

            if let onShare {
                Button {
                    onShare()
                } label: {
                    Label("Share...", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

// MARK: - Category Filter Pill

public struct FilterPill: View {
    public let title: String
    public let count: Int
    public let isSelected: Bool
    public let action: () -> Void

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(isSelected ? .bold : .medium))
                Text("(\(count))")
                    .font(.caption2)
                    .opacity(0.8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue : Color.secondary.opacity(0.15))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#endif // canImport(SwiftUI)
