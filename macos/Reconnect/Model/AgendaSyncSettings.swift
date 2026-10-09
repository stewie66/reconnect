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
    var pairings = AgendaSyncPairingRegistry()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case pairingID, enabled, agendaPath, calendarID, timeZoneID, direction, conflicts, automatic, closeAgenda, pairings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pairingID = try values.decode(UUID.self, forKey: .pairingID)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        agendaPath = try values.decode(String.self, forKey: .agendaPath)
        calendarID = try values.decode(String.self, forKey: .calendarID)
        timeZoneID = try values.decode(String.self, forKey: .timeZoneID)
        direction = try values.decode(AgendaSyncPlanner.Direction.self, forKey: .direction)
        conflicts = try values.decode(AgendaSyncPlanner.ConflictPolicy.self, forKey: .conflicts)
        automatic = try values.decode(Bool.self, forKey: .automatic)
        closeAgenda = try values.decode(Bool.self, forKey: .closeAgenda)
        pairings = try values.decodeIfPresent(AgendaSyncPairingRegistry.self, forKey: .pairings) ?? .init()
    }

    mutating func selectPairing(device: UUID, preserving previous: Self? = nil) {
        if let previous, !previous.agendaPath.isEmpty, !previous.calendarID.isEmpty {
            pairings.register(device: device, path: previous.agendaPath, calendar: previous.calendarID,
                              timeZone: previous.timeZoneID, existingID: previous.pairingID)
        }
        guard !agendaPath.isEmpty, !calendarID.isEmpty else { return }
        let existingID = previous == nil ? pairingID : nil
        pairingID = pairings.register(device: device, path: agendaPath, calendar: calendarID,
                                      timeZone: timeZoneID, existingID: existingID).id
    }

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
