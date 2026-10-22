import Foundation

public enum DASHVODReconstructionError: Error, LocalizedError, Sendable, Equatable {
    case resourceCountMismatch
    case resourceOrderMismatch
    case invalidResourceFile
    case invalidResourceSize
    case missingInitialization
    case noMediaSegments
    case unsupportedEncryption
    case unsupportedTrackLayout
    case assemblyFailed(MediaAssemblyError)

    public var errorDescription: String? {
        switch self {
        case .resourceCountMismatch:
            return "The completed DASH resources do not match the planned resource set."
        case .resourceOrderMismatch:
            return "The completed DASH resources are out of order or belong to another plan."
        case .invalidResourceFile:
            return "A completed DASH resource is not a readable local file."
        case .invalidResourceSize:
            return "A completed DASH resource has an unexpected byte count."
        case .missingInitialization:
            return "A DASH representation is missing its initialization segment."
        case .noMediaSegments:
            return "A DASH representation contains no media segments."
        case .unsupportedEncryption:
            return "This DASH reconstruction path supports clear media only."
        case .unsupportedTrackLayout:
            return "The DASH track layout cannot be represented by the available media muxer."
        case .assemblyFailed(let error):
            return error.localizedDescription
        }
    }
}

/// A completed local file paired with the exact planned DASH resource it
/// represents. Browser credentials and remote URLs remain outside this model.
public struct DASHCompletedResource: Sendable, Equatable {
    public let resource: DASHPlannedResource
    public let fileURL: URL

    public init(resource: DASHPlannedResource, fileURL: URL) {
        self.resource = resource
        self.fileURL = fileURL
    }
}

public struct DASHVODReconstructionPlan: Sendable, Equatable {
    public let assemblyRequest: MediaAssemblyRequest

    public init(assemblyRequest: MediaAssemblyRequest) {
        self.assemblyRequest = assemblyRequest
    }
}

/// Converts completed resources from a finite DASH transfer plan into a
/// container-aware assembly request. No network or download-state work occurs.
public enum DASHVODReconstructionPlanner {
    public static func makePlan(
        from transferPlan: DASHVODTransferPlan,
        completedResources: [DASHCompletedResource],
        destinationURL: URL,
        temporaryDirectoryURL: URL? = nil
    ) throws -> DASHVODReconstructionPlan {
        let plannedResources = transferPlan.resources
        guard !plannedResources.isEmpty,
              completedResources.count == plannedResources.count else {
            throw DASHVODReconstructionError.resourceCountMismatch
        }

        for (index, completed) in completedResources.enumerated() {
            guard completed.resource == plannedResources[index] else {
                throw DASHVODReconstructionError.resourceOrderMismatch
            }
            guard completed.fileURL.isFileURL,
                  FileManager.default.fileExists(atPath: completed.fileURL.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: completed.fileURL.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  size > 0 else {
                throw DASHVODReconstructionError.invalidResourceFile
            }
            if let range = completed.resource.byteRange, size != range.length {
                throw DASHVODReconstructionError.invalidResourceSize
            }
        }

        var tracks: [MediaAssemblyTrack] = []
        if let video = transferPlan.video {
            tracks.append(try makeTrack(
                from: video,
                mediaKind: .video,
                completedResources: completedResources
            ))
        }
        if let audio = transferPlan.audio {
            tracks.append(try makeTrack(
                from: audio,
                mediaKind: .audio,
                completedResources: completedResources
            ))
        }
        guard !tracks.isEmpty else {
            throw DASHVODReconstructionError.unsupportedTrackLayout
        }

        let request = MediaAssemblyRequest(
            container: .fragmentedMP4,
            tracks: tracks,
            destinationURL: destinationURL,
            temporaryDirectoryURL: temporaryDirectoryURL
        )
        return DASHVODReconstructionPlan(assemblyRequest: request)
    }

    public static func suggestedFilename(for transferPlan: DASHVODTransferPlan) -> String {
        let raw = transferPlan.manifestURL.deletingPathExtension().lastPathComponent
        let stem = raw.isEmpty ? "dash-vod" : raw
        let safe = stem.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        return "\(String(safe)).mp4"
    }

    private static func makeTrack(
        from representation: DASHRepresentationTransferPlan,
        mediaKind: DASHMediaType,
        completedResources: [DASHCompletedResource]
    ) throws -> MediaAssemblyTrack {
        let completed = completedResources.filter { $0.resource.mediaType == mediaKind }
        guard completed.count == representation.resources.count else {
            throw DASHVODReconstructionError.resourceCountMismatch
        }
        for (index, item) in completed.enumerated() {
            guard item.resource == representation.resources[index] else {
                throw DASHVODReconstructionError.resourceOrderMismatch
            }
        }

        let initialization = completed.filter { $0.resource.kind == .initialization }
        guard initialization.count == 1 else {
            throw DASHVODReconstructionError.missingInitialization
        }
        let media = completed.filter { $0.resource.kind == .mediaSegment }
        guard !media.isEmpty else {
            throw DASHVODReconstructionError.noMediaSegments
        }

        let kind: MediaAssemblyTrackKind = mediaKind == .video ? .video : .audio
        let timescale = representation.resources.first?.timescale
        let metadata = MediaAssemblyTrackMetadata(
            codec: representation.codecs,
            timescale: timescale,
            duration: representation.estimatedDurationSeconds
        )
        let initializationSegment = initialization.map {
            MediaAssemblySegment(
                fileURL: $0.fileURL,
                role: .initialization,
                order: 0,
                expectedByteCount: $0.resource.byteRange?.length,
                actualByteCount: fileSize($0.fileURL)
            )
        }
        let mediaSegments = media.enumerated().map { index, item in
            MediaAssemblySegment(
                fileURL: item.fileURL,
                role: .media,
                order: index,
                expectedByteCount: item.resource.byteRange?.length,
                actualByteCount: fileSize(item.fileURL)
            )
        }
        return MediaAssemblyTrack(
            kind: kind,
            container: .fragmentedMP4,
            metadata: metadata,
            initializationSegment: initializationSegment,
            mediaSegments: mediaSegments
        )
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
}

public enum DASHVODReconstructor {
    public static func assemble(
        transferPlan: DASHVODTransferPlan,
        completedResources: [DASHCompletedResource],
        destinationURL: URL,
        temporaryDirectoryURL: URL? = nil
    ) throws -> MediaAssemblyOutput {
        let reconstructionPlan = try DASHVODReconstructionPlanner.makePlan(
            from: transferPlan,
            completedResources: completedResources,
            destinationURL: destinationURL,
            temporaryDirectoryURL: temporaryDirectoryURL
        )
        do {
            return try MediaAssembler.assemble(reconstructionPlan.assemblyRequest)
        } catch let error as MediaAssemblyError {
            throw DASHVODReconstructionError.assemblyFailed(error)
        }
    }
}
