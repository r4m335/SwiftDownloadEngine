import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(SwiftUI)
import SwiftUI
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
    case blobCapture
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

/// Produces a comparison-ready, privacy-conscious snapshot of a navigation.
///
/// `WKNavigationResponse` exposes the final HTTP response but not its request,
/// so the coordinator retains the latest main-frame request and combines it
/// with this response snapshot.  Header values that commonly contain browser
/// credentials are redacted before reaching the diagnostic event store.
public enum BrowserNavigationDiagnosticDetails {
    private static let sensitiveHeaderNames: Set<String> = [
        "authorization", "cookie", "set-cookie", "proxy-authorization", "x-api-key"
    ]

    public static func requestDetails(_ request: URLRequest, isMainFrame: Bool) -> [String: String] {
        var details: [String: String] = [
            "requestURL": sanitizedURLString(request.url),
            "method": request.httpMethod ?? "GET",
            "isMainFrame": "\(isMainFrame)",
            "requestHeaders": formattedHeaders(request.allHTTPHeaderFields ?? [:])
        ]
        if let userAgent = header(named: "User-Agent", in: request.allHTTPHeaderFields) {
            details["userAgent"] = userAgent
        }
        if let range = header(named: "Range", in: request.allHTTPHeaderFields) {
            details["range"] = range
        }
        return details
    }

    public static func responseDetails(_ response: HTTPURLResponse) -> [String: String] {
        let headers = stringHeaders(response.allHeaderFields)
        var details: [String: String] = [
            "finalURL": sanitizedURLString(response.url),
            "statusCode": "\(response.statusCode)",
            "contentType": header(named: "Content-Type", in: headers) ?? response.mimeType ?? "unknown",
            "contentLength": header(named: "Content-Length", in: headers) ??
                (response.expectedContentLength >= 0 ? "\(response.expectedContentLength)" : "unknown"),
            "contentRange": header(named: "Content-Range", in: headers) ?? "none",
            "responseHeaders": formattedHeaders(headers)
        ]
        return details
    }

    public static func combinedDetails(
        request: URLRequest?,
        response: HTTPURLResponse
    ) -> [String: String] {
        var details = responseDetails(response)
        if let request {
            details.merge(requestDetails(request, isMainFrame: true), uniquingKeysWith: { _, requestValue in requestValue })
        } else {
            details["method"] = "unknown"
            details["isMainFrame"] = "true"
            details["requestHeaders"] = "unavailable"
        }
        return details
    }

    public static func failureDetails(request: URLRequest?, currentURL: URL?) -> [String: String] {
        var details = request.map { requestDetails($0, isMainFrame: true) } ?? [
            "method": "unknown",
            "isMainFrame": "true",
            "requestHeaders": "unavailable"
        ]
        details["finalURL"] = sanitizedURLString(currentURL ?? request?.url)
        return details
    }

    private static func stringHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { (String(describing: $0.key), String(describing: $0.value)) })
    }

    private static func header(named name: String, in headers: [String: String]?) -> String? {
        headers?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func formattedHeaders(_ headers: [String: String]) -> String {
        headers
            .map { key, value in
                let redacted = sensitiveHeaderNames.contains(key.lowercased()) ? "<redacted>" : value
                return "\(key): \(redacted)"
            }
            .sorted()
            .joined(separator: "\n")
    }

    private static func sanitizedURLString(_ url: URL?) -> String {
        guard let url else { return "unknown" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return url.absoluteString
        }
        components.queryItems = queryItems.map { item in
            let name = item.name.lowercased()
            if name.contains("token") || name.contains("signature") || name.contains("credential") || name.contains("key") {
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
            return item
        }
        return components.url?.absoluteString ?? url.absoluteString
    }
}

#if canImport(SwiftUI)
/// In-app viewer for browser navigation records. It intentionally exposes the
/// structured fields verbatim so support can compare browser implementations.
public struct BrowserDiagnosticLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var events: [BrowserDiagnosticEvent] = []

    public init() {}

    public var body: some View {
        NavigationView {
            Group {
                if events.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "ladybug").font(.largeTitle)
                        Text("No Browser Diagnostics")
                    }
                    .foregroundColor(.secondary)
                } else {
                    List(events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.message).font(.subheadline.weight(.semibold))
                            Text(event.timestamp, style: .time)
                                .font(.caption).foregroundColor(.secondary)
                            if !event.details.isEmpty {
                                Text(event.details.keys.sorted().map { key in
                                    "\(key): \(event.details[key] ?? "")"
                                }.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("Browser Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Refresh") { reloadEvents() }
                }
            }
            .onAppear(perform: reloadEvents)
        }
    }

    private func reloadEvents() {
        events = BrowserDiagnosticLogger.shared.events(limit: BrowserDiagnosticLogger.maximumEventCount)
    }
}
#endif

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
