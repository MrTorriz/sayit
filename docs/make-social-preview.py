#!/usr/bin/env python3
"""Builds docs/social-preview.png, the 1280x640 card GitHub shows when the
repository is linked elsewhere.

The wordmark is not redrawn: the card takes the outlines of
docs/logo-wordmark.svg (SAYIT and the tagline), which docs/build-logo.py
writes, and gives them the card's finish: a brushed-metal gradient on SAY,
a red glow on IT. Below it sits the overlay's pill with a voice wave. Only
the text beside it is set here.

The card is an HTML page rendered by a headless Chrome or Chromium. Set
CHROME to the browser's executable if it is not found on its own. The fonts
(Montserrat, Inter, JetBrains Mono) come from Google Fonts, so rendering
needs a network connection or the fonts installed locally.

GitHub has no API for this image. Upload the result by hand under
Settings -> General -> Social preview.

Usage:   python3 docs/make-social-preview.py          render social-preview.png
         python3 docs/make-social-preview.py --html   write the page only
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 1280, 640
RED = "#ff4d4d"
CHROMES = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
)


def wordmark_paths():
    """The wordmark's outlines as (class, d) pairs: m is SAY, t is IT."""
    with open(os.path.join(HERE, "logo-wordmark.svg"), encoding="utf-8") as f:
        svg = f.read()
    paths = re.findall(r'<path class="([mt])" d="([^"]+)"/>', svg)
    if not paths:
        raise SystemExit("logo-wordmark.svg has no class=m/t paths; update this script")
    return paths


def wave():
    """The voice wave: rounded bars, tallest in the middle."""
    heights = (10, 18, 30, 22, 40, 56, 34, 62, 46, 28, 50, 36, 20, 30, 14, 8)
    gap = 13
    bars = "".join(f'<line x1="{i * gap}" y1="{-h / 2:.1f}" x2="{i * gap}" y2="{h / 2:.1f}"/>'
                   for i, h in enumerate(heights))
    return bars, (len(heights) - 1) * gap


