import Foundation

/// Primary classification categories for downloaded files in LID Download Manager.
public enum DownloadCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case videos = "videos"
    case audio = "audio"
    case documents = "documents"
    case archives = "archives"
    case torrents = "torrents"
    case others = "others"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .torrents: return "Torrents"
        case .others: return "Others"
        }
    }

    /// Default relative subfolder under Documents/Downloads/
    public var defaultSubfolderName: String {
        switch self {
        case .videos: return "Videos"
        case .audio: return "Music"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .torrents: return "Torrents"
        case .others: return "Others"
        }
    }

    public var iconName: String {
        switch self {
        case .videos: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .torrents: return "network"
        case .others: return "folder"
        }
    }
}

/// Classifier mapping MIME types and file extensions to DownloadCategory.
/// Follows the precedence: MIME type first, file extension as fallback.
public enum DownloadCategoryClassifier: Sendable {

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mkv", "webm", "avi", "mov", "wmv", "flv", "3gp", "3g2",
        "ts", "m4s", "m3u8", "mpd", "vob", "ogv", "f4v"
    ]

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "aiff", "aif",
        "wma", "alac", "mid", "midi", "amr"
    ]

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "rtf",
        "epub", "md", "markdown", "json", "xml", "pages", "numbers", "key",
        "tex", "log", "odt", "ods", "odp"
    ]

    private static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "gzip", "bz2", "bzip2", "xz", "iso",
        "dmg", "pkg", "deb", "rpm", "zst", "tgz", "tbz2"
    ]

    private static let torrentExtensions: Set<String> = [
        "torrent"
    ]

    /// Classify a file by MIME type (first) and filename extension (fallback).
    public static func classify(mimeType: String?, filename: String?) -> DownloadCategory {
        // 1. Evaluate MIME type first
        if let rawMime = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !rawMime.isEmpty {
            let cleanMime = rawMime.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? rawMime

            if cleanMime == "application/x-bittorrent" || cleanMime == "application/x-torrent" {
                return .torrents
            }

            if cleanMime.hasPrefix("video/") ||
               cleanMime == "application/x-mpegurl" ||
               cleanMime == "application/vnd.apple.mpegurl" ||
               cleanMime == "application/dash+xml" {
                return .videos
            }

            if cleanMime.hasPrefix("audio/") {
                return .audio
            }

            if cleanMime == "application/pdf" ||
               cleanMime.hasPrefix("text/") ||
               cleanMime.contains("msword") ||
               cleanMime.contains("officedocument") ||
               cleanMime.contains("excel") ||
               cleanMime.contains("powerpoint") ||
               cleanMime == "application/rtf" ||
               cleanMime == "application/json" ||
               cleanMime == "application/xml" ||
               cleanMime == "application/epub+zip" {
                return .documents
            }

            if cleanMime == "application/zip" ||
               cleanMime == "application/x-zip-compressed" ||
               cleanMime == "application/x-rar-compressed" ||
               cleanMime == "application/x-7z-compressed" ||
               cleanMime == "application/x-tar" ||
               cleanMime == "application/gzip" ||
               cleanMime == "application/x-bzip2" ||
               cleanMime == "application/x-xz" ||
               cleanMime == "application/x-iso9660-image" ||
               cleanMime == "application/x-apple-diskimage" {
                return .archives
            }
        }

        // 2. Fallback to file extension
        if let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !filename.isEmpty {
            let ext = (filename as NSString).pathExtension.lowercased()
            if !ext.isEmpty {
                if torrentExtensions.contains(ext) {
                    return .torrents
                }
                if videoExtensions.contains(ext) {
                    return .videos
                }
                if audioExtensions.contains(ext) {
                    return .audio
                }
                if documentExtensions.contains(ext) {
                    return .documents
                }
                if archiveExtensions.contains(ext) {
                    return .archives
                }
            }
        }

        return .others
    }

    /// Convenience classifier taking a URL and optional MIME type.
    public static func classify(url: URL?, mimeType: String?) -> DownloadCategory {
        classify(mimeType: mimeType, filename: url?.lastPathComponent)
    }
}

