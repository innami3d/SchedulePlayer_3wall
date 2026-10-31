import Foundation

public enum CalendarEditScope: String, CaseIterable, Identifiable {
    case all, following, occurrence
    public var id: Self { self }
    public var title: String {
        switch self {
        case .all: return "すべての予定"
        case .following: return "これ以降のすべての予定"
        case .occurrence: return "この予定のみ"
        }
    }
}

extension PlayerProject {
    /// Applies an edit or deletion atomically. An exception retains its original occurrence identity.
    public mutating func editCalendarEntry(id: UUID, occurrenceStart: Date, replacement: CalendarEntry?,
                                          scope: CalendarEditScope, calendar: Calendar = .current) {
        guard var entries = calendarEntries, let source = entries.first(where: { $0.id == id }) else { return }
        let seriesID = source.parentSeriesID ?? source.id
        guard let index = entries.firstIndex(where: { $0.id == seriesID }) else { return }
        let series = entries[index]
        let selected = source.originalStart ?? occurrenceStart
        guard series.repetition != .once else {
            if var replacement { replacement.id = source.id; entries[index] = replacement }
            else { entries.removeAll { $0.id == source.id } }
            calendarEntries = entries; return
        }
        let linked = entries.filter { $0.parentSeriesID == seriesID }
        // Move calendar days and local clock time rather than a fixed number of seconds across DST.
        let dayShift = replacement.map {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: occurrenceStart),
                                    to: calendar.startOfDay(for: $0.start)).day ?? 0
        } ?? 0
        func shifted(_ date: Date) -> Date {
            guard let replacement else { return date }
            let day = calendar.date(byAdding: .day, value: dayShift, to: date) ?? date
            return TimeOfDay.at(replacement.start, calendar: calendar).date(on: day, calendar: calendar) ?? day
        }
        func finish(for start: Date, draft: CalendarEntry) -> Date {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: draft.start),
                                               to: calendar.startOfDay(for: draft.end)).day ?? 0
            let day = calendar.date(byAdding: .day, value: days, to: start) ?? start
            return TimeOfDay.at(draft.end, calendar: calendar).date(on: day, calendar: calendar) ?? draft.end
        }
        switch scope {
        case .occurrence:
            var excluded = series.excludedStarts ?? []
            if !excluded.contains(where: { calendar.isDate($0, inSameDayAs: selected) }) { excluded.append(selected) }
            entries[index].excludedStarts = excluded
            entries.removeAll { $0.parentSeriesID == seriesID && $0.originalStart.map { calendar.isDate($0, inSameDayAs: selected) } == true }
            if var replacement {
                replacement.id = source.parentSeriesID == nil ? UUID() : source.id
                replacement.repetition = .once; replacement.repeatUntil = nil; replacement.excludedStarts = nil
                replacement.parentSeriesID = seriesID; replacement.originalStart = selected
                entries.append(replacement)
            }
        case .following, .all:
            let boundary = scope == .all ? series.start : selected
            let affected = linked.filter { ($0.originalStart ?? $0.start) >= boundary }
            // Existing edited instances become regular occurrences under an explicit series-wide edit;
            // individually deleted dates stay deleted.
            let exclusions = (series.excludedStarts ?? []).filter { date in
                date >= boundary && !affected.contains { $0.originalStart.map { calendar.isDate($0, inSameDayAs: date) } == true }
            }
            entries.removeAll { entry in affected.contains { $0.id == entry.id } }
            guard let currentIndex = entries.firstIndex(where: { $0.id == seriesID }) else { return }
            if scope == .all {
                if var replacement {
                    let draft = replacement
                    replacement.id = seriesID
                    replacement.start = shifted(series.start)
                    replacement.end = finish(for: replacement.start, draft: draft)
                    replacement.repeatUntil = series.repeatUntil.map(shifted)
                    replacement.excludedStarts = exclusions.map(shifted)
                    replacement.parentSeriesID = nil; replacement.originalStart = nil
                    entries[currentIndex] = replacement
                } else { entries.removeAll { $0.id == seriesID || $0.parentSeriesID == seriesID } }
            } else {
                entries[currentIndex].repeatUntil = min(series.repeatUntil ?? selected, selected)
                entries[currentIndex].excludedStarts = (series.excludedStarts ?? []).filter { $0 < selected }
                if var replacement {
                    replacement.id = UUID(); replacement.parentSeriesID = nil; replacement.originalStart = nil
                    replacement.repeatUntil = series.repeatUntil.map(shifted)
                    replacement.excludedStarts = exclusions.map(shifted)
                    entries.append(replacement)
                }
            }
        }
        calendarEntries = entries
    }
}

public enum CalendarResizeEdge { case start, end }

extension CalendarEntry {
    /// Resize a displayed occurrence while keeping its opposite endpoint fixed.
    public func resized(occurrence: DateInterval, edge: CalendarResizeEdge, minutes: Int,
                        calendar: Calendar = .current) -> CalendarEntry {
        var result = self
        result.start = occurrence.start; result.end = occurrence.end
        let endpoint = edge == .start ? occurrence.start : occurrence.end
        guard let candidate = calendar.date(byAdding: .minute, value: minutes, to: endpoint) else { return result }
        let clock = calendar.dateComponents([.hour, .minute], from: candidate)
        let snapped = Int((Double((clock.hour ?? 0) * 60 + (clock.minute ?? 0)) / 15).rounded()) * 15
        let day = calendar.startOfDay(for: candidate)
        let adjusted: Date?
        if snapped == 1440 { adjusted = calendar.date(byAdding: .day, value: 1, to: day) }
        else { adjusted = calendar.date(bySettingHour: snapped / 60, minute: snapped % 60, second: 0, of: day) }
        guard let adjusted else { return result }
        if edge == .start {
            result.start = min(occurrence.end.addingTimeInterval(-900), max(occurrence.end.addingTimeInterval(-7 * 86_400), adjusted))
        } else {
            result.end = max(occurrence.start.addingTimeInterval(900), min(occurrence.start.addingTimeInterval(7 * 86_400), adjusted))
        }
        return result
    }
}

extension CalendarEntry {
    /// Move vertically within the occurrence's start day, preserving its exact duration.
    public func moved(occurrence: DateInterval, minutes: Int, calendar: Calendar = .current) -> CalendarEntry {
        var result = self
        let clock = calendar.dateComponents([.hour, .minute], from: occurrence.start)
        let originalMinute = (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
        let snapped = Int(((Double(originalMinute) + Double(minutes)) / 15).rounded()) * 15
        let clamped = min(1425, max(0, snapped))
        let start = calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: occurrence.start) ?? occurrence.start
        result.start = start
        result.end = start.addingTimeInterval(occurrence.duration)
        return result
    }
}
