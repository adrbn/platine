"""Writes CREDITS.md and the city list in both READMEs from Resources/Cities/*.json.

    python3 render/credits.py
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CITIES = sorted((json.loads(p.read_text()) for p in (ROOT / "Sources/Platine/Resources/Cities").glob("*.json")),
                key=lambda c: c["name"])


def license_name(c):
    if c["license"] in ("cc0", "pdm"):
        return "CC0" if c["license"] == "cc0" else "Public domain"
    return f'CC {c["license"].upper()} {c.get("license_version") or ""}'.strip()


rows = ["# Credits", "", "## City photographs", "",
        "Every photograph is freely licensed, found through [Openverse](https://openverse.org).", "",
        "| City | | Photograph | Author | License |", "|---|---|---|---|---|"]
for city in CITIES:
    for kind in ("day", "night"):
        if c := city.get(kind):
            title = (c.get("title") or "Untitled").replace("|", "/")
            rows.append(f'| {city["name"]} | {kind} | [{title}]({c.get("source") or ""}) | '
                        f'{c.get("creator") or "unknown"} | {license_name(c)} |')
rows += ["", "## Room", "", "Plant (`potted_plant_02`) and books (`decorative_book_set_01`): "
         "[Poly Haven](https://polyhaven.com), CC0.", ""]
(ROOT / "CREDITS.md").write_text("\n".join(rows))

names = " · ".join(c["name"] for c in CITIES)
for readme in ("README.md", "README.fr.md"):
    p = ROOT / readme
    if p.exists():
        p.write_text(re.sub(r"<!-- CITIES -->.*?<!-- /CITIES -->", f"<!-- CITIES -->\n{names}\n<!-- /CITIES -->",
                            p.read_text(), flags=re.S))
print(len(CITIES), "cities")
