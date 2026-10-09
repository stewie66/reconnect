import Foundation

/// A file/calendar pair retains its identity and occurrence-ID time zone when the display zone changes.
public struct AgendaSyncPairingRegistry: Codable, Equatable, Sendable {
    public struct Pairing: Codable, Equatable, Sendable {
        public var id: UUID
        public var identityTimeZoneID: String
    }

    private var pairings: [UUID: Pairing] = [:]

    public init() {}

    public func pairing(device: UUID, path: String, calendar: String) -> Pairing? {
        pairings[Self.key(device: device, path: path, calendar: calendar)]
    }

    @discardableResult
    public mutating func register(device: UUID, path: String, calendar: String, timeZone: String,
                                  existingID: UUID? = nil) -> Pairing {
        let key = Self.key(device: device, path: path, calendar: calendar)
        if let pairing = pairings[key] { return pairing }
        let pairing = Pairing(id: existingID ?? AgendaSyncPlanner.pairingIdentifier(device: device, path: path,
            calendar: calendar, timeZone: timeZone), identityTimeZoneID: timeZone)
        pairings[key] = pairing
        return pairing
    }

    private static func key(device: UUID, path: String, calendar: String) -> UUID {
        AgendaSyncPlanner.pairingIdentifier(device: device, path: path, calendar: calendar, timeZone: "")
    }
}
