import XCTest
@testable import PsionFormats

final class AgendaSyncPairingRegistryTests: XCTestCase {
    func testExistingPairingAndOccurrenceIdentitySurviveTravelAndRestart() throws {
        let device = UUID(), legacyID = UUID()
        var registry = AgendaSyncPairingRegistry()
        let original = registry.register(device: device, path: "C:\\Documents\\Agenda", calendar: "calendar",
                                          timeZone: "Australia/Brisbane", existingID: legacyID)
        XCTAssertEqual(original.id, legacyID)
        registry = try JSONDecoder().decode(AgendaSyncPairingRegistry.self, from: JSONEncoder().encode(registry))
        let changed = registry.register(device: device, path: " c:\\documents\\agenda ", calendar: "calendar", timeZone: "GMT")
        XCTAssertEqual(changed, original)
        XCTAssertEqual(changed.identityTimeZoneID, "Australia/Brisbane")
        let instant = Date(timeIntervalSince1970: 1767655800)
        let before = try AgendaSyncOccurrence(calendarItemID: "series", originalDate: .from(instant,
            in: TimeZone(identifier: original.identityTimeZoneID)!, allDay: false)).identifier()
        let after = try AgendaSyncOccurrence(calendarItemID: "series", originalDate: .from(instant,
            in: TimeZone(identifier: changed.identityTimeZoneID)!, allDay: false)).identifier()
        XCTAssertEqual(before, after)
    }

    func testReselectingPairsRetainsMappingsAndSeparatesDevicesAndCalendars() {
        let device = UUID()
        var registry = AgendaSyncPairingRegistry()
        let original = registry.register(device: device, path: "C:\\Agenda", calendar: "first", timeZone: "Australia/Brisbane")
        let second = registry.register(device: device, path: "C:\\Agenda", calendar: "second", timeZone: "GMT")
        let otherDevice = registry.register(device: UUID(), path: "C:\\Agenda", calendar: "first", timeZone: "Australia/Brisbane")
        XCTAssertNotEqual(original.id, second.id)
        XCTAssertNotEqual(original.id, otherDevice.id)
        XCTAssertEqual(registry.register(device: device, path: "C:\\Agenda", calendar: "first", timeZone: "GMT"), original)
    }
}
