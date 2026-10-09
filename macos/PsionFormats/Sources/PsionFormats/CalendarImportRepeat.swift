import Foundation

struct CalendarImportRepeat {
    var kind: UInt8
    var interval: UInt16
    var until: Int?
    var days: UInt8 = 0
    var firstDay: UInt8 = 1
    var exceptions: [Int] = []

    static func read(_ value: String, start: CalendarImportDate, exclusions: [CalendarContentLine], timeZone: TimeZone) throws -> Self {
        var parts: [String: String] = [:]
        for part in value.uppercased().split(separator: ";", omittingEmptySubsequences: false) {
            let pair = part.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[1].isEmpty, parts[String(pair[0])] == nil else {
                throw PsionImportError.invalid("an invalid or duplicate repeat rule part")
            }
            parts[String(pair[0])] = String(pair[1])
        }
        guard parts.keys.allSatisfy({ ["FREQ", "INTERVAL", "UNTIL", "BYDAY", "WKST"].contains($0) }),
              let frequency = parts["FREQ"], let kind = ["DAILY": UInt8(1), "WEEKLY": 2, "YEARLY": 5][frequency] else {
            throw PsionImportError.unsupported("this repeat rule; use daily, weekly or yearly by date without COUNT")
        }
        guard let interval = UInt16(parts["INTERVAL"] ?? "1"), interval > 0 else {
            throw PsionImportError.invalid("an invalid repeat interval")
        }
        guard kind == 2 || parts["BYDAY"] == nil else {
            throw PsionImportError.unsupported("this repeat rule's day selection or week start")
        }
        var result = Self(kind: kind, interval: interval)
        let names = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
        guard let firstDay = names.firstIndex(of: parts["WKST"] ?? "MO") else { throw PsionImportError.invalid("an invalid repeat week start") }
        result.firstDay = 1 << firstDay
        if let until = parts["UNTIL"] {
            let line = CalendarContentLine(name: "UNTIL", parameters: start.minute == nil ? ["VALUE": "DATE"] : [:], value: until)
            let date = try CalendarImportDate.read(line, timeZone: timeZone)
            guard date.totalMinutes >= start.totalMinutes,
                  (start.minute == nil) == (date.minute == nil) else {
                throw PsionImportError.invalid("UNTIL must match and follow DTSTART")
            }
            // Native repeat bounds store a date, not an arbitrary end time.
            guard start.minute == nil || date.minute! >= start.minute! else {
                throw PsionImportError.unsupported("UNTIL earlier than the event time on its last day")
            }
            result.until = date.day
        }
        if kind == 2 {
            let startWeekday = (start.day + 1) % 7 // 1 January 1980 was Tuesday.
            let selected = parts["BYDAY"]?.split(separator: ",").map(String.init) ?? [names[startWeekday]]
            guard !selected.isEmpty, Set(selected).count == selected.count else {
                throw PsionImportError.invalid("invalid weekly repeat days")
            }
            for day in selected {
                guard let index = names.firstIndex(of: day) else {
                    throw PsionImportError.unsupported("ordinal weekdays in a weekly repeat")
                }
                result.days |= 1 << index
            }
            guard result.days & (1 << startWeekday) != 0 else {
                throw PsionImportError.invalid("DTSTART must be one of the weekly repeat days")
            }
        }
        for exclusion in exclusions {
            for value in exclusion.value.split(separator: ",", omittingEmptySubsequences: false) {
                var line = exclusion
                line.value = String(value)
                let date = try CalendarImportDate.read(line, timeZone: timeZone)
                guard date.minute == start.minute, !date.convertedTimeZone else {
                    throw PsionImportError.unsupported("repeat exceptions at a different time from DTSTART")
                }
                result.exceptions.append(date.day)
            }
        }
        result.exceptions = Array(Set(result.exceptions)).sorted()
        return result
    }

    func encoded(start: CalendarImportDate) throws -> [UInt8] {
        var writer = BinaryWriter()
        writer.u8(kind); writer.u16(UInt16(start.day)); writer.u16(UInt16(until ?? 65535))
        writer.u16(interval); writer.u8(0); writer.u8(until == nil ? 1 : 0)
        if kind == 2 { writer.u8(days); writer.u8(firstDay) }
        writer.u8(exceptions.isEmpty ? 0 : 1)
        if !exceptions.isEmpty {
            try writer.cardinal(exceptions.count)
            for day in exceptions { writer.u16(UInt16(day)) }
        }
        return writer.bytes
    }
}
