// ConfigTests.swift - unit tests for the agent's trigger parser and settings,
// the .env reader and the pill's level rule.
//
// Plain checks with a failure counter rather than XCTest, which needs a full
// Xcode: the Command Line Tools are enough. check() is used instead of assert(),
// which -O compiles away. Built and run by mac/tests/run.sh together with
// mac/Sources/Common/*.swift and mac/Sources/Agent/Config.swift.

import CoreGraphics
import Foundation

@main
enum ConfigTests {
    static var checks = 0
    static var failures = 0

    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL ConfigTests.swift:\(line): \(what)")
        }
    }

    static func close(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    // A file in this run's temporary directory, removed by run.sh.
    static func tempFile(_ name: String, _ text: String) -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    static func main() {
        triggerSpec()
        readEnv()
        agentConfig()
        pillGeometry()
        if failures > 0 {
            print("\(failures) of \(checks) checks failed")
            exit(1)
        }
        print("all \(checks) checks passed")
    }

    // --- TriggerSpec.parse ------------------------------------------------

    static func kind(_ raw: String) -> TriggerSpec.Kind? { TriggerSpec.parse(raw)?.kind }

    static func triggerSpec() {
        let cmd = CGEventFlags.maskCommand.rawValue
        let opt = CGEventFlags.maskAlternate.rawValue
        let ctrl = CGEventFlags.maskControl.rawValue

        // The Windows mouse names, as they are.
        check(kind("MIDDLE") == .mouse(button: 2), "MIDDLE is mouse button 2")
        check(kind("XBUTTON1") == .mouse(button: 3), "XBUTTON1 is mouse button 3 (back)")
        check(kind("XBUTTON2") == .mouse(button: 4), "XBUTTON2 is mouse button 4 (forward)")
        check(TriggerSpec.parse("XBUTTON2")?.label == "mouse button 5 (forward)", "XBUTTON2 label")
        // MOUSE<n> and BUTTON<n> name the Core Graphics button number (0 = left).
        check(kind("MOUSE5") == .mouse(button: 5), "MOUSE5 is mouse button 5")
        check(TriggerSpec.parse("MOUSE5")?.label == "mouse button 6", "MOUSE5 label counts from 1")
        check(kind("BUTTON3") == .mouse(button: 3), "BUTTON3 is mouse button 3")
        check(kind("MOUSE1") == nil, "MOUSE1 (right button) is rejected")
        check(kind("MOUSE0") == nil, "MOUSE0 (left button) is rejected")
        check(kind("MOUSE32") == nil, "MOUSE32 is out of range")

        // Keys: names, F-keys, the Windows VK124..VK131 and raw key codes.
        check(kind("F18") == .key(code: 79, modifiers: 0), "F18 is key code 79")
        check(kind(" f18 ") == .key(code: 79, modifiers: 0), "case and surrounding spaces do not matter")
        check(kind("VK124") == .key(code: 105, modifiers: 0), "VK124 is F13 (key code 105)")
        check(kind("VK131") == kind("F20"), "VK131 is F20")
        check(kind("VK123") == nil, "VK123 is outside VK124..VK131")
        check(kind("KEY105") == .key(code: 105, modifiers: 0), "KEY105 is key code 105")
        check(kind("KEY128") == nil, "KEY128 is out of range")
        check(kind("SPACE") == .key(code: 49, modifiers: 0), "SPACE is key code 49")

        // A modifier on its own, told apart by its device-dependent bit.
        check(kind("RIGHTOPTION") == .modifier(code: 61, deviceMask: 0x40), "RIGHTOPTION")
        check(kind("LEFTOPTION") == .modifier(code: 58, deviceMask: 0x20), "LEFTOPTION")
        check(kind("FN") == .modifier(code: 63, deviceMask: CGEventFlags.maskSecondaryFn.rawValue), "FN")
        check(TriggerSpec.parse(" RightOption ")?.label == "RightOption", "a key label keeps the spelling, trimmed")
        // A modifier's key code on its own, as the probe prints it, is that modifier.
        check(kind("KEY61") == .modifier(code: 61, deviceMask: 0x40), "KEY61 is the right Option key")
        check(TriggerSpec.parse("KEY61")?.label == "rightoption", "KEY61 is labelled by the modifier's name")
        check(kind("KEY63") == kind("FN"), "KEY63 is fn")
        check(kind("CTRL+KEY61") == .key(code: 61, modifiers: ctrl), "with modifiers, KEY61 stays a key")

        // Combinations.
        check(kind("CTRL+OPTION+F12") == .key(code: 111, modifiers: ctrl | opt), "CTRL+OPTION+F12")
        check(kind("cmd+shift+space") == .key(code: 49, modifiers: cmd | CGEventFlags.maskShift.rawValue),
              "cmd+shift+space")
        check(kind("ALT+F1") == kind("OPT+F1"), "ALT and OPT are the same modifier")
        check(kind("CTRL+BOGUS+F12") == nil, "an unknown modifier rejects the combination")
        check(kind("CTRL+") == nil, "a combination without a key is rejected")

        // Garbage.
        check(kind("garbage") == nil, "garbage is rejected")
        check(kind("") == nil, "an empty value is rejected")
        check(kind("   ") == nil, "a blank value is rejected")
    }

    // --- Shared.readEnv ---------------------------------------------------

    static func readEnv() {
        let home = NSHomeDirectory()
        let path = tempFile("sayit-tests.env", """
            # a comment
            PLAIN=value
            DQ="double quoted # not a comment"
            SQ='single quoted'
            export EXPORTED=yes
            HOMEVAR=$HOME/models/x.bin
            HOMEBRACE="${HOME}/y"
            TRAIL=abc # trailing comment
            TABBED=abc\t# a comment after a tab
            WITHHASH=a#b
            QTRAIL="q" # after the quote
            LATER=first
            LATER=second
            1BAD=nope
            BAD-KEY=nope
             SPACED = padded
            EMPTY=
            NOEQUALS
            """)
        let env = Shared.readEnv(path)
        check(env["PLAIN"] == "value", "a plain value")
        check(env["DQ"] == "double quoted # not a comment", "double quotes are stripped, # inside kept")
        check(env["SQ"] == "single quoted", "single quotes are stripped")
        check(env["EXPORTED"] == "yes", "export is accepted")
        check(env["HOMEVAR"] == home + "/models/x.bin", "$HOME is expanded")
        check(env["HOMEBRACE"] == home + "/y", "${HOME} is expanded")
        check(env["TRAIL"] == "abc", "a trailing comment is dropped")
        check(env["TABBED"] == "abc", "a trailing comment after a tab is dropped")
        check(env["WITHHASH"] == "a#b", "a # inside an unquoted value is kept")
        check(env["QTRAIL"] == "q", "a comment after a quoted value is dropped")
        check(env["LATER"] == "second", "a later assignment wins")
        check(env["1BAD"] == nil, "a key starting with a digit is ignored")
        check(env["BAD-KEY"] == nil, "a key with a dash is ignored")
        check(env["SPACED"] == "padded", "spaces around key and value are trimmed")
        check(env["EMPTY"] == "", "an empty value is kept as empty")
        check(env["NOEQUALS"] == nil, "a line without = is ignored")
        check(env.count == 13, "exactly the valid keys are read (got \(env.count))")
        check(Shared.readEnv(path + ".missing").isEmpty, "a missing file reads as empty")
    }

    // --- AgentConfig ------------------------------------------------------

    static func agentConfig() {
        let fm = FileManager.default
        let repo = (NSTemporaryDirectory() as NSString).appendingPathComponent("sayit-tests-repo")
        try? fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let envPath = (repo as NSString).appendingPathComponent(".env")

        try? fm.removeItem(atPath: envPath)
        var c = AgentConfig(repository: repo)
        check(c.triggerRaw == "F18" && c.trigger?.kind == .key(code: 79, modifiers: 0),
              "no .env means the F18 default")
        check(c.suppress && c.indicator && c.excludeFromCapture, "flags default on")
        check(!c.resident && !c.locked, "resident and locked default off")
        check(c.mode == .auto && c.scale == 1.0, "auto mode at scale 1.0")

        try? """
            TRIGGER_BUTTON="XBUTTON2"
            TRIGGER_MODE=Hold
            TRIGGER_SUPPRESS=0
            RECORDING_INDICATOR=0
            INDICATOR_RESIDENT=1
            INDICATOR_SCALE=1.5
            """.write(toFile: envPath, atomically: true, encoding: .utf8)
        c = AgentConfig(repository: repo)
        check(c.trigger?.kind == .mouse(button: 4), "TRIGGER_BUTTON is parsed")
        check(c.mode == .hold, "TRIGGER_MODE is case-insensitive")
        check(!c.suppress && !c.indicator && c.resident, "0 and 1 flags are read")
        check(c.scale == 1.5, "INDICATOR_SCALE in range is kept")

        try? """
            TRIGGER_BUTTON="nonsense"
            TRIGGER_MODE=sometimes
            INDICATOR_SCALE=9
            """.write(toFile: envPath, atomically: true, encoding: .utf8)
        c = AgentConfig(repository: repo)
        check(c.trigger == nil && c.triggerRaw == "nonsense", "an unknown trigger is kept for the hint")
        check(c.mode == .auto, "an unknown mode falls back to auto")
        check(c.scale == 1.0, "INDICATOR_SCALE out of range falls back to 1.0")
    }

    // --- PillGeometry -----------------------------------------------------

    static func pillGeometry() {
        // Each threshold counts from the threshold itself.
        let cases: [(Double, Int)] = [
            (0, 0), (89.9, 0), (90, 1), (199.9, 1), (200, 2), (449, 2), (450, 3),
            (900, 4), (1800, 5), (3499, 5), (3500, 6), (6999, 6), (7000, 7), (1e9, 7),
        ]
        for (rms, want) in cases {
            let got = PillGeometry.level(rms: rms)
            check(got == want, "level(rms: \(rms)) is \(got), want \(want)")
        }

        let maxima = PillGeometry.barMaxU
        let rest = PillGeometry.waveHeights(level: 0, maxima: maxima)
        check(rest.count == PillGeometry.barCount, "one height per bar")
        check(rest.allSatisfy { $0 == PillGeometry.barU }, "at level 0 every bar is a dot")
        check(close(PillGeometry.waveHeights(level: 7, maxima: maxima), maxima),
              "at level 7 every bar reaches its own maximum")
        check(PillGeometry.waveHeights(level: -3, maxima: maxima) == rest, "a level below 0 is clamped")
        check(close(PillGeometry.waveHeights(level: 12, maxima: maxima), maxima), "a level above 7 is clamped")
        let mid = PillGeometry.waveHeights(level: 3.5, maxima: maxima)
        check(zip(zip(rest, mid), maxima).allSatisfy { $0.0 < $0.1 && $0.1 < $1 },
              "between 0 and 7 every bar lies strictly between dot and maximum")
        let transient = PillGeometry.transientBarMaxU
        check(close(PillGeometry.waveHeights(level: 7, maxima: transient), transient),
              "the transient maxima are reached at level 7 too")
    }
}
