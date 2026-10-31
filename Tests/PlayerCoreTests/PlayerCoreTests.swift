import XCTest
@testable import PlayerCore

final class PlayerCoreTests: XCTestCase {
    func testLegacyPlaylistPlaybackSettingsMigrationAndIndependentRoundTrip() throws {
        var project = PlayerProject()
        project.defaults.videoTrackFades = .init(fadeIn: 3, fadeOut: 4)
        project.defaults.audioTrackFades = .init(fadeIn: 5, fadeOut: 6)
        project.fadeColorHex = "#123456"
        project.playlists = [Playlist(name: "A", lane: .video), Playlist(name: "B", lane: .audio)]
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: project.encoded()) as? [String: Any])
        var playlists = try XCTUnwrap(legacy["playlists"] as? [[String: Any]])
        for index in playlists.indices { playlists[index].removeValue(forKey: "playbackSettings") }
        legacy["playlists"] = playlists
        var migrated = try PlayerProject.decode(JSONSerialization.data(withJSONObject: legacy))
        for playlist in migrated.playlists {
            XCTAssertEqual(playlist.playbackSettings.videoTrackFades, project.defaults.videoTrackFades)
            XCTAssertEqual(playlist.playbackSettings.audioTrackFades, project.defaults.audioTrackFades)
            XCTAssertEqual(playlist.playbackSettings.fadeColorHex, "#123456")
        }
        migrated.playlists[0].playbackSettings.videoTrackFades.fadeIn = 9
        migrated.playlists[0].playbackSettings.fadeColorHex = "#ABCDEF"
        XCTAssertEqual(migrated.playlists[1].playbackSettings.videoTrackFades.fadeIn, 3)
        XCTAssertEqual(migrated.playlists[1].playbackSettings.fadeColorHex, "#123456")
        XCTAssertEqual(try PlayerProject.decode(migrated.encoded()), migrated)
        XCTAssertEqual(migrated.playlists[0].duplicated(order: 2).playbackSettings, migrated.playlists[0].playbackSettings)
        var invalid = migrated
        invalid.playlists[0].playbackSettings.audioTrackFades.fadeOut = 61
        XCTAssertThrowsError(try invalid.validate())
        invalid = migrated
        invalid.playlists[1].playbackSettings.fadeColorHex = "invalid"
        XCTAssertThrowsError(try invalid.validate())
    }

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
        project.playlists[1].tracks = []
        state.tick(project: project, now: 2)
        XCTAssertFalse(state.active)
    }
    func testOutputEndStartsAtTimeAndStopsAfterFade() {
        var gate = OutputGate(); gate.start(duration: 0, now: 0)
        gate.end(duration: 3, now: 10)
        XCTAssertTrue(gate.active); XCTAssertEqual(gate.envelope.value(at: 11.5), 0.5, accuracy: 0.001)
        gate.tick(now: 13); XCTAssertFalse(gate.active)
    }
    func testLatestScheduleAndMidnightCrossing() {
        var (project, a, b) = fixture()
        project.calendarEntries = nil // Exercise legacy scheduling used during migration.
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
        project.calendarEntries = nil // Exercise legacy scheduling used during migration.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_735_776_000), start = project.video.start.date(on: day, calendar: calendar)!
        let events = DailyScheduler.events(project: project, after: start.addingTimeInterval(-1), through: start, calendar: calendar)
        XCTAssertEqual(events.filter { $0.lane == .video }.map(\.action), [.startOutput])
        XCTAssertEqual(AudioSuppression.reasons(audioPlaylistActive: true, videoMuted: true, audioOutputActive: false).count, 3)
        XCTAssertTrue(AudioSuppression.reasons(audioPlaylistActive: false, videoMuted: false, audioOutputActive: true).isEmpty)
    }
}

extension PlayerCoreTests {

    func testRememberedOutputDevicesRoundTripAndLegacyProject() throws {
        var project = PlayerProject()
        project.displayID = 10; project.displayUUID = "display-uuid"; project.displayName = "GeoBox"
        project.audioDeviceUID = "audio-uid"; project.audioDeviceName = "Audio Interface"
        XCTAssertEqual(try PlayerProject.decode(project.encoded()), project)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: project.encoded()) as? [String: Any])
        for key in ["displayUUID", "displayName", "audioDeviceName"] { legacy.removeValue(forKey: key) }
        let restored = try PlayerProject.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.displayID, 10); XCTAssertEqual(restored.audioDeviceUID, "audio-uid")
        XCTAssertNil(restored.displayUUID)
    }
}

