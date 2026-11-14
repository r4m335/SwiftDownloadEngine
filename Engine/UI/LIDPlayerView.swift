import Foundation

#if canImport(SwiftUI)
import SwiftUI

#if canImport(WebKit)
import WebKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(WebKit) && canImport(UIKit)
/// Native WKWebView representable that renders LID's custom player interface via `BrowserHLSInlinePlayer`.
public struct LIDInlinePlayerWebView: UIViewRepresentable {
    public let url: URL
    public let title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.043, green: 0.059, blue: 0.098, alpha: 1.0)
        let html = BrowserHLSInlinePlayer.html(for: url, title: title)
        webView.loadHTMLString(html, baseURL: url)
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

/// Dedicated LID Media Player sheet that presents media assets and streaming manifests
/// using LID's custom inline player infrastructure (`BrowserHLSInlinePlayer`), completely
/// eliminating reliance on Apple's default `AVPlayerViewController`.
public struct LIDPlayerView: View {
    public let url: URL
    public let title: String
    public var onDismiss: (() -> Void)? = nil
    @Environment(\.presentationMode) private var presentationMode

    public init(url: URL, title: String? = nil, onDismiss: (() -> Void)? = nil) {
        self.url = url
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            self.title = title
        } else {
            let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            self.title = last.isEmpty ? (url.host ?? "LID Media Player") : last
        }
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.043, green: 0.059, blue: 0.098)
                    .edgesIgnoringSafeArea(.all)

                #if canImport(WebKit) && canImport(UIKit)
                LIDInlinePlayerWebView(url: url, title: title)
                    .edgesIgnoringSafeArea(.all)
                #else
                VStack(spacing: 16) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding()
                #endif
            }
            .navigationTitle(title.isEmpty ? "LID Player" : title)
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                }
            }
        }
        #if canImport(UIKit)
        .navigationViewStyle(StackNavigationViewStyle())
        #endif
    }
}
#endif
