#if canImport(SwiftUI)
import SwiftUI

/// A native confirmation sheet presented when an unsolicited redirect or popup is intercepted.
/// Prompts the user before navigating to another domain, opening a new window, or invoking external schemes.
public struct BrowserRedirectSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    public let prompt: BrowserRedirectPrompt
    @Environment(\.presentationMode) private var presentationMode

    public init(viewModel: BrowserViewModel, prompt: BrowserRedirectPrompt) {
        self.viewModel = viewModel
        self.prompt = prompt
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Header Icon & Title
                VStack(spacing: 8) {
                    Image(systemName: prompt.isSuspicious ? "exclamationmark.triangle.fill" : "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.system(size: 44))
                        .foregroundColor(prompt.isSuspicious ? .orange : .blue)
                        .padding(.top, 24)

                    Text(prompt.isSuspicious ? "Warning: Suspicious Redirect" : "Website wants to open another page")
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Text(prompt.reason.rawValue)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Details Card: Destination & Origin
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Destination")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        Text(prompt.destinationHost)
                            .font(.system(.body, design: .monospaced).bold())
                            .foregroundColor(.primary)

                        Text(prompt.destinationURL.absoluteString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Origin")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        Text(prompt.originHost)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                }
                .padding(16)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(12)
                .padding(.horizontal)

                Spacer()

                // Action Buttons
                VStack(spacing: 12) {
                    Button {
                        viewModel.confirmRedirectInNewTab(prompt)
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Open in New Tab", systemImage: "plus.square.on.square")
                                .font(.headline.bold())
                            Spacer()
                        }
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        viewModel.confirmRedirectInCurrentTab(prompt)
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Open in Current Tab", systemImage: "arrow.right.circle")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .cancel) {
                        viewModel.cancelRedirectPrompt()
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Text("Cancel")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            #if canImport(UIKit)
            .navigationBarHidden(true)
            #endif
        }
    }
}
#endif
