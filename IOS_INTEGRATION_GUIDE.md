# Native iOS Application Integration Guide

This guide describes how to build, run, and validate the **SwiftDownloadEngine** download manager as a native iOS application on Apple platforms (macOS with Xcode 15/16+, iOS Simulator, or a physical iPhone).

---

## 1. Architectural Overview

The repository cleanly separates the underlying multi-worker transfer engine from the SwiftUI application presentation:

* **Engine Library (`DM_Reverse_engineering`)**: Multi-worker segmented range transfers, pause/resume offset recovery, priority queue scheduling, token-bucket bandwidth throttling, SHA-256 integrity verification, and persistent JSON manifest storage.
* **UI Layer (`Engine/UI/`)**: Complete SwiftUI user experience structured around a 4-tab navigation hierarchy coordinated by [DownloadManagerAppView](file:///c:/mini%20project/DM%20Reverse%20engineering/Engine/UI/DownloadManagerAppView.swift):
  1. **Downloads Tab (`DownloadsView`)**: Active/completed transfers, live speeds, ETA counters, segmented progress bars, and pause/resume/cancel/retry actions.
  2. **Browser Tab (`BrowserView`)**: Native WebKit browser (`WKWebView`) with unified address/search bar, navigation controls, loading progress, quick shortcuts, and direct download dispatch to the existing coordinator.
  3. **Add Download Tab (`AddDownloadView`)**: URL input, destination file name specification, worker count slider (1–16 workers), and immediate scheduling.
  4. **Settings Tab (`SettingsView`)**: Concurrency limits, global HTTP request limits, bandwidth cap configuration, manual queue manifest restoration, and persistent `UserDefaults` storage.
  * **Detail Inspection Screen (`DownloadDetailsView`)**: Pushed destination navigated to directly from any download row in the Downloads tab, showing byte-level chunk ranges, HTTP headers, hash validation results, and diagnostic metadata.
* **View Model (`DownloadManagerViewModel`)**: `@MainActor` state bridge conforming to `ObservableObject` with `@Published` properties that consumes `AsyncStream<DownloadEvent>` and automatically drives UI refreshes.
* **App Coordinator (`SwiftDownloadEngineApp`)**: Top-level `App` coordinator managing application sandbox directories, initial engine instantiation, single-restoration queue bootstrapping, and `.scenePhase` foreground/background transitions.
* **App Target Entry (`iOSApp/iOSAppEntry.swift`)**: Production entry point providing the `@main` attribute for the iOS application target and executing `SwiftDownloadEngineApp.main()`.

---

## 2. Launching in Xcode

### Method A: Open the Pre-Configured Xcode Project (Recommended)

The repository provides a ready-to-run Xcode project root bundle: `SwiftDownloadEngine.xcodeproj`.

1. Double-click `SwiftDownloadEngine.xcodeproj` to open the project in Xcode on macOS.
2. The project contains:
   * **App Target**: `SwiftDownloadEngine` (iOS 15.0+ deployment target).
   * **Entry Point**: `iOSApp/iOSAppEntry.swift`.
   * **Info.plist**: `iOSApp/Info.plist`.
   * **Package Dependency**: Pre-linked local `DM_Reverse_engineering` package product.
   * **Shared Scheme**: `SwiftDownloadEngine` pre-selected for building and debugging.
3. Select an iOS Simulator (e.g. **iPhone 15 Pro** or **iPhone 16**, iOS 17/18) or a connected physical iPhone.
4. Press **⌘R** (or click **Product > Run**). Xcode will resolve the local package, build the library, and launch the application.

### Method B: Manual Integration into an Existing Xcode Project

If integrating into an existing iOS workspace or container:
1. In Xcode: **File > New > Project... > iOS > App**. Name it `SwiftDownloadEngine`.
2. Add the local package as a dependency:
   * Select your project in the Project Navigator.
   * Under **Package Dependencies**, click **+ > Add Local...**.
   * Select the repository root folder containing `Package.swift`.
   * Link the `DM_Reverse_engineering` library product to the app target under **Frameworks, Libraries, and Embedded Content**.
3. Replace the template `*App.swift` with [iOSApp/iOSAppEntry.swift](file:///c:/mini%20project/DM%20Reverse%20engineering/iOSApp/iOSAppEntry.swift).
4. Set the build setting **Info.plist File** (`INFOPLIST_FILE`) to `iOSApp/Info.plist`.

### Method C: Automated Cloud Build & Artifact Packaging (GitHub Actions)

If developing without local macOS hardware, the repository includes an automated GitHub Actions cloud workflow: [`.github/workflows/ios-build.yml`](file:///c:/mini%20project/DM%20Reverse%20engineering/.github/workflows/ios-build.yml).

1. Runs on GitHub's hosted macOS runner (`macos-14`, Apple Silicon with Xcode 15/16).
2. Executes `swift test` on native Darwin runtime to validate package tests against Apple's Foundation framework.
3. Compiles the iOS application target (`SwiftDownloadEngine.app`) using `xcodebuild` targeting `generic/platform=iOS Simulator` with ad-hoc signing (`CODE_SIGNING_ALLOWED=NO`).
4. Compresses and uploads the resulting application bundle (`SwiftDownloadEngine.app`) as a downloadable zip artifact (`SwiftDownloadEngine-iOS-Simulator`) directly from the GitHub repository **Actions** tab.
5. Triggered automatically on push to `main` or manually via the **Run workflow** button.

---

## 3. Sandboxing & iOS Capabilities

To ensure proper file management, external app handoff, and network reliability on iOS, the application target utilizes settings defined in [iOSApp/Info.plist](file:///c:/mini%20project/DM%20Reverse%20engineering/iOSApp/Info.plist):

| Key | Value | Technical Justification |
| :--- | :--- | :--- |
| `UIFileSharingEnabled` | `YES` | Exposes the app's `Documents/Downloads` directory to the native **Files app** and iTunes/Finder file sharing. |
| `LSSupportsOpeningDocumentsInPlace` | `YES` | Enables third-party apps (e.g. media players, document viewers) to read downloaded files directly in place without making duplicate storage copies. |
| `BGTaskSchedulerPermittedIdentifiers` | `com.r4m335.SwiftDownloadEngine.continued-download` | Allows the iOS 26+ `BGContinuedProcessingTask` continuation submitted by an explicit foreground download action. Background HTTP URLSession remains the resilience path on earlier iOS versions. |
| `NSAppTransportSecurity` | `NSAllowsArbitraryLoads: YES` | Permits downloading files over plain HTTP (e.g. legacy mirrors, local intranet servers, test fixtures) in addition to HTTPS. |

### Sandbox Directory Locations:
* **Downloads Directory:** `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)/Downloads` (User-accessible in the Files app).
* **Persistent Store:** `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)/SwiftDownloadEngine` (Private application metadata and queue state).
* **Temporary Range Chunks:** `FileManager.default.temporaryDirectory` (Temporary byte buffers, purged upon assembly).

---

## 4. App Lifecycle & Background Execution Behavior

The top-level coordinator ([SwiftDownloadEngineApp](file:///c:/mini%20project/DM%20Reverse%20engineering/Engine/UI/SwiftDownloadEngineApp.swift)) coordinates engine operations with SwiftUI's `.scenePhase`:

### Single-Restoration Cold Launch Guard
* On application launch, when `scenePhase` first transitions to `.active`, the coordinator starts event observation (`viewModel.startObserving()`) and executes `viewModel.restoreQueue(autoStart: false)` once to reconstruct any incomplete or saved downloads from disk manifests.
* An internal state guard (`hasRestoredQueue = false`) ensures that subsequent transitions to `.active` (such as returning from the iOS App Switcher, Notification Center, or dismissible system dialogs) do **not** re-parse disk manifests or race with active transfers. Instead, subsequent foreground returns trigger `viewModel.refreshSnapshots()` for an immediate UI sync.

### In-Process Transfers vs. Background Sessions
* **Transfer Engine Architecture:** The engine coordinates multi-worker concurrent HTTP range chunking using direct-seek disk I/O (`URLSessionDataTask` / `FileHandle`). This achieves high download speeds and multi-connection saturation while the app is active in the foreground or executing within the operating system's background execution window.
* **App Suspension (`.background`):** When the user leaves the application, `SwiftDownloadEngineApp` immediately triggers `viewModel.refreshSnapshots()`, persisting current byte progress, segment states, and queue status to disk before the OS suspends the app process.
* **Continued processing:** On iOS 26 and later, an explicit foreground HTTP download may submit `BGContinuedProcessingTask` so the fast foreground engine can continue after backgrounding. The task reports progress and hands work back to background URLSession if it expires. Earlier iOS versions use background URLSession directly; no periodic fetch or processing mode is declared.
* **Important Distinction:** In iOS, in-process network streams are suspended by the kernel once the app process is suspended. True system daemon transfers (continuing indefinitely while the process is suspended) require `URLSessionConfiguration.background(withIdentifier:)` with single-task delegates. Because `SwiftDownloadEngine` uses segmented concurrent chunking for maximum speed, transfers seamlessly pause on OS suspension and reliably resume from their exact recorded byte offsets when foregrounded.

---

## 5. Verification on Apple Platforms

Once opened in Xcode, perform validation across both the iOS Simulator and physical hardware:

1. **Build & Launch on iOS Simulator (iPhone 15 / 16, iOS 17/18):**
   * Verify all 4 primary tabs render properly: *Downloads*, *Browser*, *Add*, and *Settings*.
   * Verify tapping an active or completed download navigates to the *Download Details* screen.
   * Verify in-app browser functionality in the *Browser* tab: navigate to a URL or search query, use navigation controls, and tap the download action button to pass the URL to the engine.
   * Add a test URL (e.g. `https://speed.hetzner.de/100MB.bin`) and observe live progress, multi-worker speed, and ETA calculations.
   * Verify interactive pause, resume, cancel, and retry controls.
2. **Physical iPhone Validation:**
   * Connect an iPhone via USB or Wi-Fi, select the target device in Xcode, and choose **Product > Run**.
   * Observe device memory usage and thermal performance (memory usage remains minimal due to direct-seek file writing without buffering entire files in RAM).
   * Open the **Files app > On My iPhone > LID Download Manager > Downloads** and verify completed files appear and open directly.
