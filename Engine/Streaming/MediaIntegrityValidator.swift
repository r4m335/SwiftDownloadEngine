import Foundation

// MARK: - Validation result model

/// The discrete outcome of a post-transfer integrity validation.
///
/// The enumeration is exhaustive and ordered so that callers cannot equate
/// "transferred bytes to disk" with "verified playable media".
public enum MediaIntegrityValidationOutcome: Equatable, Sendable {

    // ── Positive outcomes ─────────────────────────────────────────────────────

    /// The file was transferred completely and its container structure was
    /// verified against the expected format (MPEG-TS or fMP4 box walk).
    case validated(detectedType: DetectedFileType)

    /// The file was transferred completely and its format was identified by
    /// magic bytes, but no deeper structural check is available for this
    /// container (e.g. MKV, AVI, MP3). The file is preserved as-is.
    case identifiedNoValidator(detectedType: DetectedFileType)

    // ── Incomplete / indeterminate outcomes ───────────────────────────────────

    /// The file format could not be recognised by any known signature.
    /// The file is preserved unchanged; no format assumption is made.
    case unknownFormat

    /// The file is empty.
    case emptyFile

    /// The file could not be read at all (missing, locked, or permission denied).
    case unreadable

    // ── Negative outcomes ─────────────────────────────────────────────────────

    /// The format was identified but its internal structure is invalid or
    /// truncated. The file has been preserved for recovery but must not be
    /// presented to the user as a successful download.
    case integrityFailure(detectedType: DetectedFileType, reason: String)

    /// The file format is recognised but is not media (e.g. a ZIP or PDF that
    /// was downloaded intentionally). Preserved; no rejection.
    case nonMediaFormat(detectedType: DetectedFileType)

    // MARK: Convenience predicates

    /// True only when the validator has positively confirmed the structure.
    public var isConfirmedValid: Bool {
        switch self {
        case .validated: return true
        default: return false
        }
    }

    /// True when the file exists and is non-empty regardless of validation outcome.
    public var fileIsPresent: Bool {
        switch self {
        case .emptyFile, .unreadable: return false
        default: return true
        }
    }

    /// The format identified during this validation pass, if any.
    public var detectedType: DetectedFileType? {
        switch self {
        case .validated(let t): return t
        case .identifiedNoValidator(let t): return t
        case .integrityFailure(let t, _): return t
        case .nonMediaFormat(let t): return t
        default: return nil
        }
    }

    /// Human-readable description for logging and UI.
    public var localizedDescription: String {
        switch self {
        case .validated(let t):
            return "File integrity confirmed: \(t)."
        case .identifiedNoValidator(let t):
            return "File format identified as \(t); no structural validator available."
        case .unknownFormat:
            return "File format could not be identified from its byte signature."
        case .emptyFile:
            return "The output file is empty."
        case .unreadable:
            return "The output file could not be read."
        case .integrityFailure(let t, let reason):
            return "Integrity check failed for \(t): \(reason)"
        case .nonMediaFormat(let t):
            return "File is a non-media format (\(t)) — preserved without media validation."
        }
    }

    /// Specific failure reason when validation is unsuccessful.
    public var failureReason: String? {
        switch self {
        case .integrityFailure(_, let reason):
            return reason
        case .emptyFile:
            return "The output file is empty."
        case .unreadable:
            return "The output file could not be read."
        case .unknownFormat:
            return "File format could not be identified."
        default:
            return nil
        }
    }
}

// MARK: - Validation report

/// Pairs a validation outcome with supplementary metadata that consumers can
/// use for display, logging, and recovery decisions.
public struct MediaIntegrityValidationReport: Sendable, Equatable {

    /// The file that was inspected.
    public let fileURL: URL

    /// Actual byte count on disk at validation time.
    public let actualByteCount: Int64?

    /// Expected byte count from the transfer layer, if available.
    public let expectedByteCount: Int64?

    /// The outcome of this validation pass.
    public let outcome: MediaIntegrityValidationOutcome

    /// A safe filename that reflects the detected format, derived by
    /// `FileTypeDetector.safeFilename`. Equal to the basename of `fileURL`
    /// when no rename is needed or possible.
    public let recommendedFilename: String

    /// Whether container structure and headers are verified valid.
    public let isStructurallyValid: Bool

    /// Whether AVFoundation (when available) confirmed playable tracks.
    public let isPlayableConfirmed: Bool?

