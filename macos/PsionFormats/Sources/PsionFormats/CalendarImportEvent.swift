import Foundation
import CryptoKit

struct CalendarImportEvent {
    var uid: String
    var globalID: String
    var summary: String
    var location: String
    var type: UInt8
    var start: CalendarImportDate
    var end: CalendarImportDate
    var replication: UInt8
    var tentative: Bool
    var baseYear: UInt16 = 0
    var anniversaryOptions: [UInt8] = [0, 0]
    var repeatRule: CalendarImportRepeat?
    var alarmPreTime: UInt32?

    static func read(_ properties: [CalendarContentLine], alarm: [CalendarContentLine], timeZone: TimeZone) throws -> Self {
        let supported: Set<String> = ["UID", "DTSTAMP", "CREATED", "LAST-MODIFIED", "SEQUENCE", "SUMMARY",
                                     "DESCRIPTION", "LOCATION", "DTSTART", "DTEND", "CLASS", "STATUS", "TRANSP",
                                     "RRULE", "EXDATE"]
        for property in properties where !supported.contains(property.name) && !property.name.hasPrefix("X-") {
            throw PsionImportError.unsupported("the \(property.name) event property")
        }
        func one(_ name: String, required: Bool = false) throws -> CalendarContentLine? {
            let found = properties.filter { $0.name == name }
            guard found.count <= 1, !required || found.count == 1 else {
                throw PsionImportError.invalid("\(name) must occur \(required ? "once" : "at most once") per event")
            }
            return found.first
        }
        guard let uidLine = try one("UID", required: true), let startLine = try one("DTSTART", required: true) else {
            throw PsionImportError.invalid("an event is missing its UID or start")
        }
        let uid = try uidLine.text()
        guard !uid.isEmpty else { throw PsionImportError.invalid("an event has an empty UID") }
        let summary = try one("SUMMARY")?.text() ?? ""
        let description = try one("DESCRIPTION")?.text() ?? ""
        let text = [summary, description].filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { throw PsionImportError.invalid("an event has no summary or description") }
        let location = try one("LOCATION")?.text() ?? ""
        _ = try BinaryWriter.text(text)
        _ = try BinaryWriter.text(location)
        guard !text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 }) else {
            throw PsionImportError.invalid("an event contains Psion rich-text control characters")
        }
        let start = try CalendarImportDate.read(startLine, timeZone: timeZone)
        var end: CalendarImportDate
        if let endLine = try one("DTEND") { end = try CalendarImportDate.read(endLine, timeZone: timeZone) }
        else { end = try start.adding(days: start.minute == nil ? 1 : 0) }
        guard (start.minute == nil) == (end.minute == nil), end.totalMinutes >= start.totalMinutes,
              start.minute != nil || end.day > start.day else {
            throw PsionImportError.invalid("an event's end must match its start type and follow its start")
        }
        if start.minute == nil { end = try end.adding(days: -1) } // iCalendar's end is exclusive.
        let classification = try one("CLASS")?.value.uppercased() ?? "PUBLIC"
        guard let replication = ["PUBLIC", "PRIVATE", "CONFIDENTIAL"].firstIndex(of: classification) else {
            throw PsionImportError.invalid("an invalid CLASS value")
        }
        let status = try one("STATUS")?.value.uppercased() ?? "CONFIRMED"
        guard ["CONFIRMED", "TENTATIVE"].contains(status) else {
            throw PsionImportError.unsupported("event status \(status)")
        }
        let nativeID = try one("X-PSION-GLOBAL-ID")?.text()
        let hash = SHA256.hash(data: Data(uid.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let globalID = nativeID ?? hash
        guard !globalID.isEmpty, (try BinaryWriter.text(globalID)).count <= 32 else {
            throw PsionImportError.invalid("a native global ID exceeds 32 bytes")
        }
        var event = Self(uid: uid, globalID: globalID, summary: text, location: location,
                         type: start.minute == nil ? 2 : 0, start: start, end: end,
                         replication: UInt8(replication), tentative: status == "TENTATIVE")
        if let year = try one("X-PSION-BASE-YEAR") {
            guard start.minute == nil, let value = UInt16(year.value), value <= 2100 else {
                throw PsionImportError.invalid("invalid anniversary base year")
            }
            event.type = 3
            event.baseYear = value
            if let options = try one("X-PSION-ANNIVERSARY-OPTIONS") {
                let values = options.value.split(separator: ",", omittingEmptySubsequences: false)
                guard values.count == 2, let first = UInt8(values[0]), let second = UInt8(values[1]), first <= 3, second <= 1 else {
                    throw PsionImportError.invalid("invalid anniversary options")
                }
                event.anniversaryOptions = [first, second]
            }
        }
        if let rule = try one("RRULE") {
            guard !start.convertedTimeZone else {
                throw PsionImportError.unsupported("recurrences that require time-zone conversion; export floating local times in the Psion's time zone")
            }
            event.repeatRule = try CalendarImportRepeat.read(rule.value, start: start,
                                                            exclusions: properties.filter { $0.name == "EXDATE" },
                                                            timeZone: timeZone)
        } else if properties.contains(where: { $0.name == "EXDATE" }) {
            throw PsionImportError.invalid("EXDATE requires a repeat rule")
        }
        if event.type == 3 && event.repeatRule?.kind != 5 {
            throw PsionImportError.invalid("an anniversary must repeat yearly by date")
        }
        if !alarm.isEmpty {
            let allowed: Set<String> = ["ACTION", "TRIGGER", "DESCRIPTION", "X-PSION-ALARM-PRE-TIME"]
            guard alarm.allSatisfy({ allowed.contains($0.name) }), alarm.filter({ $0.name == "ACTION" }).count == 1,
                  alarm.first(where: { $0.name == "ACTION" })?.value.uppercased() == "DISPLAY",
                  alarm.filter({ $0.name == "TRIGGER" }).count == 1,
                  let trigger = alarm.first(where: { $0.name == "TRIGGER" }),
                  trigger.parameters.keys.allSatisfy({ ["RELATED", "VALUE"].contains($0) }),
                  trigger.parameters["RELATED"] == nil || trigger.parameters["RELATED"]?.uppercased() == "START",
                  trigger.parameters["VALUE"] == nil || trigger.parameters["VALUE"]?.uppercased() == "DURATION" else {
                throw PsionImportError.unsupported("alarms other than a single DISPLAY alarm relative to the event start")
            }
            let relative = try Self.durationMinutes(trigger.value)
            let native = Int64(1440) - relative
            guard (0...Int64(UInt32.max)).contains(native) else {
                throw PsionImportError.invalid("the alarm lead time exceeds the native range")
            }
            event.alarmPreTime = UInt32(native)
        }
        return event
    }

    // Whole-minute RFC durations, including weeks and days. No rounding of seconds.
    static func durationMinutes(_ text: String) throws -> Int64 {
        let pattern = #"^([+-])?P(?:(\d+)W|(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?)$"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range), match.range == range else {
            throw PsionImportError.invalid("an invalid alarm duration")
        }
        func number(_ index: Int) throws -> Int64 {
            guard let range = Range(match.range(at: index), in: text) else { return 0 }
            guard let value = Int64(text[range]), value <= 4_294_967_295 else {
                throw PsionImportError.invalid("an excessive alarm duration")
            }
            return value
        }
        guard (2...6).contains(where: { match.range(at: $0).location != NSNotFound }),
              !text.hasSuffix("T") else { throw PsionImportError.invalid("an empty alarm duration") }
        let seconds = try number(6)
        guard seconds % 60 == 0 else { throw PsionImportError.unsupported("alarms with sub-minute precision") }
        let minutes = try number(2) * 10080 + number(3) * 1440 + number(4) * 60 + number(5) + seconds / 60
        return text.hasPrefix("-") ? -minutes : minutes
    }

    func basic(entryID: UInt32, uniqueID: UInt32, modified: CalendarImportDate, deleted: Bool = false) throws -> [UInt8] {
        var writer = BinaryWriter()
        var flags: UInt16 = 0x1008 // inline plain rich text + the native extended record
        if repeatRule != nil { flags |= 2 }
        if let repeatRule, !repeatRule.exceptions.isEmpty { flags |= 4 }
        if alarmPreTime != nil { flags |= 16 }
        if tentative { flags |= 1024 }
        if type == 3 { flags |= 32 }
        writer.u8(type); writer.u32(entryID); writer.u16(flags); writer.u32(uniqueID)
        writer.append([replication, deleted ? 1 : 0, 0])
        writer.u16(UInt16(modified.day)); writer.u16(UInt16(modified.minute ?? 0))
        if let repeatRule { writer.append(try repeatRule.encoded(start: start)) }
        if let alarmPreTime { try writer.descriptor(""); writer.u32(alarmPreTime) }
        if !deleted {
            writer.append([8, 0, 0])
            var text = try BinaryWriter.text(summary)
            text = text.map { $0 == 10 ? 6 : $0 }
            text.append(6)
            try writer.cardinal(text.count); writer.append(text)
        }
        writer.u16(UInt16(start.day))
        if type == 0 {
            writer.u16(UInt16(start.minute!)); writer.u16(UInt16(end.day)); writer.u16(UInt16(end.minute!))
        } else {
            writer.u16(UInt16(end.day)); writer.u16(360)
            if type == 3 { writer.u16(baseYear); writer.append(anniversaryOptions) }
        }
        return writer.bytes
    }

    func extended(created: CalendarImportDate) throws -> [UInt8] {
        var writer = BinaryWriter()
        writer.u32(0x110000f1)
        let id = try BinaryWriter.text(globalID), place = try BinaryWriter.text(location)
        writer.u32(UInt32(id.count)); writer.append(id)
        writer.u32(UInt32(place.count)); writer.append(place)
        writer.u32(0) // no attendees
        writer.u16(UInt16(created.day)); writer.u8(0)
        return writer.bytes
    }
}

