<div align="center">

# Platine

**A record player on your desktop that plays what you play.**<br>
A live macOS wallpaper that follows Spotify and Music. Free and open source.

<br>

<p><img src="assets/hero.webp" width="720" alt="A desk by a window over the city. A turntable plays the album you are listening to, its sleeve on a stand, while the light moves from afternoon to night"></p>

<br>

<a href="https://github.com/adrbn/platine/releases/latest"><img src="assets/btn-download.svg" alt="Download" height="40"></a>&nbsp;
<a href="#cities"><img src="assets/btn-cities.svg" alt="Cities" height="40"></a>&nbsp;
<a href="#build--run"><img src="assets/btn-build.svg" alt="Build from source" height="40"></a>&nbsp;
<a href="#how-it-works"><img src="assets/btn-how.svg" alt="How it works" height="40"></a>

<br>

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-E0A24A?style=flat-square&labelColor=15100B&logo=apple&logoColor=white)](#requirements)
[![Spotify and Music](https://img.shields.io/badge/follows-Spotify%20%C2%B7%20Music-E0A24A?style=flat-square&labelColor=15100B)](#features)
[![Rendered in Cycles](https://img.shields.io/badge/light-Blender%20Cycles-E0A24A?style=flat-square&labelColor=15100B&logo=blender&logoColor=white)](#how-it-works)
[![No account](https://img.shields.io/badge/account-none-E0A24A?style=flat-square&labelColor=15100B)](#privacy)
[![Latest release](https://img.shields.io/github/v/release/adrbn/platine?style=flat-square&labelColor=15100B&color=E0A24A&label=release)](https://github.com/adrbn/platine/releases/latest)
[![License MIT](https://img.shields.io/badge/license-MIT-E0A24A?style=flat-square&labelColor=15100B)](LICENSE)

English · [Français](README.fr.md)

</div>

---

**Platine** puts a room behind your windows: a desk by a window over a city, a 1970s
turntable, a coffee, a pile of records, a lamp for the evening. Press play in Spotify or
Music and the album lands on the platter, its cover on the sleeve, the arm drops into the
groove of the song that is playing. Skip a track and the needle moves. Pause and the arm
lifts.

The light follows your clock, from dawn to night, and if it rains in your city it rains
on the window. The room is rendered once in Blender Cycles and lit for real; only the
parts that move are drawn live, so it costs almost nothing to run.

## Features

<table>
  <tr>
    <td align="center" valign="top" width="33%"><img src="assets/card-record.webp" alt="Close on the platter: the album's label and its sleeve on the stand" width="100%"><br><b>Your album, cut for real</b><br><sub>The grooves follow the real track list, each song as wide as it is long. The arm sits on the song you are playing, and flips to side B when it should.</sub></td>
    <td align="center" valign="top" width="33%"><img src="assets/card-day.webp" alt="The same desk at noon, at sunset and at night" width="100%"><br><b>Your sun</b><br><sub>Seven keyframes rendered in Cycles, blended continuously and timed to the real sunrise and sunset where you are. The lamp comes on in the evening.</sub></td>
    <td align="center" valign="top" width="33%"><img src="assets/card-city.webp" alt="The window at night, a city skyline behind the glass" width="100%"><br><b>A city behind the glass</b><br><sub>Real photographs of 44 cities and 12 landscapes, day and night, all freely licensed. Or type any place and Platine finds one.</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><img src="assets/card-rain.webp" alt="Rain running down the window" width="100%"><br><b>Your weather</b><br><sub>If it rains in your city, it rains on the window: drizzle, rain or heavy rain, from Open-Meteo. Or pick one and keep it.</sub></td>
    <td align="center" valign="top"><img src="assets/card-framings.webp" alt="Wide, medium, close and from above" width="100%"><br><b>Four framings</b><br><sub>Wide, medium, close on the platter with a real depth of field, or straight from above.</sub></td>
    <td align="center" valign="top"><img src="assets/card-yours.webp" alt="The window over Lake Como" width="100%"><br><b>Or your own view</b><br><sub>Drop in any photo of yours, and set how soft it looks through the glass, from sharp to far out of focus.</sub></td>
  </tr>
</table>

## Cities

The window looks over one of these, picked from the menu bar under **Through the window**:

<!-- CITIES -->
Alps · Amsterdam · Autumn Forest · Bangalore · Bangkok · Barcelona · Beijing · Berlin · Bogotá · Buenos Aires · Cairo · Cape Town · Chicago · Delhi · Dhaka · Dubai · Fjord · Guangzhou · Highlands · Ho Chi Minh City · Hong Kong · Istanbul · Jakarta · Kyoto · Lagos · Lake Como · Lima · Lisbon · London · Los Angeles · Madrid · Manila · Mediterranean · Mexico City · Moscow · Mumbai · New York · Osaka · Paris · Prague · Rice Terraces · Rio de Janeiro · Rome · Sahara · San Francisco · Seoul · Shanghai · Singapore · Snow Village · Sydney · São Paulo · Tehran · Tokyo · Toronto · Tropical Beach · Tuscany
<!-- /CITIES -->

Not there? Type it anyway: Platine asks [Openverse](https://openverse.org) for a free
daytime and night photograph (CC0, public domain, CC BY or CC BY-SA), falls back to the
landscape around it when there is no skyline, and keeps it in
`~/Library/Application Support/Platine/Cities`. **Another photo** tries the next one.
Each photo's credit shows under the search field.

Or pick **Use your own photo…**: a wide picture works best, a view, a landscape, a skyline.

## Download

Get `Platine.dmg` from the [latest release](https://github.com/adrbn/platine/releases/latest),
drag it to Applications and open it. It lives in the menu bar, with no Dock icon.

The first time a player is running, macOS asks whether Platine may read what it plays:
say yes, it is the only thing it reads.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon or Intel
- Spotify or Music, if you want the record to follow along

## Build & run

```bash
brew install xcodegen
make run          # Debug build, opened
make test         # unit tests: LP layout, arm geometry, turntable motion, light schedule
make install      # Release build → /Applications, signed with your Developer ID if you have one
```

Builds are ad-hoc signed by default, so anyone can clone and build. With an Apple
Developer ID in the keychain, `make install` signs with it, and macOS keeps the
Automation permission across rebuilds.

To check the room without touching the desktop:

```bash
make snapshots    # every framing at four hours, into docs/snapshots
```

### Re-rendering the room

The plates in `Sources/Platine/Resources/Plates` come from `render/room.py`, with
[Blender](https://www.blender.org) 5:

```bash
python3 render/fetch_assets.py                     # the plant and the books, CC0 from Poly Haven
blender -b -P render/room.py -- --out render/out/final --size 2560x1600 --samples 64 --masks
swift render/to_heic.swift render/out/final Sources/Platine/Resources/Plates
```

About an hour and a half on an M1. `render/cities.py` is the tool that curated the city
library: `search "Lagos" night` lays out the candidates, `pick "Lagos" night 3` keeps one.

## How it works

```
Players     PlayerBridge   Spotify and Music notifications, read over AppleScript (never launched)
Record      LPLayout       the track list cut into two sides, at real groove pitch
            TonearmGeometry · TurntableMotion   arm and platter kinematics, pure and unit tested
Scene       Plates         Cycles plates per framing and hour, cross-faded, the city composited
                           behind the window with the lens's own blur
            RoomScene      SceneKit: the record, the arm, the sleeve, steam and rain, drawn live
            DayCycle · PlateSchedule   the light through the day
Wallpaper   DesktopController   a click-through window at desktop level, one per display
            OcclusionDetector   pauses when the desktop is covered, from window geometry only
```

The room is drawn once, offline, with path-traced light and real materials. The app
blends the two plates nearest your hour, places the city's photograph in the window
with the depth of field of that framing, then draws the moving parts over it in
SceneKit, lit by a light probe rendered at the record.

## Privacy

No account, no analytics. Platine reads what Spotify or Music is playing on your Mac,
and never launches or controls a player. It asks for your approximate location, once, to
time the sun; those coordinates only go to [Open-Meteo](https://open-meteo.com), for the
rain. An album's name goes to Apple's public catalog when the player gives no cover, or
for every album if you turn on **Look up track lists**. Searching for a place sends its
name to Openverse.

## Roadmap

- A short motion of the light at the window, as clouds pass
- More room styles
- A matching screensaver

## Contributing

Issues and pull requests are welcome. Keep the room honest: real geometry, real light,
freely licensed assets with their credit.

## Credits

- Plant and books: [Poly Haven](https://polyhaven.com), CC0
- City photographs: see [CREDITS.md](CREDITS.md), each with its author and license
- Weather: [Open-Meteo](https://open-meteo.com)

## License

[MIT](LICENSE). The city photographs keep their own licenses, listed in
[CREDITS.md](CREDITS.md).
