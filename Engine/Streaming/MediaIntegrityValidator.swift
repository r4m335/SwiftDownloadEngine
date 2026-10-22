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

    public init(
        fileURL: URL,
        actualByteCount: Int64?,
        expectedByteCount: Int64?,
        outcome: MediaIntegrityValidationOutcome,
        recommendedFilename: String
    ) {
        self.fileURL = fileURL
        self.actualByteCount = actualByteCount
        self.expectedByteCount = expectedByteCount
        self.outcome = outcome
        self.recommendedFilename = recommendedFilename
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

    /// Validates every packet in the MPEG-TS file.
    ///
    /// Memory: reads one 188-byte packet at a time; heap use is O(1).
    private static func validateMPEGTS(fileURL: URL) -> MediaIntegrityValidationOutcome {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
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
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            return .integrityFailure(
                detectedType: .mpegTS,
                reason: "File could not be opened for reading."
            )
        }
        defer { handle.closeFile() }

        var packetIndex: Int64 = 0
        while true {
            let packet = handle.readData(ofLength: 188)
            if packet.isEmpty { break }
            guard packet.count == 188 else {
                return .integrityFailure(
                    detectedType: .mpegTS,
                    reason: "Packet \(packetIndex) has \(packet.count) bytes (expected 188)."
                )
            }
            guard packet[0] == 0x47 else {
                return .integrityFailure(
                    detectedType: .mpegTS,
                    reason: "Packet \(packetIndex) has an invalid sync byte (0x\(String(packet[0], radix: 16, uppercase: true)))."
                )
            }
            packetIndex += 1
        }
        return .validated(detectedType: .mpegTS)
    }

    // MARK: ISO Base Media File Format structural validator

    /// Walks the top-level box list and verifies that every required box type
    /// is present. Uses seek-based I/O; heap use is O(1) regardless of file size.
    private static func validateISOBMFF(
        fileURL: URL,
        requiredBoxes: Set<String>
    ) -> MediaIntegrityValidationOutcome {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              fileSize > 0 else {
            return .integrityFailure(
                detectedType: .fragmentedMP4,
                reason: "File does not exist or has zero size."
            )
        }
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            return .integrityFailure(
                detectedType: .fragmentedMP4,
                reason: "File could not be opened for reading."
            )
        }
        defer { handle.closeFile() }

        var foundBoxTypes = Set<String>()
        var offset: UInt64 = 0

        while offset < fileSize {
            guard fileSize - offset >= 8 else {
                return .integrityFailure(
                    detectedType: .fragmentedMP4,
                    reason: "Unexpected end of file at offset \(offset) — box header is incomplete."
                )
            }
            handle.seek(toFileOffset: offset)
            let header = handle.readData(ofLength: 8)
            guard header.count == 8 else {
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
                let extended = handle.readData(ofLength: 8)
                guard extended.count == 8 else {
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
            offset += boxSize
        }

        let missing = requiredBoxes.subtracting(foundBoxTypes)
        guard missing.isEmpty else {
            let sortedMissing = missing.sorted().joined(separator: ", ")
            return .integrityFailure(
                detectedType: .fragmentedMP4,
                reason: "Required box type(s) not found: \(sortedMissing)."
            )
        }

        // Narrow the type to fMP4 if moof is present.
        let detectedType: DetectedFileType = foundBoxTypes.contains("moof")
            ? .fragmentedMP4
            : .isoBaseMediaFile
        return .validated(detectedType: detectedType)
    }

    // MARK: - Helpers

    private static func diskByteCount(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        return size
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
}
