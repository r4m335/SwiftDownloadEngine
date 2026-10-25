import Foundation

#if canImport(WebKit)
import WebKit
#endif

// MARK: - Protocol Version

/// Incremented whenever the native <-> JavaScript protocol envelope changes in a
/// way that would cause an old receiver to misinterpret a new sender's messages.
public let BlobCaptureProtocolVersion: Int = 2

// MARK: - Transfer State Machine

/// The authoritative lifecycle of one Blob export transfer.
///
/// Legal transitions:
///   requested -> receivingChunks (after metadata accepted)
///   receivingChunks -> finalizing (on completion message)
///   finalizing -> completed
///   Any non-terminal -> cancelling -> cancelled
///   Any non-terminal -> failed
public enum BlobTransferState: String, Codable, Sendable, Equatable {
    case requested
    case receivingMetadata
    case receivingChunks
    case finalizing
    case completed
    case cancelling
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self { case .completed, .cancelled, .failed: return true; default: return false }
    }
    public var acceptsChunks: Bool { self == .receivingChunks }
    public var acceptsMetadata: Bool { self == .requested || self == .receivingMetadata }
}

// MARK: - Blob Resource Classification

public enum BlobCaptureResourceKind: String, Codable, Sendable, Equatable {
    case completeBlobCandidate
    case streamOrUnknown
    case unavailable
}

// MARK: - Export Limits

public struct BlobExportLimits: Sendable, Equatable {
    public let maximumBytesPerTransfer: Int64
    public let maximumChunkBytes: Int
    public let maximumConcurrentTransfers: Int
    public let maximumInFlightBytes: Int64
    public let maximumStagingBytes: Int64
    public let maximumIdentifierLength: Int
    public let maximumFilenameLength: Int

    public init(
        maximumBytesPerTransfer: Int64 = 512 * 1024 * 1024,
        maximumChunkBytes: Int = 256 * 1024,
        maximumConcurrentTransfers: Int = 1,
        maximumInFlightBytes: Int64 = 512 * 1024,
        maximumStagingBytes: Int64 = 1024 * 1024 * 1024,
        maximumIdentifierLength: Int = 128,
        maximumFilenameLength: Int = 200
    ) {
        self.maximumBytesPerTransfer = max(1, maximumBytesPerTransfer)
        self.maximumChunkBytes = max(1, maximumChunkBytes)
        self.maximumConcurrentTransfers = max(1, maximumConcurrentTransfers)
        self.maximumInFlightBytes = max(Int64(maximumChunkBytes), maximumInFlightBytes)
        self.maximumStagingBytes = max(1, maximumStagingBytes)
        self.maximumIdentifierLength = max(1, maximumIdentifierLength)
        self.maximumFilenameLength = max(1, maximumFilenameLength)
    }

    public static let `default` = BlobExportLimits()
}

// MARK: - Capture Authorization

/// An authorization token issued by the native side before any JS messages are accepted.
/// Binds the transfer to a specific tab, document, and candidate.
public struct BlobCaptureAuthorization: Sendable, Equatable {
    public let transferID: String
    public let tabID: String
    public let documentID: String?
    public let candidateID: String?
    public let suggestedFilename: String?
    public let expiresAt: Date

    public init(
        transferID: String,
        tabID: String,
        documentID: String? = nil,
        candidateID: String? = nil,
        suggestedFilename: String? = nil,
        expiresAt: Date = Date().addingTimeInterval(300)
    ) {
        self.transferID = transferID
        self.tabID = tabID
        self.documentID = documentID
        self.candidateID = candidateID
        self.suggestedFilename = suggestedFilename
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { Date() >= expiresAt }
}

// MARK: - Transfer Record (Persistence / Recovery)

/// Written to disk before I/O begins; updated at checkpoints.
/// On next launch the recovery coordinator reconciles these with staging files.
public struct BlobExportTransferRecord: Codable, Sendable, Equatable {
    public let transferID: String
    public let tabID: String
    public let documentID: String?
    public let stagingURL: URL
    public var finalURL: URL
    public let expectedSize: Int64?
    public var state: BlobTransferState
    public var bytesWritten: Int64
    public var chunksReceived: Int
    public var failureReason: String?
    public var lastCheckpoint: Date

    public init(
        transferID: String,
        tabID: String,
        documentID: String?,
        stagingURL: URL,
        finalURL: URL,
        expectedSize: Int64?,
        state: BlobTransferState = .requested,
        bytesWritten: Int64 = 0,
        chunksReceived: Int = 0,
        failureReason: String? = nil,
        lastCheckpoint: Date = Date()
    ) {
        self.transferID = transferID
        self.tabID = tabID
        self.documentID = documentID
        self.stagingURL = stagingURL
        self.finalURL = finalURL
        self.expectedSize = expectedSize
        self.state = state
        self.bytesWritten = bytesWritten
        self.chunksReceived = chunksReceived
        self.failureReason = failureReason
        self.lastCheckpoint = lastCheckpoint
    }
}

// MARK: - Metadata Envelope

public struct BlobCaptureMetadataEnvelope: Codable, Sendable, Equatable {
    public let transferID: String
    public let documentID: String?
    public let sourceURL: URL
    public let mimeType: String?
    public let declaredSize: Int64?
    public let resourceKind: BlobCaptureResourceKind
    public let readable: Bool

    public init(
        transferID: String,
        documentID: String? = nil,
        sourceURL: URL,
        mimeType: String? = nil,
        declaredSize: Int64? = nil,
        resourceKind: BlobCaptureResourceKind,
        readable: Bool
    ) {
        self.transferID = transferID
        self.documentID = documentID
        self.sourceURL = sourceURL
        self.mimeType = mimeType
        self.declaredSize = declaredSize
        self.resourceKind = resourceKind
        self.readable = readable
    }
}

// MARK: - Transfer Snapshot

public struct BlobExportSnapshot: Sendable, Equatable {
    public let transferID: String
    public let state: BlobTransferState
    public let bytesWritten: Int64
    public let expectedSize: Int64?
    public let chunksReceived: Int
    public let stagingURL: URL?
    public let finalURL: URL?
    /// Whole-file SHA-256 hex digest, available once state == .completed.
    public let outputDigest: String?

