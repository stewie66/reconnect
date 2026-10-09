import Foundation

struct BinaryWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { bytes += Self.integer(UInt32(value), count: 2) }
    mutating func u32(_ value: UInt32) { bytes += Self.integer(value) }
    mutating func append(_ value: [UInt8]) { bytes += value }

    mutating func cardinal(_ value: Int) throws {
        try require((0..<0x20000000).contains(value), "cardinality outside supported range")
        if value < 128 { u8(UInt8(value << 1)) }
        else if value < 16384 { u16(UInt16(value << 2 | 1)) }
        else { u32(UInt32(value << 3 | 3)) }
    }

    static func integer(_ value: UInt32, count: Int = 4) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    static func text(_ value: String) throws -> [UInt8] {
        guard let data = value.data(using: .windowsCP1252, allowLossyConversion: false),
              String(data: data, encoding: .windowsCP1252) == value else {
            throw PsionImportError.unsupported("text that cannot be represented in the Psion's Windows-1252 character set")
        }
        return Array(data)
    }

    mutating func descriptor(_ value: String) throws {
        let text = try Self.text(value)
        try cardinal(text.count * 2 + 1)
        append(text)
    }
}
