import Foundation

/// Preserves unmodified native records byte-for-byte; sync never rebuilds the whole diary from ICS.
public struct AgendaSyncDocument {
    public var events: [AgendaSyncEvent] { records.filter { !$0.entry.deleted && $0.entry.type != 1 }.map(\.event) }
    private var data: Data
    private var records: [NativeRecord]
    private var clusterIDs: [UInt32]

    public init(_ data: Data) throws {
        _ = try AgendaConverter.convert(data)
        let store = try PermanentStore(data)
        var root = BinaryReader(try store.get(store.root))
        let count = try root.cardinal()
        var modelID: UInt32 = 0
        for _ in 0..<count {
            let key = try root.u32(), id = try root.u32()
            if key == 0x100000f1 { modelID = id }
        }
        var model = BinaryReader(try store.get(modelID), position: 12)
        var clusters = BinaryReader(try store.get(model.u32()))
        let clusterCount = try clusters.cardinal()
        var ids: [UInt32] = [], records: [NativeRecord] = []
        for _ in 0..<clusterCount {
            let id = try clusters.u32()
            ids.append(id)
            var reader = BinaryReader(try store.get(id))
            _ = try reader.u8()
            let count = try reader.u8()
            var batch: [NativeRecord] = []
            for _ in 0..<count {
                let position = reader.position
                let entry = try AgendaEntry.read(&reader, store: store)
                batch.append(NativeRecord(entry: entry, basic: Array(reader.bytes[position..<reader.position]), extended: []))
            }
            for index in batch.indices where batch[index].entry.flags & 0x1000 != 0 {
                let position = reader.position
                try batch[index].entry.readExtended(&reader)
                batch[index].extended = Array(reader.bytes[position..<reader.position])
            }
            records += batch
        }
        self.data = data
        self.records = records
        self.clusterIDs = ids
        let idsOfEvents = self.events.map(\.id)
        guard Set(idsOfEvents).count == idsOfEvents.count else {
            throw PsionImportError.invalid("duplicate Agenda sync identifiers")
        }
    }

