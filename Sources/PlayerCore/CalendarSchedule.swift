import Foundation

public enum ScheduleRepeat: String, Codable, CaseIterable, Identifiable {
    case once, daily, weekly
    public var id: Self { self }
    public var title: String {
        switch self { case .once: return "繰り返さない"; case .daily: return "毎日"; case .weekly: return "毎週" }
    }
}

public struct CalendarEntry: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var playlistID: UUID
    public var start: Date
    public var end: Date
    public var fades: FadeSettings
    public var repetition: ScheduleRepeat
    /// Exclusive upper bound on occurrence starts, used when splitting a series.
    public var repeatUntil: Date?
    public var excludedStarts: [Date]?
    public var parentSeriesID: UUID?
    public var originalStart: Date?
    public init(playlistID: UUID, start: Date, end: Date, fades: FadeSettings = .init(), repetition: ScheduleRepeat = .once) {
        self.playlistID = playlistID; self.start = start; self.end = end
        self.fades = fades; self.repetition = repetition
    }
    public func occurrence(on day: Date, calendar: Calendar = .current) -> DateInterval? {
        let day = calendar.startOfDay(for: day)
        let original = calendar.startOfDay(for: start)
        if repetition == .once && day != original { return nil }
        if repetition != .once && day < original { return nil }
        if repetition == .weekly && calendar.component(.weekday, from: day) != calendar.component(.weekday, from: start) { return nil }
        guard let begin = TimeOfDay.at(start, calendar: calendar).date(on: day, calendar: calendar) else { return nil }
        if let repeatUntil, begin >= repeatUntil { return nil }
        if (excludedStarts ?? []).contains(where: { calendar.isDate($0, inSameDayAs: begin) }) { return nil }
        let dayCount = calendar.dateComponents([.day], from: original, to: calendar.startOfDay(for: end)).day ?? 0
        guard let endDay = calendar.date(byAdding: .day, value: dayCount, to: day),
              let finish = TimeOfDay.at(end, calendar: calendar).date(on: endDay, calendar: calendar), finish > begin else { return nil }
        return DateInterval(start: begin, end: finish)
    }
}

public struct CalendarOccurrence: Identifiable {
    public var id: String { entry.id.uuidString + ":" + String(interval.start.timeIntervalSince1970) }
    public var entry: CalendarEntry
    public var interval: DateInterval
}

public enum CalendarScheduler {
    public static func active(project: PlayerProject, lane: MediaLane, at date: Date, calendar: Calendar = .current) -> CalendarOccurrence? {
        occurrences(project: project, from: date.addingTimeInterval(-8 * 86_400), through: date, calendar: calendar)
            .filter { project.playlist($0.entry.playlistID)?.lane == lane && project.playlist($0.entry.playlistID)?.tracks.isEmpty == false && $0.interval.start <= date && date < $0.interval.end }
            .max { lhs, rhs in
                if lhs.interval.start != rhs.interval.start { return lhs.interval.start < rhs.interval.start }
                return lhs.entry.id.uuidString < rhs.entry.id.uuidString
            }
    }
    public static func occurrences(project: PlayerProject, from: Date, through: Date, calendar: Calendar = .current) -> [CalendarOccurrence] {
        guard through >= from else { return [] }
        var day = calendar.startOfDay(for: from)
        var result: [CalendarOccurrence] = []
        while day <= through {
            for entry in project.calendarEntries ?? [] {
                if let interval = entry.occurrence(on: day, calendar: calendar), interval.end > from, interval.start <= through {
                    result.append(.init(entry: entry, interval: interval))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }
    public static func events(project: PlayerProject, after previous: Date, through now: Date, calendar: Calendar = .current) -> [ScheduledEvent] {
        guard now > previous else { return [] }
        let occurrences = occurrences(project: project, from: previous.addingTimeInterval(-8 * 86_400), through: now, calendar: calendar)
        let boundaries = Set(occurrences.flatMap { [$0.interval.start, $0.interval.end] }.filter { $0 > previous && $0 <= now })
        var result: [ScheduledEvent] = []
        for date in boundaries.sorted() {
            for lane in MediaLane.allCases {
                let before = active(project: project, lane: lane, at: date.addingTimeInterval(-0.001), calendar: calendar)
                let after = active(project: project, lane: lane, at: date, calendar: calendar)
                if before?.entry.id != after?.entry.id || before?.interval.start != after?.interval.start {
                    result.append(.init(date: date, lane: lane, action: after.map { .playlist($0.entry.playlistID) } ?? .endOutput))
                }
            }
        }
        return result
    }
    public static func ending(project: PlayerProject, lane: MediaLane, at date: Date, calendar: Calendar = .current) -> CalendarOccurrence? {
        occurrences(project: project, from: date.addingTimeInterval(-8 * 86_400), through: date, calendar: calendar)
            .filter { project.playlist($0.entry.playlistID)?.lane == lane && $0.interval.end <= date && date < $0.interval.end.addingTimeInterval($0.entry.fades.fadeOut) }
            .max { $0.interval.end < $1.interval.end }
    }
    public static func playback(project: PlayerProject, lane: MediaLane, at date: Date, now: TimeInterval, calendar: Calendar = .current) -> ScheduledPlayback? {
        guard let occurrence = active(project: project, lane: lane, at: date, calendar: calendar) ?? ending(project: project, lane: lane, at: date, calendar: calendar),
              let playlist = project.playlist(occurrence.entry.playlistID), !playlist.tracks.isEmpty else { return nil }
        var state = LanePlayback()
        state.request(playlist, project: project, now: now - date.timeIntervalSince(occurrence.interval.start), usePlaylistFades: false)
        state.tick(project: project, now: now)
        return ScheduledPlayback(state: state, elapsed: date.timeIntervalSince(occurrence.interval.start))
    }
}
