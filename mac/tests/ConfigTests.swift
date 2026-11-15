// ConfigTests.swift - unit tests for the agent's trigger parser and settings,
// the .env reader and writer, and the pill's level rule.
//
// Plain checks with a failure counter rather than XCTest, which needs a full
// Xcode: the Command Line Tools are enough. check() is used instead of assert(),
// which -O compiles away. Built and run by mac/tests/run.sh together with
// mac/Sources/Common/*.swift, mac/Sources/Agent/Config.swift and EnvFile.swift.

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
        recordedNames()
        envFile()
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

    /// What Record in Settings writes parses back to the same trigger.
    static func recordedNames() {
        for b: Int64 in [2, 3, 4, 7] {
            check(kind(TriggerSpec.name(mouse: b)) == .mouse(button: b), "mouse \(b) round-trips")
        }
        check(TriggerSpec.name(mouse: 4) == "XBUTTON2", "button 4 is XBUTTON2")
        check(TriggerSpec.name(modifier: 61) == "RIGHTOPTION", "61 is the right Option key")
        check(kind(TriggerSpec.name(modifier: 61)!) == .modifier(code: 61, deviceMask: 0x40), "and parses back")
        check(TriggerSpec.name(modifier: 0) == nil, "A is no modifier")
        check(TriggerSpec.deviceMask(modifier: 54) == 0x10, "the right Command key's bit")
        check(TriggerSpec.name(key: 79, modifiers: 0) == "F18", "F18 by name")
        let ctrlOpt = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        let combo = TriggerSpec.name(key: 79, modifiers: ctrlOpt)
        check(combo == "CTRL+OPTION+F18", "a combination, got \(combo)")
        check(kind(combo) == .key(code: 79, modifiers: ctrlOpt), "parses back")
        check(TriggerSpec.name(key: 50, modifiers: 0) == "KEY50", "an unnamed key by code")
        check(kind("KEY50") == .key(code: 50, modifiers: 0), "and parses back")
    }

    static func envFile() {
        check(EnvFile.render("1", plain: true) == "1", "a bare number stays bare")
        check(EnvFile.render("XBUTTON2", plain: true) == "XBUTTON2", "and so does a name")
        check(EnvFile.render("auto") == "\"auto\"", "a word in double quotes unless plain")
        check(EnvFile.render("", plain: true) == "\"\"", "empty is two quotes")
        check(EnvFile.render("it's") == "\"it's\"", "an apostrophe is fine in double quotes")
        check(EnvFile.render("cost $5") == "'cost $5'", "a dollar goes in single quotes, never expanded")
        check(EnvFile.render("say \"hi\"") == "'say \"hi\"'", "a double quote too")
        check(EnvFile.render("it's \"x\"") == "\"it's \u{201D}x\u{201D}\"", "both quotes: the double ones turn curly")
        check(EnvFile.render("a\nb") == "\"a b\"", "a line break becomes a space")
        check(EnvFile.renderPath("/Users/alex/m/x.bin", home: "/Users/alex") == "\"$HOME/m/x.bin\"", "a home path keeps $HOME")
        check(EnvFile.renderPath("/opt/m.bin", home: "/Users/alex") == "\"/opt/m.bin\"", "another path as it is")

        let text = """
            # Beam search size
            # BEAM=5
            BEAM=1  # measured
            TRIGGER_MODE="auto" # how
            export SAYIT_PROFILE=1

            """
        var out = EnvFile.set("BEAM", rendered: "3", in: text)
        check(out.contains("\nBEAM=3  # measured\n") && out.contains("# BEAM=5"), "the active line changes, comments stay")
        out = EnvFile.set("TRIGGER_MODE", rendered: "\"hold\"", in: out)
        check(out.contains("TRIGGER_MODE=\"hold\" # how"), "a quoted value keeps its comment, got \(out)")
        out = EnvFile.set("SAYIT_PROFILE", rendered: "\"\"", in: out)
        check(out.contains("export SAYIT_PROFILE=\"\""), "export stays")
        out = EnvFile.set("TYPING_WPM", rendered: "50", in: out)
        check(out.hasSuffix("export SAYIT_PROFILE=\"\"\nTYPING_WPM=50\n"), "a new key goes last, got \(out)")
        check(EnvFile.remove("BEAM", in: "# BEAM=5\nBEAM=1\nexport BEAM=2\nX=1\n") == "# BEAM=5\nX=1\n",
              "remove drops active lines only")
        let twice = EnvFile.set("A", rendered: "2", in: "A=0\nA=1\n")
        check(twice == "A=0\nA=2\n", "the last assignment is the one that counts, got \(twice)")

        let path = tempFile("env-write", "# c\nBEAM=1\n")
        chmod(path, 0o600)
        do {
            try EnvFile.write([(key: "BEAM", rendered: "5"), (key: "SPOKEN_PUNCTUATION", rendered: "1")], path: path)
            let back = Shared.readEnv(path)
            check(back["BEAM"] == "5" && back["SPOKEN_PUNCTUATION"] == "1", "written and read back, got \(back)")
            let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
            check(mode == 0o600, "the file keeps its permissions")
            try EnvFile.write([(key: "INITIAL_PROMPT", rendered: EnvFile.render("Hej $USER, \"du\""))], path: path)
            check(Shared.readEnv(path)["INITIAL_PROMPT"] == "Hej $USER, \"du\"", "a tricky value reads back literally")
        } catch {
            check(false, "write failed: \(error)")
        }
    }

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
        check(c.trigger2 == nil && c.trigger2Raw.isEmpty && c.triggers.count == 1, "no second trigger by default")
        check(c.media == .off, "music is left alone by default")

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
        check(c.trigger?.label == "mouse button 5 (forward)", "without TRIGGER_LABEL the button keeps its own name")

        try? """
            TRIGGER_BUTTON="XBUTTON2"
            TRIGGER_LABEL="the thumb button"
            """.write(toFile: envPath, atomically: true, encoding: .utf8)
        c = AgentConfig(repository: repo)
        check(c.trigger?.kind == .mouse(button: 4) && c.trigger?.label == "the thumb button",
              "TRIGGER_LABEL renames the button and keeps what it listens for")

        try? """
            TRIGGER_BUTTON="XBUTTON2"
            TRIGGER_BUTTON2="FN"
            TRIGGER_LABEL2="fn"
            """.write(toFile: envPath, atomically: true, encoding: .utf8)
        c = AgentConfig(repository: repo)
        check(c.triggers.map(\.kind) == [.mouse(button: 4), .modifier(code: 63, deviceMask: CGEventFlags.maskSecondaryFn.rawValue)],
              "TRIGGER_BUTTON2 adds a second trigger after the first")
        check(c.trigger2?.label == "fn", "TRIGGER_LABEL2 names the second")

        try? """
            TRIGGER_BUTTON2="nonsense"
            MEDIA_WHILE_RECORDING=Lower
            """.write(toFile: envPath, atomically: true, encoding: .utf8)
        c = AgentConfig(repository: repo)
        check(c.trigger2 == nil && c.trigger2Raw == "nonsense" && c.triggers.count == 1,
              "an unknown second trigger is kept for the hint and leaves the first alone")
        check(c.media == .lower, "MEDIA_WHILE_RECORDING is read, case aside")

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

        let quiet = PillGeometry.voiceHeights(level: 0, phase: 1.234)
        check(quiet.count == PillGeometry.voiceBarCount, "one voice bar per count")
        check(quiet.allSatisfy { $0 == PillGeometry.voiceRestH }, "at silence the voice wave is a row of dots")
        let loud = PillGeometry.voiceHeights(level: 7, phase: 0)
        let centre = PillGeometry.voiceBarCount / 2
        check(abs(loud[centre] - (4 + 26 * (0.6 + 0.4 * abs(sin(CGFloat(centre) * 0.9))))) < 1e-9,
              "the centre bar at level 7 follows the shared formula")
        check(loud[centre] > loud[0] && loud[centre] > loud[loud.count - 1], "the voice wave is tallest in the middle")
        check(PillGeometry.voiceHeights(level: 20, phase: 0) == loud, "a level above 7 is clamped")
        check(loud.allSatisfy { $0 <= PillGeometry.pillHeight }, "the voice wave stays inside the pill")
    }
}
