// StatsWindow.swift - the Statistics window: how much has been dictated, and
// the history to search and copy from.
//
// Everything in it is read from history.jsonl when the window opens and again
// whenever the file changes while it is open; nothing is kept once it closes,
// and nothing is written anywhere. The numbers are the ones `sayit-history
// --stat` prints, with TYPING_WPM as the typing speed to compare against.
//
// The look is the README's: its lockup, SAYIT with the red IT above DON'T
// TYPE IT. SAY IT., one large number, the period as rounded bars against a
// scale, and a year of days as a calendar. A window wide enough, as a quarter
// of an ultrawide screen is, puts the lockup and the number in a panel beside
// the charts and needs no scrolling; a narrower one stacks everything. In dark mode the ground is
// all but black, with one small red glow in the corner, and the cards are
// black glass: a faint lift, a lit top edge, Liquid Glass from macOS 26.
//
// It opens as the top left quarter of the screen. While it is open Sayit is
// an ordinary app with a Dock icon and a
// menu bar, so the window can be found again with Cmd+Tab; closing it puts
// Sayit back in the menu bar only.

import AppKit
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

/// What is under the pointer, apart from the rest so that moving the mouse
/// over a chart redraws the overview only.
final class StatsHover: ObservableObject {
    @Published var bucket: Date?
    /// A day of the calendar, as its index in YearMap.words.
    @Published var day: Int?
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

/// The window's colours. In dark mode darker than the system's grey, towards
/// the black of the pill; the red is the README's: the pill's lit lamp on
/// dark, a darker one on light, where the lamp's red would be too faint for
/// small text.
enum StatsTheme {
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    static let background = dynamic(dark: NSColor(white: 0.012, alpha: 1), light: .windowBackgroundColor)
    /// Liquid Glass lightens what it covers; in dark mode it is tinted back
    /// towards black, so the cards stay black glass rather than grey.
    static let glassTint = dynamic(dark: NSColor(white: 0, alpha: 0.45), light: .clear)
    static let red = Color(nsColor: dynamic(dark: NSColor(srgbRed: 1, green: 0.302, blue: 0.302, alpha: 1),
                                            light: NSColor(srgbRed: 0.855, green: 0.267, blue: 0.325, alpha: 1)))
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
    @Published private(set) var year = YearMap()
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
            let year = Stats.year(entries, now: now)
            DispatchQueue.main.async {
                if self.range == range { self.summary = summary }
                if self.year != year { self.year = year }
            }
        }
    }

    /// The window closed: the dictated text leaves memory with it.
    func clear() {
        entries = []
        rows = []
        summary = Summary()
        year = YearMap()
        corrupt = 0
        loaded = false
        signature = ""
        view.query = ""
        view.copied = nil
        hover.bucket = nil
        hover.day = nil
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 780),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Sayit"
            // The lockup is the title; the glow runs up under the titlebar.
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.backgroundColor = StatsTheme.background
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentMinSize = NSSize(width: 680, height: 480)
            // An empty toolbar for the taller titlebar: the window buttons
            // then sit level with the period capsule drawn in it.
            w.toolbar = NSToolbar(identifier: "SayitStatistics")
            w.toolbarStyle = .unified
            w.titlebarSeparatorStyle = .none
            w.contentView = NSHostingView(rootView: StatsView(model: model, state: model.view))
            window = w
        }
        // A quarter of the screen, its top left, each time the window opens.
        if let w = window, !w.isVisible { w.setFrame(quarter(for: w), display: false) }
        if NSApp.mainMenu == nil { NSApp.mainMenu = mainMenu() }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.model.refresh() }
        }
    }

    @objc func close() { window?.close() }

    /// The top left quarter of the visible screen, no smaller than the
    /// window's minimum.
    private func quarter(for w: NSWindow) -> NSRect {
        guard let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return w.frame }
        let min = w.frameRect(forContentRect: NSRect(origin: .zero, size: w.contentMinSize)).size
        let width = max(v.width / 2, min.width), height = max(v.height / 2, min.height)
        return NSRect(x: v.minX, y: v.maxY - height, width: width, height: height)
    }

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

