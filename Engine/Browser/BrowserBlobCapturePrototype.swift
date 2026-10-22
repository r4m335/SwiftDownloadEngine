import Foundation

#if canImport(WebKit)
import WebKit
#endif

/// The conservative classification produced by the prototype inspection step.
/// A readable stream without a stable size is not exported as a completed blob;
/// it may be a MediaSource-backed stream and must go through manifest discovery.
public enum BrowserBlobCaptureResourceKind: String, Codable, Sendable, Equatable {
    case completeBlobCandidate
    case streamOrUnknown
    case unavailable
}

public struct BrowserBlobCaptureLimits: Sendable, Equatable {
    public let maximumBytes: Int64
    public let maximumChunkBytes: Int
    public let maximumIdentifierLength: Int

    public init(
        maximumBytes: Int64 = 512 * 1024 * 1024,
        maximumChunkBytes: Int = 256 * 1024,
        maximumIdentifierLength: Int = 128
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.maximumChunkBytes = max(1, maximumChunkBytes)
        self.maximumIdentifierLength = max(1, maximumIdentifierLength)
    }

    public static let `default` = BrowserBlobCaptureLimits()
}

public struct BrowserBlobCaptureMetadata: Codable, Sendable, Equatable {
    public let captureID: String
    public let sourceURL: URL
    public let mimeType: String?
    public let expectedSize: Int64?
    public let kind: BrowserBlobCaptureResourceKind
    public let readable: Bool

    public init(
        captureID: String,
        sourceURL: URL,
        mimeType: String? = nil,
        expectedSize: Int64? = nil,
        kind: BrowserBlobCaptureResourceKind,
        readable: Bool
    ) {
        self.captureID = captureID
        self.sourceURL = sourceURL
        self.mimeType = mimeType
        self.expectedSize = expectedSize
        self.kind = kind
        self.readable = readable
    }
}

public struct BrowserBlobCaptureSnapshot: Sendable, Equatable {
    public let captureID: String
    public let bytesWritten: Int64
    public let expectedSize: Int64?
    public let chunkIndex: Int
    public let isComplete: Bool
    public let temporaryURL: URL?
    public let finalURL: URL?

    public init(
        captureID: String,
        bytesWritten: Int64,
        expectedSize: Int64?,
        chunkIndex: Int,
        isComplete: Bool,
        temporaryURL: URL? = nil,
        finalURL: URL? = nil
    ) {
        self.captureID = captureID
        self.bytesWritten = bytesWritten
        self.expectedSize = expectedSize
        self.chunkIndex = chunkIndex
        self.isComplete = isComplete
        self.temporaryURL = temporaryURL
        self.finalURL = finalURL
    }
}

public enum BrowserBlobCapturePrototypeError: Error, LocalizedError, Sendable, Equatable {
    case invalidCaptureID
    case invalidBlobURL
    case unreadableBlob
    case incompleteOrStreamingResource
    case invalidExpectedSize
    case sizeLimitExceeded
    case invalidChunkSize
    case unknownCapture
    case captureAlreadyComplete
    case invalidChunkIndex
    case invalidChunkOffset
    case chunkTooLarge
    case invalidChecksum
    case checksumMismatch
    case incompleteCapture
    case invalidFilename
    case fileOperationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidCaptureID: return "The blob capture identifier is invalid."
        case .invalidBlobURL: return "The capture source is not a valid blob URL."
        case .unreadableBlob: return "The browser blob is unavailable or cannot be read."
        case .incompleteOrStreamingResource: return "The resource may be a live or MediaSource-backed stream and cannot be exported as a complete blob."
        case .invalidExpectedSize: return "The browser reported an invalid blob size."
        case .sizeLimitExceeded: return "The blob exceeds the configured capture size limit."
        case .invalidChunkSize: return "The blob chunk size is invalid."
        case .unknownCapture: return "The blob capture session is no longer available."
        case .captureAlreadyComplete: return "The blob capture has already completed."
        case .invalidChunkIndex: return "The blob chunk index is out of order."
        case .invalidChunkOffset: return "The blob chunk offset is invalid."
        case .chunkTooLarge: return "The blob chunk exceeds the configured bound."
        case .invalidChecksum: return "The blob chunk checksum is invalid."
        case .checksumMismatch: return "The blob chunk failed integrity verification."
        case .incompleteCapture: return "The blob capture ended before the expected size was received."
        case .invalidFilename: return "The blob output filename is invalid."
        case .fileOperationFailed: return "The temporary blob output could not be written or finalized."
        }
    }
}

