import Foundation

// MARK: - Public surface

/// A file format identified purely from its byte-level signature.
///
/// Values are intentionally exhaustive so callers cannot branch on
/// `unknown` and `unsupported` interchangeably; the two states carry
/// different recovery implications.
public enum DetectedFileType: Equatable, Sendable {
    // ── Video ────────────────────────────────────────────────────────────────
    /// Standard ISO Base Media File Format (MP4, M4V, M4A, …).
    case isoBaseMediaFile
    /// Fragmented MP4 — `ftyp` box present *and* contains `moof` / `mdat`.
    case fragmentedMP4
    /// MPEG-2 Transport Stream (188-byte packets, sync byte 0x47).
    case mpegTS
    /// Matroska / WebM container.
    case matroska
    /// AVI (RIFF-based).
    case avi
    /// MPEG-1 / MPEG-2 program or elementary video stream.
    case mpeg
    /// QuickTime MOV.
    case quickTime
    /// Flash Video.
    case flv
    /// 3GPP / 3GPP2.
    case threeGPP

    // ── Audio ────────────────────────────────────────────────────────────────
    /// MPEG Audio Layer I/II/III (MP3, MP2, MP1) — frame-sync header.
    case mpegAudio
    /// AAC ADTS stream (sync word 0xFFF).
    case aacADTS
    /// FLAC.
    case flac
    /// Ogg container (Ogg Vorbis, Ogg Opus, …).
    case ogg
    /// WAVE PCM audio.
    case wave
    /// AIFF / AIFF-C.
    case aiff

    // ── Images ───────────────────────────────────────────────────────────────
    case png
    case jpeg
    case gif
    case webp
    case bmp
    case heif

    // ── Archives / documents ─────────────────────────────────────────────────
    /// ZIP-compatible (also the envelope for EPUB, DOCX, XLSX, …).
    case zip
    case gzip
    case bzip2
    case sevenZip
    case rar
    case pdf

    // ── Streaming manifests ──────────────────────────────────────────────────
    /// UTF-8 text beginning with `#EXTM3U` — HLS or plain M3U playlist.
    case m3uPlaylist
    /// XML document whose root element refers to an MPEG-DASH MPD namespace.
    case dashManifest

    // ── Sentinels ────────────────────────────────────────────────────────────
    /// The file exists and is non-empty but matches no known signature.
    case unknown
    /// The file is empty (zero bytes).
    case empty
    /// The file could not be read (missing, locked, permission denied).
    case unreadable

    // MARK: Derived properties

    /// True for containers that `MediaAssembler` can validate natively.
    public var isNativelyAssemblable: Bool {
        switch self {
        case .isoBaseMediaFile, .fragmentedMP4, .mpegTS: return true
        default: return false
        }
    }

    /// Broad media category.
    public var mediaClass: MediaClass {
        switch self {
        case .isoBaseMediaFile, .fragmentedMP4, .mpegTS, .matroska, .avi,
             .mpeg, .quickTime, .flv, .threeGPP:
            return .video
        case .mpegAudio, .aacADTS, .flac, .ogg, .wave, .aiff:
            return .audio
        case .png, .jpeg, .gif, .webp, .bmp, .heif:
            return .image
        case .zip, .gzip, .bzip2, .sevenZip, .rar, .pdf:
            return .archiveOrDocument
        case .m3uPlaylist, .dashManifest:
            return .streamingManifest
        case .unknown, .empty, .unreadable:
            return .indeterminate
        }
    }

    /// A safe file extension that reflects the *detected* format.
    /// Returns `nil` for sentinels — callers must not invent an extension.
    public var canonicalExtension: String? {
        switch self {
        case .isoBaseMediaFile: return "mp4"
        case .fragmentedMP4: return "mp4"
        case .mpegTS: return "ts"
        case .matroska: return "mkv"
        case .avi: return "avi"
        case .mpeg: return "mpg"
        case .quickTime: return "mov"
        case .flv: return "flv"
        case .threeGPP: return "3gp"
        case .mpegAudio: return "mp3"
        case .aacADTS: return "aac"
        case .flac: return "flac"
        case .ogg: return "ogg"
        case .wave: return "wav"
        case .aiff: return "aiff"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .gif: return "gif"
        case .webp: return "webp"
        case .bmp: return "bmp"
        case .heif: return "heic"
        case .zip: return "zip"
        case .gzip: return "gz"
        case .bzip2: return "bz2"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        case .pdf: return "pdf"
        case .m3uPlaylist: return "m3u8"
        case .dashManifest: return "mpd"
        case .unknown, .empty, .unreadable: return nil
        }
    }
}

public enum MediaClass: Equatable, Sendable {
    case video
    case audio
    case image
    case archiveOrDocument
    case streamingManifest
    case indeterminate
}

