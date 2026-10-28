#!/usr/bin/env python3
"""Builds the README animations, one dictation per platform:

    docs/demo.gif          Linux, a terminal on a Plasma desktop
    docs/demo-macos.gif    macOS, a text document with the menu bar agent
    docs/demo-windows.gif  Windows 11, a message being written

Each is an illustration of the real hold-to-talk flow, not a screen
recording. The desktops around the pill are drawn here, deliberately plain and
without any vendor's logo. The pill is not: this script executes
bin/sayit-overlay, which defines its geometry and drawing functions without
touching GTK, and draws the pill through those same functions. The Swift and
PowerShell pills share that geometry (docs/check-geometry.py keeps them
equal), so one drawing serves all three, apart from the one difference the
platforms have: the Windows recording pill has no outline.

What the animation shows is what sayit does. Nothing is typed while the
button is held; the microphone is closed at rest and the pill exists only
while it is open; after release the recording is transcribed on the machine,
and the text arrives all at once, because injection is a paste rather than
synthetic per-character typing. The dictated sentences are Swedish because the
default model is Swedish.

Usage:   python3 docs/make-demo.py          (needs pycairo and Pillow)

The fonts are looked up by family name: Cascadia Code, Noto Sans and
Montserrat. A missing family falls back to a fontconfig default, which still
produces a correct picture with different metrics -- check that the longest
line still fits before committing the result.
"""
import math
import os
import sys

import cairo
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))

# --- the overlay itself, as a module ----------------------------------------
# Executing it defines the constants and the drawing functions; GTK is only
# touched inside main(), which is never called here.
OV = {}
_PATH = os.path.join(HERE, os.pardir, "bin", "sayit-overlay")
with open(_PATH, encoding="utf-8") as _f:
    exec(compile(_f.read(), _PATH, "exec"), OV)          # noqa: S102

PW, PH = OV["WIDTH"], OV["HEIGHT"]
PILL_SCALE = 1.5          # the pill drawn larger than life, so it reads at README size

W, SCREEN_H, STRIP_H = 1200, 600, 92
H = SCREEN_H + STRIP_H
FPS_MS = 66

MONO, SANS, BRAND = "Cascadia Code", "Noto Sans", "Montserrat"
RED = (0.855, 0.267, 0.325)          # the logo's typographic red, #da4453


def rgb(hexstr):
    h = hexstr.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def rrect(cr, x, y, w, h, r):
    OV["rounded_rect"](cr, x, y, w, h, r)


