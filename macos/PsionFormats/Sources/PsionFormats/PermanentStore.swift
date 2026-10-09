import Foundation

// ER5 Permanent Store: checked UIDs, normalized header CRC, base TOCs and 16 KiB frames.
// See Symbian U32PERM.H, UT_PERM.CPP and US_FRAME.CPP; the supplied Agenda handoff.
struct PermanentStore {
    var uids: [UInt32]
    var root: UInt32
    var streams: [UInt32: [UInt8]]

    init(_ data: Data) throws {
        let bytes = Array(data)
        try require((32...64 * 1024 * 1024).contains(bytes.count), "file size outside supported bounds")
        var reader = BinaryReader(bytes)
        uids = try [reader.u32(), reader.u32(), reader.u32()]
        guard uids[0] == 0x10000050 else {
            throw PsionConversionError.unsupported("expected an EPOC32 Permanent File Store")
        }
        let expected = try reader.u32()
        let even = stride(from: 0, to: 12, by: 2).map { bytes[$0] }
        let odd = stride(from: 1, to: 12, by: 2).map { bytes[$0] }
        try require(expected == UInt32(Self.crc(even)) | UInt32(Self.crc(odd)) << 16, "UID checksum mismatch")
        let backup = try reader.u32()
        let relocation = try reader.u32()
        let reference = try reader.u32()
        let checksum = try reader.u16()
        guard backup & 1 == 0 && relocation == 0 else {
            throw PsionConversionError.unsupported("dirty or relocating stores require recovery")
        }
        let normalized = [reference &* 2, relocation, reference].flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        try require(Self.crc(normalized) == checksum, "store header CRC mismatch")
        try require(reference >= 12, "invalid table of contents reference")
        let toc = try Self.frames(bytes, offset: Int(reference) - 12, type: 0x8000)
        var table = BinaryReader(toc.bytes)
        let primary = try table.u32()
        let available = try table.u32()
        let count = Int(try table.u32())
        try require(primary & 0x70000000 == 0, "invalid root flags")
        guard primary & 0x80000000 == 0 else { throw PsionConversionError.unsupported("delta tables of contents") }
        try require(count <= min(0xffffff, bytes.count / 5), "impossible stream count")
        try require(available == 0 || (available & 0x80000000 != 0 && available & 0x30000000 == 0), "invalid free list")
        root = primary & 0x0fffffff
        streams = [:]
        var ranges = toc.ranges
        var storedBytes = ranges.reduce(0) { $0 + $1.count }
        for index in 0..<count {
            let handle = UInt32(try table.u8()) << 24 | UInt32(index + 1)
            let offset = try table.i32()
            try require(handle & 0x70000000 == 0, "invalid stream flags")
            if handle & 0x80000000 != 0 {
                try require(offset <= 0, "invalid deleted stream reference")
                continue
            }
            try require(offset >= -1, "invalid stream offset")
            if offset == -1 { streams[handle] = []; continue }
            let frame = try Self.frames(bytes, offset: offset, type: 0x4000)
            storedBytes += frame.ranges.reduce(0) { $0 + $1.count }
            try require(storedBytes <= bytes.count - 30, "live streams exceed file storage")
            streams[handle] = frame.bytes
            ranges += frame.ranges
        }
        try table.end()
        try require(streams[root] != nil, "missing root stream")
        ranges.sort { $0.lowerBound < $1.lowerBound }
        for index in 1..<max(1, ranges.count) {
            try require(ranges[index - 1].upperBound <= ranges[index].lowerBound, "overlapping live streams")
        }
    }

    func get(_ handle: UInt32) throws -> [UInt8] {
        guard let bytes = streams[handle] else { throw PsionConversionError.invalid("missing stream \(handle)") }
        return bytes
    }

    private static func frames(_ bytes: [UInt8], offset: Int, type: UInt16) throws -> (bytes: [UInt8], ranges: [Range<Int>]) {
        var offset = offset
        var expectedType = type
        var output: [UInt8] = []
        var ranges: [Range<Int>] = []
        while true {
            try require(offset >= 0 && offset <= bytes.count, "frame offset outside file")
            let physical = 32 + offset + 2 * (offset >> 14)
            var reader = BinaryReader(bytes, position: physical - 2)
            let descriptor = try reader.u16()
            try require(descriptor & 0xc000 == expectedType, "unexpected frame type")
            let length = descriptor & 0x3fff == 0 ? 16384 - (offset & 0x3fff) : Int(descriptor & 0x3fff)
            try require((offset & 0x3fff) + length <= 16384, "frame crosses boundary")
            output += try reader.take(length)
            ranges.append(physical - 2..<physical + length)
            offset += length
            if offset & 0x3fff != 0 { break }
            let next = 32 + offset + 2 * (offset >> 14)
            if next - 2 == bytes.count { break }
            var continuation = BinaryReader(bytes, position: next - 2)
            if try continuation.u16() & 0xc000 != 0xc000 { break }
            expectedType = 0xc000
        }
        return (output, ranges)
    }

    private static func crc(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc &<< 1 : (crc &<< 1) ^ 0x1021 }
        }
        return crc
    }
}
