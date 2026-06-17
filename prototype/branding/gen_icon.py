#!/usr/bin/env python3
"""Render the Keyway app-icon master (1024x1024) — concept D (key + way)."""

# concept D mark, authored in a 100x100 box: ring bow + blade + chevron.
MARK = (
    '<path fill-rule="evenodd" d="M21 42 a13 13 0 1 0 26 0 a13 13 0 1 0 -26 0 Z '
    'M28 42 a6 6 0 1 1 12 0 a6 6 0 1 1 -12 0 Z"/>'
    '<path d="M46 39 H68 V33 L85 42 L68 51 V45 H46 Z"/>'
)

CANVAS = 1024
M = 102                       # tile margin (Apple-ish content inset)
TILE = CANVAS - 2 * M         # 820
RX = 180

# scale + center the mark's bbox (x[21,85], y[29,55]) on the canvas
S = 7.4
bx, by = 53.0, 42.0           # mark bbox center
tx = CANVAS / 2 - bx * S
ty = CANVAS / 2 - by * S

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#4C86FF"/>
      <stop offset="1" stop-color="#0E48C8"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.18"/>
      <stop offset="0.5" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect x="{M}" y="{M}" width="{TILE}" height="{TILE}" rx="{RX}" fill="url(#bg)"/>
  <rect x="{M}" y="{M}" width="{TILE}" height="{TILE/2}" rx="{RX}" fill="url(#sheen)"/>
  <g transform="translate({tx:.2f} {ty:.2f}) scale({S})" fill="#ffffff">{MARK}</g>
</svg>'''

with open("icon_master.svg", "w") as f:
    f.write(svg)
print("wrote icon_master.svg")
