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
        let accentColor: Color = prompt.isSuspicious ? .orange : .blue
        let content = VStack(spacing: 18) {
            // Top Header Badge & Title
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.14))
                        .frame(width: 60, height: 60)
                    Image(systemName: prompt.isSuspicious ? "exclamationmark.shield.fill" : "arrow.up.right.square.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(accentColor)
                }
                .padding(.top, 20)

                Text(prompt.isSuspicious ? "Suspicious Redirect" : "Open External Page?")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text(prompt.reason.rawValue)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            // Origin -> Destination Flow Card
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.secondary.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text("From")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(prompt.originHost)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(accentColor)
                        .frame(width: 24)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 1)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: prompt.destinationURL.scheme?.lowercased() == "https" ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(prompt.destinationURL.scheme?.lowercased() == "https" ? .green : .orange)
                        .frame(width: 24, height: 24)
                        .background((prompt.destinationURL.scheme?.lowercased() == "https" ? Color.green : Color.orange).opacity(0.14), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Destination")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(prompt.destinationHost)
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(prompt.destinationURL.absoluteString)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(accentColor.opacity(prompt.isSuspicious ? 0.35 : 0.16), lineWidth: 1)
            )
            .padding(.horizontal, 20)

            Spacer(minLength: 8)

            // Action Buttons
            VStack(spacing: 10) {
                Button {
                    viewModel.confirmRedirectInNewTab(prompt)
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Label("Open in New Tab", systemImage: "plus.square.on.square")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.confirmRedirectInCurrentTab(prompt)
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Label("Open in Current Tab", systemImage: "arrow.right.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(role: .cancel) {
                    viewModel.cancelRedirectPrompt()
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text("Stay on Page")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        #if canImport(UIKit)
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        #endif

        #if os(iOS)
        if #available(iOS 16.0, *) {
            content
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
#endif