    public init(
        transferID: String,
        state: BlobTransferState,
        bytesWritten: Int64,
        expectedSize: Int64?,
        chunksReceived: Int,
        stagingURL: URL? = nil,
        finalURL: URL? = nil,
        outputDigest: String? = nil
    ) {
        self.transferID = transferID
        self.state = state
        self.bytesWritten = bytesWritten
        self.expectedSize = expectedSize
        self.chunksReceived = chunksReceived
        self.stagingURL = stagingURL
        self.finalURL = finalURL
        self.outputDigest = outputDigest
    }

    /// isComplete is true only after atomic rename AND integrity verification.
    public var isComplete: Bool { state == .completed }
    public var isFailed: Bool { state == .failed }
    public var isCancelled: Bool { state == .cancelled || state == .cancelling }
}

// MARK: - Acknowledgement

/// Returned to the JS bridge after each message.
/// `accepted == true` for a chunk means the write and synchronization succeeded.
/// The JS side MUST NOT send the next chunk until this arrives.
public struct BlobCaptureAck: Sendable, Equatable {
    public let transferID: String
    public let accepted: Bool
    public let snapshot: BlobExportSnapshot?
    public let error: BlobExportError?

    public init(
        transferID: String,
        accepted: Bool,
        snapshot: BlobExportSnapshot? = nil,
        error: BlobExportError? = nil
    ) {
        self.transferID = transferID
        self.accepted = accepted
        self.snapshot = snapshot
        self.error = error
    }

    public static func rejected(transferID: String, error: BlobExportError) -> BlobCaptureAck {
        BlobCaptureAck(transferID: transferID, accepted: false, error: error)
    }
}

// MARK: - Errors

public enum BlobExportError: Error, LocalizedError, Codable, Sendable, Equatable {
    case authorizationExpired
    case unknownTransferID
    case documentMismatch
    case tabMismatch
    case captureNotAuthorized
    case unsupportedProtocolVersion(Int)
    case invalidTransferID
    case invalidMessageKind
    case messageOutOfSequence(expected: BlobTransferState, got: String)
    case duplicateTransfer
    case invalidBlobURL
    case unreadableBlob
    case streamingResourceNotSupported
    case invalidDeclaredSize
    case sizeLimitExceeded
    case concurrentTransferLimitExceeded
    case stagingStorageLimitExceeded
    case invalidChunkIndex
    case invalidChunkOffset
    case chunkTooLarge
    case inFlightBytesLimitExceeded
    case invalidChecksum
    case checksumMismatch
    case incompleteTransfer
    case invalidWholeFileDigest
    case wholeFileDigestMismatch
    case fileFormatInvalid
    case invalidFilename
    case destinationCreationFailed
    case stagingCreationFailed
    case writeFailure
    case finalizationFailure
    case diskFull
    case transferAlreadyTerminal
    case cleanupFailed

    public var errorDescription: String? {
        switch self {
        case .authorizationExpired: return "The capture authorization has expired."
        case .unknownTransferID: return "The transfer ID is not recognized."
        case .documentMismatch: return "The message document ID does not match the authorized document."
        case .tabMismatch: return "The message is not from the authorized browser tab."
        case .captureNotAuthorized: return "No capture authorization exists for this transfer."
        case .unsupportedProtocolVersion(let v): return "Protocol version \(v) is not supported."
        case .invalidTransferID: return "The transfer ID is malformed or too long."
        case .invalidMessageKind: return "The message kind is unknown or missing."
        case .messageOutOfSequence(let exp, let got):
            return "Message '\(got)' is not valid in state '\(exp.rawValue)'."
        case .duplicateTransfer: return "A transfer with this ID is already active."
        case .invalidBlobURL: return "The capture source is not a valid blob URL."
        case .unreadableBlob: return "The browser blob is unavailable or cannot be read."
        case .streamingResourceNotSupported: return "Live or MediaSource-backed streams cannot be exported."
        case .invalidDeclaredSize: return "The declared blob size is negative or non-finite."
        case .sizeLimitExceeded: return "The blob exceeds the configured per-transfer size limit."
        case .concurrentTransferLimitExceeded: return "The maximum number of concurrent blob exports has been reached."
        case .stagingStorageLimitExceeded: return "The total staging storage limit has been reached."
        case .invalidChunkIndex: return "The chunk index is out of order."
        case .invalidChunkOffset: return "The chunk byte offset does not match the expected write position."
        case .chunkTooLarge: return "The chunk exceeds the configured maximum chunk size."
        case .inFlightBytesLimitExceeded: return "Too many bytes are in flight; wait for an acknowledgement."
        case .invalidChecksum: return "The chunk checksum is not a valid 64-character hex string."
        case .checksumMismatch: return "The chunk data does not match its declared SHA-256 checksum."
        case .incompleteTransfer: return "Completion was signalled before all declared bytes were received."
        case .invalidWholeFileDigest: return "The supplied whole-file digest is not a 64-character hexadecimal SHA-256 digest."
        case .wholeFileDigestMismatch: return "The finalized file digest does not match the declared digest."
        case .fileFormatInvalid: return "The exported file failed media format validation."
        case .invalidFilename: return "The suggested filename cannot be used."
        case .destinationCreationFailed: return "The export destination directory could not be created."
        case .stagingCreationFailed: return "The staging file could not be created."
        case .writeFailure: return "A chunk could not be written to the staging file."
        case .finalizationFailure: return "The staging file could not be renamed to its final path."
        case .diskFull: return "The device storage is full."
        case .transferAlreadyTerminal: return "The transfer has already completed, failed, or been cancelled."
        case .cleanupFailed: return "The staging file could not be cleaned up."
        }
    }
}
// MARK: - Wire Message

public struct BlobCaptureWireMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case metadata; case chunk; case complete; case failure; case cancel
    }

    public let version: Int?
    public let kind: Kind
    public let transferID: String
    public let tabID: String?
    public let candidateID: String?
    public let documentID: String?
    public let url: String?
    public let mimeType: String?
    public let size: Int64?
    public let readable: Bool?
    public let resourceKind: BlobCaptureResourceKind?
    public let chunkIndex: Int?
    public let offset: Int64?
    public let base64: String?
    public let sha256: String?
    public let reason: String?

    private enum CodingKeys: String, CodingKey {
        case version, kind, type, transferID, captureID, tabID, candidateID, documentID
        case url, mimeType, size, readable, resourceKind
        case chunkIndex, offset, base64, sha256, reason
    }

    public init(
        version: Int? = BlobCaptureProtocolVersion,
        kind: Kind, transferID: String, tabID: String? = nil, candidateID: String? = nil,
        documentID: String? = nil,
        url: String? = nil, mimeType: String? = nil, size: Int64? = nil,
        readable: Bool? = nil, resourceKind: BlobCaptureResourceKind? = nil,
        chunkIndex: Int? = nil, offset: Int64? = nil,
        base64: String? = nil, sha256: String? = nil, reason: String? = nil
    ) {
        self.version = version; self.kind = kind; self.transferID = transferID
        self.tabID = tabID; self.candidateID = candidateID
        self.documentID = documentID; self.url = url; self.mimeType = mimeType
        self.size = size; self.readable = readable; self.resourceKind = resourceKind
        self.chunkIndex = chunkIndex; self.offset = offset; self.base64 = base64
        self.sha256 = sha256; self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        if let k = try c.decodeIfPresent(Kind.self, forKey: .kind) { kind = k }
        else { kind = try c.decode(Kind.self, forKey: .type) }
        if let tid = try c.decodeIfPresent(String.self, forKey: .transferID) { transferID = tid }
        else { transferID = try c.decode(String.self, forKey: .captureID) }
        tabID = try c.decodeIfPresent(String.self, forKey: .tabID)
        candidateID = try c.decodeIfPresent(String.self, forKey: .candidateID)
        documentID = try c.decodeIfPresent(String.self, forKey: .documentID)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        readable = try c.decodeIfPresent(Bool.self, forKey: .readable)
        resourceKind = try c.decodeIfPresent(BlobCaptureResourceKind.self, forKey: .resourceKind)
        chunkIndex = try c.decodeIfPresent(Int.self, forKey: .chunkIndex)
        offset = try c.decodeIfPresent(Int64.self, forKey: .offset)
        base64 = try c.decodeIfPresent(String.self, forKey: .base64)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encode(kind, forKey: .kind)
        try c.encode(transferID, forKey: .transferID)
        try c.encodeIfPresent(tabID, forKey: .tabID)
        try c.encodeIfPresent(candidateID, forKey: .candidateID)
        try c.encodeIfPresent(documentID, forKey: .documentID)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(mimeType, forKey: .mimeType)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(readable, forKey: .readable)
        try c.encodeIfPresent(resourceKind, forKey: .resourceKind)
        try c.encodeIfPresent(chunkIndex, forKey: .chunkIndex)
        try c.encodeIfPresent(offset, forKey: .offset)
        try c.encodeIfPresent(base64, forKey: .base64)
        try c.encodeIfPresent(sha256, forKey: .sha256)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
}

