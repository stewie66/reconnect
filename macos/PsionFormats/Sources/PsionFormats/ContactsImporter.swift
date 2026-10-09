import Foundation

public enum ContactsImporter {
    public static func convert(_ vCards: Data, using base: Data, mode: PsionImportMode,
                               timestamp: Date = Date()) throws -> PsionImportResult {
        let cards = try readCards(vCards)
        _ = try ContactsConverter.convert(base)
        var store = try PermanentStore(base)
        var schema = BinaryReader(try store.get(store.root), position: 9)
        let tableCount = try schema.cardinal()
        var contacts: ContactTable?
        for _ in 0..<tableCount {
            let table = try ContactTable.read(&schema)
            if table.name == "CONTACTS" { contacts = table }
        }
        guard let table = contacts, table.indexes.count == 1, let index = table.indexes.first,
              index.name == "cnt_id_index", index.comparison == 0, index.unique == 1,
              index.columns == ["CM_Identifier"], index.options == [[0, 0]] else {
            throw PsionImportError.unsupported("this Contacts index configuration")
        }
        var token = BinaryReader(try store.get(table.token))
        var head = try token.u32()
        _ = try token.u32()
        let count = try token.cardinal()
        var nextID = try token.u32()
        var lastCluster: UInt32 = 0, existing: Set<String> = [], entries: [ContactImportIndex.Entry] = []
        var liveCards = 0, maximumID: UInt32 = 0
        while head != 0 {
            lastCluster = head
            var cluster = BinaryReader(try store.get(head))
            let next = try cluster.u32(), membership = try cluster.u16()
            var lengths: [(Int, Int)] = []
            for slot in 0..<16 where membership & (1 << slot) != 0 { lengths.append((slot, try cluster.cardinal())) }
            for (slot, length) in lengths {
                let row = try ContactRow.read(cluster.take(length), store: store)
                entries.append(ContactImportIndex.Entry(recordID: head << 4 | UInt32(slot), contactID: row.id))
                maximumID = max(maximumID, row.id)
                if row.type == 0x10001309 && !row.deleted { liveCards += 1 }
                if !row.guid.isEmpty { existing.insert(row.guid) }
            }
            head = next
        }
        try ContactImportIndex.validate(store.get(index.token), entries: entries, store: store)
        guard mode != .createNew || liveCards == 0 else {
            throw PsionImportError.invalid("creating a new Contacts file requires an empty Psion Contacts template")
        }
        guard maximumID < UInt32(Int32.max) else { throw PsionImportError.invalid("Contacts identifiers are exhausted") }
        nextID = max(nextID, maximumID + 1)
        var additions: [VCardImportContact] = []
        for card in cards where existing.insert(card.guid).inserted { additions.append(card) }
        guard UInt64(nextID) + UInt64(additions.count) <= UInt64(Int32.max) else {
            throw PsionImportError.invalid("Contacts identifiers are exhausted")
        }
        if additions.isEmpty { return PsionImportResult(data: base, addedCount: 0, skippedCount: cards.count) }
        let time = (timestamp.timeIntervalSince1970 + 62_168_256_000) * 1_000_000
        guard time.isFinite, time >= 0, time < Double(Int64.max) else { throw PsionImportError.invalid("a modification date outside the native range") }
        let modified = UInt64(time)
        var lastCount = 0
        for offset in stride(from: 0, to: additions.count, by: 16) {
            let batch = Array(additions[offset..<min(offset + 16, additions.count)])
            let id = try store.add([])
            // Keep all existing row bytes and record IDs; only append to the cluster chain.
            var previous = try store.get(lastCluster)
            previous.replaceSubrange(0..<4, with: BinaryWriter.integer(id))
            store.streams[lastCluster] = previous
            var rows: [[UInt8]] = []
            for (slot, card) in batch.enumerated() {
                let blob = try card.blob(), guid = try BinaryWriter.text(card.guid)
                var row = BinaryWriter()
                row.u32(nextID); row.u8(0xbf); row.u32(0x10001309)
                row.u8(UInt8(guid.count)); row.append(guid)
                row.u32(UInt32(truncatingIfNeeded: modified)); row.u32(UInt32(modified >> 32))
                row.u32(4); row.u32(0)
                if blob.count <= 255 { row.u8(1); row.u8(UInt8(blob.count)); row.append(blob) }
                else { row.u8(0); row.u32(try store.add(blob)); row.u32(UInt32(blob.count)) }
                rows.append(row.bytes)
                entries.append(ContactImportIndex.Entry(recordID: id << 4 | UInt32(slot), contactID: nextID))
                nextID += 1
            }
            var cluster = BinaryWriter()
            cluster.u32(0); cluster.u16(UInt16(truncatingIfNeeded: (UInt32(1) << batch.count) - 1))
            for row in rows { try cluster.cardinal(row.count) }
            for row in rows { cluster.append(row) }
            store.streams[id] = cluster.bytes
            lastCluster = id; lastCount = batch.count
        }
        if lastCount == 16 {
            let id = try store.add([0, 0, 0, 0, 0, 0])
            var previous = try store.get(lastCluster)
            previous.replaceSubrange(0..<4, with: BinaryWriter.integer(id))
            store.streams[lastCluster] = previous
            lastCluster = id; lastCount = 0
        }
        var updated = BinaryWriter()
        var original = BinaryReader(try store.get(table.token))
        updated.u32(try original.u32()); updated.u32(lastCluster << 4 | UInt32(lastCount))
        try updated.cardinal(count + additions.count); updated.u32(nextID)
        store.streams[table.token] = updated.bytes
        store.streams[index.token] = try ContactImportIndex.write(entries, store: &store)
        let result = try store.encoded()
        _ = try ContactsConverter.convert(result)
        return PsionImportResult(data: result, addedCount: additions.count, skippedCount: cards.count - additions.count)
    }

    private static func readCards(_ data: Data) throws -> [VCardImportContact] {
        let lines = try CalendarContentLine.read(data)
        var properties: [CalendarContentLine] = [], inside = false, cards: [VCardImportContact] = []
        for line in lines {
            if line.name == "BEGIN" {
                guard !inside, line.value.uppercased() == "VCARD", line.parameters.isEmpty else { throw PsionImportError.invalid("invalid vCard boundary") }
                inside = true; properties = []
            } else if line.name == "END" {
                guard inside, line.value.uppercased() == "VCARD", line.parameters.isEmpty else { throw PsionImportError.invalid("unbalanced vCard boundaries") }
                cards.append(try VCardImportContact.read(properties)); inside = false
            } else {
                guard inside else { throw PsionImportError.invalid("a property outside a vCard") }
                var property = line
                if let separator = property.name.lastIndex(of: ".") {
                    property.name = String(property.name[property.name.index(after: separator)...])
                }
                properties.append(property)
            }
        }
        guard !inside, !cards.isEmpty else { throw PsionImportError.invalid("an incomplete or empty vCard file") }
        return cards
    }
}
