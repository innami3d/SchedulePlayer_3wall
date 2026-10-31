import Foundation

public enum MediaLane: String, Codable, CaseIterable, Identifiable, Sendable {
    case video, audio
    public var id: String { rawValue }
    public var title: String { self == .video ? "映像" : "音声" }
}

public enum MediaKind: String, Codable {
    case image, video, audio
    public var title: String {
        switch self { case .image: return "画像"; case .video: return "動画"; case .audio: return "音声" }
    }
    public static func identify(_ url: URL) -> Self? {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp", "webp": return .image
        case "mp4", "mov", "m4v": return .video
        case "wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "caf": return .audio
        default: return nil
        }
    }
    public func accepts(_ lane: MediaLane) -> Bool { lane == .video ? self != .audio : self == .audio }
}

public struct TimeOfDay: Codable, Equatable, Comparable, Hashable {
    public var seconds: Int
    public init(seconds: Int) { self.seconds = min(86_399, max(0, seconds)) }
    public init(hour: Int, minute: Int = 0, second: Int = 0) {
        self.init(seconds: hour * 3600 + minute * 60 + second)
    }
    public init?(text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        let s = parts.count == 3 ? Int(parts[2]) : 0
        guard let s, (0...59).contains(s) else { return nil }
        self.init(hour: h, minute: m, second: s)
    }
    public var text: String { String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.seconds < rhs.seconds }
    public func date(on day: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(bySettingHour: seconds / 3600, minute: seconds / 60 % 60, second: seconds % 60, of: day)
    }
    public static func at(_ date: Date, calendar: Calendar = .current) -> Self {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return .init(hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }
}

public struct FadeSettings: Codable, Equatable {
    public var fadeIn: Double
    public var fadeOut: Double
    public init(fadeIn: Double = 2, fadeOut: Double = 2) { self.fadeIn = fadeIn; self.fadeOut = fadeOut }
}

public struct OutputSchedule: Codable, Equatable {
    public var start = TimeOfDay(hour: 17)
    public var end = TimeOfDay(hour: 22)
    public var fades = FadeSettings(fadeIn: 3, fadeOut: 3)
    public var initialPlaylistID: UUID?
    public init() {}
    public func contains(_ time: TimeOfDay) -> Bool {
        if start == end { return false }
        return start < end ? time >= start && time < end : time >= start || time < end
    }
}

public struct ProjectDefaults: Codable, Equatable {
    public var playlistFades = FadeSettings()
    public var videoTrackFades = FadeSettings(fadeIn: 0, fadeOut: 0)
    public var audioTrackFades = FadeSettings(fadeIn: 0, fadeOut: 0)
    public var imageDuration: Double = 20
    public var volume: Double = 1
    public var muteVideo = false
    public var fadeMax: Double = 60
    public var imageMax: Double = 3600
    public var volumeMin: Double = 0
    public var volumeMax: Double = 1
    public init() {}
}

public struct MediaTrack: Codable, Identifiable, Equatable {
    public var id: UUID
    public var path: String
    public var kind: MediaKind
    public var volume: Double
    public var imageDuration: Double
    public init(id: UUID = UUID(), path: String, kind: MediaKind, volume: Double = 1, imageDuration: Double = 20) {
        self.id = id; self.path = path; self.kind = kind; self.volume = volume; self.imageDuration = imageDuration
    }
    public var filename: String { URL(fileURLWithPath: path).lastPathComponent }
    public func resolvedURL(relativeTo directory: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return (directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent(path).standardizedFileURL
    }
    public func duplicated() -> Self { var copy = self; copy.id = UUID(); return copy }
}

public struct Playlist: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var lane: MediaLane
    public var start = TimeOfDay(hour: 17)
    public var scheduleOrder: Int64
    public var fades: FadeSettings
    public var muted: Bool
    public var tracks: [MediaTrack]
    public init(id: UUID = UUID(), name: String, lane: MediaLane, order: Int64 = 0, defaults: ProjectDefaults = .init()) {
        self.id = id; self.name = name; self.lane = lane; self.scheduleOrder = order
        self.fades = defaults.playlistFades; self.muted = lane == .video && defaults.muteVideo; self.tracks = []
    }
    public func duplicated(order: Int64) -> Self {
        var p = self; p.id = UUID(); p.name += " のコピー"; p.scheduleOrder = order
        p.tracks = tracks.map { $0.duplicated() }; return p
    }
}

public struct PlayerProject: Codable, Equatable {
    public var schemaVersion = 1
    public var name = "新規プロジェクト"
    public var displayID: UInt32?
    public var displayUUID: String?
    public var displayName: String?
    public var audioDeviceName: String?
    public var audioDeviceUID: String?
    public var refreshRate: Double = 30
    public var fadeColorHex = "#000000"
    public var video = OutputSchedule()
    public var audio = OutputSchedule()
    public var defaults = ProjectDefaults()
    public var playlists: [Playlist] = []
    public init() {}
    public func schedule(for lane: MediaLane) -> OutputSchedule { lane == .video ? video : audio }
    public func playlist(_ id: UUID?) -> Playlist? { playlists.first { $0.id == id } }
    public var nextOrder: Int64 { (playlists.map(\.scheduleOrder).max() ?? 0) + 1 }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data) throws -> Self {
        let project = try JSONDecoder().decode(Self.self, from: data)
        guard project.schemaVersion == 1 else { throw ProjectError.unsupportedVersion }
        try project.validate(); return project
    }
    public func validate() throws {
        func finite(_ value: Double, _ range: ClosedRange<Double>) -> Bool { value.isFinite && range.contains(value) }
        guard finite(refreshRate, 1...240), finite(defaults.fadeMax, 0...86_400),
              finite(defaults.imageMax, 0.1...604_800), finite(defaults.volumeMin, 0...1),
              finite(defaults.volumeMax, defaults.volumeMin...1),
              finite(defaults.imageDuration, 0.1...defaults.imageMax),
              finite(defaults.volume, defaults.volumeMin...defaults.volumeMax),
              fadeColorHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
              Set(playlists.map(\.id)).count == playlists.count else { throw ProjectError.invalidValues }
        for f in [video.fades, audio.fades, defaults.playlistFades, defaults.videoTrackFades, defaults.audioTrackFades] + playlists.map(\.fades) {
            guard finite(f.fadeIn, 0...defaults.fadeMax), finite(f.fadeOut, 0...defaults.fadeMax) else { throw ProjectError.invalidValues }
        }
        for s in [video, audio] {
            guard (0...86_399).contains(s.start.seconds), (0...86_399).contains(s.end.seconds) else { throw ProjectError.invalidValues }
        }
        for p in playlists {
            guard (0...86_399).contains(p.start.seconds), Set(p.tracks.map(\.id)).count == p.tracks.count else { throw ProjectError.invalidValues }
            for t in p.tracks {
                guard !t.path.isEmpty, t.kind.accepts(p.lane), finite(t.volume, 0...1),
                      finite(t.imageDuration, 0.1...defaults.imageMax) else { throw ProjectError.invalidValues }
            }
        }
    }
}

public enum ProjectError: LocalizedError {
    case unsupportedVersion, invalidValues
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "このプロジェクトのバージョンは対応していません。"
        case .invalidValues: return "設定値が範囲外か、プレイリスト・トラックの構成が不正です。"
        }
    }
}
