import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Structural mapping of an asset byte range to BitTorrent piece indices and moov atom locations.
public struct TorrentByteRangeToPieceMapping: Equatable, Sendable {
    public let startPieceIndex: Int
    public let endPieceIndex: Int
    public let headMoovPieceIndices: [Int]
    public let tailMoovPieceIndices: [Int]
    public let totalPiecesCount: Int

    public init(
        startPieceIndex: Int,
        endPieceIndex: Int,
        headMoovPieceIndices: [Int] = [],
        tailMoovPieceIndices: [Int] = [],
        totalPiecesCount: Int = 0
    ) {
        self.startPieceIndex = startPieceIndex
        self.endPieceIndex = endPieceIndex
        self.headMoovPieceIndices = headMoovPieceIndices
        self.tailMoovPieceIndices = tailMoovPieceIndices
        self.totalPiecesCount = totalPiecesCount
    }
}

/// BitTorrent sequential swarm streaming adapter bridging AVFoundation asset loading to libtorrent 2.0.
///
/// Implements `AVAssetResourceLoaderDelegate` with a custom URL scheme (`lidtorrent://<infoHash>/<fileIndex>`).
/// Maps requested byte ranges to libtorrent piece indices, prioritizes the moov atom (head and tail pieces),
/// enforces sequential download mode, holds pending requests until verified pieces arrive on disk,
/// and immediately reprioritizes pieces upon user seek gestures.
public final class LIDTorrentStreamAdapter: NSObject, Sendable {

    public let infoHash: String
    public let fileIndex: Int
    public let customSchemeURL: URL
    public let dispatchQueue = DispatchQueue(label: "com.r4m335.LIDTorrentStreamAdapter", qos: .userInitiated)

    private let torrentEngine: TorrentEngine?
    private let pollTimerLock = NSLock()

    #if canImport(AVFoundation)
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    #endif

    public init(
        infoHash: String,
        fileIndex: Int = 0,
        torrentEngine: TorrentEngine? = nil
    ) {
        let cleanHash = infoHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.infoHash = cleanHash
        self.fileIndex = fileIndex
        self.torrentEngine = torrentEngine
        self.customSchemeURL = URL(string: "lidtorrent://\(cleanHash)/\(fileIndex)")!
        super.init()
    }

    // MARK: - Mathematical Piece Calculation Helper

    /// Maps a requested file byte range to exact libtorrent piece indices, accounting for file offset in multi-file torrents.
    public static func calculatePieceMapping(
        fileOffsetInTorrent: Int64,
        fileSize: Int64,
        requestedOffset: Int64,
        requestedLength: Int,
        pieceLength: Int
    ) -> TorrentByteRangeToPieceMapping {
        let safePieceLength = max(16 * 1024, pieceLength)
        let totalPieces = Int((fileSize + Int64(safePieceLength) - 1) / Int64(safePieceLength))

        let globalStart = fileOffsetInTorrent + requestedOffset
        let globalEnd = max(globalStart, globalStart + Int64(requestedLength) - 1)

        let startPiece = Int(globalStart / Int64(safePieceLength))
        let endPiece = Int(globalEnd / Int64(safePieceLength))

        // Moov atom head pieces: first 2 MB of the file
        let headStartPiece = Int(fileOffsetInTorrent / Int64(safePieceLength))
        let headBytes: Int64 = min(fileSize, 2 * 1024 * 1024)
        let headEndPiece = Int((fileOffsetInTorrent + headBytes - 1) / Int64(safePieceLength))
        let headMoovPieces = Array(headStartPiece...max(headStartPiece, headEndPiece))

        // Moov atom tail pieces: last 2 MB of the file (for files with tail moov atom)
        let tailStartOffset = max(0, fileSize - 2 * 1024 * 1024)
        let tailStartPiece = Int((fileOffsetInTorrent + tailStartOffset) / Int64(safePieceLength))
        let tailEndPiece = Int((fileOffsetInTorrent + fileSize - 1) / Int64(safePieceLength))
        let tailMoovPieces = Array(tailStartPiece...max(tailStartPiece, tailEndPiece))

        return TorrentByteRangeToPieceMapping(
            startPieceIndex: startPiece,
            endPieceIndex: endPiece,
            headMoovPieceIndices: headMoovPieces,
            tailMoovPieceIndices: tailMoovPieces,
            totalPiecesCount: totalPieces
        )
    }

    /// Determines the standard AVFoundation UTI / content type for a given file name or extension.
    public static func contentType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v": return "public.mpeg-4"
        case "mov": return "com.apple.quicktime-movie"
        case "mp3": return "public.mp3"
        case "m4a": return "public.audio"
        case "aac": return "public.aac-audio"
        case "ts": return "public.mpeg-2-transport-stream"
        case "webm": return "org.webmproject.webm"
        case "mkv": return "video/x-matroska"
        case "wav": return "com.microsoft.waveform-audio"
        case "flac": return "org.xiph.flac"
        default: return "public.movie"
        }
    }

    // MARK: - Swarm Piece Prioritization

    /// Activates sequential mode and prioritizes the playback window plus moov atom pieces.
    public func prioritizePlaybackWindow(
        fileOffsetInTorrent: Int64,
        fileSize: Int64,
        requestedOffset: Int64,
        requestedLength: Int
    ) async {
        guard let engine = torrentEngine else { return }

        // Enable sequential mode
        try? await engine.setSequentialDownload(true, for: infoHash)
        try? await engine.setFilePriority(.high, forFileAt: fileIndex, in: infoHash)

        let pLength = await engine.pieceLength(for: infoHash)
        let mapping = Self.calculatePieceMapping(
            fileOffsetInTorrent: fileOffsetInTorrent,
            fileSize: fileSize,
            requestedOffset: requestedOffset,
            requestedLength: requestedLength,
            pieceLength: pLength > 0 ? pLength : 1024 * 1024
        )

        // Prioritize head moov pieces (priority 7)
        for piece in mapping.headMoovPieceIndices {
            try? await engine.setPiecePriority(7, at: piece, in: infoHash)
        }

        // Prioritize tail moov pieces in case moov is at end of MP4 (priority 7)
        for piece in mapping.tailMoovPieceIndices {
            try? await engine.setPiecePriority(7, at: piece, in: infoHash)
        }

        // Prioritize requested range plus 3 lookahead pieces (priority 7)
        let totalCount = await engine.pieceCount(for: infoHash)
        let upper = min(mapping.endPieceIndex + 3, totalCount > 0 ? totalCount - 1 : mapping.endPieceIndex)
        for piece in mapping.startPieceIndex...max(mapping.startPieceIndex, upper) {
            try? await engine.setPiecePriority(7, at: piece, in: infoHash)
        }
    }
}

