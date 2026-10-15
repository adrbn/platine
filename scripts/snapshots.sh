#!/bin/sh
# Renders every framing at four times of day into docs/snapshots (offscreen).
#   ./scripts/snapshots.sh build/Build/Products/Release/Platine.app [city]
set -e
app="$1/Contents/MacOS/Platine"; city="${2:-sao-paulo}"; out=docs/snapshots
mkdir -p "$out"
for framing in wide medium close above; do
  for hour in 8 12.5 17.6 22; do
    "$app" --snapshot "$out/$framing-$hour.png" --framing "$framing" --hour "$hour" --city "$city" --size 1440x900
  done
done
echo "$out"
