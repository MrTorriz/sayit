// Trigger.swift - the push-to-talk event tap.
//
// One session-level CGEventTap for keys, modifier changes and the extra mouse
// buttons. It needs the Accessibility permission (an active tap can swallow
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

    private(set) var spec: TriggerSpec?
    private var suppress: Bool
    private var mode: TriggerMode
    private let runner: Runner
    private var tap: CFMachPort?
    private var state = State.idle
    private var keyHeld = false
    private var lastPress: TimeInterval = 0
    /// How long a press may go without bin/sayit having claimed its start
    /// before the trigger stops believing a recording exists.
    private let startGrace: TimeInterval = 1.5
    var probing = false
    var onProbe: ((String) -> Void)?
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
        spec = config.trigger
        suppress = config.suppress
        mode = config.mode
        self.runner = runner
    }

    func update(config: AgentConfig) {
        spec = config.trigger
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
        if probing { onProbe?(describe(type, event)) }
        guard let spec = spec else { return pass }

        let now = ProcessInfo.processInfo.systemUptime
        let flags = event.flags.rawValue
        switch (spec.kind, type) {
        case let (.key(code, mods), .keyDown):
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == code && (flags & TriggerSpec.modifierFlags) == mods {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { press(now) }
                keyHeld = true
                return suppress ? nil : pass
            }
            return escapeOrPass(keycode, flags, pass)
        case let (.key(code, _), .keyUp):
            // Matched to the down we acted on, not to the modifiers: a vendor
            // utility may let go of them first.
            if event.getIntegerValueField(.keyboardEventKeycode) == code && keyHeld {
                keyHeld = false
                release(now)
                return suppress ? nil : pass
            }
            return pass
        case let (.modifier(code, deviceMask), .flagsChanged):
            // A modifier is never swallowed: the system's idea of which keys
            // are down must stay intact.
            if event.getIntegerValueField(.keyboardEventKeycode) == code {
                if flags & deviceMask != 0 { press(now) } else { release(now) }
            }
            return pass
        case (.modifier, .keyDown):
            // Any other key while the modifier is held means a shortcut, not
            // a dictation: drop the recording rather than transcribe it.
            if case .holding = state {
                runner.cancel()
                state = .spoiled
                onState?()
                return pass
            }
            return escapeOrPass(event.getIntegerValueField(.keyboardEventKeycode), flags, pass)
        case let (.mouse(button), .otherMouseDown):
            if event.getIntegerValueField(.mouseEventButtonNumber) == button {
                press(now)
                return suppress ? nil : pass
            }
            return pass
        case let (.mouse(button), .otherMouseUp):
            if event.getIntegerValueField(.mouseEventButtonNumber) == button {
                release(now)
                return suppress ? nil : pass
            }
            return pass
        case (.mouse, .keyDown):
            return escapeOrPass(event.getIntegerValueField(.keyboardEventKeycode), flags, pass)
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

    private func press(_ now: TimeInterval) {
        switch state {
        case .idle:
            runner.start()
            lastPress = now
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
                state = .holding(since: now)
            }
        case .holding, .spoiled:
            return
        }
        onState?()
    }

    private func release(_ now: TimeInterval) {
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

    // MARK: - Probe

    /// Keys that type no character: safe to name in a probe log. Every other
    /// key is named only with Cmd or Ctrl held - a shortcut, not text - so
    /// a probe left running never records what was typed.
    private static let silentKeys: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,   // F1-F12
        105, 107, 113, 106, 64, 79, 80, 90,                       // F13-F20
        53, 123, 124, 125, 126, 115, 119, 116, 121, 114, 117,     // Esc, arrows, navigation
    ]

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
            guard Trigger.silentKeys.contains(code) || shortcut else {
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
