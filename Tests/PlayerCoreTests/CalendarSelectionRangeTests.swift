import XCTest
@testable import PlayerCore

final class CalendarSelectionRangeTests: XCTestCase {
    func testDownwardUpwardAndShortSelection() {
        let down = CalendarSelectionRange(anchorMinute: 610, currentMinute: 678)
        XCTAssertEqual(down.startMinute, 600); XCTAssertEqual(down.endMinute, 675)
        XCTAssertEqual(down.timeLabel, "10:00–11:15")
        let up = CalendarSelectionRange(anchorMinute: 678, currentMinute: 610)
        XCTAssertEqual(up.startMinute, 615); XCTAssertEqual(up.endMinute, 675)
        let short = CalendarSelectionRange(anchorMinute: 610, currentMinute: 612)
        XCTAssertEqual(short.startMinute, 600); XCTAssertEqual(short.endMinute, 615)
    }
    func testClampsToDayAndCreatesMidnightEndOnNextDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let late = CalendarSelectionRange(anchorMinute: 1439, currentMinute: 2000)
        XCTAssertEqual(late.startMinute, 1425); XCTAssertEqual(late.endMinute, 1440)
        let interval = try XCTUnwrap(late.interval(on: day, calendar: calendar))
        XCTAssertEqual(interval.duration, 900)
        XCTAssertEqual(interval.end, calendar.date(byAdding: .day, value: 1, to: day))
        let full = CalendarSelectionRange(anchorMinute: -200, currentMinute: 2000)
        XCTAssertEqual(full.startMinute, 0); XCTAssertEqual(full.endMinute, 1440)
    }
    func testSelectionUsesLocalClockAcrossDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let range = CalendarSelectionRange(anchorMinute: 0, currentMinute: 1440)
        let interval = try XCTUnwrap(range.interval(on: day, calendar: calendar))
        XCTAssertEqual(interval.duration, 25 * 3600)
        XCTAssertEqual(calendar.component(.hour, from: interval.end), 0)
        XCTAssertEqual(calendar.component(.day, from: interval.end), 2)
    }
}
