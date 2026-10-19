#!/usr/bin/env bash
# Builds SDL3, SDL3_image, SDL3_ttf and SDL3_mixer as static libraries (the third_party/
# submodules, pinned to the versions the engine is used with) into sdl/lib/<os>_<arch>/. Games
# link these instead of the system's shared libraries (sdl_static.odin says how), so an exported
# game is one executable that needs only libc and the OS's own graphics, audio and window system
# (SDL loads those at run time, as it always does).
#
# Every library is built with no outside dependencies:
#   SDL3_image  PNG and JPEG through stb_image (not libpng: no animated PNG); BMP, GIF, TGA, QOI, PNM, SVG, XCF, XPM, LBM,
#               PCX built in. No AVIF, TIFF, WebP or JPEG XL (they'd need more libraries)
#   SDL3_ttf    its bundled FreeType; no HarfBuzz (complex-script shaping: it's C++) or PlutoSVG
#               (color emoji)
#   SDL3_mixer  WAV, AIFF, VOC, AU, FLAC (dr_flac), MP3 (dr_mp3), Ogg Vorbis (stb_vorbis), MIDI
#               (Timidity). No Opus, MOD or GME
#
# Usage: tools/build_sdl_static.sh       (needs CMake and a C compiler; a few minutes the first time)
set -euo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)
src="$engine/third_party"
for lib in SDL SDL_image SDL_ttf SDL_mixer; do
	if [[ ! -f "$src/$lib/CMakeLists.txt" ]]; then
		echo "The $lib sources are missing: git submodule update --init --recursive third_party/$lib" >&2
		exit 1
	fi
done
# SDL_ttf's bundled FreeType is a submodule of its own (CI checks out ours without recursing)
if [[ ! -f "$src/SDL_ttf/external/freetype/CMakeLists.txt" ]]; then
	git -C "$src/SDL_ttf" submodule update --init --depth 1 external/freetype
fi
command -v cmake > /dev/null || { echo "CMake is needed to build SDL" >&2; exit 1; }

case "$(uname -s)" in
	Linux)  os=linux ;;
	Darwin) os=darwin ;;
	*)      echo "Static SDL is built for Linux and macOS so far" >&2; exit 1 ;;
esac
case "$(uname -m)" in
	x86_64)        arch=amd64 ;;
	arm64|aarch64) arch=arm64 ;;
	*)             echo "Unknown CPU $(uname -m)" >&2; exit 1 ;;
esac
target="${os}_${arch}"
out="$engine/sdl/lib/$target"
work="$engine/sdl/build/$target"
prefix="$work/install"
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
mkdir -p "$out" "$work"

common=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
	-DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_INSTALL_LIBDIR=lib)
[[ $os == darwin ]] && common+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)

build() { # <source> <name> <options...>
	local source=$1 name=$2
	shift 2
	echo "== $name"
	cmake -S "$source" -B "$work/$name" "${common[@]}" "$@" > "$work/$name.configure.log" ||
		{ tail -30 "$work/$name.configure.log" >&2; exit 1; }
	cmake --build "$work/$name" --parallel "$jobs" > "$work/$name.build.log" ||
		{ tail -30 "$work/$name.build.log" >&2; exit 1; }
	cmake --install "$work/$name" > /dev/null
}

build "$src/SDL" SDL3 -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_TEST_LIBRARY=OFF
build "$src/SDL_image" SDL3_image -DSDLIMAGE_VENDORED=OFF -DSDLIMAGE_DEPS_SHARED=OFF -DSDLIMAGE_BACKEND_STB=ON -DSDLIMAGE_PNG_LIBPNG=OFF \
	-DSDLIMAGE_AVIF=OFF -DSDLIMAGE_JXL=OFF -DSDLIMAGE_TIF=OFF -DSDLIMAGE_WEBP=OFF -DSDLIMAGE_SAMPLES=OFF -DSDLIMAGE_TESTS=OFF
build "$src/SDL_ttf" SDL3_ttf -DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF
build "$src/SDL_mixer" SDL3_mixer -DSDLMIXER_VENDORED=OFF -DSDLMIXER_DEPS_SHARED=OFF -DSDLMIXER_EXAMPLES=OFF -DSDLMIXER_TESTS=OFF \
	-DSDLMIXER_FLAC_LIBFLAC=OFF -DSDLMIXER_GME=OFF -DSDLMIXER_MOD=OFF -DSDLMIXER_MP3_MPG123=OFF -DSDLMIXER_OPUS=OFF \
	-DSDLMIXER_VORBIS_VORBISFILE=OFF -DSDLMIXER_MIDI_FLUIDSYNTH=OFF -DSDLMIXER_WAVPACK=OFF

# Just the archives: libSDL3.a, libSDL3_image.a, libSDL3_ttf.a, libSDL3_mixer.a (and FreeType, when
# SDL_ttf installs it separately)
rm -f "$out"/*.a
find "$prefix/lib" -maxdepth 1 -name '*.a' -exec cp {} "$out/" \;
ls -la "$out"
