import Foundation

// Small, invented ER5 files keep the conversion tests reproducible without personal data.
enum SyntheticStore {
    static func integer(_ value: UInt32, bytes: Int = 4) -> [UInt8] {
        (0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    static func cardinal(_ value: Int) -> [UInt8] {
        if value < 128 { return integer(UInt32(value << 1), bytes: 1) }
        if value < 16384 { return integer(UInt32(value << 2 | 1), bytes: 2) }
        return integer(UInt32(value << 3 | 3))
    }

    static func descriptor(_ value: String) -> [UInt8] {
        let bytes = Array(value.data(using: .windowsCP1252)!)
        return cardinal(bytes.count * 2 + 1) + bytes
    }

    static func store(uid2: UInt32, uid3: UInt32, streams: [[UInt8]]) -> Data {
        let uids = integer(0x10000050) + integer(uid2) + integer(uid3)
        let checked = UInt32(crc(stride(from: 0, to: 12, by: 2).map { uids[$0] })) |
            UInt32(crc(stride(from: 1, to: 12, by: 2).map { uids[$0] })) << 16
        var file = uids + integer(checked) + Array(repeating: UInt8(0), count: 14)
        var offsets: [UInt32] = []
        for stream in streams {
            if stream.isEmpty { offsets.append(UInt32.max); continue }
            offsets.append(UInt32(file.count + 2 - 32))
            file += integer(0x4000 | UInt32(stream.count), bytes: 2) + stream
        }
        let reference = UInt32(file.count + 2 - 32 + 12)
        var toc = integer(1) + integer(0) + integer(UInt32(streams.count))
        for offset in offsets { toc += [0] + integer(offset) }
        file += integer(0x8000 | UInt32(toc.count), bytes: 2) + toc
        let header = integer(reference * 2) + integer(0) + integer(reference)
        file.replaceSubrange(16..<30, with: header + integer(UInt32(crc(header)), bytes: 2))
        return Data(file)
    }

    static func agenda(recurrence: UInt8 = 2, deleted: Bool = false, version: UInt32 = 84) -> Data {
        let root = cardinal(1) + integer(0x100000f1) + integer(2)
        var model: [UInt8] = [1, 1] + integer(version, bytes: 2)
        for reference: UInt32 in [4, 4, 3, 4, 4, 4, 4, 4] { model += integer(reference) }
        let clusters = cardinal(1) + integer(4)
        var cluster: [UInt8] = [0, 1, 0] + integer(4) + integer(0x1a, bytes: 2) + integer(42)
        cluster += [0, deleted ? 1 : 0, 0] + integer(0, bytes: 2) + integer(0, bytes: 2)
        cluster += [recurrence] + integer(16000, bytes: 2) + integer(16031, bytes: 2) + integer(1, bytes: 2) + [0, 1]
        if recurrence == 2 { cluster += [2, 1] }
        cluster += [1] + cardinal(1) + integer(16007, bytes: 2)
        cluster += descriptor("") + integer(1455)
        if !deleted {
            let text = Array("Project Meeting".utf8) + [UInt8(6)]
            cluster += [8, 0, 0] + cardinal(text.count) + text
        }
        cluster += integer(16000, bytes: 2) + integer(840, bytes: 2) + integer(16000, bytes: 2) + integer(900, bytes: 2)
        return store(uid2: 0x1000006d, uid3: 0x10000084, streams: [root, model, clusters, cluster])
    }

    static func contacts(includeCard: Bool = true, includeIndex: Bool = false) -> Data {
        let columns: [(String, UInt8, UInt8)] = [("CM_Identifier", 5, 3), ("CM_Type", 5, 0), ("CM_UIDString", 11, 0),
            ("CM_Last_modified", 10, 0), ("CM_Attributes", 6, 0), ("CM_ReplicationCount", 6, 0), ("CM_DeleteFlag", 0, 0), ("CM_TextBlob", 16, 0)]
        var schema = integer(0x10000069) + integer(0x100) + [0] + cardinal(1) + descriptor("CONTACTS") + cardinal(8)
        for (name, type, attributes) in columns {
            schema += descriptor(name) + [type, attributes]
            if type == 11 { schema.append(244) }
        }
        schema += cardinal(16) + integer(4) + cardinal(includeIndex ? 1 : 0)
        if includeIndex {
            schema += descriptor("cnt_id_index") + [0, 1] + cardinal(1) + descriptor("CM_Identifier") + [0, 0] + integer(7)
        }
        let mappings: [UInt32] = [0x1000402e, 0x1000402e, 0x1000402e, 0x1000402e, 0x1000402e,
            0x1000402a, 0x1000402a, 0x1000402a, 0x1000402a, 0x10004020,
            0x10004dea, 0x10004deb, 0x1000401d, 0x10004dec, 0x10004ded, 0x10004dee, 0x10004def,
            0x10004026, 0x1000402c, 0x1000402a, 0x1000402a, 0x1000402a, 0x1000402a, 0x10004020,
            0x1000402d, 0x10004dea, 0x10004deb, 0x1000401d, 0x10004dec, 0x10004ded, 0x10004dee, 0x10004def,
            0x1000401f, 0x10004025, 0x1000402f]
        var template = integer(0), headers: [(UInt32, UInt32)] = []
        for (index, mapping) in mappings.enumerated() {
            let valueOffset = UInt32(template.count)
            let storage: UInt32 = index == 32 ? 0x3000 : 0
            template += index == 32 ? integer(0) + integer(0x80000000) : integer(0)
            headers.append((storage, UInt32(template.count)))
            template += integer(valueOffset) + integer(UInt32(index) << 22) + integer(mapping)
        }
        template = finish(template, headers: headers)
        var card = integer(0)
        headers = []
        for (index, text) in [(1, "Alex"), (3, "Café"), (5, "+61 400000000"), (9, "alex@example.test"),
                              (12, "1 Sample St"), (33, "Note; comma, slash\\\nNext line")] {
            headers.append((UInt32(index) << 22 | 0x200, UInt32(card.count)))
            card += integer(UInt32(text.utf16.count)) + descriptor(text)
        }
        // 2000-01-01 in Symbian microseconds since year zero.
        let birthday = UInt64(62_168_256_000 + 946_684_800) * 1_000_000
        headers.append((UInt32(32) << 22 | 0x3200, UInt32(card.count)))
        card += integer(UInt32(truncatingIfNeeded: birthday)) + integer(UInt32(birthday >> 32))
        card = finish(card, headers: headers)
        func row(id: UInt32, type: UInt32, blobID: UInt32, size: Int) -> [UInt8] {
            integer(id) + [0xbf] + integer(type) + [6] + Array("sample".utf8) +
            Array(repeating: UInt8(0), count: 8) + integer(4) + integer(0) + [0] + integer(blobID) + integer(UInt32(size))
        }
        let templateRow = row(id: 0, type: 0x1000130b, blobID: 5, size: template.count)
        let cardRow = row(id: 1, type: 0x10001309, blobID: 6, size: card.count)
        let cluster = integer(0) + integer(includeCard ? 3 : 1, bytes: 2) + cardinal(templateRow.count) +
            (includeCard ? cardinal(cardRow.count) : []) + templateRow + (includeCard ? cardRow : [])
        let token = integer(3) + integer(includeCard ? 50 : 49) + cardinal(includeCard ? 2 : 1) + integer(includeCard ? 2 : 1)
        var streams = [schema, [], cluster, token, template, card]
        if includeIndex {
            let index = integer(128) + integer(128) + [1] + cardinal(includeCard ? 2 : 1) + integer(0x41) + Array(repeating: UInt8(0), count: 16)
            var page = integer(includeCard ? 2 : 1) + integer(0) + integer(48) + integer(0)
            if includeCard { page += integer(49) + integer(1) }
            page += Array(repeating: 0, count: 512 - page.count)
            streams += [index, page]
        }
        return store(uid2: 0x10000ebe, uid3: 0, streams: streams)
    }

    static func emptyAgenda() -> Data {
        let root = cardinal(1) + integer(0x100000f1) + integer(2)
        let references: [UInt32] = [4, 4, 3, 5, 6, 7, 8, 9]
        let model: [UInt8] = [1, 1, 144, 0] + references.flatMap { integer($0) }
        return store(uid2: 0x1000006d, uid3: 0x10000084,
                     streams: [root, model, cardinal(0), cardinal(0), [], integer(4), [0], [], Array(repeating: 0, count: 12)])
    }

    private static func finish(_ payload: [UInt8], headers: [(UInt32, UInt32)]) -> [UInt8] {
        var result = payload
        result.replaceSubrange(0..<4, with: integer(UInt32(payload.count)))
        result += integer(UInt32(headers.count))
        for (attributes, offset) in headers { result += integer(attributes) + integer(offset) }
        return result
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