/// A deterministic native receiver for the prototype chunk protocol. It owns
/// only temporary file handles and never creates a download-history record.
public actor BrowserBlobCapturePrototypeWriter {
    private struct Session {
        let metadata: BrowserBlobCaptureMetadata
        let temporaryURL: URL
        let finalURL: URL
        let handle: FileHandle
        var bytesWritten: Int64
        var nextChunkIndex: Int
    }

    private let destinationDirectoryURL: URL
    private let limits: BrowserBlobCaptureLimits
    private var sessions: [String: Session] = [:]

    public init(
        destinationDirectoryURL: URL,
        limits: BrowserBlobCaptureLimits = .default
    ) {
        self.destinationDirectoryURL = destinationDirectoryURL
        self.limits = limits
    }

    public func begin(
        metadata: BrowserBlobCaptureMetadata,
        filename: String
    ) throws -> BrowserBlobCaptureSnapshot {
        guard validCaptureID(metadata.captureID) else {
            throw BrowserBlobCapturePrototypeError.invalidCaptureID
        }
        guard metadata.sourceURL.scheme?.lowercased() == "blob" else {
            throw BrowserBlobCapturePrototypeError.invalidBlobURL
        }
        guard metadata.readable else {
            throw BrowserBlobCapturePrototypeError.unreadableBlob
        }
        guard metadata.kind == .completeBlobCandidate else {
            throw BrowserBlobCapturePrototypeError.incompleteOrStreamingResource
        }
        if let expectedSize = metadata.expectedSize {
            guard expectedSize >= 0 else { throw BrowserBlobCapturePrototypeError.invalidExpectedSize }
            guard expectedSize <= limits.maximumBytes else {
                throw BrowserBlobCapturePrototypeError.sizeLimitExceeded
            }
        }
        guard !sessions.keys.contains(metadata.captureID) else {
            throw BrowserBlobCapturePrototypeError.captureAlreadyComplete
        }

        let safeFilename = try Self.sanitizeFilename(filename, fallback: "blob-\(metadata.captureID).bin")
        do {
            try FileManager.default.createDirectory(
                at: destinationDirectoryURL,
                withIntermediateDirectories: true
            )
            let finalURL = Self.uniqueURL(
                directory: destinationDirectoryURL,
                filename: safeFilename
            )
            let temporaryURL = destinationDirectoryURL.appendingPathComponent(".\(metadata.captureID).blob.part")
            try? FileManager.default.removeItem(at: temporaryURL)
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw BrowserBlobCapturePrototypeError.fileOperationFailed
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            sessions[metadata.captureID] = Session(
                metadata: metadata,
                temporaryURL: temporaryURL,
                finalURL: finalURL,
                handle: handle,
                bytesWritten: 0,
                nextChunkIndex: 0
            )
            return BrowserBlobCaptureSnapshot(
                captureID: metadata.captureID,
                bytesWritten: 0,
                expectedSize: metadata.expectedSize,
                chunkIndex: -1,
                isComplete: false,
                temporaryURL: temporaryURL
            )
        } catch let error as BrowserBlobCapturePrototypeError {
            throw error
        } catch {
            throw BrowserBlobCapturePrototypeError.fileOperationFailed
        }
    }

    public func append(
        captureID: String,
        chunkIndex: Int,
        offset: Int64,
        data: Data,
        sha256: String
    ) throws -> BrowserBlobCaptureSnapshot {
        guard var session = sessions[captureID] else {
            throw BrowserBlobCapturePrototypeError.unknownCapture
        }
        do {
            guard chunkIndex == session.nextChunkIndex else {
                throw BrowserBlobCapturePrototypeError.invalidChunkIndex
            }
            guard offset == session.bytesWritten else {
                throw BrowserBlobCapturePrototypeError.invalidChunkOffset
            }
            guard !data.isEmpty, data.count <= limits.maximumChunkBytes else {
                throw BrowserBlobCapturePrototypeError.chunkTooLarge
            }
            guard session.bytesWritten <= limits.maximumBytes - Int64(data.count) else {
                throw BrowserBlobCapturePrototypeError.sizeLimitExceeded
            }
            guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
                throw BrowserBlobCapturePrototypeError.invalidChecksum
            }
            guard EngineSHA256.hash(data: data).caseInsensitiveCompare(sha256) == .orderedSame else {
                throw BrowserBlobCapturePrototypeError.checksumMismatch
            }

            try session.handle.seek(toOffset: UInt64(offset))
            try session.handle.write(contentsOf: data)
            session.bytesWritten += Int64(data.count)
            session.nextChunkIndex += 1
            sessions[captureID] = session
            return BrowserBlobCaptureSnapshot(
                captureID: captureID,
                bytesWritten: session.bytesWritten,
                expectedSize: session.metadata.expectedSize,
                chunkIndex: chunkIndex,
                isComplete: false,
                temporaryURL: session.temporaryURL
            )
        } catch let error as BrowserBlobCapturePrototypeError {
            abort(captureID: captureID, session: session)
            throw error
        } catch {
            abort(captureID: captureID, session: session)
            throw BrowserBlobCapturePrototypeError.fileOperationFailed
        }
    }

    public func complete(
        captureID: String,
        finalChunkIndex: Int,
        finalOffset: Int64
    ) throws -> BrowserBlobCaptureSnapshot {
        guard let session = sessions.removeValue(forKey: captureID) else {
            throw BrowserBlobCapturePrototypeError.unknownCapture
        }
        do {
            guard finalChunkIndex == session.nextChunkIndex,
                  finalOffset == session.bytesWritten else {
                throw BrowserBlobCapturePrototypeError.invalidChunkOffset
            }
            if let expectedSize = session.metadata.expectedSize,
               expectedSize != session.bytesWritten {
                throw BrowserBlobCapturePrototypeError.incompleteCapture
            }
            try session.handle.synchronize()
            try session.handle.close()
            try FileManager.default.moveItem(at: session.temporaryURL, to: session.finalURL)
            return BrowserBlobCaptureSnapshot(
                captureID: captureID,
                bytesWritten: session.bytesWritten,
                expectedSize: session.metadata.expectedSize,
                chunkIndex: finalChunkIndex,
                isComplete: true,
                finalURL: session.finalURL
            )
        } catch let error as BrowserBlobCapturePrototypeError {
            abort(captureID: captureID, session: session)
            throw error
        } catch {
            abort(captureID: captureID, session: session)
            throw BrowserBlobCapturePrototypeError.fileOperationFailed
        }
    }

    public func cancel(captureID: String) {
        guard let session = sessions.removeValue(forKey: captureID) else { return }
        abort(captureID: captureID, session: session)
    }

    private func validCaptureID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= limits.maximumIdentifierLength &&
            value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func abort(captureID: String, session: Session) {
        try? session.handle.close()
        try? FileManager.default.removeItem(at: session.temporaryURL)
        sessions.removeValue(forKey: captureID)
    }

    private static func sanitizeFilename(_ value: String, fallback: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        let sanitized = String(Array(
            source
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
        ).filter { !$0.isNewline && !$0.isControl })
        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
            throw BrowserBlobCapturePrototypeError.invalidFilename
        }
        return String(sanitized.prefix(160))
    }

    private static func uniqueURL(directory: URL, filename: String) -> URL {
        let base = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ext = base.pathExtension
        let stem = ext.isEmpty ? base.lastPathComponent : String(base.lastPathComponent.dropLast(ext.count + 1))
        for index in 1...10_000 {
            let candidateName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("blob-\(UUID().uuidString).\(ext.isEmpty ? "bin" : ext)")
    }
}

