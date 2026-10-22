import Foundation

/// Represents the navigation state of the in-app browser.
public struct BrowserNavigationState: Equatable {
    public var currentURL: URL?
    public var title: String
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isLoading: Bool
    public var estimatedProgress: Double
    public var errorMessage: String?

    public init(
        currentURL: URL? = nil,
        title: String = "",
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isLoading: Bool = false,
        estimatedProgress: Double = 0.0,
        errorMessage: String? = nil
    ) {
        self.currentURL = currentURL
        self.title = title
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.estimatedProgress = estimatedProgress
        self.errorMessage = errorMessage
    }
}

/// Integration delegate boundary connecting the in-app browser to the download engine.
///
/// Ensures the browser does not create a duplicate HTTP downloader, but instead routes
/// user-initiated downloads directly into the established `DownloadCoordinator` workflow.
public protocol BrowserDownloadDelegate: AnyObject {
    func handleDownloadRequest(
        url: URL,
        filename: String?,
        threadCount: Int,
        speedLimitBytesPerSecond: Int64?
    ) async throws

    func handleDownloadRequest(
        url: URL,
        filename: String?,
        threadCount: Int,
        speedLimitBytesPerSecond: Int64?,
        headers: [String: String]?
    ) async throws
}

public extension BrowserDownloadDelegate {
    func handleDownloadRequest(
        url: URL,
        filename: String?,
        threadCount: Int,
        speedLimitBytesPerSecond: Int64?
    ) async throws {
        try await handleDownloadRequest(
            url: url,
            filename: filename,
            threadCount: threadCount,
            speedLimitBytesPerSecond: speedLimitBytesPerSecond,
            headers: nil
        )
    }

    func handleDownloadRequest(
        url: URL,
        filename: String?,
        threadCount: Int,
        speedLimitBytesPerSecond: Int64?,
        headers: [String: String]?
    ) async throws {
        try await handleDownloadRequest(
            url: url,
            filename: filename,
            threadCount: threadCount,
            speedLimitBytesPerSecond: speedLimitBytesPerSecond
        )
    }
}

/// Quick-access shortcut item displayed on the browser home/new-tab screen.
public struct BrowserQuickLink: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let urlString: String
    public let systemImage: String

    public init(id: String = UUID().uuidString, title: String, subtitle: String, urlString: String, systemImage: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.urlString = urlString
        self.systemImage = systemImage
    }

    public static let defaults: [BrowserQuickLink] = [
        BrowserQuickLink(
            title: "DuckDuckGo",
            subtitle: "Privacy Search",
            urlString: "https://duckduckgo.com",
            systemImage: "magnifyingglass.circle.fill"
        ),
        BrowserQuickLink(
            title: "Wikipedia",
            subtitle: "The Free Encyclopedia",
            urlString: "https://en.wikipedia.org",
            systemImage: "book.circle.fill"
        ),
        BrowserQuickLink(
            title: "Internet Archive",
            subtitle: "Digital Library & Public Media",
            urlString: "https://archive.org",
            systemImage: "building.columns.circle.fill"
        ),
        BrowserQuickLink(
            title: "Cloudflare Speed",
            subtitle: "Network Throughput & Range Testing",
            urlString: "https://speed.cloudflare.com",
            systemImage: "speedometer"
        ),
        BrowserQuickLink(
            title: "Apple Open Source",
            subtitle: "Kernel & Foundation Tarballs",
            urlString: "https://opensource.apple.com",
            systemImage: "applelogo"
        ),
        BrowserQuickLink(
            title: "GitHub",
            subtitle: "Developer Repositories & Releases",
            urlString: "https://github.com",
            systemImage: "chevron.left.forwardslash.chevron.right"
        )
    ]
}
