// Trigger.swift - the push-to-talk event tap.
//
// One session-level CGEventTap for keys, modifier changes and the extra mouse
// buttons, for the trigger and the optional second one (TRIGGER_BUTTON2):
// either starts a recording, and the one that started it ends it. It needs the Accessibility permission (an active tap can swallow
// events; a listen-only one cannot), and it is the only part of sayit that
// does: everything else is spawned from here and inherits the grant.
//
// The callback only decides and returns. Spawning happens in Runner, off the
// event path, so the tap never comes near the system's timeout - and if it is
// ever disabled anyway, it is re-enabled on the spot.
//
// Keyboard events are invisible to every tap while Secure Input is on (a
// password field, Terminal's Secure Keyboard Entry); mouse buttons are not.
// That is the reason to prefer a mouse button when one is available.

import AppKit

/// Stamped into eventSourceUserData by sayit-paste, so the paste chord sayit
/// itself posts is never mistaken for user input - the role dwExtraInfo plays
/// on Windows.
let sayitEventSignature: Int64 = 0x5341_5949_54   // "SAYIT"

final class Trigger {
    enum State { case idle, holding(since: TimeInterval), latched, spoiled }

    private(set) var specs: [TriggerSpec]
    private var suppress: Bool
    private var mode: TriggerMode
    private let runner: Runner
    private var tap: CFMachPort?
    private var state = State.idle
    /// The triggers (indices into `specs`) whose key is down.
    private var keysHeld: Set<Int> = []
    /// The trigger whose press started the recording being held.
    private var holder: Int?
    private var lastPress: TimeInterval = 0
    /// How long a press may go without bin/sayit having claimed its start
    /// before the trigger stops believing a recording exists.
    private let startGrace: TimeInterval = 1.5
    var probing = false
    var onProbe: ((String) -> Void)?
    /// Set by Record in Settings: the next mouse button, modifier key or key
    /// combination becomes the trigger, by its TRIGGER_BUTTON name, and is
    /// not passed on. Escape gives up (nil). A key that types a character
    /// counts only with Cmd, Ctrl or Option held: it would stop typing. One
    /// that types nothing, a menu key say, counts on its own.
    var capture: ((String?) -> Void)?
    /// A modifier pressed while recording: it is the trigger itself if it is
    /// let go with nothing pressed in between, else part of a combination.
    private var captureModifier: Int64?
    var onState: (() -> Void)?

    var isInstalled: Bool { tap != nil }
    /// True only while a recording plausibly exists: the trigger thinks so
    /// AND bin/sayit's session or start-intent file is there (or the press
    /// was a moment ago). A start that failed - microphone denied, no such
    /// device - must not leave Escape swallowed or the icon red.
    var isRecording: Bool {
        switch state {
        case .holding, .latched:
            return sessionIsLive() || ProcessInfo.processInfo.systemUptime - lastPress < startGrace
        default:
            return false
        }
    }

    /// The session last stopped for having lost its recorder, so a second
    /// tick before bin/sayit has claimed it does not stop it twice.
    private var endedSession = ""

    /// Called once a second: drops a latch whose recording no longer exists
    /// (a failed start, a stop or cancel from the terminal), and stops a
    /// recording whose recorder has exited on its own - MAX_RECORD_SECONDS,
    /// or a device that went away - so what was captured is transcribed now,
    /// not at the next press, which could come hours later in another window.
    func reconcile() {
        if let session = endedRecording() {
            if session != endedSession {
                endedSession = session
                runner.stop()
                state = .idle
                onState?()
            }
            return
        }
        if case .latched = state, !isRecording {
            state = .idle
            onState?()
        }
    }

    /// The session line, when its recorder is gone. bin/sayit checks the
    /// recorder 0.3 s after spawning it and retracts a session whose
    /// recorder died at once, so only sessions older than 2 s count.
    private func endedRecording() -> String? {
        guard let line = try? String(contentsOfFile: Shared.runPath("sayit.session"), encoding: .utf8),
              !FileManager.default.fileExists(atPath: Shared.runPath("sayit.starting")) else { return nil }
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        guard fields.count >= 3, let pid = pid_t(fields[0]), pid > 0, let start = Double(fields[2]),
              Date().timeIntervalSince1970 - start > 2 else { return nil }
        return kill(pid, 0) != 0 && errno == ESRCH ? line : nil
    }

