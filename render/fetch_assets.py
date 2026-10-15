"""Download the CC0 Poly Haven models the room uses (1k textures) into render/assets/."""
import json
import os
import subprocess
import sys

ASSETS = ["potted_plant_02", "decorative_book_set_01"]
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")


def fetch(url, path):
    if os.path.exists(path):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    print("↓", os.path.relpath(path, ROOT), flush=True)
    subprocess.run(["curl", "-fsSL", "-o", path + ".part", url], check=True)
    os.replace(path + ".part", path)


for asset in ASSETS:
    listing = subprocess.run(["curl", "-fsSL", f"https://api.polyhaven.com/files/{asset}"], check=True, capture_output=True)
    blend = json.loads(listing.stdout)["blend"]["1k"]["blend"]
    base = os.path.join(ROOT, asset)
    fetch(blend["url"], os.path.join(base, os.path.basename(blend["url"])))
    for rel, inc in blend.get("include", {}).items():
        if ".." in rel.split("/"):
            sys.exit(f"refusing path {rel}")
        fetch(inc["url"], os.path.join(base, rel))
print("ok")
