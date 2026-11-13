#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(QuickLook)
import QuickLook
#endif

/// Screen 3: Download Details Screen displaying URL/Info-hash, swarm metrics, progress, speed, status, and error details.
public struct DownloadDetailsView: View {
    @ObservedObject public var viewModel: DownloadManagerViewModel
    public let transferID: String

    @Environment(\.presentationMode) private var presentationMode
    @State private var showingDeleteAlert = false
    @State private var isCalculatingHash = false
    @State private var hashProgress: Double = 0.0
    @State private var calculatedHash: String? = nil
    @State private var hashError: String? = nil
    @State private var quickLookURL: URL? = nil
    @State private var torrentFiles: [TorrentFileInfo] = []
    @State private var isLoadingFiles: Bool = false
    @State private var torrentTrackers: [TorrentTrackerInfo] = []
    @State private var isLoadingTrackers: Bool = false
    @State private var showingAddTrackerSheet: Bool = false
    @State private var newTrackerURL: String = ""
    @State private var trackerErrorMessage: String? = nil
    @State private var showingRefreshSheet: Bool = false
    @State private var newRefreshURL: String = ""
    @State private var isRefreshing: Bool = false
    @State private var refreshStatusMessage: String? = nil
    @State private var hlsRecord: HLSTransferRecord? = nil
    @State private var isLoadingHLSSegments = false

    public init(viewModel: DownloadManagerViewModel, transfer: UnifiedTransfer) {
        self.viewModel = viewModel
        self.transferID = transfer.id
    }

    public init(viewModel: DownloadManagerViewModel, download: DownloadSnapshot) {
        self.viewModel = viewModel
        self.transferID = download.id
    }

    public init(viewModel: DownloadManagerViewModel, torrent: TorrentTask) {
        self.viewModel = viewModel
        self.transferID = torrent.id.uuidString
    }

    private var currentTransfer: UnifiedTransfer? {
        if let found = viewModel.unifiedTransfers.first(where: { $0.id == transferID }) {
            return found
        }
        if let snap = viewModel.downloads.first(where: { $0.id == transferID }) {
            return UnifiedTransfer(from: snap)
        }
        if let task = viewModel.torrentTasks.first(where: { $0.id.uuidString == transferID || $0.infoHash.caseInsensitiveCompare(transferID) == .orderedSame }) {
            return UnifiedTransfer(from: task)
        }
        return nil
    }

    private var currentSnapshot: DownloadSnapshot? {
        viewModel.downloads.first { $0.id == transferID }
    }

