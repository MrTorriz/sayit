// sayit-rec - record 16 kHz mono 16-bit WAV from a Core Audio input until
// SIGINT/SIGTERM. The macOS counterpart of pw-record in bin/sayit-record.
//
// Usage:
//   sayit-rec <outfile.wav> [source]   record until signalled
//   sayit-rec --list                   list input devices: default-mark, UID, name
//   sayit-rec --resolve <source>       print the device a source resolves to
//
// Arguments:
//   outfile.wav  created mode 0600, overwritten without warning
//   source       empty = the system default input. Otherwise matched against
//                the input devices in this order: UID, exact name, name
//                substring, and finally a device whose name is embedded in the
//                value - so a PipeWire node name copied from a Linux .env
//                (alsa_input.usb-SteelSeries_SteelSeries_Alias-00.mono-fallback)
//                still finds "SteelSeries Alias".
//
// Environment:
//   MAX_RECORD_SECONDS  hard cap on one recording (default 120). It bounds how
//                       long the microphone stays open if whatever started the
//                       recording dies before it can stop it.
//
// Behavior:
//   - The WAV header is rewritten about once a second and finalized on SIGINT,
//     SIGTERM or SIGHUP, so even an abrupt end leaves a readable file.
//   - The level (0..7, the overlay's RMS thresholds) is published every 125 ms
//     to $RUN_DIR/sayit.level for Sayit's pill; the file is removed on exit.
//     The microphone is opened exactly once - the pill needs no second stream.
//   - A capture whose loudest sample is 0 is reported on stderr: on macOS that
//     is what a denied microphone permission looks like, not an error.
//   - A device that disappears mid-recording ends it with what was captured
//     so far, finalized, instead of hanging.
//
// Exit codes:
//   0  Recorded and finalized (including the MAX_RECORD_SECONDS cap)
//   1  Bad arguments, unknown source, or capture failed to start
//   2  Microphone permission denied

import AVFoundation
import CoreAudio
import Foundation

setvbuf(stderr, nil, _IONBF, 0)

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("sayit-rec: \(message)\n".utf8))
    exit(code)
}

// MARK: - Core Audio devices

struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var result: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &result) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
    }
    guard status == noErr, let value = result else { return nil }
    return value.takeRetainedValue() as String
}

func inputChannelCount(_ id: AudioObjectID) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func inputDevices() -> [InputDevice] {
    var addr = address(kAudioHardwarePropertyDevices)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        guard inputChannelCount(id) > 0,
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return InputDevice(id: id, uid: uid, name: name)
    }
}

func defaultInputID() -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return status == noErr && id != 0 ? id : nil
}

func squashed(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}

/// UID, then exact name, then name substring, then a device whose (squashed)
/// name is embedded in the value - longest name first, so "SteelSeries Alias
/// Pro" beats "SteelSeries Alias" when both are present and both fit.
func resolve(_ want: String, among devices: [InputDevice]) -> InputDevice? {
    if let d = devices.first(where: { $0.uid == want }) { return d }
    if let d = devices.first(where: { $0.name.caseInsensitiveCompare(want) == .orderedSame }) { return d }
    if let d = devices.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) { return d }
    let w = squashed(want)
    return devices
        .filter { let n = squashed($0.name); return n.count >= 4 && w.contains(n) }
        .max { $0.name.count < $1.name.count }
}

// MARK: - Command line

var args = Array(CommandLine.arguments.dropFirst())

if args.first == "--list" {
    let def = defaultInputID()
    for d in inputDevices() {
        print("\(d.id == def ? "*" : " ")\t\(d.uid)\t\(d.name)")
    }
    exit(0)
}

if args.first == "--resolve" {
    let want = args.count > 1 ? args[1] : ""
    let devices = inputDevices()
    let chosen = want.isEmpty ? devices.first(where: { $0.id == defaultInputID() }) : resolve(want, among: devices)
    guard let d = chosen else { fail(1, "no input device matches \"\(want)\"") }
    print("\(d.uid)\t\(d.name)")
    exit(0)
}

guard let outPath = args.first, !outPath.hasPrefix("-") else {
    fail(1, "usage: sayit-rec <outfile.wav> [source] | --list | --resolve <source>")
}
let source = args.count > 1 ? args[1] : ""

var chosenDevice: InputDevice?
if !source.isEmpty {
    let devices = inputDevices()
    guard let d = resolve(source, among: devices) else {
        let names = devices.map { $0.name }.joined(separator: ", ")
        fail(1, "no input device matches \"\(source)\" (available: \(names))")
    }
    chosenDevice = d
}

// MARK: - Permission

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    break
case .notDetermined:
    // First use: the system asks the user, on behalf of the app that started
    // sayit (Sayit.app, or the terminal for a manual run).
    let answered = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .audio) { granted = $0; answered.signal() }
    answered.wait()
    if !granted { fail(2, "microphone access was denied") }
default:
    fail(2, "microphone access is denied for the app that started sayit - allow it under "
         + "System Settings > Privacy & Security > Microphone")
}

// MARK: - WAV writer

final class WavWriter {
    private let handle: FileHandle
    private(set) var dataBytes: UInt32 = 0
    private var sinceHeader: UInt32 = 0

    init?(path: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return nil }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard (try? handle.write(contentsOf: WavWriter.header(dataBytes: 0))) != nil else { return nil }
    }

    static func header(dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)              // PCM
        u16(1)              // mono
        u32(16000)          // sample rate
        u32(16000 * 2)      // byte rate
        u16(2)              // block align
        u16(16)             // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    func append(_ data: Data) {
        guard (try? handle.write(contentsOf: data)) != nil else { return }
        dataBytes &+= UInt32(data.count)
        sinceHeader &+= UInt32(data.count)
        if sinceHeader >= 32000 {           // about once a second
            sinceHeader = 0
            rewriteHeader()
        }
    }

    func rewriteHeader() {
        guard let end = try? handle.offset() else { return }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: WavWriter.header(dataBytes: dataBytes))
        try? handle.seek(toOffset: end)
    }

    func close() {
        rewriteHeader()
        try? handle.synchronize()
        try? handle.close()
    }
}

