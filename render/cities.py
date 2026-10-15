"""Curate the city photos seen through the window, from Openverse (CC0 / public domain / CC BY / CC BY-SA).

    python3 render/cities.py search "Tokyo" day      # contact sheet of candidates -> render/out/cities/
    python3 render/cities.py pick "Tokyo" day 7      # keep candidate 7 in the app, with its credit

Picked photos go to Sources/Platine/Resources/Cities/<slug>-<kind>.jpg, credits to <slug>.json.
"""
import io
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.parse

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "render", "out", "cities")
DEST = os.path.join(ROOT, "Sources", "Platine", "Resources", "Cities")
LICENSES = "cc0,pdm,by,by-sa"          # no NC, no ND: the app is free software
QUERIES = {"day": "{} skyline", "night": "{} skyline night"}


def slug(city):
    ascii_name = unicodedata.normalize("NFKD", city).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", ascii_name.lower()).strip("-")


def get(url, tries=4):
    for attempt in range(tries):
        run = subprocess.run(["curl", "-sfL", "--max-time", "60", "-A", "platine-curation", url], capture_output=True)
        if run.returncode == 0:
            return run.stdout
        time.sleep(5 * (attempt + 1))      # Openverse throttles anonymous bursts
    raise RuntimeError(f"curl failed ({run.returncode}): {url}")


def candidates(city, kind):
    cache = os.path.join(OUT, f"{slug(city)}-{kind}.json")
    if os.path.exists(cache):
        return json.load(open(cache))
    q = urllib.parse.quote(os.environ.get("Q") or QUERIES[kind].format(city))   # Q=... overrides the query (landscapes)
    results = []
    for page in (1, 2):
        data = json.loads(get(f"https://api.openverse.org/v1/images/?q={q}&license={LICENSES}"
                              f"&page_size=20&page={page}"))
        results += data["results"]
        if page >= data.get("page_count", 1):
            break
    keep = [r for r in results
            if (r.get("width") or 0) >= 1000 and 1.3 <= (r["width"] / max(1, r.get("height") or 1)) <= 2.2]
    os.makedirs(OUT, exist_ok=True)
    json.dump(keep, open(cache, "w"))
    return keep


def thumb_url(r):
    url = r["url"]
    if "staticflickr.com" in url:
        return re.sub(r"(_[a-z])?\.jpg$", "_n.jpg", url)
    return r.get("thumbnail") or url


def search(city, kind):
    rs = candidates(city, kind)[:24]
    tw, th = 320, 213
    sheet = Image.new("RGB", (tw * 4, th * ((len(rs) + 3) // 4 or 1)), (30, 30, 30))
    for i, r in enumerate(rs):
        try:
            im = Image.open(io.BytesIO(get(thumb_url(r)))).convert("RGB")
        except Exception:
            continue
        im = im.resize((tw, th))
        d = ImageDraw.Draw(im)
        d.rectangle((0, 0, 34, 20), fill=(0, 0, 0))
        d.text((5, 4), str(i), fill=(255, 255, 0))
        sheet.paste(im, ((i % 4) * tw, (i // 4) * th))
    path = os.path.join(OUT, f"{slug(city)}-{kind}.png")
    sheet.save(path)
    print(path, len(rs), "candidates")


def pick(city, kind, index):
    r = candidates(city, kind)[index]
    im = Image.open(io.BytesIO(get(r["url"]))).convert("RGB")
    if im.width > 1600:
        im = im.resize((1600, round(im.height * 1600 / im.width)), Image.LANCZOS)
    os.makedirs(DEST, exist_ok=True)
    if os.path.exists(os.path.join(DEST, f"{slug(city)}-{kind}.jpg")):
        sys.exit("already present, not overwriting")
    im.save(os.path.join(DEST, f"{slug(city)}-{kind}.jpg"), quality=84, optimize=True)
    credits = os.path.join(DEST, f"{slug(city)}.json")
    entry = json.load(open(credits)) if os.path.exists(credits) else {"name": city}
    entry[kind] = {"title": r.get("title"), "creator": r.get("creator"), "license": r["license"],
                   "license_version": r.get("license_version"), "source": r.get("foreign_landing_url")}
    json.dump(entry, open(credits, "w"), indent=1, ensure_ascii=False, sort_keys=True)
    print("picked", city, kind, r["license"], r.get("creator"))


if __name__ == "__main__":
    cmd, city, kind = sys.argv[1:4]
    if kind not in QUERIES:
        sys.exit(f"kind must be one of {list(QUERIES)}")
    search(city, kind) if cmd == "search" else pick(city, kind, int(sys.argv[4]))
