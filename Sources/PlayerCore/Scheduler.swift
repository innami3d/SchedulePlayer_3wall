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
