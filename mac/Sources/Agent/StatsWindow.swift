// StatsWindow.swift - the Statistics window: how much has been dictated, and
// the history to search and copy from.
//
// Everything in it is read from history.jsonl when the window opens and again
// whenever the file changes while it is open; nothing is kept once it closes,
// and nothing is written anywhere. The numbers are the ones `sayit-history
// --stat` prints, with TYPING_WPM as the typing speed to compare against, plus
// the latency and the apps the history has on macOS.
//
// The look is the README's: its lockup, SAYIT with the red IT above DON'T
// TYPE IT. SAY IT., one large number, the period as rounded bars against a
// scale, and a year of days as a calendar. A window wide enough, as a quarter
// of an ultrawide screen is, puts the lockup and the number in a panel beside
// the chart, the calendar under it across the whole width and the tiles in a
// row under that; a narrower one stacks everything. In dark mode the ground is
// all but black, with one small glow in the corner, and the cards are black
// glass: a faint lift, a lit top edge, Liquid Glass from macOS 26.
//
// Settings > Appearance (Look.swift) sets the text size, the accent colour in
// place of the red, light or dark, glass or solid cards, the glow, the layout,
// which parts and cards show in which order, and where the window opens: by
// default where it was left, the first time the top left quarter of the
// screen. While it is open Sayit is an ordinary app with a Dock icon and a
// menu bar, so the window can be found again with Cmd+Tab; closing it puts
// Sayit back in the menu bar only.

import AppKit
import Combine
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

/// Month and weekday names in the app's language (Localize.swift), with the
/// user's own region for everything else: the 24-hour clock, the day before
/// the month, the digit grouping.
let statsLocale = Locale(identifier: appLanguage + "_" + (Locale.current.region?.identifier ?? "US"))

private extension Int {
    var grouped: String { formatted(.number.locale(statsLocale)) }
}

private extension Date {
    func text(_ style: Date.FormatStyle) -> String { formatted(style.locale(statsLocale)) }
}

/// The window's colours. In dark mode darker than the system's grey, towards
/// the black of the pill. The accent is Settings' (Look.swift).
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
    private let look = Look.shared
    private var window: NSWindow?
    private var timer: Timer?
    private var lookWatch: AnyCancellable?
    /// Called once the window has closed, so the app can leave the Dock.
    var onClose: (() -> Void)?

    /// AppKit keeps the window's place under this name in Sayit's defaults.
    private static let frameName = "SayitStatistics"

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
            w.contentView = NSHostingView(rootView: StatsView(model: model, state: model.view, look: look))
            window = w
            place(w)
            w.setFrameAutosaveName(Self.frameName)
            w.appearance = look.theme.appearance
            lookWatch = look.objectWillChange.sink { [weak self] in
                // objectWillChange fires before the value changes.
                DispatchQueue.main.async { self?.window?.appearance = self?.look.theme.appearance }
            }
        } else if let w = window, !w.isVisible {
            place(w)
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.model.refresh() }
        }
    }

    @objc func close() { window?.close() }

    /// Where the window opens, as Settings > Appearance says: where it was
    /// left (the first time, the top left quarter), the top left quarter of
    /// the screen each time, or that size in the middle.
    private func place(_ w: NSWindow) {
        switch look.openAt {
        case .lastPlace:
            if !w.setFrameUsingName(Self.frameName) { w.setFrame(quarter(for: w), display: false) }
        case .quarter:
            w.setFrame(quarter(for: w), display: false)
        case .centred:
            w.setFrame(quarter(for: w), display: false)
            w.center()
        }
    }

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
        // After the close, when the window no longer counts as visible.
        DispatchQueue.main.async { self.onClose?() }
    }
}

// MARK: - Building blocks

extension StatsTheme {
    /// A solid card: a step up from the ground, plain white on light.
    static let solidCard = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.085, alpha: 1) : .white
    }
}

/// A card's surface: black glass, or a solid card when Settings say so.
private struct Surface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.sayit) private var st

    @ViewBuilder func body(content: Content) -> some View {
        if st.solid {
            content
                .background { shape.fill(Color(nsColor: StatsTheme.solidCard)) }
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75).allowsHitTesting(false)
                }
        } else {
            glass(content)
        }
    }

    /// Black glass: barely lifted off the ground, lighter at the top, with a
    /// hairline that catches the light along the top edge. Over it Liquid
    /// Glass where the system has it, for the rim and the depth.
    @ViewBuilder private func glass(_ content: Content) -> some View {
        let body = content
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
}

