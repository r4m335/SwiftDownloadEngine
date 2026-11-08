import Foundation

#if canImport(WebKit)
import WebKit
#endif

/// Narrow MSE capture support surface for 7H.4.
///
/// The prototype reconstructs only clear, single- or dual-track fMP4 sessions
/// (and single-track MPEG-TS). WebM, encrypted media, and arbitrary buffer
/// layouts are reported as unsupported rather than published as playable files.
public enum BrowserMSECaptureContainerHint: String, Codable, Sendable, Equatable {
    case fragmentedMP4
    case mpegTS
    case unsupported
}

public enum BrowserMSECaptureTrackKind: String, Codable, Sendable, Equatable {
    case video
    case audio
    case unknown
}

public enum BrowserMSECaptureSupportStatus: String, Codable, Sendable, Equatable {
    case capturable
    case unsupported
    case protectedMedia
}

public struct BrowserMSECaptureSupport: Sendable, Equatable {
    public let status: BrowserMSECaptureSupportStatus
    public let container: BrowserMSECaptureContainerHint
    public let reason: String

    public init(
        status: BrowserMSECaptureSupportStatus,
        container: BrowserMSECaptureContainerHint,
        reason: String
    ) {
        self.status = status
        self.container = container
        self.reason = reason
    }

    public var isCapturable: Bool { status == .capturable }
}

public struct BrowserMSECaptureBufferMetadata: Sendable, Equatable {
    public let trackIndex: Int
    public let mimeType: String
    public let codecs: [String]
    public let kind: BrowserMSECaptureTrackKind

    public init(trackIndex: Int, mimeType: String, codecs: [String], kind: BrowserMSECaptureTrackKind) {
        self.trackIndex = trackIndex
        self.mimeType = mimeType
        self.codecs = codecs
        self.kind = kind
    }
}

public struct BrowserMSECaptureAppendEvent: Sendable, Equatable {
    public let chunkIndex: Int
    public let trackIndex: Int
    public let segmentIndex: Int
    public let byteCount: Int64
    public let timestampOffset: Double?
    public let appendTimestamp: Double?

    public init(
        chunkIndex: Int,
        trackIndex: Int,
        segmentIndex: Int,
        byteCount: Int64,
        timestampOffset: Double? = nil,
        appendTimestamp: Double? = nil
    ) {
        self.chunkIndex = chunkIndex
        self.trackIndex = trackIndex
        self.segmentIndex = segmentIndex
        self.byteCount = byteCount
        self.timestampOffset = timestampOffset
        self.appendTimestamp = appendTimestamp
    }
}

public enum BrowserMSECaptureSupportClassifier {
    /// Evaluates whether a MediaSource MIME list can be reconstructed by the
    /// current prototype. Protection always wins over codec support.
    public static func evaluate(
        mimeTypes: [String],
        isPotentiallyProtected: Bool = false
    ) -> BrowserMSECaptureSupport {
        if isPotentiallyProtected {
            return BrowserMSECaptureSupport(
                status: .protectedMedia,
                container: .unsupported,
                reason: "Encrypted Media Extensions activity was observed; DRM-protected playback is not captured."
            )
        }

        let normalized = mimeTypes
            .map(normalizeMIME)
            .compactMap { $0 }
        guard !normalized.isEmpty else {
            return BrowserMSECaptureSupport(
                status: .unsupported,
                container: .unsupported,
                reason: "No SourceBuffer MIME type has been observed yet."
            )
        }

        if normalized.contains(where: { $0.hasPrefix("video/webm") || $0.hasPrefix("audio/webm") }) {
            return BrowserMSECaptureSupport(
                status: .unsupported,
                container: .unsupported,
                reason: "WebM MSE sessions are not reconstructed by this prototype."
            )
        }

        let tracks = normalized.map(trackKind(for:))
        if normalized.count == 1 {
            let mime = normalized[0]
            if mime.hasPrefix("video/mp2t") || mime == "video/mp2t" {
                return BrowserMSECaptureSupport(
                    status: .capturable,
                    container: .mpegTS,
                    reason: "Single MPEG-TS SourceBuffer can be concatenated after validation."
                )
            }
            if mime.hasPrefix("video/mp4") || mime.hasPrefix("audio/mp4") {
                return BrowserMSECaptureSupport(
                    status: .capturable,
                    container: .fragmentedMP4,
                    reason: "Single fragmented-MP4 SourceBuffer can be reconstructed after validation."
                )
            }
            return BrowserMSECaptureSupport(
                status: .unsupported,
                container: .unsupported,
                reason: "MIME type \(mime) is outside the supported MSE capture set."
            )
        }

        if normalized.count == 2 {
            let hasVideo = tracks.contains(.video) && normalized.contains(where: { $0.hasPrefix("video/mp4") })
            let hasAudio = tracks.contains(.audio) && normalized.contains(where: { $0.hasPrefix("audio/mp4") })
            if hasVideo && hasAudio {
                return BrowserMSECaptureSupport(
                    status: .capturable,
                    container: .fragmentedMP4,
                    reason: "Separate clear fMP4 audio and video SourceBuffers can be muxed after validation."
                )
            }
            return BrowserMSECaptureSupport(
                status: .unsupported,
                container: .unsupported,
                reason: "Only one video/mp4 plus one audio/mp4 SourceBuffer pair is supported for dual-track capture."
            )
        }

        return BrowserMSECaptureSupport(
            status: .unsupported,
            container: .unsupported,
            reason: "More than two SourceBuffers is outside the supported MSE capture set."
        )
    }

    public static func evaluate(mimeType: String?, isPotentiallyProtected: Bool = false) -> BrowserMSECaptureSupport {
        evaluate(
            mimeTypes: mimeType.map { [$0] } ?? [],
            isPotentiallyProtected: isPotentiallyProtected
        )
    }

    public static func trackKind(for mimeType: String) -> BrowserMSECaptureTrackKind {
        let mime = normalizeMIME(mimeType) ?? ""
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        return .unknown
    }

