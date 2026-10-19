#!/usr/bin/env bash
# Builds the engine's player (optimized) and packs it for a release:
#   dist/odin_sdl_engine-player-<version>-<platform>.tar.gz (.zip on Windows)
# with the SDL3 libraries it needs (Linux: in lib/, found through rpath $ORIGIN/lib; Windows:
# the DLLs next to it; macOS: Homebrew's, not bundled), unless the static SDL is built
# (tools/build_sdl_static.sh): then SDL is inside it, which is checked.
#
# Usage: tools/ci/package_player.sh <platform> <version>   (after tools/ci/setup.sh)
set -euo pipefail
platform=$1
version=$2
engine=$(cd "$(dirname "$0")/../.." && pwd)
name="odin_sdl_engine-player-$version-$platform"
stage="$engine/dist/$name"
rm -rf "$stage"
mkdir -p "$stage"
cd "$engine"

# With the static SDL built (tools/build_sdl_static.sh), SDL is inside the player
static=false
compgen -G "$engine/sdl/lib/*/libSDL3.a" > /dev/null && static=true
compgen -G "$engine/sdl/lib/*/sdl3_static.lib" > /dev/null && static=true
case "$(uname -s)" in
Linux)
	if $static; then
		odin build player -o:speed "-out:$stage/player"
	else
		odin build player -o:speed "-out:$stage/player" "-extra-linker-flags:-Wl,-rpath,\$ORIGIN/lib"
		mkdir -p "$stage/lib"
		ldd "$stage/player" | awk '/libSDL3/ { print $3 }' | while read -r lib; do cp -L "$lib" "$stage/lib/"; done
	fi
	;;
Darwin)
	# Homebrew's -L only without the static SDL: macOS's linker takes the first folder with a
	# library, so Homebrew's dylibs would win over the static ones
	if $static; then
		odin build player -o:speed "-out:$stage/player"
	else
		odin build player -o:speed "-out:$stage/player" ${ODIN_LINK_FLAGS:-}
	fi
	;;
*)
	odin build player -o:speed "-out:$stage/player.exe"
	if ! $static; then
		root=$(odin root)
		for d in sdl3 sdl3/image sdl3/ttf sdl3/mixer; do cp "${root%/}/vendor/$d"/*.dll "$stage/"; done
	fi
	;;
esac

# Static: the player mustn't load any SDL library (otool on macOS, which has no ldd)
if $static && [[ "$(uname -s)" == Darwin ]]; then
	if otool -L "$stage/player" | grep -i "sdl3"; then
		echo "The player still links SDL dynamically" >&2
		exit 1
	fi
	echo "The player has SDL inside it:"
	otool -L "$stage/player"
elif $static && command -v ldd > /dev/null; then
	program="$stage/player"
	[[ -f "$program.exe" ]] && program="$program.exe"
	if ldd "$program" | grep -i "sdl3"; then
		echo "The player still links SDL dynamically" >&2
		exit 1
	fi
	echo "The player has SDL inside it:"
	ldd "$program"
fi

cat > "$stage/README.txt" <<TXT
odin_sdl_engine player $version ($platform)

Runs a project saved by odin_sdl_editor:

    player <project folder>                 from its start scene
    player <project folder> --scene <name>  from another scene

The editor builds its own players for projects with scripts; this one runs projects without.
TXT
if [[ "$(uname -s)" == Darwin ]] && ! $static; then
	echo "Needs SDL3 from Homebrew: brew install sdl3 sdl3_image sdl3_ttf sdl3_mixer" >> "$stage/README.txt"
fi

cd "$engine/dist"
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) 7z a -tzip -bso0 "$name.zip" "$name" ;;
*) tar -czf "$name.tar.gz" "$name" ;;
esac
rm -rf "$stage"
ls -la "$engine/dist"
