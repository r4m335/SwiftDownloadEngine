import Foundation

public enum HLSVODReconstructionFormat: String, Sendable, Equatable {
    case mpegTS
    case fragmentedMP4

    public var mediaAssemblyContainer: MediaAssemblyContainer {
        switch self {
        case .mpegTS: return .mpegTS
        case .fragmentedMP4: return .fragmentedMP4
        }
    }

    public var fileExtension: String {
        switch self {
        case .mpegTS: return "ts"
        case .fragmentedMP4: return "mp4"
        }
    }
}

/// A completed local file paired with the exact planned resource it represents.
/// Remote URLs and request credentials are not stored in this assembly boundary.
public struct HLSCompletedResource: Sendable, Equatable {
    public let resource: HLSPlannedResource
    public let fileURL: URL

    public init(resource: HLSPlannedResource, fileURL: URL) {
        self.resource = resource
        self.fileURL = fileURL
    }
}

public enum HLSVODReconstructionError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedEncryption
    case decryptionFailed(HLSSegmentDecryptionError)
    case resourceCountMismatch
    case resourceOrderMismatch
    case invalidResourceFile
    case invalidResourceSize
    case unsupportedTrackLayout
    case assemblyFailed(MediaAssemblyError)

    public var errorDescription: String? {
        switch self {
        case .unsupportedEncryption:
            return "This HLS VOD uses encryption that the clear-media reconstruction path does not support."
        case .decryptionFailed(let error):
            return "HLS segment decryption failed: \(error.localizedDescription)"
        case .resourceCountMismatch:
            return "The completed HLS resources do not match the planned resource set."
        case .resourceOrderMismatch:
            return "The completed HLS resources are out of order or belong to another plan."
        case .invalidResourceFile:
            return "A completed HLS resource is not a readable local file."
        case .invalidResourceSize:
            return "A completed HLS resource has an unexpected byte count."
        case .unsupportedTrackLayout:
            return "This HLS VOD layout requires separate-track muxing that is not supported yet."
        case .assemblyFailed(let error):
            return error.localizedDescription
        }
    }
}

public struct HLSVODReconstructionPlan: Sendable, Equatable {
    public let format: HLSVODReconstructionFormat
    public let assemblyRequest: MediaAssemblyRequest

    public init(format: HLSVODReconstructionFormat, assemblyRequest: MediaAssemblyRequest) {
        self.format = format
        self.assemblyRequest = assemblyRequest
    }
}

