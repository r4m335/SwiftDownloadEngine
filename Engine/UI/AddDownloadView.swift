#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Screen 2: Add Download Screen enabling users to input URLs, customize filenames, configure segment workers, and start transfers.
public struct AddDownloadView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    @Environment(\.presentationMode) private var presentationMode

    @State private var urlString = ""
    @State private var customFilename = ""
    @State private var workerCount = 6
    @State private var autoStart = true
    @State private var speedLimitKBps = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: URL Entry
                Section(header: Text("Source URL")) {
                    HStack {
                        TextField("https://example.com/file.zip", text: $urlString)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
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
                        #endif
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                // Section 2: Destination & File Settings
                Section(header: Text("Destination & File")) {
                    TextField("Filename (optional)", text: $customFilename)
                        .autocapitalization(.none)
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
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                }

                // Section 4: Action Button
                Section {
                    Button {
                        submitDownload()
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
            .navigationTitle("Add Download")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
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

    private func submitDownload() {
        errorMessage = nil
        isSubmitting = true

        let limit: Int64?
        if let kb = Int64(speedLimitKBps), kb > 0 {
            limit = kb * 1024
        } else {
            limit = nil
        }

        Task {
            do {
                _ = try await viewModel.addDownload(
                    urlText: urlString,
                    filename: customFilename.isEmpty ? nil : customFilename,
                    threadCount: workerCount,
                    speedLimitBytesPerSecond: limit,
                    autoStart: autoStart
                )
                presentationMode.wrappedValue.dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
#endif
