import Foundation

#if canImport(Combine)
import Combine
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
public struct LiveRecordingRequest: Sendable {
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
public struct LiveRecordedSegment: Equatable, Sendable {
    public let sequenceNumber: Int64
    public let uri: URL
    public let duration: Double
    public let localFileURL: URL
    public let byteCount: Int64

    public init(
        sequenceNumber: Int64,
        uri: URL,
        duration: Double,
        localFileURL: URL,
        byteCount: Int64
    ) {
        self.sequenceNumber = sequenceNumber
        self.uri = uri
        self.duration = duration
        self.localFileURL = localFileURL
        self.byteCount = byteCount
    }
}

/// Errors occurring during live stream recording lifecycle.
public enum LiveStreamRecorderError: LocalizedError, Equatable, Sendable {
    case invalidManifestURL
    case manifestFetchFailed(String)
    case streamIsNotLive
    case drmProtectedLiveStreamUnsupported(String)
    case noSegmentsDiscovered
    case assemblyFailed(String)
    case alreadyRecording
    case notRecording
    case cancelled

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
        }
    }
}

/// Coordinates sliding-window manifest polling, segment deduplication, incremental disk writing,
/// and output container assembly for live HLS broadcasts and dynamic DASH streams.
@MainActor
public final class LiveStreamRecorder: ObservableObject {

    public static let shared = LiveStreamRecorder()

    @Published public private(set) var state: LiveRecordingState = .idle
    @Published public private(set) var recordedDurationSeconds: Double = 0.0
    @Published public private(set) var recordedSegmentCount: Int = 0
    @Published public private(set) var bytesWritten: Int64 = 0
    @Published public private(set) var activeRequest: LiveRecordingRequest? = nil

    private var seenSegmentKeys = Set<String>()
    private var recordedSegments: [LiveRecordedSegment] = []
    private var recordingTask: Task<Void, Never>? = nil
    private var isPaused: Bool = false
    private var sessionDirectory: URL? = nil
    private let urlSession: URLSession
    public let libraryStore: LIDLibraryStore?

    public init(urlSession: URLSession = .shared, libraryStore: LIDLibraryStore? = nil) {
        self.urlSession = urlSession
        self.libraryStore = libraryStore
    }

    // MARK: - Recording Control APIs

    /// Initiates continuous capture of a live HLS or dynamic DASH stream.
    public func startRecording(request: LiveRecordingRequest) throws {
        guard case .idle = state else {
            throw LiveStreamRecorderError.alreadyRecording
        }

        self.activeRequest = request
        self.state = .preparing
        self.recordedDurationSeconds = 0.0
        self.recordedSegmentCount = 0
        self.bytesWritten = 0
        self.seenSegmentKeys.removeAll()
        self.recordedSegments.removeAll()
        self.isPaused = false

        let tempBase = request.temporaryDirectoryURL ?? FileManager.default.temporaryDirectory
        let sessionID = UUID().uuidString
        let scratchDir = tempBase.appendingPathComponent("LIDLiveRecording_\(sessionID)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
            self.sessionDirectory = scratchDir
        } catch {
            let msg = "Failed to create temporary recording directory: \(error.localizedDescription)"
            self.state = .failed(error: msg)
            throw LiveStreamRecorderError.assemblyFailed(msg)
        }

        PipelineLogger.shared.log(
            "[\(logCategory(for: request.manifestKind))] Starting live capture for '\(request.title)' -> \(scratchDir.lastPathComponent)"
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
        if let kind = activeRequest?.manifestKind {
            PipelineLogger.shared.log("[\(logCategory(for: kind))] Live recording paused at \(String(format: "%.1f", d))s (\(c) segments).")
        }
    }

    /// Resumes polling and downloading newly published live segments.
    public func resumeRecording() {
        guard case .paused(let d, let c, let b) = state else { return }
        self.isPaused = false
        self.state = .recording(duration: d, segmentCount: c, bytesWritten: b)
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

        if let scratchDir = sessionDirectory {
            do {
                try FileManager.default.removeItem(at: scratchDir)
            } catch {
                PipelineLogger.shared.log("[LiveStreamRecorder] Failed to remove scratchDir: \(error)")
            }
        }

        if let kind = activeRequest?.manifestKind {
            PipelineLogger.shared.log("[\(logCategory(for: kind))] Live recording cancelled by user. Cleaned scratch files.")
        }

        self.sessionDirectory = nil
        self.activeRequest = nil
        self.recordedSegments.removeAll()
        self.seenSegmentKeys.removeAll()
        self.state = .cancelled
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
                    return
                }
            }

