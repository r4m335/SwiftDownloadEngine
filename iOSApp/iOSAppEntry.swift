#if canImport(SwiftUI)
import SwiftUI
import DM_Reverse_engineering

/// Production entry point for the launchable iOS application target.
///
/// When opened in Xcode as an iOS App target (or built with xcodebuild), this entry point
/// executes `SwiftDownloadEngineApp.main()`, bootstrapping the segmented engine, persistent queue,
/// and full 4-screen SwiftUI interface.
@main
struct iOSAppEntry {
    static func main() {
        SwiftDownloadEngineApp.main()
    }
}
#endif
