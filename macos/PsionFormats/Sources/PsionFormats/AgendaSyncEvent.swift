import Foundation

/// Identity is scoped to one device/Agenda pairing, and never depends on file contents.
public struct AgendaSyncEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var content: AgendaSyncContent

    public init(id: String, content: AgendaSyncContent) {
        self.id = id
        self.content = content
    }
}
