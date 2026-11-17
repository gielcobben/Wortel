import XCTest

/// The month Custom… draws and the times it offers. A grid that starts a
/// column out, or a time on offer that has already gone, looks fine and
/// sets the wrong reminder.
final class ReminderCalendarTests: XCTestCase {
    /// Amsterdam, weeks starting on Monday.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        return calendar
    }()

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func days(_ weeks: [[Date?]]) -> [[Int?]] {
        weeks.map { $0.map { $0.map { calendar.component(.day, from: $0) } } }
    }

    /// November 2026 starts on a Sunday: alone at the end of the first row
    /// when weeks start on Monday, and first in it when they start on Sunday.
    func testWeeks() {
        let weeks = days(ReminderCalendar.weeks(of: at(2026, 11, 16), calendar: calendar))
        XCTAssertEqual(weeks.count, 6)
        XCTAssertEqual(weeks[0], [nil, nil, nil, nil, nil, nil, 1])
        XCTAssertEqual(weeks[1], [2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(weeks[5], [30, nil, nil, nil, nil, nil, nil])

        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let american = days(ReminderCalendar.weeks(of: at(2026, 11, 16), calendar: sundayFirst))
        XCTAssertEqual(american[0], [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(american[4], [29, 30, nil, nil, nil, nil, nil])
        XCTAssertEqual(american[5], Array(repeating: nil, count: 7))
    }

    /// Every month of a year has all its days, once, in order.
    func testWeeksHoldEveryDay() {
        for month in 1...12 {
            let weeks = ReminderCalendar.weeks(of: at(2027, month, 10), calendar: calendar)
            let found = weeks.flatMap { $0 }.compactMap { $0 }
            let count = calendar.range(of: .day, in: .month, for: at(2027, month, 10))!.count
            XCTAssertEqual(found.map { calendar.component(.day, from: $0) }, Array(1...count), "month \(month)")
            for week in weeks {
                for (column, day) in week.enumerated() {
                    guard let day else { continue }
                    XCTAssertEqual((calendar.component(.weekday, from: day) - 2 + 7) % 7, column)
                }
            }
        }
    }

    func testWeekdaySymbols() {
        XCTAssertEqual(ReminderCalendar.weekdaySymbols(calendar: calendar), ["M", "T", "W", "T", "F", "S", "S"])
    }

    /// Today offers only what's left of it; another day offers all of it.
    func testClocks() {
        let now = at(2026, 11, 16, 21, 50)
        XCTAssertEqual(ReminderCalendar.clocks(on: now, now: now, calendar: calendar),
                       [22 * 60, 22 * 60 + 30, 23 * 60, 23 * 60 + 30])
        let tomorrow = ReminderCalendar.clocks(on: at(2026, 11, 17), now: now, calendar: calendar)
        XCTAssertEqual(tomorrow.count, 48)
        XCTAssertEqual(tomorrow.first, 0)
        XCTAssertEqual(ReminderCalendar.clocks(on: at(2026, 11, 15), now: now, calendar: calendar), [])
        // On the half hour exactly, that half hour has gone.
        XCTAssertEqual(ReminderCalendar.clocks(on: now, now: at(2026, 11, 16, 23), calendar: calendar),
                       [23 * 60 + 30])
    }

    /// A reminder set for 10:35 can stay there: its time joins the list, in
    /// its place, on days where it's still ahead.
    func testExtraClock() {
        let now = at(2026, 11, 16, 21, 50)
        let extra = 10 * 60 + 35
        XCTAssertFalse(ReminderCalendar.clocks(on: now, now: now, extra: extra, calendar: calendar).contains(extra))
        let tomorrow = ReminderCalendar.clocks(on: at(2026, 11, 17), now: now, extra: extra, calendar: calendar)
        XCTAssertEqual(tomorrow.count, 49)
        XCTAssertEqual(tomorrow.firstIndex(of: extra), 22)
    }

    /// The hour skipped when the clocks go forward isn't offered, and no
    /// time is offered beyond the furthest a reminder can be set.
    func testClocksSkipWhatTheDayLacks() {
        // Summer time starts on 28 March 2027: 02:00 becomes 03:00.
        let spring = ReminderCalendar.clocks(on: at(2027, 3, 28), now: at(2026, 11, 16), calendar: calendar)
        XCTAssertEqual(spring.count, 46)
        XCTAssertFalse(spring.contains(2 * 60))
        XCTAssertFalse(spring.contains(2 * 60 + 30))
        XCTAssertNil(ReminderCalendar.moment(on: at(2027, 3, 28), clock: 2 * 60 + 30, calendar: calendar))
        XCTAssertEqual(ReminderCalendar.moment(on: at(2027, 3, 28, 15), clock: 9 * 60, calendar: calendar),
                       at(2027, 3, 28, 9))

        let now = at(2026, 11, 16, 12)
        let last = now.addingTimeInterval(ReminderTime.longest)
        let offered = ReminderCalendar.clocks(on: last, now: now, calendar: calendar)
        XCTAssertFalse(offered.isEmpty)
        for clock in offered {
            XCTAssertLessThanOrEqual(ReminderCalendar.moment(on: last, clock: clock, calendar: calendar)!, last)
        }
    }

    /// A day is open exactly when it has a time to offer.
    func testIsOpenAgreesWithClocks() {
        let now = at(2026, 11, 16, 23, 40)
        for offset in -3...370 {
            let day = calendar.date(byAdding: .day, value: offset, to: at(2026, 11, 16))!
            for extra in [nil, 23 * 60 + 45] as [Int?] {
                XCTAssertEqual(ReminderCalendar.isOpen(day, now: now, extra: extra, calendar: calendar),
                               !ReminderCalendar.clocks(on: day, now: now, extra: extra, calendar: calendar).isEmpty,
                               "day \(offset), extra \(String(describing: extra))")
            }
        }
        // Past the last half hour, today is done.
        XCTAssertFalse(ReminderCalendar.isOpen(now, now: now, calendar: calendar))
        XCTAssertTrue(ReminderCalendar.isOpen(now, now: now, extra: 23 * 60 + 45, calendar: calendar))
    }
}
