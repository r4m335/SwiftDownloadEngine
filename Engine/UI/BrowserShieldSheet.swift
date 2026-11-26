#if canImport(SwiftUI)
import SwiftUI

/// Privacy shield sheet presented when tapping the shield icon or selecting Content Shields from the overflow menu.
/// Provides instant per-site protection toggles, multi-list rules (EasyList, EasyPrivacy, Fanboy), cookie policy, and site permissions.
public struct BrowserShieldSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var isShowingClearData: Bool = false

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
                    footer: Text("Whitelisting a website pauses content shields if layout or video streams break.")
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

                // Section 3: Global Protection Shields (Milestone B.2 Multi-List)
                Section(
                    header: Text("Content Blocker Rule Lists"),
                    footer: Text("Runs inside Apple's WebKit engine with hardware-accelerated zero JavaScript overhead.")
                ) {
                    Toggle("Block Invasive Ads (EasyList)", isOn: Binding(
                        get: { viewModel.isAdBlockerEnabled },
                        set: { viewModel.setAdBlockerEnabled($0) }
                    ))

                    Toggle("Block Trackers & Telemetry (EasyPrivacy)", isOn: Binding(
                        get: { viewModel.isTrackerBlockerEnabled },
                        set: { viewModel.setTrackerBlockerEnabled($0) }
                    ))

                    Toggle("Block Annoyances & Cookie Notices", isOn: Binding(
                        get: { viewModel.isAnnoyanceBlockerEnabled },
                        set: { viewModel.setAnnoyanceBlockerEnabled($0) }
                    ))

                    Toggle("Block Popups & Redirects", isOn: Binding(
                        get: { viewModel.isPopupBlockerEnabled },
                        set: { viewModel.setPopupBlockerEnabled($0) }
                    ))
                }

                // Section 4: Cookie Management
                Section(header: Text("Cookie Policy")) {
                    Picker("Cookies", selection: Binding(
                        get: { viewModel.cookiePolicy },
                        set: { viewModel.setCookiePolicy($0) }
                    )) {
                        ForEach(BrowserCookiePolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                }

                // Section 5: Current Site Hardware Permissions
                let sitePermissions = viewModel.sitePermissionsStore.entries(for: viewModel.currentDomainDisplayName)
                if !sitePermissions.isEmpty {
                    Section(header: Text("Site Permissions for \(viewModel.currentDomainDisplayName)")) {
                        ForEach(sitePermissions) { perm in
                            HStack {
                                Label(perm.permissionType.rawValue.capitalized, systemImage: iconForPermission(perm.permissionType))
                                Spacer()
                                Text(perm.decision.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundColor(perm.decision == .grant ? .green : .red)
                                Button {
                                    viewModel.sitePermissionsStore.removePermission(for: viewModel.currentDomainDisplayName, type: perm.permissionType)
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

                // Section 6: Whitelisted Sites Summary
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

                // Section 7: Data & Actions
                Section {
                    Button {
                        isShowingClearData = true
                    } label: {
                        Label("Clear Browsing Data...", systemImage: "trash")
                            .foregroundColor(.red)
                    }

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
            .sheet(isPresented: $isShowingClearData) {
                BrowserClearDataSheet(viewModel: viewModel)
            }
        }
        .modernStackNavigation()
    }

    private func iconForPermission(_ type: BrowserPermissionType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "mic"
        case .cameraAndMicrophone: return "video"
        case .geolocation: return "location"
        case .deviceMotion: return "gyroscope"
        }
    }

    private var statusBanner: some View {
        VStack(spacing: 12) {
            if !viewModel.isAdBlockerEnabled && !viewModel.isTrackerBlockerEnabled && !viewModel.isAnnoyanceBlockerEnabled {
                Image(systemName: "shield.slash")
                    .font(.system(size: 42))
                    .foregroundColor(.secondary)
                Text("Shields Disabled")
                    .font(.headline)
                Text("Content rules are currently inactive.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if viewModel.isCurrentSiteWhitelisted {
                Image(systemName: "shield.slash.fill")
                    .font(.system(size: 42))
                    .foregroundColor(.orange)
                Text("Shields Paused for This Site")
                    .font(.headline)
                Text("Content rules are paused on \(viewModel.currentDomainDisplayName).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 42))
                    .foregroundColor(.blue)
                Text("Shields Active")
                    .font(.headline)
                Text("Blocking intrusive ads, trackers, and annoyance overlays on \(viewModel.currentDomainDisplayName).")
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