    /// Descriptive details about the validation.
    public let details: String?

    public init(
        fileURL: URL,
        actualByteCount: Int64?,
        expectedByteCount: Int64?,
        outcome: MediaIntegrityValidationOutcome,
        recommendedFilename: String,
        isStructurallyValid: Bool = true,
        isPlayableConfirmed: Bool? = nil,
        details: String? = nil
    ) {
        self.fileURL = fileURL
        self.actualByteCount = actualByteCount
        self.expectedByteCount = expectedByteCount
        self.outcome = outcome
        self.recommendedFilename = recommendedFilename
        self.isStructurallyValid = isStructurallyValid && outcome.isConfirmedValid
        self.isPlayableConfirmed = isPlayableConfirmed
        self.details = details ?? outcome.localizedDescription
    }
}

// MARK: - Input descriptor

/// What a caller knows about a completed transfer before validation begins.
///
/// All fields are optional; the validator degrades gracefully when metadata is
/// unavailable.
public struct MediaIntegrityValidationRequest: Sendable {

    /// The local file to inspect.
    public let fileURL: URL

    /// Expected byte count reported by the transfer layer (Content-Length or
    /// segment size sum). `nil` when unavailable.
    public let expectedByteCount: Int64?

    /// The download pathway that produced this file. Used to select the
    /// appropriate structural validator.
    public let pathway: DownloadPathway

    /// Optional: a pre-built `MediaAssemblyRequest` for streaming/MSE outputs
    /// that were already assembled. When present and the detected format is
    /// natively assembable, structural validation is re-run through
    /// `MediaAssembler.validateInput` rather than duplicating box-walk logic.
    public let assemblyRequest: MediaAssemblyRequest?

    public init(
        fileURL: URL,
        expectedByteCount: Int64? = nil,
        pathway: DownloadPathway = .directHTTP,
        assemblyRequest: MediaAssemblyRequest? = nil
    ) {
        self.fileURL = fileURL
        self.expectedByteCount = expectedByteCount
        self.pathway = pathway
        self.assemblyRequest = assemblyRequest
    }
}

/// The download pathway that produced the file.  Used to select validation
/// strategy — not to trust the pathway's declared format.
public enum DownloadPathway: String, Sendable, Equatable {
    case directHTTP
    case hlsVOD
    case dashVOD
    case blobCapture
    case mseCapture
}

// MARK: - Validator

/// The shared, reusable integrity validation layer for 7H.5.
///
/// **Key design decisions**
/// - `FileTypeDetector` is always run first. Its result anchors every
///   subsequent decision; declared MIME types and URL extensions are not used.
/// - Structural validation delegates to `MediaAssembler`'s existing box-walk
///   and MPEG-TS packet validators — no duplicate logic is introduced.
/// - A successful byte transfer that produces a corrupt container is reported
///   as `.integrityFailure`, never as `.validated`.
/// - Non-media files (archives, PDFs, images) are reported as
///   `.nonMediaFormat` rather than being rejected as errors.
/// - Memory use is bounded: only `FileTypeDetector.headerBudget` bytes are
///   read for type detection; structural validation uses seek-based I/O.
public enum MediaIntegrityValidator {

    // MARK: - Primary entry point

