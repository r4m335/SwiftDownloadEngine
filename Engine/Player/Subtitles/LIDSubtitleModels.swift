import Foundation

/// Quality and precision of a subtitle match relative to the media query.
public enum SubtitleMatchQuality: String, Codable, CaseIterable, Sendable {
    case exactHash = "Exact Hash"
    case exactRelease = "Exact Release"
    case exactEpisode = "Exact Episode"
    case titleAndYear = "Title & Year"
    case keywordMatch = "Keyword Match"

    public var badgePriority: Int {
        switch self {
        case .exactHash: return 100
        case .exactRelease: return 90
        case .exactEpisode: return 75
        case .titleAndYear: return 60
        case .keywordMatch: return 40
        }
    }
}

/// Query parameters for searching subtitles across providers.
public struct SubtitleSearchQuery: Equatable, Sendable {
    public var query: String
    public var season: Int?
    public var episode: Int?
    public var year: Int?
    public var releaseGroup: String?
    public var language: String // e.g. "all", "en", "es", "fr"
    public var imdbId: String?
    public var infoHash: String?

    public init(
        query: String,
        season: Int? = nil,
        episode: Int? = nil,
        year: Int? = nil,
        releaseGroup: String? = nil,
        language: String = "all",
        imdbId: String? = nil,
        infoHash: String? = nil
    ) {
        self.query = query
        self.season = season
        self.episode = episode
        self.year = year
        self.releaseGroup = releaseGroup
        self.language = language
        self.imdbId = imdbId
        self.infoHash = infoHash
    }

    /// Generates a clean human-readable search string.
    public var displaySearchString: String {
        var parts: [String] = [query]
        if let s = season, let e = episode {
            parts.append(String(format: "S%02dE%02d", s, e))
        } else if let y = year {
            parts.append(String(y))
        }
        if let rel = releaseGroup, !rel.isEmpty {
            parts.append(rel)
        }
        return parts.joined(separator: " ")
    }
}

/// A normalized subtitle search result returned by any provider.
public struct SubtitleSearchResult: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let providerName: String
    public let title: String
    public let releaseName: String?
    public let languageCode: String
    public let languageDisplayName: String
    public let format: String // "srt", "vtt", etc.
    public let downloadURL: URL
    public let downloadCount: Int?
    public let isHearingImpaired: Bool
    public var matchQuality: SubtitleMatchQuality
    public var score: Int

    public init(
        id: String,
        providerName: String,
        title: String,
        releaseName: String?,
        languageCode: String,
        languageDisplayName: String,
        format: String,
        downloadURL: URL,
        downloadCount: Int? = nil,
        isHearingImpaired: Bool = false,
        matchQuality: SubtitleMatchQuality = .keywordMatch,
        score: Int = 0
    ) {
        self.id = id
        self.providerName = providerName
        self.title = title
        self.releaseName = releaseName
        self.languageCode = languageCode
        self.languageDisplayName = languageDisplayName
        self.format = format
        self.downloadURL = downloadURL
        self.downloadCount = downloadCount
        self.isHearingImpaired = isHearingImpaired
        self.matchQuality = matchQuality
        self.score = score
    }

    public var displayTitle: String {
        if let rel = releaseName, !rel.isEmpty {
            return "\(languageDisplayName) - \(rel)"
        }
        return "\(languageDisplayName) - \(title)"
    }
}

/// Common protocol implemented by all anonymous subtitle providers.
public protocol SubtitleProvider: Sendable {
    var providerName: String { get }
    func search(query: SubtitleSearchQuery) async throws -> [SubtitleSearchResult]
    func download(result: SubtitleSearchResult) async throws -> Data
}

/// Helper for language code normalization and localization.
public struct SubtitleLanguageCatalog: Sendable {
    public static let supportedLanguages: [(code: String, name: String)] = [
        ("all", "All Languages"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("ru", "Russian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("tr", "Turkish")
    ]

    public static func displayName(for code: String) -> String {
        let clean = code.lowercased().trimmingCharacters(in: .whitespaces)
        // Check 2-letter or 3-letter codes
        if let match = supportedLanguages.first(where: { $0.code == clean }) {
            return match.name
        }
        // Handle common 3-letter ISO 639-2 mappings
        switch clean {
        case "eng": return "English"
        case "spa": return "Spanish"
        case "fre", "fra": return "French"
        case "ger", "deu": return "German"
        case "ita": return "Italian"
        case "por": return "Portuguese"
        case "ara": return "Arabic"
        case "hin": return "Hindi"
        case "rus": return "Russian"
        case "jpn": return "Japanese"
        case "kor": return "Korean"
        case "chi", "zho": return "Chinese"
        case "dut", "nld": return "Dutch"
        case "pol": return "Polish"
        case "tur": return "Turkish"
        default:
            return Locale.current.localizedString(forLanguageCode: clean) ?? clean.uppercased()
        }
    }

    public static func to2LetterCode(_ code: String) -> String {
        let clean = code.lowercased()
        switch clean {
        case "eng": return "en"
        case "spa": return "es"
        case "fre", "fra": return "fr"
        case "ger", "deu": return "de"
        case "ita": return "it"
        case "por": return "pt"
        case "ara": return "ar"
        case "hin": return "hi"
        case "rus": return "ru"
        case "jpn": return "ja"
        case "kor": return "ko"
        case "chi", "zho": return "zh"
        case "dut", "nld": return "nl"
        case "pol": return "pl"
        case "tur": return "tr"
        default: return clean
        }
    }
}
