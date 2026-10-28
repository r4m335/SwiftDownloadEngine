import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Thread-safe in-memory diagnostic logger for streaming download pipelines (HLS/DASH).
/// Keeps a bounded circular buffer (last 200 lines) and automatically redacts
/// sensitive authentication tokens, session cookies, and credentialed URL parameters.
public final class PipelineLogger: @unchecked Sendable, ObservableObject {
    public static let shared = PipelineLogger()

    public static let maxLogCount: Int = 200
    private let lock = NSLock()
    private var logs: [String] = []

    @Published public private(set) var entries: [String] = []

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    public init() {}

    /// Logs a raw message, applies redaction, appends to the circular buffer,
    /// and mirrors to standard output.
    public func log(_ rawMessage: String) {
        let redacted = Self.redact(rawMessage)
        let timestamp = Self.dateFormatter.string(from: Date())
        let formattedLine = "[\(timestamp)] \(redacted)"

        lock.lock()
        logs.append(formattedLine)
        if logs.count > Self.maxLogCount {
            logs.removeFirst(logs.count - Self.maxLogCount)
        }
        let snapshot = logs
        lock.unlock()

        print(formattedLine)

        DispatchQueue.main.async { [weak self] in
            self?.entries = snapshot
        }
    }

    /// Returns a snapshot of all currently stored log lines in chronological order.
    public func allLogs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return logs
    }

    /// Formats all stored log lines into a single newline-delimited string for sharing or clipboard export.
    public func formattedLogText() -> String {
        allLogs().joined(separator: "\n")
    }

    /// Clears all recorded log entries from memory.
    public func clear() {
        lock.lock()
        logs.removeAll()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.entries = []
        }
    }

    /// Redacts all sensitive authorization headers, cookies, and authentication query parameters.
    public static func redact(_ raw: String) -> String {
        var text = raw

        // 1. Redact Authorization headers: "Authorization: Bearer <token>" or "Authorization: <token>"
        if let authRegex = try? NSRegularExpression(pattern: #"(?i)(authorization\s*:\s*)(?:bearer\s+)?[^\r\n,;]+"#) {
            let range = NSRange(text.startIndex..., in: text)
            text = authRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1[REDACTED]")
        }

        // 2. Redact Cookie headers: "Cookie: ..." or "Set-Cookie: ..." or "cookies: [...]"
        if let cookieRegex = try? NSRegularExpression(pattern: #"(?i)((?:set-)?cookie\s*:\s*)[^\r\n]+"#) {
            let range = NSRange(text.startIndex..., in: text)
            text = cookieRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1[REDACTED]")
        }
        if let cookiesListRegex = try? NSRegularExpression(pattern: #"(?i)(cookies\s*:\s*\[)[^\]]+(\])"#) {
            let range = NSRange(text.startIndex..., in: text)
            text = cookiesListRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1REDACTED$2")
        }

        // 3. Redact common sensitive query parameters (?token=, &token=, ?sig=, &sig=, ?expires=, etc.)
        if let queryRegex = try? NSRegularExpression(pattern: #"(?i)([?&](?:token|sig|s|expires|key|auth|signature|session_id|session|hash|token_hash)=)[^&\s#"'>]+"#) {
            let range = NSRange(text.startIndex..., in: text)
            text = queryRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1REDACTED")
        }

        // 4. Redact bearer tokens in freeform strings
        if let bearerRegex = try? NSRegularExpression(pattern: #"(?i)(bearer\s+)[A-Za-z0-9\-_.]+"#) {
            let range = NSRange(text.startIndex..., in: text)
            text = bearerRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1[REDACTED]")
        }

        return text
    }
}

// MARK: - SwiftUI Diagnostic Log View

#if canImport(SwiftUI)
#if canImport(UIKit) && !os(watchOS)
public struct DiagnosticActivitySheet: UIViewControllerRepresentable {
    public let items: [Any]