extension PlayerCoreTests {
    private var scheduleCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func date(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        scheduleCalendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: hour, minute: minute, second: second))!
    }
    func testResumeInitialPlaylistAndTrackLoopPosition() throws {
        var (project, a, b) = fixture()
        project.calendarEntries = nil // Exercise legacy scheduling used during migration.
        a.start = .init(hour: 16); b.start = .init(hour: 20)
        project.playlists = [a, b]; project.video.initialPlaylistID = a.id
        let playback = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(17, 1, 15), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(playback.state.playlistID, a.id)
        XCTAssertEqual(playback.elapsed, 3675)
        let position = try XCTUnwrap(ScheduledTrackPosition.resolve(durations: [20, 30], elapsed: playback.elapsed))
        XCTAssertEqual(position.index, 1); XCTAssertEqual(position.offset, 5)
        XCTAssertEqual(ScheduledTrackPosition.resolve(durations: [20, 30], elapsed: 50)?.index, 0)
        XCTAssertEqual(ScheduledTrackPosition.resolve(durations: [20, 30], elapsed: 20)?.index, 1)
        XCTAssertNil(ScheduledTrackPosition.resolve(durations: [0], elapsed: 2))
    }

    func testResumePlaylistSwitchIncludesOutgoingFadeAndPriority() throws {
        var (project, a, b) = fixture()
        project.calendarEntries = nil // Exercise legacy scheduling used during migration.
        a.start = .init(hour: 17); a.fades.fadeOut = 4
        b.start = .init(hour: 18); b.scheduleOrder = 2
        var losing = b.duplicated(order: 1); losing.start = b.start
        project.playlists = [a, losing, b]; project.video.initialPlaylistID = a.id
        let transition = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(18, 0, 2), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(transition.state.playlistID, a.id); XCTAssertEqual(transition.state.pendingID, b.id)
        XCTAssertEqual(transition.elapsed, 3602)
        let playing = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(18, 0, 10), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(playing.state.playlistID, b.id); XCTAssertEqual(playing.elapsed, 6)
        XCTAssertEqual(playing.state.phase, .playing)
        // A playlist scheduled at output start loses to the configured initial playlist.
        project.video.initialPlaylistID = b.id
        let start = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(17), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(start.state.playlistID, b.id)
    }

    func testResumeOvernightAndOutputWindowBoundaries() throws {
        var (project, a, b) = fixture()
        project.calendarEntries = nil // Exercise legacy scheduling used during migration.
        project.video.start = .init(hour: 22); project.video.end = .init(hour: 6)
        a.start = .init(hour: 22); b.start = .init(hour: 1)
        project.video.initialPlaylistID = a.id; project.playlists = [a, b]
        let midnight = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(0, 30), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(midnight.state.playlistID, a.id); XCTAssertEqual(midnight.elapsed, 9000)
        let later = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(2), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(later.state.playlistID, b.id); XCTAssertEqual(later.elapsed, 3598)
        XCTAssertNil(DailyScheduler.playback(project: project, lane: .video, at: date(6), now: 100, calendar: scheduleCalendar))
        XCTAssertNil(DailyScheduler.playback(project: project, lane: .video, at: date(12), now: 100, calendar: scheduleCalendar))
        project.video.end = project.video.start
        XCTAssertNil(DailyScheduler.playback(project: project, lane: .video, at: date(22), now: 100, calendar: scheduleCalendar))
    }

    func testResumeIndependentAudioAndIgnoredEmptyPlaylist() throws {
        var (project, a, _) = fixture()
        project.calendarEntries = nil // Exercise legacy scheduling used during migration.
        a.start = .init(hour: 17)
        var empty = Playlist(name: "Empty", lane: .video); empty.start = .init(hour: 18)
        var audio = Playlist(name: "Audio", lane: .audio); audio.start = .init(hour: 19)
        audio.tracks = [.init(path: "sound.wav", kind: .audio)]
        project.playlists = [a, empty, audio]; project.video.initialPlaylistID = a.id
        project.audio.start = .init(hour: 18); project.audio.initialPlaylistID = audio.id
        let video = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(18, 30), now: 100, calendar: scheduleCalendar))
        let sound = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .audio, at: date(18, 30), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(video.state.playlistID, a.id); XCTAssertEqual(video.elapsed, 5400)
        XCTAssertEqual(sound.state.playlistID, audio.id); XCTAssertEqual(sound.elapsed, 1800)
    }
}

extension PlayerCoreTests {

    func testResumePlaylistBeforeDefaultStartUntilNextEventAndDailyStop() throws {
        var (project, initial, early) = fixture()
        project.calendarEntries = nil // Exercise legacy scheduling used during migration.
        initial.start = .init(hour: 17); initial.fades = .init(fadeIn: 0, fadeOut: 0)
        early.name = "aa"; early.start = .init(hour: 13, minute: 58)
        early.fades = .init(fadeIn: 0, fadeOut: 0)
        project.playlists = [initial, early]; project.video.initialPlaylistID = initial.id
        XCTAssertNil(DailyScheduler.playback(project: project, lane: .video, at: date(13, 57), now: 100, calendar: scheduleCalendar))
        let resumed = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(14, 15), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(resumed.state.playlistID, early.id)
        XCTAssertEqual(resumed.elapsed, 17 * 60)
        let next = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(17, 1), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(next.state.playlistID, initial.id); XCTAssertEqual(next.elapsed, 60)
        XCTAssertNil(DailyScheduler.playback(project: project, lane: .video, at: date(22), now: 100, calendar: scheduleCalendar))
        XCTAssertNil(DailyScheduler.playback(project: project, lane: .video, at: date(23), now: 100, calendar: scheduleCalendar))
        early.start = .init(hour: 23); project.playlists[1] = early
        let afterStop = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(23, 1), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(afterStop.state.playlistID, early.id); XCTAssertEqual(afterStop.elapsed, 60)
        let midnight = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(0, 1), now: 100, calendar: scheduleCalendar))
        XCTAssertEqual(midnight.state.playlistID, early.id); XCTAssertEqual(midnight.elapsed, 3660)
    }
}
