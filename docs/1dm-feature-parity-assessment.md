# 1DM+ Feature Parity Assessment: LID Download Manager vs. Android 1DM+

**Repository:** `r4m335/SwiftDownloadEngine`  
**Application:** LID Download Manager (iOS)  
**Reference Application:** Android 1DM+ (1DM: Browser & Video / Torrent Downloader)  
**Baseline Commit:** `7d73a8bddf81b0ae09e3f25241387b48d8bba26f`  
**Date of Assessment:** November 2026  

---

## 1. Executive Summary & Parity Statistics

This assessment evaluates the degree of feature parity between **LID Download Manager (iOS)** and **1DM+ (Android)** across 7 core functional categories.

### 1.1 Methodology & Strict Classification Criteria
Each capability is classified under one of six unambiguous statuses:
- **`Complete`**: Fully implemented in code, validated by automated CI test suites, and architecturally complete.
- **`Partial`**: Core engine capability or partial UI exists, but user-facing controls, options, or workflows are incomplete.
- **`Untested`**: Code is present in the repository, but lacks dedicated automated regression tests or end-to-end verification.
- **`Missing`**: Feature is present in Android 1DM+ but completely absent in LID.
- **`iOS Restricted`**: Blocked or severely constrained by Apple's sandboxing, background execution policies, or network extension entitlements.
- **`Not Applicable`**: Android-specific platform idiosyncrasies that have no equivalent on iOS.

> **Important Testing Distinction:** While 45 features are verified through automated unit and integration tests running on macOS/Linux CI, **real-world AVFoundation audio/video playback and physical hardware behaviors have not yet been validated on a physical iPhone**. Device builds confirm arm64 compilation and linking, but physical hardware execution remains to be performed.

### 1.2 Parity Breakdown

| Status | Count | Percentage |
|---|:---:|:---:|
| **Complete** | 45 | 63.4% |
| **Partial** | 6 | 8.5% |
| **Untested** | 1 | 1.4% |
| **Missing** | 16 | 22.5% |
| **iOS Restricted** | 3 | 4.2% |
| **Total Features Evaluated** | **71** | **100.0%** |

```
[█████████████████████████████████████████░░░░░░░░░░░░░░░░░░] 63.4% Complete
```

---

## 2. Category-by-Category Feature Parity Matrix

### Category 1: Download Engine & Network Core

