#if canImport(SwiftUI)
import SwiftUI

/// Screen presented when a multi-variant stream (HLS or DASH) is detected,
/// enabling the user to choose their preferred resolution (1080p, 720p, 480p, or Audio-Only)
/// before initiating the download.
public struct StreamQualityPickerSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if viewModel.isInspectingQualities {
                    loadingView
                } else if let error = viewModel.qualityInspectionError {
                    errorView(error)
                } else if viewModel.qualityPickerOptions.isEmpty {
                    emptyView
                } else {
                    contentView
                }
            }
            .navigationTitle("Select Video Quality")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.isShowingQualityPicker = false
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Analyzing Stream Renditions...")
                .font(.headline)
            Text("Fetching manifest and extracting available resolutions.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text("Quality Discovery Incomplete")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Download with Default Quality") {
                viewModel.confirmQualitySelectionAndDownload()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
            Spacer()
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("No Specific Renditions Discovered")
                .font(.headline)
            Text("This stream will download at its native standard resolution.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Start Download") {
                viewModel.confirmQualitySelectionAndDownload()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private var contentView: some View {
        Form {
            // Section 1: File & Stream Info
            Section(header: Text("Destination Filename")) {
                TextField("Filename", text: $viewModel.qualityPickerFilename)
                    #if canImport(UIKit)
                    .autocapitalization(.none)
                    #endif
                    .disableAutocorrection(true)

                if let resource = viewModel.qualityPickerTargetResource {
                    HStack {
                        Text("Stream Type")
                        Spacer()
                        Text(resource.url.pathExtension.uppercased())
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
            }

            // Section 2: Quality Selection List
            Section(
                header: Text("Available Resolutions (\(viewModel.qualityPickerOptions.count))"),
                footer: Text("Higher resolutions require more storage and bandwidth. Audio-only exports a standalone soundtrack file.")
            ) {
                ForEach(viewModel.qualityPickerOptions) { option in
                    Button {
                        viewModel.selectQualityOption(option)
                    } label: {
                        HStack(spacing: 12) {
                            // Quality Badge
                            Text(option.qualityBadge)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 58, height: 26)
                                .background(option.badgeColor)
                                .cornerRadius(6)

                            // Title & Specs
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(option.label)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)

                                    if option.isAudioOnly {
                                        Image(systemName: "headphones")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }

                                HStack(spacing: 6) {
                                    if let res = option.resolutionText {
                                        Text(res)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text("•")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    Text(option.bitrateText)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    if let codec = option.videoCodec {
                                        Text("•")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(codec)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    if let size = option.estimatedSizeText {
                                        Text("•")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(size)
                                            .font(.caption2.bold())
                                            .foregroundColor(.primary)
                                    }
                                }
                            }

                            Spacer()

                            // Checkmark
                            if viewModel.selectedQualityOption?.id == option.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 20))
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.secondary.opacity(0.4))
                                    .font(.system(size: 20))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Section 3: Confirm Download Action
            Section {
                Button {
                    viewModel.confirmQualitySelectionAndDownload()
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text(downloadButtonTitle)
                            .font(.system(size: 16, weight: .bold))
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .disabled(viewModel.selectedQualityOption == nil && !viewModel.qualityPickerOptions.isEmpty)
            }
        }
    }

    private var downloadButtonTitle: String {
        if let selected = viewModel.selectedQualityOption {
            if selected.isAudioOnly {
                return "Download Audio Only"
            } else {
                return "Download \(selected.qualityBadge)"
            }
        }
        return "Start Download"
    }
}
#endif

