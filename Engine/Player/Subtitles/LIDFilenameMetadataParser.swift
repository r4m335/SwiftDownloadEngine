import Foundation

/// Parsed metadata extracted from a media filename or title string.
public struct ParsedFilenameMetadata: Equatable, Sendable {
    public let rawFilename: String
    public let title: String
    public let season: Int?
    public let episode: Int?
    public let year: Int?
    public let resolution: String?
    public let sourceRip: String?
    public let videoCodec: String?
    public let releaseGroup: String?

    public init(
        rawFilename: String,
        title: String,
        season: Int? = nil,
        episode: Int? = nil,
        year: Int? = nil,
        resolution: String? = nil,
        sourceRip: String? = nil,
        videoCodec: String? = nil,
        releaseGroup: String? = nil
    ) {
        self.rawFilename = rawFilename
        self.title = title
        self.season = season
        self.episode = episode
        self.year = year
        self.resolution = resolution
        self.sourceRip = sourceRip
        self.videoCodec = videoCodec
        self.releaseGroup = releaseGroup
    }

    /// Clean query suitable for subtitle database lookup.
    public var cleanQuery: String {
        title
    }

    /// Full search query representation including episode or year tags.
    public var fullSearchString: String {
        var str = title
        if let s = season, let e = episode {
            str += String(format: " S%02dE%02d", s, e)
        } else if let y = year {
            str += " \(y)"
        }
        return str
    }
}

/// Robust regex parser for extracting title, episode, year, and release tags from video filenames.
public final class LIDFilenameMetadataParser: Sendable {

    public init() {}

    public static func parse(_ rawInput: String) -> ParsedFilenameMetadata {
        // 1. Strip file extension if present
        var base = rawInput
        if let lastDotIndex = base.lastIndex(of: ".") {
            let ext = String(base[lastDotIndex...]).lowercased()
            let commonExtensions = [".mp4", ".mkv", ".ts", ".avi", ".webm", ".mov", ".flv", ".m4v", ".3gp", ".wmv", ".vob", ".mpg", ".mpeg"]
            if commonExtensions.contains(ext) {
                base = String(base[..<lastDotIndex])
            }
        }

        // 2. Extract release group (often at the end after a hyphen: "-FLUX", "-YTS", "-RARBG")
        var releaseGroup: String? = nil
        if let hyphenIndex = base.lastIndex(of: "-") {
            let groupCandidate = String(base[base.index(after: hyphenIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Ensure candidate isn't part of the title or a codec tag
            if groupCandidate.count >= 2 && groupCandidate.count <= 15 && !groupCandidate.contains(".") && !groupCandidate.contains(" ") {
                releaseGroup = groupCandidate
                base = String(base[..<hyphenIndex])
            }
        }

        // 3. Extract Season & Episode (e.g. S02E05 or 2x05)
        var season: Int? = nil
        var episode: Int? = nil
        var boundaryIndex: String.Index? = nil

        let sePattern = #"(?i)\bS(\d{1,2})E(\d{1,2})\b"#
        if let regex = try? NSRegularExpression(pattern: sePattern),
           let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) {
            if let sRange = Range(match.range(at: 1), in: base),
               let eRange = Range(match.range(at: 2), in: base),
               let fullRange = Range(match.range, in: base) {
                season = Int(base[sRange])
                episode = Int(base[eRange])
                boundaryIndex = fullRange.lowerBound
            }
        } else {
            // Check alternate pattern: 2x05
            let altPattern = #"(?i)\b(\d{1,2})x(\d{1,2})\b"#
            if let regex = try? NSRegularExpression(pattern: altPattern),
               let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) {
                if let sRange = Range(match.range(at: 1), in: base),
                   let eRange = Range(match.range(at: 2), in: base),
                   let fullRange = Range(match.range, in: base) {
                    season = Int(base[sRange])
                    episode = Int(base[eRange])
                    boundaryIndex = fullRange.lowerBound
                }
            }
        }

        // 4. Extract Year: 19xx or 20xx
        var year: Int? = nil
        let yearPattern = #"\b(19\d{2}|20\d{2})\b"#
        if let regex = try? NSRegularExpression(pattern: yearPattern) {
            let matches = regex.matches(in: base, range: NSRange(base.startIndex..., in: base))
            if let lastYearMatch = matches.last,
               let yRange = Range(lastYearMatch.range(at: 1), in: base),
               let fullRange = Range(lastYearMatch.range, in: base) {
                year = Int(base[yRange])
                if boundaryIndex == nil {
                    boundaryIndex = fullRange.lowerBound
                }
            }
        }

        // 5. Extract resolution tags
        var resolution: String? = nil
        let resPattern = #"(?i)\b(2160p|4k|1080p|1080i|720p|576p|480p)\b"#
        if let regex = try? NSRegularExpression(pattern: resPattern),
           let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let rRange = Range(match.range(at: 1), in: base) {
            resolution = String(base[rRange]).lowercased()
            if boundaryIndex == nil {
                boundaryIndex = Range(match.range, in: base)?.lowerBound
            }
        }

        // 6. Extract source/rip tags
        var sourceRip: String? = nil
        let ripPattern = #"(?i)\b(web-?dl|webrip|bluray|bdrip|brrip|dvdrip|hdtv)\b"#
        if let regex = try? NSRegularExpression(pattern: ripPattern),
           let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let rRange = Range(match.range(at: 1), in: base) {
            sourceRip = String(base[rRange]).uppercased()
            if boundaryIndex == nil {
                boundaryIndex = Range(match.range, in: base)?.lowerBound
            }
        }

        // 7. Extract video codec tags
        var videoCodec: String? = nil
        let codecPattern = #"(?i)\b(x264|x265|h\.?264|h\.?265|hevc|av1)\b"#
        if let regex = try? NSRegularExpression(pattern: codecPattern),
           let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let cRange = Range(match.range(at: 1), in: base) {
            videoCodec = String(base[cRange]).lowercased()
        }

        // 8. Derive Clean Title (everything before boundaryIndex, or the whole string)
        let rawTitleSubstring: String
        if let cut = boundaryIndex {
            rawTitleSubstring = String(base[..<cut])
        } else {
            rawTitleSubstring = base
        }

        // Normalize delimiters (dots, underscores, dashes to spaces)
        let cleanedTitle = rawTitleSubstring
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let finalTitle = cleanedTitle.isEmpty ? base : cleanedTitle

        return ParsedFilenameMetadata(
            rawFilename: rawInput,
            title: finalTitle,
            season: season,
            episode: episode,
            year: year,
            resolution: resolution,
            sourceRip: sourceRip,
            videoCodec: videoCodec,
            releaseGroup: releaseGroup
        )
    }
}
