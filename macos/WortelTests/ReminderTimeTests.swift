import XCTest

/// When a reminder goes off. Dates are wrong quietly: a reminder a day late,
/// or "next week" landing tomorrow, looks exactly like one that worked.
final class ReminderTimeTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")

    /// A moment in Amsterdam.
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // 2026-11-16 is a Monday.
    private var mondayAfternoon: Date { at(2026, 11, 16, 14, 30) }

    func testPresets() {
        let now = mondayAfternoon
        XCTAssertEqual(ReminderTime.date(for: .thirtyMinutes, now: now, calendar: calendar), at(2026, 11, 16, 15))
        XCTAssertEqual(ReminderTime.date(for: .oneHour, now: now, calendar: calendar), at(2026, 11, 16, 15, 30))
        XCTAssertEqual(ReminderTime.date(for: .threeHours, now: now, calendar: calendar), at(2026, 11, 16, 17, 30))
        XCTAssertEqual(ReminderTime.date(for: .tomorrow, now: now, calendar: calendar), at(2026, 11, 17, 9))
    }

    /// Slack's choices in Slack's words, with nine written as the Mac
    /// writes a time.
    func testPresetTitles() {
        XCTAssertEqual(ReminderTime.Preset.allCases.map { $0.title(locale: locale) },
                       ["In 30 Minutes", "In 1 Hour", "In 3 Hours", "Tomorrow at 09:00", "Monday at 09:00"])
        XCTAssertEqual(ReminderTime.Preset.tomorrow.title(locale: Locale(identifier: "en_US")),
                       "Tomorrow at 9:00\u{202F}AM")
    }

    /// The next Monday at nine: a week on from a Monday, even before nine,
    /// and tomorrow from a Sunday.
    func testNextWeekIsMondayMorning() {
        XCTAssertEqual(ReminderTime.date(for: .nextWeek, now: mondayAfternoon, calendar: calendar),
                       at(2026, 11, 23, 9))
        XCTAssertEqual(ReminderTime.date(for: .nextWeek, now: at(2026, 11, 16, 7), calendar: calendar),
                       at(2026, 11, 23, 9))
        XCTAssertEqual(ReminderTime.date(for: .nextWeek, now: at(2026, 11, 19, 12), calendar: calendar),
                       at(2026, 11, 23, 9))
        XCTAssertEqual(ReminderTime.date(for: .nextWeek, now: at(2026, 11, 22, 23), calendar: calendar),
                       at(2026, 11, 23, 9))
    }

    /// Nine in the morning is nine on the clock, across a change of clocks.
    func testTomorrowAcrossDaylightSaving() {
        // Summer time ends in the night of 24 to 25 October 2026.
        XCTAssertEqual(ReminderTime.date(for: .tomorrow, now: at(2026, 10, 24, 20), calendar: calendar),
                       at(2026, 10, 25, 9))
    }

    func testParse() {
        let now = mondayAfternoon
        func parse(_ text: String) -> Date? { ReminderTime.parse(text, now: now, calendar: calendar) }
        XCTAssertEqual(parse("20m"), at(2026, 11, 16, 14, 50))
        XCTAssertEqual(parse("1h"), at(2026, 11, 16, 15, 30))
        XCTAssertEqual(parse("1.5h"), at(2026, 11, 16, 16))
        XCTAssertEqual(parse("2d"), at(2026, 11, 18, 14, 30))
        XCTAssertEqual(parse("1w"), at(2026, 11, 23, 14, 30))
        XCTAssertEqual(parse("Tomorrow"), at(2026, 11, 17, 9))
        XCTAssertEqual(parse("next-week"), at(2026, 11, 23, 9))
        // A time still ahead is today; one already past is tomorrow.
        XCTAssertEqual(parse("15:00"), at(2026, 11, 16, 15))
        XCTAssertEqual(parse("9:05"), at(2026, 11, 17, 9, 5))
        XCTAssertEqual(parse("14:30"), at(2026, 11, 17, 14, 30))
        XCTAssertEqual(parse("3pm"), at(2026, 11, 16, 15))
        XCTAssertEqual(parse("3:15 PM"), at(2026, 11, 16, 15, 15))
        XCTAssertEqual(parse("9am"), at(2026, 11, 17, 9))
        XCTAssertEqual(parse("12am"), at(2026, 11, 17, 0))
        XCTAssertEqual(parse("12pm"), at(2026, 11, 17, 12))
        XCTAssertEqual(parse("in 2h"), at(2026, 11, 16, 16, 30))
    }

    /// A day, with or without a time. 2026-11-16 is a Monday.
    func testParseDays() {
        let now = mondayAfternoon
        func parse(_ text: String) -> Date? { ReminderTime.parse(text, now: now, calendar: calendar) }
        XCTAssertEqual(parse("today 17:00"), at(2026, 11, 16, 17))
        XCTAssertEqual(parse("tomorrow 3pm"), at(2026, 11, 17, 15))
        XCTAssertEqual(parse("fri"), at(2026, 11, 20, 9))
        XCTAssertEqual(parse("Friday 14:00"), at(2026, 11, 20, 14))
        XCTAssertEqual(parse("thurs 8:30am"), at(2026, 11, 19, 8, 30))
        // Today's Monday is still ahead at five, already gone at nine.
        XCTAssertEqual(parse("mon 17:00"), at(2026, 11, 16, 17))
        XCTAssertEqual(parse("monday"), at(2026, 11, 23, 9))
        XCTAssertEqual(parse("2026-12-03"), at(2026, 12, 3, 9))
        XCTAssertEqual(parse("2026-12-03 10:30"), at(2026, 12, 3, 10, 30))
    }

    func testParseRefuses() {
        for text in ["", "20", "soon", "0m", "-5m", "m", "25:00", "9:5", "12:60", "1h30", "2y", "400d", "inf h", "١h",
                     "13pm", "0am", "3", "fr", "today", "today 12:00", "friday 25:00", "friday soon",
                     "2026-02-30", "2026-11-01", "2028-01-01", "fri 9:00 extra"] {
            XCTAssertNil(ReminderTime.parse(text, now: mondayAfternoon, calendar: calendar), text)
        }
    }

    func testDescribe() {
        let now = mondayAfternoon
        func describe(_ date: Date) -> String {
            ReminderTime.describe(date, now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(describe(at(2026, 11, 16, 15)), "today at 15:00")
        XCTAssertEqual(describe(at(2026, 11, 17, 9)), "tomorrow at 09:00")
        XCTAssertEqual(describe(at(2026, 11, 20, 9)), "Friday at 09:00")
        XCTAssertEqual(describe(at(2026, 11, 23, 9)), "23 Nov at 09:00")
        XCTAssertEqual(describe(at(2027, 1, 4, 9)), "4 Jan 2027 at 09:00")
    }

    /// Short, for a line shared with a branch: the time today, the day
    /// and the time this week, the date and the time after that.
    func testBrief() {
        let now = mondayAfternoon
        func brief(_ date: Date) -> String {
            ReminderTime.brief(date, now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(brief(at(2026, 11, 16, 23, 17)), "23:17")
        XCTAssertEqual(brief(at(2026, 11, 17, 9)), "Tue 09:00")
        XCTAssertEqual(brief(at(2026, 11, 22, 9)), "Sun 09:00")
        XCTAssertEqual(brief(at(2026, 11, 23, 9)), "23 Nov 09:00")
        XCTAssertEqual(brief(at(2027, 1, 4, 9)), "4 Jan 09:00")
    }

    /// Every preset is ahead of now, so none can go off the moment it's set.
    func testPresetsAreAhead() {
        for preset in ReminderTime.Preset.allCases {
            for now in [mondayAfternoon, at(2026, 11, 22, 23, 59), at(2026, 11, 16, 8, 59)] {
                XCTAssertGreaterThan(ReminderTime.date(for: preset, now: now, calendar: calendar), now)
            }
        }
    }
}
