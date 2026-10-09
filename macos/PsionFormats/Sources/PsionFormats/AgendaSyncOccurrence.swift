import Foundation

/// Identifies an edited Calendar occurrence by its original date, even when it is moved.
public struct AgendaSyncOccurrence: Codable, Equatable, Sendable {
    public var calendarItemID: String
    public var originalDate: AgendaSyncContent.LocalDate
    public var originalInstant: Date?

    public init(calendarItemID: String, originalDate: AgendaSyncContent.LocalDate, originalInstant: Date? = nil) {
        self.calendarItemID = calendarItemID
        self.originalDate = originalDate
        self.originalInstant = originalInstant
    }

    public func identifier() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return "reconnect-occurrence:" + (try encoder.encode(self)).base64EncodedString()
    }

    public init?(identifier: String) {
        let prefix = "reconnect-occurrence:"
        guard identifier.hasPrefix(prefix),
              let data = Data(base64Encoded: String(identifier.dropFirst(prefix.count))),
              let occurrence = try? JSONDecoder().decode(Self.self, from: data),
              !occurrence.calendarItemID.isEmpty else { return nil }
        self = occurrence
    }

    /// Agenda represents an edited occurrence as an appointment alongside the excluded series date.
    public static func standaloneContent(_ content: AgendaSyncContent) -> AgendaSyncContent {
        var result = content
        result.repeatRule = nil
        return result
    }
}
