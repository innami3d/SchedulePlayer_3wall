import XCTest
@testable import PlayerCore

final class CalendarSchedulerTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func fixture() -> PlayerProject {
        var project = PlayerProject()
        var video = Playlist(name: "映像", lane: .video)
        video.tracks = [.init(path: "test.png", kind: .image)]
        var audio = Playlist(name: "音声", lane: .audio)
        audio.tracks = [.init(path: "test.wav", kind: .audio)]
        project.playlists = [video, audio]
        return project
    }
    func testDateSpecificBoundariesAndIndependentLanes() throws {
        var project = fixture()
        let video = project.playlists[0].id, audio = project.playlists[1].id
        project.calendarEntries = [
            .init(playlistID: video, start: date(30, 10), end: date(30, 11)),
            .init(playlistID: audio, start: date(30, 10, 30), end: date(30, 12))
        ]
        XCTAssertNil(CalendarScheduler.active(project: project, lane: .video, at: date(31, 10), calendar: calendar))
        let events = DailyScheduler.events(project: project, after: date(30, 9), through: date(30, 12), calendar: calendar)
        XCTAssertEqual(events.map(\.action), [.playlist(video), .playlist(audio), .endOutput, .endOutput])
        XCTAssertEqual(events.map(\.lane), [.video, .audio, .video, .audio])
        XCTAssertTrue(DailyScheduler.events(project: project, after: date(30, 12), through: date(30, 12), calendar: calendar).isEmpty)
        XCTAssertEqual(try PlayerProject.decode(project.encoded()), project)
    }
    func testOverlapReturnsToEarlierEntryAndRecoversPosition() throws {
        var project = fixture()
        var other = project.playlists[0].duplicated(order: 1)
        other.name = "割り込み"; project.playlists.append(other)
        let first = CalendarEntry(playlistID: project.playlists[0].id, start: date(30, 10), end: date(30, 14))
        let next = CalendarEntry(playlistID: other.id, start: date(30, 11), end: date(30, 12))
        project.calendarEntries = [first, next]
        XCTAssertEqual(CalendarScheduler.active(project: project, lane: .video, at: date(30, 11, 30), calendar: calendar)?.entry.id, next.id)
        XCTAssertEqual(CalendarScheduler.active(project: project, lane: .video, at: date(30, 12), calendar: calendar)?.entry.id, first.id)
        let playback = try XCTUnwrap(DailyScheduler.playback(project: project, lane: .video, at: date(30, 12, 30), now: 100, calendar: calendar))
        XCTAssertEqual(playback.state.playlistID, first.playlistID)
        XCTAssertEqual(playback.elapsed, 9000)
        let boundary = DailyScheduler.events(project: project, after: date(30, 11, 59), through: date(30, 12), calendar: calendar)
        XCTAssertEqual(boundary.map(\.action), [.playlist(first.playlistID)])
    }
    func testOvernightDailyWeeklyAndFadeTail() throws {
        var project = fixture()
        let entry = CalendarEntry(playlistID: project.playlists[0].id, start: date(29, 22), end: date(30, 6), fades: .init(fadeIn: 3, fadeOut: 10), repetition: .daily)
        project.calendarEntries = [entry]
        XCTAssertNotNil(CalendarScheduler.active(project: project, lane: .video, at: date(31, 2), calendar: calendar))
        XCTAssertNil(CalendarScheduler.active(project: project, lane: .video, at: date(31, 6), calendar: calendar))
        XCTAssertNotNil(DailyScheduler.playback(project: project, lane: .video, at: date(31, 6).addingTimeInterval(5), now: 100, calendar: calendar))
        XCTAssertNil(DailyScheduler.playback(project: project, lane: .video, at: date(31, 6).addingTimeInterval(10), now: 100, calendar: calendar))
        var weekly = entry; weekly.repetition = .weekly
        XCTAssertNil(weekly.occurrence(on: date(30, 22), calendar: calendar))
        XCTAssertNotNil(weekly.occurrence(on: calendar.date(byAdding: .day, value: 7, to: date(29, 22))!, calendar: calendar))
    }
    func testLegacySettingsMigrateToDailyCalendarAndRemainEditable() throws {
        var project = fixture()
        project.video.initialPlaylistID = project.playlists[0].id
        project.playlists[0].start = .init(hour: 18)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: project.encoded()) as? [String: Any])
        json.removeValue(forKey: "calendarEntries")
        let migrated = try PlayerProject.decode(JSONSerialization.data(withJSONObject: json))
        let entries = try XCTUnwrap(migrated.calendarEntries)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.allSatisfy { $0.repetition == .daily })
        let today = Calendar.current.startOfDay(for: Date())
        let at19 = TimeOfDay(hour: 19).date(on: today)!
        XCTAssertEqual(CalendarScheduler.active(project: migrated, lane: .video, at: at19)?.entry.playlistID, project.playlists[0].id)
        XCTAssertEqual(try PlayerProject.decode(migrated.encoded()), migrated)
        var invalid = migrated
        invalid.calendarEntries?[0].end = entries[0].start
        XCTAssertThrowsError(try invalid.validate())
    }
    func testEmptyCalendarDoesNotUseHiddenLegacyTimes() {
        var project = fixture()
        project.video.initialPlaylistID = project.playlists[0].id
        XCTAssertTrue(DailyScheduler.events(project: project, after: date(30, 16), through: date(30, 23), calendar: calendar).isEmpty)
        XCTAssertNil(DailyScheduler.playback(project: project, lane: .video, at: date(30, 18), now: 100, calendar: calendar))
    }
}

