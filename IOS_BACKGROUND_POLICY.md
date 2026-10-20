# iOS Background Execution & Lifecycle Policy

## 1. Executive Summary & Apple Platform Constraints

iOS enforces strict multitasking and background execution boundaries to preserve battery life, thermal headroom, and cellular data consumption. Under Apple's **App Store Review Guidelines (Guideline 2.5.4)**, apps are prohibited from executing continuous background networking unless they fit into officially recognized background modes (such as background audio playback, turn-by-turn navigation, VoIP signaling, or scheduled `BGProcessingTask`).

### The BitTorrent Protocol vs. iOS Background Architecture
- **Raw Socket Protocol:** BitTorrent requires continuous bidirectional TCP and uTP (UDP) socket connectivity, peer discovery (DHT/PEX/trackers), and piece exchange.
- **Incompatibility with `URLSessionConfiguration.background`:** Apple's system background download daemon (`nsurlsessiond`) only handles discrete HTTP/HTTPS transfers. It cannot execute custom native protocol engines (such as `libtorrent-rasterbar`) or maintain peer-to-peer swarms while the app process is suspended.
- **Policy on Audio/Location Workarounds:** Fabricating silent audio loops or continuous location polling to keep an app awake in the background violates Apple App Store policies and causes immediate app rejection.

---

## 2. Implemented Architecture in SwiftDownloadEngine

`SwiftDownloadEngine` implements an **honest, resilient, and bounded** lifecycle architecture designed specifically for Apple platforms:

### A. Bounded Background Grace Period (`beginBackgroundTask`) for Persistence Only
When the app transitions from the foreground to the background (`sceneDidEnterBackground` or `applicationDidEnterBackground`):
1. **Background Task Assertion:** The app acquires a temporary, bounded background execution window via `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)`.
2. **State & Resume-Data Generation:** The native engine triggers `post_session_save()` and writes fast-resume metadata (`.fastresume`), piece-completion bitfields, file-priority mappings, and queue manifests to disk.
3. **Graceful Engine Shutdown & Socket Suspension:** Active network connections and torrent transfers are cleanly paused, and the native torrent engine is stopped to prevent socket leaks, battery drain, and sudden process termination by iOS `jetsam`. **Torrent transfers do not continue in the background.**
4. **Guaranteed Bounded Completion:** Bounded background execution is used **strictly for state persistence**, completing well within the ~30-second operating system window before the background assertion is relinquished.

### B. Transparent Restoration on Activation
When the app returns to the foreground (`sceneWillEnterForeground` or `applicationDidBecomeActive`):
1. **Engine Relaunch & Port Binding:** The native libtorrent session verifies listening port availability across the configured range (default: `6881–6891`).
2. **State Reconciliation:** The `TorrentPersistenceStore` reloads the fast-resume cache and queue manifests, verifying file existence and piece hashes without rechecking unchanged payload blocks.
3. **Queue Promotion:** The `TorrentQueueScheduler` checks active slots against concurrency limits and automatically resumes eligible downloading torrents.
4. **UI Synchronization:** `DownloadManagerViewModel` synchronizes `UnifiedTransfer` snapshots to reflect active socket status and peer rates.

### C. HTTP Engine Lifecycle Status
- **Current Foreground / In-Process Transport:** HTTP downloads currently execute in-process via `URLSession.shared` using concurrent chunked streaming (`SegmentDownloader`). These transfers pause when the app is suspended by the operating system and resume from their recorded byte offsets upon foregrounding.
- **System-Managed Background HTTP Transport (Milestone 6A Implemented):** The background transport foundation is implemented behind a separate interface (`BackgroundDownloadSessionManager`). It provides `URLSessionConfiguration.background(withIdentifier:)`, persistent task-to-segment mappings (`BackgroundDownloadTaskMappingStore`), HTTP 206/Content-Range response validation (`BackgroundResponseValidator`), crash-safe atomic part-file relocation (`BackgroundDownloadFileHandler`), and launch reconciliation.
- **Download Coordinator Integration (Milestone 6B Pending):** Production downloads currently continue using the foreground transport. Routing eligible HTTP downloads through the background transport will be performed in Milestone 6B.

---

## 3. Comparison of Background Mechanisms

| Mechanism | Feasibility & Applicability | SwiftDownloadEngine Status | Apple Review Compliance |
|:---|:---|:---|:---|
| **Bounded Execution (`beginBackgroundTask`)** | Torrent & HTTP: Safe flush & state persistence only (up to ~30s) | **Implemented & Verified** | 100% Compliant |
| **`URLSession` Background Daemon** | HTTP only: Incompatible with BitTorrent raw socket swarms | **Milestone 6A Foundation Implemented** (Milestone 6B coordinator routing pending) | Compliant |
| **`BGAppRefreshTask` / `BGProcessingTask`** | Low: Non-deterministic batch maintenance when charging | Future exploration for queue maintenance | Fully Compliant |
| **Silent Audio / Location Workaround** | Prohibited for download managers | **Rejected & Excluded** | Violates Guideline 2.5.4 |

---

## 4. Verification & Milestone Status

- [x] Confirmed torrent transfers cleanly pause and engine stops upon background transition.
- [x] Verified bounded background execution is used exclusively for state persistence (fast-resume & manifests).
- [x] Verified corrupt fast-resume data falls back cleanly to storage verification without engine crashes.
- [x] Implemented Milestone 6A & 6A.1: Background HTTP session manager, persistent task mapping store, scoped task identity, segment-relative progress accounting, response validation, staged crash-safe part handling, corrupted manifest quarantine, reconciliation with DownloadPersistenceStore, and UIApplicationDelegate lifecycle integration.
- [ ] Milestone 6B: Download coordinator integration to route eligible production HTTP downloads through background transport.