    public static func codecs(in mimeType: String) -> [String] {
        guard let parameter = mimeType.split(separator: ";", maxSplits: 1).dropFirst().first else {
            return []
        }
        let value = parameter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("codecs=") else { return [] }
        return value.dropFirst("codecs=".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func normalizeMIME(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return result?.isEmpty == false ? result : nil
    }
}

public struct BrowserMSECaptureLimits: Sendable, Equatable {
    public let maximumBytes: Int64
    public let maximumChunkBytes: Int
    public let maximumSegmentsPerTrack: Int
    public let maximumIdentifierLength: Int

    public init(
        maximumBytes: Int64 = 512 * 1024 * 1024,
        maximumChunkBytes: Int = 256 * 1024,
        maximumSegmentsPerTrack: Int = 50_000,
        maximumIdentifierLength: Int = 128
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.maximumChunkBytes = max(1, maximumChunkBytes)
        self.maximumSegmentsPerTrack = max(1, maximumSegmentsPerTrack)
        self.maximumIdentifierLength = max(1, maximumIdentifierLength)
    }

    public static let `default` = BrowserMSECaptureLimits()
}

public enum BrowserMSECaptureLifecycle: String, Codable, Sendable, Equatable {
    case capturing
    case reconstructing
    case completed
    case failed
    case cancelled
    case unsupported
    case protectedMedia
}

public struct BrowserMSECaptureSnapshot: Sendable, Equatable {
    public let captureID: String
    public let bytesCaptured: Int64
    public let segmentCount: Int
    public let lifecycle: BrowserMSECaptureLifecycle
    public let supportReason: String?
    public let reconstructedURL: URL?
    public let temporaryDirectoryURL: URL?
    public let bufferMetadata: [BrowserMSECaptureBufferMetadata]
    public let appendSequence: [BrowserMSECaptureAppendEvent]

    public init(
        captureID: String,
        bytesCaptured: Int64,
        segmentCount: Int,
        lifecycle: BrowserMSECaptureLifecycle,
        supportReason: String? = nil,
        reconstructedURL: URL? = nil,
        temporaryDirectoryURL: URL? = nil,
        bufferMetadata: [BrowserMSECaptureBufferMetadata] = [],
        appendSequence: [BrowserMSECaptureAppendEvent] = []
    ) {
        self.captureID = captureID
        self.bytesCaptured = bytesCaptured
        self.segmentCount = segmentCount
        self.lifecycle = lifecycle
        self.supportReason = supportReason
        self.reconstructedURL = reconstructedURL
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.bufferMetadata = bufferMetadata
        self.appendSequence = appendSequence
    }

    /// True only after reconstruction validation publishes a playable file.
    public var isSuccessfullyReconstructed: Bool {
        lifecycle == .completed && reconstructedURL != nil
    }
}

public enum BrowserMSECapturePrototypeError: Error, LocalizedError, Sendable, Equatable {
    case invalidCaptureID
    case captureNotAuthorized
    case documentMismatch
    case protectedMedia
    case unsupportedSession
    case sizeLimitExceeded
    case invalidChunkSize
    case unknownCapture
    case captureAlreadyComplete
    case invalidChunkIndex
    case invalidChunkOffset
    case chunkTooLarge
    case invalidChecksum
    case checksumMismatch
    case invalidSegmentIndex
    case tooManySegments
    case missingInitializationSegment
    case invalidMediaData
    case reconstructionFailed
    case incompleteCapture
    case fileOperationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidCaptureID: return "The MSE capture identifier is invalid."
        case .captureNotAuthorized: return "The MSE capture is not authorized for this browser session."
        case .documentMismatch: return "The MSE capture belongs to a different browser document."
        case .protectedMedia: return "Protected or DRM-backed media cannot be captured."
        case .unsupportedSession: return "This MediaSource session is outside the supported capture set."
        case .sizeLimitExceeded: return "The MSE capture exceeds the configured size limit."
        case .invalidChunkSize: return "The MSE chunk size is invalid."
        case .unknownCapture: return "The MSE capture session is no longer available."
        case .captureAlreadyComplete: return "The MSE capture has already completed."
        case .invalidChunkIndex: return "The MSE chunk index is out of order."
        case .invalidChunkOffset: return "The MSE chunk offset is invalid."
        case .chunkTooLarge: return "The MSE chunk exceeds the configured bound."
        case .invalidChecksum: return "The MSE chunk checksum is invalid."
        case .checksumMismatch: return "The MSE chunk failed integrity verification."
        case .invalidSegmentIndex: return "The MSE segment index is invalid."
        case .tooManySegments: return "The MSE capture exceeded the segment count limit."
        case .missingInitializationSegment: return "A fragmented-MP4 initialization segment was not captured."
        case .invalidMediaData: return "Captured MSE bytes did not form a valid media container."
        case .reconstructionFailed: return "Captured MSE bytes could not be reconstructed into a playable file."
        case .incompleteCapture: return "The MSE capture ended before enough clear media was collected."
        case .fileOperationFailed: return "The temporary MSE capture output could not be written or finalized."
        }
    }
}

public struct BrowserMSECaptureMetadata: Codable, Sendable, Equatable {
    public let captureID: String
    public let mediaSourceURL: String
    public let documentID: String?
    public let mimeTypes: [String]
    public let isPotentiallyProtected: Bool

    public init(
        captureID: String,
        mediaSourceURL: String,
        documentID: String? = nil,
        mimeTypes: [String],
        isPotentiallyProtected: Bool = false
    ) {
        self.captureID = captureID
        self.mediaSourceURL = mediaSourceURL
        self.documentID = documentID
        self.mimeTypes = mimeTypes
        self.isPotentiallyProtected = isPotentiallyProtected
    }
}

