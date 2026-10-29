// make-demo.swift - builds docs/demo.gif, the README's one animation.
//
// Usage (macOS, Command Line Tools only):
//   swiftc -O -parse-as-library mac/Sources/Common/*.swift mac/Sources/Agent/Config.swift \
//       mac/Sources/Agent/Pill.swift docs/make-demo.swift -o /tmp/make-demo
//   /tmp/make-demo docs/demo.gif
//
// One dictation of three sentences, drawn rather than recorded: a text field, the thumb button
// of a mouse, and the pill. The pill is not redrawn here - it is Sayit's own
// PillView (mac/Sources/Agent/Pill.swift), rendered frame by frame, so the
// meter and the transcribing sweep are exactly what the app shows. Its
// geometry is the overlay's (docs/check-geometry.py keeps them equal).
//
// What the animation shows is what sayit does: nothing is typed while the
// button is held; the pill exists only while the microphone is open and while
// the recording is transcribed; the text arrives all at once, because it is
// pasted.
//
// Text is set in the system font, as on any screenshot of the platform.

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Points; the GIF is drawn at twice this, so it stays sharp on dense screens.
let W: CGFloat = 1000, H: CGFloat = 500, density: CGFloat = 2
let frameDelay = 0.066
let said = "Move the team meeting to Friday and send the agenda before lunch. "
    + "Book the large room and ask everyone to bring their notes from last week. "
    + "I will share the slides on Thursday evening."

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
// A dark page: GitHub's dark palette, with the lamp's red as the one accent.
let page = hex(0x0d1117), surface = hex(0x161b22), edge = hex(0x30363d)
let ink = hex(0xe6edf3), muted = hex(0x8b949e), faint = hex(0x484f58)
let red = hex(0xff4d4d)

let regular = NSFont.systemFont(ofSize: 21)
let title = NSFont.systemFont(ofSize: 14, weight: .semibold)
let caption = NSFont.systemFont(ofSize: 16)
let captionBold = NSFont.systemFont(ofSize: 16, weight: .semibold)

// --- the timeline -------------------------------------------------------------
enum Phase { case idle, held, speak, transcribe, pasted }
/// Levels 0..7 as sayit-rec publishes them, one every 125 ms: three sentences
/// in about four seconds, with a breath between them.
let ticks: [CGFloat] = [3, 5, 6, 4, 5, 6, 6, 4, 3, 5, 2, 0.5,
                        4, 6, 5, 6, 4, 5, 6, 3, 2, 0.5,
                        4, 5, 6, 5, 4, 3, 2, 1]

/// The level for every frame: the latest tick, as the pill reads it.
func speech() -> [CGFloat] {
    let frames = Int(Double(ticks.count) * 0.125 / frameDelay)
    return (0..<frames).map { ticks[min(ticks.count - 1, Int(Double($0) * frameDelay / 0.125))] }
}

/// (phase, level, frame-in-phase) for every frame.
func makeTimeline() -> [(Phase, CGFloat, Int)] {
    var out: [(Phase, CGFloat, Int)] = (0..<16).map { (.idle, 0, $0) }
    out += (0..<5).map { (.held, 0, $0) }
    // The pill's own smoothing, PillGeometry.ease per 1/30 s, over one GIF frame.
    let easePerFrame = 1 - pow(1 - PillGeometry.ease, CGFloat(frameDelay * 30))
    var smooth: CGFloat = 0
    for (i, level) in speech().enumerated() {
        smooth += (level - smooth) * easePerFrame
        out.append((.speak, smooth, i))
    }
    out += (0..<12).map { (.transcribe, 0, $0) }
    out += (0..<60).map { (.pasted, 0, $0) }
    return out
}

// --- drawing helpers ------------------------------------------------------------
func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func draw(_ s: String, at p: CGPoint, _ f: NSFont, _ c: NSColor) -> CGFloat {
    let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
    a.draw(at: p)
    return a.size().width
}

func width(_ s: String, _ f: NSFont) -> CGFloat {
    NSAttributedString(string: s, attributes: [.font: f]).size().width
}

