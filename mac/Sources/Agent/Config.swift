// Config.swift - the agent's settings, read from the repository's .env.
//
// The names are the Windows ones (TRIGGER_BUTTON, TRIGGER_SUPPRESS, the
// INDICATOR_* family), so one .env means the same thing on every platform. The
// values a Mac can name differ: see .env.example and docs/CONFIGURATION.md.

import AppKit

struct TriggerSpec: Equatable {
    enum Kind: Equatable {
        /// An ordinary key, optionally with modifiers that must be held.
        case key(code: Int64, modifiers: UInt64)
        /// A modifier key on its own, told apart by its device-dependent bit.
        case modifier(code: Int64, deviceMask: UInt64)
        /// A mouse button other than left and right (2 = middle, 3/4 = side).
        case mouse(button: Int64)
    }
    let kind: Kind
    let label: String

    static let modifierFlags: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

    private static let functionKeys: [String: Int64] = [
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100,
        "F9": 101, "F10": 109, "F11": 103, "F12": 111, "F13": 105, "F14": 107, "F15": 113,
        "F16": 106, "F17": 64, "F18": 79, "F19": 80, "F20": 90,
    ]
    private static let namedKeys: [String: Int64] = [
        "ESCAPE": 53, "SPACE": 49, "TAB": 48, "RETURN": 36, "HOME": 115, "END": 119,
        "PAGEUP": 116, "PAGEDOWN": 121, "HELP": 114,
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
        "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "O": 31, "U": 32,
        "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]
    // Device-dependent modifier bits (NX_DEVICE*KEYMASK): they tell left from right.
    private static let modifierKeys: [String: (Int64, UInt64)] = [
        "RIGHTOPTION": (61, 0x40), "LEFTOPTION": (58, 0x20),
        "RIGHTCOMMAND": (54, 0x10), "LEFTCOMMAND": (55, 0x08),
        "RIGHTCONTROL": (62, 0x2000), "LEFTCONTROL": (59, 0x01),
        "RIGHTSHIFT": (60, 0x04), "LEFTSHIFT": (56, 0x02),
        "FN": (63, CGEventFlags.maskSecondaryFn.rawValue),
    ]
    private static let comboModifiers: [String: UInt64] = [
        "CMD": CGEventFlags.maskCommand.rawValue, "COMMAND": CGEventFlags.maskCommand.rawValue,
        "OPT": CGEventFlags.maskAlternate.rawValue, "OPTION": CGEventFlags.maskAlternate.rawValue,
        "ALT": CGEventFlags.maskAlternate.rawValue,
        "CTRL": CGEventFlags.maskControl.rawValue, "CONTROL": CGEventFlags.maskControl.rawValue,
        "SHIFT": CGEventFlags.maskShift.rawValue,
    ]

    /// Parses TRIGGER_BUTTON. Accepts the Windows mouse names (MIDDLE,
    /// XBUTTON1, XBUTTON2) and VK124..VK131 (F13..F20) as they are, plus
    /// MOUSE<n>, key names, KEY<code> and combinations such as CTRL+OPTION+F12.
    static func parse(_ raw: String) -> TriggerSpec? {
        let value = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !value.isEmpty else { return nil }
        switch value {
        case "MIDDLE": return TriggerSpec(kind: .mouse(button: 2), label: "the middle mouse button")
        case "XBUTTON1": return TriggerSpec(kind: .mouse(button: 3), label: "mouse button 4 (back)")
        case "XBUTTON2": return TriggerSpec(kind: .mouse(button: 4), label: "mouse button 5 (forward)")
        default: break
        }
        for prefix in ["MOUSE", "BUTTON"] where value.hasPrefix(prefix) {
            guard let n = Int64(value.dropFirst(prefix.count)), n >= 2, n <= 31 else { return nil }
            return TriggerSpec(kind: .mouse(button: n), label: "mouse button \(n + 1)")
        }
        if value.hasPrefix("VK"), let vk = Int(value.dropFirst(2)), (124...131).contains(vk) {
            return parse("F\(vk - 111)")
        }
        if let (code, mask) = modifierKeys[value] {
            return TriggerSpec(kind: .modifier(code: code, deviceMask: mask), label: raw.trimmingCharacters(in: .whitespaces))
        }
        var parts = value.split(separator: "+").map(String.init)
        guard let last = parts.popLast() else { return nil }
        var mods: UInt64 = 0
        for p in parts {
            guard let m = comboModifiers[p] else { return nil }
            mods |= m
        }
        let code: Int64
        if let f = functionKeys[last] {
            code = f
        } else if let k = namedKeys[last] {
            code = k
        } else if last.hasPrefix("KEY"), let k = Int64(last.dropFirst(3)), (0...127).contains(k) {
            // A modifier's code, as the probe prints it, means that modifier.
            if parts.isEmpty, let (name, (_, mask)) = modifierKeys.first(where: { $0.value.0 == k }) {
                return TriggerSpec(kind: .modifier(code: k, deviceMask: mask), label: name.lowercased())
            }
            code = k
        } else {
            return nil
        }
        return TriggerSpec(kind: .key(code: code, modifiers: mods), label: raw.trimmingCharacters(in: .whitespaces))
    }
}

enum TriggerMode: String {
    /// Held at least holdThreshold: release stops (push-to-talk). A shorter
    /// tap latches, and the next press stops - so a button whose vendor
    /// utility sends a tap instead of a hold still works.
    case auto
    case hold
    case toggle
}

struct AgentConfig {
    let repository: String
    let trigger: TriggerSpec?
    let triggerRaw: String
    let suppress: Bool
    let mode: TriggerMode
    let indicator: Bool
    let resident: Bool
    let locked: Bool
    let scale: CGFloat
    let excludeFromCapture: Bool

