import Foundation

public enum AgendaSyncRecurrence {
    public struct Occurrence: Equatable, Sendable {
        public var start: AgendaSyncContent.LocalDate
        public var end: AgendaSyncContent.LocalDate

        public init(start: AgendaSyncContent.LocalDate, end: AgendaSyncContent.LocalDate) {
            self.start = start
            self.end = end
        }
    }

    /// Converts a repeat's weekdays into the destination zone, then checks the full observed
    /// schedule. A varying local hour or a date pattern Agenda cannot express needs expansion.
    public static func converted(_ content: AgendaSyncContent, sourceStart: AgendaSyncContent.LocalDate,
                                 occurrences: [Occurrence]) throws -> AgendaSyncContent? {
        guard var rule = content.repeatRule, !occurrences.isEmpty else { return nil }
        let dayShift = content.start.day - sourceStart.day
        func shifted(_ day: Int) -> Int { ((day + dayShift) % 7 + 7) % 7 }
        if rule.frequency == .weekly {
            rule.weekdays = rule.weekdays.map(shifted).sorted()
            rule.weekStart = shifted(rule.weekStart)
        }
        var converted = content
        converted.repeatRule = rule
        guard occurrences.allSatisfy({
            $0.start.minute == converted.start.minute && $0.end.minute == converted.end.minute &&
            $0.end.day - $0.start.day == converted.end.day - converted.start.day
        }) else { return nil }
        let observed = Set(occurrences.map { $0.start.day })
        guard try observed.isSubset(of: expectedDays(content: converted, rule: rule)) else { return nil }
        return try excludingMissingOccurrences(in: converted, observedDays: observed)
    }

    /// Only unchanged occurrences count as present. Edited and deleted dates become exclusions;
    /// edited appointments are supplied separately, preserving both their original and moved dates.
    public static func excludingMissingOccurrences(in content: AgendaSyncContent,
                                                   observedDays: Set<Int>) throws -> AgendaSyncContent {
        guard let rule = content.repeatRule else { return content }
        var result = content
        let missing = try expectedDays(content: content, rule: rule).subtracting(observedDays)
        result.repeatRule?.excludedDays = missing.union(rule.excludedDays).sorted()
        guard (result.repeatRule?.excludedDays.count ?? 0) <= 1024 else {
            throw PsionImportError.unsupported("a recurring event with more than 1024 exclusions")
        }
        return result
    }

    private static func expectedDays(content: AgendaSyncContent, rule: AgendaSyncContent.RepeatRule) throws -> Set<Int> {
        guard rule.interval > 0, (0...44194).contains(content.start.day) else {
            throw PsionImportError.invalid("a repeat starts outside 1980–2100")
        }
        let last = min(rule.untilDay ?? 44194, 44194)
        guard last >= content.start.day else { return [] }
        var days = Set<Int>()
        let firstWeek = content.start.day - (((content.start.day + 1) % 7 - rule.weekStart + 7) % 7)
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let start = try content.start.date(in: utc)
        let original = calendar.dateComponents([.year, .month, .day], from: start)
        for day in content.start.day...last {
            switch rule.frequency {
            case .daily:
                if (day - content.start.day) % rule.interval == 0 { days.insert(day) }
            case .weekly:
                if ((day - firstWeek) / 7) % rule.interval == 0,
                   rule.weekdays.contains((day + 1) % 7) { days.insert(day) }
            case .yearly:
                let date = Date(timeIntervalSince1970: 315532800 + Double(day) * 86400)
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                if components.month == original.month, components.day == original.day,
                   (components.year! - original.year!) % rule.interval == 0 { days.insert(day) }
            }
        }
        return days
    }
}
