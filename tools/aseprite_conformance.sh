#!/usr/bin/env bash
# Makes the Aseprite conformance cases again (testdata/aseprite/conformance): Aseprite writes each
# .aseprite file (make.lua), then exports every frame as PNG and its frames and tags as JSON. The
# engine's aseprite_matches_aseprite test compares its own reading of each file with them.
# Needs Aseprite (ASEPRITE, else `aseprite` in PATH).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dir="$here/testdata/aseprite/conformance"
aseprite="${ASEPRITE:-aseprite}"
cd "$dir"
rm -f ./*.aseprite ./*.png ./*.json
OUT="$dir/" "$aseprite" -b --script make.lua
for f in ./*.aseprite; do
	n="$(basename "$f" .aseprite)"
	"$aseprite" -b "$f" --save-as "${n}_{frame0}.png" >/dev/null
	"$aseprite" -b "$f" --data "${n}.json" --format json-array --list-tags --list-slices >/dev/null
done
"$aseprite" --version
echo "Made $(ls ./*.aseprite | wc -l) cases in $dir"
