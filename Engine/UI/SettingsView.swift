#if canImport(SwiftUI)
import SwiftUI

/// Root Settings Screen: Category-based navigation hub organizing preferences into
/// Downloader, Browser, and Media Player sub-pages.
public struct SettingsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel

    public init(viewModel: DownloadManagerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            List {
                Section(header: Text("Preferences Categories")) {
                    // Category 1: Downloader
                    NavigationLink {
                        DownloaderSettingsView(viewModel: viewModel)
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.blue)
                                    .frame(width: 36, height: 36)
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Downloader")
                                    .font(.headline)
                                Text("Concurrency, network, bandwidth limits, storage, BitTorrent & scheduler")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // Category 2: Browser
                    NavigationLink {
                        BrowserSettingsView(viewModel: viewModel)
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.indigo)
                                    .frame(width: 36, height: 36)
                                Image(systemName: "globe")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Browser")
                                    .font(.headline)
                                Text("Search engine, homepage, privacy shields, ad blocking & reader mode")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // Category 3: Media Player
                    NavigationLink {
                        MediaPlayerSettingsView()
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.orange)
                                    .frame(width: 36, height: 36)
                                Image(systemName: "play.tv.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Media Player")
                                    .font(.headline)
                                Text("Playback speed, aspect ratio, subtitles, audio, gestures & orientation")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section(header: Text("About & System")) {
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
                        Text("AppSettings v7 • LIDPlayer v1")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
            }
            #if os(iOS)
            .listStyle(InsetGroupedListStyle())
            #else
            .listStyle(PlainListStyle())
            #endif
            .navigationTitle("Settings")
        }
    }
}
#endif