// MARK: - Incremental SHA-256 Hasher

/// Computes SHA-256 incrementally over a stream of chunks without materialising
/// the full file in memory. Each chunk feeds the running digest.
public struct EngineSHA256Hasher {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var pending: [UInt8] = []
    private var byteCount: UInt64 = 0

    public init() {}

    public mutating func update(data: Data) {
        guard !data.isEmpty else { return }
        byteCount += UInt64(data.count)
        pending.append(contentsOf: data)
        while pending.count >= 64 {
            compress(pending, start: 0)
            pending.removeSubrange(0..<64)
        }
    }

    /// Returns lowercase hex SHA-256 and resets the accumulator without
    /// retaining the complete input.
    public mutating func finalize() -> String {
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bitCount = byteCount * 8
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        for start in stride(from: 0, to: tail.count, by: 64) {
            compress(tail, start: start)
        }
        let result = state.map { word in
            let hex = String(word, radix: 16)
            return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
        }.joined()
        self = Self()
        return result
    }

    private mutating func compress(_ block: [UInt8], start: Int) {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
            0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
            0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7,
            0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
            0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
            0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
            0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
            0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
            0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
            0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let index = start + i * 4
            w[i] = (UInt32(block[index]) << 24) | (UInt32(block[index + 1]) << 16) |
                (UInt32(block[index + 2]) << 8) | UInt32(block[index + 3])
        }
        for i in 16..<64 {
            let s0 = (w[i - 15] >> 7 | w[i - 15] << 25) ^ (w[i - 15] >> 18 | w[i - 15] << 14) ^ (w[i - 15] >> 3)
            let s1 = (w[i - 2] >> 17 | w[i - 2] << 15) ^ (w[i - 2] >> 19 | w[i - 2] << 13) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = (e >> 6 | e << 26) ^ (e >> 11 | e << 21) ^ (e >> 25 | e << 7)
            let temp1 = h &+ s1 &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
            let s0 = (a >> 2 | a << 30) ^ (a >> 13 | a << 19) ^ (a >> 22 | a << 10)
            let temp2 = s0 &+ ((a & b) ^ (a & c) ^ (b & c))
            h = g; g = f; f = e; e = d &+ temp1; d = c; c = b; b = a; a = temp1 &+ temp2
        }
        state[0] = state[0] &+ a; state[1] = state[1] &+ b
        state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f
        state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }
}

// MARK: - Blob Export Writer (Production)

