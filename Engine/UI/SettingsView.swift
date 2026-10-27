#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Screen 4: Settings Screen exposing the engine's concurrency, request budget, bandwidth limits, and BitTorrent controls.
public struct SettingsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel

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

                // Section 2: BitTorrent Concurrency & Network Ports
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

                // Section 3: BitTorrent Seeding Policy
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

                // Section 4: HTTP Connection & Request Budgeting
                Section(
                    header: Text("HTTP Request Budget"),
                    footer: Text("Limits total in-flight HTTP range requests across all segment workers to avoid socket exhaustion.")
                ) {
                    Stepper("Max Global In-Flight Requests: \(maxGlobalRequests)", value: $maxGlobalRequests, in: 2...32)
                }

                // Section 5: Bandwidth Management
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

                // Section 8: Save Action
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
                DiagnosticLogView()
            }
            .onAppear {
                loadCurrentSettings()
            }
            .alert("Settings Applied", isPresented: $showingSavedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Engine concurrency limits, seeding preferences, and speed controls have been updated.")
            }
        }
    }

    private func loadCurrentSettings() {
        self.maxConcurrent = viewModel.maxConcurrentDownloads
        self.maxGlobalRequests = viewModel.maxGlobalRequests
        self.maxConcurrentTorrents = viewModel.maxConcurrentTorrents
        self.defaultTorrentPriority = viewModel.defaultTorrentPriority

        let seeding = viewModel.defaultSeedingPreference
        self.seedingMode = seeding.mode
        self.targetRatio = seeding.targetRatio
        self.targetDurationMinutes = Int(seeding.targetDurationSeconds / 60)

        if let bytes = viewModel.globalBandwidthLimitBytesPerSecond, bytes > 0 {
            self.enableGlobalSpeedLimit = true
            self.globalSpeedLimitKBps = String(bytes / 1024)
        } else {
            self.enableGlobalSpeedLimit = false
            self.globalSpeedLimitKBps = "2048"
        }
    }

    private func saveSettings() {
        let limit: Int64?
        if enableGlobalSpeedLimit, let kb = Int64(globalSpeedLimitKBps), kb > 0 {
            limit = kb * 1024
        } else {
            limit = nil
        }

        let preference = SeedingPreference(
            mode: seedingMode,
            targetRatio: targetRatio,
            targetDurationSeconds: TimeInterval(targetDurationMinutes * 60)
        )

        Task { @MainActor in
            try? await viewModel.updateSettings(
                maxConcurrent: maxConcurrent,
                maxGlobalRequests: maxGlobalRequests,
                globalBandwidthLimit: limit
            )
            try? await viewModel.updateTorrentSettings(
                maxConcurrentTorrents: maxConcurrentTorrents,
                defaultPriority: defaultTorrentPriority,
                seedingPreference: preference
            )
            showingSavedAlert = true
        }
    }
}
#endif
