import Foundation
import CryptoKit

struct VCardImportContact {
    var guid: String
    var fields: [ContactField]

    static func read(_ lines: [CalendarContentLine]) throws -> Self {
        let supported: Set<String> = ["VERSION", "UID", "FN", "N", "TEL", "EMAIL", "ADR", "ORG", "TITLE", "URL", "BDAY", "NOTE", "REV", "PRODID"]
        guard lines.filter({ $0.name == "VERSION" }).count == 1,
              ["3.0", "4.0"].contains(lines.first(where: { $0.name == "VERSION" })?.value ?? "") else {
            throw PsionImportError.unsupported("vCard versions other than UTF-8 3.0 or 4.0")
        }
        var fields: [ContactField] = []
        func add(_ index: Int, _ text: String) throws {
            guard !text.isEmpty else { return }
            _ = try BinaryWriter.text(text)
            guard !text.contains("\0") else { throw PsionImportError.invalid("a contact contains a null character") }
            fields.append(ContactField(index: index, text: text))
        }
        func one(_ name: String) throws -> CalendarContentLine? {
            let found = lines.filter { $0.name == name }
            guard found.count <= 1 else { throw PsionImportError.invalid("duplicate \(name) in a contact") }
            return found.first
        }
        let name = try one("N")
        let formatted = try one("FN")?.text() ?? ""
        if let name {
            let values = try components(name, count: 5)
            for (index, value) in zip([3, 1, 2, 0, 4], values) { try add(index, value) }
            let nativeName = [values[3], values[1], values[2], values[0], values[4]].filter { !$0.isEmpty }.joined(separator: " ")
            if !formatted.isEmpty && formatted != nativeName { try add(34, formatted) }
        } else { try add(1, formatted) }
        for line in lines {
            guard supported.contains(line.name) || line.name.hasPrefix("X-") else {
                throw PsionImportError.unsupported("the \(line.name) contact property")
            }
            guard line.parameters.keys.allSatisfy({ ["TYPE", "PREF", "VALUE", "CHARSET"].contains($0) }),
                  line.parameters["CHARSET"] == nil || line.parameters["CHARSET"]?.uppercased() == "UTF-8" else {
                throw PsionImportError.unsupported("parameters on the \(line.name) contact property")
            }
            let types = Set((line.parameters["TYPE"] ?? "").uppercased().split(separator: ",").map(String.init))
            let work = types.contains("WORK")
            guard !types.contains("HOME") || !work else { throw PsionImportError.unsupported("a field marked both HOME and WORK") }
            switch line.name {
            case "TEL":
                guard types.isSubset(of: ["HOME", "WORK", "CELL", "VOICE", "FAX", "PAGER", "PREF"]),
                      types.intersection(["CELL", "FAX", "PAGER"]).count <= 1 else {
                    throw PsionImportError.unsupported("this telephone field type")
                }
                let index = (work ? 19 : 5) + (types.contains("CELL") ? 0 : types.contains("FAX") ? 2 : types.contains("PAGER") ? 3 : 1)
                var value = try line.text()
                if value.lowercased().hasPrefix("tel:") {
                    value = String(value.dropFirst(4))
                    guard !value.contains(";"), !value.contains("?"), let decoded = value.removingPercentEncoding else {
                        throw PsionImportError.unsupported("telephone URIs with extensions or parameters")
                    }
                    value = decoded
                }
                try add(index, value)
            case "EMAIL":
                guard types.isSubset(of: ["HOME", "WORK", "INTERNET", "PREF"]) else { throw PsionImportError.unsupported("this email field type") }
                try add(work ? 23 : 9, line.text())
            case "ADR":
                guard types.isSubset(of: ["HOME", "WORK", "POSTAL", "PARCEL", "DOM", "INTL", "PREF"]) else { throw PsionImportError.unsupported("this address field type") }
                for (offset, value) in try components(line, count: 7).enumerated() { try add((work ? 25 : 10) + offset, value) }
            case "ORG": try add(17, components(line).joined(separator: "\n"))
            case "TITLE": try add(18, line.text())
            case "URL": try add(24, line.text())
            case "NOTE": try add(33, line.text())
            case "BDAY":
                let compact = line.value.replacingOccurrences(of: "-", with: "")
                guard compact.count == 8, compact.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                    throw PsionImportError.unsupported("birthdays without a complete year, month and day")
                }
                let value = String(compact.prefix(4)) + "-" + String(compact.dropFirst(4).prefix(2)) + "-" + String(compact.suffix(2))
                _ = try birthday(value)
                try add(32, value)
            default: break
            }
        }
        guard !fields.isEmpty else { throw PsionImportError.invalid("a contact has no supported fields") }
        let suppliedUID = try one("UID")?.text()
        if let suppliedUID, suppliedUID.isEmpty { throw PsionImportError.invalid("a contact has an empty UID") }
        let canonicalFields = fields.sorted { $0.index == $1.index ? $0.text < $1.text : $0.index < $1.index }
        let identity = suppliedUID ?? canonicalFields.map { "\($0.index):\($0.text.utf8.count):\($0.text)" }.joined(separator: "\n")
        let guid: String
        if identity.hasPrefix("psion-") { guid = String(identity.dropFirst(6)) }
        else { guid = "rconn-" + SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() }
        guard !guid.isEmpty, (try BinaryWriter.text(guid)).count <= 244 else {
            throw PsionImportError.invalid("the contact identifier exceeds the Psion limit")
        }
        return Self(guid: guid, fields: fields)
    }

    private static func components(_ line: CalendarContentLine, count: Int? = nil) throws -> [String] {
        var raw: [String] = [], value = "", escaped = false
        for character in line.value {
            if character == ";" && !escaped { raw.append(value); value = "" }
            else { value.append(character) }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        raw.append(value)
        if let count, raw.count != count { throw PsionImportError.invalid("\(line.name) must have \(count) components") }
        return try raw.map {
            var property = line; property.value = $0
            return try property.text()
        }
    }

    static func birthday(_ text: String) throws -> UInt64 {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]) else { throw PsionImportError.invalid("an invalid birthday") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.year, from: date) == parts[0], calendar.component(.month, from: date) == parts[1],
              calendar.component(.day, from: date) == parts[2] else { throw PsionImportError.invalid("an invalid birthday") }
        return UInt64((date.timeIntervalSince1970 + 62_168_256_000) * 1_000_000)
    }

    func blob() throws -> [UInt8] {
        var writer = BinaryWriter(); writer.u32(0)
        var directory: [(UInt32, UInt32)] = []
        for field in fields {
            let storage: UInt32 = field.index == 32 ? 0x3000 : 0
            directory.append((UInt32(field.index) << 22 | 0x214 | storage, UInt32(writer.bytes.count)))
            if field.index == 32 {
                let value = try Self.birthday(field.text)
                writer.u32(UInt32(truncatingIfNeeded: value)); writer.u32(UInt32(value >> 32))
            } else {
                writer.u32(UInt32(field.text.utf16.count)); try writer.descriptor(field.text)
            }
        }
        writer.bytes.replaceSubrange(0..<4, with: BinaryWriter.integer(UInt32(writer.bytes.count)))
        writer.u32(UInt32(directory.count))
        for (attributes, offset) in directory { writer.u32(attributes); writer.u32(offset) }
        return writer.bytes
    }
}
