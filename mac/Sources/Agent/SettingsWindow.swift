// SettingsWindow.swift - Sayit's Settings window (Cmd+,), in place of .env in
// a text editor.
//
// Five tabs in the toolbar, as macOS's own settings windows have them:
// General (the trigger, the statistics' typing speed and goal), Dictation
// (microphone, model, language, the indicator), Text (wordlist, snippets,
// pasting), Appearance (Look.swift) and Advanced (the transcription server,
// the trigger probe, the files).
//
// What the scripts read is written to .env, one line at a time and every
// comment kept (EnvFile.swift), so .env stays the one place a setting lives,
// on every platform. Appearance is the app's own and goes to its defaults.
// Every change applies at once: the app reloads what it reads, the scripts
// read .env on their next run, and a change the transcription server reads
// only when it starts (the model, the search width) restarts it.

import AppKit
import AVFoundation
import Combine
import SwiftUI

/// .env as the Settings window sees it.
final class EnvSettings: ObservableObject {
    let path: String
    @Published private(set) var values: [String: String] = [:]
    /// Text being typed, written once typing pauses.
    @Published private var drafts: [String: String] = [:]
    @Published var error: String?
    private var pending: [String: DispatchWorkItem] = [:]
    /// After a write, with the keys written.
    var onWrite: ((Set<String>) -> Void)?

    init(path: String) {
        self.path = path
        reload()
    }

    func reload() { values = Shared.readEnv(path) }

    /// The value, or `fallback` when the key is missing or empty.
    func string(_ key: String, _ fallback: String = "") -> String {
        let v = values[key] ?? ""
        return v.isEmpty ? fallback : v
    }

    func flag(_ key: String, _ fallback: Bool) -> Bool {
        guard let v = values[key], !v.isEmpty else { return fallback }
        return v != "0"
    }

    func number(_ key: String, _ fallback: Double) -> Double { Double(string(key)) ?? fallback }

    func write(_ pairs: [(key: String, rendered: String)]) {
        do {
            try EnvFile.write(pairs.map { (key: $0.key, rendered: Optional($0.rendered)) }, path: path)
            error = nil
        } catch {
            self.error = L("Could not save to .env: %@", error.localizedDescription)
            return
        }
        reload()
        onWrite?(Set(pairs.map(\.key)))
    }

    func write(_ key: String, _ rendered: String) { write([(key: key, rendered: rendered)]) }

    func toggle(_ key: String, _ fallback: Bool) -> Binding<Bool> {
        Binding(get: { self.flag(key, fallback) }, set: { self.write(key, $0 ? "1" : "0") })
    }

    /// A choice from a list: written at once.
    func choice(_ key: String, _ fallback: String, plain: Bool = false) -> Binding<String> {
        Binding(get: { self.string(key, fallback) }, set: { self.write(key, EnvFile.render($0, plain: plain)) })
    }

    /// Typed text: shown as typed, written 0.8 s after the last keystroke.
    func text(_ key: String, plain: Bool = false) -> Binding<String> {
        Binding(get: { self.drafts[key] ?? self.values[key] ?? "" },
                set: { value in self.later(key, value) { EnvFile.render(value, plain: plain) } })
    }

    /// A number from a slider or stepper, written once it settles.
    func decimal(_ key: String, _ fallback: Double, format: String = "%.1f") -> Binding<Double> {
        Binding(get: { Double(self.drafts[key] ?? "") ?? self.number(key, fallback) },
                set: { value in
                    let text = String(format: format, value)
                    self.later(key, text) { text }
                })
    }

