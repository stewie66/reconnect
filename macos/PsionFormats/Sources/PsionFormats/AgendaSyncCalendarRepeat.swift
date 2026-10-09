import Foundation

/// Describes the parts of a Calendar repeat that determine whether Agenda can keep it native.
/// Other patterns are imported from Calendar's enumerated occurrences, without approximating rules.
public struct AgendaSyncCalendarRepeat: Equatable, Sendable {
    public enum Frequency: Sendable { case daily, weekly, monthly, yearly }

    public struct Weekday: Equatable, Sendable {
        public var day: Int
        public var ordinal: Int

        public init(day: Int, ordinal: Int = 0) {
            self.day = day
            self.ordinal = ordinal
        }
    }

    public var frequency: Frequency
    public var interval: Int
    public var occurrenceCount: Int
    public var weekdays: [Weekday]
    public var hasAdditionalSelectors: Bool

    public init(frequency: Frequency, interval: Int = 1, occurrenceCount: Int = 0,
                weekdays: [Weekday] = [], hasAdditionalSelectors: Bool = false) {
        self.frequency = frequency
        self.interval = interval
        self.occurrenceCount = occurrenceCount
        self.weekdays = weekdays
        self.hasAdditionalSelectors = hasAdditionalSelectors
    }

    public var canKeepNative: Bool {
        frequency != .monthly && (1...Int(UInt16.max)).contains(interval) && occurrenceCount == 0 &&
        !hasAdditionalSelectors && weekdays.allSatisfy { (0..<7).contains($0.day) && $0.ordinal == 0 } &&
        (frequency == .weekly || weekdays.isEmpty)
    }
}
