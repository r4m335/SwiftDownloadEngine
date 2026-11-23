import Foundation

/// User-configurable sniffer filter preferences for media grabber sniffing.
public struct BrowserSnifferFilter: Codable, Sendable, Equatable {
    public var allowedExtensions: [String]
    public var allowedMIMETypes: [String]
    public var isFilterEnabled: Bool

    public static let defaultExtensions: [String] = [
        "mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "ts",
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus",
        "m3u8", "mpd",
        "zip", "rar", "7z", "tar", "gz", "iso", "dmg", "pkg",
        "pdf", "epub", "apk"
    ]

    public static let defaultMIMETypes: [String] = [
        "video/", "audio/", "application/vnd.apple.mpegurl", "application/dash+xml",
        "application/x-mpegurl", "application/octet-stream", "application/zip",
        "application/x-zip-compressed", "application/pdf"
    ]

    public static let userDefaultsKey = "DownloadEngineKit.BrowserSnifferFilter"

    public init(
        allowedExtensions: [String] = BrowserSnifferFilter.defaultExtensions,
        allowedMIMETypes: [String] = BrowserSnifferFilter.defaultMIMETypes,
        isFilterEnabled: Bool = true
    ) {
        self.allowedExtensions = allowedExtensions
        self.allowedMIMETypes = allowedMIMETypes
        self.isFilterEnabled = isFilterEnabled
    }

    public func matches(candidate: BrowserMediaCandidate) -> Bool {
        guard isFilterEnabled else { return true }
        // Preserve streaming manifests and media source blobs
        if candidate.kind == .hlsManifest || candidate.kind == .dashManifest || candidate.kind == .mediaSource || candidate.blobKind == .mediaSource {
            return true
        }
        if candidate.associatedManifestURL != nil {
            return true
        }

        // Check path extension if present in URL or suggested filename
        let urlExt = candidate.url?.pathExtension.lowercased() ?? ""
        let filenameExt = (candidate.suggestedFilename as NSString).pathExtension.lowercased()
        let ext = !urlExt.isEmpty ? urlExt : filenameExt
        if !ext.isEmpty {
            if allowedExtensions.contains(where: { $0.caseInsensitiveCompare(ext) == .orderedSame }) {
                return true
            }
        }

        // Check MIME type if present
        if let mime = candidate.mimeType?.lowercased() {
            if allowedMIMETypes.contains(where: { prefix in
                let p = prefix.lowercased()
                return mime.hasPrefix(p) || mime.contains(p)
            }) {
                return true
            }
        }

        return false
    }

    public static func load() -> BrowserSnifferFilter {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let filter = try? JSONDecoder().decode(BrowserSnifferFilter.self, from: data) else {
            return BrowserSnifferFilter()
        }
        return filter
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: BrowserSnifferFilter.userDefaultsKey)
        }
    }
}
