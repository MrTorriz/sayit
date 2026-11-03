// SegmenterTests.swift - unit tests for sayit-rec's Segmenter: where a
// recording is cut, and where it is not.
//
// Same scheme as ConfigTests.swift: plain checks with a failure counter, no
// XCTest. Built and run by mac/tests/run.sh together with
// mac/Sources/Rec/Segmenter.swift. The audio is synthetic: a tone for speech,
// a low deterministic noise for the room.

import Foundation

@main
enum SegmenterTests {
    static var checks = 0
    static var failures = 0

    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL SegmenterTests.swift:\(line): \(what)")
        }
    }

    static func main() {
        cutsAtAPause()
        neverCutsShortRecordings()
        needsContrast()
        silentRestIsDropped()
        longPieceTakesAShorterPause()
        silenceAloneIsNoPiece()
        if failures > 0 {
            print("\(failures) of \(checks) checks failed")
            exit(1)
        }
        print("all \(checks) checks passed")
    }

    // --- audio ------------------------------------------------------------

    static var seed: UInt32 = 12345
    static func noise(_ amplitude: Double) -> Double {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return (Double(seed >> 8) / Double(1 << 24) - 0.5) * 2 * amplitude
    }

    /// Speech-like tone at 20 dB or more above the room.
    static func speech(_ seconds: Double, amplitude: Double = 4000) -> [Int16] {
        (0..<Int(seconds * 16000)).map { i in
            let t = Double(i) / 16000
            return Int16(amplitude * sin(2 * .pi * 220 * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t)) + noise(40))
        }
    }

    static func room(_ seconds: Double, amplitude: Double = 40) -> [Int16] {
        (0..<Int(seconds * 16000)).map { _ in Int16(noise(amplitude)) }
    }

    /// Feeds the samples in capture-sized buffers and returns the pieces.
    static func run(_ samples: [Int16], finish: Bool = true) -> [[Int16]] {
        var pieces: [[Int16]] = []
        let s = Segmenter { pieces.append($0) }
        var at = 0
        while at < samples.count {
            let end = min(samples.count, at + 1024)
            samples[at..<end].withUnsafeBufferPointer { s.feed($0) }
            at = end
        }
        if finish { s.finish() }
        return pieces
    }

    // --- cases ------------------------------------------------------------

    static func cutsAtAPause() {
        let first = room(0.3) + speech(5)
        let pause = room(0.6)
        let all = first + pause + speech(3) + room(0.2)
        let pieces = run(all)
        check(pieces.count == 2, "one pause after 5 s of speech gives two pieces, got \(pieces.count)")
        guard pieces.count == 2 else { return }
        check(pieces.reduce(0) { $0 + $1.count } == all.count, "the pieces hold every sample, in order")
        check(pieces[0] + pieces[1] == all, "the pieces join up to the recording")
        let cut = pieces[0].count
        check(cut > first.count && cut < first.count + pause.count,
              "the cut falls inside the pause (\(cut) between \(first.count) and \(first.count + pause.count))")
        // Found once 0.4 s of the pause have passed, 0.2 s back from there.
        check(abs(cut - (first.count + Int(0.2 * 16000))) <= 2 * Segmenter.frame,
              "the cut lies about 0.2 s into the pause")
    }

    static func neverCutsShortRecordings() {
        let pieces = run(room(0.3) + speech(1.5) + room(0.8) + speech(1.5) + room(0.3))
        check(pieces.isEmpty, "a recording under 4 s is never cut, so it is transcribed whole")
    }

    static func needsContrast() {
        check(run(room(12, amplitude: 3000)).isEmpty, "constant noise without speech gives no pieces")
        check(run([Int16](repeating: 0, count: 16000 * 10)).isEmpty, "digital silence gives no pieces")
        // Speech no louder than the room: nothing tells a pause from speech.
        let flat = speech(5, amplitude: 60) + room(0.8, amplitude: 60) + speech(5, amplitude: 60)
        check(run(flat).isEmpty, "speech at the level of the room is not cut")
    }

    static func silentRestIsDropped() {
        let all = room(0.3) + speech(5) + room(1.5)
        let pieces = run(all)
        check(pieces.count == 1, "a rest of nothing but room is not a piece of its own, got \(pieces.count)")
        let unfinished = run(all, finish: false)
        check(unfinished.count == 1, "the piece before the pause is out before the end")
    }

    static func longPieceTakesAShorterPause() {
        // Speech with 0.3 s breaks: too short a pause until the piece is 12 s.
        var all = room(0.3)
        for _ in 0..<5 { all += speech(2.5) + room(0.3) }
        let pieces = run(all, finish: false)
        check(pieces.count == 1, "a 0.3 s break cuts only past 12 s, got \(pieces.count) pieces")
        if let p = pieces.first {
            check(p.count >= Segmenter.longPiece - Segmenter.keepFrames * Segmenter.frame,
                  "and not before (\(Double(p.count) / 16000) s)")
        }
    }

    static func silenceAloneIsNoPiece() {
        // A long wait before speaking: the silence becomes the start of the
        // first piece instead of a piece of its own.
        let pieces = run(room(6) + speech(5) + room(0.6) + speech(2), finish: false)
        check(pieces.count == 1, "leading silence is no piece of its own, got \(pieces.count)")
        if let p = pieces.first {
            check(p.count > 16000 * 11, "the first piece holds the wait and the speech after it")
        }
    }
}
