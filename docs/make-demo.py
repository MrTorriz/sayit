#!/usr/bin/env python3
"""Builds docs/demo.gif — a depiction of the real hold-to-talk flow.

Every visual is taken from the code that actually draws it. The pill geometry
is not copied here but read out of bin/sayit-overlay itself, so the two cannot
drift apart: an earlier version of this file duplicated the numbers and kept
drawing three bars and a wordmark long after the overlay had four and none.
Only the drawing is written twice, because the overlay draws through cairo and
this draws through PIL. The terminal colours are the Konsole profile this
machine runs.

The text appears all at once rather than being typed, because that is what
sayit does: injection goes through the clipboard and a paste, not synthetic
per-character typing.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

BG   = (16, 16, 19)
FG   = (252, 252, 252)
RED  = (237, 37, 78)
BLU  = (0, 114, 255)
DOT  = (255, 77, 77)

# The terminal font, then the usual fallbacks. Rendering with a different
# monospace face still produces a correct picture — only the metrics shift, so
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
LH     = 24

CMD  = 'git commit -m "'
SAID = 'fix: hantera tomma inspelningar utan att krascha'
FULL = CMD + SAID + '"'

# --- pill geometry, read out of bin/sayit-overlay ---------------------------
# The overlay only touches GTK inside main(), so executing it defines the
# constants and nothing else. Reading them beats restating them: every number
# below therefore describes what the overlay actually draws today.
_OV = {}
_OVERLAY = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        os.pardir, "bin", "sayit-overlay")
with open(_OVERLAY, encoding="utf-8") as _f:
    exec(compile(_f.read(), _OVERLAY, "exec"), _OV)      # noqa: S102

PW, PH, PR = _OV["WIDTH"], _OV["HEIGHT"], _OV["RADIUS"]
BORDER     = _OV["BORDER"]
BARS       = _OV["BARS"]
BASELINE   = _OV["BASELINE"]
MARK_TOP   = _OV["MARK_TOP"]
DOT_D      = _OV["DOT_D"]
DOT_X      = _OV["DOT_X"]
SCALE      = _OV["MARK_SCALE"]
OFF_X      = _OV["OFFSET_X"]
OFF_Y      = _OV["OFFSET_Y"]


def pill(level, frame):
    """One frame of the overlay at `level` (0..7). 3x supersampled."""
    S = 3
    im = Image.new("RGBA", (PW * S, PH * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([S, S, PW * S - S, PH * S - S], radius=PR * S,
                        fill=(0, 0, 0, 255), outline=(255, 255, 255, 255),
                        width=int(BORDER * S))
    for bx, bw, low, high in BARS:
        h = low + (high - low) * level / 7.0
        h = max(h, bw)                   # same clamp the overlay applies
        x0 = (OFF_X + bx * SCALE) * S
        y0 = (OFF_Y + (BASELINE - h) * SCALE) * S
        w  = bw * SCALE * S
        d.rounded_rectangle([x0, y0, x0 + w, y0 + h * SCALE * S],
                            radius=w / 2, fill=(255, 255, 255, 255))
    alpha = 255
    if level < 0.5:                      # open but silent -> pulsing
        alpha = int(255 * (0.45 + 0.55 * (0.5 + 0.5 * math.sin(frame / 2.2))))
    r  = DOT_D / 2 * SCALE * S
    cx = (OFF_X + (DOT_X + DOT_D / 2) * SCALE) * S
    cy = (OFF_Y + (MARK_TOP + BASELINE) / 2 * SCALE) * S
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=DOT + (alpha,))
    return im.resize((PW, PH), Image.LANCZOS)


def frame(text, cursor, level, n, show_pill):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    x = PX
    d.text((x, PY), "sayit ", font=F, fill=RED); x += d.textlength("sayit ", font=F)
    d.text((x, PY), "❯ ",    font=F, fill=BLU); x += d.textlength("❯ ", font=F)
    d.text((x, PY), text,    font=F, fill=FG);  x += d.textlength(text, font=F)
    if cursor:
        d.rectangle([x + 1, PY + 1, x + 9, PY + 18], fill=FG)
    if show_pill:
        p = pill(level, n)
        img.paste(p, ((W - PW) // 2, 62), p)
        cap = "hold the thumb button — release to transcribe"
        cw = d.textlength(cap, font=FS)
        d.text(((W - cw) / 2, 118), cap, font=FS, fill=(138, 140, 148))
    return img


frames, durs = [], []
def add(im, ms):
    frames.append(im); durs.append(ms)

# 1. idle prompt, cursor blinking
for i in range(8):
    add(frame(CMD, i % 4 < 2, 0, i, False), 90)
# 2. button held, mic open, still silent -> dot pulses, bars at rest
for i in range(7):
    add(frame(CMD, True, 0, i, True), 90)
# 3. speaking -> bars follow the voice, dot steady
env = [1.6, 3.4, 5.1, 6.2, 5.4, 3.9, 4.8, 6.6, 6.9, 5.7,
       4.1, 5.5, 6.8, 6.1, 4.4, 2.8, 4.6, 6.3, 5.2, 3.1]
for i, lv in enumerate(env):
    add(frame(CMD, True, lv, i, True), 90)
# 4. released
for i in range(2):
    add(frame(CMD, True, 0.6, i, False), 90)
# 5. the text lands in one paste, not typed
for i in range(26):
    add(frame(FULL, i % 4 < 2, 0, i, False), 100)

# One palette for the whole animation: a per-frame adaptive palette snaps the
# caption's grey to the nearest red on frames where grey is rare.
montage = Image.new("RGB", (W, H * len(frames)))
for i, f in enumerate(frames):
    montage.paste(f, (0, i * H))
pal = montage.convert("P", palette=Image.ADAPTIVE, colors=128)
conv = [f.quantize(palette=pal, dither=Image.NONE) for f in frames]
conv[0].save("docs/demo.gif", save_all=True, append_images=conv[1:],
             duration=durs, loop=0, optimize=False, disposal=1)
print("frames:", len(frames))
