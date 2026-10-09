import Foundation
import CryptoKit

public enum AgendaSyncPlanner {
    public static func pairingIdentifier(device: UUID, path: String, calendar: String, timeZone: String) -> UUID {
        let components = [device.uuidString, path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), calendar, timeZone]
        // Length-delimited JSON avoids path/account delimiter collisions.
        let digest = SHA256.hash(data: try! JSONEncoder().encode(components)).prefix(16)
        let bytes = Array(digest)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public enum Direction: String, Codable, CaseIterable, Sendable {
        case agendaToMac, macToAgenda, bidirectional
    }

    public enum ConflictPolicy: String, Codable, CaseIterable, Sendable {
        case pause, preferAgenda, preferMac
    }

    /// A missing value means deletion only after a complete, successful read of that side.
    public static func resolve(agenda: AgendaSyncContent?, mac: AgendaSyncContent?,
                               baseline: AgendaSyncContent?, hasBaseline: Bool,
                               direction: Direction, conflicts: ConflictPolicy) throws -> AgendaSyncContent? {
        switch direction {
        case .agendaToMac: return agenda
        case .macToAgenda: return mac
        case .bidirectional:
            if agenda == mac { return agenda }
            if hasBaseline {
                if agenda == baseline { return mac }
                if mac == baseline { return agenda }
            } else {
                if agenda == nil { return mac }
                if mac == nil { return agenda }
            }
            switch conflicts {
            case .preferAgenda: return agenda
            case .preferMac: return mac
            case .pause: throw PsionImportError.invalid("both sides changed the same event; choose a conflict policy or resolve the edit before syncing")
            }
        }
    }
}