/// Converts one finite, clear HLS media plan and its completed files into a
/// container-aware assembly request. It performs no network work.
public enum HLSVODReconstructionPlanner {
    public static func makePlan(
        from transferPlan: HLSVODTransferPlan,
        completedResources: [HLSCompletedResource],
        destinationURL: URL,
        temporaryDirectoryURL: URL? = nil
    ) throws -> HLSVODReconstructionPlan {
        guard completedResources.count == transferPlan.resources.count else {
            throw HLSVODReconstructionError.resourceCountMismatch
        }

        for (index, completed) in completedResources.enumerated() {
            guard completed.resource == transferPlan.resources[index] else {
                throw HLSVODReconstructionError.resourceOrderMismatch
            }
            guard completed.fileURL.isFileURL,
                  FileManager.default.fileExists(atPath: completed.fileURL.path) else {
                throw HLSVODReconstructionError.invalidResourceFile
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: completed.fileURL.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  size > 0 else {
                throw HLSVODReconstructionError.invalidResourceFile
            }
            if let byteRange = completed.resource.byteRange, size != byteRange.length {
                throw HLSVODReconstructionError.invalidResourceSize
            }
            if let encryption = completed.resource.encryption,
               encryption != .clear {
                throw HLSVODReconstructionError.unsupportedEncryption
            }
            if completed.resource.kind == .encryptionKey {
                throw HLSVODReconstructionError.unsupportedEncryption
            }
        }

        let initialization = completedResources.filter { $0.resource.kind == .initializationMap }
        guard initialization.count <= 1 else {
            throw HLSVODReconstructionError.unsupportedTrackLayout
        }
        let format: HLSVODReconstructionFormat = initialization.isEmpty ? .mpegTS : .fragmentedMP4
        let media = completedResources.filter { $0.resource.kind == .mediaSegment }
        guard !media.isEmpty else { throw HLSVODReconstructionError.resourceCountMismatch }

        let initializationSegment = initialization.first.map {
            MediaAssemblySegment(
                fileURL: $0.fileURL,
                role: .initialization,
                order: 0,
                expectedByteCount: $0.resource.byteRange?.length,
                actualByteCount: fileSize($0.fileURL)
            )
        }
        let mediaSegments = media.enumerated().map { index, completed in
            MediaAssemblySegment(
                fileURL: completed.fileURL,
                role: .media,
                order: index,
                expectedByteCount: completed.resource.byteRange?.length,
                actualByteCount: fileSize(completed.fileURL)
            )
        }
        let track = MediaAssemblyTrack(
            kind: .video,
            container: format.mediaAssemblyContainer,
            initializationSegment: initializationSegment,
            mediaSegments: mediaSegments
        )
        let request = MediaAssemblyRequest(
            container: format.mediaAssemblyContainer,
            tracks: [track],
            destinationURL: destinationURL,
            temporaryDirectoryURL: temporaryDirectoryURL
        )
        return HLSVODReconstructionPlan(format: format, assemblyRequest: request)
    }

    public static func suggestedFilename(for transferPlan: HLSVODTransferPlan) -> String {
        let raw = transferPlan.manifestURL.deletingPathExtension().lastPathComponent
        let stem = raw.isEmpty ? "hls-vod" : raw
        let safe = stem.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        let format: HLSVODReconstructionFormat = transferPlan.resources.contains {
            $0.kind == .initializationMap
        } ? .fragmentedMP4 : .mpegTS
        return "\(String(safe)).\(format.fileExtension)"
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
}

public enum HLSVODReconstructor {
    public static func assemble(
        transferPlan: HLSVODTransferPlan,
        completedResources: [HLSCompletedResource],
        destinationURL: URL,
        temporaryDirectoryURL: URL? = nil
    ) throws -> MediaAssemblyOutput {
        let hasEncryption = transferPlan.resources.contains {
            $0.kind == .encryptionKey || ($0.encryption != nil && $0.encryption != .clear)
        }

        let effectiveTempDir = temporaryDirectoryURL ?? destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".media-assembly",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: effectiveTempDir, withIntermediateDirectories: true)

        let resolvedPlan: HLSVODTransferPlan
        let resolvedCompleted: [HLSCompletedResource]

        if hasEncryption {
            var keyMap: [URL: Data] = [:]
            for completed in completedResources where completed.resource.kind == .encryptionKey {
                guard let keyData = try? Data(contentsOf: completed.fileURL), keyData.count == 16 else {
                    throw HLSVODReconstructionError.decryptionFailed(.missingKeyData(completed.resource.url))
                }
                keyMap[completed.resource.url] = keyData
            }

            var clearResources: [HLSPlannedResource] = []
            var clearCompleted: [HLSCompletedResource] = []

            for completed in completedResources {
                switch completed.resource.kind {
                case .encryptionKey:
                    continue
                case .initializationMap:
                    let clearRes = HLSPlannedResource(
                        order: clearResources.count,
                        kind: completed.resource.kind,
                        url: completed.resource.url,
                        byteRange: completed.resource.byteRange,
                        sequenceNumber: completed.resource.sequenceNumber,
                        duration: completed.resource.duration,
                        encryption: .clear
                    )
                    clearResources.append(clearRes)
                    clearCompleted.append(HLSCompletedResource(resource: clearRes, fileURL: completed.fileURL))
                case .mediaSegment:
                    if case let .aes128(keyURL, explicitIV) = completed.resource.encryption {
                        guard let keyData = keyMap[keyURL] else {
                            throw HLSVODReconstructionError.decryptionFailed(.missingKeyData(keyURL))
                        }
                        let ivData: Data
                        if let explicitIV = explicitIV, let parsed = HLSSegmentDecryptor.parseIV(explicitIV) {
                            ivData = parsed
                        } else {
                            ivData = HLSSegmentDecryptor.ivForSequenceNumber(completed.resource.sequenceNumber ?? 0)
                        }
                        let ext = completed.fileURL.pathExtension.isEmpty ? "ts" : completed.fileURL.pathExtension
                        let decryptedURL = effectiveTempDir.appendingPathComponent("decrypted_seg_\(completed.resource.order).\(ext)")
                        do {
                            try HLSSegmentDecryptor.decryptFile(at: completed.fileURL, to: decryptedURL, key: keyData, iv: ivData)
                        } catch let decErr as HLSSegmentDecryptionError {
                            throw HLSVODReconstructionError.decryptionFailed(decErr)
                        } catch {
                            throw HLSVODReconstructionError.decryptionFailed(.fileWriteError(decryptedURL.path))
                        }
                        let clearRes = HLSPlannedResource(
                            order: clearResources.count,
                            kind: .mediaSegment,
                            url: completed.resource.url,
                            byteRange: nil,
                            sequenceNumber: completed.resource.sequenceNumber,
                            duration: completed.resource.duration,
                            encryption: .clear
                        )
                        clearResources.append(clearRes)
                        clearCompleted.append(HLSCompletedResource(resource: clearRes, fileURL: decryptedURL))
                    } else {
                        let clearRes = HLSPlannedResource(
                            order: clearResources.count,
                            kind: .mediaSegment,
                            url: completed.resource.url,
                            byteRange: completed.resource.byteRange,
                            sequenceNumber: completed.resource.sequenceNumber,
                            duration: completed.resource.duration,
                            encryption: .clear
                        )
                        clearResources.append(clearRes)
                        clearCompleted.append(HLSCompletedResource(resource: clearRes, fileURL: completed.fileURL))
                    }
                }
            }

            resolvedPlan = HLSVODTransferPlan(
                manifestURL: transferPlan.manifestURL,
                resources: clearResources,
                browserRequestContext: transferPlan.browserRequestContext,
                estimatedTransferBytes: transferPlan.estimatedTransferBytes
            )
            resolvedCompleted = clearCompleted
        } else {
            resolvedPlan = transferPlan
            resolvedCompleted = completedResources
        }

        let reconstructionPlan = try HLSVODReconstructionPlanner.makePlan(
            from: resolvedPlan,
            completedResources: resolvedCompleted,
            destinationURL: destinationURL,
            temporaryDirectoryURL: effectiveTempDir
        )
        do {
            return try MediaAssembler.assemble(reconstructionPlan.assemblyRequest)
        } catch let error as MediaAssemblyError {
            throw HLSVODReconstructionError.assemblyFailed(error)
        }
    }
}
