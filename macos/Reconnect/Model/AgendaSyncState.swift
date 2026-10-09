import Foundation
import PsionFormats

struct AgendaSyncState: Codable {
    struct Link: Codable {
        var id = UUID()
        var agendaID: String
        var macID: String?
        var externalID: String?
        var baseline: AgendaSyncContent?
        var hasBaseline = false
    }

    var version = 1
    var links: [Link] = []
    var lastSuccessfulSync: Date?
    var synchronizedTimeZoneID: String?

    static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let state = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard state.version == 1,
              Set(state.links.map(\.id)).count == state.links.count,
              Set(state.links.map(\.agendaID)).count == state.links.count,
              Set(state.links.compactMap(\.macID)).count == state.links.compactMap(\.macID).count else {
            throw NSError(domain: "Reconnect.AgendaSync", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The saved sync mappings are invalid. Restore the sync state before proceeding."])
        }
        return state
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
