import Foundation
import CryptoKit

/// Read-only ER5 Agenda 1.1.84 export, based on the validated Python handoff.
public enum AgendaConverter {
    public static func convert(_ data: Data, timestamp: Date = Date()) throws -> Data {
        let store = try PermanentStore(data)
        try require(store.uids[1] == 0x1000006d && store.uids[2] == 0x10000084, "not an Agenda store")
        var root = BinaryReader(try store.get(store.root))
        let count = try root.cardinal()
        try require(count <= root.remaining / 8, "invalid root dictionary size")
        var dictionary: [UInt32: UInt32] = [:]
        for _ in 0..<count {
            let key = try root.u32()
            try require(dictionary[key] == nil, "duplicate root key")
            dictionary[key] = try root.u32()
        }
        try root.end()
        guard let modelID = dictionary[0x100000f1] else { throw PsionConversionError.invalid("missing Agenda model") }
        var model = BinaryReader(try store.get(modelID))
        let major = try model.u8(), minor = try model.u8(), build = try model.u16()
        guard major == 1 && minor == 1 && build == 84 else {
            throw PsionConversionError.unsupported("Agenda model \(major).\(minor).\(build)")
        }
        var references: [UInt32] = []
        for _ in 0..<8 {
            let reference = try model.u32()
            _ = try store.get(reference)
            references.append(reference)
        }
        try model.end()
        var clusters = BinaryReader(try store.get(references[2]))
        let clusterCount = try clusters.cardinal()
        try require(clusterCount <= clusters.remaining / 4, "invalid cluster count")
        var seenClusters: Set<UInt32> = [], seenIDs: Set<UInt32> = []
        var entries: [AgendaEntry] = []
        for _ in 0..<clusterCount {
            let id = try clusters.u32()
            try require(seenClusters.insert(id).inserted, "duplicate Agenda cluster")
            var reader = BinaryReader(try store.get(id))
            let kind = try reader.u8(), recordCount = try reader.u8()
            try require(kind <= 2 && recordCount <= 16, "invalid Agenda cluster header")
            var records: [AgendaEntry] = [], slots: Set<UInt32> = []
            for _ in 0..<recordCount {
                let entry = try AgendaEntry.read(&reader, store: store)
                try require(entry.entryID & 0x0fffffff == id && slots.insert(entry.entryID >> 28).inserted,
                            "invalid Agenda entry ID")
                try require(seenIDs.insert(entry.uniqueID).inserted, "duplicate Agenda unique ID")
                records.append(entry)
            }
            // Extended fields are a second pass, after all basic records in the cluster.
            for entry in records where entry.flags & 0x1000 != 0 {
                try require(try reader.u32() == 0x110000f1, "invalid extended record")
                _ = try reader.take(Int(reader.u32())) // global ID
                _ = try reader.take(Int(reader.u32())) // location in the source encoding
                guard try reader.u32() == 0 else { throw PsionConversionError.unsupported("Agenda attendees") }
                _ = try AgendaDate.day(reader.u16())
                _ = try reader.take(Int(reader.u8()))
            }
            try reader.end()
            entries += records.filter { !$0.deleted }
        }
        try clusters.end()
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: timestamp)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Reconnect//Psion Agenda//EN", "CALSCALE:GREGORIAN"]
        for entry in entries { lines += try entry.calendarLines(fingerprint: fingerprint, stamp: stamp) }
        lines.append("END:VCALENDAR")
        return InterchangeText.encode(lines)
    }
}

private struct AgendaEntry {
    var type: UInt8
    var entryID: UInt32
    var flags: UInt16
    var uniqueID: UInt32
    var replication: UInt8
    var deleted: Bool
    var summary = ""
    var embedded = false
    var start: Int?
    var end: Int?
    var startMinute: Int?
    var endMinute: Int?
    var baseYear: UInt16 = 0
    var anniversaryOptions: [UInt8] = []
    var priority: UInt8 = 0
    var repeatRule: AgendaRepeat?
    var alarmPreTime: UInt32?

