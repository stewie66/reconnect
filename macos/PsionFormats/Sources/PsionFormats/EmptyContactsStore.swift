import Foundation

// Native ER5 DBMS 0x100 schema and the standard 35-field Contacts template.
// Generate all records, IDs, indexes and timestamps; no user's file is bundled.
enum EmptyContactsStore {
    static func create(timestamp: Date, identifier: UUID = UUID()) throws -> Data {
        let time = (timestamp.timeIntervalSince1970 + 62_168_256_000) * 1_000_000
        guard time.isFinite, time >= 0, time < Double(Int64.max) else {
            throw PsionImportError.invalid("a creation date outside the native range")
        }
        let created = UInt64(time), blob = try template()
        var row = BinaryWriter()
        row.u32(0); row.u8(0xbf); row.u32(0x1000130b)
        let guid = Array(("rconn-" + identifier.uuidString.replacingOccurrences(of: "-", with: "").lowercased()).utf8)
        row.u8(UInt8(guid.count)); row.append(guid)
        row.u32(UInt32(truncatingIfNeeded: created)); row.u32(UInt32(created >> 32))
        row.u32(4); row.u32(0); row.u8(0); row.u32(10); row.u32(UInt32(blob.count))
        var cluster = BinaryWriter()
        cluster.u32(0); cluster.u16(1); try cluster.cardinal(row.bytes.count); cluster.append(row.bytes)
        var preferences = BinaryWriter()
        preferences.u32(0); preferences.u16(1); try preferences.cardinal(17)
        preferences.u8(7); preferences.u32(0); preferences.u32(3)
        preferences.u32(UInt32(truncatingIfNeeded: created)); preferences.u32(UInt32(created >> 32))
        var store = try PermanentStore(uids: [0x10000050, 0x10000ebe, 0], root: 2, streams: [
            1: Array(repeating: 0, count: 9), 2: try schema(), 3: cluster.bytes,
            4: try token(head: 3, next: 49, count: 1, nextIdentifier: 1), 5: [],
            6: Array(repeating: 0, count: 6), 7: try token(head: 6, next: 96, count: 0, nextIdentifier: 0),
            8: preferences.bytes, 9: try token(head: 8, next: 129, count: 1, nextIdentifier: 0), 10: blob,
        ])
        let index = try ContactImportIndex.write([.init(recordID: 48, contactID: 0)], store: &store)
        store.streams[5] = index
        let data = try store.encoded()
        _ = try ContactsConverter.convert(data)
        return data
    }

    private static func token(head: UInt32, next: UInt32, count: Int, nextIdentifier: UInt32) throws -> [UInt8] {
        var writer = BinaryWriter()
        writer.u32(head); writer.u32(next); try writer.cardinal(count); writer.u32(nextIdentifier)
        return writer.bytes
    }

    private static func schema() throws -> [UInt8] {
        var writer = BinaryWriter()
        writer.u32(0x10000069); writer.u32(0x100); writer.u8(0); try writer.cardinal(3)
        let tables: [(String, [(String, UInt8, UInt8)], UInt32)] = [
            ("CONTACTS", [("CM_Identifier", 5, 3), ("CM_Type", 5, 0), ("CM_UIDString", 11, 0),
                          ("CM_Last_modified", 10, 0), ("CM_Attributes", 6, 0), ("CM_ReplicationCount", 6, 0),
                          ("CM_DeleteFlag", 0, 0), ("CM_TextBlob", 16, 0)], 4),
            ("GROUPS", [("CM_Identifier", 5, 0), ("CM_Members", 16, 0)], 7),
            ("PREFERENCES", [("CM_PrefTemplateId", 5, 0), ("CM_PrefFileVer", 5, 0), ("CM_creationdate", 10, 0)], 9),
        ]
        for (name, columns, token) in tables {
            try writer.descriptor(name); try writer.cardinal(columns.count)
            for (name, type, attributes) in columns {
                try writer.descriptor(name); writer.u8(type); writer.u8(attributes)
                if type == 11 { writer.u8(244) }
            }
            try writer.cardinal(16); writer.u32(token)
            try writer.cardinal(name == "CONTACTS" ? 1 : 0)
            if name == "CONTACTS" {
                try writer.descriptor("cnt_id_index"); writer.append([0, 1]); try writer.cardinal(1)
                try writer.descriptor("CM_Identifier"); writer.append([0, 0]); writer.u32(5)
            }
        }
        return writer.bytes
    }

