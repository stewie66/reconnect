import XCTest
import Contacts
@testable import PsionFormats

final class PsionFormatsTests: XCTestCase {
    func testSyntheticMeetingAndUnsupportedProfiles() throws {
        let output = String(decoding: try AgendaConverter.convert(SyntheticStore.agenda()), as: UTF8.self)
        XCTAssertTrue(output.contains("SUMMARY:Project Meeting\r\n"))
        XCTAssertTrue(output.contains("RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=TU"))
        XCTAssertTrue(output.contains("T140000\r\nDTEND:"))
        XCTAssertTrue(output.contains("TRIGGER:-PT15M"))
        XCTAssertThrowsError(try AgendaConverter.convert(SyntheticStore.agenda(recurrence: 4)))
        XCTAssertThrowsError(try AgendaConverter.convert(SyntheticStore.agenda(version: 85)))
        let deleted = String(decoding: try AgendaConverter.convert(SyntheticStore.agenda(deleted: true)), as: UTF8.self)
        XCTAssertFalse(deleted.contains("BEGIN:VEVENT"))
    }

    func testSyntheticContactsWithAppleVCardParser() throws {
        let output = try ContactsConverter.convert(SyntheticStore.contacts())
        let contacts = try CNContactVCardSerialization.contacts(with: output)
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts.first?.givenName, "Alex")
        XCTAssertEqual(contacts.first?.familyName, "Café")
        XCTAssertEqual(contacts.first?.phoneNumbers.first?.value.stringValue, "+61 400000000")
        XCTAssertEqual(contacts.first?.emailAddresses.first?.value as String?, "alex@example.test")
        XCTAssertEqual(contacts.first?.postalAddresses.first?.value.street, "1 Sample St")
        XCTAssertEqual(contacts.first?.birthday?.year, 2000)
        XCTAssertEqual(contacts.first?.birthday?.month, 1)
        XCTAssertEqual(contacts.first?.birthday?.day, 1)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("NOTE:Note\\; comma\\, slash\\\\\\nNext line"))
    }
    func testCardinalityBounds() throws {
        var small = BinaryReader([0xfe])
        XCTAssertEqual(try small.cardinal(), 127)
        var invalid = BinaryReader([7, 0, 0, 0])
        XCTAssertThrowsError(try invalid.cardinal())
        var truncated = BinaryReader([1])
        XCTAssertThrowsError(try truncated.cardinal())
    }

    func testEscapingAndUTF8Folding() throws {
        let text = "Meeting; café, room\\one\n" + String(repeating: "界", count: 40)
        let escaped = InterchangeText.escape(text)
        XCTAssertTrue(escaped.hasPrefix("Meeting\\; café\\, room\\\\one\\n"))
        let encoded = InterchangeText.encode(["SUMMARY:" + escaped])
        let lines = String(decoding: encoded, as: UTF8.self).components(separatedBy: "\r\n")
        XCTAssertTrue(lines.dropLast().allSatisfy { $0.utf8.count <= 75 })
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\r\n ", with: "").trimmingCharacters(in: .newlines),
                       "SUMMARY:" + escaped)
    }

    func testRejectsInvalidStore() {
        XCTAssertThrowsError(try AgendaConverter.convert(Data()))
        XCTAssertThrowsError(try AgendaConverter.convert(Data(repeating: 0, count: 80)))
        XCTAssertThrowsError(try ContactsConverter.convert(Data()))
    }

    func testPrivateContactsFixture() throws {
        guard let directory = ProcessInfo.processInfo.environment["PSION_FIXTURE_DIRECTORY"] else { throw XCTSkip("Private fixture not supplied") }
        let data = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("Contacts.cdb"))
        let output = String(decoding: try ContactsConverter.convert(data), as: UTF8.self)
        XCTAssertEqual(try CNContactVCardSerialization.contacts(with: Data(output.utf8)).count, 526)
        XCTAssertEqual(output.components(separatedBy: "BEGIN:VCARD").count - 1, 526)
        XCTAssertEqual(output.components(separatedBy: "\r\nFN:").count - 1, 526)
        XCTAssertEqual(output.components(separatedBy: "\r\nN:").count - 1, 526)
        XCTAssertTrue(output.contains("TEL;TYPE=HOME,CELL:"))
        XCTAssertTrue(output.contains("EMAIL;TYPE=HOME,INTERNET:"))
        XCTAssertTrue(output.contains("ADR;TYPE=HOME:"))
        XCTAssertTrue(output.contains("BDAY:"))
        XCTAssertThrowsError(try ContactsConverter.convert(data.dropLast()))
        XCTAssertThrowsError(try AgendaConverter.convert(data))
        XCTAssertTrue(output.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        if let exportDirectory = ProcessInfo.processInfo.environment["PSION_EXPORT_DIRECTORY"] {
            try Data(output.utf8).write(to: URL(fileURLWithPath: exportDirectory).appendingPathComponent("Contacts.vcf"), options: .atomic)
        }
    }

    // Private reference data stays outside the repository. Set this variable to run fixture checks.
    func testPrivateAgendaFixture() throws {
        guard let directory = ProcessInfo.processInfo.environment["PSION_FIXTURE_DIRECTORY"] else { throw XCTSkip("Private fixture not supplied") }
        let data = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("Agenda.agn"))
        let output = String(decoding: try AgendaConverter.convert(data), as: UTF8.self)
        XCTAssertEqual(output.components(separatedBy: "BEGIN:VEVENT").count - 1, 236)
        XCTAssertEqual(output.components(separatedBy: "BEGIN:VTODO").count - 1, 3)
        XCTAssertEqual(output.components(separatedBy: "BEGIN:VALARM").count - 1, 5)
        XCTAssertTrue(output.contains("EXDATE:20251105T050000,20251126T050000"))
        XCTAssertThrowsError(try AgendaConverter.convert(data.dropLast()))
        var damaged = data
        damaged[12] ^= 1
        XCTAssertThrowsError(try AgendaConverter.convert(damaged))
        if let exportDirectory = ProcessInfo.processInfo.environment["PSION_EXPORT_DIRECTORY"] {
            try Data(output.utf8).write(to: URL(fileURLWithPath: exportDirectory).appendingPathComponent("Agenda.ics"), options: .atomic)
        }
    }
}
