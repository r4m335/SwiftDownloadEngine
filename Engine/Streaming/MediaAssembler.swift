import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Execution boundary for a media assembler. Implementations must not download
/// resources or mutate download state; they consume completed local segment
/// files and return a published, validated output.
public protocol MediaAssemblyExecutor: Sendable {
    func assemble(_ request: MediaAssemblyRequest) async throws -> MediaAssemblyOutput
}

/// Remuxing contract for converting MPEG-TS containers to MP4.
public protocol MPEGTSMediaRemuxer: Sendable {
    func remux(sourceTSURL: URL, destinationMP4URL: URL) async throws
}

public struct AVFoundationMPEGTSMediaRemuxer: MPEGTSMediaRemuxer {
    public init() {}
    public func remux(sourceTSURL: URL, destinationMP4URL: URL) async throws {
        #if canImport(AVFoundation)
        try await MediaAssembler.remuxMPEGTSFileToMP4(sourceTSURL: sourceTSURL, destinationMP4URL: destinationMP4URL)
        #else
        throw MediaAssemblyError.muxingUnavailable
        #endif
    }
}

/// Validates and assembles supported clear VOD segment sets.
///
/// The first implementation intentionally supports one compatible track. MPEG-TS
/// inputs are packet-validated before ordered concatenation. Fragmented MP4 inputs
/// require an `ftyp`/`moov` initialization segment and `moof`/`mdat` media fragments;
/// arbitrary MP4 bytes are never blindly published.
public enum MediaAssembler {
    public static func validateInput(
        _ request: MediaAssemblyRequest
    ) throws -> MediaAssemblyValidationReport {
        guard request.sourceLifecycle == .vod else {
            throw MediaAssemblyError.liveSourceNotSupported
        }
        guard request.encryption == .clear else {
            throw MediaAssemblyError.encryptedMediaNotSupported(request.encryption)
        }
        guard request.destinationURL.isFileURL else {
            throw MediaAssemblyError.invalidDestinationURL
        }
        guard request.temporaryDirectoryURL.isFileURL else {
            throw MediaAssemblyError.invalidTemporaryDirectoryURL
        }
        guard !request.destinationURL.path.isEmpty else {
            throw MediaAssemblyError.invalidDestinationURL
        }
        guard !request.temporaryDirectoryURL.path.isEmpty else {
            throw MediaAssemblyError.invalidTemporaryDirectoryURL
        }
        guard !request.tracks.isEmpty else {
            throw MediaAssemblyError.noTracks
        }

        var seenKinds = Set<MediaAssemblyTrackKind>()
        var mediaSegmentCount = 0
        var totalBytes: Int64 = 0
        var hasUnknownByteCount = false

        for track in request.tracks {
            guard seenKinds.insert(track.kind).inserted else {
                throw MediaAssemblyError.duplicateTrack(track.kind)
            }
            guard track.container == request.container else {
                throw MediaAssemblyError.mixedTrackContainers
            }
            guard track.encryption == .clear else {
                throw MediaAssemblyError.encryptedMediaNotSupported(track.encryption)
            }
            guard isSupported(track.container) else {
                throw MediaAssemblyError.unsupportedContainer(track.container)
            }
            try validateMetadata(track.metadata, for: track.kind)

            if request.container == .fragmentedMP4 {
                guard let initializationSegment = track.initializationSegment else {
                    throw MediaAssemblyError.missingInitializationSegment(track.kind)
                }
                try validateSegment(
                    initializationSegment,
                    for: track.kind,
                    expectedRole: .initialization,
                    expectedOrder: nil
                )
                if let byteCount = knownByteCount(for: initializationSegment) {
                    let result = totalBytes.addingReportingOverflow(byteCount)
                    if result.overflow {
                        hasUnknownByteCount = true
                    } else {
                        totalBytes = result.partialValue
                    }
                } else {
                    hasUnknownByteCount = true
                }
            } else if let initializationSegment = track.initializationSegment {
                try validateSegment(
                    initializationSegment,
                    for: track.kind,
                    expectedRole: .initialization,
                    expectedOrder: nil
                )
            }

            guard !track.mediaSegments.isEmpty else {
                throw MediaAssemblyError.noMediaSegments(track.kind)
            }
            for (expectedOrder, segment) in track.mediaSegments.enumerated() {
                try validateSegment(
                    segment,
                    for: track.kind,
                    expectedRole: .media,
                    expectedOrder: expectedOrder
                )
                mediaSegmentCount += 1
                if let byteCount = knownByteCount(for: segment) {
                    let result = totalBytes.addingReportingOverflow(byteCount)
                    if result.overflow {
                        hasUnknownByteCount = true
                    } else {
                        totalBytes = result.partialValue
                    }
                } else {
                    hasUnknownByteCount = true
                }
            }
        }

        return MediaAssemblyValidationReport(
            container: request.container,
            trackCount: request.tracks.count,
            mediaSegmentCount: mediaSegmentCount,
            totalInputBytes: hasUnknownByteCount ? nil : totalBytes
        )
    }

    /// Copies validated segments to a temporary output and publishes it only after
    /// the resulting container structure has been checked.
    public static func assemble(
        _ request: MediaAssemblyRequest,
        remuxer: MPEGTSMediaRemuxer = AVFoundationMPEGTSMediaRemuxer()
    ) async throws -> MediaAssemblyOutput {
        let validation = try validateInput(request)
        if request.tracks.count > 1 {
#if canImport(AVFoundation)
            return try await assembleMultipleTracks(request, validation: validation)
#else
            throw MediaAssemblyError.muxingUnavailable
#endif
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: request.temporaryDirectoryURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: request.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw MediaAssemblyError.fileOperationFailed
        }

        let temporaryOutput = request.temporaryDirectoryURL
            .appendingPathComponent("assembly-\(UUID().uuidString).part", isDirectory: false)
        defer {
            do {
                try fileManager.removeItem(at: temporaryOutput)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to remove temporaryOutput \(temporaryOutput.path): \(error)")
            }
        }

        do {
            guard fileManager.createFile(atPath: temporaryOutput.path, contents: nil) else {
                throw MediaAssemblyError.fileOperationFailed
            }
            let output = try FileHandle(forWritingTo: temporaryOutput)
            defer {
                do {
                    try output.close()
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to close output handle: \(error)")
                }
            }

            let track = request.tracks[0]
            if let initialization = track.initializationSegment {
                try copyValidatedSegment(
                    initialization,
                    kind: track.kind,
                    container: request.container,
                    output: output
                )
            }
            for segment in track.mediaSegments {
                try copyValidatedSegment(
                    segment,
                    kind: track.kind,
                    container: request.container,
                    output: output
                )
            }
            try output.synchronize()
            try output.close()
        } catch let error as MediaAssemblyError {
            throw error
        } catch {
            throw MediaAssemblyError.fileOperationFailed
        }

        guard validateOutput(temporaryOutput, container: request.container) else {
            throw MediaAssemblyError.invalidMediaData(request.container)
        }

        do {
            let parentDir = request.destinationURL.deletingLastPathComponent()
            try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(parentDir, fileManager: fileManager)

            let stagingPublishedURL: URL
            var publishedDestinationURL = request.destinationURL
            var finalContainer = request.container
            var needsRemuxCleanup = false
            if request.container == .mpegTS && request.destinationURL.pathExtension.lowercased() == "mp4" {
                #if canImport(AVFoundation)
                let remuxStaging = parentDir.appendingPathComponent(".remux-\(UUID().uuidString).mp4")
                do {
                    try await remuxer.remux(sourceTSURL: temporaryOutput, destinationMP4URL: remuxStaging)
                    stagingPublishedURL = remuxStaging
                    needsRemuxCleanup = true
                    finalContainer = .fragmentedMP4
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] MPEG-TS remux to MP4 failed: \(error.localizedDescription). Preserving valid MPEG-TS assembly as output.")
                    stagingPublishedURL = temporaryOutput
                    publishedDestinationURL = request.destinationURL.deletingPathExtension().appendingPathExtension("ts")
                    finalContainer = .mpegTS
                }
                #else
                stagingPublishedURL = temporaryOutput
                #endif
            } else {
                stagingPublishedURL = temporaryOutput
            }
            defer {
                if needsRemuxCleanup {
                    do {
                        try fileManager.removeItem(at: stagingPublishedURL)
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to remove stagingPublishedURL \(stagingPublishedURL.path): \(error)")
                    }
                }
            }

            guard let stagingBytes = fileManager.fileSize(atPath: stagingPublishedURL.path), stagingBytes > 0 else {
                throw MediaAssemblyError.fileOperationFailed
            }

            if fileManager.fileExists(atPath: publishedDestinationURL.path) {
                #if canImport(Darwin)
                do {
                    _ = try fileManager.replaceItemAt(publishedDestinationURL, withItemAt: stagingPublishedURL, backupItemName: nil, options: [])
                    let destHandle = try FileHandle(forWritingTo: publishedDestinationURL)
                    defer {
                        do {
                            try destHandle.close()
                        } catch {
                            PipelineLogger.shared.log("[MediaAssembler] Failed to close destHandle: \(error)")
                        }
                    }
                    try destHandle.synchronize()
                } catch {
                    // Non-destructive fallback: preserve existing destination if move fails
                    let backupURL = publishedDestinationURL.deletingLastPathComponent()
                        .appendingPathComponent(".backup-\(UUID().uuidString)-\(publishedDestinationURL.lastPathComponent)")
                    try fileManager.moveItem(at: publishedDestinationURL, to: backupURL)
                    do {
                        try fileManager.moveItem(at: stagingPublishedURL, to: publishedDestinationURL)
                        let destHandle = try FileHandle(forWritingTo: publishedDestinationURL)
                        defer {
                            do {
                                try destHandle.close()
                            } catch {
                                PipelineLogger.shared.log("[MediaAssembler] Failed to close destHandle: \(error)")
                            }
                        }
                        try destHandle.synchronize()
                        do {
                            try fileManager.removeItem(at: backupURL)
                        } catch {
                            PipelineLogger.shared.log("[MediaAssembler] Failed to remove backupURL \(backupURL.path): \(error)")
                        }
                    } catch {
                        do {
                            try fileManager.removeItem(at: publishedDestinationURL)
                        } catch {
                            PipelineLogger.shared.log("[MediaAssembler] Failed to remove publishedDestinationURL: \(error)")
                        }
                        do {
                            try fileManager.moveItem(at: backupURL, to: publishedDestinationURL)
                        } catch {
                            PipelineLogger.shared.log("[MediaAssembler] Failed to restore backupURL \(backupURL.path): \(error)")
                        }
                        throw error
                    }
                }
                #else
                let backupURL = publishedDestinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".backup-\(UUID().uuidString)-\(publishedDestinationURL.lastPathComponent)")
                try fileManager.moveItem(at: publishedDestinationURL, to: backupURL)
                do {
                    try fileManager.moveItem(at: stagingPublishedURL, to: publishedDestinationURL)
                    let destHandle = try FileHandle(forWritingTo: publishedDestinationURL)
                    defer {
                        do {
                            try destHandle.close()
                        } catch {
                            PipelineLogger.shared.log("[MediaAssembler] Failed to close destHandle: \(error)")
                        }
                    }
                    try destHandle.synchronize()
                    do {
                        try fileManager.removeItem(at: backupURL)
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to remove backupURL \(backupURL.path): \(error)")
                    }
                } catch {
                    do {
                        try fileManager.removeItem(at: publishedDestinationURL)
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to remove publishedDestinationURL: \(error)")
                    }
                    do {
                        try fileManager.moveItem(at: backupURL, to: publishedDestinationURL)
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to restore backupURL \(backupURL.path): \(error)")
                    }
                    throw error
                }
                #endif
            } else {
                try fileManager.moveItem(at: stagingPublishedURL, to: publishedDestinationURL)
                do {
                    let destHandle = try FileHandle(forWritingTo: publishedDestinationURL)
                    defer {
                        do {
                            try destHandle.close()
                        } catch {
                            PipelineLogger.shared.log("[MediaAssembler] Failed to close destHandle: \(error)")
                        }
                    }
                    try destHandle.synchronize()
                } catch {
                    do {
                        try fileManager.removeItem(at: publishedDestinationURL)
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to remove publishedDestinationURL: \(error)")
                    }
                    throw error
                }
            }

