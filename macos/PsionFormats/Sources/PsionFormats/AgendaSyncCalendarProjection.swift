import Foundation

/// A source-only copy of a Calendar appointment into the fields Agenda can represent.
/// Scheduling metadata and omitted alarms remain in the original Calendar event.
public struct AgendaSyncCalendarProjection: Sendable, Equatable {
    public enum Alarm: Sendable, Equatable {
        case relative(seconds: Double)
        case absolute(Date)
        case unsupported
    }

    public enum Notice: String, CaseIterable, Sendable {
        case invitationDetails, extraAlarms, unsupportedAlarms, convertedAbsoluteAlarm
        case convertedTimeZone, expandedRecurrence
        case roundedTimes, convertedText, placeholderText, reanchoredRecurrence
    }

    public var content: AgendaSyncContent
    public var notices: Set<Notice>

    public init(content: AgendaSyncContent, notices: Set<Notice> = []) {
        self.content = content
        self.notices = notices
    }

    /// Lossy conversion is confined to Mac-source copies; the original Calendar remains authoritative.
    public static func sourceContent(text: String, location: String, start: Date, end: Date,
                                     allDay: Bool, timeZone: TimeZone, tentative: Bool = false) throws -> Self {
        let readableText = AgendaSyncCalendarText.readable(text)
        let readableLocation = AgendaSyncCalendarText.readable(location)
        let placeholder = readableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let content = AgendaSyncContent(text: placeholder ? "Untitled appointment" : readableText,
            location: readableLocation, start: try roundedLocalDate(start, in: timeZone, allDay: allDay),
            end: try roundedLocalDate(end, in: timeZone, allDay: allDay), tentative: tentative)
        var result = Self(content: content)
        if readableText != text || readableLocation != location { result.notices.insert(.convertedText) }
        if placeholder { result.notices.insert(.placeholderText) }
        if !allDay, !hasMinutePrecision(start) || !hasMinutePrecision(end) { result.notices.insert(.roundedTimes) }
        return result
    }

    public static func roundedLocalDate(_ date: Date, in timeZone: TimeZone, allDay: Bool) throws -> AgendaSyncContent.LocalDate {
        guard date.timeIntervalSince1970.isFinite else { throw PsionImportError.invalid("an invalid event date") }
        let rounded = allDay ? date : Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
        return try .from(rounded, in: timeZone, allDay: allDay)
    }

    public static func hasMinutePrecision(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && abs(seconds.truncatingRemainder(dividingBy: 60)) < 0.001
    }

    public static func project(_ content: AgendaSyncContent, hasInvitationDetails: Bool,
                               alarms: [Alarm], eventStart: Date) -> Self {
        var result = Self(content: content)
        result.content.alarmMinutes = nil
        if hasInvitationDetails { result.notices.insert(.invitationDetails) }
        if alarms.count > 1 { result.notices.insert(.extraAlarms) }
        var candidates: [(minutes: Int, absolute: Bool)] = []
        for alarm in alarms {
            let seconds: Double
            let absolute: Bool
            switch alarm {
            case .relative(let offset):
                seconds = offset
                absolute = false
            case .absolute(let date):
                // A dated alert belongs to one date; making it relative on a series would repeat it.
                guard content.repeatRule == nil else {
                    result.notices.insert(.unsupportedAlarms)
                    continue
                }
                seconds = date.timeIntervalSince(eventStart)
                absolute = true
            case .unsupported:
                result.notices.insert(.unsupportedAlarms)
                continue
            }
            let minutes = seconds / 60
            guard seconds.isFinite, seconds.truncatingRemainder(dividingBy: 60) == 0,
                  minutes >= 1440 - Double(UInt32.max), minutes <= 1440 else {
                result.notices.insert(.unsupportedAlarms)
                continue
            }
            candidates.append((Int(minutes), absolute))
        }
        // Preserve the earliest supported alert, independently of EventKit's alarm ordering.
        // Prefer the original relative alert if a dated alert has the same trigger time.
        if let selected = candidates.min(by: {
            $0.minutes == $1.minutes ? (!$0.absolute && $1.absolute) : $0.minutes < $1.minutes
        }) {
            result.content.alarmMinutes = selected.minutes
            if selected.absolute { result.notices.insert(.convertedAbsoluteAlarm) }
        }
        return result
    }
}
