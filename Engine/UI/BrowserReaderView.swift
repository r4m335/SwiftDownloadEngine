#if canImport(SwiftUI)
import SwiftUI

#if canImport(WebKit)
import WebKit
#endif

/// Presentation interface for Safari-style Reader Mode with dynamic themes and typography controls.
public struct BrowserReaderView: View {
    public let article: BrowserReaderArticle
    @Binding public var settings: BrowserReaderSettings
    public let onDismiss: () -> Void
    public let onShare: () -> Void

    @State private var isShowingAppearanceMenu: Bool = false

    public init(
        article: BrowserReaderArticle,
        settings: Binding<BrowserReaderSettings>,
        onDismiss: @escaping () -> Void,
        onShare: @escaping () -> Void
    ) {
        self.article = article
        self._settings = settings
        self.onDismiss = onDismiss
        self.onShare = onShare
    }

    public var body: some View {
        #if canImport(UIKit)
        NavigationView {
            ZStack {
                themeBackgroundColor
                    .ignoresSafeArea()

                #if canImport(WebKit) && canImport(UIKit)
                BrowserReaderWebViewRepresentable(
                    article: article,
                    settings: settings
                )
                .ignoresSafeArea(edges: .bottom)
                #else
                fallbackScrollView
                #endif
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        onDismiss()
                    }
                    .font(.body.weight(.semibold))
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(article.siteName ?? "Reader")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                        Text("\(article.readingTimeMinutes) min read")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        isShowingAppearanceMenu.toggle()
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .popover(isPresented: $isShowingAppearanceMenu) {
                        appearancePopoverContent
                            .frame(minWidth: 260, maxWidth: 340)
                            .padding()
                    }

                    Button {
                        onShare()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16))
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        #else
        VStack {
            HStack {
                Button("Done", action: onDismiss)
                Spacer()
                Text("\(article.readingTimeMinutes) min read")
                Spacer()
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .padding()
            fallbackScrollView
        }
        #endif
    }

    private var appearancePopoverContent: some View {
        VStack(spacing: 20) {
            Text("Reader Appearance")
                .font(.headline)

            // 1. Font Size Adjustment (A- / A+)
            HStack(spacing: 24) {
                Button {
                    if settings.fontSize > 13.0 {
                        settings.fontSize -= 1.0
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "minus")
                        Text("A")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(8)
                }
                .disabled(settings.fontSize <= 13.0)

                Text("\(Int(settings.fontSize)) pt")
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 44)

                Button {
                    if settings.fontSize < 32.0 {
                        settings.fontSize += 1.0
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("A")
                            .font(.system(size: 20, weight: .bold))
                        Image(systemName: "plus")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(8)
                }
                .disabled(settings.fontSize >= 32.0)
            }

            // 2. Font Family Selection
            Picker("Font Family", selection: $settings.fontFamily) {
                ForEach(BrowserReaderFontFamily.allCases) { family in
                    Text(family.displayName).tag(family)
                }
            }
            .pickerStyle(.segmented)

            // 3. Theme Color Selection (Light, Sepia, Gray, Dark)
            HStack(spacing: 16) {
                themeButton(for: .light, color: Color.white, labelColor: .black)
                themeButton(for: .sepia, color: Color(red: 0.98, green: 0.94, blue: 0.85), labelColor: Color(red: 0.35, green: 0.25, blue: 0.15))
                themeButton(for: .gray, color: Color(white: 0.2), labelColor: .white)
                themeButton(for: .dark, color: Color.black, labelColor: .white)
            }
        }
        .padding()
    }

    private func themeButton(for theme: BrowserReaderTheme, color: Color, labelColor: Color) -> some View {
        Button {
            settings.theme = theme
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle()
                            .stroke(settings.theme == theme ? Color.blue : Color.secondary.opacity(0.3), lineWidth: settings.theme == theme ? 3 : 1)
                    )

                if settings.theme == theme {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(labelColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var themeBackgroundColor: Color {
        switch settings.theme {
        case .light: return Color.white
        case .sepia: return Color(red: 0.98, green: 0.94, blue: 0.85)
        case .gray: return Color(white: 0.18)
        case .dark: return Color.black
        }
    }

    private var themeTextColor: Color {
        switch settings.theme {
        case .light: return Color(white: 0.1)
        case .sepia: return Color(red: 0.35, green: 0.25, blue: 0.15)
        case .gray: return Color(white: 0.9)
        case .dark: return Color(white: 0.85)
        }
    }

    private var fallbackScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(article.title)
                    .font(.title.weight(.bold))
                    .foregroundColor(themeTextColor)

                if let byline = article.byline {
                    Text("By \(byline)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Text(article.plainText)
                    .font(.system(size: CGFloat(settings.fontSize)))
                    .foregroundColor(themeTextColor)
                    .lineSpacing(CGFloat(settings.fontSize * 0.4))
            }
            .padding(24)
        }
        .background(themeBackgroundColor)
    }
}

#if canImport(WebKit) && canImport(UIKit)
/// Isolated WebKit view rendering distilled Reader Mode HTML string safely.
public struct BrowserReaderWebViewRepresentable: UIViewRepresentable {
    public let article: BrowserReaderArticle
    public let settings: BrowserReaderSettings

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Sandboxed configuration: disable inline media auto-play and remote script injection
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        let html = BrowserReaderExtractor.generateReaderHTML(article: article, settings: settings)
        webView.loadHTMLString(html, baseURL: article.sourceURL)
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        let html = BrowserReaderExtractor.generateReaderHTML(article: article, settings: settings)
        uiView.loadHTMLString(html, baseURL: article.sourceURL)
    }
}
#endif
#endif