/// s broken into lines no wider than maxWidth, at spaces.
func wrap(_ s: String, _ f: NSFont, _ maxWidth: CGFloat) -> [String] {
    var lines: [String] = [], line = ""
    for word in s.split(separator: " ") {
        let next = line.isEmpty ? String(word) : line + " " + word
        if width(next, f) > maxWidth && !line.isEmpty { lines.append(line); line = String(word) } else { line = next }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

/// A mouse seen from above, its thumb button lit while held.
func mouse(at o: CGPoint, held: Bool) {
    let body = rounded(CGRect(x: o.x + 7, y: o.y, width: 30, height: 46), 15)
    surface.setFill(); body.fill()
    edge.setStroke(); body.lineWidth = 2; body.stroke()
    let wheel = NSBezierPath()
    wheel.move(to: CGPoint(x: o.x + 22, y: o.y + 6)); wheel.line(to: CGPoint(x: o.x + 22, y: o.y + 15))
    wheel.lineWidth = 2; wheel.lineCapStyle = .round; wheel.stroke()
    let thumb = rounded(CGRect(x: o.x, y: o.y + 19, width: 9, height: 14), 4)
    (held ? red : faint).setFill(); thumb.fill()
}

let pillView = PillView(frame: NSRect(x: 0, y: 0, width: PillGeometry.pillWidth, height: PillGeometry.pillHeight))
let pillScale: CGFloat = 1.5

func frame(_ phase: Phase, _ level: CGFloat, _ i: Int, busyPhase: CGFloat) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let cg = CGContext(data: nil, width: Int(W * density), height: Int(H * density), bitsPerComponent: 8,
                       bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Top-left origin, like the overlay's own drawing, in points.
    cg.translateBy(x: 0, y: H * density); cg.scaleBy(x: density, y: -density)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    let recording = phase == .held || phase == .speak
    let pillUp = recording || phase == .transcribe

    page.setFill()
    CGRect(x: 0, y: 0, width: W, height: H).fill()

    // The text field.
    let field = CGRect(x: 130, y: 44, width: 740, height: 190)
    let card = rounded(field, 16)
    surface.setFill(); card.fill()
    edge.setStroke(); card.lineWidth = 1; card.stroke()
    _ = draw("NOTE", at: CGPoint(x: field.minX + 28, y: field.minY + 24), title, muted)
    var lineY = field.minY + 58
    var caretX = field.minX + 28
    if phase == .pasted {
        let lines = wrap(said, regular, field.width - 56)
        for (n, line) in lines.enumerated() {
            let w = draw(line, at: CGPoint(x: field.minX + 28, y: lineY), regular, ink)
            if n == lines.count - 1 { caretX += w } else { lineY += 34 }
        }
    }
    if (i / 8) % 2 == 0 || pillUp {
        red.setFill()
        rounded(CGRect(x: caretX + 2, y: lineY + 3, width: 2, height: 26), 1).fill()
    }

    // The pill: Sayit's own view, scaled up so it reads at README size.
    if pillUp {
        pillView.level = phase == .speak ? level : 0
        pillView.busy = phase == .transcribe
        pillView.phase = busyPhase
        // On a layer of its own: the view clears its bounds first, which
        // would punch black corners into an opaque canvas.
        let k = pillScale * density
        let pw = Int(PillGeometry.pillWidth * k), ph = Int(PillGeometry.pillHeight * k)
        let layer = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        layer.translateBy(x: 0, y: CGFloat(ph)); layer.scaleBy(x: k, y: -k)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: layer, flipped: true)
        pillView.draw(pillView.bounds)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let size = CGSize(width: PillGeometry.pillWidth * pillScale, height: PillGeometry.pillHeight * pillScale)
        let rect = CGRect(x: (W - size.width) / 2, y: 290, width: size.width, height: size.height)
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY); cg.scaleBy(x: 1, y: -1)
        cg.draw(layer.makeImage()!, in: CGRect(origin: .zero, size: rect.size))
        cg.restoreGState()
    }

    // The steps, one line under everything: the current one in red.
    let steps: [(String, [Phase])] = [("Hold the thumb button", [.held]), ("Speak", [.speak]),
                                      ("Release", [.transcribe]), ("Pasted", [.pasted])]
    let sep = "   ·   "
    let total = steps.map { width($0.0, $0.1.contains(phase) ? captionBold : caption) }.reduce(0, +)
        + width(sep, caption) * CGFloat(steps.count - 1) + 46 + 16
    var x = (W - total) / 2
    mouse(at: CGPoint(x: x, y: 418), held: recording)
    x += 46 + 16
    for (n, (label, phases)) in steps.enumerated() {
        let now = phases.contains(phase)
        x += draw(label, at: CGPoint(x: x, y: 430), now ? captionBold : caption, now ? red : muted)
        if n < steps.count - 1 { x += draw(sep, at: CGPoint(x: x, y: 430), caption, faint) }
    }

    NSGraphicsContext.current = nil
    return cg.makeImage()!
}

// --- output -----------------------------------------------------------------------
@main
enum MakeDemo {
    static func main() {
        let timeline = makeTimeline()
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/demo.gif"
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                         UTType.gif.identifier as CFString, timeline.count, nil) else {
            FileHandle.standardError.write(Data("make-demo: cannot write \(out)\n".utf8)); exit(1)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var busyPhase: CGFloat = 0
        for (phase, level, i) in timeline {
            if phase == .transcribe { busyPhase += CGFloat(frameDelay / 0.9) }
            CGImageDestinationAddImage(dest, frame(phase, level, i, busyPhase: busyPhase),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            FileHandle.standardError.write(Data("make-demo: could not finish \(out)\n".utf8)); exit(1)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
        print("\(out): \(timeline.count) frames, \(size / 1024) KiB")
    }
}
