#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Root Settings Screen: Category-based navigation hub organizing preferences into
/// Downloader, Browser, and Media Player sub-pages.
public struct SettingsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    @AppStorage("downloadsCompactMode") private var downloadsCompactMode: Bool = false
    @AppStorage("mediaLibraryGridView") private var mediaLibraryGridView: Bool = false
    @State private var notificationStatus: NotificationPermissionStatus = .notDetermined

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            List {
                // Quick Overview Summary Card
                Section {
                    HStack(spacing: 16) {
                        overviewStat(
                            value: "\(viewModel.statusCounts.active)",
                            label: "Active",
                            icon: "arrow.down.circle.fill",
                            color: .blue
                        )
                        Divider()
                        overviewStat(
                            value: "\(viewModel.statusCounts.completed)",
                            label: "Completed",
                            icon: "checkmark.circle.fill",
                            color: .green
                        )
                        Divider()
                        overviewStat(
                            value: "\(viewModel.statusCounts.paused)",
                            label: "Paused",
                            icon: "pause.circle.fill",
                            color: .orange
                        )
                    }
                    .padding(.vertical, 6)
                }

                Section(header: Text("Preferences Categories")) {
                    // Category 1: Downloader
                    NavigationLink {
                        DownloaderSettingsView(viewModel: viewModel)
                    } label: {
                        SettingsCategoryRow(
                            title: "Downloader",
                            subtitle: "Concurrency, network, bandwidth limits, storage, BitTorrent & scheduler",
                            icon: "arrow.down.circle.fill",
                            gradient: [.blue, .cyan]
                        )
                    }

                    // Category 2: Browser
                    NavigationLink {
                        BrowserSettingsView(viewModel: viewModel)
                    } label: {
                        SettingsCategoryRow(
                            title: "Browser",
                            subtitle: "Search engine, homepage, privacy shields, ad blocking & reader mode",
                            icon: "globe",
                            gradient: [.indigo, .purple]
                        )
                    }

                    // Category 3: Media Player
                    NavigationLink {
                        MediaPlayerSettingsView()
                    } label: {
                        SettingsCategoryRow(
                            title: "Media Player",
                            subtitle: "Playback speed, aspect ratio, subtitles, audio, gestures & orientation",
                            icon: "play.tv.fill",
                            gradient: [.orange, .pink]
                        )
                    }
                }

                Section(header: Text("Interface & Notifications")) {
                    Toggle(isOn: $downloadsCompactMode) {
                        Label("Compact Download Cards", systemImage: "rectangle.grid.1x2")
                    }

                    Toggle(isOn: $mediaLibraryGridView) {
                        Label("Media Library Grid Layout", systemImage: "square.grid.2x2")
                    }

                    HStack {
                        Label("Transfer Notifications", systemImage: "bell.badge")
                        Spacer()
                        Text(notificationStatusLabel)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(notificationStatusColor.opacity(0.15))
                            .foregroundColor(notificationStatusColor)
                            .clipShape(Capsule())
                    }

                    if notificationStatus == .notDetermined {
                        Button {
                            Task { @MainActor in
                                _ = await DownloadNotificationManager.requestPermissionBeforeFirstDownload()
                                notificationStatus = await DownloadNotificationManager.checkPermissionStatus()
                            }
                        } label: {
                            Label("Enable Notifications", systemImage: "bell.fill")
                        }
                    } else {
                        #if canImport(UIKit)
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Open System Notification Settings", systemImage: "gear")
                        }
                        #endif
                    }
                }

                Section(header: Text("About & System")) {
                    NavigationLink {
                        AboutView()
                    } label: {
                        SettingsCategoryRow(
                            title: "About",
                            subtitle: "Application version, engine details & open source licenses",
                            icon: "info.circle.fill",
                            gradient: [.gray, .secondary]
                        )
                    }

                    NavigationLink {
                        AppPrivacyView()
                    } label: {
                        SettingsCategoryRow(
                            title: "App Privacy & Policy",
                            subtitle: "Nutrition label, zero tracking & Privacy Manifest",
                            icon: "hand.raised.shield.fill",
                            gradient: [.green, .mint]
                        )
                    }

                    NavigationLink {
                        OpenSourceLicensesView()
                    } label: {
                        SettingsCategoryRow(
                            title: "Open Source Licenses",
                            subtitle: "Third-party attributions, BSD, Boost, and LGPL notices",
                            icon: "doc.text.fill",
                            gradient: [.teal, .blue]
                        )
                    }

                    HStack {
                        Text("Application")
                        Spacer()
                        Text("LID Download Manager")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Download Engine")
                        Spacer()
                        Text("SwiftDownloadEngine (Native)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Settings Schema")
                        Spacer()
                        Text("AppSettings v8 • LIDPlayer v1")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
            }
            .task {
                notificationStatus = await DownloadNotificationManager.checkPermissionStatus()
            }
            #if os(iOS)
            .listStyle(InsetGroupedListStyle())
            #else
            .listStyle(PlainListStyle())
            #endif
            .navigationTitle("Settings")
        }
    }

    private var notificationStatusLabel: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        }
    }

    private var notificationStatusColor: Color {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        }
    }

    @ViewBuilder
    private func overviewStat(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(value)
                    .font(.headline.monospacedDigit().bold())
                    .foregroundColor(.primary)
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsCategoryRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 4)
        }
    }
}
#endif
