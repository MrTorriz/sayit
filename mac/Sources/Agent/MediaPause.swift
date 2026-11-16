// MediaPause.swift - with MEDIA_WHILE_RECORDING, the Mac's sound gets out of
// the way while you dictate. "lower" turns the output down to a tenth: the
// volume of the output device, so everything goes down with it, a video in a
// browser as much as Music. "pause" pauses Music and Spotify. Once the
// dictation is over Sayit puts back what it changed, and only that: a volume
// you set yourself in the meantime is left as you set it.
//
// The volume by Core Audio, the same control as the slider in the menu bar,
// which needs no permission. An output without a volume of its own (a display
// over HDMI, say) cannot be turned down, and then Music and Spotify are turned
// down instead. A lowered volume is noted in the state directory until it is
// put back, so a Sayit that quits or crashes mid-dictation puts it back when
// it starts again.
//
// The players by Apple events, and only to one that is running, so nothing
// is ever launched. macOS gives an app no way to pause what else is playing,
// in a browser say. The first time Sayit asks a player, macOS asks you once
// to allow it (Privacy & Security > Automation). Through osascript, off the
// main thread: a busy player never holds up the trigger.

import AppKit
import AudioToolbox
import CoreAudio

final class MediaPause {
    private static let players = ["com.apple.Music", "com.spotify.client"]
    /// The share of its volume a lowered output or player keeps.
    private static let lowered = 0.1
    /// Where a lowered output is noted until it is put back.
    private static let notePath = Shared.statePath("lowered-output.json")
    private let queue = DispatchQueue(label: "sayit.media")
    /// Per player changed for the dictation in progress: the volume to give
    /// back, or nil for one that was paused. Touched on `queue` only.
    private var changed: [String: Int?] = [:]
    /// The output turned down for the dictation in progress. Touched on
    /// `queue` only.
    private var output: LoweredOutput?
    var mode = MediaMode.off

    init() {
        queue.async {
            if let data = FileManager.default.contents(atPath: Self.notePath),
               let note = try? JSONDecoder().decode(LoweredOutput.self, from: data) {
                self.output = note
                self.restoreOutput(fade: false)
            }
        }
    }

    /// The recording starts.
    func pause() {
        let mode = self.mode
        guard mode != .off else { return }
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        queue.async {
            if mode == .lower && self.changed.isEmpty && (self.output != nil || self.lowerOutput()) { return }
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
            self.restoreOutput(fade: true)
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

    /// Sayit quits: a lowered output goes back at once.
    func restoreNow() {
        queue.sync { self.restoreOutput(fade: false) }
    }

    // MARK: - The output

    /// An output device turned down: by its UID, which outlives a restart
    /// where its id does not, with the volume to give back and the one Sayit
    /// left it at.
    private struct LoweredOutput: Codable {
        let uid: String
        let volume: Float32
        let set: Float32
    }

    /// Turns the default output down with a short fade. False when it has no
    /// volume Sayit can set, so the players are turned down instead.
    private func lowerOutput() -> Bool {
        guard let device = OutputVolume.defaultDevice(), OutputVolume.settable(device),
              let uid = OutputVolume.uid(device), let v = OutputVolume.get(device) else { return false }
        guard v > 0.001 else { return true }
        let t = v * Float32(Self.lowered)
        for i in 1...4 {
            OutputVolume.set(device, v - (v - t) * Float32(i) / 4)
            usleep(40_000)
        }
        let note = LoweredOutput(uid: uid, volume: v, set: OutputVolume.get(device) ?? t)
        output = note
        try? FileManager.default.createDirectory(atPath: Shared.stateDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(note).write(to: URL(fileURLWithPath: Self.notePath))
        return true
    }

    /// Gives a lowered output its volume back, unless it is gone or someone
    /// changed the volume since.
    private func restoreOutput(fade: Bool) {
        guard let note = output else { return }
        output = nil
        unlink(Self.notePath)
        guard let device = OutputVolume.device(uid: note.uid), let f = OutputVolume.get(device),
              abs(f - note.set) < 0.02 else { return }
        if fade {
            for i in 1...3 {
                OutputVolume.set(device, f + (note.volume - f) * Float32(i) / 4)
                usleep(40_000)
            }
        }
        OutputVolume.set(device, note.volume)
    }

    // MARK: - The players

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

/// The output volume as the menu bar's slider sets it: the device's virtual
/// main volume, 0 to 1, across its channels.
private enum OutputVolume {
    private static let volume = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    static func defaultDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let value = uid?.takeRetainedValue() else { return nil }
        return value as String
    }

    static func device(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &name) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func settable(_ device: AudioDeviceID) -> Bool {
        var address = volume
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func get(_ device: AudioDeviceID) -> Float32? {
        var address = volume
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func set(_ device: AudioDeviceID, _ value: Float32) {
        var address = volume
        var value = min(max(value, 0), 1)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
