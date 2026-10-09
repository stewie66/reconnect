import XCTest
@testable import PsionFormats

final class AgendaSyncOccurrenceTests: XCTestCase {
    private var zone: TimeZone { TimeZone(identifier: "Australia/Brisbane")! }
    private var series: AgendaSyncEvent {
        .init(id: "global:0123456789abcdef0123456789abcdef", content: .init(text: "Weekly appointment\nBring notes",
            location: "Office", start: .init(day: 17000, minute: 540), end: .init(day: 17000, minute: 600),
            repeatRule: .init(frequency: .weekly, untilDay: 17021, weekdays: [5]), alarmMinutes: -15))
    }

    func testOccurrenceIdentityUsesOriginalDateAndRoundTrips() throws {
        let first = AgendaSyncOccurrence(calendarItemID: "opaque:/series:one", originalDate: .init(day: 17007, minute: 540))
        let identifier = try first.identifier()
        XCTAssertEqual(AgendaSyncOccurrence(identifier: identifier), first)
        XCTAssertEqual(try first.identifier(), identifier)
        let second = AgendaSyncOccurrence(calendarItemID: first.calendarItemID, originalDate: .init(day: 17014, minute: 540))
        XCTAssertNotEqual(try second.identifier(), identifier)
        let anotherSeries = AgendaSyncOccurrence(calendarItemID: "opaque:/series:two", originalDate: first.originalDate)
        XCTAssertNotEqual(try anotherSeries.identifier(), identifier)
        XCTAssertNil(AgendaSyncOccurrence(identifier: "ordinary-calendar-identifier"))
        XCTAssertNil(AgendaSyncOccurrence(identifier: "reconnect-occurrence:invalid"))
    }

    func testAllDayAndMidnightOccurrencesHaveDistinctIdentities() throws {
        let allDay = AgendaSyncOccurrence(calendarItemID: "series", originalDate: .init(day: 17007))
        let midnight = AgendaSyncOccurrence(calendarItemID: "series", originalDate: .init(day: 17007, minute: 0))
        XCTAssertNotEqual(try allDay.identifier(), try midnight.identifier())
        XCTAssertEqual(AgendaSyncOccurrence(identifier: try allDay.identifier()), allDay)
    }

    func testEditedAndDeletedDatesAreExcludedWithoutExcludingTheMovedDate() throws {
        let content = try AgendaSyncRecurrence.excludingMissingOccurrences(in: series.content, observedDays: [17000, 17021])
        XCTAssertEqual(content.repeatRule?.excludedDays, [17007, 17014])
        var moved = series.content
        moved.start.day = 17008
        moved.end.day = 17008
        moved.text = "Rescheduled appointment\nBring notes"
        let standalone = AgendaSyncOccurrence.standaloneContent(moved)
        XCTAssertNil(standalone.repeatRule)
        XCTAssertEqual(standalone.start.day, 17008)
        XCTAssertEqual(standalone.alarmMinutes, -15)
        XCTAssertEqual(standalone.text, moved.text)
        XCTAssertEqual(standalone.location, moved.location)
        XCTAssertFalse(content.repeatRule!.excludedDays.contains(standalone.start.day))
    }

    func testNativeSeriesAndEditedAppointmentUpdateDeleteAndRestore() throws {
        var nativeSeries = series
        nativeSeries.content = try AgendaSyncRecurrence.excludingMissingOccurrences(in: series.content,
                                                                                    observedDays: [17000, 17014, 17021])
        var edited = AgendaSyncEvent(id: "global:abcdef0123456789abcdef0123456789", content: series.content)
        edited.content.start.day = 17008
        edited.content.end.day = 17008
        edited.content = AgendaSyncOccurrence.standaloneContent(edited.content)
        let original = SyntheticStore.emptyAgenda()
        let imported = try AgendaSyncDocument(original).applying(upserts: [nativeSeries, edited], deleting: [], timeZone: zone)
        var expected = Dictionary(uniqueKeysWithValues: [nativeSeries, edited].map { ($0.id, $0.content) })
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try AgendaSyncDocument(imported).events.map { ($0.id, $0.content) }), expected)

        // Moving the same exception again updates its existing native identity, without a new appointment.
        edited.content.start.day = 17009
        edited.content.end.day = 17009
        edited.content.location = "New room"
        let moved = try AgendaSyncDocument(imported).applying(upserts: [edited], deleting: [], timeZone: zone)
        expected[edited.id] = edited.content
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try AgendaSyncDocument(moved).events.map { ($0.id, $0.content) }), expected)
        let before = try PermanentStore(imported), after = try PermanentStore(moved)
        for id in 1...9 { XCTAssertEqual(try before.get(UInt32(id)), try after.get(UInt32(id))) }

        // Restoring the original Calendar occurrence removes its separate appointment and exclusion.
        let restored = try AgendaSyncDocument(moved).applying(upserts: [series], deleting: [edited.id], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(restored).events, [series])
    }

    func testDailyAndFortnightlyMissingDates() throws {
        var daily = series.content
        daily.repeatRule = .init(frequency: .daily, interval: 2, untilDay: 17006)
        XCTAssertEqual(try AgendaSyncRecurrence.excludingMissingOccurrences(in: daily, observedDays: [17000, 17004, 17006])
            .repeatRule?.excludedDays, [17002])
        var fortnightly = series.content
        fortnightly.repeatRule = .init(frequency: .weekly, interval: 2, untilDay: 17028, weekdays: [5])
        XCTAssertEqual(try AgendaSyncRecurrence.excludingMissingOccurrences(in: fortnightly, observedDays: [17000, 17028])
            .repeatRule?.excludedDays, [17014])
    }

    func testYearlyAndAllDayExceptions() throws {
        var yearly = series.content
        yearly.start = .init(day: 0)
        yearly.end = .init(day: 1)
        yearly.repeatRule = .init(frequency: .yearly, untilDay: 731)
        XCTAssertEqual(try AgendaSyncRecurrence.excludingMissingOccurrences(in: yearly, observedDays: [0, 731])
            .repeatRule?.excludedDays, [366])
        var detached = AgendaSyncOccurrence.standaloneContent(yearly)
        detached.start = .init(day: 367)
        detached.end = .init(day: 369)
        XCTAssertNil(detached.repeatRule)
        XCTAssertNil(detached.start.minute)
        XCTAssertEqual(detached.end.day - detached.start.day, 2)
    }

    func testTooManyMissingDatesFailBeforeProducingAnAgendaReplacement() throws {
        var daily = series.content
        daily.repeatRule = .init(frequency: .daily, untilDay: 18025)
        XCTAssertThrowsError(try AgendaSyncRecurrence.excludingMissingOccurrences(in: daily, observedDays: []))
        XCTAssertEqual(try AgendaSyncRecurrence.excludingMissingOccurrences(in: series.content,
            observedDays: [17000, 17007, 17014, 17021]), series.content)
    }
}