/// Owns all file I/O for active Blob export sessions.
///
/// Durability: append() does not return until the chunk is written and the
/// staging file is synchronized. Callers must NOT acknowledge the JS bridge
/// before append() returns successfully.
///
/// Memory: at most limits.maximumChunkBytes are held per chunk. No whole-file
/// buffer is ever created.
public actor BlobExportWriter {

    private struct Session {
        let authorization: BlobCaptureAuthorization
        var record: BlobExportTransferRecord
        let stagingHandle: FileHandle
        var state: BlobTransferState
        var outputHasher: EngineSHA256Hasher
        var reservedStagingBytes: Int64
    }

    private let destinationDirectoryURL: URL
    private let recordDirectoryURL: URL
    private let limits: BlobExportLimits
    private var sessions: [String: Session] = [:]
    private var totalStagingBytes: Int64 = 0

    public init(
        destinationDirectoryURL: URL,
        limits: BlobExportLimits = .default,
        checkpointInterval: Int = 8
    ) {
        self.destinationDirectoryURL = destinationDirectoryURL
        self.recordDirectoryURL = destinationDirectoryURL
            .appendingPathComponent(".transfer-records", isDirectory: true)
        self.limits = limits
        _ = checkpointInterval
    }

    // MARK: Begin

    public func begin(
        authorization: BlobCaptureAuthorization,
        envelope: BlobCaptureMetadataEnvelope,
        suggestedFilename: String
    ) throws -> BlobExportSnapshot {
        guard !authorization.isExpired else { throw BlobExportError.authorizationExpired }
        guard authorization.transferID == envelope.transferID else {
            throw BlobExportError.unknownTransferID
        }
        guard validIdentifier(authorization.transferID),
              authorization.tabID.isEmpty || validIdentifier(authorization.tabID),
              authorization.documentID.map(validIdentifier) ?? true else {
            throw BlobExportError.invalidTransferID
        }
        guard sessions[authorization.transferID] == nil else { throw BlobExportError.duplicateTransfer }
        if let docID = authorization.documentID,
           let envDocID = envelope.documentID,
           docID != envDocID { throw BlobExportError.documentMismatch }
        guard sessions.count < limits.maximumConcurrentTransfers else {
            throw BlobExportError.concurrentTransferLimitExceeded
        }
        guard envelope.readable else { throw BlobExportError.unreadableBlob }
        guard envelope.resourceKind == .completeBlobCandidate else {
            throw BlobExportError.streamingResourceNotSupported
        }
        guard envelope.sourceURL.scheme?.lowercased() == "blob" else {
            throw BlobExportError.invalidBlobURL
        }
        if let sz = envelope.declaredSize {
            guard sz >= 0 else { throw BlobExportError.invalidDeclaredSize }
            guard sz <= limits.maximumBytesPerTransfer else { throw BlobExportError.sizeLimitExceeded }
        }
        let expectedStaging = envelope.declaredSize ?? 0
        guard totalStagingBytes + expectedStaging <= limits.maximumStagingBytes else {
            throw BlobExportError.stagingStorageLimitExceeded
        }

        let safeFilename = try Self.sanitizeFilename(
            suggestedFilename,
            fallback: "blob-export.bin",
            maxLength: limits.maximumFilenameLength
        )
        do {
            try FileManager.default.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: recordDirectoryURL, withIntermediateDirectories: true)
        } catch { throw BlobExportError.destinationCreationFailed }

        let finalURL = Self.uniqueURL(directory: destinationDirectoryURL, filename: safeFilename)
        let stagingURL = destinationDirectoryURL
            .appendingPathComponent(".\(authorization.transferID).blob.part")
        try? FileManager.default.removeItem(at: stagingURL)
        guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil) else {
            throw BlobExportError.stagingCreationFailed
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw BlobExportError.stagingCreationFailed
        }

        let record = BlobExportTransferRecord(
            transferID: authorization.transferID,
            tabID: authorization.tabID,
            documentID: authorization.documentID,
            stagingURL: stagingURL,
            finalURL: finalURL,
            expectedSize: envelope.declaredSize,
            state: .receivingChunks
        )
        persistRecord(record)
        totalStagingBytes += expectedStaging

        sessions[authorization.transferID] = Session(
            authorization: authorization,
            record: record,
            stagingHandle: handle,
            state: .receivingChunks,
            outputHasher: EngineSHA256Hasher(),
            reservedStagingBytes: expectedStaging
        )
        return snapshot(for: record, state: .receivingChunks)
    }

    // MARK: Append

    public func append(
        transferID: String,
        chunkIndex: Int,
        offset: Int64,
        data: Data,
        sha256: String
    ) throws -> BlobExportSnapshot {
        guard var session = sessions[transferID] else { throw BlobExportError.unknownTransferID }
        guard session.state == .receivingChunks else {
            throw BlobExportError.messageOutOfSequence(expected: session.state, got: "chunk")
        }
        guard chunkIndex == session.record.chunksReceived else { throw BlobExportError.invalidChunkIndex }
        guard offset == session.record.bytesWritten else { throw BlobExportError.invalidChunkOffset }
        guard !data.isEmpty, data.count <= limits.maximumChunkBytes else { throw BlobExportError.chunkTooLarge }
        guard session.record.bytesWritten + Int64(data.count) <= limits.maximumBytesPerTransfer else {
            throw BlobExportError.sizeLimitExceeded
        }
        let newBytesWritten = session.record.bytesWritten + Int64(data.count)
        let additionalReservation = max(0, newBytesWritten - session.reservedStagingBytes)
        guard totalStagingBytes + additionalReservation <= limits.maximumStagingBytes else {
            throw BlobExportError.stagingStorageLimitExceeded
        }
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { throw BlobExportError.invalidChecksum }
        guard EngineSHA256.hash(data: data).caseInsensitiveCompare(sha256) == .orderedSame else {
            abort(transferID: transferID, reason: "chunk \(chunkIndex) SHA-256 mismatch")
            throw BlobExportError.checksumMismatch
        }
        do {
            try session.stagingHandle.seek(toOffset: UInt64(offset))
            try session.stagingHandle.write(contentsOf: data)
            try session.stagingHandle.synchronize()
        } catch {
            abort(transferID: transferID, reason: "write failure at chunk \(chunkIndex)")
            throw BlobExportError.writeFailure
        }
        session.outputHasher.update(data: data)
        session.record.bytesWritten += Int64(data.count)
        session.record.chunksReceived += 1
        totalStagingBytes += additionalReservation
        session.reservedStagingBytes += additionalReservation
        session.record.lastCheckpoint = Date()
        persistRecord(session.record)
        sessions[transferID] = session
        return snapshot(for: session.record, state: session.state)
    }

    // MARK: Complete

    public func complete(
        transferID: String,
        finalChunkIndex: Int,
        finalOffset: Int64,
        declaredFileDigest: String? = nil
    ) throws -> BlobExportSnapshot {
        guard var session = sessions[transferID] else { throw BlobExportError.unknownTransferID }
        guard session.state == .receivingChunks else {
            throw BlobExportError.messageOutOfSequence(expected: session.state, got: "complete")
        }
        guard finalChunkIndex == session.record.chunksReceived,
              finalOffset == session.record.bytesWritten else {
            abort(transferID: transferID, reason: "completion offset mismatch")
            throw BlobExportError.incompleteTransfer
        }
        if let expected = session.record.expectedSize,
           expected != session.record.bytesWritten {
            abort(transferID: transferID, reason: "size mismatch expected=\(expected) got=\(session.record.bytesWritten)")
            throw BlobExportError.incompleteTransfer
        }
        session.state = .finalizing
        sessions[transferID] = session
        do {
            try session.stagingHandle.synchronize()
            try session.stagingHandle.close()
        } catch {
            abort(transferID: transferID, reason: "fsync/close failed")
            throw BlobExportError.writeFailure
        }
        let stagingSize = (try? FileManager.default
            .attributesOfItem(atPath: session.record.stagingURL.path))?[.size] as? Int64 ?? -1
        guard stagingSize == session.record.bytesWritten else {
            abort(transferID: transferID, reason: "staging size \(stagingSize) != \(session.record.bytesWritten)")
            throw BlobExportError.incompleteTransfer
        }
        let outputDigest = session.outputHasher.finalize()
        if let declared = declaredFileDigest {
            guard declared.count == 64, declared.allSatisfy(\.isHexDigit) else {
                abort(transferID: transferID, reason: "invalid whole-file digest")
                throw BlobExportError.invalidWholeFileDigest
            }
            guard outputDigest.caseInsensitiveCompare(declared) == .orderedSame else {
                abort(transferID: transferID, reason: "whole-file digest mismatch")
                throw BlobExportError.wholeFileDigestMismatch
            }
        }
        do {
            let targetURL = FileManager.default.fileExists(atPath: session.record.finalURL.path)
                ? Self.uniqueURL(directory: destinationDirectoryURL, filename: session.record.finalURL.lastPathComponent)
                : session.record.finalURL
            try FileManager.default.moveItem(at: session.record.stagingURL, to: targetURL)
            session.record.finalURL = targetURL
        } catch {
            abort(transferID: transferID, reason: "rename failed")
            throw BlobExportError.finalizationFailure
        }
        session.record.state = .completed
        session.record.lastCheckpoint = Date()
        persistRecord(session.record)
        totalStagingBytes -= session.reservedStagingBytes
        sessions.removeValue(forKey: transferID)
        return BlobExportSnapshot(
            transferID: transferID, state: .completed,
            bytesWritten: session.record.bytesWritten,
            expectedSize: session.record.expectedSize,
            chunksReceived: session.record.chunksReceived,
            finalURL: session.record.finalURL,
            outputDigest: outputDigest
        )
    }

    // MARK: Cancel

    public func cancel(transferID: String) {
        guard sessions[transferID] != nil else { return }
        abort(transferID: transferID, reason: "cancelled by native side")
    }

    // MARK: Recovery

    /// Reconciles on-disk transfer records with staging files at app launch.
    public func recoverIncompleteTransfers() -> [BlobExportTransferRecord] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: recordDirectoryURL, includingPropertiesForKeys: nil
        ) else { return [] }
        var recovered: [BlobExportTransferRecord] = []
        for item in items where item.pathExtension == "json" {
            guard let data = try? Data(contentsOf: item),
                  var record = try? JSONDecoder().decode(BlobExportTransferRecord.self, from: data)
            else { continue }
            guard !record.state.isTerminal else {
                removeRecord(for: record.transferID); continue
            }
            if FileManager.default.fileExists(atPath: record.stagingURL.path) {
                let actualSize = (try? FileManager.default
                    .attributesOfItem(atPath: record.stagingURL.path))?[.size] as? Int64 ?? 0
                record.state = .failed
                record.failureReason = "Incomplete transfer recovered at launch (staging \(actualSize) bytes)."
                persistRecord(record)
                try? FileManager.default.removeItem(at: record.stagingURL)
            } else {
                record.state = .failed
                record.failureReason = "Staging file missing at recovery."
                persistRecord(record)
            }
            recovered.append(record)
        }
        return recovered
    }

    // MARK: Private helpers

    private func abort(transferID: String, reason: String) {
        if var session = sessions.removeValue(forKey: transferID) {
            try? session.stagingHandle.close()
            try? FileManager.default.removeItem(at: session.record.stagingURL)
            totalStagingBytes -= session.reservedStagingBytes
            session.record.state = .failed
            session.record.failureReason = reason
            persistRecord(session.record)
        }
    }

    private func persistRecord(_ record: BlobExportTransferRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let url = recordDirectoryURL.appendingPathComponent("\(record.transferID).json")
        try? data.write(to: url, options: .atomic)
    }

    private func removeRecord(for transferID: String) {
        try? FileManager.default.removeItem(
            at: recordDirectoryURL.appendingPathComponent("\(transferID).json")
        )
    }

    private func snapshot(for record: BlobExportTransferRecord, state: BlobTransferState) -> BlobExportSnapshot {
        BlobExportSnapshot(
            transferID: record.transferID, state: state,
            bytesWritten: record.bytesWritten, expectedSize: record.expectedSize,
            chunksReceived: record.chunksReceived,
            stagingURL: state == .completed ? nil : record.stagingURL,
            finalURL: state == .completed ? record.finalURL : nil
        )
    }

    static func sanitizeFilename(_ value: String, fallback: String, maxLength: Int) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        let normalized = source
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let sanitized = String(normalized.unicodeScalars.filter { s in
            !CharacterSet.controlCharacters.contains(s) && s != "\n" && s != "\r"
        })
        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
            throw BlobExportError.invalidFilename
        }
        return String(sanitized.prefix(maxLength))
    }

    static func uniqueURL(directory: URL, filename: String) -> URL {
        let base = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ext = base.pathExtension
        let stem = ext.isEmpty ? base.lastPathComponent
            : String(base.lastPathComponent.dropLast(ext.count + 1))
        for i in 1...10_000 {
            let name = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }

        return directory.appendingPathComponent("blob-\(UUID().uuidString).\(ext.isEmpty ? "bin" : ext)")
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= limits.maximumIdentifierLength &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    var activeSessionCount: Int { sessions.count }
    var activeStagingBytes: Int64 { totalStagingBytes }
}

