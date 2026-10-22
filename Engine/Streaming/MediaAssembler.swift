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
        _ request: MediaAssemblyRequest
    ) throws -> MediaAssemblyOutput {
        let validation = try validateInput(request)
        if request.tracks.count > 1 {
#if canImport(AVFoundation)
            return try assembleMultipleTracks(request, validation: validation)
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
        defer { try? fileManager.removeItem(at: temporaryOutput) }

        do {
            fileManager.createFile(atPath: temporaryOutput.path, contents: nil)
            guard let output = FileHandle(forWritingAtPath: temporaryOutput.path) else {
                throw MediaAssemblyError.fileOperationFailed
            }
            defer { output.closeFile() }

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
            output.synchronizeFile()
        } catch let error as MediaAssemblyError {
            throw error
        } catch {
            throw MediaAssemblyError.fileOperationFailed
        }

        guard validateOutput(temporaryOutput, container: request.container) else {
            throw MediaAssemblyError.invalidMediaData(request.container)
        }

        do {
            if fileManager.fileExists(atPath: request.destinationURL.path) {
                try fileManager.removeItem(at: request.destinationURL)
            }
            try fileManager.moveItem(at: temporaryOutput, to: request.destinationURL)
            let attributes = try fileManager.attributesOfItem(atPath: request.destinationURL.path)
            guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value, byteCount > 0 else {
                throw MediaAssemblyError.fileOperationFailed
            }
            return MediaAssemblyOutput(
                destinationURL: request.destinationURL,
                container: request.container,
                trackCount: request.tracks.count,
                byteCount: byteCount,
                validation: validation
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
    }

    private static func assembleMultipleTracks(
        _ request: MediaAssemblyRequest,
        validation: MediaAssemblyValidationReport
    ) throws -> MediaAssemblyOutput {
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

        let sourceURLs = request.tracks.enumerated().map { index, _ in
            request.temporaryDirectoryURL
                .appendingPathComponent("track-\(index)-\(UUID().uuidString).mp4", isDirectory: false)
        }
        let temporaryOutput = request.temporaryDirectoryURL
            .appendingPathComponent("muxed-\(UUID().uuidString).part", isDirectory: false)
        defer {
            for sourceURL in sourceURLs { try? fileManager.removeItem(at: sourceURL) }
            try? fileManager.removeItem(at: temporaryOutput)
        }

        do {
            for (track, sourceURL) in zip(request.tracks, sourceURLs) {
                fileManager.createFile(atPath: sourceURL.path, contents: nil)
                guard let handle = FileHandle(forWritingAtPath: sourceURL.path) else {
                    throw MediaAssemblyError.fileOperationFailed
                }
                defer { handle.closeFile() }
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
                handle.synchronizeFile()
            }
        } catch let error as MediaAssemblyError {
            throw error
        } catch {
            throw MediaAssemblyError.fileOperationFailed
        }

        do {
            let writer = try AVAssetWriter(outputURL: temporaryOutput, fileType: .mp4)
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            var readers: [AVAssetReader] = []
            var outputs: [AVAssetReaderTrackOutput] = []
            var inputs: [AVAssetWriterInput] = []

            for (track, sourceURL) in zip(request.tracks, sourceURLs) {
                let asset = AVURLAsset(url: sourceURL)
                let mediaType: AVMediaType = track.kind == .video ? .video : .audio
                guard let sourceTrack = asset.tracks(withMediaType: mediaType).first else {
                    throw MediaAssemblyError.muxingFailed
                }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: sourceTrack, outputSettings: nil)
                guard reader.canAdd(output) else { throw MediaAssemblyError.muxingFailed }
                reader.add(output)
                let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil)
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else { throw MediaAssemblyError.muxingFailed }
                writer.add(input)
                readers.append(reader)
                outputs.append(output)
                inputs.append(input)
            }

            guard writer.startWriting() else { throw MediaAssemblyError.muxingFailed }
            writer.startSession(atSourceTime: .zero)
            let group = DispatchGroup()
            let state = MuxState()

            for index in inputs.indices {
                let input = inputs[index]
                let output = outputs[index]
                let reader = readers[index]
                group.enter()
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "media-mux-\(index)")) {
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        if !input.append(sample) {
                            state.lock.lock()
                            state.appendFailed = true
                            state.lock.unlock()
                            reader.cancelReading()
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.wait()
            state.lock.lock()
            let failed = state.appendFailed
            state.lock.unlock()
            guard !failed,
                  readers.allSatisfy({ $0.status == .completed }) else {
                writer.cancelWriting()
                throw MediaAssemblyError.muxingFailed
            }

            let finishSemaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { finishSemaphore.signal() }
            finishSemaphore.wait()
            guard writer.status == .completed,
                  validateMuxedOutput(temporaryOutput, expectedKinds: request.tracks.map(\.kind)) else {
                throw MediaAssemblyError.muxingFailed
            }
        } catch let error as MediaAssemblyError {
            throw error
        } catch {
            throw MediaAssemblyError.muxingFailed
        }

        do {
            if fileManager.fileExists(atPath: request.destinationURL.path) {
                try fileManager.removeItem(at: request.destinationURL)
            }
            try fileManager.moveItem(at: temporaryOutput, to: request.destinationURL)
            let attributes = try fileManager.attributesOfItem(atPath: request.destinationURL.path)
            guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value, byteCount > 0 else {
                throw MediaAssemblyError.fileOperationFailed
            }
            return MediaAssemblyOutput(
                destinationURL: request.destinationURL,
                container: request.container,
                trackCount: request.tracks.count,
                byteCount: byteCount,
                validation: validation
            )
        } catch let error as MediaAssemblyError {
            throw error
        } catch {
            throw MediaAssemblyError.fileOperationFailed
        }
    }

    private static func validateMuxedOutput(
        _ url: URL,
        expectedKinds: [MediaAssemblyTrackKind]
    ) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size > 0 else { return false }
        let asset = AVURLAsset(url: url)
        guard !asset.tracks.isEmpty else { return false }
        let hasVideo = asset.tracks(withMediaType: .video).isEmpty == false
        let hasAudio = asset.tracks(withMediaType: .audio).isEmpty == false
        if expectedKinds.contains(.video) && !hasVideo { return false }
        if expectedKinds.contains(.audio) && !hasAudio { return false }
        return asset.duration.isNumeric && asset.duration.seconds > 0
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
              let attributes = try? fileManager.attributesOfItem(atPath: segment.fileURL.path),
              let actualSize = (attributes[.size] as? NSNumber)?.int64Value,
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

        guard let input = FileHandle(forReadingAtPath: segment.fileURL.path) else {
            throw MediaAssemblyError.fileOperationFailed
        }
        defer { input.closeFile() }
        while true {
            let chunk = input.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            output.write(chunk)
        }
    }

    private static func validateOutput(_ url: URL, container: MediaAssemblyContainer) -> Bool {
        switch container {
        case .mpegTS:
            return validateMPEGTSFile(url)
        case .fragmentedMP4:
            return validateISOBaseMediaFile(url, requiredBoxes: ["ftyp", "moov", "moof", "mdat"])
        }
    }

    private static func validateMPEGTSFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size > 0,
              size % 188 == 0,
              let handle = FileHandle(forReadingAtPath: url.path) else {
            return false
        }
        defer { handle.closeFile() }
        var remaining = size
        while remaining > 0 {
            let packet = handle.readData(ofLength: 188)
            guard packet.count == 188, packet.first == 0x47 else { return false }
            remaining -= 188
        }
        return true
    }

    private static func validateISOBaseMediaFile(
        _ url: URL,
        requiredBoxes: Set<String>
    ) -> Bool {
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
        return requiredBoxes.isSubset(of: boxes)
    }
}

/// Adapter for callers that use the common media-assembly executor boundary.
public struct FileMediaAssemblyExecutor: MediaAssemblyExecutor, Sendable {
    public init() {}

    public func assemble(_ request: MediaAssemblyRequest) async throws -> MediaAssemblyOutput {
        try MediaAssembler.assemble(request)
    }
}