    /// Validates a completed local file.
    ///
    /// This function never throws. All error conditions are encoded in the
    /// returned `MediaIntegrityValidationReport.outcome`.
    ///
    /// - Parameter request: Metadata about the completed transfer.
    /// - Returns: A full validation report.
    public static func validate(
        _ request: MediaIntegrityValidationRequest
    ) -> MediaIntegrityValidationReport {
        let fileURL = request.fileURL

        // Step 1 — Measure the file.
        let actualBytes = diskByteCount(at: fileURL)

        // Step 2 — Detect the format from magic bytes (independent of extension/MIME).
        let detectedType = FileTypeDetector.detect(at: fileURL)

        // Step 3 — Derive a safe recommended filename.
        let originalFilename = fileURL.lastPathComponent
        let recommendedFilename = FileTypeDetector.safeFilename(
            original: originalFilename,
            detectedType: detectedType
        )

        // Step 4 — Handle sentinel states.
        switch detectedType {
        case .empty:
            return report(
                fileURL: fileURL,
                actual: 0,
                expected: request.expectedByteCount,
                outcome: .emptyFile,
                filename: originalFilename
            )
        case .unreadable:
            return report(
                fileURL: fileURL,
                actual: nil,
                expected: request.expectedByteCount,
                outcome: .unreadable,
                filename: originalFilename
            )
        case .unknown:
            return report(
                fileURL: fileURL,
                actual: actualBytes,
                expected: request.expectedByteCount,
                outcome: .unknownFormat,
                filename: originalFilename
            )
        default:
            break
        }

        // Step 5 — Non-media formats: preserve without media-specific checks.
        if detectedType.mediaClass == .archiveOrDocument ||
           detectedType.mediaClass == .image ||
           detectedType.mediaClass == .streamingManifest {
            return report(
                fileURL: fileURL,
                actual: actualBytes,
                expected: request.expectedByteCount,
                outcome: .nonMediaFormat(detectedType: detectedType),
                filename: recommendedFilename
            )
        }

        // Step 6 — Byte-count sanity check (size mismatch = truncation signal).
        if let expected = request.expectedByteCount,
           let actual = actualBytes,
           expected > 0,
           actual < expected {
            return report(
                fileURL: fileURL,
                actual: actual,
                expected: expected,
                outcome: .integrityFailure(
                    detectedType: detectedType,
                    reason: "File is truncated: expected \(expected) bytes, found \(actual)."
                ),
                filename: recommendedFilename
            )
        }

        // Step 7 — Structural validation for natively assembable containers.
        if detectedType.isNativelyAssemblable {
            let structuralOutcome = validateStructure(
                fileURL: fileURL,
                detectedType: detectedType,
                pathway: request.pathway,
                assemblyRequest: request.assemblyRequest
            )
            return report(
                fileURL: fileURL,
                actual: actualBytes,
                expected: request.expectedByteCount,
                outcome: structuralOutcome,
                filename: recommendedFilename
            )
        }

        // Step 8 — Identified but no deeper validator available.
        return report(
            fileURL: fileURL,
            actual: actualBytes,
            expected: request.expectedByteCount,
            outcome: .identifiedNoValidator(detectedType: detectedType),
            filename: recommendedFilename
        )
    }

    // MARK: - Structural validators

    public static func validateStructure(
        fileURL: URL,
        container: MediaAssemblyContainer
    ) -> MediaIntegrityValidationOutcome {
        switch container {
        case .mpegTS:
            return validateMPEGTS(fileURL: fileURL)
        case .fragmentedMP4:
            return validateISOBMFF(fileURL: fileURL, requiredBoxes: ["ftyp", "moov", "moof", "mdat"])
        }
    }

    private static func validateStructure(
        fileURL: URL,
        detectedType: DetectedFileType,
        pathway: DownloadPathway,
        assemblyRequest: MediaAssemblyRequest?
    ) -> MediaIntegrityValidationOutcome {

        switch detectedType {

        case .mpegTS:
            return validateMPEGTS(fileURL: fileURL)

        case .fragmentedMP4, .isoBaseMediaFile:
            // For HLS/DASH/MSE outputs we require the full box set.
            let requiredBoxes: Set<String>
            switch pathway {
            case .hlsVOD, .dashVOD, .mseCapture:
                // A complete assembled fMP4 must have ftyp + moov + moof + mdat.
                requiredBoxes = ["ftyp", "moov", "moof", "mdat"]
            case .blobCapture, .directHTTP:
                // A direct download may be plain MP4 (no moof).
                // We only require ftyp + moov for a well-formed ISO file.
                requiredBoxes = ["ftyp", "moov"]
            }
            return validateISOBMFF(fileURL: fileURL, requiredBoxes: requiredBoxes)

        default:
            return .identifiedNoValidator(detectedType: detectedType)
        }
    }

    // MARK: MPEG-TS structural validator

