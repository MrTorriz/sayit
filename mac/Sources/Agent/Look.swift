// Look.swift - how Sayit's windows look, as chosen under Settings >
// Appearance: the text size, the accent colour, light or dark, the cards, and
// what the Statistics window shows in which order.
//
// Kept in Sayit's own defaults (io.github.mrtorriz.sayit), not in .env: only
// the app reads it, and it belongs to the Mac it was chosen on.

import AppKit
import SwiftUI

enum AccentChoice: String, CaseIterable, Identifiable {
    case red, amber, green, blue, purple, graphite
    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return L("Sayit Red")
        case .amber: return L("Amber")
        case .green: return L("Green")
        case .blue: return L("Blue")
        case .purple: return L("Purple")
        case .graphite: return L("Graphite")
        }
    }

    /// A lighter shade on dark, a deeper one on light, where the dark mode's
    /// would be too faint for small text. The red is the README's.
    var nsColor: NSColor {
        let (dark, light): (UInt32, UInt32)
        switch self {
        case .red: (dark, light) = (0xFF4D4D, 0xDA4453)
        case .amber: (dark, light) = (0xFFA23E, 0xC46A00)
        case .green: (dark, light) = (0x3ED67F, 0x1F8D4C)
        case .blue: (dark, light) = (0x4AA3FF, 0x0A63D1)
        case .purple: (dark, light) = (0xB07CFF, 0x7740CF)
        case .graphite: (dark, light) = (0xD0D0D0, 0x4B4B4F)
        }
        func rgb(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { L(rawValue.capitalized) }
    /// nil follows macOS.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum CardStyle: String, CaseIterable, Identifiable {
    case glass, solid
    var id: String { rawValue }
    var title: String { L(rawValue.capitalized) }
}

enum LayoutChoice: String, CaseIterable, Identifiable {
    case automatic, side, stacked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return L("Automatic")
        case .side: return L("Side Panel")
        case .stacked: return L("Stacked")
        }
    }
}

enum OpenChoice: String, CaseIterable, Identifiable {
    case lastPlace, quarter, centred
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lastPlace: return L("Where You Left It")
        case .quarter: return L("Top Left Quarter")
        case .centred: return L("Centred")
        }
    }
}

/// The Statistics window's cards, in the order of the Settings list.
enum TileKind: String, CaseIterable, Identifiable {
    case streak, peakHour, bestDay, perDictation, latency, apps, goal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .streak: return L("Streak")
        case .peakHour: return L("Peak hour")
        case .bestDay: return L("Best day")
        case .perDictation: return L("Per dictation")
        case .latency: return L("Release to text")
        case .apps: return L("Where you dictate")
        case .goal: return L("Daily goal")
        }
    }

    var detail: String {
        switch self {
        case .streak: return L("Days in a row with a dictation")
        case .peakHour: return L("Your busiest hour, and all 24 hours as bars")
        case .bestDay: return L("The day with the most words")
        case .perDictation: return L("The average length of a dictation")
        case .latency: return L("How soon the text is there after you let go")
        case .apps: return L("Words per app, by the app's name only")
        case .goal: return L("Today's words against your daily goal")
        }
    }

    var symbol: String {
        switch self {
        case .streak: return "flame"
        case .peakHour: return "clock"
        case .bestDay: return "trophy"
        case .perDictation: return "text.bubble"
        case .latency: return "bolt"
        case .apps: return "square.grid.2x2"
        case .goal: return "target"
        }
    }

    var onByDefault: Bool { self != .goal }
}

struct TextScale: Identifiable {
    let value: Double
    let title: String
    var id: Double { value }
}

struct TileSetting: Equatable, Identifiable {
    var kind: TileKind
    var on: Bool
    var id: TileKind { kind }
}

final class Look: ObservableObject {
    static let shared = Look()

    /// The text sizes the Settings window offers, and ⌘+ and ⌘− step through.
    static let textScales = [
        TextScale(value: 1.0, title: L("Default")), TextScale(value: 1.15, title: L("Large")),
        TextScale(value: 1.3, title: L("Larger")), TextScale(value: 1.5, title: L("Largest")),
    ]

    private let defaults = UserDefaults.standard