// MARK: - Building blocks

private extension View {
    /// Black glass in `shape`: barely lifted off the ground, lighter at the
    /// top, with a hairline that catches the light along the top edge. Over
    /// it Liquid Glass where the system has it, for the rim and the depth.
    @ViewBuilder func glass<S: InsettableShape>(_ shape: S) -> some View {
        let body = self
            .background {
                shape.fill(LinearGradient(colors: [Color.primary.opacity(0.05), Color.primary.opacity(0.012)],
                                          startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.22), Color.primary.opacity(0.05),
                                                           Color.primary.opacity(0.08)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
        // Liquid Glass needs the macOS 26 SDK to build (Swift 6.2 and later)
        // and macOS 26 to run; anything older gets the lift and the hairline.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Behind the content rather than around it: glass gives what it
            // holds a vibrant treatment that greys the lockup's outlines.
            body.background {
                Color.clear.glassEffect(.clear.tint(Color(nsColor: StatsTheme.glassTint)), in: shape)
            }
        } else {
            body
        }
        #else
        body
        #endif
    }

    func card() -> some View {
        padding(16)
            // As tall as its row allows: beside the tiles it matches them.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The window's ground: all but black, with one small red glow in the top
/// right corner, behind the comparison with typing, and none behind the cards.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: StatsTheme.background)
            RadialGradient(colors: [StatsTheme.red.opacity(0.17), .clear], center: UnitPoint(x: 1.0, y: 0.0),
                           startRadius: 0, endRadius: 340)
        }
        .ignoresSafeArea()
    }
}

private struct WordmarkShape: Shape {
    enum Part { case say, it, dontTypeIt, sayIt }
    let part: Part
    /// Scaled with the whole lockup, or with SAYIT alone.
    let lockup: Bool

    func path(in rect: CGRect) -> Path {
        let b = lockup ? Wordmark.lockupBounds : Wordmark.bounds
        guard b.width > 0, b.height > 0 else { return Path() }
        let k = min(rect.width / b.width, rect.height / b.height)
        var t = CGAffineTransform(translationX: rect.minX + (rect.width - b.width * k) / 2,
                                  y: rect.minY + (rect.height - b.height * k) / 2)
            .scaledBy(x: k, y: k)
            .translatedBy(x: -b.minX, y: -b.minY)
        let source: CGPath
        switch part {
        case .say: source = Wordmark.sayPath
        case .it: source = Wordmark.itPath
        case .dontTypeIt: source = Wordmark.dontTypeItPath
        case .sayIt: source = Wordmark.sayItPath
        }
        return Path(source.copy(using: &t) ?? source)
    }
}

/// The README's lockup, drawn from its own outlines: SAYIT, and under it
/// DON'T TYPE IT. SAY IT. set to the wordmark's width. The reds are the
/// window's; the tagline's first half is quieter than the wordmark.
private struct Lockup: View {
    let height: CGFloat

    var body: some View {
        ZStack {
            WordmarkShape(part: .say, lockup: true).fill(Color.primary)
            WordmarkShape(part: .it, lockup: true).fill(StatsTheme.red)
            WordmarkShape(part: .dontTypeIt, lockup: true).fill(Color.secondary)
            WordmarkShape(part: .sayIt, lockup: true).fill(StatsTheme.red)
        }
        .frame(width: height * Wordmark.lockupAspect, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sayit: don't type it. Say it.")
    }
}

/// The periods and History as one glass capsule in the titlebar, the
/// selected one lit red.
private struct NavBar: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var state: StatsViewState

    private func item(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? StatsTheme.red : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(StatsTheme.red.opacity(active ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StatsRange.allCases) { r in
                item(r.title, active: state.tab == .overview && model.range == r) {
                    state.tab = .overview
                    model.range = r
                }
            }
            Divider().frame(height: 16).padding(.horizontal, 6)
            item("History", active: state.tab == .history) { state.tab = .history }
        }
        .padding(3)
        .glass(Capsule())
    }
}