def page():
    word = "\n".join(
        f'<path d="{d}" fill="url(#metal)"/>' if c == "m"
        else f'<path d="{d}" fill="{RED}" filter="url(#redglow)"/>'
        for c, d in wordmark_paths())
    bars, wave_w = wave()
    # The author's MK mark, small in the bottom right corner.
    mark = ('<g clip-path="url(#cap)" fill="none" stroke="url(#mkstroke)" '
            'stroke-linecap="butt" stroke-linejoin="miter">'
            '<path d="M0 112V-12M104 112V-12" stroke-width="9.6"/>'
            '<path d="M0 0L52 56L104 0" stroke-width="8.2"/>'
            '<path d="M166.40 -11.20L104 56M125.84 32.48L177.07 110.80" '
            'stroke-width="8.2" mask="url(#gap)"/></g>')
    return f'''<!doctype html><html><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@500;600&family=Inter:wght@400&family=JetBrains+Mono:wght@400&display=swap" rel="stylesheet">
<style>
html,body{{margin:0;width:{W}px;height:{H}px;overflow:hidden;background:#070708}}
.card{{position:relative;width:{W}px;height:{H}px;
  background:radial-gradient(ellipse 70% 80% at 30% 45%,#1a1a1e 0%,#0e0e10 55%,#060607 100%)}}
.right{{position:absolute;left:690px;top:172px;width:560px;font-family:Inter,sans-serif}}
h1{{margin:0;font:600 50px/1.12 Montserrat,sans-serif;letter-spacing:-.5px;
  background:linear-gradient(160deg,#fff 0%,#e9eaee 45%,#a9acb3 100%);
  -webkit-background-clip:text;color:transparent;filter:drop-shadow(0 0 14px rgba(255,255,255,.10))}}
p{{margin:22px 0 0;font-size:23px;line-height:1.5;color:#9a9da5}}
.chips{{display:flex;gap:12px;margin-top:30px}}
.chip{{font:500 19px Montserrat,sans-serif;color:#d6d8dd;padding:9px 18px;border-radius:999px;
  border:1px solid rgba(255,255,255,.14);background:rgba(255,255,255,.03)}}
.tech{{margin-top:26px;font:400 16px 'JetBrains Mono',monospace;color:#6f727a;white-space:nowrap}}
.tech b{{color:{RED};font-weight:400}}
</style></head><body><div class="card">
<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" style="position:absolute;inset:0">
<defs>
  <linearGradient id="metal" gradientUnits="userSpaceOnUse" x1="50" y1="334" x2="506" y2="520">
    <stop offset="0" stop-color="#d9dbe0"/><stop offset=".3" stop-color="#fff"/>
    <stop offset=".48" stop-color="#b4b7bd"/><stop offset=".6" stop-color="#f4f5f7"/><stop offset="1" stop-color="#8a8d93"/>
  </linearGradient>
  <linearGradient id="wave" gradientUnits="userSpaceOnUse" x1="0" y1="-32" x2="0" y2="32">
    <stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#9c9ea4"/>
  </linearGradient>
  <linearGradient id="mkstroke" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="170" y2="100">
    <stop offset="0" stop-color="#d9dbe0"/><stop offset=".3" stop-color="#fff"/>
    <stop offset=".6" stop-color="#c9cbd0"/><stop offset="1" stop-color="#7f8288"/>
  </linearGradient>
  <linearGradient id="divider" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".5" stop-color="#fff" stop-opacity=".16"/>
    <stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </linearGradient>
  <clipPath id="cap"><rect x="-20" y="0" width="220" height="100"/></clipPath>
  <mask id="gap" maskUnits="userSpaceOnUse" x="-20" y="-20" width="230" height="140">
    <rect x="-20" y="-20" width="230" height="140" fill="#fff"/><rect x="108.8" y="-20" width="5.1" height="140" fill="#000"/>
  </mask>
  <filter id="glow" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="3" result="b1"/>
    <feGaussianBlur in="SourceAlpha" stdDeviation="12" result="b2"/>
    <feGaussianBlur in="SourceAlpha" stdDeviation="30" result="b3"/>
    <feFlood flood-color="#fff" flood-opacity=".30" result="c1"/>
    <feFlood flood-color="#8dbbd5" flood-opacity=".16" result="c2"/>
    <feFlood flood-color="#8dbbd5" flood-opacity=".10" result="c3"/>
    <feComposite in="c1" in2="b1" operator="in" result="g1"/>
    <feComposite in="c2" in2="b2" operator="in" result="g2"/>
    <feComposite in="c3" in2="b3" operator="in" result="g3"/>
    <feMerge><feMergeNode in="g3"/><feMergeNode in="g2"/><feMergeNode in="g1"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="redglow" x="-40%" y="-40%" width="180%" height="180%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="10" result="b"/>
    <feFlood flood-color="{RED}" flood-opacity=".35"/><feComposite in2="b" operator="in" result="g"/>
    <feMerge><feMergeNode in="g"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
</defs>
<g transform="translate(322 272) translate(-278 -427)" filter="url(#glow)">
{word}
</g>
<g transform="translate(322 430)">
  <rect x="-150" y="-36" width="300" height="72" rx="36" fill="#0b0b0d" stroke="#fff" stroke-opacity=".12"/>
  <circle cx="-112" cy="0" r="7" fill="{RED}" filter="url(#redglow)"/>
  <g transform="translate({-wave_w / 2 + 14} 0)" stroke="url(#wave)" stroke-width="5" stroke-linecap="round" filter="url(#glow)">{bars}</g>
</g>
<line x1="620" y1="130" x2="620" y2="510" stroke="url(#divider)" stroke-width="1.5"/>
<g transform="translate(1166 574) scale(.22)" opacity=".75">{mark}</g>
</svg>
<div class="right">
  <h1>Local push-to-talk<br>dictation</h1>
  <p>Hold a button, speak, release.<br>Your words land in the focused window.</p>
  <div class="chips"><span class="chip">macOS</span><span class="chip">Linux</span><span class="chip">Windows 11</span></div>
  <div class="tech">whisper.cpp <b>·</b> KB-Whisper <b>·</b> Metal / Vulkan <b>·</b> offline</div>
</div>
</div></body></html>
'''


def chrome():
    for c in ([os.environ["CHROME"]] if os.environ.get("CHROME") else []) + list(CHROMES):
        path = c if os.path.isabs(c) else shutil.which(c)
        if path and os.path.exists(path):
            return path
    raise SystemExit("no Chrome or Chromium found; set CHROME to its executable")


def main():
    html = os.path.join(HERE, "social-preview.html")
    with open(html, "w", encoding="utf-8") as f:
        f.write(page())
    if "--html" in sys.argv[1:]:
        print(html)
        return
    out = os.path.join(HERE, "social-preview.png")
    try:
        with tempfile.TemporaryDirectory() as profile:
            subprocess.run([chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars",
                            f"--user-data-dir={profile}", "--virtual-time-budget=5000",
                            f"--window-size={W},{H}", f"--screenshot={out}", f"file://{html}"],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        os.remove(html)
    print(out)


if __name__ == "__main__":
    main()
