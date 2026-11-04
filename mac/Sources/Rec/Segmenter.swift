// Segmenter.swift - cuts a recording at pauses while it is still being made,
// for SEGMENT_WHILE_RECORDING: each finished piece can be transcribed while
// the speaker goes on, so at release only the last one is left.
//
// A pause is a run of 20 ms frames below a threshold that follows the
// recording's own levels: the 5th percentile of all frames so far is the
// noise floor, the 95th the speech, and the threshold sits up to 10 dB above
// the floor. Without 15 dB between the two (a constant noise) nothing is cut,
// and the whole recording is transcribed as before. Frames of digital silence
// (a device that starts with zeros) count as pause but not as the floor.

import Foundation

final class Segmenter {
    static let rate = 16000
    static let frame = 320                  // 20 ms
    /// A piece is at least 4 s long: shorter ones give whisper too little
    /// context, and dictations shorter than this are never cut at all.
    static let minPiece = 4 * rate
    /// Past 12 s a shorter pause will do.
    static let longPiece = 12 * rate
    static let pauseFrames = 20             // 0.4 s
    static let shortPauseFrames = 12        // 0.24 s
    /// The cut falls this far before the end of the pause, so both pieces
    /// keep some of it: 0.2 s.
    static let keepFrames = 10
    /// Frames above the threshold a piece needs: a stretch of silence is
    /// never a piece of its own, it becomes the start of the next one.
    static let minVoicedFrames = 15         // 0.3 s
    /// The rest after the last cut is left out when it holds less than
    /// this above the threshold: a release after a pause adds no request.
    static let restVoicedFrames = 3         // 60 ms

    /// Receives each piece's samples, in order.
    private let emit: ([Int16]) -> Void
    /// Samples since the last cut; `scanned` of them are judged already.
    private var pending: [Int16] = []
    private var scanned = 0
    /// Frame levels in 0.5 dB steps from -100 to 0 dBFS.
    private var histogram = [Int](repeating: 0, count: 201)
    private var frames = 0
    private var silentRun = 0
    private var voiced = 0
    private(set) var pieces = 0

    init(emit: @escaping ([Int16]) -> Void) {
        self.emit = emit
        pending.reserveCapacity(Segmenter.longPiece * 2)
    }

    func feed(_ samples: UnsafeBufferPointer<Int16>) {
        pending.append(contentsOf: samples)
        while pending.count - scanned >= Segmenter.frame {
            judge(from: scanned)
            scanned += Segmenter.frame
            cutIfPaused()
        }
    }

    /// The end of the recording. Emits the rest only when something was cut
    /// before: a recording with no cut is transcribed whole, as before.
    func finish() {
        guard pieces > 0, voiced >= Segmenter.restVoicedFrames, !pending.isEmpty else { return }
        pieces += 1
        emit(pending)
        pending.removeAll()
        scanned = 0
    }

    /// The pause threshold in dBFS, or nil while the recording shows no clear
    /// difference between speech and silence.
    var threshold: Double? {
        guard frames >= 50 else { return nil }
        let noise = percentile(0.05), speech = percentile(0.95)
        guard speech - noise >= 15 else { return nil }
        return noise + min(10, (speech - noise) / 3)
    }

    private func percentile(_ p: Double) -> Double {
        let want = Int((Double(frames) * p).rounded(.up))
        var seen = 0
        for (bin, n) in histogram.enumerated() {
            seen += n
            if seen >= max(want, 1) { return Double(bin) / 2 - 100 }
        }
        return 0
    }

    private func judge(from start: Int) {
        var sum = 0.0
        for i in start..<(start + Segmenter.frame) {
            let v = Double(pending[i])
            sum += v * v
        }
        let rms = (sum / Double(Segmenter.frame)).squareRoot()
        if rms == 0 {
            silentRun += 1
            return
        }
        let db = max(-100, min(0, 20 * log10(rms / 32768)))
        histogram[Int(((db + 100) * 2).rounded())] += 1
        frames += 1
        if let t = threshold, db < t {
            silentRun += 1
        } else {
            silentRun = 0
            voiced += 1
        }
    }

    private func cutIfPaused() {
        let length = scanned
        guard length >= Segmenter.minPiece, voiced >= Segmenter.minVoicedFrames else { return }
        let needed = length >= Segmenter.longPiece ? Segmenter.shortPauseFrames : Segmenter.pauseFrames
        guard silentRun >= needed else { return }
        let cut = length - Segmenter.keepFrames * Segmenter.frame
        pieces += 1
        emit(Array(pending[..<cut]))
        pending.removeFirst(cut)
        scanned -= cut
        voiced = 0
    }
}
