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


public struct DownloadMenuContent: View {
    public let download: DownloadSnapshot
    public let onOpen: () -> Void
    public let onSaveToFiles: () -> Void
    public let onShare: () -> Void
    public let onCopyLink: () -> Void
    public let onVerifyIntegrity: () -> Void
    public let onShowDetails: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onRetry: () -> Void
    public let onRestart: () -> Void
    public let onCancel: () -> Void
    public let onRemoveQueue: () -> Void
    public let onDeleteFile: () -> Void

    public init(
        download: DownloadSnapshot,
        onOpen: @escaping () -> Void = {},
        onSaveToFiles: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onVerifyIntegrity: @escaping () -> Void = {},
        onShowDetails: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onRestart: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        onRemoveQueue: @escaping () -> Void = {},
        onDeleteFile: @escaping () -> Void = {}
    ) {
        self.download = download
        self.onOpen = onOpen
        self.onSaveToFiles = onSaveToFiles
        self.onShare = onShare
        self.onCopyLink = onCopyLink
        self.onVerifyIntegrity = onVerifyIntegrity
        self.onShowDetails = onShowDetails
        self.onPause = onPause
        self.onResume = onResume
        self.onRetry = onRetry
        self.onRestart = onRestart
        self.onCancel = onCancel
        self.onRemoveQueue = onRemoveQueue
        self.onDeleteFile = onDeleteFile
    }

    public var body: some View {
        switch download.state {
        case .completed:
            Button(action: onOpen) {
                Label("Open File", systemImage: "doc.text")
            }
            Button(action: onSaveToFiles) {
                Label("Save to Files", systemImage: "folder")
            }
            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button(action: onCopyLink) {
                Label("Copy Download Link", systemImage: "doc.on.doc")
            }
            Button(action: onVerifyIntegrity) {
                Label("Verify Integrity", systemImage: "checkmark.shield")
            }
            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
            Button(role: .destructive, action: onDeleteFile) {
                Label("Delete File", systemImage: "trash")
            }

        case .downloading, .probing:
            Button(action: onPause) {
                Label("Pause", systemImage: "pause.fill")
            }
            Button(action: onCopyLink) {
                Label("Copy Download Link", systemImage: "doc.on.doc")
            }
            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onCancel) {
                Label("Cancel Transfer", systemImage: "xmark.circle")
            }
            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }

        case .paused:
            Button(action: onResume) {
                Label("Resume", systemImage: "play.fill")
            }
            Button(action: onCopyLink) {
                Label("Copy Download Link", systemImage: "doc.on.doc")
            }
            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
            Button(role: .destructive, action: onDeleteFile) {
                Label("Delete File", systemImage: "trash")
            }

        case .failed:
            if download.isNonResumable {
                Button(action: onRestart) {
                    Label("Restart Download", systemImage: "arrow.counterclockwise")
                }
            } else if download.isRateLimited {
                Button(action: onRetry) {
                    Label("Retry when eligible", systemImage: "clock.arrow.circlepath")
                }
            } else {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                }
            }
            Button(action: onCopyLink) {
                Label("Copy Download Link", systemImage: "doc.on.doc")
            }
            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
            Button(role: .destructive, action: onDeleteFile) {
                Label("Delete File", systemImage: "trash")
            }

        case .cancelled, .pending:
            if download.canResume {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                }
            }
            Button(action: onCopyLink) {
                Label("Copy Download Link", systemImage: "doc.on.doc")
            }
            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
            Button(role: .destructive, action: onDeleteFile) {
                Label("Delete File", systemImage: "trash")
            }
        }
    }
}

// MARK: - Vertical Three-Dot Action Icon

public struct VerticalThreeDotsButtonLabel: View {
    public init() {}

    public var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 32, height: 32)

            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .scaledFont(size: 14, weight: .bold)
                .foregroundColor(.primary)
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }
}

// MARK: - Unified Transfer Row View

private struct GradientTransferProgressBar: View {
    let progress: Double
    let isIndeterminate: Bool
    let gradientColors: [Color]
    let height: CGFloat

    @State private var shimmerOffset: CGFloat = -0.5

    init(progress: Double, isIndeterminate: Bool, gradientColors: [Color], height: CGFloat = 6) {
        self.progress = progress
        self.isIndeterminate = isIndeterminate
        self.gradientColors = gradientColors
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: height)