    private func later(_ key: String, _ draft: String, _ rendered: @escaping () -> String) {
        drafts[key] = draft
        pending[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pending[key] = nil
            self.write(key, rendered())
            self.drafts[key] = nil
        }
        pending[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes whatever is still waiting: the window is closing.
    func flush() {
        for (_, work) in pending { work.perform(); work.cancel() }
        pending.removeAll()
    }
}

/// What the agent knows and the Settings window shows, refreshed by
/// AppDelegate; and what the window can ask the agent to do.
final class AgentStatus: ObservableObject {
    @Published var server = L("Checking…")
    @Published var probing = false
    @Published var probeLines: [String] = []
    @Published var placing = false
    @Published var permissions = ""
    /// Which trigger, 1 or 2, Record is waiting for a button or key for.
    @Published var capturing: Int?
    var recordTrigger: (Int) -> Void = { _ in }
    var placeIndicator: () -> Void = {}
    var toggleProbe: () -> Void = {}
    var restartServer: () -> Void = {}
    var checkServer: () -> Void = {}
}

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate, NSTabViewDelegate {
    private let repository: String
    let env: EnvSettings
    private let profiles = AppProfileStore()
    private lazy var downloads = ModelDownloads(repository: repository)
    private let status: AgentStatus
    private let look = Look.shared
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private var lookWatch: AnyCancellable?
    var onClose: (() -> Void)?

    init(repository: String, status: AgentStatus) {
        self.repository = repository
        self.status = status
        env = EnvSettings(path: (repository as NSString).appendingPathComponent(".env"))
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        env.reload()
        profiles.reload()
        status.checkServer()
        if window == nil { build() }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func close() { window?.close() }

    private func build() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: SettingsPane(look: look) { view })
            host.sizingOptions = [.preferredContentSize]
            // The window's title follows the selected tab.
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let repo = repository
        add(L("General"), "gearshape", GeneralPane(env: env, look: look, status: status))
        add(L("Dictation"), "waveform", DictationPane(env: env, status: status, downloads: downloads, repository: repo))
        add(L("Text"), "textformat", TextPane(env: env, repository: repo))
        add(L("Apps"), "square.grid.2x2", AppsPane(store: profiles))
        add(L("Appearance"), "circle.lefthalf.filled", AppearancePane(look: look))
        add(L("Advanced"), "slider.horizontal.3", AdvancedPane(env: env, status: status, repository: repo))
        let saved = UserDefaults.standard.integer(forKey: "settingsTab")
        tabs.selectedTabViewItemIndex = (0..<tabs.tabViewItems.count).contains(saved) ? saved : 0

        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("SayitSettings")
        w.appearance = look.theme.appearance
        if !w.setFrameUsingName("SayitSettings") { w.center() }
        lookWatch = look.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.window?.appearance = self?.look.theme.appearance }
        }
        self.tabs = tabs
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        env.flush()
        profiles.flush()
        if let i = tabs?.selectedTabViewItemIndex { UserDefaults.standard.set(i, forKey: "settingsTab") }
        DispatchQueue.main.async { self.onClose?() }
    }
}

/// Every pane: a grouped form at the chosen text size, one width for all so
/// the window does not jump between tabs, scrolling when it is long.
private struct SettingsPane<Content: View>: View {
    @ObservedObject var look: Look
    @ViewBuilder let content: () -> Content

    var body: some View {
        let k = CGFloat(look.textScale)
        Form { content() }
            .formStyle(.grouped)
            .font(.system(size: 13 * k))
            .controlSize(k >= 1.3 ? .large : .regular)
            .tint(look.accent.color)
            .frame(width: min(560 * k, 860), height: min(600 * max(k, 1), 820))
    }
}

/// A line of grey help under a setting.
private struct Help: View {
    let text: String
    @ObservedObject var look = Look.shared
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(L(text)).font(.system(size: 11 * CGFloat(look.textScale))).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var env: EnvSettings
    @ObservedObject var look: Look
    @ObservedObject var status: AgentStatus

    private static let presets: [(String, String)] = [
        ("XBUTTON2", "Mouse button 5 (forward)"),
        ("XBUTTON1", "Mouse button 4 (back)"),
        ("MIDDLE", "Middle mouse button"),
        ("RIGHTOPTION", "Right Option"),
        ("RIGHTCOMMAND", "Right Command"),
        ("F18", "F18"),
        ("F13", "F13"),
    ]