/// Messages exchanged by the prototype WebKit bridge. Chunk payloads are
/// Base64 encoded individually; the complete blob is never Base64 encoded.
public struct BrowserBlobCapturePrototypeMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case metadata
        case chunk
        case complete
        case failure
        case cancel
    }

    public let kind: Kind
    public let captureID: String
    public let url: String?
    public let mimeType: String?
    public let size: Int64?
    public let readable: Bool?
    public let resourceKind: BrowserBlobCaptureResourceKind?
    public let chunkIndex: Int?
    public let offset: Int64?
    public let base64: String?
    public let sha256: String?
    public let reason: String?

    public init(
        kind: Kind,
        captureID: String,
        url: String? = nil,
        mimeType: String? = nil,
        size: Int64? = nil,
        readable: Bool? = nil,
        resourceKind: BrowserBlobCaptureResourceKind? = nil,
        chunkIndex: Int? = nil,
        offset: Int64? = nil,
        base64: String? = nil,
        sha256: String? = nil,
        reason: String? = nil
    ) {
        self.kind = kind
        self.captureID = captureID
        self.url = url
        self.mimeType = mimeType
        self.size = size
        self.readable = readable
        self.resourceKind = resourceKind
        self.chunkIndex = chunkIndex
        self.offset = offset
        self.base64 = base64
        self.sha256 = sha256
        self.reason = reason
    }
}

