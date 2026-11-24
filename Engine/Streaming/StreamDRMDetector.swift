import Foundation

/// Detects digital rights management (DRM) encryption across HLS and DASH streaming manifests.
public enum StreamDRMDetector {

    public struct DRMResult: Equatable, Sendable {
        public let isProtected: Bool
        public let protectionType: String?
        public let reason: String?
        public let isAES128Encrypted: Bool

        public static let clear = DRMResult(isProtected: false, protectionType: nil, reason: nil, isAES128Encrypted: false)

        public init(
            isProtected: Bool,
            protectionType: String? = nil,
            reason: String? = nil,
            isAES128Encrypted: Bool = false
        ) {
            self.isProtected = isProtected
            self.protectionType = protectionType
            self.reason = reason
            self.isAES128Encrypted = isAES128Encrypted
        }
    }

    /// Evaluates raw manifest text, MIME type, and optional URL for DRM indicators.
    ///
    /// Standards-compliant rule: Manifest evidence determines DRM protection when available.
    /// URL naming is advisory and never misclassifies clear media manifests as DRM.
    public static func evaluate(manifestText: String, url: URL? = nil) -> DRMResult {
        let text = manifestText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Manifest evidence determines DRM protection when available
        if !text.isEmpty {
            return evaluateManifestContent(text)
        }

        // 2. Advisory fallback only if manifest text is completely unavailable
        if let url = url {
            let lowerURL = url.absoluteString.lowercased()
            if lowerURL.contains("/fairplay/") || lowerURL.contains("/widevine/") || lowerURL.contains("/playready/") ||
               lowerURL.contains("/drm_fairplay/") || lowerURL.contains("/drm_widevine/") {
                return DRMResult(
                    isProtected: true,
                    protectionType: "DRM",
                    reason: "Media URL path specifies DRM system (\(url.lastPathComponent))"
                )
            }
        }

        return .clear
    }

    private static func evaluateManifestContent(_ text: String) -> DRMResult {
        var hasAES128 = false

        // 1. Check HLS Key Delivery, Session Keys, & Encryption (#EXT-X-KEY and #EXT-X-SESSION-KEY)
        if text.contains("#EXT-X-KEY") || text.contains("#EXT-X-SESSION-KEY") || text.contains("METHOD=SAMPLE-AES") {
            let lines = text.components(separatedBy: .newlines)
            for rawLine in lines {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("#EXT-X-KEY:") || trimmed.hasPrefix("#EXT-X-SESSION-KEY:") else { continue }
                let upper = trimmed.uppercased()

                if upper.contains("KEYFORMAT=\"COM.APPLE.STREAMINGKEYDELIVERY\"") ||
                   upper.contains("KEYFORMAT=COM.APPLE.STREAMINGKEYDELIVERY") ||
                   upper.contains("SKD://") {
                    return DRMResult(
                        isProtected: true,
                        protectionType: "FairPlay",
                        reason: "Apple FairPlay streaming key delivery detected"
                    )
                }

                if upper.contains("KEYFORMAT=\"URN:UUID:EDEF8BA9-79D6-4ACE-A3C8-27DCD51D21ED\"") ||
                   upper.contains("KEYFORMAT=URN:UUID:EDEF8BA9-79D6-4ACE-A3C8-27DCD51D21ED") {
                    return DRMResult(
                        isProtected: true,
                        protectionType: "Widevine",
                        reason: "Google Widevine DRM key format detected"
                    )
                }

                if upper.contains("KEYFORMAT=\"COM.MICROSOFT.PLAYREADY\"") ||
                   upper.contains("URN:UUID:9A04F079-9840-4286-AB92-E65BE0885F95") {
                    return DRMResult(
                        isProtected: true,
                        protectionType: "PlayReady",
                        reason: "Microsoft PlayReady DRM key format detected"
                    )
                }

                if upper.contains("METHOD=SAMPLE-AES") || upper.contains("METHOD=SAMPLE-AES-CTR") || upper.contains("METHOD=SAMPLE-AES-CENC") {
                    return DRMResult(
                        isProtected: true,
                        protectionType: "Sample-AES",
                        reason: "HLS Sample-AES DRM encryption detected"
                    )
                }

                if upper.contains("METHOD=AES-128") {
                    hasAES128 = true
                }
            }
        }

        // 2. Check DASH MPD ContentProtection elements
        if text.contains("<ContentProtection") || text.contains("<cenc:pssh") || text.contains("ContentProtection") {
            let lower = text.lowercased()
            if lower.contains("edef8ba9-79d6-4ace-a3c8-27dcd51d21ed") {
                return DRMResult(
                    isProtected: true,
                    protectionType: "Widevine",
                    reason: "DASH ContentProtection scheme specifies Google Widevine DRM"
                )
            }
            if lower.contains("9a04f079-9840-4286-ab92-e65be0885f95") {
                return DRMResult(
                    isProtected: true,
                    protectionType: "PlayReady",
                    reason: "DASH ContentProtection scheme specifies Microsoft PlayReady DRM"
                )
            }
            if lower.contains("94ce86fb-07ff-4f43-adb8-93d2fa968ca2") {
                return DRMResult(
                    isProtected: true,
                    protectionType: "FairPlay",
                    reason: "DASH ContentProtection scheme specifies Apple FairPlay DRM"
                )
            }
            return DRMResult(
                isProtected: true,
                protectionType: "DRM",
                reason: "DASH MPD manifest contains ContentProtection descriptor"
            )
        }

        if hasAES128 {
            return DRMResult(
                isProtected: false,
                protectionType: "AES-128",
                reason: "HLS standard envelope AES-128 encryption",
                isAES128Encrypted: true
            )
        }

        return .clear
    }
}
