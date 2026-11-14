import Foundation

/// Result of an in-page search query.
public struct BrowserFindInPageResult: Codable, Sendable, Equatable {
    public var matchCount: Int
    public var currentIndex: Int

    public init(matchCount: Int = 0, currentIndex: Int = 0) {
        self.matchCount = max(0, matchCount)
        self.currentIndex = matchCount > 0 ? max(1, min(matchCount, currentIndex)) : 0
    }

    public var displayString: String {
        guard matchCount > 0 else { return "0 of 0" }
        return "\(currentIndex) of \(matchCount)"
    }
}

/// Injected DOM search engine for finding, highlighting, and navigating text occurrences in WKWebView.
public enum BrowserFindInPageEngine {

    /// Generates JavaScript to find all occurrences of `query`, wrap them in highlight marks, and focus the first match.
    public static func searchScript(query: String) -> String {
        let escaped = escapeForJavaScript(query)
        return """
        (function() {
            try {
                // Clear existing highlights first
                var oldMarks = document.querySelectorAll('.lid-find-match');
                for (var i = 0; i < oldMarks.length; i++) {
                    var m = oldMarks[i];
                    var parent = m.parentNode;
                    if (parent) {
                        parent.replaceChild(document.createTextNode(m.textContent), m);
                        parent.normalize();
                    }
                }

                window.__lidFindMatches = [];
                window.__lidFindIndex = 0;

                var query = "\(escaped)".trim();
                if (!query || query.length === 0) {
                    return { matchCount: 0, currentIndex: 0 };
                }

                // Inject stylesheet for highlight marks if not present
                if (!document.getElementById('lid-find-in-page-style')) {
                    var style = document.createElement('style');
                    style.id = 'lid-find-in-page-style';
                    style.textContent = `
                        mark.lid-find-match {
                            background-color: #ffeb3b !important;
                            color: #000000 !important;
                            border-radius: 2px !important;
                            padding: 1px 2px !important;
                        }
                        mark.lid-find-match.lid-find-active {
                            background-color: #ff9800 !important;
                            color: #ffffff !important;
                            outline: 2px solid #e65100 !important;
                        }
                    `;
                    document.head.appendChild(style);
                }

                var textNodes = [];
                var walker = document.createTreeWalker(
                    document.body,
                    NodeFilter.SHOW_TEXT,
                    {
                        acceptNode: function(node) {
                            var parent = node.parentNode;
                            if (!parent) return NodeFilter.FILTER_REJECT;
                            var tag = parent.tagName ? parent.tagName.toLowerCase() : '';
                            if (tag === 'script' || tag === 'style' || tag === 'noscript' || tag === 'textarea') {
                                return NodeFilter.FILTER_REJECT;
                            }
                            return NodeFilter.FILTER_ACCEPT;
                        }
                    },
                    false
                );

                while (walker.nextNode()) {
                    textNodes.push(walker.currentNode);
                }

                var qLower = query.toLowerCase();
                var matches = [];

                for (var j = 0; j < textNodes.length; j++) {
                    var node = textNodes[j];
                    var text = node.nodeValue;
                    var tLower = text.toLowerCase();
                    var pos = 0;

                    while ((pos = tLower.indexOf(qLower, pos)) !== -1) {
                        var mark = document.createElement('mark');
                        mark.className = 'lid-find-match';
                        var matchText = text.substring(pos, pos + query.length);
                        mark.appendChild(document.createTextNode(matchText));

                        var afterText = text.substring(pos + query.length);
                        node.nodeValue = text.substring(0, pos);

                        var afterNode = document.createTextNode(afterText);
                        node.parentNode.insertBefore(afterNode, node.nextSibling);
                        node.parentNode.insertBefore(mark, afterNode);

                        matches.push(mark);

                        node = afterNode;
                        text = afterText;
                        tLower = text.toLowerCase();
                        pos = 0;
                    }
                }

                window.__lidFindMatches = matches;
                window.__lidFindIndex = 0;

                if (matches.length > 0) {
                    matches[0].classList.add('lid-find-active');
                    matches[0].scrollIntoView({ behavior: 'smooth', block: 'center' });
                    return { matchCount: matches.length, currentIndex: 1 };
                }

                return { matchCount: 0, currentIndex: 0 };
            } catch (e) {
                return { matchCount: 0, currentIndex: 0, error: e.toString() };
            }
        })();
        """
    }

    /// Moves highlight focus to the next match in document order.
    public static let nextMatchScript: String = """
    (function() {
        var matches = window.__lidFindMatches || [];
        if (matches.length === 0) return { matchCount: 0, currentIndex: 0 };

        var curIdx = window.__lidFindIndex || 0;
        matches[curIdx].classList.remove('lid-find-active');

        curIdx = (curIdx + 1) % matches.length;
        window.__lidFindIndex = curIdx;

        matches[curIdx].classList.add('lid-find-active');
        matches[curIdx].scrollIntoView({ behavior: 'smooth', block: 'center' });

        return { matchCount: matches.length, currentIndex: curIdx + 1 };
    })();
    """

    /// Moves highlight focus to the previous match in document order.
    public static let previousMatchScript: String = """
    (function() {
        var matches = window.__lidFindMatches || [];
        if (matches.length === 0) return { matchCount: 0, currentIndex: 0 };

        var curIdx = window.__lidFindIndex || 0;
        matches[curIdx].classList.remove('lid-find-active');

        curIdx = (curIdx - 1 + matches.length) % matches.length;
        window.__lidFindIndex = curIdx;

        matches[curIdx].classList.add('lid-find-active');
        matches[curIdx].scrollIntoView({ behavior: 'smooth', block: 'center' });

        return { matchCount: matches.length, currentIndex: curIdx + 1 };
    })();
    """

    /// Clears all highlights and restores original text node structure.
    public static let clearHighlightsScript: String = """
    (function() {
        var marks = document.querySelectorAll('.lid-find-match');
        for (var i = 0; i < marks.length; i++) {
            var m = marks[i];
            var parent = m.parentNode;
            if (parent) {
                parent.replaceChild(document.createTextNode(m.textContent), m);
                parent.normalize();
            }
        }
        window.__lidFindMatches = [];
        window.__lidFindIndex = 0;
        return { matchCount: 0, currentIndex: 0 };
    })();
    """

    /// Parses the JSON dictionary returned from evaluateJavaScript into a `BrowserFindInPageResult`.
    public static func parseResult(from jsonDict: [String: Any]?) -> BrowserFindInPageResult {
        guard let jsonDict else { return BrowserFindInPageResult(matchCount: 0, currentIndex: 0) }
        let matchCount = jsonDict["matchCount"] as? Int ?? 0
        let currentIndex = jsonDict["currentIndex"] as? Int ?? 0
        return BrowserFindInPageResult(matchCount: matchCount, currentIndex: currentIndex)
    }

    private static func escapeForJavaScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
