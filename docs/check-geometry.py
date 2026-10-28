#!/usr/bin/env python3
"""Check the Windows and macOS copies of the pill against bin/sayit-overlay.

The pill is one design with three implementations. The Windows indicator
(win/lib/indicator-geometry.ps1) and Sayit.app on macOS
(mac/Sources/Common/PillGeometry.swift) each hold their own copy of the
geometry, because neither PowerShell nor compiled Swift can read the overlay's
Python constants at runtime, and both copies were transcribed by hand: the
wordmark outlines were lifted from the overlay rather than converted again
from the font, because a second conversion is a second shape.

A hand-made copy drifts silently. Change a constant in the overlay and the
sides simply disagree, on different machines, with nothing to say so. This
script is what says so. It is the same guard docs/build-logo.py --check gives
the logo, which had already drifted once before that check existed.

It compares, and does not rewrite. Regenerating the PowerShell or the Swift
would gain no accuracy the comparison does not already give -- the literal
formats are siblings -- and would cost the files their comments, which explain
the design rather than restate the numbers.

Only hand-written numbers are compared. The derived values (WaveWidth,
ContentX and their kin) are computed on every side from the constants checked
here, with the formulae written out in plain sight next to each other.

The macOS copy carries more of the overlay than the Windows one: Sayit.app
also draws the transient (recording-only) pill, so TRANSIENT_WAVE_INSET and
TRANSIENT_BAR_MAX_U are checked there, and sayit-rec computes the level
itself, so LEVELS, EASE and AUDIO_IDLE_S are too.

MinScale and MaxScale are deliberately absent from the Windows check: the pill
can be resized on Windows and cannot on Linux, so they answer to nothing in
the overlay. The macOS scale limits live in the agent's settings, not here.

Runs anywhere Python does, PowerShell and Swift not required: the .ps1 and the
.swift are read as text.

Usage:   python3 docs/check-geometry.py

Exit codes:
  0  every side agrees with the overlay
  1  at least one has drifted, with each difference named
"""

import collections
import importlib.machinery
import importlib.util
import io
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OVERLAY = ROOT / "bin" / "sayit-overlay"
PS1 = ROOT / "win" / "lib" / "indicator-geometry.ps1"
SWIFT = ROOT / "mac" / "Sources" / "Common" / "PillGeometry.swift"

# PowerShell name, overlay name. Every plain number in the .ps1 that is not
# derived and not Windows-only appears here; a new constant on either side
# should be added, or it is checked by nothing.
SCALARS = [
    ("TransientWaveInset", "TRANSIENT_WAVE_INSET"),
    ("PillWidth", "WIDTH"),
    ("PillHeight", "HEIGHT"),
    ("PillRadius", "RADIUS"),
    ("PillBorder", "BORDER"),
    ("MarkScale", "MARK_SCALE"),
    ("BarCount", "BAR_COUNT"),
    ("BarU", "BAR_U"),
    ("GapU", "GAP_U"),
    ("DotD", "DOT_D"),
    ("LampGap", "LAMP_GAP"),
    ("LayoutGap", "LAYOUT_GAP"),
    ("WordmarkHeight", "WORDMARK_H"),
    ("WordmarkAspect", "WORDMARK_ASPECT"),
]

VECTORS = [
    ("TransientBarMaxU", "TRANSIENT_BAR_MAX_U"),
    ("BarMaxU", "BAR_MAX_U"),
    ("LampLit", "LAMP_LIT"),
    ("LampUnlit", "LAMP_UNLIT"),
]

# The ink and the pill are not module constants in the overlay; they are named
# only where it reports what it draws. That helper is the honest source, so it
# is what we ask.
STATE_COLOURS = [("InkRgb", "wordmark_rgb"), ("PillRgb", "pill_rgb")]

# Swift name, overlay name. The same rule: every plain number in
# PillGeometry.swift that is not derived appears here.
SWIFT_SCALARS = [
    ("pillWidth", "WIDTH"),
    ("pillHeight", "HEIGHT"),
    ("pillRadius", "RADIUS"),
    ("pillBorder", "BORDER"),
    ("markScale", "MARK_SCALE"),
    ("barCount", "BAR_COUNT"),
    ("barU", "BAR_U"),
    ("gapU", "GAP_U"),
    ("dotD", "DOT_D"),
    ("lampGap", "LAMP_GAP"),
    ("layoutGap", "LAYOUT_GAP"),
    ("transientWaveInset", "TRANSIENT_WAVE_INSET"),
    ("ease", "EASE"),
    ("audioIdleS", "AUDIO_IDLE_S"),
    ("wordmarkHeight", "WORDMARK_H"),
    ("wordmarkAspect", "WORDMARK_ASPECT"),
]

SWIFT_VECTORS = [
    ("barMaxU", "BAR_MAX_U"),
    ("transientBarMaxU", "TRANSIENT_BAR_MAX_U"),
    ("lampLit", "LAMP_LIT"),
    ("lampUnlit", "LAMP_UNLIT"),
    ("levels", "LEVELS"),
]

SWIFT_STATE_COLOURS = [("inkRgb", "wordmark_rgb"), ("pillRgb", "pill_rgb")]

EPS = 1e-9
NUMBER = r"-?\d+(?:\.\d+)?"


def load_overlay():
    """Import bin/sayit-overlay as a module, without running its main().

    Deliberately a copy of the loader in docs/build-logo.py rather than an
    import of it: this check should not break when the logo builder changes.
    """
    loader = importlib.machinery.SourceFileLoader("overlay", str(OVERLAY))
    spec = importlib.util.spec_from_loader("overlay", loader)
    module = importlib.util.module_from_spec(spec)
    argv, stdout = sys.argv, sys.stdout
    sys.argv = ["sayit-overlay", "--help"]
    sys.stdout = io.StringIO()
    try:
        spec.loader.exec_module(module)
    except SystemExit:
        pass
    finally:
        sys.argv, sys.stdout = argv, stdout
    return module