| # | Feature | 1DM+ Android Reference | LID Status | Code Evidence | Test Evidence | Gaps & Platform Limitations |
|---|---|---|:---:|---|---|---|
| 1 | Multi-Part Segmented HTTP Downloads | Up to 32 concurrent threads per download; dynamic range slicing | **Complete** | `AdaptiveSegmentWorkQueue.swift`, `SegmentAllocator.swift`, `SegmentDownloader.swift`, `DownloadCoordinator.swift` | `AdaptiveSegmentWorkQueueTests.swift`, `SegmentAllocatorTests.swift`, `EndToEndHTTPRangeTests.swift` | Fully functional up to 32 threads. Allocates segments dynamically and reassembles parts into final file. |
| 2 | Dynamic Work Stealing & Rebalancing | Reallocates trailing slow chunks to idle connections in real time | **Complete** | `AdaptiveSegmentWorkQueue.swift:stealWork()`, `SegmentDownloader.swift` | `AdaptiveSegmentWorkQueueTests.test04_WorkStealing()` | Tested with synthetic range servers. |
| 3 | Pause, Resume & State Recovery | Resumes interrupted downloads using HTTP `Range`, `ETag`, and `Last-Modified` | **Complete** | `DownloadCoordinator.swift:resumeDownload()`, `DownloadPersistence.swift` | `PauseResumeAndRecoveryTests.swift`, `DownloadPersistenceTests.swift` | Atomic `.tmp` segment storage; validates 206 Partial Content vs 200 OK. |
| 4 | Automatic Retries & Exponential Backoff | Retries dropped connections with jittered backoff | **Complete** | `HTTPRetryPolicy.swift`, `HTTPRetryPolicyConfiguration` | `HTTPRetryPolicyTests.swift` | Retries on network drops, HTTP 503, 504, 429. Configurable in AppSettings. |
| 5 | Download Scheduling | Starts and stops downloads at configured times, days of week, and Wi-Fi conditions | **Complete** | `Engine/Scheduling/ScheduleCoordinator.swift`, `ScheduleRule.swift` | `ScheduleCoordinatorTests.swift` | Manages scheduled queues, start/stop timers, and local notifications. |
| 6 | Queue Priority Management | Concurrency caps (1–10) with High/Normal/Low priority queues | **Complete** | `DownloadQueueManager.swift`, `PriorityDownloadQueue` | `DownloadQueueManagerTests.swift` | Prioritizes downloads dynamically; preempts lower-priority items when limits are reached. |
| 7 | Speed Throttling & Bandwidth Limits | Global and per-task speed limits in KB/s | **Complete** | `BandwidthLimiter.swift`, `AppSettings.globalSpeedLimitKBps`, `AddDownloadView.speedLimitKBps` | `ResourceThrottlingTests.swift` | Token-bucket byte pacing algorithm. |
| 8 | Large File Handling (>4GB) | Downloads 10GB+ files without memory pressure | **Complete** | `DownloadFileWriter.swift`, `Int64` range offsets | `EndToEndHTTPRangeTests.swift`, `DownloadFileWriterTests.swift` | 64-bit offsets, zero whole-file memory buffering, direct streaming writes. |
| 9 | Expired Link Refresh | Updates expired tokenized URLs while keeping existing partial chunks | **Complete** | `DownloadCoordinator.swift:refreshDownload()`, `DownloadDetailsView.swift` | `DownloadCoordinatorTests.testRefreshDownloadLink()` | Probes new URL, verifies ETag/Content-Length consistency, and updates URL. |
| 10 | Background HTTP Execution | Continuous segmented downloads when app is closed or locked | **iOS Restricted** | `BackgroundHTTPTransport.swift`, `BackgroundDownloadTaskMappingStore.swift` | `BackgroundHTTPTransportTests.swift`, `BackgroundCoordinatorIntegrationTests.swift` | **iOS Constraint:** iOS suspends socket connections. Background downloads must delegate to `nsurlsessiond`, which does not allow dynamic multi-connection socket stealing while suspended. |
| 11 | Batch Downloads (Pattern URLs) | Pattern-based link expansion (e.g. `image[001-100].jpg`) | **Missing** | None | None | 1DM+ enables downloading numbered series via URL bracket syntax. Not implemented in LID. |
| 12 | Batch Link Import (Text / Clipboard) | Multi-URL import from `.txt`, clipboard, or HTML files | **Missing** | `AddDownloadView.swift` (single link only) | None | LID only imports one link at a time. |
| 13 | Auto-Start Toggle on Add | User option to queue without starting immediately | **Complete** | `AddDownloadView.swift:autoStart`, `DownloadEngine.addDownload()` | `DownloadManagerViewModelTests.swift` | Present in UI and respected by the coordinator. |
| 14 | Checksum & File Integrity Validation | SHA-256 verification and post-download hash matching | **Complete** | `MediaIntegrityValidator.swift`, `DownloadsView.swift:verifyIntegrity()` | `MediaIntegrityValidatorTests.swift` | Background checksum computation with progress report and mismatch alerting. |

---

### Category 2: Integrated Web Browser & Media Discovery

