import Foundation

/// What Remind Me ▸ Custom… lays out: a month as a grid of days, and the times
/// a day still has to offer.
///
/// Pure, with the calendar and `now` handed in, as `ReminderTime` is: a grid
/// that starts a column late, or a time offered that has already gone, is
/// wrong quietly.
enum ReminderCalendar {
    /// Times are offered on the half hour, as Slack offers them.
    static let step = 30

    /// The month's days in six rows of seven, starting on the calendar's
    /// first weekday; nil where a row runs outside the month. Always six
    /// rows, so the dialog keeps its height from month to month.
    static func weeks(of month: Date, calendar: Calendar) -> [[Date?]] {
        guard let first = calendar.dateInterval(of: .month, for: month)?.start,
              let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return (0..<6).map { row in
            (0..<7).map { column in
                let index = row * 7 + column - lead
                guard (0..<count).contains(index) else { return nil }
                return calendar.date(byAdding: .day, value: index, to: first)
            }
        }
    }

    /// The weekdays' initials, in the grid's column order.
    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    /// The times on offer on a day, as minutes past midnight: each half hour
    /// still ahead of `now` and within `ReminderTime.longest`. `extra` joins
    /// them: a reminder already set for 10:35 has to be able to stay there.
    static func clocks(on day: Date, now: Date, extra: Int? = nil, calendar: Calendar) -> [Int] {
        var all = Array(stride(from: 0, to: 24 * 60, by: step))
        if let extra, !all.contains(extra) {
            all.append(extra)
            all.sort()
        }
        return all.filter { clock in
            guard let moment = moment(on: day, clock: clock, calendar: calendar) else { return false }
            return moment > now && moment.timeIntervalSince(now) <= ReminderTime.longest
        }
    }

    /// Whether a day has any time left to offer. The same answer as
    /// `clocks(on:)` being non-empty, without building them for every cell
    /// of the grid.
    static func isOpen(_ day: Date, now: Date, extra: Int? = nil, calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: day)
        guard start.timeIntervalSince(now) <= ReminderTime.longest else { return false }
        let last = max(24 * 60 - step, extra ?? 0)
        if let end = moment(on: start, clock: last, calendar: calendar) { return end > now }
        return !clocks(on: start, now: now, extra: extra, calendar: calendar).isEmpty
    }

    /// A time on a day. Nil for a time the day doesn't have: the hour that
    /// is skipped when the clocks go forward.
    static func moment(on day: Date, clock: Int, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: day)
        guard let moment = calendar.date(bySettingHour: clock / 60, minute: clock % 60, second: 0, of: start),
              calendar.isDate(moment, inSameDayAs: start),
              clock == self.clock(of: moment, calendar: calendar) else { return nil }
        return moment
    }

    /// A moment's time of day, as minutes past midnight.
    static func clock(of date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}
