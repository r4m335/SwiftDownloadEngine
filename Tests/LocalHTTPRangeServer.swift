import Foundation
@testable import DM_Reverse_engineering

#if canImport(Glibc)
import Glibc
@discardableResult
private func posix_close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
#elseif canImport(Darwin)
import Darwin
@discardableResult
private func posix_close(_ fd: Int32) -> Int32 { Darwin.close(fd) }
#endif

/// Lightweight, in-process RFC 7233 compliant HTTP Range test server.
/// Uses standard POSIX TCP sockets over the loopback interface (`127.0.0.1`)
/// with an OS-assigned ephemeral port (port 0) for zero collision risk.
public final class LocalHTTPRangeServer: @unchecked Sendable {
    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let headers: [String: String]
    }

    public struct Response: Sendable {
        public let statusCode: Int
        public let statusText: String
        public let headers: [String: String]
        public let body: Data
        public let chunkDelayMs: UInt32
        public let dropConnectionAfterBytes: Int?

        public init(
            statusCode: Int = 200,
            statusText: String = "OK",
            headers: [String: String] = [:],
            body: Data = Data(),
            chunkDelayMs: UInt32 = 0,
            dropConnectionAfterBytes: Int? = nil
        ) {
            self.statusCode = statusCode
            self.statusText = statusText
            self.headers = headers
            self.body = body
            self.chunkDelayMs = chunkDelayMs
            self.dropConnectionAfterBytes = dropConnectionAfterBytes
        }
    }

    public struct Resource: Sendable {
        public let data: Data
        public let eTag: String?
        public let lastModified: String?
        public let mimeType: String
        public let ignoresRange: Bool
        public let statusCodeOverride: Int?
        public let chunkDelayMs: UInt32
        public let dropConnectionAfterBytes: Int?

        public init(
            data: Data,
            eTag: String? = nil,
            lastModified: String? = nil,
            mimeType: String = "application/octet-stream",
            ignoresRange: Bool = false,
            statusCodeOverride: Int? = nil,
            chunkDelayMs: UInt32 = 0,
            dropConnectionAfterBytes: Int? = nil
        ) {
            self.data = data
            self.eTag = eTag
            self.lastModified = lastModified
            self.mimeType = mimeType
            self.ignoresRange = ignoresRange
            self.statusCodeOverride = statusCodeOverride
            self.chunkDelayMs = chunkDelayMs
            self.dropConnectionAfterBytes = dropConnectionAfterBytes
        }
    }

    private let lock = NSLock()
    private var resources: [String: Resource] = [:]
    private var customHandlers: [String: @Sendable (Request) -> Response] = [:]
    private var transientFailures: [String: (count: Int, statusCode: Int)] = [:]
    private var serverSocket: Int32 = -1
    private var listeningThread: Thread?
    private var isRunning = false

    public private(set) var port: UInt16 = 0

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    public init() {}

    deinit {
        stop()
    }

    public func register(
        path: String,
        data: Data,
        eTag: String? = nil,
        lastModified: String? = nil,
        mimeType: String = "application/octet-stream",
        ignoresRange: Bool = false,
        statusCodeOverride: Int? = nil,
        chunkDelayMs: UInt32 = 0,
        dropConnectionAfterBytes: Int? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        let tag = eTag ?? "\"etag-\(EngineSHA256.hash(data: data).prefix(12))\""
        resources[normalizedPath] = Resource(
            data: data,
            eTag: tag,
            lastModified: lastModified,
            mimeType: mimeType,
            ignoresRange: ignoresRange,
            statusCodeOverride: statusCodeOverride,
            chunkDelayMs: chunkDelayMs,
            dropConnectionAfterBytes: dropConnectionAfterBytes
        )
    }

    public func updateResource(
        path: String,
        data: Data? = nil,
        eTag: String? = nil,
        lastModified: String? = nil,
        chunkDelayMs: UInt32? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        guard let existing = resources[normalizedPath] else { return }
        let newData = data ?? existing.data
        let newTag = eTag ?? existing.eTag
        let newLM = lastModified ?? existing.lastModified
        let newDelay = chunkDelayMs ?? existing.chunkDelayMs
        resources[normalizedPath] = Resource(
            data: newData,
            eTag: newTag,
            lastModified: newLM,
            mimeType: existing.mimeType,
            ignoresRange: existing.ignoresRange,
            statusCodeOverride: existing.statusCodeOverride,
            chunkDelayMs: newDelay,
            dropConnectionAfterBytes: existing.dropConnectionAfterBytes
        )
    }

    public func failNextRequests(path: String, count: Int, statusCode: Int = 500) {
        lock.lock()
        defer { lock.unlock() }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        transientFailures[normalizedPath] = (count, statusCode)
    }

    public func registerHandler(
        path: String,
        handler: @escaping @Sendable (Request) -> Response
    ) {
        lock.lock()
        defer { lock.unlock() }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        customHandlers[normalizedPath] = handler
    }

    public func url(for path: String) -> URL {
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return baseURL.appendingPathComponent(normalizedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        #if os(Linux)
        signal(SIGPIPE, SIG_IGN)
        let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        #endif

        guard sock >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        #if !os(Linux)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0) // kernel assigns ephemeral port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            posix_close(sock)
            throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE)
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(sock, sa, &addrLen)
            }
        }
        guard nameRes == 0 else {
            posix_close(sock)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        self.port = UInt16(bigEndian: boundAddr.sin_port)
        guard listen(sock, 128) == 0 else {
            posix_close(sock)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        self.serverSocket = sock
        self.isRunning = true

        let thread = Thread { [weak self] in
            self?.acceptLoop(serverSock: sock)
        }
        thread.name = "1DM_LocalHTTPRangeServer"
        thread.start()
        self.listeningThread = thread
    }

    public func stop() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        isRunning = false
        let sock = serverSocket
        serverSocket = -1
        lock.unlock()

        if sock >= 0 {
            posix_close(sock)
        }
    }

    // MARK: - Accept Loop

    private func acceptLoop(serverSock: Int32) {
        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSock = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(serverSock, sa, &clientLen)
                }
            }

            guard clientSock >= 0 else {
                lock.lock()
                let running = isRunning
                lock.unlock()
                if !running { break }
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientSock: clientSock)
            }
        }
    }

    // MARK: - Client Handler

    private func handleClient(clientSock: Int32) {
        defer { posix_close(clientSock) }

        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

        while true {
            let bytesRead = recv(clientSock, &buffer, buffer.count, 0)
            if bytesRead <= 0 { break }
            requestData.append(contentsOf: buffer[0..<bytesRead])
            if requestData.range(of: headerDelimiter) != nil {
                break
            }
            if requestData.count > 64 * 1024 {
                break // header too large
            }
        }

        guard let requestString = String(data: requestData, encoding: .utf8),
              !requestString.isEmpty else {
            return
        }

        guard let request = parseRequest(requestString) else {
            sendResponse(
                clientSock: clientSock,
                response: Response(statusCode: 400, statusText: "Bad Request", headers: ["Connection": "close"])
            )
            return
        }

        let response = routeRequest(request)
        sendResponse(clientSock: clientSock, response: response)
    }

    private func parseRequest(_ raw: String) -> Request? {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        let lineParts = requestLine.split(separator: " ")
        guard lineParts.count >= 2 else { return nil }

        let method = String(lineParts[0]).uppercased()
        let pathWithQuery = String(lineParts[1])
        let path = pathWithQuery.split(separator: "?").first.map(String.init) ?? pathWithQuery

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2 {
                let name = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }

        return Request(method: method, path: path, headers: headers)
    }

    private func routeRequest(_ req: Request) -> Response {
        lock.lock()
        if let failure = transientFailures[req.path], failure.count > 0 {
            transientFailures[req.path] = (failure.count - 1, failure.statusCode)
            lock.unlock()
            return Response(
                statusCode: failure.statusCode,
                statusText: "Server Error",
                headers: ["Content-Length": "0", "Connection": "close"]
            )
        }

        let handler = customHandlers[req.path]
        let res = resources[req.path]
        lock.unlock()

        if let handler = handler {
            return handler(req)
        }

        guard let resource = res else {
            return Response(
                statusCode: 404,
                statusText: "Not Found",
                headers: ["Content-Length": "0", "Connection": "close"]
            )
        }

        if let overrideStatus = resource.statusCodeOverride {
            return Response(
                statusCode: overrideStatus,
                statusText: "Overridden",
                headers: ["Content-Length": "0", "Connection": "close"]
            )
        }

        let totalSize = Int64(resource.data.count)

        func buildCommonHeaders(length: Int64) -> [String: String] {
            var h = [
                "Content-Length": String(length),
                "Accept-Ranges": "bytes",
                "Content-Type": resource.mimeType,
                "Connection": "close"
            ]
            if let tag = resource.eTag {
                h["ETag"] = tag
            }
            if let lm = resource.lastModified {
                h["Last-Modified"] = lm
            }
            return h
        }

        // HEAD request handling
        if req.method == "HEAD" {
            let headers = buildCommonHeaders(length: totalSize)
            return Response(statusCode: 200, statusText: "OK", headers: headers, body: Data())
        }

        // Check if server ignores Range
        let rangeHeader = req.headers["range"]
        let isProbe = (rangeHeader == "bytes=0-")
        if resource.ignoresRange || rangeHeader == nil {
            let headers = buildCommonHeaders(length: totalSize)
            return Response(
                statusCode: 200,
                statusText: "OK",
                headers: headers,
                body: resource.data,
                chunkDelayMs: resource.chunkDelayMs,
                dropConnectionAfterBytes: isProbe ? nil : resource.dropConnectionAfterBytes
            )
        }

        // Byte-range request
        guard let rangeStr = rangeHeader, rangeStr.hasPrefix("bytes=") else {
            return Response(
                statusCode: 400,
                statusText: "Bad Request",
                headers: ["Content-Length": "0", "Connection": "close"]
            )
        }

        // Check If-Range validator if provided
        if let ifRange = req.headers["if-range"], ifRange != resource.eTag {
            // Validator mismatched -> RFC 7233 sends full 200 representation
            let headers = buildCommonHeaders(length: totalSize)
            return Response(
                statusCode: 200,
                statusText: "OK",
                headers: headers,
                body: resource.data,
                chunkDelayMs: resource.chunkDelayMs,
                dropConnectionAfterBytes: isProbe ? nil : resource.dropConnectionAfterBytes
            )
        }

        // Handle empty file (0 bytes)
        if totalSize == 0 {
            // RFC 7233 Section 4.4: Content-Range: bytes */0
            var headers = buildCommonHeaders(length: 0)
            headers["Content-Range"] = "bytes */0"
            return Response(statusCode: 416, statusText: "Range Not Satisfiable", headers: headers, body: Data())
        }

        let spec = rangeStr.replacingOccurrences(of: "bytes=", with: "").trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)

        let start: Int64
        let end: Int64

        if parts.count == 2 {
            if parts[1].isEmpty {
                // e.g. "0-" (Probe request or fetch to end)
                guard let s = Int64(parts[0]), s >= 0, s < totalSize else {
                    return Response(
                        statusCode: 416,
                        statusText: "Range Not Satisfiable",
                        headers: ["Content-Range": "bytes */\(totalSize)", "Content-Length": "0", "Connection": "close"]
                    )
                }
                start = s
                end = totalSize - 1
            } else if parts[0].isEmpty {
                // e.g. "-500" (suffix range)
                guard let suffixLen = Int64(parts[1]), suffixLen > 0 else {
                    return Response(statusCode: 416, statusText: "Range Not Satisfiable", headers: ["Connection": "close"])
                }
                start = max(0, totalSize - suffixLen)
                end = totalSize - 1
            } else {
                // e.g. "0-999"
                guard let s = Int64(parts[0]), let e = Int64(parts[1]), s >= 0, s <= e, e < totalSize else {
                    return Response(
                        statusCode: 416,
                        statusText: "Range Not Satisfiable",
                        headers: ["Content-Range": "bytes */\(totalSize)", "Content-Length": "0", "Connection": "close"]
                    )
                }
                start = s
                end = e
            }
        } else {
            return Response(statusCode: 416, statusText: "Range Not Satisfiable", headers: ["Connection": "close"])
        }

        let sliceCount = Int(end - start + 1)
        let slice = resource.data.subdata(in: Int(start)..<Int(start) + sliceCount)

        var headers = buildCommonHeaders(length: Int64(sliceCount))
        headers["Content-Range"] = "bytes \(start)-\(end)/\(totalSize)"

        return Response(
            statusCode: 206,
            statusText: "Partial Content",
            headers: headers,
            body: slice,
            chunkDelayMs: resource.chunkDelayMs,
            dropConnectionAfterBytes: isProbe ? nil : resource.dropConnectionAfterBytes
        )
    }

    private func sendResponse(clientSock: Int32, response: Response) {
        var headerStr = "HTTP/1.1 \(response.statusCode) \(response.statusText)\r\n"
        for (k, v) in response.headers {
            headerStr += "\(k): \(v)\r\n"
        }
        headerStr += "\r\n"

        let headerBytes = Array(headerStr.utf8)
        headerBytes.withUnsafeBytes { ptr in
            #if os(Linux)
            _ = send(clientSock, ptr.baseAddress, ptr.count, Int32(MSG_NOSIGNAL))
            #else
            _ = send(clientSock, ptr.baseAddress, ptr.count, 0)
            #endif
        }

        if !response.body.isEmpty {
            response.body.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                var sent = 0
                while sent < ptr.count {
                    if let dropLimit = response.dropConnectionAfterBytes, sent >= dropLimit {
                        // Abrupt connection termination (FIN / RST)
                        #if os(Linux)
                        shutdown(clientSock, Int32(SHUT_RDWR))
                        #else
                        shutdown(clientSock, SHUT_RDWR)
                        #endif
                        return
                    }

                    let toSend = min(32 * 1024, ptr.count - sent)
                    #if os(Linux)
                    let n = send(clientSock, base + sent, toSend, Int32(MSG_NOSIGNAL))
                    #else
                    let n = send(clientSock, base + sent, toSend, 0)
                    #endif
                    if n <= 0 { break }
                    sent += n

                    if response.chunkDelayMs > 0 {
                        usleep(response.chunkDelayMs * 1000)
                    }
                }
            }
        }
    }
}
