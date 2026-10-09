import XCTest
@testable import PsionFormats

final class AgendaSyncTests: XCTestCase {
    private var zone: TimeZone { TimeZone(identifier: "Australia/Brisbane")! }
    private var event: AgendaSyncEvent {
        .init(id: "global:0123456789abcdef0123456789abcdef", content: .init(text: "Planning\nBring notes",
            location: "Library", start: .init(day: 17000, minute: 540), end: .init(day: 17000, minute: 600)))
    }

    func testNativeCreateUpdateDeleteAndUnrelatedStreams() throws {
        let empty = SyntheticStore.emptyAgenda()
        let first = try AgendaSyncDocument(empty).applying(upserts: [event], deleting: [], timeZone: zone)
        var changed = event
        changed.content.text = "Updated meeting"
        changed.content.location = "Office"
        changed.content.alarmMinutes = -15
        let updated = try AgendaSyncDocument(first).applying(upserts: [changed], deleting: [], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(updated).events, [changed])
        let before = try PermanentStore(first), after = try PermanentStore(updated)
        for id in 1...9 { XCTAssertEqual(try before.get(UInt32(id)), try after.get(UInt32(id))) }
        let deleted = try AgendaSyncDocument(updated).applying(upserts: [], deleting: [event.id], timeZone: zone)
        XCTAssertTrue(try AgendaSyncDocument(deleted).events.isEmpty)
        XCTAssertFalse(String(decoding: try AgendaConverter.convert(deleted), as: UTF8.self).contains("BEGIN:VEVENT"))
    }

