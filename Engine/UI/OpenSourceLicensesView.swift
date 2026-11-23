#if canImport(SwiftUI)
import SwiftUI

/// Displays third-party open-source libraries, versions, copyright statements, and licensing details.
public struct OpenSourceLicensesView: View {
    @State private var searchText: String = ""
    @State private var showOnlyLinked: Bool = false

    public init() {}

    private var filteredLicenses: [OpenSourceLicense] {
        let base = showOnlyLinked ? OpenSourceLicensesRegistry.linkedLicenses : OpenSourceLicensesRegistry.allLicenses
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return base
        }
        let query = searchText.lowercased()
        return base.filter {
            $0.name.lowercased().contains(query) ||
            $0.licenseName.lowercased().contains(query) ||
            $0.spdxIdentifier.lowercased().contains(query) ||
            $0.copyright.lowercased().contains(query)
        }
    }

    public var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Third-Party Software Notices")
                        .font(.headline)
                    Text("This application relies on open-source projects. In accordance with their respective licenses, copyright notices and licensing terms are provided below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                Toggle("Only Show Linked Components", isOn: $showOnlyLinked)
                    .font(.subheadline)
            }

            Section(header: Text("Libraries & Components")) {
                ForEach(filteredLicenses) { license in
                    NavigationLink {
                        OpenSourceLicenseDetailView(license: license)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(license.name)
                                    .font(.headline)
                                Spacer()
                                Text(license.version)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(4)
                            }

                            HStack(spacing: 8) {
                                Text(license.licenseName)
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.blue)

                                if license.isDynamicallyLinked {
                                    Text("Dynamic (LGPL)")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.2))
                                        .foregroundColor(.green)
                                        .cornerRadius(4)
                                }

                                if !license.isLinked {
                                    Text("Not Linked")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.gray.opacity(0.2))
                                        .foregroundColor(.secondary)
                                        .cornerRadius(4)
                                }
                            }

                            Text(license.copyright.components(separatedBy: "\n").first ?? license.copyright)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section(header: Text("LGPL-2.1 Compliance Notice")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.green)
                        Text("VLCKit Dynamic Linking & Replacement")
                            .font(.subheadline.weight(.semibold))
                    }

                    Text("VLCKit is packaged and dynamically linked as VLCKit.framework inside the application bundle. In compliance with LGPL-2.1, users retain the freedom to relink or replace the dynamic library with custom builds on supported environments.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        #if os(iOS)
        .listStyle(InsetGroupedListStyle())
        #else
        .listStyle(PlainListStyle())
        #endif
        .navigationTitle("Open Source Licenses")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Detailed view showing full metadata, compliance notices, and external references for a single library.
public struct OpenSourceLicenseDetailView: View {
    public let license: OpenSourceLicense

    public init(license: OpenSourceLicense) {
        self.license = license
    }

    public var body: some View {
        List {
            Section(header: Text("Component Overview")) {
                LabeledRow(label: "Library Name", value: license.name)
                LabeledRow(label: "Version", value: license.version)
                LabeledRow(label: "License", value: license.licenseName)
                LabeledRow(label: "SPDX Identifier", value: license.spdxIdentifier)
                LabeledRow(label: "Binary Linkage", value: license.isLinked ? (license.isDynamicallyLinked ? "Dynamic Framework" : "Static Library / Core") : "Disabled at Build")
            }

            Section(header: Text("Copyright Notice")) {
                Text(license.copyright)
                    .font(.caption.monospaced())
                    .foregroundColor(.primary)
                    .padding(.vertical, 4)
            }

            if let notes = license.complianceNotes {
                Section(header: Text("Licensing & Compliance Notes")) {
                    Text(notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }
            }

            Section(header: Text("Terms & Permissions Summary")) {
                Text(license.summary)
                    .font(.callout)
                    .padding(.vertical, 4)
            }

            Section(header: Text("Official References")) {
                Link(destination: URL(string: license.licenseURL) ?? URL(string: "https://opensource.org")!) {
                    HStack {
                        Label("View Standard License Text", systemImage: "arrow.up.right.square")
                        Spacer()
                    }
                }

                if let sourceStr = license.sourceURL, let url = URL(string: sourceStr) {
                    Link(destination: url) {
                        HStack {
                            Label("Upstream Source Repository", systemImage: "safari")
                            Spacer()
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(InsetGroupedListStyle())
        #else
        .listStyle(PlainListStyle())
        #endif
        .navigationTitle(license.name)
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
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
#endif