public struct BrowserBlobCapturePrototypeAck: Sendable, Equatable {
    public let captureID: String
    public let accepted: Bool
    public let snapshot: BrowserBlobCaptureSnapshot?
    public let error: BrowserBlobCapturePrototypeError?

    public init(
        captureID: String,
        accepted: Bool,
        snapshot: BrowserBlobCaptureSnapshot? = nil,
        error: BrowserBlobCapturePrototypeError? = nil
    ) {
        self.captureID = captureID
        self.accepted = accepted
        self.snapshot = snapshot
        self.error = error
    }
}

/// Platform-neutral message receiver used by tests and by the future WKWebView
/// adapter. It decodes and validates the same envelopes that WebKit emits.
public actor BrowserBlobCapturePrototypeReceiver {
    private let writer: BrowserBlobCapturePrototypeWriter

    public init(writer: BrowserBlobCapturePrototypeWriter) {
        self.writer = writer
    }

    public nonisolated func receive(payload: Any) async -> BrowserBlobCapturePrototypeAck {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return BrowserBlobCapturePrototypeAck(
                captureID: "",
                accepted: false,
                error: .fileOperationFailed
            )
        }
        return await receive(data: data)
    }

    public func receive(data: Data) async -> BrowserBlobCapturePrototypeAck {
        var captureID = ""
        do {
            guard let message = try? JSONDecoder().decode(BrowserBlobCapturePrototypeMessage.self, from: data) else {
                throw BrowserBlobCapturePrototypeError.fileOperationFailed
            }
            captureID = message.captureID
            switch message.kind {
            case .metadata:
                guard let rawURL = message.url,
                      let url = URL(string: rawURL),
                      let resourceKind = message.resourceKind,
                      let readable = message.readable else {
                    throw BrowserBlobCapturePrototypeError.invalidBlobURL
                }
                let metadata = BrowserBlobCaptureMetadata(
                    captureID: message.captureID,
                    sourceURL: url,
                    mimeType: message.mimeType,
                    expectedSize: message.size,
                    kind: resourceKind,
                    readable: readable
                )
                let snapshot = try await writer.begin(metadata: metadata, filename: suggestedFilename(mimeType: message.mimeType))
                return BrowserBlobCapturePrototypeAck(captureID: message.captureID, accepted: true, snapshot: snapshot)
            case .chunk:
                guard let index = message.chunkIndex,
                      let offset = message.offset,
                      let base64 = message.base64,
                      let checksum = message.sha256,
                      let data = Data(base64Encoded: base64) else {
                    throw BrowserBlobCapturePrototypeError.fileOperationFailed
                }
                let snapshot = try await writer.append(
                    captureID: message.captureID,
                    chunkIndex: index,
                    offset: offset,
                    data: data,
                    sha256: checksum
                )
                return BrowserBlobCapturePrototypeAck(captureID: message.captureID, accepted: true, snapshot: snapshot)
            case .complete:
                guard let index = message.chunkIndex, let offset = message.offset else {
                    throw BrowserBlobCapturePrototypeError.incompleteCapture
                }
                let snapshot = try await writer.complete(
                    captureID: message.captureID,
                    finalChunkIndex: index,
                    finalOffset: offset
                )
                return BrowserBlobCapturePrototypeAck(captureID: message.captureID, accepted: true, snapshot: snapshot)
            case .failure, .cancel:
                await writer.cancel(captureID: message.captureID)
                return BrowserBlobCapturePrototypeAck(captureID: message.captureID, accepted: true)
            }
        } catch let error as BrowserBlobCapturePrototypeError {
            return BrowserBlobCapturePrototypeAck(captureID: captureID, accepted: false, error: error)
        } catch {
            return BrowserBlobCapturePrototypeAck(captureID: captureID, accepted: false, error: .fileOperationFailed)
        }
    }

    private func suggestedFilename(mimeType: String?) -> String {
        let ext: String
        switch mimeType?.lowercased() {
        case "video/mp4": ext = "mp4"
        case "video/webm": ext = "webm"
        case "audio/mpeg": ext = "mp3"
        case "audio/mp4": ext = "m4a"
        case "audio/webm": ext = "webm"
        default: ext = "bin"
        }
        return "captured-blob.\(ext)"
    }
}

