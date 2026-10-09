import Foundation

enum InterchangeText {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    static func encode(_ lines: [String]) -> Data {
        var folded: [String] = []
        for line in lines {
            var part = ""
            // Fold at 75 UTF-8 octets, without splitting a Unicode scalar.
            for scalar in line.unicodeScalars {
                let character = String(scalar)
                if part.utf8.count + character.utf8.count > 75 {
                    folded.append(part)
                    part = " "
                }
                part += character
            }
            folded.append(part)
        }
        return Data((folded.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
