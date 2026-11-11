// Stats.swift - what the Statistics window shows, computed from history.jsonl.
//
// Foundation only, no AppKit: mac/tests/StatsTests.swift compiles this file on
// its own. The history is the file bin/sayit appends to, one JSON object per
// line: time (local, ISO-8601 to seconds), seconds, words, text. A line that
// does not parse is counted and skipped, as bin/sayit-history does, so one
// bad line never hides the healthy entries around it.

import Foundation

struct Dictation: Equatable {
    let time: Date
    let seconds: Double
    let words: Int
    let text: String
}

enum History {
    /// $XDG_DATA_HOME/sayit/history.jsonl, where the scripts keep it.
    static var path: String {
        var base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? ""
        if base.isEmpty { base = (NSHomeDirectory() as NSString).appendingPathComponent(".local/share") }
        return (base as NSString).appendingPathComponent("sayit/history.jsonl")
    }

    /// "2026-11-10T16:34:59" in the calendar's own time zone. A fraction or
    /// a zone after the seconds is ignored: the scripts write local time.
    static func parseTime(_ raw: String, calendar: Calendar) -> Date? {
        let s = Array(raw.utf8)
        guard s.count >= 19, s[4] == 45, s[7] == 45, s[10] == 84 || s[10] == 32, s[13] == 58, s[16] == 58 else {
            return nil
        }
        func number(_ from: Int, _ count: Int) -> Int? {
            var n = 0
            for c in s[from..<(from + count)] {
                guard c >= 48, c <= 57 else { return nil }
                n = n * 10 + Int(c - 48)
            }
            return n
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))
    }

    /// Every entry of a history file, oldest first as written, and how many
    /// lines were not an entry.
    static func parse(_ data: Data, calendar: Calendar = .current) -> (entries: [Dictation], corrupt: Int) {
        var entries: [Dictation] = []
        var corrupt = 0
        for line in data.split(separator: 10, omittingEmptySubsequences: true) {
            if line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let time = (object["time"] as? String).flatMap({ parseTime($0, calendar: calendar) }) else {
                corrupt += 1
                continue
            }
            let seconds = (object["seconds"] as? NSNumber)?.doubleValue ?? 0
            let words = (object["words"] as? NSNumber)?.intValue ?? 0
            entries.append(Dictation(time: time, seconds: seconds.isFinite ? max(0, seconds) : 0,
                                     words: max(0, words), text: object["text"] as? String ?? ""))
        }
        return (entries, corrupt)
    }
}

/// The period the window sums over. A week is today and the six days before
/// it, a month today and the 29 before: whole calendar days, never "the last
/// 168 hours", so a bar is always one full day.
enum StatsRange: String, CaseIterable, Identifiable {
    case today, week, month, all
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .all: return "All time"
        }
    }
}

struct Bucket: Equatable, Identifiable {
    let start: Date
    var words = 0
    var seconds = 0.0
    var dictations = 0
    var id: Date { start }
}

struct Summary: Equatable {
    var dictations = 0
    var words = 0
    var seconds = 0.0
    /// The chart: hours for today, days otherwise, weeks once all time spans
    /// more days than fit as bars. Empty periods are there, with zeros.
    var buckets: [Bucket] = []
    var unit: Calendar.Component = .day
    /// Words by hour of the day, 0...23, over the range.
    var hours: [Int] = Array(repeating: 0, count: 24)
    var activeDays = 0
    var longestSeconds = 0.0
    var bestDay: Bucket?
    /// Days in a row with a dictation, counted over the whole history
    /// whatever the range. A day without one breaks the streak only once it
    /// is over: today still open keeps yesterday's streak.
    var streak = 0
    var longestStreak = 0

    /// Words a minute while speaking.
    var pace: Double { seconds > 0 ? Double(words) / (seconds / 60) : 0 }

    /// What typing the same words would have taken, at `typingWPM`.
    func typingSeconds(typingWPM: Double) -> Double {
        typingWPM > 0 ? Double(words) / typingWPM * 60 : 0
    }

    /// Typing time minus speaking time: negative when speaking was slower.
    func savedSeconds(typingWPM: Double) -> Double {
        typingSeconds(typingWPM: typingWPM) - seconds
    }
}

/// The calendar: words per day over the last `Stats.yearWeeks` weeks, one
/// column a week from the calendar's first weekday, whatever the range.
struct YearMap: Equatable {
    /// The first day of the first column.
    var start = Date.distantPast
    /// Words per day from `start` to today, in order; the days after today in
    /// the last column are not there.
    var words: [Int] = []
    /// Per day: 0 for no words, else 1 to 4, how dark the day is drawn.
    var levels: [Int] = []
    var total: Int { words.reduce(0, +) }
}

enum Stats {
    /// More days than this in "All time" and the chart goes by week.
    static let dailyBarLimit = 92
    /// Columns in the calendar: a year, and the week it is in.
    static let yearWeeks = 53