def font(cr, family, size, bold=False):
    cr.select_font_face(family, cairo.FONT_SLANT_NORMAL,
                        cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
    cr.set_font_size(size)


def text(cr, x, y, s, colour, family=SANS, size=16, bold=False):
    """Draw s with its baseline at y; return the x after it."""
    font(cr, family, size, bold)
    cr.set_source_rgb(*colour)
    cr.move_to(x, y)
    cr.show_text(s)
    return x + cr.text_extents(s).x_advance


def width(cr, s, family=SANS, size=16, bold=False):
    font(cr, family, size, bold)
    return cr.text_extents(s).x_advance


def wrap(cr, s, maxw, family, size):
    lines, line = [], ""
    for word in s.split():
        trial = (line + " " + word).strip()
        if line and width(cr, trial, family, size) > maxw:
            lines.append(line)
            line = word
        else:
            line = trial
    return lines + [line] if line else lines


def shadow(cr, x, y, w, h, r, depth=14, alpha=0.05):
    """A soft drop shadow from a few stacked translucent shapes."""
    for i in range(depth, 0, -2):
        rrect(cr, x - i / 2, y - i / 4 + 6, w + i, h + i, r + i / 2)
        cr.set_source_rgba(0, 0, 0, alpha)
        cr.fill()


def pill(cr, cx, bottom, level, outline):
    """The recording pill, centred on cx with its lower edge at bottom."""
    s = PILL_SCALE
    cr.save()
    cr.translate(cx - PW * s / 2, bottom - PH * s)
    cr.scale(s, s)
    border, radius = OV["BORDER"], OV["RADIUS"]
    inset = border / 2 if outline else 0
    rrect(cr, inset, inset, PW - 2 * inset, PH - 2 * inset, radius)
    cr.set_source_rgb(0, 0, 0)
    if outline:
        cr.fill_preserve()
        cr.set_source_rgb(1, 1, 1)
        cr.set_line_width(border)
        cr.stroke()
    else:
        cr.fill()
    OV["draw_wave"](cr, OV["TRANSIENT_WAVE_INSET"], PH / 2.0, level,
                    OV["TRANSIENT_WAVE_SCALE"], OV["TRANSIENT_BAR_MAX_U"])
    cr.restore()


# --- the timeline -------------------------------------------------------------
# One dictation, the same in every film. Levels are 0..7, the meter's scale.
SPEECH = [1.6, 3.4, 5.1, 6.2, 5.4, 3.9, 4.8, 6.6, 6.9, 5.7, 4.1, 5.5, 6.8, 6.1,
          4.4, 2.8, 1.2, 0.6, 3.6, 5.9, 6.4, 5.2, 4.6, 6.3, 6.7, 5.0, 3.1, 4.9,
          6.0, 5.6, 3.8, 2.2, 0.9, 0.3]


def timeline():
    """(phase, level, frame-in-phase) for every frame."""
    out = [("idle", 0.0, i) for i in range(20)]
    out += [("held", 0.0, i) for i in range(5)]
    smooth = 0.0
    for i, lv in enumerate(SPEECH):
        smooth += (lv - smooth) * 0.6
        out.append(("speak", smooth, i))
    out += [("transcribe", 0.0, i) for i in range(9)]
    out += [("pasted", 0.0, i) for i in range(42)]
    return out


def cursor_on(i):
    return (i // 8) % 2 == 0          # a terminal's ~530 ms blink


# --- the strip under the desktop --------------------------------------------
STEPS = (("Hold", "held"), ("Speak", "speak"), ("Release", "transcribe"),
         ("Pasted", "pasted"))
ORDER = ["idle", "held", "speak", "transcribe", "pasted"]
CAPTIONS = {
    "idle":       "Ready. The microphone is closed until you press.",
    "held":       "The pill appears as the microphone opens.",
    "speak":      "The waveform follows your voice. Nothing is typed yet.",
    "transcribe": "Release: the recording is transcribed on this machine.",
    "pasted":     "The text lands in the focused window in one paste.",
}


def trigger_glyph(cr, x, y, kind, held):
    """A mouse with its thumb button, or a key cap, lit while held."""
    lit = RED if held else rgb("#5b6470")
    if kind == "key":
        rrect(cr, x, y + 6, 46, 42, 8)
        cr.set_source_rgb(*(rgb("#2a1418") if held else rgb("#1c2128")))
        cr.fill_preserve()
        cr.set_source_rgb(*lit)
        cr.set_line_width(2)
        cr.stroke()
        w = width(cr, "F18", BRAND, 14, True)
        text(cr, x + 23 - w / 2, y + 33, "F18", lit, BRAND, 14, True)
        return 46
    rrect(cr, x + 6, y, 34, 54, 17)
    cr.set_source_rgb(*rgb("#1c2128"))
    cr.fill_preserve()
    cr.set_source_rgb(*rgb("#5b6470"))
    cr.set_line_width(2)
    cr.stroke()
    cr.move_to(x + 23, y + 6)
    cr.line_to(x + 23, y + 18)
    cr.stroke()
    rrect(cr, x, y + 22, 9, 16, 4)            # the thumb button
    cr.set_source_rgb(*lit)
    cr.fill()
    return 40


def strip(cr, phase, trigger):
    kind, label = trigger
    y0 = SCREEN_H
    cr.set_source_rgb(*rgb("#0d1117"))
    cr.rectangle(0, y0, W, STRIP_H)
    cr.fill()
    held = phase in ("held", "speak")

    gx = 34
    gw = trigger_glyph(cr, gx, y0 + 18, kind, held)
    text(cr, gx + gw + 14, y0 + 42, label, rgb("#e6edf3"), BRAND, 15, True)
    text(cr, gx + gw + 14, y0 + 62, "held" if held else "released",
         RED if held else rgb("#7d8590"), BRAND, 13, True)

    # The steps, as chips: done, current, or still to come.
    cur = ORDER.index(phase)
    chip_h, gap, pad = 34, 12, 18
    widths = [width(cr, f"{n}  {name}", BRAND, 15, True) + 2 * pad
              for n, (name, _) in enumerate(STEPS, 1)]
    x = W - 34 - sum(widths) - gap * (len(STEPS) - 1)
    for n, ((name, key), cw) in enumerate(zip(STEPS, widths), 1):
        idx = ORDER.index(key)
        state = ("now" if idx == cur or (key == "held" and phase == "speak")
                 else "done" if idx < cur else "next")
        rrect(cr, x, y0 + 14, cw, chip_h, chip_h / 2)
        if state == "now":
            cr.set_source_rgb(*RED)
            cr.fill()
            fg = (1, 1, 1)
        elif state == "done":
            cr.set_source_rgb(*rgb("#21262d"))
            cr.fill()
            fg = rgb("#c9d1d9")
        else:
            cr.set_source_rgb(*rgb("#30363d"))
            cr.set_line_width(1.5)
            cr.stroke()
            fg = rgb("#6e7681")
        text(cr, x + pad, y0 + 14 + 23, f"{n}  {name}", fg, BRAND, 15, True)
        x += cw + gap
    cap = CAPTIONS[phase]
    cw = width(cr, cap, SANS, 15)
    right = W - 34
    text(cr, right - cw, y0 + 74, cap, rgb("#8b949e"), SANS, 15)


# --- Linux: a terminal on a Plasma-like desktop -----------------------------
LINUX_SAID = "Hantera tomma inspelningar utan att krascha"


def linux(cr, phase, level, i):
    cr.set_source_rgb(*rgb("#1b2836"))
    cr.paint()
    for pts, col in (([(0, 380), (520, 0), (900, 0), (0, 600)], "#1f3042"),
                     ([(700, 600), (1200, 160), (1200, 600)], "#22374b"),
                     ([(1200, 0), (980, 0), (1200, 220)], "#203245")):
        cr.move_to(*pts[0])
        for p in pts[1:]:
            cr.line_to(*p)
        cr.close_path()
        cr.set_source_rgb(*rgb(col))
        cr.fill()

    # The panel.
    py = SCREEN_H - 44
    cr.set_source_rgb(*rgb("#202326"))
    cr.rectangle(0, py, W, 44)
    cr.fill()
    cr.arc(26, py + 22, 11, 0, 2 * math.pi)
    cr.set_source_rgb(*rgb("#3daee9"))
    cr.fill()
    for k, col in enumerate(("#31363b", "#31363b", "#31363b")):
        rrect(cr, 52 + k * 44, py + 6, 36, 32, 6)
        cr.set_source_rgb(*rgb(col))
        cr.fill()
    rrect(cr, 52, py + 6, 36, 32, 6)          # the terminal, active
    cr.set_source_rgb(*rgb("#3b4045"))
    cr.fill()
    text(cr, 60, py + 28, ">_", rgb("#e6edf3"), MONO, 13, True)
    cr.set_source_rgb(*rgb("#3daee9"))
    cr.rectangle(56, py + 41, 28, 3)
    cr.fill()
    text(cr, W - 66, py + 28, "21:14", rgb("#e6edf3"), SANS, 14)

    # The window.
    x, y, w, h = 120, 56, 960, 340
    shadow(cr, x, y, w, h, 8, alpha=0.08)
    rrect(cr, x, y, w, h, 8)
    cr.set_source_rgb(*rgb("#141619"))
    cr.fill()
    rrect(cr, x, y, w, 36, 8)
    cr.rectangle(x, y + 18, w, 18)
    cr.set_source_rgb(*rgb("#2a2e32"))
    cr.fill()
    title = "~/projects/sayit : bash"
    text(cr, x + w / 2 - width(cr, title, SANS, 14) / 2, y + 23, title,
         rgb("#d6dade"), SANS, 14)
    cx = x + w - 22
    cr.set_line_width(1.6)
    cr.set_source_rgb(*rgb("#d6dade"))
    for k in range(3):                         # close, maximise, minimise
        bx = cx - k * 30
        if k == 0:
            cr.move_to(bx - 5, y + 13); cr.line_to(bx + 5, y + 23)
            cr.move_to(bx + 5, y + 13); cr.line_to(bx - 5, y + 23)
        elif k == 1:
            cr.move_to(bx - 6, y + 21); cr.line_to(bx, y + 15); cr.line_to(bx + 6, y + 21)
        else:
            cr.move_to(bx - 6, y + 15); cr.line_to(bx, y + 21); cr.line_to(bx + 6, y + 15)
        cr.stroke()

    lx, ly, lh, size = x + 22, y + 74, 30, 19
    blue, red, fg, green = rgb("#1d99f3"), rgb("#ed254e"), rgb("#fcfcfc"), rgb("#1cdc9a")

    def prompt(yy):
        xx = text(cr, lx, yy, "~/projects/sayit", blue, MONO, size, True)
        return text(cr, xx, yy, " ❯ ", red, MONO, size, True)

    xx = prompt(ly)
    text(cr, xx, ly, "git status --short", fg, MONO, size, True)
    xx = text(cr, lx, ly + lh, "M  ", green, MONO, size, True)
    text(cr, xx, ly + lh, "bin/sayit-transcribe", fg, MONO, size, True)
    xx = text(cr, lx, ly + 2 * lh, "M  ", green, MONO, size, True)
    text(cr, xx, ly + 2 * lh, "tests/transcribe.bats", fg, MONO, size, True)
    yy = ly + 3 * lh + 12
    xx = prompt(yy)
    xx = text(cr, xx, yy, 'git commit -m "', fg, MONO, size, True)
    if phase == "pasted":
        xx = text(cr, xx, yy, LINUX_SAID, fg, MONO, size, True)
    if phase != "pasted" or cursor_on(i):
        cr.set_source_rgb(*fg)
        cr.rectangle(xx + 1, yy - 17, 10, 22)
        cr.fill()

    if phase in ("held", "speak"):
        pill(cr, W / 2, py - 18, level, outline=True)


# --- macOS: a document and the menu bar agent -------------------------------
MAC_SAID = "Boka service för bilen på fredag och ring verkstaden före lunch."


def mac_glyph(cr, x, cy, recording):
    """The menu bar item: a waveform, inside a red disc while recording."""
    ink = rgb("#1d1d1f")
    if recording:
        cr.arc(x + 10, cy, 10, 0, 2 * math.pi)
        cr.set_source_rgb(*rgb("#ff3b30"))      # systemRed, as Sayit.app tints it
        cr.fill()
        ink = (1, 1, 1)
    hs = (5, 9, 13, 9, 5) if recording else (6, 11, 16, 11, 6)
    step = 3.6 if recording else 4.2
    x0 = x + 10 - step * 2
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    cr.set_line_width(2)
    cr.set_source_rgb(*ink)
    for k, hh in enumerate(hs):
        cr.move_to(x0 + k * step, cy - hh / 2)
        cr.line_to(x0 + k * step, cy + hh / 2)
    cr.stroke()
    cr.set_line_cap(cairo.LINE_CAP_BUTT)


def macos(cr, phase, level, i):
    cr.set_source_rgb(*rgb("#c9cfe8"))
    cr.paint()
    for cx_, cy_, r, col in ((150, 520, 420, "#b8c0e3"), (1100, 80, 380, "#d8cdea"),
                             (980, 640, 300, "#aab4df")):
        cr.arc(cx_, cy_, r, 0, 2 * math.pi)
        cr.set_source_rgb(*rgb(col))
        cr.fill()

    # The menu bar.
    cr.set_source_rgb(*rgb("#ecebf1"))
    cr.rectangle(0, 0, W, 30)
    cr.fill()
    ink = rgb("#1d1d1f")
    x = text(cr, 20, 20, "TextEdit", ink, SANS, 14, True) + 22
    for item in ("File", "Edit", "Format", "View", "Window", "Help"):
        x = text(cr, x, 20, item, ink, SANS, 14) + 20
    clock = "Wed 28 Oct  21:14"
    cw = width(cr, clock, SANS, 14)
    text(cr, W - 18 - cw, 20, clock, ink, SANS, 14)
    recording = phase in ("held", "speak")
    gx = W - 18 - cw - 44
    if recording:
        rrect(cr, gx - 6, 3, 32, 24, 6)
        cr.set_source_rgba(0, 0, 0, 0.08)
        cr.fill()
    mac_glyph(cr, gx, 15, recording)

    # The document.
    x, y, w, h = 210, 62, 780, 330
    shadow(cr, x, y, w, h, 12)
    rrect(cr, x, y, w, h, 12)
    cr.set_source_rgb(1, 1, 1)
    cr.fill()
    rrect(cr, x, y, w, 40, 12)
    cr.rectangle(x, y + 20, w, 20)
    cr.set_source_rgb(*rgb("#f3f2f5"))
    cr.fill()
    cr.set_source_rgb(*rgb("#dcdbe0"))
    cr.rectangle(x, y + 40, w, 1)
    cr.fill()
    for k, col in enumerate(("#ff5f57", "#febc2e", "#28c840")):
        cr.arc(x + 22 + k * 20, y + 20, 6.5, 0, 2 * math.pi)
        cr.set_source_rgb(*rgb(col))
        cr.fill()
    title = "Veckoplan.txt"
    text(cr, x + w / 2 - width(cr, title, SANS, 14, True) / 2, y + 25, title,
         rgb("#4a4a4f"), SANS, 14, True)

    tx, ty, size = x + 40, y + 92, 20
    text(cr, tx, ty, "Veckoplan", ink, SANS, 24, True)
    lines = ["Måndag: uppdatera servern och kontrollera backuperna.",
             "Onsdag: lunch med teamet klockan tolv."]
    for k, ln in enumerate(lines):
        text(cr, tx, ty + 46 + k * 34, "•  " + ln, rgb("#333336"), SANS, size)
    yy = ty + 46 + 2 * 34
    xx = text(cr, tx, yy, "•  ", rgb("#333336"), SANS, size)
    if phase == "pasted":
        for k, ln in enumerate(wrap(cr, MAC_SAID, w - 120, SANS, size)):
            end = text(cr, xx, yy + k * 34, ln, rgb("#333336"), SANS, size)
        xx, yy = end, yy + k * 34
    if phase != "pasted" or cursor_on(i):
        cr.set_source_rgb(*rgb("#0a64d8"))
        cr.rectangle(xx + 2, yy - 18, 2, 24)
        cr.fill()

    # The Dock, plain coloured tiles rather than anyone's icons.
    tiles = ("#5aa0f2", "#f2a65a", "#7bc96f", "#b07ce8", "#f27a7a", "#e8d36a", "#6fd0c9")
    dw = len(tiles) * 54 + 14
    dx, dy = W / 2 - dw / 2, SCREEN_H - 70
    rrect(cr, dx, dy, dw, 62, 18)
    cr.set_source_rgba(1, 1, 1, 0.55)
    cr.fill()
    for k, col in enumerate(tiles):
        rrect(cr, dx + 14 + k * 54, dy + 8, 44, 44, 11)
        cr.set_source_rgb(*rgb(col))
        cr.fill()

    if recording:
        pill(cr, W / 2, dy - 30, level, outline=True)


# --- Windows 11: a message ----------------------------------------------------
WIN_SAID = ("Hej Anna! Jag hinner tyvärr inte till mötet klockan tio. "
            "Kan vi flytta det till eftermiddagen?")


def windows(cr, phase, level, i):
    cr.set_source_rgb(*rgb("#cfe0f3"))
    cr.paint()
    for k, col in enumerate(("#bed4ee", "#aec9ea", "#9fbfe6")):
        cr.move_to(0, 420 + k * 60)
        cr.curve_to(300, 300 + k * 60, 700, 560 + k * 40, W, 340 + k * 70)
        cr.line_to(W, SCREEN_H)
        cr.line_to(0, SCREEN_H)
        cr.close_path()
        cr.set_source_rgb(*rgb(col))
        cr.fill()

    # The taskbar.
    ty = SCREEN_H - 48
    cr.set_source_rgb(*rgb("#eef1f5"))
    cr.rectangle(0, ty, W, 48)
    cr.fill()
    cr.set_source_rgb(*rgb("#d9dde3"))
    cr.rectangle(0, ty, W, 1)
    cr.fill()
    tiles = ("#3b82f6", "#f59e0b", "#10b981", "#8b5cf6", "#ef4444")
    sx = W / 2 - (190 + len(tiles) * 44) / 2
    rrect(cr, sx, ty + 8, 180, 32, 16)
    cr.set_source_rgb(1, 1, 1)
    cr.fill()
    cr.arc(sx + 20, ty + 23, 6, 0, 2 * math.pi)
    cr.set_source_rgb(*rgb("#5f6670"))
    cr.set_line_width(1.6)
    cr.stroke()
    cr.move_to(sx + 24.5, ty + 27.5); cr.line_to(sx + 29, ty + 32); cr.stroke()
    text(cr, sx + 38, ty + 29, "Search", rgb("#5f6670"), SANS, 14)
    for k, col in enumerate(tiles):
        bx = sx + 190 + k * 44
        rrect(cr, bx + 6, ty + 10, 28, 28, 6)
        cr.set_source_rgb(*rgb(col))
        cr.fill()
    bx = sx + 190 + 44                          # the active app
    rrect(cr, bx + 12, ty + 42, 16, 3, 1.5)
    cr.set_source_rgb(*rgb("#0067c0"))
    cr.fill()
    ink = rgb("#1b1b1f")
    text(cr, W - 104, ty + 21, "21:14", ink, SANS, 13)
    text(cr, W - 104, ty + 39, "2026-10-28", ink, SANS, 13)

    # The message window.
    x, y, w, h = 200, 40, 800, 370
    shadow(cr, x, y, w, h, 8)
    rrect(cr, x, y, w, h, 8)
    cr.set_source_rgb(1, 1, 1)
    cr.fill()
    rrect(cr, x, y, w, 40, 8)
    cr.rectangle(x, y + 20, w, 20)
    cr.set_source_rgb(*rgb("#f3f3f3"))
    cr.fill()
    text(cr, x + 16, y + 26, "New message", ink, SANS, 14)
    cr.set_source_rgb(*ink)
    cr.set_line_width(1.2)
    bx = x + w - 24
    cr.move_to(bx - 5, y + 15); cr.line_to(bx + 5, y + 25)
    cr.move_to(bx + 5, y + 15); cr.line_to(bx - 5, y + 25)
    cr.rectangle(bx - 51, y + 15, 10, 10)
    cr.move_to(bx - 97, y + 20); cr.line_to(bx - 87, y + 20)
    cr.stroke()

    grey, line = rgb("#5f6670"), rgb("#e3e6ea")
    fx = x + 28
    for k, (label, value) in enumerate((("To", "Anna Berg"), ("Subject", "Mötet imorgon"))):
        fy = y + 82 + k * 46
        text(cr, fx, fy, label, grey, SANS, 16)
        text(cr, fx + 92, fy, value, ink, SANS, 16)
        cr.set_source_rgb(*line)
        cr.rectangle(fx, fy + 16, w - 56, 1)
        cr.fill()
    by, size = y + 196, 19
    xx, yy = fx, by
    if phase == "pasted":
        for k, ln in enumerate(wrap(cr, WIN_SAID, w - 70, SANS, size)):
            xx = text(cr, fx, by + k * 32, ln, ink, SANS, size)
            yy = by + k * 32
    if phase != "pasted" or cursor_on(i):
        cr.set_source_rgb(*ink)
        cr.rectangle(xx + 2, yy - 18, 1.6, 24)
        cr.fill()
    rrect(cr, x + w - 128, y + h - 58, 100, 36, 6)
    cr.set_source_rgb(*rgb("#0067c0"))
    cr.fill()
    text(cr, x + w - 100, y + h - 34, "Send", (1, 1, 1), SANS, 15, True)

    if phase in ("held", "speak"):
        pill(cr, W / 2, ty - 48, level, outline=False)


# --- rendering ----------------------------------------------------------------
FILMS = (
    ("demo.gif",         linux,   ("mouse", "Thumb button")),
    ("demo-macos.gif",   macos,   ("key",   "Trigger key")),
    ("demo-windows.gif", windows, ("mouse", "Mouse 5")),
)


def render(scene, trigger):
    frames = []
    for phase, level, i in timeline():
        surf = cairo.ImageSurface(cairo.FORMAT_RGB24, W, H)
        cr = cairo.Context(surf)
        scene(cr, phase, level, i)
        strip(cr, phase, trigger)
        surf.flush()
        frames.append(Image.frombuffer("RGB", (W, H), bytes(surf.get_data()),
                                       "raw", "BGRX", surf.get_stride(), 1))
    return frames


def save(frames, path):
    # One palette for the whole film, built from every phase, so a colour
    # never shifts between frames.
    keys = [0, 22, 40, 60, len(frames) - 1]
    sample = Image.new("RGB", (W, H * len(keys)))
    for k, idx in enumerate(keys):
        sample.paste(frames[idx], (0, k * H))
    pal = sample.quantize(colors=255, method=Image.Quantize.MEDIANCUT,
                          dither=Image.Dither.NONE)
    conv = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames]
    conv[0].save(path, save_all=True, append_images=conv[1:],
                 duration=FPS_MS, loop=0, optimize=True, disposal=1)


def main():
    only = sys.argv[1:]
    for name, scene, trigger in FILMS:
        if only and name not in only:
            continue
        path = os.path.join(HERE, name)
        save(render(scene, trigger), path)
        print(f"{name}: {os.path.getsize(path) // 1024} KiB")


if __name__ == "__main__":
    main()