guard let writer = WavWriter(path: outPath) else { fail(1, "cannot create \(outPath)") }

// MARK: - Level publishing

/// One byte, rewritten in place every 125 ms. Its modification time is the
/// liveness signal: the pill treats a level older than audioIdleS as a closed
/// microphone.
final class LevelPublisher {
    private let path = Shared.runPath("sayit.level")
    private var fd: Int32 = -1
    private var inode: ino_t = 0
    private var block: [Int16] = []
    private(set) var peak: Int32 = 0

    init() {
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        var st = stat()
        if fd >= 0 && fstat(fd, &st) == 0 { inode = st.st_ino }
        block.reserveCapacity(2000)
    }

    func feed(_ samples: UnsafeBufferPointer<Int16>) {
        for s in samples {
            let a = abs(Int32(s))
            if a > peak { peak = a }
            block.append(s)
            if block.count == 2000 { publish() }    // 125 ms at 16 kHz
        }
    }

    private func publish() {
        var sum = 0.0
        for s in block { let v = Double(s); sum += v * v }
        let rms = (sum / Double(block.count)).squareRoot()
        block.removeAll(keepingCapacity: true)
        guard fd >= 0 else { return }
        var digit = UInt8(ascii: "0") + UInt8(PillGeometry.level(rms: rms))
        _ = pwrite(fd, &digit, 1, 0)
    }

    /// Removes the file only while it is still ours: a quick re-press can
    /// start the next recorder, which opens the same path, before this one
    /// has finished stopping.
    func remove() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
        var st = stat()
        if stat(path, &st) == 0 && st.st_ino == inode { unlink(path) }
    }
}

let levels = LevelPublisher()

// MARK: - Capture

// AVCaptureSession rather than AVAudioEngine: it selects a device by its Core
// Audio UID directly, and its audio output converts to the requested format
// itself. AVAudioEngine keeps the default device's format on its input node
// after a device switch, and refuses the tap with a format mismatch.
final class Capture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "sayit-rec.capture")
    let writer: WavWriter
    let levels: LevelPublisher
    var finished = false

    init(writer: WavWriter, levels: LevelPublisher) {
        self.writer = writer
        self.levels = levels
    }

    func start(device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "sayit-rec", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot use \(device.localizedName)"])
        }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "sayit-rec", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot convert \(device.localizedName) to 16 kHz mono"])
        }
        session.addOutput(output)
        session.startRunning()
        guard session.isRunning else {
            throw NSError(domain: "sayit-rec", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "\(device.localizedName) did not start"])
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !finished, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        writer.append(data)
        data.withUnsafeBytes { raw in levels.feed(raw.bindMemory(to: Int16.self)) }
    }

    /// Stops capture and finalizes the file. Runs the last write on the
    /// capture queue, so no buffer can land after the header is written.
    func stop() {
        session.stopRunning()
        queue.sync {
            finished = true
            writer.close()
        }
    }
}

func captureDevice() -> AVCaptureDevice? {
    guard let wanted = chosenDevice else { return AVCaptureDevice.default(for: .audio) }
    if let d = AVCaptureDevice(uniqueID: wanted.uid) { return d }
    // Core Audio UIDs and capture-device IDs agree for audio devices; the name
    // is only a fallback for a device that reports them differently.
    let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                 mediaType: .audio, position: .unspecified).devices
    return found.first { $0.localizedName == wanted.name }
}

let capture = Capture(writer: writer, levels: levels)
var activeDevice: AVCaptureDevice?

func finish(_ code: Int32, _ note: String? = nil) -> Never {
    capture.stop()
    levels.remove()
    if let note = note { FileHandle.standardError.write(Data("sayit-rec: \(note)\n".utf8)) }
    if levels.peak == 0 {
        FileHandle.standardError.write(Data(("sayit-rec: digitally silent capture (peak 0) - "
            + "microphone permission denied, input muted, or the wrong device\n").utf8))
    }
    exit(code)
}

// The signal handlers run on the main queue, never inside the capture callback.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { finish(0) }
    source.resume()
    signalSources.append(source)
}

do {
    guard let device = captureDevice() else {
        throw NSError(domain: "sayit-rec", code: 4, userInfo: [NSLocalizedDescriptionKey: "no input device"])
    }
    activeDevice = device
    try capture.start(device: device)
} catch {
    // The header-only WAV stays: a stop that arrives after bin/sayit's
    // liveness check then reads an empty recording, not a missing file.
    writer.close()
    levels.remove()
    fail(1, "could not start capture: \(error.localizedDescription)")
}

// A device that disappears mid-recording (unplugged, a headset leaving) ends
// the recording with what was captured so far rather than hanging.
NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                       object: capture.session, queue: .main) { note in
    let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
    finish(0, "capture stopped: \(err?.localizedDescription ?? "runtime error") - recording ended early")
}
NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                       object: activeDevice, queue: .main) { _ in
    finish(0, "the input device was disconnected - recording ended early")
}

let maxSeconds = Double(ProcessInfo.processInfo.environment["MAX_RECORD_SECONDS"] ?? "") ?? 120
if maxSeconds > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds) {
        finish(0, "MAX_RECORD_SECONDS (\(Int(maxSeconds)) s) reached - recording stopped")
    }
}

dispatchMain()
