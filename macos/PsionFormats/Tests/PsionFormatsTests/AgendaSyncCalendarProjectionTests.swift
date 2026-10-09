import XCTest
@testable import PsionFormats

final class AgendaSyncCalendarProjectionTests: XCTestCase {
    private var content: AgendaSyncContent {
        .init(text: "Meeting\nDiscuss the project", location: "Office", start: .init(day: 17000, minute: 540),
              end: .init(day: 17000, minute: 600))
    }
    private var start: Date { Date(timeIntervalSince1970: 1_500_000_000) }

    func testInvitationCopiesCoreDetailsAndReportsSchedulingMetadata() {
        let result = AgendaSyncCalendarProjection.project(content, hasInvitationDetails: true,
                                                          alarms: [.relative(seconds: -900)], eventStart: start)
        var expected = content
        expected.alarmMinutes = -15
        XCTAssertEqual(result.content, expected)
        XCTAssertEqual(result.notices, [.invitationDetails])
    }

    func testMultipleAlarmsKeepEarliestSupportedTriggerRegardlessOfOrder() {
        let alarms: [AgendaSyncCalendarProjection.Alarm] = [.relative(seconds: -300), .relative(seconds: 0),
                                                           .relative(seconds: -3600)]
        for ordered in [alarms, Array(alarms.reversed())] {
            let result = AgendaSyncCalendarProjection.project(content, hasInvitationDetails: false,
                                                              alarms: ordered, eventStart: start)
            XCTAssertEqual(result.content.alarmMinutes, -60)
            XCTAssertEqual(result.notices, [.extraAlarms])
        }
    }

    func testUnsupportedAlarmsDoNotPreventTheAppointmentImport() {
        let alarms: [AgendaSyncCalendarProjection.Alarm] = [.unsupported, .relative(seconds: -90),
                                                           .relative(seconds: .nan), .relative(seconds: .infinity),
                                                           .relative(seconds: 1441 * 60)]
        let result = AgendaSyncCalendarProjection.project(content, hasInvitationDetails: false,
                                                          alarms: alarms, eventStart: start)
        XCTAssertEqual(result.content, content)
        XCTAssertEqual(result.notices, [.extraAlarms, .unsupportedAlarms])
    }

    func testAValidAlarmIsKeptAlongsideUnsupportedAlarms() {
        let result = AgendaSyncCalendarProjection.project(content, hasInvitationDetails: false,
            alarms: [.unsupported, .relative(seconds: -900)], eventStart: start)
        XCTAssertEqual(result.content.alarmMinutes, -15)
        XCTAssertEqual(result.notices, [.extraAlarms, .unsupportedAlarms])
    }

    func testDatedAlarmConvertsOnlyForNonRepeatingAppointments() {
        let alarm = AgendaSyncCalendarProjection.Alarm.absolute(start.addingTimeInterval(-1800))
        let single = AgendaSyncCalendarProjection.project(content, hasInvitationDetails: false,
                                                          alarms: [alarm], eventStart: start)
        XCTAssertEqual(single.content.alarmMinutes, -30)
        XCTAssertEqual(single.notices, [.convertedAbsoluteAlarm])
        var recurring = content
        recurring.repeatRule = .init(frequency: .weekly, weekdays: [5])
        let series = AgendaSyncCalendarProjection.project(recurring, hasInvitationDetails: false,
                                                          alarms: [alarm], eventStart: start)
        XCTAssertEqual(series.content, recurring)
        XCTAssertEqual(series.notices, [.unsupportedAlarms])
    }

    func testMatchingRelativeAlarmAvoidsAnUnnecessaryDatedConversion() {
        let alarms: [AgendaSyncCalendarProjection.Alarm] = [.absolute(start.addingTimeInterval(-900)),
                                                           .relative(seconds: -900)]
        let result = AgendaSyncCalendarProjection.project(content, hasInvitationDetails: false,
                                                          alarms: alarms, eventStart: start)
        XCTAssertEqual(result.content.alarmMinutes, -15)
        XCTAssertEqual(result.notices, [.extraAlarms])
    }

    func testNativeAlarmRangeAndEmptyAlarmList() {
        let minimum = Int(1440) - Int(UInt32.max)
        let result = AgendaSyncCalendarProjection.project(content, hasInvitationDetails: false,
            alarms: [.relative(seconds: Double(minimum - 1) * 60), .relative(seconds: Double(minimum) * 60)], eventStart: start)
        XCTAssertEqual(result.content.alarmMinutes, minimum)
        XCTAssertTrue(result.notices.contains(.unsupportedAlarms))
        var old = content
        old.alarmMinutes = -15
        let cleared = AgendaSyncCalendarProjection.project(old, hasInvitationDetails: false, alarms: [], eventStart: start)
        XCTAssertNil(cleared.content.alarmMinutes)
        XCTAssertTrue(cleared.notices.isEmpty)
    }

    func testProjectedMeetingRoundTripsAndUpdatesAnExistingAgendaEntry() throws {
        let original = AgendaSyncCalendarProjection.project(content, hasInvitationDetails: true,
            alarms: [.relative(seconds: -900), .relative(seconds: -300)], eventStart: start)
        var event = AgendaSyncEvent(id: "global:0123456789abcdef0123456789abcdef", content: original.content)
        let zone = TimeZone(identifier: "Australia/Brisbane")!
        let first = try AgendaSyncDocument(SyntheticStore.emptyAgenda()).applying(upserts: [event], deleting: [], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(first).events, [event])
        let changed = AgendaSyncCalendarProjection.project(content, hasInvitationDetails: true,
            alarms: [.unsupported, .absolute(start.addingTimeInterval(-1800))], eventStart: start)
        event.content = changed.content
        let updated = try AgendaSyncDocument(first).applying(upserts: [event], deleting: [], timeZone: zone)
        XCTAssertEqual(try AgendaSyncDocument(updated).events, [event])
        XCTAssertEqual(try AgendaSyncDocument(updated).events.first?.content.alarmMinutes, -30)
    }
}
