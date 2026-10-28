import Foundation

/// Classifies supplied manifest metadata and a bounded content sample without
/// performing any network access.
public enum StreamingManifestClassifier {

    public static let hlsMIMETypes: Set<String> = [
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl",
        "video/mpegurl"
    ]

    public static let dashMIMETypes: Set<String> = [
        "application/dash+xml",
        "video/vnd.mpeg.dash.mpd"
    ]

    public static func classify(
        url: URL,
        mimeType: String? = nil,
        content: Data? = nil,
        limits: ManifestParsingLimits = .default
    ) -> StreamingManifestClassification {
        let metadataKind = metadataKind(url: url, mimeType: mimeType)

        if let content {
            guard content.count <= limits.maxBytes else {
                return StreamingManifestClassification(
                    kind: .unsupported,
                    evidence: .content,
                    reason: "Manifest inspection input exceeds the configured size limit."
                )
            }

            let contentKind = inspectContent(content)
            switch contentKind {
            case .hls:
                return classification(kind: .hls, evidence: .content, reason: "Content contains an HLS playlist marker.")
            case .dash:
                return classification(kind: .dash, evidence: .content, reason: "Content contains a DASH MPD root element.")
            case .conflict:
                return classification(kind: .unsupported, evidence: .conflictingMetadata, reason: "Content contains conflicting HLS and DASH markers.")
            case .none:
                if metadataKind != .unknown {
                    return classification(
                        kind: .unknown,
                        evidence: .insufficient,
                        reason: "Manifest metadata conflicts with the supplied content, which contains no recognized protocol marker."
                    )
                }
                return classification(kind: .unknown, evidence: .insufficient, reason: "Content contains no recognized HLS or DASH marker.")
            }
        }

        switch metadataKind {
        case .hls:
            return classification(kind: .hls, evidence: metadataEvidence(url: url, mimeType: mimeType), reason: "URL or MIME metadata identifies an HLS manifest.")
        case .dash:
            return classification(kind: .dash, evidence: metadataEvidence(url: url, mimeType: mimeType), reason: "URL or MIME metadata identifies a DASH manifest.")
        case .unknown:
            return classification(kind: .unknown, evidence: .insufficient, reason: "No reliable manifest metadata was supplied.")
        case .unsupported:
            return classification(kind: .unsupported, evidence: .conflictingMetadata, reason: "URL extension and MIME type identify different manifest protocols.")
        }
    }

    public static func classify(
        url: URL,
        mimeType: String? = nil,
        content: String,
        limits: ManifestParsingLimits = .default
    ) -> StreamingManifestClassification {
        classify(url: url, mimeType: mimeType, content: Data(content.utf8), limits: limits)
    }

    private enum ContentKind {
        case hls
        case dash
        case conflict
        case none
    }

    private static func classification(
        kind: StreamingManifestKind,
        evidence: ManifestEvidence,
        reason: String
    ) -> StreamingManifestClassification {
        StreamingManifestClassification(kind: kind, evidence: evidence, reason: reason)
    }

    private static func metadataKind(url: URL, mimeType: String?) -> StreamingManifestKind {
        let extensionKind: StreamingManifestKind
        switch url.pathExtension.lowercased() {
        case "m3u8": extensionKind = .hls
        case "mpd": extensionKind = .dash
        default: extensionKind = .unknown
        }

        let cleanMIME = mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let mimeKind: StreamingManifestKind
        if let cleanMIME, hlsMIMETypes.contains(cleanMIME) {
            mimeKind = .hls
        } else if let cleanMIME, dashMIMETypes.contains(cleanMIME) {
            mimeKind = .dash
        } else {
            mimeKind = .unknown
        }

        if extensionKind != .unknown && mimeKind != .unknown && extensionKind != mimeKind {
            return .unsupported
        }
        return extensionKind != .unknown ? extensionKind : mimeKind
    }

    private static func metadataEvidence(url: URL, mimeType: String?) -> ManifestEvidence {
        if let mimeType, !mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = mimeType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            if hlsMIMETypes.contains(clean.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ||
                dashMIMETypes.contains(clean.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                return .mimeType
            }
        }
        return url.pathExtension.isEmpty ? .insufficient : .urlExtension
    }

    private static func inspectContent(_ data: Data) -> ContentKind {
        guard let text = String(data: data, encoding: .utf8) else { return .none }
        let normalized = String(
            text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .drop(while: { $0 == "\u{FEFF}" })
        )
        let lower = normalized.lowercased()
        if lower.hasPrefix("<html") || lower.hasPrefix("<!doctype html") || (lower.hasPrefix("<!doctype") && lower.contains("html")) {
            return .none
        }
        let hls = normalized.hasPrefix("#EXTM3U")
        let dash = normalized.range(of: #"<\s*(?:[A-Za-z_][A-Za-z0-9_.-]*:)?MPD(?:\s|>)"#, options: .regularExpression) != nil
        if hls && dash { return .conflict }
        if hls { return .hls }
        if dash { return .dash }
        return .none
    }
}
