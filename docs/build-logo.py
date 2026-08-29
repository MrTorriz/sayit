#!/usr/bin/env python3
"""Rebuild docs/logo.svg and docs/logo-lockup.svg from bin/sayit-overlay.

The logo is the overlay's pill, so its geometry is read out of the overlay's
own constants rather than drawn by hand. That is the whole point of this
script: the two used to be maintained separately and drifted apart, until the
README showed a mark the product had not drawn in a long time. Change the
pill in bin/sayit-overlay, run this, and the logo follows.

The typography in the lockup is not generated. It is outlined type, lifted
unchanged from the previous lockup, and this script only moves it under the
new mark.

Usage:   python3 docs/build-logo.py [--check]
         --check  exit 1 if the committed files differ from what this
                  script would write, and write nothing

Exit codes:
  0  files written, or (--check) they are already up to date
  1  (--check) the committed files are stale
"""

import importlib.machinery
import importlib.util
import io
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OVERLAY = ROOT / "bin" / "sayit-overlay"
LOGO = ROOT / "docs" / "logo.svg"
LOCKUP = ROOT / "docs" / "logo-lockup.svg"

# The meter is drawn at its top level, the pattern the overlay's BAR_MAX_U was
# shaped to read as: a phrase, quiet at both ends. A logo showing the resting
# row would be ten identical dots.
LEVEL = 7.0

# The lockup keeps the old mark's left edge and width, so the column of the
# logo is unchanged and only its height differs.
MARK_X, MARK_Y, MARK_W = 56.5, 60.0, 441.08
OLD_WORDMARK_TOP = 345.8            # where the old lockup set the SAYIT top
OLD_TAGLINE_BOTTOM = 513.24
GAP = 32.3                          # the old gap between mark and wordmark
MARGIN = 60.0                       # the old bottom margin


def load_overlay():
    """Import bin/sayit-overlay as a module, without running its main()."""
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


def mark(ov):
    """The pill's elements, in the overlay's own 160x40 pixels."""
    cy = ov.HEIGHT / 2.0
    x = ov.CONTENT_X
    lamp_r = ov.LAMP_W / 2.0
    parts = [
        '<rect class="p" x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%d"/>'
        % (ov.BORDER / 2, ov.BORDER / 2, ov.WIDTH - ov.BORDER,
           ov.HEIGHT - ov.BORDER, ov.RADIUS),
        '<circle class="a" cx="%.3f" cy="%.1f" r="%.3f"/>' % (x + lamp_r, cy, lamp_r),
    ]

    x += ov.LAMP_W + ov.LAMP_GAP
    bw = ov.BAR_U * ov.MARK_SCALE
    for i, height in enumerate(ov.bar_heights(LEVEL)):
        bh = height * ov.MARK_SCALE
        bx = x + i * (ov.BAR_U + ov.GAP_U) * ov.MARK_SCALE
        parts.append('<rect class="w" x="%.3f" y="%.3f" width="%.3f" height="%.3f" rx="%.3f"/>'
                     % (bx, cy - bh / 2.0, bw, bh, bw / 2.0))

    x += ov.WAVE_W + ov.LAYOUT_GAP
    h = ov.WORDMARK_H
    top = cy - h / 2.0
    segs = []
    for seg in ov.WORDMARK:
        if seg[0] == "m":
            segs.append("M%.4f %.4f" % (x + seg[1] * h, top + seg[2] * h))
        elif seg[0] == "l":
            segs.append("L%.4f %.4f" % (x + seg[1] * h, top + seg[2] * h))
        elif seg[0] == "c":
            segs.append("C%.4f %.4f %.4f %.4f %.4f %.4f"
                        % (x + seg[1] * h, top + seg[2] * h,
                           x + seg[3] * h, top + seg[4] * h,
                           x + seg[5] * h, top + seg[6] * h))
        else:
            segs.append("Z")
    while segs and segs[-1].startswith("M"):
        segs.pop()                  # a trailing move draws nothing
    parts.append('<path class="w" d="%s"/>' % " ".join(segs))
    return parts


def typography():
    """The outlined SAYIT wordmark and tagline, from the committed lockup."""
    paths = re.findall(r'<path class="([mta])" d="([^"]+)"/>', LOCKUP.read_text())
    assert len(paths) == 4, "expected four outlined type paths in the lockup"
    # The lamp's red and the typographic red are different colours now, so the
    # type never carries the lamp's class.
    return [(("t" if cls == "a" else cls), d) for cls, d in paths]


