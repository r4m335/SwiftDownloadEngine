import Foundation

#if canImport(WebKit)
import WebKit
#endif

public enum BrowserUserScriptInjectionTime: String, Codable, Sendable, Equatable {
    case atDocumentStart
    case atDocumentEnd

    #if canImport(WebKit)
    public var wkInjectionTime: WKUserScriptInjectionTime {
        switch self {
        case .atDocumentStart: return .atDocumentStart
        case .atDocumentEnd: return .atDocumentEnd
        }
    }
    #endif
}

public struct BrowserUserScript: Identifiable, Sendable, Equatable {
    public let id: String
    public let source: String
    public let injectionTime: BrowserUserScriptInjectionTime
    public let forMainFrameOnly: Bool

    public init(
        id: String = UUID().uuidString,
        source: String,
        injectionTime: BrowserUserScriptInjectionTime = .atDocumentStart,
        forMainFrameOnly: Bool = false
    ) {
        self.id = id
        self.source = source
        self.injectionTime = injectionTime
        self.forMainFrameOnly = forMainFrameOnly
    }
}

/// Generic User Script Manager capable of loading custom JavaScript strings
/// and injecting them into WKWebView at .atDocumentStart or .atDocumentEnd.
@MainActor
public final class BrowserUserScriptManager {
    public static let defaultURLResolutionScriptID = "defaultPlayerURLResolutionScript"

    /// Default user script loaded at .atDocumentStart to intercept and resolve
    /// dynamically signed media and segment URLs (e.g. signature and n-parameter transformation).
    public static var defaultURLResolutionScript: String {
        BrowserMediaDiscoveryScripts.defaultURLResolutionScript
    }

    private var scripts: [BrowserUserScript] = []

    public init(loadDefaultScript: Bool = true) {
        if loadDefaultScript {
            loadScript(
                Self.defaultURLResolutionScript,
                id: Self.defaultURLResolutionScriptID,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        }
    }

    public func loadDefaultURLResolutionScript() {
        loadScript(
            Self.defaultURLResolutionScript,
            id: Self.defaultURLResolutionScriptID,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    public func resetToDefaults() {
        scripts.removeAll()
        loadDefaultURLResolutionScript()
    }

    @discardableResult
    public func loadScript(
        _ source: String,
        id: String = UUID().uuidString,
        injectionTime: BrowserUserScriptInjectionTime = .atDocumentStart,
        forMainFrameOnly: Bool = false
    ) -> BrowserUserScript {
        let script = BrowserUserScript(
            id: id,
            source: source,
            injectionTime: injectionTime,
            forMainFrameOnly: forMainFrameOnly
        )
        scripts.removeAll { $0.id == id }
        scripts.append(script)
        return script
    }

    @discardableResult
    public func loadCustomScript(_ source: String, id: String = UUID().uuidString) -> BrowserUserScript {
        loadScript(source, id: id, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    public func registerScript(_ script: BrowserUserScript) {
        scripts.removeAll { $0.id == script.id }
        scripts.append(script)
    }

    @discardableResult
    public func unregisterScript(id: String) -> BrowserUserScript? {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else { return nil }
        return scripts.remove(at: idx)
    }

    @discardableResult
    public func removeScript(id: String) -> BrowserUserScript? {
        unregisterScript(id: id)
    }

    public func removeAllScripts() {
        scripts.removeAll()
    }

    public func allScripts() -> [BrowserUserScript] {
        return scripts
    }

    public func script(withID id: String) -> BrowserUserScript? {
        return scripts.first(where: { $0.id == id })
    }

    public func hasScript(id: String) -> Bool {
        return scripts.contains(where: { $0.id == id })
    }

    public var count: Int {
        return scripts.count
    }

    #if canImport(WebKit)
    public func inject(into configuration: WKWebViewConfiguration) {
        let current = allScripts()
        for script in current {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: script.source,
                    injectionTime: script.injectionTime.wkInjectionTime,
                    forMainFrameOnly: script.forMainFrameOnly
                )
            )
        }
    }

    public func install(on configuration: WKWebViewConfiguration) {
        inject(into: configuration)
    }
    #endif
}