    init(config: AgentConfig, runner: Runner) {
        specs = config.triggers
        suppress = config.suppress
        mode = config.mode
        self.runner = runner
    }

    func update(config: AgentConfig) {
        if specs != config.triggers {
            keysHeld.removeAll()
            holder = nil
        }
        specs = config.triggers
        suppress = config.suppress
        mode = config.mode
    }

    /// Creates the tap. Returns false while the permission is missing; the
    /// caller retries.
    @discardableResult
    func install() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info = info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<Trigger>.fromOpaque(info).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        return true
    }

    // MARK: - Event handling (main thread)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == sayitEventSignature { return pass }
        if capture != nil { return record(type, event) }
        if probing { onProbe?(describe(type, event)) }
        guard !specs.isEmpty else { return pass }

        let now = ProcessInfo.processInfo.systemUptime
        let flags = event.flags.rawValue
        switch type {
        case .keyDown:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let match = specs.firstIndex {
                if case let .key(code, mods) = $0.kind { return code == keycode && flags & TriggerSpec.modifierFlags == mods }
                return false
            }
            if let i = match {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { press(now, by: i) }
                keysHeld.insert(i)
                return suppress ? nil : pass
            }
            // Any other key while a modifier trigger is held means a
            // shortcut, not a dictation: drop the recording rather than
            // transcribe it.
            if case .holding = state, let h = holder, specs.indices.contains(h), case .modifier = specs[h].kind {
                runner.cancel()
                state = .spoiled
                onState?()
                return pass
            }
            return escapeOrPass(keycode, flags, pass)
        case .keyUp:
            // Matched to the down we acted on, not to the modifiers: a vendor
            // utility may let go of them first.
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let match = keysHeld.first {
                if specs.indices.contains($0), case let .key(code, _) = specs[$0].kind { return code == keycode }
                return false
            }
            if let i = match {
                keysHeld.remove(i)
                release(now, by: i)
                return suppress ? nil : pass
            }
            return pass
        case .flagsChanged:
            // A modifier is never swallowed: the system's idea of which keys
            // are down must stay intact.
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            for (i, spec) in specs.enumerated() {
                if case let .modifier(code, deviceMask) = spec.kind, code == keycode {
                    if flags & deviceMask != 0 { press(now, by: i) } else { release(now, by: i) }
                    break
                }
            }
            return pass
        case .otherMouseDown, .otherMouseUp:
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            let match = specs.firstIndex {
                if case let .mouse(button) = $0.kind { return button == number }
                return false
            }
            guard let i = match else { return pass }
            if type == .otherMouseDown { press(now, by: i) } else { release(now, by: i) }
            return suppress ? nil : pass
        default:
            return pass
        }
    }

    /// Escape on its own discards a recording in progress, like `sayit cancel`.
    private func escapeOrPass(_ keycode: Int64, _ flags: UInt64, _ pass: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {
        guard keycode == 53, flags & TriggerSpec.modifierFlags == 0, isRecording else { return pass }
        runner.cancel()
        state = .idle
        onState?()
        return nil
    }

    private func sessionIsLive() -> Bool {
        FileManager.default.fileExists(atPath: Shared.runPath("sayit.session"))
            || FileManager.default.fileExists(atPath: Shared.runPath("sayit.starting"))
    }

    private func press(_ now: TimeInterval, by trigger: Int) {
        switch state {
        case .idle:
            runner.start()
            lastPress = now
            holder = trigger
            state = .holding(since: now)
        case .latched:
            // The recording may have ended without us: a start that failed,
            // a stop from the terminal. Then this press means start, not stop.
            if sessionIsLive() {
                runner.stop()
                state = .idle
            } else {
                runner.start()
                lastPress = now
                holder = trigger
                state = .holding(since: now)
            }
        case .holding, .spoiled:
            return
        }
        onState?()
    }

    /// Only the trigger that started a hold ends it: letting go of the
    /// other one, pressed meanwhile, changes nothing.
    private func release(_ now: TimeInterval, by trigger: Int) {
        if let h = holder, h != trigger { return }
        switch state {
        case let .holding(since):
            let held = now - since
            if mode == .hold || (mode == .auto && held >= AgentConfig.holdThreshold) {
                runner.stop()
                state = .idle
            } else {
                state = .latched
            }
        case .spoiled:
            state = .idle
        case .idle, .latched:
            return
        }
        onState?()
    }

    // MARK: - Record

    private func record(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        func finish(_ name: String?) {
            let done = capture
            capture = nil
            captureModifier = nil
            done?(name)
        }
        switch type {
        case .otherMouseDown:
            finish(TriggerSpec.name(mouse: event.getIntegerValueField(.mouseEventButtonNumber)))
            return nil
        case .otherMouseUp:
            return nil
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = event.flags.rawValue & TriggerSpec.modifierFlags
            if code == 53 && mods == 0 {
                finish(nil)
                return nil
            }
            let held = mods & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
                               | CGEventFlags.maskAlternate.rawValue)
            guard Trigger.silentKeys.contains(code) || Trigger.typesNothing(event) || held != 0 else { return nil }
            finish(TriggerSpec.name(key: code, modifiers: mods))
            return nil
        case .keyUp:
            return nil
        case .flagsChanged:
            // Modifiers always pass: the system must know which are down.
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard let mask = TriggerSpec.deviceMask(modifier: code) else { return pass }
            if event.flags.rawValue & mask != 0 {
                captureModifier = code
            } else if captureModifier == code {
                finish(TriggerSpec.name(modifier: code))
            }
            return pass
        default:
            return pass
        }
    }

    // MARK: - Probe

    /// Keys that type no character: safe to name in a probe log. Every other
    /// key is named only with Cmd or Ctrl held - a shortcut, not text - so
    /// a probe left running never records what was typed.
    private static let silentKeys: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,   // F1-F12
        105, 107, 113, 106, 64, 79, 80, 90,                       // F13-F20
        53, 123, 124, 125, 126, 115, 119, 116, 121, 114, 117,     // Esc, arrows, navigation
    ]

    /// A key that types nothing: no character, or only a function-key or
    /// control character - a menu key or a vendor's extra key, not a letter,
    /// and not Return, Tab, Backspace or Enter either. Safe to name in a probe
    /// log and to record as a trigger.
    static func typesNothing(_ event: CGEvent) -> Bool {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        return chars.prefix(length).allSatisfy {
            ($0 < 0x20 && ![0x03, 0x08, 0x09, 0x0D].contains($0)) || (0xF700...0xF8FF).contains($0)
        }
    }

    func describe(_ type: CGEventType, _ event: CGEvent) -> String {
        let flags = event.flags
        var mods: [String] = []
        if flags.contains(.maskControl) { mods.append("CTRL") }
        if flags.contains(.maskAlternate) { mods.append("OPTION") }
        if flags.contains(.maskShift) { mods.append("SHIFT") }
        if flags.contains(.maskCommand) { mods.append("CMD") }
        if flags.contains(.maskSecondaryFn) { mods.append("FN") }
        let m = mods.isEmpty ? "" : " [\(mods.joined(separator: "+"))]"
        switch type {
        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)
            guard Trigger.silentKeys.contains(code) || shortcut || Trigger.typesNothing(event) else {
                return "key \(type == .keyDown ? "down" : "up") (a typing key - not recorded)"
            }
            let rep = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? " repeat" : ""
            return "key \(type == .keyDown ? "down" : "up") KEY\(code)\(m)\(rep)"
        case .flagsChanged:
            return "modifier KEY\(event.getIntegerValueField(.keyboardEventKeycode))\(m)"
        case .otherMouseDown, .otherMouseUp:
            let b = event.getIntegerValueField(.mouseEventButtonNumber)
            return "mouse \(type == .otherMouseDown ? "down" : "up") MOUSE\(b)\(m)"
        default:
            return "event \(type.rawValue)"
        }
    }
}
