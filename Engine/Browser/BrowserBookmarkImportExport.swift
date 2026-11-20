import Foundation

/// Summary metrics returned upon completing a bookmark import operation.
public struct BookmarkImportSummary: Equatable, Sendable {
    public let totalFound: Int
    public let importedBookmarksCount: Int
    public let importedFoldersCount: Int
    public let skippedCount: Int
    public let duplicateCount: Int

    public init(
        totalFound: Int = 0,
        importedBookmarksCount: Int = 0,
        importedFoldersCount: Int = 0,
        skippedCount: Int = 0,
        duplicateCount: Int = 0
    ) {
        self.totalFound = totalFound
        self.importedBookmarksCount = importedBookmarksCount
        self.importedFoldersCount = importedFoldersCount
        self.skippedCount = skippedCount
        self.duplicateCount = duplicateCount
    }
}

/// URL normalization utility for consistent matching and duplicate detection.
public enum BookmarkURLNormalizer {
    public static func normalize(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        // Normalize empty or slash-only path
        if var path = components.path as String?, path.count > 1, path.hasSuffix("/") {
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            components.path = path
        }
        return components.url?.absoluteString ?? url.absoluteString
    }
}

/// Standard Netscape Bookmark File Format HTML Exporter.
@MainActor
public enum BrowserBookmarkExporter {

