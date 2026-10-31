import Foundation

public struct Envelope: Equatable {
    public var from: Double
    public var to: Double
    public var started: TimeInterval
    public var duration: TimeInterval
    public init(from: Double = 0, to: Double = 0, started: TimeInterval = 0, duration: TimeInterval = 0) {
        self.from = from; self.to = to; self.started = started; self.duration = max(0, duration)
    }
    public func value(at now: TimeInterval) -> Double {
        guard duration > 0 else { return to }
        let p = min(1, max(0, (now - started) / duration))
        return from + (to - from) * p
    }
    public func completed(at now: TimeInterval) -> Bool { now >= started + duration }
}

public enum PlaybackPhase: String {
    case stopped, fadingIn, playing, fadingOut
    public var title: String {
        switch self {
        case .stopped: return "停止中"
        case .fadingIn: return "フェードイン中"
        case .playing: return "再生中"
        case .fadingOut: return "フェードアウト中"
        }
    }
}

/// Owns one playlist at a time, including transitions. Time is monotonic, not wall-clock time.
public struct LanePlayback {
    public private(set) var playlistID: UUID?
    public private(set) var pendingID: UUID?
    public private(set) var phase: PlaybackPhase = .stopped
    public private(set) var envelope = Envelope()
    public init() {}
    public var active: Bool { playlistID != nil }

    public mutating func request(_ next: Playlist, project: PlayerProject, now: TimeInterval) {
        guard !next.tracks.isEmpty else { return }
        if phase == .fadingIn || phase == .fadingOut {
            stop(); begin(next, now: now)
        } else if let current = project.playlist(playlistID) {
            guard current.id != next.id else { return }
            pendingID = next.id; phase = .fadingOut
            envelope = Envelope(from: envelope.value(at: now), to: 0, started: now, duration: current.fades.fadeOut)
        } else { begin(next, now: now) }
        tick(project: project, now: now)
    }
    private mutating func begin(_ next: Playlist, now: TimeInterval) {
        playlistID = next.id; pendingID = nil; phase = .fadingIn
        envelope = Envelope(from: 0, to: 1, started: now, duration: next.fades.fadeIn)
    }
    public mutating func tick(project: PlayerProject, now: TimeInterval) {
        guard let current = project.playlist(playlistID), !current.tracks.isEmpty else { stop(); return }
        guard envelope.completed(at: now) else { return }
        if phase == .fadingOut {
            let next = project.playlist(pendingID)
            stop()
            if let next, !next.tracks.isEmpty { begin(next, now: now) }
        }
        if phase == .fadingIn && envelope.completed(at: now) { phase = .playing }
    }
    public mutating func stop() {
        playlistID = nil; pendingID = nil; phase = .stopped; envelope = Envelope()
    }
}

public struct OutputGate {
    public private(set) var phase: PlaybackPhase = .stopped
    public private(set) var envelope = Envelope()
    public init() {}
    public var active: Bool { phase != .stopped }
    public mutating func start(duration: Double, now: TimeInterval) {
        phase = .fadingIn
        envelope = Envelope(from: envelope.value(at: now), to: 1, started: now, duration: duration)
        tick(now: now)
    }
    public mutating func end(duration: Double, now: TimeInterval) {
        guard active else { return }
        phase = .fadingOut
        envelope = Envelope(from: envelope.value(at: now), to: 0, started: now, duration: duration)
        tick(now: now)
    }
    public mutating func tick(now: TimeInterval) {
        guard envelope.completed(at: now) else { return }
        if phase == .fadingOut { phase = .stopped }
        else if phase == .fadingIn { phase = .playing }
    }
    public mutating func stop() { phase = .stopped; envelope = Envelope() }
}

public enum AudioSuppression {
    public static func reasons(audioPlaylistActive: Bool, videoMuted: Bool, audioOutputActive: Bool) -> [String] {
        var result: [String] = []
        if audioPlaylistActive { result.append("映像プレイリスト音声をミュート中") }
        if videoMuted { result.append("映像プレイリストをミュート中") }
        if !audioOutputActive { result.append("音声出力は停止中") }
        return result
    }
}
