import Foundation

/// A single timestamped subtitle cue.
public struct LIDSubtitleCue: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startTime: Double
    public let endTime: Double
    public let text: String

    public init(id: UUID = UUID(), startTime: Double, endTime: Double, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }

    /// Whether this cue is active at the given playback position.
    public func isActive(at seconds: Double) -> Bool {
        seconds >= startTime && seconds <= endTime
    }
}

/// Parser for SRT and WebVTT subtitle files with encoding fallback and HTML formatting cleanup.
public final class LIDSubtitleParser: Sendable {

    public init() {}

    /// Parse subtitles from file URL with encoding autodetection.
    public func parse(fileURL: URL) throws -> [LIDSubtitleCue] {
        let data = try Data(contentsOf: fileURL)
        return parse(data: data)
    }

    /// Parse subtitles from raw data, trying UTF-8 then ISO-Latin-1 then Windows-1252.
    public func parse(data: Data) -> [LIDSubtitleCue] {
        var text: String?
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            text = latin1
        } else if let win1252 = String(data: data, encoding: .windowsCP1252) {
            text = win1252
        }

        guard let content = text else { return [] }
        return parse(string: content)
    }

    /// Parse subtitle text string (SRT or WebVTT).
    public func parse(string: String) -> [LIDSubtitleCue] {
        let cleaned = string.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = cleaned.components(separatedBy: "\n\n")

        var cues: [LIDSubtitleCue] = []

        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard !lines.isEmpty else { continue }

            // Skip WebVTT header blocks
            if lines[0].uppercased().hasPrefix("WEBVTT") || lines[0].uppercased().hasPrefix("NOTE") {
                continue
            }

            var timeLineIndex = -1
            for (idx, line) in lines.enumerated() {
                if line.contains("-->") {
                    timeLineIndex = idx
                    break
                }
            }

            guard timeLineIndex >= 0 else { continue }

            let timeLine = lines[timeLineIndex]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count == 2 else { continue }

            let startStr = parts[0].trimmingCharacters(in: .whitespaces)
            var endStr = parts[1].trimmingCharacters(in: .whitespaces)
            // Strip any WebVTT cue settings (e.g. line:50% position:50%)
            if let spaceIdx = endStr.firstIndex(of: " ") {
                endStr = String(endStr[..<spaceIdx])
            }

            guard let startSec = parseTimestamp(startStr),
                  let endSec = parseTimestamp(endStr),
                  endSec > startSec else {
                continue
            }

            let textLines = lines[(timeLineIndex + 1)...]
            guard !textLines.isEmpty else { continue }

            let rawText = textLines.joined(separator: "\n")
            let strippedText = stripFormattingTags(rawText)

            if !strippedText.isEmpty {
                cues.append(LIDSubtitleCue(startTime: startSec, endTime: endSec, text: strippedText))
            }
        }

        return cues.sorted { $0.startTime < $1.startTime }
    }

    /// Finds the active subtitle cue for a given position with an optional synchronization delay.
    public func activeCue(in cues: [LIDSubtitleCue], at seconds: Double, delay: Double = 0.0) -> LIDSubtitleCue? {
        let adjustedSeconds = seconds - delay
        guard adjustedSeconds >= 0 else { return nil }

        // Binary search or linear scan (cues typically < 2000 items)
        for cue in cues {
            if cue.isActive(at: adjustedSeconds) {
                return cue
            }
            if cue.startTime > adjustedSeconds {
                break
            }
        }
        return nil
    }

    // MARK: - Helper Methods

    /// Parse timestamp in format "00:01:23,456" or "00:01:23.456" or "01:23.456".
    public func parseTimestamp(_ timestamp: String) -> Double? {
        let normalized = timestamp.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").map { String($0) }

        if parts.count == 3 {
            // HH:MM:SS.mmm
            guard let h = Double(parts[0]),
                  let m = Double(parts[1]),
                  let s = Double(parts[2]) else { return nil }
            return (h * 3600.0) + (m * 60.0) + s
        } else if parts.count == 2 {
            // MM:SS.mmm
            guard let m = Double(parts[0]),
                  let s = Double(parts[1]) else { return nil }
            return (m * 60.0) + s
        }

        return nil
    }

    /// Strip HTML/XML formatting tags such as <i>, </i>, <b>, <font color="...">, etc.
    public func stripFormattingTags(_ text: String) -> String {
        var result = ""
        var inTag = false

        for char in text {
            if char == "<" {
                inTag = true
            } else if char == ">" {
                inTag = false
            } else if !inTag {
                result.append(char)
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
