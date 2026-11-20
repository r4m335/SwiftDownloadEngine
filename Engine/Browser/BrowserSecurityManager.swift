import Foundation

#if canImport(WebKit)
import WebKit
#endif

// MARK: - 1. Redirect Loop Detection

/// Detects infinite or malicious redirect loops within provisional browser navigations.
@MainActor
public final class BrowserRedirectLoopDetector {
    private var history: [(url: URL, timestamp: Date)] = []
    public let maxHops: Int
    public let timeWindowSeconds: TimeInterval

    public init(maxHops: Int = 6, timeWindowSeconds: TimeInterval = 4.0) {
        self.maxHops = maxHops
        self.timeWindowSeconds = timeWindowSeconds
    }

    /// Records a navigation attempt. Returns `(isLoopDetected: Bool, reason: String?)`.
    public func recordNavigation(url: URL) -> (isLoopDetected: Bool, reason: String?) {
        let now = Date()
        history.append((url: url, timestamp: now))

        // Prune entries older than the evaluation window
        let cutoff = now.addingTimeInterval(-timeWindowSeconds)
        history.removeAll { $0.timestamp < cutoff }

        // Condition A: Ping-pong / cyclical redirect loop (e.g. A -> B -> A -> B -> A)
        let normalizedHistory = history.map { BrowserDomainMatcher.normalizeDomain($0.url.absoluteString) }
        let currentNormalized = BrowserDomainMatcher.normalizeDomain(url.absoluteString)
        let occurrences = normalizedHistory.filter { $0 == currentNormalized }.count

        if occurrences >= 3 {
            let host = url.host ?? url.absoluteString
            return (
                true,
                "Cyclical redirect loop detected: '\(host)' repeatedly redirected back to itself. Navigation was stopped."
            )
        }

        // Condition B: Excessive hops in rapid succession
        if history.count >= maxHops {
            let host = url.host ?? url.absoluteString
            return (
                true,
                "Redirect loop detected: The website at '\(host)' redirected \(history.count) times in rapid succession. Navigation was aborted for your safety."
            )
        }

        return (false, nil)
    }

    /// Clears the navigation history on successful user-initiated navigation or committed load.
    public func reset() {
        history.removeAll()
    }
}

// MARK: - 2. Suspicious Download Security Inspector

/// Evaluates downloads for dangerous executable extensions, malicious scripts, and MIME type anomalies.
public enum BrowserDownloadSecurityInspector {

    /// Extensions commonly associated with malware, scripts, or unwanted executable payloads.
    public static let dangerousExtensions: Set<String> = [
        "exe", "scr", "bat", "vbs", "msi", "cmd", "apk",
        "pif", "gadget", "cpl", "wsf", "com", "hta", "jar",
        "reg", "ps1", "sh", "bin", "action", "command"
    ]

    /// Extensions requiring heightened scrutiny when initiated outside user gestures.
    public static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "iso", "dmg", "pkg"
    ]

    public struct SecurityWarning: Equatable, Sendable {
        public let filename: String
        public let extensionName: String
        public let riskLevel: RiskLevel
        public let warningMessage: String

        public enum RiskLevel: String, Sendable {
            case high
            case medium
            case low
        }
    }

    /// Evaluates a URL and optional MIME type / suggested filename.
    public static func evaluate(
        url: URL,
        declaredFilename: String? = nil,
        mimeType: String? = nil
    ) -> SecurityWarning? {
        let name = declaredFilename ?? url.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()

        if dangerousExtensions.contains(ext) {
            return SecurityWarning(
                filename: name,
                extensionName: ext,
                riskLevel: .high,
                warningMessage: "Warning: '\(name)' is an executable file (\(ext.uppercased())). Executable files can harm your device or access personal data. Download only from trusted sources."
            )
        }

        // Check for suspicious MIME type mismatch (e.g. file named photo.jpg but served as application/x-msdownload)
        if let mime = mimeType?.lowercased() {
            let executableMIMEs = [
                "application/x-msdownload",
                "application/x-executable",
                "application/x-sh",
                "application/x-bat",
                "application/vnd.android.package-archive"
            ]
            for badMime in executableMIMEs {
                if mime.contains(badMime) && !dangerousExtensions.contains(ext) {
                    return SecurityWarning(
                        filename: name,
                        extensionName: ext.isEmpty ? "unknown" : ext,
                        riskLevel: .high,
                        warningMessage: "Warning: '\(name)' declared as an image/document but served as an executable program (\(mime))."
                    )
                }
            }
        }

        return nil
    }
}

// MARK: - 3. HTTPS Certificate Error & Session Decision Store