// MARK: - Blob Capture Receiver (Production)

/// Validates and routes incoming WebKit messages to BlobExportWriter.
/// All authorization checking happens here before the writer sees the message.
public actor BrowserBlobCaptureReceiver {
    private let writer: BlobExportWriter
    private var authorizations: [String: BlobCaptureAuthorization] = [:]

    public init(writer: BlobExportWriter) {
        self.writer = writer
    }

    /// Issues a native authorization before JS is asked to start the transfer.
    public func authorize(
        transferID: String,
        tabID: String,
        documentID: String?,
        candidateID: String?,
        suggestedFilename: String? = nil
    ) {
        let auth = BlobCaptureAuthorization(
            transferID: transferID, tabID: tabID,
            documentID: documentID, candidateID: candidateID,
            suggestedFilename: suggestedFilename
        )
        authorizations[transferID] = auth
    }

    public func cancel(transferID: String) async {
        authorizations.removeValue(forKey: transferID)
        await writer.cancel(transferID: transferID)
    }

    public nonisolated func receive(payload: Any) async -> BlobCaptureAck {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return BlobCaptureAck.rejected(transferID: "", error: .invalidMessageKind)
        }
        return await receive(data: data)
    }

    public func receive(data: Data) async -> BlobCaptureAck {
        var transferID = ""
        do {
            guard let message = try? JSONDecoder().decode(BlobCaptureWireMessage.self, from: data) else {
                return BlobCaptureAck.rejected(transferID: "", error: .invalidMessageKind)
            }
            transferID = message.transferID
            if let v = message.version, v != BlobCaptureProtocolVersion, v != 1 {
                return BlobCaptureAck.rejected(transferID: transferID,
                    error: .unsupportedProtocolVersion(v))
            }
            guard let auth = authorizations[transferID] else {
                return BlobCaptureAck.rejected(transferID: transferID, error: .captureNotAuthorized)
            }
            guard !auth.isExpired else {
                authorizations.removeValue(forKey: transferID)
                await writer.cancel(transferID: transferID)
                return BlobCaptureAck.rejected(transferID: transferID, error: .authorizationExpired)
            }
            if !auth.tabID.isEmpty, message.tabID != auth.tabID {
                authorizations.removeValue(forKey: transferID)
                await writer.cancel(transferID: transferID)
                return BlobCaptureAck.rejected(transferID: transferID, error: .tabMismatch)
            }
            if let authCandidateID = auth.candidateID, message.candidateID != authCandidateID {
                authorizations.removeValue(forKey: transferID)
                await writer.cancel(transferID: transferID)
                return BlobCaptureAck.rejected(transferID: transferID, error: .captureNotAuthorized)
            }
            if let authDocID = auth.documentID, message.documentID != authDocID {
                authorizations.removeValue(forKey: transferID)
                await writer.cancel(transferID: transferID)
                return BlobCaptureAck.rejected(transferID: transferID, error: .documentMismatch)
            }
            switch message.kind {
            case .metadata:
                guard let rawURL = message.url, let sourceURL = URL(string: rawURL),
                      let readable = message.readable, let resourceKind = message.resourceKind else {
                    return BlobCaptureAck.rejected(transferID: transferID, error: .invalidBlobURL)
                }
                let envelope = BlobCaptureMetadataEnvelope(
                    transferID: transferID, documentID: message.documentID,
                    sourceURL: sourceURL, mimeType: message.mimeType,
                    declaredSize: message.size, resourceKind: resourceKind, readable: readable
                )
                let effectiveFilename = auth.suggestedFilename ?? suggestedFilename(mimeType: message.mimeType)
                let snapshot = try await writer.begin(
                    authorization: auth, envelope: envelope,
                    suggestedFilename: effectiveFilename
                )
                return BlobCaptureAck(transferID: transferID, accepted: true, snapshot: snapshot)
            case .chunk:
                guard let index = message.chunkIndex, let offset = message.offset,
                      let b64 = message.base64, let checksum = message.sha256,
                      let chunkData = Data(base64Encoded: b64) else {
                    return BlobCaptureAck.rejected(transferID: transferID, error: .writeFailure)
                }
                let snapshot = try await writer.append(
                    transferID: transferID, chunkIndex: index,
                    offset: offset, data: chunkData, sha256: checksum
                )
                return BlobCaptureAck(transferID: transferID, accepted: true, snapshot: snapshot)
            case .complete:
                guard let index = message.chunkIndex, let offset = message.offset else {
                    return BlobCaptureAck.rejected(transferID: transferID, error: .incompleteTransfer)
                }
                let snapshot = try await writer.complete(
                    transferID: transferID, finalChunkIndex: index,
                    finalOffset: offset, declaredFileDigest: message.sha256
                )
                authorizations.removeValue(forKey: transferID)
                return BlobCaptureAck(transferID: transferID, accepted: true, snapshot: snapshot)
            case .failure, .cancel:
                authorizations.removeValue(forKey: transferID)
                await writer.cancel(transferID: transferID)
                return BlobCaptureAck(transferID: transferID, accepted: true)
            }
        } catch let error as BlobExportError {
            if !transferID.isEmpty {
                authorizations.removeValue(forKey: transferID)
                await writer.cancel(transferID: transferID)
            }
            return BlobCaptureAck.rejected(transferID: transferID, error: error)
        } catch {
            if !transferID.isEmpty {
                authorizations.removeValue(forKey: transferID)
                await writer.cancel(transferID: transferID)
            }
            return BlobCaptureAck.rejected(transferID: transferID, error: .writeFailure)
        }
    }

    private func suggestedFilename(mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "video/mp4": return "captured-blob.mp4"
        case "video/webm": return "captured-blob.webm"
        case "audio/mpeg": return "captured-blob.mp3"
        case "audio/mp4", "audio/x-m4a": return "captured-blob.m4a"
        case "audio/webm": return "captured-blob.webm"
        case "audio/ogg": return "captured-blob.ogg"
        default: return "captured-blob.bin"
        }
    }
}

