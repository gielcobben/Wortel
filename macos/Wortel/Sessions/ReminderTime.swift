import Foundation

/// When a session's reminder comes due: Slack's "Remind me about this"
/// choices, what `wortel remind` takes, and how a pending one is described.
///
/// Pure, and resolved against a `now` and a calendar handed in, so the tests
/// can stand on a Sunday night in Amsterdam. Compiled into the `wortel` command
/// too: it turns what was typed into a moment before sending it, so the app and
/// the command can never disagree about what "tomorrow" means. Both run on the
/// same Mac, in the same time zone.
enum ReminderTime {
    /// The menu's choices: Slack's, in Slack's order and words. Custom… is
    /// the menu's own.
    enum Preset: CaseIterable {
        case thirtyMinutes, oneHour, threeHours, tomorrow, nextWeek

        var title: String { title(locale: .current) }

        /// The two mornings say their time, written the way the Mac writes
        /// one: "Tomorrow at 09:00", or "Tomorrow at 9:00 AM".
        func title(locale: Locale) -> String {
            switch self {
            case .thirtyMinutes: return "In 30 Minutes"
            case .oneHour: return "In 1 Hour"
            case .threeHours: return "In 3 Hours"
            case .tomorrow: return "Tomorrow at \(ReminderTime.morning(locale: locale))"
            case .nextWeek: return "Monday at \(ReminderTime.morning(locale: locale))"
            }
        }
    }

