#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Render Resources/Dish.icns from Resources/Dish.svg, the app mark the fleet
# shares (dish-linux resources/brand/dish-logo.svg). The SVG is the source;
# the .icns is a build product kept in the tree because SwiftPM has no step
# for it and bundle.sh copies it as is. Run after the mark changes.
#
# Requires rsvg-convert (Homebrew librsvg) and the system's iconutil.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="${ROOT}/Resources/Dish.svg"
ICNS="${ROOT}/Resources/Dish.icns"
ICONSET="$(mktemp -d)/Dish.iconset"
mkdir -p "${ICONSET}"
trap 'rm -rf "$(dirname "${ICONSET}")"' EXIT

command -v rsvg-convert >/dev/null || { echo "rsvg-convert is missing: brew install librsvg" >&2; exit 1; }

# Every slot iconutil accepts: the point size and its @2x, sharing a render
# where the pixel sizes coincide.
render() {
  rsvg-convert --width "$1" --height "$1" --keep-aspect-ratio "${SVG}" -o "${ICONSET}/$2"
}
render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "${ICONSET}" -o "${ICNS}"
echo "Rendered ${ICNS} from ${SVG}"
