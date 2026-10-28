// PillGeometry.swift - the pill's geometry, colours and level rule.
//
// The numbers are not independent. They are the same constants bin/sayit-overlay
// draws from: the pill is one design with three implementations, not three
// drawings that resemble each other. The wordmark outlines were extracted from
// that file rather than converted again from the font, because a second
// conversion is a second shape.
//
// docs/check-geometry.py compares every hand-written number below against the
// overlay and CI runs it, so a change to one side without the other fails the
// build. Change bin/sayit-overlay, run that script, and it names what to edit.
//
// Compiled into both Sayit (which draws) and sayit-rec (which computes the
// level), so the level thresholds live here too.

import CoreGraphics

enum PillGeometry {
    // --- the pill ---------------------------------------------------------
    // 160x40 points. The transient pill uses the whole width for its meter;
    // the resident one holds a lamp, the meter and the wordmark.
    static let pillWidth: CGFloat = 160
    static let pillHeight: CGFloat = 40
    static let pillRadius: CGFloat = 12
    static let pillBorder: CGFloat = 1.2

    // --- the mark ---------------------------------------------------------
    // A 96-unit design space (icons/*.svg) scaled into the pill at draw time.
    static let markScale: CGFloat = 0.3562
    static let barCount = 10
    static let barU: CGFloat = 11          // bar width, and its height at rest
    static let gapU: CGFloat = 3
    // Height at level 7, per bar: a phrase rather than a progress bar.
    static let barMaxU: [CGFloat] = [32.32, 38.08, 58.24, 45.76, 64, 42.4, 53.44, 36.16, 59.68, 40]
    static let dotD: CGFloat = 42          // the lamp, larger than the bars ask for

    // Gaps in pill points, not mark units.
    static let lampGap: CGFloat = 8
    static let layoutGap: CGFloat = 12

    // The transient (recording-only) pill: more bars rather than bigger ones,
    // spread across the whole pill inside a small shoulder.
    static let transientWaveInset: CGFloat = 13
    static let transientBarMaxU: [CGFloat] = [26, 31, 37, 45, 54, 61, 50, 42, 33, 29, 39, 53, 64, 58, 45, 35, 28, 40, 54, 47, 36, 60, 52, 43, 34, 28]

    // --- colours ----------------------------------------------------------
    // The lamp is always drawn in the resident pill; colour is the whole
    // signal. Unlit is a dark red that still reads as a lamp.
    static let lampLit: [CGFloat] = [1, 0.3, 0.3]
    static let lampUnlit: [CGFloat] = [0.42, 0.13, 0.15]
    static let inkRgb: [CGFloat] = [1, 1, 1]
    static let pillRgb: [CGFloat] = [0, 0, 0]

    // --- level and motion -------------------------------------------------
    // RMS thresholds (s16 samples) -> level 0..7, matching bin/sayit-meter.
    static let levels: [Double] = [90, 200, 450, 900, 1800, 3500, 7000]
    static let ease: CGFloat = 0.35        // level smoothing per frame
    static let audioIdleS: Double = 0.4   // no level update for this long = mic closed

    // --- the wordmark -----------------------------------------------------
    // "sayit" as outlines, normalised to height 1.0 with the origin at the
    // wordmark's own top left, so wordmarkHeight alone sets its size.
    static let wordmarkHeight: CGFloat = 21.875
    static let wordmarkAspect: CGFloat = 2.396638

    enum Segment {
        case m(CGFloat, CGFloat)
        case l(CGFloat, CGFloat)
        case c(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case z
    }