    /// Nine in the morning, in the locale's short time.
    static func morning(locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let nine = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: morningHour)) ?? Date()
        return formatter.string(from: nine)
    }

    /// "Tomorrow" and "next week" mean the start of a working day, as in Slack.
    static let morningHour = 9

    /// The furthest ahead a reminder can be set. Further is a typo.
    static let longest: TimeInterval = 366 * 24 * 3600

    static func date(for preset: Preset, now: Date, calendar: Calendar = .current) -> Date {
        switch preset {
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(3600)
        case .threeHours: return now.addingTimeInterval(3 * 3600)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: tomorrow)
                ?? tomorrow
        case .nextWeek:
            // The first Monday after today: tomorrow, said on a Sunday, and a
            // week on, said on a Monday morning before nine.
            let today = calendar.startOfDay(for: now)
            let monday = calendar.nextDate(
                after: today, matching: DateComponents(hour: morningHour, minute: 0, second: 0, weekday: 2),
                matchingPolicy: .nextTime)
            guard let monday else { return now.addingTimeInterval(7 * 24 * 3600) }
            return calendar.isDate(monday, inSameDayAs: now)
                ? calendar.date(byAdding: .day, value: 7, to: monday) ?? monday
                : monday
        }
    }

    /// What `wortel remind` or Custom… was given, as a moment: a duration
    /// (`20m`, `1h`, `2d`, `1w`, with or without `in`), a time on the clock
    /// (`15:00`, `3pm`, `9:30am`: the next one), `tomorrow`, `next-week`, or a
    /// day with or without a time (`fri`, `friday 14:00`, `tomorrow 3pm`,
    /// `2026-12-03 10:00`). Nil for anything else, for nothing in the future,
    /// and for anything further than `longest`.
    static func parse(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " am", with: "am").replacingOccurrences(of: " pm", with: "pm")
        if text.hasPrefix("in ") { text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        let resolved: Date?
        switch text {
        case "tomorrow": resolved = date(for: .tomorrow, now: now, calendar: calendar)
        case "next-week", "nextweek", "next week": resolved = date(for: .nextWeek, now: now, calendar: calendar)
        default: resolved = clock(text, now: now, calendar: calendar)
            ?? duration(text).map { now.addingTimeInterval($0) }
            ?? day(text, now: now, calendar: calendar)
        }
        guard let resolved, resolved > now, resolved.timeIntervalSince(now) <= longest else { return nil }
        return resolved
    }

    /// `15:00`, `9:30` or `3pm`: today if that's still ahead, otherwise tomorrow.
    private static func clock(_ text: String, now: Date, calendar: Calendar) -> Date? {
        guard let (hour, minute) = timeOfDay(Substring(text)),
              let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
        else { return nil }
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// `15:00`, `9:30`, `3pm`, `9:30am`, `12am` (midnight). Minutes are two
    /// digits; a bare number needs am or pm, or it could be a duration.
    private static func timeOfDay(_ text: Substring) -> (hour: Int, minute: Int)? {
        var body = text
        var meridiem: Int?
        if body.hasSuffix("am") { meridiem = 0; body = body.dropLast(2) }
        else if body.hasSuffix("pm") { meridiem = 12; body = body.dropLast(2) }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), (1...2).contains(parts[0].count),
              parts.count == 2 ? parts[1].count == 2 : meridiem != nil,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              var hour = Int(parts[0]), let minute = parts.count == 2 ? Int(parts[1]) : 0
        else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + meridiem
        }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// A day, then a time or nine in the morning: `today 17:00`, `tomorrow
    /// 3pm`, `fri`, `friday 14:00`, `2026-12-03`. A weekday is the next one
    /// whose moment is still ahead: today's, said that morning, otherwise a
    /// week on.
    private static func day(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard (1...2).contains(words.count) else { return nil }
        let (hour, minute) = words.count == 2 ? timeOfDay(words[1]) ?? (-1, 0) : (morningHour, 0)
        guard hour >= 0 else { return nil }
        func at(_ day: Date) -> Date? { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) }
        let word = String(words[0])
        let today = calendar.startOfDay(for: now)
        switch word {
        case "today": return at(today)
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today).flatMap(at)
        default: break
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if word.count >= 3, let index = weekdays.firstIndex(where: { $0.hasPrefix(word) }) {
            for offset in 0...7 {
                guard let candidate = calendar.date(byAdding: .day, value: offset, to: today),
                      calendar.component(.weekday, from: candidate) == index + 1,
                      let moment = at(candidate), moment > now else { continue }
                return moment
            }
            return nil
        }
        // 2026-12-03
        let parts = word.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)),
              calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == dayOfMonth
        else { return nil }
        return at(date)
    }

    /// `20m`, `1h`, `90s`, `2d`, `1w`. A unit is required: a bare `20` could
    /// be minutes or a time, and guessing wrong is a reminder that never comes.
    private static func duration(_ text: String) -> TimeInterval? {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400, "w": 7 * 86400]
        guard let last = text.last, let unit = units[last] else { return nil }
        let number = text.dropLast()
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(number), value > 0, value.isFinite else { return nil }
        return value * unit
    }

    /// A pending reminder written short, for a line it shares with a
    /// worktree's branch: the time if it's today ("23:17"), the day and the
    /// time within the week ("Tue 09:00"), the date and the time beyond it
    /// ("24 Nov 09:00").
    static func brief(_ date: Date, now: Date, calendar: Calendar = .current,
                      locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        guard days > 0 else { return time }
        formatter.setLocalizedDateFormatFromTemplate(days < 7 ? "EEE" : "dMMM")
        return "\(formatter.string(from: date)) \(time)"
    }

    /// A pending reminder in words, for the line under a session's name or "set
    /// for" in the command's answer: "today at 15:00", "tomorrow at 9:00",
    /// "Monday at 9:00" within the week, "17 Nov at 9:00" beyond it. The
    /// time is written the way the Mac is set to write it.
    static func describe(_ date: Date, now: Date, calendar: Calendar = .current,
                         locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = locale
        time.dateStyle = .none
        time.timeStyle = .short
        let at = time.string(from: date)

        let startOfToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: startOfToday, to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today at \(at)"
        case 1: return "tomorrow at \(at)"
        default:
            let day = DateFormatter()
            day.calendar = calendar
            day.timeZone = calendar.timeZone
            day.locale = locale
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            day.setLocalizedDateFormatFromTemplate(days < 7 ? "EEEE" : sameYear ? "dMMM" : "dMMMy")
            return "\(day.string(from: date)) at \(at)"
        }
    }
}