/// Native receiver for ordered MSE segment chunks. Bytes are written to staging
/// segment files immediately; reconstruction runs only when the user stops or
/// the page signals end-of-stream.
public actor BrowserMSECapturePrototypeWriter {
    private struct TrackState {
        let mimeType: String
        let kind: BrowserMSECaptureTrackKind
        var openSegmentIndex: Int?
        var openHandle: FileHandle?
        var openURL: URL?
        var openBytes: Int64
        var nextExpectedSegmentIndex: Int
        var initializationURL: URL?
        var initializationByteCount: Int64?
        var mediaSegments: [(url: URL, bytes: Int64)]
    }

    private struct Session {
        let metadata: BrowserMSECaptureMetadata
        let support: BrowserMSECaptureSupport
        let stagingDirectoryURL: URL
        var tracks: [Int: TrackState]
        var bytesCaptured: Int64
        var segmentCount: Int
        var nextChunkIndex: Int
        var nextChunkOffset: Int64
        var appendSequence: [BrowserMSECaptureAppendEvent]
        var lifecycle: BrowserMSECaptureLifecycle
    }

    private let destinationDirectoryURL: URL
    private let limits: BrowserMSECaptureLimits
    private var sessions: [String: Session] = [:]

    public init(
        destinationDirectoryURL: URL,
        limits: BrowserMSECaptureLimits = .default
    ) {
        self.destinationDirectoryURL = destinationDirectoryURL
        self.limits = limits
    }

    public func begin(metadata: BrowserMSECaptureMetadata) throws -> BrowserMSECaptureSnapshot {
        guard validCaptureID(metadata.captureID) else {
            throw BrowserMSECapturePrototypeError.invalidCaptureID
        }
        guard !sessions.keys.contains(metadata.captureID) else {
            throw BrowserMSECapturePrototypeError.captureAlreadyComplete
        }

        let support = BrowserMSECaptureSupportClassifier.evaluate(
            mimeTypes: metadata.mimeTypes,
            isPotentiallyProtected: metadata.isPotentiallyProtected
        )
        if support.status == .protectedMedia {
            throw BrowserMSECapturePrototypeError.protectedMedia
        }
        guard support.isCapturable else {
            throw BrowserMSECapturePrototypeError.unsupportedSession
        }

        let staging = destinationDirectoryURL
            .appendingPathComponent("MSECaptures", isDirectory: true)
            .appendingPathComponent(metadata.captureID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw BrowserMSECapturePrototypeError.fileOperationFailed
        }

        var tracks: [Int: TrackState] = [:]
        for (index, mime) in metadata.mimeTypes.enumerated() {
            tracks[index] = TrackState(
                mimeType: mime,
                kind: BrowserMSECaptureSupportClassifier.trackKind(for: mime),
                openSegmentIndex: nil,
                openHandle: nil,
                openURL: nil,
                openBytes: 0,
                nextExpectedSegmentIndex: 0,
                initializationURL: nil,
                initializationByteCount: nil,
                mediaSegments: []
            )
        }

        sessions[metadata.captureID] = Session(
            metadata: metadata,
            support: support,
            stagingDirectoryURL: staging,
            tracks: tracks,
            bytesCaptured: 0,
            segmentCount: 0,
            nextChunkIndex: 0,
            nextChunkOffset: 0,
            appendSequence: [],
            lifecycle: .capturing
        )

        return BrowserMSECaptureSnapshot(
            captureID: metadata.captureID,
            bytesCaptured: 0,
            segmentCount: 0,
            lifecycle: .capturing,
            supportReason: support.reason,
            temporaryDirectoryURL: staging
        )
    }

    public func appendChunk(
        captureID: String,
        chunkIndex: Int,
        offset: Int64,
        trackIndex: Int,
        segmentIndex: Int,
        data: Data,
        sha256: String,
        isSegmentEnd: Bool,
        timestampOffset: Double? = nil,
        appendTimestamp: Double? = nil
    ) throws -> BrowserMSECaptureSnapshot {
        guard var session = sessions[captureID] else {
            throw BrowserMSECapturePrototypeError.unknownCapture
        }
        guard session.lifecycle == .capturing else {
            throw BrowserMSECapturePrototypeError.captureAlreadyComplete
        }

        do {
            guard chunkIndex == session.nextChunkIndex else {
                throw BrowserMSECapturePrototypeError.invalidChunkIndex
            }
            guard offset == session.nextChunkOffset else {
                throw BrowserMSECapturePrototypeError.invalidChunkOffset
            }
            guard !data.isEmpty, data.count <= limits.maximumChunkBytes else {
                throw BrowserMSECapturePrototypeError.chunkTooLarge
            }
            guard session.bytesCaptured <= limits.maximumBytes - Int64(data.count) else {
                throw BrowserMSECapturePrototypeError.sizeLimitExceeded
            }
            guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
                throw BrowserMSECapturePrototypeError.invalidChecksum
            }
            guard EngineSHA256.hash(data: data).caseInsensitiveCompare(sha256) == .orderedSame else {
                throw BrowserMSECapturePrototypeError.checksumMismatch
            }
            guard var track = session.tracks[trackIndex] else {
                throw BrowserMSECapturePrototypeError.unsupportedSession
            }
            if segmentIndex < 0 || segmentIndex > track.nextExpectedSegmentIndex {
                throw BrowserMSECapturePrototypeError.invalidSegmentIndex
            }
            if track.mediaSegments.count + (track.initializationURL == nil ? 0 : 1) >= limits.maximumSegmentsPerTrack {
                throw BrowserMSECapturePrototypeError.tooManySegments
            }

            if track.openSegmentIndex != segmentIndex {
                try closeOpenSegment(track: &track, container: session.support.container)
                guard segmentIndex == track.nextExpectedSegmentIndex else {
                    throw BrowserMSECapturePrototypeError.invalidSegmentIndex
                }
                let segmentURL = session.stagingDirectoryURL
                    .appendingPathComponent("track-\(trackIndex)-seg-\(segmentIndex).part", isDirectory: false)
                try? FileManager.default.removeItem(at: segmentURL)
                guard FileManager.default.createFile(atPath: segmentURL.path, contents: nil) else {
                    throw BrowserMSECapturePrototypeError.fileOperationFailed
                }
                track.openHandle = try FileHandle(forWritingTo: segmentURL)
                track.openURL = segmentURL
                track.openSegmentIndex = segmentIndex
                track.openBytes = 0
            }

            guard let handle = track.openHandle else {
                throw BrowserMSECapturePrototypeError.fileOperationFailed
            }
            try handle.write(contentsOf: data)
            track.openBytes += Int64(data.count)
            session.bytesCaptured += Int64(data.count)
            session.nextChunkIndex += 1
            session.nextChunkOffset += Int64(data.count)
            session.appendSequence.append(BrowserMSECaptureAppendEvent(
                chunkIndex: chunkIndex,
                trackIndex: trackIndex,
                segmentIndex: segmentIndex,
                byteCount: Int64(data.count),
                timestampOffset: timestampOffset,
                appendTimestamp: appendTimestamp
            ))

            if isSegmentEnd {
                try closeOpenSegment(track: &track, container: session.support.container)
                session.segmentCount += 1
            }

            session.tracks[trackIndex] = track
            sessions[captureID] = session
            return snapshot(for: session)
        } catch let error as BrowserMSECapturePrototypeError {
            abort(captureID: captureID)
            throw error
        } catch {
            abort(captureID: captureID)
            throw BrowserMSECapturePrototypeError.fileOperationFailed
        }
    }

    /// Finalizes open segments, runs MediaAssembler validation, and only then
    /// publishes a reconstructed file. Captured bytes alone are never success.
    public func complete(captureID: String) throws -> BrowserMSECaptureSnapshot {
        guard var session = sessions[captureID] else {
            throw BrowserMSECapturePrototypeError.unknownCapture
        }
        guard session.lifecycle == .capturing else {
            throw BrowserMSECapturePrototypeError.captureAlreadyComplete
        }

        do {
            for key in session.tracks.keys.sorted() {
                guard var track = session.tracks[key] else { continue }
                try closeOpenSegment(track: &track, container: session.support.container)
                session.tracks[key] = track
            }
            session.lifecycle = .reconstructing
            sessions[captureID] = session

            let output = try reconstruct(session: session)
            session.lifecycle = .completed
            let result = BrowserMSECaptureSnapshot(
                captureID: captureID,
                bytesCaptured: session.bytesCaptured,
                segmentCount: session.segmentCount,
                lifecycle: .completed,
                supportReason: session.support.reason,
                reconstructedURL: output,
                temporaryDirectoryURL: session.stagingDirectoryURL,
                bufferMetadata: bufferMetadata(for: session),
                appendSequence: session.appendSequence
            )
            cleanupStaging(session: session, keepOutput: output)
            sessions.removeValue(forKey: captureID)
            return result
        } catch let error as BrowserMSECapturePrototypeError {
            abort(captureID: captureID)
            throw error
        } catch {
            abort(captureID: captureID)
            throw BrowserMSECapturePrototypeError.reconstructionFailed
        }
    }

    public func cancel(captureID: String) {
        abort(captureID: captureID)
    }

    private func closeOpenSegment(
        track: inout TrackState,
        container: BrowserMSECaptureContainerHint
    ) throws {
        guard let handle = track.openHandle, let url = track.openURL else {
            track.openSegmentIndex = nil
            return
        }
        try handle.synchronize()
        try handle.close()
        track.openHandle = nil

        let bytes = track.openBytes
        guard bytes > 0 else {
            try? FileManager.default.removeItem(at: url)
            track.openURL = nil
            track.openSegmentIndex = nil
            track.openBytes = 0
            return
        }

        let role = classifySegment(url: url, container: container, track: track)
        let finalURL = url.deletingPathExtension().appendingPathExtension(role == .initialization ? "init" : "m4s")
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: url, to: finalURL)

        switch role {
        case .initialization:
            if track.initializationURL != nil {
                // Quality switches that re-append init are outside the narrow
                // prototype; treat as unsupported rather than corrupting output.
                throw BrowserMSECapturePrototypeError.unsupportedSession
            }
            track.initializationURL = finalURL
            track.initializationByteCount = bytes
        case .media:
            track.mediaSegments.append((finalURL, bytes))
        }

        track.nextExpectedSegmentIndex += 1
        track.openURL = nil
        track.openSegmentIndex = nil
        track.openBytes = 0
    }

    private enum SegmentRole {
        case initialization
        case media
    }

    private func classifySegment(
        url: URL,
        container: BrowserMSECaptureContainerHint,
        track: TrackState
    ) -> SegmentRole {
        switch container {
        case .mpegTS:
            return .media
        case .fragmentedMP4, .unsupported:
            if BrowserMSECaptureSegmentInspector.containsBoxes(url, required: ["ftyp", "moov"]) {
                return .initialization
            }
            return .media
        }
    }

    private func reconstruct(session: Session) throws -> URL {
        guard session.bytesCaptured > 0, session.segmentCount > 0 else {
            throw BrowserMSECapturePrototypeError.incompleteCapture
        }

        let assemblyContainer: MediaAssemblyContainer
        switch session.support.container {
        case .fragmentedMP4: assemblyContainer = .fragmentedMP4
        case .mpegTS: assemblyContainer = .mpegTS
        case .unsupported: throw BrowserMSECapturePrototypeError.unsupportedSession
        }

        var tracks: [MediaAssemblyTrack] = []
        for key in session.tracks.keys.sorted() {
            guard let track = session.tracks[key] else { continue }
            let kind: MediaAssemblyTrackKind
            switch track.kind {
            case .video: kind = .video
            case .audio: kind = .audio
            case .unknown: throw BrowserMSECapturePrototypeError.unsupportedSession
            }

            if assemblyContainer == .fragmentedMP4 {
                guard let initURL = track.initializationURL,
                      let initBytes = track.initializationByteCount else {
                    throw BrowserMSECapturePrototypeError.missingInitializationSegment
                }
                guard !track.mediaSegments.isEmpty else {
                    throw BrowserMSECapturePrototypeError.incompleteCapture
                }
                let media = track.mediaSegments.enumerated().map { index, item in
                    MediaAssemblySegment(
                        fileURL: item.url,
                        role: .media,
                        order: index,
                        actualByteCount: item.bytes
                    )
                }
                tracks.append(MediaAssemblyTrack(
                    kind: kind,
                    container: .fragmentedMP4,
                    initializationSegment: MediaAssemblySegment(
                        fileURL: initURL,
                        role: .initialization,
                        order: 0,
                        actualByteCount: initBytes
                    ),
                    mediaSegments: media,
                    encryption: .clear
                ))
            } else {
                guard !track.mediaSegments.isEmpty else {
                    throw BrowserMSECapturePrototypeError.incompleteCapture
                }
                let media = track.mediaSegments.enumerated().map { index, item in
                    MediaAssemblySegment(
                        fileURL: item.url,
                        order: index,
                        actualByteCount: item.bytes
                    )
                }
                tracks.append(MediaAssemblyTrack(
                    kind: kind,
                    container: .mpegTS,
                    mediaSegments: media,
                    encryption: .clear
                ))
            }
        }

        let filename: String
        switch assemblyContainer {
        case .fragmentedMP4: filename = "mse-capture.mp4"
        case .mpegTS: filename = "mse-capture.ts"
        }
        let destination = uniqueURL(directory: destinationDirectoryURL, filename: filename)

        let request = MediaAssemblyRequest(
            container: assemblyContainer,
            tracks: tracks,
            destinationURL: destination,
            temporaryDirectoryURL: session.stagingDirectoryURL.appendingPathComponent("assembly", isDirectory: true)
        )

        do {
            let output = try MediaAssembler.assemble(request)
            return output.destinationURL
        } catch let error as MediaAssemblyError {
            switch error {
            case .encryptedMediaNotSupported:
                throw BrowserMSECapturePrototypeError.protectedMedia
            case .missingInitializationSegment:
                throw BrowserMSECapturePrototypeError.missingInitializationSegment
            case .invalidMediaData:
                throw BrowserMSECapturePrototypeError.invalidMediaData
            case .muxingUnavailable, .muxingFailed, .multipleTracksNotSupported:
                throw BrowserMSECapturePrototypeError.reconstructionFailed
            default:
                throw BrowserMSECapturePrototypeError.reconstructionFailed
            }
        } catch {
            throw BrowserMSECapturePrototypeError.reconstructionFailed
        }
    }

    private func snapshot(for session: Session) -> BrowserMSECaptureSnapshot {
        BrowserMSECaptureSnapshot(
            captureID: session.metadata.captureID,
            bytesCaptured: session.bytesCaptured,
            segmentCount: session.segmentCount,
            lifecycle: session.lifecycle,
            supportReason: session.support.reason,
            temporaryDirectoryURL: session.stagingDirectoryURL,
            bufferMetadata: bufferMetadata(for: session),
            appendSequence: session.appendSequence
        )
    }

    private func bufferMetadata(for session: Session) -> [BrowserMSECaptureBufferMetadata] {
        session.tracks.keys.sorted().compactMap { index in
            guard let track = session.tracks[index] else { return nil }
            return BrowserMSECaptureBufferMetadata(
                trackIndex: index,
                mimeType: track.mimeType,
                codecs: BrowserMSECaptureSupportClassifier.codecs(in: track.mimeType),
                kind: track.kind
            )
        }
    }

    private func abort(captureID: String) {
        guard let session = sessions.removeValue(forKey: captureID) else { return }
        for track in session.tracks.values {
            try? track.openHandle?.close()
        }
        cleanupStaging(session: session, keepOutput: nil)
    }

    private func cleanupStaging(session: Session, keepOutput: URL?) {
        try? FileManager.default.removeItem(at: session.stagingDirectoryURL)
        _ = keepOutput
    }

    private func validCaptureID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= limits.maximumIdentifierLength &&
            value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func uniqueURL(directory: URL, filename: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ext = base.pathExtension
        let stem = ext.isEmpty ? base.lastPathComponent : String(base.lastPathComponent.dropLast(ext.count + 1))
        for index in 1...10_000 {
            let candidateName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("mse-\(UUID().uuidString).\(ext.isEmpty ? "bin" : ext)")
    }
}

