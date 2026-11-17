import Foundation

/// A parsed subsegment descriptor extracted from an ISO BMFF `sidx` box.
public struct DASHSidxSegment: Sendable, Equatable {
    public let byteRange: DASHByteRange
    public let duration: Double
    public let timescale: Int64
    public let presentationTime: Double

    public init(
        byteRange: DASHByteRange,
        duration: Double,
        timescale: Int64,
        presentationTime: Double
    ) {
        self.byteRange = byteRange
        self.duration = duration
        self.timescale = timescale
        self.presentationTime = presentationTime
    }
}

public enum DASHSidxParserError: Error, LocalizedError, Sendable, Equatable {
    case dataTooShort
    case invalidBoxType
    case unsupportedVersion(UInt8)
    case malformed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .dataTooShort:
            return "sidx data is shorter than required ISO BMFF box headers."
        case .invalidBoxType:
            return "Box type is not 'sidx'."
        case .unsupportedVersion(let v):
            return "sidx box version \(v) is unsupported."
        case .malformed(let reason):
            return "Malformed sidx box: \(reason)"
        }
    }
}

/// Parses ISO/IEC 14496-12 `sidx` (Segment Index) boxes for DASH `SegmentBase` addressing.
public enum DASHSidxParser {

    public static func parse(
        data: Data,
        sidxOffset: Int64 = 0
    ) throws -> [DASHSidxSegment] {
        guard data.count >= 12 else {
            throw DASHSidxParserError.dataTooShort
        }

        // Locate 'sidx' if preceded by box length or search within first 32 bytes
        var offset = 0
        if data.count >= 8 {
            let type = String(bytes: data[4..<8], encoding: .ascii)
            if type != "sidx" {
                // Search for "sidx" marker within bounded window
                var found = false
                let searchEnd = min(data.count - 4, 64)
                for i in 0..<searchEnd {
                    if data[i] == 0x73 && data[i+1] == 0x69 && data[i+2] == 0x64 && data[i+3] == 0x78 { // 's','i','d','x'
                        if i >= 4 {
                            offset = i - 4
                            found = true
                            break
                        }
                    }
                }
                guard found else {
                    throw DASHSidxParserError.invalidBoxType
                }
            }
        }

        guard offset + 8 <= data.count else {
            throw DASHSidxParserError.dataTooShort
        }

        let boxSizeInt = UInt64(data[offset]) << 24 | UInt64(data[offset+1]) << 16 |
                         UInt64(data[offset+2]) << 8 | UInt64(data[offset+3])
        let boxType = String(bytes: data[offset+4..<offset+8], encoding: .ascii)
        guard boxType == "sidx" else {
            throw DASHSidxParserError.invalidBoxType
        }
        offset += 8

        let boxSize: UInt64
        if boxSizeInt == 1 {
            // Large box size (64-bit)
            guard offset + 8 <= data.count else { throw DASHSidxParserError.dataTooShort }
            boxSize = readUInt64(from: data, at: offset)
            offset += 8
        } else if boxSizeInt == 0 {
            boxSize = UInt64(data.count)
        } else {
            boxSize = boxSizeInt
        }

        guard offset + 4 <= data.count else { throw DASHSidxParserError.dataTooShort }
        let version = data[offset]
        guard version == 0 || version == 1 else {
            throw DASHSidxParserError.unsupportedVersion(version)
        }
        offset += 4 // version (1) + flags (3)

        // reference_ID (UInt32)
        offset += 4

        guard offset + 4 <= data.count else { throw DASHSidxParserError.dataTooShort }
        let timescale = Int64(UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 |
                              UInt32(data[offset+2]) << 8 | UInt32(data[offset+3]))
        guard timescale > 0 else {
            throw DASHSidxParserError.malformed(reason: "timescale must be positive.")
        }
        offset += 4

        let earliestPresentationTime: Int64
        let firstOffset: Int64
        if version == 0 {
            guard offset + 8 <= data.count else { throw DASHSidxParserError.dataTooShort }
            earliestPresentationTime = Int64(UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 |
                                             UInt32(data[offset+2]) << 8 | UInt32(data[offset+3]))
            offset += 4
            firstOffset = Int64(UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 |
                                UInt32(data[offset+2]) << 8 | UInt32(data[offset+3]))
            offset += 4
        } else {
            guard offset + 16 <= data.count else { throw DASHSidxParserError.dataTooShort }
            earliestPresentationTime = Int64(readUInt64(from: data, at: offset))
            offset += 8
            firstOffset = Int64(readUInt64(from: data, at: offset))
            offset += 8
        }

        guard offset + 4 <= data.count else { throw DASHSidxParserError.dataTooShort }
        offset += 2 // reserved
        let referenceCount = Int(UInt16(data[offset]) << 8 | UInt16(data[offset+1]))
        offset += 2

        guard referenceCount > 0 else { return [] }
        guard offset + referenceCount * 12 <= data.count else {
            throw DASHSidxParserError.dataTooShort
        }

        // Anchor is first byte following the sidx box plus first_offset
        let anchor = sidxOffset + Int64(boxSize) + firstOffset
        var currentOffset = anchor
        var currentPresentationTime = Double(earliestPresentationTime) / Double(timescale)
        var segments: [DASHSidxSegment] = []
        segments.reserveCapacity(referenceCount)

        for _ in 0..<referenceCount {
            let refWord = UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 |
                          UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
            let referencedSize = Int64(refWord & 0x7FFFFFFF)
            offset += 4

            let subsegmentDuration = UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 |
                                    UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
            offset += 4

            // SAP bits (4 bytes)
            offset += 4

            guard referencedSize > 0 else {
                throw DASHSidxParserError.malformed(reason: "referenced_size must be positive.")
            }
            let segStart = currentOffset
            let segEnd = segStart + referencedSize - 1
            let durationSeconds = Double(subsegmentDuration) / Double(timescale)

            segments.append(DASHSidxSegment(
                byteRange: DASHByteRange(start: segStart, end: segEnd),
                duration: durationSeconds,
                timescale: timescale,
                presentationTime: currentPresentationTime
            ))

            currentOffset = segEnd + 1
            currentPresentationTime += durationSeconds
        }

        return segments
    }