            guard let byteCount = fileManager.fileSize(atPath: publishedDestinationURL.path), byteCount > 0 else {
                throw MediaAssemblyError.fileOperationFailed
            }

            // Validate the final published file on disk (structural integrity)
            let validationOutcome = MediaIntegrityValidator.validateStructure(
                fileURL: publishedDestinationURL,
                container: finalContainer
            )
            guard validationOutcome.isConfirmedValid else {
                let reason = validationOutcome.failureReason ?? "Published media failed structural validation"
                PipelineLogger.shared.log("[MediaAssembler] Final published file validation failed: \(reason)")
                quarantineFailedPublishedFile(fileURL: publishedDestinationURL, reason: reason, container: finalContainer)
                throw MediaAssemblyError.finalValidationFailed(reason: reason)
            }

            #if canImport(AVFoundation)
            let playability = await MediaIntegrityValidator.checkAVFoundationPlayability(fileURL: publishedDestinationURL)
            let isPlayableConfirmed: Bool? = playability.isPlayable
            let details = playability.isPlayable
                ? "Published file validated and confirmed playable: \(byteCount) bytes"
                : "Published file structurally valid (\(byteCount) bytes); AVFoundation: \(playability.reason ?? "not confirmed playable")"
            #else
            let isPlayableConfirmed: Bool? = nil
            let details = "Published file structurally valid: \(byteCount) bytes"
            #endif

            PipelineLogger.shared.log("[MediaAssembler] assemble completed: outputURL=\(publishedDestinationURL.path), byteCount=\(byteCount), pathExtension=\(publishedDestinationURL.pathExtension)")
            let publishedReport = MediaAssemblyValidationReport(
                container: finalContainer,
                trackCount: request.tracks.count,
                mediaSegmentCount: validation.mediaSegmentCount,
                totalInputBytes: validation.totalInputBytes,
                isReadyForAssembly: true,
                isStructurallyValid: true,
                isPlayableConfirmed: isPlayableConfirmed,
                validationDetails: details,
                state: .outputValidated
            )
            return MediaAssemblyOutput(
                destinationURL: publishedDestinationURL,
                container: finalContainer,
                trackCount: request.tracks.count,
                byteCount: byteCount,
                validation: publishedReport
            )
        } catch let error as MediaAssemblyError {
            throw error
        } catch {
            throw MediaAssemblyError.fileOperationFailed
        }
    }

