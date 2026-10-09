import Foundation

/// Exports the ER5 Contacts DBMS 0x100 profile to UTF-8 vCard 3.0.
public enum ContactsConverter {
    public static func convert(_ data: Data) throws -> Data {
        let store = try PermanentStore(data)
        try require(store.uids[1] == 0x10000ebe && store.uids[2] == 0, "not an ER5 Contacts database")
        var schema = BinaryReader(try store.get(store.root))
        try require(try schema.u32() == 0x10000069, "invalid DBMS signature")
        guard try schema.u32() == 0x100, try schema.u8() == 0 else {
            throw PsionConversionError.unsupported("Contacts DBMS version or compression")
        }
        let tableCount = try schema.cardinal()
        try require(tableCount <= 16, "invalid DBMS table count")
        var contacts: ContactTable?
        for _ in 0..<tableCount {
            let table = try ContactTable.read(&schema)
            if table.name == "CONTACTS" {
                try require(contacts == nil, "duplicate Contacts table")
                contacts = table
            }
        }
        try require(schema.remaining == 0, "Contacts schema has \(schema.remaining) unconsumed bytes")
        guard let contacts else { throw PsionConversionError.invalid("missing Contacts table") }
        let expectedNames = ["CM_Identifier", "CM_Type", "CM_UIDString", "CM_Last_modified", "CM_Attributes",
                             "CM_ReplicationCount", "CM_DeleteFlag", "CM_TextBlob"]
        let expectedTypes: [UInt8] = [5, 5, 11, 10, 6, 6, 0, 16]
        guard contacts.columns.map(\.name) == expectedNames && contacts.columns.map(\.type) == expectedTypes &&
                contacts.columns.map(\.attributes) == [3, 0, 0, 0, 0, 0, 0, 0] else {
            throw PsionConversionError.unsupported("Contacts table schema")
        }
        var token = BinaryReader(try store.get(contacts.token))
        var head = try token.u32()
        _ = try token.u32() // next record ID
        let expectedCount = try token.cardinal()
        _ = try token.u32() // auto-increment
        try token.end()
        try require(expectedCount <= data.count, "impossible contact count")
        var rows: [ContactRow] = [], clusters: Set<UInt32> = [], identifiers: Set<UInt32> = []
        while head != 0 {
            try require(clusters.insert(head).inserted, "cycle in Contacts cluster chain")
            var cluster = BinaryReader(try store.get(head))
            head = try cluster.u32()
            let membership = try cluster.u16()
            var lengths: [Int] = []
            for index in 0..<16 where membership & (1 << index) != 0 { lengths.append(try cluster.cardinal()) }
            for length in lengths {
                let row = try ContactRow.read(cluster.take(length), store: store)
                try require(identifiers.insert(row.id).inserted, "duplicate contact ID")
                rows.append(row)
                try require(rows.count <= expectedCount, "contact count exceeds table count")
            }
            try cluster.end()
        }
        try require(rows.count == expectedCount, "Contacts table count mismatch")
        let templates = rows.filter { $0.type == 0x1000130b && !$0.deleted }
        guard templates.count == 1, let template = templates.first else {
            throw PsionConversionError.unsupported("Contacts template configuration")
        }
        // Validate field mappings from the database template rather than trusting sample field labels.
        _ = try ContactField.read(template.blob, isTemplate: true)
        var lines: [String] = []
        for row in rows where row.type == 0x10001309 && !row.deleted {
            let fields = try ContactField.read(row.blob, isTemplate: false)
            lines += ContactField.vCard(fields, id: row.id, guid: row.guid)
        }
        return InterchangeText.encode(lines)
    }
}

private struct ContactTable {
    var name: String
    var token: UInt32
    var columns: [ContactColumn]

    static func read(_ reader: inout BinaryReader) throws -> Self {
        let name = try reader.descriptor(), count = try reader.cardinal()
        try require(count > 0 && count <= 64, "invalid column count")
        var columns: [ContactColumn] = []
        for _ in 0..<count {
            let name = try reader.descriptor(), type = try reader.u8(), attributes = try reader.u8()
            try require(type <= 16 && attributes & ~3 == 0, "invalid column type or attributes")
            if (11...13).contains(type) { _ = try reader.u8() }
            columns.append(ContactColumn(name: name, type: type, attributes: attributes))
        }
        let clustering = try reader.cardinal()
        try require((1...16).contains(clustering), "invalid DBMS clustering")
        let token = try reader.u32(), indexes = try reader.cardinal()
        try require(indexes <= 32, "invalid index count")
        for _ in 0..<indexes {
            _ = try reader.descriptor()
            _ = try reader.take(2) // comparison and uniqueness
            let keys = try reader.cardinal()
            try require(keys > 0 && keys <= count, "invalid index key count")
            for _ in 0..<keys { _ = try reader.descriptor(); _ = try reader.take(2) }
            _ = try reader.u32()
        }
        return Self(name: name, token: token, columns: columns)
    }
}

