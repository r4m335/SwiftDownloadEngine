import Foundation

/// Structured distilled article extracted from a webpage.
public struct BrowserReaderArticle: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var byline: String?
    public var siteName: String?
    public var publishDate: String?
    public var readingTimeMinutes: Int
    public var contentHTML: String
    public var plainText: String
    public var sourceURL: URL?

    public init(
        id: UUID = UUID(),
        title: String,
        byline: String? = nil,
        siteName: String? = nil,
        publishDate: String? = nil,
        readingTimeMinutes: Int = 1,
        contentHTML: String,
        plainText: String = "",
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.publishDate = publishDate
        self.readingTimeMinutes = max(1, readingTimeMinutes)
        self.contentHTML = contentHTML
        self.plainText = plainText
        self.sourceURL = sourceURL
    }
}

/// User visual preferences for Reader Mode rendering.
public struct BrowserReaderSettings: Codable, Sendable, Equatable {
    public var theme: BrowserReaderTheme
    public var fontFamily: BrowserReaderFontFamily
    public var fontSize: Double
    public var lineSpacing: Double

    public init(
        theme: BrowserReaderTheme = .light,
        fontFamily: BrowserReaderFontFamily = .serif,
        fontSize: Double = 18.0,
        lineSpacing: Double = 1.6
    ) {
        self.theme = theme
        self.fontFamily = fontFamily
        self.fontSize = max(12.0, min(36.0, fontSize))
        self.lineSpacing = max(1.2, min(2.4, lineSpacing))
    }
}

/// Pure engine for extracting article readability metadata and generating styled reader HTML.
public enum BrowserReaderExtractor {

    /// Client-side JavaScript evaluated inside WKWebView to distill the main article.
    public static let extractionScript: String = """
    (function() {
        try {
            // 1. Identify Title
            var title = "";
            var ogTitle = document.querySelector('meta[property="og:title"]');
            if (ogTitle && ogTitle.content) {
                title = ogTitle.content.trim();
            } else {
                var h1 = document.querySelector('h1');
                if (h1 && h1.innerText.trim().length > 0) {
                    title = h1.innerText.trim();
                } else {
                    title = document.title ? document.title.trim() : "Untitled Article";
                }
            }

            // 2. Identify Author / Byline
            var byline = null;
            var authorMeta = document.querySelector('meta[name="author"]') ||
                             document.querySelector('meta[property="article:author"]') ||
                             document.querySelector('[rel="author"]') ||
                             document.querySelector('.byline') ||
                             document.querySelector('.author');
            if (authorMeta) {
                byline = authorMeta.content || authorMeta.innerText || null;
                if (byline) byline = byline.trim();
            }

            // 3. Identify Site Name
            var siteName = null;
            var ogSite = document.querySelector('meta[property="og:site_name"]');
            if (ogSite && ogSite.content) {
                siteName = ogSite.content.trim();
            } else {
                siteName = window.location.hostname.replace(/^www\\./, '');
            }

            // 4. Identify Publication Date
            var pubDate = null;
            var dateMeta = document.querySelector('meta[property="article:published_time"]') ||
                           document.querySelector('time[datetime]');
            if (dateMeta) {
                pubDate = dateMeta.content || dateMeta.getAttribute('datetime') || dateMeta.innerText || null;
                if (pubDate) pubDate = pubDate.trim();
            }

            // 5. Locate candidate article container
            var candidates = [
                document.querySelector('article'),
                document.querySelector('[role="article"]'),
                document.querySelector('.post-content'),
                document.querySelector('.entry-content'),
                document.querySelector('.article-body'),
                document.querySelector('.story-body'),
                document.querySelector('#article-body'),
                document.querySelector('main')
            ];

            var container = null;
            for (var i = 0; i < candidates.length; i++) {
                if (candidates[i] && candidates[i].innerText && candidates[i].innerText.trim().length > 120) {
                    container = candidates[i];
                    break;
                }
            }

            // Fallback: look for body if sufficient paragraphs exist
            if (!container) {
                var paras = document.querySelectorAll('p');
                if (paras.length >= 2) {
                    container = document.body;
                }
            }

            if (!container) {
                return { success: false, reason: "No readable article content found on this page." };
            }

            // Clone to avoid modifying the live page DOM
            var clone = container.cloneNode(true);

            // Strip noise elements
            var noiseSelectors = [
                'script', 'style', 'iframe', 'nav', 'header', 'footer', 'aside',
                'form', 'button', 'input', 'textarea', 'select', 'noscript',
                '.ad', '.ads', '.advertisement', '.social-share', '.banner',
                '.cookie-banner', '.newsletter', '.comments', '.sidebar',
                '[role="complementary"]', '[role="navigation"]', '[aria-hidden="true"]'
            ];
            noiseSelectors.forEach(function(sel) {
                var matches = clone.querySelectorAll(sel);
                for (var j = 0; j < matches.length; j++) {
                    matches[j].parentNode && matches[j].parentNode.removeChild(matches[j]);
                }
            });

            // Ensure relative image src attributes are converted to absolute URLs
            var images = clone.querySelectorAll('img');
            for (var k = 0; k < images.length; k++) {
                var img = images[k];
                if (img.src) {
                    img.setAttribute('src', img.src);
                }
            }

            var textContent = clone.innerText ? clone.innerText.trim() : "";
            var words = textContent.split(/\\s+/).filter(function(w) { return w.length > 0; });
            var wordCount = words.length;

            if (wordCount < 40) {
                return { success: false, reason: "Page content is too brief for Reader Mode." };
            }

            var readingTime = Math.max(1, Math.round(wordCount / 200));

            return {
                success: true,
                title: title,
                byline: byline,
                siteName: siteName,
                publishDate: pubDate,
                contentHTML: clone.innerHTML,
                plainText: textContent.substring(0, 5000),
                wordCount: wordCount,
                readingTimeMinutes: readingTime
            };
        } catch (e) {
            return { success: false, reason: e.toString() };
        }
    })();
    """

