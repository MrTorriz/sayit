// Pill.swift - the recording indicator: the same pill bin/sayit-overlay draws.
//
// Two lifetimes, as on Linux:
//   transient (default)  on screen only while recording, a voice wave across
//                        the pill, click-through - it exists for seconds and must
//                        never be in the way.
//   resident             INDICATOR_RESIDENT=1: on screen for the whole session
//                        with the lamp, the meter and the wordmark. The lamp is
//                        lit by an open microphone and by nothing else.
//                        Draggable unless INDICATOR_LOCKED=1.
//
// Inputs are files in the run directory, the Windows indicator's model:
//   sayit.indicator.on   presence = recording; bin/sayit-indicator show/hide
//   sayit.level          one digit 0..7 from sayit-rec, every 125 ms. Its
//                        modification time is the "audio is arriving" signal,
//                        which is also what sets the voice wave moving.
//   sayit.busy           presence = transcribing (bin/sayit); read only for
//                        the menu bar icon - the pill itself goes at release.
//
// The panel never activates and never takes focus. Positions are stored in
// ~/.config/sayit/overlay-position in the Linux format: points from the top
// left corner of the main screen.

import AppKit

final class PillView: NSView {
    var residentStyle = false
    var lit = false
    var level: CGFloat = 0
    var scale: CGFloat = 1
    /// The voice wave's motion, in seconds; it advances while audio arrives.
    var phase: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    private func color(_ c: [CGFloat]) -> CGColor {
        CGColor(red: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    private func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        let rr = min(radius, r.width / 2, r.height / 2)
        return CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let G = PillGeometry.self
        cg.clear(bounds)
        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)

        let b = G.pillBorder
        let pill = roundedRect(CGRect(x: b / 2, y: b / 2, width: G.pillWidth - b, height: G.pillHeight - b),
                               G.pillRadius)
        cg.addPath(pill)
        cg.setFillColor(color(G.pillRgb))
        cg.fillPath()
        cg.addPath(pill)
        cg.setStrokeColor(color(G.inkRgb))
        cg.setLineWidth(b)
        cg.strokePath()

        let cy = G.pillHeight / 2
        if residentStyle {
            var x = G.contentX
            let r = G.lampWidth / 2
            cg.addEllipse(in: CGRect(x: x, y: cy - r, width: 2 * r, height: 2 * r))
            cg.setFillColor(color(lit ? G.lampLit : G.lampUnlit))
            cg.fillPath()
            x += G.lampWidth + G.lampGap
            drawWave(cg, x: x, cy: cy, scale: G.markScale, maxima: G.barMaxU)
            x += G.waveWidth + G.layoutGap
            drawWordmark(cg, x: x, cy: cy)
        } else {
            drawVoiceWave(cg, cy: cy)
        }
        cg.restoreGState()
    }

    /// The meter, grown symmetrically about cy - a line of dots at rest.
    private func drawWave(_ cg: CGContext, x: CGFloat, cy: CGFloat, scale s: CGFloat, maxima: [CGFloat]) {
        let G = PillGeometry.self
        cg.setFillColor(color(G.inkRgb))
        for (i, h) in G.waveHeights(level: level, maxima: maxima).enumerated() {
            let bw = G.barU * s
            let bh = h * s
            let bx = x + CGFloat(i) * (G.barU + G.gapU) * s
            cg.addPath(roundedRect(CGRect(x: bx, y: cy - bh / 2, width: bw, height: bh), bw / 2))
        }
        cg.fillPath()
    }

    /// The transient meter, the voice wave (PillGeometry.voiceHeights): a row
    /// of dots at rest that rises in the middle as the voice comes in.
    private func drawVoiceWave(_ cg: CGContext, cy: CGFloat) {
        let G = PillGeometry.self
        let w = G.voiceBarW
        cg.setFillColor(color(G.inkRgb))
        for (i, h) in G.voiceHeights(level: level, phase: phase).enumerated() {
            let x = G.voiceX0 + CGFloat(i) * (w + G.voiceGap)
            cg.addPath(roundedRect(CGRect(x: x, y: cy - h / 2, width: w, height: h), w / 2))
        }
        cg.fillPath()
    }

    private func drawWordmark(_ cg: CGContext, x: CGFloat, cy: CGFloat) {
        let G = PillGeometry.self
        let h = G.wordmarkHeight
        let top = cy - h / 2
        let path = CGMutablePath()
        func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: x + a * h, y: top + b * h) }
        for seg in G.wordmark {
            switch seg {
            case let .m(a, b): path.move(to: p(a, b))
            case let .l(a, b): path.addLine(to: p(a, b))
            case let .c(a, b, c, d, e, f): path.addCurve(to: p(e, f), control1: p(a, b), control2: p(c, d))
            case .z: path.closeSubpath()
            }
        }
        cg.addPath(path)
        cg.setFillColor(color(G.inkRgb))
        cg.fillPath()
    }
}

final class PillController {
    private var config: AgentConfig
    private var panel: NSPanel?
    private let view = PillView()
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var target: CGFloat = 0
    private(set) var placing = false
    private(set) var micOpen = false
    private(set) var recording = false
    private(set) var busy = false
    /// Fast polling until then: set by a trigger press or release, so the
    /// pill follows at once while the idle rate stays at once a second.
    private var awakeUntil: TimeInterval = 0

    private let markerPath = Shared.runPath("sayit.indicator.on")
    private let levelPath = Shared.runPath("sayit.level")
    private let busyPath = Shared.runPath("sayit.busy")
    private var positionPath: String { (Shared.configDir as NSString).appendingPathComponent("overlay-position") }

    var onChange: (() -> Void)?