def numbers(text):
    return [float(n) for n in re.findall(NUMBER, text)]


def ps_scalar(src, name):
    m = re.search(r"^\$script:%s\s*=\s*(%s)" % (name, NUMBER), src, re.M)
    return None if m is None else float(m.group(1))


def ps_vector(src, name):
    m = re.search(r"^\$script:%s\s*=\s*@\(([^)]*)\)" % name, src, re.M)
    return None if m is None else numbers(m.group(1))


def ps_wordmark(src):
    """The outline segments, as (command, coordinates) in file order."""
    head, _, rest = src.partition("$script:Wordmark = @(")
    if not rest:
        return None
    block = rest.split("\n)", 1)[0]
    return [(cmd, tuple(numbers(nums)))
            for cmd, nums in re.findall(r"@\('([a-z])'((?:\s*,\s*-?[0-9.]+)*)\s*\)", block)]


def swift_scalar(src, name):
    """`static let name: Type = 1.5`, with or without the type. A value that
    is an expression rather than one literal counts as missing."""
    m = re.search(r"^\s*static let %s(?:\s*:\s*\w+)?\s*=\s*(%s)(?=\s*(?://|$))"
                  % (name, NUMBER), src, re.M)
    return None if m is None else float(m.group(1))


def swift_vector(src, name):
    m = re.search(r"^\s*static let %s(?:\s*:\s*\[\w+\])?\s*=\s*\[([^\]]*)\]" % name, src, re.M)
    return None if m is None else numbers(m.group(1))


def swift_wordmark(src):
    """The outline segments -- .m(x, y), .l(x, y), .c(...), .z -- as
    (command, coordinates) in file order."""
    m = re.search(r"^\s*static let wordmark(?:\s*:\s*\[\w+\])?\s*=\s*\[(.*?)^\s*\]",
                  src, re.M | re.S)
    if m is None:
        return None
    return [(cmd, tuple(numbers(nums)))
            for cmd, nums in re.findall(r"\.([mlcz])\b(?:\(([^)]*)\))?", m.group(1))]


Side = collections.namedtuple(
    "Side", "name path scalars vectors colours scalar vector wordmark wordmark_name missing")

SIDES = [
    Side("Windows", PS1, SCALARS, VECTORS, STATE_COLOURS,
         ps_scalar, ps_vector, ps_wordmark,
         "Wordmark", "$script:%s is missing from the PowerShell"),
    Side("macOS", SWIFT, SWIFT_SCALARS, SWIFT_VECTORS, SWIFT_STATE_COLOURS,
         swift_scalar, swift_vector, swift_wordmark,
         "wordmark", "PillGeometry.%s is missing from the Swift"),
]


def differ(a, b):
    if len(a) != len(b):
        return True
    return any(abs(x - y) > EPS for x, y in zip(a, b))


def compare(side, ov, state, py_marks):
    """Every difference between one side and the overlay, named."""
    src = side.path.read_text(encoding="utf-8")
    faults = []

    for name, py_name in side.scalars:
        got = side.scalar(src, name)
        if got is None:
            faults.append(side.missing % name)
        elif abs(got - float(getattr(ov, py_name))) > EPS:
            faults.append("%s = %g but %s = %g"
                          % (name, got, py_name, float(getattr(ov, py_name))))

    for name, py_name in side.vectors:
        got = side.vector(src, name)
        want = [float(v) for v in getattr(ov, py_name)]
        if got is None:
            faults.append(side.missing % name)
        elif differ(got, want):
            faults.append("%s = %s but %s = %s" % (name, got, py_name, want))

    for name, key in side.colours:
        got = side.vector(src, name)
        want = [float(v) for v in state[key]]
        if got is None:
            faults.append(side.missing % name)
        elif differ(got, want):
            faults.append("%s = %s but the overlay draws %s" % (name, got, want))

    marks = side.wordmark(src)
    if marks is None:
        faults.append(side.missing % side.wordmark_name)
    elif len(marks) != len(py_marks):
        faults.append("the wordmark has %d segments but the overlay has %d"
                      % (len(marks), len(py_marks)))
    else:
        for i, (a, b) in enumerate(zip(marks, py_marks)):
            if a[0] != b[0] or differ(a[1], b[1]):
                faults.append("wordmark segment %d is %s %s but the overlay has %s %s"
                              % (i, a[0], list(a[1]), b[0], list(b[1])))
    return faults


def main():
    ov = load_overlay()
    state = ov._test_state(True)
    py_marks = [(seg[0], tuple(float(v) for v in seg[1:])) for seg in ov.WORDMARK]
    status = 0

    for side in SIDES:
        faults = compare(side, ov, state, py_marks)
        if faults:
            print("the %s pill has drifted from bin/sayit-overlay:" % side.name,
                  file=sys.stderr)
            for f in faults:
                print("  " + f, file=sys.stderr)
            print("\nedit %s to match, then rerun."
                  % side.path.relative_to(ROOT).as_posix(), file=sys.stderr)
            status = 1
        else:
            print("the %s pill matches bin/sayit-overlay: %d constants, %d vectors, "
                  "%d wordmark segments"
                  % (side.name, len(side.scalars), len(side.vectors) + len(side.colours),
                     len(py_marks)))
    return status


if __name__ == "__main__":
    sys.exit(main())