    static let wordmark: [Segment] = [
        .m(0.253707, 0.846809),
        .c(0.380086, 0.846809, 0.510389, 0.787583, 0.510389, 0.652443),
        .c(0.510389, 0.583428, 0.468933, 0.524269, 0.364279, 0.501596),
        .l(0.262600, 0.479904),
        .c(0.235937, 0.473986, 0.231001, 0.468068, 0.231001, 0.453291),
        .c(0.231001, 0.428640, 0.267537, 0.418783, 0.306034, 0.418783),
        .c(0.350465, 0.418783, 0.380086, 0.437517, 0.395878, 0.455253),
        .c(0.412650, 0.473986, 0.417586, 0.475964, 0.430419, 0.470047),
        .l(0.513348, 0.433577),
        .c(0.526180, 0.427660, 0.524219, 0.415824, 0.519282, 0.407929),
        .c(0.486702, 0.355602, 0.420562, 0.304255, 0.308993, 0.304255),
        .c(0.173753, 0.304255, 0.053308, 0.370412, 0.053308, 0.499618),
        .c(0.053308, 0.576529, 0.103657, 0.614977, 0.192503, 0.635672),
        .l(0.290243, 0.658344),
        .c(0.323803, 0.666240, 0.334674, 0.674119, 0.334674, 0.686935),
        .c(0.334674, 0.726380, 0.270495, 0.727360, 0.246809, 0.727360),
        .c(0.175715, 0.727360, 0.152028, 0.699751, 0.135239, 0.674119),
        .c(0.124385, 0.657364, 0.113531, 0.657364, 0.096742, 0.665259),
        .l(0.015791, 0.703707),
        .c(0.001978, 0.710605, 0.000000, 0.717503, 0.006915, 0.731316),
        .c(0.037517, 0.792520, 0.112533, 0.846809, 0.253707, 0.846809),
        .z,
        .m(0.826355, 0.797872),
        .c(0.842163, 0.781084, 0.851039, 0.781084, 0.852036, 0.793916),
        .l(0.853017, 0.805768),
        .c(0.854995, 0.824518, 0.855976, 0.837367, 0.873745, 0.837367),
        .l(1.009001, 0.837367),
        .c(1.027751, 0.837367, 1.027751, 0.836370, 1.030710, 0.816622),
        .l(1.079097, 0.473072),
        .c(1.080078, 0.463198, 1.081059, 0.453324, 1.081059, 0.444448),
        .c(1.081059, 0.362500, 1.025790, 0.304255, 0.857954, 0.304255),
        .c(0.732571, 0.304255, 0.641747, 0.332879, 0.599294, 0.410871),
        .c(0.587458, 0.441489, 0.596335, 0.450366, 0.607189, 0.452344),
        .l(0.732571, 0.478009),
        .c(0.749360, 0.480967, 0.754297, 0.478009, 0.758236, 0.470113),
        .c(0.778981, 0.427660, 0.816481, 0.421742, 0.848080, 0.421742),
        .c(0.878682, 0.421742, 0.892512, 0.432596, 0.892512, 0.459259),
        .c(0.892512, 0.463198, 0.892512, 0.468135, 0.891514, 0.473072),
        .l(0.888556, 0.489860),
        .c(0.886577, 0.502693, 0.878682, 0.509608, 0.866830, 0.509608),
        .l(0.859932, 0.509608),
        .c(0.721717, 0.509608, 0.533153, 0.560937, 0.533153, 0.715924),
        .c(0.533153, 0.790957, 0.586461, 0.847224, 0.679264, 0.847224),
        .c(0.736528, 0.847224, 0.792794, 0.833411, 0.826355, 0.797872),
        .z,
        .m(0.864869, 0.662616),
        .c(0.862891, 0.677427, 0.850058, 0.692237, 0.837226, 0.703092),
        .c(0.824393, 0.713963, 0.800690, 0.722839, 0.771069, 0.722839),
        .c(0.742445, 0.722839, 0.727635, 0.705070, 0.727635, 0.684342),
        .c(0.727635, 0.624119, 0.808585, 0.602394, 0.849061, 0.599435),
        .l(0.862891, 0.598454),
        .c(0.874742, 0.597457, 0.873745, 0.598454, 0.871767, 0.610289),
        .z,
        .m(1.116223, 1.000000),
        .c(1.266273, 1.000000, 1.329455, 0.965459, 1.421277, 0.801579),
        .l(1.679920, 0.337533),
        .c(1.687832, 0.323720, 1.687832, 0.313830, 1.672025, 0.313830),
        .l(1.561453, 0.313830),
        .c(1.549618, 0.313830, 1.539744, 0.319764, 1.530851, 0.338531),
        .l(1.418318, 0.563630),
        .c(1.409425, 0.581400, 1.400549, 0.582380, 1.396592, 0.565608),
        .l(1.345263, 0.328657),
        .c(1.343285, 0.317786, 1.336370, 0.313830, 1.324518, 0.313830),
        .l(1.143866, 0.313830),
        .c(1.128075, 0.313830, 1.121160, 0.324701, 1.127078, 0.347407),
        .l(1.254438, 0.811436),
        .c(1.261336, 0.835140, 1.235672, 0.858843, 1.190259, 0.858843),
        .l(1.120163, 0.858843),
        .c(1.098454, 0.858843, 1.085622, 0.866739, 1.084624, 0.874634),
        .l(1.070811, 0.975332),
        .c(1.067852, 0.994082, 1.078707, 1.000000, 1.116223, 1.000000),
        .z,
        .m(1.957883, 0.130918),
        .c(1.959845, 0.118085, 1.958864, 0.104255, 1.948009, 0.104255),
        .l(1.782152, 0.104255),
        .c(1.770300, 0.104255, 1.764382, 0.112168, 1.762404, 0.126978),
        .l(1.745616, 0.238531),
        .c(1.742657, 0.255303, 1.745616, 0.270113, 1.760426, 0.270113),
        .l(1.909496, 0.270113),
        .c(1.932202, 0.270113, 1.939117, 0.267154, 1.942075, 0.247407),
        .z,
        .m(1.929243, 0.339511),
        .c(1.930240, 0.327660, 1.928262, 0.313830, 1.917391, 0.313830),
        .l(1.750553, 0.313830),
        .c(1.738718, 0.313830, 1.734761, 0.315808, 1.732783, 0.330635),
        .l(1.665662, 0.806632),
        .c(1.663684, 0.823421, 1.671580, 0.837234, 1.691327, 0.837234),
        .l(1.830523, 0.837234),
        .c(1.853229, 0.837234, 1.859146, 0.835273, 1.862122, 0.814528),
        .z,
        .m(2.168580, 0.837234),
        .c(2.209055, 0.837234, 2.260401, 0.836253, 2.301858, 0.832314),
        .c(2.316668, 0.831316, 2.324564, 0.822440, 2.326542, 0.806632),
        .l(2.338393, 0.727660),
        .c(2.340355, 0.716805, 2.331479, 0.701995, 2.320624, 0.701995),
        .l(2.278171, 0.701995),
        .c(2.235717, 0.701995, 2.218929, 0.693102, 2.218929, 0.667404),
        .c(2.218929, 0.663447, 2.218929, 0.659491, 2.219926, 0.655552),
        .l(2.246572, 0.465808),
        .c(2.248550, 0.452959, 2.254467, 0.447041, 2.265338, 0.447041),
        .l(2.357143, 0.447041),
        .c(2.373932, 0.447041, 2.378869, 0.444082, 2.380830, 0.431233),
        .l(2.394660, 0.329555),
        .c(2.396638, 0.316722, 2.385767, 0.312766, 2.372935, 0.312766),
        .l(2.286066, 0.312766),
        .c(2.279151, 0.312766, 2.273234, 0.306848, 2.274215, 0.299934),
        .l(2.294943, 0.163697),
        .c(2.297918, 0.141988, 2.292981, 0.136054, 2.282110, 0.136054),
        .l(2.136997, 0.136054),
        .c(2.125145, 0.136054, 2.118231, 0.139029, 2.115272, 0.149884),
        .l(2.077755, 0.296061),
        .c(2.075777, 0.304953, 2.067881, 0.313830, 2.059986, 0.313830),
        .l(2.001741, 0.313830),
        .c(1.987928, 0.313830, 1.983972, 0.313830, 1.981994, 0.326679),
        .l(1.969161, 0.419398),
        .c(1.966203, 0.439146, 1.970159, 0.447041, 1.981013, 0.447041),
        .l(2.030365, 0.447041),
        .c(2.042217, 0.447041, 2.051110, 0.450997, 2.050112, 0.460871),
        .l(2.015571, 0.700017),
        .c(2.014574, 0.706932, 2.014574, 0.712849, 2.014574, 0.718783),
        .c(2.014574, 0.791822, 2.077755, 0.837234, 2.168580, 0.837234),
        .z,
        .m(0.006915, 0.000000),
    ]

