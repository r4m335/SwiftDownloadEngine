import Foundation

/// Execution boundary for a future media assembler. Implementations must not
/// download resources or mutate download state; they consume completed local
/// segment files and return a published, validated output.
public protocol MediaAssemblyExecutor: Sendable {
    func assemble(_ request: MediaAssemblyRequest) async throws -> MediaAssemblyOutput
}

/// 7F.4.1 contract validation.
///
/// This method validates the request's declared structure only. It deliberately
/// does not read files, inspect media bytes, create directories, publish output,
/// or select AVFoundation/FFmpeg/a different media-processing strategy. Those
/// concerns belong to the later assembly and output-validation stages.
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
}