| # | Feature | 1DM+ Android Reference | LID Status | Code Evidence | Test Evidence | Gaps & Platform Limitations |
|---|---|---|:---:|---|---|---|
| 15 | Multi-Tab Web Browser | Tab switcher, multi-tab session management | **Complete** | `BrowserView.swift`, `BrowserTabs.swift:BrowserTabManager` | `BrowserTests.swift`, `BrowserNavigationTests.swift` | Dynamic tab creation, per-tab webview sessions, tab switcher grid. |
| 16 | Media Sniffing & Asset Detection | Intercepts video, audio, and media streams from HTML5 elements and network requests | **Complete** | `BrowserMediaDiscoveryBridge.swift`, `BrowserMediaCandidateClassifier.swift` | `BrowserMediaDiscoveryTests.swift`, `BrowserMediaCandidateTests.swift` | Injects JavaScript observers for `<video>`, `<audio>`, `fetch()`, `XMLHttpRequest`, and URL regex patterns. |
| 17 | Download Decision Pipeline | Routes media candidates to direct, streaming, blob, MSE, or DRM paths | **Complete** | `BrowserDownloadDecisionPipeline.swift` | `BrowserDownloadDecisionPipelineTests.swift`, `BrowserToDownloadWorkflowTests.swift` | Automatically classifies `.direct`, `.streaming`, `.blobExport`, `.mseCapture`, `.protectedMedia`. |
| 18 | Request Context & Cookie Preservation | Preserves `Cookie`, `Referer`, and `User-Agent` from the browser page | **Complete** | `BrowserRequestContext.swift`, `DownloadRequestEnricher.swift` | `DownloadRequestEnricherTests.swift`, `BrowserToDownloadWorkflowTests.swift` | Strips Referer on HTTPS->HTTP downgrade; extracts WKHTTPCookieStore session cookies. |
| 19 | Built-in Ad Blocker | Rule-based element hiding and ad network blocking | **Missing** | None | None | 1DM+ includes a full ad blocker. LID currently has no `WKContentRuleListStore` integration. |
| 20 | Popup Blocker | Blocks aggressive popups and redirect loops | **Missing** | None | None | No JavaScript `window.open` interception or suppression rules. |
| 21 | Desktop Mode (User-Agent Switcher) | Per-tab toggle to request desktop version of sites | **Missing** | `AppSettings.swift` (global UA only) | None | LID has a global UA setting, but lacks a per-tab "Request Desktop Site" quick toggle. |
| 22 | Incognito / Private Browsing Mode | Ephemeral browsing with zero history or cookie persistence | **Missing** | None | None | Needs `WKWebsiteDataStore.nonPersistent()` implementation for isolated tabs. |
| 23 | Bookmarks & History Management | Hierarchical folders, bookmark export/import, searchable history | **Partial** | `BrowserViewModel.bookmarks` (rudimentary array) | `BrowserTests.swift` | Lacks folder hierarchy, history persistence store, search, and import/export. |
| 24 | Search Engine Selector | DuckDuckGo, Google, Bing, Yahoo, Startpage, Ecosia | **Complete** | `BrowserURLResolver.swift`, `BrowserSearchEngine` | `BrowserTests.swift` | Configurable in browser address bar. |
| 25 | Webpage Offline Saving | Save complete webpage as MHTML or WebArchive | **Missing** | None | None | 1DM+ allows offline page saves. Not implemented. |

---

### Category 3: Streaming Media Downloads (HLS, DASH, Blob, MSE)

