import Foundation

public enum AgendaSyncRecurrence {
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