    /// Parses the JSON dictionary returned from evaluateJavaScript into a `BrowserReaderArticle`.
    public static func parseExtraction(jsonDict: [String: Any], sourceURL: URL?) -> BrowserReaderArticle? {
        guard let success = jsonDict["success"] as? Bool, success,
              let title = jsonDict["title"] as? String,
              let contentHTML = jsonDict["contentHTML"] as? String else {
            return nil
        }

        let byline = jsonDict["byline"] as? String
        let siteName = jsonDict["siteName"] as? String
        let publishDate = jsonDict["publishDate"] as? String
        let readingTime = jsonDict["readingTimeMinutes"] as? Int ?? 1
        let plainText = jsonDict["plainText"] as? String ?? ""

        return BrowserReaderArticle(
            title: title,
            byline: byline,
            siteName: siteName,
            publishDate: publishDate,
            readingTimeMinutes: readingTime,
            contentHTML: contentHTML,
            plainText: plainText,
            sourceURL: sourceURL
        )
    }

    /// Generates self-contained, sanitized, and responsive HTML for the article rendered in Reader Mode.
    public static func generateReaderHTML(article: BrowserReaderArticle, settings: BrowserReaderSettings) -> String {
        let (bgHex, textHex, linkHex, mutedHex) = themeColors(for: settings.theme)
        let fontStack = fontFamilyStack(for: settings.fontFamily)

        let safeTitle = escapeHTML(article.title)
        var metadataLine = ""
        if let byline = article.byline, !byline.isEmpty {
            metadataLine += "<span>By \(escapeHTML(byline))</span>"
        }
        if let site = article.siteName, !site.isEmpty {
            if !metadataLine.isEmpty { metadataLine += " • " }
            metadataLine += "<span>\(escapeHTML(site))</span>"
        }
        metadataLine += " • <span>\(article.readingTimeMinutes) min read</span>"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=2.0">
            <title>\(safeTitle)</title>
            <style>
                :root {
                    --bg-color: \(bgHex);
                    --text-color: \(textHex);
                    --link-color: \(linkHex);
                    --muted-color: \(mutedHex);
                    --font-family: \(fontStack);
                    --font-size: \(settings.fontSize)px;
                    --line-spacing: \(settings.lineSpacing);
                }
                body {
                    background-color: var(--bg-color);
                    color: var(--text-color);
                    font-family: var(--font-family);
                    font-size: var(--font-size);
                    line-height: var(--line-spacing);
                    margin: 0;
                    padding: 24px 20px 80px 20px;
                    display: flex;
                    justify-content: center;
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                }
                .reader-container {
                    max-width: 680px;
                    width: 100%;
                }
                h1.article-title {
                    font-size: 1.85em;
                    line-height: 1.25;
                    margin-bottom: 8px;
                    font-weight: 700;
                }
                .article-meta {
                    font-size: 0.85em;
                    color: var(--muted-color);
                    margin-bottom: 32px;
                    border-bottom: 1px solid var(--muted-color);
                    padding-bottom: 16px;
                }
                .article-body {
                    line-height: var(--line-spacing);
                }
                .article-body p {
                    margin-top: 0;
                    margin-bottom: 1.25em;
                }
                .article-body h2, .article-body h3, .article-body h4 {
                    margin-top: 1.4em;
                    margin-bottom: 0.6em;
                    line-height: 1.3;
                }
                .article-body a {
                    color: var(--link-color);
                    text-decoration: underline;
                }
                .article-body img {
                    max-width: 100%;
                    height: auto;
                    border-radius: 8px;
                    display: block;
                    margin: 20px auto;
                }
                .article-body blockquote {
                    border-left: 3px solid var(--link-color);
                    margin: 1.5em 0;
                    padding-left: 16px;
                    font-style: italic;
                    color: var(--muted-color);
                }
                .article-body pre, .article-body code {
                    font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
                    font-size: 0.9em;
                    background: rgba(128, 128, 128, 0.15);
                    border-radius: 4px;
                    padding: 2px 6px;
                }
                .article-body pre {
                    padding: 12px;
                    overflow-x: auto;
                }
            </style>
        </head>
        <body>
            <div class="reader-container">
                <h1 class="article-title">\(safeTitle)</h1>
                <div class="article-meta">\(metadataLine)</div>
                <div class="article-body">
                    \(article.contentHTML)
                </div>
            </div>
        </body>
        </html>
        """
    }

    private static func themeColors(for theme: BrowserReaderTheme) -> (bg: String, text: String, link: String, muted: String) {
        switch theme {
        case .light:
            return ("#ffffff", "#1a1a1a", "#007aff", "#6e6e73")
        case .sepia:
            return ("#fbf0d9", "#5f4b32", "#a35800", "#8c7355")
        case .gray:
            return ("#2c2c2e", "#e5e5ea", "#64d2ff", "#98989d")
        case .dark:
            return ("#121212", "#d1d1d6", "#0a84ff", "#8e8e93")
        }
    }

    private static func fontFamilyStack(for family: BrowserReaderFontFamily) -> String {
        switch family {
        case .serif:
            return "Georgia, Cambria, 'Times New Roman', Times, serif"
        case .sansSerif:
            return "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
        case .monospace:
            return "'SF Mono', Menlo, Monaco, Consolas, 'Courier New', monospace"
        }
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