    public var body: some View {
        Group {
            if let transfer = currentTransfer {
                if transfer.isTorrent {
                    torrentDetailsView(transfer)
                } else {
                    httpDetailsView(transfer, snapshot: currentSnapshot)
                }
            } else {
                VStack(spacing: 12) {
                    Text("Transfer Not Found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("This transfer may have been removed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .navigationTitle("Details")
            }
        }
    }

    // MARK: - BitTorrent Details View

    @ViewBuilder
    private func torrentDetailsView(_ transfer: UnifiedTransfer) -> some View {
        List {
            torrentHeaderSection(transfer)
            torrentDiagnosticsSection(transfer)
            torrentMetricsSection(transfer)
            torrentTrackersSection(transfer)
            torrentFilesSection(transfer)
            torrentSeedingSection(transfer)
            torrentIdentitySection(transfer)
            torrentControlSection(transfer)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Torrent Details")
        .onAppear {
            if let hash = transfer.infoHash {
                if transfer.totalBytes != nil {
                    loadFiles(for: hash)
                }
                loadTrackers(for: hash)
            }
        }
        .sheet(isPresented: $showingAddTrackerSheet) {
            #if os(iOS)
            NavigationView {
                addTrackerForm(for: transfer)
            }
            #else
            addTrackerForm(for: transfer)
            #endif
        }
    }

    @ViewBuilder
    private func torrentHeaderSection(_ transfer: UnifiedTransfer) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(transfer.name)
                        .font(.title3.bold())
                        .lineLimit(2)
                    Spacer()
                    TypeBadge(type: .torrent)
                    UnifiedStatusBadge(state: transfer.state)
                }

                if let total = transfer.totalBytes, total > 0 {
                    ProgressView(value: transfer.progressFraction)
                        .progressViewStyle(LinearProgressViewStyle())

                    HStack {
                        Text("\(Int(transfer.progressFraction * 100))% Complete")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(UIFormatters.formatBytes(transfer.completedBytes)) of \(UIFormatters.formatBytes(total))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 6)
                        Text("Fetching torrent metadata...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func torrentDiagnosticsSection(_ transfer: UnifiedTransfer) -> some View {
        if let reason = transfer.failureReason {
            Section(header: Text("Error Information")) {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(reason)
                        .font(.body)
                        .foregroundColor(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func torrentMetricsSection(_ transfer: UnifiedTransfer) -> some View {
        Section(header: Text("BitTorrent Swarm Metrics")) {
            DetailRow(label: "Download Speed", value: UIFormatters.formatSpeed(transfer.downloadSpeedBytesPerSecond))
            DetailRow(label: "Upload Speed", value: UIFormatters.formatSpeed(transfer.uploadSpeedBytesPerSecond))
            DetailRow(label: "Connected Peers", value: "\(transfer.connectedPeers ?? 0)")
            DetailRow(label: "Active Seeds", value: "\(transfer.connectedSeeds ?? 0)")

            if let currentPriority = transfer.torrentPriority, let hash = transfer.infoHash {
                HStack {
                    Text("Queue Priority")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("Priority", selection: Binding(
                        get: { currentPriority },
                        set: { newPrio in
                            Task { @MainActor in
                                try? await viewModel.setTorrentPriority(newPrio, for: hash)
                            }
                        }
                    )) {
                        Text("Low").tag(TorrentPriority.low)
                        Text("Normal").tag(TorrentPriority.normal)
                        Text("High").tag(TorrentPriority.high)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(maxWidth: 180)
                }
                .padding(.vertical, 2)
            }

            if let hash = transfer.infoHash {
                Toggle("Sequential Piece Download", isOn: Binding(
                    get: { transfer.isSequentialDownload },
                    set: { newVal in
                        Task { @MainActor in
                            try? await viewModel.setSequentialDownload(newVal, for: hash)
                        }
                    }
                ))
            }
        }
    }

    // MARK: - Swarm Trackers

    @ViewBuilder
    private func torrentTrackersSection(_ transfer: UnifiedTransfer) -> some View {
        if let hash = transfer.infoHash {
            Section(
                header: HStack {
                    Text("Swarm Trackers (\(torrentTrackers.count))")
                    Spacer()
                    Button {
                        Task { @MainActor in
                            try? await viewModel.forceReannounce(for: hash)
                            loadTrackers(for: hash)
                        }
                    } label: {
                        Label("Re-announce", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    #if os(iOS)
                    .textCase(nil)
                    #endif
                },
                footer: Text("Trackers coordinate peer discovery and swarm health. Adding custom trackers connects the transfer to additional swarms.")
            ) {
                if torrentTrackers.isEmpty {
                    if isLoadingTrackers {
                        HStack {
                            Spacer()
                            ProgressView()
                                .padding(.trailing, 6)
                            Text("Querying trackers...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    } else {
                        Text("No active trackers found.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(torrentTrackers) { tracker in
                        trackerRow(tracker: tracker, hash: hash)
                    }
                }

                Button {
                    newTrackerURL = ""
                    trackerErrorMessage = nil
                    showingAddTrackerSheet = true
                } label: {
                    Label("Add Custom Tracker", systemImage: "plus.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func trackerRow(tracker: TorrentTrackerInfo, hash: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tier \(tracker.tier)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)

                Text(tracker.url)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                trackerStateBadge(tracker.state)
            }

            HStack(spacing: 12) {
                if let peers = tracker.numPeers, peers >= 0 {
                    Text("Peers: \(peers)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let seeds = tracker.numSeeds, seeds >= 0 {
                    Text("Seeds: \(seeds)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let dl = tracker.numDownloaded, dl >= 0 {
                    Text("Downloaded: \(dl)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    Task { @MainActor in
                        try? await viewModel.removeTracker(url: tracker.url, for: hash)
                        loadTrackers(for: hash)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
                .buttonStyle(BorderlessButtonStyle())
            }

            if let msg = tracker.message, !msg.isEmpty {
                Text(msg)
                    .font(.caption2)
                    .foregroundColor(tracker.state == .notWorking ? .red : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func trackerStateBadge(_ state: TorrentTrackerState) -> some View {
        Text(state.rawValue.capitalized)
            .font(.caption2)
            .bold()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeBackgroundColor(for: state))
            .foregroundColor(badgeForegroundColor(for: state))
            .cornerRadius(4)
    }

    private func badgeBackgroundColor(for state: TorrentTrackerState) -> Color {
        switch state {
        case .working: return Color.green.opacity(0.15)
        case .updating: return Color.blue.opacity(0.15)
        case .notWorking: return Color.red.opacity(0.15)
        case .notContacted: return Color.gray.opacity(0.15)
        }
    }

    private func badgeForegroundColor(for state: TorrentTrackerState) -> Color {
        switch state {
        case .working: return .green
        case .updating: return .blue
        case .notWorking: return .red
        case .notContacted: return .secondary
        }
    }

    @ViewBuilder
    private func addTrackerForm(for transfer: UnifiedTransfer) -> some View {
        Form {
            Section(
                header: Text("Tracker URL"),
                footer: Text("Supported schemes: http, https, udp, ws, wss. UDP trackers must specify a port (e.g. :1337/announce).")
            ) {
                TextField("udp://tracker.opentrackr.org:1337/announce", text: $newTrackerURL)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            }

            if let err = trackerErrorMessage {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Add Tracker")
        #if os(iOS)
        .navigationBarItems(
            leading: Button("Cancel") { showingAddTrackerSheet = false },
            trailing: Button("Add") {
                submitNewTracker(for: transfer)
            }
            .disabled(newTrackerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )
        #else
        .toolbar {
            Button("Cancel") { showingAddTrackerSheet = false }
            Button("Add") {
                submitNewTracker(for: transfer)
            }
            .disabled(newTrackerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        #endif
    }

    private func submitNewTracker(for transfer: UnifiedTransfer) {
        guard let hash = transfer.infoHash else { return }
        let trimmed = newTrackerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                try await viewModel.addTracker(url: trimmed, tier: 0, for: hash)
                showingAddTrackerSheet = false
                loadTrackers(for: hash)
            } catch {
                trackerErrorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func torrentFilesSection(_ transfer: UnifiedTransfer) -> some View {
        Section(
            header: Text("Files & Selective Download"),
            footer: Text(transfer.totalBytes == nil ? "Metadata is downloading from swarm peers. Individual files will be selectable once metadata resolves." : "Customize which files to download or skip.")
        ) {
            if let hash = transfer.infoHash {
                if transfer.totalBytes == nil {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.orange)
                        Text("Metadata pending from peers...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if torrentFiles.isEmpty {
                    if isLoadingFiles {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 6)
                            Text("Loading file list...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            loadFiles(for: hash)
                        } label: {
                            Label("Fetch File List", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                } else {
                    ForEach(torrentFiles) { file in
                        torrentFileRow(file: file, hash: hash)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func torrentFileRow(file: TorrentFileInfo, hash: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Image(systemName: file.priority == .doNotDownload ? "xmark.circle" : "doc.fill")
                    .foregroundColor(file.priority == .doNotDownload ? .secondary : (file.priority == .high ? .orange : .blue))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    if file.priority == .doNotDownload {
                        Text("\(file.name) (Skipped)")
                            .font(.subheadline)
                            .lineLimit(2)
                            .foregroundColor(.secondary)
                    } else {
                        Text(file.name)
                            .font(.subheadline)
                            .lineLimit(2)
                            .foregroundColor(.primary)
                    }

                    HStack(spacing: 8) {
                        Text(UIFormatters.formatBytes(file.size))
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if file.progressFraction > 0 {
                            Text("\(Int(file.progressFraction * 100))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                Picker("", selection: Binding(
                    get: { file.priority },
                    set: { newPrio in
                        Task { @MainActor in
                            try? await viewModel.setTorrentFilePriority(
                                infoHash: hash,
                                fileIndex: file.index,
                                priority: newPrio
                            )
                            if let idx = torrentFiles.firstIndex(where: { $0.index == file.index }) {
                                torrentFiles[idx].priority = newPrio
                            }
                        }
                    }
                )) {
                    Text("Skip").tag(TorrentFilePriority.doNotDownload)
                    Text("Normal").tag(TorrentFilePriority.normal)
                    Text("High").tag(TorrentFilePriority.high)
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: 90)
            }

            if file.progressFraction > 0 && file.progressFraction < 1.0 {
                ProgressView(value: file.progressFraction)
                    .progressViewStyle(LinearProgressViewStyle())
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func torrentSeedingSection(_ transfer: UnifiedTransfer) -> some View {
        Section(
            header: Text("Seeding Behavior"),
            footer: Text("Controls when this torrent will stop seeding after completion.")
        ) {
            if let hash = transfer.infoHash {
                Picker("Seeding Policy", selection: Binding(
                    get: { transfer.seedingPreference?.mode ?? viewModel.defaultSeedingPreference.mode },
                    set: { newMode in
                        Task { @MainActor in
                            let pref = SeedingPreference(
                                mode: newMode,
                                targetRatio: 1.0,
                                targetDurationSeconds: 3600
                            )
                            try? await viewModel.setSeedingPreference(infoHash: hash, preference: pref)
                        }
                    }
                )) {
                    Text("Stop when complete").tag(SeedingMode.doNotSeed)
                    Text("Seed until ratio (1.0x)").tag(SeedingMode.ratio)
                    Text("Seed for 1 hour").tag(SeedingMode.duration)
                    Text("Seed indefinitely").tag(SeedingMode.indefinitely)
                }
            }
        }
    }

    @ViewBuilder
    private func torrentIdentitySection(_ transfer: UnifiedTransfer) -> some View {
        Section(header: Text("Torrent Identity")) {
            if let hash = transfer.infoHash {
                HStack {
                    DetailRow(label: "Info Hash", value: hash)
                    Spacer()
                    Button {
                        copyToClipboard(hash, message: "Info-hash copied")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }

            HStack {
                DetailRow(label: "Source", value: transfer.source)
                Spacer()
                Button {
                    copyToClipboard(transfer.source, message: "Source URI copied")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.blue)
                }
                .buttonStyle(BorderlessButtonStyle())
            }

            DetailRow(label: "Save Destination", value: transfer.destinationURL.path)
            DetailRow(label: "Added At", value: transfer.createdAt.formatted())
        }
    }

    @ViewBuilder
    private func torrentControlSection(_ transfer: UnifiedTransfer) -> some View {
        Section {
            if transfer.state == .downloading || transfer.state == .seeding {
                Button {
                    Task { @MainActor in
                        try? await viewModel.pauseTransfer(id: transfer.id)
                    }
                } label: {
                    Label("Pause Torrent", systemImage: "pause.fill")
                        .foregroundColor(.orange)
                }
            } else if transfer.state == .paused || transfer.state == .queued {
                Button {
                    Task { @MainActor in
                        try? await viewModel.resumeTransfer(id: transfer.id)
                    }
                } label: {
                    Label("Resume Torrent", systemImage: "play.fill")
                        .foregroundColor(.green)
                }
            }

            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                Label("Remove Torrent", systemImage: "trash")
            }
        }
        .alert("Remove Torrent", isPresented: $showingDeleteAlert) {
            Button("Remove Task Only", role: .none) {
                Task { @MainActor in
                    try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: false)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            Button("Delete Files from Disk", role: .destructive) {
                Task { @MainActor in
                    try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: true)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to remove only the torrent task or delete its downloaded payload files from disk?")
        }
    }

    // MARK: - HTTP Details View

    @ViewBuilder
    private func httpDetailsView(_ transfer: UnifiedTransfer, snapshot: DownloadSnapshot?) -> some View {
        List {
            // Header Status & Progress
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(transfer.name)
                            .font(.title3.bold())
                        Spacer()
                        TypeBadge(type: transfer.type)
                        if let snap = snapshot {
                            StatusBadge(state: snap.state)
                        } else {
                            UnifiedStatusBadge(state: transfer.state)
                        }
                    }

                    ProgressView(value: transfer.progressFraction)
                        .progressViewStyle(LinearProgressViewStyle())

                    HStack {
                        Text("\(Int(transfer.progressFraction * 100))% Complete")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(UIFormatters.formatBytes(transfer.completedBytes)) of \(transfer.totalBytes.map(UIFormatters.formatBytes) ?? "Unknown")")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Failure Diagnostics
            if let reason = transfer.failureReason {
                Section(header: Text("Error Information")) {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(reason)
                            .font(.body)
                            .foregroundColor(.red)
                    }

                    if snapshot?.isForbidden == true || snapshot?.isLinkExpired == true ||
                       reason.localizedCaseInsensitiveContains("403") ||
                       reason.localizedCaseInsensitiveContains("404") ||
                       reason.localizedCaseInsensitiveContains("expired") {
                        Button {
                            newRefreshURL = snapshot?.url.absoluteString ?? ""
                            refreshStatusMessage = nil
                            showingRefreshSheet = true
                        } label: {
                            Label("Refresh Link", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline)
                        }
                    }

                    if snapshot?.isUnauthorized == true || reason.localizedCaseInsensitiveContains("401") {
                        Button {
                            if let pageURL = snapshot?.url {
                                #if canImport(UIKit)
                                UIApplication.shared.open(pageURL)
                                #endif
                            }
                        } label: {
                            Label("Log In in Browser", systemImage: "person.crop.circle.badge.exclamationmark")
                                .font(.headline)
                        }
                    }
                }
            }

            // Transfer Metrics
            Section(header: Text("Transfer Metrics")) {
                DetailRow(label: "Current Speed", value: UIFormatters.formatSpeed(transfer.downloadSpeedBytesPerSecond))
                if let snap = snapshot {
                    DetailRow(label: "Average Speed", value: UIFormatters.formatSpeed(snap.averageBytesPerSecond))
                    DetailRow(label: "Time Remaining", value: UIFormatters.formatTimeInterval(snap.estimatedTimeRemaining))
                    DetailRow(label: "Elapsed Time", value: UIFormatters.formatTimeInterval(snap.elapsedTime))
                    DetailRow(label: "Priority", value: priorityLabel(for: snap.priority))
                }
            }

            if transfer.type == .hls {
                hlsSegmentsSection
            }

            // Integrity & Checksums
            if let snap = snapshot {
                Section(header: Text("Integrity Verification")) {
                    DetailRow(label: "Verification Status", value: checksumString(snap.checksumOutcome))

                    if let hash = calculatedHash {
                        DetailRow(label: "Calculated SHA-256", value: hash)
                    }

                    if let err = hashError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if isCalculatingHash {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Calculating SHA-256... \(Int(hashProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ProgressView(value: hashProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                        }
                        .padding(.vertical, 4)
                    } else if FileManager.default.fileExists(atPath: snap.destinationURL.path) {
                        Button {
                            runChecksumVerification(for: snap)
                        } label: {
                            Label(calculatedHash == nil ? "Verify File Integrity (SHA-256)" : "Recalculate SHA-256", systemImage: "checkmark.shield")
                        }
                    }
                }
            }

            // Network Rules
            Section(
                header: Text("Network Rules"),
                footer: Text("When 'Wi-Fi Only' is enabled, this download will not use cellular data or expensive metered networks.")
            ) {
                Toggle("Wi-Fi Only (Disable Cellular)", isOn: Binding(
                    get: { currentSnapshot?.networkPolicy == .wifiOnly || transfer.networkPolicy == .wifiOnly },
                    set: { isWifiOnly in
                        let policy: DownloadNetworkPolicy = isWifiOnly ? .wifiOnly : .anyNetwork
                        Task { @MainActor in
                            await viewModel.updateNetworkPolicy(for: transfer.id, policy: policy)
                        }
                    }
                ))
            }

            // File & Location Details
            Section(header: Text("File Details")) {
                DetailRow(label: "Destination", value: transfer.destinationURL.path)
                DetailRow(label: "Source URL", value: transfer.source)
                DetailRow(label: "Download ID", value: transfer.id)
                DetailRow(label: "Enqueued At", value: transfer.createdAt.formatted())
            }

            // Control Operations
            Section {
                if transfer.state == .downloading {
                    Button {
                        Task { @MainActor in try? await viewModel.pauseTransfer(id: transfer.id) }
                    } label: {
                        Label("Pause Download", systemImage: "pause.fill")
                            .foregroundColor(.orange)
                    }
                } else if transfer.state == .paused {
                    Button {
                        Task { @MainActor in try? await viewModel.resumeTransfer(id: transfer.id) }
                    } label: {
                        Label("Resume Download", systemImage: "play.fill")
                            .foregroundColor(.green)
                    }
                } else if transfer.state == .completed {
                    Button {
                        quickLookURL = transfer.destinationURL
                    } label: {
                        Label("Open File", systemImage: "doc.text")
                            .foregroundColor(.blue)
                    }
                }

                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("Remove from Queue", systemImage: "trash")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Details")
        .task(id: transfer.id) {
            await monitorHLSTransferRecord(for: transfer.id)
        }
        .filePreviewSheet(item: $quickLookURL)
        .alert("Remove Download", isPresented: $showingDeleteAlert) {
            Button("Remove Entry Only", role: .none) {
                Task { @MainActor in
                    try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: false)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            Button("Delete File from Disk", role: .destructive) {
                Task { @MainActor in
                    try? await viewModel.removeTransfer(id: transfer.id, deleteFiles: true)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to keep or delete the downloaded file from disk?")
        }
        .sheet(isPresented: $showingRefreshSheet) {
            #if canImport(SwiftUI)
            NavigationView {
                Form {
                    Section(
                        header: Text("Update Download URL / Token"),
                        footer: Text("If the ETag and file size match the original resource, the download resumes seamlessly. Otherwise, the engine restarts fresh.")
                    ) {
                        TextField("https://...", text: $newRefreshURL)
                            #if os(iOS)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            #endif
                    }

                    if let msg = refreshStatusMessage {
                        Section {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }

                    Section {
                        Button {
                            guard let snap = snapshot else { return }
                            isRefreshing = true
                            refreshStatusMessage = nil
                            Task {
                                do {
                                    try await viewModel.refreshDownloadLink(id: snap.id, newURLText: newRefreshURL)
                                    isRefreshing = false
                                    showingRefreshSheet = false
                                } catch {
                                    isRefreshing = false
                                    refreshStatusMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            if isRefreshing {
                                HStack {
                                    ProgressView()
                                        .padding(.trailing, 6)
                                    Text("Validating & Refreshing...")
                                }
                            } else {
                                Text("Refresh & Resume")
                                    .bold()
                            }
                        }
                        .disabled(newRefreshURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRefreshing)
                    }
                }
                .navigationTitle("Refresh Link")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingRefreshSheet = false }
                    }
                }
            }
            #endif
        }
    }

    // MARK: - HLS Segment Details

    @ViewBuilder
    private var hlsSegmentsSection: some View {
        Section(header: Text("HLS Download")) {
            if isLoadingHLSSegments && hlsRecord == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading HLS details...")
                        .foregroundColor(.secondary)
                }
            } else if let record = hlsRecord {
                let downloaded = record.completedSegmentCount
                let total = max(0, record.totalSegments)
                let remaining = max(0, total - downloaded)
                let progressPercent: String = total > 0
                    ? String(format: "%.1f%%", record.downloadFraction * 100.0)
                    : "0.0%"
                let assemblyStatusText: String = {
                    switch record.assemblyState {
                    case .notStarted:
                        return "Waiting"
                    case .inProgress:
                        return "Assembling"
                    case .completed:
                        return "Completed"
                    case .failed:
                        return "Failed"
                    }
                }()

                DetailRow(label: "Segments Downloaded", value: "\(downloaded) / \(total)")
                DetailRow(label: "Remaining Segments", value: "\(remaining)")
                DetailRow(label: "Download Progress", value: progressPercent)
                DetailRow(label: "Assembly Status", value: assemblyStatusText)
            } else {
                Text("HLS segment checkpoints are unavailable for this transfer.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func loadHLSTransferRecord(for id: String) async {
        guard currentTransfer?.type == .hls else { return }
        if hlsRecord == nil {
            isLoadingHLSSegments = true
        }
        let record = await viewModel.hlsTransferRecord(for: id)
        guard !Task.isCancelled else { return }
        if record != hlsRecord {
            hlsRecord = record
        }
        isLoadingHLSSegments = false
    }

    private func monitorHLSTransferRecord(for id: String) async {
        guard currentTransfer?.type == .hls else { return }
        await loadHLSTransferRecord(for: id)

        while !Task.isCancelled {
            if let transfer = currentTransfer, transfer.isTerminal {
                break
            }
            if let record = hlsRecord, record.isTerminal {
                break
            }

            try? await Task.sleep(nanoseconds: 750_000_000)
            if Task.isCancelled { break }

            if let updatedRecord = await viewModel.hlsTransferRecord(for: id) {
                if updatedRecord != hlsRecord {
                    hlsRecord = updatedRecord
                }
                if updatedRecord.isTerminal {
                    break
                }
            }
        }
    }

    private func copyToClipboard(_ text: String, message: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        viewModel.showNotification(message)
    }

    private func priorityLabel(for priority: DownloadPriority) -> String {
        switch priority {
        case .low:
            return "Low"
        case .normal:
            return "Normal"
        case .high:
            return "High"
        }
    }

    private func checksumString(_ outcome: ChecksumOutcome) -> String {
        switch outcome {
        case .notChecked:
            return "Not Verified"
        case .verified(let sha):
            return "Verified (\(sha.prefix(8))...)"
        case .mismatch(let expected, _):
            return "Mismatch (Expected \(expected.prefix(8))...)"
        }
    }

    private func runChecksumVerification(for download: DownloadSnapshot) {
        guard !isCalculatingHash else { return }
        isCalculatingHash = true
        hashProgress = 0.0
        hashError = nil
        let url = download.destinationURL

        Task.detached(priority: .userInitiated) {
            do {
                let hash = try FileHasher.sha256(for: url) { progress in
                    Task { @MainActor in
                        self.hashProgress = progress
                    }
                }
                await MainActor.run {
                    self.calculatedHash = hash
                    self.isCalculatingHash = false
                }
            } catch {
                await MainActor.run {
                    self.hashError = "Verification error: \(error.localizedDescription)"
                    self.isCalculatingHash = false
                }
            }
        }
    }

    private func loadFiles(for infoHash: String) {
        isLoadingFiles = true
        Task { @MainActor in
            let fetched = await viewModel.fetchTorrentFiles(for: infoHash)
            self.torrentFiles = fetched
            self.isLoadingFiles = false
        }
    }

    private func loadTrackers(for infoHash: String) {
        isLoadingTrackers = true
        Task { @MainActor in
            let fetched = await viewModel.fetchTrackers(for: infoHash)
            self.torrentTrackers = fetched
            self.isLoadingTrackers = false
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
#endif