    static func read(_ reader: inout BinaryReader, store: PermanentStore) throws -> Self {
        let type = try reader.u8(), entryID = try reader.u32(), flags = try reader.u16(), uniqueID = try reader.u32()
        let replication = try reader.u8(), deleted = try reader.u8()
        _ = try reader.u8() // replication count
        try require(type <= 3 && replication <= 2 && deleted <= 1, "invalid Agenda entry type or replication")
        _ = try AgendaDate.day(reader.u16())
        _ = try AgendaDate.minute(reader.u16())
        var entry = Self(type: type, entryID: entryID, flags: flags, uniqueID: uniqueID, replication: replication, deleted: deleted == 1)
        if flags & 2 != 0 { entry.repeatRule = try AgendaRepeat.read(&reader) }
        if flags & 128 != 0 { _ = try reader.u16() }
        if flags & 16 != 0 {
            _ = try reader.descriptor()
            entry.alarmPreTime = try reader.u32()
        }
        if !entry.deleted {
            let raw: [UInt8]
            if flags & 8 != 0 {
                guard try reader.take(3) == [8, 0, 0] else { throw PsionConversionError.unsupported("inline Agenda rich text") }
                raw = try reader.take(reader.cardinal())
            } else {
                try require(try reader.u8() == 0, "invalid Agenda text marker")
                var text = BinaryReader(try store.get(reader.u32()))
                let offset = Int(try text.u32())
                try require(offset >= 4 && offset < text.bytes.count, "invalid embedded text root")
                text.position = offset
                try require(try text.u32() == 0x1000005c, "invalid text dictionary")
                for key: UInt32 in [0x10000063, 0x10000065, 0x10000066] {
                    try require(try text.u32() == key, "unexpected text dictionary key")
                    _ = try text.u32()
                }
                try require(try text.u32() == 0x10000064, "missing plain text")
                raw = try text.take(text.cardinal())
                try text.end()
                entry.embedded = true
            }
            try require(raw.last == 6, "missing paragraph terminator")
            entry.summary = try BinaryReader.text(raw)
                .replacingOccurrences(of: "\u{000e}", with: "")
                .replacingOccurrences(of: "\u{0007}", with: "\n")
                .replacingOccurrences(of: "\u{0006}", with: "\n")
            while entry.summary.hasSuffix("\n") { entry.summary.removeLast() }
        }
        switch type {
        case 0:
            entry.start = try AgendaDate.day(reader.u16())
            entry.startMinute = try AgendaDate.minute(reader.u16())
            entry.end = try AgendaDate.day(reader.u16())
            entry.endMinute = try AgendaDate.minute(reader.u16())
        case 2, 3:
            entry.start = try AgendaDate.day(reader.u16())
            entry.end = try AgendaDate.day(reader.u16())
            _ = try AgendaDate.minute(reader.u16())
            if type == 3 {
                entry.baseYear = try reader.u16()
                entry.anniversaryOptions = try reader.take(2)
            }
        default:
            _ = try reader.u32() // todo list ID
            entry.end = try AgendaDate.day(reader.u16()) // due date
            if flags & 1 != 0 { _ = try AgendaDate.day(reader.u16()) }
            if entry.end != nil { _ = try reader.u16() } // duration
            _ = try reader.u8()
            _ = try AgendaDate.minute(reader.u16())
            entry.priority = try reader.u8()
            _ = try reader.u8()
        }
        return entry
    }

    func calendarLines(fingerprint: String, stamp: String) throws -> [String] {
        let component = type == 1 ? "VTODO" : "VEVENT"
        var lines = ["BEGIN:\(component)", "UID:psion-\(fingerprint.prefix(16))-\(uniqueID)@agenda.local",
                     "DTSTAMP:\(stamp)", "SUMMARY:\(InterchangeText.escape(summary))",
                     "X-PSION-UNIQUE-ID:\(uniqueID)", "X-PSION-FLAGS:\(flags)",
                     "CLASS:\(["PUBLIC", "PRIVATE", "CONFIDENTIAL"][Int(replication)])"]
        if embedded { lines.append("X-PSION-EMBEDDED-TEXT:TRUE") }
        if type == 1 {
            try require(priority <= 9, "invalid todo priority")
            lines.append("PRIORITY:\(priority)")
            if let end { lines.append("DUE;VALUE=DATE:\(AgendaDate.format(end))") }
            if flags & 1 != 0 { lines.append("STATUS:COMPLETED") }
            guard repeatRule == nil else { throw PsionConversionError.unsupported("recurring to-dos") }
        } else {
            guard let start, let end else { throw PsionConversionError.invalid("event has no start or end date") }
            let allDay = type == 2 || type == 3 || flags & 256 != 0
            if allDay {
                try require(end >= start, "event ends before it starts")
                lines += ["DTSTART;VALUE=DATE:\(AgendaDate.format(start))", "DTEND;VALUE=DATE:\(AgendaDate.format(end + 1))"]
            } else {
                guard let startMinute, let endMinute else { throw PsionConversionError.invalid("appointment has no time") }
                try require(end * 1440 + endMinute >= start * 1440 + startMinute, "appointment ends before it starts")
                lines.append("DTSTART:\(AgendaDate.format(start, minute: startMinute))")
                if end == start && endMinute == startMinute { lines.append("X-PSION-ZERO-DURATION:TRUE") }
                else { lines.append("DTEND:\(AgendaDate.format(end, minute: endMinute))") }
            }
            if type == 3 {
                lines += ["X-PSION-BASE-YEAR:\(baseYear)", "X-PSION-ANNIVERSARY-OPTIONS:\(anniversaryOptions.map(String.init).joined(separator: ","))"]
            }
            if flags & 1024 != 0 { lines.append("STATUS:TENTATIVE") }
            if let repeatRule { lines += try repeatRule.calendarLines(minute: allDay ? nil : startMinute) }
        }
        if let alarmPreTime {
            let relative = 1440 - Int64(alarmPreTime)
            lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:\(InterchangeText.escape(summary))",
                      "TRIGGER:\(relative < 0 ? "-" : "")PT\(abs(relative))M",
                      "X-PSION-ALARM-PRE-TIME:\(alarmPreTime)", "END:VALARM"]
        }
        lines.append("END:\(component)")
        return lines
    }
}