    private static func template() throws -> [UInt8] {
        let definitions: [(UInt32, UInt32, [UInt32], String)] = [
            (0x11c, 0x200, [0x1000402e], "Title"),
            (0x114, 0x20, [0x1000402e], "First name"),
            (0x11c, 0x80, [0x1000402e], "Middle name"),
            (0x114, 0x10, [0x1000402e], "Last name"),
            (0x11c, 0x100, [0x1000402e], "Suffix"),
            (0x80114, 2, [0x100039db, 0x10003e71, 0x1000402a], "Mobile"),
            (0x40114, 2, [0x100039db, 0x1000402a], "Home tel"),
            (0xc011c, 0, [0x10001791, 0x100039db, 0x100039de, 0x1000402a], "Home fax"),
            (0x8011c, 2, [0x10003e72, 0x100039db, 0x1000402a], "Pager"),
            (0x40114, 0x4000, [0x100039db, 0x10004020], "Home email"),
            (0x8011c, 0, [0x10004df4, 0x100039db, 0x10004dea], "Home PO box"),
            (0x8011c, 0, [0x10004df5, 0x100039db, 0x10004deb], "Home ext address"),
            (0x40114, 0x40, [0x100039db, 0x1000401d], "Home address"),
            (0x80114, 0, [0x10004df6, 0x100039db, 0x10004dec], "Home city"),
            (0x80114, 0, [0x10004df7, 0x100039db, 0x10004ded], "Home region"),
            (0x80114, 0, [0x10004df8, 0x100039db, 0x10004dee], "Home p'code"),
            (0x80114, 0, [0x10004df9, 0x100039db, 0x10004def], "Home country"),
            (0x124, 8, [0x10004026], "Company"),
            (0x124, 0, [0x1000402c], "Job title"),
            (0x8012c, 2, [0x10003e71, 0x100039da, 0x1000402a], "Work mobile"),
            (0x40124, 2, [0x100039da, 0x1000402a], "Work tel"),
            (0xc0124, 0, [0x10001791, 0x100039da, 0x100039de, 0x1000402a], "Work fax"),
            (0x8012c, 2, [0x10003e72, 0x100039da, 0x1000402a], "Work pager"),
            (0x40124, 0x4000, [0x100039da, 0x10004020], "Work email"),
            (0x40124, 0, [0x10004035, 0x1000402d], "Web page"),
            (0x8012c, 0, [0x10004df4, 0x100039da, 0x10004dea], "Work PO box"),
            (0x8012c, 0, [0x10004df5, 0x100039da, 0x10004deb], "Work ext address"),
            (0x40124, 0x40, [0x100039da, 0x1000401d], "Work address"),
            (0x80124, 0, [0x10004df6, 0x100039da, 0x10004dec], "Work city"),
            (0x80124, 0, [0x10004df7, 0x100039da, 0x10004ded], "Work region"),
            (0x80124, 0, [0x10004df8, 0x100039da, 0x10004dee], "Work p'code"),
            (0x80124, 0, [0x10004df9, 0x100039da, 0x10004def], "Work country"),
            (0x4313c, 0, [0x10004034, 0x1000401f], "Birthday"),
            (0x40134, 0, [0x1000401c, 0x10004025], "Notes"),
            (0x105, 0, [0x1000402f], "Display name"),
        ]
        var writer = BinaryWriter(); writer.u32(0)
        var directory: [(UInt32, UInt32)] = []
        for (index, definition) in definitions.enumerated() {
            let (attributes, content, uids, label) = definition
            let valueOffset = UInt32(writer.bytes.count)
            writer.u32(0)
            if index == 32 { writer.u32(0x80000000) } // null Symbian date
            directory.append((attributes, UInt32(writer.bytes.count)))
            writer.u32(valueOffset); writer.u32(UInt32(index) << 22 | content)
            for uid in uids { writer.u32(uid) }
            writer.u32(UInt32(label.utf16.count)); try writer.descriptor(label)
        }
        writer.bytes.replaceSubrange(0..<4, with: BinaryWriter.integer(UInt32(writer.bytes.count)))
        writer.u32(UInt32(directory.count))
        for (attributes, offset) in directory { writer.u32(attributes); writer.u32(offset) }
        return writer.bytes
    }
}
