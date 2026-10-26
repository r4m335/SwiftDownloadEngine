import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Errors that can occur during HLS AES-128 segment decryption.
public enum HLSSegmentDecryptionError: Error, LocalizedError, Sendable, Equatable {
    case commonCryptoUnavailable
    case missingKeyData(URL)
    case invalidKeyLength(expected: Int, actual: Int)
    case invalidIVLength(expected: Int, actual: Int)
    case cryptorError(status: Int32)
    case fileReadError(String)
    case fileWriteError(String)

    public var errorDescription: String? {
        switch self {
        case .commonCryptoUnavailable:
            return "AES-128 decryption is unavailable on this platform."
        case .missingKeyData(let url):
            return "Encryption key could not be loaded from \(url.absoluteString)."
        case .invalidKeyLength(let expected, let actual):
            return "Invalid AES-128 key length: expected \(expected) bytes, got \(actual) bytes."
        case .invalidIVLength(let expected, let actual):
            return "Invalid AES-128 IV length: expected \(expected) bytes, got \(actual) bytes."
        case .cryptorError(let status):
            return "CommonCrypto AES-128-CBC decryption failed with status \(status)."
        case .fileReadError(let path):
            return "Failed to read encrypted segment at \(path)."
        case .fileWriteError(let path):
            return "Failed to write decrypted segment to \(path)."
        }
    }
}

/// AES-128-CBC decryptor for HLS media segments according to RFC 8216 Section 5.2.
///
/// HLS AES-128 encryption uses:
/// - AES-128 in Cipher Block Chaining (CBC) mode with PKCS#7 padding.
/// - A 16-octet binary key fetched from the `#EXT-X-KEY` URI.
/// - A 16-octet IV either specified in the `#EXT-X-KEY` `IV` attribute or derived
///   from the segment sequence number formatted as a 16-octet big-endian integer.
public enum HLSSegmentDecryptor {

    /// Parses an IV hex string (e.g., `"0x123456789abcdef0123456789abcdef0"`) into 16 bytes of `Data`.
    public static func parseIV(_ ivString: String) -> Data? {
        var hex = ivString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex.removeFirst(2)
        }
        if hex.count % 2 != 0 {
            hex = "0" + hex
        }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        if data.count < 16 {
            data = Data(repeating: 0, count: 16 - data.count) + data
        } else if data.count > 16 {
            data = data.prefix(16)
        }
        return data
    }

    /// Derives the default 16-byte IV from a media segment sequence number per RFC 8216 Section 5.2.
    ///
    /// The sequence number is represented as a 16-octet binary value in network byte order
    /// (most significant byte first) with the appropriate number of leading zeroes.
    public static func ivForSequenceNumber(_ sequenceNumber: Int64) -> Data {
        var iv = Data(repeating: 0, count: 16)
        var bigEndianSeq = UInt64(max(0, sequenceNumber)).bigEndian
        withUnsafeBytes(of: &bigEndianSeq) { seqBytes in
            iv.replaceSubrange(8..<16, with: seqBytes)
        }
        return iv
    }

    /// Decrypts AES-128-CBC encrypted data with PKCS#7 padding.
    public static func decrypt(
        data: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        #if canImport(CommonCrypto)
        guard key.count == kCCKeySizeAES128 else {
            throw HLSSegmentDecryptionError.invalidKeyLength(expected: kCCKeySizeAES128, actual: key.count)
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw HLSSegmentDecryptionError.invalidIVLength(expected: kCCBlockSizeAES128, actual: iv.count)
        }

        var decryptedData = Data(count: data.count + kCCBlockSizeAES128)
        var numBytesDecrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    decryptedData.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outBytes.baseAddress,
                            decryptedData.count,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw HLSSegmentDecryptionError.cryptorError(status: status)
        }

        decryptedData.removeSubrange(numBytesDecrypted..<decryptedData.count)
        return decryptedData
        #else
        throw HLSSegmentDecryptionError.commonCryptoUnavailable
        #endif
    }

    /// Decrypts a file on disk and writes the clear plaintext to destinationURL.
    public static func decryptFile(
        at sourceURL: URL,
        to destinationURL: URL,
        key: Data,
        iv: Data
    ) throws {
        guard let ciphertext = try? Data(contentsOf: sourceURL) else {
            throw HLSSegmentDecryptionError.fileReadError(sourceURL.path)
        }
        let cleartext = try decrypt(data: ciphertext, key: key, iv: iv)
        do {
            try cleartext.write(to: destinationURL, options: .atomic)
        } catch {
            throw HLSSegmentDecryptionError.fileWriteError(destinationURL.path)
        }
    }

    #if canImport(CommonCrypto)
    /// Helper for testing: Encrypts clear data using AES-128-CBC with PKCS#7 padding.
    public static func encrypt(
        data: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw HLSSegmentDecryptionError.invalidKeyLength(expected: kCCKeySizeAES128, actual: key.count)
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw HLSSegmentDecryptionError.invalidIVLength(expected: kCCBlockSizeAES128, actual: iv.count)
        }

        var encryptedData = Data(count: data.count + kCCBlockSizeAES128)
        var numBytesEncrypted: size_t = 0

        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    encryptedData.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outBytes.baseAddress,
                            encryptedData.count,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw HLSSegmentDecryptionError.cryptorError(status: status)
        }

        encryptedData.removeSubrange(numBytesEncrypted..<encryptedData.count)
        return encryptedData
    }
    #endif
}
