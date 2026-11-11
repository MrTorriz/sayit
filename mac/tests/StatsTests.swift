// StatsTests.swift - unit tests for the Statistics window's numbers: the
// history reader, the ranges and their buckets, the streaks, the durations,
// the year calendar, and the path reader behind the wordmark.
//
// Plain checks with a failure counter rather than XCTest, as in
// ConfigTests.swift. Built and run by mac/tests/run.sh together with
// mac/Sources/Agent/Stats.swift and Wordmark.swift alone: neither needs AppKit.

import Foundation

@main
enum StatsTests {
    static var checks = 0
    static var failures = 0

    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL StatsTests.swift:\(line): \(what)")
        }
    }

    /// Stockholm, weeks from Monday: a zone with daylight saving, so a day
    /// is not always 24 hours.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }()

    static func at(_ text: String) -> Date {
        History.parseTime(text, calendar: calendar)!
    }

    static func entry(_ time: String, words: Int = 10, seconds: Double = 5) -> Dictation {
        Dictation(time: at(time), seconds: seconds, words: words, text: "")
    }

    static func main() {
        parseTime()
        parseHistory()
        ranges()
        buckets()
        streaks()
        derived()
        durations()
        year()
        levels()
        scale()
        wordmark()
        print("StatsTests: \(checks - failures) of \(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    static func parseTime() {
        let c = calendar
        let t = History.parseTime("2026-11-10T16:34:59", calendar: c)
        check(t != nil, "a time to the second parses")
        let parts = t.map { c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0) }
        check(parts?.year == 2026 && parts?.month == 11 && parts?.day == 10, "the date is read as written")
        check(parts?.hour == 16 && parts?.minute == 34 && parts?.second == 59, "the time is local, as written")
        check(History.parseTime("2026-11-10T16:34:59.123456", calendar: c) == t, "a fraction is ignored")
        check(History.parseTime("2026-11-10T16:34:59+01:00", calendar: c) == t, "a zone is ignored")
        check(History.parseTime("2026-11-10 16:34:59", calendar: c) == t, "a space separates as well")
        check(History.parseTime("2026-11-10", calendar: c) == nil, "a date alone is not a time")
        check(History.parseTime("2026-13-10T16:34:59", calendar: c) == nil, "month 13 is refused")
        check(History.parseTime("2026-11-10T24:00:00", calendar: c) == nil, "hour 24 is refused")
        check(History.parseTime("yesterday at noon!!", calendar: c) == nil, "prose is refused")
        check(History.parseTime("", calendar: c) == nil, "an empty time is refused")
    }

    static func parseHistory() {
        let text = """
            {"time": "2026-11-09T08:00:00", "seconds": 4.5, "words": 9, "text": "Hur går det?"}

            not json at all
            {"time": "2026-11-10T09:30:00", "seconds": 12, "words": 30, "text": "Åäö och \\"citat\\"."}
            ["an", "array"]
            {"seconds": 3, "words": 5, "text": "no time"}
            {"time": "2026-11-10T10:00:00", "seconds": -2, "words": -7}
            {"time": "2026-11-10T11:00:00", "seconds": 3, "wor
            """
        let parsed = History.parse(Data(text.utf8), calendar: calendar)
        check(parsed.entries.count == 3, "three entries are read, got \(parsed.entries.count)")
        check(parsed.corrupt == 4, "four lines are counted as unreadable, got \(parsed.corrupt)")
        check(parsed.entries.first == Dictation(time: at("2026-11-09T08:00:00"), seconds: 4.5, words: 9,
                                                text: "Hur går det?"), "the first entry is read whole")
        check(parsed.entries.dropFirst().first?.text == "Åäö och \"citat\".", "non-ASCII and escapes survive")
        check(parsed.entries.dropFirst().first?.seconds == 12, "whole seconds are read as a number")
        check(parsed.entries.last?.seconds == 0 && parsed.entries.last?.words == 0 && parsed.entries.last?.text == "",
              "negative numbers count as nothing, a missing text as empty")
        let empty = History.parse(Data(), calendar: calendar)
        check(empty.entries.isEmpty && empty.corrupt == 0, "an empty file is an empty history")
        let crlf = History.parse(Data("{\"time\": \"2026-11-10T10:00:00\", \"seconds\": 1, \"words\": 2, \"text\": \"a\"}\r\n\r\n".utf8),
                                 calendar: calendar)
        check(crlf.entries.count == 1 && crlf.corrupt == 0, "Windows line ends are read, blank ones skipped")
    }

    static let sample: [Dictation] = [
        entry("2026-09-01T12:00:00", words: 1000, seconds: 600),   // long ago
        entry("2026-10-12T12:00:00", words: 100, seconds: 60),     // 29 days before the 10th
        entry("2026-10-11T23:59:59", words: 7, seconds: 4),        // 30 days before: outside the month
        entry("2026-11-04T09:00:00", words: 50, seconds: 30),      // six days before
        entry("2026-11-03T23:00:00", words: 20, seconds: 10),      // seven days before: outside the week
        entry("2026-11-09T14:10:00", words: 40, seconds: 20),
        entry("2026-11-10T08:15:00", words: 30, seconds: 15),
        entry("2026-11-10T08:45:00", words: 12, seconds: 9),
        entry("2026-11-10T16:00:00", words: 8, seconds: 3),
        entry("2026-11-11T00:00:00", words: 999, seconds: 99),     // tomorrow: a clock that was wrong
    ]
    static let now = at("2026-11-10T16:40:00")

    static func ranges() {
        let today = Stats.summarize(sample, range: .today, now: now, calendar: calendar)
        check(today.words == 50 && today.dictations == 3 && today.seconds == 27, "today is the calendar day")
        let week = Stats.summarize(sample, range: .week, now: now, calendar: calendar)
        check(week.words == 140 && week.dictations == 5, "a week is today and the six days before, got \(week.words)")
        let month = Stats.summarize(sample, range: .month, now: now, calendar: calendar)
        check(month.words == 260 && month.dictations == 7, "a month is today and the 29 days before, got \(month.words)")
        let all = Stats.summarize(sample, range: .all, now: now, calendar: calendar)
        check(all.words == 1267 && all.dictations == 9, "all time leaves out only what lies in the future, got \(all.words)")
        check(all.longestSeconds == 600 && week.longestSeconds == 30, "the longest dictation is the range's own")
        check(week.activeDays == 3 && month.activeDays == 5, "days with a dictation are counted in the range")
        check(week.bestDay?.words == 50 && week.bestDay?.start == at("2026-11-04T00:00:00"),
              "the best day by words, the earlier one on a tie")
        check(week.hours[8] == 42 && week.hours[9] == 50 && week.hours[14] == 40 && week.hours[16] == 8
              && week.hours.reduce(0, +) == 140, "words land in their hour of the day")
        let nothing = Stats.summarize([], range: .week, now: now, calendar: calendar)
        check(nothing.words == 0 && nothing.bestDay == nil && nothing.buckets.count == 7 && nothing.streak == 0,
              "an empty history still has its seven empty days")
    }

    static func buckets() {
        let today = Stats.summarize(sample, range: .today, now: now, calendar: calendar)
        check(today.unit == .hour && today.buckets.count == 24, "today is 24 hours")
        check(today.buckets[8].words == 42 && today.buckets[8].dictations == 2 && today.buckets[16].words == 8,
              "an hour's bar sums its dictations")
        let week = Stats.summarize(sample, range: .week, now: now, calendar: calendar)
        check(week.unit == .day && week.buckets.count == 7, "a week is seven days")
        check(week.buckets.first?.start == at("2026-11-04T00:00:00") && week.buckets.last?.start == at("2026-11-10T00:00:00"),
              "from six days ago to today")
        check(week.buckets.map(\.words) == [50, 0, 0, 0, 0, 40, 50], "days without a dictation are there, at zero")
        let month = Stats.summarize(sample, range: .month, now: now, calendar: calendar)
        // The clocks go back on 25 October: a 25-hour day must still be one bar.
        check(month.buckets.count == 30 && month.buckets.first?.start == at("2026-10-12T00:00:00"),
              "a month is thirty days, across the end of daylight saving")
        check(month.buckets.reduce(0) { $0 + $1.words } == month.words, "every word of the month is in a bar")
        let all = Stats.summarize(sample, range: .all, now: now, calendar: calendar)
        check(all.unit == .day && all.buckets.count == 71, "71 days of history are shown by day, got \(all.buckets.count)")
        let long = [entry("2026-06-01T12:00:00", words: 5)] + sample
        let weekly = Stats.summarize(long, range: .all, now: now, calendar: calendar)
        check(weekly.unit == .weekOfYear, "a longer history is shown by week")
        check(weekly.buckets.first?.start == at("2026-06-01T00:00:00"), "weeks start on the calendar's first weekday")
        check(weekly.buckets.count == 24, "24 weeks from 1 June to 10 November, got \(weekly.buckets.count)")
        check(weekly.buckets.reduce(0) { $0 + $1.words } == weekly.words, "every word is in a week")
        let onlyToday = Stats.summarize([entry("2026-11-10T08:00:00")], range: .all, now: now, calendar: calendar)
        check(onlyToday.buckets.count == 1, "a history that starts today is one bar")
    }

    static func streaks() {
        func streak(_ days: [String], now: String = "2026-11-10T12:00:00") -> (Int, Int) {
            let s = Stats.summarize(days.map { entry($0 + "T10:00:00") }, range: .today, now: at(now), calendar: calendar)
            return (s.streak, s.longestStreak)
        }
        check(streak(["2026-11-08", "2026-11-09", "2026-11-10"]) == (3, 3), "three days in a row up to today")
        check(streak(["2026-11-08", "2026-11-09"]) == (2, 2), "today still open keeps yesterday's streak")
        check(streak(["2026-11-07", "2026-11-08"]) == (0, 2), "a whole day missed ends it")
        check(streak(["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-09", "2026-11-10"]) == (2, 4),
              "the longest streak is remembered after it ended")
        check(streak(["2026-11-10", "2026-11-10", "2026-11-10"]) == (1, 1), "several dictations make one day")
        check(streak(["2026-10-24", "2026-10-25", "2026-10-26"], now: "2026-10-26T12:00:00") == (3, 3),
              "the 25-hour day in October does not break a streak")
        check(streak(["2026-03-28", "2026-03-29", "2026-03-30"], now: "2026-03-30T12:00:00") == (3, 3),
              "nor does the 23-hour day in March")
        check(streak([]) == (0, 0), "no history, no streak")
        let ranged = Stats.summarize(sample, range: .today, now: now, calendar: calendar)
        check(ranged.streak == 2 && ranged.longestStreak == 2, "streaks cover the whole history whatever the range")
    }

    static func derived() {
        var s = Summary()
        s.words = 300
        s.seconds = 120
        check(s.pace == 150, "pace is words a minute of speaking")
        check(s.typingSeconds(typingWPM: 40) == 450, "typing 300 words at 40 a minute takes 450 s")
        check(s.savedSeconds(typingWPM: 40) == 330, "saved is typing time less speaking time")
        check(s.savedSeconds(typingWPM: 200) == -30, "a fast typist loses time, and the number says so")
        check(s.typingSeconds(typingWPM: 0) == 0, "a typing speed of zero divides nothing")
        check(Summary().pace == 0, "no speech, no pace")
    }

    static func durations() {
        check(Stats.duration(0) == "0 s", "zero")
        check(Stats.duration(44.6) == "45 s", "seconds are rounded")
        check(Stats.duration(89) == "89 s", "up to a minute and a half in seconds")
        check(Stats.duration(90) == "2 min", "then minutes, rounded")
        check(Stats.duration(3540) == "59 min", "59 minutes")
        check(Stats.duration(3600) == "1 h", "a whole hour has no minutes")
        check(Stats.duration(15021) == "4 h 10 min", "hours and minutes")
        check(Stats.duration(-125) == "2 min", "a negative duration is shown by its size")
    }

    static func year() {
        // Wednesday 11 November 2026; weeks start on Monday here.
        let now = at("2026-11-11T12:00:00")
        let y = Stats.year([
            entry("2026-11-11T08:00:00", words: 40),
            entry("2026-11-11T09:00:00", words: 2),
            entry("2026-11-09T10:00:00", words: 7),
            entry("2026-03-29T12:00:00", words: 5),   // the day the clocks go forward
            entry("2026-11-12T08:00:00", words: 99),  // tomorrow: a clock that was wrong
            entry("2025-01-01T08:00:00", words: 99),  // before the first column
        ], now: now, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: y.start)
        check(parts.weekday == 2, "the first column starts on the calendar's first weekday")
        check(parts.year == 2025 && parts.month == 11 && parts.day == 10,
              "52 weeks before this week's Monday, got \(parts)")
        check(y.words.count == Stats.yearWeeks * 7 - 4, "the days after today are not there, got \(y.words.count)")
        check(y.words.last == 42, "today holds today's words")
        check(y.words[y.words.count - 3] == 7, "Monday holds Monday's")
        let spring = calendar.dateComponents([.day], from: y.start, to: at("2026-03-29T00:00:00")).day!
        check(y.words[spring] == 5, "a day with daylight saving is still one day")
        check(y.total == 54, "outside the year counts nothing, got \(y.total)")
        check(y.levels.count == y.words.count, "a level per day")
        check(Stats.year([], now: now, calendar: calendar).total == 0, "no history, an empty year")
    }

    static func levels() {
        check(Stats.levels([]) == [], "no days, no levels")
        check(Stats.levels([0, 0]) == [0, 0], "no words is level 0")
        check(Stats.levels([0, 30]) == [0, 4], "a lone day is the darkest")
        let l = Stats.levels([0, 10, 25, 50, 75, 100, 100, 100, 100, 100, 100, 5000])
        check(l[0] == 0 && l[1] == 1 && l[2] == 1 && l[3] == 2 && l[4] == 3 && l[5] == 4,
              "by quarters of a busy day, got \(l)")
        check(l[11] == 4, "a marathon is no darker than the darkest")
    }

    static func scale() {
        func check(_ peak: Int, _ step: Int, _ top: Int, line: Int = #line) {
            let got = Stats.scale(peak)
            StatsTests.check(got.step == step && got.top == top,
                             "\(peak) words: step \(step) to \(top), got \(got)", line: line)
        }
        check(0, 0, 0)
        check(1, 1, 1)
        check(3, 1, 3)
        check(10, 5, 10)
        check(250, 100, 300)
        check(1283, 500, 1500)
        check(1500, 500, 1500)
        check(7670, 2000, 8000)
        check(23_456, 10_000, 30_000)
    }

    static func wordmark() {
        let b = Wordmark.bounds
        check(abs(b.minX - 64.08) < 0.5 && abs(b.maxX - 493.47) < 0.5, "SAYIT spans its x, got \(b)")
        check(abs(b.minY - 344.05) < 0.5 && abs(b.maxY - 449.75) < 0.5, "and its height, got \(b)")
        check(Wordmark.itPath.boundingBoxOfPath.minX > Wordmark.sayPath.boundingBoxOfPath.maxX, "IT follows SAY")
        let l = Wordmark.lockupBounds
        check(Wordmark.dontTypeItPath.boundingBoxOfPath.minY > b.maxY && abs(l.maxY - 513.18) < 0.5,
              "the tagline sits under SAYIT, got \(l)")
        check(Wordmark.sayItPath.boundingBoxOfPath.minX > Wordmark.dontTypeItPath.boundingBoxOfPath.maxX,
              "SAY IT. follows DON'T TYPE IT.")
        let square = SVGPath.parse("M 0,0 h 10 v 10 H 0 z").boundingBoxOfPath
        check(square == CGRect(x: 0, y: 0, width: 10, height: 10), "h, v and H draw a square, got \(square)")
        let rel = SVGPath.parse("m 5,5 10,0 0,10 z").boundingBoxOfPath
        check(rel == CGRect(x: 5, y: 5, width: 10, height: 10), "pairs after m are relative linetos, got \(rel)")
        let curve = SVGPath.parse("M 0,0 c 0,10 10,10 10,0").boundingBoxOfPath
        check(abs(curve.maxY - 7.5) < 0.01 && curve.maxX == 10, "c is relative to where it starts, got \(curve)")
        let cut = SVGPath.parse("M 0,0 h 10 v").boundingBoxOfPath
        check(cut == CGRect(x: 0, y: 0, width: 10, height: 0), "a path cut off keeps what came before, got \(cut)")
        check(SVGPath.parse("").isEmpty, "nothing is an empty path")
    }
}
