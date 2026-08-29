#!/usr/bin/env python3
"""Check win/lib/indicator-geometry.ps1 against bin/sayit-overlay.

The pill is one design with two implementations. The Windows indicator holds
its own copy of the geometry, because PowerShell cannot read the overlay's
Python constants at runtime, and that copy was transcribed by hand: the
wordmark outlines were lifted from the overlay rather than converted again
from the font, because a second conversion is a second shape.

A hand-made copy drifts silently. Change a constant in the overlay and the two
sides simply disagree, on two machines, with nothing to say so. This script is
what says so. It is the same guard docs/build-logo.py --check gives the logo,
which had already drifted once before that check existed.

It compares, and does not rewrite. Regenerating the PowerShell would gain no
accuracy the comparison does not already give -- the two literal formats are
siblings -- and would cost the file its comments, which explain the design
rather than restate the numbers.

Only hand-written numbers are compared. The derived values (WaveWidth,
ContentX and their kin) are computed on both sides from the constants checked
here, with the formulae written out in plain sight next to each other.

MinScale and MaxScale are deliberately absent: the pill can be resized on
Windows and cannot on Linux, so they answer to nothing in the overlay.

Runs anywhere Python does, PowerShell not required: the .ps1 is read as text.

Usage:   python3 docs/check-geometry.py

Exit codes:
  0  the two sides agree
  1  they have drifted, with each difference named
"""

import importlib.machinery
import importlib.util
import io
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OVERLAY = ROOT / "bin" / "sayit-overlay"
PS1 = ROOT / "win" / "lib" / "indicator-geometry.ps1"

# PowerShell name, overlay name. Every plain number in the .ps1 that is not
# derived and not Windows-only appears here; a new constant on either side
# should be added, or it is checked by nothing.
SCALARS = [
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
    ("BarMaxU", "BAR_MAX_U"),
    ("LampLit", "LAMP_LIT"),
    ("LampUnlit", "LAMP_UNLIT"),
]

# The ink and the pill are not module constants in the overlay; they are named
# only where it reports what it draws. That helper is the honest source, so it
# is what we ask.
STATE_COLOURS = [("InkRgb", "wordmark_rgb"), ("PillRgb", "pill_rgb")]

EPS = 1e-9


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
    return [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", text)]


def ps_scalar(src, name):
    m = re.search(r"^\$script:%s\s*=\s*(-?\d+(?:\.\d+)?)" % name, src, re.M)
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


def differ(a, b):
    if len(a) != len(b):
        return True
    return any(abs(x - y) > EPS for x, y in zip(a, b))


def main():
    src = PS1.read_text(encoding="utf-8")
    ov = load_overlay()
    faults = []

    for ps_name, py_name in SCALARS:
        got = ps_scalar(src, ps_name)
        if got is None:
            faults.append("$script:%s is missing from the PowerShell" % ps_name)
        elif abs(got - float(getattr(ov, py_name))) > EPS:
            faults.append("%s = %g but %s = %g"
                          % (ps_name, got, py_name, float(getattr(ov, py_name))))

    for ps_name, py_name in VECTORS:
        got = ps_vector(src, ps_name)
        want = [float(v) for v in getattr(ov, py_name)]
        if got is None:
            faults.append("$script:%s is missing from the PowerShell" % ps_name)
        elif differ(got, want):
            faults.append("%s = %s but %s = %s" % (ps_name, got, py_name, want))

    state = ov._test_state(True)
    for ps_name, key in STATE_COLOURS:
        got = ps_vector(src, ps_name)
        want = [float(v) for v in state[key]]
        if got is None:
            faults.append("$script:%s is missing from the PowerShell" % ps_name)
        elif differ(got, want):
            faults.append("%s = %s but the overlay draws %s" % (ps_name, got, want))

    ps_marks = ps_wordmark(src)
    py_marks = [(seg[0], tuple(float(v) for v in seg[1:])) for seg in ov.WORDMARK]
    if ps_marks is None:
        faults.append("$script:Wordmark is missing from the PowerShell")
    elif len(ps_marks) != len(py_marks):
        faults.append("the wordmark has %d segments but the overlay has %d"
                      % (len(ps_marks), len(py_marks)))
    else:
        for i, (a, b) in enumerate(zip(ps_marks, py_marks)):
            if a[0] != b[0] or differ(a[1], b[1]):
                faults.append("wordmark segment %d is %s %s but the overlay has %s %s"
                              % (i, a[0], list(a[1]), b[0], list(b[1])))

    if faults:
        print("the Windows pill has drifted from bin/sayit-overlay:", file=sys.stderr)
        for f in faults:
            print("  " + f, file=sys.stderr)
        print("\nedit win/lib/indicator-geometry.ps1 to match, then rerun.",
              file=sys.stderr)
        return 1

    print("the Windows pill matches bin/sayit-overlay: %d constants, %d vectors, "
          "%d wordmark segments"
          % (len(SCALARS), len(VECTORS) + len(STATE_COLOURS), len(py_marks)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
