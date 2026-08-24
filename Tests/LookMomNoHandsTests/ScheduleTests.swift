import XCTest
@testable import LookMomNoHands

final class ScheduleTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Denver")!
        return c
    }

    /// Monday 2026-08-24 (weekday 2) at the given time.
    private func monday(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: hour, minute: minute))!
    }

    private let nineWeekdays = ProcedureSchedule(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6])

    func testFiresAtItsSlot() {
        XCTAssertTrue(nineWeekdays.isDue(now: monday(9, 0), lastFired: nil, calendar: calendar))
        XCTAssertTrue(nineWeekdays.isDue(now: monday(9, 10), lastFired: nil, calendar: calendar))
    }

    func testNotBeforeTheSlot() {
        XCTAssertFalse(nineWeekdays.isDue(now: monday(8, 59), lastFired: nil, calendar: calendar))
    }

    func testMissedByMoreThanGraceIsSkippedNotLate() {
        // Lid opened at 9:31 — a half-hour-late 9:00 routine is fine, later is a surprise.
        XCTAssertTrue(nineWeekdays.isDue(now: monday(9, 30), lastFired: nil, calendar: calendar))
        XCTAssertFalse(nineWeekdays.isDue(now: monday(9, 31), lastFired: nil, calendar: calendar))
    }

    func testWrongWeekdayNeverFires() {
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 9, minute: 5))!
        XCTAssertFalse(nineWeekdays.isDue(now: sunday, lastFired: nil, calendar: calendar))
    }

    func testOneFirePerSlot() {
        let firedAtSlot = monday(9, 0)
        XCTAssertFalse(nineWeekdays.isDue(now: monday(9, 10), lastFired: firedAtSlot, calendar: calendar))
    }

    func testYesterdaysFireDoesNotBlockToday() {
        let friday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 9, minute: 0))!
        XCTAssertTrue(nineWeekdays.isDue(now: monday(9, 5), lastFired: friday, calendar: calendar))
    }

    func testOldProcedureJSONStillDecodes() throws {
        // Records written before schedule/lastFiredAt existed must load unchanged.
        let old = #"[{"id":"x","name":"Old","triggers":["go"],"steps":"do it","createdAt":700000000}]"#
        let decoded = try JSONDecoder().decode([Procedure].self, from: Data(old.utf8))
        XCTAssertEqual(decoded.first?.name, "Old")
        XCTAssertNil(decoded.first?.schedule)
        XCTAssertNil(decoded.first?.lastFiredAt)
    }

    func testLabelReadsBack() {
        XCTAssertEqual(nineWeekdays.label, "9:00 weekdays")
        XCTAssertEqual(ProcedureSchedule(hour: 18, minute: 30, weekdays: [1, 2, 3, 4, 5, 6, 7]).label, "18:30 every day")
    }
}