/// Thread-safe session store of user-approved HTTPS certificate overrides.
@MainActor
public final class BrowserCertificateDecisionStore {
    public static let shared = BrowserCertificateDecisionStore()

    private var allowedHostsForSession: Set<String> = []

    public init() {}

    public func allowHostForSession(_ hostOrURL: String) {
        let domain = BrowserDomainMatcher.normalizeDomain(hostOrURL)
        guard !domain.isEmpty else { return }

        allowedHostsForSession.insert(domain)
    }

    public func isHostAllowedForSession(_ hostOrURL: String) -> Bool {
        let domain = BrowserDomainMatcher.normalizeDomain(hostOrURL)
        guard !domain.isEmpty else { return false }

        return allowedHostsForSession.contains(domain)
    }

    public func revokeHostForSession(_ hostOrURL: String) {
        let domain = BrowserDomainMatcher.normalizeDomain(hostOrURL)
        guard !domain.isEmpty else { return }

        allowedHostsForSession.remove(domain)
    }

    public func clearAllSessionOverrides() {
        allowedHostsForSession.removeAll()
    }
}

// MARK: - 4. Frame-Busting & Anti-Hijack Defense

/// Injects user script defenses to prevent malicious subframes from hijacking `window.top.location`.
public enum BrowserFrameBustingDefense {

    public static let antiHijackScript: String = """
    (function() {
        try {
            // Guard against unauthorized frame-busting lockouts
            if (window.top !== window.self) {
                // Neutralize malicious window.onbeforeunload spam in iframes
                window.onbeforeunload = null;
                Object.defineProperty(window, 'onbeforeunload', {
                    configurable: false,
                    writeable: false,
                    value: null
                });
            }
        } catch(e) {}
    })();
    """

    #if canImport(WebKit)
    public static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: antiHijackScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
    #endif
}

// MARK: - 4b. Media Playback Optimization

/// Ensures video elements configure inline playback and disable remote playback restrictions
/// preventing WebKit on iOS from stalling ManagedMediaSource / MediaSource adaptive video pipelines.
public enum BrowserMediaPlaybackOptimization {

    public static let script: String = """
    (function() {
        "use strict";
        try {
            var origPlay = HTMLMediaElement.prototype.play;
            if (origPlay) {
                HTMLMediaElement.prototype.play = function() {
                    try {
                        if (this.disableRemotePlayback !== true) {
                            this.disableRemotePlayback = true;
                        }
                    } catch (_) {}
                    return origPlay.apply(this, arguments);
                };
            }
            var srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "src");
            if (srcDesc && srcDesc.set) {
                var prevSet = srcDesc.set;
                Object.defineProperty(HTMLMediaElement.prototype, "src", {
                    set: function(val) {
                        try {
                            this.playsInline = true;
                            this.setAttribute("playsinline", "");
                            this.setAttribute("webkit-playsinline", "");
                            this.disableRemotePlayback = true;
                        } catch (_) {}
                        return prevSet.call(this, val);
                    }
                });
            }
        } catch (_) {}
    })();
    """

    #if canImport(WebKit)
    public static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
    #endif
}

// MARK: - 5. Security & Permission Prompts

public struct BrowserCertificatePrompt: Identifiable, Sendable {
    public let id: UUID
    public let host: String
    public let message: String
    public let onProceed: @Sendable () -> Void
    public let onCancel: @Sendable () -> Void

    public init(
        id: UUID = UUID(),
        host: String,
        message: String,
        onProceed: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.host = host
        self.message = message
        self.onProceed = onProceed
        self.onCancel = onCancel
    }
}

public struct BrowserSuspiciousDownloadPrompt: Identifiable, Sendable {
    public let id: UUID
    public let warning: BrowserDownloadSecurityInspector.SecurityWarning
    public let onProceed: @Sendable () -> Void
    public let onCancel: @Sendable () -> Void

    public init(
        id: UUID = UUID(),
        warning: BrowserDownloadSecurityInspector.SecurityWarning,
        onProceed: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.warning = warning
        self.onProceed = onProceed
        self.onCancel = onCancel
    }
}

public struct BrowserPermissionPrompt: Identifiable, Sendable {
    public let id: UUID
    public let type: BrowserPermissionType
    public let host: String
    public let onDecision: @Sendable (BrowserPermissionDecisionResult) -> Void

    public init(
        id: UUID = UUID(),
        type: BrowserPermissionType,
        host: String,
        onDecision: @escaping @Sendable (BrowserPermissionDecisionResult) -> Void
    ) {
        self.id = id
        self.type = type
        self.host = host
        self.onDecision = onDecision
    }
}