    func testIdentitySurvivesAnotherEventAndNativeEdit() throws {
        let first = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [event], deleting: [], timeZone: zone)
        var second = event
        second.id = "global:abcdef0123456789abcdef0123456789"
        second.content.text = "Another event"
        let both = try AgendaSyncDocument(first).applying(upserts: [second], deleting: [], timeZone: zone)
        XCTAssertEqual(Set(try AgendaSyncDocument(both).events.map(\.id)), [event.id, second.id])
        let native = try AgendaSyncDocument(SyntheticStore.agenda(recurrence: 1))
        var changed = try XCTUnwrap(native.events.first)
        let identifier = changed.id
        changed.content.location = "New room"
        let updated = try native.applying(upserts: [changed], deleting: [], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(updated).events.first?.id, identifier)
    }

    func testAllDayRepeatAndExclusionsRoundTrip() throws {
        var recurring = event
        recurring.content.start.minute = nil
        recurring.content.end = .init(day: recurring.content.start.day + 2)
        recurring.content.repeatRule = .init(frequency: .weekly, interval: 2, untilDay: 17100,
            weekdays: [5], excludedDays: [17014])
        // 17000 days after 1980-01-01 is Saturday.
        let data = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [recurring], deleting: [], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(data).events, [recurring])
    }

    func testUnsupportedUpdateDoesNotModifyInput() throws {
        let native = try AgendaSyncDocument(SyntheticStore.agenda())
        var changed = try XCTUnwrap(native.events.first)
        changed.content.repeatRule = nil
        XCTAssertThrowsError(try native.applying(upserts: [changed], deleting: [], timeZone: zone))
        changed = try XCTUnwrap(native.events.first)
        changed.content.text = "Meeting 🗓"
        XCTAssertThrowsError(try native.applying(upserts: [changed], deleting: [], timeZone: zone))
    }

    func testThreeWayReconciliationAndDeleteEditConflict() throws {
        let base = event.content
        var changed = base
        changed.text = "Changed"
        XCTAssertEqual(try AgendaSyncPlanner.resolve(agenda: changed, mac: base, baseline: base, hasBaseline: true,
            direction: .bidirectional, conflicts: .pause), changed)
        XCTAssertNil(try AgendaSyncPlanner.resolve(agenda: nil, mac: base, baseline: base, hasBaseline: true,
            direction: .bidirectional, conflicts: .pause))
        XCTAssertThrowsError(try AgendaSyncPlanner.resolve(agenda: nil, mac: changed, baseline: base, hasBaseline: true,
            direction: .bidirectional, conflicts: .pause))
        XCTAssertEqual(try AgendaSyncPlanner.resolve(agenda: nil, mac: changed, baseline: base, hasBaseline: true,
            direction: .bidirectional, conflicts: .preferMac), changed)
        XCTAssertEqual(try AgendaSyncPlanner.resolve(agenda: base, mac: changed, baseline: nil, hasBaseline: false,
            direction: .agendaToMac, conflicts: .pause), base)
        XCTAssertEqual(try AgendaSyncPlanner.resolve(agenda: base, mac: changed, baseline: nil, hasBaseline: false,
            direction: .macToAgenda, conflicts: .pause), changed)
    }

    func testDeletedEntryCanBeRestoredWithoutChangingItsIdentity() throws {
        for original in [SyntheticStore.agenda(recurrence: 1), SyntheticStore.emptyAgenda()] {
            let populated = try AgendaSyncDocument(original).events.isEmpty
                ? AgendaSyncDocument(original).applying(upserts: [event], deleting: [], timeZone: zone) : original
            let document = try AgendaSyncDocument(populated)
            let existing = try XCTUnwrap(document.events.first)
            let deleted = try document.applying(upserts: [], deleting: [existing.id], timeZone: zone)
            XCTAssertTrue(try AgendaSyncDocument(deleted).events.isEmpty)
            let restored = try AgendaSyncDocument(deleted).applying(upserts: [existing], deleting: [], timeZone: zone)
            XCTAssertEqual(try AgendaSyncDocument(restored).events, [existing])
        }
    }

    func testNoOpPreservesWholeFileAndBatchUpdatesKeepUnrelatedEvents() throws {
        let entries = (0..<34).map { index in
            AgendaSyncEvent(id: "global:" + String(format: "%032x", index), content: .init(text: "Event \(index)",
                start: .init(day: 17000 + index, minute: 540), end: .init(day: 17000 + index, minute: 600)))
        }
        let original = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: entries, deleting: [], timeZone: zone)
        let document = try AgendaSyncDocument(original)
        XCTAssertEqual(try document.applying(upserts: document.events, deleting: [], timeZone: zone), original)
        var changed = entries[17]
        changed.content.text = "Updated across cluster boundary"
        let updated = try document.applying(upserts: [changed], deleting: [entries[2].id], timeZone: zone)
        let records = Dictionary(uniqueKeysWithValues: try AgendaSyncDocument(updated).events.map { ($0.id, $0) })
        XCTAssertEqual(records.count, 33)
        XCTAssertEqual(records[changed.id], changed)
        XCTAssertNil(records[entries[2].id])
        for entry in entries where entry.id != changed.id && entry.id != entries[2].id {
            XCTAssertEqual(records[entry.id], entry)
        }
    }

    func testLocalDatesAndDaylightSavingGap() throws {
        let local = AgendaSyncContent.LocalDate(day: 17083, minute: 90)
        let date = try local.date(in: zone)
        XCTAssertEqual(try AgendaSyncContent.LocalDate.from(date, in: zone, allDay: false), local)
        let allDay = AgendaSyncContent.LocalDate(day: 17083)
        XCTAssertEqual(try AgendaSyncContent.LocalDate.from(allDay.date(in: zone), in: zone, allDay: true), allDay)
        // Sydney skips 02:30 on 2026-10-04.
        let day = Int((DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026, month: 10, day: 4).date!.timeIntervalSince1970 - 315532800) / 86400)
        XCTAssertThrowsError(try AgendaSyncContent.LocalDate(day: day, minute: 150).date(in: TimeZone(identifier: "Australia/Sydney")!))
    }

    func testPairingIdentitySurvivesReselectingAFileAndSeparatesDevices() {
        let device = UUID()
        let original = AgendaSyncPlanner.pairingIdentifier(device: device, path: "C:\\Documents\\Agenda",
            calendar: "local-calendar", timeZone: "Australia/Brisbane")
        XCTAssertEqual(original, AgendaSyncPlanner.pairingIdentifier(device: device, path: " c:\\documents\\agenda ",
            calendar: "local-calendar", timeZone: "Australia/Brisbane"))
        XCTAssertNotEqual(original, AgendaSyncPlanner.pairingIdentifier(device: UUID(), path: "C:\\Documents\\Agenda",
            calendar: "local-calendar", timeZone: "Australia/Brisbane"))
        XCTAssertNotEqual(original, AgendaSyncPlanner.pairingIdentifier(device: device, path: "C:\\Documents\\Agenda",
            calendar: "other-calendar", timeZone: "Australia/Brisbane"))
    }
}
