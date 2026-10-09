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
    }

    public var content: AgendaSyncContent
    public var notices: Set<Notice>

    public init(content: AgendaSyncContent, notices: Set<Notice> = []) {
        self.content = content
        self.notices = notices
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
