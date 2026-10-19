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

### A. Bounded Background Grace Period (`beginBackgroundTask`)
When the app transitions from the foreground to the background (`sceneDidEnterBackground` or `applicationDidEnterBackground`):
1. **Background Task Assertion:** The app acquires a background execution window via `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)`.
2. **State & Resume-Data Generation:** The native engine triggers `post_session_save()` and writes fast-resume metadata (`.fastresume`), piece-completion bitfields, file-priority mappings, and queue manifests to disk.
3. **Graceful Socket Suspension:** Active network connections are cleanly paused or flushed to prevent socket leaks and avoid sudden process termination by iOS `jetsam`.
4. **Guaranteed Bounded Completion:** If the operating system signals that background time is expiring (`expirationHandler`), the pending flush is terminated immediately and the background assertion is relinquished.

### B. Transparent Restoration on Activation
When the app returns to the foreground (`sceneWillEnterForeground` or `applicationDidBecomeActive`):
1. **Engine Relaunch & Port Binding:** The native libtorrent session verifies listening port availability across the configured range (default: `6881–6891`).
2. **State Reconciliation:** The `TorrentPersistenceStore` reloads the fast-resume cache and queue manifests, verifying file existence and piece hashes without rechecking unchanged payload blocks.
3. **Queue Promotion:** The `TorrentQueueScheduler` checks active slots against concurrency limits and automatically resumes eligible downloading torrents.
4. **UI Synchronization:** `DownloadManagerViewModel` synchronizes `UnifiedTransfer` snapshots to reflect active socket status and peer rates.

---

## 3. Comparison of Background Mechanisms

| Mechanism | Feasibility for Torrent Downloads | SwiftDownloadEngine Status | Apple Review Compliance |
|:---|:---|:---|:---|
| **Bounded Execution (`beginBackgroundTask`)** | High (for safe flush & persistence up to 30s) | **Implemented & Verified** | 100% Compliant |
| **`URLSession` Background Daemon** | Not Applicable (HTTP only) | **Implemented for HTTP transfers** | 100% Compliant |
| **`BGAppRefreshTask` / `BGProcessingTask`** | Low (non-deterministic batch tasks when charging) | Future exploration for queue maintenance | Fully Compliant |
| **Silent Audio / Location Workaround** | Prohibited | **Rejected & Excluded** | Violates Guideline 2.5.4 |

---

## 4. Verification in Milestone 6

- [x] Tested graceful state persistence under bounded execution timeouts.
- [x] Verified that corrupt fast-resume data falls back cleanly to storage verification without engine crashes.
- [x] Confirmed zero lost piece data or corrupted file state after simulated app suspension and process relaunch.
- [x] Display honest session status in UI without claiming non-existent background transfers.
