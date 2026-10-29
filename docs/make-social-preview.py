#!/usr/bin/env python3
"""Builds docs/social-preview.png, the 1280x640 card GitHub shows when the
repository is linked elsewhere.

The wordmark is not redrawn: the card renders docs/logo-wordmark.svg (SAYIT
and the tagline, without the pill), which docs/build-logo.py writes, in the
colours it already uses for a dark page. Only the text beside it is set here.

GitHub has no API for this image. Upload the result by hand under
Settings -> General -> Social preview.

Usage:   python3 docs/make-social-preview.py   (needs pycairo and PyGObject
         with librsvg; Montserrat and Noto Sans are used when installed)
"""
import os
import re

import cairo
import gi

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 1280, 640
BG, INK, MUTED, LINE = "#0d1117", "#e6edf3", "#8b949e", "#30363d"
BRAND, SANS = "Montserrat", "Noto Sans"


def rgb(hexstr):
    h = hexstr.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def dark_wordmark():
    """The wordmark with its dark-theme colours made unconditional."""
    with open(os.path.join(HERE, "logo-wordmark.svg"), encoding="utf-8") as f:
        svg = f.read()
    dark = re.search(r"@media \(prefers-color-scheme: dark\) \{(.*?)\}\s*\}", svg, re.S)
    if not dark:
        raise SystemExit("logo-wordmark.svg has no dark-theme block; update this script")
    for cls, colour in re.findall(r"\.(\w) \{ fill: (#[0-9a-f]{6}); \}", dark.group(1)):
        svg = re.sub(r"(\.%s \{ fill: )#[0-9a-f]{6}" % cls, r"\g<1>" + colour, svg, count=1)
    return Rsvg.Handle.new_from_data(svg.encode())


def text(cr, x, y, s, colour, family, size, bold=False):
    cr.select_font_face(family, cairo.FONT_SLANT_NORMAL,
                        cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
    cr.set_font_size(size)
    cr.set_source_rgb(*rgb(colour))
    cr.move_to(x, y)
    cr.show_text(s)
    return x + cr.text_extents(s).x_advance


def main():
    surf = cairo.ImageSurface(cairo.FORMAT_RGB24, W, H)
    cr = cairo.Context(surf)
    cr.set_source_rgb(*rgb(BG))
    cr.paint()

    # The wordmark, left, vertically centred, at the size and column it had
    # under the pill in the earlier card.
    logo = dark_wordmark()
    lw = 387
    lh = lw * 191 / 456
    vp = Rsvg.Rectangle()
    vp.x, vp.y, vp.width, vp.height = 112.4, (H - lh) / 2, lw, lh
    logo.render_document(cr, vp)

    # A hairline between logo and text.
    cr.set_source_rgb(*rgb(LINE))
    cr.rectangle(600, 150, 1.5, H - 300)
    cr.fill()

    x = 650
    text(cr, x, 222, "Local push-to-talk", INK, BRAND, 46, True)
    text(cr, x, 280, "dictation", INK, BRAND, 46, True)
    text(cr, x, 336, "Hold a button, speak, release.", MUTED, SANS, 25)
    text(cr, x, 370, "Your words land in the focused window.", MUTED, SANS, 25)

    cx = x
    for name in ("Linux", "Windows 11", "macOS"):
        cr.select_font_face(BRAND, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(19)
        tw = cr.text_extents(name).x_advance
        cr.new_sub_path()
        r, cw, ch, cy = 20, tw + 40, 40, 410
        cr.arc(cx + cw - r, cy + r, r, -1.5708, 1.5708)
        cr.arc(cx + r, cy + r, r, 1.5708, 4.7124)
        cr.close_path()
        cr.set_source_rgb(*rgb(LINE))
        cr.set_line_width(2)
        cr.stroke()
        text(cr, cx + 20, cy + 27, name, INK, BRAND, 19, True)
        cx += cw + 14

    text(cr, x, 500, "whisper.cpp  ·  Swedish KB-Whisper  ·  offline  ·  MIT",
         MUTED, SANS, 20)

    out = os.path.join(HERE, "social-preview.png")
    surf.write_to_png(out)
    print(out)


if __name__ == "__main__":
    main()
