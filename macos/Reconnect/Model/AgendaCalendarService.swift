import EventKit
import Foundation
import PsionFormats

/// EventKit objects stay on this actor; views and the planner receive value snapshots.
actor AgendaCalendarService {
    struct CalendarChoice: Identifiable, Equatable, Sendable {
        var id: String
        var title: String
        var writable: Bool
    }

    struct EventSnapshot: Sendable {
        var id: String
        var externalID: String?
        var recoveryURL: String?
        var content: AgendaSyncContent
        var notices: Set<AgendaSyncCalendarProjection.Notice> = []
    }

    struct CalendarSnapshot: Sendable {
        var events: [EventSnapshot]
        // These series remain in Calendar but are now represented by individual occurrences.
        var replacedSeriesIDs: Set<String> = []
    }

    private var store = EKEventStore()

    func authorize() async throws {
        guard try await store.requestFullAccessToEvents() else {
            throw failure("Allow Calendar access in System Settings → Privacy & Security → Calendars to enable sync.")
        }
        store.reset()
    }

    func calendars() throws -> [CalendarChoice] {
        try checkAccess()
        return store.calendars(for: .event).map {
            CalendarChoice(id: $0.calendarIdentifier, title: $0.title + " — " + $0.source.title,
                           writable: $0.allowsContentModifications)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func createCalendar(title: String) throws -> CalendarChoice {
        try checkAccess()
        guard let source = store.sources.first(where: { $0.sourceType == .local }) ?? store.defaultCalendarForNewEvents?.source else {
            throw failure("No Calendar account is available to create a Psion calendar. Add an account in Calendar, then try again.")
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return CalendarChoice(id: calendar.calendarIdentifier, title: calendar.title + " — " + source.title, writable: true)
    }

    func snapshot(calendarID: String, timeZone: TimeZone, allowSourceOnlyMetadata: Bool = false) throws -> CalendarSnapshot {
        try checkAccess()
        store.reset()
        let calendar = try selectedCalendar(calendarID)
        var masters: [String: EKEvent] = [:]
        var occurrences: [String: Set<Int>] = [:]
        var editedOccurrences: [String: EventSnapshot] = [:]
        var conversionOccurrences: [String: [String: EKEvent]] = [:]
        // EventKit silently truncates queries over four years. Fetch the complete supported
        // Agenda range in smaller windows, so out-of-window events never become deletions.
        for year in stride(from: 1980, through: 2100, by: 3) {
            try Task.checkCancellation()
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = timeZone
            let start = gregorian.date(from: DateComponents(year: year, month: 1, day: 1))!
            let end = gregorian.date(from: DateComponents(year: min(year + 3, 2101), month: 1, day: 1))!
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
            for event in store.events(matching: predicate) {
                if event.isDetached {
                    // Canceled exceptions are absent appointments; they still exclude the original date.
                    guard event.status != .canceled else { continue }
                    let single = try occurrenceSnapshot(of: event, timeZone: timeZone,
                                                        allowSourceOnlyMetadata: allowSourceOnlyMetadata)
                    if let previous = editedOccurrences[single.id], previous.content != single.content {
                        throw failure("Calendar returned conflicting versions of an edited occurrence. Try syncing again.")
                    }
                    // Exceptions inherit the series URL, so it cannot serve as their recovery identifier.
                    editedOccurrences[single.id] = single
                    continue
                }
                let identifier = event.calendarItemIdentifier
                if masters[identifier] == nil || event.startDate < masters[identifier]!.startDate {
                    let candidate = store.calendarItem(withIdentifier: identifier) as? EKEvent
                    // If EventKit resolves the series ID to a detached first occurrence, use the earliest
                    // unchanged occurrence as the repeat anchor. Earlier edits remain separate appointments.
                    masters[identifier] = candidate.flatMap { $0.isDetached ? nil : $0 } ?? event
                }
                if event.hasRecurrenceRules || masters[identifier]?.hasRecurrenceRules == true {
                    let day = try AgendaSyncContent.LocalDate.from(event.occurrenceDate ?? event.startDate,
                        in: event.isAllDay ? .current : timeZone, allDay: true).day
                    occurrences[identifier, default: []].insert(day)
                    let sourceZone = masters[identifier]?.timeZone ?? event.timeZone ?? .current
                    if allowSourceOnlyMetadata, !event.isAllDay, sourceZone != timeZone {
                        let id = try occurrenceIdentifier(of: event, timeZone: timeZone).identifier()
                        conversionOccurrences[identifier, default: [:]][id] = event
                    }
                }
            }
        }
        var series: [EventSnapshot] = []
        var replacedSeriesIDs = Set<String>()
        for (identifier, event) in masters {
            var projection = try readProjection(of: event, timeZone: timeZone,
                                                 allowSourceOnlyMetadata: allowSourceOnlyMetadata)
            let content: AgendaSyncContent
            if let convertedEvents = conversionOccurrences[identifier], !convertedEvents.isEmpty {
                let sourceStart = try AgendaSyncContent.LocalDate.from(event.startDate, in: event.timeZone ?? .current,
                                                                       allDay: false)
                let observed = try convertedEvents.values.map {
                    try AgendaSyncRecurrence.Occurrence(start: .from($0.startDate, in: timeZone, allDay: false),
                                                       end: .from($0.endDate, in: timeZone, allDay: false))
                }
                if let converted = try AgendaSyncRecurrence.converted(projection.content, sourceStart: sourceStart,
                                                                      occurrences: observed) {
                    content = converted
                    projection.notices.insert(.convertedTimeZone)
                } else {
                    replacedSeriesIDs.insert(identifier)
                    for occurrence in convertedEvents.values {
                        var single = try occurrenceSnapshot(of: occurrence, timeZone: timeZone,
                                                            allowSourceOnlyMetadata: true)
                        single.notices.insert(.expandedRecurrence)
                        if let previous = editedOccurrences[single.id], previous.content != single.content {
                            throw failure("Calendar returned conflicting versions of a converted occurrence. Try syncing again.")
                        }
                        editedOccurrences[single.id] = single
                    }
                    continue
                }
            } else {
                content = try AgendaSyncRecurrence.excludingMissingOccurrences(in: projection.content,
                                                                               observedDays: occurrences[identifier] ?? [])
            }
            series.append(EventSnapshot(id: identifier, externalID: event.calendarItemExternalIdentifier,
                                        recoveryURL: event.url?.absoluteString, content: content, notices: projection.notices))
        }
        return CalendarSnapshot(events: (series + Array(editedOccurrences.values)).sorted { $0.id < $1.id },
                                replacedSeriesIDs: replacedSeriesIDs)
    }

    func validateChange(_ content: AgendaSyncContent?, replacing identifier: String?, timeZone: TimeZone) throws {
        if let identifier, AgendaSyncOccurrence(identifier: identifier) != nil {
            throw failure("Writing Psion edits back to edited or expanded Calendar occurrences is not supported yet. Use Mac Calendar → Agenda to preserve Calendar as the source.")
        }
        if let content { try validateWrite(content, timeZone: timeZone) }
    }

    func validateWrite(_ content: AgendaSyncContent, timeZone: TimeZone) throws {
        guard !content.text.isEmpty else { throw failure("An Agenda entry has no title or text. Give it a title before syncing it to Mac Calendar.") }
        _ = try content.start.date(in: timeZone)
        _ = try content.end.date(in: timeZone)
        guard !content.tentative else { throw failure("EventKit cannot create tentative event status. This Agenda event will be preserved until status mapping is supported.") }
        if let rule = content.repeatRule {
            guard rule.interval > 0, rule.interval <= Int(UInt16.max),
                  rule.weekStart == 0,
                  rule.excludedDays.isEmpty else {
                throw failure("Writing repeats with exclusions or a custom fortnightly week start to Mac Calendar is not supported yet. The existing events will be preserved.")
            }
        }
    }

    func write(_ content: AgendaSyncContent?, replacing identifier: String?, expected: AgendaSyncContent?,
               calendarID: String, timeZone: TimeZone, recoveryURL: URL) throws -> EventSnapshot? {
        try checkAccess()
        try validateChange(content, replacing: identifier, timeZone: timeZone)
        let calendar = try selectedCalendar(calendarID)
        guard calendar.allowsContentModifications else { throw failure("The selected Mac calendar is read-only.") }
        let existing = identifier.flatMap { store.calendarItem(withIdentifier: $0) as? EKEvent }
        guard identifier == nil || existing != nil else { throw failure("A Mac event changed during sync. Sync again to include its latest state.") }
        if let existing {
            var observed = try self.content(of: existing, timeZone: timeZone)
            observed.repeatRule?.excludedDays = expected?.repeatRule?.excludedDays ?? []
            guard observed == expected else { throw failure("A Mac event was edited during sync. Its latest edit has been preserved; sync again.") }
        }
        guard let content else {
            if let existing { try store.remove(existing, span: .futureEvents, commit: true) }
            return nil
        }
        try validateWrite(content, timeZone: timeZone)
        let event = existing ?? EKEvent(eventStore: store)
        event.calendar = calendar
        let dateZone = content.start.minute == nil ? TimeZone.current : timeZone
        event.startDate = try content.start.date(in: dateZone)
        event.endDate = try content.end.date(in: dateZone)
        event.isAllDay = content.start.minute == nil
        event.timeZone = event.isAllDay ? nil : timeZone
        let components = content.text.components(separatedBy: "\n")
        event.title = components.first ?? ""
        event.notes = components.dropFirst().joined(separator: "\n")
        event.location = content.location
        if existing == nil { event.url = recoveryURL }
        event.alarms = content.alarmMinutes.map { [EKAlarm(relativeOffset: Double($0) * 60)] } ?? []
        if let rule = content.repeatRule {
            let frequency: EKRecurrenceFrequency = rule.frequency == .daily ? .daily : rule.frequency == .weekly ? .weekly : .yearly
            let weekdays: [EKRecurrenceDayOfWeek]? = rule.frequency == .weekly ? rule.weekdays.map {
                EKRecurrenceDayOfWeek(EKWeekday(rawValue: (($0 + 1) % 7) + 1)!)
            } : nil
            let end: EKRecurrenceEnd? = try rule.untilDay.map {
                EKRecurrenceEnd(end: try AgendaSyncContent.LocalDate(day: $0, minute: 1439).date(in: timeZone))
            }
            event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: frequency, interval: rule.interval,
                daysOfTheWeek: weekdays, daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                daysOfTheYear: nil, setPositions: nil, end: end)]
        } else { event.recurrenceRules = nil }
        try store.save(event, span: .futureEvents, commit: true)
        return EventSnapshot(id: event.calendarItemIdentifier, externalID: event.calendarItemExternalIdentifier,
                             recoveryURL: event.url?.absoluteString, content: try self.content(of: event, timeZone: timeZone))
    }

    private func content(of event: EKEvent, timeZone: TimeZone) throws -> AgendaSyncContent {
        try projection(of: event, timeZone: timeZone).content
    }

    private func readProjection(of event: EKEvent, timeZone: TimeZone, includingRecurrence: Bool = true,
                                allowSourceOnlyMetadata: Bool) throws -> AgendaSyncCalendarProjection {
        do {
            return try projection(of: event, timeZone: timeZone, includingRecurrence: includingRecurrence,
                                  allowSourceOnlyMetadata: allowSourceOnlyMetadata)
        } catch {
            let title = event.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled event"
            throw failure("Calendar event “\(title)”: " + error.localizedDescription)
        }
    }

    private func projection(of event: EKEvent, timeZone: TimeZone, includingRecurrence: Bool = true,
                            allowSourceOnlyMetadata: Bool = false) throws -> AgendaSyncCalendarProjection {
        if !allowSourceOnlyMetadata {
            guard event.attendees?.isEmpty != false, event.organizer == nil,
                  (event.alarms?.count ?? 0) <= 1 else {
                throw failure("Invitations and multiple alerts require Mac Calendar → Agenda. This direction copies appointment details without changing the Calendar invitation or its alerts.")
            }
        }
        guard event.status != .canceled else { throw failure("The selected calendar contains a canceled event that cannot be mapped to Agenda safely.") }
        if !allowSourceOnlyMetadata, includingRecurrence, let sourceZone = event.timeZone,
           !event.isAllDay, event.hasRecurrenceRules, sourceZone != timeZone {
            throw failure("A recurring event uses a different time zone from the Psion. Its recurrence cannot be converted safely.")
        }
        let text = [event.title ?? "", event.notes ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        let dateZone = event.isAllDay ? TimeZone.current : timeZone
        var result = AgendaSyncContent(text: text, location: event.location ?? "",
            start: try .from(event.startDate, in: dateZone, allDay: event.isAllDay),
            end: try .from(event.endDate, in: dateZone, allDay: event.isAllDay), tentative: event.status == .tentative)
        if !allowSourceOnlyMetadata, let alarm = event.alarms?.first {
            let seconds = alarm.relativeOffset
            let minutes = seconds / 60
            guard alarm.absoluteDate == nil, alarm.structuredLocation == nil,
                  alarm.type == .display || alarm.type == .audio,
                  seconds.isFinite, seconds.truncatingRemainder(dividingBy: 60) == 0,
                  minutes >= 1440 - Double(UInt32.max), minutes <= 1440 else {
                throw failure("An event has an alarm that cannot be represented on the Psion.")
            }
            result.alarmMinutes = Int(minutes)
        }
        if includingRecurrence, let rules = event.recurrenceRules, !rules.isEmpty {
            guard rules.count == 1 else { throw failure("Multiple recurrence rules are not supported.") }
            let rule = rules[0]
            guard rule.frequency != .monthly, (rule.recurrenceEnd?.occurrenceCount ?? 0) == 0,
                  rule.daysOfTheMonth?.isEmpty != false, rule.monthsOfTheYear?.isEmpty != false,
                  rule.daysOfTheYear?.isEmpty != false, rule.weeksOfTheYear?.isEmpty != false,
                  rule.setPositions?.isEmpty != false,
                  rule.daysOfTheWeek?.allSatisfy({ $0.weekNumber == 0 }) != false,
                  rule.frequency == .weekly || rule.daysOfTheWeek?.isEmpty != false else {
                throw failure("An event has a repeat rule outside the supported daily, weekly or yearly-by-date Agenda profile.")
            }
            let weekdays = rule.daysOfTheWeek?.map { (Int($0.dayOfTheWeek.rawValue) + 5) % 7 }.sorted() ?? []
            let sourceStart = try AgendaSyncContent.LocalDate.from(event.startDate, in: event.isAllDay ? .current : (event.timeZone ?? .current),
                                                                   allDay: true)
            let until = try rule.recurrenceEnd?.endDate.map { try AgendaSyncContent.LocalDate.from($0, in: dateZone, allDay: true).day }
            result.repeatRule = .init(frequency: rule.frequency == .daily ? .daily : rule.frequency == .weekly ? .weekly : .yearly,
                interval: rule.interval, untilDay: until,
                weekdays: rule.frequency == .weekly ? (weekdays.isEmpty ? [(sourceStart.day + 1) % 7] : weekdays) : [],
                weekStart: rule.firstDayOfTheWeek == 0 ? 0 : (rule.firstDayOfTheWeek + 5) % 7)
        }
        if allowSourceOnlyMetadata {
            let alarms: [AgendaSyncCalendarProjection.Alarm] = (event.alarms ?? []).map { alarm in
                guard alarm.structuredLocation == nil, alarm.type == .display || alarm.type == .audio else {
                    return .unsupported
                }
                if let date = alarm.absoluteDate {
                    // Dated alerts on a regular series must not become an alert on every expanded entry.
                    if !event.isDetached, !includingRecurrence {
                        let master = store.calendarItem(withIdentifier: event.calendarItemIdentifier) as? EKEvent
                        if event.hasRecurrenceRules || master?.hasRecurrenceRules == true { return .unsupported }
                    }
                    return .absolute(date)
                }
                return .relative(seconds: alarm.relativeOffset)
            }
            return .project(result, hasInvitationDetails: event.attendees?.isEmpty == false || event.organizer != nil,
                            alarms: alarms, eventStart: event.startDate)
        }
        return AgendaSyncCalendarProjection(content: result)
    }

    private func occurrenceIdentifier(of event: EKEvent, timeZone: TimeZone) throws -> AgendaSyncOccurrence {
        guard let date = event.occurrenceDate else { throw failure("A Calendar occurrence has no original date for sync.") }
        return AgendaSyncOccurrence(calendarItemID: event.calendarItemIdentifier,
            originalDate: try .from(date, in: event.isAllDay ? .current : timeZone, allDay: event.isAllDay))
    }

    private func occurrenceSnapshot(of event: EKEvent, timeZone: TimeZone,
                                    allowSourceOnlyMetadata: Bool) throws -> EventSnapshot {
        let occurrence = try occurrenceIdentifier(of: event, timeZone: timeZone)
        let external = try event.calendarItemExternalIdentifier.map {
            try AgendaSyncOccurrence(calendarItemID: $0, originalDate: occurrence.originalDate).identifier()
        }
        let projection = try readProjection(of: event, timeZone: timeZone, includingRecurrence: false,
                                            allowSourceOnlyMetadata: allowSourceOnlyMetadata)
        return EventSnapshot(id: try occurrence.identifier(), externalID: external, recoveryURL: nil,
                             content: AgendaSyncOccurrence.standaloneContent(projection.content), notices: projection.notices)
    }

    private func selectedCalendar(_ identifier: String) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: identifier) else {
            throw failure("The selected calendar is unavailable. Choose an available calendar before syncing.")
        }
        return calendar
    }

    func verifyMissing(_ identifier: String, timeZone: TimeZone) throws {
        try checkAccess()
        if let occurrence = AgendaSyncOccurrence(identifier: identifier) {
            // A series can remain after one exception is deleted or restored to its regular occurrence.
            // Only a still-existing detached appointment at the same original date blocks deletion.
            if let event = store.calendarItem(withIdentifier: occurrence.calendarItemID) as? EKEvent,
               event.isDetached, let originalDate = event.occurrenceDate {
                let original = try AgendaSyncContent.LocalDate.from(originalDate,
                    in: event.isAllDay ? .current : timeZone, allDay: event.isAllDay)
                if original == occurrence.originalDate {
                    throw failure("A linked edited occurrence moved outside the selected calendar or supported date range. Resolve that move before syncing.")
                }
            }
            return
        }
        if store.calendarItem(withIdentifier: identifier) != nil {
            throw failure("A linked Mac event moved outside the selected calendar or supported date range. Resolve that move before syncing.")
        }
    }

    private func checkAccess() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw failure("Calendar access is required. Allow full access to enable sync.")
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Reconnect.CalendarSync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
