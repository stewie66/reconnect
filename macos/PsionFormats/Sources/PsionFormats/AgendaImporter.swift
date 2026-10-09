import Foundation
import CryptoKit

/// Adds supported iCalendar events to a copy of an ER5 Agenda store.
public enum AgendaImporter {
    public static func convert(_ calendar: Data, using base: Data, mode: PsionImportMode,
                               timeZone: TimeZone = .current, timestamp: Date = Date()) throws -> PsionImportResult {
        let events = try readCalendar(calendar, timeZone: timeZone)
        // Validate all existing entries before altering any native streams.
        _ = try AgendaConverter.convert(base, timestamp: timestamp)
        var store = try PermanentStore(base)
        var root = BinaryReader(try store.get(store.root))
        let count = try root.cardinal()
        var modelID: UInt32 = 0
        for _ in 0..<count {
            let key = try root.u32(), id = try root.u32()
            if key == 0x100000f1 { modelID = id }
        }
        var model = BinaryReader(try store.get(modelID), position: 4)
        var references: [UInt32] = []
        for _ in 0..<8 { references.append(try model.u32()) }
        var set = BinaryReader(try store.get(references[2]))
        let clusterCount = try set.cardinal()
        var clusterIDs: [UInt32] = [], existing: Set<String> = [], exportedUIDs: Set<String> = []
        let fingerprint = SHA256.hash(data: base).prefix(8).map { String(format: "%02x", $0) }.joined()
        var maximumID: UInt32 = 0
        var liveCount = 0
        for _ in 0..<clusterCount {
            let id = try set.u32()
            clusterIDs.append(id)
            var reader = BinaryReader(try store.get(id), position: 1)
            let records = try reader.u8()
            var entries: [AgendaEntry] = []
            for _ in 0..<records {
                let entry = try AgendaEntry.read(&reader, store: store)
                maximumID = max(maximumID, entry.uniqueID)
                exportedUIDs.insert("psion-\(fingerprint)-\(entry.uniqueID)@agenda.local")
                if !entry.deleted { liveCount += 1 }
                entries.append(entry)
            }
            for index in entries.indices where entries[index].flags & 0x1000 != 0 {
                try entries[index].readExtended(&reader)
                if !entries[index].globalID.isEmpty { existing.insert(entries[index].globalID) }
            }
        }
        guard mode != .createNew || liveCount == 0 else {
            throw PsionImportError.invalid("creating a new Agenda requires an empty Psion Agenda template")
        }
        var counter = BinaryReader(try store.get(references[4]))
        var uniqueID = max(try counter.u32(), maximumID)
        try counter.end()
        var manager = BinaryReader(try store.get(references[7]))
        var heads = try [manager.u32(), manager.u32(), manager.u32()]
        try manager.end()
        var additions: [CalendarImportEvent] = []
        for event in events {
            if exportedUIDs.contains(event.uid) { continue }
            if existing.insert(event.globalID).inserted { additions.append(event) }
        }
        if additions.isEmpty { return PsionImportResult(data: base, addedCount: 0, skippedCount: events.count) }
        let modified = try CalendarImportDate.from(timestamp, timeZone: timeZone)
        guard UInt64(uniqueID) + UInt64(additions.count) <= UInt64(UInt32.max) else {
            throw PsionImportError.invalid("Agenda unique IDs are exhausted")
        }
        for repeating in [false, true] {
            let group = additions.filter { ($0.repeatRule != nil) == repeating }
            for offset in stride(from: 0, to: group.count, by: 16) {
                let batch = Array(group[offset..<min(offset + 16, group.count)])
                let id = try store.add([])
                var writer = BinaryWriter()
                writer.u8(repeating ? 1 : 2); writer.u8(UInt8(batch.count))
                for (slot, event) in batch.enumerated() {
                    uniqueID += 1
                    writer.append(try event.basic(entryID: id | UInt32(slot) << 28, uniqueID: uniqueID, modified: modified))
                }
                for event in batch { writer.append(try event.extended(created: modified)) }
                store.streams[id] = writer.bytes
                clusterIDs.append(id)
                heads[repeating ? 2 : 0] = batch.count == 16 ? 0 : id
            }
        }
        if !additions.isEmpty {
            var clusters = BinaryWriter()
            try clusters.cardinal(clusterIDs.count)
            for id in clusterIDs { clusters.u32(id) }
            store.streams[references[2]] = clusters.bytes
            store.streams[references[4]] = BinaryWriter.integer(uniqueID)
            store.streams[references[7]] = heads.flatMap { BinaryWriter.integer($0) }
        }
        let result = try store.encoded()
        _ = try AgendaConverter.convert(result, timestamp: timestamp)
        return PsionImportResult(data: result, addedCount: additions.count, skippedCount: events.count - additions.count)
    }

    private static func readCalendar(_ data: Data, timeZone: TimeZone) throws -> [CalendarImportEvent] {
        let lines = try CalendarContentLine.read(data)
        var stack: [String] = [], properties: [CalendarContentLine] = [], alarm: [CalendarContentLine] = []
        var events: [CalendarImportEvent] = [], version = false, finished = false, hasAlarm = false
        for line in lines {
            if line.name == "BEGIN" {
                guard !finished, line.parameters.isEmpty else { throw PsionImportError.invalid("invalid component boundary") }
                let component = line.value.uppercased()
                if stack.isEmpty {
                    guard component == "VCALENDAR" else { throw PsionImportError.invalid("expected VCALENDAR") }
                } else if stack == ["VCALENDAR"] {
                    guard component == "VEVENT" else { throw PsionImportError.unsupported("the \(component) component") }
                    properties = []; alarm = []; hasAlarm = false
                } else if stack == ["VCALENDAR", "VEVENT"] {
                    guard component == "VALARM", !hasAlarm else { throw PsionImportError.unsupported("multiple alarms or nested event components") }
                    hasAlarm = true
                } else { throw PsionImportError.invalid("invalid component nesting") }
                stack.append(component)
            } else if line.name == "END" {
                guard line.parameters.isEmpty, stack.last == line.value.uppercased() else {
                    throw PsionImportError.invalid("unbalanced component boundaries")
                }
                if stack == ["VCALENDAR", "VEVENT"] {
                    events.append(try CalendarImportEvent.read(properties, alarm: alarm, timeZone: timeZone))
                }
                if stack == ["VCALENDAR", "VEVENT", "VALARM"] && alarm.isEmpty {
                    throw PsionImportError.invalid("an empty alarm")
                }
                stack.removeLast()
                if stack.isEmpty { finished = true }
            } else if stack == ["VCALENDAR"] {
                if line.name == "VERSION" {
                    guard !version, line.value == "2.0" else { throw PsionImportError.invalid("expected one VERSION:2.0") }
                    version = true
                } else if line.name == "METHOD" {
                    throw PsionImportError.unsupported("scheduling messages with METHOD; export a calendar file")
                } else if !["PRODID", "CALSCALE"].contains(line.name) && !line.name.hasPrefix("X-") {
                    throw PsionImportError.unsupported("the \(line.name) calendar property")
                } else if line.name == "CALSCALE" && line.value.uppercased() != "GREGORIAN" {
                    throw PsionImportError.unsupported("non-Gregorian calendars")
                }
            } else if stack == ["VCALENDAR", "VEVENT"] { properties.append(line) }
            else if stack == ["VCALENDAR", "VEVENT", "VALARM"] { alarm.append(line) }
            else { throw PsionImportError.invalid("a property outside its component") }
        }
        guard stack.isEmpty, finished, version, !events.isEmpty else { throw PsionImportError.invalid("an incomplete or empty calendar") }
        return events
    }
}
