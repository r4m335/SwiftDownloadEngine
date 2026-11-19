import Foundation

#if canImport(SwiftUI)
import SwiftUI

/// Sheet interface enabling anonymous, multi-provider subtitle search and one-tap application directly within the player.
public struct LIDSubtitleSearchView: View {

    public let mediaTitle: String
    @ObservedObject public var engine: LIDPlaybackEngine
    @Environment(\.presentationMode) private var presentationMode

    @State private var searchText: String = ""
    @State private var selectedLanguage: String = "en"
    @State private var isSearching: Bool = false
    @State private var searchResults: [SubtitleSearchResult] = []
    @State private var downloadedSubtitles: [LIDSubtitleTrack] = []
    @State private var downloadingResultId: String? = nil
    @State private var statusMessage: String? = nil
    @State private var errorMessage: String? = nil

    public init(mediaTitle: String, engine: LIDPlaybackEngine) {
        self.mediaTitle = mediaTitle
        self.engine = engine
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search & Filter Header
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)

                        TextField("Movie or Show Title", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                            #if os(iOS)
                            .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .onSubmit {
                                performSearch()
                            }

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button("Search") {
                            performSearch()
                        }
                        .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                    }
                    .padding(10)
                    .background(fieldBackground)
                    .cornerRadius(10)

                    // Language Filter Picker
                    HStack {
                        Text("Language:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Picker("Language", selection: $selectedLanguage) {
                            ForEach(SubtitleLanguageCatalog.supportedLanguages, id: \.code) { item in
                                Text(item.name).tag(item.code)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())

                        Spacer()

                        if isSearching {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .padding()
                .background(headerBackground)

                Divider()

                // Content View
                if isSearching && searchResults.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView("Searching anonymous subtitle databases...")
                            .font(.subheadline)
                        Text("Querying SubtitleDB & OpenSubtitles")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else if searchResults.isEmpty && !isSearching {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No subtitles found")
                            .font(.headline)
                        Text("Try refining your search keywords or switching languages.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Spacer()
                    }
                } else {
                    List {
                        // Section 1: Search Results
                        Section(header: Text("Online Results (\(searchResults.count))")) {
                            ForEach(searchResults) { result in
                                SubtitleResultRow(
                                    result: result,
                                    isDownloading: downloadingResultId == result.id,
                                    onSelect: {
                                        downloadAndApply(result: result)
                                    }
                                )
                            }
                        }

                        // Section 2: Already Downloaded for this Media
                        if !downloadedSubtitles.isEmpty {
                            Section(header: Text("Downloaded Subtitles")) {
                                ForEach(downloadedSubtitles) { track in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(track.displayName)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                            if let extURL = track.externalURL {
                                                Text(extURL.lastPathComponent)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }

                                        Spacer()

                                        if engine.trackManager.selectedSubtitleTrack.id == track.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                        } else {
                                            Button("Apply") {
                                                engine.selectSubtitleTrack(track)
                                            }
                                            .font(.caption)
                                            .buttonStyle(.bordered)
                                        }

                                        if let extURL = track.externalURL {
                                            Button(role: .destructive) {
                                                deleteSubtitle(url: extURL)
                                            } label: {
                                                Image(systemName: "trash")
                                                    .foregroundColor(.red)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(InsetGroupedListStyle())
                    #else
                    .listStyle(.automatic)
                    #endif
                }

                if let status = statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(8)
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(8)
                }
            }
            .navigationTitle("Download Subtitles")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .task {
                setupInitialQueryAndSearch()
                await refreshDownloadedSubtitles()
            }
        }
    }

    // MARK: - Actions

    private func setupInitialQueryAndSearch() {
        let parsed = LIDFilenameMetadataParser.parse(mediaTitle)
        self.searchText = parsed.fullSearchString
        performSearch()
    }

    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        errorMessage = nil
        statusMessage = nil

        let parsed = LIDFilenameMetadataParser.parse(searchText)
        let query = SubtitleSearchQuery(
            query: parsed.title,
            season: parsed.season,
            episode: parsed.episode,
            year: parsed.year,
            releaseGroup: parsed.releaseGroup,
            language: selectedLanguage
        )

        Task {
            let results = await engine.searchSubtitles(query: query)
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
                if results.isEmpty {
                    self.errorMessage = "No matching subtitles found for this title."
                }
            }
        }
    }

    private func downloadAndApply(result: SubtitleSearchResult) {
        downloadingResultId = result.id
        errorMessage = nil

        Task {
            do {
                let track = try await engine.downloadAndApplySubtitle(result: result, forMediaTitle: mediaTitle)
                await MainActor.run {
                    self.downloadingResultId = nil
                    self.statusMessage = "Applied: \(track.displayName)"
                }
                await refreshDownloadedSubtitles()
            } catch {
                await MainActor.run {
                    self.downloadingResultId = nil
                    self.errorMessage = "Failed to download subtitle: \(error.localizedDescription)"
                }
            }
        }
    }

    private func refreshDownloadedSubtitles() async {
        let subs = await engine.listDownloadedSubtitles(for: mediaTitle)
        await MainActor.run {
            self.downloadedSubtitles = subs
        }
    }

    private func deleteSubtitle(url: URL) {
        Task {
            do {
                try await engine.deleteDownloadedSubtitle(url: url)
            } catch {
                PipelineLogger.shared.log(stage: .ui, message: "Failed to delete subtitle \(url.path): \(error)")
            }
            await refreshDownloadedSubtitles()
        }
    }

    private var fieldBackground: Color {
        #if os(iOS)
        return Color(.secondarySystemBackground)
        #else
        return Color.secondary.opacity(0.15)
        #endif
    }

    private var headerBackground: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #else
        return Color.secondary.opacity(0.08)
        #endif
    }
}

/// A single row representing an online subtitle search result.
private struct SubtitleResultRow: View {
    let result: SubtitleSearchResult
    let isDownloading: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Language badge
            Text(result.languageCode.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 32, height: 24)
                .background(badgeColor(for: result.matchQuality))
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.releaseName ?? result.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(result.providerName)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(result.format.uppercased())
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if result.isHearingImpaired {
                        Text("• HI")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }

                    Spacer()

                    Text(result.matchQuality.rawValue)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(badgeColor(for: result.matchQuality))
                }
            }

            if isDownloading {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button {
                    onSelect()
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
        .padding(.vertical, 4)
    }

    private func badgeColor(for quality: SubtitleMatchQuality) -> Color {
        switch quality {
        case .exactHash, .exactRelease:
            return .green
        case .exactEpisode:
            return .blue
        case .titleAndYear:
            return .orange
        case .keywordMatch:
            return .secondary
        }
    }
}
#endif
