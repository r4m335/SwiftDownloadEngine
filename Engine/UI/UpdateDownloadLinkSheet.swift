#if canImport(SwiftUI)
import SwiftUI

/// Compact modal sheet enabling users to manually replace an expired or invalid URL for a failed download.
public struct UpdateDownloadLinkSheet: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    public let transfer: UnifiedTransfer
    public let onDismiss: () -> Void

    @State private var urlText: String
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String? = nil
    @State private var restartConfirmationReason: String? = nil
    @Environment(\.presentationMode) private var presentationMode

    public init(
        viewModel: DownloadManagerViewModel,
        transfer: UnifiedTransfer,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.transfer = transfer
        self.onDismiss = onDismiss
        _urlText = State(initialValue: transfer.source)
    }

    public var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                // Header Information Card
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(transfer.name)
                            .font(.headline)
                            .lineLimit(2)
                        Spacer()
                        TypeBadge(type: transfer.type)
                    }

                    Text(transfer.type == .hls ? "HLS Streaming Download" : "HTTP Direct Download")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .padding(.top, 4)

                // Explanation Note
                Text("Enter a replacement URL for this download. Completed data will be preserved if the new URL points to the same file.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // URL Input Field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Download Link")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        TextField("https://...", text: $urlText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            #if os(iOS)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            #endif

                        if !urlText.isEmpty {
                            Button {
                                urlText = ""
                                #if canImport(UIKit)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                #endif
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear link")
                        }

                        #if canImport(UIKit)
                        Button {
                            if let paste = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !paste.isEmpty {
                                urlText = paste
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .scaledFont(size: 16)
                                .padding(8)
                        }
                        .buttonStyle(.bordered)
                        #endif
                    }
                }

                if let err = errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }

                Spacer()

                // Action Buttons
                Button {
                    Task {
                        await executeUpdate(forceRestart: false)
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .padding(.trailing, 6)
                        }
                        Text("Update & Resume")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.blue)
                    .cornerRadius(10)
                }
                .disabled(isProcessing || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
            .navigationTitle("Update Download Link")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                        onDismiss()
                    }
                }
            }
            .alert("Resume Unavailable", isPresented: Binding(
                get: { restartConfirmationReason != nil },
                set: { if !$0 { restartConfirmationReason = nil } }
            )) {
                Button("Restart from 0", role: .destructive) {
                    Task {
                        await executeUpdate(forceRestart: true)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(restartConfirmationReason ?? "Server does not support range requests. Restart from byte 0?")
            }
        }
        .modernStackNavigation()
        .modernSheetDetents()
    }

    private func executeUpdate(forceRestart: Bool) async {
        isProcessing = true
        errorMessage = nil

        do {
            try await viewModel.updateTransferLink(
                transfer: transfer,
                newURLText: urlText,
                newHeaders: nil,
                forceRestartIfNonResumable: forceRestart
            )
            isProcessing = false
            presentationMode.wrappedValue.dismiss()
            onDismiss()
        } catch let recoveryError as DownloadRecoveryError {
            isProcessing = false
            switch recoveryError {
            case .restartRequired(let reason):
                restartConfirmationReason = reason
            case .incompatibleResource(let reason):
                errorMessage = "Incompatible file: \(reason)"
            default:
                errorMessage = recoveryError.localizedDescription
            }
        } catch {
            isProcessing = false
            errorMessage = error.localizedDescription
        }
    }
}
#endif
