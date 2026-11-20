import Foundation

public enum BrowserPermissionType: String, Sendable, CaseIterable, Codable {
    case camera
    case microphone
    case cameraAndMicrophone
    case geolocation
    case deviceMotion
}

public enum BrowserPermissionDecisionResult: String, Equatable, Sendable, Codable {
    case grant = "grant"
    case deny = "deny"
    case prompt = "prompt"
}

public protocol BrowserPermissionProviding: AnyObject, Sendable {
    func requestPermission(
        type: BrowserPermissionType,
        originHost: String,
        frameURL: URL?,
        completionHandler: @escaping @Sendable (BrowserPermissionDecisionResult) -> Void
    )
}

@MainActor
public final class BrowserPermissionCoordinator {
    public static let shared = BrowserPermissionCoordinator()

    public weak var provider: BrowserPermissionProviding?

    public init(provider: BrowserPermissionProviding? = nil) {
        self.provider = provider
    }

    public func decidePermission(
        type: BrowserPermissionType,
        originHost: String,
        frameURL: URL?,
        completionHandler: @escaping @Sendable (BrowserPermissionDecisionResult) -> Void
    ) {
        guard let provider else {
            // NEVER silently grant permissions; the default must strictly be deny.
            completionHandler(.deny)
            return
        }
        provider.requestPermission(
            type: type,
            originHost: originHost,
            frameURL: frameURL,
            completionHandler: completionHandler
        )
    }
}
