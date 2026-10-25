import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Category of browser diagnostic events for troubleshooting navigation,
/// redirects, challenges, and runtime lifecycle errors.
public enum BrowserDiagnosticCategory: String, Codable, Sendable, CaseIterable {
    case navigation
    case redirect
    case challenge
    case javaScriptError
    case processTermination
    case cookie
    case policy
}

/// A structured diagnostic record capturing lifecycle events in the in-app browser.
public struct BrowserDiagnosticEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let tabID: UUID?
    public let category: BrowserDiagnosticCategory
    public let message: String
    public let url: URL?
    public let details: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        tabID: UUID? = nil,
        category: BrowserDiagnosticCategory,
        message: String,
        url: URL? = nil,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tabID = tabID
        self.category = category
        self.message = message
        self.url = url
        self.details = details
    }
}

/// Thread-safe logger and event store for browser diagnostic telemetry.
///
/// Records navigation transitions, redirects, challenge page lifecycle,
/// WebKit process termination, and observable page JavaScript errors without
/// logging sensitive request payloads or authentication tokens.
public final class BrowserDiagnosticLogger: @unchecked Sendable {
    public static let shared = BrowserDiagnosticLogger()

    public static let messageName = "browserDiagnostics"
    public static let maximumEventCount = 500

    private let lock = NSLock()
    private var events: [BrowserDiagnosticEvent] = []
    public var onEventLogged: ((BrowserDiagnosticEvent) -> Void)?

    public init() {}

    /// Records a diagnostic event in the thread-safe ring buffer.
    public func log(
        category: BrowserDiagnosticCategory,
        message: String,
        url: URL? = nil,
        tabID: UUID? = nil,
        details: [String: String] = [:]
    ) {
        let event = BrowserDiagnosticEvent(
            tabID: tabID,
            category: category,
            message: message,
            url: url,
            details: details
        )
        lock.lock()
        events.append(event)
        if events.count > Self.maximumEventCount {
            events.removeFirst(events.count - Self.maximumEventCount)
        }
        let callback = onEventLogged
        lock.unlock()

        callback?(event)
    }

    /// Retrieves all logged events matching the optional category and tabID filters.
    public func events(
        matching category: BrowserDiagnosticCategory? = nil,
        tabID: UUID? = nil,
        limit: Int = 100
    ) -> [BrowserDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }

        var filtered = events
        if let category {
            filtered = filtered.filter { $0.category == category }
        }
        if let tabID {
            filtered = filtered.filter { $0.tabID == tabID }
        }
        if filtered.count > limit {
            filtered = Array(filtered.suffix(limit))
        }
        return filtered
    }

    /// Clears the event buffer.
    public func clear() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// User script injected into pages to report unhandled JavaScript errors,
    /// promise rejections, and observable Cloudflare challenge lifecycle states.
    public static let diagnosticScript = #"""
    (function() {
        "use strict";
        if (window.__lidDiagnosticsInstalled) { return; }
        window.__lidDiagnosticsInstalled = true;

        var handler = window.webkit && window.webkit.messageHandlers &&
            window.webkit.messageHandlers.browserDiagnostics;
        if (!handler) { return; }

        function postDiag(category, message, details) {
            try {
                handler.postMessage({
                    category: category,
                    message: message,
                    url: window.location.href,
                    details: details || {}
                });
            } catch (_) {}
        }

        // Capture unhandled errors
        window.addEventListener("error", function(evt) {
            var msg = evt && evt.message ? String(evt.message) : "Unknown script error";
            var src = evt && evt.filename ? String(evt.filename) : "";
            var line = evt && evt.lineno ? String(evt.lineno) : "0";
            var col = evt && evt.colno ? String(evt.colno) : "0";
            postDiag("javaScriptError", "Unhandled JS error: " + msg, {
                filename: src,
                lineno: line,
                colno: col
            });
        }, true);

        // Capture unhandled promise rejections
        window.addEventListener("unhandledrejection", function(evt) {
            var reason = "Unknown promise rejection";
            if (evt && evt.reason) {
                try {
                    reason = typeof evt.reason === "string" ? evt.reason : JSON.stringify(evt.reason);
                } catch (_) {
                    reason = String(evt.reason);
                }
            }
            postDiag("javaScriptError", "Unhandled Promise Rejection: " + reason, {});
        }, true);

        // Detect Cloudflare / Turnstile challenge presence and lifecycle
        function checkChallengeState() {
            try {
                var isCF = document.getElementById("challenge-stage") !== null ||
                           document.getElementById("challenge-form") !== null ||
                           document.querySelector(".cf-turnstile-wrapper") !== null ||
                           document.querySelector("iframe[src*='challenges.cloudflare.com']") !== null ||
                           document.querySelector("iframe[src*='turnstile']") !== null;

                if (isCF) {
                    var title = document.title || "";
                    var bodyText = document.body ? document.body.innerText || "" : "";
                    var hasTokenStatus = bodyText.indexOf("Generating access token") !== -1 ||
                                         bodyText.indexOf("Verifying you are human") !== -1;

                    postDiag("challenge", "Cloudflare challenge detected", {
                        title: title,
                        hasTokenStatus: hasTokenStatus ? "true" : "false",
                        turnstileIframePresent: (document.querySelector("iframe[src*='cloudflare']") !== null) ? "true" : "false"
                    });
                }
            } catch (_) {}
        }

        if (document.readyState === "complete" || document.readyState === "interactive") {
            checkChallengeState();
        } else {
            document.addEventListener("DOMContentLoaded", checkChallengeState);
            window.addEventListener("load", checkChallengeState);
        }
    })();
    """#
}

#if canImport(WebKit)
/// WebKit script message handler that receives diagnostic events from `diagnosticScript`.
public final class BrowserDiagnosticWebKitHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    public let logger: BrowserDiagnosticLogger
    public let tabID: UUID?

    public init(logger: BrowserDiagnosticLogger = .shared, tabID: UUID? = nil) {
        self.logger = logger
        self.tabID = tabID
        super.init()
    }

    public func install(on configuration: WKWebViewConfiguration) {
        let script = WKUserScript(
            source: BrowserDiagnosticLogger.diagnosticScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(self, name: BrowserDiagnosticLogger.messageName)
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BrowserDiagnosticLogger.messageName,
              let dict = message.body as? [String: Any] else {
            return
        }

        let categoryRaw = dict["category"] as? String ?? "javaScriptError"
        let category = BrowserDiagnosticCategory(rawValue: categoryRaw) ?? .javaScriptError
        let msg = dict["message"] as? String ?? ""
        let urlString = dict["url"] as? String
        let url = urlString.flatMap { URL(string: $0) }
        let details = dict["details"] as? [String: String] ?? [:]

        logger.log(
            category: category,
            message: msg,
            url: url,
            tabID: tabID,
            details: details
        )
    }
}
#endif