| # | Feature | 1DM+ Android Reference | LID Status | Code Evidence | Test Evidence | Gaps & Platform Limitations |
|---|---|---|:---:|---|---|---|
| 26 | HLS Master & Media Playlist Parsing | Parses multivariant playlists, EXT-X-BYTERANGE, EXT-X-KEY | **Complete** | `HLSManifestParser.swift`, `StreamingDownloadOrchestrator.swift` | `StreamingManifestTests.swift`, `HLSLifecycleTests.swift` | Supports RFC 8216 HLS specs, discrete video/audio renditions. |
| 27 | HLS AES-128 Segment Decryption | Decrypts encrypted segments using fetched keys and initialization vectors | **Complete** | `HLSSegmentDecryptor.swift` | `HLSSegmentDecryptorTests.swift` | AES-128-CBC software decryptor using Apple `CryptoKit` / `CommonCrypto`. |
| 28 | DASH MPD Manifest Parsing | Parses XML MPD manifests, SegmentTemplate, SegmentTimeline, SegmentList | **Complete** | `DASHManifestParser.swift`, `DASHTransferPlanner.swift` | `StreamingManifestTests.swift`, `DASHTransferPlannerTests.swift` | Supports multi-period and separated adaptation sets. |
| 29 | Stream Reconstruction & Muxing | Demuxes and multiplexes separate video and audio tracks into MP4 | **Complete** | `MediaAssembler.swift`, `HLSVODReconstruction.swift`, `DASHVODReconstruction.swift` | `MediaAssemblerTests.swift`, `HLSVODReconstructionTests.swift`, `DASHVODReconstructionTests.swift` | **Testing Gap:** Compiles and muxes via `AVAssetWriter` on Apple platforms; synthetic parser tests pass. Real-world physical playback on an iPhone hardware screen remains unverified. |
| 30 | Stream Quality / Resolution Picker Modal | Interactive sheet displaying resolutions (1080p, 720p, 480p, Audio) | **Partial** | `HLSVariantSelection.swift:HLSVariantSelector` | `HLSVariantSelectionTests` | Engine has variant ranking and preference filtering, but the UI automatically selects highest quality without showing an interactive selection dialog to the user. |
| 31 | Browser Blob URL Export | Transfers `blob:` URLs out of WKWebView via memory-bounded chunks | **Complete** | `BrowserBlobCaptureService.swift`, `BlobExportWriter.swift` | `BrowserBlobCaptureServiceTests.swift`, `BrowserBlobCaptureStabilityTests.swift` | 256 KB chunking, SHA-256 rolling verification, handles WebContent crashes, persists staging. |
| 32 | MediaSource Extensions (MSE) Interception | Hooks `SourceBuffer.appendBuffer` to capture media streams | **Complete** | `BrowserMSECapturePrototype.swift`, `BrowserMediaDiscoveryBridge.swift` | `BrowserMSECapturePrototypeTests.swift`, `BrowserMSERealWorldValidationTests.swift` | Early-append capture, track separation, representation switch rejection. |
| 33 | Live Stream Recording | Captures continuous live broadcasts to local file | **Untested** | `StreamingDownloadOrchestrator.swift` (VOD oriented) | None | Architecture is optimized for VOD (fixed duration manifests). Live sliding-window capture is untested and unverified. |
| 34 | DRM Media Detection & Guidance | Rejects FairPlay, Widevine, PlayReady with clear user explanation | **Complete** | `BrowserDownloadDecisionPipeline.swift:protectedMedia` | `BrowserDownloadDecisionPipelineTests.swift` | Upfront interception avoids hanging downloads on encrypted DRM content. |
| 35 | Sniffer File Type & MIME Filtering | Filters captured media by extensions and MIME prefixes | **Complete** | `SettingsView.swift`, `BrowserViewModel.mediaCandidates` | `AppSettingsTests.swift`, `BrowserToDownloadWorkflowTests.swift` | Excludes raw `.ts` / `.m4s` fragments; lets user specify allowed formats. |

---

### Category 4: BitTorrent & Swarm Capabilities

| # | Feature | 1DM+ Android Reference | LID Status | Code Evidence | Test Evidence | Gaps & Platform Limitations |
|---|---|---|:---:|---|---|---|
| 36 | Native BitTorrent Engine Core | C++ engine with DHT, PeX, LSD, and uTP support | **Complete** | `TorrentEngine.swift`, `LibTorrent.xcframework` (libtorrent 2.0 rasterbar) | `TorrentEngineTests.swift`, `TorrentSessionBridgeTests.swift` | Real arm64 native binary compiled via CI; pure Swift mock fallback for non-Darwin. |
| 37 | Magnet Link Resolution & Parsing | Resolves `magnet:?xt=urn:btih:` and extracts trackers/names | **Complete** | `Engine/Browser/MagnetLink.swift`, `TorrentEngine.swift:addTorrent(magnetURI:)` | `MagnetLinkTests.swift`, `TorrentEngineTests.swift` | Robust parsing of BTIH (hex & base32), display names, and tracker lists. |
| 38 | `.torrent` File Import & Decoding | Bencoded metadata decoding and file selection | **Complete** | `TorrentModels.swift`, `AddDownloadView.swift:.fileImporter` | `TorrentModelsTests.swift` | Uses native iOS file importer for `.torrent` files. |
| 39 | Multi-File Torrent Selection & Priorities | Select individual files to download or skip; set priority per file | **Complete** | `TorrentSessionBridge.mm:setFilePriority()`, `DownloadManagerViewModel.swift` | `TorrentSessionBridgeTests.swift` | Priorities: High, Normal, Skip (0). |
| 40 | Torrent Queue & Concurrency Management | Limits active torrents to prevent bandwidth saturation | **Complete** | `TorrentQueueScheduler.swift`, `AppSettings.maxConcurrentTorrents` | `TorrentQueueSchedulerTests.swift` | Manages active vs queued torrent transfers based on user settings. |
| 41 | Seeding Policies (Ratio & Duration) | Stops seeding when ratio or time threshold is reached | **Complete** | `TorrentModels.swift:SeedingPreference`, `TorrentQueueScheduler.swift` | `TorrentQueueSchedulerTests.swift` | Modes: `doNotSeed`, `ratio`, `duration`, `indefinitely`. |
| 42 | Fast-Resume Persistence | Saves resume data so torrents do not re-check on relaunch | **Complete** | `TorrentPersistenceStore.swift` | `TorrentPersistenceTests.swift` | Serializes and restores resume data. |
| 43 | Sequential Download Mode | Prioritizes head and tail pieces to allow streaming while downloading | **Missing** | None | None | 1DM+ supports sequential piece downloading. Not exposed in LID torrent engine. |
| 44 | Swarm Tracker Management | View, add, update, and re-announce trackers | **Missing** | None | None | Magnet trackers are passed at addition time, but no interactive tracker list or editing UI exists. |
| 45 | Swarm Diagnostics (Peers, Pieces Map) | Visual piece map and peer IP/client list | **Partial** | `UnifiedTransfer.connectedPeers`, `connectedSeeds` | `UnifiedTransferTests.swift` | Peer counts are shown, but detailed peer inspection table and graphical piece map are absent. |
| 46 | Create / Make `.torrent` Files | Generate `.torrent` from local files with custom trackers | **Missing** | None | None | Present in 1DM+ desktop/Android tools; not implemented in LID. |
| 47 | Indefinite Background Seeding | Continues seeding torrents while app is closed | **iOS Restricted** | `ScheduleCoordinator.torrentBackgroundLimitationMessage` | None | **iOS Constraint:** iOS forbids raw socket listeners in the background. Torrent engine pauses shortly after app backgrounding. |

