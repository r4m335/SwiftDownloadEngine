import Foundation

public enum AddDownloadType: String, CaseIterable, Identifiable, Sendable {
    case http = "HTTP"
    case torrent = "BitTorrent"

    public var id: String { rawValue }
}

public enum HTTPInputMode: String, CaseIterable, Identifiable, Sendable {
    case single = "Single URL"
    case batch = "Multiple URLs / Text Import"
    case pattern = "URL Pattern"

    public var id: String { rawValue }
}

/// Backwards compatibility alias
public typealias BatchInputMode = HTTPInputMode

public enum TorrentInputMode: String, CaseIterable, Identifiable, Sendable {
    case magnet = "Magnet Link"
    case file = ".torrent File"

    public var id: String { rawValue }
}

#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Screen 2: Add Download Screen enabling users to input HTTP URLs (Single URL, Batch Multi-Link, URL Pattern)
/// or BitTorrent transfers (Magnet URIs and .torrent files).
public struct AddDownloadView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    @Environment(\.presentationMode) private var presentationMode
    public var onDownloadAdded: (() -> Void)? = nil
    public var onOpenInBrowser: ((URL) -> Void)? = nil
    /// A URL supplied by the browser's direct-file handoff.
    public var prefilledURL: String?

    // Common State
    @State private var downloadType: AddDownloadType = .http
    @State private var httpInputMode: HTTPInputMode = .single
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    // HTTP Single URL State
    @State private var urlString = ""
    @State private var baseFilename = ""
    @State private var fileExtension = ""
    @State private var selectedCategory: DownloadCategory = .others
    @State private var workerCount = 6
    @State private var autoStart = true
    @State private var speedLimitKBps = ""
    @State private var isInspectingURL = false
    @State private var inspectionResult: URLInspectionResult? = nil
    @State private var previewPlayURL: URL? = nil

    // Batch Download State (Text Import & Pattern Expansion)
    @State private var patternString = ""
    @State private var multiLineText = ""
    @State private var batchItems: [BatchDownloadItem] = []
    @State private var batchRejectedEntries: [BatchRejectedEntry] = []
    @State private var batchDuplicateCount = 0
    @State private var isParsingBatch = false
    @State private var isShowingTextFileImporter = false
    @State private var showRejectedEntriesModal = false

    // Torrent Download State
    @State private var torrentInputMode: TorrentInputMode = .magnet
    @State private var magnetURI = ""
    @State private var selectedTorrentURL: URL? = nil
    @State private var selectedTorrentFilename = ""
    @State private var torrentBaseFilename = ""
    @State private var torrentFileExtension = ""
    @State private var torrentRootFolderName = ""
    @State private var isMultiFileTorrent = false
    @State private var torrentPriority: TorrentPriority = .normal
    @State private var isSequentialDownload = false
    @State private var isShowingFileImporter = false

    public init(
        viewModel: DownloadManagerViewModel,
        onDownloadAdded: (() -> Void)? = nil,
        onOpenInBrowser: ((URL) -> Void)? = nil,
        prefilledURL: String? = nil
    ) {
        self.viewModel = viewModel
        self.onDownloadAdded = onDownloadAdded
        self.onOpenInBrowser = onOpenInBrowser
        self.prefilledURL = prefilledURL
        _torrentPriority = State(initialValue: viewModel.defaultTorrentPriority)
    }

    private var navigationTitle: String {
        switch downloadType {
        case .http:
            switch httpInputMode {
            case .single: return "Add HTTP Download"
            case .batch: return "Batch / Multi-Link Import"
            case .pattern: return "URL Pattern Expansion"
            }
        case .torrent:
            return "Add BitTorrent Transfer"
        }
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 0: Top-Level Transfer Type Selector (HTTP vs BitTorrent)
                Section {
                    Picker("Transfer Type", selection: $downloadType) {
                        ForEach(AddDownloadType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }

                if downloadType == .http {
                    httpFormContent
                } else {
                    torrentFormSections
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .onAppear { applyPrefilledURL() }
            .onChange(of: prefilledURL) { _ in applyPrefilledURL() }
            .sheet(isPresented: Binding(
                get: { previewPlayURL != nil },
                set: { if !$0 { previewPlayURL = nil } }
            )) {
                if let pURL = previewPlayURL {
                    LIDPlayerView(
                        url: pURL,
                        title: filename.isEmpty ? (inspectedResult?.suggestedBaseFilename ?? "Media Preview") : filename
                    ) {
                        previewPlayURL = nil
                    }
                }
            }
            #if canImport(UniformTypeIdentifiers)
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        selectedTorrentURL = url
                        selectedTorrentFilename = url.lastPathComponent
                        errorMessage = nil
                        processSelectedTorrentFile(url: url)
                    }
                case .failure(let error):
                    errorMessage = "File import failed: \(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $isShowingTextFileImporter,
                allowedContentTypes: [UTType.plainText, UTType.text, UTType(filenameExtension: "txt") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        guard url.startAccessingSecurityScopedResource() else {
                            errorMessage = "Permission denied to read selected file."
                            return
                        }
                        defer { url.stopAccessingSecurityScopedResource() }
                        do {
                            let content = try String(contentsOf: url, encoding: .utf8)
                            multiLineText = content
                            parseBatchText()
                        } catch {
                            errorMessage = "Failed to read text file: \(error.localizedDescription)"
                        }
                    }
                case .failure(let error):
                    errorMessage = "Text file import failed: \(error.localizedDescription)"
                }
            }
            #endif
            .sheet(isPresented: $showRejectedEntriesModal) {
                NavigationView {
                    List(batchRejectedEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.rawText)
                                .font(.subheadline)
                                .bold()
                                .lineLimit(2)
                            Text(entry.reason)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(.vertical, 2)
                    }
                    .navigationTitle("Invalid Entries")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showRejectedEntriesModal = false
                            }
                        }
                    }
                }
            }
        }
    }

    private func applyPrefilledURL() {
        guard let prefilledURL,
              !prefilledURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if prefilledURL.contains("[") && prefilledURL.contains("]") {
            downloadType = .http
            httpInputMode = .pattern
            patternString = prefilledURL
            previewPatternExpansion()
        } else if prefilledURL.lowercased().hasPrefix("magnet:?") {
            downloadType = .torrent
            torrentInputMode = .magnet
            magnetURI = prefilledURL
            processMagnetURI(prefilledURL)
        } else {
            downloadType = .http
            httpInputMode = .single
            urlString = prefilledURL
            inspectURL(prefilledURL)
        }
        errorMessage = nil
    }

    // MARK: - HTTP Form Content (Merged Single URL & Batch Modes)

    @ViewBuilder
    private var httpFormContent: some View {
        Section(header: Text("HTTP Input Mode")) {
            Picker("Mode", selection: $httpInputMode) {
                ForEach(HTTPInputMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
        }

        switch httpInputMode {
        case .single:
            httpSingleURLSections
        case .batch:
            httpBatchTextSections
        case .pattern:
            httpPatternExpansionSections
        }
    }

    // MARK: - Single URL Form Sections

    @ViewBuilder
    private var httpSingleURLSections: some View {
        // Section 1: URL Entry & Inspection Trigger
        Section(header: Text("Source URL")) {
            HStack {
                TextField("https://example.com/file.zip", text: $urlString)
                #if canImport(UIKit)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                #endif
                    .disableAutocorrection(true)
                    .onChange(of: urlString) { newURL in
                        inspectURL(newURL)
                    }

                #if canImport(UIKit)
                Button {
                    if let pasteboard = UIPasteboard.general.string {
                        urlString = pasteboard
                        inspectURL(pasteboard)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.blue)
                }
                #elseif canImport(AppKit)
                Button {
                    if let pasteboard = NSPasteboard.general.string(forType: .string) {
                        urlString = pasteboard
                        inspectURL(pasteboard)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.blue)
                }
                #endif
            }

            if isInspectingURL {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Inspecting URL...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if let success = successMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(success)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }

        // Section 2: URL Inspection Result & Contextual Actions
        if let inspection = inspectionResult {
            inspectionResultSection(inspection)
        }

        // Section 3: Separated Filename & Extension
        Section(
            header: Text("Destination Filename"),
            footer: Text("Result: \(FilenameExtensionHelper.combine(base: baseFilename, ext: fileExtension))")
        ) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Filename")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("Filename", text: $baseFilename)
                    #if canImport(UIKit)
                        .autocapitalization(.none)
                    #endif
                        .disableAutocorrection(true)
                        .onChange(of: baseFilename) { newBase in
                            updateCategoryAfterNameChange()
                        }
                }

                Text(".")
                    .font(.title3)
                    .bold()
                    .foregroundColor(.secondary)
                    .padding(.top, 14)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Extension")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("ext", text: $fileExtension)
                    #if canImport(UIKit)
                        .autocapitalization(.none)
                    #endif
                        .disableAutocorrection(true)
                        .frame(width: 70)
                        .onChange(of: fileExtension) { _ in
                            updateCategoryAfterNameChange()
                        }
                }
            }

            Picker("Category", selection: $selectedCategory) {
                ForEach(DownloadCategory.allCases) { cat in
                    HStack {
                        Image(systemName: cat.iconName)
                        Text(cat.displayName)
                    }
                    .tag(cat)
                }
            }

            HStack {
                Text("Subfolder")
                    .foregroundColor(.secondary)
                Spacer()
                Text("Downloads/\(viewModel.appSettings.subfolderName(for: selectedCategory))")
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }

        // Section 4: Performance & Worker Configuration
        Section(header: Text("Download Acceleration"), footer: Text("Parallel workers divide the file into multi-segment HTTP range chunks.")) {
            Stepper("Worker Threads: \(workerCount)", value: $workerCount, in: 1...32)

            Toggle("Start Download Immediately", isOn: $autoStart)

            HStack {
                Text("Speed Limit (KB/s)")
                Spacer()
                TextField("Unlimited", text: $speedLimitKBps)
                #if canImport(UIKit)
                    .keyboardType(.numberPad)
                #endif
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
            }
        }

        // Section 5: Action Button
        Section {
            Button {
                submitSingleHTTPDownload()
            } label: {
                HStack {
                    Spacer()
                    if isSubmitting {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    Text("Start Download")
                        .bold()
                    Spacer()
                }
            }
            .disabled(isSubmitDisabled)
        }
    }

    private var isSubmitDisabled: Bool {
        if urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting {
            return true
        }
        if let inspection = inspectionResult {
            if case .ordinaryWebpage = inspection.kind {
                return true
            }
        }
        return false
    }

    @ViewBuilder
    private func inspectionResultSection(_ inspection: URLInspectionResult) -> some View {
        switch inspection.kind {
        case .ordinaryWebpage(let pageURL, _):
            Section(header: Text("Webpage Detected")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "safari.fill")
                            .font(.title2)
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("HTML Webpage")
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                            Text("This URL points to an HTML webpage rather than a direct downloadable file.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button {
                        if let cb = onOpenInBrowser {
                            cb(pageURL)
                        }
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Open in LID Browser", systemImage: "globe")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)

                    Text("To download media from this page, open it in LID Browser and inspect resources using the Grabber tool.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

        case .playableMedia(let mediaURL, _, let ext, _, let size):
            Section(header: Text("Media Inspection")) {
                HStack {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Playable Media (\(ext.uppercased()))")
                            .font(.subheadline.bold())
                        if let s = size {
                            Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        previewPlayURL = mediaURL
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .streamingManifest(let kind, let manifestURL, _, let summary):
            Section(header: Text("Stream Manifest")) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind == .hls ? "HLS Master Playlist" : "MPEG-DASH Manifest")
                            .font(.subheadline.bold())
                        if let sum = summary {
                            Text(sum)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        previewPlayURL = manifestURL
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .directDownload(_, let ext, let mime, let size):
            Section(header: Text("Direct Download File")) {
                HStack {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloadable File (\(ext.uppercased()))")
                            .font(.subheadline.bold())
                        HStack(spacing: 6) {
                            if let s = size {
                                Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let m = mime {
                                Text("• \(m)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

        case .unknown(let url, let reason):
            Section(header: Text("URL Notice")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        if let cb = onOpenInBrowser {
                            cb(url)
                        }
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Label("Open in Browser", systemImage: "globe")
                            .font(.caption.bold())
                    }
                }
            }
        }
    }

    private func updateCategoryAfterNameChange() {
        let combined = FilenameExtensionHelper.combine(base: baseFilename, ext: fileExtension)
        if !combined.isEmpty {
            selectedCategory = DownloadCategoryClassifier.classify(
                mimeType: inspectionResult?.mimeType,
                filename: combined
            )
        }
    }

    private func inspectURL(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            inspectionResult = nil
            return
        }
        isInspectingURL = true
        Task { @MainActor in
            let result = await URLInspector.shared.inspect(url: url)
            if self.urlString.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) {
                self.inspectionResult = result
                if self.baseFilename.isEmpty || self.baseFilename == "download" {
                    self.baseFilename = result.suggestedBaseFilename
                    self.fileExtension = result.suggestedExtension
                }
                updateCategoryAfterNameChange()
            }
            self.isInspectingURL = false
        }
    }

    private func submitSingleHTTPDownload() {
        errorMessage = nil
        isSubmitting = true

        let limit: Int64?
        if let kb = Int64(speedLimitKBps), kb > 0 {
            limit = kb * 1024
        } else {
            limit = nil
        }

        let finalFilename = FilenameExtensionHelper.combine(base: baseFilename, ext: fileExtension)

        Task { @MainActor in
            do {
                _ = try await viewModel.addDownload(
                    urlText: urlString,
                    filename: finalFilename.isEmpty ? nil : finalFilename,
                    threadCount: workerCount,
                    speedLimitBytesPerSecond: limit,
                    autoStart: autoStart,
                    category: selectedCategory
                )

                isSubmitting = false
                successMessage = "Download added successfully."
                viewModel.showNotification("Download added successfully.")
                urlString = ""
                baseFilename = ""
                fileExtension = ""
                speedLimitKBps = ""

                onDownloadAdded?()
                presentationMode.wrappedValue.dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }

    // MARK: - Batch Form Sections (Text Import & Pattern Expansion)

    @ViewBuilder
    private var httpBatchTextSections: some View {
        Section(header: Text("Multi-Link Text Import")) {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $multiLineText)
                    .frame(minHeight: 120, maxHeight: 180)
                    .font(.system(.caption, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                HStack(spacing: 12) {
                    #if canImport(UIKit)
                    Button {
                        if let pasteboard = UIPasteboard.general.string {
                            multiLineText = pasteboard
                            parseBatchText()
                        }
                    } label: {
                        Label("Paste URLs", systemImage: "doc.on.clipboard")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    #elseif canImport(AppKit)
                    Button {
                        if let pasteboard = NSPasteboard.general.string(forType: .string) {
                            multiLineText = pasteboard
                            parseBatchText()
                        }
                    } label: {
                        Label("Paste URLs", systemImage: "doc.on.clipboard")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    #endif

                    #if canImport(UniformTypeIdentifiers)
                    Button {
                        isShowingTextFileImporter = true
                    } label: {
                        Label("Import .txt...", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    #endif

                    Spacer()

                    Button {
                        parseBatchText()
                    } label: {
                        HStack {
                            if isParsingBatch {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Label("Parse Links", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(multiLineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsingBatch)
                }
            }

            batchStatusMessages
        }

        batchItemsPreviewAndConfiguration
    }

    @ViewBuilder
    private var httpPatternExpansionSections: some View {
        Section(header: Text("URL Pattern Expansion")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("https://example.com/file[001-050].zip", text: $patternString)
                    #if canImport(UIKit)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                    #endif
                        .disableAutocorrection(true)

                    #if canImport(UIKit)
                    Button {
                        if let pasteboard = UIPasteboard.general.string {
                            patternString = pasteboard
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.blue)
                    }
                    #elseif canImport(AppKit)
                    Button {
                        if let pasteboard = NSPasteboard.general.string(forType: .string) {
                            patternString = pasteboard
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.blue)
                    }
                    #endif
                }

                Text("Example: https://example.com/file[001-050].zip or [1-20] or [a-z]")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button {
                    previewPatternExpansion()
                } label: {
                    HStack {
                        if isParsingBatch {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Image(systemName: "wand.and.stars")
                        Text("Preview Pattern")
                    }
                    .font(.subheadline.bold())
                }
                .padding(.top, 4)
                .disabled(patternString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsingBatch)
            }

            batchStatusMessages
        }

        batchItemsPreviewAndConfiguration
    }

    @ViewBuilder
    private var batchStatusMessages: some View {
        if let error = errorMessage {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
        }

        if let success = successMessage {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(success)
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }

    @ViewBuilder
    private var batchItemsPreviewAndConfiguration: some View {
        if !batchItems.isEmpty {
            Section(header: HStack {
                Text("Batch Preview (\(batchItems.count) links)")
                Spacer()
                if batchItems.allSatisfy(\.isSelected) {
                    Button("Deselect All") {
                        for i in 0..<batchItems.count { batchItems[i].isSelected = false }
                    }
                    .font(.caption2)
                } else {
                    Button("Select All") {
                        for i in 0..<batchItems.count { batchItems[i].isSelected = true }
                    }
                    .font(.caption2)
                }
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("\(batchItems.filter(\.isSelected).count) of \(batchItems.count) selected")
                            .font(.caption.bold())
                            .foregroundColor(.primary)

                        if batchDuplicateCount > 0 {
                            Text("• \(batchDuplicateCount) duplicates omitted")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !batchRejectedEntries.isEmpty {
                        Button {
                            showRejectedEntriesModal = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("\(batchRejectedEntries.count) invalid entries skipped (View details)")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)

                ForEach(batchItems) { item in
                    HStack(spacing: 10) {
                        Button {
                            if let idx = batchItems.firstIndex(where: { $0.id == item.id }) {
                                batchItems[idx].isSelected.toggle()
                            }
                        } label: {
                            Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(item.isSelected ? .blue : .secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.filename)
                                    .font(.subheadline)
                                    .bold()
                                    .lineLimit(1)

                                Spacer()

                                Image(systemName: item.category.iconName)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(item.category.displayName)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Text(item.url.absoluteString)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Button {
                            batchItems.removeAll(where: { $0.id == item.id })
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }

                Button(role: .destructive) {
                    batchItems.removeAll()
                    batchRejectedEntries.removeAll()
                    batchDuplicateCount = 0
                } label: {
                    HStack {
                        Spacer()
                        Label("Clear All Links", systemImage: "trash")
                            .font(.caption)
                        Spacer()
                    }
                }
            }

            // Batch Download Settings
            Section(header: Text("Batch Download Settings")) {
                Picker("Category Override", selection: $selectedCategory) {
                    Text("Auto Detect").tag(DownloadCategory.others)
                    ForEach(DownloadCategory.allCases) { cat in
                        HStack {
                            Image(systemName: cat.iconName)
                            Text(cat.displayName)
                        }
                        .tag(cat)
                    }
                }

                Stepper("Worker Threads: \(workerCount)", value: $workerCount, in: 1...32)

                Toggle("Start Immediately", isOn: $autoStart)

                HStack {
                    Text("Speed Limit (KB/s)")
                    Spacer()
                    TextField("Unlimited", text: $speedLimitKBps)
                    #if canImport(UIKit)
                        .keyboardType(.numberPad)
                    #endif
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                }
            }

            // Start All Action
            Section {
                Button {
                    submitBatchDownloads()
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text("Start All Downloads (\(batchItems.filter(\.isSelected).count))")
                            .bold()
                        Spacer()
                    }
                }
                .disabled(batchItems.filter(\.isSelected).isEmpty || isSubmitting)
            }
        }
    }

    private func previewPatternExpansion() {
        errorMessage = nil
        successMessage = nil
        isParsingBatch = true

        do {
            let urls = try BatchURLExpander.expandPattern(patternString)
            let result = BatchExpansionResult(validURLs: urls, rejectedEntries: [], duplicateCount: 0)
            self.batchItems = result.toDownloadItems()
            self.batchRejectedEntries = []
            self.batchDuplicateCount = 0
            self.isParsingBatch = false
            self.successMessage = "Expanded \(urls.count) URLs from pattern."
        } catch {
            self.errorMessage = error.localizedDescription
            self.isParsingBatch = false
        }
    }

    private func parseBatchText() {
        errorMessage = nil
        successMessage = nil
        isParsingBatch = true

        let result = BatchURLExpander.parseMultiLineText(multiLineText, expandPatterns: true)
        self.batchItems = result.toDownloadItems()
        self.batchRejectedEntries = result.rejectedEntries
        self.batchDuplicateCount = result.duplicateCount
        self.isParsingBatch = false

        if result.validURLs.isEmpty {
            self.errorMessage = "No valid HTTP/HTTPS URLs were detected in input."
        } else {
            self.successMessage = "Found \(result.validURLs.count) valid URLs."
        }
    }

    private func submitBatchDownloads() {
        errorMessage = nil
        isSubmitting = true

        let limit: Int64?
        if let kb = Int64(speedLimitKBps), kb > 0 {
            limit = kb * 1024
        } else {
            limit = nil
        }

        let itemsToDownload = batchItems.filter(\.isSelected)

        Task { @MainActor in
            do {
                _ = try await viewModel.addBatchDownloads(
                    items: itemsToDownload,
                    threadCount: workerCount,
                    speedLimitBytesPerSecond: limit,
                    autoStart: autoStart,
                    categoryOverride: selectedCategory == .others ? nil : selectedCategory
                )

                isSubmitting = false
                viewModel.showNotification("Started \(itemsToDownload.count) batch downloads.")
                batchItems.removeAll()
                patternString = ""
                multiLineText = ""

                onDownloadAdded?()
                presentationMode.wrappedValue.dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }

    // MARK: - Torrent Form Sections

    @ViewBuilder
    private var torrentFormSections: some View {
        Section(header: Text("Torrent Source")) {
            Picker("Input Mode", selection: $torrentInputMode) {
                ForEach(TorrentInputMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(SegmentedPickerStyle())

            if torrentInputMode == .magnet {
                HStack {
                    TextField("magnet:?xt=urn:btih:...", text: $magnetURI)
                    #if canImport(UIKit)
                        .autocapitalization(.none)
                    #endif
                        .disableAutocorrection(true)
                        .onChange(of: magnetURI) { newURI in
                            processMagnetURI(newURI)
                        }

                    #if canImport(UIKit)
                    Button {
                        if let pasteboard = UIPasteboard.general.string {
                            magnetURI = pasteboard
                            processMagnetURI(pasteboard)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.blue)
                    }
                    #elseif canImport(AppKit)
                    Button {
                        if let pasteboard = NSPasteboard.general.string(forType: .string) {
                            magnetURI = pasteboard
                            processMagnetURI(pasteboard)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.blue)
                    }
                    #endif
                }

                if isMagnetValid {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Valid Magnet URI format")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                } else if !magnetURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Magnet URI must begin with 'magnet:?' and contain an 'xt=urn:btih:' info-hash.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedTorrentFilename.isEmpty ? "No file selected" : selectedTorrentFilename)
                            .font(.body)
                            .foregroundColor(selectedTorrentFilename.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                        if let url = selectedTorrentURL {
                            Text(url.path)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Browse...") {
                        isShowingFileImporter = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if let success = successMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(success)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }

        // Section 2: Destination & Naming Structure
        Section(
            header: Text("Destination & Structure"),
            footer: Text(isMultiFileTorrent ? "Multi-file torrent will extract contents into this folder." : "Single-file torrent will download with this filename.")
        ) {
            Picker("Structure", selection: $isMultiFileTorrent) {
                Text("Single File").tag(false)
                Text("Multi-File Folder").tag(true)
            }
            .pickerStyle(SegmentedPickerStyle())

            if isMultiFileTorrent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Root Destination Folder")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("Folder name", text: $torrentRootFolderName)
                    #if canImport(UIKit)
                        .autocapitalization(.none)
                    #endif
                        .disableAutocorrection(true)
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Filename")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        TextField("Filename", text: $torrentBaseFilename)
                        #if canImport(UIKit)
                            .autocapitalization(.none)
                        #endif
                            .disableAutocorrection(true)
                    }

                    Text(".")
                        .font(.title3)
                        .bold()
                        .foregroundColor(.secondary)
                        .padding(.top, 14)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extension")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        TextField("ext", text: $torrentFileExtension)
                        #if canImport(UIKit)
                            .autocapitalization(.none)
                        #endif
                            .disableAutocorrection(true)
                            .frame(width: 70)
                    }
                }
            }
        }

        // Section 3: Torrent Settings & Priority
        Section(header: Text("Torrent Options"), footer: Text("Higher priority torrents receive bandwidth preference. Sequential download requests pieces in chronological order.")) {
            Picker("Priority", selection: $torrentPriority) {
                Text("Low").tag(TorrentPriority.low)
                Text("Normal").tag(TorrentPriority.normal)
                Text("High").tag(TorrentPriority.high)
            }

            Toggle("Sequential Piece Download", isOn: $isSequentialDownload)

            HStack {
                Text("Destination")
                    .foregroundColor(.secondary)
                Spacer()
                Text("Downloads/\(viewModel.appSettings.subfolderName(for: .torrents))")
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }

        // Section 4: Action Button
        Section {
            Button {
                submitTorrentDownload()
            } label: {
                HStack {
                    Spacer()
                    if isSubmitting {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    Text("Start Torrent Transfer")
                        .bold()
                    Spacer()
                }
            }
            .disabled(!canSubmitTorrent || isSubmitting)
        }
    }

    private var isMagnetValid: Bool {
        let trimmed = magnetURI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("magnet:?") && (trimmed.contains("xt=urn:btih:") || trimmed.contains("xt=urn:btmh:"))
    }

    private var canSubmitTorrent: Bool {
        if torrentInputMode == .magnet {
            return isMagnetValid
        } else {
            return selectedTorrentURL != nil
        }
    }

    private func processMagnetURI(_ uri: String) {
        if let name = TorrentMetadataParser.extractDisplayName(from: uri) {
            if name.contains(".") {
                isMultiFileTorrent = false
                let (base, ext) = FilenameExtensionHelper.split(filename: name)
                torrentBaseFilename = base
                torrentFileExtension = ext
            } else {
                isMultiFileTorrent = true
                torrentRootFolderName = name
            }
        }
    }

    private func processSelectedTorrentFile(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        if let parsed = TorrentMetadataParser.extractBencodedInfo(from: data) {
            let candidateName = parsed.name ?? url.deletingPathExtension().lastPathComponent
            isMultiFileTorrent = parsed.isMultiFile
            if parsed.isMultiFile {
                torrentRootFolderName = candidateName
            } else {
                let (base, ext) = FilenameExtensionHelper.split(filename: candidateName)
                torrentBaseFilename = base
                torrentFileExtension = ext
            }
        }
    }

    private func submitTorrentDownload() {
        errorMessage = nil
        isSubmitting = true

        let customName: String? = {
            if isMultiFileTorrent {
                let trimmed = torrentRootFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : FilenameExtensionHelper.sanitizeFilename(trimmed)
            } else {
                let combined = FilenameExtensionHelper.combine(base: torrentBaseFilename, ext: torrentFileExtension)
                let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }()

        Task { @MainActor in
            do {
                if torrentInputMode == .magnet {
                    _ = try await viewModel.addTorrent(
                        magnetURI: magnetURI,
                        name: customName,
                        priority: torrentPriority,
                        isSequential: isSequentialDownload
                    )
                } else if let fileURL = selectedTorrentURL {
                    _ = try await viewModel.addTorrent(
                        fileURL: fileURL,
                        name: customName,
                        priority: torrentPriority,
                        isSequential: isSequentialDownload
                    )
                }

                isSubmitting = false
                successMessage = "Torrent added successfully."
                viewModel.showNotification("Torrent added successfully.")
                magnetURI = ""
                selectedTorrentURL = nil
                selectedTorrentFilename = ""
                torrentBaseFilename = ""
                torrentFileExtension = ""
                torrentRootFolderName = ""

                onDownloadAdded?()
                presentationMode.wrappedValue.dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
#endif