                if isIndeterminate {
                    Capsule()
                        .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(36, geo.size.width * 0.35), height: height)
                        .offset(x: shimmerOffset * geo.size.width)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                                shimmerOffset = 0.65
                            }
                        }
                } else {
                    let clamped = max(0.0, min(progress, 1.0))
                    Capsule()
                        .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(clamped > 0 ? height : 0, geo.size.width * clamped), height: height)
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: clamped)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

public struct UnifiedTransferRowView: View {
    public let viewModel: DownloadManagerViewModel
    public let transfer: UnifiedTransfer
    public var isSelectingMultiple: Bool
    public var isCompact: Bool = false
    public var onTapContent: (() -> Void)?
    public let onOpen: () -> Void
    public var onStreamOnline: () -> Void = {}
    public var onOpenInPlayer: () -> Void = {}
    public let onSaveToFiles: () -> Void
    public let onShare: () -> Void
    public let onCopyLink: () -> Void
    public let onShowDetails: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void
    public var onRetry: () -> Void = {}
    public var onUpdateLink: () -> Void = {}
    public var onRefreshFromBrowser: () -> Void = {}
    public let onRemoveQueue: () -> Void
    public let onDeleteFile: () -> Void

    public init(
        viewModel: DownloadManagerViewModel,
        transfer: UnifiedTransfer,
        isSelectingMultiple: Bool = false,
        isCompact: Bool = false,
        onTapContent: (() -> Void)? = nil,
        onOpen: @escaping () -> Void = {},
        onStreamOnline: @escaping () -> Void = {},
        onOpenInPlayer: @escaping () -> Void = {},
        onSaveToFiles: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onShowDetails: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onUpdateLink: @escaping () -> Void = {},
        onRefreshFromBrowser: @escaping () -> Void = {},
        onRemoveQueue: @escaping () -> Void = {},
        onDeleteFile: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.transfer = transfer
        self.isSelectingMultiple = isSelectingMultiple
        self.isCompact = isCompact
        self.onTapContent = onTapContent
        self.onOpen = onOpen
        self.onStreamOnline = onStreamOnline
        self.onOpenInPlayer = onOpenInPlayer
        self.onSaveToFiles = onSaveToFiles
        self.onShare = onShare
        self.onCopyLink = onCopyLink
        self.onShowDetails = onShowDetails
        self.onPause = onPause
        self.onResume = onResume
        self.onRetry = onRetry
        self.onUpdateLink = onUpdateLink
        self.onRefreshFromBrowser = onRefreshFromBrowser
        self.onRemoveQueue = onRemoveQueue
        self.onDeleteFile = onDeleteFile
    }