---

### Category 5: File Management & Storage

| # | Feature | 1DM+ Android Reference | LID Status | Code Evidence | Test Evidence | Gaps & Platform Limitations |
|---|---|---|:---:|---|---|---|
| 48 | Unified Downloads List Screen | Consolidated list of HTTP, Torrent, and Stream transfers | **Complete** | `DownloadsView.swift`, `DownloadItemRowView` | `DownloadsViewInteractionTests.swift` | Clean SwiftUI list with badges, speeds, progress, and context menus. |
| 49 | In-App Media & Document Preview | QuickLook and AVPlayer integration for completed files | **Complete** | `FilePreviewView.swift:FilePreviewController`, `FilePreviewContainerView` | `DownloadsViewInteractionTests.swift` | Supports videos, audio, images, PDFs, and text without leaving app. Includes floating "Done" button. |
| 50 | Share Sheet & "Save to Files" | System share sheet and UIDocumentPicker export | **Complete** | `DownloadsView.swift:ActiveSheet.saveToFiles`, `ActiveSheet.shareFile` | `DownloadsViewInteractionTests.swift` | Exports downloads to external locations or other apps via `UIActivityViewController`. |
| 51 | File Deletion (List vs Disk) | Option to remove from list only or delete file from storage | **Complete** | `DownloadsView.swift:activeAlert = .deleteConfirmation` | `DownloadsViewInteractionTests.swift` | User chooses whether to delete physical file from disk. |
| 52 | File Renaming | Rename downloaded files from the UI | **Complete** | `DownloadDetailsView.swift`, `DownloadPersistence.swift` | `DownloadDetailsViewTests` | Updates filename on disk and in database records. |
| 53 | Custom Categories & Subfolders | Automatic routing by type (Videos, Music, Docs) to custom folders | **Partial** | `DownloadFilter` (status filters: All, Active, Paused, Completed, Failed) | `DownloadManagerViewModelTests.swift` | Filter bar filters by transfer state, but does not provide MIME-type categorization (Video/Audio/Docs) or custom destination folder mapping. |
| 54 | In-App Archive Extraction (ZIP/RAR/7z) | Extract compressed archives directly inside the app | **Missing** | None | None | 1DM+ has built-in unzipper. Not implemented in LID. |
| 55 | Secure File Vault / Password Protection | Password-protected or hidden download folder | **Missing** | None | None | Present in 1DM+. Not implemented in LID. |
| 56 | Storage Thresholds & Disk Space Monitoring | Enforces free disk reserve and aborts if space is low | **Complete** | `BrowserBlobCaptureService.swift:limits.minimumFreeDiskBytes` | `BrowserBlobCaptureStabilityTests.swift` | Verifies available volume storage before initiating large staging operations. |

---

### Category 6: User Experience & Automation

