import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif


/// Redirect delegate used by exact ranged resource transfers. It preserves the
/// coordinator's existing origin rule even though the transfer is issued as a
/// single URLSession request rather than through SegmentDownloader.
final class DownloadResourceRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let originalURL: URL
    private let headers: [String: String]
    private let allowedOrigins: Set<String>

    init(originalURL: URL, headers: [String: String], allowedOrigins: Set<String> = []) {
        self.originalURL = originalURL
        self.headers = headers
        self.allowedOrigins = allowedOrigins
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let redirected = DownloadRequestEnricher.handleRedirect(
            task: task,
            response: response,
            newRequest: request,
            allowedOrigins: allowedOrigins
        )
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let host = space.host

        if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
           space.authenticationMethod == NSURLAuthenticationMethodDefault ||
           space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            if let saved = KeychainManager.shared.getInternetPassword(server: host, path: "/") {
                completionHandler(.useCredential, URLCredential(user: saved.username, password: saved.password, persistence: .none))
                return
            }
            if let provider = DownloadCoordinator.basicAuthChallengeHandler {
                Task {
                    if let cred = await provider(host, space.realm ?? "") {
                        KeychainManager.shared.storeInternetPassword(
                            username: cred.username,
                            password: cred.password,
                            server: host
                        )
                        completionHandler(.useCredential, URLCredential(user: cred.username, password: cred.password, persistence: .none))
                    } else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                    }
                }
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

/// Standard, zero-dependency SHA-256 implementation ensuring portable digest validation across all platforms.
public enum EngineSHA256 {
    public static func hash(data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]

        var bytes = Array(data)
        let bitLength = UInt64(data.count) * 8
        bytes.append(0x80)
        while (bytes.count % 64) != 56 {
            bytes.append(0x00)
        }
        for i in (0..<8).reversed() {
            bytes.append(UInt8((bitLength >> (i * 8)) & 0xff))
        }

        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let idx = chunkStart + i * 4
                w[i] = (UInt32(bytes[idx]) << 24) |
                       (UInt32(bytes[idx + 1]) << 16) |
                       (UInt32(bytes[idx + 2]) << 8) |
                       UInt32(bytes[idx + 3])
            }
            for i in 16..<64 {
                let s0 = (w[i-15] >> 7 | w[i-15] << 25) ^ (w[i-15] >> 18 | w[i-15] << 14) ^ (w[i-15] >> 3)
                let s1 = (w[i-2] >> 17 | w[i-2] << 15) ^ (w[i-2] >> 19 | w[i-2] << 13) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hVal = h[7]
            for i in 0..<64 {
                let s1 = (e >> 6 | e << 26) ^ (e >> 11 | e << 21) ^ (e >> 25 | e << 7)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hVal &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = (a >> 2 | a << 30) ^ (a >> 13 | a << 19) ^ (a >> 22 | a << 10)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hVal = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hVal
        }

        return h.map { String(format: "%08x", $0) }.joined()
        #endif
    }
}

// MARK: - Streaming File Hasher
#if canImport(CryptoKit)
public enum FileHasher {
    public static func sha256(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try fileHandle.close()
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to close fileHandle in sha256: \(error)")
            }
        }
        let totalSize: Int64 = FileManager.default.fileSize(atPath: url.path) ?? 0
        var hasher = SHA256()
        let bufferSize = 256 * 1024
        var processed: Int64 = 0

        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if totalSize > 0, let progress = progress {
                let frac = min(1.0, max(0.0, Double(processed) / Double(totalSize)))
                progress(frac)
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func computeSHA256(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try fileHandle.close()
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to close fileHandle in sha256: \(error)")
            }
        }
        let totalSize: Int64 = FileManager.default.fileSize(atPath: url.path) ?? 0
        var hasher = SHA256()
        let bufferSize = 256 * 1024
        var processed: Int64 = 0

        while true {
            try Task.checkCancellation()
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if totalSize > 0, let progress = progress {
                let frac = min(1.0, max(0.0, Double(processed) / Double(totalSize)))
                progress(frac)
            }
            await Task.yield()
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#else
public enum FileHasher {
    public static func sha256(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try fileHandle.close()
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to close fileHandle in sha256: \(error)")
            }
        }
        let totalSize: Int64 = FileManager.default.fileSize(atPath: url.path) ?? 0
        var hasher = EngineSHA256Hasher()
        let bufferSize = 256 * 1024
        var processed: Int64 = 0

        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if totalSize > 0, let progress = progress {
                let frac = min(1.0, max(0.0, Double(processed) / Double(totalSize)))
                progress(frac)
            }
        }
        return hasher.finalize()
    }

    public static func computeSHA256(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try fileHandle.close()
            } catch {
                PipelineLogger.shared.log(stage: .coordinator, message: "Failed to close fileHandle in sha256: \(error)")
            }
        }
        let totalSize: Int64 = FileManager.default.fileSize(atPath: url.path) ?? 0
        var hasher = EngineSHA256Hasher()
        let bufferSize = 256 * 1024
        var processed: Int64 = 0

        while true {
            try Task.checkCancellation()
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if totalSize > 0, let progress = progress {
                let frac = min(1.0, max(0.0, Double(processed) / Double(totalSize)))
                progress(frac)
            }
            await Task.yield()
        }
        return hasher.finalize()
    }
}
#endif
