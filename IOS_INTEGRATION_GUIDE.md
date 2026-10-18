# Native iOS Application Integration Guide

This guide describes how to build, run, and validate the **SwiftDownloadEngine** download manager as a native iOS application on an Apple platform (macOS with Xcode 15/16+, iOS Simulator, or a physical iPhone).

---

## 1. Architectural Overview

The project is structured to maintain clean separation between the underlying transfer engine and the iOS user interface:

* **Engine Library (`DM_Reverse_engineering`)**: Multi-worker segmented range transfers, pause/resume offset recovery, priority queue scheduling, token-bucket bandwidth throttling, SHA-256 integrity verification, and persistent JSON storage.
* **UI Layer (`Engine/UI/` and `UI/`)**: Complete SwiftUI implementation featuring four integrated screens ([DownloadsView](file:///c:/mini%20project/DM%20Reverse%20engineering/Engine/UI/DownloadsView.swift), [AddDownloadView](file:///c:/mini%20project/DM%20Reverse%20engineering/Engine/UI/AddDownloadView.swift), [DownloadDetailsView](file:///c:/mini%20project/DM%20Reverse%20engineering/Engine/UI/DownloadDetailsView.swift), [SettingsView](file:///c:/mini%20project/DM%20Reverse%20engineering/Engine/UI/SettingsView.swift)) coordinated by [DownloadManagerAppView](file:///c:/mini%20project/DM%20Reverse%20engineering/Engine/UI/DownloadManagerAppView.swift).
* **View Model (`DownloadManagerViewModel`)**: `@MainActor` state bridge conforming to `ObservableObject` with `@Published` properties that consumes `AsyncStream<DownloadEvent>` and automatically triggers SwiftUI view redraws.
* **App Entry Point (`SwiftDownloadEngineApp` & `iOSAppEntry`)**: Top-level `App` coordinator managing application sandbox directories, initial engine instantiation, and `.scenePhase` foreground/background synchronization.

---

## 2. Launching in Xcode

### Method A: Direct Xcode Workspace Setup (Recommended)

1. Open Xcode on macOS: **File > New > Project...**
2. Select **iOS > App** and click **Next**.
   - **Product Name**: `SwiftDownloadEngine`
   - **Interface**: `SwiftUI`
   - **Language**: `Swift`
3. Save the project inside the repository root or adjacent to it.
4. Add the local package as a dependency:
   - Select your project in the Xcode Project Navigator.
   - Go to **Package Dependencies > + > Add Local...**
   - Select the `SwiftDownloadEngine` folder containing `Package.swift`.
   - Link the `DM_Reverse_engineering` library product to your App target under **Frameworks, Libraries, and Embedded Content**.
5. Replace the generated `YourApp.swift` with the provided [iOSApp/iOSAppEntry.swift](file:///c:/mini%20project/DM%20Reverse%20engineering/iOSApp/iOSAppEntry.swift):
   ```swift
   import SwiftUI
   import DM_Reverse_engineering

   @main
   struct iOSAppEntry {
       static func main() {
           SwiftDownloadEngineApp.main()
       }
   }
   ```
6. Replace or merge `Info.plist` with [iOSApp/Info.plist](file:///c:/mini%20project/DM%20Reverse%20engineering/iOSApp/Info.plist).

---

## 3. Sandboxing & iOS Capabilities

To ensure full functionality on an iPhone, the app requires specific configuration entries defined in [iOSApp/Info.plist](file:///c:/mini%20project/DM%20Reverse%20engineering/iOSApp/Info.plist):

| Key | Value | Purpose |
| :--- | :--- | :--- |
| `UIFileSharingEnabled` | `YES` | Exposes the app's `Documents/Downloads` folder to the native **Files app** on iOS. |
| `LSSupportsOpeningDocumentsInPlace` | `YES` | Allows other apps (VLC, Files, PDF viewers) to open downloaded files in place without duplication. |
| `UIBackgroundModes` | `fetch`, `processing` | Enables background task execution and transfer continuation. |
| `NSAppTransportSecurity` | `NSAllowsArbitraryLoads: YES` | Allows downloading files over standard HTTP or test networks in addition to HTTPS. |

### Sandbox Directory Locations:
* **Downloads Destination:** `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)/Downloads`
* **Persistent Store:** `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)/SwiftDownloadEngine`
* **Temporary Range Chunks:** `FileManager.default.temporaryDirectory` (automatically cleaned up upon segment merge).

---

## 4. App Lifecycle & Background Behavior

The native entry point ([SwiftDownloadEngineApp](file:///c:/mini%20project/DM%20Reverse%20engineering/Engine/UI/SwiftDownloadEngineApp.swift)) ties engine operations to SwiftUI's scene phases:

* **Foreground / Active (`.active`):**
  - Subscribes to `engine.events()` via `viewModel.startObserving()`.
  - Automatically invokes `viewModel.restoreQueue(autoStart: false)` to recover any interrupted transfers or persisted downloads from disk.
* **Background (`.background`):**
  - Calls `viewModel.refreshSnapshots()` to ensure state and byte metrics are flushed to persistent disk storage before the app is suspended.

---

## 5. Verification on Apple Platforms

Once loaded into Xcode, perform the following validation steps:

1. **Build & Launch on iOS Simulator (iPhone 15 / 16 Pro, iOS 17/18):**
   - Verify all 4 tabs display properly: *Downloads*, *Add*, *Settings*.
   - Add a test URL (e.g. `https://speed.hetzner.de/100MB.bin`) and check live progress, speed metrics, and ETA updates.
   - Test pause, resume, and cancellation.
2. **Physical iPhone Validation:**
   - Connect iPhone via USB/WiFi, select the device in Xcode, and choose **Run**.
   - Check device thermal profile, memory usage (should remain flat even during 100MB+ transfers due to direct-seek file writing), and background persistence.
   - Open the **Files app > On My iPhone > SwiftDownloadEngine > Downloads** and verify completed files appear and open directly.