            // Sleep with jitter prevention
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
            // Master playlist: pick preferred variant URI or highest bandwidth
            let targetMediaURL: URL
            if let prefURI = request.preferredQualityOption?.uri {
                targetMediaURL = prefURI
            } else if let topVariant = manifest.variants.sorted(by: { $0.bandwidth > $1.bandwidth }).first {
                targetMediaURL = topVariant.uri
            } else {
                throw LiveStreamRecorderError.noSegmentsDiscovered
            }

            let subData = try await fetchManifestData(url: targetMediaURL, requestContext: request.requestContext)
            guard let subText = String(data: subData, encoding: .utf8) else {
                throw ManifestParserError.malformed(reason: "Media playlist is not valid UTF-8.")
            }
            let mediaManifest = try HLSManifestParser.parse(subText, baseURL: targetMediaURL)
            return try await recordHLSMediaSegments(manifest: mediaManifest, request: request, scratchDir: scratchDir)
        } else {
            return try await recordHLSMediaSegments(manifest: manifest, request: request, scratchDir: scratchDir)
        }
    }

    private func recordHLSMediaSegments(
        manifest: HLSManifest,
        request: LiveRecordingRequest,
        scratchDir: URL
    ) async throws -> Double? {
        if manifest.encryption == .sampleEncrypted || manifest.encryption == .unsupported {
            throw LiveStreamRecorderError.drmProtectedLiveStreamUnsupported("HLS FairPlay / SAMPLE-AES encryption detected.")
        }

        var newSegmentsDiscovered = 0
        for seg in manifest.segments {
            let key = seg.uri.absoluteString
            if seenSegmentKeys.contains(key) {
                continue
            }

            seenSegmentKeys.insert(key)
            newSegmentsDiscovered += 1

            let segOrder = recordedSegments.count
            let segExt = seg.uri.pathExtension.isEmpty ? "ts" : seg.uri.pathExtension
            let localURL = scratchDir.appendingPathComponent("seg_\(String(format: "%06d", segOrder)).\(segExt)")

            do {
                let bytes = try await downloadSegmentToDisk(url: seg.uri, destination: localURL, requestContext: request.requestContext)
                let recorded = LiveRecordedSegment(
                    sequenceNumber: seg.sequenceNumber,
                    uri: seg.uri,
                    duration: seg.duration,
                    localFileURL: localURL,
                    byteCount: bytes
                )
                self.recordedSegments.append(recorded)
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

                PipelineLogger.shared.log(
                    "[Live HLS Recording] Segment #\(segOrder) recorded (\(bytes) bytes, \(String(format: "%.1f", seg.duration))s). Total: \(String(format: "%.1f", self.recordedDurationSeconds))s"
                )
            } catch {
                PipelineLogger.shared.log(
                    "[Live HLS Recording] Failed to download segment '\(seg.uri.lastPathComponent)': \(error.localizedDescription)"
                )
            }
        }

        // If the live stream broadcast concludes naturally (EXT-X-ENDLIST tag found)
        if manifest.lifecycle == .vod {
            PipelineLogger.shared.log("[Live HLS Recording] #EXT-X-ENDLIST detected: live broadcast concluded. Finalizing recording automatically.")
            _ = try await stopRecording()
            return nil
        }

        // Return polling interval: part target duration for LL-HLS, or target duration / segment duration
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

        // If SegmentTemplate is present with a timeline, extract published segments
        let template = rep.segmentTemplate ?? inspection.manifest.periods.first?.adaptationSets.first(where: { $0.representations.contains(where: { $0.id == rep.id }) })?.segmentTemplate

        if let template = template, !template.timeline.isEmpty, let mediaPattern = template.media {
            var runningTime: Int64 = template.presentationTimeOffset
            let timescale = template.timescale > 0 ? template.timescale : 1000

            for entry in template.timeline {
                if let s = entry.start {
                    runningTime = s
                }
                let repeatCount = entry.repeatCount
                for r in 0...repeatCount {
                    let segTime = runningTime + Int64(r) * entry.duration
                    let key = "\(rep.id ?? "rep")_\(segTime)"
                    if !seenSegmentKeys.contains(key) {
                        seenSegmentKeys.insert(key)
                        let segDuration = Double(entry.duration) / Double(timescale)

                        let constructed = mediaPattern
                            .replacingOccurrences(of: "$RepresentationID$", with: rep.id ?? "1")
                            .replacingOccurrences(of: "$Time$", with: String(segTime))
                        if let segURL = URL(string: constructed, relativeTo: rep.baseURL ?? request.manifestURL) {
                            let segOrder = recordedSegments.count
                            let localURL = scratchDir.appendingPathComponent("seg_\(String(format: "%06d", segOrder)).m4s")

                            if let bytes = try? await downloadSegmentToDisk(url: segURL, destination: localURL, requestContext: request.requestContext) {
                                let recorded = LiveRecordedSegment(
                                    sequenceNumber: Int64(segOrder),
                                    uri: segURL,
                                    duration: segDuration,
                                    localFileURL: localURL,
                                    byteCount: bytes
                                )
                                self.recordedSegments.append(recorded)
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
                            }
                        }
                    }
                }
                runningTime += Int64(repeatCount + 1) * entry.duration
            }
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

        // Ensure parent directory of destination exists
        let destDir = request.destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let isDestinationTS = request.destinationURL.pathExtension.lowercased() == "ts"
        let stagingOutputURL = scratchDir.appendingPathComponent("final_assembled.\(isDestinationTS ? "ts" : "mp4")")

        // 1. Direct packet-safe ordered concatenation
        do {
            FileManager.default.createFile(atPath: stagingOutputURL.path, contents: nil)
            let outHandle = try FileHandle(forWritingTo: stagingOutputURL)
            defer { try? outHandle.close() }

            for seg in recordedSegments {
                guard FileManager.default.fileExists(atPath: seg.localFileURL.path) else { continue }
                do {
                    let segHandle = try FileHandle(forReadingFrom: seg.localFileURL)
                    defer { try? segHandle.close() }
                    let bufferSize = 64 * 1024
                    while true {
                        let chunk = segHandle.readData(ofLength: bufferSize)
                        if chunk.isEmpty { break }
                        outHandle.write(chunk)
                    }
                }
            }
            try outHandle.synchronize()
        } catch {
            let msg = "Failed to concatenate live segments: \(error.localizedDescription)"
            self.state = .failed(error: msg)
            throw LiveStreamRecorderError.assemblyFailed(msg)
        }

        // 2. Publish to final destination safely
        let finalOutputURL = request.destinationURL
        if FileManager.default.fileExists(atPath: finalOutputURL.path) {
            do {
                try FileManager.default.removeItem(at: finalOutputURL)
            } catch {
                PipelineLogger.shared.log("[LiveStreamRecorder] Failed to remove existing output file: \(error)")
            }
        }

        do {
            try FileManager.default.moveItem(at: stagingOutputURL, to: finalOutputURL)
        } catch {
            let msg = "Failed to publish finalized recording: \(error.localizedDescription)"
            self.state = .failed(error: msg)
            throw LiveStreamRecorderError.assemblyFailed(msg)
        }

        let finalBytes = (try? FileManager.default.attributesOfItem(atPath: finalOutputURL.path)[.size] as? Int64) ?? bytesWritten
        self.bytesWritten = finalBytes

        // 3. Register with LIDLibraryStore
        _ = await (libraryStore ?? .shared).scanLibrary(in: destDir)

        // 4. Clean up scratch directory
        do {
            try FileManager.default.removeItem(at: scratchDir)
        } catch {
            PipelineLogger.shared.log("[LiveStreamRecorder] Failed to remove scratchDir: \(error)")
        }
        self.sessionDirectory = nil
        self.activeRequest = nil

        self.state = .completed(
            outputURL: finalOutputURL,
            duration: self.recordedDurationSeconds,
            bytesWritten: finalBytes
        )

        PipelineLogger.shared.log(
            "[\(cat)] Live recording successfully completed -> \(finalOutputURL.lastPathComponent) (\(finalBytes) bytes, \(String(format: "%.1f", self.recordedDurationSeconds))s)"
        )

        return finalOutputURL
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

    private func downloadSegmentToDisk(url: URL, destination: URL, requestContext: BrowserRequestContext?) async throws -> Int64 {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15.0
        if let headers = requestContext?.effectiveHeaders(for: url) {
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }

        let (tempURL, response) = try await urlSession.download(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw LiveStreamRecorderError.manifestFetchFailed("Segment HTTP \(http.statusCode)")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                PipelineLogger.shared.log("[LiveStreamRecorder] Failed to remove destination segment: \(error)")
            }
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        return attrs[.size] as? Int64 ?? 0
    }

    private func logCategory(for kind: StreamingManifestKind) -> String {
        switch kind {
        case .hls: return "Live HLS Recording"
        case .dash: return "Live DASH Recording"
        default: return "Live Recording"
        }
    }
}
