#if canImport(SwiftUI)
import SwiftUI

#if canImport(QuickLook)
import QuickLook
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Identifiable wrapper for file URLs to be presented cleanly in SwiftUI sheets and fullScreenCovers.
public struct IdentifiableURL: Identifiable, Equatable {
    public var id: String { url.absoluteString }
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}

#if canImport(QuickLook) && canImport(UIKit)
/// Custom UIViewControllerRepresentable wrapping Apple's QLPreviewController for universal file previewing.
public struct FilePreviewController: UIViewControllerRepresentable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    public func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    public final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif

/// Container view that presents the file preview inside a navigation container with guaranteed dismiss controls.
/// Provides both a Navigation Bar "Done" button and a floating ZStack overlay "Done" button so the user is never trapped.
public struct FilePreviewContainerView: View {
    public let url: URL
    public let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismissAction

    public init(url: URL, onDismiss: @escaping () -> Void) {
        self.url = url
        self.onDismiss = onDismiss
    }

    public var body: some View {
        #if os(iOS)
        NavigationView {
            ZStack(alignment: .topLeading) {
                #if canImport(QuickLook) && canImport(UIKit)
                FilePreviewController(url: url)
                    .ignoresSafeArea(edges: .bottom)
                #else
                fallbackView
                #endif

                // Floating "Done" overlay button in top-left corner
                // Guarantees dismissibility even when the video player or QuickLook hides the navigation bar
                Button(action: dismiss) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                        Text("Done")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 2)
                }
                .padding(.top, 12)
                .padding(.leading, 16)
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        #else
        VStack(spacing: 0) {
            HStack {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(url.lastPathComponent).font(.headline)
                Spacer()
            }
            .padding()
            Divider()
            fallbackView
        }
        #endif
    }

    private func dismiss() {
        onDismiss()
        dismissAction()
    }

    private var fallbackView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            Text(url.lastPathComponent)
                .font(.headline)
            Text(url.path)
                .font(.caption)
                .foregroundColor(.secondary)
            #if os(macOS)
            Button("Open in Default App") {
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Presents a file preview with guaranteed navigation and dismissal controls.
    @ViewBuilder
    public func filePreviewSheet(item: Binding<URL?>) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: Binding<IdentifiableURL?>(
            get: { item.wrappedValue.map { IdentifiableURL(url: $0) } },
            set: { item.wrappedValue = $0?.url }
        )) { previewItem in
            FilePreviewContainerView(url: previewItem.url) {
                item.wrappedValue = nil
            }
        }
        #else
        self.sheet(item: Binding<IdentifiableURL?>(
            get: { item.wrappedValue.map { IdentifiableURL(url: $0) } },
            set: { item.wrappedValue = $0?.url }
        )) { previewItem in
            FilePreviewContainerView(url: previewItem.url) {
                item.wrappedValue = nil
            }
        }
        #endif
    }
}
#endif