extension CalendarSchedulerTests {
    func testEditOneOccurrencePreservesPastFutureAndRoundTrip() throws {
        var project = fixture()
        let series = CalendarEntry(playlistID: project.playlists[0].id, start: date(25, 10), end: date(25, 11), repetition: .daily)
        project.calendarEntries = [series]
        var changed = series; changed.start = date(28, 14); changed.end = date(28, 16)
        project.editCalendarEntry(id: series.id, occurrenceStart: date(28, 10), replacement: changed, scope: .occurrence, calendar: calendar)
        let entries = try XCTUnwrap(project.calendarEntries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].occurrence(on: date(28, 10), calendar: calendar))
        XCTAssertNotNil(entries[0].occurrence(on: date(27, 10), calendar: calendar))
        XCTAssertNotNil(entries[0].occurrence(on: date(29, 10), calendar: calendar))
        let exception = entries[1]
        XCTAssertEqual(exception.repetition, .once)
        XCTAssertEqual(exception.originalStart, date(28, 10))
        XCTAssertEqual(exception.parentSeriesID, series.id)
        XCTAssertEqual(exception.start, date(28, 14))
        XCTAssertEqual(try PlayerProject.decode(project.encoded()), project)
        // Re-editing the exception replaces it, and deleting it never restores the original.
        changed.start = date(28, 15); changed.end = date(28, 17)
        project.editCalendarEntry(id: exception.id, occurrenceStart: exception.start, replacement: changed, scope: .occurrence, calendar: calendar)
        XCTAssertEqual(project.calendarEntries?.count, 2)
        project.editCalendarEntry(id: exception.id, occurrenceStart: changed.start, replacement: nil, scope: .occurrence, calendar: calendar)
        XCTAssertEqual(project.calendarEntries?.count, 1)
        XCTAssertNil(project.calendarEntries?[0].occurrence(on: date(28, 10), calendar: calendar))
    }
    func testEditFollowingSplitsWithoutChangingEarlierOccurrences() throws {
        var project = fixture()
        let series = CalendarEntry(playlistID: project.playlists[0].id, start: date(25, 22), end: date(26, 6), repetition: .daily)
        project.calendarEntries = [series]
        var changed = series; changed.start = date(28, 23); changed.end = date(29, 7)
        project.editCalendarEntry(id: series.id, occurrenceStart: date(28, 22), replacement: changed, scope: .following, calendar: calendar)
        let entries = try XCTUnwrap(project.calendarEntries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].repeatUntil, date(28, 22))
        XCTAssertNotNil(entries[0].occurrence(on: date(27, 22), calendar: calendar))
        XCTAssertNil(entries[0].occurrence(on: date(28, 22), calendar: calendar))
        XCTAssertEqual(entries[1].occurrence(on: date(29, 22), calendar: calendar)?.start, date(29, 23))
        XCTAssertEqual(entries[1].occurrence(on: date(29, 22), calendar: calendar)?.end, date(30, 7))
        XCTAssertEqual(try PlayerProject.decode(project.encoded()), project)
        project.editCalendarEntry(id: entries[1].id, occurrenceStart: date(30, 23), replacement: nil, scope: .following, calendar: calendar)
        XCTAssertNotNil(project.calendarEntries?[1].occurrence(on: date(29, 23), calendar: calendar))
        XCTAssertNil(project.calendarEntries?[1].occurrence(on: date(30, 23), calendar: calendar))
    }
    func testEditAllFromLaterOccurrenceKeepsOriginalSeriesAnchorAndOvernightLength() throws {
        var project = fixture()
        let series = CalendarEntry(playlistID: project.playlists[0].id, start: date(25, 22), end: date(26, 6), repetition: .daily)
        project.calendarEntries = [series]
        var changed = series; changed.start = date(29, 23); changed.end = date(30, 7)
        changed.fades.fadeIn = 8
        project.editCalendarEntry(id: series.id, occurrenceStart: date(29, 22), replacement: changed, scope: .all, calendar: calendar)
        let updated = try XCTUnwrap(project.calendarEntries?.first)
        XCTAssertEqual(updated.id, series.id)
        XCTAssertEqual(updated.start, date(25, 23)); XCTAssertEqual(updated.end, date(26, 7))
        XCTAssertEqual(updated.fades.fadeIn, 8)
        XCTAssertEqual(updated.occurrence(on: date(26, 22), calendar: calendar)?.start, date(26, 23))
        project.editCalendarEntry(id: series.id, occurrenceStart: date(29, 23), replacement: nil, scope: .all, calendar: calendar)
        XCTAssertEqual(project.calendarEntries, [])
    }
    func testFutureSplitOfExceptionKeepsDeletedDatesAndRemovesFutureOverrides() throws {
        var project = fixture()
        let series = CalendarEntry(playlistID: project.playlists[0].id, start: date(25, 10), end: date(25, 11), repetition: .daily)
        project.calendarEntries = [series]
        project.editCalendarEntry(id: series.id, occurrenceStart: date(30, 10), replacement: nil, scope: .occurrence, calendar: calendar)
        var changed = series; changed.start = date(28, 14); changed.end = date(28, 15)
        project.editCalendarEntry(id: series.id, occurrenceStart: date(28, 10), replacement: changed, scope: .occurrence, calendar: calendar)
        let exception = try XCTUnwrap(project.calendarEntries?.last)
        changed.start = date(28, 16); changed.end = date(28, 17)
        project.editCalendarEntry(id: exception.id, occurrenceStart: exception.start, replacement: changed, scope: .following, calendar: calendar)
        let entries = try XCTUnwrap(project.calendarEntries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].occurrence(on: date(28, 10), calendar: calendar))
        XCTAssertEqual(entries[1].occurrence(on: date(29, 10), calendar: calendar)?.start, date(29, 16))
        XCTAssertNil(entries[1].occurrence(on: date(30, 10), calendar: calendar))
        XCTAssertEqual(try PlayerProject.decode(project.encoded()), project)
    }
    func testWeeklyScopeEditsAndBackwardCompatibleMetadata() throws {
        var project = fixture()
        let series = CalendarEntry(playlistID: project.playlists[0].id, start: date(18, 10), end: date(18, 11), repetition: .weekly)
        project.calendarEntries = [series]
        project.editCalendarEntry(id: series.id, occurrenceStart: date(25, 10), replacement: nil, scope: .occurrence, calendar: calendar)
        XCTAssertNotNil(project.calendarEntries?[0].occurrence(on: date(18, 10), calendar: calendar))
        XCTAssertNil(project.calendarEntries?[0].occurrence(on: date(25, 10), calendar: calendar))
        let november = calendar.date(byAdding: .day, value: 7, to: date(25, 10))!
        XCTAssertNotNil(project.calendarEntries?[0].occurrence(on: november, calendar: calendar))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: project.encoded()) as? [String: Any])
        var entries = try XCTUnwrap(legacy["calendarEntries"] as? [[String: Any]])
        for key in ["repeatUntil", "excludedStarts", "parentSeriesID", "originalStart"] { entries[0].removeValue(forKey: key) }
        legacy["calendarEntries"] = entries
        let restored = try PlayerProject.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNotNil(restored.calendarEntries?[0].occurrence(on: date(25, 10), calendar: calendar))
    }
}