enum BrowserMSECaptureSegmentInspector {
    static func containsBoxes(_ url: URL, required: Set<String>) -> Bool {
        guard let fileSizeInt = FileManager.default.fileSize(atPath: url.path),
              fileSizeInt > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        let fileSize = UInt64(fileSizeInt)
        var offset: UInt64 = 0
        var boxes = Set<String>()
        while offset < fileSize {
            guard fileSize - offset >= 8 else { return false }
            do {
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 8), header.count == 8 else { return false }
                var boxSize = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 |
                    UInt64(header[2]) << 8 | UInt64(header[3])
                let type = String(bytes: header[4...7], encoding: .ascii) ?? ""
                guard !type.isEmpty else { return false }
                var headerSize: UInt64 = 8
                if boxSize == 1 {
                    guard fileSize - offset >= 16 else { return false }
                    try handle.seek(toOffset: offset + 8)
                    guard let extended = try handle.read(upToCount: 8), extended.count == 8 else { return false }
                    boxSize = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    headerSize = 16
                } else if boxSize == 0 {
                    boxSize = fileSize - offset
                }
                guard boxSize >= headerSize, boxSize <= fileSize - offset else { return false }
                boxes.insert(type)
                offset += boxSize
            } catch {
                return false
            }
        }
        return required.isSubset(of: boxes)
    }
}

public struct BrowserMSECapturePrototypeMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case metadata
        case chunk
        case complete
        case failure
        case cancel
    }

    public let kind: Kind
    public let captureID: String
    public let documentID: String?
    public let mediaSourceURL: String?
    public let mimeTypes: [String]?
    public let isPotentiallyProtected: Bool?
    public let chunkIndex: Int?
    public let offset: Int64?
    public let trackIndex: Int?
    public let segmentIndex: Int?
    public let base64: String?
    public let sha256: String?
    public let isSegmentEnd: Bool?
    public let timestampOffset: Double?
    public let appendTimestamp: Double?
    public let reason: String?

    public init(
        kind: Kind,
        captureID: String,
        documentID: String? = nil,
        mediaSourceURL: String? = nil,
        mimeTypes: [String]? = nil,
        isPotentiallyProtected: Bool? = nil,
        chunkIndex: Int? = nil,
        offset: Int64? = nil,
        trackIndex: Int? = nil,
        segmentIndex: Int? = nil,
        base64: String? = nil,
        sha256: String? = nil,
        isSegmentEnd: Bool? = nil,
        timestampOffset: Double? = nil,
        appendTimestamp: Double? = nil,
        reason: String? = nil
    ) {
        self.kind = kind
        self.captureID = captureID
        self.documentID = documentID
        self.mediaSourceURL = mediaSourceURL
        self.mimeTypes = mimeTypes
        self.isPotentiallyProtected = isPotentiallyProtected
        self.chunkIndex = chunkIndex
        self.offset = offset
        self.trackIndex = trackIndex
        self.segmentIndex = segmentIndex
        self.base64 = base64
        self.sha256 = sha256
        self.isSegmentEnd = isSegmentEnd
        self.timestampOffset = timestampOffset
        self.appendTimestamp = appendTimestamp
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case kind, type, captureID, documentID, mediaSourceURL, mimeTypes
        case isPotentiallyProtected, chunkIndex, offset, trackIndex, segmentIndex
        case base64, sha256, isSegmentEnd, timestampOffset, appendTimestamp, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try container.decodeIfPresent(Kind.self, forKey: .kind) {
            kind = decoded
        } else {
            kind = try container.decode(Kind.self, forKey: .type)
        }
        captureID = try container.decode(String.self, forKey: .captureID)
        documentID = try container.decodeIfPresent(String.self, forKey: .documentID)
        mediaSourceURL = try container.decodeIfPresent(String.self, forKey: .mediaSourceURL)
        mimeTypes = try container.decodeIfPresent([String].self, forKey: .mimeTypes)
        isPotentiallyProtected = try container.decodeIfPresent(Bool.self, forKey: .isPotentiallyProtected)
        chunkIndex = try container.decodeIfPresent(Int.self, forKey: .chunkIndex)
        offset = try container.decodeIfPresent(Int64.self, forKey: .offset)
        trackIndex = try container.decodeIfPresent(Int.self, forKey: .trackIndex)
        segmentIndex = try container.decodeIfPresent(Int.self, forKey: .segmentIndex)
        base64 = try container.decodeIfPresent(String.self, forKey: .base64)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        isSegmentEnd = try container.decodeIfPresent(Bool.self, forKey: .isSegmentEnd)
        timestampOffset = try container.decodeIfPresent(Double.self, forKey: .timestampOffset)
        appendTimestamp = try container.decodeIfPresent(Double.self, forKey: .appendTimestamp)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(captureID, forKey: .captureID)
        try container.encodeIfPresent(documentID, forKey: .documentID)
        try container.encodeIfPresent(mediaSourceURL, forKey: .mediaSourceURL)
        try container.encodeIfPresent(mimeTypes, forKey: .mimeTypes)
        try container.encodeIfPresent(isPotentiallyProtected, forKey: .isPotentiallyProtected)
        try container.encodeIfPresent(chunkIndex, forKey: .chunkIndex)
        try container.encodeIfPresent(offset, forKey: .offset)
        try container.encodeIfPresent(trackIndex, forKey: .trackIndex)
        try container.encodeIfPresent(segmentIndex, forKey: .segmentIndex)
        try container.encodeIfPresent(base64, forKey: .base64)
        try container.encodeIfPresent(sha256, forKey: .sha256)
        try container.encodeIfPresent(isSegmentEnd, forKey: .isSegmentEnd)
        try container.encodeIfPresent(timestampOffset, forKey: .timestampOffset)
        try container.encodeIfPresent(appendTimestamp, forKey: .appendTimestamp)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

public struct BrowserMSECapturePrototypeAck: Sendable, Equatable {
    public let captureID: String
    public let accepted: Bool
    public let snapshot: BrowserMSECaptureSnapshot?
    public let error: BrowserMSECapturePrototypeError?

    public init(
        captureID: String,
        accepted: Bool,
        snapshot: BrowserMSECaptureSnapshot? = nil,
        error: BrowserMSECapturePrototypeError? = nil
    ) {
        self.captureID = captureID
        self.accepted = accepted
        self.snapshot = snapshot
        self.error = error
    }
}

public actor BrowserMSECapturePrototypeReceiver {
    private let writer: BrowserMSECapturePrototypeWriter
    private var authorizedCaptureIDs: Set<String> = []
    private var expectedDocumentIDs: [String: String] = [:]

    public init(writer: BrowserMSECapturePrototypeWriter) {
        self.writer = writer
    }

    public func register(captureID: String, documentID: String?) {
        authorizedCaptureIDs.insert(captureID)
        if let documentID, !documentID.isEmpty {
            expectedDocumentIDs[captureID] = documentID
        } else {
            expectedDocumentIDs.removeValue(forKey: captureID)
        }
    }

    public func cancel(captureID: String) async {
        authorizedCaptureIDs.remove(captureID)
        expectedDocumentIDs.removeValue(forKey: captureID)
        await writer.cancel(captureID: captureID)
    }

    public nonisolated func receive(payload: Any) async -> BrowserMSECapturePrototypeAck {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return BrowserMSECapturePrototypeAck(
                captureID: "",
                accepted: false,
                error: .fileOperationFailed
            )
        }
        return await receive(data: data)
    }

    public func receive(data: Data) async -> BrowserMSECapturePrototypeAck {
        var captureID = ""
        do {
            guard let message = try? JSONDecoder().decode(BrowserMSECapturePrototypeMessage.self, from: data) else {
                throw BrowserMSECapturePrototypeError.fileOperationFailed
            }
            captureID = message.captureID
            guard authorizedCaptureIDs.contains(message.captureID) else {
                throw BrowserMSECapturePrototypeError.captureNotAuthorized
            }
            if let expectedDocumentID = expectedDocumentIDs[message.captureID],
               message.documentID != expectedDocumentID {
                throw BrowserMSECapturePrototypeError.documentMismatch
            }

            switch message.kind {
            case .metadata:
                guard let mediaSourceURL = message.mediaSourceURL,
                      let mimeTypes = message.mimeTypes else {
                    throw BrowserMSECapturePrototypeError.unsupportedSession
                }
                let metadata = BrowserMSECaptureMetadata(
                    captureID: message.captureID,
                    mediaSourceURL: mediaSourceURL,
                    documentID: message.documentID,
                    mimeTypes: mimeTypes,
                    isPotentiallyProtected: message.isPotentiallyProtected == true
                )
                let snapshot = try await writer.begin(metadata: metadata)
                return BrowserMSECapturePrototypeAck(captureID: message.captureID, accepted: true, snapshot: snapshot)
            case .chunk:
                guard let index = message.chunkIndex,
                      let offset = message.offset,
                      let trackIndex = message.trackIndex,
                      let segmentIndex = message.segmentIndex,
                      let base64 = message.base64,
                      let checksum = message.sha256,
                      let data = Data(base64Encoded: base64) else {
                    throw BrowserMSECapturePrototypeError.fileOperationFailed
                }
                let snapshot = try await writer.appendChunk(
                    captureID: message.captureID,
                    chunkIndex: index,
                    offset: offset,
                    trackIndex: trackIndex,
                    segmentIndex: segmentIndex,
                    data: data,
                    sha256: checksum,
                    isSegmentEnd: message.isSegmentEnd == true,
                    timestampOffset: message.timestampOffset,
                    appendTimestamp: message.appendTimestamp
                )
                return BrowserMSECapturePrototypeAck(captureID: message.captureID, accepted: true, snapshot: snapshot)
            case .complete:
                let snapshot = try await writer.complete(captureID: message.captureID)
                authorizedCaptureIDs.remove(message.captureID)
                expectedDocumentIDs.removeValue(forKey: message.captureID)
                return BrowserMSECapturePrototypeAck(captureID: message.captureID, accepted: true, snapshot: snapshot)
            case .failure, .cancel:
                authorizedCaptureIDs.remove(message.captureID)
                expectedDocumentIDs.removeValue(forKey: message.captureID)
                await writer.cancel(captureID: message.captureID)
                return BrowserMSECapturePrototypeAck(captureID: message.captureID, accepted: true)
            }
        } catch let error as BrowserMSECapturePrototypeError {
            if !captureID.isEmpty {
                authorizedCaptureIDs.remove(captureID)
                expectedDocumentIDs.removeValue(forKey: captureID)
                await writer.cancel(captureID: captureID)
            }
            return BrowserMSECapturePrototypeAck(captureID: captureID, accepted: false, error: error)
        } catch {
            if !captureID.isEmpty {
                expectedDocumentIDs.removeValue(forKey: captureID)
                await writer.cancel(captureID: captureID)
            }
            return BrowserMSECapturePrototypeAck(captureID: captureID, accepted: false, error: .fileOperationFailed)
        }
    }
}

public actor BrowserMSECaptureService {
    public nonisolated let receiver: BrowserMSECapturePrototypeReceiver

    public init(
        destinationDirectoryURL: URL,
        limits: BrowserMSECaptureLimits = .default
    ) {
        let writer = BrowserMSECapturePrototypeWriter(
            destinationDirectoryURL: destinationDirectoryURL,
            limits: limits
        )
        self.receiver = BrowserMSECapturePrototypeReceiver(writer: writer)
    }

    public func register(captureID: String, documentID: String?) async {
        await receiver.register(captureID: captureID, documentID: documentID)
    }

    public func cancel(captureID: String) async {
        await receiver.cancel(captureID: captureID)
    }

    public func receive(data: Data) async -> BrowserMSECapturePrototypeAck {
        await receiver.receive(data: data)
    }

    public nonisolated func receive(payload: Any) async -> BrowserMSECapturePrototypeAck {
        await receiver.receive(payload: payload)
    }
}

