#if canImport(SwiftUI)
import SwiftUI

/// Screen presenting the App Privacy Nutrition Label, privacy policy URL, and Apple Privacy Manifest details.
public struct AppPrivacyView: View {
    public init() {}

    public var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: 64, height: 64)
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.green)
                    }

                    VStack(spacing: 4) {
                        Text("Privacy by Design")
                            .font(.headline)
                        Text(AppPrivacyInfo.dataCollectionSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section(header: Text("Privacy Policy")) {
                Link(destination: AppPrivacyInfo.privacyPolicyURL) {
                    HStack {
                        Label("Read Official Privacy Policy", systemImage: "safari.fill")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                Link(destination: AppPrivacyInfo.repositoryURL) {
                    HStack {
                        Label("Open Source Codebase (GitHub)", systemImage: "chevron.left.forwardslash.chevron.right")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }

            Section(header: Text("App Privacy Nutrition Label")) {
                ForEach(AppPrivacyInfo.appStoreAnswers) { answer in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text(answer.category)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(answer.isCollected ? "Collected" : "Not Collected")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .foregroundColor(.green)
                                .cornerRadius(4)
                        }

                        Text(answer.explanation)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text("Apple Privacy Manifest APIs (PrivacyInfo.xcprivacy)")) {
                ForEach(AppPrivacyInfo.accessedAPIs) { api in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(api.category.replacingOccurrences(of: "NSPrivacyAccessedAPICategory", with: ""))
                                .font(.subheadline.bold())
                            Spacer()
                            Text(api.reasons.joined(separator: ", "))
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }

                        Text(api.purpose)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        #if os(iOS)
        .listStyle(InsetGroupedListStyle())
        #else
        .listStyle(PlainListStyle())
        #endif
        .navigationTitle("App Privacy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
#endif
