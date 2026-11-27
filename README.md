# SwiftDownloadEngine (`DownloadEngineKit`)

[![Swift](https://img.shields.io/badge/Swift-5.9%20%7C%206.0-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platforms-iOS%2015%2B%20%7C%20macOS%2012%2B-blue.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A multi-protocol download engine, streaming media pipeline, BitTorrent client, integrated browser, and media player library for Apple platforms (**`DownloadEngineKit`**). Built on Swift Concurrency (`actor`, `async/await`, `AsyncStream`) with durable `SchemaVersioned` persistence.

---

## Key Features

* **Accelerated Multi-Segment HTTP Transfers:** Partitions range-capable files across parallel worker streams (`SegmentDownloader`, `AdaptiveSegmentWorkQueue`) with work stealing, token-bucket rate limiting (`BandwidthLimiter`), global/per-host concurrency caps, and HTTP/HTTPS proxy support (`ForegroundURLSession`, `BackgroundHTTPTransport`).
* **Resilient Pause, Resume & Crash Recovery:** Atomic writes via `DurableStorage` (`SchemaVersioned`), HTTP validator checks (`ETag`, `Last-Modified`, `Accept-Ranges`), and `BGTaskScheduler` reconciliation (`ScheduleCoordinator`).
* **Streaming Media Pipeline (HLS, DASH, Live, Blob, MSE):**
  * Parses HLS (`HLSManifestParser`) and DASH MPD (`DASHManifestParser`) manifests, decrypts AES-128 HLS segments (`HLSSegmentDecryptor`), and muxes/reconstructs outputs (`MediaAssembler`, `HLSVODReconstruction`, `DASHVODReconstruction`).
  * Supports live stream recording (`LiveStreamRecorder`, `LiveRecordingStore`), bounded `blob:` export (`BrowserBlobCaptureService`), and MSE capture (`BrowserMSECaptureService`).
* **BitTorrent Support:** Native `libtorrent` 2.0 bridge (`TorrentSessionBridge.mm` / `LibTorrent.xcframework`) on iOS with queue scheduling (`TorrentQueueScheduler`), sequential download mode, tracker management, seeding policies, and periodic fast-resume persistence (`TorrentPersistenceStore`). When `LibTorrent` is not linked, the engine surfaces an explicit error rather than silently pretending to transfer peers.
* **Integrated Web Browser & Resource Grabber:** Multi-tab `WKWebView` browser (`BrowserView`, `BrowserViewModel`) with ad/tracker/popup blocking (`BrowserContentBlocker`), bookmarks/history/quick access, incognito tabs, reader mode, and unified per-tab/per-document resource discovery (`WebpageResource`, `BrowserMediaCandidate`, `BrowserResourceDiscoveryCoordinator`).
* **Integrated Media Player (`LIDPlaybackEngine`):** Dual-backend playback (`LIDAVFoundationBackend` and `LIDVLCKitBackend`), subtitle search/storage (`LIDSubtitleStore`), library/history tracking, and deferred ready-state resume positioning.
* **Localization, Accessibility & Dynamic Type:** `L10n` localization wrapper, VoiceOver accessibility labels across core controls, and `@ScaledMetric` Dynamic Type scaling (`L10nAndAccessibility.swift`).

---

## Architecture Overview

```
                     ┌────────────────────────────────────────┐
                     │          AppCompositionRoot            │  ◄── Dependency Injection
                     └──────────────────┬─────────────────────┘
                                        │
        ┌───────────────────────────────┼───────────────────────────────┐
        ▼                               ▼                               ▼
┌───────────────────┐         ┌───────────────────┐         ┌───────────────────────┐
│  DownloadEngine   │         │  TorrentEngine    │         │ StreamingDownload     │
│ (HTTP Queue/Coord)│         │ (libtorrent 2.0)  │         │ Orchestrator (HLS/DASH│
└─────────┬─────────┘         └─────────┬─────────┘         └───────────┬───────────┘
          │                             │                               │
          └─────────────────────────────┼───────────────────────────────┘
                                        ▼
                       ┌─────────────────────────────────┐
                       │   DurableStorage / Persistence  │
                       │ (SchemaVersioned + Quarantine)  │
                       └─────────────────────────────────┘
```

---

## Installation

Add **SwiftDownloadEngine** as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/r4m335/SwiftDownloadEngine.git", from: "1.0.0")
]
```

Link the `DownloadEngineKit` product in your target.

---

## Quick Start

```swift
import Foundation
import DownloadEngineKit

let engine = try DownloadEngine(
    storageDirectoryURL: nil,
    maxConcurrentDownloads: 3,
    maxGlobalRequests: 12,
    globalBandwidthLimit: 2_097_152
)

let destination = FileManager.default.temporaryDirectory.appendingPathComponent("sample.iso")
let request = DownloadRequest(
    url: URL(string: "https://example.com/sample.iso")!,
    destinationURL: destination,
    configuredThreadCount: 8,
    retryCount: 3
)

let snapshot = try await engine.addDownload(request, priority: .high, autoStart: true)
try await engine.pauseDownload(id: snapshot.id)
try await engine.resumeDownload(id: snapshot.id)
```

---

## Testing & Verification

```bash
swift test
```

GitHub Actions (`.github/workflows/ios-build.yml`) runs:
1. **Swift Package Tests** (`swift test`)
2. **Milestone 1-3** (libtorrent 2.0 iOS native build, bridge & transfer engine tests)
3. **iOS Device Build** (`xcodebuild` arm64 device build)

---

## Project Structure

```text
├── Engine/
│   ├── AppCompositionRoot.swift            # Dependency injection container
│   ├── DownloadEngine.swift                # Public HTTP download facade & event streams
│   ├── DownloadCoordinator*.swift          # Multi-segment, single-stream & recovery
│   ├── DownloadQueueManager.swift          # Persistent priority queue & per-host caps
│   ├── DownloadPersistence.swift           # Durable download & schedule persistence
│   ├── DurableStorage.swift                # Atomic writes, SchemaVersioned & quarantine
│   ├── TorrentEngine.swift                 # BitTorrent facade & periodic fast-resume
│   ├── TorrentQueueScheduler.swift         # Torrent queue, priority & seeding policies
│   ├── Configuration/                      # AppSettings & EngineConfiguration
│   ├── Browser/                            # Tab manager, content blocker, resource grabber
│   ├── Streaming/                          # HLS, DASH, live recording & MediaAssembler
│   ├── Player/                             # LIDPlaybackEngine, AVFoundation/VLCKit, subtitles
│   ├── Scheduling/                         # ScheduleCoordinator & BGTaskScheduler hooks
│   ├── Notifications/                      # DownloadNotificationManager (grouped/actionable)
│   ├── Recovery/                           # DownloadRecoveryManager & BrowserDownloadMatcher
│   ├── Security/                           # KeychainManager
│   └── UI/                                 # SwiftUI views, ViewModels, L10n & Dynamic Type
├── iOSApp/                                 # iOS app entry point, Info.plist, PrivacyInfo
├── Tests/                                  # Unit & integration test suites
└── Package.swift
```

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