    init(config: AgentConfig) {
        self.config = config
        rebuild()
        schedule(1)
    }

    /// Something is about to happen: poll fast for a few seconds.
    func wake() {
        awakeUntil = ProcessInfo.processInfo.systemUptime + 3
        schedule(1.0 / 30)
    }

    func reconfigure(_ config: AgentConfig) {
        self.config = config
        rebuild()
    }

    private var size: NSSize {
        NSSize(width: PillGeometry.pillWidth * config.scale, height: PillGeometry.pillHeight * config.scale)
    }

    private func rebuild() {
        if let old = panel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: old)
            old.close()
        }
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        if config.excludeFromCapture { p.sharingType = .none }
        view.frame = NSRect(origin: .zero, size: size)
        view.scale = config.scale
        p.contentView = view
        panel = p
        applyInteraction()
        p.setFrameOrigin(savedOrigin() ?? defaultOrigin())
        // Observed only after the initial placement, which would otherwise be
        // saved as if the user had chosen it.
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: p)
        if config.indicator && config.resident { p.orderFrontRegardless() }
    }

    /// Click-through unless the pill is resident and unlocked, or being placed.
    private func applyInteraction() {
        guard let p = panel else { return }
        let movable = placing || (config.resident && !config.locked)
        p.ignoresMouseEvents = !movable
        p.isMovableByWindowBackground = movable
        view.residentStyle = config.resident || placing
    }

    func togglePlacing() {
        placing.toggle()
        applyInteraction()
        if placing {
            panel?.orderFrontRegardless()
        } else {
            savePosition()
            if !(config.indicator && config.resident) && !recording { panel?.orderOut(nil) }
        }
        view.needsDisplay = true
        onChange?()
    }

    // MARK: - Position

    private var mainScreenFrame: NSRect { NSScreen.screens.first?.frame ?? .zero }

    private func defaultOrigin() -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? mainScreenFrame
        return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 48)
    }

    private func savedOrigin() -> NSPoint? {
        guard let text = try? String(contentsOfFile: positionPath, encoding: .utf8) else { return nil }
        var x: CGFloat?, y: CGFloat?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let v = Double(parts[1]) else { continue }
            if parts[0] == "x" { x = CGFloat(v) } else if parts[0] == "y" { y = CGFloat(v) }
        }
        guard let tx = x, let ty = y else { return nil }
        let origin = NSPoint(x: tx, y: mainScreenFrame.maxY - ty - size.height)
        // A position on a screen that is no longer attached falls back.
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(NSRect(origin: origin, size: size)) }
        return onScreen ? origin : nil
    }

    private func savePosition() {
        guard let f = panel?.frame else { return }
        let x = Int(f.minX.rounded()), y = Int((mainScreenFrame.maxY - f.maxY).rounded())
        try? FileManager.default.createDirectory(atPath: Shared.configDir, withIntermediateDirectories: true)
        Shared.writeAtomically("# sayit overlay position, in points from the top-left\n"
                               + "# corner of the main screen. Drag the pill, or use Sayit's menu.\n"
                               + "x=\(x)\ny=\(y)\n", to: positionPath)
    }

    /// Saves a move the user made by dragging. Moves macOS makes itself - a
    /// display going away, a resolution change - happen with no button held
    /// and must not overwrite the chosen position.
    @objc private func moved() {
        guard placing || (config.resident && !config.locked) else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 { savePosition() }
    }

    // MARK: - Animation

    private func schedule(_ seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = seconds / 5
    }

    /// The level and how old it is, read without allocating.
    private func readLevel() -> (CGFloat, Bool) {
        var st = stat()
        guard stat(levelPath, &st) == 0 else { return (0, false) }
        let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let fresh = Date().timeIntervalSince1970 - modified < PillGeometry.audioIdleS
        let fd = open(levelPath, O_RDONLY)
        guard fd >= 0 else { return (0, fresh) }
        defer { close(fd) }
        var byte: UInt8 = 0
        guard read(fd, &byte, 1) == 1, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7") else { return (0, fresh) }
        return (CGFloat(byte - UInt8(ascii: "0")), fresh)
    }

    /// A marker file that exists and was written less than maxAge ago - a
    /// crashed bin/sayit must not leave the icon busy forever.
    private func isFresh(_ path: String, maxAge: TimeInterval) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) < maxAge
    }

    private func tick() {
        let wasRecording = recording, wasOpen = micOpen, wasBusy = busy
        let now = ProcessInfo.processInfo.systemUptime
        recording = FileManager.default.fileExists(atPath: markerPath)
        busy = !recording && isFresh(busyPath, maxAge: 120)
        let (level, fresh) = readLevel()
        micOpen = fresh
        target = fresh ? level : 0

        if let p = panel, config.indicator, !config.resident, !placing {
            if recording && !p.isVisible {
                view.level = 0
                p.orderFrontRegardless()
            } else if !recording && p.isVisible {
                p.orderOut(nil)
            }
        }
        view.lit = micOpen
        if micOpen { view.phase += CGFloat(interval) }
        let before = view.level
        view.level += (target - view.level) * PillGeometry.ease
        if abs(view.level - before) > 0.001 || micOpen != wasOpen || placing || (micOpen && view.level > 0.01) {
            view.needsDisplay = true
        }
        if recording != wasRecording || micOpen != wasOpen || busy != wasBusy { onChange?() }
        // A still image at rest costs nothing to look at; redraw at ~30 fps
        // only while something moves, and look once a second otherwise.
        let active = recording || micOpen || placing || view.level > 0.01 || now < awakeUntil
        schedule(active ? 1.0 / 30 : 1)
    }
}
