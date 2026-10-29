#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Screen 4: Settings Screen exposing the engine's concurrency, request budget, bandwidth limits, and BitTorrent controls.
public struct SettingsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel

    // Engine Execution Settings (Codable AppSettings Layer)
    @State private var timeoutSeconds: Int = 30
    @State private var customUserAgent: String = ""
    @State private var maxRetryAttempts: Int = 3
    @State private var duplicateNamingRule: DuplicateNamingRule = .autoRename
    @State private var allowCellular: Bool = true

    // Keychain Sensitive Authentication & Proxy (Hardware-backed iOS Keychain, never in AppSettings)
    @State private var authServer: String = ""
    @State private var authUsername: String = ""
    @State private var authPassword: String = ""
    @State private var keychainFeedbackMessage: String? = nil

    // HTTP Settings
    @State private var maxConcurrent: Int = 3
    @State private var maxGlobalRequests: Int = 12
    @State private var enableGlobalSpeedLimit: Bool = false
    @State private var globalSpeedLimitKBps: String = "2048"

    // Torrent Settings
    @State private var maxConcurrentTorrents: Int = 3
    @State private var defaultTorrentPriority: TorrentPriority = .normal

    // Seeding Settings
    @State private var seedingMode: SeedingMode = .ratio
    @State private var targetRatio: Double = 1.0
    @State private var targetDurationMinutes: Int = 60

    // Media Sniffer Filter Settings
    @State private var enableSnifferFilter: Bool = true
    @State private var snifferExtensions: String = ""
    @State private var snifferMIMETypes: String = ""

    // Download Scheduler Settings (iOS URLSession & Local Notifications)
    @State private var scheduleEnabled: Bool = false
    @State private var scheduleStartTime: Date = Calendar.current.date(from: DateComponents(hour: 2, minute: 0)) ?? Date()
    @State private var scheduleEnableStopTime: Bool = true
    @State private var scheduleStopTime: Date = Calendar.current.date(from: DateComponents(hour: 6, minute: 0)) ?? Date()
    @State private var scheduleWeekdays: Set<Int> = Set(1...7)
    @State private var scheduleWifiOnly: Bool = true

    // UI Feedback
    @State private var showingSavedAlert: Bool = false
    @State private var statusMessage: String? = nil
    @State private var showingDiagnostics: Bool = false

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: HTTP Queue & Concurrency
                Section(
                    header: Text("HTTP Queue Concurrency"),
                    footer: Text("Controls how many HTTP downloads are transferred concurrently. Excess items wait in priority order.")
                ) {
                    Stepper("Max Concurrent HTTP Downloads: \(maxConcurrent)", value: $maxConcurrent, in: 1...10)
                }

                // Section 2: Network Rules & Engine Execution
                Section(
                    header: Text("Network Rules & Execution"),
                    footer: Text("Platform rules and execution timeouts for all downloads. Cellular downloads can be restricted to Wi-Fi only.")
                ) {
                    Toggle("Allow Cellular Data", isOn: $allowCellular)

                    Stepper("Request Timeout: \(timeoutSeconds)s", value: $timeoutSeconds, in: 5...120, step: 5)

                    Stepper("Max Retry Attempts: \(maxRetryAttempts)", value: $maxRetryAttempts, in: 0...10)

                    Picker("Duplicate Filename Rule", selection: $duplicateNamingRule) {
                        ForEach(DuplicateNamingRule.allCases, id: \.self) { rule in
                            Text(rule.rawValue).tag(rule)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom User-Agent (Optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Default iOS User-Agent", text: $customUserAgent)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }

                // Section 3: BitTorrent Concurrency & Network Ports (Platform Gated)
                if viewModel.isTorrentEngineAvailable {
                    Section(
                        header: Text("BitTorrent Queueing & Ports"),
                        footer: Text("Limits concurrent active torrent downloads, displays the verified native listening socket, and binds the 6881–6891 port range.")
                    ) {
                        Stepper("Max Concurrent Torrents: \(maxConcurrentTorrents)", value: $maxConcurrentTorrents, in: 1...10)

                        Picker("Default Priority", selection: $defaultTorrentPriority) {
                            Text("Low").tag(TorrentPriority.low)
                            Text("Normal").tag(TorrentPriority.normal)
                            Text("High").tag(TorrentPriority.high)
                        }

                        HStack {
                            Text("Active Listen Port")
                            Spacer()
                            Text(viewModel.torrentActivePortString)
                                .font(.caption.monospaced())
                                .foregroundColor(viewModel.torrentSessionStatus?.isListening == true ? .green : .secondary)
                        }

                        HStack {
                            Text("Configured Range")
                            Spacer()
                            Text(viewModel.torrentPortRangeString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Section 4: BitTorrent Seeding Policy
                    Section(
                        header: Text("BitTorrent Seeding Behavior"),
                        footer: Text("Defines automatic seeding cessation once a transfer completes. Settings are enforced by the scheduler and stored persistently.")
                    ) {
                        Picker("Seeding Mode", selection: $seedingMode) {
                            Text("Stop when complete").tag(SeedingMode.doNotSeed)
                            Text("Seed until ratio").tag(SeedingMode.ratio)
                            Text("Seed for duration").tag(SeedingMode.duration)
                            Text("Seed indefinitely").tag(SeedingMode.indefinitely)
                        }

                        if seedingMode == .ratio {
                            HStack {
                                Text("Target Ratio")
                                Spacer()
                                Text(String(format: "%.1fx", targetRatio))
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $targetRatio, in: 0.5...5.0, step: 0.1)
                        } else if seedingMode == .duration {
                            Stepper("Duration: \(targetDurationMinutes) min", value: $targetDurationMinutes, in: 5...1440, step: 15)
                        }
                    }
                }

                // Section 5: HTTP Connection & Request Budgeting
                Section(
                    header: Text("HTTP Request Budget"),
                    footer: Text("Limits total in-flight HTTP range requests across all segment workers to avoid socket exhaustion.")
                ) {
                    Stepper("Max Global In-Flight Requests: \(maxGlobalRequests)", value: $maxGlobalRequests, in: 2...32)
                }

                // Section 6: Bandwidth Management
                Section(
                    header: Text("Bandwidth Throttling"),
                    footer: Text("Token-bucket rate limiter dynamically enforces download throughput caps.")
                ) {
                    Toggle("Enable Global Speed Limit", isOn: $enableGlobalSpeedLimit)

                    if enableGlobalSpeedLimit {
                        HStack {
                            Text("Speed Cap (KB/s)")
                            Spacer()
                            TextField("KB/s", text: $globalSpeedLimitKBps)
                            #if canImport(UIKit)
                                .keyboardType(.numberPad)
                            #endif
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                        }
                    }
                }

                // Section 7: Secure Credentials & Proxy (Stored in iOS Keychain)
                Section(
                    header: Text("Secure Authentication & Proxy"),
                    footer: Text("Sensitive auth passwords and proxy credentials are encrypted in the iOS Keychain (kSecClassInternetPassword) and never stored in plain AppSettings.")
                ) {
                    TextField("Server / Host (e.g. example.com)", text: $authServer)
                        #if canImport(UIKit)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        #endif
                    TextField("Username", text: $authUsername)
                        #if canImport(UIKit)
                        .autocapitalization(.none)
                        #endif
                    SecureField("Password / Token", text: $authPassword)

                    HStack {
                        Button("Save to Keychain") {
                            saveKeychainCredentials()
                        }
                        .disabled(authServer.isEmpty || authUsername.isEmpty || authPassword.isEmpty)

                        Spacer()

                        Button("Clear") {
                            clearKeychainCredentials()
                        }
                        .foregroundColor(.red)
                        .disabled(authServer.isEmpty)
                    }

                    if let msg = keychainFeedbackMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }

                // Section 6: Storage & Persistence
                Section(header: Text("Storage & Recovery")) {
                    HStack {
                        Text("Download Directory")
                        Spacer()
                        Text(viewModel.downloadsDirectoryURL.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Button {
                        Task { @MainActor in
                            do {
                                try await viewModel.restoreQueue(autoStart: false)
                                statusMessage = "Queue successfully restored from disk."
                            } catch {
                                statusMessage = "Restore failed: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Label("Restore Queue from Disk", systemImage: "arrow.clockwise.circle")
                    }

                    if let msg = statusMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }

                // Section 7: Pipeline Diagnostics & Remote Debugging
                Section(
                    header: Text("Diagnostics & Remote Debugging"),
                    footer: Text("Inspect in-memory diagnostic logs for HLS and DASH stream downloads with sensitive tokens and cookies redacted.")
                ) {
                    Button {
                        showingDiagnostics = true
                    } label: {
                        Label("View Pipeline Diagnostics", systemImage: "doc.text.magnifyingglass")
                    }
                }

                // Section 8: Media Sniffer Filters
                Section(
                    header: Text("Media Sniffer Filters"),
                    footer: Text("Filter browser Grabber media candidates by comma-separated file extensions and MIME type prefixes.")
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

                // Section 9: Download Scheduler (iOS Native URLSession & Local Notifications)
                Section(
                    header: Text("Download Scheduler"),
                    footer: Text("\(ScheduleCoordinator.scheduledBackgroundBehaviorMessage) \(ScheduleCoordinator.torrentBackgroundLimitationMessage)")
                ) {
                    Toggle("Enable Scheduler", isOn: $scheduleEnabled)

                    if scheduleEnabled {
                        DatePicker("Start Time", selection: $scheduleStartTime, displayedComponents: .hourAndMinute)

                        Toggle("Enable Stop Time", isOn: $scheduleEnableStopTime)

                        if scheduleEnableStopTime {
                            DatePicker("Stop Time", selection: $scheduleStopTime, displayedComponents: .hourAndMinute)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Active Days")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 6) {
                                ForEach(ScheduleRule.orderedWeekdaySymbols, id: \.day) { item in
                                    let isSelected = scheduleWeekdays.contains(item.day)
                                    Button {
                                        if isSelected {
                                            if scheduleWeekdays.count > 1 {
                                                scheduleWeekdays.remove(item.day)
                                            }
                                        } else {
                                            scheduleWeekdays.insert(item.day)
                                        }
                                    } label: {
                                        Text(item.symbol)
                                            .font(.caption2.bold())
                                            .frame(maxWidth: .infinity, minHeight: 28)
                                            .background(isSelected ? Color.blue : Color.secondary.opacity(0.15))
                                            .foregroundColor(isSelected ? .white : .primary)
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        Toggle("Wi-Fi Only", isOn: $scheduleWifiOnly)

                        HStack {
                            Text("Scheduled Downloads Tagged")
                            Spacer()
                            Text("\(viewModel.scheduleRules.first?.targetDownloadIDs.count ?? 0) items")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Section 10: Save Action
                Section {
                    Button {
                        saveSettings()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Apply Settings")
                                .bold()
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingDiagnostics) {
                DiagnosticLogView(configuration: viewModel.activeEngineConfiguration)
            }
            .onAppear {
                loadCurrentSettings()
            }
            .alert("Settings Applied", isPresented: $showingSavedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Engine execution state, UI preferences, scheduler rules, and security policies have been updated.")
            }
        }
    }

    private func loadCurrentSettings() {
        let settings = viewModel.appSettings
        self.maxConcurrent = settings.maxConcurrentDownloads
        self.maxGlobalRequests = settings.maxGlobalRequests
        self.timeoutSeconds = settings.timeoutSeconds
        self.customUserAgent = settings.customUserAgent ?? ""
        self.maxRetryAttempts = settings.maxRetryAttempts
        self.duplicateNamingRule = settings.duplicateNamingRule
        self.allowCellular = settings.allowCellular

        self.maxConcurrentTorrents = settings.maxConcurrentTorrents
        self.defaultTorrentPriority = settings.defaultTorrentPriority
        self.seedingMode = settings.seedingMode
        self.targetRatio = settings.targetRatio
        self.targetDurationMinutes = settings.targetDurationMinutes

        self.enableGlobalSpeedLimit = settings.enableGlobalSpeedLimit
        self.globalSpeedLimitKBps = String(settings.globalSpeedLimitKBps)

        let sniffer = BrowserSnifferFilter.load()
        self.enableSnifferFilter = sniffer.isFilterEnabled
        self.snifferExtensions = sniffer.allowedExtensions.joined(separator: ", ")
        self.snifferMIMETypes = sniffer.allowedMIMETypes.joined(separator: ", ")

        if let rule = viewModel.scheduleRules.first {
            self.scheduleEnabled = rule.isEnabled
            let cal = Calendar.current
            self.scheduleStartTime = cal.date(from: rule.startTime) ?? Date()
            if let stopComp = rule.stopTime {
                self.scheduleEnableStopTime = true
                self.scheduleStopTime = cal.date(from: stopComp) ?? Date()
            } else {
                self.scheduleEnableStopTime = false
            }
            self.scheduleWeekdays = rule.weekdays
            self.scheduleWifiOnly = rule.wifiOnly
        }
    }

    private func saveSettings() {
        let speedKB = Int(globalSpeedLimitKBps) ?? 2048
        let updatedSettings = AppSettings(
            version: AppSettings.currentVersion,
            maxConcurrentDownloads: maxConcurrent,
            maxGlobalRequests: maxGlobalRequests,
            timeoutSeconds: timeoutSeconds,
            customUserAgent: customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customUserAgent,
            maxRetryAttempts: maxRetryAttempts,
            duplicateNamingRule: duplicateNamingRule,
            allowCellular: allowCellular,
            enableGlobalSpeedLimit: enableGlobalSpeedLimit,
            globalSpeedLimitKBps: speedKB,
            maxConcurrentTorrents: maxConcurrentTorrents,
            defaultTorrentPriority: defaultTorrentPriority,
            seedingMode: seedingMode,
            targetRatio: targetRatio,
            targetDurationMinutes: targetDurationMinutes
        )

        var currentRule = viewModel.scheduleRules.first ?? ScheduleRule()
        currentRule.isEnabled = scheduleEnabled
        let cal = Calendar.current
        currentRule.startTime = cal.dateComponents([.hour, .minute], from: scheduleStartTime)
        if scheduleEnableStopTime {
            currentRule.stopTime = cal.dateComponents([.hour, .minute], from: scheduleStopTime)
        } else {
            currentRule.stopTime = nil
        }
        currentRule.weekdays = scheduleWeekdays
        currentRule.wifiOnly = scheduleWifiOnly

        Task { @MainActor in
            await viewModel.saveScheduleRule(currentRule)
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

            try? await viewModel.applySettings(updatedSettings)
            await viewModel.reconcileSchedule()
            showingSavedAlert = true
        }
    }

    private func saveKeychainCredentials() {
        let cleanHost = authServer.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = authUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanUser.isEmpty, !authPassword.isEmpty else { return }

        let success = KeychainManager.shared.storeInternetPassword(
            username: cleanUser,
            password: authPassword,
            server: cleanHost
        )
        if success {
            keychainFeedbackMessage = "Credentials securely saved in Keychain for \(cleanHost)."
            authPassword = ""
        } else {
            keychainFeedbackMessage = "Failed to store credentials in Keychain."
        }
    }

    private func clearKeychainCredentials() {
        let cleanHost = authServer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return }
        let cleanUser = authUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanUser.isEmpty {
            _ = KeychainManager.shared.deleteInternetPassword(server: cleanHost)
        }
        authUsername = ""
        authPassword = ""
        keychainFeedbackMessage = "Cleared credentials for \(cleanHost)."
    }
}
#endif
