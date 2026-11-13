import Foundation

// MARK: - Batch Expansion Errors & Models

public enum BatchExpansionError: Error, LocalizedError, Equatable {
    case malformedPattern(String)
    case invalidRange(String)
    case rangeTooLarge(count: Int, limit: Int)
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .malformedPattern(let reason):
            return "Malformed pattern: \(reason)"
        case .invalidRange(let reason):
            return "Invalid range: \(reason)"
        case .rangeTooLarge(let count, let limit):
            return "Pattern produces \(count) URLs, exceeding the safety limit of \(limit)."
        case .emptyInput:
            return "Input text or pattern is empty."
        }
    }
}

public struct BatchRejectedEntry: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let rawText: String
    public let reason: String

    public init(id: UUID = UUID(), rawText: String, reason: String) {
        self.id = id
        self.rawText = rawText
        self.reason = reason
    }
}

public struct BatchDownloadItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public var filename: String
    public var category: DownloadCategory
    public var isSelected: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String? = nil,
        category: DownloadCategory? = nil,
        isSelected: Bool = true
    ) {
        self.id = id
        self.url = url
        let resolvedFilename: String
        if let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !filename.isEmpty {
            resolvedFilename = filename
        } else {
            let last = url.lastPathComponent
            resolvedFilename = (!last.isEmpty && last != "/") ? last : "download_\(id.uuidString.prefix(8)).bin"
        }
        self.filename = resolvedFilename
        self.category = category ?? DownloadCategoryClassifier.classify(mimeType: nil, filename: resolvedFilename)
        self.isSelected = isSelected
    }
}

public struct BatchExpansionResult: Equatable, Sendable {
    public let validURLs: [URL]
    public let rejectedEntries: [BatchRejectedEntry]
    public let duplicateCount: Int

    public init(
        validURLs: [URL] = [],
        rejectedEntries: [BatchRejectedEntry] = [],
        duplicateCount: Int = 0
    ) {
        self.validURLs = validURLs
        self.rejectedEntries = rejectedEntries
        self.duplicateCount = duplicateCount
    }

    public func toDownloadItems(category: DownloadCategory? = nil) -> [BatchDownloadItem] {
        validURLs.map { url in
            BatchDownloadItem(url: url, category: category)
        }
    }
}

// MARK: - BatchURLExpander Engine

public struct BatchURLExpander: Sendable {
    public static let defaultMaxExpansionCount: Int = 1000

    private struct ParsedBracketRange {
        let values: [String]
    }

    /// Expands a single URL pattern containing range brackets (e.g. `https://example.com/file[001-050].zip`)
    /// into an array of validated URLs.
    public static func expandPattern(
        _ rawPattern: String,
        maxCount: Int = defaultMaxExpansionCount
    ) throws -> [URL] {
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            throw BatchExpansionError.emptyInput
        }

        // Bracket balance check
        let openBrackets = pattern.filter { $0 == "[" }.count
        let closeBrackets = pattern.filter { $0 == "]" }.count
        guard openBrackets == closeBrackets else {
            throw BatchExpansionError.malformedPattern("Mismatched range brackets ('[': \(openBrackets), ']': \(closeBrackets))")
        }

        if openBrackets == 0 {
            guard let url = validateAndBuildURL(pattern) else {
                throw BatchExpansionError.malformedPattern("Invalid URL format: \(pattern)")
            }
            return [url]
        }

        // Extract static parts and bracket segments
        var staticParts: [String] = []
        var bracketRanges: [ParsedBracketRange] = []

        var searchIndex = pattern.startIndex

        while let openRange = pattern[searchIndex...].range(of: "[") {
            let staticPart = String(pattern[searchIndex..<openRange.lowerBound])
            staticParts.append(staticPart)

            guard let closeRange = pattern[openRange.upperBound...].range(of: "]") else {
                throw BatchExpansionError.malformedPattern("Unclosed bracket starting at position \(pattern.distance(from: pattern.startIndex, to: openRange.lowerBound))")
            }

            let fullMatch = String(pattern[openRange.lowerBound..<closeRange.upperBound])
            let innerContent = String(pattern[openRange.upperBound..<closeRange.lowerBound])

            if innerContent.contains("[") || innerContent.contains("]") {
                throw BatchExpansionError.malformedPattern("Nested brackets are not supported in '\(fullMatch)'")
            }

            let values = try parseRangeValues(innerContent: innerContent, fullMatch: fullMatch)
            bracketRanges.append(ParsedBracketRange(values: values))

            searchIndex = closeRange.upperBound
        }

        // Trailing static text
        staticParts.append(String(pattern[searchIndex...]))

        // Validate count limits before generation
        var totalCount = 1
        for range in bracketRanges {
            let (newTotal, overflow) = totalCount.multipliedReportingOverflow(by: range.values.count)
            if overflow || newTotal > maxCount {
                throw BatchExpansionError.rangeTooLarge(count: overflow ? Int.max : newTotal, limit: maxCount)
            }
            totalCount = newTotal
        }

        // Combine static parts and range expansions
        var currentResults = [staticParts[0]]
        for i in 0..<bracketRanges.count {
            let values = bracketRanges[i].values
            let nextStatic = staticParts[i + 1]

            var nextResults: [String] = []
            nextResults.reserveCapacity(currentResults.count * values.count)

            for prefix in currentResults {
                for value in values {
                    nextResults.append(prefix + value + nextStatic)
                }
            }
            currentResults = nextResults
        }

        // Validate each expanded string as a legitimate URL
        var urls: [URL] = []
        urls.reserveCapacity(currentResults.count)

