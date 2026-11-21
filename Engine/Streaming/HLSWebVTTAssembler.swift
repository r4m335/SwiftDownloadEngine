import Foundation

/// Represents an `X-TIMESTAMP-MAP` header in an HLS WebVTT segment, mapping MPEG-2 TS PTS
/// presentation time stamps (at 90 kHz) to local WebVTT cue times.
public struct WebVTTTimestampMap: Sendable, Equatable {
    /// 33-bit MPEG-2 Transport Stream Presentation Time Stamp (PTS) at 90 kHz.
    public let mpegTS: Int64
    /// Local WebVTT cue time in seconds corresponding to `mpegTS`.
    public let localTime: Double

    public init(mpegTS: Int64, localTime: Double) {
        self.mpegTS = mpegTS
        self.localTime = localTime
    }
}

/// A parsed WebVTT subtitle cue with start/end presentation timestamps in seconds.
public struct WebVTTCue: Sendable, Equatable {
    public var identifier: String?
    public var startTime: Double
    public var endTime: Double
    public var settings: String?
    public var text: String

    public init(
        identifier: String? = nil,
        startTime: Double,
        endTime: Double,
        settings: String? = nil,
        text: String
    ) {
        self.identifier = identifier
        self.startTime = startTime
        self.endTime = endTime
        self.settings = settings
        self.text = text
    }
}

/// Parsed representation of a WebVTT segment or document.
public struct WebVTTDocument: Sendable, Equatable {
    public var header: String
    public var timestampMap: WebVTTTimestampMap?
    public var headerBlocks: [String]
    public var cues: [WebVTTCue]

    public init(
        header: String = "WEBVTT",
        timestampMap: WebVTTTimestampMap? = nil,
        headerBlocks: [String] = [],
        cues: [WebVTTCue] = []
    ) {
        self.header = header
        self.timestampMap = timestampMap
        self.headerBlocks = headerBlocks
        self.cues = cues
    }
}

/// Represents one WebVTT segment input to be assembled, including its playlist metadata.
public struct WebVTTSegmentInput: Sendable {
    public let text: String
    public let playlistStartTime: Double
    public let duration: Double

    public init(text: String, playlistStartTime: Double, duration: Double) {
        self.text = text
        self.playlistStartTime = playlistStartTime
        self.duration = duration
    }
}

/// Robust parser, synchronizer, and assembler for multi-segment HLS WebVTT subtitles.
///
/// Handles:
/// 1. Interpreting `X-TIMESTAMP-MAP=MPEGTS:<pts>,LOCAL:<local>` headers to shift local cue times
///    to the master presentation timeline using MPEG-2 TS 90 kHz clock.
/// 2. Shifting segment-relative cues according to cumulative playlist start times when `X-TIMESTAMP-MAP` is omitted.
/// 3. Detecting already-absolute timestamps to prevent erroneous double-shifting.
/// 4. Merging spanning or overlapping cues across segment boundaries with identical text.
/// 5. Deduplicating identical cues and sorting cues chronologically.
public enum HLSWebVTTAssembler {

    /// 33-bit PTS modulus constant (2^33 = 8,589,934,592).
    public static let ptsModulus: Int64 = 1 << 33

    /// Parses a WebVTT timestamp string (e.g. `00:01.500`, `00:00:01.500`, `01:23:45.678`) into seconds.
    public static func parseTimestamp(_ rawString: String) -> Double? {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let components = trimmed.components(separatedBy: ":")

        switch components.count {
        case 2:
            // MM:SS.mmm
            guard let minutes = Double(components[0]),
                  let seconds = Double(components[1]) else {
                return nil
            }
            return (minutes * 60.0) + seconds
        case 3:
            // HH:MM:SS.mmm
            guard let hours = Double(components[0]),
                  let minutes = Double(components[1]),
                  let seconds = Double(components[2]) else {
                return nil
            }
            return (hours * 3600.0) + (minutes * 60.0) + seconds
        default:
            return nil
        }
    }

