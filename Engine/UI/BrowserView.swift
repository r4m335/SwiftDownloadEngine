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


// MARK: - Browser View (SwiftUI)

/// Native in-app web browser interface integrating address bar, navigation controls, and direct engine download handoff.
public struct BrowserView: View {
    @StateObject public var viewModel: BrowserViewModel
    @FocusState private var isAddressBarFocused: Bool
    @State private var isShowingDiagnosticLogs: Bool = false

    public init(viewModel: BrowserViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public init(
        downloadDelegate: BrowserDownloadDelegate? = nil,
        magnetDelegate: (any BrowserMagnetDelegate)? = nil,
        onDownloadInitiated: (() -> Void)? = nil,
        onOpenAddDownload: ((URL) -> Void)? = nil,
        onOpenDownloads: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: BrowserViewModel(
            downloadDelegate: downloadDelegate,
            magnetDelegate: magnetDelegate,
            onDownloadInitiated: onDownloadInitiated,
            onOpenAddDownload: onOpenAddDownload,
            onOpenDownloads: onOpenDownloads,
            sessionStore: BrowserSessionStore.shared
        ))
    }

    public init(
        viewModel: DownloadManagerViewModel,
        onDownloadInitiated: (() -> Void)? = nil,
        onOpenAddDownload: ((URL) -> Void)? = nil,
        onOpenDownloads: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: BrowserViewModel(
            downloadDelegate: viewModel,
            magnetDelegate: viewModel,
            onDownloadInitiated: onDownloadInitiated,
            onOpenAddDownload: onOpenAddDownload,
            onOpenDownloads: onOpenDownloads,
            streamingOrchestrator: viewModel.streamingOrchestrator,
            streamingDestinationDirectoryURL: viewModel.downloadsDirectoryURL,
            sessionStore: BrowserSessionStore.shared
        ))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Keep one navigation menu at the top, like a compact browser toolbar.
            if !viewModel.isToolbarCollapsed || isAddressBarFocused || viewModel.currentURL == nil {
                topNavigationToolbar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if viewModel.isLoading {
                ProgressView(value: max(0.05, viewModel.estimatedProgress), total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .frame(height: 2)
            } else {
                Divider()
            }

            // Find in Page Search Bar (Milestone B.3)
            if viewModel.isShowingFindInPage {
                BrowserFindInPageView(
                    query: Binding(
                        get: { viewModel.findInPageQuery },
                        set: { viewModel.updateFindInPageQuery($0) }
                    ),
                    result: viewModel.findInPageResult,
                    onPrevious: { viewModel.findInPagePrevious() },
                    onNext: { viewModel.findInPageNext() },
                    onDone: { viewModel.closeFindInPage() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Reader Mode Feedback Banner (Milestone B.3)
            if let banner = viewModel.readerFeedbackBanner {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(banner)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.readerFeedbackBanner = nil
                    }
                    .font(.caption.bold())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.18))
                .foregroundColor(.primary)
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
                    if let activeTabID = viewModel.activeTabID {
                        PlatformWebView(viewModel: viewModel, tabID: activeTabID)
                            .id(activeTabID)
                    } else {
                        BrowserHomeView(viewModel: viewModel)
                    }
                    #else
                    Text("WebKit is not supported in this environment.")
                        .foregroundColor(.secondary)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "browserContent")
            .overlay {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: 32)
                            .highPriorityGesture(
                                DragGesture(
                                    minimumDistance: 12,
                                    coordinateSpace: .named("browserContent")
                                )
                                .onEnded { value in
                                    viewModel.handleEdgeGesture(
                                        startX: value.startLocation.x,
                                        translationX: value.translation.width,
                                        containerWidth: geometry.size.width,
                                        modalPresented: isModalPresented
                                    )
                                }
                            )

                        Spacer(minLength: 0)

                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: 32)
                            .highPriorityGesture(
                                DragGesture(
                                    minimumDistance: 12,
                                    coordinateSpace: .named("browserContent")
                                )
                                .onEnded { value in
                                    viewModel.handleEdgeGesture(
                                        startX: value.startLocation.x,
                                        translationX: value.translation.width,
                                        containerWidth: geometry.size.width,
                                        modalPresented: isModalPresented
                                    )
                                }
                            )
                    }
                }
            }

        }
        .sheet(isPresented: $viewModel.isShowingDownloadSheet) {
            BrowserDownloadSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingResourceInspector) {
            BrowserResourceInspectorSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingQualityPicker) {
            StreamQualityPickerSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingShieldSheet) {
            BrowserShieldSheet(viewModel: viewModel)
        }
        .sheet(item: $viewModel.redirectPrompt) { prompt in
            BrowserRedirectSheet(viewModel: viewModel, prompt: prompt)
        }
        .sheet(isPresented: $viewModel.isShowingMagnetSheet) {
            BrowserMagnetConfirmationSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingTabSwitcher) {
            BrowserTabSwitcherView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingBookmarksAndHistory) {
            BrowserBookmarksAndHistoryView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingClearDataSheet) {
            BrowserClearDataSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingReaderMode) {
            if let article = viewModel.readerArticle {
                BrowserReaderView(
                    article: article,
                    settings: $viewModel.readerSettings,
                    onDismiss: {
                        viewModel.closeReaderMode()
                    },
                    onShare: {
                        viewModel.shareCurrentPage()
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingShareSheet) {
            BrowserShareSheet(items: viewModel.shareItems)
        }
        .sheet(isPresented: $viewModel.isShowingSearchEngineManager) {
            SearchEngineManagementView {
                viewModel.reloadSettings()
            }
        }
        .sheet(isPresented: $isShowingDiagnosticLogs) {
            DiagnosticLogView(configuration: viewModel.activeEngineConfiguration)
        }
        .alert(item: $viewModel.certificateWarningPrompt) { prompt in
            Alert(
                title: Text("Security Warning"),
                message: Text(prompt.message),
                primaryButton: .destructive(Text("Proceed Anyway")) {
                    prompt.onProceed()
                },
                secondaryButton: .cancel(Text("Go Back (Safe)")) {
                    prompt.onCancel()
                }
            )
        }
        .alert(item: $viewModel.suspiciousDownloadPrompt) { prompt in
            Alert(
                title: Text("Dangerous Download Warning"),
                message: Text(prompt.warning.warningMessage),
                primaryButton: .destructive(Text("Download Anyway")) {
                    prompt.onProceed()
                },
                secondaryButton: .cancel(Text("Cancel")) {
                    prompt.onCancel()
                }
            )
        }
        .alert(item: $viewModel.permissionPrompt) { prompt in
            Alert(
                title: Text("Permission Request"),
                message: Text("'\(prompt.host)' wants access to your \(prompt.type.rawValue.capitalized)."),
                primaryButton: .default(Text("Allow")) {
                    prompt.onDecision(.grant)
                },
                secondaryButton: .cancel(Text("Deny")) {
                    prompt.onDecision(.deny)
                }
            )
        }
        .alert(item: $viewModel.externalAppLinkPrompt) { link in
            Alert(
                title: Text("Open in \(link.serviceName)?"),
                message: Text("Would you like to open this in the \(link.serviceName) app or continue browsing here?"),
                primaryButton: .default(Text("Continue in Browser")) {
                    viewModel.continueInBrowser(link)
                },
                secondaryButton: .default(Text("Open in App")) {
                    viewModel.openInAssociatedApp(link)
                }
            )
        }
        .overlay(alignment: .bottom) {
            Group {
                if viewModel.isToolbarCollapsed && !isAddressBarFocused && viewModel.currentURL != nil {
                    collapsedAddressPill
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else {
                    addressBarHeader
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, isAddressBarFocused ? 6 : 70)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.isToolbarCollapsed)
        .onReceive(NotificationCenter.default.publisher(for: .sdeBrowserTabRetapped)) { _ in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                if viewModel.isToolbarCollapsed {
                    viewModel.setToolbarCollapsed(false)
                } else {
                    isAddressBarFocused = true
                }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if viewModel.isCapturingMSE {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Capturing MediaSource stream...")
                                .font(.caption.bold())
                                .foregroundColor(.primary)
                            if let snapshot = viewModel.mseCaptureSnapshot {
                                Text("\(ByteCountFormatter.string(fromByteCount: snapshot.bytesCaptured, countStyle: .file)) captured (\(snapshot.segmentCount) segments)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            viewModel.stopMSECapture()
                        } label: {
                            Text("Save")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.blue)
                                .cornerRadius(6)
                        }
                        Button {
                            viewModel.cancelMSECapture()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    #if canImport(UIKit)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                    #else
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.2)))
                    #endif
                    .shadow(radius: 4)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if viewModel.isCapturingBlob {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Exporting in-memory Blob...")
                                .font(.caption.bold())
                                .foregroundColor(.primary)
                            if let snapshot = viewModel.blobCaptureSnapshot {
                                Text("\(ByteCountFormatter.string(fromByteCount: snapshot.bytesWritten, countStyle: .file)) written")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            viewModel.cancelBlobCapture()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    #if canImport(UIKit)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                    #else
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.2)))
                    #endif
                    .shadow(radius: 4)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let notification = viewModel.downloadSuccessNotification {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(notification)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    #if canImport(UIKit)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                    #else
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.2)))
                    #endif
                    .shadow(radius: 4)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                            withAnimation { viewModel.downloadSuccessNotification = nil }
                        }
                    }
                }
                if let error = viewModel.blobCaptureErrorMessage ?? viewModel.mseCaptureErrorMessage ?? viewModel.streamingErrorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                        Button {
                            isShowingDiagnosticLogs = true
                        } label: {
                            Text("Logs")
                                .font(.caption.bold())
                                .foregroundColor(.blue)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(6)
                        }
                        Button {
                            withAnimation {
                                viewModel.blobCaptureErrorMessage = nil
                                viewModel.mseCaptureErrorMessage = nil
                                viewModel.streamingErrorMessage = nil
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    #if canImport(UIKit)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
                    #else
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.2)))
                    #endif
                    .shadow(radius: 4)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 8)
            .animation(.easeInOut, value: viewModel.downloadSuccessNotification)
            .animation(.easeInOut, value: viewModel.blobCaptureErrorMessage)
            .animation(.easeInOut, value: viewModel.mseCaptureErrorMessage)
            .animation(.easeInOut, value: viewModel.streamingErrorMessage)
            .animation(.easeInOut, value: viewModel.isCapturingMSE)
            .animation(.easeInOut, value: viewModel.isCapturingBlob)
        }
        #if canImport(UIKit)
        .background(Color(UIColor.systemBackground))
        #endif
        .onAppear {
            viewModel.reloadSettings()
        }
    }

    var isModalPresented: Bool {
        viewModel.isShowingDownloadSheet ||
        viewModel.isShowingResourceInspector ||
        viewModel.isShowingQualityPicker ||
        viewModel.isShowingShieldSheet ||
        viewModel.isShowingReaderMode ||
        viewModel.isShowingShareSheet ||
        viewModel.redirectPrompt != nil ||
        viewModel.isShowingMagnetSheet ||
        viewModel.isShowingTabSwitcher
    }

    var shieldIconName: String {
        if !viewModel.isAdBlockerEnabled {
            return "shield.slash"
        }
        if viewModel.isCurrentSiteWhitelisted {
            return "shield.slash.fill"
        }
        return "shield.checkered"
    }

    var shieldIconColor: Color {
        if !viewModel.isAdBlockerEnabled {
            return .secondary
        }
        if viewModel.isCurrentSiteWhitelisted {
            return .orange
        }
        return .blue
    }

    // MARK: - Address Bar Header

    var collapsedWebsiteName: String {
        guard let host = viewModel.currentURL?.host, !host.isEmpty else {
            return viewModel.currentURL?.lastPathComponent ?? "Website"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var collapsedAddressPill: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                viewModel.setToolbarCollapsed(false)
            }
        } label: {
            HStack(spacing: 6) {
                if let url = viewModel.currentURL {
                    Image(systemName: url.scheme?.lowercased() == "https" ? "lock.fill" : "lock.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(url.scheme?.lowercased() == "https" ? .green : .orange)
                }
                Text(collapsedWebsiteName)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
        .accessibilityLabel("Website: \(collapsedWebsiteName). Tap to expand browser bar.")
    }

    var addressBarHeader: some View {
        VStack(spacing: 4) {
            // Show Quick Search Engine Switcher only when editing or on start page
            if isAddressBarFocused || viewModel.currentURL == nil {
                searchEngineQuickSwitcher
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                // Address Bar Capsule
                HStack(spacing: 6) {
                // Shield Protection Button
                Button {
                    viewModel.isShowingShieldSheet = true
                } label: {
                    Image(systemName: shieldIconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(shieldIconColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Content Shields")

                // Incognito Private Indicator (Phase 3 Milestone 3.4)
                if viewModel.isCurrentTabIncognito {
                    HStack(spacing: 3) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 11, weight: .bold))
                        Text("Private")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .clipShape(Capsule())
                }

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

                if isAddressBarFocused && !viewModel.urlInputText.isEmpty {
                    Button {
                        viewModel.urlInputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Clear search bar")
                } else if viewModel.isLoading {
                    Button {
                        viewModel.stopLoading()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Stop loading")
                } else if !viewModel.urlInputText.isEmpty {
                    Button {
                        viewModel.urlInputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Clear search bar")
                }

                if viewModel.currentURL != nil {
                    Button {
                        viewModel.openResourceInspector()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(width: 26, height: 26)

                            if viewModel.detectedMediaCount > 0 {
                                Text("\(viewModel.detectedMediaCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, viewModel.detectedMediaCount > 9 ? 3 : 0)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(Circle().fill(Color.red))
                                    .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .accessibilityLabel(viewModel.detectedMediaCount > 0
                        ? "Find Resources (\(viewModel.detectedMediaCount))"
                        : "Find Resources")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)

            if isAddressBarFocused {
                Button("Go") {
                    viewModel.navigate(to: viewModel.urlInputText)
                    isAddressBarFocused = false
                }
                .font(.body.weight(.semibold))
            }
        }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    var searchEngineQuickSwitcher: some View {
        HStack {
            Menu {
                Section("Search Engines") {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Button {
                            viewModel.setSearchEngine(id: engine.rawValue)
                        } label: {
                            if viewModel.activeSearchEngineID == engine.rawValue {
                                Label(engine.displayName, systemImage: "checkmark")
                            } else {
                                Text(engine.displayName)
                            }
                        }
                    }
                    ForEach(viewModel.customSearchEngines) { custom in
                        Button {
                            viewModel.setSearchEngine(id: custom.id)
                        } label: {
                            if viewModel.activeSearchEngineID == custom.id {
                                Label(custom.name, systemImage: "checkmark")
                            } else {
                                Text(custom.name)
                            }
                        }
                    }
                }

                Divider()

                Button {
                    viewModel.isShowingSearchEngineManager = true
                } label: {
                    Label("Manage Search Engines...", systemImage: "gearshape")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                    Text(viewModel.currentSearchEngineName)
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                #if canImport(UIKit)
                .background(Color(UIColor.tertiarySystemFill))
                #else
                .background(Color.secondary.opacity(0.12))
                #endif
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Active search engine: \(viewModel.currentSearchEngineName). Tap to switch.")

            Spacer()
        }
    }

    // MARK: - Top Navigation Toolbar

    var topNavigationToolbar: some View {
        VStack(spacing: 0) {
            HStack {
                // Back Button
                Button {
                    viewModel.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 18, weight: .semibold))
                }
                .accessibilityLabel("Back")
                .disabled(!viewModel.canGoBack)
                .frame(maxWidth: .infinity, minHeight: 44)

                // Forward Button
                Button {
                    viewModel.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 18, weight: .semibold))
                }
                .accessibilityLabel("Forward")
                .disabled(!viewModel.canGoForward)
                .frame(maxWidth: .infinity, minHeight: 44)

                // Home Button
                Button {
                    viewModel.goHome()
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 18))
                }
                .accessibilityLabel("Home")
                .frame(maxWidth: .infinity, minHeight: 44)

                // Tab overview button with live count badge
                Button {
                    viewModel.showTabSwitcher()
                } label: {
                    if viewModel.tabs.isEmpty {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 18))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .stroke(lineWidth: 1.6)
                                .frame(width: 19, height: 19)
                            Text("\(viewModel.tabs.count)")
                                .font(.system(size: viewModel.tabs.count >= 100 ? 8 : 11, weight: .bold))
                                .minimumScaleFactor(0.6)
                        }
                    }
                }
                .accessibilityLabel("Tabs (\(viewModel.tabs.count) open)")
                .disabled(viewModel.tabs.isEmpty)
                .frame(maxWidth: .infinity, minHeight: 44)

                // Dynamic Reload / Stop Button
                Button {
                    if viewModel.isLoading {
                        viewModel.stopLoading()
                    } else {
                        viewModel.reload()
                    }
                } label: {
                    Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 18))
                }
                .accessibilityLabel(viewModel.isLoading ? "Stop" : "Reload")
                .disabled(viewModel.currentURL == nil && !viewModel.isLoading)
                .frame(maxWidth: .infinity, minHeight: 44)

                // Vertical Three-Dot (⋮) Overflow Menu
                overflowMenu
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            #if canImport(UIKit)
            .background(Color(UIColor.secondarySystemBackground))
            #else
            .background(Color.secondary.opacity(0.15))
            #endif
            Divider()
        }
    }

    // MARK: - Overflow Menu (⋮)

    @ViewBuilder
    var overflowMenu: some View {
        BrowserOverflowMenu(
            isDesktopMode: viewModel.isCurrentTabDesktopMode,
            isWhitelisted: viewModel.isCurrentSiteWhitelisted,
            hasURL: viewModel.currentURL != nil,
            activeDownloadCount: viewModel.activeDownloadCount,
            onToggleDesktopMode: { viewModel.toggleDesktopMode() },
            onShowBookmarksAndHistory: { viewModel.showBookmarksAndHistory() },
            onShowShieldSheet: { viewModel.isShowingShieldSheet = true },
            onToggleReaderMode: { viewModel.toggleReaderMode() },
            onOpenFindInPage: { viewModel.openFindInPage() },
            onShareCurrentPage: { viewModel.shareCurrentPage() }
        )
        .equatable()
    }
}

struct BrowserOverflowMenu: View, Equatable {
    let isDesktopMode: Bool
    let isWhitelisted: Bool
    let hasURL: Bool
    let activeDownloadCount: Int
    let onToggleDesktopMode: () -> Void
    let onShowBookmarksAndHistory: () -> Void
    let onShowShieldSheet: () -> Void
    let onToggleReaderMode: () -> Void
    let onOpenFindInPage: () -> Void
    let onShareCurrentPage: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isDesktopMode == rhs.isDesktopMode &&
        lhs.isWhitelisted == rhs.isWhitelisted &&
        lhs.hasURL == rhs.hasURL &&
        lhs.activeDownloadCount == rhs.activeDownloadCount
    }

    var body: some View {
        Menu {
            // Desktop / Mobile Mode Toggle
            Button(action: onToggleDesktopMode) {
                Label(
                    isDesktopMode ? "Request Mobile Site" : "Request Desktop Site",
                    systemImage: isDesktopMode ? "iphone" : "desktopcomputer"
                )
            }
            .disabled(!hasURL)

            // Bookmarks & History
            Button(action: onShowBookmarksAndHistory) {
                Label("Bookmarks & History", systemImage: "book")
            }

            // Content Shields (Milestone B.2)
            Button(action: onShowShieldSheet) {
                Label(
                    "Content Shields",
                    systemImage: isWhitelisted ? "shield.slash" : "shield.checkered"
                )
            }

            // Safari-Style Reader Mode (Milestone B.3)
            Button(action: onToggleReaderMode) {
                Label("Reader Mode", systemImage: "doc.plaintext")
            }
            .disabled(!hasURL)

            // Find in Page (Milestone B.3)
            Button(action: onOpenFindInPage) {
                Label("Find in Page", systemImage: "magnifyingglass")
            }
            .disabled(!hasURL)

            // Webpage Sharing (Milestone B.3)
            Button(action: onShareCurrentPage) {
                Label("Share Webpage...", systemImage: "square.and.arrow.up")
            }
            .disabled(!hasURL)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.system(size: 18, weight: .semibold))

                // Priority Badge Indicator: Blue for active downloads
                if activeDownloadCount > 0 {
                    Text("\(activeDownloadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue)
                        .clipShape(Capsule())
                        .offset(x: 8, y: -6)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("More Options")
    }
}
#endif
