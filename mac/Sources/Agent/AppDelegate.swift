// AppDelegate.swift - Sayit's menu bar item, permissions and settings.
//
// The menu bar icon is the state at a glance: a waveform at rest, a red one
// while recording, an ellipsis while transcribing, a warning for a few seconds
// after a problem; today's words beside it if Settings say so. The first menu
// line is the last thing bin/sayit reported - notifications are deliberately
// not used, because Notification Center keeps them, and a "Done" message would
// keep a snippet of every dictation there. The menu holds what is used every
// day: Statistics and History (StatsWindow.swift, also what opening Sayit.app
// again shows), Paste Last Dictation and Settings (SettingsWindow.swift);
// placing the indicator, the trigger probe and restarting the transcription
// server live under Settings, and show in the menu only while they run.
//
// .env is watched: an edit by hand applies within a second, as a change in
// the Settings window does at once.

import AppKit
import AVFoundation
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var repository = ""
    private var config: AgentConfig!
    private var runner: Runner!
    private var trigger: Trigger!
    private var pill: PillController!
    private var stats: StatsWindowController!
    private let media = MediaPause()
    private var settings: SettingsWindowController!
    private let agentStatus = AgentStatus()
    private let look = Look.shared
    private var lookWatch: AnyCancellable?
    /// .env's modification time and size, to notice an edit by hand.
    private var envSignature = ""
    /// Today's words for the menu, read again when the history changes.
    private var today = (words: 0, dictations: 0)
    private var todaySignature = ""
    private let todayLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// Set by Quit Sayit, the one way to quit while the Statistics window is open.
    private var quitting = false
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hintLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let serverLine = NSMenuItem(title: L("Transcription server: checking…"), action: nil, keyEquivalent: "")
    private let pasteLastItem = NSMenuItem(title: L("Paste Last Dictation"), action: #selector(pasteLast), keyEquivalent: "")
    private let statsItem = NSMenuItem(title: L("Statistics and History…"), action: #selector(showStatistics), keyEquivalent: "")
    private let learnItem = NSMenuItem(title: L("Learn From Selection…"), action: #selector(learnFromSelection),
                                       keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
    private let restartItem = NSMenuItem(title: L("Restart Transcription Server"), action: #selector(restartServer),
                                         keyEquivalent: "")
    private var serverRestarting = false
    private let accessibilityItem = NSMenuItem(title: L("Allow Accessibility…"), action: #selector(openAccessibility), keyEquivalent: "")
    private let microphoneItem = NSMenuItem(title: L("Allow Microphone…"), action: #selector(openMicrophone), keyEquivalent: "")
    /// Shown only while placing or probing, to end it from the menu as well.
    private let placeItem = NSMenuItem(title: L("Done Placing"), action: #selector(togglePlacing), keyEquivalent: "")
    private let probeItem = NSMenuItem(title: L("Stop Probe"), action: #selector(toggleProbe), keyEquivalent: "")
    private var probeLines: [String] = []
    /// Which Record attempt is current, so an old timeout leaves a new one be.
    private var captureCount = 0
    private var retryTimer: Timer?
    private var stateTimer: Timer?
    private var lastAgentStatus = ""
    private var lastIcon = ""
    /// AXIsProcessTrusted is a TCC request: asked every 10 s once granted
    /// (every 2 s while waiting for it, and whenever the menu opens), not on
    /// every refresh.
    private var trusted = false
    private var trustedCheckedAt: TimeInterval = -.infinity

    private let statusPath = Shared.runPath("sayit.status")
    private let agentPath = Shared.runPath("sayit.agent")
    private let probeLogPath = Shared.runPath("trigger-probe.log")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let repo = AgentConfig.repositoryPath(),
              FileManager.default.isExecutableFile(atPath: (repo as NSString).appendingPathComponent("bin/sayit")) else {
            FileHandle.standardError.write(Data("Sayit: cannot find the sayit repository (SAYIT_REPO)\n".utf8))
            exit(1)
        }
        repository = repo
        config = AgentConfig(repository: repo)
        runner = Runner(repository: repo)
        pill = PillController(config: config)
        stats = StatsWindowController(repository: repo)
        media.mode = config.media
        runner.onStart = { [weak self] in self?.media.pause() }
        runner.onEnd = { [weak self] in self?.media.resume() }
        settings = SettingsWindowController(repository: repo, status: agentStatus)
        stats.onClose = { [weak self] in self?.windowClosed() }
        settings.onClose = { [weak self] in self?.windowClosed() }
        settings.env.onWrite = { [weak self] _ in self?.reload() }
        agentStatus.recordTrigger = { [weak self] in self?.recordTrigger($0) }
        agentStatus.placeIndicator = { [weak self] in self?.togglePlacing() }
        agentStatus.toggleProbe = { [weak self] in self?.toggleProbe() }
        agentStatus.restartServer = { [weak self] in self?.restartServer() }
        agentStatus.checkServer = { [weak self] in self?.checkServer() }
        lookWatch = look.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.lastIcon = ""; self?.refresh() }
        }
        NSApp.mainMenu = mainMenu()
        envSignature = signature(of: (repo as NSString).appendingPathComponent(".env"))
        trigger = Trigger(config: config, runner: runner)
        trigger.onState = { [weak self] in self?.pill.wake(); self?.refresh() }
        trigger.onProbe = { [weak self] line in self?.probed(line) }
        pill.onChange = { [weak self] in self?.refresh() }
        buildMenu()

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            // Ask once now, at install, rather than in the middle of the first dictation.
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.refresh() }
            }
        }
        if !installTrigger(prompt: true) {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if self?.installTrigger(prompt: false) == true { t.invalidate() }
            }
        }
        stateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.trigger.reconcile()
            self?.watchEnv()
            self?.refresh()
        }
        refresh()
        checkServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        media.restoreNow()
        unlink(agentPath)
    }

    /// Opening Sayit.app again - from Finder, Spotlight or the Dock - while it
    /// runs in the menu bar opens the Statistics window: the one window it has.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatistics()
        return false
    }

    /// With a window open Sayit sits in the Dock like any app, and the Dock's
    /// Quit would take the push-to-talk trigger down with the window - the
    /// LaunchAgent restarts Sayit only after a crash. So that closes the
    /// windows instead. Quit Sayit in the menu bar item still quits, and so
    /// does a logout, restart or shutdown, whose quit event says why.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let quitReason: AEKeyword = 0x7768_793F  // 'why?', kAEQuitReason
        if quitting || !(stats.isVisible || settings.isVisible) { return .terminateNow }
        if NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: quitReason) != nil {
            return .terminateNow
        }
        closeWindows()
        return .terminateCancel
    }

    // MARK: - Windows

    @objc private func closeWindows() {
        stats.close()
        settings.close()
    }

    /// The last window closed: back to the menu bar only.
    private func windowClosed() {
        if !stats.isVisible && !settings.isVisible { NSApp.setActivationPolicy(.accessory) }
    }

    @objc private func showSettings() { settings.show() }

    @objc private func largerText() { look.stepText(1) }
    @objc private func smallerText() { look.stepText(-1) }
    @objc private func actualSizeText() { look.stepText(0) }

    /// The menu bar Sayit has while a window is open. Cmd+Q closes the
    /// windows rather than quitting: quitting would take the push-to-talk
    /// trigger with it, and that stays with Quit Sayit in the menu bar item.
    private func mainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String, target: AnyObject? = nil,
                  modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = modifiers
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
        main.addItem(submenu(L("Sayit"), [
            item(L("Settings…"), #selector(showSettings), ",", target: self),
            .separator(),
            item(L("Hide Sayit"), #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item(L("Close Windows"), #selector(closeWindows), "q", target: self),
        ]))
        main.addItem(submenu(L("Edit"), [
            item(L("Undo"), Selector(("undo:")), "z"),
            item(L("Redo"), Selector(("redo:")), "z", modifiers: [.command, .shift]),
            .separator(),
            item(L("Cut"), #selector(NSText.cut(_:)), "x"),
            item(L("Copy"), #selector(NSText.copy(_:)), "c"),
            item(L("Paste"), #selector(NSText.paste(_:)), "v"),
            item(L("Select All"), #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu(L("View"), [
            item(L("Larger Text"), #selector(largerText), "+", target: self),
            item(L("Smaller Text"), #selector(smallerText), "-", target: self),
            item(L("Default Text Size"), #selector(actualSizeText), "0", target: self),
        ]))
        let windowMenu = submenu(L("Window"), [
            item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("Close"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return main
    }

    // MARK: - Permissions

    @discardableResult
    private func installTrigger(prompt: Bool) -> Bool {
        if trigger.install() {
            refresh()
            return true
        }
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refresh()
        return false
    }

    private var microphoneStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not determined"
        }
    }

    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openMicrophone() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    // MARK: - Menu

    private func buildMenu() {
        // Variable length: the icon alone is square, today's words widen it.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        hintLine.isEnabled = false
        todayLine.isEnabled = false
        serverLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(hintLine)
        menu.addItem(todayLine)
        menu.addItem(serverLine)
        menu.addItem(restartItem)
        restartItem.isHidden = true
        menu.addItem(accessibilityItem)
        menu.addItem(microphoneItem)
        menu.addItem(placeItem)
        menu.addItem(probeItem)
        menu.addItem(.separator())
        menu.addItem(statsItem)
        menu.addItem(pasteLastItem)
        menu.addItem(learnItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit Sayit"), action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        trustedCheckedAt = -.infinity
        refresh()
        checkServer()
    }

    // MARK: - Transcription server

    /// Asks the daemon's /health, under its private path, and puts the answer
    /// in the menu. curl rather than URLSession: plain HTTP to 127.0.0.1 is
    /// all it takes, and App Transport Security has no say over curl.
    private func checkServer() {
        let env = Shared.readEnv((repository as NSString).appendingPathComponent(".env"))
        let port = Int(env["DAEMON_PORT"] ?? "") ?? 9876
        var prefix = (try? String(contentsOfFile: Shared.statePath("sayit-daemon.path"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if prefix.range(of: "^/[0-9a-f]+$", options: .regularExpression) == nil { prefix = "" }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-sf", "-o", "/dev/null", "--max-time", "1.5", "http://127.0.0.1:\(port)\(prefix)/health"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            DispatchQueue.main.async {
                if ok {
                    self.serverRestarting = false
                    self.serverState("Ready")
                } else if self.serverRestarting {
                    self.serverState("Loading the model…")
                } else {
                    self.serverState("Not answering — dictation is slower")
                }
            }
        }
    }

    /// The server's state, in the menu only when it is not ready: with
    /// Restart beside it when it does not answer. Settings shows it always.
    private func serverState(_ text: String) {
        let shown = L(text)
        serverLine.title = L("Transcription server: %@", shown.prefix(1).lowercased() + shown.dropFirst())
        serverLine.isHidden = text == "Ready"
        restartItem.isHidden = text == "Ready" || serverRestarting
        if agentStatus.server != shown { agentStatus.server = shown }
    }

    @objc private func restartServer() {
        serverRestarting = true
        serverState("Restarting…")
        let label = (Bundle.main.bundleIdentifier ?? "io.github.mrtorriz.sayit") + ".daemon"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
        try? p.run()
        // The large model takes a few seconds to load: look again until it answers.
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            tries += 1
            guard let self = self, self.serverRestarting, tries <= 20 else { t.invalidate(); return }
            self.checkServer()
        }
    }

    // MARK: - History and settings

    @objc private func pasteLast() { runner.pasteLast() }

    @objc private func showStatistics() {
        var hint = ""
        if let names = triggerNames {
            switch config.mode {
            case .auto: hint = L("Hold or tap %@ and speak", names)
            case .hold: hint = L("Hold %@ and speak", names)
            case .toggle: hint = L("Tap %@ and speak", names)
            }
        }
        stats.show(hint: hint)
    }

    /// The trigger's name, or both triggers' joined with "or"; nil for none.
    private var triggerNames: String? {
        let names = config.triggers.map { L($0.label) }
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        default: return L("%@ or %@", names[0], names[1])
        }
    }

    private var envPath: String { (repository as NSString).appendingPathComponent(".env") }

    /// A file's modification time and size: enough to see that it changed.
    private func signature(of path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(modified)/\((attrs?[.size] as? NSNumber)?.int64Value ?? -1)"
    }

    /// .env edited by hand, or by another tool: apply it as Settings would.
    private func watchEnv() {
        guard signature(of: envPath) != envSignature else { return }
        settings.env.reload()
        reload()
    }

    /// Today's words and dictations, read again when the history changes or
    /// the day does. From the history's last 512 KB, which hold today many
    /// times over, off the main thread.
    private func updateToday() {
        let path = History.path
        let start = Calendar.current.startOfDay(for: Date())
        let sig = signature(of: path) + "/\(start.timeIntervalSince1970)"
        guard sig != todaySignature else { return }
        todaySignature = sig
        DispatchQueue.global(qos: .utility).async {
            var data = Data()
            if let h = FileHandle(forReadingAtPath: path) {
                let size = (try? h.seekToEnd()) ?? 0
                let from = size > 524_288 ? size - 524_288 : 0
                try? h.seek(toOffset: from)
                data = (try? h.readToEnd()) ?? Data()
                try? h.close()
                // A cut first line is not an entry.
                if from > 0, let nl = data.firstIndex(of: 10) { data = data.suffix(from: data.index(after: nl)) }
            }
            var words = 0, count = 0
            for e in History.parse(data).entries where e.time >= start {
                words += e.words
                count += 1
            }
            DispatchQueue.main.async {
                self.today = (words, count)
                self.refresh()
            }
        }
    }

    /// The last status: its first line, the level bin/sayit gave it (warn or
    /// error, on a second line; empty for plain progress) and its age.
    private func lastStatus() -> (text: String, level: String, age: TimeInterval)? {
        guard let raw = try? String(contentsOfFile: statusPath, encoding: .utf8),
              let attrs = try? FileManager.default.attributesOfItem(atPath: statusPath),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (lines.first ?? "", lines.count > 1 ? lines[1] : "", Date().timeIntervalSince(modified))
    }

    /// bin/sayit's status line in the app's language: the fixed ones by the
    /// table, the ones that carry a count or a reason by their pattern.
    static func translate(_ text: String) -> String {
        let fixed = L(text)
        if fixed != text { return fixed }
        let patterns: [(String, String)] = [
            ("^Done \\(([0-9]+) words?(; the recording had already stopped)?\\): (.*)$", "done"),
            ("^Recording failed to start: (.*)$", "Recording failed to start: %@"),
            ("^Transcription failed: (.*)$", "Transcription failed: %@"),
        ]
        let ns = text as NSString
        for (pattern, key) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ i: Int) -> String {
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
            if key == "done" {
                let ended = group(2).isEmpty ? "" : L("; the recording had already stopped")
                return L("Done (%@ words%@): %@", group(1), ended, group(3))
            }
            return L(key, group(1))
        }
        return text
    }

    private static func ago(_ age: TimeInterval) -> String {
        switch age {
        case ..<60: return ""
        case ..<3600: return L(" · %d min ago", Int(age / 60))
        case ..<86400: return L(" · %d h ago", Int(age / 3600))
        default: return L(" · %d d ago", Int(age / 86400))
        }
    }

    private func refresh() {
        guard statusItem != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - trustedCheckedAt > (trusted ? 10 : 2) {
            trusted = AXIsProcessTrusted()
            trustedCheckedAt = now
        }
        let mic = microphoneStatus
        var problem = false
        if let status = lastStatus(), !status.text.isEmpty {
            // Progress lines are current by nature; an old outcome says how old.
            let progress = status.text.hasPrefix("Recording") && status.level.isEmpty
                || status.text.hasPrefix("Transcribing")
            statusLine.title = AppDelegate.translate(status.text) + (progress ? "" : AppDelegate.ago(status.age))
            problem = status.age < 8 && (!status.level.isEmpty || status.text.lowercased().contains("fail"))
        } else {
            statusLine.title = L("Ready")
        }

        let symbol: String
        var tint: NSColor?
        if pill.recording || trigger.isRecording {
            symbol = "waveform.circle.fill"
            tint = .systemRed
        } else if pill.busy {
            symbol = "ellipsis.circle"
        } else if !trigger.isInstalled || mic == "denied" {
            symbol = "exclamationmark.triangle"
        } else if problem {
            symbol = "exclamationmark.triangle.fill"
            tint = .systemOrange
        } else {
            symbol = "waveform"
        }
        updateToday()
        let count = look.menuCount ? " " + today.words.formatted(.number.locale(statsLocale)) : ""
        let icon = symbol + (tint == nil ? "" : "/\(tint!)") + count
        if icon != lastIcon, let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "sayit")
            button.contentTintColor = tint
            button.title = count
            lastIcon = icon
        }
        todayLine.title = today.dictations == 0 ? L("Nothing dictated yet today")
            : L(today.words == 1 ? "Today: %@ word in %@" : "Today: %@ words in %@",
                today.words.formatted(.number.locale(statsLocale)),
                L(today.dictations == 1 ? "%d dictation" : "%d dictations", today.dictations))

        if !trigger.isInstalled {
            // After a rebuild the old entry can still look switched on.
            hintLine.title = L("Waiting for Accessibility — if Sayit is already on, remove it (−) and allow again")
        } else if config.trigger == nil {
            hintLine.title = L("TRIGGER_BUTTON=\"%@\" is not understood", config.triggerRaw)
        } else if config.trigger2 == nil && !config.trigger2Raw.isEmpty {
            hintLine.title = L("TRIGGER_BUTTON2=\"%@\" is not understood", config.trigger2Raw)
        } else if let names = triggerNames {
            let how: String
            switch config.mode {
            case .auto: how = L("Hold or tap %@ to dictate", names)
            case .hold: how = L("Hold %@ to dictate", names)
            case .toggle: how = L("Tap %@ to start and stop", names)
            }
            hintLine.title = how + L(" · Esc cancels")
        }
        if trigger.probing, !probeLines.isEmpty {
            hintLine.title = L("Probe: %@", probeLines.suffix(3).joined(separator: "  ·  "))
        }
        accessibilityItem.isHidden = trusted && trigger.isInstalled
        microphoneItem.isHidden = mic == "authorized" || mic == "not determined"
        placeItem.isHidden = !pill.placing
        probeItem.isHidden = !trigger.probing

        // What the Settings window shows, set only when it changes.
        if agentStatus.placing != pill.placing { agentStatus.placing = pill.placing }
        if agentStatus.probing != trigger.probing { agentStatus.probing = trigger.probing }
        if agentStatus.probeLines != probeLines { agentStatus.probeLines = probeLines }
        let permissions = L("Microphone %@ · Accessibility %@", L(mic == "authorized" ? "allowed" : mic),
                            L(trusted && trigger.isInstalled ? "allowed" : "not yet"))
        if agentStatus.permissions != permissions { agentStatus.permissions = permissions }

        // What the doctor reads: permissions and the resolved trigger, never
        // text. Written only when it changes.
        let doctorStatus = """
            pid=\(getpid())
            repository=\(repository)
            accessibility=\(trusted ? "yes" : "no")
            event_tap=\(trigger.isInstalled ? "yes" : "no")
            microphone=\(mic)
            trigger=\(config.triggerRaw)\(config.trigger == nil ? " (invalid)" : "")
            trigger2=\(config.trigger2Raw)\(config.trigger2 == nil && !config.trigger2Raw.isEmpty ? " (invalid)" : "")
            mode=\(config.mode.rawValue)
            indicator=\(config.indicator ? (config.resident ? "resident" : "transient") : "off")

            """
        if doctorStatus != lastAgentStatus || !FileManager.default.fileExists(atPath: agentPath) {
            Shared.writeAtomically(doctorStatus, to: agentPath)
            lastAgentStatus = doctorStatus
        }
    }

    // MARK: - Learning from a correction

    /// Learn From Selection: the corrected text you selected, set against
    /// the recent dictation it matches (Corrections.swift), and the rules
    /// you tick go into the wordlist through bin/sayit-learn.
    @objc private func learnFromSelection() {
        let front = NSWorkspace.shared.frontmostApplication
        guard let selected = selectedText(in: front), !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return inform(L("No text is selected"),
                          L("Correct the text where Sayit pasted it, select it, and choose Learn From Selection again."),
                          then: front)
        }
        let recent = recentDictations()
        guard let i = Corrections.source(of: selected, in: recent) else {
            return inform(L("No dictation matches"),
                          L("The selected text is not like anything dictated in the last day."), then: front)
        }
        let proposals = Corrections.propose(original: recent[i], corrected: selected)
        guard !proposals.isEmpty else {
            return inform(L("Nothing to learn"),
                          L("The selection matches a dictation, but no word in it was replaced."), then: front)
        }
        let alert = NSAlert()
        alert.messageText = L("Learn these corrections?")
        alert.informativeText = L("Ticked ones go into your wordlist and fix the same words from the next dictation on.")
        let boxes = proposals.map { p -> NSButton in
            let box = NSButton(checkboxWithTitle: "\(p.heard)  →  \(p.right)", target: nil, action: nil)
            box.state = .on
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(boxes.count) * 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: L("Learn"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        front?.activate()
        guard answer == .alertFirstButtonReturn else { return }
        let chosen = zip(proposals, boxes).filter { $0.1.state == .on }.map(\.0)
        guard !chosen.isEmpty else { return }
        let tool = (repository as NSString).appendingPathComponent("bin/sayit-learn")
        DispatchQueue.global(qos: .userInitiated).async {
            var learned = 0
            var notes: [String] = []
            for rule in chosen {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = [rule.heard, rule.right]
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
                p.environment = environment
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                guard (try? p.run()) != nil else { continue }
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    learned += 1
                } else if let line = text.split(separator: "\n").last {
                    notes.append(String(line))
                }
            }
            DispatchQueue.main.async {
                self.statusLine.title = L(learned == 1 ? "Learned %d correction" : "Learned %d corrections", learned)
                if !notes.isEmpty {
                    self.inform(L(learned == 1 ? "Learned %d correction" : "Learned %d corrections", learned),
                                notes.joined(separator: "\n"), then: front)
                }
            }
        }
    }

    /// The selected text in the app in front: by Accessibility where the
    /// app offers it, else by a copy whose clipboard is put back at once.
    private func selectedText(in app: NSRunningApplication?) -> String? {
        if let app = app {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            // Electron apps build their accessibility tree only when asked.
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
                   let text = value as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return copiedSelection()
    }

    /// Cmd+C into the app in front, the clipboard read and put back as it
    /// was. The keystroke carries Sayit's signature, so the trigger lets it be.
    private func copiedSelection() -> String? {
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let before = board.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: sayitEventSignature)
            event.post(tap: .cghidEventTap)
        }
        let deadline = Date().addingTimeInterval(0.6)
        while board.changeCount == before && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        guard board.changeCount != before else { return nil }
        let text = board.string(forType: .string)
        board.clearContents()
        if !saved.isEmpty { board.writeObjects(saved) }
        return text
    }

    /// The last day's dictations, newest first.
    private func recentDictations() -> [String] {
        let since = Date().addingTimeInterval(-86_400)
        var data = Data()
        if let h = FileHandle(forReadingAtPath: History.path) {
            let size = (try? h.seekToEnd()) ?? 0
            let from = size > 1_048_576 ? size - 1_048_576 : 0
            try? h.seek(toOffset: from)
            data = (try? h.readToEnd()) ?? Data()
            try? h.close()
            if from > 0, let nl = data.firstIndex(of: 10) { data = data.suffix(from: data.index(after: nl)) }
        }
        return History.parse(data).entries.filter { $0.time >= since }.reversed().prefix(50).map(\.text)
    }

    private func inform(_ title: String, _ text: String, then app: NSRunningApplication?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        app?.activate()
    }

    // MARK: - Actions

    /// Record in Settings: the next press becomes trigger `slot`, 1 or 2.
    /// A second click, Escape or 15 s without a press gives up.
    private func recordTrigger(_ slot: Int) {
        if trigger.capture != nil {
            trigger.capture = nil
            let same = agentStatus.capturing == slot
            agentStatus.capturing = nil
            if same { return }
        }
        agentStatus.capturing = slot
        captureCount += 1
        let attempt = captureCount
        trigger.capture = { [weak self] name in
            DispatchQueue.main.async { self?.recorded(name, slot: slot) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.captureCount == attempt, self.trigger.capture != nil else { return }
            self.trigger.capture = nil
            self.agentStatus.capturing = nil
        }
    }

    /// A new trigger goes to .env; a name given to the old one goes with it.
    private func recorded(_ name: String?, slot: Int) {
        agentStatus.capturing = nil
        guard let name = name else { return }
        let (key, labelKey, old) = slot == 2 ? ("TRIGGER_BUTTON2", "TRIGGER_LABEL2", config.trigger2Raw)
                                             : ("TRIGGER_BUTTON", "TRIGGER_LABEL", config.triggerRaw)
        var pairs = [(key: key, rendered: EnvFile.render(name, plain: true))]
        if name.caseInsensitiveCompare(old) != .orderedSame {
            pairs.append((key: labelKey, rendered: "\"\""))
        }
        settings.env.write(pairs)
    }

    @objc private func togglePlacing() { pill.togglePlacing() }

    @objc private func toggleProbe() {
        trigger.probing.toggle()
        probeLines.removeAll()
        if trigger.probing {
            Shared.writeAtomically("# sayit trigger probe: button and key transitions, never text\n", to: probeLogPath)
        }
        refresh()
    }

    private func probed(_ line: String) {
        probeLines.append(line)
        if probeLines.count > 20 { probeLines.removeFirst(probeLines.count - 20) }
        if let h = FileHandle(forWritingAtPath: probeLogPath) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            h.closeFile()
        }
        refresh()
    }

    /// Applies .env: what the app reads from it (the trigger, the indicator).
    private func reload() {
        envSignature = signature(of: envPath)
        config = AgentConfig(repository: repository)
        media.mode = config.media
        trigger.update(config: config)
        pill.reconfigure(config)
        refresh()
    }

    @objc private func quit() {
        // A clean exit: the LaunchAgent restarts Sayit only after a crash.
        quitting = true
        NSApp.terminate(nil)
    }
}
