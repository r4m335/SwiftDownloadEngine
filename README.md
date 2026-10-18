# SwiftDownloadEngine

[![Swift](https://img.shields.io/badge/Swift-5.9%20%7C%206.0-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platforms-macOS%20%7C%20iOS%20%7C%20Linux-blue.svg)](https://swift.org)
[![Tests](https://img.shields.io/badge/Tests-144%20Passing-brightgreen.svg)]()
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A high-performance, resilient, multi-segment HTTP range download engine for Swift. Architected from the reverse-engineered principles of industry-leading download managers (such as 1DM+ and IDM), **SwiftDownloadEngine** delivers accelerated parallel downloads, token-bucket bandwidth throttling, global HTTP request budgeting, cooperative pause/resume, persistent queue scheduling, and reactive Swift Concurrency event streams.

---

## Key Features

* **Accelerated Multi-Segment Transfers:** Dynamically partitions large files into contiguous byte ranges using `Range: bytes=start-end` over parallel worker streams (`SegmentDownloader`).
* **Actor-Isolated Architecture:** Built strictly on modern Swift structured concurrency (`actor`, `async/await`, `withThrowingTaskGroup`) for guaranteed data-race safety without manual locks.
* **Resilient Pause & Resume:** Durable checkpoints survive sudden app terminations or process kills. Validates HTTP validators (`ETag`, `Last-Modified`, `Accept-Ranges`) to ensure segment integrity on resume.
* **Dual Storage Strategies:** Direct-seek preallocated writes (`directSeek`) or individual part-file buffering (`partFiles`) with disk-space preflighting.
* **Global & Per-Download Bandwidth Throttling:** High-precision token-bucket rate limiting (`BandwidthLimiter`) enforcing strict bandwidth caps across all connections or per individual download.
* **In-Flight HTTP Request Budgeting:** Prevents connection starvation and server rate limits by strictly bounding concurrent active HTTP requests across segments and downloads (`SharedRequestBudget`).
* **Reactive Event Streams:** Non-competing broadcast fan-out via `AsyncStream<DownloadEvent>` with bounded buffering and progress coalescing (max 20 Hz) to keep UI responsive.
* **Persistent Priority Queue:** Manages downloads across `.high`, `.normal`, and `.low` priorities with FIFO ordering within equal priority bands.
* **Integrity Verification:** Automated SHA-256 post-transfer hashing and validation (`ChecksumOutcome`).
* **Cross-Platform:** Zero third-party dependencies. Compiles and executes identically on macOS, iOS, and Linux (via SwiftPM).

---

## Architecture Overview

```
                      ┌────────────────────────────────────────┐
                      │             DownloadEngine             │  ◄── Public Facade
                      │   (AsyncStream<DownloadEvent>, Actor)  │
                      └──────────────────┬─────────────────────┘
                                         │
                 ┌───────────────────────┴───────────────────────┐
                 ▼                                               ▼
   ┌───────────────────────────┐                   ┌───────────────────────────┐
   │   DownloadQueueManager    │                   │    DownloadCoordinator    │
   │ (Priority & Concurrency)  │                   │ (Segment Orchestration)   │
   └─────────────┬─────────────┘                   └─────────────┬─────────────┘
                 │                                               │
                 │         ┌───────────────────────────┐         │
                 ├────────►│   SharedRequestBudget     │◄────────┤
                 │         │  (Global Request Cap)     │         │
                 │         └───────────────────────────┘         │
                 │         ┌───────────────────────────┐         │
                 ├────────►│     BandwidthLimiter      │◄────────┤
                 │         │ (Token-Bucket Throttle)   │         │
                 │         └───────────────────────────┘         │
                 │         ┌───────────────────────────┐         │
                 └────────►│  DownloadPersistenceStore │◄────────┘
                           │ (Atomic Metadata/Resume)  │
                           └───────────────────────────┘
```

---

## Installation

Add **SwiftDownloadEngine** as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/r4m335/SwiftDownloadEngine.git", from: "1.0.0")
]
```

Or add the URL directly via Xcode: **File** > **Add Package Dependencies...**

---

## Quick Start

### 1. Construct the Engine

```swift
import Foundation
import DM_Reverse_engineering

// Create the engine with customizable concurrency and bandwidth caps
let engine = try DownloadEngine(
    storageDirectoryURL: nil,        // Defaults to Application Support / Linux fallback
    maxConcurrentDownloads: 3,      // Max active parallel downloads
    maxGlobalRequests: 12,           // Max concurrent in-flight HTTP requests
    globalBandwidthLimit: 2_097_152  // 2 MB/s global bandwidth limit
)
```

### 2. Observe Real-Time Download Events

`DownloadEngine.events()` yields an independent `AsyncStream<DownloadEvent>`:

```swift
Task {
    for await event in await engine.events() {
        switch event {
        case .started(let snap):
            print("Download started: \(snap.id)")
        case .progressUpdated(let snap):
            print("Progress [\(snap.id)]: \(Int(snap.progressFraction * 100))% - Speed: \(snap.currentBytesPerSecond / 1024) KB/s")
        case .completed(let snap):
            print("Finished: \(snap.id) -> \(snap.destinationURL.path)")
        case .failed(let snap, let reason):
            print("Download failed: \(snap.id) - Reason: \(reason)")
        case .integrityVerified(let id, let outcome):
            print("SHA-256 verification for \(id): \(outcome)")
        default:
            break
        }
    }
}
```

### 3. Add and Manage Downloads

```swift
let destination = FileManager.default.temporaryDirectory.appendingPathComponent("sample.iso")

let request = DownloadRequest(
    url: URL(string: "https://example.com/sample.iso")!,
    destinationURL: destination,
    configuredThreadCount: 8,              // Dynamic multi-segment parallel workers
    retryCount: 3,
    expectedSHA256: "e8964d4c55ec266ef61d68a2bf172fc22ae1d62ebc22d10c0e1cfeb93bcf91c9",
    maxConcurrentRequests: 4,              // Per-download connection budget
    speedLimitBytesPerSecond: 1_048_576    // Per-download rate limit (1 MB/s)
)

// Enqueue with priority
let initialSnapshot = try await engine.addDownload(request, priority: .high, autoStart: true)

// Query live authoritative snapshot anytime
if let live = await engine.snapshot(for: request.id) {
    print("State: \(live.state), Transferred: \(live.completedBytes) / \(live.totalBytes ?? 0) bytes")
}

// Cooperative lifecycle controls
try await engine.pauseDownload(id: request.id)
try await engine.resumeDownload(id: request.id)
try await engine.cancelDownload(id: request.id, deleteFile: false)
try await engine.removeDownload(id: request.id, deleteFile: false)
```

### 4. Dynamic Limit Controls

```swift
// Adjust active limits on the fly without resetting transfers
try await engine.setMaxGlobalRequests(16)
await engine.setGlobalSpeedLimit(5_000_000) // 5 MB/s
try await engine.setMaxConcurrentDownloads(5)
```

---

## Testing & Verification

The test suite validates real-world networking scenarios without external network dependencies using an integrated, RFC 7233-compliant local HTTP server (`LocalHTTPRangeServer`).

```bash
# Run the entire test suite
swift test
```

### Test Coverage Highlights:
* **Segment Allocation:** Contiguous, non-overlapping boundary partitioning and thread count clamping.
* **HTTP Range Probe:** Range validation, redirects, content-length detection, and validator capture (`ETag`, `Last-Modified`).
* **Pause, Resume & Interruption Recovery:** Verifies state preservation across process `SIGKILL` interruptions and source validator modifications.
* **Queue Lifecycle & Priority:** Strict `.high` > `.normal` > `.low` scheduling and FIFO sequencing.
* **Resource Throttling:** Validates token-bucket rate limiting tolerances and shared request permit acquisition/release.
* **Engine Facade & Event Streams:** Broadcast fan-out, late subscribers, task cancellation cleanup, and progress coalescing.

---

## Project Structure

```text
├── Engine/
│   ├── DownloadEngine.swift            # High-level public facade & event streams
│   ├── DownloadCoordinator.swift       # Download orchestration & lifecycle
│   ├── DownloadQueueManager.swift      # Persistent priority queue & scheduling
│   ├── DownloadPersistence.swift      # Durable checkpoints & metadata store
│   ├── DownloadFileWriter.swift       # Direct-seek & part-file atomic writers
│   ├── SegmentDownloader.swift        # Concurrently executing range workers
│   ├── SegmentAllocator.swift         # Dynamic segment boundary calculations
│   ├── HTTPRangeProbe.swift           # Server range capability & size probing
│   ├── BandwidthLimiter.swift         # Token-bucket rate limiter
│   ├── SharedRequestBudget.swift      # Global HTTP active request semaphore
│   └── DownloadSpeedTracker.swift     # Monotonic moving-average speed & ETA
├── Tests/
│   ├── DownloadEngineTests.swift      # Facade and AsyncStream integration tests
│   ├── DownloadCoordinatorTests.swift # Coordinator unit and integration tests
│   ├── DownloadQueueManagerTests.swift# Queue scheduler and priority tests
│   ├── ResourceThrottlingTests.swift  # Bandwidth and budget throttling tests
│   ├── PauseResumeAndRecoveryTests.swift # Interruption & process recovery tests
│   └── LocalHTTPRangeServer.swift     # In-process deterministic range server
└── Package.swift
```

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
