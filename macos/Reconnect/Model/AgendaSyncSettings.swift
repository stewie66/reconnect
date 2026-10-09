import Foundation
import PsionFormats

struct AgendaSyncSettings: Codable, Equatable {
    var pairingID = UUID()
    var enabled = false
    var agendaPath = ""
    var calendarID = ""
    var timeZoneID = TimeZone.current.identifier
    var direction: AgendaSyncPlanner.Direction = .agendaToMac
    var conflicts: AgendaSyncPlanner.ConflictPolicy = .pause
    var automatic = false
    var closeAgenda = true

    var isConfigured: Bool {
        enabled && !agendaPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !calendarID.isEmpty
    }
}

extension AgendaSyncPlanner.Direction {
    var title: String {
        switch self {
        case .agendaToMac: return "Agenda → Mac Calendar"
        case .macToAgenda: return "Mac Calendar → Agenda"
        case .bidirectional: return "Both directions"
        }
    }
}

extension AgendaSyncPlanner.ConflictPolicy {
    var title: String {
        switch self {
        case .pause: return "Pause and report the conflict"
        case .preferAgenda: return "Prefer Agenda"
        case .preferMac: return "Prefer Mac Calendar"
        }
    }
}