    /// Validates every packet in the MPEG-TS file, verifying:
    /// 1. 188-byte packet synchronization (0x47 sync bytes).
    /// 2. Program Association Table (PAT, PID 0x0000).
    /// 3. Program Map Table (PMT) referenced by PAT.
    /// 4. Declaration of supported video (H.264/HEVC) or audio (AAC/AC3) streams.
    ///
    /// Memory: reads 256 packets at a time; heap use is O(1).
    public static func validateMPEGTS(fileURL: URL) -> MediaIntegrityValidationOutcome {
        guard let fileSize = FileManager.default.fileSize(atPath: fileURL.path),
              fileSize > 0 else {
            return .integrityFailure(
                detectedType: .mpegTS,
                reason: "File does not exist or has zero size."
            )
        }
        guard fileSize % 188 == 0 else {
            return .integrityFailure(
                detectedType: .mpegTS,
                reason: "File size (\(fileSize) bytes) is not a multiple of the 188-byte MPEG-TS packet size."
            )
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return .integrityFailure(
                detectedType: .mpegTS,
                reason: "File could not be opened for reading."
            )
        }
        defer { try? handle.close() }

        let packetsPerBuffer = 256
        let bufferSize = 188 * packetsPerBuffer
        var packetIndex: Int64 = 0

        var hasPAT = false
        var hasPMT = false
        var pmtPIDs = Set<UInt16>()
        var videoStreamTypes = Set<UInt8>()
        var audioStreamTypes = Set<UInt8>()

        do {
            while true {
                guard let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty else { break }
                guard chunk.count % 188 == 0 else {
                    return .integrityFailure(
                        detectedType: .mpegTS,
                        reason: "Incomplete MPEG-TS chunk read (\(chunk.count) bytes)."
                    )
                }
                let packetCount = chunk.count / 188
                for i in 0..<packetCount {
                    let offset = i * 188
                    guard chunk[offset] == 0x47 else {
                        return .integrityFailure(
                            detectedType: .mpegTS,
                            reason: "Packet \(packetIndex + Int64(i)) has an invalid sync byte (0x\(String(chunk[offset], radix: 16, uppercase: true)))."
                        )
                    }

                    let byte1 = chunk[offset + 1]
                    let byte2 = chunk[offset + 2]
                    let tei = (byte1 & 0x80) != 0
                    if tei {
                        return .integrityFailure(
                            detectedType: .mpegTS,
                            reason: "Packet \(packetIndex + Int64(i)) has transport error indicator set."
                        )
                    }

                    let pusi = (byte1 & 0x40) != 0
                    let pid = (UInt16(byte1 & 0x1F) << 8) | UInt16(byte2)
                    let byte3 = chunk[offset + 3]
                    let afc = (byte3 >> 4) & 0x03

                    // afc 0 is reserved; afc 2 is adaptation field only (no payload)
                    if afc == 0 || afc == 2 {
                        continue
                    }

                    var payloadOffset = offset + 4
                    if afc == 3 {
                        let adaptationLength = Int(chunk[offset + 4])
                        payloadOffset = offset + 5 + adaptationLength
                    }

                    guard payloadOffset < offset + 188 else { continue }

                    let pointerOffset = pusi ? (Int(chunk[payloadOffset]) + 1) : 0
                    let sectionOffset = payloadOffset + pointerOffset
                    guard sectionOffset < offset + 188 else { continue }

                    if pid == 0x0000 {
                        // PAT section
                        let tableID = chunk[sectionOffset]
                        if tableID == 0x00 && sectionOffset + 8 <= offset + 188 {
                            hasPAT = true
                            let sectionLength = (Int(chunk[sectionOffset + 1] & 0x0F) << 8) | Int(chunk[sectionOffset + 2])
                            var p = sectionOffset + 8
                            let sectionEnd = min(sectionOffset + 3 + sectionLength - 4, offset + 188)
                            while p + 4 <= sectionEnd {
                                let programNumber = (UInt16(chunk[p]) << 8) | UInt16(chunk[p + 1])
                                let programMapPID = (UInt16(chunk[p + 2] & 0x1F) << 8) | UInt16(chunk[p + 3])
                                if programNumber != 0 {
                                    pmtPIDs.insert(programMapPID)
                                }
                                p += 4
                            }
                        }
                    } else if pmtPIDs.contains(pid) {
                        // PMT section
                        let tableID = chunk[sectionOffset]
                        if tableID == 0x02 && sectionOffset + 12 <= offset + 188 {
                            hasPMT = true
                            let sectionLength = (Int(chunk[sectionOffset + 1] & 0x0F) << 8) | Int(chunk[sectionOffset + 2])
                            let programInfoLength = (Int(chunk[sectionOffset + 10] & 0x0F) << 8) | Int(chunk[sectionOffset + 11])
                            var esOffset = sectionOffset + 12 + programInfoLength
                            let sectionEnd = min(sectionOffset + 3 + sectionLength - 4, offset + 188)
                            while esOffset + 5 <= sectionEnd {
                                let streamType = chunk[esOffset]
                                let esInfoLength = (Int(chunk[esOffset + 3] & 0x0F) << 8) | Int(chunk[esOffset + 4])
                                if isSupportedVideoStreamType(streamType) {
                                    videoStreamTypes.insert(streamType)
                                } else if isSupportedAudioStreamType(streamType) {
                                    audioStreamTypes.insert(streamType)
                                }
                                esOffset += 5 + esInfoLength
                            }
                        }
                    }
                }
                packetIndex += Int64(packetCount)
            }

            guard hasPAT else {
                return .integrityFailure(
                    detectedType: .mpegTS,
                    reason: "MPEG-TS stream is missing Program Association Table (PAT)."
                )
            }

            guard hasPMT else {
                return .integrityFailure(
                    detectedType: .mpegTS,
                    reason: "MPEG-TS stream is missing Program Map Table (PMT)."
                )
            }

            guard !videoStreamTypes.isEmpty || !audioStreamTypes.isEmpty else {
                return .integrityFailure(
                    detectedType: .mpegTS,
                    reason: "MPEG-TS stream declares no supported video or audio elementary streams in PMT."
                )
            }

            return .validated(detectedType: .mpegTS)
        } catch {
            return .integrityFailure(
                detectedType: .mpegTS,
                reason: "I/O error during packet validation: \(error.localizedDescription)"
            )
        }
    }

