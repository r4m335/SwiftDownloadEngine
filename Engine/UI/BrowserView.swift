#if canImport(SwiftUI)
import SwiftUI

#if canImport(WebKit)
import WebKit
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Browser View Model

/// Manages navigation state and coordinates actions between SwiftUI and WKWebView.
@MainActor
public final class BrowserViewModel: NSObject, ObservableObject {
    @Published public var urlInputText: String = ""
    @Published public var currentURL: URL? = nil
    @Published public var pageTitle: String = ""
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    @Published public var isLoading: Bool = false
    @Published public var estimatedProgress: Double = 0.0
    @Published public var errorMessage: String? = nil
    @Published public var selectedSearchEngine: BrowserSearchEngine = .duckDuckGo

    // Download modal state
    @Published public var isShowingDownloadSheet: Bool = false
    @Published public var downloadCandidateURL: URL? = nil
    @Published public var downloadCandidateFilename: String = ""
    @Published public var downloadCandidateThreads: Int = 6
    @Published public var downloadCandidateSpeedLimitKBps: String = ""
    @Published public var downloadSuccessNotification: String? = nil

    public weak var downloadDelegate: BrowserDownloadDelegate?
    public var onDownloadInitiated: (() -> Void)? = nil

    #if canImport(WebKit)
    public weak var webView: WKWebView?
    #endif

    public init(downloadDelegate: BrowserDownloadDelegate? = nil, onDownloadInitiated: (() -> Void)? = nil) {
        self.downloadDelegate = downloadDelegate
        self.onDownloadInitiated = onDownloadInitiated
        super.init()
    }

    public func navigate(to input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let url = BrowserURLResolver.resolve(input: trimmed, searchEngine: selectedSearchEngine) else {
            errorMessage = "Invalid or unsupported web address. Only HTTP and HTTPS are permitted."
            return
        }

        load(url: url)
    }

    public func load(url: URL) {
        errorMessage = nil
        currentURL = url
        urlInputText = url.absoluteString

        #if canImport(WebKit)
        let request = URLRequest(url: url)
        webView?.load(request)
        #endif
    }

    public func goBack() {
        errorMessage = nil
        #if canImport(WebKit)
        webView?.goBack()
        #endif
    }

    public func goForward() {
        errorMessage = nil
        #if canImport(WebKit)
        webView?.goForward()
        #endif
    }

    public func reload() {
        errorMessage = nil
        #if canImport(WebKit)
        if let wv = webView, wv.url != nil {
            wv.reload()
        } else if let url = currentURL {
            load(url: url)
        }
        #endif
    }

    public func stopLoading() {
        #if canImport(WebKit)
        webView?.stopLoading()
        #endif
        isLoading = false
    }

    public func goHome() {
        #if canImport(WebKit)
        webView?.stopLoading()
        if let blank = URL(string: "about:blank") {
            webView?.load(URLRequest(url: blank))
        }
        #endif
        currentURL = nil
        urlInputText = ""
        pageTitle = ""
        errorMessage = nil
        isLoading = false
        estimatedProgress = 0.0
        canGoBack = false
        canGoForward = false
    }

    public func prepareDownloadCurrentURL() {
        guard let url = currentURL, BrowserURLResolver.isValidDownloadURL(url) else {
            errorMessage = "The current page URL cannot be downloaded directly."
            return
        }
        downloadCandidateURL = url
        downloadCandidateFilename = BrowserURLResolver.suggestedFilename(from: url)
        downloadCandidateThreads = 6
        downloadCandidateSpeedLimitKBps = ""
        isShowingDownloadSheet = true
    }