    static let defaultTrigger = "F18"
    static let holdThreshold: TimeInterval = 0.4

    init(repository: String) {
        self.repository = repository
        let env = Shared.readEnv((repository as NSString).appendingPathComponent(".env"))
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            guard let v = env[key], !v.isEmpty else { return fallback }
            return v != "0"
        }
        triggerRaw = (env["TRIGGER_BUTTON"].flatMap { $0.isEmpty ? nil : $0 }) ?? AgentConfig.defaultTrigger
        // TRIGGER_LABEL names the button in the menu when what the system
        // sees differs from what is under your thumb (a vendor utility can
        // send a mouse's thumb button as button 5, say).
        let label = (env["TRIGGER_LABEL"] ?? "").trimmingCharacters(in: .whitespaces)
        trigger = TriggerSpec.parse(triggerRaw).map { label.isEmpty ? $0 : TriggerSpec(kind: $0.kind, label: label) }
        suppress = flag("TRIGGER_SUPPRESS", true)
        mode = TriggerMode(rawValue: (env["TRIGGER_MODE"] ?? "").lowercased()) ?? .auto
        indicator = flag("RECORDING_INDICATOR", true)
        resident = flag("INDICATOR_RESIDENT", false)
        locked = flag("INDICATOR_LOCKED", false)
        let s = Double(env["INDICATOR_SCALE"] ?? "") ?? 1.0
        scale = CGFloat((0.5...4.0).contains(s) ? s : 1.0)
        excludeFromCapture = flag("INDICATOR_EXCLUDE_FROM_CAPTURE", true)
    }

    /// The repository holding bin/sayit: SAYIT_REPO (set by the LaunchAgent),
    /// else the path recorded in Info.plist when the app was built.
    static func repositoryPath() -> String? {
        if let r = ProcessInfo.processInfo.environment["SAYIT_REPO"], !r.isEmpty { return r }
        return Bundle.main.object(forInfoDictionaryKey: "SayitRepository") as? String
    }
}