extension CalendarSchedulerTests {
    func testResizeBothEdgesSnapsAndKeepsOppositeEndpointFixed() {
        let entry = CalendarEntry(playlistID: UUID(), start: date(25, 10), end: date(25, 11))
        let interval = DateInterval(start: entry.start, end: entry.end)
        let longer = entry.resized(occurrence: interval, edge: .end, minutes: 38, calendar: calendar)
        XCTAssertEqual(longer.start, entry.start)
        XCTAssertEqual(longer.end, date(25, 11, 45))
        let earlier = entry.resized(occurrence: interval, edge: .start, minutes: -22, calendar: calendar)
        XCTAssertEqual(earlier.start, date(25, 9, 45))
        XCTAssertEqual(earlier.end, entry.end)
        let shorter = entry.resized(occurrence: interval, edge: .start, minutes: 16, calendar: calendar)
        XCTAssertEqual(shorter.start, date(25, 10, 15))
        XCTAssertEqual(shorter.end, entry.end)
    }
    func testResizeCannotInvertOrExceedMaximumAndSupportsMidnight() {
        let entry = CalendarEntry(playlistID: UUID(), start: date(25, 23), end: date(26, 0))
        let interval = DateInterval(start: entry.start, end: entry.end)
        XCTAssertEqual(entry.resized(occurrence: interval, edge: .start, minutes: 999, calendar: calendar).start, date(25, 23, 45))
        XCTAssertEqual(entry.resized(occurrence: interval, edge: .end, minutes: -999, calendar: calendar).end, date(25, 23, 15))
        XCTAssertEqual(entry.resized(occurrence: interval, edge: .end, minutes: 60, calendar: calendar).end, date(26, 1))
        XCTAssertEqual(entry.resized(occurrence: interval, edge: .end, minutes: 99_999, calendar: calendar).end.timeIntervalSince(entry.start), 7 * 86_400)
        XCTAssertEqual(entry.end.timeIntervalSince(entry.resized(occurrence: interval, edge: .start, minutes: -99_999, calendar: calendar).start), 7 * 86_400)
    }
    func testResizeLaterRecurringOccurrenceAppliesChosenScope() throws {
        var project = fixture()
        let series = CalendarEntry(playlistID: project.playlists[0].id, start: date(25, 10), end: date(25, 11), repetition: .daily)
        let occurrence = DateInterval(start: date(28, 10), end: date(28, 11))
        let changed = series.resized(occurrence: occurrence, edge: .end, minutes: 90, calendar: calendar)
        for scope in CalendarEditScope.allCases {
            project.calendarEntries = [series]
            project.editCalendarEntry(id: series.id, occurrenceStart: occurrence.start, replacement: changed, scope: scope, calendar: calendar)
            let on27 = CalendarScheduler.active(project: project, lane: .video, at: date(27, 11, 30), calendar: calendar)
            let on29 = CalendarScheduler.active(project: project, lane: .video, at: date(29, 11, 30), calendar: calendar)
            XCTAssertEqual(on27 != nil, scope == .all)
            XCTAssertEqual(on29 != nil, scope != .occurrence)
            XCTAssertNotNil(CalendarScheduler.active(project: project, lane: .video, at: date(28, 12), calendar: calendar))
            XCTAssertEqual(try PlayerProject.decode(project.encoded()), project)
        }
        // Changing the upper edge of all occurrences keeps every end at 11:00.
        project.calendarEntries = [series]
        let earlier = series.resized(occurrence: occurrence, edge: .start, minutes: -30, calendar: calendar)
        project.editCalendarEntry(id: series.id, occurrenceStart: occurrence.start, replacement: earlier, scope: .all, calendar: calendar)
        XCTAssertEqual(project.calendarEntries?.first?.start, date(25, 9, 30))
        XCTAssertEqual(project.calendarEntries?.first?.end, date(25, 11))
    }
}