    var body: some View {
        let raw = env.string("TRIGGER_BUTTON", AgentConfig.defaultTrigger)
        let raw2 = env.string("TRIGGER_BUTTON2")
        let known = Self.presets.contains { $0.0.caseInsensitiveCompare(raw) == .orderedSame }
        Section("Trigger") {
            Picker("Dictate with", selection: env.choice("TRIGGER_BUTTON", AgentConfig.defaultTrigger, plain: true)) {
                ForEach(Self.presets, id: \.0) { Text(L($0.1)).tag($0.0) }
                if !known { Text(raw).tag(raw) }
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Record a button") {
                    Button(L(status.capturing == 1 ? "Press it now… (Esc cancels)" : "Record…")) { status.recordTrigger(1) }
                }
                Help("Press the mouse button, key or combination you want, once. Sayit saves it.")
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Button or key", text: env.text("TRIGGER_BUTTON", plain: true))
                if TriggerSpec.parse(raw) == nil {
                    Text(L("Sayit does not know \"%@\".", raw)).foregroundStyle(.red).font(.callout)
                }
                Help("A key such as F18 or RIGHTOPTION, a combination such as CTRL+OPTION+F12, or MOUSE5. "
                     + "Probe Trigger under Advanced shows what a button sends.")
            }
            TextField("Name in the menu", text: env.text("TRIGGER_LABEL"), prompt: Text("the thumb button"))
            Picker("Mode", selection: env.choice("TRIGGER_MODE", "auto")) {
                Text("Hold or Tap").tag("auto")
                Text("Hold").tag("hold")
                Text("Tap").tag("toggle")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: env.toggle("TRIGGER_SUPPRESS", true)) {
                Text("Keep the button from other apps")
                Help("Otherwise the browser goes forward too, say.")
            }
        }
        Section("Second trigger") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Also dictate with") {
                    HStack {
                        if !raw2.isEmpty && status.capturing != 2 { Text(raw2).foregroundStyle(.secondary) }
                        Button(L(status.capturing == 2 ? "Press it now… (Esc cancels)" : "Record…")) {
                            status.recordTrigger(2)
                        }
                        if !raw2.isEmpty {
                            Button("Remove") {
                                env.write([(key: "TRIGGER_BUTTON2", rendered: "\"\""),
                                           (key: "TRIGGER_LABEL2", rendered: "\"\"")])
                            }
                        }
                    }
                }
                if !raw2.isEmpty && TriggerSpec.parse(raw2) == nil {
                    Text(L("Sayit does not know \"%@\".", raw2)).foregroundStyle(.red).font(.callout)
                }
                Help("A key on the keyboard as well as the mouse button, say. Either one starts a recording, "
                     + "and the one you pressed ends it; the mode above applies to both.")
            }
            if !raw2.isEmpty {
                TextField("Name in the menu", text: env.text("TRIGGER_LABEL2"), prompt: Text("the key"))
            }
        }
        Section("Statistics") {
            LabeledContent("Typing speed to compare with") {
                Stepper(L("%d wpm", Int(env.number("TYPING_WPM", 40))),
                        value: Binding(get: { Int(env.number("TYPING_WPM", 40)) },
                                       set: { env.write("TYPING_WPM", "\(max(5, $0))") }),
                        in: 5...200, step: 5)
            }
            LabeledContent("Daily word goal") {
                Stepper(L("%@ words", look.dailyGoal.formatted(.number.locale(statsLocale))),
                        value: $look.dailyGoal, in: 250...50_000, step: 250)
            }
        }
        if let error = env.error { Section { Text(error).foregroundStyle(.red) } }
    }
}

// MARK: - Dictation

private struct DictationPane: View {
    @ObservedObject var env: EnvSettings
    @ObservedObject var status: AgentStatus
    @ObservedObject var downloads: ModelDownloads
    let repository: String

