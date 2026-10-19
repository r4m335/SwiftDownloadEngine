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

public enum AddDownloadType: String, CaseIterable, Identifiable {
    case http = "Web (HTTP)"
    case torrent = "BitTorrent"

    public var id: String { rawValue }
}

public enum TorrentInputMode: String, CaseIterable, Identifiable {
    case magnet = "Magnet Link"
    case file = ".torrent File"

    public var id: String { rawValue }
}

/// Screen 2: Add Download Screen enabling users to input HTTP URLs or BitTorrent transfers (Magnet URIs and .torrent files).
public struct AddDownloadView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    @Environment(\.presentationMode) private var presentationMode
    public var onDownloadAdded: (() -> Void)? = nil

    // Common State
    @State private var downloadType: AddDownloadType = .http
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    // HTTP Download State
    @State private var urlString = ""
    @State private var customFilename = ""
    @State private var workerCount = 6
    @State private var autoStart = true
    @State private var speedLimitKBps = ""

    // Torrent Download State
    @State private var torrentInputMode: TorrentInputMode = .magnet
    @State private var magnetURI = ""
    @State private var selectedTorrentURL: URL? = nil
    @State private var selectedTorrentFilename = ""
    @State private var torrentPriority: TorrentPriority = .normal
    @State private var isShowingFileImporter = false

    public init(viewModel: DownloadManagerViewModel, onDownloadAdded: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.onDownloadAdded = onDownloadAdded
        _torrentPriority = State(initialValue: viewModel.defaultTorrentPriority)
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 0: Transfer Type Selector
                Section {
                    Picker("Transfer Type", selection: $downloadType) {
                        ForEach(AddDownloadType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }

                if downloadType == .http {
                    httpFormSections
                } else {
                    torrentFormSections
                }
            }
            .navigationTitle(downloadType == .http ? "Add HTTP Download" : "Add BitTorrent Transfer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
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
                    }
                case .failure(let error):
                    errorMessage = "File import failed: \(error.localizedDescription)"
                }
            }
            #endif
        }
    }

    // MARK: - HTTP Form Sections

    @ViewBuilder
    private var httpFormSections: some View {
        // Section 1: URL Entry
        Section(header: Text("Source URL")) {
            HStack {
                TextField("https://example.com/file.zip", text: $urlString)
                #if canImport(UIKit)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                #endif
                    .disableAutocorrection(true)
                    .onChange(of: urlString) { newURL in
                        autoFillFilename(from: newURL)
                    }

                #if canImport(UIKit)
                Button {
                    if let pasteboard = UIPasteboard.general.string {
                        urlString = pasteboard
                        autoFillFilename(from: pasteboard)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.blue)
                }
                #elseif canImport(AppKit)
                Button {
                    if let pasteboard = NSPasteboard.general.string(forType: .string) {
                        urlString = pasteboard
                        autoFillFilename(from: pasteboard)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.blue)
                }
                #endif
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

        // Section 2: Destination & File Settings
        Section(header: Text("Destination & File")) {
            TextField("Filename (optional)", text: $customFilename)
            #if canImport(UIKit)
                .autocapitalization(.none)
            #endif
                .disableAutocorrection(true)

            HStack {
                Text("Destination")
                    .foregroundColor(.secondary)
                Spacer()
                Text(viewModel.downloadsDirectoryURL.lastPathComponent)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }

        // Section 3: Performance & Worker Configuration
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

        // Section 4: Action Button
        Section {
            Button {
                submitHTTPDownload()
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
            .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
        }
    }

    // MARK: - Torrent Form Sections

    @ViewBuilder
    private var torrentFormSections: some View {
        // Section 1: Ingestion Mode
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

                    #if canImport(UIKit)
                    Button {
                        if let pasteboard = UIPasteboard.general.string {
                            magnetURI = pasteboard
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.blue)
                    }
                    #elseif canImport(AppKit)
                    Button {
                        if let pasteboard = NSPasteboard.general.string(forType: .string) {
                            magnetURI = pasteboard
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

        // Section 2: Torrent Settings & Priority
        Section(header: Text("Torrent Options"), footer: Text("Higher priority torrents receive bandwidth preference and scheduled queue admittance.")) {
            Picker("Priority", selection: $torrentPriority) {
                Text("Low").tag(TorrentPriority.low)
                Text("Normal").tag(TorrentPriority.normal)
                Text("High").tag(TorrentPriority.high)
            }

            HStack {
                Text("Destination")
                    .foregroundColor(.secondary)
                Spacer()
                Text(viewModel.downloadsDirectoryURL.lastPathComponent)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }

        // Section 3: Action Button
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

    private func autoFillFilename(from urlText: String) {
        guard customFilename.isEmpty, let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        let last = url.lastPathComponent
        if !last.isEmpty && last != "/" && last.contains(".") {
            customFilename = last
        }
    }

    private func submitHTTPDownload() {
        errorMessage = nil
        isSubmitting = true

        let limit: Int64?
        if let kb = Int64(speedLimitKBps), kb > 0 {
            limit = kb * 1024
        } else {
            limit = nil
        }

        Task { @MainActor in
            do {
                _ = try await viewModel.addDownload(
                    urlText: urlString,
                    filename: customFilename.isEmpty ? nil : customFilename,
                    threadCount: workerCount,
                    speedLimitBytesPerSecond: limit,
                    autoStart: autoStart
                )

                isSubmitting = false
                successMessage = "Download added successfully."
                viewModel.showNotification("Download added successfully.")
                urlString = ""
                customFilename = ""
                speedLimitKBps = ""

                onDownloadAdded?()
                presentationMode.wrappedValue.dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }

    private func submitTorrentDownload() {
        errorMessage = nil
        isSubmitting = true

        Task { @MainActor in
            do {
                if torrentInputMode == .magnet {
                    _ = try await viewModel.addTorrent(
                        magnetURI: magnetURI,
                        priority: torrentPriority
                    )
                } else if let fileURL = selectedTorrentURL {
                    _ = try await viewModel.addTorrent(
                        fileURL: fileURL,
                        priority: torrentPriority
                    )
                }

                isSubmitting = false
                successMessage = "Torrent added successfully."
                viewModel.showNotification("Torrent added successfully.")
                magnetURI = ""
                selectedTorrentURL = nil
                selectedTorrentFilename = ""

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