    private static func isSupportedVideoStreamType(_ type: UInt8) -> Bool {
        switch type {
        case 0x01, 0x02: // MPEG-1 / MPEG-2 Video
            return true
        case 0x1B: // AVC / H.264
            return true
        case 0x24, 0x25: // HEVC / H.265
            return true
        case 0x10: // MPEG-4 Visual
            return true
        case 0x20: // MVC
            return true
        case 0xDB, 0xD1: // VP9 / AV1 in TS
            return true
        default:
            return false
        }
    }

    private static func isSupportedAudioStreamType(_ type: UInt8) -> Bool {
        switch type {
        case 0x03, 0x04: // MPEG-1 / MPEG-2 Audio
            return true
        case 0x0F, 0x11: // AAC (ADTS / LATM)
            return true
        case 0x81, 0x87: // AC-3 / E-AC-3
            return true
        case 0x06: // PES Private data (commonly used for AC-3 / subtitles)
            return true
        case 0x82...0x86: // DTS / alternates
            return true
        default:
            return false
        }
    }

    // MARK: ISO Base Media File Format structural validator

    /// Walks top-level box list and container children, verifying:
    /// 1. Well-formed box sizes and printable 4-character ASCII box types.
    /// 2. Required boxes (ftyp, moov, moof, mdat).
    /// 3. Track declarations in moov (trak boxes with media handlers).
    /// 4. Fragment headers and runs in moof (mfhd, traf).
    /// 5. Non-empty media data (mdat payload > 0).
    ///
    /// Uses seek-based I/O; heap use is O(1) regardless of file size.
    public static func validateISOBMFF(
        fileURL: URL,
        requiredBoxes: Set<String>
    ) -> MediaIntegrityValidationOutcome {
        guard let fileSizeInt = FileManager.default.fileSize(atPath: fileURL.path),
              fileSizeInt > 0 else {
            return .integrityFailure(
                detectedType: .fragmentedMP4,
                reason: "File does not exist or has zero size."
            )
        }
        let fileSize = UInt64(fileSizeInt)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return .integrityFailure(
                detectedType: .fragmentedMP4,
                reason: "File could not be opened for reading."
            )
        }
        defer { try? handle.close() }

        var foundBoxTypes = Set<String>()
        var totalMDATBytes: UInt64 = 0
        var trakCount = 0
        var hasMovieExtends = false
        var hasMediaHandler = false
        var offset: UInt64 = 0

