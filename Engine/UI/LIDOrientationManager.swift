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

    public init() {}

    /// Restores the app interface to portrait orientation upon player dismissal.
    public func restorePortrait() {
        self.isPlayerActive = false
        #if os(iOS)
        if #available(iOS 16.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let windowScene = scenes.first {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
                    PipelineLogger.shared.logPlayer(
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
}
#endif