    /// Formats a time in seconds to a standard WebVTT timestamp string `HH:MM:SS.mmm`.
    public static func formatTimestamp(_ seconds: Double) -> String {
        let clamped = max(0.0, seconds)
        let totalMillis = Int64((clamped * 1000.0).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let secs = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60

        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    /// Parses an `X-TIMESTAMP-MAP` header line.
    ///
    /// Accepts variations like:
    /// - `X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000`
    /// - `X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000`
    public static func parseTimestampMap(from line: String) -> WebVTTTimestampMap? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eqIndex = trimmed.firstIndex(of: "=") else { return nil }
        let prefix = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
        guard prefix.caseInsensitiveCompare("X-TIMESTAMP-MAP") == .orderedSame else { return nil }

        let payload = trimmed[trimmed.index(after: eqIndex)...]
        let pairs = payload.components(separatedBy: ",")

        var parsedMPEGTS: Int64?
        var parsedLocal: Double?

        for pair in pairs {
            let keyVal = pair.components(separatedBy: ":")
            guard keyVal.count >= 2 else { continue }
            let key = keyVal[0].trimmingCharacters(in: .whitespaces).uppercased()
            let val = keyVal.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)

            if key == "MPEGTS" {
                parsedMPEGTS = Int64(val)
            } else if key == "LOCAL" {
                parsedLocal = parseTimestamp(val)
            }
        }

        guard let mpegTS = parsedMPEGTS, let local = parsedLocal else {
            return nil
        }
        return WebVTTTimestampMap(mpegTS: mpegTS, localTime: local)
    }

    /// Parses a WebVTT text into a `WebVTTDocument`.
    public static func parseDocument(text: String) -> WebVTTDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawBlocks = normalized.components(separatedBy: "\n\n")

        var header = "WEBVTT"
        var timestampMap: WebVTTTimestampMap?
        var headerBlocks: [String] = []
        var cues: [WebVTTCue] = []

        var blockIndex = 0
        while blockIndex < rawBlocks.count {
            let rawBlock = rawBlocks[blockIndex]
            let blockLines = rawBlock.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard !blockLines.isEmpty else {
                blockIndex += 1
                continue
            }

            // Check if this is the initial header block
            if blockIndex == 0 && blockLines[0].uppercased().hasPrefix("WEBVTT") {
                header = blockLines[0]
                for line in blockLines.dropFirst() {
                    if line.uppercased().hasPrefix("X-TIMESTAMP-MAP") {
                        timestampMap = parseTimestampMap(from: line)
                    } else if line.uppercased().hasPrefix("STYLE") || line.uppercased().hasPrefix("REGION") {
                        headerBlocks.append(line)
                    }
                }
                blockIndex += 1
                continue
            }

            // Standalone STYLE or REGION block
            let firstLineUpper = blockLines[0].uppercased()
            if firstLineUpper.hasPrefix("STYLE") || firstLineUpper.hasPrefix("REGION") {
                headerBlocks.append(rawBlock.trimmingCharacters(in: .whitespacesAndNewlines))
                blockIndex += 1
                continue
            }

            // Standalone NOTE (comment) block
            if firstLineUpper.hasPrefix("NOTE") {
                blockIndex += 1
                continue
            }

            // Standalone X-TIMESTAMP-MAP line
            if firstLineUpper.hasPrefix("X-TIMESTAMP-MAP") {
                if let map = parseTimestampMap(from: blockLines[0]) {
                    timestampMap = map
                }
                blockIndex += 1
                continue
            }

            // Attempt to parse as a cue
            if let cue = parseCue(from: blockLines) {
                cues.append(cue)
            }

            blockIndex += 1
        }

