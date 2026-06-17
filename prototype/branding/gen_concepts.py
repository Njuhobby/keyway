#!/usr/bin/env python3
"""Generate a contact sheet of Keyway logo concepts.

Each concept is drawn once as a monochrome glyph in a 100x100 box, then shown
three ways: a colored app-icon tile, on a dark menu bar, and on a light menu
bar. Marks inherit `fill`/`stroke` from the placing <use>, so one definition
serves all three renderings.
"""

# --- the four candidate marks, each authored in a 100x100 coordinate box ----
MARKS = {
    # A — keyhole: circle bow + tapered slot. Classic "access / key".
    "A": (
        "Keyhole", "access · classic",
        '<circle cx="50" cy="40" r="15"/>'
        '<path d="M44 52 L56 52 L59 78 L41 78 Z"/>'
    ),
    # B — keycap outline + geometric K. Keyboard identity.
    "B": (
        "Keycap K", "keyboard-native",
        '<rect x="20" y="20" width="60" height="60" rx="13" fill="none" stroke-width="7"/>'
        '<path d="M34 32 L42 32 L42 46 L56 32 L66 32 L50 50 '
        'L66 68 L56 68 L42 54 L42 68 L34 68 Z"/>'
    ),
    # C — key-blade / keyway profile: vertical bar with ward notches (evenodd).
    "C": (
        "Keyway profile", "literal · abstract",
        '<path fill-rule="evenodd" d="M42 24 H58 V76 H42 Z '
        'M58 40 H49 V48 H58 Z M58 54 H49 V62 H58 Z"/>'
    ),
    # D — key + way: ring bow + blade ending in a directional chevron.
    "D": (
        "Key + way", "name pun · dynamic",
        '<path fill-rule="evenodd" d="M21 42 a13 13 0 1 0 26 0 a13 13 0 1 0 -26 0 Z '
        'M28 42 a6 6 0 1 1 12 0 a6 6 0 1 1 -12 0 Z"/>'
        '<path d="M46 39 H68 V33 L85 42 L68 51 V45 H46 Z"/>'
    ),
}

ROW_H = 232
TOP = 96
W = 940
H = TOP + ROW_H * len(MARKS) + 24

# column geometry
TILE = 150
TILE_X = 196
STRIP_W, STRIP_H = 196, 46
DARK_X = 432
LIGHT_X = 676


def placed(mark_id, cx, cy, scale, fill, stroke=None):
    s = f'stroke="{stroke}" ' if stroke else ""
    t = scale / 100.0
    off = -50 * t
    return (f'<g transform="translate({cx + off:.1f} {cy + off:.1f}) scale({t:.4f})" '
            f'fill="{fill}" {s}>{MARKS[mark_id][2]}</g>')


parts = [
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
    f'viewBox="0 0 {W} {H}" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">',
    f'<rect width="{W}" height="{H}" fill="#f4f5f7"/>',
    '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="#3D7BFF"/>'
    '<stop offset="1" stop-color="#0E48C8"/></linearGradient></defs>',
    # header
    f'<text x="40" y="50" font-size="30" font-weight="700" fill="#111">Keyway — logo concepts</text>',
    f'<text x="{TILE_X + TILE/2}" y="84" font-size="15" fill="#666" text-anchor="middle">App icon</text>',
    f'<text x="{DARK_X + STRIP_W/2}" y="84" font-size="15" fill="#666" text-anchor="middle">Menu bar (dark)</text>',
    f'<text x="{LIGHT_X + STRIP_W/2}" y="84" font-size="15" fill="#666" text-anchor="middle">Menu bar (light)</text>',
]

for i, (mid, (name, tag, _)) in enumerate(MARKS.items()):
    y0 = TOP + i * ROW_H
    cy = y0 + ROW_H / 2
    # row label
    parts.append(f'<text x="40" y="{cy - 6:.0f}" font-size="20" font-weight="700" fill="#111">{mid}. {name}</text>')
    parts.append(f'<text x="40" y="{cy + 16:.0f}" font-size="13" fill="#888">{tag}</text>')
    # app-icon tile (rounded square, gradient, white mark)
    parts.append(f'<rect x="{TILE_X}" y="{cy - TILE/2:.0f}" width="{TILE}" height="{TILE}" rx="34" fill="url(#bg)"/>')
    parts.append(placed(mid, TILE_X + TILE/2, cy, TILE * 0.66, "#ffffff", "#ffffff"))
    # dark menu-bar strip
    parts.append(f'<rect x="{DARK_X}" y="{cy - STRIP_H/2:.0f}" width="{STRIP_W}" height="{STRIP_H}" rx="9" fill="#2b2b2e"/>')
    parts.append(placed(mid, DARK_X + STRIP_W/2, cy, 34, "#ffffff", "#ffffff"))
    # light menu-bar strip
    parts.append(f'<rect x="{LIGHT_X}" y="{cy - STRIP_H/2:.0f}" width="{STRIP_W}" height="{STRIP_H}" rx="9" fill="#e9e9ec"/>')
    parts.append(placed(mid, LIGHT_X + STRIP_W/2, cy, 34, "#1a1a1a", "#1a1a1a"))

parts.append('</svg>')

with open("concepts.svg", "w") as f:
    f.write("\n".join(parts))
print("wrote concepts.svg")
