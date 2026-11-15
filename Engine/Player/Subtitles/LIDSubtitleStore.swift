import Foundation

/// Manages local persistent storage, encoding conversion, validation, and retrieval of downloaded subtitles.
public actor LIDSubtitleStore {

    public static let shared = LIDSubtitleStore()

    private let storageRootDirectory: URL
    private let parser = LIDSubtitleParser()

    public init(storageDirectory: URL? = nil) {
        if let customDir = storageDirectory {
            self.storageRootDirectory = customDir
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.storageRootDirectory = docs.appendingPathComponent("LID/Media/Subtitles", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.storageRootDirectory, withIntermediateDirectories: true)
    }

    /// Validates, transcodes to UTF-8, and saves downloaded subtitle data to disk under the media's directory.
    public func saveSubtitle(
        data: Data,
        mediaTitle: String,
        languageCode: String,
        releaseName: String?,
        format: String = "srt"
    ) throws -> URL {
        // 1. Untrusted input handling: Check for ZIP header (PK\x03\x04)
        var textContent: String?
        if data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04 {
            // Unpack plain text from ZIP payload if embedded
            textContent = extractTextFromZip(data: data)
        }

        // 2. Decode character encoding fallback (UTF-8 -> CP1252 -> Latin-1)
        if textContent == nil {
            if let utf8 = String(data: data, encoding: .utf8) {
                textContent = utf8
            } else if let cp1252 = String(data: data, encoding: .windowsCP1252) {
                textContent = cp1252
            } else if let latin1 = String(data: data, encoding: .isoLatin1) {
                textContent = latin1
            }
        }

        guard let validText = textContent, !validText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "LIDSubtitleStore", code: 422, userInfo: [NSLocalizedDescriptionKey: "Invalid or empty subtitle content."])
        }

        // 3. Validation: Verify that content parses into at least one cue
        let cues = parser.parse(string: validText)
        guard !cues.isEmpty else {
            throw NSError(domain: "LIDSubtitleStore", code: 422, userInfo: [NSLocalizedDescriptionKey: "Subtitle content contains no recognizable cues or timestamps."])
        }

        // 4. Determine destination path
        let sanitizedMediaFolder = sanitizePathComponent(mediaTitle)
        let mediaDir = storageRootDirectory.appendingPathComponent(sanitizedMediaFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let safeRelease = sanitizePathComponent(releaseName ?? "sub")
        let fileName = "\(safeRelease).\(languageCode).\(format)"
        let targetFileURL = mediaDir.appendingPathComponent(fileName)

        // 5. Write standardized UTF-8 text to disk
        try validText.write(to: targetFileURL, atomically: true, encoding: .utf8)

        return targetFileURL
    }

    /// Discovers all previously downloaded subtitles for a given media title.
    public func listDownloadedSubtitles(for mediaTitle: String) -> [LIDSubtitleTrack] {
        let sanitizedMediaFolder = sanitizePathComponent(mediaTitle)
        let mediaDir = storageRootDirectory.appendingPathComponent(sanitizedMediaFolder, isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(at: mediaDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var tracks: [LIDSubtitleTrack] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "srt" || ext == "vtt" {
                let name = fileURL.deletingPathExtension().lastPathComponent
                let parts = name.split(separator: ".")
                let lang = parts.count > 1 ? String(parts.last!) : "en"
                let displayName = "\(SubtitleLanguageCatalog.displayName(for: lang)) (\(fileURL.lastPathComponent))"

                let track = LIDSubtitleTrack(
                    id: fileURL.path,
                    displayName: displayName,
                    languageCode: lang,
                    isExternal: true,
                    externalURL: fileURL
                )
                tracks.append(track)
            }
        }
        return tracks
    }

    /// Deletes a specific downloaded subtitle file.
    public func deleteSubtitle(at fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Private Helpers

    private func sanitizePathComponent(_ string: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>").union(.newlines)
        return string.components(separatedBy: invalidCharacters).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }

    private func extractTextFromZip(data: Data) -> String? {
        // Simple ZIP single-file extractor looking for uncompressed text segment
        // Or scanning for subtitle text markers inside the payload
        let marker = "00:00:".data(using: .utf8)!
        if let range = data.range(of: marker) {
            let start = max(0, range.lowerBound - 10)
            let subData = data.subdata(in: start..<data.count)
            if let str = String(data: subData, encoding: .utf8) ?? String(data: subData, encoding: .windowsCP1252) {
                return str
            }
        }
        return nil
    }
}
