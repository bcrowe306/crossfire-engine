#!/usr/bin/env bash
# Builds Box2D (the third_party/box2d submodule, v3.1.1: the version the box2d/ binding is for)
# into box2d/lib/, where the binding links it from. Compiles the sources directly, so it needs a
# C compiler but not CMake.
#
# Usage: tools/build_box2d.sh            the library for this machine (Linux x86_64 for now)
#        tools/build_box2d.sh <emsdk>    also the web library (box2d_web.o), with that emsdk's Emscripten
#
# The desktop library uses SSE2, not AVX2, so exported games run on any x86_64 CPU. The web
# library has SIMD off (BOX2D_DISABLE_SIMD), so it doesn't need wasm SIMD support.
set -euo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)
src="$engine/third_party/box2d"
out="$engine/box2d/lib"
if [[ ! -f "$src/src/body.c" ]]; then
	echo "The Box2D sources are missing: git submodule update --init third_party/box2d" >&2
	exit 1
fi
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

build() { # <compiler> <archiver> <library> <flags...>
	local cc=$1 ar=$2 lib=$3
	shift 3
	rm -f "$work"/*.o
	local pids=()
	for file in "$src"/src/*.c; do
		# gnu17: timer.c needs POSIX's clock_gettime
		"$cc" -c "$file" -o "$work/$(basename "${file%.c}").o" -std=gnu17 -O2 -DNDEBUG -I"$src/include" "$@" &
		pids+=($!)
	done
	for pid in "${pids[@]}"; do wait "$pid" || { echo "Compiling Box2D failed" >&2; exit 1; }; done
	rm -f "$lib"
	if [[ "$lib" == *.o ]]; then
		# One relocatable object (the web): Odin keeps C symbol names on wasm only for .o files
		"$ar" -r "$work"/*.o -o "$lib"
	else
		"$ar" rcs "$lib" "$work"/*.o
	fi
	echo "Built $lib"
}

case "$(uname -s)-$(uname -m)" in
Linux-x86_64) build cc ar "$out/box2d_linux_amd64.a" -fPIC -msse2 ;;
*) echo "No desktop Box2D build for $(uname -s)-$(uname -m) yet" >&2 ;;
esac

if [[ $# -ge 1 ]]; then
	emsdk=$1
	# The "archiver" here is emcc -r, which links the objects into one
	build "$emsdk/upstream/emscripten/emcc" "$emsdk/upstream/emscripten/emcc" "$out/box2d_web.o" -DBOX2D_DISABLE_SIMD
fi
