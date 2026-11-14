#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit

/// Native iOS Share Sheet representation for sharing webpage links and media assets.
public struct BrowserShareSheet: UIViewControllerRepresentable {
    public let items: [Any]
    public let excludedActivityTypes: [UIActivity.ActivityType]?

    public init(items: [Any], excludedActivityTypes: [UIActivity.ActivityType]? = nil) {
        self.items = items
        self.excludedActivityTypes = excludedActivityTypes
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
public struct BrowserShareSheet: View {
    public let items: [Any]

    public init(items: [Any], excludedActivityTypes: [Any]? = nil) {
        self.items = items
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text("Share")
                .font(.headline)
            ForEach(0..<items.count, id: \.self) { i in
                Text(String(describing: items[i]))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}
#endif
#endif
