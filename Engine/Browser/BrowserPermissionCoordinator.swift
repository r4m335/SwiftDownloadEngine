import Foundation

public enum BrowserPermissionType: String, Sendable, CaseIterable {
    case camera
    case microphone
    case cameraAndMicrophone
    case geolocation
    case deviceMotion
}

public enum BrowserPermissionDecisionResult: Equatable, Sendable {
    case grant
    case deny
    case prompt
}

public protocol BrowserPermissionProviding: AnyObject, Sendable {
    func requestPermission(
        type: BrowserPermissionType,
        originHost: String,
        frameURL: URL?,
        completionHandler: @escaping @Sendable (BrowserPermissionDecisionResult) -> Void
    )
}

public final class BrowserPermissionCoordinator: @unchecked Sendable {
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
