// AppDelegate.swift - Sayit's menu bar item, permissions and settings.
//
// The menu bar icon is the state at a glance: a waveform at rest, a red one
// while recording, a warning for a few seconds after a failure. The first menu
// line is the last thing bin/sayit reported - notifications are deliberately
// not used, because Notification Center keeps them, and a "Done" message would
// keep a snippet of every dictation there.

import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var repository = ""
    private var config: AgentConfig!
    private var runner: Runner!
    private var trigger: Trigger!
    private var pill: PillController!
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hintLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Allow Accessibility…", action: #selector(openAccessibility), keyEquivalent: "")
    private let microphoneItem = NSMenuItem(title: "Allow Microphone…", action: #selector(openMicrophone), keyEquivalent: "")
    private let placeItem = NSMenuItem(title: "Place Indicator", action: #selector(togglePlacing), keyEquivalent: "")
    private let probeItem = NSMenuItem(title: "Probe Trigger", action: #selector(toggleProbe), keyEquivalent: "")
    private var probeLines: [String] = []
    private var retryTimer: Timer?
    private var stateTimer: Timer?
    private var lastAgentStatus = ""

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
        trigger = Trigger(config: config, runner: runner)
        trigger.onState = { [weak self] in self?.refresh() }
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
            self?.refresh()
        }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unlink(agentPath)
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        hintLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(hintLine)
        menu.addItem(accessibilityItem)
        menu.addItem(microphoneItem)
        menu.addItem(.separator())
        menu.addItem(placeItem)
        menu.addItem(probeItem)
        menu.addItem(NSMenuItem(title: "Reload Settings", action: #selector(reload), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Sayit", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func lastStatus() -> (String, TimeInterval)? {
        guard let text = try? String(contentsOfFile: statusPath, encoding: .utf8),
              let attrs = try? FileManager.default.attributesOfItem(atPath: statusPath),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), Date().timeIntervalSince(modified))
    }

    private func refresh() {
        guard statusItem != nil else { return }
        let trusted = AXIsProcessTrusted()
        let mic = microphoneStatus
        let failure: Bool
        if let (text, age) = lastStatus() {
            statusLine.title = text.isEmpty ? "Ready" : text
            failure = age < 8 && text.lowercased().contains("fail")
        } else {
            statusLine.title = "Ready"
            failure = false
        }

        let symbol: String
        var tint: NSColor?
        if pill.recording || trigger.isRecording {
            symbol = "waveform.circle.fill"
            tint = .systemRed
        } else if !trigger.isInstalled || mic == "denied" {
            symbol = "exclamationmark.triangle"
        } else if failure {
            symbol = "exclamationmark.triangle.fill"
            tint = .systemOrange
        } else {
            symbol = "waveform"
        }
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "sayit")
            button.contentTintColor = tint
        }

        if !trigger.isInstalled {
            hintLine.title = "Waiting for the Accessibility permission"
        } else if let spec = trigger.spec {
            let how: String
            switch config.mode {
            case .auto: how = "Hold or tap \(spec.label) to dictate"
            case .hold: how = "Hold \(spec.label) to dictate"
            case .toggle: how = "Tap \(spec.label) to start and stop"
            }
            hintLine.title = how + " · Esc cancels"
        } else {
            hintLine.title = "TRIGGER_BUTTON=\"\(config.triggerRaw)\" is not understood"
        }
        if trigger.probing, !probeLines.isEmpty {
            hintLine.title = "Probe: " + probeLines.suffix(3).joined(separator: "  ·  ")
        }
        accessibilityItem.isHidden = trusted && trigger.isInstalled
        microphoneItem.isHidden = mic == "authorized" || mic == "not determined"
        placeItem.title = pill.placing ? "Done Placing" : "Place Indicator"
        probeItem.state = trigger.probing ? .on : .off

        // What the doctor reads: permissions and the resolved trigger, never
        // text. Written only when it changes.
        let agentStatus = """
            pid=\(getpid())
            repository=\(repository)
            accessibility=\(trusted ? "yes" : "no")
            event_tap=\(trigger.isInstalled ? "yes" : "no")
            microphone=\(mic)
            trigger=\(config.triggerRaw)\(trigger.spec == nil ? " (invalid)" : "")
            mode=\(config.mode.rawValue)
            indicator=\(config.indicator ? (config.resident ? "resident" : "transient") : "off")

            """
        if agentStatus != lastAgentStatus || !FileManager.default.fileExists(atPath: agentPath) {
            Shared.writeAtomically(agentStatus, to: agentPath)
            lastAgentStatus = agentStatus
        }
    }

    // MARK: - Actions

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

    @objc private func reload() {
        config = AgentConfig(repository: repository)
        trigger.update(config: config)
        pill.reconfigure(config)
        refresh()
    }

    @objc private func quit() {
        // A clean exit: the LaunchAgent restarts Sayit only after a crash.
        NSApp.terminate(nil)
    }
}
