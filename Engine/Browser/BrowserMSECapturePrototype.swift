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

    public init(chunkIndex: Int, trackIndex: Int, segmentIndex: Int, byteCount: Int64) {
        self.chunkIndex = chunkIndex
        self.trackIndex = trackIndex
        self.segmentIndex = segmentIndex
        self.byteCount = byteCount
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
        isSegmentEnd: Bool
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
                byteCount: Int64(data.count)
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
            if track.initializationURL == nil,
               BrowserMSECaptureSegmentInspector.containsBoxes(url, required: ["ftyp", "moov"]) {
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              fileSize > 0,
              let handle = FileHandle(forReadingAtPath: url.path) else {
            return false
        }
        defer { handle.closeFile() }

        var offset: UInt64 = 0
        var boxes = Set<String>()
        while offset < fileSize {
            guard fileSize - offset >= 8 else { return false }
            handle.seek(toFileOffset: offset)
            let header = handle.readData(ofLength: 8)
            guard header.count == 8 else { return false }
            var boxSize = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 |
                UInt64(header[2]) << 8 | UInt64(header[3])
            let type = String(bytes: header[4...7], encoding: .ascii) ?? ""
            guard !type.isEmpty else { return false }
            var headerSize: UInt64 = 8
            if boxSize == 1 {
                guard fileSize - offset >= 16 else { return false }
                let extended = handle.readData(ofLength: 8)
                guard extended.count == 8 else { return false }
                boxSize = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerSize = 16
            } else if boxSize == 0 {
                boxSize = fileSize - offset
            }
            guard boxSize >= headerSize, boxSize <= fileSize - offset else { return false }
            boxes.insert(type)
            offset += boxSize
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
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case kind, type, captureID, documentID, mediaSourceURL, mimeTypes
        case isPotentiallyProtected, chunkIndex, offset, trackIndex, segmentIndex
        case base64, sha256, isSegmentEnd, reason
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
                    isSegmentEnd: message.isSegmentEnd == true
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
        var MAX_CHUNK_BYTES = 262144;
        var protectionObserved = false;

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

        function enqueueSegment(session, trackIndex, bytes) {
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
                    isSegmentEnd: end >= bytes.length
                });
                offset = end;
            }
            pump(session);
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
                    isSegmentEnd: item.isSegmentEnd === true
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
                var buffers = mediaSource && mediaSource.sourceBuffers;
                if (!buffers) { return mimeTypes; }
                for (var i = 0; i < buffers.length; i++) {
                    var buffer = buffers[i];
                    var info = sourceBufferInfo && sourceBufferInfo.get(buffer);
                    var mime = (info && info.mimeType) || buffer.type || null;
                    if (mime) { mimeTypes.push(String(mime)); }
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
                            if (sourceBufferInfo) {
                                sourceBufferInfo.set(buffer, {
                                    mimeType: String(mimeType || ""),
                                    mediaSourceURL: objectURL || null,
                                    mediaSource: this
                                });
                            }
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
            }
        } catch (_) {}

        try {
            if (window.SourceBuffer && window.SourceBuffer.prototype) {
                var originalAppendBuffer = window.SourceBuffer.prototype.appendBuffer;
                if (typeof originalAppendBuffer === "function") {
                    window.SourceBuffer.prototype.appendBuffer = function(data) {
                        try {
                            var info = sourceBufferInfo && sourceBufferInfo.get(this);
                            var objectURL = info && info.mediaSourceURL;
                            var session = objectURL ? activeCaptureForMediaSourceURL(objectURL) : null;
                            if (session && !protectionObserved) {
                                var bytes = toUint8Array(data);
                                // Copy immediately; the page may detach the buffer.
                                var copy = new Uint8Array(bytes.length);
                                copy.set(bytes);
                                var mimeTypes = session.mimeTypes || [];
                                var trackIndex = 0;
                                var mime = (info && info.mimeType) || this.type || "";
                                for (var i = 0; i < mimeTypes.length; i++) {
                                    if (String(mimeTypes[i]) === String(mime)) {
                                        trackIndex = i;
                                        break;
                                    }
                                }
                                enqueueSegment(session, trackIndex, copy);
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
            cancel: cancel
        };
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