        for urlStr in currentResults {
            guard let url = validateAndBuildURL(urlStr) else {
                throw BatchExpansionError.malformedPattern("Generated invalid URL: '\(urlStr)'")
            }
            urls.append(url)
        }

        return urls
    }

    /// Parses multi-link text (e.g. from clipboard or imported .txt file).
    /// Skips blank lines and comments, deduplicates repeated URLs, expands patterns if enabled,
    /// and collects valid URLs along with detailed rejected entries.
    public static func parseMultiLineText(
        _ text: String,
        expandPatterns: Bool = true,
        maxCount: Int = defaultMaxExpansionCount
    ) -> BatchExpansionResult {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return BatchExpansionResult()
        }

        var validURLs: [URL] = []
        var rejectedEntries: [BatchRejectedEntry] = []
        var seenNormalizedURLs = Set<String>()
        var duplicateCount = 0

        let lines = text.components(separatedBy: .newlines)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix("//") {
                continue
            }

            // Check if pattern expansion is present
            if expandPatterns && line.contains("[") && line.contains("]") {
                let remainingBudget = max(1, maxCount - validURLs.count)
                do {
                    let expanded = try expandPattern(line, maxCount: remainingBudget)
                    for url in expanded {
                        let normalized = url.absoluteString.lowercased()
                        if seenNormalizedURLs.contains(normalized) {
                            duplicateCount += 1
                        } else {
                            seenNormalizedURLs.insert(normalized)
                            validURLs.append(url)
                        }
                    }
                } catch {
                    rejectedEntries.append(BatchRejectedEntry(rawText: line, reason: error.localizedDescription))
                }
                continue
            }

            // Determine candidate tokens for this line
            let tokens = line.components(separatedBy: .whitespaces).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }

            let urlTokens = tokens.filter {
                $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://")
            }

            let candidateTokens: [String]
            if urlTokens.count > 1 {
                // Multiple URLs on a single line
                candidateTokens = tokens
            } else if urlTokens.count == 1 && tokens.count > 1 {
                // Single URL with other non-URL tokens on the line (e.g. "https://example.com/file.zip Description")
                candidateTokens = urlTokens
            } else {
                // Single token or line without recognized URL prefixes
                candidateTokens = [line]
            }

            for token in candidateTokens {
                guard let url = validateAndBuildURL(token) else {
                    rejectedEntries.append(BatchRejectedEntry(
                        rawText: token,
                        reason: "Must be a valid HTTP or HTTPS address with a non-empty host"
                    ))
                    continue
                }

                let normalized = url.absoluteString.lowercased()
                if seenNormalizedURLs.contains(normalized) {
                    duplicateCount += 1
                } else {
                    seenNormalizedURLs.insert(normalized)
                    validURLs.append(url)
                }
            }
        }

        return BatchExpansionResult(
            validURLs: validURLs,
            rejectedEntries: rejectedEntries,
            duplicateCount: duplicateCount
        )
    }

    // MARK: - Internal Helpers

    private static func parseRangeValues(innerContent: String, fullMatch: String) throws -> [String] {
        let parts = innerContent.components(separatedBy: "-")
        guard parts.count == 2 else {
            throw BatchExpansionError.malformedPattern("Range '\(fullMatch)' must contain exactly one '-' separator (e.g. [001-050] or [1-10] or [a-z])")
        }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)

        guard !startStr.isEmpty, !endStr.isEmpty else {
            throw BatchExpansionError.malformedPattern("Empty range boundary in '\(fullMatch)'")
        }

        // Case 1: Numeric range
        if let startNum = Int(startStr), let endNum = Int(endStr) {
            guard startNum >= 0, endNum >= 0 else {
                throw BatchExpansionError.malformedPattern("Negative numbers are not allowed in range '\(fullMatch)'")
            }
            guard startNum <= endNum else {
                throw BatchExpansionError.invalidRange("Start value (\(startNum)) cannot be greater than end value (\(endNum)) in '\(fullMatch)'")
            }

            let isZeroPadded = (startStr.hasPrefix("0") && startStr.count > 1) || (endStr.hasPrefix("0") && endStr.count > 1)
            let paddingWidth = isZeroPadded ? max(startStr.count, endStr.count) : 0

            return (startNum...endNum).map { num in
                if paddingWidth > 0 {
                    return String(format: "%0*d", paddingWidth, num)
                } else {
                    return String(num)
                }
            }
        }

        // Case 2: Alphabetic range
        if startStr.count == 1 && endStr.count == 1 {
            let startChar = startStr.first!
            let endChar = endStr.first!

            guard (startChar.isASCII && startChar.isLetter) && (endChar.isASCII && endChar.isLetter) else {
                throw BatchExpansionError.malformedPattern("Characters in '\(fullMatch)' must be standard ASCII letters (a-z or A-Z)")
            }

            guard (startChar.isLowercase && endChar.isLowercase) || (startChar.isUppercase && endChar.isUppercase) else {
                throw BatchExpansionError.malformedPattern("Mismatched casing in alphabetic range '\(fullMatch)'")
            }

            guard let startScalar = startChar.unicodeScalars.first,
                  let endScalar = endChar.unicodeScalars.first,
                  startScalar.value <= endScalar.value else {
                throw BatchExpansionError.invalidRange("Start character '\(startChar)' cannot follow end character '\(endChar)' in '\(fullMatch)'")
            }

            return (startScalar.value...endScalar.value).compactMap { scalar in
                UnicodeScalar(scalar).map { String(Character($0)) }
            }
        }

        throw BatchExpansionError.malformedPattern("Unsupported range format '\(fullMatch)'. Expected numeric (e.g. [001-050]) or alphabetic (e.g. [a-z])")
    }

    private static func validateAndBuildURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}