#if canImport(WebKit)
public final class BrowserMSECapturePrototypeWebKitHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    public let receiver: BrowserMSECapturePrototypeReceiver
    public var acknowledgementHandler: ((BrowserMSECapturePrototypeAck) -> Void)?

    public init(receiver: BrowserMSECapturePrototypeReceiver) {
        self.receiver = receiver
        super.init()
    }

    public func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserMSECapturePrototypeBridge.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.add(self, name: BrowserMSECapturePrototypeBridge.messageName)
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BrowserMSECapturePrototypeBridge.messageName,
              let data = try? JSONSerialization.data(withJSONObject: message.body) else {
            return
        }
        let receiver = self.receiver
        let webView = message.webView
        Task { @MainActor [weak webView] in
            let acknowledgement = await receiver.receive(data: data)
            self.acknowledgementHandler?(acknowledgement)
            guard let webView,
                  !acknowledgement.captureID.isEmpty else { return }
            _ = try? await webView.evaluateJavaScript(
                BrowserMSECapturePrototypeBridge.acknowledgeCommand(
                    captureID: acknowledgement.captureID,
                    accepted: acknowledgement.accepted
                )
            )
        }
    }
}
#endif

/// Page bridge for optional MSE capture. Bytes are copied from `appendBuffer`
/// only while an explicit capture is active for that MediaSource.
public enum BrowserMSECapturePrototypeBridge {
    public static let messageName = "browserMSECapture"
    public static let maximumChunkBytes = 256 * 1024

