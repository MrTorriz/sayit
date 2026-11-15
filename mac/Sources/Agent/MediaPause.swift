// MediaPause.swift - with MEDIA_WHILE_RECORDING, Music and Spotify get out
// of the way while you dictate: "lower" turns them down to a tenth, "pause"
// pauses them. Once the dictation is over each is put back as it was: only a
// player that was playing, and only what Sayit itself changed.
//
// By Apple events to the two players, and only to one that is running, so
// nothing is ever launched. macOS gives an app no way to ask what else is
// playing, in a browser say, so other players are left alone. The first time
// Sayit asks a player, macOS asks you once to allow it (Privacy & Security >
// Automation). Through osascript, off the main thread: a busy player never
// holds up the trigger.

import AppKit

final class MediaPause {
    private static let players = ["com.apple.Music", "com.spotify.client"]
    /// The share of its volume a lowered player keeps.
    private static let lowered = 0.1
    private let queue = DispatchQueue(label: "sayit.media")
    /// Per player changed for the dictation in progress: the volume to give
    /// back, or nil for one that was paused. Touched on `queue` only.
    private var changed: [String: Int?] = [:]
    var mode = MediaMode.off

    /// The recording starts.
    func pause() {
        let mode = self.mode
        guard mode != .off else { return }
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        guard !running.isEmpty else { return }
        queue.async {
            for id in running where self.changed[id] == nil {
                switch mode {
                case .pause:
                    if self.osascript(Self.script(id, """
                        if player state is playing then
                            pause
                            return "paused"
                        end if
                        """)) == "paused" { self.changed[id] = .some(nil) }
                case .lower:
                    // A short fade down, so the music steps aside rather than
                    // cutting out.
                    if let volume = Int(self.osascript(Self.script(id, """
                        if player state is playing then
                            set v to sound volume
                            set t to round (v * \(Self.lowered))
                            repeat with i from 1 to 4
                                set sound volume to round (v - (v - t) * i / 4)
                                delay 0.04
                            end repeat
                            return v as text
                        end if
                        """))) { self.changed[id] = volume }
                case .off:
                    break
                }
            }
        }
    }

    /// The dictation is over, or cancelled.
    func resume() {
        queue.async {
            for (id, volume) in self.changed
            where !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                if let v = volume {
                    _ = self.osascript(Self.script(id, """
                        set f to sound volume
                        repeat with i from 1 to 4
                            set sound volume to round (f + (\(v) - f) * i / 4)
                            delay 0.04
                        end repeat
                        """))
                } else {
                    _ = self.osascript(Self.script(id, "play"))
                }
            }
            self.changed.removeAll()
        }
    }

    private static func script(_ id: String, _ body: String) -> String {
        "with timeout of 3 seconds\ntell application id \"\(id)\"\n\(body)\nend tell\nend timeout\nreturn \"\""
    }

    private func osascript(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