def build(ov):
    parts = mark(ov)
    alt_mark = ("sayit: a recording lamp, a ten-bar level meter and the wordmark "
                "sayit, inside a rounded pill")

    logo = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" role="img" aria-label="%s">
  <title>sayit</title>
  <!-- The mark on its own: the pill exactly as bin/sayit-overlay draws it on
       screen. Lamp, ten-bar meter and the wordmark, in that reading order,
       inside a filled pill with a hairline border. The geometry is not drawn
       by hand here; docs/build-logo.py reads it out of the overlay's own
       constants, so the logo cannot drift away from the thing the user sees.

       Colour: the pill is dark and the ink white in both themes, because the
       pill itself is dark on every desktop. It is a screen object, not a piece
       of page furniture, and inverting it would picture something that does
       not exist. The lamp is #ff4d4d, the overlay's LAMP_LIT, shown lit
       because a lit lamp is what the product looks like while it works.

       Size: the wordmark's x-height is 5.6 units of 40, so it is legible from
       about 160 px wide and marginal below 120. Use 160 as the floor.

       docs/logo-lockup.svg adds the wordmark and the tagline below it. -->
  <style>
    .p { fill: #000000; stroke: #ffffff; stroke-width: %s; }
    .w { fill: #ffffff; }
    .a { fill: #ff4d4d; }
  </style>
%s
</svg>
''' % (ov.WIDTH, ov.HEIGHT, ov.WIDTH, ov.HEIGHT, alt_mark, ov.BORDER,
       "\n".join("  " + p for p in parts))

    scale = MARK_W / ov.WIDTH
    mark_bottom = MARK_Y + ov.HEIGHT * scale
    dy = (mark_bottom + GAP) - OLD_WORDMARK_TOP
    vb_h = round(OLD_TAGLINE_BOTTOM + dy + MARGIN)
    alt_lockup = (alt_mark.replace(", inside", " inside")
                  + ", above the wordmark SAYIT and the line DON'T TYPE IT. SAY IT.")

    lockup = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 554 %d" width="554" height="%d" role="img" aria-label="%s">
  <title>sayit</title>
  <!-- Full logo: the mark above the wordmark and the tagline. The type is
       outlined, so nothing here depends on an installed font, and the file
       references no external resource.

       The mark is the pill exactly as bin/sayit-overlay draws it on screen,
       written by docs/build-logo.py from the overlay's own constants rather
       than redrawn by hand, so the logo cannot drift away from the thing the
       user sees. It is scaled here to the width the old four-bar mark
       occupied, which is why the lockup keeps its column and only loses
       height.

       Colour, and why the two reds differ:
         - The pill is dark with white ink in both themes, because the pill is
           dark on every desktop. It is a screen object, not page furniture,
           and inverting it would picture something that does not exist.
         - The lamp is #ff4d4d, the overlay's LAMP_LIT, shown lit because that
           is what the product looks like while it works. On the pill's black
           it reads at about 8:1.
         - The typographic accent sits on the page instead, so it follows the
           theme: #da4453 on light (4.3:1) and #ff4d4d on dark. The lit red
           alone would be 3.3:1 on white, which the tagline is far too small
           to carry. The product's red where the product shows it, a readable
           one where the page does.

       Size: at 280 wide the pill lands at 223 px, past its own 160 px floor,
       and the tagline's cap height at 10.6 px. Use 240 as the floor and 280
       where it matters. For smaller places use docs/logo.svg, the mark alone. -->
  <style>
    .p { fill: #000000; stroke: #ffffff; stroke-width: %s; }
    .w { fill: #ffffff; }
    .a { fill: #ff4d4d; }
    .m { fill: #1f2328; }
    .t { fill: #da4453; }
    @media (prefers-color-scheme: dark) {
      .m { fill: #e6edf3; }
      .t { fill: #ff4d4d; }
    }
  </style>
  <g transform="translate(%s %s) scale(%.6f)">
%s
  </g>
  <g transform="translate(0 %.2f)">
%s
  </g>
</svg>
''' % (vb_h, vb_h, alt_lockup, ov.BORDER, MARK_X, MARK_Y, scale,
       "\n".join("    " + p for p in parts), dy,
       "\n".join('    <path class="%s" d="%s"/>' % ct for ct in typography()))
    return logo, lockup


def main():
    check = "--check" in sys.argv[1:]
    logo, lockup = build(load_overlay())
    stale = []
    for path, text in ((LOGO, logo), (LOCKUP, lockup)):
        if path.read_text() != text:
            stale.append(path.name)
        if not check:
            path.write_text(text)
    if check:
        if stale:
            print("stale, rerun docs/build-logo.py: " + ", ".join(stale), file=sys.stderr)
            return 1
        print("logo files are up to date")
        return 0
    print("wrote %s and %s" % (LOGO.name, LOCKUP.name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