// MARK: - Top-level Blob Capture Service

/// Coordinates one WebKit session's blob export lifecycle.
/// This is the primary entry point used by BrowserView.
public actor BrowserBlobCaptureService {
    public nonisolated let receiver: BrowserBlobCaptureReceiver
    private let writer: BlobExportWriter

    public init(destinationDirectoryURL: URL, limits: BlobExportLimits = .default) {
        let w = BlobExportWriter(destinationDirectoryURL: destinationDirectoryURL, limits: limits)
        self.writer = w
        self.receiver = BrowserBlobCaptureReceiver(writer: w)
    }

    public func authorize(
        transferID: String,
        tabID: String,
        documentID: String?,
        candidateID: String? = nil,
        suggestedFilename: String? = nil
    ) async {
        await receiver.authorize(
            transferID: transferID,
            tabID: tabID,
            documentID: documentID,
            candidateID: candidateID,
            suggestedFilename: suggestedFilename
        )
    }

    /// Legacy compat: existing BrowserView call sites use register().
    public func register(captureID: String, documentID: String?) async {
        await receiver.authorize(transferID: captureID, tabID: "", documentID: documentID, candidateID: nil)
    }

    public func cancel(captureID: String) async {
        await receiver.cancel(transferID: captureID)
    }

    public func receive(data: Data) async -> BlobCaptureAck {
        await receiver.receive(data: data)
    }

    public nonisolated func receive(payload: Any) async -> BlobCaptureAck {
        await receiver.receive(payload: payload)
    }

    public func recoverIncompleteTransfers() async -> [BlobExportTransferRecord] {
        await writer.recoverIncompleteTransfers()
    }
}