#if canImport(WebKit)
/// Thin WKWebView adapter for the prototype. It keeps the WebKit callback
/// responsible for JavaScript acknowledgement while the actor owns all file
/// writes and protocol validation.
public final class BrowserBlobCapturePrototypeWebKitHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    public let receiver: BrowserBlobCapturePrototypeReceiver

    public init(receiver: BrowserBlobCapturePrototypeReceiver) {
        self.receiver = receiver
        super.init()
    }

    public func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrowserBlobCapturePrototypeBridge.script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.add(self, name: BrowserBlobCapturePrototypeBridge.messageName)
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BrowserBlobCapturePrototypeBridge.messageName,
              let data = try? JSONSerialization.data(withJSONObject: message.body) else {
            return
        }
        let receiver = self.receiver
        let webView = message.webView
        Task { @MainActor [weak webView] in
            let acknowledgement = await receiver.receive(data: data)
            guard let webView,
                  !acknowledgement.captureID.isEmpty else { return }
            _ = try? await webView.evaluateJavaScript(
                BrowserBlobCapturePrototypeBridge.acknowledgeCommand(
                    captureID: acknowledgement.captureID,
                    accepted: acknowledgement.accepted
                )
            )
        }
    }
}
#endif

/// The prototype script uses a ReadableStream and waits for a native
/// acknowledgement after every bounded chunk. It deliberately does not call
/// `response.blob()`, `FileReader`, or build a whole-file Base64 string.
public enum BrowserBlobCapturePrototypeBridge {
    public static let messageName = "browserBlobCapture"
    public static let maximumChunkBytes = 256 * 1024