    static func year(_ entries: [Dictation], now: Date = Date(), calendar: Calendar = .current) -> YearMap {
        let today = calendar.startOfDay(for: now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = calendar.date(byAdding: .weekOfYear, value: -(yearWeeks - 1), to: thisWeek) ?? thisWeek
        let count = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        var out = YearMap(start: start, words: Array(repeating: 0, count: max(count, 0)))
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        for entry in entries where entry.time >= start && entry.time < end {
            // Whole calendar days, so a daylight saving change moves nothing.
            guard let i = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: entry.time)).day,
                  out.words.indices.contains(i) else { continue }
            out.words[i] += entry.words
        }
        out.levels = levels(out.words)
        return out
    }

    /// The chart's scale for a busiest period of `peak` words: a round step,
    /// 1, 2, 2.5 or 5 times a power of ten, that gives about four lines, and
    /// the line at or above the peak. No words, no scale: (0, 0).
    static func scale(_ peak: Int) -> (step: Int, top: Int) {
        guard peak > 0 else { return (0, 0) }
        let raw = Double(peak) / 4
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw && $0.rounded() == $0 && $0 >= 1 }
            ?? 10 * magnitude
        let s = max(1, Int(step))
        return (s, (peak + s - 1) / s * s)
    }

    /// How dark each day is: 1 to 4 by its share of a busy day, the 90th
    /// percentile of the days with words, so one marathon does not leave
    /// every other day pale. No words is 0.
    static func levels(_ words: [Int]) -> [Int] {
        let active = words.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return words.map { _ in 0 } }
        let busy = Double(active[Int(Double(active.count - 1) * 0.9)])
        return words.map { w in
            w <= 0 ? 0 : min(4, max(1, Int((4 * Double(w) / busy).rounded(.up))))
        }
    }

    static func summarize(_ entries: [Dictation], range: StatsRange, now: Date = Date(),
                          calendar: Calendar = .current) -> Summary {
        var out = Summary()
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }

        // Tomorrow and later is a clock that was wrong: in no range, no streak.
        let end = day(1)

        // Streaks, over everything.
        let days = Set(entries.lazy.filter { $0.time < end }.map { calendar.startOfDay(for: $0.time) })
        var cursor = days.contains(today) ? today : day(-1)
        while days.contains(cursor) {
            out.streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? .distantPast
        }
        var run = 0
        var previous: Date?
        for d in days.sorted() {
            if let p = previous, calendar.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            out.longestStreak = max(out.longestStreak, run)
            previous = d
        }

        // The range, and its empty buckets.
        let first: Date
        switch range {
        case .today: first = today
        case .week: first = day(-6)
        case .month: first = day(-29)
        case .all: first = min(days.min() ?? today, today)
        }
        if range == .today {
            out.unit = .hour
        } else if range == .all, (calendar.dateComponents([.day], from: first, to: today).day ?? 0) >= dailyBarLimit {
            out.unit = .weekOfYear
        }
        func bucketStart(_ date: Date) -> Date {
            switch out.unit {
            case .hour: return calendar.dateInterval(of: .hour, for: date)?.start ?? date
            case .weekOfYear: return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            default: return calendar.startOfDay(for: date)
            }
        }
        var index: [Date: Int] = [:]
        var slot = bucketStart(first)
        while slot < end {
            index[slot] = out.buckets.count
            out.buckets.append(Bucket(start: slot))
            guard let next = calendar.date(byAdding: out.unit, value: 1, to: slot), next > slot else { break }
            slot = bucketStart(next)
        }

        var perDay: [Date: Bucket] = [:]
        for entry in entries where entry.time >= first && entry.time < end {
            out.dictations += 1
            out.words += entry.words
            out.seconds += entry.seconds
            out.longestSeconds = max(out.longestSeconds, entry.seconds)
            out.hours[calendar.component(.hour, from: entry.time)] += entry.words
            if let i = index[bucketStart(entry.time)] {
                out.buckets[i].words += entry.words
                out.buckets[i].seconds += entry.seconds
                out.buckets[i].dictations += 1
            }
            let d = calendar.startOfDay(for: entry.time)
            perDay[d, default: Bucket(start: d)].words += entry.words
            perDay[d]?.seconds += entry.seconds
            perDay[d]?.dictations += 1
        }
        out.activeDays = perDay.count
        // The earlier day wins a tie, so the answer does not move about.
        out.bestDay = perDay.values.max { ($0.words, $1.start) < ($1.words, $0.start) }
        return out
    }

    /// "45 s", "12 min", "4 h 10 min": a duration as a person says it.
    static func duration(_ seconds: Double) -> String {
        let s = Int(abs(seconds).rounded())
        if s < 90 { return "\(s) s" }
        let minutes = Int((Double(s) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