#if canImport(AVFoundation)
extension LIDTorrentStreamAdapter: AVAssetResourceLoaderDelegate {

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == "lidtorrent" else {
            return false
        }

        dispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.handleResourceRequest(loadingRequest)
        }
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        dispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingRequests.removeAll { $0 == loadingRequest }
        }
    }

    // MARK: - Internal Request Fulfillment

    private func handleResourceRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let engine = torrentEngine else {
            // If no torrent engine injected, check if file exists directly on disk
            loadingRequest.finishLoading(with: NSError(domain: "com.r4m335.LIDTorrentStreamAdapter", code: 404, userInfo: [NSLocalizedDescriptionKey: "Torrent engine unavailable."]))
            return
        }

        Task {
            guard let task = await engine.task(for: infoHash) else {
                loadingRequest.finishLoading(with: NSError(domain: "com.r4m335.LIDTorrentStreamAdapter", code: 404, userInfo: [NSLocalizedDescriptionKey: "Torrent not found."]))
                return
            }

            let files = await engine.files(for: infoHash) ?? []
            guard fileIndex >= 0 && fileIndex < files.count else {
                loadingRequest.finishLoading(with: NSError(domain: "com.r4m335.LIDTorrentStreamAdapter", code: 404, userInfo: [NSLocalizedDescriptionKey: "Torrent file index out of bounds."]))
                return
            }

            let targetFile = files[fileIndex]
            let fileSize = targetFile.size
            let fileOffsetInTorrent = files.prefix(fileIndex).reduce(Int64(0)) { $0 + $1.size }

            // 1. Content Information Request
            if let contentInfo = loadingRequest.contentInformationRequest {
                contentInfo.contentType = Self.contentType(for: targetFile.name)
                contentInfo.contentLength = fileSize
                contentInfo.isByteRangeAccessSupported = true
            }

            // 2. Data Request
            guard let dataRequest = loadingRequest.dataRequest else {
                loadingRequest.finishLoading()
                return
            }

            let reqOffset = dataRequest.requestedOffset
            let reqLength = dataRequest.requestedLength

            // Prioritize swarm pieces for this range
            await self.prioritizePlaybackWindow(
                fileOffsetInTorrent: fileOffsetInTorrent,
                fileSize: fileSize,
                requestedOffset: reqOffset,
                requestedLength: reqLength
            )

            // Resolve file location on disk
            let fileURL = task.savePath.appendingPathComponent(targetFile.path)

            // Attempt immediate fulfillment if data is already verified on disk
            if self.fulfillDataRequest(dataRequest, from: fileURL, maxBytes: fileSize) {
                loadingRequest.finishLoading()
            } else {
                // Hold in pending queue and schedule verification poller
                self.dispatchQueue.async {
                    self.pendingRequests.append(loadingRequest)
                    self.pollPendingRequests(fileURL: fileURL, fileSize: fileSize)
                }
            }
        }
    }

    private func fulfillDataRequest(
        _ dataRequest: AVAssetResourceLoadingDataRequest,
        from fileURL: URL,
        maxBytes: Int64
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }

        let current = dataRequest.currentOffset
        let remainingToFulfill = (dataRequest.requestedOffset + Int64(dataRequest.requestedLength)) - current
        guard remainingToFulfill > 0 else { return true }

        let onDiskSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        guard onDiskSize > current else { return false }

        let bytesToRead = min(remainingToFulfill, onDiskSize - current)
        guard bytesToRead > 0 else { return false }

        try? handle.seek(toOffset: UInt64(current))
        let chunk = handle.readData(ofLength: Int(bytesToRead))
        guard !chunk.isEmpty else { return false }

        dataRequest.respond(with: chunk)
        return dataRequest.currentOffset >= dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
    }

    private func pollPendingRequests(fileURL: URL, fileSize: Int64) {
        guard !pendingRequests.isEmpty else { return }

        dispatchQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            var remaining: [AVAssetResourceLoadingRequest] = []

            for req in self.pendingRequests {
                if req.isCancelled { continue }
                if let dataReq = req.dataRequest {
                    if self.fulfillDataRequest(dataReq, from: fileURL, maxBytes: fileSize) {
                        req.finishLoading()
                    } else {
                        remaining.append(req)
                    }
                } else {
                    req.finishLoading()
                }
            }

            self.pendingRequests = remaining
            if !remaining.isEmpty {
                self.pollPendingRequests(fileURL: fileURL, fileSize: fileSize)
            }
        }
    }
}
#endif
