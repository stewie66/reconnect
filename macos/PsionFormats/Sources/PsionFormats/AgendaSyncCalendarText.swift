import Foundation

public enum AgendaSyncCalendarText {
    /// Keeps representable characters intact; transliterates unsupported runs and marks any remainder.
    public static func readable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result = "", pending = ""
        func representable(_ text: String) -> Bool {
            guard let bytes = text.data(using: .windowsCP1252, allowLossyConversion: false) else { return false }
            return String(data: bytes, encoding: .windowsCP1252) == text
        }
        func flush() {
            guard !pending.isEmpty else { return }
            var converted = pending
            for transform: StringTransform in [.fullwidthToHalfwidth, .toLatin, .stripDiacritics] {
                converted = converted.applyingTransform(transform, reverse: false) ?? converted
            }
            for character in converted {
                let value = String(character)
                if representable(value) { result += value }
                else if !character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .format }) { result += "?" }
            }
            pending = ""
        }
        for character in normalized {
            let value = String(character)
            if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .format }) { continue }
            if character.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 }) {
                flush()
                result += " "
            } else if representable(value) {
                flush()
                result += value
            } else { pending += value }
        }
        flush()
        return result
    }
}
