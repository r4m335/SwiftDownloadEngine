import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Comprehensive technical metadata extracted from a media asset.
public struct LIDMediaDetailInfo: Equatable, Sendable {
    public let fileName: String
    public let fileURL: URL
    public let containerFormat: String
    public let fileSizeBytes: Int64
    public let durationSeconds: Double?
    public let bitrateBps: Int64?
    public let videoResolution: String?
    public let videoCodec: String?
    public let frameRateFps: Double?
    public let audioCodec: String?
    public let audioChannels: Int?
    public let audioSampleRateHz: Double?
    public let audioLanguages: [String]
    public let subtitleLanguages: [String]
    public let creationDate: Date?

    public init(
        fileName: String,
        fileURL: URL,
        containerFormat: String,
        fileSizeBytes: Int64,
        durationSeconds: Double? = nil,
        bitrateBps: Int64? = nil,
        videoResolution: String? = nil,
        videoCodec: String? = nil,
        frameRateFps: Double? = nil,
        audioCodec: String? = nil,
        audioChannels: Int? = nil,
        audioSampleRateHz: Double? = nil,
        audioLanguages: [String] = [],
        subtitleLanguages: [String] = [],
        creationDate: Date? = nil
    ) {
        self.fileName = fileName
        self.fileURL = fileURL
        self.containerFormat = containerFormat
        self.fileSizeBytes = fileSizeBytes
        self.durationSeconds = durationSeconds
        self.bitrateBps = bitrateBps
        self.videoResolution = videoResolution
        self.videoCodec = videoCodec
        self.frameRateFps = frameRateFps
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.audioSampleRateHz = audioSampleRateHz
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.creationDate = creationDate
    }

    /// Human-formatted file size string (e.g. "1.24 GB", "45.2 MB").
    public var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    /// Human-formatted duration string (e.g. "01:23:45" or "04:12").
    public var formattedDuration: String {
        guard let dur = durationSeconds, dur > 0 else { return "Unknown" }
        let total = Int(dur)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    /// Human-formatted bitrate string (e.g. "5.4 Mbps").
    public var formattedBitrate: String {
        guard let b = bitrateBps, b > 0 else { return "Unknown" }
        let mbps = Double(b) / 1_000_000.0
        return String(format: "%.2f Mbps", mbps)
    }
}

/// Utility for asynchronously inspecting detailed media metadata from file URLs and AVAssets.
public final class LIDMediaInspector: Sendable {

    public init() {}

    /// Inspects a media file at the given URL.
    public func inspect(url: URL) async -> LIDMediaDetailInfo {
        let name = url.lastPathComponent
        let ext = url.pathExtension.uppercased()
        let container = ext.isEmpty ? "Unknown Container" : "\(ext) Media"

        var size: Int64 = 0
        var created: Date?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            created = attrs[.creationDate] as? Date
        }

        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        var duration: Double? = nil
        let rawDur = asset.duration.seconds
        if rawDur.isFinite && !rawDur.isNaN && rawDur > 0 {
            duration = rawDur
        }

        var resString: String? = nil
        var vCodec: String? = nil
        var fps: Double? = nil
        var vBitrate: Int64? = nil

        var aCodec: String? = nil
        var aChannels: Int? = nil
        var aRate: Double? = nil
        var aLangs: [String] = []
        var subLangs: [String] = []

        // Video Tracks
        let vTracks = asset.tracks(withMediaType: .video)
        if let video = vTracks.first {
            let sz = video.naturalSize
            if sz.width > 0 && sz.height > 0 {
                resString = "\(Int(sz.width)) × \(Int(sz.height))"
            }
            if video.nominalFrameRate > 0 {
                fps = Double(video.nominalFrameRate)
            }
            if video.estimatedDataRate > 0 {
                vBitrate = Int64(video.estimatedDataRate)
            }
            for desc in video.formatDescriptions {
                let formatDesc = desc as! CMFormatDescription
                let subtype = CMFormatDescriptionGetMediaSubType(formatDesc)
                vCodec = fourCCToString(subtype)
            }
        }

        // Audio Tracks
        let aTracks = asset.tracks(withMediaType: .audio)
        for audio in aTracks {
            if let lang = audio.extendedLanguageTag ?? audio.languageCode {
                aLangs.append(lang)
            }
            if aCodec == nil {
                for desc in audio.formatDescriptions {
                    let formatDesc = desc as! CMFormatDescription
                    let subtype = CMFormatDescriptionGetMediaSubType(formatDesc)
                    aCodec = fourCCToString(subtype)
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                        aChannels = Int(asbd.pointee.mChannelsPerFrame)
                        aRate = asbd.pointee.mSampleRate
                    }
                }
            }
        }

        // Subtitle Tracks
        let subTracks = asset.tracks(withMediaType: .subtitle)
        for sub in subTracks {
            if let lang = sub.extendedLanguageTag ?? sub.languageCode {
                subLangs.append(lang)
            }
        }

        return LIDMediaDetailInfo(
            fileName: name,
            fileURL: url,
            containerFormat: container,
            fileSizeBytes: size,
            durationSeconds: duration,
            bitrateBps: vBitrate,
            videoResolution: resString,
            videoCodec: vCodec,
            frameRateFps: fps,
            audioCodec: aCodec,
            audioChannels: aChannels,
            audioSampleRateHz: aRate,
            audioLanguages: aLangs,
            subtitleLanguages: subLangs,
            creationDate: created
        )
        #else
        return LIDMediaDetailInfo(
            fileName: name,
            fileURL: url,
            containerFormat: container,
            fileSizeBytes: size,
            creationDate: created
        )
        #endif
    }

    #if canImport(AVFoundation)
    private func fourCCToString(_ code: FourCharCode) -> String {
        switch code {
        case 0x61766331: return "H.264 / AVC (avc1)"
        case 0x68766331, 0x68657631: return "HEVC / H.265 (hevc)"
        case 0x76703039: return "VP9 (vp09)"
        case 0x61763031: return "AV1 (av01)"
        case 0x6D703461: return "AAC (mp4a)"
        case 0x2E6D7033: return "MP3"
        case 0x666C6163: return "FLAC"
        case 0x6F707573: return "Opus"
        case 0x6C70636D: return "Linear PCM"
        case 0x61632D33: return "AC-3 (Dolby Digital)"
        case 0x65632D33: return "E-AC-3 (Dolby Digital Plus)"
        default:
            let bytes: [CChar] = [
                CChar((code >> 24) & 0xFF),
                CChar((code >> 16) & 0xFF),
                CChar((code >> 8) & 0xFF),
                CChar(code & 0xFF),
                0
            ]
            return String(cString: bytes).trimmingCharacters(in: .whitespaces)
        }
    }
    #endif
}
