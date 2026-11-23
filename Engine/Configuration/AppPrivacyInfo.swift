import Foundation

/// Represents an Apple Required Reason API category declaration.
public struct PrivacyAccessedAPI: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let category: String
    public let reasons: [String]
    public let purpose: String

    public init(id: String, category: String, reasons: [String], purpose: String) {
        self.id = id
        self.category = category
        self.reasons = reasons
        self.purpose = purpose
    }
}

/// Represents an App Store Connect App Privacy nutrition label question and answer pair.
public struct AppPrivacyAnswer: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let category: String
    public let isCollected: Bool
    public let explanation: String

    public init(id: String, category: String, isCollected: Bool, explanation: String) {
        self.id = id
        self.category = category
        self.isCollected = isCollected
        self.explanation = explanation
    }
}

/// Global registry and single source of truth for application privacy declarations,
/// privacy policy URL, and App Store Nutrition Label answers.
public enum AppPrivacyInfo {

    /// Official hosted Privacy Policy URL.
    public static let privacyPolicyURL: URL = URL(
        string: "https://github.com/r4m335/SwiftDownloadEngine/blob/main/PRIVACY_POLICY.md"
    )!

    /// Upstream repository URL.
    public static let repositoryURL: URL = URL(
        string: "https://github.com/r4m335/SwiftDownloadEngine"
    )!

    /// Privacy tracking status (must correspond to `NSPrivacyTracking` in `PrivacyInfo.xcprivacy`).
    public static let isTrackingEnabled: Bool = false

    /// High-level summary of data collection practices.
    public static let dataCollectionSummary: String =
        "LID Download Manager operates completely on-device. No personal data, download activity, browsing history, or analytics are collected, stored on external servers, or shared with third parties."

    /// High-level summary of tracking practices.
    public static let trackingSummary: String =
        "The application does not track users across other companies' apps or websites. It contains zero advertising SDKs, behavioral tracking, or analytics identifiers."

    /// Declared Required Reason APIs corresponding to `NSPrivacyAccessedAPITypes`.
    public static let accessedAPIs: [PrivacyAccessedAPI] = [
        PrivacyAccessedAPI(
            id: "user-defaults",
            category: "NSPrivacyAccessedAPICategoryUserDefaults",
            reasons: ["CA92.1"],
            purpose: "Access user defaults to read and write application configuration, user preferences, and persistent local state."
        ),
        PrivacyAccessedAPI(
            id: "file-timestamp",
            category: "NSPrivacyAccessedAPICategoryFileTimestamp",
            reasons: ["C617.1", "3B52.1"],
            purpose: "Access modification timestamps of files inside the app container to display file dates and manage download resumption."
        ),
        PrivacyAccessedAPI(
            id: "disk-space",
            category: "NSPrivacyAccessedAPICategoryDiskSpace",
            reasons: ["E174.1"],
            purpose: "Verify available storage capacity before initiating downloads or allocating disk space."
        ),
        PrivacyAccessedAPI(
            id: "system-boot-time",
            category: "NSPrivacyAccessedAPICategorySystemBootTime",
            reasons: ["35F9.1"],
            purpose: "Measure time elapsed between transfer events to calculate transfer speed, ETA, and request timeouts."
        )
    ]

    /// Accurate App Store Connect App Privacy nutrition label answers.
    public static let appStoreAnswers: [AppPrivacyAnswer] = [
        AppPrivacyAnswer(
            id: "contact-info",
            category: "Contact Info (Name, Email, Phone)",
            isCollected: false,
            explanation: "No account registration or contact information is requested or collected."
        ),
        AppPrivacyAnswer(
            id: "user-content",
            category: "User Content (Files, Media, Downloads)",
            isCollected: false,
            explanation: "All downloaded files and media remain solely on the user's physical device in the sandboxed container."
        ),
        AppPrivacyAnswer(
            id: "browsing-history",
            category: "Browsing History & Bookmarks",
            isCollected: false,
            explanation: "Stored strictly in on-device database; never transmitted to developers or third parties."
        ),
        AppPrivacyAnswer(
            id: "identifiers",
            category: "Identifiers (User ID, Device ID)",
            isCollected: false,
            explanation: "No persistent user or device identifiers are generated or shared."
        ),
        AppPrivacyAnswer(
            id: "usage-data",
            category: "Usage Data & Analytics",
            isCollected: false,
            explanation: "Zero telemetry, analytics SDKs, or event tracking frameworks are present."
        ),
        AppPrivacyAnswer(
            id: "diagnostics",
            category: "Diagnostics & Crash Logs",
            isCollected: false,
            explanation: "Diagnostic logs are written locally on-device for user inspection only; no remote crash reporting."
        )
    ]
}