// MARK: - WebKit Handler (Production)

#if canImport(WebKit)
public final class BlobCaptureWebKitHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    public let receiver: BrowserBlobCaptureReceiver
    public var acknowledgementHandler: ((BlobCaptureAck) -> Void)?

    public init(receiver: BrowserBlobCaptureReceiver) {
        self.receiver = receiver
        super.init()
    }

    public func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(source: BlobCaptureBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.add(self, name: BlobCaptureBridge.messageName)
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BlobCaptureBridge.messageName,
              let data = try? JSONSerialization.data(withJSONObject: message.body) else { return }
        let receiver = self.receiver
        let webView = message.webView
        Task { @MainActor [weak webView] in
            let ack = await receiver.receive(data: data)
            self.acknowledgementHandler?(ack)
            if !ack.accepted {
                BrowserDiagnosticLogger.shared.log(
                    category: .blobCapture,
                    message: "Native blob capture receiver rejected message",
                    details: [
                        "transferID": ack.transferID,
                        "error": ack.error?.rawValue ?? "unknown"
                    ]
                )
            } else if ack.snapshot?.isComplete == true {
                BrowserDiagnosticLogger.shared.log(
                    category: .blobCapture,
                    message: "Native blob capture completed successfully",
                    details: [
                        "transferID": ack.transferID,
                        "bytesWritten": "\(ack.snapshot?.bytesWritten ?? 0)"
                    ]
                )
            }
            guard let webView, !ack.transferID.isEmpty else { return }
            _ = try? await webView.evaluateJavaScript(
                BlobCaptureBridge.acknowledgeCommand(transferID: ack.transferID, accepted: ack.accepted)
            )
        }
    }
}

/// Backward-compatible alias so existing BrowserView code compiles unchanged.
#endif

// MARK: - JavaScript Bridge v2

/// Protocol v2 sends:
///   - version: 2 in every message
///   - transferID (falls back to captureID for v1 receivers)
///   - whole-file SHA-256 in the complete message (rolling digest, O(1) heap)
public enum BlobCaptureBridge {
    public static let messageName = "browserBlobCapture"
    public static let maximumChunkBytes = 256 * 1024
    public static let protocolVersion = BlobCaptureProtocolVersion

