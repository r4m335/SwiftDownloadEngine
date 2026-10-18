#if canImport(SwiftUI)
import SwiftUI

/// Screen 4: Settings Screen exposing the engine's concurrency, request budget, and bandwidth limits.
public struct SettingsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel

    @State private var maxConcurrent: Int = 3
    @State private var maxGlobalRequests: Int = 12
    @State private var enableGlobalSpeedLimit: Bool = false
    @State private var globalSpeedLimitKBps: String = "2048"
    @State private var showingSavedAlert: Bool = false
    @State private var statusMessage: String? = nil

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: Queue & Concurrency
                Section(
                    header: Text("Queue Concurrency"),
                    footer: Text("Controls how many downloads are transferred concurrently. Excess items wait in priority order.")
                ) {
                    Stepper("Max Concurrent Downloads: \(maxConcurrent)", value: $maxConcurrent, in: 1...10)
                }

                // Section 2: HTTP Connection & Request Budgeting
                Section(
                    header: Text("HTTP Request Budget"),
                    footer: Text("Limits total in-flight HTTP range requests across all segment workers to avoid socket exhaustion.")
                ) {
                    Stepper("Max Global In-Flight Requests: \(maxGlobalRequests)", value: $maxGlobalRequests, in: 2...32)
                }

                // Section 3: Bandwidth Management
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
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                        }
                    }
                }

                // Section 4: Storage & Persistence
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
                        Task {
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

                // Section 5: Save Action
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
            .onAppear {
                loadCurrentSettings()
            }
            .alert("Settings Applied", isPresented: $showingSavedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Engine concurrency limits and speed controls have been updated.")
            }
        }
    }

    private func loadCurrentSettings() {
        self.maxConcurrent = viewModel.maxConcurrentDownloads
        self.maxGlobalRequests = viewModel.maxGlobalRequests
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

        Task {
            try? await viewModel.updateSettings(
                maxConcurrent: maxConcurrent,
                maxGlobalRequests: maxGlobalRequests,
                globalBandwidthLimit: limit
            )
            showingSavedAlert = true
        }
    }
}
#endif
