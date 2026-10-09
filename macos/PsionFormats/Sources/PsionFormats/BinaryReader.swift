import Foundation

struct BinaryReader {
    var bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    var remaining: Int { bytes.count - position }

    mutating func take(_ count: Int) throws -> [UInt8] {
        try require(position >= 0 && position <= bytes.count && count >= 0 && count <= remaining,
                    "read outside stream at byte \(position)")
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }
    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
    mutating func i32() throws -> Int { Int(Int32(bitPattern: try u32())) }
    mutating func cardinal() throws -> Int {
        let first = try u8()
        if first & 1 == 0 { return Int(first >> 1) }
        if first & 2 == 0 { return Int(UInt16(first) | UInt16(try u8()) << 8) >> 2 }
        try require(first & 4 == 0, "invalid cardinality")
        let b = try take(3)
        return Int(UInt32(first) | UInt32(b[0]) << 8 | UInt32(b[1]) << 16 | UInt32(b[2]) << 24) >> 3
    }
    mutating func descriptor() throws -> String {
        let length = try cardinal()
        guard length & 1 == 1 else { throw PsionConversionError.unsupported("wide text descriptors") }
        return try Self.text(take(length >> 1))
    }
    func end() throws { try require(remaining == 0, "\(remaining) unconsumed stream bytes") }

    static func text(_ bytes: [UInt8]) throws -> String {
        guard let string = String(data: Data(bytes), encoding: .windowsCP1252) else {
            throw PsionConversionError.invalid("invalid Windows text encoding")
        }
        return string
    }
}