    /// Omitted events are preserved. Only explicitly supplied updates and deletions are applied.
    public func applying(upserts: [AgendaSyncEvent], deleting: Set<String>, timeZone: TimeZone,
                         timestamp: Date = Date()) throws -> Data {
        guard Set(upserts.map(\.id)).count == upserts.count, deleting.isDisjoint(with: upserts.map(\.id)) else {
            throw PsionImportError.invalid("overlapping Agenda sync operations")
        }
        let live = Dictionary(uniqueKeysWithValues: records.filter { !$0.entry.deleted && $0.entry.type != 1 }.map { ($0.event.id, $0) })
        guard deleting.allSatisfy({ live[$0] != nil }) else { throw PsionImportError.invalid("an Agenda entry disappeared during sync") }
        if deleting.isEmpty, upserts.allSatisfy({ live[$0.id]?.event.content == $0.content }) { return data }
        var updates = Dictionary(uniqueKeysWithValues: upserts.map { ($0.id, $0) })
        var store = try PermanentStore(data)
        let modified = try CalendarImportDate.from(timestamp, timeZone: timeZone)
        for id in clusterIDs {
            let batch = records.filter { $0.entry.entryID & 0x0fffffff == id }
            var basics: [[UInt8]] = [], extensions: [[UInt8]] = []
            for record in batch {
                let entry = record.entry, key = record.event.id
                let isCurrentRecord = live[key].map { $0.entry.uniqueID == entry.uniqueID } ?? true
                guard entry.type != 1, isCurrentRecord,
                      (!entry.deleted && deleting.contains(key)) || updates[key] != nil else {
                    basics.append(record.basic); extensions.append(record.extended)
                    continue
                }
                let content = updates.removeValue(forKey: key)?.content ?? record.event.content
                if !deleting.contains(key), content == record.event.content {
                    basics.append(record.basic); extensions.append(record.extended)
                    continue
                }
                guard !entry.embedded else { throw PsionImportError.unsupported("modifying or deleting Agenda entries with embedded content") }
                guard (content.repeatRule != nil) == (entry.repeatRule != nil) else {
                    throw PsionImportError.unsupported("changing an existing entry between repeating and non-repeating")
                }
                var imported = try content.imported(identifier: key, timeZone: timeZone)
                imported.globalID = entry.globalID
                imported.replication = entry.replication
                if entry.type == 3 {
                    guard content.start.minute == nil, content.repeatRule?.frequency == .yearly else {
                        throw PsionImportError.unsupported("changing an anniversary into a different entry type")
                    }
                    imported.type = 3
                    imported.baseYear = entry.baseYear
                    imported.anniversaryOptions = entry.anniversaryOptions
                }
                // Reject flags whose payload is not encoded by the current writer.
                let supportedFlags: UInt16 = 0x153e
                guard entry.flags & ~supportedFlags == 0 else {
                    throw PsionImportError.unsupported("updating this Agenda entry's native metadata")
                }
                basics.append(try imported.basic(entryID: entry.entryID, uniqueID: entry.uniqueID,
                                                 modified: modified, deleted: deleting.contains(key)))
                if record.extended.isEmpty {
                    extensions.append(try imported.extended(created: modified))
                } else {
                    // Preserve the original creation date and all trailing replication metadata.
                    var reader = BinaryReader(record.extended, position: 4)
                    _ = try reader.take(Int(reader.u32()))
                    _ = try reader.take(Int(reader.u32()))
                    var writer = BinaryWriter()
                    writer.u32(0x110000f1)
                    let global = try BinaryWriter.text(entry.globalID), place = try BinaryWriter.text(content.location)
                    writer.u32(UInt32(global.count)); writer.append(global)
                    writer.u32(UInt32(place.count)); writer.append(place)
                    writer.append(Array(reader.bytes[reader.position...]))
                    extensions.append(writer.bytes)
                }
            }
            store.streams[id] = Array(try store.get(id).prefix(2)) + basics.flatMap { $0 } + extensions.flatMap { $0 }
        }
        var result = try store.encoded()
        if !updates.isEmpty {
            var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Reconnect//Agenda Sync//EN"]
            for event in updates.values.sorted(by: { $0.id < $1.id }) {
                guard event.id.hasPrefix("global:"), event.id.dropFirst(7).count == 32 else {
                    throw PsionImportError.invalid("new sync entries require a 32-byte global identifier")
                }
                var eventLines = try event.content.lines(identifier: event.id)
                eventLines.insert("X-PSION-GLOBAL-ID:" + String(event.id.dropFirst(7)), at: 1)
                lines += eventLines
            }
            lines.append("END:VCALENDAR")
            result = try AgendaImporter.convert(InterchangeText.encode(lines), using: result, mode: .merge,
                                                timeZone: timeZone, timestamp: timestamp).data
        }
        let verified = Dictionary(uniqueKeysWithValues: try Self(result).events.map { ($0.id, $0.content) })
        for event in upserts where verified[event.id] != event.content {
            throw PsionImportError.invalid("an Agenda sync update did not round-trip")
        }
        guard deleting.allSatisfy({ verified[$0] == nil }) else { throw PsionImportError.invalid("an Agenda sync deletion did not round-trip") }
        return result
    }
}

private struct NativeRecord {
    var entry: AgendaEntry
    var basic: [UInt8]
    var extended: [UInt8]

    var event: AgendaSyncEvent {
        let allDay = entry.type == 2 || entry.type == 3 || entry.flags & 256 != 0
        var rule: AgendaSyncContent.RepeatRule?
        if let native = entry.repeatRule {
            rule = .init(frequency: native.kind == 1 ? .daily : native.kind == 2 ? .weekly : .yearly,
                         interval: Int(native.interval), untilDay: native.forever ? nil : native.end,
                         weekdays: native.kind == 2 ? (0..<7).filter { native.days & (1 << $0) != 0 } : [],
                         weekStart: native.kind == 2 ? native.firstDay.trailingZeroBitCount : 0,
                         excludedDays: native.exceptions.sorted())
        }
        let identifier = entry.globalID.isEmpty ? "native:\(entry.uniqueID)" : "global:\(entry.globalID)"
        return AgendaSyncEvent(id: identifier, content: .init(text: entry.summary, location: entry.location,
            start: .init(day: entry.start ?? 0, minute: allDay ? nil : entry.startMinute),
            end: .init(day: (entry.end ?? 0) + (allDay ? 1 : 0), minute: allDay ? nil : entry.endMinute),
            repeatRule: rule, alarmMinutes: entry.alarmPreTime.map { 1440 - Int($0) }, tentative: entry.flags & 1024 != 0))
    }
}
