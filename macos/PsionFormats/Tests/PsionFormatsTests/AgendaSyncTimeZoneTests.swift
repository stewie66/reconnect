import XCTest
@testable import PsionFormats

final class AgendaSyncTimeZoneTests: XCTestCase {
    private var brisbane: TimeZone { TimeZone(identifier: "Australia/Brisbane")! }
    private var gmt: TimeZone { TimeZone(secondsFromGMT: 0)! }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0,
                      zone: TimeZone) -> Date {
        DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: zone,
                       year: year, month: month, day: day, hour: hour, minute: minute).date!
    }

    private func occurrence(start: Date, end: Date) throws -> AgendaSyncRecurrence.Occurrence {
        try .init(start: .from(start, in: brisbane, allDay: false), end: .from(end, in: brisbane, allDay: false))
    }

    private func content(_ occurrences: [AgendaSyncRecurrence.Occurrence], rule: AgendaSyncContent.RepeatRule) -> AgendaSyncContent {
        .init(text: "Training - Gym", location: "Gym", start: occurrences[0].start, end: occurrences[0].end,
              repeatRule: rule, alarmMinutes: -15)
    }

    func testGMTToBrisbanePreservesADailyNativeRepeat() throws {
        let starts = (5...7).map { date(2026, 1, $0, 7, zone: gmt) }
        let observed = try starts.map { try occurrence(start: $0, end: $0.addingTimeInterval(3600)) }
        let input = content(observed, rule: .init(frequency: .daily, untilDay: observed.last!.start.day))
        let result = try XCTUnwrap(AgendaSyncRecurrence.converted(input,
            sourceStart: .from(starts[0], in: gmt, allDay: false), occurrences: observed))
        XCTAssertEqual(result.start.minute, 17 * 60)
        XCTAssertEqual(result.end.minute, 18 * 60)
        XCTAssertEqual(result.repeatRule?.frequency, .daily)
        XCTAssertEqual(result.repeatRule?.excludedDays, [])
    }

    func testForwardMidnightConversionPreservesFortnightlyWeekGroupingAndExclusions() throws {
        // Monday and Sunday in alternate GMT weeks become Tuesday and Monday in Brisbane.
        let starts = [5, 11, 19, 25].map { date(2026, 1, $0, 23, zone: gmt) }
        let observed = try starts.map { try occurrence(start: $0, end: $0.addingTimeInterval(3600)) }
        let input = content(observed, rule: .init(frequency: .weekly, interval: 2,
                                                 untilDay: observed.last!.start.day, weekdays: [0, 6]))
        let remaining = [observed[0], observed[2], observed[3]]
        let result = try XCTUnwrap(AgendaSyncRecurrence.converted(input,
            sourceStart: .from(starts[0], in: gmt, allDay: false), occurrences: remaining))
        XCTAssertEqual(result.start.minute, 9 * 60)
        XCTAssertEqual(result.repeatRule?.weekdays, [0, 1])
        XCTAssertEqual(result.repeatRule?.weekStart, 1)
        XCTAssertEqual(result.repeatRule?.excludedDays, [observed[1].start.day])
        let event = AgendaSyncEvent(id: "global:0123456789abcdef0123456789abcdef", content: result)
        let native = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [event], deleting: [], timeZone: brisbane)
        XCTAssertEqual(try AgendaSyncDocument(native).events, [event])
    }

    func testBackwardMidnightConversionMovesMondayToSunday() throws {
        let zone = TimeZone(identifier: "Pacific/Kiritimati")!
        let starts = [5, 12, 19].map { date(2026, 1, $0, 2, zone: zone) }
        let observed = try starts.map { try occurrence(start: $0, end: $0.addingTimeInterval(3600)) }
        let input = content(observed, rule: .init(frequency: .weekly, untilDay: observed.last!.start.day, weekdays: [0]))
        let result = try XCTUnwrap(AgendaSyncRecurrence.converted(input,
            sourceStart: .from(starts[0], in: zone, allDay: false), occurrences: observed))
        XCTAssertEqual(result.start.minute, 22 * 60)
        XCTAssertEqual(result.repeatRule?.weekdays, [6])
        XCTAssertEqual(result.repeatRule?.weekStart, 6)
        XCTAssertEqual(result.repeatRule?.excludedDays, [])
    }

    func testEquivalentZoneNamesDoNotRequireExpansion() throws {
        let queensland = TimeZone(identifier: "Australia/Queensland")!
        let starts = [5, 12, 19].map { date(2026, 1, $0, 7, zone: queensland) }
        let observed = try starts.map { try occurrence(start: $0, end: $0.addingTimeInterval(3600)) }
        let input = content(observed, rule: .init(frequency: .weekly, untilDay: observed.last!.start.day, weekdays: [0]))
        XCTAssertEqual(try AgendaSyncRecurrence.converted(input,
            sourceStart: .from(starts[0], in: queensland, allDay: false), occurrences: observed), input)
    }

    func testDifferentSummerAndWinterHoursRequireIndividualAppointments() throws {
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        let starts = [date(2026, 1, 5, 9, zone: sydney), date(2026, 7, 6, 9, zone: sydney)]
        let observed = try starts.map { try occurrence(start: $0, end: $0.addingTimeInterval(3600)) }
        XCTAssertEqual(observed.map(\.start.minute), [8 * 60, 9 * 60])
        let input = content(observed, rule: .init(frequency: .weekly, untilDay: observed.last!.start.day, weekdays: [0]))
        XCTAssertNil(try AgendaSyncRecurrence.converted(input,
            sourceStart: .from(starts[0], in: sydney, allDay: false), occurrences: observed))
        let singles = observed.enumerated().map { index, dates in
            AgendaSyncEvent(id: "global:" + String(format: "%032x", index + 1),
                content: .init(text: input.text, location: input.location, start: dates.start, end: dates.end,
                               alarmMinutes: input.alarmMinutes))
        }
        // Retiring an already-linked series must not leave it alongside its expanded appointments.
        let aggregate = AgendaSyncEvent(id: "global:0123456789abcdef0123456789abcdef", content: input)
        let first = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [aggregate], deleting: [], timeZone: brisbane)
        let expanded = try AgendaSyncDocument(first).applying(upserts: singles, deleting: [aggregate.id], timeZone: brisbane)
        XCTAssertEqual(Set(try AgendaSyncDocument(expanded).events.map(\.id)), Set(singles.map(\.id)))
        for event in try AgendaSyncDocument(expanded).events {
            XCTAssertNil(event.content.repeatRule)
            XCTAssertEqual(event.content, singles.first { $0.id == event.id }?.content)
        }
        XCTAssertEqual(try AgendaSyncDocument(expanded).applying(upserts: singles, deleting: [], timeZone: brisbane), expanded)
    }

    func testAnOvernightDSTTransitionCannotChangeTheAppointmentEnd() throws {
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        let starts = [date(2026, 3, 28, 23, 30, zone: sydney), date(2026, 4, 4, 23, 30, zone: sydney)]
        let ends = [date(2026, 3, 29, 4, 30, zone: sydney), date(2026, 4, 5, 4, 30, zone: sydney)]
        let observed = try zip(starts, ends).map { try occurrence(start: $0.0, end: $0.1) }
        XCTAssertEqual(observed[0].start.minute, observed[1].start.minute)
        XCTAssertNotEqual(observed[0].end.minute, observed[1].end.minute)
        let input = content(observed, rule: .init(frequency: .weekly, untilDay: observed.last!.start.day, weekdays: [5]))
        XCTAssertNil(try AgendaSyncRecurrence.converted(input,
            sourceStart: .from(starts[0], in: sydney, allDay: false), occurrences: observed))
    }

    func testYearlyDateShiftAcrossLeapYearsRequiresExpansion() throws {
        let starts = [date(2024, 2, 28, 20, zone: gmt), date(2025, 2, 28, 20, zone: gmt)]
        let observed = try starts.map { try occurrence(start: $0, end: $0.addingTimeInterval(3600)) }
        let input = content(observed, rule: .init(frequency: .yearly, untilDay: observed.last!.start.day))
        XCTAssertNil(try AgendaSyncRecurrence.converted(input,
            sourceStart: .from(starts[0], in: gmt, allDay: false), occurrences: observed))
        XCTAssertNil(try AgendaSyncRecurrence.converted(input,
            sourceStart: .from(starts[0], in: gmt, allDay: false), occurrences: []))
    }
}
