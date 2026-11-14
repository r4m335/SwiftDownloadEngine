import Foundation

/// Pure Swift torrent metadata and bencoding parser that operates across all platforms
/// (iOS device builds, macOS, Linux, and Windows) without requiring native libtorrent symbols.
public struct TorrentMetadataParser: Sendable {

    /// Extracts the 40-character hex (or 32-character base32) info-hash from a magnet URI string.
    public static func extractInfoHash(from magnetURI: String) -> String? {
        guard let components = URLComponents(string: magnetURI),
              let queryItems = components.queryItems else {
            return nil
        }
        for item in queryItems where item.name == "xt" {
            guard let value = item.value?.lowercased() else { continue }
            if value.hasPrefix("urn:btih:") {
                let hash = String(value.dropFirst("urn:btih:".count))
                if hash.count == 40 || hash.count == 32 {
                    return hash
                }
            }
        }
        return nil
    }

    /// Extracts the display name from the `dn=` parameter of a magnet URI string.
    public static func extractDisplayName(from magnetURI: String) -> String? {
        guard let components = URLComponents(string: magnetURI),
              let queryItems = components.queryItems else {
            return nil
        }
        for item in queryItems where item.name == "dn" {
            if let name = item.value, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// Extracts bencoded torrent info: the computed infoHash, the suggested name,
    /// and whether it contains multiple files (`isMultiFile`).
    public static func extractBencodedInfo(from data: Data) -> (infoHash: String, name: String?, isMultiFile: Bool)? {
        guard let infoRange = data.range(of: Data("4:info".utf8)) else { return nil }
        let infoStart = infoRange.upperBound
        guard infoStart < data.count, data[infoStart] == 0x64 else { return nil }

        var depth = 0
        var idx = infoStart
        var inString = false
        var stringLength = 0

        while idx < data.count {
            let b = data[idx]
            if inString {
                stringLength -= 1
                if stringLength == 0 { inString = false }
                idx += 1
                continue
            }
            if b >= 0x30 && b <= 0x39 {
                var lenStr = ""
                while idx < data.count && data[idx] >= 0x30 && data[idx] <= 0x39 {
                    lenStr.append(Character(UnicodeScalar(data[idx])))
                    idx += 1
                }
                if idx < data.count && data[idx] == 0x3a {
                    idx += 1
                    if let len = Int(lenStr), len > 0 {
                        inString = true
                        stringLength = len
                    }
                }
                continue
            }
            if b == 0x64 || b == 0x6c {
                depth += 1
                idx += 1
            } else if b == 0x69 {
                idx += 1
                while idx < data.count && data[idx] != 0x65 { idx += 1 }
                if idx < data.count { idx += 1 }
            } else if b == 0x65 {
                depth -= 1
                idx += 1
                if depth == 0 {
                    let infoSlice = data.subdata(in: infoStart..<idx)
                    var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE, h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
                    var msg = infoSlice
                    let bitLength = UInt64(infoSlice.count) * 8
                    msg.append(0x80)
                    while (msg.count % 64) != 56 { msg.append(0x00) }
                    var bigEndianBits = bitLength.bigEndian
                    msg.append(Data(bytes: &bigEndianBits, count: 8))
                    for chunkStart in stride(from: 0, to: msg.count, by: 64) {
                        var w = [UInt32](repeating: 0, count: 80)
                        for i in 0..<16 {
                            let off = chunkStart + i * 4
                            w[i] = UInt32(msg[off]) << 24 | UInt32(msg[off + 1]) << 16 | UInt32(msg[off + 2]) << 8 | UInt32(msg[off + 3])
                        }
                        for i in 16..<80 {
                            let val = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                            w[i] = (val << 1) | (val >> 31)
                        }
                        var a = h0, b = h1, c = h2, d = h3, e = h4
                        for i in 0..<80 {
                            var f: UInt32 = 0, k: UInt32 = 0
                            if i < 20 { f = (b & c) | ((~b) & d); k = 0x5A827999 }
                            else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1 }
                            else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC }
                            else { f = b ^ c ^ d; k = 0xCA62C1D6 }
                            let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
                        }
                        h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
                    }
                    var result = Data()
                    let parts = [h0.bigEndian, h1.bigEndian, h2.bigEndian, h3.bigEndian, h4.bigEndian]
                    for var p in parts { result.append(Data(bytes: &p, count: 4)) }
                    let hashHex = result.map { String(format: "%02x", $0) }.joined()

                    var parsedName: String? = nil
                    if let nameRange = infoSlice.range(of: Data("4:name".utf8)) {
                        let nameStart = nameRange.upperBound
                        if let colonIdx = (nameStart..<min(nameStart + 10, infoSlice.count)).first(where: { infoSlice[$0] == 0x3a }),
                           let len = Int(String(data: infoSlice.subdata(in: nameStart..<colonIdx), encoding: .utf8) ?? ""),
                           colonIdx + 1 + len <= infoSlice.count {
                            parsedName = String(data: infoSlice.subdata(in: (colonIdx + 1)..<(colonIdx + 1 + len)), encoding: .utf8)
                        }
                    }

                    let isMultiFile = infoSlice.range(of: Data("5:files".utf8)) != nil
                    return (hashHex, parsedName, isMultiFile)
                }
            } else {
                idx += 1
            }
        }
        return nil
    }
}