/// One fact as a tile: a red symbol in a soft disc, the label in small
/// capitals, the figure, and a line of context.
private struct StatTile: View {
    let symbol: String
    let label: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StatsTheme.red)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(StatsTheme.red.opacity(0.15)))
                    .overlay(Circle().strokeBorder(StatsTheme.red.opacity(0.35), lineWidth: 0.5))
                Text(label)
                    .font(.system(size: 10, weight: .semibold)).kerning(1.2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(note)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Views

struct StatsView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var state: StatsViewState

    /// The titlebar's height with its toolbar: the capsule is centred in it,
    /// level with the window buttons.
    static let titlebar: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            NavBar(model: model, state: state)
                .frame(maxWidth: .infinity)
                .frame(height: Self.titlebar)
                .padding(.horizontal, 90)
            Group {
                if model.loaded && model.rows.isEmpty {
                    EmptyHistory(hint: model.hint)
                } else if state.tab == .overview {
                    OverviewView(model: model, hover: model.hover)
                } else {
                    HistoryList(rows: model.rows, state: state)
                }
            }
            .padding(.top, 6)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 680, minHeight: 480)
        .background(Backdrop())
        .environment(\.locale, statsLocale)
    }
}

private struct EmptyHistory: View {
    let hint: String
    var body: some View {
        VStack(spacing: 14) {
            Lockup(height: 44)
            Text("No dictations yet").font(.title3.weight(.semibold)).padding(.top, 10)
            Text(hint.isEmpty ? "Dictate something and it shows up here." : hint + " — it shows up here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OverviewView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var hover: StatsHover

    private var s: Summary { model.summary }

    private func words(_ n: Int) -> String { "\(n.grouped) \(n == 1 ? "word" : "words")" }
    private func days(_ n: Int) -> String { "\(n) \(n == 1 ? "day" : "days")" }
    private func dictations(_ n: Int) -> String { "\(n.grouped) \(n == 1 ? "dictation" : "dictations")" }

    private var rangeLabel: String {
        switch model.range {
        case .today: return "TODAY"
        case .week: return "LAST 7 DAYS"
        case .month: return "LAST 30 DAYS"
        case .all: return "ALL TIME"
        }
    }

    private var heroNote: String {
        guard s.dictations > 0 else {
            return model.range == .today ? "Nothing dictated yet today" : "Nothing dictated in this period"
        }
        return "\(s.words == 1 ? "word" : "words") in \(Stats.duration(s.seconds)) of speaking, "
            + dictations(s.dictations)
    }

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
            return bucketLabel(b) + " · \(words(b.words)) · \(Stats.duration(b.seconds)) · " + dictations(b.dictations)
        }
        if s.unit == .day, s.activeDays > 1 {
            return "\((s.words / s.activeDays).grouped) words on an average day with dictation"
        }
        return ""
    }

    /// The hour of the day with the most words, nil without any.
    private var peakHour: Int? {
        guard let top = s.hours.max(), top > 0 else { return nil }
        return s.hours.firstIndex(of: top)
    }

    /// The left panel's width in the wide layout.
    private static let panelWidth: CGFloat = 380
    /// The narrowest window for the wide layout: the panel, the calendar and
    /// two 170-point columns of tiles, the gaps and the margins.
    private static let wideWidth: CGFloat = panelWidth + YearView.cardWidth + 340 + 24 + 40

    var body: some View {
        GeometryReader { geo in
            // Wide and tall enough for the panel beside the charts, with the
            // calendar and two columns of tiles under them, as a quarter of
            // an ultrawide screen is: everything at once, nothing to scroll.
            if geo.size.width >= Self.wideWidth && geo.size.height >= 520 {
                wide
            } else {
                narrow
            }
        }
    }

    private var wide: some View {
        HStack(alignment: .top, spacing: 12) {
            panel.frame(width: Self.panelWidth)
            VStack(spacing: 12) {
                chart(minHeight: 120)
                HStack(alignment: .top, spacing: 12) {
                    year.frame(width: YearView.cardWidth)
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow { tiles[0]; tiles[1] }
                        GridRow { tiles[2]; tiles[3] }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                corruptNote
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private var narrow: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        Lockup(height: 36)
                        figure(alignment: .leading, size: 56)
                    }
                    Spacer(minLength: 0)
                    speed.frame(width: 270)
                }
                .card()
                chart(minHeight: 124).frame(height: 190)
                year
                HStack(spacing: 12) { ForEach(0..<4) { tiles[$0] } }
                    .fixedSize(horizontal: false, vertical: true)
                corruptNote
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    /// The wide layout's left column: the lockup at the top like a poster's
    /// title, the figure in the middle, speaking against typing at the foot,
    /// over a red glow that rises from behind the lockup.
    private var panel: some View {
        VStack(spacing: 0) {
            Lockup(height: 84)
                .padding(.top, 6)
            Spacer(minLength: 18)
            figure(alignment: .center, size: 84)
            Spacer(minLength: 18)
            speed
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RadialGradient(colors: [StatsTheme.red.opacity(0.22), .clear], center: .top,
                           startRadius: 0, endRadius: 260)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The range, its number of words, and how they were spoken.
    private func figure(alignment: HorizontalAlignment, size: CGFloat) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(rangeLabel)
                .font(.system(size: 11, weight: .semibold)).kerning(1.6)
                .foregroundStyle(StatsTheme.red)
            Text(s.words.grouped)
                .font(.system(size: size, weight: .heavy)).monospacedDigit().kerning(-size / 40)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(heroNote).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var speed: some View {
        SpeedView(pace: s.pace, typing: model.typingWPM, saved: s.savedSeconds(typingWPM: model.typingWPM))
    }

    private func chart(minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(chartTitle).font(.headline)
                Spacer()
                Text(chartReadout).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            WordsChart(buckets: s.buckets, unit: s.unit, hovered: hover.bucket) { hover.bucket = $0 }
                .frame(minHeight: minHeight, maxHeight: .infinity)
        }
        .card()
    }

    @ViewBuilder private var corruptNote: some View {
        if model.corrupt > 0 {
            Text("\(model.corrupt) history \(model.corrupt == 1 ? "line" : "lines") could not be read and \(model.corrupt == 1 ? "is" : "are") left out.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var year: some View {
        YearView(year: model.year, streak: s.streak, hovered: hover.day) { hover.day = $0 }
            .card()
    }

    private var tiles: [StatTile] {
        let perDictation = s.dictations > 0 ? Int((Double(s.words) / Double(s.dictations)).rounded()) : 0
        return [
            StatTile(symbol: "flame", label: "STREAK", value: days(s.streak),
                     note: "longest " + days(s.longestStreak)),
            StatTile(symbol: "clock", label: "PEAK HOUR",
                     value: peakHour.map { String(format: "%02d–%02d", $0, ($0 + 1) % 24) } ?? "–",
                     note: peakHour.map { words(s.hours[$0]) } ?? "nothing yet"),
            StatTile(symbol: "trophy", label: "BEST DAY", value: s.bestDay.map { $0.words.grouped } ?? "–",
                     note: s.bestDay.map { $0.start.text(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
                        ?? "nothing yet"),
            StatTile(symbol: "text.bubble", label: "PER DICTATION",
                     value: s.dictations > 0 ? words(perDictation) : "–",
                     note: s.dictations > 0 ? Stats.duration(s.seconds / Double(s.dictations)) + " on average"
                                            : "nothing yet"),
        ]
    }
}

/// Speaking against typing: two bars, and how many times faster.
private struct SpeedView: View {
    let pace: Double
    let typing: Double
    let saved: Double

    private func bar(_ label: String, _ value: Double, top: Double, _ fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(fill)
                            .frame(width: value > 0 ? max(10, geo.size.width * value / top) : 0)
                    }
                }
                .frame(height: 10)
                Text("\(Int(value.rounded())) wpm").font(.caption).monospacedDigit()
                    .frame(width: 58, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(Int(value.rounded())) words a minute")
    }

    var body: some View {
        let top = max(pace, typing, 1)
        VStack(alignment: .leading, spacing: 10) {
            bar("Typing", typing, top: top, Color.secondary.opacity(0.6))
            bar("Speaking", pace, top: top, StatsTheme.red)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if pace > 0 && typing > 0 {
                    Text(String(format: "%.1f×", pace / typing))
                        .font(.system(size: 26, weight: .bold)).monospacedDigit()
                        .foregroundStyle(StatsTheme.red)
                    Text(pace >= typing ? "faster, \(Stats.duration(saved)) saved"
                                        : "the speed of typing, \(Stats.duration(saved)) lost")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Dictate to compare with typing").font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Words per hour, day or week: one rounded bar per period on a baseline,
/// against a scale that follows the busiest period in the range, and a dot
/// where nothing was said. The current period is drawn brightest, periods
/// still to come not at all.
private struct WordsChart: View {
    let buckets: [Bucket]
    let unit: Calendar.Component
    let hovered: Date?
    let onHover: (Date?) -> Void

    private struct Mark: Identifiable {
        let index: Int
        let text: String
        var id: Int { index }
    }

    /// The bucket the present is in.
    private var current: Int? { buckets.lastIndex(where: { $0.start <= Date() }) }

    private var scale: (step: Int, top: Int) { Stats.scale(buckets.map(\.words).max() ?? 0) }

    /// Room on the left for the scale's widest number.
    private var axisWidth: CGFloat { CGFloat(scale.top.grouped.count) * 6.5 + 12 }

    private var marks: [Mark] {
        let n = buckets.count
        guard n > 0 else { return [] }
        let last = n - 1
        func label(_ i: Int) -> String {
            let d = buckets[i].start
            switch unit {
            case .hour: return String(format: "%02d", Calendar.current.component(.hour, from: d))
            case .weekOfYear: return i == last ? "This week" : d.text(.dateTime.day().month(.abbreviated))
            default:
                if n <= 7 { return d.text(.dateTime.weekday(.abbreviated).day()) }
                return i == last ? "Today" : d.text(.dateTime.day().month(.abbreviated))
            }
        }
        let picked: [Int]
        switch unit {
        case .hour: picked = Array(stride(from: 0, to: n, by: 6))
        default: picked = n <= 7 ? Array(0..<n) : Array(Set((0...4).map { $0 * last / 4 })).sorted()
        }
        return picked.map { Mark(index: $0, text: label($0)) }
    }

    var body: some View {
        let current = self.current
        let scale = self.scale
        let axis = axisWidth
        VStack(spacing: 6) {
            GeometryReader { geo in
                let n = max(buckets.count, 1)
                let slot = (geo.size.width - axis) / CGFloat(n)
                Canvas { ctx, size in
                    // Room above the top number and below the 0.
                    let bottom = size.height - 7, high: CGFloat = 7
                    let plot = bottom - high
                    func y(_ v: Int) -> CGFloat { scale.top > 0 ? bottom - plot * CGFloat(v) / CGFloat(scale.top) : bottom }
                    // The scale: a line and a number per step, 0 included.
                    if scale.step > 0 {
                        for v in stride(from: 0, through: scale.top, by: scale.step) {
                            ctx.fill(Path(CGRect(x: axis, y: y(v) - 0.25, width: size.width - axis, height: 0.5)),
                                     with: .color(Color.primary.opacity(v == 0 ? 0.14 : 0.07)))
                            ctx.draw(Text(v.grouped).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit(),
                                     at: CGPoint(x: axis - 8, y: y(v)), anchor: .trailing)
                        }
                    } else {
                        ctx.fill(Path(CGRect(x: axis, y: bottom - 0.25, width: size.width - axis, height: 0.5)),
                                 with: .color(Color.primary.opacity(0.14)))
                    }
                    let w = min(max(slot * 0.55, 2), 40)
                    for (i, b) in buckets.enumerated() {
                        if let c = current, i > c { continue }
                        let cx = axis + slot * (CGFloat(i) + 0.5)
                        let dim = hovered != nil && hovered != b.start
                        if b.words > 0 {
                            let h = max(3, bottom - y(b.words))
                            let rect = CGRect(x: cx - w / 2, y: bottom - h, width: w, height: h)
                            let now = i == current
                            let alpha: Double = dim ? 0.28 : (now ? 1 : 0.72)
                            ctx.fill(Path(roundedRect: rect, cornerRadius: min(w / 2, 6, h / 2)),
                                     with: .color(StatsTheme.red.opacity(alpha)))
                        } else {
                            let d = min(w, 5)
                            ctx.fill(Path(ellipseIn: CGRect(x: cx - d / 2, y: bottom - d - 1.5, width: d, height: d)),
                                     with: .color(Color.primary.opacity(dim ? 0.1 : 0.25)))
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active(let p) = phase, !buckets.isEmpty, p.x >= axis else {
                        if hovered != nil { onHover(nil) }
                        return
                    }
                    let i = min(buckets.count - 1, max(0, Int((p.x - axis) / slot)))
                    let past = current.map { i <= $0 } ?? true
                    let found = past ? buckets[i].start : nil
                    if found != hovered { onHover(found) }
                }
            }
            GeometryReader { geo in
                let slot = (geo.size.width - axis) / CGFloat(max(buckets.count, 1))
                let last = buckets.count - 1
                let ends = buckets.count > 7 && unit != .hour
                ZStack(alignment: .topLeading) {
                    // Holds the stack's left edge at the chart's, whatever
                    // the labels do.
                    Color.clear.frame(width: geo.size.width, height: 1)
                    ForEach(marks) { m in
                        Text(m.text)
                            .font(.caption)
                            .foregroundStyle(m.index == current ? .primary : .secondary)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in
                                if m.index == 0 && ends { return -axis }
                                if m.index == last && ends { return d.width - geo.size.width }
                                return d.width / 2 - axis - slot * (CGFloat(m.index) + 0.5)
                            }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words per period")
        .accessibilityValue("\(buckets.reduce(0) { $0 + $1.words }.grouped) words in \(buckets.count) periods")
    }
}

/// A year of days, one column a week, darker red for more words.
private struct YearView: View {
    let year: YearMap
    let streak: Int
    let hovered: Int?
    let onHover: (Int?) -> Void

    private static let labelWidth: CGFloat = 30
    private static let monthHeight: CGFloat = 16
    private static let gap: CGFloat = 2.5
    /// Past about 14 points a cell stops looking like a calendar.
    private static let maxStep: CGFloat = 14
    /// The card at its widest: the grid at `maxStep`, and the card's padding.
    static let cardWidth: CGFloat = labelWidth + CGFloat(Stats.yearWeeks) * maxStep + 32

    private func date(_ i: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: i, to: year.start) ?? year.start
    }

    private var readout: String {
        guard let i = hovered, year.words.indices.contains(i) else {
            return streak > 0 ? "\(streak) \(streak == 1 ? "day" : "days") in a row" : ""
        }
        let n = year.words[i]
        return date(i).text(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            + (n > 0 ? " · \(n.grouped) \(n == 1 ? "word" : "words")" : " · nothing dictated")
    }

    /// The red's opacity per level, 1 to 4.
    private static let shades: [Double] = [0, 0.3, 0.52, 0.76, 1]

    private static func fill(_ level: Int) -> Color {
        if level <= 0 { return Color.primary.opacity(0.07) }
        return StatsTheme.red.opacity(shades[min(level, 4)])
    }

    var body: some View {
        let columns = CGFloat(Stats.yearWeeks)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(year.total.grouped) \(year.total == 1 ? "word" : "words") in the last year").font(.headline)
                Spacer()
                Text(readout).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .trailing, spacing: 8) {
                GeometryReader { geo in
                    let step = min((geo.size.width - Self.labelWidth) / columns,
                                   (geo.size.height - Self.monthHeight) / 7)
                    Canvas { ctx, _ in grid(ctx, step: step) }
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let p) = phase, step > 0 else {
                                if hovered != nil { onHover(nil) }
                                return
                            }
                            let c = Int((p.x - Self.labelWidth) / step)
                            let r = Int((p.y - Self.monthHeight) / step)
                            let i = c * 7 + r
                            let inside = p.x >= Self.labelWidth && p.y >= Self.monthHeight && r < 7
                            let found: Int? = inside && year.words.indices.contains(i) ? i : nil
                            if found != hovered { onHover(found) }
                        }
                }
                .aspectRatio(6.6, contentMode: .fit)
                HStack(spacing: 3) {
                    Text("Less").padding(.trailing, 2)
                    ForEach(0..<5) { l in
                        RoundedRectangle(cornerRadius: 2).fill(Self.fill(l)).frame(width: 10, height: 10)
                    }
                    Text("More").padding(.leading, 2)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            // The grid and its legend stop growing at `maxStep` and sit in the
            // middle.
            .frame(maxWidth: Self.labelWidth + columns * Self.maxStep)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A year of dictation")
        .accessibilityValue("\(year.total.grouped) words, \(year.words.filter { $0 > 0 }.count) days with dictation")
    }

    private func grid(_ ctx: GraphicsContext, step: CGFloat) {
        let cell = max(step - Self.gap, 1)
        var cal = Calendar.current
        cal.locale = statsLocale
        var lastMonth = -1, lastLabel = -10
        for (i, level) in year.levels.enumerated() {
            let c = i / 7, r = i % 7
            let rect = CGRect(x: Self.labelWidth + CGFloat(c) * step, y: Self.monthHeight + CGFloat(r) * step,
                              width: cell, height: cell)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(2.5, cell / 4)), with: .color(Self.fill(level)))
            if i == hovered || i == year.levels.count - 1 {
                ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: min(3, cell / 3)),
                           with: .color(Color.primary.opacity(i == hovered ? 0.9 : 0.5)), lineWidth: 1)
            }
            if r == 0 {
                let month = cal.component(.month, from: date(i))
                if month != lastMonth {
                    // The first column often holds the end of a month; it
                    // gets a name only if it has room before the next one.
                    if lastMonth != -1 || cal.component(.day, from: date(i)) <= 7, c - lastLabel >= 3,
                       c < Stats.yearWeeks - 2 {
                        ctx.draw(Text(cal.shortMonthSymbols[month - 1]).font(.system(size: 10))
                                    .foregroundStyle(.secondary),
                                 at: CGPoint(x: rect.minX, y: 0), anchor: .topLeading)
                        lastLabel = c
                    }
                    lastMonth = month
                }
            }
        }
        // Monday, Wednesday and Friday, wherever the week starts.
        for r in 0..<7 {
            let weekday = (cal.firstWeekday - 1 + r) % 7 + 1
            guard [2, 4, 6].contains(weekday) else { continue }
            ctx.draw(Text(cal.shortWeekdaySymbols[weekday - 1]).font(.system(size: 10)).foregroundStyle(.secondary),
                     at: CGPoint(x: 0, y: Self.monthHeight + CGFloat(r) * step + cell / 2), anchor: .leading)
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
        VStack(spacing: 0) {
            HStack {
                TextField("Search the history", text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                Spacer()
                Text("\(rows.count.grouped) \(rows.count == 1 ? "dictation" : "dictations")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
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
                        .listRowBackground(Color.clear)
                    }
                    if found.count > HistoryList.limit {
                        Text("The newest \(HistoryList.limit) of \(found.count.grouped) are shown. Search to find older ones.")
                            .font(.caption).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
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
