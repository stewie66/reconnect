import XCTest
import Contacts
@testable import PsionFormats

final class ImportTests: XCTestCase {
    let zone = TimeZone(identifier: "Australia/Brisbane")!
    let timestamp = Date(timeIntervalSince1970: 1_791_500_000)

    func calendar(_ body: String) -> Data {
        Data(("BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:sample-event\nSUMMARY:Sample Meeting\n" + body + "\nEND:VEVENT\nEND:VCALENDAR\n").utf8)
    }
    var meeting: Data { calendar("DTSTART:20261009T090000\nDTEND:20261009T100000\nLOCATION:Library") }
    var card: Data { Data("BEGIN:VCARD\nVERSION:3.0\nUID:sample-contact\nFN:Alex Example\nN:Example;Alex;;;\nTEL;TYPE=HOME,CELL:+61 400000000\nEMAIL;TYPE=HOME:alex@example.test\nBDAY:2000-01-01\nNOTE:Line one\\nLine two\nEND:VCARD\n".utf8) }

    func testAutomaticFileCreationWithoutTemplates() throws {
        let agenda = try AgendaImporter.create(meeting, timeZone: zone, timestamp: timestamp)
        XCTAssertEqual(agenda.addedCount, 1)
        let events = String(decoding: try AgendaConverter.convert(agenda.data), as: UTF8.self)
        XCTAssertTrue(events.contains("DTSTART:20261009T090000"))
        XCTAssertTrue(events.contains("LOCATION:Library"))
        XCTAssertEqual(try AgendaImporter.convert(meeting, using: agenda.data, mode: .merge, timeZone: zone).skippedCount, 1)
        let contacts = try ContactsImporter.create(card, timestamp: timestamp)
        XCTAssertEqual(contacts.addedCount, 1)
        let parsed = try CNContactVCardSerialization.contacts(with: ContactsConverter.convert(contacts.data))
        XCTAssertEqual(parsed.first?.givenName, "Alex")
        XCTAssertEqual(parsed.first?.birthday?.year, 2000)
        XCTAssertEqual(try ContactsImporter.convert(card, using: contacts.data, mode: .merge).skippedCount, 1)
        if let export = ProcessInfo.processInfo.environment["PSION_IMPORT_EXPORT_DIRECTORY"] {
            let directory = URL(fileURLWithPath: export)
            try agenda.data.write(to: directory.appendingPathComponent("Reconnect-auto-agenda.agn"), options: .atomic)
            try contacts.data.write(to: directory.appendingPathComponent("Reconnect-auto-contacts.cdb"), options: .atomic)
        }
    }