// MARK: - Detector

/// Identifies files from their byte-level signatures only.
///
/// **Design constraints:**
/// - Never reads more than `headerBudget` bytes from any file.
/// - Never modifies files.
/// - Never performs network I/O.
/// - Treats extension and MIME type as untrusted hints (they are not consulted).
public enum FileTypeDetector {

    /// Maximum bytes read during signature analysis.
    /// 512 bytes covers every signature used here with room to spare.
    public static let headerBudget: Int = 512

    // MARK: Primary entry points

    /// Detects the format of the file at `url`.
    ///
    /// For most formats only the first few bytes are read. For fragmented MP4
    /// an additional pass is performed to distinguish it from plain ISOBMFF.
    ///
    /// - Parameter url: A local file URL.
    /// - Returns: The detected type. Never throws.
    public static func detect(at url: URL) -> DetectedFileType {
        guard url.isFileURL else { return .unreadable }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
            return .unreadable
        }
        guard fileSize > 0 else { return .empty }
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return .unreadable }
        defer { handle.closeFile() }
        let readLength = Int(min(Int64(headerBudget), fileSize))
        let header = handle.readData(ofLength: readLength)
        guard !header.isEmpty else { return .unreadable }
        return classify(header: header, fileSize: fileSize)
    }

    /// Detects a format from a pre-read byte sequence.
    ///
    /// Useful in tests where a real file may not be needed.
    /// The caller is responsible for supplying representative leading bytes.
    public static func detect(bytes: Data) -> DetectedFileType {
        guard !bytes.isEmpty else { return .empty }
        return classify(header: bytes, fileSize: Int64(bytes.count))
    }

    // MARK: - Internal classification

    private static func classify(
        header: Data,
        fileSize: Int64
    ) -> DetectedFileType {
        let b = header

        // ── MPEG-TS ─────────────────────────────────────────────────────────
        // 188-byte packets, first byte of each must be 0x47 (sync byte).
        // Check three packets if available; fall back to a single-packet heuristic.
        if b.count >= 376, b[0] == 0x47, b[188] == 0x47, b[376] == 0x47 {
            return .mpegTS
        }
        if b.count >= 188, b[0] == 0x47, fileSize % 188 == 0 {
            return .mpegTS
        }

        // ── ISO Base Media File Format (MP4 family) ──────────────────────────
        if let isoResult = classifyISOBMFF(header: b, fileSize: fileSize) {
            return isoResult
        }

        // ── Matroska / WebM ─────────────────────────────────────────────────
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 {
            return .matroska
        }

        // ── RIFF-based (AVI / WAVE / WebP) ──────────────────────────────────
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 {
            if b[8] == 0x41, b[9] == 0x56, b[10] == 0x49, b[11] == 0x20 { return .avi }
            if b[8] == 0x57, b[9] == 0x41, b[10] == 0x56, b[11] == 0x45 { return .wave }
            if b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return .webp }
        }

        // ── FLV ─────────────────────────────────────────────────────────────
        if b.count >= 3, b[0] == 0x46, b[1] == 0x4C, b[2] == 0x56 { return .flv }

        // ── PNG ─────────────────────────────────────────────────────────────
        if b.count >= 8,
           b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A {
            return .png
        }

        // ── JPEG ─────────────────────────────────────────────────────────────
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }

        // ── GIF ─────────────────────────────────────────────────────────────
        if b.count >= 6,
           b[0] == 0x47, b[1] == 0x49, b[2] == 0x46,
           b[3] == 0x38, (b[4] == 0x37 || b[4] == 0x39), b[5] == 0x61 {
            return .gif
        }

        // ── BMP ─────────────────────────────────────────────────────────────
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return .bmp }

        // ── PDF ─────────────────────────────────────────────────────────────
        if b.count >= 4, b[0] == 0x25, b[1] == 0x50, b[2] == 0x44, b[3] == 0x46 { return .pdf }

        // ── ZIP ─────────────────────────────────────────────────────────────
        if b.count >= 4, b[0] == 0x50, b[1] == 0x4B {
            if (b[2] == 0x03 && b[3] == 0x04) ||
               (b[2] == 0x05 && b[3] == 0x06) ||
               (b[2] == 0x07 && b[3] == 0x08) {
                return .zip
            }
        }

        // ── gzip ─────────────────────────────────────────────────────────────
        if b.count >= 2, b[0] == 0x1F, b[1] == 0x8B { return .gzip }

        // ── bzip2 ────────────────────────────────────────────────────────────
        if b.count >= 3, b[0] == 0x42, b[1] == 0x5A, b[2] == 0x68 { return .bzip2 }

        // ── 7-Zip ────────────────────────────────────────────────────────────
        if b.count >= 6,
           b[0] == 0x37, b[1] == 0x7A, b[2] == 0xBC, b[3] == 0xAF,
           b[4] == 0x27, b[5] == 0x1C {
            return .sevenZip
        }

        // ── RAR ─────────────────────────────────────────────────────────────
        if b.count >= 7,
           b[0] == 0x52, b[1] == 0x61, b[2] == 0x72, b[3] == 0x21,
           b[4] == 0x1A, b[5] == 0x07 {
            return .rar
        }

        // ── FLAC ─────────────────────────────────────────────────────────────
        if b.count >= 4, b[0] == 0x66, b[1] == 0x4C, b[2] == 0x61, b[3] == 0x43 { return .flac }

        // ── Ogg ─────────────────────────────────────────────────────────────
        if b.count >= 4, b[0] == 0x4F, b[1] == 0x67, b[2] == 0x67, b[3] == 0x53 { return .ogg }

        // ── AIFF ─────────────────────────────────────────────────────────────
        if b.count >= 4, b[0] == 0x46, b[1] == 0x4F, b[2] == 0x52, b[3] == 0x4D {
            return .aiff
        }

        // ── AAC ADTS ─────────────────────────────────────────────────────────
        // Sync: 0xFFF, layer bits (10-9) = 00 distinguishes ADTS from MPEG audio.
        if b.count >= 2, b[0] == 0xFF {
            let highNibble = b[1] & 0xF0
            if highNibble == 0xF0 {
                let layer = (b[1] >> 1) & 0x03
                if layer == 0x00 { return .aacADTS }
            }
        }

        // ── MPEG Audio (MP3 / MP2 / MP1) ────────────────────────────────────
        if b.count >= 2, b[0] == 0xFF {
            let syncBits = b[1] & 0xE0
            if syncBits == 0xE0 { return .mpegAudio }
        }

        // ── MPEG PS/ES (video) ────────────────────────────────────────────────
        if b.count >= 4, b[0] == 0x00, b[1] == 0x00, b[2] == 0x01 {
            if b[3] == 0xBA || b[3] == 0xB3 || b[3] == 0xE0 { return .mpeg }
        }

        // ── Text-based signatures ─────────────────────────────────────────────
        if let text = String(data: b, encoding: .utf8) ?? String(data: b, encoding: .isoLatin1) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXTM3U") { return .m3uPlaylist }
            if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<MPD") {
                let lower = trimmed.lowercased()
                if lower.contains("urn:mpeg:dash") ||
                   lower.contains("<mpd ") ||
                   lower.contains("<mpd>") {
                    return .dashManifest
                }
            }
        }

        return .unknown
    }

    // MARK: - ISO Base Media File Format

    /// Parses the leading ISO BMFF boxes to determine whether this is a plain
    /// MP4 / ISOBMFF file, a fragmented MP4, a QuickTime MOV, a 3GPP file, or
    /// a HEIF image.  Returns `nil` when the header does not look like ISOBMFF.
    private static func classifyISOBMFF(
        header: Data,
        fileSize: Int64
    ) -> DetectedFileType? {
        guard header.count >= 8 else { return nil }

        let firstBoxSize = readUInt32BE(header, offset: 0)
        let firstBoxType = readFourCC(header, offset: 4)

        let knownStartBoxes: Set<String> = [
            "ftyp", "moov", "mdat", "free", "skip", "wide", "pnot",
            "uuid", "moof", "sidx", "styp"
        ]
        guard knownStartBoxes.contains(firstBoxType) else { return nil }

        guard firstBoxSize == 0 || firstBoxSize == 1 ||
              (firstBoxSize >= 8 && Int64(firstBoxSize) <= fileSize) else {
            return nil
        }

        // Walk boxes within the header window.
        var foundBoxTypes = Set<String>()
        var ftypBrand: String?
        var offset = 0

        while offset + 8 <= header.count {
            let rawSize = readUInt32BE(header, offset: offset)
            let boxType = readFourCC(header, offset: offset + 4)
            guard !boxType.isEmpty else { break }
            foundBoxTypes.insert(boxType)

            // Record the ftyp brand.
            if boxType == "ftyp", ftypBrand == nil, offset + 12 <= header.count {
                ftypBrand = readFourCC(header, offset: offset + 8)
            }

            let advance: Int
            if rawSize == 1 {
                advance = offset + 16 <= header.count
                    ? Int(min(readUInt64BE(header, offset: offset + 8), UInt64(Int.max)))
                    : header.count
            } else if rawSize == 0 {
                advance = header.count
            } else {
                advance = Int(rawSize)
            }
            guard advance > 0, offset + advance > offset else { break }
            offset += advance
        }

        let isFragmented = foundBoxTypes.contains("moof")

        if let brand = ftypBrand {
            if let result = typeFromFtypBrand(brand, isFragmented: isFragmented) {
                return result
            }
        }

        if isFragmented { return .fragmentedMP4 }
        if foundBoxTypes.contains("moov") { return .isoBaseMediaFile }
        if foundBoxTypes.contains("mdat") { return .isoBaseMediaFile }
        if firstBoxType == "free" || firstBoxType == "skip" ||
           firstBoxType == "wide" || firstBoxType == "pnot" {
            return .quickTime
        }

        return nil
    }

    private static func typeFromFtypBrand(
        _ brand: String,
        isFragmented: Bool
    ) -> DetectedFileType? {
        let trimmed = brand.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "qt":
            return .quickTime
        case "heic", "heis", "hevs", "avif", "avis", "mif1", "msf1":
            return .heif
        case "3gp4", "3gp5", "3gp6", "3gp7", "3g2a", "3g2b", "3g2c":
            return .threeGPP
        case "fmp4":
            return .fragmentedMP4
        default:
            // Generic ISOBMFF brand.
            return isFragmented ? .fragmentedMP4 : .isoBaseMediaFile
        }
    }

    // MARK: - Byte-reading helpers

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var result: UInt64 = 0
        for i in 0..<8 { result = (result << 8) | UInt64(data[offset + i]) }
        return result
    }

    private static func readFourCC(_ data: Data, offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        let bytes = data[offset..<(offset + 4)]
        let allPrintable = bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
        guard allPrintable else { return "" }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

// MARK: - Naming helper

public extension FileTypeDetector {
    /// Returns a corrected filename when the extension on `filename` does not
    /// match the detected type.
    ///
    /// Rules:
    /// - Never renames when `detectedType` is a sentinel (unknown/empty/unreadable).
    /// - Never adds an extension to a basename that has none.
    /// - Only replaces extensions that are clearly wrong (e.g. `.bin` for MP4).
    /// - Returns the original name unchanged when the extension is already
    ///   acceptable for the detected type.
    static func safeFilename(
        original: String,
        detectedType: DetectedFileType
    ) -> String {
        guard let canonical = detectedType.canonicalExtension else {
            return original  // Sentinel — never rename.
        }

        let nsStr = original as NSString
        let existingExt = nsStr.pathExtension.lowercased()
        let stem = nsStr.deletingPathExtension

        guard !existingExt.isEmpty else {
            return original  // No extension — do not invent one.
        }

        if isAcceptableExtension(existingExt, for: detectedType) { return original }

        return "\(stem).\(canonical)"
    }

    private static func isAcceptableExtension(
        _ ext: String,
        for type: DetectedFileType
    ) -> Bool {
        switch type {
        case .isoBaseMediaFile, .fragmentedMP4:
            return ["mp4", "m4v", "m4a", "m4b", "m4p"].contains(ext)
        case .mpegTS:
            return ["ts", "m2ts", "mts"].contains(ext)
        case .matroska:
            return ["mkv", "webm", "mka"].contains(ext)
        case .avi: return ext == "avi"
        case .mpeg: return ["mpg", "mpeg", "m2v", "m1v"].contains(ext)
        case .quickTime: return ["mov", "qt"].contains(ext)
        case .flv: return ext == "flv"
        case .threeGPP: return ["3gp", "3g2"].contains(ext)
        case .mpegAudio: return ["mp3", "mp2", "mp1"].contains(ext)
        case .aacADTS: return ["aac", "adts"].contains(ext)
        case .flac: return ext == "flac"
        case .ogg: return ["ogg", "oga", "ogv", "opus"].contains(ext)
        case .wave: return ["wav", "wave"].contains(ext)
        case .aiff: return ["aiff", "aif"].contains(ext)
        case .png: return ext == "png"
        case .jpeg: return ["jpg", "jpeg", "jpe"].contains(ext)
        case .gif: return ext == "gif"
        case .webp: return ext == "webp"
        case .bmp: return ["bmp", "dib"].contains(ext)
        case .heif: return ["heic", "heif", "avif"].contains(ext)
        case .zip: return ["zip", "jar", "epub", "docx", "xlsx", "pptx"].contains(ext)
        case .gzip: return ["gz", "tgz"].contains(ext)
        case .bzip2: return ["bz2", "tbz", "tbz2"].contains(ext)
        case .sevenZip: return ext == "7z"
        case .rar: return ext == "rar"
        case .pdf: return ext == "pdf"
        case .m3uPlaylist: return ["m3u", "m3u8"].contains(ext)
        case .dashManifest: return ["mpd", "xml"].contains(ext)
        case .unknown, .empty, .unreadable: return true  // Never rename sentinels.
        }
    }
}
