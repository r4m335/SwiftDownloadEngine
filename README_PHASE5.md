# Phase 5: Download Engine Public API & Application Integration

This document describes the high-level public API introduced in Phase 5 for the 1DM+-inspired Swift download engine. The API is designed for clean integration into modern Swift applications and future iOS/macOS user interfaces without exposing internal segment workers or breaking existing queue and persistence guarantees.

---

## 1. Constructing the Engine

`DownloadEngine` is an `actor` providing thread-safe, structured access to all underlying queue, transfer, throttling, and persistence systems.

### Option A: Standard Application Initialization
Using default storage paths (`Application Support/1DMDownloads/Metadata` or temporary directory fallback on Linux) and standard limits:

```swift
import Foundation
import DM_Reverse_engineering

// Initialize with default or customized storage and limits
let engine = try DownloadEngine(
    storageDirectoryURL: nil,          // nil defaults to Application Support / Linux fallback
    maxConcurrentDownloads: 3,        // Maximum downloads running in parallel
    maxGlobalRequests: 12,             // HTTP request concurrency cap
    globalBandwidthLimit: 1_048_576,   // 1 MB/s global speed limit (or nil for unlimited)
    session: .shared
)
```

### Option B: Explicit Component Injection
Useful for advanced configurations or specialized test setups:

```swift
let persistence = try DownloadPersistenceStore(storageDirectoryURL: customStoreURL)
let budget = SharedRequestBudget(maxGlobalRequests: 16)
let limiter = BandwidthLimiter(bytesPerSecond: 2_000_000)
let coordinator = try DownloadCoordinator(
    session: .shared,
    persistenceStore: persistence,
    requestBudget: budget,
    globalBandwidthLimiter: limiter
)
let queueManager = DownloadQueueManager(
    coordinator: coordinator,
    persistenceStore: persistence,
    maxConcurrentDownloads: 4
)

let engine = DownloadEngine(
    queueManager: queueManager,
    coordinator: coordinator,
    persistenceStore: persistence
)
```

---

## 2. Subscribing to Asynchronous Download Events

`DownloadEngine.events()` returns an independent `AsyncStream<DownloadEvent>` for each observer.

* **Broadcast Fan-Out:** Multiple subscribers receive independent copies of every event without competing for or stealing events from one another.
* **Bounded Buffering:** Uses `.bufferingNewest(200)` to prevent unbounded memory growth if an observer is slow.
* **Progress Coalescing:** High-frequency chunk writes are throttled to a maximum of 20 Hz (once per 50 ms per download) to prevent UI thread flooding.
* **Immediate Lifecycle Dispatch:** All state changes (`added`, `queued`, `started`, `paused`, `resumed`, `completed`, `failed`, `cancelled`, `removed`, `integrityVerified`) are dispatched immediately without coalescing.
* **Automatic Observer Cleanup:** When the observing `Task` terminates or is cancelled, continuation teardown automatically unregisters the observer from the engine.

```swift
let observerTask = Task {
    for await event in await engine.events() {
        switch event {
        case .added(let snapshot):
            print("Download added: \(snapshot.id)")
        case .queued(let snapshot):
            print("Download queued: \(snapshot.id)")
        case .started(let snapshot):
            print("Download started: \(snapshot.id)")
        case .progressUpdated(let snapshot):
            print("Progress [\(snapshot.id)]: \(Int(snapshot.progressFraction * 100))% - \(snapshot.currentBytesPerSecond / 1024) KB/s")
        case .paused(let snapshot):
            print("Download paused: \(snapshot.id)")
        case .resumed(let snapshot):
            print("Download resumed: \(snapshot.id)")
        case .completed(let snapshot):
            print("Download completed: \(snapshot.id) -> \(snapshot.destinationURL.path)")
        case .failed(let snapshot, let reason):
            print("Download failed: \(snapshot.id) due to: \(reason)")
        case .cancelled(let snapshot):
            print("Download cancelled: \(snapshot.id)")
        case .removed(let id):
            print("Download removed from queue: \(id)")
        case .integrityVerified(let id, let outcome):
            print("Integrity check for \(id): \(outcome)")
        case .queueStateChanged(let queueSnapshot):
            print("Queue active: \(queueSnapshot.activeCount), queued: \(queueSnapshot.queuedCount)")
        }
    }
}
```

---

## 3. Adding Downloads

Create a `DownloadRequest` and enqueue it. The request can specify destination paths, custom headers, segment concurrency, and checksum validation:

```swift
let request = DownloadRequest(
    url: URL(string: "https://example.com/files/archive.zip")!,
    destinationURL: documentsDirectory.appendingPathComponent("archive.zip"),
    headers: ["Authorization": "Bearer token"],
    configuredThreadCount: 8,
    retryCount: 3,
    expectedSHA256: "optional_expected_sha256_hash",
    maxConcurrentRequests: 4,               // Per-download active request limit
    speedLimitBytesPerSecond: 512 * 1024     // Per-download bandwidth limit (512 KB/s)
)

// Add single download (returns initial DownloadSnapshot)
let snapshot = try await engine.addDownload(request, priority: .high, autoStart: true)

// Or add multiple downloads in bulk
let bulkSnapshots = try await engine.addDownloads([req1, req2], priority: .normal, autoStart: true)
```

---

## 4. Querying Authoritative Snapshots

Consumers do not need to rely solely on streaming events. Authoritative, live snapshots can be fetched at any time:

```swift
// Query an individual download's snapshot
if let snapshot = await engine.snapshot(for: request.id) {
    print("Status: \(snapshot.state)")
    print("Bytes: \(snapshot.completedBytes) / \(snapshot.totalBytes ?? 0)")
    print("ETA: \(snapshot.estimatedTimeRemaining ?? 0) seconds")
    print("Can resume: \(snapshot.canResume)")
    print("Is completed: \(snapshot.isCompleted)")
}

// Retrieve all downloads in queue priority order
let allDownloads: [DownloadSnapshot] = await engine.allSnapshots()

// Summary of the overall queue
let queueSnap: QueueSnapshot = await engine.queueSnapshot()
print("Total items: \(queueSnap.totalItems), Active: \(queueSnap.activeCount)")
```

---

## 5. Download Lifecycle Controls

All lifecycle controls are asynchronous and respect cooperative task boundaries and persistence invariants:

```swift
// Cooperative Pause
try await engine.pauseDownload(id: request.id)

// Resume paused or interrupted download
try await engine.resumeDownload(id: request.id)

// Cancel download (optionally preserve partially downloaded file)
try await engine.cancelDownload(id: request.id, deleteFile: false)

// Remove from queue (preserves downloaded file on disk by default)
try await engine.removeDownload(id: request.id, deleteFile: false)

// Retry an eligible failed download
try await engine.retryDownload(id: request.id)

// Bulk operations
await engine.pauseAllDownloads()
await engine.resumeAllDownloads()
await engine.cancelAllDownloads(deleteFiles: false)
```

---

## 6. Resource and Bandwidth Throttling Configuration

Dynamic limits can be updated live without restarting downloads:

```swift
// Global active HTTP request limit
try await engine.setMaxGlobalRequests(16)

// Global bandwidth speed limit (in bytes/sec, or nil for unlimited)
await engine.setGlobalSpeedLimit(2_000_000)

// Per-download bandwidth speed limit
await engine.setSpeedLimit(for: request.id, bytesPerSecond: 256 * 1024)

// Maximum concurrent active downloads in queue
try await engine.setMaxConcurrentDownloads(4)

// Inspect live metrics
if let metrics = await engine.speedMetrics(for: request.id) {
    print("Speed: \(metrics.currentBytesPerSecond) B/s, ETA: \(metrics.estimatedTimeRemaining ?? 0)s")
}

// Inspect integrity verification outcome
let checksumOutcome = await engine.checksumOutcome(for: request.id)
```

---

## 7. Stream Termination and Engine Shutdown

When an observer finishes or cancels its consuming Task, the engine automatically removes the subscriber without leaking memory. When shutting down the engine completely:

```swift
// Cancels individual subscriber
observerTask.cancel()

// Or closes all streams and active continuations during app teardown
await engine.shutdown()
```

---

## Summary of Delivered Phase 5 Components

| Component | File | Responsibility |
|---|---|---|
| `DownloadEngine` | `Engine/DownloadEngine.swift`<br>`DownloadEngine.swift` | Unified actor facade coordinating queue, coordinator, and persistence. |
| `DownloadSnapshot` | `Engine/DownloadEngine.swift`<br>`DownloadEngine.swift` | Immutable, application-facing snapshot model (Sendable, Codable, Identifiable). |
| `DownloadEvent` | `Engine/DownloadEngine.swift`<br>`DownloadEngine.swift` | Strongly typed enum for real-time lifecycle transitions. |
| `DownloadEngineTests` | `Tests/DownloadEngineTests.swift` | 18 deterministic integration test scenarios against `LocalHTTPRangeServer`. |