| # | Feature | 1DM+ Android Reference | LID Status | Code Evidence | Test Evidence | Gaps & Platform Limitations |
|---|---|---|:---:|---|---|---|
| 57 | Real-time Speed, Progress, and ETA | Instantaneous throughput, byte counts, and completion ETA | **Complete** | `DownloadSpeedTracker.swift`, `UIFormatters.swift` | `DownloadCoordinatorTests.swift` | Formatted cleanly with rolling average window. |
| 58 | Multi-Select & Batch Actions | Long-press to select multiple items for bulk pause, resume, delete | **Complete** | `DownloadsView.swift:isSelectingMultiple`, `selectedIDs`, `showBulkDeleteAlert` | `DownloadsViewInteractionTests.swift` | Allows bulk deletion and queue control. |
| 59 | Clipboard Link Sniffing & Prompt Banner | Auto-detects URLs copied to clipboard and shows download banner | **Complete** | `DownloadsView.swift:checkClipboardForURL()`, `UIPasteboard.general.detectPatterns` | `DownloadsViewInteractionTests.swift` | Checks clipboard on foregrounding with iOS 14+ pattern detection. |
| 60 | Completion Notifications | System banner and sound when download finishes | **Complete** | `DownloadManagerViewModel.swift`, `UNUserNotificationCenter` | `DownloadManagerViewModelTests.swift` | Sends local notifications on download completion. |
| 61 | Search & Filter Bar | Search downloads by name; filter by active/paused/finished | **Complete** | `DownloadsView.swift:.searchable`, `FilterBar` | `DownloadsViewInteractionTests.swift` | Real-time name search and filter chips. |
| 62 | Real-time Bandwidth Speed Graph | Visual line chart displaying speed history over time | **Missing** | None | None | 1DM+ displays a live speed graph in notifications and UI. Not implemented in LID. |
| 63 | Dark / Light Theme Support | Follows system dark/light mode with native colors | **Complete** | Native SwiftUI color system (`Color.primary`, `Color.platformSecondaryBackground`) | `DownloadsViewInteractionTests.swift` | Adapts automatically to iOS dark/light appearance. |
| 64 | Download Sorting Options | Sort downloads by date, name, size, type, or speed | **Partial** | Default chronological sort | None | No UI picker to reorder items by name, file size, or speed. |

---

### Category 7: Advanced Capabilities & Security

| # | Feature | 1DM+ Android Reference | LID Status | Code Evidence | Test Evidence | Gaps & Platform Limitations |
|---|---|---|:---:|---|---|---|
| 65 | Hardware-Backed Keychain Storage | Stores sensitive server logins and proxy passwords securely | **Complete** | `Engine/Security/KeychainManager.swift`, `kSecClassInternetPassword` | `KeychainManagerTests.swift` | Encrypted in iOS Secure Enclave / Keychain; never stored in plaintext AppSettings. |
| 66 | Cellular Data Gating (Wi-Fi Only) | Global toggle to restrict downloads to Wi-Fi | **Complete** | `AppSettings.allowCellular`, `NetworkConnectivityGate.swift` | `DownloadURLPolicyTests.swift` | Rejects cellular transfers when disabled. |
| 67 | Pipeline Diagnostics & Debug Logging | Redacted diagnostic logs for HLS, DASH, and network pipelines | **Complete** | `PipelineLogger.swift`, `BrowserDiagnostics.swift`, `SettingsView.swift:showingDiagnostics` | `CloudflareVerificationDiagnosticTests.swift` | In-memory ring buffer with token/cookie redaction for safe debugging. |
| 68 | Queue Manifest Backup & Restore | Export/import download queue to a portable file | **Partial** | `DownloadPersistenceStore.swift`, `SettingsView:restoreQueue` | `DownloadPersistenceTests.swift` | Can restore automatically from disk, but lacks manual export/import of queue JSON/text file. |
| 69 | Custom Proxy Configuration (HTTP/SOCKS5) | Route downloads through custom HTTP or SOCKS5 proxy | **Missing** | `SettingsView.swift` (keychain server entry only) | None | **iOS Constraint:** System proxy settings apply by default; custom proxy routing at the `URLSessionConfiguration` level is not wired into the engine. |
| 70 | Battery Saver / Low Power Auto-Pause | Automatically pause downloads when battery falls below threshold | **Missing** | None | None | Present in 1DM+ settings. Not implemented in LID. |
| 71 | In-App Web Server (Wi-Fi Sharing to PC) | Access downloaded files from desktop browser over local Wi-Fi | **Missing** | None | None | 1DM+ includes a local HTTP server for PC file transfers. Not implemented in LID. |

