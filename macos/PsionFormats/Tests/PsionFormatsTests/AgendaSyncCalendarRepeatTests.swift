import XCTest
@testable import PsionFormats

final class AgendaSyncCalendarRepeatTests: XCTestCase {
    private var zone: TimeZone { TimeZone(identifier: "Australia/Brisbane")! }

    private func local(_ year: Int, _ month: Int, _ day: Int, minute: Int? = nil) throws -> AgendaSyncContent.LocalDate {
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: zone,
                                  year: year, month: month, day: day).date!
        var result = try AgendaSyncContent.LocalDate.from(date, in: zone, allDay: true)
        result.minute = minute
        return result
    }

    func testEveryThreeWeeksOnMondayAndThursdayStaysNative() throws {
        XCTAssertTrue(AgendaSyncCalendarRepeat(frequency: .weekly, interval: 3,
            weekdays: [.init(day: 0), .init(day: 3)]).canKeepNative)
        let start = try local(2026, 1, 5, minute: 600)
        let offsets = [0, 3, 21, 24, 42, 45]
        let observed = offsets.map { offset in
            AgendaSyncRecurrence.Occurrence(start: .init(day: start.day + offset, minute: 600),
                                            end: .init(day: start.day + offset, minute: 660))
        }
        let content = AgendaSyncContent(text: "Three-week schedule", start: start, end: observed[0].end,
            repeatRule: .init(frequency: .weekly, interval: 3, untilDay: start.day + 45, weekdays: [0, 3]))
        let converted = try XCTUnwrap(AgendaSyncRecurrence.converted(content, sourceStart: start, occurrences: observed))
        XCTAssertEqual(converted.repeatRule?.excludedDays, [])
        let event = AgendaSyncEvent(id: "global:0123456789abcdef0123456789abcdef", content: converted)
        let data = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [event], deleting: [], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(data).events, [event])
    }

    func testMonthlyOrdinalOccurrencesPreserveSpansAndRescheduledIdentity() throws {
        XCTAssertFalse(AgendaSyncCalendarRepeat(frequency: .monthly,
            weekdays: [.init(day: 1, ordinal: 2)]).canKeepNative)
        let originalDays = try [(1, 13), (2, 10), (3, 10)].map { try local(2026, $0.0, $0.1) }
        let singles = originalDays.enumerated().map { index, start in
            AgendaSyncEvent(id: "global:" + String(format: "%032x", index + 1),
                content: .init(text: "Second Tuesday retreat", start: start, end: .init(day: start.day + 3)))
        }
        let first = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: singles, deleting: [], timeZone: zone)
        var moved = singles[1]
        let identity = try AgendaSyncOccurrence(calendarItemID: "monthly-series", originalDate: originalDays[1]).identifier()
        moved.content.start.day += 1
        moved.content.end.day += 1
        moved.content.text = "Rescheduled retreat"
        XCTAssertEqual(AgendaSyncOccurrence(identifier: identity)?.originalDate, originalDays[1])
        let updated = try AgendaSyncDocument(first).applying(upserts: [moved], deleting: [singles[2].id], timeZone: zone)
        let events = try AgendaSyncDocument(updated).events
        XCTAssertEqual(Set(events.map(\.id)), [singles[0].id, moved.id])
        XCTAssertEqual(events.first { $0.id == moved.id }?.content, moved.content)
        for event in events {
            XCTAssertNil(event.content.repeatRule)
            XCTAssertEqual(event.content.end.day - event.content.start.day, 3)
            XCTAssertNil(event.content.start.minute)
        }
        XCTAssertEqual(try AgendaSyncDocument(updated).applying(upserts: [moved], deleting: [], timeZone: zone), updated)
    }

    func testCountLimitedAndYearlyOrdinalRulesRequireExpansion() throws {
        XCTAssertFalse(AgendaSyncCalendarRepeat(frequency: .daily, occurrenceCount: 3).canKeepNative)
        XCTAssertFalse(AgendaSyncCalendarRepeat(frequency: .yearly,
            weekdays: [.init(day: 0, ordinal: -1)]).canKeepNative)
        XCTAssertFalse(AgendaSyncCalendarRepeat(frequency: .yearly, hasAdditionalSelectors: true).canKeepNative)
        XCTAssertFalse(AgendaSyncCalendarRepeat(frequency: .daily, interval: 65536).canKeepNative)
        let singles = (0..<3).map { index in
            AgendaSyncEvent(id: "global:" + String(format: "%032x", index + 1),
                content: .init(text: "Only three appointments", start: .init(day: 17000 + index, minute: 540),
                               end: .init(day: 17000 + index, minute: 600)))
        }
        let native = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: singles, deleting: [], timeZone: zone)
        let result = try AgendaSyncDocument(native).events
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.content.repeatRule == nil })
        XCTAssertEqual(Set(result.map { $0.content.start.day }), [17000, 17001, 17002])
    }

    func testUnboundedNativeRepeatKeepsNoEndDateWithinValidatedRange() throws {
        let start = AgendaSyncContent.LocalDate(day: 17000, minute: 540)
        let observed = stride(from: start.day, through: 44194, by: 7).map {
            AgendaSyncRecurrence.Occurrence(start: .init(day: $0, minute: 540), end: .init(day: $0, minute: 600))
        }
        let content = AgendaSyncContent(text: "No end date", start: start, end: observed[0].end,
            repeatRule: .init(frequency: .weekly, weekdays: [5]))
        let converted = try XCTUnwrap(AgendaSyncRecurrence.converted(content, sourceStart: start, occurrences: observed))
        XCTAssertNil(converted.repeatRule?.untilDay)
        XCTAssertEqual(converted.repeatRule?.excludedDays, [])
        let event = AgendaSyncEvent(id: "global:0123456789abcdef0123456789abcdef", content: converted)
        let native = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [event], deleting: [], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(native).events, [event])
    }

    func testTooManyExclusionsChooseExpansionWithoutDroppingDates() throws {
        let content = AgendaSyncContent(text: "Sparse daily series", start: .init(day: 17000, minute: 540),
            end: .init(day: 17000, minute: 600), repeatRule: .init(frequency: .daily, untilDay: 19000))
        let observed = [AgendaSyncRecurrence.Occurrence(start: content.start, end: content.end)]
        XCTAssertNil(try AgendaSyncRecurrence.converted(content, sourceStart: content.start, occurrences: observed))
        XCTAssertThrowsError(try AgendaSyncRecurrence.excludingMissingOccurrences(in: content, observedDays: [17000]))
    }

    func testLongPlainNotesAndTimedMultiDayEventRoundTripWithoutTruncation() throws {
        let notes = String(repeating: "Long notes with café and £.\n", count: 800)
        let event = AgendaSyncEvent(id: "global:0123456789abcdef0123456789abcdef",
            content: .init(text: "Weekend trip\n" + notes, location: "Brisbane", start: .init(day: 17000, minute: 1380),
                           end: .init(day: 17003, minute: 120), alarmMinutes: -30))
        let native = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [event], deleting: [], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(native).events, [event])
        XCTAssertEqual(try AgendaSyncDocument(native).events[0].content.text.count, event.content.text.count)
    }
}