struct CalendarImportDate {
    var day: Int
    var minute: Int?
    var convertedTimeZone = false
    var totalMinutes: Int { day * 1440 + (minute ?? 0) }

    static func read(_ line: CalendarContentLine, timeZone: TimeZone) throws -> Self {
        guard line.parameters.keys.allSatisfy({ ["VALUE", "TZID"].contains($0) }) else {
            throw PsionImportError.unsupported("parameters on \(line.name)")
        }
        let dateOnly = line.parameters["VALUE"]?.uppercased() == "DATE"
        let value = line.value
        let isUTC = value.hasSuffix("Z")
        let raw = isUTC ? String(value.dropLast()) : value
        guard (dateOnly && raw.count == 8 && !isUTC && line.parameters["TZID"] == nil) ||
              (!dateOnly && raw.count == 15 && raw.dropFirst(8).hasPrefix("T") &&
               (line.parameters["VALUE"] == nil || line.parameters["VALUE"]?.uppercased() == "DATE-TIME")) else {
            throw PsionImportError.invalid("use basic DATE or DATE-TIME values in \(line.name)")
        }
        guard !isUTC || line.parameters["TZID"] == nil else { throw PsionImportError.invalid("UTC dates cannot have TZID") }
        let numbers = raw.filter { $0 != "T" }
        guard numbers.count == (dateOnly ? 8 : 14), numbers.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw PsionImportError.invalid("an invalid date") }
        func integer(_ start: Int, _ length: Int) -> Int {
            Int(numbers.dropFirst(start).prefix(length))!
        }
        let year = integer(0, 4), month = integer(4, 2), day = integer(6, 2)
        let hour = dateOnly ? 0 : integer(8, 2), minute = dateOnly ? 0 : integer(10, 2)
        guard dateOnly || integer(12, 2) == 0 else { throw PsionImportError.unsupported("event times with sub-minute precision") }
        let sourceZone: TimeZone
        if isUTC { sourceZone = TimeZone(secondsFromGMT: 0)! }
        else if let identifier = line.parameters["TZID"] {
            guard let zone = TimeZone(identifier: identifier) else {
                throw PsionImportError.unsupported("the time zone \(identifier); export UTC or floating local times")
            }
            sourceZone = zone
        } else { sourceZone = dateOnly ? TimeZone(secondsFromGMT: 0)! : timeZone }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sourceZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        guard let date = calendar.date(from: components) else { throw PsionImportError.invalid("an invalid date") }
        let checked = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard checked.year == year && checked.month == month && checked.day == day && checked.hour == hour && checked.minute == minute else {
            throw PsionImportError.invalid("a date is invalid or falls in a daylight-saving gap")
        }
        let converted = !dateOnly && (isUTC || line.parameters["TZID"] != nil) && sourceZone != timeZone
        return try from(date, timeZone: dateOnly ? TimeZone(secondsFromGMT: 0)! : timeZone,
                        dateOnly: dateOnly, convertedTimeZone: converted)
    }

    static func from(_ date: Date, timeZone: TimeZone, dateOnly: Bool = false, convertedTimeZone: Bool = false) throws -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let midnight = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) else {
            throw PsionImportError.invalid("an invalid date")
        }
        let day = Int((midnight.timeIntervalSince1970 - 315532800) / 86400)
        guard (0...44194).contains(day) else { throw PsionImportError.unsupported("dates outside 1980–2100") }
        return Self(day: day, minute: dateOnly ? nil : c.hour! * 60 + c.minute!, convertedTimeZone: convertedTimeZone)
    }

    func adding(days: Int) throws -> Self {
        guard (0...44195).contains(day + days) else { throw PsionImportError.unsupported("dates outside 1980–2100") }
        return Self(day: day + days, minute: minute, convertedTimeZone: convertedTimeZone)
    }
}
