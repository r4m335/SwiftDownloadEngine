import Foundation

/// Utility helper for safely separating, editing, sanitizing, and recombining
/// base filenames and file extensions across HTTP, streaming, and BitTorrent downloads.
public struct FilenameExtensionHelper: Sendable {

    /// Characters prohibited across modern filesystem paths (POSIX / NTFS / APFS).
    public static let invalidCharacters = CharacterSet(charactersIn: #"/\\:*?"<>|"#)
        .union(.controlCharacters)
        .union(.newlines)

    /// Known container extensions permitted for HLS / DASH reconstructed media outputs.
    public static let validStreamingContainers: Set<String> = [
        "mp4", "m4v", "m4a", "mov", "ts"
    ]

    /// Splits a filename or path into a base stem and an extension.
    ///
    /// Examples:
    /// - `"My Video.mp4"` -> `("My Video", "mp4")`
    /// - `"archive.tar.gz"` -> `("archive.tar", "gz")`
    /// - `"readme"` -> `("readme", "")`
    /// - `".gitignore"` -> `("", "gitignore")`
    /// - `""` -> `("", "")`
    public static func split(filename: String) -> (base: String, ext: String) {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }

        let ns = trimmed as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension

        if ext.isEmpty {
            return (trimmed, "")
        }
        return (base, ext)
    }

    /// Combines a base filename and extension, preventing duplicate extensions
    /// and sanitizing invalid characters.
    ///
    /// Examples:
    /// - `base: "My Video.mp4", ext: "mp4"` -> `"My Video.mp4"` (not `.mp4.mp4`)
    /// - `base: "file:name?", ext: "zip"` -> `"filename.zip"`
    /// - `base: "file", ext: ".mp4"` -> `"file.mp4"`
    public static func combine(base: String, ext: String) -> String {
        let cleanExt = ext.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .components(separatedBy: invalidCharacters).joined()

        var cleanBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalidCharacters).joined()

        // Prevent duplicate extension if user typed "video.mp4" into base and ext is "mp4"
        if !cleanExt.isEmpty {
            let lowerExt = cleanExt.lowercased()
            let suffixWithDot = "." + lowerExt
            if cleanBase.lowercased().hasSuffix(suffixWithDot) {
                cleanBase = String(cleanBase.dropLast(suffixWithDot.count))
            }
        }

        if cleanBase.isEmpty && cleanExt.isEmpty {
            return "download"
        }
        if cleanExt.isEmpty {
            return cleanBase
        }
        if cleanBase.isEmpty {
            return "download." + cleanExt
        }
        return "\(cleanBase).\(cleanExt)"
    }

    /// Sanitizes an arbitrary user-supplied string for safe use as a file or folder name.
    public static func sanitizeFilename(_ filename: String) -> String {
        let cleaned = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalidCharacters).joined()
        return cleaned.isEmpty ? "download" : cleaned
    }

    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "ts"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"]
    private static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "txt", "rtf"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz"]

    /// Validates whether an extension change is compatible with the underlying transfer container.
    public static func isCompatibleExtensionChange(
        originalExtension: String,
        newExtension: String,
        isStreamingReconstruction: Bool = false
    ) -> Bool {
        let orig = originalExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let newExt = newExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()

        if orig == newExt || newExt.isEmpty { return true }

        if isStreamingReconstruction {
            return validStreamingContainers.contains(newExt)
        }

        if videoExtensions.contains(orig) {
            return videoExtensions.contains(newExt)
        }
        if audioExtensions.contains(orig) {
            return audioExtensions.contains(newExt)
        }
        if documentExtensions.contains(orig) {
            return documentExtensions.contains(newExt)
        }
        if archiveExtensions.contains(orig) {
            return archiveExtensions.contains(newExt)
        }

        return true
    }

    /// Detects a suggested extension from a URL and an optional MIME type.
    public static func detectExtension(from url: URL?, mimeType: String? = nil) -> String {
        if let pathExt = url?.pathExtension, !pathExt.isEmpty {
            return pathExt.lowercased()
        }
        if let mime = mimeType?.lowercased() {
            if mime.contains("mp4") { return "mp4" }
            if mime.contains("mpegurl") || mime.contains("m3u8") { return "mp4" } // Reconstruction container
            if mime.contains("dash") || mime.contains("mpd") { return "mp4" }
            if mime.contains("audio/mpeg") || mime.contains("mp3") { return "mp3" }
            if mime.contains("audio/mp4") || mime.contains("m4a") { return "m4a" }
            if mime.contains("pdf") { return "pdf" }
            if mime.contains("zip") { return "zip" }
            if mime.contains("gzip") { return "gz" }
            if mime.contains("tar") { return "tar" }
            if mime.contains("json") { return "json" }
            if mime.contains("image/png") { return "png" }
            if mime.contains("image/jpeg") { return "jpg" }
            if mime.contains("image/webp") { return "webp" }
        }
        return ""
    }
}