    /// The model the server runs: MODEL_PATH, else what bin/sayit-daemon
    /// picks on Apple silicon - large when it is there, else medium.
    private var modelInUse: String {
        let current = env.string("MODEL_PATH")
        if !current.isEmpty { return current }
        let large = WhisperModel.all.first { $0.size == "large" }!
        return downloads.isInstalled(large) ? large.path(in: repository)
                                            : WhisperModel.all.first { $0.size == "medium" }!.path(in: repository)
    }

    private var inputs: [String] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified).devices.map(\.localizedName)
    }

    /// GGML models in the repository's models folder, the voice activity
    /// detector left out.
    private var models: [String] {
        let dir = (repository as NSString).appendingPathComponent("models")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasSuffix(".bin") && !$0.contains("silero") && !$0.contains("vad") }
            .sorted().map { (dir as NSString).appendingPathComponent($0) }
    }

    private static func modelName(_ path: String) -> String {
        var n = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if n.hasPrefix("ggml-") { n = String(n.dropFirst(5)) }
        n = n.replacingOccurrences(of: "kb-whisper", with: "KB-Whisper")
        if let q = n.range(of: "-q[0-9]_[0-9k]+$", options: .regularExpression) {
            n = n.replacingCharacters(in: q, with: " (" + n[q].dropFirst() + ")")
        }
        return n.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "KB Whisper", with: "KB-Whisper")
    }

    private var modelBinding: Binding<String> {
        Binding(get: { env.string("MODEL_PATH") },
                set: { path in
                    env.write("MODEL_PATH", path.isEmpty ? "\"\"" : EnvFile.renderPath(path))
                    status.restartServer()
                })
    }

    private var beamBinding: Binding<String> {
        Binding(get: { env.string("BEAM", "5") },
                set: { env.write("BEAM", $0); status.restartServer() })
    }

    var body: some View {
        let source = env.string("AUDIO_SOURCE")
        let devices = inputs
        Section("Microphone") {
            Picker("Input", selection: env.choice("AUDIO_SOURCE", "")) {
                Text("System default").tag("")
                ForEach(devices, id: \.self) { Text($0).tag($0) }
                if !source.isEmpty && !devices.contains(source) { Text(L("%@ (not connected)", source)).tag(source) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker("Sound while recording", selection: env.choice("MEDIA_WHILE_RECORDING", "off")) {
                    Text("Keep playing").tag("off")
                    Text("Turn down").tag("lower")
                    Text("Pause").tag("pause")
                }
                Help("Turn down lowers all sound to a tenth, a video in a browser as much as music. "
                     + "Pause pauses Music and Spotify if they were playing; macOS asks once for permission, "
                     + "under Privacy & Security > Automation. Afterwards Sayit puts back what it changed.")
            }
        }
        Section("Transcription") {
            let current = env.string("MODEL_PATH")
            let found = models
            Picker("Model", selection: modelBinding) {
                Text("Default").tag("")
                ForEach(found, id: \.self) { Text(Self.modelName($0)).tag($0) }
                if !current.isEmpty && !found.contains(current) { Text(Self.modelName(current)).tag(current) }
            }
            let language = env.string("SPEECH_LANGUAGE", "sv")
            Picker("Language", selection: env.choice("SPEECH_LANGUAGE", "sv")) {
                Text("Swedish").tag("sv")
                Text("English").tag("en")
                Text("Detect").tag("auto")
                if !["sv", "en", "auto"].contains(language) { Text(language).tag(language) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker("Search width", selection: beamBinding) {
                    Text("1").tag("1")
                    Text("2").tag("2")
                    Text("5").tag("5")
                    if !["1", "2", "5"].contains(env.string("BEAM", "5")) {
                        Text(env.string("BEAM", "5")).tag(env.string("BEAM", "5"))
                    }
                }
                .pickerStyle(.segmented)
                Help("1 is fastest; 5 can be a little more accurate. Changing it or the model restarts "
                     + "the transcription server, which takes a few seconds.")
            }
            Toggle(isOn: env.toggle("SPOKEN_PUNCTUATION", false)) {
                Text("Spoken punctuation")
                Help("Say \"kommatecken\", \"frågetecken\" or \"kolon\" and get the mark.")
            }
            Toggle(isOn: env.toggle("SEGMENT_WHILE_RECORDING", false)) {
                Text("Transcribe while recording")
                Help("Long dictations are ready sooner after you let go.")
            }
            Toggle(isOn: env.toggle("AUDIO_CTX_ADAPTIVE", false)) {
                Text("Quicker short dictations")
                Help("About 0.3 s faster each time, a little less accurate.")
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Words to expect", text: env.text("INITIAL_PROMPT"), axis: .vertical)
                    .lineLimit(2...4)
                Help("A sentence with the names and terms you use, so they come out spelled right.")
            }
        }
        Section("Models") {
            let inUse = modelInUse
            ForEach(WhisperModel.all) { m in
                let path = m.path(in: repository)
                LabeledContent {
                    if let p = downloads.progress[m.size] {
                        HStack {
                            ProgressView(value: p).frame(width: 120)
                            Button("Cancel") { downloads.cancel(m) }
                        }
                    } else if downloads.isInstalled(m) {
                        if inUse == path {
                            Text("In use").foregroundStyle(.secondary)
                        } else {
                            Button("Use") { modelBinding.wrappedValue = path }
                        }
                    } else {
                        Button(L("Download (%@)", ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file))) {
                            downloads.download(m)
                        }
                    }
                } label: {
                    Text(m.title)
                    Help(downloads.message[m.size] ?? m.note)
                }
            }
        }
        Section("Recording indicator") {
            Toggle("Show the indicator while recording", isOn: env.toggle("RECORDING_INDICATOR", true))
            Toggle("Keep it on screen between dictations", isOn: env.toggle("INDICATOR_RESIDENT", false))
            LabeledContent("Size") {
                Slider(value: env.decimal("INDICATOR_SCALE", 1.0), in: 0.5...2.0, step: 0.1)
                    .frame(maxWidth: 220)
            }
            Toggle("Hide it from screenshots and screen sharing",
                   isOn: env.toggle("INDICATOR_EXCLUDE_FROM_CAPTURE", true))
            LabeledContent("Position") {
                Button(L(status.placing ? "Done Placing" : "Place Indicator…")) { status.placeIndicator() }
            }
        }
        if let error = env.error { Section { Text(error).foregroundStyle(.red) } }
    }
}