private struct ContactColumn {
    var name: String
    var type: UInt8
    var attributes: UInt8
}

private struct ContactRow {
    var id: UInt32
    var type: UInt32
    var guid: String
    var deleted: Bool
    var blob: [UInt8]

    static func read(_ bytes: [UInt8], store: PermanentStore) throws -> Self {
        var reader = BinaryReader(bytes)
        let id = try reader.u32()
        var bits = ContactBits()
        let type = try bits.read(&reader) ? reader.u32() : 0
        let guid = try bits.read(&reader) ? BinaryReader.text(reader.take(Int(reader.u8()))) : ""
        if try bits.read(&reader) { _ = try reader.take(8) } // modification time
        if try bits.read(&reader) { _ = try reader.u32() } // attributes
        if try bits.read(&reader) { _ = try reader.u32() } // replication count
        let deleted = try bits.read(&reader) ? bits.read(&reader) : false
        var blob: [UInt8] = []
        if try bits.read(&reader) {
            if try bits.read(&reader) { blob = try reader.take(Int(reader.u8())) }
            else {
                blob = try store.get(reader.u32())
                try require(blob.count == Int(reader.u32()), "contact blob length mismatch")
            }
        }
        try require(reader.remaining == 0, "contact row \(id) has \(reader.remaining) unconsumed bytes")
        return Self(id: id, type: type, guid: guid, deleted: deleted, blob: blob)
    }
}

private struct ContactBits {
    var value: UInt8 = 0
    var remaining = 0

    mutating func read(_ reader: inout BinaryReader) throws -> Bool {
        if remaining == 0 { value = try reader.u8(); remaining = 8 }
        let result = value & 1 != 0
        value >>= 1
        remaining -= 1
        return result
    }
}

private struct ContactField {
    var index: Int
    var text: String

    // ER5's template indexes; each is checked against its serialized vCard mapping UID.
    static let mappings: [UInt32] = [
        0x1000402e, 0x1000402e, 0x1000402e, 0x1000402e, 0x1000402e,
        0x1000402a, 0x1000402a, 0x1000402a, 0x1000402a, 0x10004020,
        0x10004dea, 0x10004deb, 0x1000401d, 0x10004dec, 0x10004ded, 0x10004dee, 0x10004def,
        0x10004026, 0x1000402c, 0x1000402a, 0x1000402a, 0x1000402a, 0x1000402a, 0x10004020,
        0x1000402d, 0x10004dea, 0x10004deb, 0x1000401d, 0x10004dec, 0x10004ded, 0x10004dee, 0x10004def,
        0x1000401f, 0x10004025, 0x1000402f,
    ]

