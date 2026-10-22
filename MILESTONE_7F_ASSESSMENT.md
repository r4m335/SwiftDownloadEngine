# Milestone 7F.0 — Streaming Capability Assessment

Status: assessment complete; no HLS/DASH transfer implementation is enabled yet.

## Executive finding

The project has a solid transport foundation for authenticated HTTP file downloads,
but it does not currently have a streaming-media pipeline. HLS and DASH should be
added as a validated transfer-plan layer above the existing transport components,
not by making `DownloadCoordinator` download a manifest as if it were a file.

The first implementation target should be finite, clear VOD content. Live playlists,
DRM, encrypted media, and separate-track muxing need explicit capability states before
they are allowed into the download queue.

## Existing capabilities

### Browser discovery and classification

- `WebpageResourceExtractor` discovers URLs from DOM candidates and preserves the
  existing 7D behavior.
- URLs ending in `.m3u8` or `.mpd` are currently marked unsupported with a Milestone
  7F explanation in `WebpageResourceExtractor.evaluateSupport`.
- `BrowserDownloadClassifier` classifies ordinary HTTP responses from status,
  Content-Disposition, MIME type, and URL extension.
- There is no bounded response-body inspection for extensionless manifests. A later
  change should inspect only a capped prefix and require protocol markers before
  classifying a response as HLS or DASH.

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

## Capability gaps and constraints

| Area | Current state | Required decision |
| --- | --- | --- |
| Manifest detection | Extension/MIME-based only; no body sniffing | Add bounded HLS/DASH inspection with false-positive tests |
| HLS master playlists | Unsupported | Parse variants, codecs, bandwidth, resolution, and relative URLs |
| HLS media playlists | Unsupported | Parse finite VOD segments, `EXT-X-MAP`, byte ranges, and end-list state |
| HLS live playlists | Unsupported | Detect and report live/non-final state; do not enqueue indefinitely |
| HLS encryption/DRM | Unsupported | Classify `EXT-X-KEY` methods and reject unsupported/DRM cases explicitly |
| DASH MPD | Unsupported | Parse finite `Period`, `AdaptationSet`, `Representation`, and supported segment models |
| Multi-track media | Unsupported | Represent audio/video tracks and defer muxing until a compatible implementation exists |
| Assembly | Unsupported | Validate segment bytes and assemble only formats proven safe |
| Stream persistence | Unsupported | Persist an immutable plan plus per-segment state, not just a manifest URL |
| UI | Existing unsupported-resource text only | Add selection UI after planner output is stable |

## Recommended architecture

Keep the existing `DownloadCoordinator` as the admission and lifecycle owner, and
introduce pure, platform-agnostic planning types:

```text
BrowserResource / response metadata
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

### 7F.1 — Intelligence and pure parsers

1. Add protocol classification types and bounded manifest inspection.
2. Add HLS parsing for master and finite media playlists.
3. Add DASH parsing for `BaseURL`, `SegmentTemplate`, `SegmentTimeline`, and
   `SegmentList`.
4. Add deterministic local fixtures and URL-resolution tests.
5. Add explicit states for live, encrypted, DRM-protected, malformed, and unsupported
   manifests.

No download queue integration should occur until the plans are validated.

### 7F.2 — HLS VOD transfer

1. Add a stream-job record with selected variant, initialization data, and segment list.
2. Download segments through the existing coordinator-owned request budget and progress
   path, applying `BrowserRequestContext` separately to each segment origin.
3. Validate segment completion and assemble clear MPEG-TS or compatible fragmented MP4
   output.
4. Keep live, encrypted, DRM, and unsupported codec plans out of the queue.

### 7F.3 — DASH VOD transfer

Add finite representation selection and segment transfer after HLS has established the
stream-job lifecycle. Separate audio/video tracks must remain explicit in the plan.

### 7F.4+ — Assembly, authentication integration, and UI

Only after parser and transfer fixtures are stable should the project choose between:

- a small iOS-compatible media assembly implementation for the supported containers;
- an evaluated, licensed media dependency; or
- a clear limitation that requires external muxing for separate audio/video tracks.

The UI should display available variants, tracks, estimated size when meaningful,
authentication requirements, and unsupported/DRM warnings. It must not claim exact
size for live or variable-duration content.

## Security requirements carried forward from 7E

- Resolve every segment URL against the manifest URL before applying cookies.
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
- live playlist detection and unsupported encryption/DRM classification;
- DASH `SegmentTemplate`, `SegmentTimeline`, `SegmentList`, `BaseURL`, and separate
  adaptation sets;
- per-origin cookies and header filtering across redirects;
- missing segments, HTTP errors, expired URLs, incomplete assembly, and output checks;
- regression coverage for the existing 7D browser discovery and ordinary HTTP downloads.

The complete iOS build and real WebKit cookie behavior must still be run by the
macOS GitHub Actions workflow and later on a physical iPhone. The current Windows
workspace cannot execute Swift or Xcode locally.