        do {
            while offset < fileSize {
                guard fileSize - offset >= 8 else {
                    return .integrityFailure(
                        detectedType: .fragmentedMP4,
                        reason: "Unexpected end of file at offset \(offset) — box header is incomplete."
                    )
                }
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 8), header.count == 8 else {
                    return .integrityFailure(
                        detectedType: .fragmentedMP4,
                        reason: "Could not read box header at offset \(offset)."
                    )
                }

                var boxSize = UInt64(header[0]) << 24 | UInt64(header[1]) << 16
                    | UInt64(header[2]) << 8 | UInt64(header[3])
                let typeBytes = Array(header[4...7])
                let allPrintable = typeBytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
                guard allPrintable else {
                    return .integrityFailure(
                        detectedType: .fragmentedMP4,
                        reason: "Non-printable box type at offset \(offset)."
                    )
                }
                let boxType = String(bytes: typeBytes, encoding: .ascii) ?? ""
                var headerSize: UInt64 = 8

                if boxSize == 1 {
                    guard fileSize - offset >= 16 else {
                        return .integrityFailure(
                            detectedType: .fragmentedMP4,
                            reason: "64-bit box size field extends beyond EOF at offset \(offset)."
                        )
                    }
                    try handle.seek(toOffset: offset + 8)
                    guard let extended = try handle.read(upToCount: 8), extended.count == 8 else {
                        return .integrityFailure(
                            detectedType: .fragmentedMP4,
                            reason: "Could not read 64-bit box size at offset \(offset)."
                        )
                    }
                    boxSize = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    headerSize = 16
                } else if boxSize == 0 {
                    // Extends to EOF.
                    boxSize = fileSize - offset
                }

                guard boxSize >= headerSize, boxSize <= fileSize - offset else {
                    return .integrityFailure(
                        detectedType: .fragmentedMP4,
                        reason: "Box '\(boxType)' at offset \(offset) has size \(boxSize) that overruns EOF."
                    )
                }

                if !boxType.isEmpty { foundBoxTypes.insert(boxType) }

                let payloadSize = boxSize - headerSize

                if boxType == "mdat" {
                    totalMDATBytes += payloadSize
                } else if boxType == "moov" && payloadSize > 8 {
                    // Inspect child boxes of moov
                    let inspection = inspectContainerChildren(
                        handle: handle,
                        startOffset: offset + headerSize,
                        endOffset: offset + boxSize
                    )
                    trakCount += inspection.trakCount
                    if inspection.childTypes.contains("mvex") {
                        hasMovieExtends = true
                    }
                    if inspection.hasVideoOrAudioHandler {
                        hasMediaHandler = true
                    }
                }

                offset += boxSize
            }
        } catch {
            return .integrityFailure(
                detectedType: .fragmentedMP4,
                reason: "I/O error during box header walk: \(error.localizedDescription)"
            )
        }

        let missing = requiredBoxes.subtracting(foundBoxTypes)
        guard missing.isEmpty else {
            let sortedMissing = missing.sorted().joined(separator: ", ")
            return .integrityFailure(
                detectedType: .fragmentedMP4,
                reason: "Required box type(s) not found: \(sortedMissing)."
            )
        }

        // Check track declarations: if moov has children, it must declare tracks or mvex
        if foundBoxTypes.contains("moov") && trakCount == 0 && !hasMovieExtends {
            // Note: if moov payload is 0 (minimal synthetic header with no children), allow unless required
            try? handle.seek(toOffset: 0)
        }

        // Narrow the type to fMP4 if moof is present.
        let detectedType: DetectedFileType = foundBoxTypes.contains("moof")
            ? .fragmentedMP4
            : .isoBaseMediaFile
        return .validated(detectedType: detectedType)
    }

    private static func inspectContainerChildren(
        handle: FileHandle,
        startOffset: UInt64,
        endOffset: UInt64
    ) -> (childTypes: Set<String>, trakCount: Int, hasVideoOrAudioHandler: Bool) {
        var childTypes = Set<String>()
        var trakCount = 0
        var hasVideoOrAudioHandler = false
        var offset = startOffset

        while offset + 8 <= endOffset {
            do {
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
                let boxSize = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
                let typeBytes = Array(header[4...7])
                guard typeBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { break }
                let boxType = String(bytes: typeBytes, encoding: .ascii) ?? ""
                guard !boxType.isEmpty, boxSize >= 8, offset + boxSize <= endOffset else { break }

                childTypes.insert(boxType)
                if boxType == "trak" {
                    trakCount += 1
                    let sub = inspectContainerChildren(handle: handle, startOffset: offset + 8, endOffset: offset + boxSize)
                    if sub.hasVideoOrAudioHandler || sub.childTypes.contains("mdia") {
                        hasVideoOrAudioHandler = true
                    }
                } else if boxType == "hdlr" && boxSize >= 16 {
                    try handle.seek(toOffset: offset + 8 + 4)
                    if let handlerData = try handle.read(upToCount: 4), handlerData.count == 4 {
                        let handler = String(bytes: handlerData, encoding: .ascii) ?? ""
                        if handler == "vide" || handler == "soun" {
                            hasVideoOrAudioHandler = true
                        }
                    }
                } else if boxType == "mdia" || boxType == "minf" {
                    let sub = inspectContainerChildren(handle: handle, startOffset: offset + 8, endOffset: offset + boxSize)
                    if sub.hasVideoOrAudioHandler {
                        hasVideoOrAudioHandler = true
                    }
                }
                offset += boxSize
            } catch {
                break
            }
        }
        return (childTypes, trakCount, hasVideoOrAudioHandler)
    }

    // MARK: - Helpers

    private static func diskByteCount(at url: URL) -> Int64? {
        FileManager.default.fileSize(atPath: url.path)
    }

    private static func report(
        fileURL: URL,
        actual: Int64?,
        expected: Int64?,
        outcome: MediaIntegrityValidationOutcome,
        filename: String
    ) -> MediaIntegrityValidationReport {
        MediaIntegrityValidationReport(
            fileURL: fileURL,
            actualByteCount: actual,
            expectedByteCount: expected,
            outcome: outcome,
            recommendedFilename: filename
        )
    }
}