    public static let script = #"""
    (function() {
        "use strict";
        if (window.__lidMSECapture) { return; }

        var captures = Object.create(null);
        var mediaSourceURLs = typeof WeakMap === "function" ? new WeakMap() : null;
        var sourceBufferInfo = typeof WeakMap === "function" ? new WeakMap() : null;
        var mediaSourceBufferList = typeof WeakMap === "function" ? new WeakMap() : null;
        var MAX_CHUNK_BYTES = 262144;
        var protectionObserved = false;
        var preCaptureLimits = {
            maxMediaBytesPerTrack: 10 * 1024 * 1024,
            maxTotalMediaBytes: 20 * 1024 * 1024
        };
        var globalAppendCounter = 0;

        function post(message) {
            try {
                var handler = window.webkit && window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.browserMSECapture;
                if (handler) { handler.postMessage(message); }
            } catch (_) {}
        }

        function bytesToBase64(bytes) {
            var binary = "";
            for (var offset = 0; offset < bytes.length; offset += 0x8000) {
                binary += String.fromCharCode.apply(null, bytes.subarray(offset, Math.min(offset + 0x8000, bytes.length)));
            }
            return btoa(binary);
        }

        function digestHex(bytes) {
            if (!window.crypto || !window.crypto.subtle) {
                return Promise.reject(new Error("SHA-256 is unavailable"));
            }
            var exactBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
            return window.crypto.subtle.digest("SHA-256", exactBuffer).then(function(buffer) {
                return Array.prototype.map.call(new Uint8Array(buffer), function(value) {
                    return value.toString(16).padStart(2, "0");
                }).join("");
            });
        }

        function toUint8Array(data) {
            if (!data) { return new Uint8Array(0); }
            if (data instanceof ArrayBuffer) { return new Uint8Array(data); }
            if (ArrayBuffer.isView(data)) {
                return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            }
            return new Uint8Array(0);
        }

        function getBoxTypes(bytes) {
            var types = [];
            if (!bytes || bytes.length < 8) { return types; }
            var offset = 0;
            var len = bytes.length;
            while (offset + 8 <= len) {
                var size = ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
                var type = String.fromCharCode(bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7]);
                types.push(type);
                if (size === 1) {
                    if (offset + 16 > len) { break; }
                    var high = ((bytes[offset + 8] << 24) | (bytes[offset + 9] << 16) | (bytes[offset + 10] << 8) | bytes[offset + 11]) >>> 0;
                    var low = ((bytes[offset + 12] << 24) | (bytes[offset + 13] << 16) | (bytes[offset + 14] << 8) | bytes[offset + 15]) >>> 0;
                    var bigSize = high * 4294967296 + low;
                    if (bigSize <= 16) { break; }
                    offset += bigSize;
                } else if (size === 0) {
                    break;
                } else if (size < 8) {
                    break;
                } else {
                    offset += size;
                }
            }
            return types;
        }

        function isInitializationSegment(bytes) {
            var boxes = getBoxTypes(bytes);
            return boxes.indexOf("moov") !== -1 && boxes.indexOf("moof") === -1;
        }

        function areBytesEqual(a, b) {
            if (!a || !b) { return false; }
            if (a.length !== b.length) { return false; }
            for (var i = 0; i < a.length; i++) {
                if (a[i] !== b[i]) { return false; }
            }
            return true;
        }

        function evictPreCaptureMediaFragments(info) {
            while (info.totalMediaBytes > preCaptureLimits.maxMediaBytesPerTrack && info.mediaFragments.length > 0) {
                var evicted = info.mediaFragments.shift();
                info.totalMediaBytes -= evicted.byteLength;
            }
        }

        function activeCaptureForMediaSourceURL(objectURL) {
            var keys = Object.keys(captures);
            for (var i = 0; i < keys.length; i++) {
                var session = captures[keys[i]];
                if (session && session.mediaSourceURL === objectURL && !session.finishing) {
                    return session;
                }
            }
            return null;
        }

        function failCapture(session, reason) {
            if (!session || session.finishing) { return; }
            delete captures[session.captureID];
            post({
                kind: "failure",
                captureID: session.captureID,
                documentID: session.documentID,
                reason: reason
            });
        }

        function cancelAllCaptures(reason) {
            var keys = Object.keys(captures);
            for (var i = 0; i < keys.length; i++) {
                var session = captures[keys[i]];
                if (!session) { continue; }
                delete captures[keys[i]];
                post({
                    kind: "cancel",
                    captureID: session.captureID,
                    documentID: session.documentID,
                    reason: reason
                });
            }
        }

        function enqueueSegment(session, trackIndex, bytes, timestampOffset) {
            if (!bytes || bytes.length === 0) { return; }
            var segmentIndex = session.nextSegmentIndex[trackIndex] || 0;
            session.nextSegmentIndex[trackIndex] = segmentIndex + 1;
            var offset = 0;
            while (offset < bytes.length) {
                var end = Math.min(offset + session.chunkSize, bytes.length);
                session.queue.push({
                    trackIndex: trackIndex,
                    segmentIndex: segmentIndex,
                    bytes: bytes.subarray(offset, end),
                    isSegmentEnd: end >= bytes.length,
                    timestampOffset: Number(timestampOffset) || 0,
                    appendTimestamp: Date.now()
                });
                offset = end;
            }
            if (session.metadataAcked) {
                pump(session);
            }
        }

        function pump(session) {
            if (session.awaitingAck || session.sending) { return; }
            if (session.queue.length === 0) {
                if (session.finishing && !session.completedPosted) {
                    session.completedPosted = true;
                    post({
                        kind: "complete",
                        captureID: session.captureID,
                        documentID: session.documentID
                    });
                    session.awaitingAck = true;
                }
                return;
            }
            session.sending = true;
            var item = session.queue.shift();
            digestHex(item.bytes).then(function(checksum) {
                post({
                    kind: "chunk",
                    captureID: session.captureID,
                    documentID: session.documentID,
                    chunkIndex: session.chunkIndex,
                    offset: session.offset,
                    trackIndex: item.trackIndex,
                    segmentIndex: item.segmentIndex,
                    base64: bytesToBase64(item.bytes),
                    sha256: checksum,
                    isSegmentEnd: item.isSegmentEnd === true,
                    timestampOffset: item.timestampOffset,
                    appendTimestamp: item.appendTimestamp
                });
                session.awaitingAck = true;
                session.chunkIndex += 1;
                session.offset += item.bytes.length;
                session.sending = false;
            }).catch(function(error) {
                session.sending = false;
                post({
                    kind: "failure",
                    captureID: session.captureID,
                    documentID: session.documentID,
                    reason: String(error && error.message || error)
                });
                delete captures[session.captureID];
            });
        }

        function collectMimeTypes(mediaSource) {
            var mimeTypes = [];
            try {
                var buffers = (mediaSourceBufferList && mediaSourceBufferList.get(mediaSource)) ||
                              (mediaSource && mediaSource.sourceBuffers);
                if (!buffers) { return mimeTypes; }
                for (var i = 0; i < buffers.length; i++) {
                    var buffer = buffers[i];
                    var info = sourceBufferInfo && sourceBufferInfo.get(buffer);
                    var mime = (info && info.mimeType) || buffer.type || null;
                    if (mime && mimeTypes.indexOf(String(mime)) === -1) {
                        mimeTypes.push(String(mime));
                    }
                }
            } catch (_) {}
            return mimeTypes;
        }

        function start(mediaSourceURL, captureID, requestedChunkSize, requestedDocumentID) {
            if (protectionObserved) {
                post({
                    kind: "failure",
                    captureID: captureID,
                    reason: "protected media detected"
                });
                return;
            }
            var registry = window.__lidBlobRegistry || null;
            var registered = null;
            try { registered = registry && registry[String(mediaSourceURL)]; } catch (_) {}
            if (!registered || registered.kind !== "mediaSource" || !registered.mediaSource) {
                post({
                    kind: "failure",
                    captureID: captureID,
                    reason: "MediaSource session is unavailable"
                });
                return;
            }
            var mediaSource = registered.mediaSource;
            var mimeTypes = collectMimeTypes(mediaSource);
            if (!mimeTypes.length) {
                post({
                    kind: "failure",
                    captureID: captureID,
                    reason: "No SourceBuffer MIME types are available yet"
                });
                return;
            }

            for (var m = 0; m < mimeTypes.length; m++) {
                if (mimeTypes[m].indexOf("webm") !== -1) {
                    post({
                        kind: "failure",
                        captureID: captureID,
                        reason: "WebM MSE sessions are not reconstructed by this prototype."
                    });
                    return;
                }
            }

            var buffers = (mediaSourceBufferList && mediaSourceBufferList.get(mediaSource)) ||
                          (mediaSource && mediaSource.sourceBuffers) || [];
            for (var b = 0; b < buffers.length; b++) {
                var sb = buffers[b];
                var sInfo = sourceBufferInfo && sourceBufferInfo.get(sb);
                if (sInfo) {
                    if (sInfo.initChanged) {
                        post({
                            kind: "failure",
                            captureID: captureID,
                            reason: "Multiple distinct initialization segments detected (codec or representation switch not supported by prototype reconstruction)."
                        });
                        return;
                    }
                    if (sInfo.appendsCount > 0 && !sInfo.initSegment) {
                        post({
                            kind: "failure",
                            captureID: captureID,
                            reason: "Missing initialization segment for MediaSource buffer. Playback started before capture without retained initialization data."
                        });
                        return;
                    }
                }
            }

            var chunkSize = Math.max(1, Math.min(MAX_CHUNK_BYTES, Number(requestedChunkSize) || MAX_CHUNK_BYTES));
            captures[captureID] = {
                captureID: captureID,
                documentID: requestedDocumentID || registered.documentID || null,
                mediaSourceURL: String(mediaSourceURL),
                mediaSource: mediaSource,
                mimeTypes: mimeTypes,
                chunkSize: chunkSize,
                chunkIndex: 0,
                offset: 0,
                queue: [],
                nextSegmentIndex: {},
                awaitingAck: true,
                sending: false,
                finishing: false,
                completedPosted: false,
                metadataAcked: false
            };
            var session = captures[captureID];

            try {
                mediaSource.addEventListener("sourceended", function() {
                    if (session && !session.completedPosted) {
                        session.finishing = true;
                        pump(session);
                    }
                });
                mediaSource.addEventListener("sourceclose", function() {
                    failCapture(session, "MediaSource was detached from the document");
                });
                mediaSource.addEventListener("error", function() {
                    failCapture(session, "MediaSource error");
                });
            } catch (_) {}

            // Late-start handoff: retrieve retained initialization segments & media fragments
            // 1. Enqueue each track's retained init segment as segment 0
            for (var t = 0; t < mimeTypes.length; t++) {
                var targetMime = mimeTypes[t];
                for (var sbIdx = 0; sbIdx < buffers.length; sbIdx++) {
                    var buf = buffers[sbIdx];
                    var bInfo = sourceBufferInfo && sourceBufferInfo.get(buf);
                    if (bInfo && String(bInfo.mimeType) === String(targetMime)) {
                        if (bInfo.initSegment) {
                            enqueueSegment(session, t, bInfo.initSegment, 0);
                        }
                        break;
                    }
                }
            }

            // 2. Collect all retained media fragments from all buffers, sort by appendOrder
            var allFragments = [];
            for (var sbIdx = 0; sbIdx < buffers.length; sbIdx++) {
                var buf = buffers[sbIdx];
                var bInfo = sourceBufferInfo && sourceBufferInfo.get(buf);
                if (bInfo && bInfo.mediaFragments.length > 0) {
                    var tIdx = 0;
                    for (var t = 0; t < mimeTypes.length; t++) {
                        if (String(mimeTypes[t]) === String(bInfo.mimeType)) {
                            tIdx = t;
                            break;
                        }
                    }
                    for (var f = 0; f < bInfo.mediaFragments.length; f++) {
                        var frag = bInfo.mediaFragments[f];
                        allFragments.push({
                            trackIndex: tIdx,
                            bytes: frag.bytes,
                            appendOrder: frag.appendOrder,
                            timestampOffset: frag.timestampOffset
                        });
                    }
                }
            }
            allFragments.sort(function(a, b) { return a.appendOrder - b.appendOrder; });
            for (var fIdx = 0; fIdx < allFragments.length; fIdx++) {
                var item = allFragments[fIdx];
                enqueueSegment(session, item.trackIndex, item.bytes, item.timestampOffset);
            }

            post({
                kind: "metadata",
                captureID: captureID,
                documentID: requestedDocumentID || registered.documentID || null,
                mediaSourceURL: String(mediaSourceURL),
                mimeTypes: mimeTypes,
                isPotentiallyProtected: protectionObserved
            });
        }

        function acknowledge(captureID, accepted) {
            var session = captures[captureID];
            if (!session) { return; }
            if (!accepted) {
                delete captures[captureID];
                return;
            }
            session.awaitingAck = false;
            session.metadataAcked = true;
            if (session.completedPosted && session.queue.length === 0) {
                delete captures[captureID];
                return;
            }
            pump(session);
        }

        function stop(captureID) {
            var session = captures[captureID];
            if (!session) { return; }
            session.finishing = true;
            pump(session);
        }

        function cancel(captureID) {
            var session = captures[captureID];
            if (!session) { return; }
            delete captures[captureID];
            post({ kind: "cancel", captureID: captureID, documentID: session.documentID });
        }

        try {
            if (window.URL && typeof window.URL.createObjectURL === "function") {
                var originalCreateObjectURL = window.URL.createObjectURL;
                window.URL.createObjectURL = function(object) {
                    var objectURL = originalCreateObjectURL.apply(this, arguments);
                    try {
                        if (window.MediaSource && object instanceof window.MediaSource) {
                            if (mediaSourceURLs) { mediaSourceURLs.set(object, objectURL); }
                            window.__lidBlobRegistry = window.__lidBlobRegistry || Object.create(null);
                            window.__lidBlobRegistry[objectURL] = {
                                kind: "mediaSource",
                                mediaSource: object,
                                documentID: (window.__lidMediaDocumentID || null)
                            };
                        }
                    } catch (_) {}
                    return objectURL;
                };
            }
            if (window.URL && typeof window.URL.revokeObjectURL === "function") {
                var originalRevokeObjectURL = window.URL.revokeObjectURL;
                window.URL.revokeObjectURL = function(url) {
                    try {
                        var active = activeCaptureForMediaSourceURL(String(url));
                        if (active) {
                            failCapture(active, "MediaSource URL was revoked");
                        }
                    } catch (_) {}
                    return originalRevokeObjectURL.apply(this, arguments);
                };
            }
        } catch (_) {}

        try {
            if (navigator && typeof navigator.requestMediaKeySystemAccess === "function") {
                var originalRequest = navigator.requestMediaKeySystemAccess;
                navigator.requestMediaKeySystemAccess = function() {
                    protectionObserved = true;
                    return originalRequest.apply(this, arguments);
                };
            }
        } catch (_) {}

        try {
            if (window.MediaSource && window.MediaSource.prototype) {
                var originalAddSourceBuffer = window.MediaSource.prototype.addSourceBuffer;
                if (typeof originalAddSourceBuffer === "function") {
                    window.MediaSource.prototype.addSourceBuffer = function(mimeType) {
                        var buffer = originalAddSourceBuffer.apply(this, arguments);
                        try {
                            var objectURL = mediaSourceURLs ? mediaSourceURLs.get(this) : null;
                            var sbState = {
                                mimeType: String(mimeType || ""),
                                mediaSourceURL: objectURL || null,
                                mediaSource: this,
                                initSegment: null,
                                initBoxTypes: [],
                                mediaFragments: [],
                                totalMediaBytes: 0,
                                hasMultipleInitSegments: false,
                                initChanged: false,
                                appendsCount: 0
                            };
                            if (sourceBufferInfo) {
                                sourceBufferInfo.set(buffer, sbState);
                            }
                            if (mediaSourceBufferList) {
                                var list = mediaSourceBufferList.get(this) || [];
                                list.push(buffer);
                                mediaSourceBufferList.set(this, list);
                            }
                            buffer.addEventListener("error", function() {
                                var info = sourceBufferInfo && sourceBufferInfo.get(buffer);
                                var objectURL = info && info.mediaSourceURL;
                                failCapture(
                                    objectURL ? activeCaptureForMediaSourceURL(objectURL) : null,
                                    "SourceBuffer error"
                                );
                            });
                            buffer.addEventListener("abort", function() {
                                // Handled if needed
                            });
                            buffer.addEventListener("updateend", function() {
                                var info = sourceBufferInfo && sourceBufferInfo.get(buffer);
                                var objectURL = info && info.mediaSourceURL;
                                var session = objectURL ? activeCaptureForMediaSourceURL(objectURL) : null;
                                if (session && session.finishing) { pump(session); }
                            });
                        } catch (_) {}
                        return buffer;
                    };
                }

                var originalEndOfStream = window.MediaSource.prototype.endOfStream;
                if (typeof originalEndOfStream === "function") {
                    window.MediaSource.prototype.endOfStream = function() {
                        try {
                            var objectURL = mediaSourceURLs ? mediaSourceURLs.get(this) : null;
                            var session = objectURL ? activeCaptureForMediaSourceURL(objectURL) : null;
                            if (session) { session.finishing = true; pump(session); }
                        } catch (_) {}
                        return originalEndOfStream.apply(this, arguments);
                    };
                }
                var originalRemoveSourceBuffer = window.MediaSource.prototype.removeSourceBuffer;
                if (typeof originalRemoveSourceBuffer === "function") {
                    window.MediaSource.prototype.removeSourceBuffer = function(buffer) {
                        try {
                            var objectURL = mediaSourceURLs ? mediaSourceURLs.get(this) : null;
                            var session = objectURL ? activeCaptureForMediaSourceURL(objectURL) : null;
                            if (session) { failCapture(session, "SourceBuffer was detached"); }
                            if (mediaSourceBufferList) {
                                var list = mediaSourceBufferList.get(this) || [];
                                var idx = list.indexOf(buffer);
                                if (idx !== -1) { list.splice(idx, 1); }
                            }
                        } catch (_) {}
                        return originalRemoveSourceBuffer.apply(this, arguments);
                    };
                }
            }
        } catch (_) {}

        try {
            if (window.SourceBuffer && window.SourceBuffer.prototype) {
                var originalAppendBuffer = window.SourceBuffer.prototype.appendBuffer;
                if (typeof originalAppendBuffer === "function") {
                    window.SourceBuffer.prototype.appendBuffer = function(data) {
                        try {
                            var info = sourceBufferInfo && sourceBufferInfo.get(this);
                            if (info) {
                                var bytes = toUint8Array(data);
                                var copy = new Uint8Array(bytes.length);
                                copy.set(bytes);
                                info.appendsCount += 1;

                                var isInit = isInitializationSegment(copy);
                                if (isInit) {
                                    if (info.initSegment) {
                                        if (!areBytesEqual(info.initSegment, copy)) {
                                            info.hasMultipleInitSegments = true;
                                            info.initChanged = true;
                                            var objectURL = info.mediaSourceURL;
                                            var session = objectURL ? activeCaptureForMediaSourceURL(objectURL) : null;
                                            if (session) {
                                                failCapture(session, "Multiple distinct initialization segments detected (codec or representation switch not supported by prototype reconstruction).");
                                                return originalAppendBuffer.apply(this, arguments);
                                            }
                                        }
                                    } else {
                                        info.initSegment = copy;
                                        info.initBoxTypes = getBoxTypes(copy);
                                    }
                                } else {
                                    // Bounded media fragments retention
                                    info.mediaFragments.push({
                                        bytes: copy,
                                        byteLength: copy.length,
                                        timestamp: Date.now(),
                                        appendOrder: ++globalAppendCounter,
                                        timestampOffset: Number(this.timestampOffset) || 0
                                    });
                                    info.totalMediaBytes += copy.length;
                                    evictPreCaptureMediaFragments(info);
                                }

                                var objectURL = info.mediaSourceURL;
                                var session = objectURL ? activeCaptureForMediaSourceURL(objectURL) : null;
                                if (session && !protectionObserved) {
                                    if (info.initChanged) {
                                        failCapture(session, "Multiple distinct initialization segments detected (codec or representation switch not supported by prototype reconstruction).");
                                        return originalAppendBuffer.apply(this, arguments);
                                    }
                                    var mimeTypes = session.mimeTypes || [];
                                    var trackIndex = 0;
                                    var mime = info.mimeType || this.type || "";
                                    for (var i = 0; i < mimeTypes.length; i++) {
                                        if (String(mimeTypes[i]) === String(mime)) {
                                            trackIndex = i;
                                            break;
                                        }
                                    }
                                    enqueueSegment(session, trackIndex, copy, this.timestampOffset || 0);
                                }
                            }
                        } catch (_) {}
                        return originalAppendBuffer.apply(this, arguments);
                    };
                }
            }
        } catch (_) {}

        window.__lidMSECapture = {
            start: start,
            acknowledge: acknowledge,
            stop: stop,
            cancel: cancel,
            getPreCaptureState: function(sourceBuffer) {
                return sourceBufferInfo && sourceBufferInfo.get(sourceBuffer);
            },
            setPreCaptureLimits: function(trackLimit, totalLimit) {
                if (typeof trackLimit === "number") { preCaptureLimits.maxMediaBytesPerTrack = trackLimit; }
                if (typeof totalLimit === "number") { preCaptureLimits.maxTotalMediaBytes = totalLimit; }
            }
        };

        try {
            window.addEventListener("pagehide", function() {
                cancelAllCaptures("Document navigation interrupted MSE capture");
            });
            window.addEventListener("beforeunload", function() {
                cancelAllCaptures("Document navigation interrupted MSE capture");
            });
        } catch (_) {}
    })();
    """#

    public static func startCommand(
        mediaSourceURL: String,
        captureID: String,
        documentID: String? = nil,
        chunkSize: Int = maximumChunkBytes
    ) -> String {
        let escapedURL = jsString(mediaSourceURL)
        let escapedID = jsString(captureID)
        let escapedDocumentID = documentID.map(jsString) ?? "null"
        return "window.__lidMSECapture.start(\(escapedURL), \(escapedID), \(min(maximumChunkBytes, max(1, chunkSize))), \(escapedDocumentID));"
    }

    public static func acknowledgeCommand(captureID: String, accepted: Bool) -> String {
        "window.__lidMSECapture.acknowledge(\(jsString(captureID)), \(accepted ? "true" : "false"));"
    }

    public static func stopCommand(captureID: String) -> String {
        "window.__lidMSECapture.stop(\(jsString(captureID)));"
    }

    public static func cancelCommand(captureID: String) -> String {
        "window.__lidMSECapture.cancel(\(jsString(captureID)));"
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: [value],
            options: [.withoutEscapingSlashes]
        )
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }
}
