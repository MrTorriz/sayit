// StatsWindow.swift - the Statistics window: how much has been dictated, and
// the history to search and copy from.
//
// Everything in it is read from history.jsonl when the window opens and again
// whenever the file changes while it is open; nothing is kept once it closes,
// and nothing is written anywhere. The numbers are the ones `sayit-history
// --stat` prints, with TYPING_WPM as the typing speed to compare against.
//
// While the window is open Sayit is an ordinary app with a Dock icon and a
// menu bar, so the window can be found again with Cmd+Tab; closing it puts
// Sayit back in the menu bar only.

import AppKit
import Charts
import SwiftUI

/// What the views themselves change. An observable object rather than @State:
/// in recent SDKs @State is a macro whose plugin ships with Xcode only, and
/// Sayit builds with the Command Line Tools alone.
final class StatsViewState: ObservableObject {
    @Published var tab = StatsTab.overview
    @Published var query = ""
    /// The history row whose text was just copied.
    @Published var copied: Int?
}

/// The bars under the pointer, apart from the rest so that moving the mouse
/// over a chart redraws the overview only.
final class StatsHover: ObservableObject {
    @Published var bucket: Date?
    @Published var hour: Int?
}

/// English month and weekday names, as the rest of the window is in English,
/// with the user's own region for everything else: the 24-hour clock, the
/// day before the month, the digit grouping.
let statsLocale = Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))

private extension Int {
    var grouped: String { formatted(.number.locale(statsLocale)) }
}

private extension Date {
    func text(_ style: Date.FormatStyle) -> String { formatted(style.locale(statsLocale)) }
}

/// The window's two surfaces. In light mode the system's own; in dark mode
/// darker than the system's grey, towards the black of the pill.
enum StatsTheme {
    private static func surface(dark: CGFloat, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: dark, alpha: 1) : light
        }
    }
    static let background = surface(dark: 0.03, light: .windowBackgroundColor)
    static let card = surface(dark: 0.085, light: .controlBackgroundColor)
}

enum StatsTab: String, CaseIterable, Identifiable {
    case overview = "Overview", history = "History"
    var id: String { rawValue }
}

struct HistoryRow: Identifiable {
    /// The entry's position in the file: two dictations can share a second.
    let id: Int
    let entry: Dictation
}

final class StatsModel: ObservableObject {
    @Published private(set) var rows: [HistoryRow] = []
    @Published private(set) var summary = Summary()
    @Published private(set) var corrupt = 0
    @Published private(set) var loaded = false
    @Published var range: StatsRange {
        didSet {
            UserDefaults.standard.set(range.rawValue, forKey: "statsRange")
            recompute()
        }
    }
    let view = StatsViewState()
    let hover = StatsHover()
    var typingWPM = 40.0
    /// How to dictate, for the empty window: "Hold the thumb button".
    var hint = ""

    private var entries: [Dictation] = []
    private var signature = ""
    private var day = Date.distantPast
    private let queue = DispatchQueue(label: "sayit.stats", qos: .userInitiated)

    init() {
        range = StatsRange(rawValue: UserDefaults.standard.string(forKey: "statsRange") ?? "") ?? .week
    }

    /// Reads the history again when it changed, and moves the range along
    /// when the day did. Cheap enough to call every couple of seconds.
    func refresh() {
        let path = History.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let now = "\(modified)/\((attrs?[.size] as? NSNumber)?.int64Value ?? -1)"
        if now == signature {
            if Calendar.current.startOfDay(for: Date()) != day { recompute() }
            return
        }
        signature = now
        queue.async {
            let parsed = History.parse(FileManager.default.contents(atPath: path) ?? Data())
            let rows = parsed.entries.enumerated().reversed().map { HistoryRow(id: $0.offset, entry: $0.element) }
            DispatchQueue.main.async {
                guard self.signature == now else { return }
                self.entries = parsed.entries
                self.rows = Array(rows)
                self.corrupt = parsed.corrupt
                self.loaded = true
                self.recompute()
            }
        }
    }