    public static let script = #"""
    (function() {
        "use strict";
        if (window.__lidBlobCapture) { return; }

        var sessions = Object.create(null);
        var MAX_CHUNK_BYTES = 262144;

        function post(message) {
            try {
                var handler = window.webkit && window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.browserBlobCapture;
                if (handler) { handler.postMessage(message); }
            } catch (_) {}
        }

        function bytesToBase64(bytes) {
            var binary = "";
            for (var offset = 0; offset < bytes.length; offset += 0x8000) {
                binary += String.fromCharCode.apply(null, bytes.subarray(offset, Math.min(offset + 0x8000, bytes.length)));
            }
            return btoa(binary);
        }

        function digestHex(bytes) {
            if (!window.crypto || !window.crypto.subtle) { return Promise.reject(new Error("SHA-256 is unavailable")); }
            var exactBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
            return window.crypto.subtle.digest("SHA-256", exactBuffer).then(function(buffer) {
                return Array.prototype.map.call(new Uint8Array(buffer), function(value) {
                    return value.toString(16).padStart(2, "0");
                }).join("");
            });
        }

        function nextBytes(session) {
            if (session.pending && session.pending.length > 0) {
                var pending = session.pending;
                session.pending = null;
                return Promise.resolve(pending);
            }
            return session.reader.read().then(function(result) {
                if (result.done) { return null; }
                var bytes = result.value || new Uint8Array(0);
                if (bytes.length <= session.chunkSize) { return bytes; }
                session.pending = bytes.slice(session.chunkSize);
                return bytes.slice(0, session.chunkSize);
            });
        }

        function readNext(session) {
            if (session.awaitingAck) { return; }
            nextBytes(session).then(function(bytes) {
                if (!bytes) {
                    post({ type: "complete", captureID: session.captureID, chunkIndex: session.chunkIndex, offset: session.offset });
                    session.awaitingAck = true;
                    return;
                }
                if (bytes.length > MAX_CHUNK_BYTES) { throw new Error("chunk exceeds safety limit"); }
                return digestHex(bytes).then(function(checksum) {
                    post({
                        type: "chunk",
                        captureID: session.captureID,
                        chunkIndex: session.chunkIndex,
                        offset: session.offset,
                        base64: bytesToBase64(bytes),
                        sha256: checksum
                    });
                    session.awaitingAck = true;
                    session.chunkIndex += 1;
                    session.offset += bytes.length;
                });
            }).catch(function(error) {
                post({ type: "failure", captureID: session.captureID, reason: String(error && error.message || error) });
                delete sessions[session.captureID];
            });
        }

        function start(blobURL, captureID, requestedChunkSize) {
            var chunkSize = Math.max(1, Math.min(MAX_CHUNK_BYTES, Number(requestedChunkSize) || MAX_CHUNK_BYTES));
            fetch(String(blobURL)).then(function(response) {
                if (!response.ok || !response.body || !response.body.getReader) {
                    throw new Error("blob response is not readable");
                }
                var lengthHeader = response.headers.get("content-length");
                var parsedLength = lengthHeader === null ? null : Number(lengthHeader);
                var knownSize = isFinite(parsedLength) && parsedLength >= 0 ? Math.floor(parsedLength) : null;
                var kind = knownSize === null ? "streamOrUnknown" : "completeBlobCandidate";
                sessions[captureID] = {
                    captureID: captureID,
                    reader: response.body.getReader(),
                    chunkSize: chunkSize,
                    chunkIndex: 0,
                    offset: 0,
                    pending: null,
                    awaitingAck: true
                };
                post({
                    type: "metadata",
                    captureID: captureID,
                    url: String(blobURL),
                    mimeType: response.headers.get("content-type"),
                    size: knownSize,
                    readable: true,
                    resourceKind: kind
                });
            }).catch(function(error) {
                post({ type: "failure", captureID: captureID, reason: String(error && error.message || error) });
            });
        }

        function acknowledge(captureID, accepted) {
            var session = sessions[captureID];
            if (!session) { return; }
            if (!accepted) {
                try { session.reader.cancel(); } catch (_) {}
                delete sessions[captureID];
                return;
            }
            session.awaitingAck = false;
            readNext(session);
        }

        function cancel(captureID) {
            var session = sessions[captureID];
            if (session) { try { session.reader.cancel(); } catch (_) {} }
            delete sessions[captureID];
            post({ type: "cancel", captureID: captureID });
        }

        window.__lidBlobCapture = {
            start: start,
            acknowledge: acknowledge,
            cancel: cancel
        };
    })();
    """#

    public static func startCommand(blobURL: URL, captureID: String, chunkSize: Int = maximumChunkBytes) -> String {
        let escapedURL = jsString(blobURL.absoluteString)
        let escapedID = jsString(captureID)
        return "window.__lidBlobCapture.start(\(escapedURL), \(escapedID), \(min(maximumChunkBytes, max(1, chunkSize))));"
    }

    public static func acknowledgeCommand(captureID: String, accepted: Bool) -> String {
        "window.__lidBlobCapture.acknowledge(\(jsString(captureID)), \(accepted ? "true" : "false"));"
    }

    public static func cancelCommand(captureID: String) -> String {
        "window.__lidBlobCapture.cancel(\(jsString(captureID)));"
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }
}