    public func executeDownload() async throws {
        guard let url = downloadCandidateURL else { return }
        let limit: Int64?
        if let kb = Int64(downloadCandidateSpeedLimitKBps), kb > 0 {
            limit = kb * 1024
        } else {
            limit = nil
        }

        try await downloadDelegate?.handleDownloadRequest(
            url: url,
            filename: downloadCandidateFilename.isEmpty ? nil : downloadCandidateFilename,
            threadCount: downloadCandidateThreads,
            speedLimitBytesPerSecond: limit
        )

        isShowingDownloadSheet = false
        downloadSuccessNotification = "Download queued: \(downloadCandidateFilename)"
        onDownloadInitiated?()
    }
}

// MARK: - Browser View (SwiftUI)

/// Native in-app web browser interface integrating address bar, navigation controls, and direct engine download handoff.
public struct BrowserView: View {
    @StateObject public var viewModel: BrowserViewModel
    @FocusState private var isAddressBarFocused: Bool

    public init(viewModel: BrowserViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public init(downloadDelegate: BrowserDownloadDelegate? = nil, onDownloadInitiated: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: BrowserViewModel(
            downloadDelegate: downloadDelegate,
            onDownloadInitiated: onDownloadInitiated
        ))
    }

    public init(viewModel: DownloadManagerViewModel, onDownloadInitiated: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: BrowserViewModel(
            downloadDelegate: viewModel,
            onDownloadInitiated: onDownloadInitiated
        ))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Address & Navigation Header
            addressBarHeader

