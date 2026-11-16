// Runner.swift - starts bin/sayit start/stop/cancel, exactly as Solaar or a
// desktop shortcut does on Linux. The session state machine stays in bash, so
// all three platforms' race handling is the one that is already tested.

import AppKit

final class Runner {
    private let sayit: String
    private let environment: [String: String]
    /// The most recent start. A stop waits for it to have exited, so a very
    /// quick release can never reach bin/sayit before its own start did and
    /// leave a recording running with nothing left to stop it.
    private var lastStart: Process?
    private var running: Set<Process> = []
    private let lock = NSLock()
    /// Spawning happens here, never on the event-tap callback, and in order:
    /// a stop always sees the start that preceded it.
    private let queue = DispatchQueue(label: "sayit.runner")

    init(repository: String) {
        sayit = (repository as NSString).appendingPathComponent("bin/sayit")
        var env = ProcessInfo.processInfo.environment
        // Homebrew's bash 5 first: `env bash` would otherwise find /bin/bash 3.2.
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        env["XDG_RUNTIME_DIR"] = Shared.runDir
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            env["SAYIT_MAC_HELPERS"] = dir
        }
        environment = env
    }

    /// A recording starts, and a dictation ends (stopped or cancelled): for
    /// what goes with them, such as turning the sound down.
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?

    /// The profile of the app in front when the recording started
    /// (AppProfiles.swift): it holds for the whole dictation.
    private var profile: [String: String] = [:]

    func start() {
        onStart?()
        profile = AppProfileStore.activePath().map { ["SAYIT_APP_PROFILE": $0] } ?? [:]
        let env = profile
        queue.async { self.lastStart = self.spawn("start", env: env) }
    }

    /// The text goes to the app in front at the release: its name rides
    /// along for the history (SAYIT_APP), never a window title.
    func stop() {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        after("stop", env: profile.merging(app.isEmpty ? [:] : ["SAYIT_APP": app]) { _, new in new })
        onEnd?()
    }

    func cancel() {
        after("cancel", env: profile)
        onEnd?()
    }

    /// Pastes the newest history entry again, under Sayit's permissions.
    func pasteLast() {
        queue.async { _ = self.spawn("--inject", script: "bin/sayit-history", extra: ["last"]) }
    }

    private func after(_ verb: String, env: [String: String] = [:]) {
        queue.async {
            let prior = self.lastStart
            DispatchQueue.global(qos: .userInitiated).async {
                prior?.waitUntilExit()
                // A start that failed has cleaned up and said why; a stop
                // after it would only replace the reason with "No recording
                // in progress". Unless a session exists after all.
                if let p = prior, p.terminationStatus != 0,
                   !FileManager.default.fileExists(atPath: Shared.runPath("sayit.session")) { return }
                _ = self.spawn(verb, env: env)
            }
        }
    }

    @discardableResult
    private func spawn(_ verb: String, script: String? = nil, extra: [String] = [],
                       env: [String: String] = [:]) -> Process? {
        let p = Process()
        let tool = script.map { ((sayit as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(($0 as NSString).lastPathComponent) } ?? sayit
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = [verb] + extra
        p.environment = environment.merging(env) { _, new in new }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] done in
            guard let self = self else { return }
            self.lock.lock(); self.running.remove(done); self.lock.unlock()
        }
        do {
            try p.run()
        } catch {
            FileHandle.standardError.write(Data("Sayit: cannot run \(tool) \(verb): \(error.localizedDescription)\n".utf8))
            return nil
        }
        lock.lock(); running.insert(p); lock.unlock()
        return p
    }
}
