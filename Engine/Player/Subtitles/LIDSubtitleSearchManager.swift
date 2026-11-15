import Foundation

/// Central coordinator aggregating and ranking subtitle searches across all anonymous providers.
/// Ensures resilient fail-soft execution where one provider's failure does not break the query pipeline.
public actor LIDSubtitleSearchManager {

    public static let shared = LIDSubtitleSearchManager()

    private let providers: [SubtitleProvider]
    private var searchCache: [String: [SubtitleSearchResult]] = [:]

    public init(providers: [SubtitleProvider]? = nil) {
        if let customProviders = providers {
            self.providers = customProviders
        } else {
            self.providers = [
                LIDSubtitleDBProvider(),
                LIDStremioSubtitlesProvider(),
                LIDSubtitlesWebsiteProvider()
            ]
        }
    }

    /// Searches all registered providers concurrently, deduplicates results, and ranks them by match quality.
    public func search(query: SubtitleSearchQuery, bypassCache: Bool = false) async -> [SubtitleSearchResult] {
        let cacheKey = "\(query.query.lowercased())_\(query.season ?? -1)_\(query.episode ?? -1)_\(query.year ?? -1)_\(query.language)_\(query.imdbId ?? "")_\(query.infoHash ?? "")"

        if !bypassCache, let cached = searchCache[cacheKey], !cached.isEmpty {
            return cached
        }

        // Concurrent execution across all providers with isolated error boundaries
        let allResults = await withTaskGroup(of: [SubtitleSearchResult].self, returning: [SubtitleSearchResult].self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return try await provider.search(query: query)
                    } catch {
                        // Fail-soft: record nothing from failed provider and continue
                        return []
                    }
                }
            }

            var aggregated: [SubtitleSearchResult] = []
            for await providerResults in group {
                aggregated.append(contentsOf: providerResults)
            }
            return aggregated
        }

        // Deduplication & ranking
        let deduplicated = deduplicateAndRank(results: allResults, query: query)

        // Cache successful results
        if !deduplicated.isEmpty {
            searchCache[cacheKey] = deduplicated
        }

        return deduplicated
    }

    /// Downloads subtitle data using the provider associated with the result.
    public func download(result: SubtitleSearchResult) async throws -> Data {
        guard let provider = providers.first(where: { $0.providerName == result.providerName }) else {
            // Direct URL download fallback
            var req = URLRequest(url: result.downloadURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15.0)
            req.setValue("Mozilla/5.0 (compatible; LIDDownloadManager/1.0)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "LIDSubtitleSearchManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Download failed."])
            }
            return data
        }

        return try await provider.download(result: result)
    }

    /// Clear in-memory query cache
    public func clearCache() {
        searchCache.removeAll()
    }

    // MARK: - Deduplication & Ranking

    private func deduplicateAndRank(results: [SubtitleSearchResult], query: SubtitleSearchQuery) -> [SubtitleSearchResult] {
        var seenKeys = Set<String>()
        var unique: [SubtitleSearchResult] = []

        for item in results {
            let key = "\(item.languageCode)_\(item.releaseName?.lowercased().trimmingCharacters(in: .whitespaces) ?? item.title.lowercased())"
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                var scored = item
                scored.score = calculateScore(for: item, query: query)
                unique.append(scored)
            }
        }

        // Sort by score descending, then by language, then title
        return unique.sorted { a, b in
            if a.score != b.score {
                return a.score > b.score
            }
            if a.matchQuality.badgePriority != b.matchQuality.badgePriority {
                return a.matchQuality.badgePriority > b.matchQuality.badgePriority
            }
            return a.languageDisplayName < b.languageDisplayName
        }
    }

    private func calculateScore(for result: SubtitleSearchResult, query: SubtitleSearchQuery) -> Int {
        var score = result.matchQuality.badgePriority

        // Boost if release matches exact release group from query
        if let qRel = query.releaseGroup?.lowercased(), !qRel.isEmpty,
           let rRel = result.releaseName?.lowercased(), rRel.contains(qRel) {
            score += 20
        }

        // Boost if preferred language
        if query.language != "all" && result.languageCode == SubtitleLanguageCatalog.to2LetterCode(query.language) {
            score += 15
        }

        // Boost if hearing impaired preference (or penalize slightly if not requested)
        if result.isHearingImpaired {
            score += 5
        }

        return score
    }
}