    /// Helper for constructing valid synthetic `sidx` box bytes for testing and validation.
    public static func makeSidxBox(
        version: UInt8 = 0,
        referenceID: UInt32 = 1,
        timescale: UInt32 = 1000,
        earliestPresentationTime: UInt64 = 0,
        firstOffset: UInt64 = 0,
        entries: [(size: UInt32, duration: UInt32)]
    ) -> Data {
        var body = Data()
        // version (1) + flags (3)
        body.append(version)
        body.append(contentsOf: [0, 0, 0])
        // reference_ID
        body.append(contentsOf: withUnsafeBytes(of: referenceID.bigEndian) { Array($0) })
        // timescale
        body.append(contentsOf: withUnsafeBytes(of: timescale.bigEndian) { Array($0) })

        if version == 0 {
            let ept = UInt32(earliestPresentationTime).bigEndian
            body.append(contentsOf: withUnsafeBytes(of: ept) { Array($0) })
            let fo = UInt32(firstOffset).bigEndian
            body.append(contentsOf: withUnsafeBytes(of: fo) { Array($0) })
        } else {
            let ept = earliestPresentationTime.bigEndian
            body.append(contentsOf: withUnsafeBytes(of: ept) { Array($0) })
            let fo = firstOffset.bigEndian
            body.append(contentsOf: withUnsafeBytes(of: fo) { Array($0) })
        }

        // reserved (16 bits)
        body.append(contentsOf: [0, 0])
        // reference_count (16 bits)
        let count = UInt16(entries.count).bigEndian
        body.append(contentsOf: withUnsafeBytes(of: count) { Array($0) })

        for entry in entries {
            let refWord = (entry.size & 0x7FFFFFFF).bigEndian
            body.append(contentsOf: withUnsafeBytes(of: refWord) { Array($0) })
            let durWord = entry.duration.bigEndian
            body.append(contentsOf: withUnsafeBytes(of: durWord) { Array($0) })
            // starts_with_SAP (1), SAP_type (3), SAP_delta_time (28) -> SAP=1, type=1, delta=0 -> 0x90000000
            let sapWord: UInt32 = 0x90000000
            body.append(contentsOf: withUnsafeBytes(of: sapWord.bigEndian) { Array($0) })
        }

        let totalSize = UInt32(8 + body.count).bigEndian
        var box = Data()
        box.append(contentsOf: withUnsafeBytes(of: totalSize) { Array($0) })
        box.append(contentsOf: "sidx".utf8)
        box.append(body)
        return box
    }

    private static func readUInt64(from data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }
}