    public init(items: [Any]) {
        self.items = items
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

/// Monospaced in-app diagnostic log viewer sheet with copy and share support,
/// and live active EngineConfiguration inspection for remote / Xcode-free debugging.
public struct DiagnosticLogView: View {
    public let configuration: EngineConfiguration
    @ObservedObject private var logger = PipelineLogger.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copiedAlert: Bool = false
    @State private var filterText: String = ""
    @State private var isShowingShareSheet: Bool = false
    @State private var isConfigExpanded: Bool = true

    public init(configuration: EngineConfiguration? = nil) {
        self.configuration = configuration ?? AppSettings.load().makeEngineConfiguration()
    }

    private var filteredEntries: [String] {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return logger.entries
        }
        return logger.entries.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var activeEngineConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation {
                    isConfigExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "cpu")
                        .foregroundColor(.blue)
                    Text("Active Engine Configuration")
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: isConfigExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isConfigExpanded {
                VStack(spacing: 6) {
                    configRow(title: "Max Concurrent Downloads", value: "\(configuration.maxConcurrentDownloads)")
                    configRow(title: "Max Global In-Flight Requests", value: "\(configuration.maxGlobalRequests)")
                    configRow(title: "Global Timeout", value: "\(Int(configuration.requestTimeoutSeconds))s req / \(Int(configuration.resourceTimeoutSeconds))s res")
                    configRow(title: "User-Agent", value: configuration.userAgent)
                    configRow(title: "Max Retry Attempts", value: "\(configuration.maxRetryAttempts)")
                    configRow(title: "Duplicate Naming Rule", value: configuration.duplicateNamingRule.rawValue)
                    configRow(title: "Cellular Usage", value: configuration.allowCellular ? "Allowed" : "Wi-Fi Only")
                    configRow(title: "Global Speed Limit", value: configuration.globalBandwidthLimitBytesPerSecond != nil ? "\(configuration.globalBandwidthLimitBytesPerSecond! / 1024) KB/s" : "Unlimited")
                    configRow(title: "Max Concurrent Torrents", value: "\(configuration.maxConcurrentTorrents)")
                    configRow(title: "Default Torrent Priority", value: "\(configuration.defaultTorrentPriority)")
                    configRow(title: "Default Seeding Behavior", value: "\(configuration.defaultSeedingPreference.mode.rawValue)")
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        #if canImport(UIKit)
        .background(Color(UIColor.secondarySystemBackground))
        #else
        .background(Color.secondary.opacity(0.1))
        #endif
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func configRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                activeEngineConfigurationCard
                Divider()
                if logger.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Pipeline Logs Recorded")
                            .font(.headline)
                        Text("Logs from [HLS Pipeline] and [DASH Pipeline] will appear here automatically when downloads are initiated.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundColor(.secondary)
                        TextField("Filter logs...", text: $filterText)
                            .font(.subheadline)
                        if !filterText.isEmpty {
                            Button {
                                filterText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(filteredEntries.count) / \(logger.entries.count)")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    #if canImport(UIKit)
                    .background(Color(UIColor.secondarySystemBackground))
                    #endif

                    Divider()

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(filteredEntries.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(lineColor(for: line))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        #if canImport(UIKit)
                                        .textSelection(.enabled)
                                        #endif
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id("logBottomID")
                            }
                            .padding(12)
                        }
                        #if canImport(UIKit)
                        .background(Color(UIColor.black))
                        #else
                        .background(Color.black)
                        #endif
                        .onAppear {
                            proxy.scrollTo("logBottomID", anchor: .bottom)
                        }
                    }
                }
            }
            .navigationTitle("Pipeline Diagnostics")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .confirmationAction) {
                    Button {
                        copyToClipboard()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    #if canImport(UIKit) && !os(watchOS)
                    Button {
                        isShowingShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    #endif

                    Menu {
                        Button(role: .destructive) {
                            logger.clear()
                        } label: {
                            Label("Clear Logs", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            #if canImport(UIKit) && !os(watchOS)
            .sheet(isPresented: $isShowingShareSheet) {
                DiagnosticActivitySheet(items: [logger.formattedLogText()])
            }
            #endif
            .alert("Copied to Clipboard", isPresented: $copiedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Pipeline diagnostic logs have been copied to your clipboard.")
            }
        }
    }

    private func lineColor(for entry: String) -> Color {
        if entry.localizedCaseInsensitiveContains("Error") || entry.localizedCaseInsensitiveContains("failed") {
            return .red
        }
        if entry.localizedCaseInsensitiveContains("Step 1b") {
            return .yellow
        }
        if entry.localizedCaseInsensitiveContains("Step 2") || entry.localizedCaseInsensitiveContains("succeeded") {
            return .green
        }
        #if canImport(UIKit)
        return Color(UIColor.systemGreen)
        #else
        return .green
        #endif
    }

    private func copyToClipboard() {
        #if canImport(UIKit)
        UIPasteboard.general.string = logger.formattedLogText()
        copiedAlert = true
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logger.formattedLogText(), forType: .string)
        copiedAlert = true
        #endif
    }
}
#endif
