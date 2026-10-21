#if canImport(SwiftUI)
import SwiftUI

/// Sheet displaying media assets, documents, and downloadable files discovered inside the active webpage.
public struct BrowserResourceInspectorSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode

    @State private var selectedCategory: WebpageResourceType? = nil
    @State private var searchText: String = ""
    @State private var isDownloadingBatch: Bool = false
    @State private var batchErrorMessage: String? = nil

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var filteredResources: [WebpageResource] {
        viewModel.discoveredResources.filter { res in
            let matchesCategory = selectedCategory == nil || res.resourceType == selectedCategory
            let matchesSearch = searchText.isEmpty ||
                res.title.localizedCaseInsensitiveContains(searchText) ||
                res.suggestedFilename.localizedCaseInsensitiveContains(searchText) ||
                res.url.absoluteString.localizedCaseInsensitiveContains(searchText)
            return matchesCategory && matchesSearch
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
                } else {
                    resourceList
                }

                // Batch Download Footer (when items are selected)
                if !viewModel.selectedResourceIDs.isEmpty {
                    batchDownloadFooter
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
        }
    }

    // MARK: - Category Filter Bar

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" Pill
                FilterPill(
                    title: "All",
                    count: viewModel.discoveredResources.count,
                    isSelected: selectedCategory == nil
                ) {
                    selectedCategory = nil
                }

                // Per-type Pills
                ForEach(WebpageResourceType.allCases) { cat in
                    let count = viewModel.discoveredResources.filter { $0.resourceType == cat }.count
                    if count > 0 {
                        FilterPill(
                            title: cat.rawValue,
                            count: count,
                            isSelected: selectedCategory == cat
                        ) {
                            selectedCategory = cat
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
        HStack(spacing: 8) {
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

            // Select All / Deselect All
            Button {
                toggleSelectAll()
            } label: {
                Text(areAllFilteredSelected ? "Deselect All" : "Select All")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var areAllFilteredSelected: Bool {
        let supported = filteredResources.filter { $0.isSupported }
        guard !supported.isEmpty else { return false }
        return supported.allSatisfy { viewModel.selectedResourceIDs.contains($0.id) }
    }

    private func toggleSelectAll() {
        let supported = filteredResources.filter { $0.isSupported }
        if areAllFilteredSelected {
            for item in supported {
                viewModel.selectedResourceIDs.remove(item.id)
            }
        } else {
            for item in supported {
                viewModel.selectedResourceIDs.insert(item.id)
            }
        }
    }

    // MARK: - Resource List

    private var resourceList: some View {
        List {
            ForEach(filteredResources) { resource in
                ResourceRowView(
                    resource: resource,
                    isSelected: viewModel.selectedResourceIDs.contains(resource.id),
                    onToggleSelect: {
                        if viewModel.selectedResourceIDs.contains(resource.id) {
                            viewModel.selectedResourceIDs.remove(resource.id)
                        } else {
                            viewModel.selectedResourceIDs.insert(resource.id)
                        }
                    },
                    onDownload: {
                        viewModel.promptDownloadFromInspector(for: resource)
                    }
                )
            }
        }
        #if canImport(UIKit)
        .listStyle(InsetGroupedListStyle())
        #endif
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

    // MARK: - Batch Download Footer

    private var batchDownloadFooter: some View {
        VStack(spacing: 8) {
            if let err = batchErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button {
                startBatchDownload()
            } label: {
                HStack {
                    Spacer()
                    if isDownloadingBatch {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    Text("Download Selected (\(viewModel.selectedResourceIDs.count))")
                        .bold()
                    Spacer()
                }
                .padding(12)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(isDownloadingBatch)
        }
        .padding(16)
        #if canImport(UIKit)
        .background(Color(UIColor.secondarySystemBackground))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
    }

    private func startBatchDownload() {
        batchErrorMessage = nil
        isDownloadingBatch = true

        Task { @MainActor in
            do {
                try await viewModel.downloadSelectedResources()
                isDownloadingBatch = false
                presentationMode.wrappedValue.dismiss()
            } catch {
                batchErrorMessage = error.localizedDescription
                isDownloadingBatch = false
            }
        }
    }
}

// MARK: - Resource Row Component

public struct ResourceRowView: View {
    public let resource: WebpageResource
    public let isSelected: Bool
    public let onToggleSelect: () -> Void
    public let onDownload: () -> Void

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Selection Checkbox (if supported)
            if resource.isSupported {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .blue : .secondary)
                        .font(.system(size: 20))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 2)
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundColor(.orange)
                    .font(.system(size: 20))
                    .padding(.top, 2)
            }

            // Resource Icon
            Image(systemName: resource.resourceType.systemImage)
                .font(.system(size: 24))
                .foregroundColor(.blue)
                .frame(width: 30)
                .padding(.top, 2)

            // Resource Metadata
            VStack(alignment: .leading, spacing: 4) {
                Text(resource.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(resource.suggestedFilename)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // URL & Type Badges
                HStack(spacing: 6) {
                    Text(resource.resourceType.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        #if canImport(UIKit)
                        .background(Color(UIColor.tertiarySystemBackground))
                        #else
                        .background(Color.secondary.opacity(0.2))
                        #endif
                        .cornerRadius(4)

                    if let host = resource.url.host {
                        Text(host)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                // Unsupported Warning Badge
                if !resource.isSupported, let reason = resource.unsupportedReason {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                        Text(reason)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.orange)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            // Individual Download Action Button
            if resource.isSupported {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
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