---

## 3. Critical Architectural Differences & Platform Constraints

Understanding the architectural divergence between Android and iOS is critical for establishing realistic parity expectations:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        iOS Platform Constraints                        │
├────────────────────────────┬───────────────────────────────────────────┤
│ WKWebView Out-of-Process   │ Unlike Android WebView, WKWebView runs in │
│ Sandboxing                 │ an isolated process. Video streams cannot │
│                            │ be intercepted via local socket proxies.  │
│                            │ Solution: Injected JS sniffers & MSE hook │
├────────────────────────────┼───────────────────────────────────────────┤
│ Background Process         │ iOS suspends third-party apps after ~30s. │
│ Suspension                 │ Multi-connection chunked HTTP engines     │
│                            │ cannot run arbitrary TCP loops in BG.     │
│                            │ Solution: nsurlsessiond delegation        │
├────────────────────────────┼───────────────────────────────────────────┤
│ BitTorrent Sockets in      │ Apple forbids raw TCP/UDP listen sockets  │
│ Background                 │ while backgrounded (no VoIP entitlement). │
│                            │ Solution: Foreground download/local notif │
├────────────────────────────┼───────────────────────────────────────────┤
│ App Sandbox File System    │ Downloads reside in app container. Export │
│                            │ requires UIDocumentPickerViewController.  │
└────────────────────────────┴───────────────────────────────────────────┘
```

1. **WKWebView Sandboxing:**  
   In Android 1DM+, the browser engine runs in-process or allows local HTTP proxying to intercept all media requests. In iOS, `WKWebView` runs in an out-of-process daemon (`com.apple.WebKit.WebContent`). LID overcomes this through injected JavaScript bridges (`BrowserMediaDiscoveryBridge`, `BrowserBlobCaptureService`, and `BrowserMSECapturePrototype`).

2. **Background Execution Policy:**  
   Android allows foreground services with persistent status-bar notifications that keep CPU and network sockets awake indefinitely. iOS strictly suspends background execution. To download in the background on iOS, tasks must be handed over to `URLSessionConfiguration.background(withIdentifier:)`, which runs via the system daemon `nsurlsessiond`. Segmented multi-part work-stealing algorithms cannot execute while suspended.

3. **BitTorrent Background Seeding:**  
   On iOS, BitTorrent swarms cannot remain connected in the background because the operating system closes or suspends listening sockets. Continuous 24/7 seeding is structurally disallowed on iOS without enterprise or specialized audio/VoIP entitlements.

4. **File System Sandboxing:**  
   Android allows writing to shared public directories (e.g., `/sdcard/Download`). iOS enforces strict container isolation. LID stores files in its sandboxed `Documents` directory and provides system Share Sheet / `UIDocumentPicker` integration to export files to the system Files app.

---

## 4. Key Gaps Summary

The following major gaps constitute the functional distance between LID and 1DM+:

1. **Ad & Popup Blocking (Browser):**  
   1DM+ features an integrated ad and popup blocker. LID currently has no ad-blocking layer. Integrating `WKContentRuleListStore` is the top priority for browser usability.

2. **Interactive Stream Resolution Picker (Media):**  
   While LID's HLS/DASH manifest parsers understand all available bitrates and resolutions, the browser UI currently auto-proposes the highest bitrate. An interactive modal allowing users to select 1080p, 720p, 480p, or audio-only before downloading is missing.

3. **Batch Downloads & URL Pattern Expansion (Engine):**  
   1DM+ supports batch downloading via bracket syntax (e.g. `file[01-50].mp4`) and multi-URL text imports. LID currently supports only single URL additions.

4. **File Categorization & Subfolders (File Management):**  
   1DM+ automatically organizes files into Videos, Music, Documents, and custom user folders. LID currently filters only by transfer state (Active, Paused, Completed).

5. **BitTorrent Swarm Inspection & Sequential Mode (Torrent):**  
   LID supports core torrent downloading, file priorities, and seeding preferences, but lacks a peer list, piece map visualization, tracker editor, and sequential download mode for media streaming.
