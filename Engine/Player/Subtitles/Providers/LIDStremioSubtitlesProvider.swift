import Foundation

/// Secondary anonymous subtitle provider querying Stremio's public OpenSubtitles v3 add-on (opensubtitles-v3.strem.io).
/// Includes automated Cinemeta catalog resolution to map media titles to IMDb identifiers without API keys.
public final class LIDStremioSubtitlesProvider: SubtitleProvider {

    public let providerName: String = "OpenSubtitles (Stremio)"
    private let addonBaseURL: String
    private let cinemetaBaseURL: String
    private let urlSession: URLSession

    public init(
        addonBaseURL: String = "https://opensubtitles-v3.strem.io",
        cinemetaBaseURL: String = "https://v3-cinemeta.strem.io",
        urlSession: URLSession = .shared
    ) {
        self.addonBaseURL = addonBaseURL
        self.cinemetaBaseURL = cinemetaBaseURL
        self.urlSession = urlSession
    }

    public func search(query: SubtitleSearchQuery) async throws -> [SubtitleSearchResult] {
        // 1. Resolve IMDb identifier
        var imdbId = query.imdbId
        let isSeries = query.season != nil && query.episode != nil

        if imdbId == nil || imdbId?.isEmpty == true {
            imdbId = await resolveIMDbId(title: query.query, isSeries: isSeries, year: query.year)
        }

        guard let resolvedIMDb = imdbId, !resolvedIMDb.isEmpty else {
            return []
        }

        // 2. Build target subtitle endpoint
        let cleanIMDb = resolvedIMDb.hasPrefix("tt") ? resolvedIMDb : "tt\(resolvedIMDb)"
        let path: String
        if isSeries, let s = query.season, let e = query.episode {
            path = "\(addonBaseURL)/subtitles/series/\(cleanIMDb):\(s):\(e).json"
        } else {
            path = "\(addonBaseURL)/subtitles/movie/\(cleanIMDb).json"
        }

        guard let endpointURL = URL(string: path) else {
            return []
        }

        // 3. Fetch subtitle list
        var request = URLRequest(url: endpointURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10.0)
        request.setValue("Mozilla/5.0 (compatible; LIDDownloadManager/1.0)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subtitles = json["subtitles"] as? [[String: Any]] else {
            return []
        }

        // 4. Map subtitle records
        var results: [SubtitleSearchResult] = []
        let requestedLang2 = SubtitleLanguageCatalog.to2LetterCode(query.language)

        for item in subtitles {
            guard let rawLang = item["lang"] as? String,
                  let urlString = item["url"] as? String,
                  let downloadURL = URL(string: urlString) else {
                continue
            }

            let lang2 = SubtitleLanguageCatalog.to2LetterCode(rawLang)
            if query.language != "all" && !query.language.isEmpty && lang2 != requestedLang2 {
                continue
            }

            let subId = item["id"] as? String ?? UUID().uuidString
            let releaseName = (item["subtitleFileName"] as? String)
                ?? (item["movieReleaseName"] as? String)
                ?? (item["releaseGroup"] as? String)

            let isHI = (item["hearing_impaired"] as? Bool) ?? false

            // Score match quality
            var quality: SubtitleMatchQuality = .keywordMatch
            var score = 40

            if let reqRel = query.releaseGroup?.lowercased(),
               let rel = releaseName?.lowercased(),
               !reqRel.isEmpty, rel.contains(reqRel) {
                quality = .exactRelease
                score = 90
            } else if isSeries {
                quality = .exactEpisode
                score = 75
            } else if query.year != nil {
                quality = .titleAndYear
                score = 60
            }

            let result = SubtitleSearchResult(
                id: "stremio_\(subId)",
                providerName: providerName,
                title: query.query,
                releaseName: releaseName,
                languageCode: lang2,
                languageDisplayName: SubtitleLanguageCatalog.displayName(for: rawLang),
                format: downloadURL.pathExtension.lowercased().isEmpty ? "srt" : downloadURL.pathExtension.lowercased(),
                downloadURL: downloadURL,
                downloadCount: nil,
                isHearingImpaired: isHI,
                matchQuality: quality,
                score: score
            )
            results.append(result)
        }

        return results
    }

    public func download(result: SubtitleSearchResult) async throws -> Data {
        var request = URLRequest(url: result.downloadURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15.0)
        request.setValue("Mozilla/5.0 (compatible; LIDDownloadManager/1.0)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "LIDStremioSubtitlesProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to download subtitle from \(result.downloadURL)"])
        }
        return data
    }

    // MARK: - Cinemeta Title Resolution

    private func resolveIMDbId(title: String, isSeries: Bool, year: Int?) async -> String? {
        let type = isSeries ? "series" : "movie"
        guard let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        let searchURLString = "\(cinemetaBaseURL)/catalog/\(type)/top/search=\(encodedTitle).json"
        guard let url = URL(string: searchURLString) else { return nil }

        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 6.0)
        request.setValue("Mozilla/5.0 (compatible; LIDDownloadManager/1.0)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metas = json["metas"] as? [[String: Any]] else {
            return nil
        }

        if let year = year {
            let yearStr = String(year)
            if let match = metas.first(where: { ($0["releaseInfo"] as? String)?.contains(yearStr) == true }) {
                return match["id"] as? String
            }
        }

        return metas.first?["id"] as? String
    }
}
