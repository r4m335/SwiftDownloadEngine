import Foundation

/// Tertiary fallback subtitle provider querying Subtitle Search Engine (subtitles.website).
/// Operates under guest quota limits (10 requests/day); handles 429 rate limit responses gracefully.
public final class LIDSubtitlesWebsiteProvider: SubtitleProvider {

    public let providerName: String = "Subtitle Search Engine"
    private let baseURL: String
    private let urlSession: URLSession

    public init(baseURL: String = "https://subtitles.website", urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func search(query: SubtitleSearchQuery) async throws -> [SubtitleSearchResult] {
        var components = URLComponents(string: "\(baseURL)/api/v1/search")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: query.query)
        ]

        if let imdb = query.imdbId, !imdb.isEmpty {
            items.append(URLQueryItem(name: "imdb_id", value: imdb))
        }

        if query.language != "all" && !query.language.isEmpty {
            let lang = SubtitleLanguageCatalog.to2LetterCode(query.language)
            items.append(URLQueryItem(name: "lang", value: lang))
        }

        if let s = query.season, let e = query.episode {
            items.append(URLQueryItem(name: "season", value: String(s)))
            items.append(URLQueryItem(name: "episode", value: String(e)))
        }

        components?.queryItems = items

        guard let targetURL = components?.url else { return [] }

        var request = URLRequest(url: targetURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8.0)
        request.setValue("Mozilla/5.0 (compatible; LIDDownloadManager/1.0)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return [] }

            if http.statusCode == 429 {
                // Rate limit reached for guest tier: gracefully return empty results
                return []
            }

            guard http.statusCode == 200 else { return [] }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resultsArray = (json["results"] as? [[String: Any]]) ?? (json["subtitles"] as? [[String: Any]]) else {
                return []
            }

            var results: [SubtitleSearchResult] = []
            for item in resultsArray {
                guard let id = (item["id"] as? String) ?? ((item["id"] as? Int).map(String.init)),
                      let urlStr = (item["download_url"] as? String) ?? (item["url"] as? String),
                      let downloadURL = URL(string: urlStr) else {
                    continue
                }

                let lang = (item["language"] as? String) ?? "en"
                let releaseName = (item["release_name"] as? String) ?? (item["title"] as? String)

                let result = SubtitleSearchResult(
                    id: "subtitles_website_\(id)",
                    providerName: providerName,
                    title: query.query,
                    releaseName: releaseName,
                    languageCode: SubtitleLanguageCatalog.to2LetterCode(lang),
                    languageDisplayName: SubtitleLanguageCatalog.displayName(for: lang),
                    format: (item["format"] as? String) ?? "srt",
                    downloadURL: downloadURL,
                    downloadCount: item["downloads"] as? Int,
                    isHearingImpaired: (item["hearing_impaired"] as? Bool) ?? false,
                    matchQuality: query.season != nil ? .exactEpisode : .keywordMatch,
                    score: 45
                )
                results.append(result)
            }
            return results
        } catch {
            // Fail-soft: network errors do not disrupt the broader search workflow
            return []
        }
    }

    public func download(result: SubtitleSearchResult) async throws -> Data {
        var request = URLRequest(url: result.downloadURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15.0)
        request.setValue("Mozilla/5.0 (compatible; LIDDownloadManager/1.0)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "LIDSubtitlesWebsiteProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: "Download failed with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        return data
    }
}
