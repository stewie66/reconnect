import XCTest
@testable import PsionFormats

final class AgendaSyncCalendarSourceTests: XCTestCase {
    private var zone: TimeZone { TimeZone(identifier: "Australia/Brisbane")! }
    private var start: Date { Date(timeIntervalSince1970: 1_500_000_000) }

    func testSourceRoundsEndpointsAndAllowsVeryShortAppointments() throws {
        for (offset, expectedStart, expectedEnd) in [(0.0, 540, 540), (50.0, 541, 541)] {
            let original = try AgendaSyncContent.LocalDate(day: 17000, minute: 540).date(in: zone).addingTimeInterval(offset)
            let projected = try AgendaSyncCalendarProjection.sourceContent(text: "Inspection", location: "Office",
                start: original, end: original.addingTimeInterval(1), allDay: false, timeZone: zone)
            XCTAssertEqual(projected.content.start.minute, expectedStart)
            XCTAssertEqual(projected.content.end.minute, expectedEnd)
            XCTAssertEqual(projected.notices, [.roundedTimes])
            let event = AgendaSyncEvent(id: "global:0123456789abcdef0123456789abcdef", content: projected.content)
            let native = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [event], deleting: [], timeZone: zone)
            XCTAssertEqual(try AgendaSyncDocument(native).events, [event])
        }
        let projected = try AgendaSyncCalendarProjection.sourceContent(text: "Inspection", location: "",
            start: start, end: start.addingTimeInterval(3659), allDay: false, timeZone: zone)
        XCTAssertEqual(projected.content.end.minute! - projected.content.start.minute!, 61)
        XCTAssertThrowsError(try AgendaSyncContent.LocalDate.from(start.addingTimeInterval(50), in: zone, allDay: false))
    }

    func testRoundingCrossesMidnightAndAllDayDatesStayFloating() throws {
        let original = try AgendaSyncContent.LocalDate(day: 17000, minute: 1439).date(in: zone).addingTimeInterval(50)
        let projected = try AgendaSyncCalendarProjection.sourceContent(text: "Overnight", location: "",
            start: original, end: original.addingTimeInterval(3600), allDay: false, timeZone: zone)
        XCTAssertEqual(projected.content.start, .init(day: 17001, minute: 0))
        XCTAssertEqual(projected.content.end, .init(day: 17001, minute: 60))
        let allDay = try AgendaSyncCalendarProjection.sourceContent(text: "Day note", location: "",
            start: original, end: original.addingTimeInterval(86400), allDay: true, timeZone: zone)
        XCTAssertEqual(allDay.content.start, .init(day: 17000))
        XCTAssertEqual(allDay.content.end, .init(day: 17001))
        XCTAssertFalse(allDay.notices.contains(.roundedTimes))
    }

    func testReadableCopiesPreserveLatinTextAndReplaceUnrepresentableGraphemes() throws {
        let original = "Café £ — 東京\nTraining 🏋️‍♂️ 😊\nName ą ō"
        let projected = try AgendaSyncCalendarProjection.sourceContent(text: original, location: "\u{200e}Office",
            start: start, end: start.addingTimeInterval(3600), allDay: false, timeZone: zone)
        XCTAssertTrue(projected.content.text.hasPrefix("Café £ — "))
        XCTAssertTrue(projected.content.text.contains("Training ? ?"))
        XCTAssertTrue(projected.content.text.hasSuffix("Name a o"))
        XCTAssertEqual(projected.content.location, "Office")
        XCTAssertEqual(projected.notices, [.convertedText])
        _ = try BinaryWriter.text(projected.content.text)
        let event = AgendaSyncEvent(id: "global:0123456789abcdef0123456789abcdef", content: projected.content)
        let native = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [event], deleting: [], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(native).events, [event])
        XCTAssertThrowsError(try BinaryWriter.text(original))
        XCTAssertEqual(AgendaSyncCalendarText.readable("Café £\nNotes\n"), "Café £\nNotes\n")
    }

    func testEmptyTextAndNativeControlCharactersBecomeReadableCopies() throws {
        let blank = try AgendaSyncCalendarProjection.sourceContent(text: "\u{200e} \n", location: "",
            start: start, end: start, allDay: false, timeZone: zone)
        XCTAssertEqual(blank.content.text, "Untitled appointment")
        XCTAssertEqual(blank.notices, [.convertedText, .placeholderText])
        XCTAssertEqual(AgendaSyncCalendarText.readable("Line\r\nNext\rLast\u{0006}paragraph"), "Line\nNext\nLast paragraph")
    }

    func testPreciseOccurrenceIdentitiesRemainDistinctAndLegacyIDsStayUnchanged() throws {
        let date = try AgendaSyncCalendarProjection.roundedLocalDate(start, in: zone, allDay: false)
        let first = AgendaSyncOccurrence(calendarItemID: "series", originalDate: date, originalInstant: start.addingTimeInterval(1))
        let second = AgendaSyncOccurrence(calendarItemID: "series", originalDate: date, originalInstant: start.addingTimeInterval(2))
        XCTAssertNotEqual(try first.identifier(), try second.identifier())
        XCTAssertEqual(AgendaSyncOccurrence(identifier: try first.identifier()), first)
        let old = AgendaSyncOccurrence(calendarItemID: "series", originalDate: .init(day: 17000, minute: 540))
        let legacy = Data("{\"calendarItemID\":\"series\",\"originalDate\":{\"day\":17000,\"minute\":540}}".utf8)
        XCTAssertEqual(try old.identifier(), "reconnect-occurrence:" + legacy.base64EncodedString())
    }

    func testPreEpochAnnualSeriesCanUseSupportedOccurrencesWithoutChangingItsDates() throws {
        let first = try AgendaSyncContent.LocalDate(day: 185).date(in: zone)
        let projected = try AgendaSyncCalendarProjection.sourceContent(text: "Anniversary\nOriginal Calendar series start: 1955-07-04",
            location: "", start: first, end: first.addingTimeInterval(86400), allDay: true, timeZone: zone)
        var content = projected.content
        content.repeatRule = .init(frequency: .yearly, untilDay: 1000)
        let converted = try XCTUnwrap(AgendaSyncRecurrence.converted(content, sourceStart: content.start,
            occurrences: [185, 550, 915].map { .init(start: .init(day: $0), end: .init(day: $0 + 1)) }))
        let event = AgendaSyncEvent(id: "global:0123456789abcdef0123456789abcdef", content: converted)
        let native = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [event], deleting: [], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(native).events, [event])
    }

    /// Opt-in private fixture: validate each exported record's projected fields, not EventKit enumeration.
    /// The original export and generated personal data are never stored in the repository.
    func testOptionalAppleCalendarExportProjectedCopies() throws {
        guard let path = ProcessInfo.processInfo.environment["PSION_CALENDAR_EXPORT_FIXTURE"] else {
            throw XCTSkip("Private Calendar export not supplied")
        }
        let lines = try CalendarContentLine.read(Data(contentsOf: URL(fileURLWithPath: path)))
        var records: [[CalendarContentLine]] = [], current: [CalendarContentLine] = [], stack: [String] = []
        for line in lines {
            if line.name == "BEGIN" {
                stack.append(line.value)
                if line.value == "VEVENT" { current = [] }
            } else if line.name == "END" {
                if line.value == "VEVENT" { records.append(current) }
                _ = stack.popLast()
            } else if stack.last == "VEVENT" { current.append(line) }
        }
        XCTAssertFalse(records.isEmpty)
        var events: [AgendaSyncEvent] = []
        for (index, properties) in records.enumerated() {
            func first(_ name: String) -> CalendarContentLine? { properties.first { $0.name == name } }
            let startLine = try XCTUnwrap(first("DTSTART")), endLine = try XCTUnwrap(first("DTEND"))
            let allDay = startLine.parameters["VALUE"] == "DATE"
            func date(_ line: CalendarContentLine) throws -> Date {
                let utc = line.value.hasSuffix("Z")
                let sourceZone = try line.parameters["TZID"].map { try XCTUnwrap(TimeZone(identifier: $0)) } ?? (utc ? TimeZone(secondsFromGMT: 0)! : zone)
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = sourceZone
                formatter.dateFormat = line.parameters["VALUE"] == "DATE" ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
                let value = utc ? String(line.value.dropLast()) : line.value
                return try XCTUnwrap(formatter.date(from: value))
            }
            var start = try date(startLine), end = try date(endLine)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let originalYear = calendar.component(.year, from: start)
            if originalYear < 1980 {
                XCTAssertNotNil(first("RRULE"), "Out-of-range non-recurring record at index \(index)")
                start = try XCTUnwrap(calendar.date(byAdding: .year, value: 1980 - originalYear, to: start))
                end = try XCTUnwrap(calendar.date(byAdding: .year, value: 1980 - originalYear, to: end))
            }
            let text = try [first("SUMMARY")?.text(), first("DESCRIPTION")?.text()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            let projected = try AgendaSyncCalendarProjection.sourceContent(text: text,
                location: first("LOCATION")?.text() ?? "", start: start, end: end, allDay: allDay, timeZone: zone)
            events.append(.init(id: "global:" + String(format: "%032x", index + 1), content: projected.content))
        }
        let native = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: events, deleting: [], timeZone: zone)
        let result = Dictionary(uniqueKeysWithValues: try AgendaSyncDocument(native).events.map { ($0.id, $0.content) })
        XCTAssertEqual(result.count, records.count)
        for event in events { XCTAssertEqual(result[event.id], event.content, "Projected record did not round-trip: \(event.id)") }
    }
}