private struct CardPadding: ViewModifier {
    @Environment(\.sayit) private var st

    func body(content: Content) -> some View {
        content
            .padding(16 * st.heroScale)
            // As tall as its row allows: beside the tiles it matches them.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private extension View {
    func glass<S: InsettableShape>(_ shape: S) -> some View { modifier(Surface(shape: shape)) }
    func card() -> some View { modifier(CardPadding()) }
}

/// The window's ground: all but black, with one small glow in the top right
/// corner, behind the comparison with typing, and none behind the cards.
private struct Backdrop: View {
    @Environment(\.sayit) private var st

    var body: some View {
        ZStack {
            Color(nsColor: StatsTheme.background)
            if st.glow {
                RadialGradient(colors: [st.accent.opacity(0.17), .clear], center: UnitPoint(x: 1.0, y: 0.0),
                               startRadius: 0, endRadius: 340)
            }
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
/// DON'T TYPE IT. SAY IT. set to the wordmark's width, in the accent colour;
/// the tagline's first half is quieter than the wordmark.
private struct Lockup: View {
    let height: CGFloat
    @Environment(\.sayit) private var st

    var body: some View {
        ZStack {
            WordmarkShape(part: .say, lockup: true).fill(Color.primary)
            WordmarkShape(part: .it, lockup: true).fill(st.accent)
            WordmarkShape(part: .dontTypeIt, lockup: true).fill(Color.secondary)
            WordmarkShape(part: .sayIt, lockup: true).fill(st.accent)
        }
        .frame(width: height * Wordmark.lockupAspect, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Sayit: don't type it. Say it."))
    }
}

/// The periods and History as one glass capsule in the titlebar, the
/// selected one lit in the accent colour.
private struct NavBar: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var state: StatsViewState
    @Environment(\.sayit) private var st

    private func item(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(st.font(12.5, active ? .semibold : .regular))
                .foregroundStyle(active ? st.accent : Color.secondary)
                .padding(.horizontal, 14 * st.heroScale)
                .padding(.vertical, 6)
                .background(Capsule().fill(st.accent.opacity(active ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StatsRange.allCases) { r in
                item(L(r.title), active: state.tab == .overview && model.range == r) {
                    state.tab = .overview
                    model.range = r
                }
            }
            Divider().frame(height: 16).padding(.horizontal, 6)
            item(L("History"), active: state.tab == .history) { state.tab = .history }
        }
        .padding(3)
        .glass(Capsule())
    }
}

/// One fact as a tile: a symbol in a soft disc, the label in small capitals,
/// the figure, a line of context, and for some a small chart under them or a
/// ring beside them.
private struct StatTile: View {
    let symbol: String
    let label: String
    let value: String
    let note: String
    var extra: AnyView? = nil
    var trailing: AnyView? = nil
    @Environment(\.sayit) private var st

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * st.heroScale) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(st.font(11, .semibold))
                    .foregroundStyle(st.accent)
                    .frame(width: st.size(24), height: st.size(24))
                    .background(Circle().fill(st.accent.opacity(0.15)))
                    .overlay(Circle().strokeBorder(st.accent.opacity(0.35), lineWidth: 0.5))
                Text(label)
                    .font(st.font(10, .semibold)).kerning(1.2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4 * st.heroScale) {
                    if !value.isEmpty {
                        Text(value)
                            .font(st.font(22, .bold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    if !note.isEmpty {
                        Text(note).font(st.font(10.5)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                if let trailing = trailing {
                    Spacer(minLength: 0)
                    trailing
                }
            }
            if let extra = extra { extra }
        }
        .padding(12 * st.heroScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Words by hour of the day, 0 to 23, the busiest hour brightest.
private struct HoursBars: View {
    let hours: [Int]
    let peak: Int?
    @Environment(\.sayit) private var st

    var body: some View {
        let top = max(hours.max() ?? 0, 1)
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(hours.indices, id: \.self) { h in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(h == peak ? st.accent : st.accent.opacity(hours[h] > 0 ? 0.45 : 0.12))
                        .frame(height: max(2, st.size(20) * CGFloat(hours[h]) / CGFloat(top)))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: st.size(20), alignment: .bottom)
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { t in
                    Text(t)
                    if t != "24" { Spacer(minLength: 0) }
                }
            }
            .font(st.font(9.5)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

/// The apps with the most words, as shares of the words with an app: at
/// most three rows, the rest as one, so the tile is as tall with ten apps as
/// with three and the window never has to scroll for it.
private struct AppBars: View {
    let apps: [AppShare]
    let total: Int
    @Environment(\.sayit) private var st

    private var rows: [AppShare] {
        guard apps.count > 3 else { return apps }
        let top = Array(apps.prefix(2))
        return top + [AppShare(name: L("Other apps"), words: total - top.reduce(0) { $0 + $1.words })]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * st.heroScale) {
            ForEach(rows, id: \.name) { app in
                let share = total > 0 ? Double(app.words) / Double(total) : 0
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(app.name).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(Int((share * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(st.font(11))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(st.accent).frame(width: max(4, geo.size.width * share))
                        }
                    }
                    .frame(height: st.size(5))
                }
            }
        }
    }
}

/// Today's words against the daily goal, as a ring.
private struct GoalRing: View {
    let progress: Double
    @Environment(\.sayit) private var st

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: st.size(5))
            Circle().trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(st.accent, style: StrokeStyle(lineWidth: st.size(5), lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: st.size(44), height: st.size(44))
        .accessibilityHidden(true)
    }
}

// MARK: - Views

struct StatsView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var state: StatsViewState
    @ObservedObject var look: Look

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
                    OverviewView(model: model, hover: model.hover, look: look)
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
        .environment(\.sayit, look.style)
        .tint(look.accent.color)
    }
}

private struct EmptyHistory: View {
    let hint: String
    @Environment(\.sayit) private var st

    var body: some View {
        VStack(spacing: 14) {
            Lockup(height: 44 * st.heroScale)
            Text("No dictations yet").font(st.font(15, .semibold)).padding(.top, 10)
            Text(hint.isEmpty ? L("Dictate something and it shows up here.") : L("%@ — it shows up here.", hint))
                .font(st.font(13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OverviewView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var hover: StatsHover
    @ObservedObject var look: Look

    private var s: Summary { model.summary }
    private var st: SayitStyle { look.style }
    private var k: CGFloat { st.scale }
    private var hk: CGFloat { st.heroScale }

    private func words(_ n: Int) -> String { L(n == 1 ? "%@ word" : "%@ words", n.grouped) }
    private func days(_ n: Int) -> String { L(n == 1 ? "%d day" : "%d days", n) }
    private func dictations(_ n: Int) -> String { L(n == 1 ? "%@ dictation" : "%@ dictations", n.grouped) }

    private var rangeLabel: String {
        switch model.range {
        case .today: return L("TODAY")
        case .week: return L("LAST 7 DAYS")
        case .month: return L("LAST 30 DAYS")
        case .all: return L("ALL TIME")
        }
    }

    private var heroNote: String {
        guard s.dictations > 0 else {
            return L(model.range == .today ? "Nothing dictated yet today" : "Nothing dictated in this period")
        }
        return L(s.words == 1 ? "word in %@ of speaking, %@" : "words in %@ of speaking, %@",
                 Stats.duration(s.seconds), dictations(s.dictations))
    }

    private var chartTitle: String {
        switch s.unit {
        case .hour: return L("Words per hour")
        case .weekOfYear: return L("Words per week")
        default: return L("Words per day")
        }
    }

    private func bucketLabel(_ b: Bucket) -> String {
        switch s.unit {
        case .hour:
            let h = Calendar.current.component(.hour, from: b.start)
            return String(format: "%02d:00–%02d:00", h, (h + 1) % 24)
        case .weekOfYear:
            return L("Week of %@", b.start.text(.dateTime.day().month(.abbreviated)))
        default:
            return b.start.text(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    /// The line above the chart: the bar under the pointer, else the average.
    private var chartReadout: String {
        if let b = s.buckets.first(where: { $0.start == hover.bucket }) {
            guard b.dictations > 0 else { return bucketLabel(b) + L(" · nothing dictated") }
            return bucketLabel(b) + " · \(words(b.words)) · \(Stats.duration(b.seconds)) · " + dictations(b.dictations)
        }
        if s.unit == .day, s.activeDays > 1 {
            return L("%@ words on an average day with dictation", (s.words / s.activeDays).grouped)
        }
        return ""
    }

    /// The hour of the day with the most words, nil without any.
    private var peakHour: Int? {
        guard let top = s.hours.max(), top > 0 else { return nil }
        return s.hours.firstIndex(of: top)
    }

    private var shown: [TileKind] { look.tiles.filter(\.on).map(\.kind) }

    /// The narrowest a tile gets in the row under the calendar.
    private var tileMin: CGFloat { 140 * k }
    /// The wide layout's columns: the panel, and beside it the calendar at
    /// 10-point days or three tiles, whichever is wider.
    private var panelWidth: CGFloat { 380 * hk }
    private var wideWidth: CGFloat {
        panelWidth + 12 + 40
            + max(look.showYear ? YearView.width(step: 10 * k, scale: k) : 0,
                  shown.isEmpty ? 0 : CGFloat(min(shown.count, 3)) * (tileMin + 12) - 12)
    }

    var body: some View {
        GeometryReader { geo in
            // Wide and tall enough for the panel beside the charts, with the
            // calendar across and the tiles in a row under it, as a quarter
            // of an ultrawide screen is: everything at once. More than fits
            // that height scrolls.
            if useWide(geo.size) {
                let column = geo.size.width - 40 - panelWidth - 12
                ViewThatFits(in: .vertical) {
                    wide(fill: true, column: column)
                    ScrollView { wide(fill: false, column: column) }
                }
            } else {
                narrow
            }
        }
    }

    private func useWide(_ size: CGSize) -> Bool {
        switch look.layout {
        case .side: return true
        case .stacked: return false
        case .automatic: return size.width >= wideWidth && size.height >= 520
        }
    }

    /// The chart takes what height is left; the calendar, across the whole
    /// column, and the tiles take what they need.
    private func wide(fill: Bool, column: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            panel.frame(width: panelWidth)
            VStack(spacing: 12) {
                if look.showChart {
                    if fill {
                        chart(minHeight: 72 * k)
                    } else {
                        chart(minHeight: 120 * k).frame(height: 200 * k)
                    }
                }
                if look.showYear {
                    year.fixedSize(horizontal: false, vertical: true)
                }
                tileRows(shown, width: column)
                corruptNote
            }
        }
        // Scrolling, the panel is as tall as the column beside it.
        .fixedSize(horizontal: false, vertical: !fill)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    /// The tiles in as few rows as `width` allows, as even as can be, each
    /// row as tall as its tallest tile.
    @ViewBuilder private func tileRows(_ kinds: [TileKind], width: CGFloat) -> some View {
        if !kinds.isEmpty {
            let fit = max(1, Int((width + 12) / (tileMin + 12)))
            let rows = (kinds.count + fit - 1) / fit
            let perRow = (kinds.count + rows - 1) / rows
            VStack(spacing: 12) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(kinds[(r * perRow)..<min(kinds.count, (r + 1) * perRow)])) { tile($0) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var narrow: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        Lockup(height: 36 * hk)
                        figure(alignment: .leading, size: 56 * hk)
                    }
                    Spacer(minLength: 0)
                    if look.showSpeed { speed.frame(width: 270 * k) }
                }
                .card()
                if look.showChart { chart(minHeight: 124 * k).frame(height: 190 * k) }
                if look.showYear { year }
                if !shown.isEmpty { tileGrid(shown) }
                corruptNote
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    /// As many columns as fit, for the stacked layout.
    private func tileGrid(_ kinds: [TileKind]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170 * k), spacing: 12)], spacing: 12) {
            ForEach(kinds) { tile($0) }
        }
    }

    /// The wide layout's left column: the lockup at the top like a poster's
    /// title, the figure in the middle, speaking against typing at the foot,
    /// over a glow that rises from behind the lockup.
    private var panel: some View {
        VStack(spacing: 0) {
            Lockup(height: 84 * hk)
                .padding(.top, 6)
            Spacer(minLength: 18)
            figure(alignment: .center, size: 84 * hk)
            Spacer(minLength: 18)
            if look.showSpeed { speed }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if st.glow {
                RadialGradient(colors: [st.accent.opacity(0.22), .clear], center: .top,
                               startRadius: 0, endRadius: 260 * hk)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The range, its number of words, and how they were spoken.
    private func figure(alignment: HorizontalAlignment, size: CGFloat) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(rangeLabel)
                .font(st.font(11, .semibold)).kerning(1.6)
                .foregroundStyle(st.accent)
            Text(s.words.grouped)
                .font(.system(size: size, weight: .heavy)).monospacedDigit().kerning(-size / 40)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(heroNote).font(st.font(12)).foregroundStyle(.secondary).lineLimit(1)
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
                Text(chartTitle).font(st.font(13, .bold))
                Spacer()
                Text(chartReadout).font(st.font(12)).foregroundStyle(.secondary).lineLimit(1)
            }
            WordsChart(buckets: s.buckets, unit: s.unit, hovered: hover.bucket) { hover.bucket = $0 }
                .frame(minHeight: minHeight, maxHeight: .infinity)
        }
        .card()
    }

    @ViewBuilder private var corruptNote: some View {
        if model.corrupt > 0 {
            Text(L(model.corrupt == 1 ? "%d history line could not be read and is left out."
                                      : "%d history lines could not be read and are left out.", model.corrupt))
                .font(st.font(10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var year: some View {
        YearView(year: model.year, streak: s.streak, hovered: hover.day) { hover.day = $0 }
            .card()
    }

    private func tile(_ kind: TileKind) -> StatTile {
        let label = kind.title.uppercased()
        switch kind {
        case .streak:
            return StatTile(symbol: kind.symbol, label: label, value: days(s.streak),
                            note: L("longest %@", days(s.longestStreak)))
        case .peakHour:
            return StatTile(symbol: kind.symbol, label: label,
                            value: peakHour.map { String(format: "%02d–%02d", $0, ($0 + 1) % 24) } ?? "–",
                            note: peakHour.map { words(s.hours[$0]) } ?? L("nothing yet"),
                            extra: peakHour == nil ? nil : AnyView(HoursBars(hours: s.hours, peak: peakHour)))
        case .bestDay:
            return StatTile(symbol: kind.symbol, label: label, value: s.bestDay.map { $0.words.grouped } ?? "–",
                            note: s.bestDay.map { $0.start.text(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
                                ?? L("nothing yet"))
        case .perDictation:
            let perDictation = s.dictations > 0 ? Int((Double(s.words) / Double(s.dictations)).rounded()) : 0
            return StatTile(symbol: kind.symbol, label: label,
                            value: s.dictations > 0 ? words(perDictation) : "–",
                            note: s.dictations > 0 ? L("%@ on average", Stats.duration(s.seconds / Double(s.dictations)))
                                                   : L("nothing yet"))
        case .latency:
            guard let median = s.latencyMedian else {
                return StatTile(symbol: kind.symbol, label: label, value: "–",
                                note: L("measured from the next dictation"))
            }
            return StatTile(symbol: kind.symbol, label: label, value: String(format: "%.2f s", median),
                            note: L("median · slowest %@", String(format: "%.1f s", s.latencySlowest ?? median)))
        case .apps:
            guard !s.apps.isEmpty else {
                return StatTile(symbol: kind.symbol, label: label, value: "–",
                                note: L("recorded from the next dictation"))
            }
            return StatTile(symbol: kind.symbol, label: label, value: "", note: "",
                            extra: AnyView(AppBars(apps: s.apps, total: s.appWords)))
        case .goal:
            let goal = max(look.dailyGoal, 1)
            let done = s.todayWords >= goal
            return StatTile(symbol: kind.symbol, label: label, value: s.todayWords.grouped,
                            note: L(done ? "goal of %@ reached today" : "of %@ words today", goal.grouped),
                            trailing: AnyView(GoalRing(progress: Double(s.todayWords) / Double(goal))))
        }
    }
}

/// Speaking against typing: two bars, and how many times faster.
private struct SpeedView: View {
    let pace: Double
    let typing: Double
    let saved: Double
    @Environment(\.sayit) private var st

    private func bar(_ label: String, _ value: Double, top: Double, _ fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(st.font(10.5)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(fill)
                            .frame(width: value > 0 ? max(10, geo.size.width * value / top) : 0)
                    }
                }
                .frame(height: st.size(10))
                Text(L("%d wpm", Int(value.rounded()))).font(st.font(10.5)).monospacedDigit()
                    .frame(width: st.size(60), alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("%@: %d words a minute", label, Int(value.rounded())))
    }

    var body: some View {
        let top = max(pace, typing, 1)
        VStack(alignment: .leading, spacing: 10) {
            bar(L("Typing"), typing, top: top, Color.secondary.opacity(0.6))
            bar(L("Speaking"), pace, top: top, st.accent)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if pace > 0 && typing > 0 {
                    Text(String(format: "%.1f×", pace / typing))
                        .font(st.font(26, .bold)).monospacedDigit()
                        .foregroundStyle(st.accent)
                    Text(L(pace >= typing ? "faster, %@ saved" : "the speed of typing, %@ lost", Stats.duration(saved)))
                        .font(st.font(12)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Dictate to compare with typing").font(st.font(12)).foregroundStyle(.secondary)
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
    @Environment(\.sayit) private var st

    private struct Mark: Identifiable {
        let index: Int
        let text: String
        var id: Int { index }
    }

    /// The bucket the present is in.
    private var current: Int? { buckets.lastIndex(where: { $0.start <= Date() }) }

    private var scale: (step: Int, top: Int) { Stats.scale(buckets.map(\.words).max() ?? 0) }

    /// Room on the left for the scale's widest number.
    private var axisWidth: CGFloat { CGFloat(scale.top.grouped.count) * 6.5 * st.scale + 12 }

    private var marks: [Mark] {
        let n = buckets.count
        guard n > 0 else { return [] }
        let last = n - 1
        func label(_ i: Int) -> String {
            let d = buckets[i].start
            switch unit {
            case .hour: return String(format: "%02d", Calendar.current.component(.hour, from: d))
            case .weekOfYear: return i == last ? L("This week") : d.text(.dateTime.day().month(.abbreviated))
            default:
                if n <= 7 { return d.text(.dateTime.weekday(.abbreviated).day()) }
                return i == last ? L("Today") : d.text(.dateTime.day().month(.abbreviated))
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
        let accent = st.accent
        let axisFont = st.font(10)
        let axisLine = st.size(13)
        VStack(spacing: 6) {
            GeometryReader { geo in
                let n = max(buckets.count, 1)
                let slot = (geo.size.width - axis) / CGFloat(n)
                Canvas { ctx, size in
                    // Room above the top number and below the 0.
                    let bottom = size.height - 7, high: CGFloat = 7
                    let plot = bottom - high
                    func y(_ v: Int) -> CGFloat { scale.top > 0 ? bottom - plot * CGFloat(v) / CGFloat(scale.top) : bottom }
                    // The scale: a line per step, 0 included, and a number
                    // on each - on every other one when a short chart would
                    // crowd them.
                    if scale.step > 0 {
                        let steps = max(scale.top / scale.step, 1)
                        let every = plot / CGFloat(steps) < axisLine * 1.6 ? 2 : 1
                        for v in stride(from: 0, through: scale.top, by: scale.step) {
                            ctx.fill(Path(CGRect(x: axis, y: y(v) - 0.25, width: size.width - axis, height: 0.5)),
                                     with: .color(Color.primary.opacity(v == 0 ? 0.14 : 0.07)))
                            guard (v / scale.step) % every == 0 else { continue }
                            ctx.draw(Text(v.grouped).font(axisFont).foregroundStyle(.secondary).monospacedDigit(),
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
                                     with: .color(accent.opacity(alpha)))
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
                            .font(axisFont)
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
            .frame(height: st.size(14))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words per period")
        .accessibilityValue(L("%@ words in %d periods", buckets.reduce(0) { $0 + $1.words }.grouped, buckets.count))
    }
}

/// A year of days, one column a week, a deeper accent for more words.
private struct YearView: View {
    let year: YearMap
    let streak: Int
    let hovered: Int?
    let onHover: (Int?) -> Void
    @Environment(\.sayit) private var st

    private static let gap: CGFloat = 2.5
    /// Past about 20 points a cell stops looking like a calendar.
    static let maxStep: CGFloat = 20

    /// The card's width with days `step` apart: the weekday labels, the grid
    /// and the card's padding.
    static func width(step: CGFloat, scale: CGFloat) -> CGFloat {
        30 * scale + CGFloat(Stats.yearWeeks) * step + 32 * (1 + (scale - 1) * 0.5)
    }

    private var labelWidth: CGFloat { 30 * st.scale }
    private var monthHeight: CGFloat { 16 * st.scale }

    private func date(_ i: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: i, to: year.start) ?? year.start
    }

    private var readout: String {
        guard let i = hovered, year.words.indices.contains(i) else {
            return streak > 0 ? L(streak == 1 ? "%d day in a row" : "%d days in a row", streak) : ""
        }
        let n = year.words[i]
        return date(i).text(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            + (n > 0 ? " · " + L(n == 1 ? "%@ word" : "%@ words", n.grouped) : L(" · nothing dictated"))
    }

    /// The accent's opacity per level, 1 to 4.
    private static let shades: [Double] = [0, 0.3, 0.52, 0.76, 1]

    private func fill(_ level: Int) -> Color {
        if level <= 0 { return Color.primary.opacity(0.07) }
        return st.accent.opacity(Self.shades[min(level, 4)])
    }

    var body: some View {
        let columns = CGFloat(Stats.yearWeeks)
        let labelWidth = self.labelWidth, monthHeight = self.monthHeight
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(year.total == 1 ? "%@ word in the last year" : "%@ words in the last year", year.total.grouped))
                    .font(st.font(13, .bold))
                Spacer()
                Text(readout).font(st.font(12)).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .trailing, spacing: 8) {
                GeometryReader { geo in
                    let step = min((geo.size.width - labelWidth) / columns,
                                   (geo.size.height - monthHeight) / 7)
                    Canvas { ctx, _ in grid(ctx, step: step) }
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let p) = phase, step > 0 else {
                                if hovered != nil { onHover(nil) }
                                return
                            }
                            let c = Int((p.x - labelWidth) / step)
                            let r = Int((p.y - monthHeight) / step)
                            let i = c * 7 + r
                            let inside = p.x >= labelWidth && p.y >= monthHeight && r < 7
                            let found: Int? = inside && year.words.indices.contains(i) ? i : nil
                            if found != hovered { onHover(found) }
                        }
                }
                .aspectRatio(6.6, contentMode: .fit)
                HStack(spacing: 3) {
                    Text("Less").padding(.trailing, 2)
                    ForEach(0..<5) { l in
                        RoundedRectangle(cornerRadius: 2).fill(fill(l)).frame(width: st.size(10), height: st.size(10))
                    }
                    Text("More").padding(.leading, 2)
                }
                .font(st.font(10)).foregroundStyle(.secondary)
            }
            // The grid and its legend stop growing at `maxStep` and sit in the
            // middle.
            .frame(maxWidth: labelWidth + columns * Self.maxStep * st.scale)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A year of dictation")
        .accessibilityValue(L("%@ words, %d days with dictation", year.total.grouped, year.words.filter { $0 > 0 }.count))
    }

    private func grid(_ ctx: GraphicsContext, step: CGFloat) {
        let cell = max(step - Self.gap, 1)
        let labelFont = st.font(10)
        var cal = Calendar.current
        cal.locale = statsLocale
        var lastMonth = -1, lastLabel = -10
        for (i, level) in year.levels.enumerated() {
            let c = i / 7, r = i % 7
            let rect = CGRect(x: labelWidth + CGFloat(c) * step, y: monthHeight + CGFloat(r) * step,
                              width: cell, height: cell)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(2.5, cell / 4)), with: .color(fill(level)))
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
                        ctx.draw(Text(cal.shortMonthSymbols[month - 1]).font(labelFont)
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
            ctx.draw(Text(cal.shortWeekdaySymbols[weekday - 1]).font(labelFont).foregroundStyle(.secondary),
                     at: CGPoint(x: 0, y: monthHeight + CGFloat(r) * step + cell / 2), anchor: .leading)
        }
    }
}

// MARK: - History

private struct HistoryList: View {
    let rows: [HistoryRow]
    @ObservedObject var state: StatsViewState
    @Environment(\.sayit) private var st
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
                    .font(st.font(13))
                    .frame(width: 260 * st.scale)
                Spacer()
                Text(L(rows.count == 1 ? "%@ dictation" : "%@ dictations", rows.count.grouped))
                    .font(st.font(12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            if found.isEmpty {
                Text("Nothing in the history matches.")
                    .font(st.font(13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(found.prefix(HistoryList.limit)) { row in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.entry.time.text(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                                        .hour().minute())
                                     + " · " + L(row.entry.words == 1 ? "%@ word" : "%@ words", row.entry.words.grouped)
                                     + " · \(Stats.duration(row.entry.seconds))")
                                    .font(st.font(10.5)).foregroundStyle(.secondary)
                                Text(row.entry.text).font(st.font(13)).lineLimit(4).textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            Button(L(state.copied == row.id ? "Copied" : "Copy")) { copy(row) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                    }
                    if found.count > HistoryList.limit {
                        Text(L("The newest %d of %@ are shown. Search to find older ones.", HistoryList.limit, found.count.grouped))
                            .font(st.font(10.5)).foregroundStyle(.secondary)
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
