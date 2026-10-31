import XCTest
@testable import PlayerCore

final class PlayerCoreTests: XCTestCase {
    func fixture() -> (PlayerProject, Playlist, Playlist) {
        var project = PlayerProject()
        var a = Playlist(name: "A", lane: .video)
        a.tracks = [MediaTrack(path: "/tmp/a.mp4", kind: .video)]
        var b = a.duplicated(order: 2); b.name = "B"
        project.playlists = [a, b]
        return (project, a, b)
    }
    func testProjectRoundTripAndIndependentCopies() throws {
        let (project, a, b) = fixture()
        XCTAssertEqual(try PlayerProject.decode(project.encoded()), project)
        XCTAssertNotEqual(a.id, b.id); XCTAssertNotEqual(a.tracks[0].id, b.tracks[0].id)
        XCTAssertEqual(a.tracks[0].path, b.tracks[0].path)
    }
    func testRejectInvalidProject() throws {
        var (project, _, _) = fixture()
        project.defaults.volumeMin = 2
        XCTAssertThrowsError(try PlayerProject.decode(project.encoded()))
        project.defaults.volumeMin = 0; project.playlists[0].tracks[0].volume = -1
        XCTAssertThrowsError(try PlayerProject.decode(project.encoded()))
    }
    func testTimeValidationAndOvernightWindow() {
        XCTAssertNil(TimeOfDay(text: "25:00")); XCTAssertNil(TimeOfDay(text: "12:99"))
        XCTAssertEqual(TimeOfDay(text: "01:02:03")?.text, "01:02:03")
        var schedule = OutputSchedule(); schedule.start = .init(hour: 22); schedule.end = .init(hour: 6)
        XCTAssertTrue(schedule.contains(.init(hour: 23))); XCTAssertTrue(schedule.contains(.init(hour: 2)))
        XCTAssertFalse(schedule.contains(.init(hour: 12)))
    }
    func testSequentialPlaylistSwitchAndInterruptedFade() {
        let (project, a, b) = fixture(); var state = LanePlayback()
        state.request(a, project: project, now: 0); state.tick(project: project, now: 2)
        XCTAssertEqual(state.phase, .playing)
        state.request(b, project: project, now: 3)
        XCTAssertEqual(state.playlistID, a.id); XCTAssertEqual(state.pendingID, b.id)
        state.tick(project: project, now: 4.9); XCTAssertEqual(state.playlistID, a.id)
        state.tick(project: project, now: 5); XCTAssertEqual(state.playlistID, b.id)
        XCTAssertNil(state.pendingID); XCTAssertEqual(state.envelope.value(at: 5), 0)
        // A new request during fade-in interrupts immediately, not queued behind the old fade.
        state.request(a, project: project, now: 5.5)
        XCTAssertEqual(state.playlistID, a.id); XCTAssertNil(state.pendingID)
    }
    func testZeroFadeAndEmptyPlaylist() {
        var (project, a, b) = fixture(); a.fades = .init(fadeIn: 0, fadeOut: 0); b.fades = a.fades
        project.playlists = [a, b]; var state = LanePlayback()
        state.request(a, project: project, now: 0); XCTAssertEqual(state.phase, .playing)
        state.request(b, project: project, now: 0); XCTAssertEqual(state.playlistID, b.id)
        var empty = b; empty.tracks = []; state.request(empty, project: project, now: 1)
        XCTAssertEqual(state.playlistID, b.id)
    }
    func testOutputEndStartsAtTimeAndStopsAfterFade() {
        var gate = OutputGate(); gate.start(duration: 0, now: 0)
        gate.end(duration: 3, now: 10)
        XCTAssertTrue(gate.active); XCTAssertEqual(gate.envelope.value(at: 11.5), 0.5, accuracy: 0.001)
        gate.tick(now: 13); XCTAssertFalse(gate.active)
    }
    func testLatestScheduleAndMidnightCrossing() {
        var (project, a, b) = fixture()
        a.start = .init(hour: 0); a.scheduleOrder = 1
        b.start = a.start; b.scheduleOrder = 2; project.playlists = [a, b]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = Date(timeIntervalSince1970: 1_735_776_000)
        let events = DailyScheduler.events(project: project, after: midnight.addingTimeInterval(-1), through: midnight, calendar: calendar)
        XCTAssertEqual(events.filter { $0.lane == .video }.map(\.action), [.playlist(b.id)])
        XCTAssertTrue(DailyScheduler.events(project: project, after: midnight, through: midnight, calendar: calendar).isEmpty)
    }
    func testProjectStartWinsPlaylistAndSuppressionReasons() {
        var (project, a, _) = fixture(); a.start = project.video.start; project.playlists = [a]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_735_776_000), start = project.video.start.date(on: day, calendar: calendar)!
        let events = DailyScheduler.events(project: project, after: start.addingTimeInterval(-1), through: start, calendar: calendar)
        XCTAssertEqual(events.filter { $0.lane == .video }.map(\.action), [.startOutput])
        XCTAssertEqual(AudioSuppression.reasons(audioPlaylistActive: true, videoMuted: true, audioOutputActive: false).count, 3)
        XCTAssertTrue(AudioSuppression.reasons(audioPlaylistActive: false, videoMuted: false, audioOutputActive: true).isEmpty)
    }
}
