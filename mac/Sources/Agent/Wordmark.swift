// Wordmark.swift - the README's lockup, SAYIT above DON'T TYPE IT. SAY IT.,
// for the Statistics window.
//
// The letters are the outlined paths of docs/logo-wordmark.svg, copied as they
// are written there (docs/check-geometry.py fails if the two drift apart), and
// read by a small parser for the path commands that file uses: M, L, H, V, C
// and Z, absolute and relative. CoreGraphics only, so the unit tests can build
// it without AppKit.

import CoreGraphics

enum Wordmark {
    /// "SAY", drawn in the text colour.
    static let say = "m 105.698,449.752 c 29.2,0 43.362,-14.6 43.362,-31.682 0,-37.522 -59.422,-24.528 -59.422,-43.362 0,-6.424 5.402,-11.68 19.418,-11.68 9.052,0 18.834,2.628 28.324,8.03 l 7.3,-17.958 c -9.49,-5.986 -22.63,-9.052 -35.478,-9.052 -29.054,0 -43.07,14.454 -43.07,31.828 0,37.96 59.422,24.82 59.422,43.946 0,6.278 -5.694,10.95 -19.71,10.95 -12.264,0 -25.112,-4.38 -33.726,-10.658 l -8.03,17.812 c 9.052,7.008 25.404,11.826 41.61,11.826 z M 151.83407,448 h 24.236 l 9.052,-21.9 h 47.45 l 9.052,21.9 h 24.82 l -45.698,-102.2 h -23.36 z m 40.734,-39.858 16.352,-38.982 16.206,38.982 z M 294.76825,448 h 23.652 v -36.208 l 39.712,-65.992 h -23.214 l -27.448,45.406 -27.156,-45.406 h -25.112 l 39.566,65.846 z"

    /// "IT", drawn in red.
    static let it = "m 368.06035,448 h 23.652 V 345.8 h -23.652 z m 69.05785,0 h 23.652 v -82.928 h 32.704 V 345.8 h -89.06 v 19.272 h 32.704 z"

    /// "DON'T TYPE IT.", the tagline's first half.
    static let dontTypeIt = "m 109.35,513 h 8.85 c 6.75,0 11.34,-4.26 11.34,-10.5 0,-6.24 -4.59,-10.5 -11.34,-10.5 h -8.85 z m 3,-2.61 v -15.78 h 5.67 c 5.19,0 8.52,3.18 8.52,7.89 0,4.71 -3.33,7.89 -8.52,7.89 z m 31.26,2.85 c 6.39,0 11.13,-4.56 11.13,-10.74 0,-6.18 -4.74,-10.74 -11.13,-10.74 -6.45,0 -11.19,4.59 -11.19,10.74 0,6.15 4.74,10.74 11.19,10.74 z m 0,-2.67 c -4.71,0 -8.19,-3.42 -8.19,-8.07 0,-4.65 3.48,-8.07 8.19,-8.07 4.65,0 8.13,3.42 8.13,8.07 0,4.65 -3.48,8.07 -8.13,8.07 z m 15.72001,2.43 h 3 v -15.66 l 12.6,15.66 h 2.46 v -21 h -3 v 15.66 l -12.6,-15.66 h -2.46 z m 22.80001,-14.07 h 1.89 l 1.44,-4.2 c 0.39,-1.11 0.48,-1.56 0.48,-2.13 0,-1.17 -0.81,-2.04 -1.95,-2.04 -1.14,0 -2.01,0.84 -2.01,2.04 0,0.9 0.51,1.59 1.26,1.86 z M 195.48,513 h 2.97 v -18.39 h 7.2 V 492 h -17.37 v 2.61 h 7.2 z m 25.67998,0 h 2.97 v -18.39 h 7.2 V 492 h -17.37 v 2.61 h 7.2 z m 18.27001,0 h 2.97 v -7.32 l 8.34,-13.68 h -2.97 l -6.75,11.04 -6.72,-11.04 h -3.21 l 8.34,13.68 z m 13.89001,0 h 3 v -6.36 h 5.19 c 5.46,0 8.76,-2.76 8.76,-7.32 0,-4.56 -3.3,-7.32 -8.76,-7.32 h -8.19 z m 3,-8.97 v -9.42 h 5.1 c 3.84,0 5.85,1.71 5.85,4.71 0,3 -2.01,4.71 -5.85,4.71 z m 18.35998,8.97 h 15.24 v -2.61 h -12.24 v -6.78 h 10.53 v -2.55 h -10.53 v -6.45 h 11.82 V 492 h -14.82 z m 28.16999,0 h 3 v -21 h -3 z m 13.46998,0 h 2.97 v -18.39 h 7.2 V 492 h -17.37 v 2.61 h 7.2 z m 12.75,0.18 c 1.08,0 1.98,-0.87 1.98,-2.07 0,-1.2 -0.9,-2.04 -1.98,-2.04 -1.11,0 -2.04,0.84 -2.04,2.04 0,1.2 0.93,2.07 2.04,2.07 z"

