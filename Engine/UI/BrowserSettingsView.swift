#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Dedicated sub-settings screen for web search, homepage navigation, content shields,
/// cookie policy, Safari-style Reader mode, and media sniffer candidate filters.
public struct BrowserSettingsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel

    // Media Sniffer Filter Settings
    @State private var enableSnifferFilter: Bool = true
    @State private var snifferExtensions: String = ""
    @State private var snifferMIMETypes: String = ""

    // Content Shields & Ad Blocking
    @State private var isAdBlockerEnabled: Bool = true
    @State private var isTrackerBlockerEnabled: Bool = true
    @State private var isAnnoyanceBlockerEnabled: Bool = true
    @State private var cookiePolicy: BrowserCookiePolicy = .blockThirdParty
    @State private var isPopupBlockerEnabled: Bool = true
    @State private var selectedSearchEngine: BrowserSearchEngine = .duckDuckGo
    @State private var isShowingClearDataSheet: Bool = false

    // Browser Navigation & Reader Experience
    @State private var browserHomepage: String = "https://duckduckgo.com"
    @State private var restoreTabsOnLaunch: Bool = true
    @State private var readerTheme: BrowserReaderTheme = .light
    @State private var readerFontFamily: BrowserReaderFontFamily = .serif
    @State private var readerFontSize: Double = 18.0

    // UI Feedback
    @State private var showingSavedAlert: Bool = false

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            // Section 1: Browser Navigation Experience
            Section(
                header: Text("Browser & Navigation Experience"),
                footer: Text("Configure search, homepage, tab restoration, and Safari-style Reader Mode appearance.")
            ) {
                Picker("Default Search Engine", selection: $selectedSearchEngine) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                HStack {
                    Text("Homepage")
                    Spacer()
                    TextField("https://...", text: $browserHomepage)
                        .multilineTextAlignment(.trailing)
                        #if canImport(UIKit)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
                }

                Toggle("Restore Tabs on App Startup", isOn: $restoreTabsOnLaunch)
            }

            // Section 2: Content Shields & Privacy
            Section(
                header: Text("Content Shields & Privacy"),
                footer: Text("Apple WKContentRuleListStore provides hardware-accelerated ad, tracker, and annoyance blocking with zero JavaScript overhead.")
            ) {
                Toggle("Block Invasive Ads (EasyList)", isOn: $isAdBlockerEnabled)
                Toggle("Block Trackers & Telemetry (EasyPrivacy)", isOn: $isTrackerBlockerEnabled)
                Toggle("Block Annoyances & Cookie Notices", isOn: $isAnnoyanceBlockerEnabled)
                Toggle("Block Popups & Hijack Redirects", isOn: $isPopupBlockerEnabled)

                Picker("Cookie Policy", selection: $cookiePolicy) {
                    ForEach(BrowserCookiePolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }

                if !viewModel.appSettings.adBlockerWhitelistedDomains.isEmpty {
                    HStack {
                        Text("Whitelisted Domains")
                        Spacer()
                        Text("\(viewModel.appSettings.adBlockerWhitelistedDomains.count) active")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Button {
                    isShowingClearDataSheet = true
                } label: {
                    Label("Clear Browsing Data...", systemImage: "trash")
                        .foregroundColor(.red)
                }
            }

            // Section 3: Media Sniffer Filters
            Section(
                header: Text("Media Sniffer Filters"),
                footer: Text("Filter browser Resource Grabber media candidates by comma-separated file extensions and MIME type prefixes.")
            ) {
                Toggle("Enable Media Sniffer Filter", isOn: $enableSnifferFilter)

                if enableSnifferFilter {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Allowed Extensions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("mp4, mkv, mp3, m3u8, zip...", text: $snifferExtensions)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Allowed MIME Types")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("video/, audio/, application/...", text: $snifferMIMETypes)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }
            }

            // Section 4: Reader Mode Appearance
            Section(
                header: Text("Reader Mode Appearance"),
                footer: Text("Customizes typography and color themes for distractive-free reader articles.")
            ) {
                Picker("Reader Theme", selection: $readerTheme) {
                    ForEach(BrowserReaderTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }

                Picker("Reader Font", selection: $readerFontFamily) {
                    ForEach(BrowserReaderFontFamily.allCases) { font in
                        Text(font.displayName).tag(font)
                    }
                }

                Stepper("Reader Font Size: \(Int(readerFontSize)) pt", value: $readerFontSize, in: 12...32, step: 1)
            }

            // Section 5: Apply Settings Action
            Section {
                Button {
                    saveSettings()
                } label: {
                    HStack {
                        Spacer()
                        Text("Apply Browser Settings")
                            .bold()
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Browser Settings")
        .sheet(isPresented: $isShowingClearDataSheet) {
            BrowserClearDataSheet(viewModel: BrowserViewModel(downloadDelegate: viewModel))
        }
        .onAppear {
            loadCurrentSettings()
        }
        .alert("Browser Settings Applied", isPresented: $showingSavedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Search engine, content shields, reader mode styling, and media filters have been updated.")
        }
    }

    private func loadCurrentSettings() {
        let settings = viewModel.appSettings
        let sniffer = BrowserSnifferFilter.load()
        self.enableSnifferFilter = sniffer.isFilterEnabled
        self.snifferExtensions = sniffer.allowedExtensions.joined(separator: ", ")
        self.snifferMIMETypes = sniffer.allowedMIMETypes.joined(separator: ", ")

        self.isAdBlockerEnabled = settings.isAdBlockerEnabled
        self.isTrackerBlockerEnabled = settings.isTrackerBlockerEnabled
        self.isAnnoyanceBlockerEnabled = settings.isAnnoyanceBlockerEnabled
        self.cookiePolicy = settings.cookiePolicy
        self.isPopupBlockerEnabled = settings.isPopupBlockerEnabled
        self.selectedSearchEngine = settings.browserSearchEngine
        self.browserHomepage = settings.browserHomepage
        self.restoreTabsOnLaunch = settings.restoreTabsOnLaunch
        self.readerTheme = settings.readerTheme
        self.readerFontFamily = settings.readerFontFamily
        self.readerFontSize = settings.readerFontSize
    }

    private func saveSettings() {
        var updated = viewModel.appSettings
        updated.isAdBlockerEnabled = isAdBlockerEnabled
        updated.isTrackerBlockerEnabled = isTrackerBlockerEnabled
        updated.isAnnoyanceBlockerEnabled = isAnnoyanceBlockerEnabled
        updated.cookiePolicy = cookiePolicy
        updated.isPopupBlockerEnabled = isPopupBlockerEnabled
        updated.browserSearchEngine = selectedSearchEngine
        let cleanHomepage = browserHomepage.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.browserHomepage = cleanHomepage.isEmpty ? "https://duckduckgo.com" : cleanHomepage
        updated.restoreTabsOnLaunch = restoreTabsOnLaunch
        updated.readerTheme = readerTheme
        updated.readerFontFamily = readerFontFamily
        updated.readerFontSize = readerFontSize

        Task { @MainActor in
            let exts = snifferExtensions
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let mimes = snifferMIMETypes
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let filter = BrowserSnifferFilter(
                allowedExtensions: exts.isEmpty ? BrowserSnifferFilter.defaultExtensions : exts,
                allowedMIMETypes: mimes.isEmpty ? BrowserSnifferFilter.defaultMIMETypes : mimes,
                isFilterEnabled: enableSnifferFilter
            )
            filter.save()

            try? await viewModel.applySettings(updated)
            showingSavedAlert = true
        }
    }
}
#endif
