// Runner.swift - starts bin/sayit start/stop/cancel, exactly as Solaar or a
// desktop shortcut does on Linux. The session state machine stays in bash, so
// all three platforms' race handling is the one that is already tested.

import Foundation

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

    func start() {
        queue.async { self.lastStart = self.spawn("start") }
    }

    func stop() { after("stop") }

    func cancel() { after("cancel") }

    /// Pastes the newest history entry again, under Sayit's permissions.
    func pasteLast() {
        queue.async { _ = self.spawn("--inject", script: "bin/sayit-history", extra: ["last"]) }
    }

    private func after(_ verb: String) {
        queue.async {
            let prior = self.lastStart
            DispatchQueue.global(qos: .userInitiated).async {
                prior?.waitUntilExit()
                // A start that failed has cleaned up and said why; a stop
                // after it would only replace the reason with "No recording
                // in progress". Unless a session exists after all.
                if let p = prior, p.terminationStatus != 0,
                   !FileManager.default.fileExists(atPath: Shared.runPath("sayit.session")) { return }
                _ = self.spawn(verb)
            }
        }
    }

    @discardableResult
    private func spawn(_ verb: String, script: String? = nil, extra: [String] = []) -> Process? {
        let p = Process()
        let tool = script.map { ((sayit as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(($0 as NSString).lastPathComponent) } ?? sayit
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = [verb] + extra
        p.environment = environment
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
