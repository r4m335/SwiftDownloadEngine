import Foundation
#if canImport(UIKit)
import UIKit

/// Centralized manager for application interface orientation lifecycle.
/// Enforces portrait orientation across the app while allowing the full-screen
/// media player to freely rotate and toggles orientations dynamically without reloading media.
@MainActor
public final class LIDOrientationManager: ObservableObject {
    public static let shared = LIDOrientationManager()

    /// Indicates whether the media player is currently active and allowed to rotate.
    public var isPlayerActive: Bool = false

    /// The active orientation preference applied to the player.
    public private(set) var activeOrientationPreference: LIDPlayerOrientationPreference = .auto

    public init() {}

    /// Restores the app interface to portrait orientation upon player dismissal.
    public func restorePortrait(session: String = "IDLE") {
        self.isPlayerActive = false
        #if os(iOS)
        if #available(iOS 16.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let windowScene = scenes.first {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
                    PipelineLogger.shared.logPlayer(
                        session: session,
                        category: "OrientationManager",
                        message: "requestGeometryUpdate(.portrait) notice: \(error.localizedDescription)"
                    )
                }
                UIViewController.attemptRotationToDeviceOrientation()
            }
        } else {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
        PipelineLogger.shared.logPlayer(
            session: session,
            category: "OrientationManager",
            message: "Restored portrait orientation on player dismissal"
        )
        #endif
    }

    /// Toggles orientation between portrait and landscape during media playback.
    public func toggleOrientation(session: String = "IDLE") {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let windowScene = scenes.first {
                let isLandscape = windowScene.interfaceOrientation.isLandscape
                let targetMask: UIInterfaceOrientationMask = isLandscape ? .portrait : .landscapeRight
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: targetMask)) { error in
                    PipelineLogger.shared.logPlayer(
                        session: session,
                        category: "OrientationManager",
                        message: "toggleOrientation notice: \(error.localizedDescription)"
                    )
                }
                UIViewController.attemptRotationToDeviceOrientation()
            }
        } else {
            let isLandscape = UIDevice.current.orientation.isLandscape
            let targetOrientation = isLandscape ? UIInterfaceOrientation.portrait.rawValue : UIInterfaceOrientation.landscapeRight.rawValue
            UIDevice.current.setValue(targetOrientation, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
        PipelineLogger.shared.logPlayer(
            session: session,
            category: "OrientationManager",
            message: "Toggled player orientation"
        )
        #endif
    }

    /// Requests landscape orientation for player launch when preferred.
    public func requestLandscape(session: String = "IDLE") {
        self.isPlayerActive = true
        #if os(iOS)
        if #available(iOS 16.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let windowScene = scenes.first {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                    PipelineLogger.shared.logPlayer(
                        session: session,
                        category: "OrientationManager",
                        message: "requestLandscape notice: \(error.localizedDescription)"
                    )
                }
                UIViewController.attemptRotationToDeviceOrientation()
            }
        } else {
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
        PipelineLogger.shared.logPlayer(
            session: session,
            category: "OrientationManager",
            message: "Requested landscape orientation for player"
        )
        #endif
    }

    /// Requests portrait orientation for player launch when preferred.
    public func requestPortrait(session: String = "IDLE") {
        self.isPlayerActive = true
        #if os(iOS)
        if #available(iOS 16.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let windowScene = scenes.first {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
                    PipelineLogger.shared.logPlayer(
                        session: session,
                        category: "OrientationManager",
                        message: "requestPortrait notice: \(error.localizedDescription)"
                    )
                }
                UIViewController.attemptRotationToDeviceOrientation()
            }
        } else {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
        PipelineLogger.shared.logPlayer(
            session: session,
            category: "OrientationManager",
            message: "Requested portrait orientation for player"
        )
        #endif
    }

    /// Applies the configured orientation policy upon player launch.
    public func applyOrientationPreference(_ preference: LIDPlayerOrientationPreference, session: String = "IDLE") {
        self.isPlayerActive = true
        self.activeOrientationPreference = preference
        switch preference {
        case .auto:
            #if os(iOS)
            if #available(iOS 16.0, *) {
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                if let windowScene = scenes.first {
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown)) { _ in }
                    UIViewController.attemptRotationToDeviceOrientation()
                }
            } else {
                UIViewController.attemptRotationToDeviceOrientation()
            }
            #endif
            PipelineLogger.shared.logPlayer(session: session, category: "OrientationManager", message: "Applied auto sensor orientation policy")
        case .landscape:
            requestLandscape(session: session)
        case .portrait:
            requestPortrait(session: session)
        }
    }
}
#else
@MainActor
public final class LIDOrientationManager: ObservableObject {
    public static let shared = LIDOrientationManager()
    public var isPlayerActive: Bool = false
    public var activeOrientationPreference: LIDPlayerOrientationPreference = .auto
    public init() {}
    public func restorePortrait(session: String = "IDLE") {}
    public func applyOrientationPreference(_ preference: LIDPlayerOrientationPreference, session: String = "IDLE") {}
    public func toggleOrientation(session: String = "IDLE") {}
}
#endif