    static func read(_ bytes: [UInt8], isTemplate: Bool) throws -> [Self] {
        var reader = BinaryReader(bytes)
        let offset = Int(try reader.u32())
        try require(offset >= 4 && offset <= bytes.count - 4, "invalid contact field directory")
        reader.position = offset
        let count = Int(try reader.u32())
        try require(count <= min(4096, reader.remaining / 8), "invalid contact field count")
        if isTemplate {
            guard count == mappings.count else { throw PsionConversionError.unsupported("Contacts template field count") }
        }
        var directory: [(attributes: UInt32, offset: Int)] = []
        for _ in 0..<count { directory.append((try reader.u32(), Int(try reader.u32()))) }
        try reader.end()
        var fields: [Self] = []
        var ranges: [Range<Int>] = []
        for position in 0..<count {
            let entry = directory[position]
            try require(entry.offset >= 4 && entry.offset < offset, "invalid field boundary")
            var field = BinaryReader(bytes, position: entry.offset)
            var valueOffset = entry.offset
            var index = Int(entry.attributes >> 22)
            if entry.attributes & 0x200 == 0 {
                // Full field headers point backwards to separately stored values.
                // Template-inherited fields point directly to the value instead.
                valueOffset = Int(try field.u32())
                let content = try field.u32()
                if isTemplate { index = Int(content >> 22) }
                let uidCount = Int((entry.attributes >> 18) & 15) + 1
                var mapping: UInt32 = 0
                for _ in 0..<uidCount { mapping = try field.u32() }
                guard index < mappings.count && mapping == mappings[index] else {
                    throw PsionConversionError.unsupported("Contacts field mapping")
                }
            }
            try require(index < mappings.count, "invalid template field reference")
            if isTemplate { try require(index == position, "unexpected Contacts template order") }
            if entry.attributes & 0x100 != 0 {
                let length = Int(try field.u32())
                if length > 0 {
                    let label = try field.descriptor()
                    try require(label.utf16.count == length, "contact label length mismatch")
                }
            }
            try require(field.position <= offset, "contact header crosses field directory")
            if entry.attributes & 0x200 == 0 { ranges.append(entry.offset..<field.position) }
            try require(valueOffset >= 4 && valueOffset < offset, "invalid contact value offset")
            var value = BinaryReader(bytes, position: valueOffset)
            let storage = (entry.attributes >> 12) & 3
            let text: String
            switch storage {
            case 0:
                let length = Int(try value.u32())
                text = length == 0 ? "" : try value.descriptor()
                try require(text.utf16.count == length, "contact text length mismatch")
            case 3:
                let low = UInt64(try value.u32()), high = UInt64(try value.u32())
                let time = Int64(bitPattern: low | high << 32)
                if time == Int64.min { text = "" }
                else {
                    guard index == 32 else { throw PsionConversionError.unsupported("non-birthday date fields") }
                    let date = Date(timeIntervalSince1970: Double(time) / 1_000_000 - 62_168_256_000)
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                    try require((1...9999).contains(calendar.component(.year, from: date)), "birthday outside supported range")
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "yyyy-MM-dd"
                    text = formatter.string(from: date)
                }
            default: throw PsionConversionError.unsupported("Contacts binary or agent fields")
            }
            try require(value.position <= offset, "contact value crosses field directory")
            ranges.append(valueOffset..<value.position)
            if !isTemplate { fields.append(Self(index: index, text: text)) }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var consumed = 4
        for range in ranges {
            try require(range.lowerBound == consumed, "unconsumed or overlapping Contacts field storage")
            consumed = range.upperBound
        }
        try require(consumed == offset, "unconsumed Contacts field bytes")
        return fields
    }

    static func vCard(_ fields: [Self], id: UInt32, guid: String) -> [String] {
        func values(_ index: Int) -> [String] { fields.filter { $0.index == index }.map(\.text).filter { !$0.isEmpty } }
        func value(_ index: Int) -> String { values(index).joined(separator: "\n") }
        func escaped(_ index: Int) -> String { InterchangeText.escape(value(index)) }
        let name = [value(0), value(1), value(2), value(3), value(4)].filter { !$0.isEmpty }.joined(separator: " ")
        let formattedName = !value(34).isEmpty ? value(34) : !name.isEmpty ? name : !value(17).isEmpty ? value(17) : "Unnamed contact"
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "UID:psion-\(InterchangeText.escape(guid.isEmpty ? String(id) : guid))",
                     "FN:\(InterchangeText.escape(formattedName))", "N:\([escaped(3), escaped(1), escaped(2), escaped(0), escaped(4)].joined(separator: ";"))"]
        let phones = [(5, "HOME,CELL"), (6, "HOME,VOICE"), (7, "HOME,FAX"), (8, "HOME,PAGER"),
                      (19, "WORK,CELL"), (20, "WORK,VOICE"), (21, "WORK,FAX"), (22, "WORK,PAGER")]
        for (index, type) in phones {
            for text in values(index) { lines.append("TEL;TYPE=\(type):\(InterchangeText.escape(text))") }
        }
        for (index, type) in [(9, "HOME"), (23, "WORK")] {
            for text in values(index) { lines.append("EMAIL;TYPE=\(type),INTERNET:\(InterchangeText.escape(text))") }
        }
        for (indexes, type) in [(Array(10...16), "HOME"), (Array(25...31), "WORK")] {
            if indexes.contains(where: { !value($0).isEmpty }) {
                lines.append("ADR;TYPE=\(type):" + indexes.map(escaped).joined(separator: ";"))
            }
        }
        for (index, property) in [(17, "ORG"), (18, "TITLE"), (24, "URL"), (32, "BDAY"), (33, "NOTE")] {
            for text in values(index) { lines.append("\(property):\(InterchangeText.escape(text))") }
        }
        lines.append("END:VCARD")
        return lines
    }
}
