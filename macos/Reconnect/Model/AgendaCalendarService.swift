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

    func snapshot(calendarID: String, timeZone: TimeZone, identityTimeZone: TimeZone? = nil,
                  allowSourceOnlyMetadata: Bool = false) throws -> CalendarSnapshot {
        try checkAccess()
        store.reset()
        let calendar = try selectedCalendar(calendarID)
        let identityZone = identityTimeZone ?? timeZone
        var masters: [String: EKEvent] = [:]
        var occurrences: [String: Set<Int>] = [:]
        var editedOccurrences: [String: EventSnapshot] = [:]
        var detachedSeriesIDs = Set<String>()
        var sourceOccurrences: [String: [String: EKEvent]] = [:]
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
                    detachedSeriesIDs.insert(event.calendarItemIdentifier)
                    // Canceled exceptions are absent appointments; they still exclude the original date.
                    guard event.status != .canceled else { continue }
                    let single = try occurrenceSnapshot(of: event, timeZone: timeZone, identityTimeZone: identityZone,
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
                    if allowSourceOnlyMetadata {
                        let id = try occurrenceIdentifier(of: event, timeZone: identityZone, allowRounding: true).identifier()
                        if let previous = sourceOccurrences[identifier]?[id],
                           previous.startDate != event.startDate || previous.endDate != event.endDate {
                            throw failure("Calendar returned conflicting versions of a recurring occurrence. Try syncing again.")
                        }
                        sourceOccurrences[identifier, default: [:]][id] = event
                    }
                }
            }
        }
        var series: [EventSnapshot] = []
        // A finite series can have every occurrence edited or canceled. Its old native repeat
        // must be retired even when EventKit returns no unchanged occurrence to use as an anchor.
        var replacedSeriesIDs = allowSourceOnlyMetadata ? detachedSeriesIDs.subtracting(masters.keys) : []
        for (identifier, event) in masters {
            try Task.checkCancellation()
            let canKeepNative = nativeRepeatIsSupported(event)
            let sourceZone = event.isAllDay ? TimeZone.current : (event.timeZone ?? .current)
            var sourceCalendar = Calendar(identifier: .gregorian)
            sourceCalendar.timeZone = sourceZone
            // Birthday/anniversary series can start before Agenda's epoch. Use their first fetched
            // regular occurrence, while retaining the master ID, rules and original date in notes.
            let needsAnchor = allowSourceOnlyMetadata && sourceCalendar.component(.year, from: event.startDate) < 1980
            let anchor = needsAnchor ? sourceOccurrences[identifier]?.values.min(by: { $0.startDate < $1.startDate }) : nil
            var projection = try readProjection(of: event, timeZone: timeZone,
                                                 includingRecurrence: !allowSourceOnlyMetadata || canKeepNative,
                                                 allowSourceOnlyMetadata: allowSourceOnlyMetadata,
                                                 startOverride: anchor?.startDate, endOverride: anchor?.endDate)
            var originalSeriesNote: String?
            if anchor != nil {
                let original = sourceCalendar.dateComponents([.year, .month, .day], from: event.startDate)
                originalSeriesNote = String(format: "Original Calendar series start: %04d-%02d-%02d",
                                            original.year!, original.month!, original.day!)
                projection.content.text += "\n" + originalSeriesNote!
                projection.notices.insert(.reanchoredRecurrence)
            }
            let content: AgendaSyncContent
            if let regularEvents = sourceOccurrences[identifier], !regularEvents.isEmpty {
                let dateZone = event.isAllDay ? TimeZone.current : timeZone
                var converted: AgendaSyncContent?
                if canKeepNative {
                    let sourceStart = try AgendaSyncCalendarProjection.roundedLocalDate(anchor?.startDate ?? event.startDate,
                        in: sourceZone, allDay: event.isAllDay)
                    let observed = try regularEvents.values.map {
                        try AgendaSyncRecurrence.Occurrence(
                            start: AgendaSyncCalendarProjection.roundedLocalDate($0.startDate, in: dateZone, allDay: event.isAllDay),
                            end: AgendaSyncCalendarProjection.roundedLocalDate($0.endDate, in: dateZone, allDay: event.isAllDay))
                    }
                    converted = try AgendaSyncRecurrence.converted(projection.content, sourceStart: sourceStart,
                                                                   occurrences: observed)
                }
                if let converted {
                    content = converted
                    if !event.isAllDay, sourceZone != timeZone { projection.notices.insert(.convertedTimeZone) }
                } else {
                    replacedSeriesIDs.insert(identifier)
                    for occurrence in regularEvents.values {
                        try Task.checkCancellation()
                        var single = try occurrenceSnapshot(of: occurrence, timeZone: timeZone, identityTimeZone: identityZone,
                                                            allowSourceOnlyMetadata: true)
                        if let originalSeriesNote {
                            single.content.text += "\n" + originalSeriesNote
                            single.notices.insert(.reanchoredRecurrence)
                        }
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
                                allowSourceOnlyMetadata: Bool, startOverride: Date? = nil,
                                endOverride: Date? = nil) throws -> AgendaSyncCalendarProjection {
        do {
            return try projection(of: event, timeZone: timeZone, includingRecurrence: includingRecurrence,
                                  allowSourceOnlyMetadata: allowSourceOnlyMetadata,
                                  startOverride: startOverride, endOverride: endOverride)
        } catch {
            let title = event.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled event"
            throw failure("Calendar event “\(title)”: " + error.localizedDescription)
        }
    }

    private func projection(of event: EKEvent, timeZone: TimeZone, includingRecurrence: Bool = true,
                            allowSourceOnlyMetadata: Bool = false, startOverride: Date? = nil,
                            endOverride: Date? = nil) throws -> AgendaSyncCalendarProjection {
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
        guard let start = startOverride ?? event.startDate, let end = endOverride ?? event.endDate else {
            throw failure("The event has no start or end date.")
        }
        let initial: AgendaSyncCalendarProjection
        if allowSourceOnlyMetadata {
            initial = try .sourceContent(text: text, location: event.location ?? "", start: start, end: end,
                                        allDay: event.isAllDay, timeZone: dateZone, tentative: event.status == .tentative)
        } else {
            initial = .init(content: .init(text: text, location: event.location ?? "",
                start: try .from(start, in: dateZone, allDay: event.isAllDay),
                end: try .from(end, in: dateZone, allDay: event.isAllDay), tentative: event.status == .tentative))
        }
        var result = initial.content
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
            guard nativeRepeatIsSupported(event) else {
                throw failure("This repeat pattern needs Mac Calendar → Agenda, which copies its occurrences as individual appointments.")
            }
            let rule = rules[0]
            let weekdays = rule.daysOfTheWeek?.map { (Int($0.dayOfTheWeek.rawValue) + 5) % 7 }.sorted() ?? []
            let sourceStart = try AgendaSyncContent.LocalDate.from(start, in: event.isAllDay ? .current : (event.timeZone ?? .current),
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
            var projected = AgendaSyncCalendarProjection.project(result,
                hasInvitationDetails: event.attendees?.isEmpty == false || event.organizer != nil,
                alarms: alarms, eventStart: start)
            projected.notices.formUnion(initial.notices)
            return projected
        }
        return AgendaSyncCalendarProjection(content: result)
    }

    private func occurrenceIdentifier(of event: EKEvent, timeZone: TimeZone, allowRounding: Bool = false) throws -> AgendaSyncOccurrence {
        guard let date = event.occurrenceDate else { throw failure("A Calendar occurrence has no original date for sync.") }
        let dateZone = event.isAllDay ? TimeZone.current : timeZone
        let precise = event.isAllDay || AgendaSyncCalendarProjection.hasMinutePrecision(date)
        return AgendaSyncOccurrence(calendarItemID: event.calendarItemIdentifier,
            originalDate: try allowRounding ? AgendaSyncCalendarProjection.roundedLocalDate(date, in: dateZone, allDay: event.isAllDay) :
                .from(date, in: dateZone, allDay: event.isAllDay),
            originalInstant: precise ? nil : date)
    }

    private func occurrenceSnapshot(of event: EKEvent, timeZone: TimeZone, identityTimeZone: TimeZone,
                                    allowSourceOnlyMetadata: Bool) throws -> EventSnapshot {
        let occurrence = try occurrenceIdentifier(of: event, timeZone: identityTimeZone, allowRounding: allowSourceOnlyMetadata)
        let external = try event.calendarItemExternalIdentifier.map {
            try AgendaSyncOccurrence(calendarItemID: $0, originalDate: occurrence.originalDate,
                                    originalInstant: occurrence.originalInstant).identifier()
        }
        let projection = try readProjection(of: event, timeZone: timeZone, includingRecurrence: false,
                                            allowSourceOnlyMetadata: allowSourceOnlyMetadata)
        return EventSnapshot(id: try occurrence.identifier(), externalID: external, recoveryURL: nil,
                             content: AgendaSyncOccurrence.standaloneContent(projection.content), notices: projection.notices)
    }

    private func nativeRepeatIsSupported(_ event: EKEvent) -> Bool {
        guard let rules = event.recurrenceRules, !rules.isEmpty else { return !event.hasRecurrenceRules }
        guard rules.count == 1 else { return false }
        let rule = rules[0]
        let frequency: AgendaSyncCalendarRepeat.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return false
        }
        return AgendaSyncCalendarRepeat(frequency: frequency, interval: rule.interval,
            occurrenceCount: rule.recurrenceEnd?.occurrenceCount ?? 0,
            weekdays: rule.daysOfTheWeek?.map { .init(day: (Int($0.dayOfTheWeek.rawValue) + 5) % 7, ordinal: $0.weekNumber) } ?? [],
            hasAdditionalSelectors: rule.daysOfTheMonth?.isEmpty == false || rule.monthsOfTheYear?.isEmpty == false ||
                rule.daysOfTheYear?.isEmpty == false || rule.weeksOfTheYear?.isEmpty == false ||
                rule.setPositions?.isEmpty == false).canKeepNative
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
               event.isDetached {
                let actual = try occurrenceIdentifier(of: event, timeZone: timeZone, allowRounding: true)
                if actual.originalDate == occurrence.originalDate && actual.originalInstant == occurrence.originalInstant {
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
