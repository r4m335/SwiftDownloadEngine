import Foundation

/// Defines how a download was intercepted and handed off from the browser.
public enum BrowserDownloadHandoffSource: String, Sendable, CaseIterable {
    case nativeWebKitDownload = "Native WebKit Download"
    case responseAttachment = "Content-Disposition Attachment"
    case extensionMatch = "File Extension Match"
    case manualUserAction = "Manual Download Action"
}

/// Represents an intercepted download candidate ready for confirmation and
/// handoff into the native `DownloadCoordinator`.
public struct BrowserDownloadHandoff: Equatable, Sendable {
    public let originalURL: URL
    public let finalURL: URL
    public let suggestedFilename: String
    public let mimeType: String?
    public let expectedContentLength: Int64?
    public let source: BrowserDownloadHandoffSource
    public let timestamp: Date

    public init(
        originalURL: URL,
        finalURL: URL,
        suggestedFilename: String,
        mimeType: String? = nil,
        expectedContentLength: Int64? = nil,
        source: BrowserDownloadHandoffSource = .nativeWebKitDownload,
        timestamp: Date = Date()
    ) {
        self.originalURL = originalURL
        self.finalURL = finalURL
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.expectedContentLength = expectedContentLength
        self.source = source
        self.timestamp = timestamp
    }
}

/// Pure Swift coordinator that manages download interception policies,
/// filename resolution hierarchy, duplicate prompt prevention, and error discrimination.
public final class BrowserDownloadInterceptionManager: @unchecked Sendable {

    private let lock = NSLock()
    private var lastInterceptedURL: URL?
    private var lastInterceptedTimestamp: Date?
    public var cooldownSeconds: TimeInterval

    public init(cooldownSeconds: TimeInterval = 3.0) {
        self.cooldownSeconds = cooldownSeconds
    }

    /// Determines whether an intercepted URL should be suppressed due to a recent prompt.
    public func shouldSuppressDuplicate(for url: URL, isSheetPresented: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isSheetPresented { return true }

        if let lastURL = lastInterceptedURL, lastURL == url,
           let lastTime = lastInterceptedTimestamp {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < cooldownSeconds {
                return true
            }
        }
        return false
    }

    /// Records that an interception prompt has been presented to prevent rapid duplicate sheets.
    public func recordInterception(for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        lastInterceptedURL = url
        lastInterceptedTimestamp = Date()
    }

    /// Resolves the preferred destination filename following the precedence:
    /// 1. Server-provided suggested filename (from WebKit or Content-Disposition)
    /// 2. Header-parsed Content-Disposition filename
    /// 3. URL last path component
    /// 4. MIME-type fallback
    /// 5. Host-based fallback
    public func resolveFilename(
        serverSuggested: String?,
        contentDisposition: String?,
        url: URL,
        mimeType: String?
    ) -> String {
        // 1. Try server-provided suggested filename
        if let s = serverSuggested?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            let sanitized = BrowserDownloadClassifier.sanitizeFilename(s)
            if sanitized != "download.bin" && sanitized.contains(".") {
                return sanitized
            }
        }

        // 2. Try Content-Disposition
        if let disposition = contentDisposition, !disposition.isEmpty {
            let (_, parsedName) = BrowserDownloadClassifier.parseContentDisposition(disposition)
            if let p = parsedName, !p.isEmpty {
                return p
            }
        }

        // 3. Fall back to URL and MIME
        return BrowserDownloadClassifier.suggestedFilenameFromURL(url, mimeType: mimeType)
    }

    /// Prepares a validated `BrowserDownloadHandoff` payload for engine admission.
    public func prepareHandoff(
        originalURL: URL,
        finalURL: URL? = nil,
        serverSuggestedFilename: String? = nil,
        contentDisposition: String? = nil,
        mimeType: String? = nil,
        expectedLength: Int64? = nil,
        source: BrowserDownloadHandoffSource = .nativeWebKitDownload
    ) -> BrowserDownloadHandoff? {
        let destinationURL = finalURL ?? originalURL

        guard BrowserURLResolver.isValidDownloadURL(destinationURL) else {
            return nil
        }

        let filename = resolveFilename(
            serverSuggested: serverSuggestedFilename,
            contentDisposition: contentDisposition,
            url: destinationURL,
            mimeType: mimeType
        )

        return BrowserDownloadHandoff(
            originalURL: originalURL,
            finalURL: destinationURL,
            suggestedFilename: filename,
            mimeType: mimeType,
            expectedContentLength: expectedLength,
            source: source
        )
    }

    /// Evaluates whether a WebKit download error represents an intentional cancellation
    /// during handoff, rather than an authentic network failure.
    public static func isIntentionalHandoffCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        // WKErrorDomain: code 2 is downloadCancelled
        if nsError.domain == "WKErrorDomain" && nsError.code == 2 {
            return true
        }
        // NSURLErrorDomain: -999 is NSURLErrorCancelled
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        return false
    }
}