    // --- derived ----------------------------------------------------------
    // Computed exactly as the overlay computes them, from the constants above.
    static var waveWidthU: CGFloat { CGFloat(barCount) * barU + CGFloat(barCount - 1) * gapU }
    static var lampWidth: CGFloat { dotD * markScale }
    static var waveWidth: CGFloat { waveWidthU * markScale }
    static var wordmarkWidth: CGFloat { wordmarkHeight * wordmarkAspect }
    static var contentWidth: CGFloat { lampWidth + lampGap + waveWidth + layoutGap + wordmarkWidth }
    static var contentX: CGFloat { (pillWidth - contentWidth) / 2 }
    static var transientWaveWidthU: CGFloat {
        CGFloat(transientBarMaxU.count) * barU + CGFloat(transientBarMaxU.count - 1) * gapU
    }
    static var transientWaveScale: CGFloat { (pillWidth - 2 * transientWaveInset) / transientWaveWidthU }

    /// Heights in mark units for a level of 0..7: every bar is barU tall at
    /// rest (a dot) and grows towards its own maximum.
    static func waveHeights(level: CGFloat, maxima: [CGFloat]) -> [CGFloat] {
        let l = max(0, min(7, level))
        return maxima.map { barU + ($0 - barU) * l / 7 }
    }

    /// Level 0..7 for one block of samples, by its RMS.
    static func level(rms: Double) -> Int {
        levels.filter { rms >= $0 }.count
    }
}
