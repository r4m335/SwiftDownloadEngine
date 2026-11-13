#if canImport(SwiftUI)
import SwiftUI

/// Privacy shield sheet presented when tapping the shield icon in the browser address bar.
/// Provides instant per-site protection toggles and global ad/popup blocker controls.
public struct BrowserShieldSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            Form {
                // Section 1: Status Banner
                Section {
                    statusBanner
                        .listRowInsets(EdgeInsets())
                }

                // Section 2: Per-Site Protection
                Section(
                    header: Text("Current Website"),
                    footer: Text("Whitelisting a website allows all ads and trackers to load if a site breaks with shields enabled.")
                ) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(viewModel.currentDomainDisplayName)
                                .font(.headline)
                            Text(viewModel.isCurrentSiteWhitelisted ? "Shields paused for this site" : "Full shield protection enabled")
                                .font(.caption)
                                .foregroundColor(viewModel.isCurrentSiteWhitelisted ? .orange : .secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !viewModel.isCurrentSiteWhitelisted },
                            set: { _ in viewModel.toggleShieldForCurrentSite() }
                        ))
                        .labelsHidden()
                    }
                }

                // Section 3: Global Protection Shields
                Section(
                    header: Text("Global Content Shields"),
                    footer: Text("Runs directly inside Apple's WebKit engine with hardware-accelerated zero JavaScript overhead.")
                ) {
                    Toggle("Block Invasive Ads", isOn: Binding(
                        get: { viewModel.isAdBlockerEnabled },
                        set: { viewModel.setAdBlockerEnabled($0) }
                    ))

                    Toggle("Block Popups & Redirects", isOn: Binding(
                        get: { viewModel.isPopupBlockerEnabled },
                        set: { viewModel.setPopupBlockerEnabled($0) }
                    ))
                }

                // Section 4: Whitelisted Sites Summary
                if !viewModel.adBlockerWhitelistedDomains.isEmpty {
                    Section(header: Text("Whitelisted Domains (\(viewModel.adBlockerWhitelistedDomains.count))")) {
                        ForEach(Array(viewModel.adBlockerWhitelistedDomains).sorted(), id: \.self) { domain in
                            HStack {
                                Image(systemName: "shield.slash")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text(domain)
                                    .font(.subheadline)
                                Spacer()
                                Button {
                                    viewModel.adBlockerWhitelistedDomains.remove(domain)
                                    viewModel.persistShieldSettings()
                                    viewModel.updateActiveTabBlocker()
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Section 5: Actions
                Section {
                    Button {
                        viewModel.reload()
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Reload Page", systemImage: "arrow.clockwise")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Content Shields")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    private var statusBanner: some View {
        VStack(spacing: 12) {
            if !viewModel.isAdBlockerEnabled {
                Image(systemName: "shield.slash")
                    .font(.system(size: 42))
                    .foregroundColor(.secondary)
                Text("Shields Disabled")
                    .font(.headline)
                Text("Global ad blocking is switched off. Content rules are not applied.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if viewModel.isCurrentSiteWhitelisted {
                Image(systemName: "shield.slash.fill")
                    .font(.system(size: 42))
                    .foregroundColor(.orange)
                Text("Shields Down for This Site")
                    .font(.headline)
                Text("Ads and trackers are allowed on \(viewModel.currentDomainDisplayName).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 42))
                    .foregroundColor(.blue)
                Text("Shields Active")
                    .font(.headline)
                Text("Blocking intrusive ads, trackers, and malicious scripts on \(viewModel.currentDomainDisplayName).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        #if canImport(UIKit)
        .background(Color(UIColor.secondarySystemBackground))
        #else
        .background(Color.secondary.opacity(0.12))
        #endif
    }
}
#endif