    @Published var textScale: Double { didSet { defaults.set(textScale, forKey: "textScale") } }
    @Published var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    @Published var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var cards: CardStyle { didSet { defaults.set(cards.rawValue, forKey: "cards") } }
    @Published var glow: Bool { didSet { defaults.set(glow, forKey: "glow") } }
    @Published var layout: LayoutChoice { didSet { defaults.set(layout.rawValue, forKey: "statsLayout") } }
    @Published var openAt: OpenChoice { didSet { defaults.set(openAt.rawValue, forKey: "statsOpenAt") } }
    @Published var showChart: Bool { didSet { defaults.set(showChart, forKey: "showChart") } }
    @Published var showYear: Bool { didSet { defaults.set(showYear, forKey: "showYear") } }
    @Published var showSpeed: Bool { didSet { defaults.set(showSpeed, forKey: "showSpeed") } }
    @Published var tiles: [TileSetting] {
        didSet { defaults.set(tiles.map { "\($0.kind.rawValue):\($0.on ? 1 : 0)" }, forKey: "statsTiles") }
    }
    @Published var menuCount: Bool { didSet { defaults.set(menuCount, forKey: "menuBarCount") } }
    @Published var dailyGoal: Int { didSet { defaults.set(dailyGoal, forKey: "dailyGoal") } }

    private init() {
        let d = UserDefaults.standard
        func flag(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
        // The nearest size offered: a value written as a float reads back
        // as 1.2999999523, which no picker segment would match.
        let scale = d.double(forKey: "textScale")
        textScale = Look.textScales.map(\.value).min { abs($0 - scale) < abs($1 - scale) } ?? 1.0
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .red
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        cards = CardStyle(rawValue: d.string(forKey: "cards") ?? "") ?? .glass
        glow = flag("glow", true)
        layout = LayoutChoice(rawValue: d.string(forKey: "statsLayout") ?? "") ?? .automatic
        openAt = OpenChoice(rawValue: d.string(forKey: "statsOpenAt") ?? "") ?? .lastPlace
        showChart = flag("showChart", true)
        showYear = flag("showYear", true)
        showSpeed = flag("showSpeed", true)
        menuCount = flag("menuBarCount", false)
        let goal = d.integer(forKey: "dailyGoal")
        dailyGoal = goal > 0 ? goal : 2000
        tiles = Look.decodeTiles(d.stringArray(forKey: "statsTiles"))
    }

    /// The saved order, with unknown cards dropped and new ones added last.
    static func decodeTiles(_ saved: [String]?) -> [TileSetting] {
        var out: [TileSetting] = []
        for item in saved ?? [] {
            let parts = item.split(separator: ":")
            guard parts.count == 2, let kind = TileKind(rawValue: String(parts[0])),
                  !out.contains(where: { $0.kind == kind }) else { continue }
            out.append(TileSetting(kind: kind, on: parts[1] == "1"))
        }
        for kind in TileKind.allCases where !out.contains(where: { $0.kind == kind }) {
            out.append(TileSetting(kind: kind, on: kind.onByDefault))
        }
        return out
    }

    var textScaleTitle: String {
        Look.textScales.min { abs($0.value - textScale) < abs($1.value - textScale) }?.title ?? L("Default")
    }

    /// ⌘+ and ⌘−: the next size up or down; ⌘0 the default.
    func stepText(_ direction: Int) {
        let values = Look.textScales.map(\.value)
        if direction == 0 { textScale = 1.0; return }
        if direction > 0, let next = values.first(where: { $0 > textScale + 0.001 }) { textScale = next }
        if direction < 0, let next = values.last(where: { $0 < textScale - 0.001 }) { textScale = next }
    }

    func move(_ kind: TileKind, by offset: Int) {
        guard let i = tiles.firstIndex(where: { $0.kind == kind }) else { return }
        let j = i + offset
        guard tiles.indices.contains(j) else { return }
        tiles.swapAt(i, j)
    }

    var style: SayitStyle {
        SayitStyle(scale: CGFloat(textScale), accent: accent.color, solid: cards == .solid, glow: glow)
    }
}

/// What the Statistics window's views draw with: the text size, the accent,
/// the card style and the glow.
struct SayitStyle {
    var scale: CGFloat = 1
    var accent: Color = AccentChoice.red.color
    var solid = false
    var glow = true

    /// The big figure and the lockup grow at half the rate of the text, so
    /// a larger text size reads better without the poster taking over.
    var heroScale: CGFloat { 1 + (scale - 1) * 0.5 }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    func size(_ points: CGFloat) -> CGFloat { points * scale }
}

private struct SayitStyleKey: EnvironmentKey {
    static let defaultValue = SayitStyle()
}

extension EnvironmentValues {
    var sayit: SayitStyle {
        get { self[SayitStyleKey.self] }
        set { self[SayitStyleKey.self] = newValue }
    }
}