// MARK: - Text

/// The Text pane's own state: the rule being typed and what became of it.
private final class LearnState: ObservableObject {
    @Published var heard = ""
    @Published var right = ""
    @Published var message = ""
    @Published var busy = false
    @Published var version = 0
}

private struct TextPane: View {
    @ObservedObject var env: EnvSettings
    let repository: String
    @ObservedObject private var learn = LearnState()

    init(env: EnvSettings, repository: String) {
        self.env = env
        self.repository = repository
    }

    private func configFile(_ key: String, _ name: String) -> String {
        let v = env.string(key)
        return v.isEmpty ? (Shared.configDir as NSString).appendingPathComponent(name) : v
    }

    /// The lines of a TSV file that are rules: not blank, not a comment.
    private func count(_ path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: .newlines).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#") && t.contains("\t")
        }.count
    }

    private func openInEditor(_ path: String, header: String) {
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data(header.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", path]
        try? p.run()
    }

    /// bin/sayit-learn, as on the command line: it checks the rule and keeps
    /// the file's format.
    private func add() {
        let heard = learn.heard.trimmingCharacters(in: .whitespaces)
        let right = learn.right.trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty, !right.isEmpty else { return }
        learn.busy = true
        let tool = (repository as NSString).appendingPathComponent("bin/sayit-learn")
        let learn = self.learn
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = [heard, right]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            p.environment = environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            var text = ""
            var ok = false
            do {
                try p.run()
                text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch {
                text = error.localizedDescription
            }
            DispatchQueue.main.async {
                learn.busy = false
                learn.version += 1
                if ok {
                    learn.message = L("Added: %@ → %@", heard, right)
                    learn.heard = ""
                    learn.right = ""
                } else {
                    let line = text.split(separator: "\n").last.map(String.init) ?? L("it was not added")
                    learn.message = line
                }
            }
        }
    }

    var body: some View {
        _ = learn.version
        let wordlist = configFile("WORDLIST", "wordlist.tsv")
        let snippets = configFile("SNIPPETS", "snippets.tsv")
        let rules = count(wordlist), cues = count(snippets)
        return Group {
            Section("Wordlist") {
                Help(L(rules == 1 ? "%d replacement fixes a word Whisper keeps getting wrong."
                                  : "%d replacements fix words Whisper keeps getting wrong.", rules))
                Help("Or correct a dictation where it was pasted, select it, and choose Learn From Selection "
                     + "in Sayit's menu: Sayit suggests the words to add.")
                TextField("Heard", text: $learn.heard, prompt: Text("kubernetis"))
                TextField("Should be", text: $learn.right, prompt: Text("Kubernetes"))
                HStack {
                    if !learn.message.isEmpty { Text(learn.message).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    Button("Open Wordlist") {
                        openInEditor(wordlist, header: "# heard<TAB>should be, one per line\n")
                    }
                    Button("Add") { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(learn.busy || learn.heard.trimmingCharacters(in: .whitespaces).isEmpty
                                  || learn.right.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Snippets") {
                Help(L(cues == 1 ? "%d snippet: say a cue on its own and its text is pasted instead."
                                 : "%d snippets: say a cue on its own and its text is pasted instead.", cues))
                HStack {
                    Spacer()
                    Button("Open Snippets") {
                        openInEditor(snippets, header: "# cue<TAB>text to paste, one per line; \\n starts a new line\n")
                    }
                }
            }
            Section("Pasting") {
                LabeledContent("Put the clipboard back after") {
                    HStack {
                        Slider(value: env.decimal("PASTE_RESTORE_DELAY", 1.0), in: 0.5...5.0, step: 0.5)
                            .frame(maxWidth: 180)
                        Text(String(format: "%.1f s", env.decimal("PASTE_RESTORE_DELAY", 1.0).wrappedValue))
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Apps

/// Settings of an app's own, for dictating into it (AppProfiles.swift).
private struct AppsPane: View {
    @ObservedObject var store: AppProfileStore

    private var adding: Binding<String> {
        Binding(get: { "" }, set: { id in
            guard let app = store.candidates.first(where: { $0.id == id }) else { return }
            store.add(app.id, name: app.name)
        })
    }

    var body: some View {
        Section {
            Help("An app's own settings replace the general ones while you dictate into it. "
                 + "Sayit looks at the app in front when you start to speak.")
        }
        ForEach(store.profiles) { p in
            Section {
                Picker("Language", selection: store.choice(p.bundleID, "SPEECH_LANGUAGE")) {
                    Text("As in General").tag("")
                    Text("Swedish").tag("sv")
                    Text("English").tag("en")
                    Text("Detect").tag("auto")
                }
                Picker("Spoken punctuation", selection: store.choice(p.bundleID, "SPOKEN_PUNCTUATION")) {
                    Text("As in General").tag("")
                    Text("On").tag("1")
                    Text("Off").tag("0")
                }
                TextField("Words to expect", text: store.text(p.bundleID, "INITIAL_PROMPT"),
                          prompt: Text("As in General"), axis: .vertical)
                    .lineLimit(1...4)
                HStack {
                    Spacer()
                    Button("Remove") { store.remove(p.bundleID) }
                }
            } header: {
                HStack(spacing: 6) {
                    if let icon = AppProfileStore.icon(p.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Text(p.name)
                }
            }
        }
        Section {
            Picker("Add an app", selection: adding) {
                Text("Choose…").tag("")
                ForEach(store.candidates, id: \.id) { Text($0.name).tag($0.id) }
            }
            Help("The apps that are open now. Open one to add it.")
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var look: Look

    private func tileToggle(_ kind: TileKind) -> Binding<Bool> {
        Binding(get: { look.tiles.first { $0.kind == kind }?.on ?? false },
                set: { on in
                    if let i = look.tiles.firstIndex(where: { $0.kind == kind }) { look.tiles[i].on = on }
                })
    }

    var body: some View {
        Section("Text and colour") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Text size", selection: $look.textScale) {
                    ForEach(Look.textScales) { Text($0.title).tag($0.value) }
                }
                .pickerStyle(.segmented)
                Help("Every Sayit window. In the Statistics window ⌘+ and ⌘− too.")
            }
            LabeledContent("Accent colour") {
                HStack(spacing: 10) {
                    ForEach(AccentChoice.allCases) { a in
                        Button { look.accent = a } label: {
                            Circle().fill(a.color)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                                .padding(3)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(look.accent == a ? 0.8 : 0),
                                                               lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(a.title)
                        .accessibilityLabel(a.title)
                        .accessibilityAddTraits(look.accent == a ? .isSelected : [])
                    }
                }
            }
            Picker("Appearance", selection: $look.theme) {
                ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                Picker("Cards", selection: $look.cards) {
                    ForEach(CardStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Help("Solid is calmer and easier to read in a bright room.")
            }
            Toggle("Glow behind the logo", isOn: $look.glow)
        }
        Section("Statistics window") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Layout", selection: $look.layout) {
                    ForEach(LayoutChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Help("Automatic puts the panel beside the charts when the window is wide enough.")
            }
            Picker("Open the window", selection: $look.openAt) {
                ForEach(OpenChoice.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Words per day chart", isOn: $look.showChart)
            Toggle("Year calendar", isOn: $look.showYear)
            Toggle("Speaking against typing", isOn: $look.showSpeed)
        }
        Section("Cards, in order") {
            ForEach(look.tiles) { t in
                let i = look.tiles.firstIndex(of: t) ?? 0
                HStack(spacing: 8) {
                    Toggle(isOn: tileToggle(t.kind)) {
                        Text(t.kind.title)
                        Help(t.kind.detail)
                    }
                    Button { look.move(t.kind, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(i == 0)
                        .accessibilityLabel(L("Move %@ up", t.kind.title))
                    Button { look.move(t.kind, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(i == look.tiles.count - 1)
                        .accessibilityLabel(L("Move %@ down", t.kind.title))
                }
            }
        }
        Section("Menu bar") {
            Toggle("Show today's words next to the icon", isOn: $look.menuCount)
        }
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @ObservedObject var env: EnvSettings
    @ObservedObject var status: AgentStatus
    let repository: String

    var body: some View {
        Section("Transcription server") {
            LabeledContent(status.server) {
                Button("Restart") { status.restartServer() }
            }
        }
        Section("Troubleshooting") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Probe trigger") {
                    Button(L(status.probing ? "Stop Probe" : "Start Probe")) { status.toggleProbe() }
                }
                if status.probing {
                    Text(status.probeLines.isEmpty ? L("Press the button or key you want to use.")
                                                   : status.probeLines.suffix(4).joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
                Help("Shows what each button and key sends, to find the name for Dictate with.")
            }
            LabeledContent("Permissions", value: status.permissions)
        }
        Section("Files") {
            LabeledContent("Every setting as text") {
                Button("Edit .env…") {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    p.arguments = ["-t", env.path]
                    try? p.run()
                }
            }
            LabeledContent("Your dictations") {
                Button("Show History in Finder") {
                    let url = URL(fileURLWithPath: History.path)
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent())
                    }
                }
            }
            Help("Sayit notices when .env is edited by hand and applies it.")
        }
    }
}