    // swiftlint:disable line_length
    public static let script = """
(function() {
    "use strict";
    if (window.__lidBlobCapture) { return; }
    var sessions = Object.create(null);
    var MAX_CHUNK_BYTES = 262144;
    var PROTOCOL_VERSION = 2;
    function post(msg) {
        try {
            var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserBlobCapture;
            if (h) { h.postMessage(msg); }
        } catch(_) {}
    }
    function bytesToBase64(bytes) {
        var bin = "";
        for (var off = 0; off < bytes.length; off += 0x8000) {
            bin += String.fromCharCode.apply(null, bytes.subarray(off, Math.min(off + 0x8000, bytes.length)));
        }
        return btoa(bin);
    }
    function digestHex(bytes) {
        if (!window.crypto || !window.crypto.subtle) { return Promise.reject(new Error("SHA-256 unavailable")); }
        var buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        return window.crypto.subtle.digest("SHA-256", buf).then(function(ab) {
            return Array.prototype.map.call(new Uint8Array(ab), function(b) { return b.toString(16).padStart(2,"0"); }).join("");
        });
    }
    function makeRollingDigest() {
        var h=[0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
        var k=[0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
        var pending=new Uint8Array(0), total=0;
        function rotr(x,n){return (x>>>n)|(x<<(32-n));}
        function block(bytes) {
            var w=new Uint32Array(64), i, a,b,c,d,e,f,g,x;
            for(i=0;i<16;i++) w[i]=((bytes[i*4]<<24)|(bytes[i*4+1]<<16)|(bytes[i*4+2]<<8)|bytes[i*4+3])>>>0;
            for(i=16;i<64;i++){var s0=rotr(w[i-15],7)^rotr(w[i-15],18)^(w[i-15]>>>3),s1=rotr(w[i-2],17)^rotr(w[i-2],19)^(w[i-2]>>>10);w[i]=(w[i-16]+s0+w[i-7]+s1)>>>0;}
            a=h[0];b=h[1];c=h[2];d=h[3];e=h[4];f=h[5];g=h[6];x=h[7];
            for(i=0;i<64;i++){var S1=rotr(e,6)^rotr(e,11)^rotr(e,25),t1=(x+S1+((e&f)^(~e&g))+k[i]+w[i])>>>0,S0=rotr(a,2)^rotr(a,13)^rotr(a,22),t2=(S0+((a&b)^(a&c)^(b&c)))>>>0;x=g;g=f;f=e;e=(d+t1)>>>0;d=c;c=b;b=a;a=(t1+t2)>>>0;}
            h[0]=(h[0]+a)>>>0;h[1]=(h[1]+b)>>>0;h[2]=(h[2]+c)>>>0;h[3]=(h[3]+d)>>>0;h[4]=(h[4]+e)>>>0;h[5]=(h[5]+f)>>>0;h[6]=(h[6]+g)>>>0;h[7]=(h[7]+x)>>>0;
        }
        function update(bytes) {
            total+=bytes.length;
            var merged=new Uint8Array(pending.length+bytes.length); merged.set(pending); merged.set(bytes,pending.length);
            var off=0; while(merged.length-off>=64){block(merged.subarray(off,off+64));off+=64;}
            pending=merged.slice(off);
        }
        return {update:update,finalize:function(){
            var pad=new Uint8Array(pending.length+1);pad.set(pending);pad[pending.length]=128;
            var size=pad.length;while(size%64!==56)size++;var tail=new Uint8Array(size+8);tail.set(pad);
            var bits=total*8;for(var j=0;j<8;j++)tail[size+7-j]=bits%256,bits=Math.floor(bits/256);
            for(var off=0;off<tail.length;off+=64)block(tail.subarray(off,off+64));
            var out="";for(var q=0;q<8;q++)out+=("00000000"+h[q].toString(16)).slice(-8);return Promise.resolve(out);
        }};
    }
    function nextBytes(s) {
        if (s.pending && s.pending.length>0) { var p=s.pending; s.pending=null; return Promise.resolve(p); }
        if (s.blob) {
            if (s.offset>=s.size) { return Promise.resolve(null); }
            var end=Math.min(s.offset+s.chunkSize,s.size);
            return s.blob.slice(s.offset,end).arrayBuffer().then(function(ab){return new Uint8Array(ab);});
        }
        return s.reader.read().then(function(r){
            if (r.done){return null;}
            var bytes=r.value||new Uint8Array(0);
            if (bytes.length<=s.chunkSize){return bytes;}
            s.pending=bytes.slice(s.chunkSize); return bytes.slice(0,s.chunkSize);
        });
    }
    function readNext(s) {
        if (s.awaitingAck){return;}
        nextBytes(s).then(function(bytes){
            if (!bytes) {
                return s.rollingDigest.finalize().then(function(digest){
                    post({version:PROTOCOL_VERSION,kind:"complete",transferID:s.transferID,tabID:s.tabID,candidateID:s.candidateID,
                          documentID:s.documentID,chunkIndex:s.chunkIndex,offset:s.offset,
                          sha256:digest||undefined});
                    s.awaitingAck=true;
                });
            }
            if (bytes.length>MAX_CHUNK_BYTES){throw new Error("chunk too large");}
            return digestHex(bytes).then(function(cksum){
                s.rollingDigest.update(bytes);
                post({version:PROTOCOL_VERSION,kind:"chunk",transferID:s.transferID,tabID:s.tabID,candidateID:s.candidateID,
                      documentID:s.documentID,chunkIndex:s.chunkIndex,offset:s.offset,
                      base64:bytesToBase64(bytes),sha256:cksum});
                s.awaitingAck=true; s.chunkIndex+=1; s.offset+=bytes.length;
            });
        }).catch(function(err){
            post({version:PROTOCOL_VERSION,kind:"failure",transferID:s.transferID,
                  reason:String(err&&err.message||err)});
            delete sessions[s.transferID];
        });
    }
    function start(blobURL,transferID,chunkSize,docID,tabID,candidateID) {
        var sz=Math.max(1,Math.min(MAX_CHUNK_BYTES,Number(chunkSize)||MAX_CHUNK_BYTES));
        var reg=window.__lidBlobRegistry||null, entry=null;
        try{entry=reg&&reg[String(blobURL)];}catch(_){}
        var rd=makeRollingDigest();
        if (entry&&entry.kind==="blob"&&entry.blob) {
            var rawSize=(entry.blob&&isFinite(entry.blob.size))?entry.blob.size:entry.size;
            var esz=(rawSize!==null&&rawSize!==undefined&&isFinite(Number(rawSize)))?Math.floor(Number(rawSize)):null;
            if (esz!==null&&esz>=0) {
                sessions[transferID]={transferID:transferID,tabID:tabID,candidateID:candidateID,documentID:docID||entry.documentID||null,
                    blob:entry.blob,size:esz,reader:null,chunkSize:sz,chunkIndex:0,offset:0,
                    pending:null,awaitingAck:true,rollingDigest:rd};
                post({version:PROTOCOL_VERSION,kind:"metadata",transferID:transferID,tabID:tabID,candidateID:candidateID,
                      documentID:docID||entry.documentID||null,url:String(blobURL),
                      mimeType:(entry.blob&&entry.blob.type)||entry.type||null,size:esz,readable:true,resourceKind:"completeBlobCandidate"});
                return;
            }
        }
        fetch(String(blobURL)).then(function(r){
            if (!r.ok){throw new Error("blob not readable");}
            var len=r.headers.get("content-length"),parsed=len===null?null:Number(len);
            var ksz=(isFinite(parsed)&&parsed>=0)?Math.floor(parsed):null;
            var reader=(r.body&&r.body.getReader)?r.body.getReader():null;
            return r.blob().then(function(b){
                var esz=(b&&isFinite(b.size)&&b.size>=0)?Math.floor(b.size):ksz;
                if (esz===null){throw new Error("blob size unavailable");}
                sessions[transferID]={transferID:transferID,tabID:tabID,candidateID:candidateID,documentID:docID||null,
                    blob:b,size:esz,reader:reader,chunkSize:sz,chunkIndex:0,offset:0,
                    pending:null,awaitingAck:true,rollingDigest:rd};
                post({version:PROTOCOL_VERSION,kind:"metadata",transferID:transferID,tabID:tabID,candidateID:candidateID,
                      documentID:docID||null,url:String(blobURL),
                      mimeType:(b&&b.type)||r.headers.get("content-type"),size:esz,readable:true,resourceKind:"completeBlobCandidate"});
            });
        }).catch(function(err){
            post({version:PROTOCOL_VERSION,kind:"failure",transferID:transferID,tabID:tabID,candidateID:candidateID,reason:String(err&&err.message||err)});
        });
    }
    function acknowledge(transferID,accepted) {
        var s=sessions[transferID]; if (!s){return;}
        if (!accepted){if(s.reader){try{s.reader.cancel();}catch(_){}}delete sessions[transferID];return;}
        s.awaitingAck=false; readNext(s);
    }
    function cancel(transferID) {
        var s=sessions[transferID];
        if(s&&s.reader){try{s.reader.cancel();}catch(_){}}
        delete sessions[transferID];
        post({version:PROTOCOL_VERSION,kind:"cancel",transferID:transferID,tabID:s&&s.tabID,candidateID:s&&s.candidateID});
    }
    window.__lidBlobCapture={start:start,acknowledge:acknowledge,cancel:cancel};
})();
"""
    // swiftlint:enable line_length

    public static func startCommand(
        blobURL: URL,
        transferID: String,
        documentID: String? = nil,
        tabID: String? = nil,
        candidateID: String? = nil,
        chunkSize: Int = maximumChunkBytes
    ) -> String {
        let eu = jsString(blobURL.absoluteString)
        let ei = jsString(transferID)
        let ed = documentID.map(jsString) ?? "null"
        let sc = min(maximumChunkBytes, max(1, chunkSize))
        let et = tabID.map(jsString) ?? "null"
        let ec = candidateID.map(jsString) ?? "null"
        return "window.__lidBlobCapture.start(\(eu),\(ei),\(sc),\(ed),\(et),\(ec));"
    }

    public static func acknowledgeCommand(transferID: String, accepted: Bool) -> String {
        "window.__lidBlobCapture.acknowledge(\(jsString(transferID)),\(accepted ? "true" : "false"));"
    }

    public static func cancelCommand(transferID: String) -> String {
        "window.__lidBlobCapture.cancel(\(jsString(transferID)));"
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }
}

// MARK: - Backward compatibility type aliases
// Keep old names so BrowserView and any surviving prototype-era call sites compile
// unchanged while the production rename propagates incrementally.
