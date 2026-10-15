"""Regenerates the README buttons in assets/ (EN and FR).

    python3 assets/make_svgs.py

Warm walnut-to-amber pools, like the room's lamp at night. Only SMIL, so they move inside GitHub's <img>
sandbox (no scripts, no webfonts). The pictures (hero.webp, card-*.webp) are the app's own offscreen
snapshots, see make_pictures.sh.
"""
from pathlib import Path

OUT = Path(__file__).parent
FONT = "-apple-system,BlinkMacSystemFont,'SF Pro Display','Helvetica Neue',Arial,sans-serif"
COLS = ["#5a2e12", "#b8661f", "#e0a24a", "#f3d39a", "#b8661f", "#5a2e12"]

_LOW = "abcdefghijklmnopqrstuvwxyz"
BOLD = dict(zip(_LOW, [556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389,
                       556, 333, 611, 556, 778, 556, 556, 500]))
BOLD.update(zip(_LOW.upper(), [722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778,
                                722, 667, 611, 722, 667, 944, 667, 667, 611]))
BOLD.update({" ": 278, "'": 238, "é": 556, "ç": 556, "à": 556})


def button(name, label):
    tw = sum(BOLD.get(c, 600) for c in label) / 1000 * 14.5
    w, h = round(tw + 44), 40
    stops = "".join(f'<stop offset="{i / (len(COLS) - 1):.2f}" stop-color="{c}"/>' for i, c in enumerate(COLS))
    defs = (f'<linearGradient id="g" x1="0" y1="0" x2="1" y2="0">{stops}'
            f'<animateTransform attributeName="gradientTransform" type="translate" values="-.25 0;.25 0;-.25 0" '
            f'dur="9s" repeatCount="indefinite"/></linearGradient>'
            f'<linearGradient id="l" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".3"/>'
            f'<stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>')
    rx = h / 2 - .5
    rect = f'<rect x=".5" y=".5" width="{w - 1}" height="{h - 1}" rx="{rx}"'
    t = (f'font-family="{FONT}" font-size="14.5" font-weight="600" textLength="{tw:.0f}" '
         f'lengthAdjust="spacing"')
    label = label.replace("&", "&amp;")
    body = (f'{rect} fill="url(#g)"/>{rect} fill="#000" fill-opacity=".28"/>'
            f'{rect} fill="url(#l)" stroke="#fff" stroke-opacity=".35"/>'
            f'<text x="22" y="26" {t} fill="#000" fill-opacity=".25">{label}</text>'
            f'<text x="22" y="25" {t} fill="#fff">{label}</text>')
    (OUT / f"btn-{name}.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img">'
        f'<title>{label}</title><defs>{defs}</defs>{body}</svg>\n')


for name, en, fr in [("download", "Download", "Télécharger"), ("cities", "Cities", "Villes"),
                     ("build", "Build from source", "Compiler"), ("how", "How it works", "Comment ça marche")]:
    button(name, en)
    button(f"{name}-fr", fr)