        return WebVTTDocument(
            header: header,
            timestampMap: timestampMap,
            headerBlocks: headerBlocks,
            cues: cues
        )
    }

    private static func parseCue(from lines: [String]) -> WebVTTCue? {
        guard !lines.isEmpty else { return nil }

        var timingLineIndex = -1
        for (idx, line) in lines.enumerated() {
            if line.contains("-->") {
                timingLineIndex = idx
                break
            }
        }

        guard timingLineIndex >= 0 else { return nil }

        let identifier: String? = timingLineIndex > 0 ? lines[0..<timingLineIndex].joined(separator: " ") : nil
        let timingLine = lines[timingLineIndex]

        let parts = timingLine.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        guard let startTime = parseTimestamp(startStr) else { return nil }

        let afterArrow = parts[1].trimmingCharacters(in: .whitespaces)
        let afterComponents = afterArrow.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let endStr = afterComponents.first,
              let endTime = parseTimestamp(endStr) else {
            return nil
        }

        let settings: String? = afterComponents.count > 1 ? afterComponents.dropFirst().joined(separator: " ") : nil
        let payloadLines = lines[(timingLineIndex + 1)...]
        let payload = payloadLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return WebVTTCue(
            identifier: identifier,
            startTime: startTime,
            endTime: endTime,
            settings: settings,
            text: payload
        )
    }

    /// Assembles multiple WebVTT segment inputs into a synchronized, single-file WebVTT string.
    public static func assemble(segments: [WebVTTSegmentInput]) -> String {
        guard !segments.isEmpty else {
            return "WEBVTT\n"
        }

        // Parse all segments
        let parsedDocuments = segments.map { parseDocument(text: $0.text) }

        // Step 1: Establish base MPEGTS PTS from the first segment that contains an X-TIMESTAMP-MAP
        var basePTS: Int64?
        for (idx, doc) in parsedDocuments.enumerated() {
            if let map = doc.timestampMap {
                let seg = segments[idx]
                let anchorSec = map.localTime + seg.playlistStartTime
                let ptsOffset = Int64((anchorSec * 90_000.0).rounded())
                basePTS = map.mpegTS - ptsOffset
                break
            }
        }

        // Step 2: Time-shift all cues to presentation time
        var allCues: [WebVTTCue] = []
        var headerBlocks: [String] = []

        for (idx, doc) in parsedDocuments.enumerated() {
            let seg = segments[idx]
            for block in doc.headerBlocks where !headerBlocks.contains(block) {
                headerBlocks.append(block)
            }

            if let map = doc.timestampMap, let base = basePTS {
                // Shift using X-TIMESTAMP-MAP and 90 kHz clock
                var segMPEGTS = map.mpegTS
                // Handle 33-bit PTS rollover: if PTS wrapped around (difference > 2^32)
                if segMPEGTS < base && (base - segMPEGTS) > (1 << 32) {
                    segMPEGTS += ptsModulus
                }
                let ptsDelta = Double(segMPEGTS - base)
                let anchorTime = ptsDelta / 90_000.0

                for cue in doc.cues {
                    let shiftedStart = max(0.0, anchorTime + (cue.startTime - map.localTime))
                    let shiftedEnd = max(shiftedStart + 0.001, anchorTime + (cue.endTime - map.localTime))
                    allCues.append(WebVTTCue(
                        identifier: cue.identifier,
                        startTime: shiftedStart,
                        endTime: shiftedEnd,
                        settings: cue.settings,
                        text: cue.text
                    ))
                }
            } else {
                // No X-TIMESTAMP-MAP: Shift by cumulative playlist time if cues are segment-relative
                let isSegmentRelative: Bool
                if let firstCue = doc.cues.first {
                    // If first cue starts earlier than the segment start (with a small 0.5s tolerance),
                    // the segment starts at 00:00.000 relative to itself.
                    isSegmentRelative = firstCue.startTime < (seg.playlistStartTime - 0.5)
                } else {
                    isSegmentRelative = false
                }

                let shift = isSegmentRelative ? seg.playlistStartTime : 0.0

                for cue in doc.cues {
                    let shiftedStart = max(0.0, cue.startTime + shift)
                    let shiftedEnd = max(shiftedStart + 0.001, cue.endTime + shift)
                    allCues.append(WebVTTCue(
                        identifier: cue.identifier,
                        startTime: shiftedStart,
                        endTime: shiftedEnd,
                        settings: cue.settings,
                        text: cue.text
                    ))
                }
            }
        }

        // Step 3: Sort cues chronologically by start time, then end time
        allCues.sort {
            if abs($0.startTime - $1.startTime) > 0.001 {
                return $0.startTime < $1.startTime
            }
            return $0.endTime < $1.endTime
        }

        // Step 4: Deduplicate and merge spanning/overlapping cues across segment boundaries
        var mergedCues: [WebVTTCue] = []
        for cue in allCues {
            guard let last = mergedCues.last else {
                mergedCues.append(cue)
                continue
            }

            let cleanCurrentText = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanLastText = last.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // If consecutive cues have identical text:
            if cleanCurrentText == cleanLastText {
                // Check if they are overlapping or adjacent within 0.15s tolerance
                let isOverlappingOrAdjacent = cue.startTime <= (last.endTime + 0.15) && cue.endTime >= (last.startTime - 0.15)
                if isOverlappingOrAdjacent {
                    // Merge spanning cue into a continuous interval
                    mergedCues[mergedCues.count - 1].startTime = min(last.startTime, cue.startTime)
                    mergedCues[mergedCues.count - 1].endTime = max(last.endTime, cue.endTime)
                    continue
                }
            }

            // Exact duplicate check within 0.05s tolerance
            if abs(cue.startTime - last.startTime) < 0.05 &&
               abs(cue.endTime - last.endTime) < 0.05 &&
               cleanCurrentText == cleanLastText {
                continue
            }

            mergedCues.append(cue)
        }

        // Step 5: Format assembled WebVTT document
        var output = "WEBVTT\n\n"
        for block in headerBlocks {
            output += "\(block)\n\n"
        }

        for (index, cue) in mergedCues.enumerated() {
            let identifier = cue.identifier ?? "\(index + 1)"
            output += "\(identifier)\n"
            let startString = formatTimestamp(cue.startTime)
            let endString = formatTimestamp(cue.endTime)
            if let settings = cue.settings, !settings.isEmpty {
                output += "\(startString) --> \(endString) \(settings)\n"
            } else {
                output += "\(startString) --> \(endString)\n"
            }
            output += "\(cue.text)\n\n"
        }

        return output
    }
}
