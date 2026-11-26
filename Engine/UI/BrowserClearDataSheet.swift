#if canImport(SwiftUI)
import SwiftUI

#if canImport(WebKit)
import WebKit
#endif

/// Time range selector for clearing browsing data.
public enum BrowserClearDataTimeRange: String, CaseIterable, Identifiable {
    case lastHour = "Last Hour"
    case today = "Today"
    case allTime = "All Time"

    public var id: String { rawValue }

    public var cutoffDate: Date? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .lastHour:
            return calendar.date(byAdding: .hour, value: -1, to: now)
        case .today:
            return calendar.startOfDay(for: now)
        case .allTime:
            return nil
        }
    }
}

/// Sheet enabling selective clearing of history, cookies, cached data, site permissions, and tab previews.
public struct BrowserClearDataSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode

    @State private var timeRange: BrowserClearDataTimeRange = .allTime
    @State private var clearHistory: Bool = true
    @State private var clearCookiesAndCache: Bool = true
    @State private var clearSitePermissions: Bool = false
    @State private var clearTabPreviews: Bool = false

    @State private var isShowingConfirmationAlert: Bool = false
    @State private var isClearing: Bool = false

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: Time Range
                Section(header: Text("Time Range")) {
                    Picker("Time Range", selection: $timeRange) {
                        ForEach(BrowserClearDataTimeRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Section 2: Data Types
                Section(header: Text("Data Types to Clear")) {
                    Toggle("Browsing History", isOn: $clearHistory)
                    Toggle("Cookies & Cached Website Files", isOn: $clearCookiesAndCache)
                    Toggle("Saved Site Permissions", isOn: $clearSitePermissions)
                    Toggle("Visual Tab Previews", isOn: $clearTabPreviews)
                }

                // Section 3: Action
                Section {
                    Button(role: .destructive) {
                        isShowingConfirmationAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            if isClearing {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("Clear Browsing Data Now")
                                .font(.headline)
                                .foregroundColor(isSelectionEmpty ? .secondary : .red)
                            Spacer()
                        }
                    }
                    .disabled(isSelectionEmpty || isClearing)
                }
            }
            .navigationTitle("Clear Browsing Data")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .alert("Confirm Clear Data", isPresented: $isShowingConfirmationAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear Data", role: .destructive) {
                    performClear()
                }
            } message: {
                Text("This will permanently remove the selected browsing data for the '\(timeRange.rawValue)' time range. This action cannot be undone.")
            }
        }
        .modernStackNavigation()
        .modernSheetDetents()
    }

    private var isSelectionEmpty: Bool {
        !clearHistory && !clearCookiesAndCache && !clearSitePermissions && !clearTabPreviews
    }

    private func performClear() {
        isClearing = true
        let cutoff = timeRange.cutoffDate

        if clearHistory {
            viewModel.historyStore.clearHistory(since: cutoff)
        }

        if clearSitePermissions {
            viewModel.sitePermissionsStore.clearAll()
        }

        if clearTabPreviews {
            viewModel.tabPreviewCache.clearAll()
        }

        #if canImport(WebKit)
        if clearCookiesAndCache {
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            let date = cutoff ?? Date.distantPast
            WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: date) {
                Task { @MainActor in
                    self.isClearing = false
                    self.presentationMode.wrappedValue.dismiss()
                }
            }
            return
        }
        #endif

        isClearing = false
        presentationMode.wrappedValue.dismiss()
    }
}
#endif