    func testGeneratedEmptyStoresHaveDefaultsAndFreshMetadata() throws {
        let agendaData = try EmptyAgendaStore.create(timeZone: zone, timestamp: timestamp)
        let agenda = try PermanentStore(agendaData)
        XCTAssertEqual(agenda.root, 23)
        XCTAssertEqual(agenda.streams.count, 23)
        XCTAssertFalse(String(decoding: try AgendaConverter.convert(agendaData), as: UTF8.self).contains("BEGIN:VEVENT"))
        var lists = BinaryReader(try agenda.get(1))
        XCTAssertEqual(try lists.cardinal(), 3)
        for (uniqueID, name) in [(UInt32(2), "To-do list"), (3, "Notes"), (4, "Personal")] {
            let streamID = try lists.u32()
            var list = BinaryReader(try agenda.get(streamID))
            XCTAssertEqual(try list.u8(), 0)
            XCTAssertEqual(try list.u32(), streamID)
            XCTAssertEqual(try list.u32(), uniqueID)
            XCTAssertEqual(try list.descriptor(), name)
        }
        let contactsData = try EmptyContactsStore.create(timestamp: timestamp)
        let contacts = try PermanentStore(contactsData)
        XCTAssertEqual(contacts.root, 2)
        XCTAssertEqual(contacts.streams.count, 11)
        XCTAssertTrue(String(decoding: try ContactsConverter.convert(contactsData), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        func templateRow(_ data: Data) throws -> ContactRow {
            let store = try PermanentStore(data)
            var cluster = BinaryReader(try store.get(3), position: 6)
            return try ContactRow.read(cluster.take(cluster.cardinal()), store: store)
        }
        let first = try templateRow(contactsData)
        let second = try templateRow(EmptyContactsStore.create(timestamp: timestamp))
        XCTAssertEqual(first.type, 0x1000130b)
        XCTAssertNotEqual(first.guid, second.guid)
        XCTAssertEqual(first.blob, second.blob)
        var preferences = BinaryReader(try contacts.get(8), position: 7)
        XCTAssertEqual(try preferences.u8(), 7)
        XCTAssertEqual(try preferences.u32(), 0)
        XCTAssertEqual(try preferences.u32(), 3)
        let time = UInt64(try preferences.u32()) | UInt64(try preferences.u32()) << 32
        XCTAssertEqual(time, UInt64((timestamp.timeIntervalSince1970 + 62_168_256_000) * 1_000_000))
    }

    func testAgendaCreateMergeAndDuplicateUID() throws {
        let base = SyntheticStore.emptyAgenda()
        let result = try AgendaImporter.convert(meeting, using: base, mode: .createNew, timeZone: zone, timestamp: timestamp)
        XCTAssertEqual(result.addedCount, 1)
        let output = String(decoding: try AgendaConverter.convert(result.data), as: UTF8.self)
        XCTAssertTrue(output.contains("DTSTART:20261009T090000"))
        XCTAssertTrue(output.contains("LOCATION:Library"))
        let repeatImport = try AgendaImporter.convert(meeting, using: result.data, mode: .merge, timeZone: zone, timestamp: timestamp)
        XCTAssertEqual(repeatImport.addedCount, 0)
        XCTAssertEqual(repeatImport.skippedCount, 1)
        XCTAssertEqual(repeatImport.data, result.data)
        let exported = try AgendaConverter.convert(result.data)
        XCTAssertEqual(try AgendaImporter.convert(exported, using: result.data, mode: .merge, timeZone: zone).skippedCount, 1)
        XCTAssertThrowsError(try AgendaImporter.convert(meeting, using: result.data, mode: .createNew, timeZone: zone))
        let old = try PermanentStore(base), new = try PermanentStore(result.data)
        for (id, bytes) in old.streams where ![3, 6, 9].contains(id) { XCTAssertEqual(new.streams[id], bytes) }
    }

    func testAllDayRepeatsExceptionsAndAlarm() throws {
        let input = calendar("DTSTART;VALUE=DATE:20261009\nDTEND;VALUE=DATE:20261011\nRRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20261031\nEXDATE;VALUE=DATE:20261013\nBEGIN:VALARM\nACTION:DISPLAY\nDESCRIPTION:Reminder\nTRIGGER:-PT15M\nEND:VALARM")
        let result = try AgendaImporter.convert(input, using: SyntheticStore.emptyAgenda(), mode: .createNew, timeZone: zone, timestamp: timestamp)
        let output = String(decoding: try AgendaConverter.convert(result.data), as: UTF8.self)
        XCTAssertTrue(output.contains("DTEND;VALUE=DATE:20261011"))
        XCTAssertTrue(output.contains("RRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20261031"))
        XCTAssertTrue(output.contains("EXDATE;VALUE=DATE:20261013"))
        XCTAssertTrue(output.contains("TRIGGER:-PT15M"))
        XCTAssertTrue(output.contains("X-PSION-FLAGS:4126"))
        let weekly = calendar("DTSTART:20261009T090000\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR;WKST=SU")
        let imported = try AgendaImporter.convert(weekly, using: SyntheticStore.emptyAgenda(), mode: .createNew, timeZone: zone)
        XCTAssertTrue(String(decoding: try AgendaConverter.convert(imported.data), as: UTF8.self).contains("BYDAY=MO,FR;WKST=SU"))
    }

    func testTimeZonesAndMalformedInputs() throws {
        let input = calendar("DTSTART:20261008T230000Z\nDTEND:20261009T000000Z")
        let result = try AgendaImporter.convert(input, using: SyntheticStore.emptyAgenda(), mode: .createNew, timeZone: zone)
        XCTAssertTrue(String(decoding: try AgendaConverter.convert(result.data), as: UTF8.self).contains("DTSTART:20261009T090000"))
        for body in ["DTSTART:2026T009T090000", "DTSTART:20260230T090000", "DTSTART:20261009T090001",
                     "DTSTART:20261009T090000\nATTENDEE:mailto:alex@example.test",
                     "DTSTART:20261009T090000\nRRULE:FREQ=MONTHLY",
                     "DTSTART:20261009T090000\nRRULE:FREQ=DAILY;COUNT=5",
                     "DTSTART:20261009T090000\nDTEND:20261009T080000"] {
            XCTAssertThrowsError(try AgendaImporter.convert(calendar(body), using: SyntheticStore.emptyAgenda(), mode: .createNew, timeZone: zone))
        }
        XCTAssertThrowsError(try ContactsImporter.convert(Data("BEGIN:VCARD\nVERSION:3.0\nFN:Example\nPHOTO:binary\nEND:VCARD".utf8), using: SyntheticStore.contacts(includeCard: false, includeIndex: true), mode: .createNew))
    }

    func testContactsCreateMergeAndAppleParser() throws {
        let base = SyntheticStore.contacts(includeCard: false, includeIndex: true)
        let result = try ContactsImporter.convert(card, using: base, mode: .createNew, timestamp: timestamp)
        XCTAssertEqual(result.addedCount, 1)
        let contacts = try CNContactVCardSerialization.contacts(with: ContactsConverter.convert(result.data))
        XCTAssertEqual(contacts.first?.givenName, "Alex")
        XCTAssertEqual(contacts.first?.birthday?.year, 2000)
        let duplicate = try ContactsImporter.convert(card, using: result.data, mode: .merge, timestamp: timestamp)
        XCTAssertEqual(duplicate.skippedCount, 1)
        XCTAssertEqual(duplicate.data, result.data)
        let exported = try ContactsConverter.convert(result.data)
        XCTAssertEqual(try ContactsImporter.convert(exported, using: result.data, mode: .merge).skippedCount, 1)
        XCTAssertThrowsError(try ContactsImporter.convert(card, using: result.data, mode: .createNew))
    }

    func testLargeContactsIndexAndClusters() throws {
        var input = Data()
        for index in 0..<4200 {
            input.append(Data("BEGIN:VCARD\nVERSION:3.0\nUID:contact-\(index)\nFN:Contact \(index)\nNOTE:\(String(repeating: "a", count: 300))\nEND:VCARD\n".utf8))
        }
        let result = try ContactsImporter.create(input)
        XCTAssertEqual(result.addedCount, 4200)
        XCTAssertEqual(try CNContactVCardSerialization.contacts(with: ContactsConverter.convert(result.data)).count, 4200)
        let repeated = try ContactsImporter.convert(input, using: result.data, mode: .merge)
        XCTAssertEqual(repeated.skippedCount, 4200)
    }

    func testContactIdentityWithoutUIDIncludesFieldTypes() throws {
        let home = "BEGIN:VCARD\nVERSION:4.0\nFN:Example\nitem1.TEL;TYPE=HOME:1234\nEND:VCARD\n"
        let work = home.replacingOccurrences(of: "TYPE=HOME", with: "TYPE=WORK")
        let result = try ContactsImporter.convert(Data((home + work + home).utf8), using: SyntheticStore.contacts(includeCard: false, includeIndex: true), mode: .createNew)
        XCTAssertEqual(result.addedCount, 2)
        XCTAssertEqual(result.skippedCount, 1)
        let output = String(decoding: try ContactsConverter.convert(result.data), as: UTF8.self)
        XCTAssertTrue(output.contains("TEL;TYPE=HOME,VOICE:1234"))
        XCTAssertTrue(output.contains("TEL;TYPE=WORK,VOICE:1234"))
    }

    func testPermanentStoreFrameBoundaries() throws {
        var store = try PermanentStore(SyntheticStore.emptyAgenda())
        let sizes = [16381, 16382, 16383, 16384, 16385, 32768, 32769, 0, 1]
        for size in sizes { _ = try store.add(Array(repeating: 65, count: size)) }
        let decoded = try PermanentStore(store.encoded())
        XCTAssertEqual(decoded.streams, store.streams)
        XCTAssertEqual(decoded.uids, store.uids)
        XCTAssertEqual(decoded.root, store.root)
    }

    func testPrivateNativeImportFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["PSION_IMPORT_FIXTURE_DIRECTORY"] else { throw XCTSkip("Private native templates not supplied") }
        let directory = URL(fileURLWithPath: path)
        func fixture(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
        let defaultAgenda = try PermanentStore(EmptyAgendaStore.create(timeZone: zone, timestamp: timestamp))
        let nativeAgenda = try PermanentStore(fixture("emptyagenda"))
        for id: UInt32 in [1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14, 15, 16, 17, 18, 20, 21, 22, 23] {
            XCTAssertEqual(try defaultAgenda.get(id), try nativeAgenda.get(id), "Default Agenda stream \(id)")
        }
        let defaultContacts = try PermanentStore(EmptyContactsStore.create(timestamp: timestamp))
        let nativeContacts = try PermanentStore(fixture("NoContacts.cdb"))
        for id: UInt32 in [1, 2, 4, 5, 6, 7, 9, 10, 11] {
            XCTAssertEqual(try defaultContacts.get(id), try nativeContacts.get(id), "Default Contacts stream \(id)")
        }
        let agenda = try AgendaImporter.convert(meeting, using: fixture("emptyagenda"), mode: .createNew, timeZone: zone, timestamp: timestamp)
        XCTAssertEqual(agenda.addedCount, 1)
        let single = try AgendaImporter.convert(meeting, using: fixture("singleagenda"), mode: .merge, timeZone: zone, timestamp: timestamp)
        XCTAssertEqual(String(decoding: try AgendaConverter.convert(single.data), as: UTF8.self).components(separatedBy: "BEGIN:VEVENT").count - 1, 2)
        XCTAssertThrowsError(try AgendaImporter.convert(meeting, using: fixture("singleagenda"), mode: .createNew))
        let contacts = try ContactsImporter.convert(card, using: fixture("NoContacts.cdb"), mode: .createNew, timestamp: timestamp)
        XCTAssertEqual(try CNContactVCardSerialization.contacts(with: ContactsConverter.convert(contacts.data)).count, 1)
        let merged = try ContactsImporter.convert(card, using: fixture("1Contacts 2.cdb"), mode: .merge, timestamp: timestamp)
        XCTAssertEqual(try CNContactVCardSerialization.contacts(with: ContactsConverter.convert(merged.data)).count, 2)
        let oldStore = try PermanentStore(fixture("1Contacts 2.cdb")), mergedStore = try PermanentStore(merged.data)
        for (id, bytes) in oldStore.streams where ![3, 4, 5].contains(id) { XCTAssertEqual(mergedStore.streams[id], bytes) }
        XCTAssertEqual(try mergedStore.get(3).dropFirst(4), try oldStore.get(3).dropFirst(4))
        let exportedSingle = try AgendaConverter.convert(fixture("singleagenda"))
        let skippedSingle = try AgendaImporter.convert(exportedSingle, using: fixture("singleagenda"), mode: .merge, timeZone: zone)
        XCTAssertEqual(skippedSingle.skippedCount, 1)
        XCTAssertEqual(skippedSingle.data, try fixture("singleagenda"))
        if let oldDirectory = ProcessInfo.processInfo.environment["PSION_FIXTURE_DIRECTORY"] {
            let populated = URL(fileURLWithPath: oldDirectory)
            let oldAgenda = try Data(contentsOf: populated.appendingPathComponent("Agenda.agn"))
            let oldContacts = try Data(contentsOf: populated.appendingPathComponent("Contacts.cdb"))
            let mergedAgenda = try AgendaImporter.convert(meeting, using: oldAgenda, mode: .merge, timeZone: zone, timestamp: timestamp)
            XCTAssertEqual(String(decoding: try AgendaConverter.convert(mergedAgenda.data), as: UTF8.self).components(separatedBy: "BEGIN:VEVENT").count - 1, 237)
            let mergedContacts = try ContactsImporter.convert(card, using: oldContacts, mode: .merge, timestamp: timestamp)
            XCTAssertEqual(try CNContactVCardSerialization.contacts(with: ContactsConverter.convert(mergedContacts.data)).count, 527)
        }
        if let export = ProcessInfo.processInfo.environment["PSION_IMPORT_EXPORT_DIRECTORY"] {
            let output = URL(fileURLWithPath: export)
            try agenda.data.write(to: output.appendingPathComponent("Reconnect-test-agenda.agn"), options: .atomic)
            try contacts.data.write(to: output.appendingPathComponent("Reconnect-test-contacts.cdb"), options: .atomic)
            try meeting.write(to: output.appendingPathComponent("Reconnect-test-agenda.ics"), options: .atomic)
            try card.write(to: output.appendingPathComponent("Reconnect-test-contacts.vcf"), options: .atomic)
        }
    }
}