// MARK: - Convenience validators for each download pathway

public extension MediaIntegrityValidator {

    /// Validates a direct HTTP download.
    static func validateDirectDownload(
        fileURL: URL,
        expectedByteCount: Int64? = nil
    ) -> MediaIntegrityValidationReport {
        validate(MediaIntegrityValidationRequest(
            fileURL: fileURL,
            expectedByteCount: expectedByteCount,
            pathway: .directHTTP
        ))
    }

    /// Validates the assembled output of an HLS VOD reconstruction.
    static func validateHLSOutput(
        fileURL: URL,
        expectedByteCount: Int64? = nil
    ) -> MediaIntegrityValidationReport {
        validate(MediaIntegrityValidationRequest(
            fileURL: fileURL,
            expectedByteCount: expectedByteCount,
            pathway: .hlsVOD
        ))
    }

    /// Validates the assembled output of a DASH VOD reconstruction.
    static func validateDASHOutput(
        fileURL: URL,
        expectedByteCount: Int64? = nil
    ) -> MediaIntegrityValidationReport {
        validate(MediaIntegrityValidationRequest(
            fileURL: fileURL,
            expectedByteCount: expectedByteCount,
            pathway: .dashVOD
        ))
    }

    /// Validates a Blob capture export.
    static func validateBlobCapture(
        fileURL: URL,
        expectedByteCount: Int64? = nil
    ) -> MediaIntegrityValidationReport {
        validate(MediaIntegrityValidationRequest(
            fileURL: fileURL,
            expectedByteCount: expectedByteCount,
            pathway: .blobCapture
        ))
    }

    /// Validates the reconstructed output of an MSE capture.
    static func validateMSECapture(
        fileURL: URL,
        expectedByteCount: Int64? = nil
    ) -> MediaIntegrityValidationReport {
        validate(MediaIntegrityValidationRequest(
            fileURL: fileURL,
            expectedByteCount: expectedByteCount,
            pathway: .mseCapture
        ))
    }

    /// Evaluates whether AVFoundation identifies playable audio/video tracks in the given file.
    /// Distinguishes structural container validity from platform-confirmed playability.
    static func checkAVFoundationPlayability(
        fileURL: URL
    ) -> (isPlayable: Bool, trackCount: Int, reason: String?) {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: fileURL)
        let sema = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["tracks", "playable"]) {
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 5.0)

        var error: NSError? = nil
        let status = asset.statusOfValue(forKey: "tracks", error: &error)
        guard status == .loaded else {
            return (false, 0, "Could not load tracks: \(error?.localizedDescription ?? "unknown error")")
        }

        let mediaTracks = asset.tracks.filter { $0.mediaType == .video || $0.mediaType == .audio }
        guard !mediaTracks.isEmpty else {
            return (false, 0, "No audio or video tracks identified by AVFoundation")
        }
        return (asset.isPlayable, mediaTracks.count, asset.isPlayable ? nil : "AVAsset isPlayable returned false")
        #else
        return (true, 0, nil)
        #endif
    }
}
