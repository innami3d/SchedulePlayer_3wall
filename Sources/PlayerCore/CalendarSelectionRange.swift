import Foundation

/// A drag-selected interval on a calendar day, in local clock minutes.
public struct CalendarSelectionRange: Equatable {
    public let startMinute: Int
    public let endMinute: Int
    public init(anchorMinute: Int, currentMinute: Int) {
        let anchor = min(1425, max(0, anchorMinute / 15 * 15))
        let current = min(1440, max(0, Int((Double(currentMinute) / 15).rounded()) * 15))
        startMinute = min(anchor, current)
        endMinute = max(startMinute + 15, max(anchor, current))
    }
    public func interval(on day: Date, calendar: Calendar = .current) -> DateInterval? {
        func date(_ minute: Int) -> Date? {
            if minute == 1440 { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) }
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
        }
        guard let start = date(startMinute), let end = date(endMinute), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
    public var timeLabel: String {
        String(format: "%02d:%02d–%02d:%02d", startMinute / 60, startMinute % 60, endMinute / 60, endMinute % 60)
    }
}