    /// Exports all bookmarks and nested folders in standard Netscape Bookmark HTML format.
    public static func exportToHTML(store: BrowserBookmarkStore) -> String {
        var html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """

        appendFolderContents(folderID: nil, store: store, html: &html, indentLevel: 1)

        html += "</DL><p>\n"
        return html
    }

    private static func appendFolderContents(
        folderID: UUID?,
        store: BrowserBookmarkStore,
        html: inout String,
        indentLevel: Int
    ) {
        let indent = String(repeating: "    ", count: indentLevel)
        let subfolders = store.subfolders(in: folderID)
        let bookmarks = store.bookmarks(in: folderID)

        // 1. Export subfolders
        for folder in subfolders {
            let timestamp = Int(folder.dateCreated.timeIntervalSince1970)
            let escapedTitle = escapeHTML(folder.title)
            html += "\(indent)<DT><H3 ADD_DATE=\"\(timestamp)\" LAST_MODIFIED=\"\(timestamp)\">\(escapedTitle)</H3>\n"
            html += "\(indent)<DL><p>\n"
            appendFolderContents(folderID: folder.id, store: store, html: &html, indentLevel: indentLevel + 1)
            html += "\(indent)</DL><p>\n"
        }

        // 2. Export bookmarks
        for item in bookmarks {
            let timestamp = Int(item.dateAdded.timeIntervalSince1970)
            let escapedURL = escapeHTML(item.url.absoluteString)
            let escapedTitle = escapeHTML(item.title)
            html += "\(indent)<DT><A HREF=\"\(escapedURL)\" ADD_DATE=\"\(timestamp)\">\(escapedTitle)</A>\n"
        }
    }

    public static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// Standard Netscape Bookmark File Format HTML Importer.
@MainActor
public enum BrowserBookmarkImporter {

    public static func unescapeHTML(_ string: String) -> String {
        var result = string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Handle numeric entities &#DDD;
        if result.contains("&#") {
            let pattern = "&#([0-9]+);"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                let matches = regex.matches(in: result, range: range).reversed()
                for match in matches {
                    if let codeRange = Range(match.range(at: 1), in: result),
                       let code = Int(result[codeRange]),
                       let scalar = UnicodeScalar(code) {
                        if let fullRange = Range(match.range, in: result) {
                            result.replaceSubrange(fullRange, with: String(scalar))
                        }
                    }
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Imports bookmarks and folders from Netscape HTML data into the given store.
    @discardableResult
    public static func importHTML(
        _ htmlData: Data,
        intoFolderID targetFolderID: UUID? = nil,
        store: BrowserBookmarkStore,
        skipDuplicates: Bool = true
    ) -> BookmarkImportSummary {
        guard let html = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .ascii) else {
            return BookmarkImportSummary()
        }
        return importHTMLString(html, intoFolderID: targetFolderID, store: store, skipDuplicates: skipDuplicates)
    }

    /// Parses and imports Netscape bookmark HTML string.
    public static func importHTMLString(
        _ html: String,
        intoFolderID targetFolderID: UUID? = nil,
        store: BrowserBookmarkStore,
        skipDuplicates: Bool = true
    ) -> BookmarkImportSummary {
        var totalFound = 0
        var importedBookmarks = 0
        var importedFolders = 0
        var skippedCount = 0
        var duplicateCount = 0

        // Track folder nesting using a stack of folder IDs
        var folderStack: [UUID?] = [targetFolderID]

        // Parse line by line or tag by tag
        let lines = html.components(separatedBy: .newlines)
        var pendingFolderTitle: String? = nil
        var pendingFolderDate: Date? = nil

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            // 1. Detect Folder definition: <DT><H3 ...>Title</H3> or <H3 ...>Title</H3>
            if lower.contains("<h3") {
                if let h3Start = lower.range(of: "<h3"),
                   let h3Close = lower.range(of: ">", range: h3Start.upperBound..<lower.endIndex),
                   let h3End = lower.range(of: "</h3", range: h3Close.upperBound..<lower.endIndex) {
                    let titleRaw = String(line[h3Close.upperBound..<h3End.lowerBound])
                    let title = unescapeHTML(titleRaw)
                    let tagAttributes = String(line[h3Start.upperBound..<h3Close.lowerBound])

                    var dateCreated = Date()
                    if let dateStr = extractAttribute("add_date", from: tagAttributes),
                       let sec = Double(dateStr) {
                        dateCreated = Date(timeIntervalSince1970: sec)
                    }

                    pendingFolderTitle = title.isEmpty ? "Imported Folder" : title
                    pendingFolderDate = dateCreated
                }
            }

            // 2. Detect <DL> entering a folder
            if lower.contains("<dl") {
                if let folderTitle = pendingFolderTitle {
                    let parentID = folderStack.last ?? targetFolderID
                    let folder = store.createFolder(title: folderTitle, parentFolderID: parentID)
                    folderStack.append(folder.id)
                    importedFolders += 1
                    pendingFolderTitle = nil
                    pendingFolderDate = nil
                } else if folderStack.count > 1 {
                    // Nested DL without explicit H3, retain current parent
                    folderStack.append(folderStack.last ?? targetFolderID)
                }
            }

            // 3. Detect </DL> exiting a folder
            if lower.contains("</dl") {
                if folderStack.count > 1 {
                    _ = folderStack.popLast()
                }
            }

            // 4. Detect Bookmark: <DT><A HREF="url" ...>Title</A> or <A HREF="url" ...>Title</A>
            if lower.contains("<a ") && lower.contains("href=") {
                totalFound += 1
                if let hrefVal = extractAttribute("href", from: line) {
                    let cleanURLString = unescapeHTML(hrefVal)
                    if let url = URL(string: cleanURLString),
                       let scheme = url.scheme?.lowercased(),
                       (scheme == "http" || scheme == "https" || scheme == "ftp") {

                        let title: String
                        if let aClose = lower.range(of: ">", range: lower.range(of: "<a ")!.upperBound..<lower.endIndex),
                           let aEnd = lower.range(of: "</a", range: aClose.upperBound..<lower.endIndex) {
                            let rawTitle = String(line[aClose.upperBound..<aEnd.lowerBound])
                            let unescaped = unescapeHTML(rawTitle)
                            title = unescaped.isEmpty ? (url.host ?? cleanURLString) : unescaped
                        } else {
                            title = url.host ?? cleanURLString
                        }

                        var dateAdded = Date()
                        if let addDateStr = extractAttribute("add_date", from: line),
                           let sec = Double(addDateStr) {
                            dateAdded = Date(timeIntervalSince1970: sec)
                        }

                        let parentID = folderStack.last ?? targetFolderID

                        // Check duplicates
                        if store.isBookmarked(url: url) {
                            duplicateCount += 1
                            if skipDuplicates {
                                skippedCount += 1
                                continue
                            }
                        }

                        _ = store.addBookmark(title: title, url: url, folderID: parentID, dateAdded: dateAdded)
                        importedBookmarks += 1
                    } else {
                        skippedCount += 1
                    }
                } else {
                    skippedCount += 1
                }
            }
        }

        return BookmarkImportSummary(
            totalFound: totalFound,
            importedBookmarksCount: importedBookmarks,
            importedFoldersCount: importedFolders,
            skippedCount: skippedCount,
            duplicateCount: duplicateCount
        )
    }

    private static func extractAttribute(_ name: String, from text: String) -> String? {
        let pattern = "(?i)\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valRange = Range(match.range(at: 1), in: text) else {
            // Check unquoted attribute e.g. HREF=http://example.com
            let unquotedPattern = "(?i)\(name)\\s*=\\s*([^\\s>]+)"
            if let unquotedRegex = try? NSRegularExpression(pattern: unquotedPattern),
               let unquotedMatch = unquotedRegex.firstMatch(in: text, range: range),
               let unquotedRange = Range(unquotedMatch.range(at: 1), in: text) {
                return String(text[unquotedRange])
            }
            return nil
        }
        return String(text[valRange])
    }
}
