import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(WebKit)
import WebKit
#endif

public enum BrowserAuthDecision: Equatable, Sendable {
    case useSavedCredential(username: String)
    case useUserCredential(username: String)
    case cancelled
    case unsupportedMethod(String)
    case performDefaultHandling
}

public protocol BrowserAuthenticationProviding: AnyObject, Sendable {
    func promptForCredentials(
        host: String,
        realm: String?,
        completionHandler: @escaping @Sendable (String?, String?) -> Void
    )
}

public final class BrowserAuthenticationHandler: @unchecked Sendable {
    public static let shared = BrowserAuthenticationHandler()

    public weak var promptProvider: BrowserAuthenticationProviding?
    private let keychain: KeychainManager

    public init(keychain: KeychainManager = .shared, promptProvider: BrowserAuthenticationProviding? = nil) {
        self.keychain = keychain
        self.promptProvider = promptProvider
    }

    /// Evaluates an authentication challenge and produces a disposition and credential.
    public func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        targetPageURL: URL? = nil,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let authMethod = space.authenticationMethod

        // Server trust challenges must use default handling, never credentials
        if authMethod == "NSURLAuthenticationMethodServerTrust" {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Only handle HTTP Basic, Digest, and default HTTP auth methods
        guard authMethod == NSURLAuthenticationMethodHTTPBasic ||
              authMethod == NSURLAuthenticationMethodHTTPDigest ||
              authMethod == NSURLAuthenticationMethodDefault else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = space.host.lowercased()
        guard !host.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Never expose credentials to unrelated origins if targetPageURL is provided
        if let targetPageURL, let pageHost = targetPageURL.host?.lowercased() {
            if host != pageHost && !host.hasSuffix("." + pageHost) && !pageHost.hasSuffix("." + host) {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }

        // Check Keychain if this is the first attempt
        if challenge.previousFailureCount == 0 {
            if let saved = keychain.getInternetPassword(server: host, path: "/") {
                let credential = URLCredential(
                    user: saved.username,
                    password: saved.password,
                    persistence: .forSession
                )
                completionHandler(.useCredential, credential)
                return
            }
        }

        // If no saved credential or previous failure, request from user prompt provider if available
        guard let promptProvider else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        promptProvider.promptForCredentials(host: host, realm: space.realm) { [weak self] username, password in
            guard let self, let username, let password, !username.isEmpty else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            let isProxySpace: Bool
            #if canImport(FoundationNetworking)
            isProxySpace = space.isProxy()
            #else
            isProxySpace = space.isProxy
            #endif

            self.keychain.storeInternetPassword(
                username: username,
                password: password,
                server: host,
                protocolType: isProxySpace ? "http" : (space.port == 443 ? "https" : "http"),
                path: "/"
            )

            let credential = URLCredential(
                user: username,
                password: password,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        }
    }
}
