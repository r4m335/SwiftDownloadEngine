# Milestone 7F.0 — Streaming Capability Assessment

Status: updated after 7F.1–7F.4.1 and 7H.0 implementation work. Parser and
planner layers are implemented, but stream execution and media assembly are not
integrated into the download queue. The latest 7H.0 change is awaiting macOS CI.

## Executive finding

The project has a solid transport foundation for authenticated HTTP file downloads
and now has deterministic HLS/DASH parsing plus VOD transfer-plan models. Those
plans still stop before execution: the browser must discover dynamic media requests,
and a future stream job must connect validated plans to the existing coordinator.
Media assembly remains a later stage and must not be inferred from parser success.

The supported path remains finite, clear VOD content. Live playlists, DRM,
encrypted media, separate-track muxing, and arbitrary blob playback are explicit
unsupported or deferred states.

## Existing capabilities

### Browser discovery and classification

- `WebpageResourceExtractor` discovers URLs from DOM candidates and preserves the
  existing 7D behavior.
- `BrowserMediaDiscoveryBridge` now injects a document-start, all-frame WebKit
  observer for fetch, XHR, media/source elements, DOM mutations, and resource
  performance entries. It validates messages in Swift, deduplicates candidates,
  records sanitized page/frame origins, and never forwards blob URLs as downloads.
- Extension- and MIME-based HLS/DASH candidates are classified as streaming
  manifests, while transfer execution remains intentionally unsupported until 7H.1.
- `BrowserDownloadClassifier` classifies ordinary HTTP responses from status,
  Content-Disposition, MIME type, and URL extension.
- Dynamic discovery cannot guarantee visibility into service workers, native player
  networking, browser internals, or inaccessible cross-origin frames. Extensionless
  responses are useful when the observed request exposes a manifest MIME type; the
  bridge does not read response bodies.

### HTTP transfer engine

- `DownloadCoordinator` is the single source of truth for queue admission, probing,
  segmentation, persistence, pause/resume, retries, progress, and foreground/background
  transport selection.
- `HTTPRangeProbe` and `SegmentDownloader` support authenticated HTTP requests and
  byte ranges. This is reusable for individual HLS/DASH segments, but it cannot
  represent a manifest, an initialization segment, or multiple tracks by itself.
- `BackgroundDownloadSessionManager` can schedule independent HTTP segment tasks and
  persist their progress. Its current record model assumes one ordinary download
  destination and needs a stream-specific mapping layer before it can assemble media.
- 7F.2 and 7F.3 provide validated HLS/DASH VOD plans, but no planner starts a
  download or owns cancellation, progress, persistence, or queue admission.
- 7E `BrowserRequestContext` already provides origin-matched cookies, approved headers,
  redaction, and cross-origin redirect credential stripping. Each stream segment must
  call the context’s target-aware header builder rather than reuse one Cookie header
  for every CDN host.

### Persistence and output

- `DownloadRequest` and `DownloadRecord` model one URL, one destination, one size, and
  byte-range segments.
- There is no manifest snapshot, selected representation, segment identity, media-track
  metadata, assembly state, or stream-specific recovery record.
- `DownloadFileWriter` is suitable for byte ranges in one output file, but media
  assembly needs separate validated segment files or a stream-aware staging directory.
- `Package.swift` has no FFmpeg, MP4 muxer, MPEG-TS parser, or other media-processing
  dependency. No existing Engine source imports AVFoundation for export or muxing.
- 7F.4.1 now defines dependency-neutral assembly inputs, outputs, encryption states,
  track metadata, temporary/output locations, and pure contract validation. It does
  not inspect bytes or publish output.

## Capability gaps and constraints

| Area | Current state | Required decision |
| --- | --- | --- |
| Area | Current state | Required next decision |
| --- | --- | --- |
| Dynamic browser discovery | 7H.0 bridge implemented; CI pending | Validate on iOS/macOS WebKit and document blind spots |
| Manifest classification | Extension/MIME/content classification implemented | Connect discovered manifests to parser loading without ordinary-file fallback |
| HLS parser/planner | Implemented and CI-validated for finite VOD planning | Add 7H.1 coordinator-owned execution |
| DASH parser/planner | Implemented and CI-validated for finite VOD planning | Add 7H.1 coordinator-owned execution |
| Live/encrypted/DRM media | Explicitly detected or rejected by planners | Keep out of finite transfer jobs |
| Multi-track media | Represented in parser/planner/assembly contracts | Defer muxing until a compatible implementation is selected |
| Assembly | 7F.4.1 contracts only; no byte validation or publication | Evaluate AVFoundation first, then implement supported containers |
| Stream persistence | Unsupported | Persist immutable plans and per-segment state in 7H.2 |
| UI | Existing resource inspector and unsupported-resource messaging | Add stream selection only after execution is stable |

## Recommended architecture

Keep the existing `DownloadCoordinator` as the admission and lifecycle owner, and
introduce pure, platform-agnostic planning types:

```text
BrowserResource / response metadata
        |
        v
Dynamic browser media discovery
        |
        v
ManifestInspector
        |
        +--> HLSManifestParser --> HLSStreamPlan
        |
        +--> DASHManifestParser -> DASHStreamPlan
                                      |
                                      v
                          StreamTransferPlan
                                      |
                                      v
                  DownloadCoordinator stream job
                                      |
                                      v
                        Segment staging + validation
                                      |
                                      v
                             MediaAssembler
```

The parsers and planners should not perform network requests. A separate manifest
loader should use the existing request context and apply headers per resolved URL.
The planner should return explicit unsupported reasons instead of silently degrading
to an ordinary file download.

## Proposed staged implementation

### 7H.0 — Dynamic browser media discovery (implemented; CI pending)

1. Inject the `BrowserMediaDiscoveryBridge` at document start in all frames.
2. Observe fetch, XHR, media/source elements, DOM mutations, and performance
   resource entries without reading cookies, request bodies, or response bodies.
3. Validate every message in Swift, resolve only HTTP/HTTPS candidates, reject
   credential-bearing URLs, deduplicate observations, and retain blob signals only.
4. Permit browser credentials only for same-origin observations from the main page;
   cross-origin resources and frames are forwarded without credential inheritance.

The bridge is discovery-only. It does not parse manifests, enqueue downloads, or
start an independent transfer task. WebKit cannot expose every request made by
service workers, native players, browser internals, or inaccessible frames.

### 7F.1 — Intelligence and pure parsers

Implemented and CI-validated. The classifier, HLS/DASH models, bounded parsers,
security limits, malformed-input handling, and deterministic fixtures are complete.

No download queue integration should occur until the plans are validated.

### 7F.2 — HLS VOD transfer planning

Implemented and CI-validated as a pure planner. It resolves resources, preserves
ordering/ranges, applies target-aware credential restrictions, and returns explicit
unsupported results. It does not download or assemble segments.

### 7F.3 — DASH VOD transfer planning

Implemented and CI-validated as a pure planner. It models finite representations,
initialization/media resources, ranges, timelines, and separate audio/video tracks.

### 7F.4 / 7H.3+ — Assembly, authentication integration, and UI

### 7H.1 — Connect plans to transfers

Next execution milestone. Add a stream-job adapter owned by the existing download
coordinator, with per-segment progress, cancellation, retry, staging, and fresh
browser credential resolution. Do not let the bridge or planner start transfers.

### 7H.2 — Persistence and recovery

Persist an immutable manifest/representation plan plus non-secret segment state and
validated local locations. Keep cookies, authorization headers, and unnecessary
signed URLs out of durable history.

7F.4.1 contracts are defined, but byte validation and media publication remain
unimplemented. Only after transfer fixtures are stable should the project choose between:

- a small iOS-compatible media assembly implementation for the supported containers;
- an evaluated, licensed media dependency; or
- a clear limitation that requires external muxing for separate audio/video tracks.

The UI should display available variants, tracks, estimated size when meaningful,
authentication requirements, and unsupported/DRM warnings. It must not claim exact
size for live or variable-duration content.

## Security requirements carried forward from 7E

- Resolve every segment URL against the manifest URL before applying cookies.
- Treat every JavaScript discovery message as untrusted. Validate its URL and
  source origin in Swift before forwarding it to resource classification.
- Allow browser credentials only for same-origin main-frame observations; do not
  inherit credentials for cross-origin frames or resources.
- Treat `blob:` observations as browser-local signals and never pass them to the
  HTTP download coordinator.
- Build headers for that exact segment URL; never copy one host’s Cookie header to all
  CDN origins.
- Strip sensitive headers across cross-origin redirects and sanitize signed URLs in
  diagnostics.
- Do not persist raw browser credentials in stream history. Persist a plan reference
  and non-sensitive metadata; require fresh browser context when credentials expire.
- Treat missing/expired cookies, 401, 403, expired signatures, and missing segments as
  understandable stream-job failures.

## Validation plan

Use local fixtures and a deterministic test server for:

- HLS master/media playlists, relative paths, query strings, `EXT-X-MAP`, and VOD end;
- dynamic media elements, fetch/XHR manifest requests, duplicate observations,
  extensionless MIME-identified manifests, cross-origin frames, malformed messages,
  unsupported schemes, and blob signals;
- live playlist detection and unsupported encryption/DRM classification;
- DASH `SegmentTemplate`, `SegmentTimeline`, `SegmentList`, `BaseURL`, and separate
  adaptation sets;
- per-origin cookies and header filtering across redirects;
- missing segments, HTTP errors, expired URLs, incomplete assembly, and output checks;
- regression coverage for the existing 7D browser discovery and ordinary HTTP downloads.

The complete iOS build and real WebKit cookie behavior must still be run by the
macOS GitHub Actions workflow and later on a physical iPhone. The current Windows
workspace cannot execute Swift or Xcode locally.