            // Loading Progress Bar
            if viewModel.isLoading {
                ProgressView(value: max(0.05, viewModel.estimatedProgress), total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .frame(height: 2)
            } else {
                Divider()
            }

            // Main View Area: Home Screen, Error Screen, or Active Web View
            ZStack {
                if viewModel.currentURL == nil {
                    BrowserHomeView(viewModel: viewModel)
                } else if let error = viewModel.errorMessage {
                    BrowserErrorView(error: error, onRetry: {
                        viewModel.reload()
                    }, onHome: {
                        viewModel.goHome()
                    })
                } else {
                    #if canImport(WebKit)
                    PlatformWebView(viewModel: viewModel)
                    #else
                    Text("WebKit is not supported in this environment.")
                        .foregroundColor(.secondary)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom Navigation Toolbar
            bottomToolbar
        }
        .sheet(isPresented: $viewModel.isShowingDownloadSheet) {
            BrowserDownloadSheet(viewModel: viewModel)
        }
        #if canImport(UIKit)
        .background(Color(UIColor.systemBackground))
        #endif
    }

    // MARK: - Address Bar Header

    private var addressBarHeader: some View {
        HStack(spacing: 8) {
            // Address Bar Capsule
            HStack(spacing: 6) {
                // Security / Search Icon
                if let url = viewModel.currentURL {
                    if url.scheme?.lowercased() == "https" {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "lock.slash.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                TextField("Search or enter website address", text: $viewModel.urlInputText)
                    #if canImport(UIKit)
                    .keyboardType(.webSearch)
                    .autocapitalization(.none)
                    #endif
                    .disableAutocorrection(true)
                    .focused($isAddressBarFocused)
                    .onSubmit {
                        viewModel.navigate(to: viewModel.urlInputText)
                        isAddressBarFocused = false
                    }

                if viewModel.isLoading {
                    Button {
                        viewModel.stopLoading()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                } else if !viewModel.urlInputText.isEmpty {
                    Button {
                        if viewModel.currentURL != nil {
                            viewModel.reload()
                        } else {
                            viewModel.urlInputText = ""
                        }
                    } label: {
                        Image(systemName: viewModel.currentURL != nil ? "arrow.clockwise" : "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            #if canImport(UIKit)
            .background(Color(UIColor.secondarySystemBackground))
            #else
            .background(Color.secondary.opacity(0.15))
            #endif
            .cornerRadius(10)

            if isAddressBarFocused {
                Button("Go") {
                    viewModel.navigate(to: viewModel.urlInputText)
                    isAddressBarFocused = false
                }
                .font(.body.weight(.semibold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                // Back Button
                Button {
                    viewModel.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 18, weight: .semibold))
                }
                .disabled(!viewModel.canGoBack)
                .frame(maxWidth: .infinity)

                // Forward Button
                Button {
                    viewModel.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 18, weight: .semibold))
                }
                .disabled(!viewModel.canGoForward)
                .frame(maxWidth: .infinity)

                // Home Button
                Button {
                    viewModel.goHome()
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 18))
                }
                .frame(maxWidth: .infinity)

                // Download Page URL Button
                Button {
                    viewModel.prepareDownloadCurrentURL()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18))
                        Text("Download")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(viewModel.currentURL != nil ? .white : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(viewModel.currentURL != nil ? Color.blue : Color.gray.opacity(0.2))
                    .cornerRadius(16)
                }
                .disabled(viewModel.currentURL == nil)
                .frame(maxWidth: .infinity)

                // Reload Button
                Button {
                    viewModel.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18))
                }
                .disabled(viewModel.currentURL == nil)
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 10)
            #if canImport(UIKit)
            .background(Color(UIColor.secondarySystemBackground))
            #endif
        }
    }
}

// MARK: - Home / New Tab View

public struct BrowserHomeView: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @State private var quickSearchText: String = ""

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero Branding Card
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 72, height: 72)
                        Image(systemName: "globe")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    .padding(.top, 16)

                    Text("LID In-App Browser")
                        .font(.title2.weight(.bold))

                    Text("Browse the web, inspect links, and send downloads directly to the high-performance multi-threaded download engine.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Quick Search Box
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search the web or type a URL...", text: $quickSearchText)
                            #if canImport(UIKit)
                            .keyboardType(.webSearch)
                            .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .onSubmit {
                                viewModel.navigate(to: quickSearchText)
                            }
                        if !quickSearchText.isEmpty {
                            Button {
                                viewModel.navigate(to: quickSearchText)
                            } label: {
                                Text("Search")
                                    .bold()
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .padding(12)
                    #if canImport(UIKit)
                    .background(Color(UIColor.secondarySystemBackground))
                    #else
                    .background(Color.secondary.opacity(0.15))
                    #endif
                    .cornerRadius(12)

                    // Search engine selection picker
                    HStack {
                        Text("Search with:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Search Engine", selection: $viewModel.selectedSearchEngine) {
                            ForEach(BrowserSearchEngine.allCases) { engine in
                                Text(engine.rawValue).tag(engine)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                }
                .padding(.horizontal, 16)

                // Quick Links Grid
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Access")
                        .font(.headline)
                        .padding(.horizontal, 16)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(BrowserQuickLink.defaults) { link in
                            Button {
                                if let url = URL(string: link.urlString) {
                                    viewModel.load(url: url)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: link.systemImage)
                                        .font(.system(size: 24))
                                        .foregroundColor(.blue)
                                        .frame(width: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(link.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(link.subtitle)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                                #if canImport(UIKit)
                                .background(Color(UIColor.secondarySystemBackground))
                                #else
                                .background(Color.secondary.opacity(0.15))
                                #endif
                                .cornerRadius(12)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Architectural Invariant Card
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Integrated Transfer Engine")
                            .font(.subheadline.weight(.bold))
                        Text("Downloads initiated from this browser automatically reuse the established priority queue, segmented range writer, and persistent checkpoint storage.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(14)
                #if canImport(UIKit)
                .background(Color(UIColor.secondarySystemBackground))
                #else
                .background(Color.secondary.opacity(0.15))
                #endif
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Browser Error View

public struct BrowserErrorView: View {
    public let error: String
    public let onRetry: () -> Void
    public let onHome: () -> Void

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Unable to Load Page")
                .font(.headline)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            HStack(spacing: 16) {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)

                Button("Return to Home", action: onHome)
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .padding()
    }
}

// MARK: - Browser Download Modal Sheet

public struct BrowserDownloadSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var isSubmitting = false
    @State private var submitErrorMessage: String? = nil

    public var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Source URL")) {
                    Text(viewModel.downloadCandidateURL?.absoluteString ?? "No URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }

                Section(header: Text("Destination Filename")) {
                    TextField("filename.ext", text: $viewModel.downloadCandidateFilename)
                        #if canImport(UIKit)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
                }

                Section(header: Text("Acceleration & Threads"), footer: Text("The download coordinator will allocate parallel segmented workers if the host server supports HTTP range requests.")) {
                    Stepper("Worker Threads: \(viewModel.downloadCandidateThreads)", value: $viewModel.downloadCandidateThreads, in: 1...32)

                    HStack {
                        Text("Speed Limit (KB/s)")
                        Spacer()
                        TextField("Unlimited", text: $viewModel.downloadCandidateSpeedLimitKBps)
                            #if canImport(UIKit)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                }

                if let err = submitErrorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

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
                    .disabled(isSubmitting || viewModel.downloadCandidateURL == nil)
                }
            }
            .navigationTitle("Download File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    private func submitDownload() {
        submitErrorMessage = nil
        isSubmitting = true

        Task { @MainActor in
            do {
                try await viewModel.executeDownload()
                isSubmitting = false
                presentationMode.wrappedValue.dismiss()
            } catch {
                submitErrorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

// MARK: - Platform WebView Wrapper (WebKit)

#if canImport(WebKit)

#if canImport(UIKit)
public struct PlatformWebView: UIViewRepresentable {
    @ObservedObject public var viewModel: BrowserViewModel

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public func makeCoordinator() -> BrowserWebViewCoordinator {
        BrowserWebViewCoordinator(viewModel: viewModel)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.setupProgressObserver(for: webView)
        viewModel.webView = webView
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        // Navigation is triggered explicitly via BrowserViewModel to avoid unnecessary re-creation.
    }
}
#elseif canImport(AppKit)
public struct PlatformWebView: NSViewRepresentable {
    @ObservedObject public var viewModel: BrowserViewModel

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public func makeCoordinator() -> BrowserWebViewCoordinator {
        BrowserWebViewCoordinator(viewModel: viewModel)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.setupProgressObserver(for: webView)
        viewModel.webView = webView
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

// MARK: - WKNavigationDelegate Coordinator

public final class BrowserWebViewCoordinator: NSObject, WKNavigationDelegate {
    public weak var viewModel: BrowserViewModel?
    private var progressObserver: NSKeyValueObservation?

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    deinit {
        progressObserver?.invalidate()
    }

    public func setupProgressObserver(for webView: WKWebView) {
        progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            DispatchQueue.main.async {
                self?.viewModel?.estimatedProgress = wv.estimatedProgress
            }
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            vm.isLoading = true
            vm.errorMessage = nil
            if let url = webView.url, url.absoluteString != "about:blank" {
                vm.currentURL = url
                vm.urlInputText = url.absoluteString
            }
            vm.canGoBack = webView.canGoBack
            vm.canGoForward = webView.canGoForward
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            vm.isLoading = false
            if let url = webView.url, url.absoluteString != "about:blank" {
                vm.currentURL = url
                vm.urlInputText = url.absoluteString
            }
            vm.pageTitle = webView.title ?? ""
            vm.canGoBack = webView.canGoBack
            vm.canGoForward = webView.canGoForward
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    private func handleErrorInternal(_ error: Error) {
        let nsError = error as NSError
        // Ignore NSURLErrorCancelled (-999), emitted on redirection or intentional user stops
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let vm = self.viewModel else { return }
            vm.isLoading = false
            vm.errorMessage = error.localizedDescription
        }
    }

    private func handleNavigationError(_ error: Error) {
        handleErrorInternal(error)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Allow HTTP, HTTPS, and blank page
        if BrowserURLResolver.isValidWebNavigationURL(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}

#endif // canImport(WebKit)

#endif // canImport(SwiftUI)
