import Foundation

#if canImport(Combine)
import Combine
#endif

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// State transitions for an active live stream recording session.
public enum LiveRecordingState: Equatable, Sendable {
    case idle
    case preparing
    case recording(duration: Double, segmentCount: Int, bytesWritten: Int64)
    case paused(duration: Double, segmentCount: Int, bytesWritten: Int64)
    case finalizing
    case completed(outputURL: URL, duration: Double, bytesWritten: Int64)
    case failed(error: String)
    case cancelled
}

/// Request parameters to initiate a live stream recording session.
public struct LiveRecordingRequest: Sendable, Codable, Equatable {
    public let manifestURL: URL
    public let manifestKind: StreamingManifestKind
    public let destinationURL: URL
    public let title: String
    public let requestContext: BrowserRequestContext?
    public let preferredQualityOption: StreamQualityOption?
    public let temporaryDirectoryURL: URL?

    public init(
        manifestURL: URL,
        manifestKind: StreamingManifestKind = .hls,
        destinationURL: URL,
        title: String? = nil,
        requestContext: BrowserRequestContext? = nil,
        preferredQualityOption: StreamQualityOption? = nil,
        temporaryDirectoryURL: URL? = nil
    ) {
        self.manifestURL = manifestURL
        self.manifestKind = manifestKind
        self.destinationURL = destinationURL
        self.title = title ?? destinationURL.deletingPathExtension().lastPathComponent
        self.requestContext = requestContext
        self.preferredQualityOption = preferredQualityOption
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }
}

/// Discovered media segment awaiting or completing live recording capture.
public struct LiveRecordedSegment: Equatable, Sendable, Codable {
    public let sequenceNumber: Int64
    public let uri: URL
    public let duration: Double
    public let localFileURL: URL
    public let byteCount: Int64
    public let trackKind: String
    public let byteRangeLength: Int64?
    public let byteRangeOffset: Int64?

    public init(
        sequenceNumber: Int64,
        uri: URL,
        duration: Double,
        localFileURL: URL,
        byteCount: Int64,
        trackKind: String = "video",
        byteRangeLength: Int64? = nil,
        byteRangeOffset: Int64? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.uri = uri
        self.duration = duration
        self.localFileURL = localFileURL
        self.byteCount = byteCount
        self.trackKind = trackKind
        self.byteRangeLength = byteRangeLength
        self.byteRangeOffset = byteRangeOffset
    }
}

/// Errors occurring during live stream recording lifecycle.
public enum LiveStreamRecorderError: LocalizedError, Equatable, Sendable {
    case invalidManifestURL
    case manifestFetchFailed(String)
    case streamIsNotLive
    case drmProtectedLiveStreamUnsupported(String)
    case unsupportedLiveEncryption(String)
    case noSegmentsDiscovered
    case assemblyFailed(String)
    case alreadyRecording
    case notRecording
    case cancelled
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifestURL:
            return "The live manifest URL is invalid or malformed."
        case .manifestFetchFailed(let reason):
            return "Failed to fetch live manifest: \(reason)"
        case .streamIsNotLive:
            return "The target stream is a static VOD playlist rather than a live stream."
        case .drmProtectedLiveStreamUnsupported(let details):
            return "DRM-protected live streams are not supported: \(details)"
        case .unsupportedLiveEncryption(let details):
            return "Unsupported live encryption: \(details)"
        case .noSegmentsDiscovered:
            return "No playable media segments could be captured from the live stream."
        case .assemblyFailed(let reason):
            return "Failed to assemble captured live segments into output file: \(reason)"
        case .alreadyRecording:
            return "A live recording session is already active."
        case .notRecording:
            return "No live recording session is currently active."
        case .cancelled:
            return "Live stream recording was cancelled by user."
        case .sessionNotFound(let id):
            return "Live recording session '\(id)' was not found."
        }
    }
}

/// Coordinates sliding-window manifest polling, segment deduplication, incremental disk writing,
/// durable checkpointing, AES-128 decryption, and output container assembly for live HLS broadcasts and dynamic DASH streams.
@MainActor
public final class LiveStreamRecorder: ObservableObject {

    public static let shared = LiveStreamRecorder()

    @Published public private(set) var state: LiveRecordingState = .idle
    @Published public private(set) var recordedDurationSeconds: Double = 0.0
    @Published public private(set) var recordedSegmentCount: Int = 0
    @Published public private(set) var bytesWritten: Int64 = 0
    @Published public private(set) var activeRequest: LiveRecordingRequest? = nil

    private var currentSessionID: String? = nil
    private var committedSegmentKeys = Set<String>()
    private var failedSegmentAttempts: [String: Int] = [:]
    private var recordedSegments: [LiveRecordedSegment] = []
    private var initializationSegmentURLs: [URL] = []
    private var cachedKeyData: [URL: Data] = [:]
    private var recordingTask: Task<Void, Never>? = nil
    private var isPaused: Bool = false
    private var sessionDirectory: URL? = nil