#if canImport(AVFoundation)
    private final class MuxState: @unchecked Sendable {
        let lock = NSLock()
        var appendFailed = false
        var lastError: String? = nil
        var samplesAppended = 0
    }

    private final class MuxTrackContext: @unchecked Sendable {
        let kind: MediaAssemblyTrackKind
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var nextSample: CMSampleBuffer? = nil
        var isFinished: Bool = false

        init(
            kind: MediaAssemblyTrackKind,
            reader: AVAssetReader,
            output: AVAssetReaderTrackOutput,
            input: AVAssetWriterInput
        ) {
            self.kind = kind
            self.reader = reader
            self.output = output
            self.input = input
        }
    }

    private struct LoadedSourceTrack {
        let directAsset: AVURLAsset
        let asset: AVAsset
        let manifestURL: URL?
        let sourceURL: URL
        let kind: MediaAssemblyTrackKind
        let fileSize: Int64
    }

    private static func extractPTSFromPacket(_ chunk: Data, offset: Int) -> UInt64? {
        guard offset + 188 <= chunk.count, chunk[offset] == 0x47 else { return nil }
        let byte1 = chunk[offset + 1]
        let pusi = (byte1 & 0x40) != 0
        guard pusi else { return nil }

        let byte3 = chunk[offset + 3]
        let afc = (byte3 >> 4) & 0x03
        var payloadOffset = offset + 4
        if afc == 0 || afc == 2 {
            return nil
        } else if afc == 3 {
            let adaptationLength = Int(chunk[offset + 4])
            payloadOffset = offset + 5 + adaptationLength
        }
        guard payloadOffset + 14 <= offset + 188 else { return nil }
        guard chunk[payloadOffset] == 0x00,
              chunk[payloadOffset + 1] == 0x00,
              chunk[payloadOffset + 2] == 0x01 else { return nil }
        let streamID = chunk[payloadOffset + 3]
        guard (streamID >= 0xC0 && streamID <= 0xDF) || (streamID >= 0xE0 && streamID <= 0xEF) else {
            return nil
        }
        let ptsDtsFlags = (chunk[payloadOffset + 7] >> 6) & 0x03
        guard (ptsDtsFlags & 0x02) != 0 else { return nil }

        let b0 = UInt64(chunk[payloadOffset + 9])
        let b1 = UInt64(chunk[payloadOffset + 10])
        let b2 = UInt64(chunk[payloadOffset + 11])
        let b3 = UInt64(chunk[payloadOffset + 12])
        let b4 = UInt64(chunk[payloadOffset + 13])
        return ((b0 & 0x0E) << 29) |
               ((b1 & 0xFF) << 22) |
               ((b2 & 0xFE) << 14) |
               ((b3 & 0xFF) << 7)  |
               ((b4 & 0xFE) >> 1)
    }

    private static func readMPEGTSFirstPTS(fileURL: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer {
            do {
                try handle.close()
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to close handle in readMPEGTSFirstPTS: \(error)")
            }
        }
        let scanSize = 188 * 512
        guard let chunk = try? handle.read(upToCount: scanSize), chunk.count >= 188 else { return nil }
        let count = chunk.count / 188
        for i in 0..<count {
            if let pts = extractPTSFromPacket(chunk, offset: i * 188) {
                return pts
            }
        }
        return nil
    }

    private static func readMPEGTSLastPTS(fileURL: URL, fileSize: Int64) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer {
            do {
                try handle.close()
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to close handle in readMPEGTSLastPTS: \(error)")
            }
        }
        let scanSize = Int64(188 * 512)
        let offset = max(0, fileSize - scanSize)
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.readToEnd(), chunk.count >= 188 else { return nil }
            let count = chunk.count / 188
            for i in stride(from: count - 1, through: 0, by: -1) {
                if let pts = extractPTSFromPacket(chunk, offset: i * 188) {
                    return pts
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func estimateMPEGTSDuration(fileURL: URL, asset: AVAsset? = nil) async -> Double {
        if let asset {
            if let dur = try? await asset.load(.duration), dur.isNumeric && dur.seconds > 0 {
                return dur.seconds
            }
        }

        guard let fileSize = FileManager.default.fileSize(atPath: fileURL.path), fileSize >= 188 else {
            return 10.0
        }

        let firstPTS = readMPEGTSFirstPTS(fileURL: fileURL)
        let lastPTS = readMPEGTSLastPTS(fileURL: fileURL, fileSize: fileSize)
        if let first = firstPTS, let last = lastPTS, last > first {
            let dur = Double(last - first) / 90000.0
            if dur > 0.05 && dur < 86400.0 {
                return dur
            }
        }

        let estimated = Double(fileSize * 8) / 2_000_000.0
        return max(1.0, min(estimated, 14400.0))
    }

    private static func loadTrackAsset(
        sourceURL: URL,
        kind: MediaAssemblyTrackKind,
        container: MediaAssemblyContainer,
        temporaryDirectoryURL: URL
    ) async -> LoadedSourceTrack {
        let fileManager = FileManager.default
        let size = fileManager.fileSize(atPath: sourceURL.path) ?? 0
        let directAsset = AVURLAsset(url: sourceURL)
        _ = try? await directAsset.load(.tracks, .isPlayable, .duration)

        var manifestURL: URL? = nil
        var targetAsset: AVAsset = directAsset

        let directTracks = (try? await directAsset.load(.tracks)) ?? []
        if container == .mpegTS && directTracks.isEmpty {
            let estimatedDuration = await estimateMPEGTSDuration(fileURL: sourceURL, asset: directAsset)
            let targetDuration = max(1, Int(ceil(estimatedDuration)))

            let m3u8URL = temporaryDirectoryURL
                .appendingPathComponent("manifest-\(kind.rawValue)-\(UUID().uuidString).m3u8", isDirectory: false)
            let tempKeyURL = temporaryDirectoryURL.appendingPathComponent("key.bin")
            let sourceKeyURL = sourceURL.deletingLastPathComponent().appendingPathComponent("key.bin")
            if !fileManager.fileExists(atPath: tempKeyURL.path) && fileManager.fileExists(atPath: sourceKeyURL.path) {
                do {
                    try fileManager.copyItem(at: sourceKeyURL, to: tempKeyURL)
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to copy sourceKeyURL: \(error)")
                }
            }
            let keyTag = fileManager.fileExists(atPath: tempKeyURL.path)
                ? "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key.bin\"\n"
                : ""
            let m3u8Content = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:\(targetDuration)
            #EXT-X-MEDIA-SEQUENCE:0
            \(keyTag)#EXTINF:\(String(format: "%.3f", estimatedDuration)),
            \(sourceURL.lastPathComponent)
            #EXT-X-ENDLIST
            """
            do {
                try m3u8Content.write(to: m3u8URL, atomically: true, encoding: .utf8)
                manifestURL = m3u8URL
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to write manifest wrapper: \(error)")
            }

            if let mURL = manifestURL {
                let playlistAsset = AVURLAsset(url: mURL)
                _ = try? await playlistAsset.load(.tracks, .isPlayable, .duration)
                let pTracks = (try? await playlistAsset.load(.tracks)) ?? []
                if !pTracks.isEmpty {
                    targetAsset = playlistAsset
                }
            }
        }

        let loadedTracks = (try? await targetAsset.load(.tracks)) ?? []
        let mediaTypes = loadedTracks.map { $0.mediaType.rawValue }.joined(separator: ", ")
        let dur = (try? await targetAsset.load(.duration)) ?? .zero
        let duration = dur.isNumeric ? dur.seconds : -1.0
        PipelineLogger.shared.log("[MediaAssembler] Loaded source track diagnostics: kind=\(kind.rawValue), file=\(sourceURL.lastPathComponent), size=\(size) bytes, container=\(container), tracks=\(loadedTracks.count) [\(mediaTypes)], duration=\(duration)s")

        return LoadedSourceTrack(
            directAsset: directAsset,
            asset: targetAsset,
            manifestURL: manifestURL,
            sourceURL: sourceURL,
            kind: kind,
            fileSize: size
        )
    }

    private static func publishOutput(
        from temporaryURL: URL,
        to destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let parentDir = destinationURL.deletingLastPathComponent()
        try DownloadManagerViewModel.ensureDirectoryExistsAndWritable(parentDir, fileManager: fileManager)

        if fileManager.fileExists(atPath: destinationURL.path) {
            #if canImport(Darwin)
            do {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL, backupItemName: nil, options: [])
                let destHandle = try FileHandle(forWritingTo: destinationURL)
                defer {
                    do {
                        try destHandle.close()
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to close destHandle: \(error)")
                    }
                }
                try destHandle.synchronize()
            } catch {
                // Non-destructive fallback: preserve existing destination if move fails
                let backupURL = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".backup-\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                do {
                    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                    let destHandle = try FileHandle(forWritingTo: destinationURL)
                    defer {
                        do {
                            try destHandle.close()
                        } catch {
                            PipelineLogger.shared.log("[MediaAssembler] Failed to close destHandle: \(error)")
                        }
                    }
                    try destHandle.synchronize()
                    do {
                        try fileManager.removeItem(at: backupURL)
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to remove backupURL \(backupURL.path): \(error)")
                    }
                } catch {
                    do {
                        try fileManager.removeItem(at: destinationURL)
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to remove destinationURL \(destinationURL.path): \(error)")
                    }
                    do {
                        try fileManager.moveItem(at: backupURL, to: destinationURL)
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to restore backupURL \(backupURL.path): \(error)")
                    }
                    throw error
                }
            }
            #else
            let backupURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".backup-\(UUID().uuidString)-\(destinationURL.lastPathComponent)")
            try fileManager.moveItem(at: destinationURL, to: backupURL)
            do {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                let destHandle = try FileHandle(forWritingTo: destinationURL)
                defer {
                    do {
                        try destHandle.close()
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to close destHandle: \(error)")
                    }
                }
                try destHandle.synchronize()
                do {
                    try fileManager.removeItem(at: backupURL)
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to remove backupURL \(backupURL.path): \(error)")
                }
            } catch {
                do {
                    try fileManager.removeItem(at: destinationURL)
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to remove destinationURL \(destinationURL.path): \(error)")
                }
                do {
                    try fileManager.moveItem(at: backupURL, to: destinationURL)
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to restore backupURL \(backupURL.path): \(error)")
                }
                throw error
            }
            #endif
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            do {
                let destHandle = try FileHandle(forWritingTo: destinationURL)
                defer {
                    do {
                        try destHandle.close()
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to close destHandle: \(error)")
                    }
                }
                try destHandle.synchronize()
            } catch {
                do {
                    try fileManager.removeItem(at: destinationURL)
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to remove destinationURL: \(error)")
                }
                throw error
            }
        }
    }

    private static func assembleMultipleTracks(
        _ request: MediaAssemblyRequest,
        validation: MediaAssemblyValidationReport
    ) async throws -> MediaAssemblyOutput {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: request.temporaryDirectoryURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: request.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw MediaAssemblyError.fileOperationFailed
        }

        let sourceExtension = request.container == .mpegTS ? "ts" : "mp4"
        let sourceURLs = request.tracks.enumerated().map { index, track in
            request.temporaryDirectoryURL
                .appendingPathComponent("track-\(index)-\(track.kind.rawValue)-\(UUID().uuidString).\(sourceExtension)", isDirectory: false)
        }
        let outputExtension = request.destinationURL.pathExtension.isEmpty ? "mp4" : request.destinationURL.pathExtension
        let temporaryOutput = request.temporaryDirectoryURL
            .appendingPathComponent("muxed-\(UUID().uuidString).\(outputExtension)", isDirectory: false)

        var preservedSourceURLs = Set<URL>()
        var manifestURLsToClean = [URL]()

        defer {
            for manifestURL in manifestURLsToClean {
                do {
                    try fileManager.removeItem(at: manifestURL)
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to remove manifestURL \(manifestURL.path): \(error)")
                }
            }
            for sourceURL in sourceURLs {
                if !preservedSourceURLs.contains(sourceURL) {
                    do {
                        try fileManager.removeItem(at: sourceURL)
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to remove sourceURL \(sourceURL.path): \(error)")
                    }
                }
            }
            do {
                try fileManager.removeItem(at: temporaryOutput)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to remove temporaryOutput \(temporaryOutput.path): \(error)")
            }
        }

        do {
            for (track, sourceURL) in zip(request.tracks, sourceURLs) {
                guard fileManager.createFile(atPath: sourceURL.path, contents: nil) else {
                    throw MediaAssemblyError.fileOperationFailed
                }
                let handle = try FileHandle(forWritingTo: sourceURL)
                defer {
                    do {
                        try handle.close()
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to close handle: \(error)")
                    }
                }
                if let initialization = track.initializationSegment {
                    try copyValidatedSegment(
                        initialization,
                        kind: track.kind,
                        container: request.container,
                        output: handle
                    )
                }
                for segment in track.mediaSegments {
                    try copyValidatedSegment(
                        segment,
                        kind: track.kind,
                        container: request.container,
                        output: handle
                    )
                }
                try handle.synchronize()
                try handle.close()
            }
        } catch let error as MediaAssemblyError {
            throw error
        } catch {
            throw MediaAssemblyError.fileOperationFailed
        }

        // Deep Source Diagnostics & AVAsset Asynchronous Loading
        var loadedTracks: [LoadedSourceTrack] = []
        for (track, sourceURL) in zip(request.tracks, sourceURLs) {
            let loaded = await loadTrackAsset(
                sourceURL: sourceURL,
                kind: track.kind,
                container: request.container,
                temporaryDirectoryURL: request.temporaryDirectoryURL
            )
            loadedTracks.append(loaded)
        }
        for loaded in loadedTracks {
            if let mURL = loaded.manifestURL {
                manifestURLsToClean.append(mURL)
            }
        }

        do {
            let writer = try AVAssetWriter(outputURL: temporaryOutput, fileType: .mp4)
            if request.container == .fragmentedMP4 {
                writer.movieFragmentInterval = CMTime(seconds: 0.5, preferredTimescale: 600)
            } else {
                writer.shouldOptimizeForNetworkUse = true
            }

            var contexts: [MuxTrackContext] = []
            var canUseWriter = true

            for (track, loaded) in zip(request.tracks, loadedTracks) {
                let mediaType: AVMediaType = track.kind == .video ? .video : .audio
                let sourceTrack = loaded.directAsset.tracks(withMediaType: mediaType).first ??
                                  loaded.asset.tracks(withMediaType: mediaType).first

                guard let chosenTrack = sourceTrack else {
                    let available = loaded.asset.tracks.map { $0.mediaType.rawValue }.joined(separator: ", ")
                    let msg = "No \(mediaType.rawValue) track found in source \(loaded.sourceURL.lastPathComponent). Available: [\(available)]"
                    PipelineLogger.shared.log("[MediaAssembler] \(msg)")
                    canUseWriter = false
                    break
                }

                let assetForReader = !loaded.directAsset.tracks(withMediaType: mediaType).isEmpty ? loaded.directAsset : loaded.asset
                guard let reader = try? AVAssetReader(asset: assetForReader) else {
                    PipelineLogger.shared.log("[MediaAssembler] Cannot initialize AVAssetReader for \(track.kind.rawValue)")
                    canUseWriter = false
                    break
                }

                let output = AVAssetReaderTrackOutput(track: chosenTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    let msg = "Cannot add reader output for \(track.kind.rawValue)"
                    PipelineLogger.shared.log("[MediaAssembler] \(msg)")
                    canUseWriter = false
                    break
                }
                reader.add(output)

                let formatDesc = (chosenTrack.formatDescriptions as? [CMFormatDescription])?.first
                let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil, sourceFormatHint: formatDesc)
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else {
                    let msg = "Cannot add writer input for \(track.kind.rawValue)"
                    PipelineLogger.shared.log("[MediaAssembler] \(msg)")
                    canUseWriter = false
                    break
                }
                writer.add(input)

                contexts.append(MuxTrackContext(kind: track.kind, reader: reader, output: output, input: input))
            }

            var muxSucceeded = false

            if canUseWriter && contexts.count == request.tracks.count {
                for ctx in contexts {
                    guard ctx.reader.startReading() else {
                        let err = ctx.reader.error?.localizedDescription ?? "unknown reader error"
                        PipelineLogger.shared.log("[MediaAssembler] reader.startReading() failed for \(ctx.kind.rawValue): \(err)")
                        canUseWriter = false
                        break
                    }
                }

                if canUseWriter && writer.startWriting() {
                    let muxQueue = DispatchQueue(label: "com.engine.media-assembler.muxQueue")
                    var hasFailed = false
                    var failureReason: String? = nil
                    var sessionStarted = false
                    var isCompleted = false

                    await withCheckedContinuation { continuation in
                        var resumed = false
                        let resumeOnce: @Sendable () -> Void = {
                            if !resumed {
                                resumed = true
                                continuation.resume()
                            }
                        }

                        let pumpSamples: @Sendable () -> Void = {
                            muxQueue.async {
                                guard !hasFailed, !isCompleted else { return }
                                if writer.status == .failed || writer.status == .cancelled {
                                    hasFailed = true
                                    failureReason = writer.error?.localizedDescription ?? "Writer status: \(writer.status.rawValue)"
                                    isCompleted = true
                                    resumeOnce()
                                    return
                                }

                                while true {
                                    // 1. Fetch next sample for active tracks needing one
                                    for ctx in contexts where !ctx.isFinished && ctx.nextSample == nil {
                                        if let sample = ctx.output.copyNextSampleBuffer() {
                                            ctx.nextSample = sample
                                        } else {
                                            ctx.isFinished = true
                                            ctx.input.markAsFinished()
                                            if ctx.reader.status == .failed {
                                                let rErr = ctx.reader.error?.localizedDescription ?? "unknown"
                                                PipelineLogger.shared.log("[MediaAssembler] Reader for \(ctx.kind.rawValue) failed: \(rErr)")
                                                hasFailed = true
                                                failureReason = "Reader for \(ctx.kind.rawValue) failed: \(rErr)"
                                                isCompleted = true
                                                resumeOnce()
                                                return
                                            }
                                        }
                                    }

                                    // 2. If all tracks are finished, complete
                                    if contexts.allSatisfy({ $0.isFinished }) {
                                        isCompleted = true
                                        resumeOnce()
                                        return
                                    }

                                    // 3. Find active tracks with buffered sample
                                    let activeContexts = contexts.filter { !$0.isFinished && $0.nextSample != nil }
                                    if activeContexts.isEmpty {
                                        break
                                    }

                                    // If some unfinished tracks have not buffered a sample yet, wait for them
                                    let unfinishedWithoutSample = contexts.filter { !$0.isFinished && $0.nextSample == nil }
                                    if !unfinishedWithoutSample.isEmpty {
                                        break
                                    }

                                    // 4. Select the sample with earliest Presentation Timestamp (PTS)
                                    guard let nextCtx = activeContexts.min(by: { a, b in
                                        guard let sampleA = a.nextSample, let sampleB = b.nextSample else { return false }
                                        let timeA = CMSampleBufferGetPresentationTimeStamp(sampleA)
                                        let timeB = CMSampleBufferGetPresentationTimeStamp(sampleB)
                                        return CMTimeCompare(timeA, timeB) < 0
                                    }), let sampleToAppend = nextCtx.nextSample else {
                                        break
                                    }

                                    // 5. Ensure the chosen input is ready for more media data
                                    guard nextCtx.input.isReadyForMoreMediaData else {
                                        break
                                    }

                                    // 6. Start the session at the timestamp of the first appended sample
                                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleToAppend)
                                    if !sessionStarted {
                                        writer.startSession(atSourceTime: pts)
                                        sessionStarted = true
                                    }

                                    // 7. Append sample buffer
                                    if nextCtx.input.append(sampleToAppend) {
                                        nextCtx.nextSample = nil
                                    } else {
                                        let wErr = writer.error?.localizedDescription ?? "unknown writer error"
                                        PipelineLogger.shared.log("[MediaAssembler] Failed appending \(nextCtx.kind.rawValue) sample: \(wErr)")
                                        hasFailed = true
                                        failureReason = wErr
                                        isCompleted = true
                                        resumeOnce()
                                        return
                                    }
                                }
                            }
                        }

                        for ctx in contexts {
                            ctx.input.requestMediaDataWhenReady(on: muxQueue) {
                                pumpSamples()
                            }
                        }

                        // Initial pump
                        pumpSamples()
                    }

                    if hasFailed || (writer.status != .writing && writer.status != .completed) {
                        for ctx in contexts { ctx.reader.cancelReading() }
                        writer.cancelWriting()
                        let reason = failureReason ?? writer.error?.localizedDescription ?? "Muxing failed"
                        PipelineLogger.shared.log("[MediaAssembler] AVAssetWriter muxing failed: \(reason)")
                    } else {
                        await writer.finishWriting()

                        if writer.status == .completed {
                            do {
                                try await validateMuxedOutput(
                                    temporaryOutput,
                                    expectedKinds: request.tracks.map(\.kind),
                                    writerError: writer.error
                                )
                                muxSucceeded = true
                            } catch {
                                PipelineLogger.shared.log("[MediaAssembler] validateMuxedOutput failed: \(error.localizedDescription)")
                            }
                        } else {
                            let err = writer.error?.localizedDescription ?? "writer status: \(writer.status.rawValue)"
                            PipelineLogger.shared.log("[MediaAssembler] writer.finishWriting failed: \(err)")
                        }
                    }
                } else {
                    for ctx in contexts { ctx.reader.cancelReading() }
                    let err = writer.error?.localizedDescription ?? "unknown writer error"
                    PipelineLogger.shared.log("[MediaAssembler] writer.startWriting() failed: \(err)")
                }
            }

            if !muxSucceeded {
                PipelineLogger.shared.log("[MediaAssembler] AVAssetWriter muxing unsuccessful. Attempting AVAssetExportSession passthrough fallback...")
                if await exportMultipleTracksWithPassthrough(request: request, loadedTracks: loadedTracks, outputURL: temporaryOutput) {
                    PipelineLogger.shared.log("[MediaAssembler] AVAssetExportSession passthrough fallback succeeded.")
                    muxSucceeded = true
                } else {
                    throw MediaAssemblyError.assetWriterFailed(reason: "Multi-track muxing and passthrough fallback failed")
                }
            }

            try publishOutput(from: temporaryOutput, to: request.destinationURL)
            guard let byteCount = fileManager.fileSize(atPath: request.destinationURL.path), byteCount > 0 else {
                throw MediaAssemblyError.fileOperationFailed
            }

            // Validate final published multi-track output on disk
            let publishedReport = MediaAssemblyValidationReport(
                container: .fragmentedMP4,
                trackCount: request.tracks.count,
                mediaSegmentCount: validation.mediaSegmentCount,
                totalInputBytes: validation.totalInputBytes,
                isReadyForAssembly: true,
                isStructurallyValid: true,
                isPlayableConfirmed: true,
                validationDetails: "Multi-track output validated: \(byteCount) bytes",
                state: .outputValidated
            )
            PipelineLogger.shared.log("[MediaAssembler] assembleMultipleTracks completed: outputURL=\(request.destinationURL.path), byteCount=\(byteCount), pathExtension=\(request.destinationURL.pathExtension)")
            return MediaAssemblyOutput(
                destinationURL: request.destinationURL,
                container: .fragmentedMP4,
                trackCount: request.tracks.count,
                byteCount: byteCount,
                validation: publishedReport
            )
        } catch {
            // MUXING / CONVERSION FAILED:
            // Do NOT disguise failed multi-track assembly as a single-track success!
            // Quarantine source tracks and diagnostics for forensic recovery, and propagate the error.
            PipelineLogger.shared.log("[MediaAssembler] Multi-track assembly/muxing failed: \(error.localizedDescription). Quarantining input tracks...")
            let quarantineDir = request.destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".media-quarantine-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
                var quarantinedFiles: [String] = []
                for (idx, sourceURL) in sourceURLs.enumerated() {
                    let trackKind = request.tracks.indices.contains(idx) ? request.tracks[idx].kind.rawValue : "track\(idx)"
                    let qDest = quarantineDir.appendingPathComponent("\(trackKind)-\(sourceURL.lastPathComponent)")
                    if fileManager.fileExists(atPath: sourceURL.path) {
                        do {
                            try fileManager.copyItem(at: sourceURL, to: qDest)
                            quarantinedFiles.append(qDest.lastPathComponent)
                        } catch {
                            PipelineLogger.shared.log("[MediaAssembler] Failed to copy quarantine item \(sourceURL.path): \(error)")
                        }
                    }
                }
                if fileManager.fileExists(atPath: temporaryOutput.path) {
                    let qPartial = quarantineDir.appendingPathComponent("partial-mux-\(temporaryOutput.lastPathComponent)")
                    do {
                        try fileManager.copyItem(at: temporaryOutput, to: qPartial)
                        quarantinedFiles.append(qPartial.lastPathComponent)
                    } catch {
                        PipelineLogger.shared.log("[MediaAssembler] Failed to copy partial quarantine mux: \(error)")
                    }
                }
                let record = MediaQuarantineRecord(
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    reason: error.localizedDescription,
                    destinationURL: request.destinationURL.path,
                    container: request.container.rawValue,
                    expectedTrackKinds: request.tracks.map { $0.kind.rawValue },
                    quarantinedFiles: quarantinedFiles,
                    validationDetails: "Multi-track muxing failed: preserved raw track sources for recovery"
                )
                do {
                    let jsonData = try JSONEncoder().encode(record)
                    let infoURL = quarantineDir.appendingPathComponent("quarantine-info.json")
                    try jsonData.write(to: infoURL)
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to write quarantine info: \(error)")
                }
                PipelineLogger.shared.log("[MediaAssembler] Preserved \(quarantinedFiles.count) assembly inputs in quarantine: \(quarantineDir.path)")
            } catch let qErr {
                PipelineLogger.shared.log("[MediaAssembler] Failed writing quarantine records: \(qErr.localizedDescription)")
            }

            if fileManager.fileExists(atPath: request.destinationURL.path) {
                do {
                    try fileManager.removeItem(at: request.destinationURL)
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to remove destinationURL on error: \(error)")
                }
            }
            throw error
        }
    }

    private static func validateMuxedOutput(
        _ url: URL,
        expectedKinds: [MediaAssemblyTrackKind],
        writerError: Error?
    ) async throws {
        guard let size = FileManager.default.fileSize(atPath: url.path),
              size > 0 else {
            let reason = writerError?.localizedDescription ?? "Muxed output file is empty or missing"
            PipelineLogger.shared.log("[MediaAssembler] validateMuxedOutput failed: \(reason)")
            throw MediaAssemblyError.assetWriterFailed(reason: reason)
        }

        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        let isPlayable: Bool
        do {
            tracks = try await asset.load(.tracks)
            duration = try await asset.load(.duration)
            isPlayable = try await asset.load(.isPlayable)
        } catch {
            let reason = writerError?.localizedDescription ?? "Could not load muxed output properties: \(error.localizedDescription)"
            PipelineLogger.shared.log("[MediaAssembler] validateMuxedOutput failed: \(reason)")
            throw MediaAssemblyError.assetWriterFailed(reason: reason)
        }

        guard !tracks.isEmpty else {
            let reason = writerError?.localizedDescription ?? "Muxed output has no media tracks"
            PipelineLogger.shared.log("[MediaAssembler] validateMuxedOutput failed: \(reason)")
            throw MediaAssemblyError.assetWriterFailed(reason: reason)
        }

        let hasVideo = !tracks.filter { $0.mediaType == .video }.isEmpty
        let hasAudio = !tracks.filter { $0.mediaType == .audio }.isEmpty
        if expectedKinds.contains(.video) && !hasVideo {
            let reason = writerError?.localizedDescription ?? "Muxed output is missing expected video track"
            PipelineLogger.shared.log("[MediaAssembler] validateMuxedOutput failed: \(reason)")
            throw MediaAssemblyError.assetWriterFailed(reason: reason)
        }
        if expectedKinds.contains(.audio) && !hasAudio {
            let reason = writerError?.localizedDescription ?? "Muxed output is missing expected audio track"
            PipelineLogger.shared.log("[MediaAssembler] validateMuxedOutput failed: \(reason)")
            throw MediaAssemblyError.assetWriterFailed(reason: reason)
        }
        guard duration.isNumeric && duration.seconds > 0 else {
            let reason = writerError?.localizedDescription ?? "Muxed output duration is non-numeric or zero"
            PipelineLogger.shared.log("[MediaAssembler] validateMuxedOutput failed: \(reason)")
            throw MediaAssemblyError.assetWriterFailed(reason: reason)
        }

        guard isPlayable else {
            let reason = writerError?.localizedDescription ?? "Muxed output is not playable"
            PipelineLogger.shared.log("[MediaAssembler] validateMuxedOutput failed: \(reason)")
            throw MediaAssemblyError.assetWriterFailed(reason: reason)
        }
    }

    private static func exportMultipleTracksWithPassthrough(
        request: MediaAssemblyRequest,
        loadedTracks: [LoadedSourceTrack],
        outputURL: URL
    ) async -> Bool {
        let composition = AVMutableComposition()
        for (track, loaded) in zip(request.tracks, loadedTracks) {
            let mediaType: AVMediaType = track.kind == .video ? .video : .audio
            let sourceTrack = loaded.asset.tracks(withMediaType: mediaType).first ??
                              loaded.directAsset.tracks(withMediaType: mediaType).first
            guard let st = sourceTrack else {
                PipelineLogger.shared.log("[MediaAssembler] Passthrough export: no \(mediaType.rawValue) track in \(loaded.sourceURL.lastPathComponent)")
                continue
            }
            guard let compTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                PipelineLogger.shared.log("[MediaAssembler] Passthrough export: cannot add mutable track for \(mediaType.rawValue)")
                continue
            }
            let duration = st.timeRange.duration
            let assetDuration = loaded.asset.duration.isValid ? loaded.asset.duration : loaded.directAsset.duration
            let timeRange = CMTimeRange(start: .zero, duration: duration.isValid && duration > .zero ? duration : assetDuration)
            do {
                try compTrack.insertTimeRange(timeRange, of: st, at: .zero)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Passthrough export: insertTimeRange failed for \(mediaType.rawValue): \(error.localizedDescription)")
            }
        }

        guard !composition.tracks.isEmpty else {
            PipelineLogger.shared.log("[MediaAssembler] Passthrough export: composition has no tracks")
            return false
        }

        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        for preset in presets {
            guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to remove outputURL \(outputURL.path): \(error)")
            }
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true

            await withCheckedContinuation { continuation in
                exportSession.exportAsynchronously {
                    continuation.resume()
                }
            }

            if exportSession.status == .completed && FileManager.default.fileExists(atPath: outputURL.path) {
                let size = FileManager.default.fileSize(atPath: outputURL.path) ?? 0
                let isValid = await validateRemuxedMP4(outputURL)
                if size > 0 && isValid {
                    PipelineLogger.shared.log("[MediaAssembler] Passthrough export succeeded with preset \(preset): \(size) bytes")
                    return true
                }
            }
            PipelineLogger.shared.log("[MediaAssembler] Passthrough export with preset \(preset) failed: status=\(exportSession.status.rawValue), error=\(exportSession.error?.localizedDescription ?? "none")")
        }

        return false
    }

    private static func validateRemuxedMP4(_ url: URL) async -> Bool {
        let fileManager = FileManager.default
        guard let size = fileManager.fileSize(atPath: url.path), size > 0 else {
            return false
        }
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.load(.tracks)
            guard !tracks.isEmpty else { return false }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric && duration.seconds > 0 else { return false }
            return true
        } catch {
            return false
        }
    }
    public static func remuxMPEGTSFileToMP4(sourceTSURL: URL, destinationMP4URL: URL) async throws {
        let fileManager = FileManager.default
        let tempDir = destinationMP4URL.deletingLastPathComponent()
        let tempMP4 = tempDir
            .appendingPathComponent("remux-\(UUID().uuidString).mp4", isDirectory: false)
        defer {
            do {
                if fileManager.fileExists(atPath: tempMP4.path) {
                    try fileManager.removeItem(at: tempMP4)
                }
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to remove tempMP4 \(tempMP4.path): \(error)")
            }
        }

        // AVFoundation requires a .ts extension (or .m3u8 playlist wrapper) to parse MPEG-TS
        let tsFileURL = tempDir.appendingPathComponent("source-\(UUID().uuidString).ts", isDirectory: false)
        do {
            try fileManager.removeItem(at: tsFileURL)
        } catch {
            PipelineLogger.shared.log("[MediaAssembler] Failed to remove tsFileURL before remux \(tsFileURL.path): \(error)")
        }
        do {
            try fileManager.copyItem(at: sourceTSURL, to: tsFileURL)
        } catch {
            do {
                try fileManager.linkItem(at: sourceTSURL, to: tsFileURL)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to linkItem for tsFileURL: \(error)")
            }
        }
        defer {
            do {
                try fileManager.removeItem(at: tsFileURL)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to remove tsFileURL \(tsFileURL.path): \(error)")
            }
        }

        // Create a local single-segment HLS manifest wrapper so AVFoundation can demux MPEG-TS reliably on iOS & macOS
        let playlistURL = tempDir.appendingPathComponent("manifest-\(UUID().uuidString).m3u8", isDirectory: false)
        let tempKeyURL = tempDir.appendingPathComponent("key.bin")
        let sourceKeyURL = sourceTSURL.deletingLastPathComponent().appendingPathComponent("key.bin")
        let destKeyURL = destinationMP4URL.deletingLastPathComponent().appendingPathComponent("key.bin")
        if !fileManager.fileExists(atPath: tempKeyURL.path) {
            if fileManager.fileExists(atPath: sourceKeyURL.path) {
                do {
                    try fileManager.copyItem(at: sourceKeyURL, to: tempKeyURL)
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to copy sourceKeyURL: \(error)")
                }
            } else if fileManager.fileExists(atPath: destKeyURL.path) {
                do {
                    try fileManager.copyItem(at: destKeyURL, to: tempKeyURL)
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to copy destKeyURL: \(error)")
                }
            }
        }
        let keyTag = fileManager.fileExists(atPath: tempKeyURL.path)
            ? "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key.bin\"\n"
            : ""

        let tsAsset = AVURLAsset(url: tsFileURL)
        _ = try? await tsAsset.load(.tracks, .isPlayable, .duration)
        let tsTracks = (try? await tsAsset.load(.tracks)) ?? []

        var targetAsset: AVAsset = tsAsset
        if tsTracks.isEmpty {
            let estimatedDuration = await estimateMPEGTSDuration(fileURL: tsFileURL, asset: tsAsset)
            let targetDuration = max(1, Int(ceil(estimatedDuration)))

            let m3u8Content = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:\(targetDuration)
            #EXT-X-MEDIA-SEQUENCE:0
            \(keyTag)#EXTINF:\(String(format: "%.3f", estimatedDuration)),
            \(tsFileURL.lastPathComponent)
            #EXT-X-ENDLIST
            """
            do {
                try m3u8Content.write(to: playlistURL, atomically: true, encoding: .utf8)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to write playlistURL: \(error)")
            }
            defer {
                do {
                    if fileManager.fileExists(atPath: playlistURL.path) {
                        try fileManager.removeItem(at: playlistURL)
                    }
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to remove playlistURL \(playlistURL.path): \(error)")
                }
                do {
                    if fileManager.fileExists(atPath: tempKeyURL.path) {
                        try fileManager.removeItem(at: tempKeyURL)
                    }
                } catch {
                    PipelineLogger.shared.log("[MediaAssembler] Failed to remove tempKeyURL \(tempKeyURL.path): \(error)")
                }
            }

            let playlistAsset = AVURLAsset(url: playlistURL)
            _ = try? await playlistAsset.load(.tracks, .isPlayable, .duration)
            let pTracks = (try? await playlistAsset.load(.tracks)) ?? []
            if !pTracks.isEmpty {
                targetAsset = playlistAsset
            }
        }

        let videoTracks = targetAsset.tracks(withMediaType: .video)
        let audioTracks = targetAsset.tracks(withMediaType: .audio)
        let durationSec = targetAsset.duration.isNumeric ? targetAsset.duration.seconds : -1.0
        let playable: Bool
        if #available(macOS 12.0, iOS 15.0, *) {
            playable = targetAsset.isPlayable
        } else {
            playable = true
        }
        let trackCodecs = targetAsset.tracks.compactMap { track -> String? in
            let desc = (track.formatDescriptions as? [CMFormatDescription])?.first
            if let desc = desc {
                let mediaSubtype = CMFormatDescriptionGetMediaSubType(desc)
                let fourCC = String(format: "%c%c%c%c",
                                    (mediaSubtype >> 24) & 0xff,
                                    (mediaSubtype >> 16) & 0xff,
                                    (mediaSubtype >> 8) & 0xff,
                                    mediaSubtype & 0xff)
                return "\(track.mediaType.rawValue):\(fourCC)"
            }
            return track.mediaType.rawValue
        }.joined(separator: ", ")

        PipelineLogger.shared.log("[MediaAssembler] MPEG-TS source diagnostics: totalTracks=\(targetAsset.tracks.count), video=\(videoTracks.count), audio=\(audioTracks.count), duration=\(durationSec)s, playable=\(playable), codecs=[\(trackCodecs)]")

        var didSucceed = false
        var lastErrorReason: String? = nil

        // Attempt 1: AVAssetExportSession passthrough
        PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 1: AVAssetExportSession with AVAssetExportPresetPassthrough...")
        if let exportSession = AVAssetExportSession(asset: targetAsset, presetName: AVAssetExportPresetPassthrough) {
            exportSession.outputURL = tempMP4
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true
            await withCheckedContinuation { continuation in
                exportSession.exportAsynchronously {
                    continuation.resume()
                }
            }
            if exportSession.status == .completed && fileManager.fileExists(atPath: tempMP4.path) {
                let size = fileManager.fileSize(atPath: tempMP4.path) ?? 0
                let isValid = await validateRemuxedMP4(tempMP4)
                if size > 0 && isValid {
                    PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 1 succeeded: \(size) bytes")
                    didSucceed = true
                } else {
                    lastErrorReason = "Attempt 1 output validation failed (size=\(size))"
                    PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 1 produced invalid MP4 (size=\(size))")
                }
            } else {
                let errDesc = exportSession.error?.localizedDescription ?? "unknown error"
                lastErrorReason = "Attempt 1 status=\(exportSession.status.rawValue), error=\(errDesc)"
                PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 1 failed: status=\(exportSession.status.rawValue), error=\(errDesc)")
            }
        } else {
            lastErrorReason = "AVAssetExportSession(preset: Passthrough) could not be initialized"
            PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 1: export session could not be created with preset Passthrough")
        }

        // Attempt 2: AVAssetExportPresetHighestQuality
        if !didSucceed {
            do {
                try fileManager.removeItem(at: tempMP4)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to remove tempMP4: \(error)")
            }
            PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 2: AVAssetExportSession with AVAssetExportPresetHighestQuality...")
            if let exportSession = AVAssetExportSession(asset: targetAsset, presetName: AVAssetExportPresetHighestQuality) {
                exportSession.outputURL = tempMP4
                exportSession.outputFileType = .mp4
                exportSession.shouldOptimizeForNetworkUse = true
                await withCheckedContinuation { continuation in
                    exportSession.exportAsynchronously {
                        continuation.resume()
                    }
                }
                if exportSession.status == .completed && fileManager.fileExists(atPath: tempMP4.path) {
                    let size = fileManager.fileSize(atPath: tempMP4.path) ?? 0
                    let isValid = await validateRemuxedMP4(tempMP4)
                    if size > 0 && isValid {
                        PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 2 succeeded: \(size) bytes")
                        didSucceed = true
                    } else {
                        lastErrorReason = "Attempt 2 output validation failed (size=\(size))"
                        PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 2 produced invalid MP4 (size=\(size))")
                    }
                } else {
                    let errDesc = exportSession.error?.localizedDescription ?? "unknown error"
                    lastErrorReason = "Attempt 2 status=\(exportSession.status.rawValue), error=\(errDesc)"
                    PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 2 failed: status=\(exportSession.status.rawValue), error=\(errDesc)")
                }
            } else {
                lastErrorReason = "AVAssetExportSession(preset: HighestQuality) could not be initialized"
                PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 2: export session could not be created with preset HighestQuality")
            }
        }

        // Attempt 3: AVAssetReader + AVAssetWriter if tracks are exposed
        if !didSucceed {
            do {
                try fileManager.removeItem(at: tempMP4)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to remove tempMP4: \(error)")
            }
            PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3: AVAssetReader + AVAssetWriter...")
            let assetToRead = targetAsset.tracks.isEmpty ? tsAsset : targetAsset
            if !assetToRead.tracks.isEmpty {
                do {
                    let writer = try AVAssetWriter(outputURL: tempMP4, fileType: .mp4)
                    let reader = try AVAssetReader(asset: assetToRead)
                    var outputsAndInputs: [(AVAssetReaderTrackOutput, AVAssetWriterInput, MediaAssemblyTrackKind)] = []

                    for track in assetToRead.tracks {
                        guard track.mediaType == .video || track.mediaType == .audio else { continue }
                        let kind: MediaAssemblyTrackKind = track.mediaType == .video ? .video : .audio
                        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                        output.alwaysCopiesSampleData = false
                        guard reader.canAdd(output) else {
                            PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3: cannot add reader output for \(kind.rawValue)")
                            continue
                        }
                        reader.add(output)

                        let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil)
                        input.expectsMediaDataInRealTime = false
                        guard writer.canAdd(input) else {
                            PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3: cannot add writer input for \(kind.rawValue)")
                            continue
                        }
                        writer.add(input)

                        outputsAndInputs.append((output, input, kind))
                    }

                    if outputsAndInputs.isEmpty {
                        let msg = "No suitable video or audio tracks could be added to reader/writer"
                        lastErrorReason = msg
                        PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3: \(msg)")
                    } else if !reader.startReading() {
                        let rErr = reader.error?.localizedDescription ?? "unknown reader start error"
                        lastErrorReason = "Reader startReading failed: \(rErr)"
                        PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3: \(lastErrorReason!)")
                    } else if !writer.startWriting() {
                        let wErr = writer.error?.localizedDescription ?? "unknown writer start error"
                        lastErrorReason = "Writer startWriting failed: \(wErr)"
                        PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3: \(lastErrorReason!)")
                        reader.cancelReading()
                    } else {
                        writer.startSession(atSourceTime: .zero)
                        let state = MuxState()

                        await withCheckedContinuation { continuation in
                            var resumed = false
                            let pending = outputsAndInputs.count
                            var completed = 0
                            let countLock = NSLock()

                            for (output, input, kind) in outputsAndInputs {
                                input.requestMediaDataWhenReady(on: DispatchQueue(label: "remux-track-\(UUID().uuidString)")) {
                                    while input.isReadyForMoreMediaData {
                                        guard let sample = output.copyNextSampleBuffer() else {
                                            input.markAsFinished()
                                            countLock.lock()
                                            completed += 1
                                            let isAllDone = completed >= pending
                                            countLock.unlock()
                                            if isAllDone && !resumed {
                                                resumed = true
                                                continuation.resume()
                                            }
                                            return
                                        }
                                        if input.append(sample) {
                                            state.lock.lock()
                                            state.samplesAppended += 1
                                            state.lock.unlock()
                                        } else {
                                            let wErr = writer.error?.localizedDescription ?? "unknown writer error"
                                            PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3: failed appending \(kind.rawValue) sample: \(wErr)")
                                            state.lock.lock()
                                            state.appendFailed = true
                                            state.lastError = wErr
                                            state.lock.unlock()
                                            reader.cancelReading()
                                            input.markAsFinished()
                                            countLock.lock()
                                            completed += 1
                                            let isAllDone = completed >= pending
                                            countLock.unlock()
                                            if isAllDone && !resumed {
                                                resumed = true
                                                continuation.resume()
                                            }
                                            return
                                        }
                                    }
                                }
                            }
                        }

                        state.lock.lock()
                        let failed = state.appendFailed
                        let samples = state.samplesAppended
                        let appendErr = state.lastError
                        state.lock.unlock()

                        if !failed && samples > 0 {
                            await writer.finishWriting()
                            if writer.status == .completed && fileManager.fileExists(atPath: tempMP4.path) {
                                let size = fileManager.fileSize(atPath: tempMP4.path) ?? 0
                                let isValid = await validateRemuxedMP4(tempMP4)
                                if size > 0 && isValid {
                                    PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3 succeeded: \(size) bytes, \(samples) samples appended")
                                    didSucceed = true
                                } else {
                                    lastErrorReason = "Attempt 3 output validation failed (size=\(size))"
                                    PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3 produced invalid MP4: size=\(size)")
                                }
                            } else {
                                let fErr = writer.error?.localizedDescription ?? "writer status: \(writer.status.rawValue)"
                                lastErrorReason = "Writer finishWriting failed: \(fErr)"
                                PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3 finishWriting failed: \(fErr)")
                            }
                        } else {
                            lastErrorReason = appendErr ?? "No samples appended or append failed (samples=\(samples))"
                            PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3 failed: appendFailed=\(failed), samples=\(samples), error=\(lastErrorReason!)")
                        }
                    }
                } catch {
                    lastErrorReason = "Attempt 3 threw error: \(error.localizedDescription)"
                    PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3 error: \(error.localizedDescription)")
                }
            } else {
                lastErrorReason = "No tracks exposed on assetToRead"
                PipelineLogger.shared.log("[MediaAssembler] Remux Attempt 3: assetToRead has no tracks")
            }
        }

        guard didSucceed else {
            let reason = lastErrorReason ?? "All remux attempts failed"
            PipelineLogger.shared.log("[MediaAssembler] MPEG-TS remuxing failed to produce valid MP4: \(destinationMP4URL.path). Reason: \(reason)")
            throw MediaAssemblyError.assetWriterFailed(reason: reason)
        }

        if fileManager.fileExists(atPath: destinationMP4URL.path) {
            do {
                try fileManager.removeItem(at: destinationMP4URL)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to remove destinationMP4URL: \(error)")
            }
        }
        try fileManager.moveItem(at: tempMP4, to: destinationMP4URL)
    }
