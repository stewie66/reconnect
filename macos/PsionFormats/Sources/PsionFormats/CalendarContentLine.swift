import Foundation

// RFC 5545 unfolding is byte-based: a producer can fold inside a UTF-8 scalar.
struct CalendarContentLine {
    var name: String
    var parameters: [String: String]
    var value: String

    static func read(_ data: Data) throws -> [Self] {
        guard data.count <= 16 * 1024 * 1024 else { throw PsionImportError.invalid("the file exceeds 16 MiB") }
        let bytes = Array(data)
        var unfolded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 {
                if index + 2 < bytes.count && [9, 32].contains(bytes[index + 2]) { index += 3; continue }
                unfolded.append(10); index += 2; continue
            }
            if bytes[index] == 10 && index + 1 < bytes.count && [9, 32].contains(bytes[index + 1]) {
                index += 2; continue
            }
            unfolded.append(bytes[index]); index += 1
        }
        guard var text = String(bytes: unfolded, encoding: .utf8), !text.contains("\r"), !text.contains("\0") else {
            throw PsionImportError.invalid("use a UTF-8 iCalendar or vCard file")
        }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        var result: [Self] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.utf8.count <= 256 * 1024 else { throw PsionImportError.invalid("a content line is too long") }
            var quoted = false
            var delimiter: String.Index?
            for position in line.indices {
                if line[position] == "\"" { quoted.toggle() }
                if line[position] == ":" && !quoted { delimiter = position; break }
            }
            guard let delimiter, !quoted else { throw PsionImportError.invalid("a content line has no value") }
            let head = line[..<delimiter]
            var parts: [String] = [], part = ""
            quoted = false
            for character in head {
                if character == "\"" { quoted.toggle() }
                if character == ";" && !quoted { parts.append(part); part = "" }
                else { part.append(character) }
            }
            guard !quoted else { throw PsionImportError.invalid("an unterminated parameter quote") }
            parts.append(part)
            let name = parts.removeFirst().uppercased()
            guard !name.isEmpty && name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else {
                throw PsionImportError.invalid("an invalid property name")
            }
            var parameters: [String: String] = [:]
            for part in parts {
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !pair[0].isEmpty, parameters[String(pair[0]).uppercased()] == nil else {
                    throw PsionImportError.invalid("an invalid or duplicate parameter")
                }
                var value = String(pair[1])
                if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
                parameters[String(pair[0]).uppercased()] = value
            }
            result.append(Self(name: name, parameters: parameters, value: String(line[line.index(after: delimiter)...])))
        }
        return result
    }

    func text() throws -> String {
        var output = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "n", "N": output.append("\n")
                case "\\", ";", ",": output.append(character)
                default: throw PsionImportError.invalid("an invalid text escape in \(name)")
                }
                escaped = false
            } else if character == "\\" { escaped = true }
            else { output.append(character) }
        }
        guard !escaped else { throw PsionImportError.invalid("an incomplete text escape in \(name)") }
        return output
    }
}