    private func recompute() {
        let entries = self.entries, range = self.range, now = Date()
        day = Calendar.current.startOfDay(for: now)
        queue.async {
            let summary = Stats.summarize(entries, range: range, now: now)
            DispatchQueue.main.async {
                if self.range == range { self.summary = summary }
            }
        }
    }

    /// The window closed: the dictated text leaves memory with it.
    func clear() {
        entries = []
        rows = []
        summary = Summary()
        corrupt = 0
        loaded = false
        signature = ""
        view.query = ""
        view.copied = nil
        hover.bucket = nil
        hover.hour = nil
    }
}

// MARK: - Window

final class StatsWindowController: NSObject, NSWindowDelegate {
    private let repository: String
    private let model = StatsModel()
    private var window: NSWindow?
    private var timer: Timer?

    init(repository: String) {
        self.repository = repository
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(hint: String) {
        let env = Shared.readEnv((repository as NSString).appendingPathComponent(".env"))
        if let wpm = Double(env["TYPING_WPM"] ?? ""), wpm > 0 { model.typingWPM = wpm } else { model.typingWPM = 40 }
        model.hint = hint
        model.refresh()

        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 730),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Sayit"
            w.backgroundColor = StatsTheme.background
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentMinSize = NSSize(width: 680, height: 480)
            w.contentView = NSHostingView(rootView: StatsView(model: model, state: model.view))
            w.center()
            w.setFrameAutosaveName("SayitStatistics")
            window = w
        }
        if NSApp.mainMenu == nil { NSApp.mainMenu = mainMenu() }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.model.refresh() }
        }
    }

    @objc func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        model.clear()
        NSApp.setActivationPolicy(.accessory)
    }

    /// The menu bar Sayit has while the window is open. Cmd+Q closes the
    /// window rather than quitting: quitting would take the push-to-talk
    /// trigger with it, and that stays with Quit Sayit in the menu bar item.
    private func mainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            top.submenu = menu
            return top
        }
        let main = NSMenu()
        main.addItem(submenu("Sayit", [
            item("Hide Sayit", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Close Statistics", #selector(close), "q", target: self),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return main
    }
}

// MARK: - Views

struct StatsView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var state: StatsViewState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $state.tab) {
                    ForEach(StatsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if state.tab == .overview {
                    Picker("Period", selection: $model.range) {
                        ForEach(StatsRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                } else {
                    TextField("Search the history", text: $state.query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if model.loaded && model.rows.isEmpty {
                EmptyHistory(hint: model.hint)
            } else if state.tab == .overview {
                OverviewView(model: model, hover: model.hover)
            } else {
                HistoryList(rows: model.rows, state: state)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(Color(nsColor: StatsTheme.background))
        .environment(\.locale, statsLocale)
    }
}

private struct EmptyHistory: View {
    let hint: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No dictations yet").font(.title3.weight(.semibold))
            Text(hint.isEmpty ? "Dictate something and it shows up here." : hint + " — it shows up here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Card<Content: View>: View {
    private let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: StatsTheme.card)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// One headline number: what it is, the figure, and a line of context.
private struct Tile: View {
    let label: String
    /// The figure in parts, each a number and its unit: 4 h, 10 min.
    let parts: [(value: String, unit: String)]
    let note: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Text(part.value).font(.system(size: 28, weight: .semibold))
                        if !part.unit.isEmpty {
                            Text(part.unit).font(.callout).foregroundStyle(.secondary).padding(.trailing, 3)
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var hover: StatsHover

    private var s: Summary { model.summary }

    /// A duration as tile parts: 4 h 10 min, 12 min, 45 s.
    private func parts(_ seconds: Double) -> [(value: String, unit: String)] {
        let total = Int(abs(seconds).rounded())
        if total < 90 { return [("\(total)", "s")] }
        let minutes = Int((Double(total) / 60).rounded())
        if minutes < 60 { return [("\(minutes)", "min")] }
        return minutes % 60 == 0 ? [("\(minutes / 60)", "h")] : [("\(minutes / 60)", "h"), ("\(minutes % 60)", "min")]
    }

    private func words(_ n: Int) -> String { "\(n.grouped) \(n == 1 ? "word" : "words")" }
    private func days(_ n: Int) -> String { "\(n) \(n == 1 ? "day" : "days")" }

    private var chartTitle: String {
        switch s.unit {
        case .hour: return "Words per hour"
        case .weekOfYear: return "Words per week"
        default: return "Words per day"
        }
    }

    private func bucketLabel(_ b: Bucket) -> String {
        switch s.unit {
        case .hour:
            let h = Calendar.current.component(.hour, from: b.start)
            return String(format: "%02d:00–%02d:00", h, (h + 1) % 24)
        case .weekOfYear:
            return "Week of " + b.start.text(.dateTime.day().month(.abbreviated))
        default:
            return b.start.text(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    /// The line above the chart: the bar under the pointer, else the average.
    private var chartReadout: String {
        if let b = s.buckets.first(where: { $0.start == hover.bucket }) {
            guard b.dictations > 0 else { return bucketLabel(b) + " · nothing dictated" }
            return bucketLabel(b) + " · \(words(b.words)) · \(Stats.duration(b.seconds))"
                + " · \(b.dictations) \(b.dictations == 1 ? "dictation" : "dictations")"
        }
        if s.unit == .day, s.activeDays > 1 {
            return "\((s.words / s.activeDays).grouped) words on an average day with dictation"
        }
        return ""
    }

    private var hoursReadout: String {
        guard let h = hover.hour else { return "" }
        return String(format: "%02d:00–%02d:00 · ", h, (h + 1) % 24) + words(s.hours[h])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                tiles
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(chartTitle).font(.headline)
                            Spacer()
                            Text(chartReadout).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        WordsChart(buckets: s.buckets, unit: s.unit, hovered: hover.bucket) { hover.bucket = $0 }
                            .frame(height: 200)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    if s.unit != .hour {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Time of day").font(.headline)
                                    Spacer()
                                    Text(hoursReadout).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                                HoursChart(hours: s.hours, hovered: hover.hour) { hover.hour = $0 }
                                    .frame(height: 130)
                            }
                        }
                    }
                    Card { facts }
                }
                .fixedSize(horizontal: false, vertical: true)
                if model.corrupt > 0 {
                    Text("\(model.corrupt) history \(model.corrupt == 1 ? "line" : "lines") could not be read and \(model.corrupt == 1 ? "is" : "are") left out.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }

    private var tiles: some View {
        let saved = s.savedSeconds(typingWPM: model.typingWPM)
        let average = s.dictations > 0 ? s.seconds / Double(s.dictations) : 0
        return HStack(spacing: 12) {
            Tile(label: "Words", parts: [(s.words.grouped, "")],
                 note: "\(s.dictations.grouped) \(s.dictations == 1 ? "dictation" : "dictations")")
            Tile(label: "Speaking time", parts: parts(s.seconds),
                 note: s.dictations > 0 ? "\(Stats.duration(average)) on average" : "nothing yet")
            Tile(label: "Pace", parts: [("\(Int(s.pace.rounded()))", "words/min")],
                 note: "while speaking")
            Tile(label: saved >= 0 ? "Time saved" : "Time lost", parts: parts(saved),
                 note: "against typing \(Int(model.typingWPM)) words/min")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var facts: some View {
        let rows: [(String, String)] = [
            ("Day streak", days(s.streak)),
            ("Longest streak", days(s.longestStreak)),
            ("Days with dictation", model.range == .today ? (s.activeDays > 0 ? "Today" : "Not yet today")
                : "\(s.activeDays) of \(max(s.activeDays, daysInRange))"),
            ("Best day", s.bestDay.map {
                "\(words($0.words)) · " + $0.start.text(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            } ?? "–"),
            ("Longest dictation", s.longestSeconds > 0 ? Stats.duration(s.longestSeconds) : "–"),
            ("Average dictation", s.dictations > 0 ? words(Int((Double(s.words) / Double(s.dictations)).rounded())) : "–"),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            Text("In numbers").font(.headline).padding(.bottom, 8)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider() }
                HStack {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).multilineTextAlignment(.trailing)
                }
                .font(.callout)
                .padding(.vertical, 6)
            }
        }
    }

    private var daysInRange: Int {
        guard let first = s.buckets.first?.start else { return 0 }
        let today = Calendar.current.startOfDay(for: Date())
        return (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: first), to: today).day ?? 0) + 1
    }
}

/// Words per hour, day or week: one series, so no legend - the title names it.
private struct WordsChart: View {
    let buckets: [Bucket]
    let unit: Calendar.Component
    let hovered: Date?
    let onHover: (Date?) -> Void

    var body: some View {
        Chart(buckets) { b in
            BarMark(x: .value("Period", b.start, unit: unit), y: .value("Words", b.words),
                    width: buckets.count <= 12 ? .fixed(24) : .ratio(0.62))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                .foregroundStyle(Color.accentColor.opacity(hovered == nil || hovered == b.start ? 1 : 0.4))
        }
        .chartXAxis {
            switch unit {
            case .hour:
                AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                    AxisValueLabel(format: Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).locale(statsLocale))
                }
            case .weekOfYear:
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: Date.FormatStyle.dateTime.day().month(.abbreviated).locale(statsLocale))
                }
            default:
                if buckets.count <= 7 {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: Date.FormatStyle.dateTime.weekday(.abbreviated).locale(statsLocale), centered: true)
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel(format: Date.FormatStyle.dateTime.day().month(.abbreviated).locale(statsLocale))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color(nsColor: .separatorColor))
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let point) = phase, let frame = proxy.plotFrame,
                              let date: Date = proxy.value(atX: point.x - geo[frame].origin.x) else {
                            if hovered != nil { onHover(nil) }
                            return
                        }
                        let found = buckets.last(where: { $0.start <= date })?.start
                        if found != hovered { onHover(found) }
                    }
            }
        }
    }
}

/// Words by hour of the day over the period: when the dictating happens.
private struct HoursChart: View {
    let hours: [Int]
    let hovered: Int?
    let onHover: (Int?) -> Void

    var body: some View {
        Chart(Array(hours.enumerated()), id: \.offset) { hour, words in
            BarMark(x: .value("Hour", hour), y: .value("Words", words), width: .fixed(7))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                .foregroundStyle(Color.accentColor.opacity(hovered == nil || hovered == hour ? 1 : 0.4))
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel { Text(String(format: "%02d", value.as(Int.self) ?? 0)) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color(nsColor: .separatorColor))
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let point) = phase, let frame = proxy.plotFrame,
                              let x: Double = proxy.value(atX: point.x - geo[frame].origin.x) else {
                            if hovered != nil { onHover(nil) }
                            return
                        }
                        let hour = Int(x.rounded())
                        let found = (0..<24).contains(hour) ? hour : nil
                        if found != hovered { onHover(found) }
                    }
            }
        }
    }
}

// MARK: - History

private struct HistoryList: View {
    let rows: [HistoryRow]
    @ObservedObject var state: StatsViewState
    /// The newest matches shown; a search narrows it down further.
    private static let limit = 500

    private var matches: [HistoryRow] {
        let q = state.query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? rows : rows.filter { $0.entry.text.localizedStandardContains(q) }
    }

    var body: some View {
        let found = matches
        if found.isEmpty {
            Text("Nothing in the history matches.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(found.prefix(HistoryList.limit)) { row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.entry.time.text(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                                    .hour().minute())
                                 + " · \(row.entry.words) \(row.entry.words == 1 ? "word" : "words")"
                                 + " · \(Stats.duration(row.entry.seconds))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(row.entry.text).lineLimit(4).textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Button(state.copied == row.id ? "Copied" : "Copy") { copy(row) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
                if found.count > HistoryList.limit {
                    Text("The newest \(HistoryList.limit) of \(found.count.grouped) are shown. Search to find older ones.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func copy(_ row: HistoryRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.entry.text, forType: .string)
        state.copied = row.id
        let state = self.state
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if state.copied == row.id { state.copied = nil }
        }
    }
}
