#!/usr/bin/env python3
"""Builds docs/demo.gif -- a depiction of the real hold-to-talk flow.

The pill is not drawn twice. This script executes bin/sayit-overlay, which
defines its geometry and its drawing functions without touching GTK, and then
calls those same functions through cairo. The overlay draws the pill in the
animation exactly as it draws it on screen, so the two cannot drift apart. An
earlier version of this file restated the numbers and kept drawing four bars
and no wordmark long after the overlay had ten and one; the version before
that drew three bars and a wordmark the overlay did not have. Only the
terminal around the pill is PIL's, and the terminal colours are a Konsole
profile.

The text appears all at once rather than being typed, because that is what
sayit does: injection goes through the clipboard and a paste, not synthetic
per-character typing.
"""
import os
import sys

import cairo
from PIL import Image, ImageDraw, ImageFont

BG  = (16, 16, 19)
FG  = (252, 252, 252)
RED = (237, 37, 78)
BLU = (0, 114, 255)

# The terminal font, then the usual fallbacks. Rendering with a different
# monospace face still produces a correct picture -- only the metrics shift, so
# check that the longest line still fits before committing the result.
CANDIDATES = [
    "/usr/share/fonts/cascadia-code-fonts/CascadiaCode-SemiBold.otf",
    "/usr/share/fonts/cascadia-code/CascadiaCode.ttf",
    "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
]
FONT = next((c for c in CANDIDATES if os.path.exists(c)), None)
if FONT is None:
    sys.exit("no monospace font found; add one to CANDIDATES in this file")
F  = ImageFont.truetype(FONT, 16)
FS = ImageFont.truetype(FONT, 12)

W, H   = 900, 150
PX, PY = 16, 18

CMD  = 'git commit -m "'
SAID = 'fix: hantera tomma inspelningar utan att krascha'
FULL = CMD + SAID + '"'

# --- the overlay itself, as a module ----------------------------------------
# Executing it defines the constants and the drawing functions; GTK is only
# touched inside main(), which is never called here.
OV = {}
_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     os.pardir, "bin", "sayit-overlay")
with open(_PATH, encoding="utf-8") as _f:
    exec(compile(_f.read(), _PATH, "exec"), OV)          # noqa: S102

PW, PH = OV["WIDTH"], OV["HEIGHT"]
SS = 3                                   # supersampling factor


def pill(level, lit):
    """One frame of the overlay at `level` (0..7), drawn by the overlay."""
    surf = cairo.ImageSurface(cairo.FORMAT_RGB24, PW * SS, PH * SS)
    cr = cairo.Context(surf)
    cr.scale(SS, SS)

    # The pill is transparent outside its rounded corners. Painting the
    # terminal's own background behind it composites those corners here
    # instead of leaving PIL to guess at premultiplied alpha.
    cr.set_source_rgb(*[c / 255 for c in BG])
    cr.paint()

    border, radius = OV["BORDER"], OV["RADIUS"]
    OV["rounded_rect"](cr, border / 2, border / 2,
                       PW - border, PH - border, radius)
    cr.set_source_rgb(0, 0, 0)
    cr.fill_preserve()
    cr.set_source_rgb(1, 1, 1)
    cr.set_line_width(border)
    cr.stroke()

    cy = PH / 2.0
    x = OV["CONTENT_X"]
    OV["draw_lamp"](cr, x, cy, lit)
    x += OV["LAMP_W"] + OV["LAMP_GAP"]
    OV["draw_wave"](cr, x, cy, level)
    x += OV["WAVE_W"] + OV["LAYOUT_GAP"]
    OV["draw_wordmark"](cr, x, cy)

    surf.flush()
    im = Image.frombuffer("RGB", (PW * SS, PH * SS), bytes(surf.get_data()),
                          "raw", "BGRX", surf.get_stride(), 1)
    return im.resize((PW, PH), Image.LANCZOS)


def frame(text, cursor, level, lit, caption):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    x = PX
    d.text((x, PY), "sayit ", font=F, fill=RED); x += d.textlength("sayit ", font=F)
    d.text((x, PY), "❯ ",  font=F, fill=BLU); x += d.textlength("❯ ", font=F)
    d.text((x, PY), text,    font=F, fill=FG)
    if cursor:
        x += d.textlength(text, font=F)
        d.rectangle([x + 1, PY + 1, x + 9, PY + 18], fill=FG)
    img.paste(pill(level, lit), ((W - PW) // 2, 62))
    cw = d.textlength(caption, font=FS)
    d.text(((W - cw) / 2, 118), caption, font=FS, fill=(138, 140, 148))
    return img


frames, durs = [], []
def add(im, ms):
    frames.append(im); durs.append(ms)

REST  = "the pill stays on screen; the lamp is dark while the microphone is closed"
OPEN  = "hold the thumb button -- the lamp lights and the meter follows your voice"
PASTE = "release, and the transcription arrives in one paste"

# 1. Idle. The pill is already there: it is a resident window, not something
# that appears with the recording. A terminal cursor blinks around once a
# second, so at 90 ms a frame the sequence has to run one full 12-frame cycle
# or the blink reads as a glitch rather than as a cursor.
for i in range(13):
    add(frame(CMD, i % 12 < 6, 0, False, REST), 90)
# 2. Button held, microphone open, still silent. The lamp is the only thing
# that changed; the meter has not moved.
for _ in range(6):
    add(frame(CMD, True, 0, True, OPEN), 90)
# 3. Speaking. Now the meter moves and nothing else does.
env = [1.6, 3.4, 5.1, 6.2, 5.4, 3.9, 4.8, 6.6, 6.9, 5.7,
       4.1, 5.5, 6.8, 6.1, 4.4, 2.8, 4.6, 6.3, 5.2, 3.1]
for lv in env:
    add(frame(CMD, True, lv, True, OPEN), 90)
# 4. Released: the lamp goes out first, and the meter settles.
for lv in (2.0, 0.7, 0.0):
    add(frame(CMD, True, lv, False, PASTE), 90)
# 5. The text lands in one paste, not typed.
for i in range(26):
    add(frame(FULL, i % 10 < 5, 0, False, PASTE), 100)

# One palette for the whole animation: a per-frame adaptive palette snaps the
# caption's grey to the nearest red on frames where grey is rare.
montage = Image.new("RGB", (W, H * len(frames)))
for i, f in enumerate(frames):
    montage.paste(f, (0, i * H))
pal = montage.convert("P", palette=Image.ADAPTIVE, colors=128)
conv = [f.quantize(palette=pal, dither=Image.NONE) for f in frames]
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo.gif")
conv[0].save(out, save_all=True, append_images=conv[1:],
             duration=durs, loop=0, optimize=False, disposal=1)
print("frames:", len(frames))
