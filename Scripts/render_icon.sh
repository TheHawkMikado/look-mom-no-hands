#!/usr/bin/env bash
# Rasterises the brand assets from their SVG masters.
#
#   Assets/icon.svg  ->  Assets/AppIcon.icns          (bundled by assemble_app)
#                        Assets/png/icon-{16..1024}.png
#   Assets/menubar-template.svg -> Assets/png/menubar-template{,@2x}.png
#   Assets/lockup.svg           -> Assets/png/lockup{,@2x}.png
#
# Only needs the macOS toolchain: WebKit does the SVG (Scripts/svg2png.swift),
# sips resamples, iconutil packs the .icns. Re-run whenever an SVG changes and
# commit the results, so a plain `build_app.sh` never has to rasterise anything.
set -euo pipefail

cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "▸ compiling svg2png"
swiftc -O -o "${WORK}/svg2png" Scripts/svg2png.swift

mkdir -p Assets/png

# The 1024 render comes back at 2x backing scale, i.e. a 2048px master that
# every smaller size is resampled down from.
echo "▸ rendering icon master"
"${WORK}/svg2png" Assets/icon.svg "${WORK}/master.png" 1024 1024

ICONSET="${WORK}/AppIcon.iconset"
mkdir -p "${ICONSET}"

# name=size pairs for the .iconset layout Apple requires.
for entry in \
    icon_16x16.png=16       icon_16x16@2x.png=32 \
    icon_32x32.png=32       icon_32x32@2x.png=64 \
    icon_128x128.png=128    icon_128x128@2x.png=256 \
    icon_256x256.png=256    icon_256x256@2x.png=512 \
    icon_512x512.png=512    icon_512x512@2x.png=1024
do
    name="${entry%%=*}"; size="${entry##*=}"
    sips -z "${size}" "${size}" "${WORK}/master.png" --out "${ICONSET}/${name}" >/dev/null
done

echo "▸ packing Assets/AppIcon.icns"
iconutil --convert icns "${ICONSET}" --output Assets/AppIcon.icns

echo "▸ exporting PNGs"
for size in 16 32 64 128 256 512 1024; do
    sips -z "${size}" "${size}" "${WORK}/master.png" \
        --out "Assets/png/icon-${size}.png" >/dev/null
done

# Menu-bar template: rendered at its true pixel sizes rather than resampled,
# so the 1x version stays crisp on a non-Retina display.
"${WORK}/svg2png" Assets/menubar-template.svg Assets/png/menubar-template.png 28 18
"${WORK}/svg2png" Assets/menubar-template.svg Assets/png/menubar-template@2x.png 56 36

# Two lockups, because a currentColor SVG has to be baked to a fixed ink once
# it becomes a PNG: black for light backgrounds, white for dark ones.
sed 's/currentColor/#111111/g' Assets/lockup.svg > "${WORK}/lockup-light.svg"
sed 's/currentColor/#FFFFFF/g' Assets/lockup.svg > "${WORK}/lockup-dark.svg"
for variant in light dark; do
    "${WORK}/svg2png" "${WORK}/lockup-${variant}.svg" \
        "Assets/png/lockup-${variant}.png"    743 170
    "${WORK}/svg2png" "${WORK}/lockup-${variant}.svg" \
        "Assets/png/lockup-${variant}@2x.png" 1485 340
done

echo "✓ assets written to Assets/"
