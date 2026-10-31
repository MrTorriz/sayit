// sayit-icon - draw Sayit.app's icon into a macOS .iconset directory.
//
// Usage:
//   sayit-icon <dir.iconset>     writes icon_16x16.png ... icon_512x512@2x.png
//
// The icon is the pill on a dark tile: the lit lamp and the ten-bar mark, the
// same shapes docs/logo.svg shows and bin/sayit-overlay draws, taken from
// PillGeometry rather than redrawn, so the icon cannot drift from the logo.
// The wordmark is left out: it is unreadable at icon sizes, and the app's
// name is printed under the icon anyway.
//
// mac/install.sh builds and runs this, then turns the set into AppIcon.icns
// with iconutil.
//
// Exit codes:
//   0  The iconset was written
//   1  Bad arguments, or a file could not be written

import AppKit
import ImageIO
import UniformTypeIdentifiers

let G = PillGeometry.self

func rgb(_ c: [CGFloat], _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: c[0], green: c[1], blue: c[2], alpha: alpha)
}

/// One icon, `px` pixels square, drawn on Apple's 1024-point grid: an 824-point
/// tile with rounded corners, inset 100 points on every side.
func icon(px: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let cg = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024
    cg.scaleBy(x: k, y: k)
    // Top-left origin, like the pill's own drawing.
    cg.translateBy(x: 0, y: 1024)
    cg.scaleBy(x: 1, y: -1)

    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.addPath(tile)
    cg.clip()
    let shade = CGGradient(colorsSpace: space, colors: [rgb([0.17, 0.17, 0.19]), rgb([0.07, 0.07, 0.08])] as CFArray,
                           locations: [0, 1])!
    cg.drawLinearGradient(shade, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    cg.restoreGState()

    // The pill holds only the lamp and the mark: the same padding on both
    // ends as from the lamp to the pill's edge.
    let pad = (G.pillHeight - G.lampWidth) / 2
    let content: CGFloat = G.lampWidth + G.lampGap + G.waveWidth
    let pillW: CGFloat = 2 * pad + content
    let s: CGFloat = 640 / pillW                      // pill units -> grid points
    cg.saveGState()
    cg.translateBy(x: (1024 - pillW * s) / 2, y: (1024 - G.pillHeight * s) / 2)
    cg.scaleBy(x: s, y: s)

    let b = G.pillBorder
    let pill = CGPath(roundedRect: CGRect(x: b / 2, y: b / 2, width: pillW - b, height: G.pillHeight - b),
                      cornerWidth: G.pillRadius, cornerHeight: G.pillRadius, transform: nil)
    cg.addPath(pill)
    cg.setFillColor(rgb(G.pillRgb))
    cg.fillPath()
    cg.addPath(pill)
    cg.setStrokeColor(rgb(G.inkRgb))
    cg.setLineWidth(b)
    cg.strokePath()

    let cy = G.pillHeight / 2
    var x = pad
    cg.setFillColor(rgb(G.lampLit))
    cg.fillEllipse(in: CGRect(x: x, y: cy - G.lampWidth / 2, width: G.lampWidth, height: G.lampWidth))
    x += G.lampWidth + G.lampGap

    // The mark as a voice in mid sentence: level 5 of 7.
    cg.setFillColor(rgb(G.inkRgb))
    for (i, h) in G.waveHeights(level: 5, maxima: G.barMaxU).enumerated() {
        let bw = G.barU * G.markScale, bh = h * G.markScale
        let bx = x + CGFloat(i) * (G.barU + G.gapU) * G.markScale
        cg.addPath(CGPath(roundedRect: CGRect(x: bx, y: cy - bh / 2, width: bw, height: bh),
                          cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil))
    }
    cg.fillPath()
    cg.restoreGState()
    return cg.makeImage()!
}

let args = CommandLine.arguments
guard args.count == 2, args[1].hasSuffix(".iconset") else {
    FileHandle.standardError.write(Data("usage: sayit-icon <dir.iconset>\n".utf8))
    exit(1)
}
let dir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { exit(1) }
        CGImageDestinationAddImage(dest, icon(px: size * scale), nil)
        guard CGImageDestinationFinalize(dest) else { exit(1) }
    }
}
