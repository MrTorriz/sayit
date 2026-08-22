"""Builds docs/demo.gif — a depiction of the real hold-to-talk flow.

Every visual is taken from the code that actually draws it: the pill is
bin/sayit-overlay's geometry (150x40, radius 20, black fill, white 1.5 px
border, three bars at the mark's offsets, a red dot that pulses while the mic
is open but silent and burns steady once it hears you), and the terminal
colours are the Konsole profile this machine runs.

The text appears all at once rather than being typed, because that is what
sayit does: injection goes through the clipboard and a paste, not synthetic
per-character typing.
"""
import math
from PIL import Image, ImageDraw, ImageFont

BG   = (16, 16, 19)
FG   = (252, 252, 252)
RED  = (237, 37, 78)
BLU  = (0, 114, 255)
DOT  = (255, 77, 77)

FONT = "/usr/share/fonts/cascadia-code-fonts/CascadiaCode-SemiBold.otf"
F  = ImageFont.truetype(FONT, 16)
FS = ImageFont.truetype(FONT, 12)

W, H   = 900, 150
PX, PY = 16, 18
LH     = 24

CMD  = 'git commit -m "'
SAID = 'fix: hantera tomma inspelningar utan att krascha'
FULL = CMD + SAID + '"'

# --- pill geometry, straight from bin/sayit-overlay -------------------------
PW, PH, PR = 150, 40, 20
BARS = [(-10.4, 5.8, 17.3), (-2.3, 8.1, 25.3), (5.8, 4.6, 13.8)]
MARK_CX, MARK_BASE = 30.0, PH / 2 + 12.6
DOT_R = 2.6


def pill(level, frame):
    """One frame of the overlay at `level` (0..7). 3x supersampled."""
    S = 3
    im = Image.new("RGBA", (PW * S, PH * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([S, S, PW * S - S, PH * S - S], radius=PR * S,
                        fill=(0, 0, 0, 255), outline=(255, 255, 255, 255),
                        width=int(1.5 * S))
    for dx, low, high in BARS:
        h = low + (high - low) * level / 7.0
        w = 3.9
        x0 = (MARK_CX + dx) * S
        d.rounded_rectangle([x0, (MARK_BASE - h) * S, x0 + w * S, MARK_BASE * S],
                            radius=w * S / 2, fill=(255, 255, 255, 255))
    alpha = 255
    if level < 0.5:                      # open but silent -> pulsing
        alpha = int(255 * (0.45 + 0.55 * (0.5 + 0.5 * math.sin(frame / 2.2))))
    cx, cy = (MARK_CX + 14.4) * S, (MARK_BASE - DOT_R - 0.3) * S
    d.ellipse([cx - DOT_R * S, cy - DOT_R * S, cx + DOT_R * S, cy + DOT_R * S],
              fill=DOT + (alpha,))
    d.text((58 * S, (PH * S - 15 * S) / 2), "sayit",
           font=ImageFont.truetype(FONT, 11 * S), fill=(255, 255, 255, 255))
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
