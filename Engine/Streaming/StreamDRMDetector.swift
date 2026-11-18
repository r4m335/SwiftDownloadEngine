import Foundation

/// Detects digital rights management (DRM) encryption across HLS and DASH streaming manifests.
public enum StreamDRMDetector {

    public struct DRMResult: Equatable, Sendable {
        public let isProtected: Bool
        public let protectionType: String?
        public let reason: String?

        public static let clear = DRMResult(isProtected: false, protectionType: nil, reason: nil)

        public init(isProtected: Bool, protectionType: String? = nil, reason: String? = nil) {
            self.isProtected = isProtected
            self.protectionType = protectionType
            self.reason = reason
        }
    }

    /// Evaluates raw manifest text, MIME type, and optional URL for DRM indicators.
    public static func evaluate(manifestText: String, url: URL? = nil) -> DRMResult {
        // 0. Check URL path and query parameters for DRM indicators
        if let url = url {
            let lowerURL = url.absoluteString.lowercased()
            if lowerURL.contains("/hls_drm/") || lowerURL.contains("_drm/") || lowerURL.contains("/drm/") || lowerURL.contains("drm.m3u8") || lowerURL.contains("_drm.") {
                return DRMResult(
                    isProtected: true,
                    protectionType: "DRM",
                    reason: "Media URL path explicitly indicates DRM protection (\(url.lastPathComponent))"
                )
            }
        }

        let text = manifestText
        guard !text.isEmpty else { return .clear }

        // 1. Check HLS Key Delivery, Session Keys, & Encryption (#EXT-X-KEY and #EXT-X-SESSION-KEY)
        if text.contains("#EXT-X-KEY") || text.contains("#EXT-X-SESSION-KEY") || text.contains("METHOD=SAMPLE-AES") {
            let lines = text.components(separatedBy: .newlines)
            for rawLine in lines {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("#EXT-X-KEY:") || trimmed.hasPrefix("#EXT-X-SESSION-KEY:") else { continue }
                let upper = trimmed.uppercased()

                if upper.contains("KEYFORMAT=\"COM.APPLE.STREAMINGKEYDELIVERY\"") ||
                   upper.contains("KEYFORMAT=COM.APPLE.STREAMINGKEYDELIVERY") {
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

                if upper.contains("METHOD=SAMPLE-AES") || upper.contains("METHOD=\"SAMPLE-AES\"") ||
                   upper.contains("METHOD=SAMPLE-AES-CTR") {
                    return DRMResult(
                        isProtected: true,
                        protectionType: "Sample-AES",
                        reason: "HLS Sample-level AES encryption detected"
                    )
                }
            }
        }

        // 1b. Check if master manifest references child variant playlists containing DRM paths
        let lower = text.lowercased()
        if lower.contains("/hls_drm/") || lower.contains("_drm/") || lower.contains("/drm/") {
            return DRMResult(
                isProtected: true,
                protectionType: "DRM",
                reason: "Manifest references DRM-protected stream variants"
            )
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

        return .clear
    }
}