private struct AgendaRepeat {
    var kind: UInt8
    var end: Int?
    var interval: UInt16
    var forever: Bool
    var days: UInt8 = 0
    var exceptions: [Int] = []

    static func read(_ reader: inout BinaryReader) throws -> Self {
        let kind = try reader.u8()
        _ = try AgendaDate.day(reader.u16())
        let end = try AgendaDate.day(reader.u16()), interval = try reader.u16()
        let display = try reader.u8(), forever = try reader.u8()
        guard [1, 2, 5].contains(kind) else { throw PsionConversionError.unsupported("Agenda recurrence kind \(kind)") }
        try require(interval > 0 && display <= 1 && forever <= 1, "invalid recurrence")
        var result = Self(kind: kind, end: end, interval: interval, forever: forever == 1)
        if kind == 2 {
            result.days = try reader.u8()
            _ = try reader.u8()
            try require(result.days > 0 && result.days & 128 == 0, "invalid weekly recurrence days")
        }
        let hasExceptions = try reader.u8()
        try require(hasExceptions <= 1, "invalid recurrence exception flag")
        if hasExceptions == 1 {
            let count = try reader.cardinal()
            try require(count <= reader.remaining / 2, "invalid exception count")
            for _ in 0..<count {
                guard let day = try AgendaDate.day(reader.u16()) else { throw PsionConversionError.invalid("null exception date") }
                result.exceptions.append(day)
            }
        }
        return result
    }

    func calendarLines(minute: Int?) throws -> [String] {
        var rule = "FREQ=\(kind == 1 ? "DAILY" : kind == 2 ? "WEEKLY" : "YEARLY");INTERVAL=\(interval)"
        if kind == 2 {
            let weekdays = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
            rule += ";BYDAY=" + weekdays.enumerated().filter { days & (1 << $0.offset) != 0 }.map(\.element).joined(separator: ",")
        }
        if !forever {
            guard let end else { throw PsionConversionError.invalid("bounded recurrence has no end") }
            rule += ";UNTIL=" + AgendaDate.format(end, minute: minute)
        }
        var lines = ["RRULE:" + rule]
        if !exceptions.isEmpty {
            lines.append("EXDATE\(minute == nil ? ";VALUE=DATE" : ""):" + exceptions.map { AgendaDate.format($0, minute: minute) }.joined(separator: ","))
        }
        return lines
    }
}

private enum AgendaDate {
    static func day(_ value: UInt16) throws -> Int? {
        try require(value == 65535 || value <= 44194, "date outside ER5 range")
        return value == 65535 ? nil : Int(value)
    }
    static func minute(_ value: UInt16) throws -> Int? {
        try require(value == 65535 || value < 1440, "time outside ER5 range")
        return value == 65535 ? nil : Int(value)
    }
    static func format(_ day: Int, minute: Int? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 315532800 + Double(day) * 86400)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let base = String(format: "%04d%02d%02d", components.year!, components.month!, components.day!)
        guard let minute else { return base }
        return base + String(format: "T%02d%02d00", minute / 60, minute % 60)
    }
}