    #if canImport(UIKit) && !os(watchOS)
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    private let urlSession: URLSession
    public let libraryStore: LIDLibraryStore?
    public let recordingStore: LiveRecordingStore?

    public init(
        urlSession: URLSession = .shared,
        libraryStore: LIDLibraryStore? = nil,
        recordingStore: LiveRecordingStore? = nil
    ) {
        self.urlSession = urlSession
        self.libraryStore = libraryStore
        self.recordingStore = recordingStore ?? (try? LiveRecordingStore())
    }

    // MARK: - Recording Control APIs

    /// Initiates continuous capture of a live HLS or dynamic DASH stream.
    public func startRecording(request: LiveRecordingRequest) throws {
        guard case .idle = state else {
            throw LiveStreamRecorderError.alreadyRecording
        }

        let sessionID = UUID().uuidString
        self.currentSessionID = sessionID
        self.activeRequest = request
        self.state = .preparing
        self.recordedDurationSeconds = 0.0
        self.recordedSegmentCount = 0
        self.bytesWritten = 0
        self.committedSegmentKeys.removeAll()
        self.failedSegmentAttempts.removeAll()
        self.recordedSegments.removeAll()
        self.initializationSegmentURLs.removeAll()
        self.cachedKeyData.removeAll()
        self.isPaused = false

        let tempBase = request.temporaryDirectoryURL ?? FileManager.default.temporaryDirectory
        let scratchDir = tempBase.appendingPathComponent("LIDLiveRecording_\(sessionID)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
            self.sessionDirectory = scratchDir
        } catch {
            let msg = "Failed to create temporary recording directory: \(error.localizedDescription)"
            self.state = .failed(error: msg)
            throw LiveStreamRecorderError.assemblyFailed(msg)
        }

        #if canImport(UIKit) && !os(watchOS)
        if bgTaskID == .invalid {
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "DownloadEngineKit.liveRecording") { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.pauseRecording()
                    if self.bgTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(self.bgTaskID)
                        self.bgTaskID = .invalid
                    }
                }
            }
        }
        #endif

        Task {
            await self.persistSessionCheckpoint(state: "preparing")
        }

        PipelineLogger.shared.log(
            "[\(logCategory(for: request.manifestKind))] Starting live capture for '\(request.title)' [session: \(sessionID)] -> \(scratchDir.lastPathComponent)"
        )

        self.recordingTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runRecordingLoop(request: request, scratchDir: scratchDir)
        }
    }

    /// Pauses polling and downloading new live segments without finalizing.
    public func pauseRecording() {
        guard case .recording(let d, let c, let b) = state else { return }
        self.isPaused = true
        self.state = .paused(duration: d, segmentCount: c, bytesWritten: b)
        Task {
            await self.persistSessionCheckpoint(state: "paused")
        }
        if let kind = activeRequest?.manifestKind {
            PipelineLogger.shared.log("[\(logCategory(for: kind))] Live recording paused at \(String(format: "%.1f", d))s (\(c) segments).")
        }
    }

    /// Resumes polling and downloading newly published live segments.
    public func resumeRecording() {
        guard case .paused(let d, let c, let b) = state else { return }
        self.isPaused = false
        self.state = .recording(duration: d, segmentCount: c, bytesWritten: b)
        Task {
            await self.persistSessionCheckpoint(state: "recording")
        }
        if let kind = activeRequest?.manifestKind {
            PipelineLogger.shared.log("[\(logCategory(for: kind))] Live recording resumed.")
        }
    }

    /// Stops the live capture and finalizes all downloaded segments into the destination media file.
    public func stopRecording() async throws -> URL {
        guard activeRequest != nil, sessionDirectory != nil else {
            throw LiveStreamRecorderError.notRecording
        }

        self.recordingTask?.cancel()
        self.recordingTask = nil

        return try await finalizeRecording()
    }

    /// Halts capture immediately and deletes all temporary segment files from disk.
    public func cancelRecording() {
        self.recordingTask?.cancel()
        self.recordingTask = nil

        if let sid = currentSessionID {
            Task {
                try? await self.recordingStore?.delete(sessionID: sid)
            }
        }

        if let scratchDir = sessionDirectory {
            do {
                try FileManager.default.removeItem(at: scratchDir)
            } catch {
                PipelineLogger.shared.log("[LiveStreamRecorder] Failed to remove scratchDir: \(error)")
            }
        }

        #if canImport(UIKit) && !os(watchOS)
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
        #endif

        if let kind = activeRequest?.manifestKind {
            PipelineLogger.shared.log("[\(logCategory(for: kind))] Live recording cancelled by user. Cleaned scratch files.")
        }

        self.sessionDirectory = nil
        self.activeRequest = nil
        self.currentSessionID = nil
        self.recordedSegments.removeAll()
        self.initializationSegmentURLs.removeAll()
        self.committedSegmentKeys.removeAll()
        self.failedSegmentAttempts.removeAll()
        self.cachedKeyData.removeAll()
        self.state = .cancelled
    }

    // MARK: - Recovery APIs

    /// Scans for interrupted live recording sessions stored durably on disk.
    public func recoverInterruptedRecordings() async -> [LiveRecordingRecoverySummary] {
        guard let store = recordingStore else { return [] }
        let records = await store.allInterruptedRecords()
        return records.map { LiveRecordingRecoverySummary(record: $0) }
    }

    /// Recovers and finalizes an interrupted recording session directly from disk.
    public func finalizeInterruptedRecording(sessionID: String, destinationURL: URL? = nil) async throws -> URL {
        guard let store = recordingStore else {
            throw LiveStreamRecorderError.sessionNotFound(sessionID)
        }
        guard let record = await store.load(sessionID: sessionID) else {
            throw LiveStreamRecorderError.sessionNotFound(sessionID)
        }

        let scratchDir = URL(fileURLWithPath: record.scratchDirectoryPath)
        guard FileManager.default.fileExists(atPath: scratchDir.path) else {
            try? await store.delete(sessionID: sessionID)
            throw LiveStreamRecorderError.assemblyFailed("Scratch directory for session \(sessionID) no longer exists.")
        }

        let targetDestination = destinationURL ?? record.request.destinationURL
        let finalURL = try await assembleRecordingOutput(
            segments: record.recordedSegments,
            initializationSegments: record.initializationSegmentURLs,
            destinationURL: targetDestination,
            scratchDir: scratchDir
        )

        try? await store.delete(sessionID: sessionID)
        try? FileManager.default.removeItem(at: scratchDir)
        return finalURL
    }

    // MARK: - Internal Polling Loop

    private func runRecordingLoop(request: LiveRecordingRequest, scratchDir: URL) async {
        var pollInterval: Double = 3.0
        var consecutiveErrors: Int = 0

        while !Task.isCancelled {
            if isPaused {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            do {
                let manifestData = try await fetchManifestData(url: request.manifestURL, requestContext: request.requestContext)
                consecutiveErrors = 0

                switch request.manifestKind {
                case .hls:
                    let nextInterval = try await processLiveHLSManifest(
                        manifestData: manifestData,
                        request: request,
                        scratchDir: scratchDir
                    )
                    if let interval = nextInterval {
                        pollInterval = max(1.0, min(interval, 10.0))
                    }

                case .dash:
                    let nextInterval = try await processLiveDASHManifest(
                        manifestData: manifestData,
                        request: request,
                        scratchDir: scratchDir
                    )
                    if let interval = nextInterval {
                        pollInterval = max(1.0, min(interval, 10.0))
                    }

                default:
                    throw LiveStreamRecorderError.streamIsNotLive
                }

            } catch {
                consecutiveErrors += 1
                PipelineLogger.shared.log(
                    "[\(logCategory(for: request.manifestKind))] Manifest poll error (count=\(consecutiveErrors)): \(error.localizedDescription)"
                )

                if consecutiveErrors >= 10 {
                    let err = "Live stream interrupted: server failed to respond after multiple attempts."
                    self.state = .failed(error: err)
                    await self.persistSessionCheckpoint(state: "failed")
                    return
                }
            }

            let sleepNanos = UInt64(pollInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNanos)
        }
    }

    // MARK: - HLS Live Processing

    private func processLiveHLSManifest(
        manifestData: Data,
        request: LiveRecordingRequest,
        scratchDir: URL
    ) async throws -> Double? {
        guard let text = String(data: manifestData, encoding: .utf8) else {
            throw ManifestParserError.malformed(reason: "Manifest is not valid UTF-8.")
        }

        let manifest = try HLSManifestParser.parse(text, baseURL: request.manifestURL)

        if manifest.playlistType == .master {
            let targetMediaURL: URL
            let selectedVariant: HLSVariant?

            if let prefURI = request.preferredQualityOption?.uri {
                targetMediaURL = prefURI
                selectedVariant = manifest.variants.first(where: { $0.uri == prefURI })
            } else if let topVariant = manifest.variants.sorted(by: { $0.bandwidth > $1.bandwidth }).first {
                targetMediaURL = topVariant.uri
                selectedVariant = topVariant
            } else {
                throw LiveStreamRecorderError.noSegmentsDiscovered
            }

            let subData = try await fetchManifestData(url: targetMediaURL, requestContext: request.requestContext)
            guard let subText = String(data: subData, encoding: .utf8) else {
                throw ManifestParserError.malformed(reason: "Media playlist is not valid UTF-8.")
            }
            let mediaManifest = try HLSManifestParser.parse(subText, baseURL: targetMediaURL)
            let videoInterval = try await recordHLSMediaSegments(
                manifest: mediaManifest,
                trackKind: "video",
                request: request,
                scratchDir: scratchDir
            )

            // Capture external audio rendition if referenced by audioGroup
            if let audioGroup = selectedVariant?.audioGroup,
               let audioRendition = manifest.renditions.first(where: {
                   $0.type.uppercased() == "AUDIO" && $0.groupID == audioGroup && $0.uri != nil && $0.uri != targetMediaURL
               }),
               let audioURL = audioRendition.uri {
                if let audioData = try? await fetchManifestData(url: audioURL, requestContext: request.requestContext),
                   let audioText = String(data: audioData, encoding: .utf8),
                   let audioManifest = try? HLSManifestParser.parse(audioText, baseURL: audioURL) {
                    _ = try? await recordHLSMediaSegments(
                        manifest: audioManifest,
                        trackKind: "audio",
                        request: request,
                        scratchDir: scratchDir
                    )
                }
            }

            return videoInterval
        } else {
            return try await recordHLSMediaSegments(
                manifest: manifest,
                trackKind: "muxed",
                request: request,
                scratchDir: scratchDir
            )
        }
    }

    private func recordHLSMediaSegments(
        manifest: HLSManifest,
        trackKind: String,
        request: LiveRecordingRequest,
        scratchDir: URL
    ) async throws -> Double? {
        if manifest.encryption == .sampleEncrypted || manifest.encryption == .unsupported {
            throw LiveStreamRecorderError.drmProtectedLiveStreamUnsupported("HLS FairPlay / SAMPLE-AES encryption detected.")
        }

        // Check for initialization map (EXT-X-MAP)
        if let map = manifest.segments.first(where: { $0.initializationMap != nil })?.initializationMap {
            try await downloadInitializationSegmentIfNeeded(
                url: map.uri,
                byteRange: map.byteRange,
                trackKind: trackKind,
                scratchDir: scratchDir,
                requestContext: request.requestContext
            )
        }

        for seg in manifest.segments {
            let key = "\(trackKind)_\(seg.sequenceNumber)_\(seg.uri.absoluteString)_\(seg.byteRange?.length ?? -1)_\(seg.byteRange?.offset ?? -1)"
            if committedSegmentKeys.contains(key) {
                continue
            }

            let segOrder = recordedSegments.count
            let segExt = seg.uri.pathExtension.isEmpty ? (trackKind == "audio" ? "aac" : "ts") : seg.uri.pathExtension
            let localURL = scratchDir.appendingPathComponent("seg_\(trackKind)_\(String(format: "%06d", segOrder)).\(segExt)")

            var downloadedBytes: Int64? = nil
            for attempt in 1...3 {
                do {
                    let bytes = try await downloadAndProcessSegment(
                        url: seg.uri,
                        byteRange: seg.byteRange,
                        encryption: seg.encryption ?? manifest.encryption,
                        sequenceNumber: seg.sequenceNumber,
                        destination: localURL,
                        requestContext: request.requestContext
                    )
                    downloadedBytes = bytes
                    break
                } catch {
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt * 100_000_000))
                    }
                }
            }

            if let bytes = downloadedBytes, bytes > 0 {
                let recorded = LiveRecordedSegment(
                    sequenceNumber: seg.sequenceNumber,
                    uri: seg.uri,
                    duration: seg.duration,
                    localFileURL: localURL,
                    byteCount: bytes,
                    trackKind: trackKind,
                    byteRangeLength: seg.byteRange?.length,
                    byteRangeOffset: seg.byteRange?.offset
                )
                self.recordedSegments.append(recorded)
                self.committedSegmentKeys.insert(key)
                self.recordedDurationSeconds += seg.duration
                self.recordedSegmentCount += 1
                self.bytesWritten += bytes

                if !isPaused {
                    self.state = .recording(
                        duration: self.recordedDurationSeconds,
                        segmentCount: self.recordedSegmentCount,
                        bytesWritten: self.bytesWritten
                    )
                }

                await persistSessionCheckpoint(state: "recording")

                PipelineLogger.shared.log(
                    "[Live HLS Recording] Segment [\(trackKind)] #\(segOrder) recorded (\(bytes) bytes, \(String(format: "%.1f", seg.duration))s). Total: \(String(format: "%.1f", self.recordedDurationSeconds))s"
                )
            } else {
                failedSegmentAttempts[key, default: 0] += 1
                PipelineLogger.shared.log(
                    "[Live HLS Recording] Failed downloading segment '\(seg.uri.lastPathComponent)' (attempts=\(failedSegmentAttempts[key]!))"
                )
            }
        }

        if manifest.lifecycle == .vod {
            PipelineLogger.shared.log("[Live HLS Recording] #EXT-X-ENDLIST detected: live broadcast concluded. Finalizing recording automatically.")
            _ = try await stopRecording()
            return nil
        }

        if manifest.isLowLatency, let partTarget = manifest.partTargetDuration {
            return partTarget
        }
        return manifest.targetDuration ?? (manifest.segments.last?.duration ?? 4.0)
    }

    // MARK: - DASH Live Processing

    private func processLiveDASHManifest(
        manifestData: Data,
        request: LiveRecordingRequest,
        scratchDir: URL
    ) async throws -> Double? {
        let inspection = try LIDDASHStreamAdapter.validateForPlayback(
            manifestData: manifestData,
            baseURL: request.manifestURL,
            preferredRepresentationID: request.preferredQualityOption?.dashVideoRepresentationID
        )

        guard inspection.isDynamicLive else {
            throw LiveStreamRecorderError.streamIsNotLive
        }

        guard let rep = inspection.selectedRepresentation else {
            throw LiveStreamRecorderError.noSegmentsDiscovered
        }

        var pollInterval = 4.0
        if let minBuffer = inspection.manifest.minBufferTime, minBuffer > 0 {
            pollInterval = minBuffer
        }

        let template = rep.segmentTemplate ?? inspection.manifest.periods.first?.adaptationSets.first(where: {
            $0.representations.contains(where: { $0.id == rep.id })
        })?.segmentTemplate

        // Download initialization segment if present
        if let template = template, let initPattern = template.initialization, !initPattern.isEmpty {
            let expandedInitURL = try expandDASHPattern(
                initPattern,
                representation: rep,
                number: template.startNumber,
                time: template.presentationTimeOffset,
                baseURL: rep.baseURL ?? request.manifestURL
            )
            try await downloadInitializationSegmentIfNeeded(
                url: expandedInitURL,
                byteRange: nil,
                trackKind: "video",
                scratchDir: scratchDir,
                requestContext: request.requestContext
            )
        }

        if let template = template, !template.timeline.isEmpty, let mediaPattern = template.media {
            var runningTime: Int64 = template.presentationTimeOffset
            let timescale = template.timescale > 0 ? template.timescale : 1000

            for (idx, entry) in template.timeline.enumerated() {
                if let s = entry.start {
                    runningTime = s
                }
                let duration = max(1, entry.duration)
                let repeatCount: Int

                if entry.repeatCount >= 0 {
                    repeatCount = min(entry.repeatCount, 1000)
                } else if entry.repeatCount == -1 {
                    if let nextStart = template.timeline.dropFirst(idx + 1).first?.start, nextStart > runningTime {
                        let span = nextStart - runningTime
                        repeatCount = max(0, Int(span / duration) - 1)
                    } else {
                        let bufferDepthUnits = Int64(pollInterval * Double(timescale) * 3)
                        let estimatedUnits = max(duration, bufferDepthUnits)
                        repeatCount = max(0, min(30, Int(estimatedUnits / duration)))
                    }
                } else {
                    repeatCount = 0
                }

                for r in 0...repeatCount {
                    let segTime = runningTime + Int64(r) * duration
                    let key = "dash_video_\(rep.id ?? "rep")_\(segTime)"
                    if committedSegmentKeys.contains(key) {
                        continue
                    }

                    let segDuration = Double(duration) / Double(timescale)
                    let segURL = try expandDASHPattern(
                        mediaPattern,
                        representation: rep,
                        number: Int64(recordedSegments.count + 1),
                        time: segTime,
                        baseURL: rep.baseURL ?? request.manifestURL
                    )

                    let segOrder = recordedSegments.count
                    let localURL = scratchDir.appendingPathComponent("seg_\(String(format: "%06d", segOrder)).m4s")

                    var downloadedBytes: Int64? = nil
                    for attempt in 1...3 {
                        do {
                            let bytes = try await downloadAndProcessSegment(
                                url: segURL,
                                byteRange: nil,
                                encryption: nil,
                                sequenceNumber: Int64(segOrder),
                                destination: localURL,
                                requestContext: request.requestContext
                            )
                            downloadedBytes = bytes
                            break
                        } catch {
                            if attempt < 3 {
                                try? await Task.sleep(nanoseconds: UInt64(attempt * 100_000_000))
                            }
                        }
                    }

                    if let bytes = downloadedBytes, bytes > 0 {
                        let recorded = LiveRecordedSegment(
                            sequenceNumber: Int64(segOrder),
                            uri: segURL,
                            duration: segDuration,
                            localFileURL: localURL,
                            byteCount: bytes,
                            trackKind: "video"
                        )
                        self.recordedSegments.append(recorded)
                        self.committedSegmentKeys.insert(key)
                        self.recordedDurationSeconds += segDuration
                        self.recordedSegmentCount += 1
                        self.bytesWritten += bytes

                        if !isPaused {
                            self.state = .recording(
                                duration: self.recordedDurationSeconds,
                                segmentCount: self.recordedSegmentCount,
                                bytesWritten: self.bytesWritten
                            )
                        }

                        await persistSessionCheckpoint(state: "recording")
                    } else {
                        failedSegmentAttempts[key, default: 0] += 1
                        PipelineLogger.shared.log(
                            "[Live DASH Recording] Failed downloading chunk at time=\(segTime) (attempts=\(failedSegmentAttempts[key]!))"
                        )
                    }
                }
                runningTime += Int64(repeatCount + 1) * duration
            }
        } else if let template = template, let segDurationUnits = template.duration, segDurationUnits > 0, let mediaPattern = template.media {
            // Duration-based template when timeline is empty
            let timescale = template.timescale > 0 ? template.timescale : 1000
            let segDuration = Double(segDurationUnits) / Double(timescale)
            let baseNumber = template.startNumber > 0 ? template.startNumber : 1
            let currentNumber = max(baseNumber, baseNumber + Int64(recordedSegments.count))

            for segNumber in currentNumber...(currentNumber + 2) {
                let segTime = template.presentationTimeOffset + (segNumber - baseNumber) * segDurationUnits
                let key = "dash_video_\(rep.id ?? "rep")_num_\(segNumber)"
                if committedSegmentKeys.contains(key) {
                    continue
                }

                let segURL = try expandDASHPattern(
                    mediaPattern,
                    representation: rep,
                    number: segNumber,
                    time: segTime,
                    baseURL: rep.baseURL ?? request.manifestURL
                )

                let segOrder = recordedSegments.count
                let localURL = scratchDir.appendingPathComponent("seg_\(String(format: "%06d", segOrder)).m4s")

                var downloadedBytes: Int64? = nil
                for attempt in 1...3 {
                    do {
                        let bytes = try await downloadAndProcessSegment(
                            url: segURL,
                            byteRange: nil,
                            encryption: nil,
                            sequenceNumber: Int64(segOrder),
                            destination: localURL,
                            requestContext: request.requestContext
                        )
                        downloadedBytes = bytes
                        break
                    } catch {
                        if attempt < 3 {
                            try? await Task.sleep(nanoseconds: UInt64(attempt * 100_000_000))
                        }
                    }
                }

                if let bytes = downloadedBytes, bytes > 0 {
                    let recorded = LiveRecordedSegment(
                        sequenceNumber: segNumber,
                        uri: segURL,
                        duration: segDuration,
                        localFileURL: localURL,
                        byteCount: bytes,
                        trackKind: "video"
                    )
                    self.recordedSegments.append(recorded)
                    self.committedSegmentKeys.insert(key)
                    self.recordedDurationSeconds += segDuration
                    self.recordedSegmentCount += 1
                    self.bytesWritten += bytes

                    if !isPaused {
                        self.state = .recording(
                            duration: self.recordedDurationSeconds,
                            segmentCount: self.recordedSegmentCount,
                            bytesWritten: self.bytesWritten
                        )
                    }

                    await persistSessionCheckpoint(state: "recording")
                } else {
                    failedSegmentAttempts[key, default: 0] += 1
                }
            }
        } else {
            throw LiveStreamRecorderError.noSegmentsDiscovered
        }

        return pollInterval
    }

    // MARK: - Finalization & Assembly

    private func finalizeRecording() async throws -> URL {
        self.state = .finalizing
        guard let request = activeRequest, let scratchDir = sessionDirectory else {
            throw LiveStreamRecorderError.notRecording
        }

        guard !recordedSegments.isEmpty else {
            throw LiveStreamRecorderError.noSegmentsDiscovered
        }

        let cat = logCategory(for: request.manifestKind)
        PipelineLogger.shared.log("[\(cat)] Finalizing \(recordedSegments.count) segments into \(request.destinationURL.lastPathComponent)")

        let finalOutputURL = try await assembleRecordingOutput(
            segments: recordedSegments,
            initializationSegments: initializationSegmentURLs,
            destinationURL: request.destinationURL,
            scratchDir: scratchDir
        )

        if let sid = currentSessionID {
            try? await recordingStore?.delete(sessionID: sid)
        }

        do {
            try FileManager.default.removeItem(at: scratchDir)
        } catch {
            PipelineLogger.shared.log("[LiveStreamRecorder] Failed to remove scratchDir: \(error)")
        }

        #if canImport(UIKit) && !os(watchOS)
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
        #endif

        self.sessionDirectory = nil
        self.activeRequest = nil
        self.currentSessionID = nil

        self.state = .completed(
            outputURL: finalOutputURL,
            duration: self.recordedDurationSeconds,
            bytesWritten: self.bytesWritten
        )

        PipelineLogger.shared.log(
            "[\(cat)] Live recording successfully completed -> \(finalOutputURL.lastPathComponent) (\(self.bytesWritten) bytes, \(String(format: "%.1f", self.recordedDurationSeconds))s)"
        )

        return finalOutputURL
    }

    private func assembleRecordingOutput(
        segments: [LiveRecordedSegment],
        initializationSegments: [URL],
        destinationURL: URL,
        scratchDir: URL
    ) async throws -> URL {
        let destDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var detectedContainer: DetectedFileType? = nil
        if let firstInit = initializationSegments.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            detectedContainer = FileTypeDetector.detect(fileAt: firstInit)
        } else if let firstSeg = segments.first(where: { FileManager.default.fileExists(atPath: $0.localFileURL.path) }) {
            detectedContainer = FileTypeDetector.detect(fileAt: firstSeg.localFileURL)
        }

        let isMPEGTS = (detectedContainer == .mpegTS)
        let isFMP4 = (detectedContainer == .fragmentedMP4 || detectedContainer == .isoBaseMediaFile)

        let targetURL: URL
        let requestedExt = destinationURL.pathExtension.lowercased()
        if isMPEGTS && requestedExt != "ts" {
            targetURL = destinationURL.deletingPathExtension().appendingPathExtension("ts")
        } else if isFMP4 && requestedExt == "ts" {
            targetURL = destinationURL.deletingPathExtension().appendingPathExtension("mp4")
        } else {
            targetURL = destinationURL
        }

        let stagingOutputURL = scratchDir.appendingPathComponent("assembled_live_output.\(targetURL.pathExtension)")
        if FileManager.default.fileExists(atPath: stagingOutputURL.path) {
            try? FileManager.default.removeItem(at: stagingOutputURL)
        }
        FileManager.default.createFile(atPath: stagingOutputURL.path, contents: nil)

        guard let outHandle = try? FileHandle(forWritingTo: stagingOutputURL) else {
            throw LiveStreamRecorderError.assemblyFailed("Could not open handle for staging file at \(stagingOutputURL.path)")
        }
        defer { try? outHandle.close() }

        // 1. Write initialization segment(s) FIRST (essential for fMP4 and DASH)
        for initURL in initializationSegments {
            guard FileManager.default.fileExists(atPath: initURL.path) else { continue }
            if let inHandle = try? FileHandle(forReadingFrom: initURL) {
                defer { try? inHandle.close() }
                let bufferSize = 64 * 1024
                while true {
                    let chunk = inHandle.readData(ofLength: bufferSize)
                    if chunk.isEmpty { break }
                    outHandle.write(chunk)
                }
            }
        }

        // 2. Write media segments in sequential recorded order
        for seg in segments {
            guard FileManager.default.fileExists(atPath: seg.localFileURL.path) else { continue }
            if let inHandle = try? FileHandle(forReadingFrom: seg.localFileURL) {
                defer { try? inHandle.close() }
                let bufferSize = 64 * 1024
                while true {
                    let chunk = inHandle.readData(ofLength: bufferSize)
                    if chunk.isEmpty { break }
                    outHandle.write(chunk)
                }
            }
        }
        try outHandle.synchronize()

        // 3. Move staging file to final target destination
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.moveItem(at: stagingOutputURL, to: targetURL)

        let finalBytes = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int64) ?? bytesWritten
        self.bytesWritten = finalBytes

        _ = await (libraryStore ?? .shared).scanLibrary(in: destDir)
        return targetURL
    }

    // MARK: - Segment & Key Helpers

    private func downloadInitializationSegmentIfNeeded(
        url: URL,
        byteRange: HLSByteRange?,
        trackKind: String,
        scratchDir: URL,
        requestContext: BrowserRequestContext?
    ) async throws {
        let key = "init_\(trackKind)_\(url.absoluteString)_\(byteRange?.length ?? -1)_\(byteRange?.offset ?? -1)"
        if committedSegmentKeys.contains(key) { return }

        let initFileName = "init_\(trackKind)_\(initializationSegmentURLs.count).mp4"
        let localURL = scratchDir.appendingPathComponent(initFileName)

        _ = try await downloadAndProcessSegment(
            url: url,
            byteRange: byteRange,
            encryption: nil,
            sequenceNumber: 0,
            destination: localURL,
            requestContext: requestContext
        )

        initializationSegmentURLs.append(localURL)
        committedSegmentKeys.insert(key)
        PipelineLogger.shared.log("[LiveStreamRecorder] Downloaded initialization segment for track '\(trackKind)' (\(localURL.lastPathComponent))")
    }

    private func downloadAndProcessSegment(
        url: URL,
        byteRange: HLSByteRange?,
        encryption: HLSEncryption?,
        sequenceNumber: Int64,
        destination: URL,
        requestContext: BrowserRequestContext?
    ) async throws -> Int64 {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15.0
        if let headers = requestContext?.effectiveHeaders(for: url) {
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }

        if let br = byteRange {
            let offset = br.offset ?? 0
            let end = offset + br.length - 1
            req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LiveStreamRecorderError.manifestFetchFailed("Segment HTTP \(code)")
        }

        var segmentPayload = data
        if let br = byteRange, http.statusCode == 200 {
            let offset = Int(br.offset ?? 0)
            let len = Int(br.length)
            if offset < data.count {
                let sliceEnd = min(data.count, offset + len)
                segmentPayload = data.subdata(in: offset..<sliceEnd)
            }
        }

        if let enc = encryption {
            switch enc.classification {
            case .aes128:
                guard let keyURL = enc.keyURL else {
                    throw LiveStreamRecorderError.unsupportedLiveEncryption("AES-128 segment has no key URL.")
                }
                let keyData: Data
                if let cached = cachedKeyData[keyURL] {
                    keyData = cached
                } else {
                    do {
                        let fetched = try await fetchKeyData(url: keyURL, requestContext: requestContext)
                        cachedKeyData[keyURL] = fetched
                        keyData = fetched
                    } catch {
                        throw LiveStreamRecorderError.unsupportedLiveEncryption("Failed to fetch AES-128 key from \(keyURL.absoluteString): \(error.localizedDescription)")
                    }
                }

                let ivData: Data
                if let ivStr = enc.iv, let parsed = HLSSegmentDecryptor.parseIV(ivStr) {
                    ivData = parsed
                } else {
                    ivData = HLSSegmentDecryptor.ivForSequenceNumber(sequenceNumber)
                }

                do {
                    segmentPayload = try HLSSegmentDecryptor.decrypt(data: segmentPayload, key: keyData, iv: ivData)
                } catch {
                    throw LiveStreamRecorderError.unsupportedLiveEncryption("AES-128 decryption failed: \(error.localizedDescription)")
                }

            case .sampleEncrypted, .unsupported:
                throw LiveStreamRecorderError.drmProtectedLiveStreamUnsupported("Encrypted live segment (classification=\(enc.classification.rawValue)) cannot be recorded.")

            case .clear:
                break
            }
        }

        try segmentPayload.write(to: destination, options: .atomic)
        return Int64(segmentPayload.count)
    }

    private func fetchKeyData(url: URL, requestContext: BrowserRequestContext?) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        if let headers = requestContext?.effectiveHeaders(for: url) {
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw LiveStreamRecorderError.unsupportedLiveEncryption("HTTP key fetch status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }

    private func expandDASHPattern(
        _ pattern: String,
        representation: DASHRepresentation,
        number: Int64,
        time: Int64,
        baseURL: URL
    ) throws -> URL {
        var output = ""
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            guard characters[index] == "$" else {
                output.append(characters[index])
                index += 1
                continue
            }
            if index + 1 < characters.count && characters[index + 1] == "$" {
                output.append("$")
                index += 2
                continue
            }
            guard let end = characters[(index + 1)...].firstIndex(of: "$"), end > index + 1 else {
                output.append(characters[index])
                index += 1
                continue
            }
            let token = String(characters[(index + 1)..<end])
            let pieces = token.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pieces[0])
            var val = ""
            switch name {
            case "RepresentationID":
                val = representation.id ?? "1"
            case "Bandwidth":
                val = representation.bandwidth.map { String($0) } ?? "0"
            case "Number":
                val = String(number)
            case "Time":
                val = String(time)
            default:
                val = token
            }
            if pieces.count == 2 && pieces[1].hasSuffix("d") {
                let format = String(pieces[1].dropLast())
                if let width = Int(format), width > 0 {
                    val = String(repeating: "0", count: max(0, width - val.count)) + val
                }
            }
            output += val
            index = end + 1
        }

        if let direct = URL(string: output, relativeTo: baseURL)?.absoluteURL {
            return direct
        }
        throw LiveStreamRecorderError.assemblyFailed("Invalid expanded DASH URL: \(output)")
    }

    private func persistSessionCheckpoint(state: String) async {
        guard let sessionID = currentSessionID, let req = activeRequest, let scratchDir = sessionDirectory else { return }
        let record = LiveRecordingRecord(
            id: sessionID,
            request: req,
            state: state,
            recordedDurationSeconds: self.recordedDurationSeconds,
            recordedSegmentCount: self.recordedSegmentCount,
            bytesWritten: self.bytesWritten,
            recordedSegments: self.recordedSegments,
            initializationSegmentURLs: self.initializationSegmentURLs,
            committedSegmentKeys: Array(self.committedSegmentKeys),
            scratchDirectoryPath: scratchDir.path,
            outputContainerFormat: req.destinationURL.pathExtension,
            updatedAt: Date()
        )
        try? await recordingStore?.save(record: record)
    }

    // MARK: - Network Helpers

    private func fetchManifestData(url: URL, requestContext: BrowserRequestContext?) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10.0
        if let headers = requestContext?.effectiveHeaders(for: url) {
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }

        let (data, response) = try await urlSession.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw LiveStreamRecorderError.manifestFetchFailed("HTTP \(http.statusCode)")
        }
        return data
    }

    private func logCategory(for kind: StreamingManifestKind) -> String {
        switch kind {
        case .hls: return "Live HLS Recording"
        case .dash: return "Live DASH Recording"
        default: return "Live Recording"
        }
    }
}
