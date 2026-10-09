import Foundation

public struct AgendaSyncContent: Codable, Equatable, Sendable {
    public struct LocalDate: Codable, Equatable, Sendable {
        public var day: Int // Days since 1980-01-01, in the Psion's time zone.
        public var minute: Int?

        public init(day: Int, minute: Int? = nil) {
            self.day = day
            self.minute = minute
        }

        public func date(in timeZone: TimeZone) throws -> Date {
            let utc = Calendar(identifier: .gregorian)
            let reference = Date(timeIntervalSince1970: 315532800 + Double(day) * 86400)
            var components = utc.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: reference)
            components.timeZone = timeZone
            components.hour = (minute ?? 0) / 60
            components.minute = (minute ?? 0) % 60
            components.second = 0
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard let date = calendar.date(from: components),
                  calendar.component(.hour, from: date) == components.hour,
                  calendar.component(.minute, from: date) == components.minute else {
                throw PsionImportError.invalid("an event falls in a daylight-saving gap")
            }
            return date
        }

        public static func from(_ date: Date, in timeZone: TimeZone, allDay: Bool) throws -> Self {
            guard allDay || abs(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)) < 0.001 else {
                throw PsionImportError.unsupported("event times with sub-minute precision")
            }
            let value = try CalendarImportDate.from(date, timeZone: timeZone, dateOnly: allDay)
            return Self(day: value.day, minute: value.minute)
        }

        var formatted: String { AgendaDate.format(day, minute: minute) }
    }

    public struct RepeatRule: Codable, Equatable, Sendable {
        public enum Frequency: String, Codable, Sendable { case daily, weekly, yearly }
        public var frequency: Frequency
        public var interval: Int
        public var untilDay: Int?
        public var weekdays: [Int] // ISO: Monday = 0, Sunday = 6.
        public var weekStart: Int
        public var excludedDays: [Int]

        public init(frequency: Frequency, interval: Int = 1, untilDay: Int? = nil,
                    weekdays: [Int] = [], weekStart: Int = 0, excludedDays: [Int] = []) {
            self.frequency = frequency
            self.interval = interval
            self.untilDay = untilDay
            self.weekdays = weekdays
            self.weekStart = weekStart
            self.excludedDays = excludedDays
        }
    }

    public var text: String
    public var location: String
    public var start: LocalDate
    public var end: LocalDate // Exclusive for all-day events, matching EventKit.
    public var repeatRule: RepeatRule?
    public var alarmMinutes: Int?
    public var tentative: Bool

    public init(text: String, location: String = "", start: LocalDate, end: LocalDate,
                repeatRule: RepeatRule? = nil, alarmMinutes: Int? = nil, tentative: Bool = false) {
        self.text = text
        self.location = location
        self.start = start
        self.end = end
        self.repeatRule = repeatRule
        self.alarmMinutes = alarmMinutes
        self.tentative = tentative
    }

    func lines(identifier: String) throws -> [String] {
        var lines = ["BEGIN:VEVENT", "UID:\(InterchangeText.escape(identifier))",
                     "SUMMARY:\(InterchangeText.escape(text))", "LOCATION:\(InterchangeText.escape(location))"]
        let parameter = start.minute == nil ? ";VALUE=DATE" : ""
        lines += ["DTSTART\(parameter):\(start.formatted)", "DTEND\(parameter):\(end.formatted)"]
        if tentative { lines.append("STATUS:TENTATIVE") }
        if let rule = repeatRule {
            let names = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
            guard rule.weekdays.allSatisfy({ names.indices.contains($0) }), names.indices.contains(rule.weekStart) else {
                throw PsionImportError.invalid("invalid repeat weekdays")
            }
            var value = "FREQ=\(rule.frequency.rawValue.uppercased());INTERVAL=\(rule.interval)"
            if rule.frequency == .weekly {
                value += ";BYDAY=" + rule.weekdays.map { names[$0] }.joined(separator: ",")
                value += ";WKST=" + names[rule.weekStart]
            }
            if let day = rule.untilDay { value += ";UNTIL=" + LocalDate(day: day, minute: start.minute).formatted }
            lines.append("RRULE:" + value)
            if !rule.excludedDays.isEmpty {
                lines.append("EXDATE\(parameter):" + rule.excludedDays.map { LocalDate(day: $0, minute: start.minute).formatted }.joined(separator: ","))
            }
        }
        if let minutes = alarmMinutes {
            guard minutes != Int.min else { throw PsionImportError.invalid("an excessive alarm duration") }
            lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder",
                      "TRIGGER:\(minutes < 0 ? "-" : "")PT\(abs(minutes))M", "END:VALARM"]
        }
        lines.append("END:VEVENT")
        return lines
    }

    func imported(identifier: String, timeZone: TimeZone) throws -> CalendarImportEvent {
        let lines = try CalendarContentLine.read(InterchangeText.encode(self.lines(identifier: identifier)))
        let begin = lines.firstIndex { $0.name == "BEGIN" && $0.value == "VALARM" }
        let properties = Array(lines[1..<(begin ?? lines.count - 1)])
        let alarm = begin.map { Array(lines[($0 + 1)..<(lines.count - 2)]) } ?? []
        return try CalendarImportEvent.read(properties, alarm: alarm, timeZone: timeZone)
    }
}
