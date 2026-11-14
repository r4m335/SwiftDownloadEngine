#if canImport(SwiftUI)
import Foundation
import SwiftUI
#if canImport(AVKit)
import AVKit
#endif

public struct MediaPreviewItem: Identifiable {
    public let id = UUID()
    public let url: URL
    public let title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

#if canImport(AVKit) && canImport(UIKit) && (os(iOS) || os(tvOS) || targetEnvironment(macCatalyst))
public struct AVPlayerViewRepresentable: UIViewControllerRepresentable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        controller.player = player
        controller.showsPlaybackControls = true
        player.play()
        return controller
    }

    public func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
#endif

/// Sheet displaying media assets, documents, and downloadable files discovered inside the active webpage.
public struct BrowserResourceInspectorSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode

    @State private var selectedCategory: WebpageResourceType? = nil
    @State private var showsAllResources = false
    @State private var searchText: String = ""
    @State private var previewItem: MediaPreviewItem? = nil

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
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

    private var eligibleResources: [WebpageResource] {
        let hasStreamingManifest = viewModel.discoveredResources.contains(where: { $0.isStreamingManifest })
        let sequentialChunkIDs = WebpageResourceExtractor.detectSequentialSegmentChunks(in: viewModel.discoveredResources)
        let variantURLs = knownHLSVariantURLs
        let hasExpandedVariants = viewModel.discoveredResources.contains(where: { $0.hlsVariantPreferences != nil || $0.dashVideoRepresentationID != nil })
        var expanded: [WebpageResource] = []

        for res in viewModel.discoveredResources {
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
            if variantURLs.contains(res.url.absoluteString.lowercased()) && res.hlsVariantPreferences == nil {
                continue
            }

            // In standard "Media" view, when expanded variants exist, hide the unexpanded parent master manifest
            // so users only see the individual video qualities. Under "All", the parent master is visible.
            if res.isStreamingManifest && res.hlsVariantPreferences == nil && res.dashVideoRepresentationID == nil && hasExpandedVariants && !showsAllResources {
                continue
            }

            // Expand master playlist synchronously if text is present and not already expanded
            if res.isStreamingManifest, res.hlsVariantPreferences == nil, res.dashVideoRepresentationID == nil,
               let text = res.manifestText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !hasExpandedVariants {
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
        return expanded
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

    public var filteredResources: [WebpageResource] {
        let resources = eligibleResources.filter { res in
            let matchesCategory = selectedCategory == nil || res.resourceType == selectedCategory
            let hasStreamingManifest = eligibleResources.contains(where: { $0.isStreamingManifest })
            let matchesDefaultMedia = showsAllResources ||
                (res.resourceType == .video && (!res.isMediaSourceBlob || !hasStreamingManifest)) ||
                res.resourceType == .audio
            let matchesSearch = searchText.isEmpty ||
                res.title.localizedCaseInsensitiveContains(searchText) ||
                res.suggestedFilename.localizedCaseInsensitiveContains(searchText) ||
                res.url.absoluteString.localizedCaseInsensitiveContains(searchText)
            return matchesCategory && matchesDefaultMedia && matchesSearch
        }
        return resources.sorted {
            let lhsPriority: Int
            if $0.isStreamingManifest {
                lhsPriority = 0
            } else if $0.resourceType == .video || $0.resourceType == .audio {
                lhsPriority = 1
            } else {
                lhsPriority = 2
            }

            let rhsPriority: Int
            if $1.isStreamingManifest {
                rhsPriority = 0
            } else if $1.resourceType == .video || $1.resourceType == .audio {
                rhsPriority = 1
            } else {
                rhsPriority = 2
            }

            return lhsPriority == rhsPriority
                ? $0.suggestedFilename.localizedCaseInsensitiveCompare($1.suggestedFilename) == .orderedAscending
                : lhsPriority < rhsPriority
        }
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Category Filter Pills
                categoryFilterBar

                // Search & Quick Selection Bar
                searchAndSelectionHeader

                // Main Content: Loading, Empty, or List
                if viewModel.isScanningResources {
                    loadingView
                } else if let error = viewModel.resourceScanError {
                    errorView(error)
                } else if filteredResources.isEmpty {
                    emptyView
                } else if !filteredResources.isEmpty {
                    resourceList
                }
            }
            .navigationTitle("Find Resources")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.inspectCurrentPageResources()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isScanningResources)
                }
            }
            .onAppear {
                viewModel.expandStreamingManifests()
            }
            .sheet(item: $previewItem) { item in
                #if canImport(AVKit) && canImport(UIKit) && (os(iOS) || os(tvOS) || targetEnvironment(macCatalyst))
                NavigationView {
                    AVPlayerViewRepresentable(url: item.url)
                        .edgesIgnoringSafeArea(.all)
                        .navigationTitle(item.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
                                    previewItem = nil
                                }
                            }
                        }
                }
                #else
                VStack(spacing: 16) {
                    Text("Media Preview")
                        .font(.headline)
                    Text(item.title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(item.url.absoluteString)
                        .font(.caption)
                        .lineLimit(2)
                    Button("Close") {
                        previewItem = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                #endif
            }
        }
    }

    // MARK: - Category Filter Bar

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" Pill
                FilterPill(
                    title: "Media",
                    count: eligibleResources.filter {
                        $0.resourceType == .video || $0.resourceType == .audio
                    }.count,
                    isSelected: selectedCategory == nil && !showsAllResources
                ) {
                    selectedCategory = nil
                    showsAllResources = false
                }

                FilterPill(
                    title: "All",
                    count: eligibleResources.count,
                    isSelected: selectedCategory == nil && showsAllResources
                ) {
                    selectedCategory = nil
                    showsAllResources = true
                }

                // Per-type Pills
                ForEach(WebpageResourceType.allCases) { cat in
                    let count = eligibleResources.filter { $0.resourceType == cat }.count
                    if count > 0 {
                        FilterPill(
                            title: cat.rawValue,
                            count: count,
                            isSelected: selectedCategory == cat
                        ) {
                            selectedCategory = cat
                            showsAllResources = true
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

    // MARK: - Search & Selection Header

    private var searchAndSelectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))

            TextField("Filter by name or extension", text: $searchText)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Resource List

    private var resourceList: some View {
        List {
            ForEach(filteredResources) { resource in
                rowView(for: resource)
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

        ResourceRowView(
            resource: resource,
            candidate: cand,
            qualitySummary: quality,
            variantItem: variant,
            onSelect: {
                if resource.isSegmentChunk {
                    viewModel.blobCaptureErrorMessage = "This is a streaming segment chunk. Download the playlist manifest (.m3u8 or .mpd) instead."
                } else {
                    viewModel.promptDownloadFromInspector(for: resource)
                }
            },
            onPreview: {
                let title = resource.suggestedFilename.isEmpty ? resource.title : resource.suggestedFilename
                previewItem = MediaPreviewItem(url: resource.url, title: title)
            },
            onOpenBrowser: {
                presentationMode.wrappedValue.dismiss()
                viewModel.load(url: resource.url)
            }
        )
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
                viewModel.inspectCurrentPageResources()
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
    public let onSelect: () -> Void
    public let onPreview: (() -> Void)?
    public let onOpenBrowser: (() -> Void)?

    public init(
        resource: WebpageResource,
        candidate: BrowserMediaCandidate? = nil,
        qualitySummary: String? = nil,
        variantItem: HLSVariantStreamItem? = nil,
        onSelect: @escaping () -> Void,
        onPreview: (() -> Void)? = nil,
        onOpenBrowser: (() -> Void)? = nil
    ) {
        self.resource = resource
        self.candidate = candidate
        self.qualitySummary = qualitySummary
        self.variantItem = variantItem
        self.onSelect = onSelect
        self.onPreview = onPreview
        self.onOpenBrowser = onOpenBrowser
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
        self.onSelect = onDownload
        self.onPreview = onPreview
        self.onOpenBrowser = nil
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
                    // Line 1: Actual Filename as headline
                    Text(displayFilename)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Line 2: Size & Quality Specifications
                    HStack(spacing: 6) {
                        Text(displayFileSize)
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)

                        if let variant = variantItem {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            if let resStr = variant.resolutionText ?? variant.resolution.map({ "\($0.width) × \($0.height)" }) {
                                Text(resStr)
                                    .font(.caption)
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
                        } else if resource.isStreamingManifest {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("HLS Stream")
                                .font(.caption)
                                .foregroundColor(.blue)
                        } else if let ext = FilenameExtensionHelper.split(filename: displayFilename).ext, !ext.isEmpty {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(ext.uppercased())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Audio indicator: Small speaker icon ONLY when audio is present
                        if let variant = variantItem, variant.hasAudio {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        // Subtitle indicator
                        if let variant = variantItem, variant.hasSubtitles {
                            Image(systemName: "captions.bubble.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.purple)
                        }
                    }

                    // Line 3: Format Badge & Host
                    HStack(spacing: 6) {
                        if let variant = variantItem {
                            Text(variant.qualityLabel)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue)
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

                // Trailing Contextual Actions
                HStack(spacing: 10) {
                    if isPlayable {
                        Button {
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

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.vertical, 4)
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