extension CalendarSchedulerTests {
    func testCalendarPlaybackDoesNotMultiplyHiddenPlaylistFade() throws {
        var project = fixture()
        project.playlists[0].fades = .init(fadeIn: 60, fadeOut: 60)
        let entry = CalendarEntry(playlistID: project.playlists[0].id, start: date(25, 10), end: date(25, 11), fades: .init(fadeIn: 0, fadeOut: 0))
        project.calendarEntries = [entry]
        let playback = try XCTUnwrap(CalendarScheduler.playback(project: project, lane: .video, at: date(25, 10), now: 100, calendar: calendar))
        XCTAssertEqual(playback.state.phase, .playing)
        XCTAssertEqual(playback.state.envelope.value(at: 100), 1)
        var manual = LanePlayback()
        manual.request(project.playlists[0], project: project, now: 100, usePlaylistFades: false)
        XCTAssertEqual(manual.phase, .playing)
        var next = project.playlists[0].duplicated(order: 2)
        next.fades = .init(fadeIn: 60, fadeOut: 60)
        project.playlists.append(next)
        manual.request(next, project: project, now: 101, usePlaylistFades: false)
        XCTAssertEqual(manual.playlistID, next.id)
        XCTAssertEqual(manual.phase, .playing)
    }
}

extension CalendarSchedulerTests {
    func testVerticalMovePreservesDurationSnapsBothDirectionsAndClampsAtDayBounds() {
        let entry = CalendarEntry(playlistID: UUID(), start: date(25, 10), end: date(25, 11, 30))
        let interval = DateInterval(start: entry.start, end: entry.end)
        let down = entry.moved(occurrence: interval, minutes: 38, calendar: calendar)
        XCTAssertEqual(down.start, date(25, 10, 45)); XCTAssertEqual(down.end, date(25, 12, 15))
        let up = entry.moved(occurrence: interval, minutes: -22, calendar: calendar)
        XCTAssertEqual(up.start, date(25, 9, 45)); XCTAssertEqual(up.end, date(25, 11, 15))
        let midnight = entry.moved(occurrence: interval, minutes: -999, calendar: calendar)
        XCTAssertEqual(midnight.start, date(25, 0)); XCTAssertEqual(midnight.end, date(25, 1, 30))
        let overnight = entry.moved(occurrence: interval, minutes: 999, calendar: calendar)
        XCTAssertEqual(overnight.start, date(25, 23, 45)); XCTAssertEqual(overnight.end, date(26, 1, 15))
        XCTAssertEqual(overnight.end.timeIntervalSince(overnight.start), interval.duration)
    }
    func testMovingLaterRecurringOccurrenceChangesOnlyChosenScope() throws {
        var project = fixture()
        let series = CalendarEntry(playlistID: project.playlists[0].id, start: date(25, 10), end: date(25, 11), repetition: .daily)
        let interval = DateInterval(start: date(28, 10), end: date(28, 11))
        let moved = series.moved(occurrence: interval, minutes: 90, calendar: calendar)
        for scope in CalendarEditScope.allCases {
            project.calendarEntries = [series]
            project.editCalendarEntry(id: series.id, occurrenceStart: interval.start, replacement: moved, scope: scope, calendar: calendar)
            XCTAssertNotNil(CalendarScheduler.active(project: project, lane: .video, at: date(28, 12), calendar: calendar))
            XCTAssertEqual(CalendarScheduler.active(project: project, lane: .video, at: date(27, 12), calendar: calendar) != nil, scope == .all)
            XCTAssertEqual(CalendarScheduler.active(project: project, lane: .video, at: date(29, 12), calendar: calendar) != nil, scope != .occurrence)
            XCTAssertEqual(try PlayerProject.decode(project.encoded()), project)
        }
    }
}
