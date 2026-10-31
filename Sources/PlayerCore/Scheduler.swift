import Foundation

public enum ScheduledAction: Equatable {
    case startOutput, endOutput, playlist(UUID)
}
public struct ScheduledEvent: Equatable {
    public var date: Date
    public var lane: MediaLane
    public var action: ScheduledAction
}

public enum DailyScheduler {
    /// Returns crossings in (previous, now]. Project end wins over start; start wins over playlist.
    /// A pause longer than a day should be reconciled by the caller rather than replaying old events.
    public static func events(project: PlayerProject, after previous: Date, through now: Date,
                              calendar: Calendar = .current) -> [ScheduledEvent] {
        guard now > previous, now.timeIntervalSince(previous) <= 86_400 else { return [] }
        let first = calendar.startOfDay(for: previous)
        let last = calendar.startOfDay(for: now)
        let days = first == last ? [first] : [first, last]
        var result: [ScheduledEvent] = []
        for day in days {
            for lane in MediaLane.allCases {
                let schedule = project.schedule(for: lane)
                var byDate: [Date: (priority: Int, order: Int64, action: ScheduledAction)] = [:]
                func insert(_ time: TimeOfDay, priority: Int, order: Int64 = 0, action: ScheduledAction) {
                    guard let date = time.date(on: day, calendar: calendar), date > previous, date <= now else { return }
                    if let old = byDate[date], old.priority > priority || (old.priority == priority && old.order > order) { return }
                    byDate[date] = (priority, order, action)
                }
                for p in project.playlists where p.lane == lane {
                    insert(p.start, priority: 0, order: p.scheduleOrder, action: .playlist(p.id))
                }
                insert(schedule.start, priority: 1, action: .startOutput)
                insert(schedule.end, priority: 2, action: .endOutput)
                result += byDate.map { ScheduledEvent(date: $0.key, lane: lane, action: $0.value.action) }
            }
        }
        return result.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.lane.rawValue < $1.lane.rawValue
        }
    }
}

/// A scheduled lane reconstructed on the caller's monotonic clock.
public struct ScheduledPlayback {
    public var state: LanePlayback
    public var elapsed: TimeInterval
}

public struct ScheduledTrackPosition: Equatable {
    public var index: Int
    public var offset: TimeInterval

    public static func resolve(durations: [Double], elapsed: TimeInterval) -> Self? {
        guard !durations.isEmpty, elapsed.isFinite, elapsed >= 0,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let total = durations.reduce(0, +)
        guard total.isFinite else { return nil }
        var offset = elapsed.truncatingRemainder(dividingBy: total)
        for (index, duration) in durations.enumerated() {
            if offset < duration { return Self(index: index, offset: offset) }
            offset -= duration
        }
        return Self(index: 0, offset: 0)
    }
}

extension DailyScheduler {
    /// Replays decisions since the latest daily stop, including playlist fade-out delays.
    /// A playlist's own start time can start output before the default output start.
    public static func playback(project: PlayerProject, lane: MediaLane, at date: Date,
                                now: TimeInterval, calendar: Calendar = .current) -> ScheduledPlayback? {
        let schedule = project.schedule(for: lane)
        var day = calendar.startOfDay(for: date)
        guard var stop = schedule.end.date(on: day, calendar: calendar) else { return nil }
        if stop > date {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
            day = previous
            guard let previousStop = schedule.end.date(on: day, calendar: calendar) else { return nil }
            stop = previousStop
        }
        // Split by calendar day so a 25-hour DST day does not hit events' 24-hour limit.
        var decisions: [ScheduledEvent] = []
        var cursor = stop
        while cursor < date {
            let next = min(date, cursor.addingTimeInterval(43_200))
            decisions += events(project: project, after: cursor, through: next, calendar: calendar)
            cursor = next
        }
        let dateNow = date
        func clock(_ date: Date) -> TimeInterval { now + date.timeIntervalSince(dateNow) }
        var state = LanePlayback()
        var outputActive = false
        var began: TimeInterval = now
        func advance(to time: TimeInterval) {
            if state.phase == .fadingOut, state.envelope.started + state.envelope.duration <= time {
                let boundary = state.envelope.started + state.envelope.duration
                state.tick(project: project, now: boundary)
                if state.active { began = boundary }
            }
            state.tick(project: project, now: time)
        }
        for event in decisions where event.lane == lane {
            let time = clock(event.date)
            advance(to: time)
            let playlist: Playlist?
            switch event.action {
            case .startOutput:
                outputActive = true
                playlist = project.playlist(schedule.initialPlaylistID)
            case .playlist(let id): playlist = project.playlist(id)
            case .endOutput:
                outputActive = false; state.stop(); playlist = nil
            }
            if let playlist, playlist.lane == lane, !playlist.tracks.isEmpty {
                outputActive = true
                let oldID = state.playlistID, oldPhase = state.phase
                state.request(playlist, project: project, now: time)
                if state.playlistID != oldID || oldPhase == .fadingIn || oldPhase == .fadingOut {
                    began = time
                }
            }
        }
        advance(to: now)
        guard outputActive else { return nil }
        return ScheduledPlayback(state: state, elapsed: max(0, now - began))
    }
}