#endif

    private static func isSupported(_ container: MediaAssemblyContainer) -> Bool {
        switch container {
        case .mpegTS, .fragmentedMP4:
            return true
        }
    }

    private static func validateMetadata(
        _ metadata: MediaAssemblyTrackMetadata,
        for kind: MediaAssemblyTrackKind
    ) throws {
        if let timescale = metadata.timescale, timescale <= 0 {
            throw MediaAssemblyError.invalidTrackMetadata(kind)
        }
        if let duration = metadata.duration, (!duration.isFinite || duration < 0) {
            throw MediaAssemblyError.invalidTrackMetadata(kind)
        }
        if let sampleRate = metadata.sampleRate, sampleRate <= 0 {
            throw MediaAssemblyError.invalidTrackMetadata(kind)
        }
        if let channelCount = metadata.channelCount, channelCount <= 0 {
            throw MediaAssemblyError.invalidTrackMetadata(kind)
        }
        if let pixelWidth = metadata.pixelWidth, pixelWidth <= 0 {
            throw MediaAssemblyError.invalidTrackMetadata(kind)
        }
        if let pixelHeight = metadata.pixelHeight, pixelHeight <= 0 {
            throw MediaAssemblyError.invalidTrackMetadata(kind)
        }
    }

    private static func validateSegment(
        _ segment: MediaAssemblySegment,
        for kind: MediaAssemblyTrackKind,
        expectedRole: MediaAssemblySegmentRole,
        expectedOrder: Int?
    ) throws {
        guard segment.role == expectedRole else {
            throw MediaAssemblyError.invalidSegmentRole(kind)
        }
        guard segment.fileURL.isFileURL, !segment.fileURL.path.isEmpty else {
            throw MediaAssemblyError.invalidSegmentFileURL(kind, order: segment.order)
        }
        guard segment.isComplete else {
            throw MediaAssemblyError.incompleteSegment(kind, order: segment.order)
        }
        guard segment.order >= 0 else {
            throw MediaAssemblyError.invalidSegmentOrder(kind)
        }
        if let expectedOrder, segment.order != expectedOrder {
            throw MediaAssemblyError.invalidSegmentOrder(kind)
        }
        if let expectedByteCount = segment.expectedByteCount, expectedByteCount <= 0 {
            throw MediaAssemblyError.invalidSegmentSize(kind, order: segment.order)
        }
        if let actualByteCount = segment.actualByteCount, actualByteCount <= 0 {
            throw MediaAssemblyError.invalidSegmentSize(kind, order: segment.order)
        }
        if let expectedByteCount = segment.expectedByteCount,
           let actualByteCount = segment.actualByteCount,
           expectedByteCount != actualByteCount {
            throw MediaAssemblyError.invalidSegmentSize(kind, order: segment.order)
        }
    }

    private static func knownByteCount(for segment: MediaAssemblySegment) -> Int64? {
        segment.actualByteCount ?? segment.expectedByteCount
    }

    private static func copyValidatedSegment(
        _ segment: MediaAssemblySegment,
        kind: MediaAssemblyTrackKind,
        container: MediaAssemblyContainer,
        output: FileHandle
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: segment.fileURL.path),
              let actualSize = fileManager.fileSize(atPath: segment.fileURL.path),
              actualSize > 0 else {
            throw MediaAssemblyError.invalidSegmentSize(kind, order: segment.order)
        }
        if let expected = segment.expectedByteCount, expected != actualSize {
            throw MediaAssemblyError.invalidSegmentSize(kind, order: segment.order)
        }
        if let declaredActual = segment.actualByteCount, declaredActual != actualSize {
            throw MediaAssemblyError.invalidSegmentSize(kind, order: segment.order)
        }

        switch container {
        case .mpegTS:
            guard validateMPEGTSFile(segment.fileURL) else {
                throw MediaAssemblyError.invalidMediaData(container)
            }
        case .fragmentedMP4:
            let required: Set<String> = segment.role == .initialization
                ? ["ftyp", "moov"]
                : ["moof", "mdat"]
            guard validateISOBaseMediaFile(segment.fileURL, requiredBoxes: required) else {
                throw MediaAssemblyError.invalidMediaData(container)
            }
        }

        guard let input = try? FileHandle(forReadingFrom: segment.fileURL) else {
            throw MediaAssemblyError.fileOperationFailed
        }
        defer {
            do {
                try input.close()
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to close segment input handle: \(error)")
            }
        }
        while true {
            let chunk = try input.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
    }

    private static func quarantineFailedPublishedFile(
        fileURL: URL,
        reason: String,
        container: MediaAssemblyContainer
    ) {
        let fileManager = FileManager.default
        let quarantineDir = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".media-quarantine-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
            let dest = quarantineDir.appendingPathComponent("invalid-output-\(fileURL.lastPathComponent)")
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.moveItem(at: fileURL, to: dest)
            }
            let record = MediaQuarantineRecord(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                reason: reason,
                destinationURL: fileURL.path,
                container: container.rawValue,
                expectedTrackKinds: ["unknown"],
                quarantinedFiles: [dest.lastPathComponent],
                validationDetails: reason
            )
            do {
                let data = try JSONEncoder().encode(record)
                try data.write(to: quarantineDir.appendingPathComponent("quarantine-info.json"))
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to write quarantine info: \(error)")
            }
            PipelineLogger.shared.log("[MediaAssembler] Quarantined invalid published output to \(quarantineDir.path)")
        } catch {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to remove fileURL \(fileURL.path): \(error)")
            }
        }
    }

    private static func validateOutput(_ url: URL, container: MediaAssemblyContainer) -> Bool {
        MediaIntegrityValidator.validateStructure(fileURL: url, container: container).isConfirmedValid
    }

    private static func validateMPEGTSFile(_ url: URL) -> Bool {
        guard let size = FileManager.default.fileSize(atPath: url.path),
              size > 0,
              size % 188 == 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer {
            do {
                try handle.close()
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to close handle: \(error)")
            }
        }
        let packetsPerBuffer = 256
        let bufferSize = 188 * packetsPerBuffer
        do {
            while true {
                guard let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty else { break }
                guard chunk.count % 188 == 0 else { return false }
                let packetCount = chunk.count / 188
                for i in 0..<packetCount {
                    guard chunk[i * 188] == 0x47 else { return false }
                }
            }
            return true
        } catch {
            return false
        }
    }

    private static func validateISOBaseMediaFile(
        _ url: URL,
        requiredBoxes: Set<String>
    ) -> Bool {
        guard let fileSizeInt = FileManager.default.fileSize(atPath: url.path),
              fileSizeInt > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer {
            do {
                try handle.close()
            } catch {
                PipelineLogger.shared.log("[MediaAssembler] Failed to close handle: \(error)")
            }
        }

        let fileSize = UInt64(fileSizeInt)

        var offset: UInt64 = 0
        var boxes = Set<String>()
        do {
            while offset < fileSize {
                guard fileSize - offset >= 8 else { return false }
                try handle.seek(toOffset: offset)
                let header = try handle.read(upToCount: 8) ?? Data()
                guard header.count == 8 else { return false }
                var boxSize = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 |
                    UInt64(header[2]) << 8 | UInt64(header[3])
                let type = String(bytes: header[4...7], encoding: .ascii) ?? ""
                guard !type.isEmpty else { return false }
                var headerSize: UInt64 = 8
                if boxSize == 1 {
                    guard fileSize - offset >= 16 else { return false }
                    let extended = try handle.read(upToCount: 8) ?? Data()
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
            return requiredBoxes.isSubset(of: boxes)
        } catch {
            return false
        }
    }
}

/// Adapter for callers that use the common media-assembly executor boundary.
public struct FileMediaAssemblyExecutor: MediaAssemblyExecutor, Sendable {
    public init() {}

    public func assemble(_ request: MediaAssemblyRequest) async throws -> MediaAssemblyOutput {
        try await MediaAssembler.assemble(request)
    }
}