    public var body: some View {
        let content = VStack(alignment: .leading, spacing: isCompact ? 5 : 8) {
            // Header: Media Icon Badge, Name, clock icon, TypeBadge, UnifiedStatusBadge, and visible Three-Dot (⋮) Menu
            HStack(alignment: .center, spacing: isCompact ? 8 : 10) {
                if !isCompact {
                    transferIconBadge
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(transfer.name)
                            .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                            .lineLimit(1)

                        if viewModel.isScheduled(transferID: transfer.id) {
                            Image(systemName: "clock.fill")
                                .font(.caption2)
                                .foregroundColor(.indigo)
                        }
                    }

                    if !isCompact {
                        HStack(spacing: 5) {
                            TypeBadge(type: transfer.type)
                            UnifiedStatusBadge(state: transfer.state)
                        }
                    }
                }

                Spacer(minLength: 4)

                if isCompact {
                    TypeBadge(type: transfer.type)
                    UnifiedStatusBadge(state: transfer.state)
                }

                if !isSelectingMultiple {
                    quickActionCircleButton

                    StableTransferRowMenu(
                        transfer: transfer,
                        isScheduled: viewModel.isScheduled(transferID: transfer.id),
                        onOpen: onOpen,
                        onStreamOnline: onStreamOnline,
                        onOpenInPlayer: onOpenInPlayer,
                        onSaveToFiles: onSaveToFiles,
                        onShare: onShare,
                        onCopyLink: onCopyLink,
                        onShowDetails: onShowDetails,
                        onPause: onPause,
                        onResume: onResume,
                        onRetry: onRetry,
                        onUpdateLink: onUpdateLink,
                        onRefreshFromBrowser: onRefreshFromBrowser,
                        onToggleSchedule: { viewModel.toggleScheduled(transferID: transfer.id) },
                        onRemoveQueue: onRemoveQueue,
                        onDeleteFile: onDeleteFile
                    )
                    .equatable()
                }
            }

            // Sleek Gradient Progress Bar
            let isIndeterminate = (transfer.totalBytes ?? 0) <= 0 && transfer.state == .downloading
            GradientTransferProgressBar(
                progress: transfer.progressFraction,
                isIndeterminate: isIndeterminate,
                gradientColors: progressGradientColors,
                height: isCompact ? 4 : 6
            )

            // Metrics: Size & Speed
            HStack {
                if let total = transfer.totalBytes, total > 0 {
                    let totalStr: String = {
                        if transfer.isStreaming && transfer.state == .downloading {
                            return "~\(UIFormatters.formatBytes(total)) (Estimated)"
                        } else {
                            return UIFormatters.formatBytes(total)
                        }
                    }()
                    Text("\(UIFormatters.formatBytes(transfer.completedBytes)) / \(totalStr)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(UIFormatters.formatBytes(transfer.completedBytes)) (Size pending)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if transfer.state == .downloading {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                        if transfer.isTorrent {
                            Text("↓ \(UIFormatters.formatSpeed(transfer.downloadSpeedBytesPerSecond))  ↑ \(UIFormatters.formatSpeed(transfer.uploadSpeedBytesPerSecond))")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.blue)
                        } else {
                            Text(UIFormatters.formatSpeed(transfer.downloadSpeedBytesPerSecond))
                                .font(.caption.weight(.medium))
                                .foregroundColor(.blue)
                        }
                    }
                } else if transfer.state == .seeding {
                    Text("Seeding • ↑ \(UIFormatters.formatSpeed(transfer.uploadSpeedBytesPerSecond))")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.teal)
                } else {
                    Text("\(Int(transfer.progressFraction * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }

            // Extra metrics for torrent: Peers & Seeds (hidden in compact mode)
            if !isCompact && transfer.isTorrent {
                HStack {
                    Text("Peers: \(transfer.connectedPeers ?? 0) • Seeds: \(transfer.connectedSeeds ?? 0)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                    if let prio = transfer.torrentPriority {
                        Spacer()
                        Text("Priority: \(prioLabel(prio))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }

        Group {
            if isCompact {
                content
                    .padding(.vertical, 4)
            } else {
                content
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(statusColor.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTapContent?()
        }
        .contextMenu {
            UnifiedTransferMenuContent(
                transfer: transfer,
                isScheduled: viewModel.isScheduled(transferID: transfer.id),
                onOpen: onOpen,
                onStreamOnline: onStreamOnline,
                onOpenInPlayer: onOpenInPlayer,
                onSaveToFiles: onSaveToFiles,
                onShare: onShare,
                onCopyLink: onCopyLink,
                onShowDetails: onShowDetails,
                onPause: onPause,
                onResume: onResume,
                onRetry: onRetry,
                onUpdateLink: onUpdateLink,
                onRefreshFromBrowser: onRefreshFromBrowser,
                onToggleSchedule: { viewModel.toggleScheduled(transferID: transfer.id) },
                onRemoveQueue: onRemoveQueue,
                onDeleteFile: onDeleteFile
            )
        }
    }

    @ViewBuilder
    private var quickActionCircleButton: some View {
        if transfer.canPause {
            circularIconButton(icon: "pause.fill", color: .orange, label: "Pause \(transfer.name)", action: onPause)
        } else if transfer.canResume {
            circularIconButton(icon: "play.fill", color: .green, label: "Resume \(transfer.name)", action: onResume)
        } else if transfer.canRetry {
            circularIconButton(icon: "arrow.clockwise", color: .blue, label: "Retry \(transfer.name)", action: onRetry)
        } else if transfer.state == .completed {
            circularIconButton(icon: "arrow.up.forward.square", color: .blue, label: "Open \(transfer.name)", action: onOpen)
        }
    }

    private func circularIconButton(icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundColor(color)
            }
        }
        .buttonStyle(BorderlessButtonStyle())
        .accessibilityLabel(label)
    }

    private var transferIconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(statusColor.opacity(0.14))
                .frame(width: 38, height: 38)

            Image(systemName: iconNameForTransfer)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundColor(statusColor)
        }
    }

    private var iconNameForTransfer: String {
        switch transfer.type {
        case .torrent: return "arrow.triangle.2.circlepath"
        case .hls, .dash, .streaming: return "dot.radiowaves.left.and.right"
        case .http:
            return transfer.category.iconName
        }
    }

    private var progressGradientColors: [Color] {
        switch transfer.state {
        case .downloading: return [.blue, .cyan]
        case .completed: return [.green, .mint]
        case .paused: return [.orange, .yellow]
        case .failed: return [.red, .pink]
        case .queued: return [.gray, .secondary]
        case .seeding: return [.purple, .indigo]
        }
    }

    private func prioLabel(_ p: TorrentPriority) -> String {
        switch p {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }

    private var statusColor: Color {
        switch transfer.state {
        case .downloading: return .blue
        case .completed: return .green
        case .paused: return .orange
        case .failed: return .red
        case .queued: return .gray
        case .seeding: return .teal
        }
    }
}

// MARK: - Unified Transfer Menu Content

private struct StableTransferRowMenu: View, Equatable {
    let transfer: UnifiedTransfer
    let isScheduled: Bool
    let onOpen: () -> Void
    let onStreamOnline: () -> Void
    let onOpenInPlayer: () -> Void
    let onSaveToFiles: () -> Void
    let onShare: () -> Void
    let onCopyLink: () -> Void
    let onShowDetails: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRetry: () -> Void
    let onUpdateLink: () -> Void
    let onRefreshFromBrowser: () -> Void
    let onToggleSchedule: () -> Void
    let onRemoveQueue: () -> Void
    let onDeleteFile: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.transfer.id == rhs.transfer.id &&
        lhs.transfer.name == rhs.transfer.name &&
        lhs.transfer.state == rhs.transfer.state &&
        lhs.transfer.isTorrent == rhs.transfer.isTorrent &&
        lhs.isScheduled == rhs.isScheduled
    }

    var body: some View {
        Menu {
            UnifiedTransferMenuContent(
                transfer: transfer,
                isScheduled: isScheduled,
                onOpen: onOpen,
                onStreamOnline: onStreamOnline,
                onOpenInPlayer: onOpenInPlayer,
                onSaveToFiles: onSaveToFiles,
                onShare: onShare,
                onCopyLink: onCopyLink,
                onShowDetails: onShowDetails,
                onPause: onPause,
                onResume: onResume,
                onRetry: onRetry,
                onUpdateLink: onUpdateLink,
                onRefreshFromBrowser: onRefreshFromBrowser,
                onToggleSchedule: onToggleSchedule,
                onRemoveQueue: onRemoveQueue,
                onDeleteFile: onDeleteFile
            )
        } label: {
            VerticalThreeDotsButtonLabel()
        }
        .buttonStyle(BorderlessButtonStyle())
        .accessibilityLabel("Transfer actions for \(transfer.name)")
    }
}

public struct UnifiedTransferMenuContent: View {
    public let transfer: UnifiedTransfer
    public var isScheduled: Bool = false
    public let onOpen: () -> Void
    public var onStreamOnline: () -> Void = {}
    public var onOpenInPlayer: () -> Void = {}
    public let onSaveToFiles: () -> Void
    public let onShare: () -> Void
    public let onCopyLink: () -> Void
    public let onShowDetails: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void
    public var onRetry: () -> Void = {}
    public var onUpdateLink: () -> Void = {}
    public var onRefreshFromBrowser: () -> Void = {}
    public var onToggleSchedule: () -> Void = {}
    public let onRemoveQueue: () -> Void
    public let onDeleteFile: () -> Void

    public init(
        transfer: UnifiedTransfer,
        isScheduled: Bool = false,
        onOpen: @escaping () -> Void = {},
        onStreamOnline: @escaping () -> Void = {},
        onOpenInPlayer: @escaping () -> Void = {},
        onSaveToFiles: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onShowDetails: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onUpdateLink: @escaping () -> Void = {},
        onRefreshFromBrowser: @escaping () -> Void = {},
        onToggleSchedule: @escaping () -> Void = {},
        onRemoveQueue: @escaping () -> Void = {},
        onDeleteFile: @escaping () -> Void = {}
    ) {
        self.transfer = transfer
        self.isScheduled = isScheduled
        self.onOpen = onOpen
        self.onStreamOnline = onStreamOnline
        self.onOpenInPlayer = onOpenInPlayer
        self.onSaveToFiles = onSaveToFiles
        self.onShare = onShare
        self.onCopyLink = onCopyLink
        self.onShowDetails = onShowDetails
        self.onPause = onPause
        self.onResume = onResume
        self.onRetry = onRetry
        self.onUpdateLink = onUpdateLink
        self.onRefreshFromBrowser = onRefreshFromBrowser
        self.onToggleSchedule = onToggleSchedule
        self.onRemoveQueue = onRemoveQueue
        self.onDeleteFile = onDeleteFile
    }

    public var body: some View {
        Group {
            Button(action: onToggleSchedule) {
                Label(
                    isScheduled ? "Remove from Schedule" : "Add to Schedule",
                    systemImage: isScheduled ? "clock.badge.xmark" : "clock.badge"
                )
            }

            if transfer.canPause {
                Button(action: onPause) {
                    Label("Pause", systemImage: "pause.fill")
                }
            } else if transfer.canResume {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                }
            }

            if transfer.canRetry {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }

            if transfer.canRetry || transfer.canResume {
                Button(action: onUpdateLink) {
                    Label("Update Download Link", systemImage: "link")
                }
                if !transfer.isTorrent {
                    Button(action: onRefreshFromBrowser) {
                        Label("Refresh Link from Browser", systemImage: "safari")
                    }
                }
            }

            if transfer.state == .completed {
                Button(action: onOpen) {
                    Label("Open File", systemImage: "doc.text")
                }
                Button(action: onSaveToFiles) {
                    Label("Save to Files", systemImage: "folder")
                }
                Button(action: onShare) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            if transfer.destinationURL.isPlayableMedia || transfer.type == .hls || transfer.type == .dash {
                if URL(string: transfer.source) != nil || transfer.isTorrent {
                    Button(action: onStreamOnline) {
                        Label("Stream Online", systemImage: "play.tv")
                    }
                }
                if transfer.state != .completed {
                    Button(action: onOpenInPlayer) {
                        Label("Open in Player", systemImage: "play.circle")
                    }
                }
            }

            Button(action: onCopyLink) {
                Label(transfer.isTorrent ? "Copy Torrent Source" : "Copy Download Link", systemImage: "doc.on.doc")
            }

            Button(action: onShowDetails) {
                Label("Show Details", systemImage: "info.circle")
            }

            Divider()

            Button(action: onRemoveQueue) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }

            Button(role: .destructive, action: onDeleteFile) {
                Label("Delete Files from Disk", systemImage: "trash")
            }
        }
    }
}

// MARK: - Row View

public struct DownloadRowView: View {
    public let viewModel: DownloadManagerViewModel
    public let download: DownloadSnapshot
    public var isSelectingMultiple: Bool
    public var onTapContent: (() -> Void)?
    public let onOpen: () -> Void
    public var onStreamOnline: () -> Void = {}
    public var onOpenInPlayer: () -> Void = {}
    public let onSaveToFiles: () -> Void
    public let onShare: () -> Void
    public let onCopyLink: () -> Void
    public let onVerifyIntegrity: () -> Void
    public let onShowDetails: () -> Void
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onRetry: () -> Void
    public let onRestart: () -> Void
    public let onCancel: () -> Void
    public let onRemoveQueue: () -> Void
    public let onDeleteFile: () -> Void

    public init(
        viewModel: DownloadManagerViewModel,
        download: DownloadSnapshot,
        isSelectingMultiple: Bool = false,
        onTapContent: (() -> Void)? = nil,
        onOpen: @escaping () -> Void = {},
        onStreamOnline: @escaping () -> Void = {},
        onOpenInPlayer: @escaping () -> Void = {},
        onSaveToFiles: @escaping () -> Void = {},
        onShare: @escaping () -> Void = {},
        onCopyLink: @escaping () -> Void = {},
        onVerifyIntegrity: @escaping () -> Void = {},
        onShowDetails: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onRestart: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        onRemoveQueue: @escaping () -> Void = {},
        onDeleteFile: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.download = download
        self.isSelectingMultiple = isSelectingMultiple
        self.onTapContent = onTapContent
        self.onOpen = onOpen
        self.onStreamOnline = onStreamOnline
        self.onOpenInPlayer = onOpenInPlayer
        self.onSaveToFiles = onSaveToFiles
        self.onShare = onShare
        self.onCopyLink = onCopyLink
        self.onVerifyIntegrity = onVerifyIntegrity
        self.onShowDetails = onShowDetails
        self.onPause = onPause
        self.onResume = onResume
        self.onRetry = onRetry
        self.onRestart = onRestart
        self.onCancel = onCancel
        self.onRemoveQueue = onRemoveQueue
        self.onDeleteFile = onDeleteFile
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Filename, Status Badge, and visible Three-Dot (⋮) Menu
            HStack(alignment: .center, spacing: 8) {
                Text(download.destinationURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 4)

                StatusBadge(state: download.state)

                if !isSelectingMultiple {
                    Menu {
                        DownloadMenuContent(
                            download: download,
                            onOpen: onOpen,
                            onSaveToFiles: onSaveToFiles,
                            onShare: onShare,
                            onCopyLink: onCopyLink,
                            onVerifyIntegrity: onVerifyIntegrity,
                            onShowDetails: onShowDetails,
                            onPause: onPause,
                            onResume: onResume,
                            onRetry: onRetry,
                            onRestart: onRestart,
                            onCancel: onCancel,
                            onRemoveQueue: onRemoveQueue,
                            onDeleteFile: onDeleteFile
                        )
                    } label: {
                        VerticalThreeDotsButtonLabel()
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .accessibilityLabel("Download actions for \(download.destinationURL.lastPathComponent)")
                }
            }

            // Progress Bar
            ProgressView(value: download.progressFraction)
                .progressViewStyle(LinearProgressViewStyle(tint: statusColor))

            // Metrics: Size, Progress %, Speed, ETA
            HStack {
                Text("\(UIFormatters.formatBytes(download.completedBytes)) / \(download.totalBytes.map(UIFormatters.formatBytes) ?? "Unknown")")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if download.state == .downloading {
                    Text("\(UIFormatters.formatSpeed(download.currentBytesPerSecond)) • ETA: \(UIFormatters.formatTimeInterval(download.estimatedTimeRemaining))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(Int(download.progressFraction * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Quick Inline Action Controls
            HStack(spacing: 12) {
                if download.state == .downloading || download.state == .probing {
                    Button {
                        onPause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                } else if download.state == .paused {
                    Button {
                        onResume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                } else if download.state == .completed {
                    Button {
                        onOpen()
                    } label: {
                        Label("Open File", systemImage: "doc.text")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                } else if download.isFailed {
                    if download.isNonResumable {
                        Button {
                            onRestart()
                        } label: {
                            Label("Restart", systemImage: "arrow.counterclockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    } else if download.isRateLimited {
                        Button {
                            onRetry()
                        } label: {
                            Label("Retry when eligible", systemImage: "clock.arrow.circlepath")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                    } else {
                        Button {
                            onResume()
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                    }
                }

                if !download.isTerminal {
                    Button(role: .destructive) {
                        onCancel()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTapContent?()
        }
        .padding(.vertical, 4)
        .contextMenu {
            DownloadMenuContent(
                download: download,
                onOpen: onOpen,
                onSaveToFiles: onSaveToFiles,
                onShare: onShare,
                onCopyLink: onCopyLink,
                onVerifyIntegrity: onVerifyIntegrity,
                onShowDetails: onShowDetails,
                onPause: onPause,
                onResume: onResume,
                onRetry: onRetry,
                onRestart: onRestart,
                onCancel: onCancel,
                onRemoveQueue: onRemoveQueue,
                onDeleteFile: onDeleteFile
            )
        }
    }

    private var statusColor: Color {
        switch download.state {
        case .downloading, .probing:
            return .blue
        case .completed:
            return .green
        case .paused:
            return .orange
        case .failed:
            return .red
        case .cancelled, .pending:
            return .gray
        }
    }
}

// MARK: - Status Badge

public struct StatusBadge: View {
    public let state: DownloadState

    public var body: some View {
        Text(statusText)
            .font(.caption2.bold())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(backgroundColor.opacity(0.15))
            .foregroundColor(backgroundColor)
            .clipShape(Capsule())
    }

    private var statusText: String {
        switch state {
        case .pending: return "Queued"
        case .probing: return "Probing"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .pending: return .gray
        case .probing, .downloading: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Queue Summary Header & Download Status Counters

public typealias QueueStatsHeader = QueueSummaryHeader

extension DownloadFilter {
    public var accentColor: Color {
        switch self {
        case .all: return .primary
        case .active: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        case .liveRecordings: return .purple
        case .torrents: return .teal
        case .http: return .blue
        case .hls: return .indigo
        case .dash: return .cyan
        case .archived: return .gray
        }
    }
}

#endif
