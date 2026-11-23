#if canImport(SwiftUI)
import SwiftUI

/// About screen displaying application identity, native architecture details, and open-source licensing.
public struct AboutView: View {
    public init() {}

    public var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(LinearGradient(colors: [Color.blue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 72, height: 72)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    }

                    VStack(spacing: 4) {
                        Text("LID Download Manager")
                            .font(.title2.bold())
                        Text("Version 1.0.0 (Build 2026)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section(header: Text("Core Architecture")) {
                LabeledRow(label: "Download Engine", value: "SwiftDownloadEngine (Native)")
                LabeledRow(label: "BitTorrent Core", value: "libtorrent-rasterbar 2.0.10")
                LabeledRow(label: "Media Decoding", value: "VLCKit 4.0.0 & AVFoundation")
                LabeledRow(label: "Settings Schema", value: "AppSettings v7 • LIDPlayer v1")
                LabeledRow(label: "Platform", value: "iOS 15.0+ / macOS 12.0+")
            }

            Section(header: Text("Privacy & Legal")) {
                NavigationLink {
                    AppPrivacyView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.shield.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("App Privacy & Policy")
                                .font(.body)
                            Text("Nutrition label, zero tracking & Privacy Manifest")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Link(destination: AppPrivacyInfo.privacyPolicyURL) {
                    HStack(spacing: 12) {
                        Image(systemName: "safari.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Privacy Policy (Web)")
                                .font(.body)
                            Text("Official policy hosted on GitHub")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                }

                NavigationLink {
                    OpenSourceLicensesView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundColor(.blue)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open Source Licenses")
                                .font(.body)
                            Text("Third-party notices, attributions, and LGPL terms")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text("Project Information")) {
                HStack {
                    Text("License")
                    Spacer()
                    Text("MIT License")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Copyright")
                    Spacer()
                    Text("© 2026 r4m335")
                        .foregroundColor(.secondary)
                }
            }
        }
        #if os(iOS)
        .listStyle(InsetGroupedListStyle())
        #else
        .listStyle(PlainListStyle())
        #endif
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.subheadline)
        }
    }
}
#endif
