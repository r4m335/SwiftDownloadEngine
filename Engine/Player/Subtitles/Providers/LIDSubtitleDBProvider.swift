import Foundation

/// Primary anonymous subtitle provider integrating The Subtitle Database (api.thesubtitledb.org).
/// Requires no API keys, accounts, or user configuration.
public final class LIDSubtitleDBProvider: SubtitleProvider {

    public let providerName: String = "The Subtitle Database"
    private let baseURL: String
    private let urlSession: URLSession

    public init(baseURL: String = "https://api.thesubtitledb.org", urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func search(query: SubtitleSearchQuery) async throws -> [SubtitleSearchResult] {
        var endpoint: String

        // 1. Choose optimal endpoint based on provided identifiers
        if let infoHash = query.infoHash, !infoHash.isEmpty {
            endpoint = "\(baseURL)/v1/by-infohash/\(infoHash)"
            if let s = query.season, let e = query.episode {
                endpoint += "/season/\(s)/episode/\(e)"
            }
        } else if let imdb = query.imdbId, !imdb.isEmpty {
            let cleanIMDb = imdb.hasPrefix("tt") ? imdb : "tt\(imdb)"
            endpoint = "\(baseURL)/v1/by-imdb/\(cleanIMDb)"
            if let s = query.season, let e = query.episode {
                endpoint += "/season/\(s)/episode/\(e)"
            }
        } else {
            // Title search
            if let s = query.season, let e = query.episode {
                endpoint = "\(baseURL)/v1/by-title/season/\(s)/episode/\(e)"
            } else {
                endpoint = "\(baseURL)/v1/by-title"
            }
        }

        // 2. Query parameters
        var components = URLComponents(string: endpoint)
        var queryItems: [URLQueryItem] = []

        if query.imdbId == nil && query.infoHash == nil {
            queryItems.append(URLQueryItem(name: "q", value: query.query))
        }

        if query.language != "all" && !query.language.isEmpty {
            let langCode = SubtitleLanguageCatalog.to2LetterCode(query.language)
            queryItems.append(URLQueryItem(name: "lang", value: langCode))
        }

        components?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let targetURL = components?.url else {
            return []
        }

        // 3. Perform network request with timeout
        var request = URLRequest(url: targetURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10.0)
        request.setValue("Mozilla/5.0 (compatible; LIDDownloadManager/1.0)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            return []
        }

        guard http.statusCode == 200 else {
            // Silently handle 404 (not found) or 429/500 without crashing
            return []
        }

        // 4. Parse response JSON
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let mediaTitle = (json["title"] as? [String: Any])?["name"] as? String ?? query.query
        guard let subtitlesDict = json["subtitles"] as? [String: Any],
              let items = subtitlesDict["items"] as? [[String: Any]] else {
            return []
        }

        // 5. Transform into SubtitleSearchResult models
        var results: [SubtitleSearchResult] = []

        for item in items {
            guard let idNum = item["id"] as? Int,
                  let langCode = item["language"] as? String else {
                continue
            }

            let idStr = String(idNum)
            let releaseName = item["release_name"] as? String
            let format = (item["format"] as? String ?? "srt").lowercased()
            let hearingImpaired = (item["hearing_impaired"] as? Bool) ?? false
            let cuesCount = item["cues"] as? Int

            let dlURLString = item["download_url"] as? String ?? "\(baseURL)/get/\(idStr)"
            guard let downloadURL = URL(string: dlURLString) else { continue }

            // Match quality calculation
            var quality: SubtitleMatchQuality = .keywordMatch
            var score = 40

            if query.infoHash != nil {
                quality = .exactHash
                score = 100
            } else if let reqRel = query.releaseGroup?.lowercased(),
                      let rel = releaseName?.lowercased(),
                      !reqRel.isEmpty, rel.contains(reqRel) {
                quality = .exactRelease
                score = 90
            } else if query.season != nil && query.episode != nil {
                quality = .exactEpisode
                score = 75
            } else if query.year != nil {
                quality = .titleAndYear
                score = 60
            }

            let result = SubtitleSearchResult(
                id: "subtitledb_\(idStr)",
                providerName: providerName,
                title: mediaTitle,
                releaseName: releaseName,
                languageCode: langCode,
                languageDisplayName: SubtitleLanguageCatalog.displayName(for: langCode),
                format: format,
                downloadURL: downloadURL,
                downloadCount: cuesCount,
                isHearingImpaired: hearingImpaired,
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
            throw NSError(domain: "LIDSubtitleDBProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to download subtitle file from \(result.downloadURL)"])
        }
        return data
    }
}