    /// "SAY IT.", the tagline's second half, in red.
    static let sayIt = "m 357.86988,513.24 c 5.55,0 8.13,-2.76 8.13,-5.97 0,-7.71 -12.72,-4.5 -12.72,-9.63 0,-1.83 1.53,-3.33 5.1,-3.33 1.86,0 3.93,0.54 5.76,1.71 l 0.99,-2.4 c -1.74,-1.2 -4.29,-1.86 -6.75,-1.86 -5.52,0 -8.04,2.76 -8.04,6 0,7.8 12.72,4.56 12.72,9.69 0,1.83 -1.56,3.24 -5.19,3.24 -2.7,0 -5.37,-1.02 -6.93,-2.43 l -1.11,2.34 c 1.68,1.56 4.83,2.64 8.04,2.64 z M 367.1999,513 h 3.09 l 2.31,-5.25 h 11.16 l 2.31,5.25 h 3.15 l -9.54,-21 h -2.97 z m 6.45,-7.65 4.53,-10.29 4.53,10.29 z m 22.26003,7.65 h 2.97 v -7.32 l 8.34,-13.68 h -2.97 l -6.75,11.04 -6.72,-11.04 h -3.21 l 8.34,13.68 z m 22.40995,0 h 3 v -21 h -3 z m 13.46998,0 h 2.97 v -18.39 h 7.2 V 492 h -17.37 v 2.61 h 7.2 z m 12.75,0.18 c 1.08,0 1.98,-0.87 1.98,-2.07 0,-1.2 -0.9,-2.04 -1.98,-2.04 -1.11,0 -2.04,0.84 -2.04,2.04 0,1.2 0.93,2.07 2.04,2.07 z"

    static let sayPath = SVGPath.parse(say)
    static let itPath = SVGPath.parse(it)
    static let dontTypeItPath = SVGPath.parse(dontTypeIt)
    static let sayItPath = SVGPath.parse(sayIt)
    /// SAYIT alone, so that its two parts are scaled as one.
    static let bounds = sayPath.boundingBoxOfPath.union(itPath.boundingBoxOfPath)
    /// The whole lockup, the tagline included.
    static let lockupBounds = bounds.union(dontTypeItPath.boundingBoxOfPath).union(sayItPath.boundingBoxOfPath)
    static var aspect: CGFloat { bounds.height > 0 ? bounds.width / bounds.height : 1 }
    static var lockupAspect: CGFloat { lockupBounds.height > 0 ? lockupBounds.width / lockupBounds.height : 1 }
}

enum SVGPath {
    private static let commands: Set<Character> = ["M", "m", "L", "l", "H", "h", "V", "v", "C", "c", "Z", "z"]

    /// The path an SVG `d` attribute describes, in its own coordinates (y
    /// down). Stops at the first thing it cannot read, keeping what came
    /// before it.
    static func parse(_ d: String) -> CGPath {
        var tokens: [String] = []
        var number = ""
        func flush() {
            if !number.isEmpty { tokens.append(number) }
            number = ""
        }
        for ch in d {
            if commands.contains(ch) {
                flush()
                tokens.append(String(ch))
            } else if ch == "-" || ch == "+" {
                if let last = number.last, last == "e" || last == "E" { number.append(ch) } else { flush(); number.append(ch) }
            } else if ch == "." {
                // "1.5.5" is 1.5 followed by .5.
                if number.contains(".") { flush() }
                number.append(ch)
            } else if ch.isASCII && (ch.isNumber || ch == "e" || ch == "E") {
                number.append(ch)
            } else {
                flush()
            }
        }
        flush()

        let path = CGMutablePath()
        var i = 0
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        func next() -> CGFloat? {
            guard i < tokens.count, let v = Double(tokens[i]) else { return nil }
            i += 1
            return CGFloat(v)
        }
        func point(_ relative: Bool) -> CGPoint? {
            guard let x = next(), let y = next() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while i < tokens.count {
            if let c = tokens[i].first, tokens[i].count == 1, commands.contains(c) {
                command = c
                i += 1
            }
            let relative = command.isLowercase
            let before = i
            switch command {
            case "M", "m":
                guard let p = point(relative) else { return path }
                path.move(to: p)
                current = p
                start = p
                // Further pairs after a moveto are linetos.
                command = relative ? "l" : "L"
            case "L", "l":
                guard let p = point(relative) else { return path }
                path.addLine(to: p)
                current = p
            case "H", "h":
                guard let x = next() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case "V", "v":
                guard let y = next() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case "C", "c":
                let origin = current
                guard let c1 = point(relative) else { return path }
                current = origin
                guard let c2 = point(relative) else { return path }
                current = origin
                guard let p = point(relative) else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
            default:  // Z, z
                path.closeSubpath()
                current = start
                // A number straight after Z is not a command this file uses.
                if i < tokens.count, Double(tokens[i]) != nil { return path }
                continue
            }
            if i == before { return path }
        }
        return path
    }
}
