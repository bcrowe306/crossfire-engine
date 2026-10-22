#!/usr/bin/env bash
# Builds the shader compilers the engine's shaders (shaders.odin) need, from the third_party/
# submodules, into shader_tools/<os>_<arch>/:
#   glslang      GLSL -> SPIR-V (glslang 16.6.0; the standalone `glslang` program)
#   shadercross  SPIR-V -> MSL for Metal, and its reflection (SDL_shadercross, built without DXC
#                against our own SPIRV-Cross and the static SDL)
#   msdf-atlas-gen  TTF/OTF -> an MSDF atlas (BMP) and its layout (JSON), for fonts that stay sharp
#                at any size (asset_import.odin; msdf-atlas-gen 1.4 with its msdfgen, against
#                SDL_ttf's FreeType; no PNG, SVG, Skia or Artery Font)
# Projects' shaders and the engine's built-in effects are written in GLSL; the editor compiles
# them to SPIR-V (Vulkan: Linux, Windows) and MSL (Metal: macOS), which is what SDL's GPU
# renderer takes on desktops. No DXIL: games with shaders draw through Vulkan on Windows.
#
# Needs CMake, a C++ compiler and Python 3 (glslang's build). Uses the static SDL's install
# (tools/build_sdl_static.sh) when it's there, else builds SDL itself. A few minutes the first time.
#
# Usage: tools/build_shader_tools.sh
set -euo pipefail

engine=$(cd "$(dirname "$0")/.." && pwd)
src="$engine/third_party"
# Submodules of submodules (CI checks ours out without recursing): msdf-atlas-gen's msdfgen and
# SDL_ttf's FreeType
if [[ -f "$src/msdf-atlas-gen/CMakeLists.txt" && ! -f "$src/msdf-atlas-gen/msdfgen/CMakeLists.txt" ]]; then
	git -C "$src/msdf-atlas-gen" submodule update --init --depth 1 msdfgen
fi
if [[ -f "$src/SDL_ttf/CMakeLists.txt" && ! -f "$src/SDL_ttf/external/freetype/CMakeLists.txt" ]]; then
	git -C "$src/SDL_ttf" submodule update --init --depth 1 external/freetype
fi
for lib in glslang SPIRV-Cross SDL_shadercross msdf-atlas-gen msdf-atlas-gen/msdfgen SDL_ttf/external/freetype; do
	if [[ ! -f "$src/$lib/CMakeLists.txt" ]]; then
		echo "The $lib sources are missing: git submodule update --init --recursive third_party/${lib%%/*}" >&2
		exit 1
	fi
done
command -v cmake > /dev/null || { echo "CMake is needed to build the shader tools" >&2; exit 1; }

case "$(uname -s)" in
	Linux)  os=linux ;;
	Darwin) os=darwin ;;
	MINGW* | MSYS* | CYGWIN*) os=windows ;;
	*)      echo "The shader tools are built for Linux, macOS and Windows" >&2; exit 1 ;;
esac
case "$(uname -m)" in
	x86_64)        arch=amd64 ;;
	arm64|aarch64) arch=arm64 ;;
	*)             echo "Unknown CPU $(uname -m)" >&2; exit 1 ;;
esac
target="${os}_${arch}"
out="$engine/shader_tools/$target"
work="$engine/shader_tools/build/$target"
prefix="$work/install"
# shadercross links SDL: the static SDL's CMake install (tools/build_sdl_static.sh), else (CI
# restores only sdl/lib from its cache) a static SDL of its own, built below
sdlPrefix="$engine/sdl/build/$target/install"
[[ -d "$sdlPrefix/lib/cmake/SDL3" ]] || sdlPrefix="$prefix"
# SHADER_TOOLS_JOBS caps parallel compiles (Linux CI: zig's C++ compiler on glslang ran a
# 4-job build out of the runner's memory, and the job was killed)
jobs=${SHADER_TOOLS_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
mkdir -p "$out" "$work"
exe=""
[[ $os == windows ]] && exe=".exe"

native() {
	if [[ $os == windows ]]; then cygpath -m "$1"; else echo "$1"; fi
}
common=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
	-DCMAKE_INSTALL_PREFIX="$(native "$prefix")" -DCMAKE_PREFIX_PATH="$(native "$prefix");$(native "$sdlPrefix")" -DCMAKE_INSTALL_LIBDIR=lib)
[[ $os == darwin ]] && common+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
[[ $os == windows ]] && common+=(-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DCMAKE_POLICY_DEFAULT_CMP0091=NEW -A x64)

build() { # <source> <name> <options...>
	local source=$1 name=$2
	shift 2
	echo "== $name"
	cmake -S "$(native "$source")" -B "$(native "$work/$name")" "${common[@]}" "$@" > "$work/$name.configure.log" 2>&1 ||
		{ tail -40 "$work/$name.configure.log" >&2; exit 1; }
	cmake --build "$(native "$work/$name")" --config Release --parallel "$jobs" > "$work/$name.build.log" 2>&1 ||
		{ tail -40 "$work/$name.build.log" >&2; exit 1; }
	cmake --install "$(native "$work/$name")" --config Release > /dev/null
}

# SDL, when the static SDL's install isn't here: just the library (no tests, no other parts)
if [[ "$sdlPrefix" == "$prefix" && ! -d "$prefix/lib/cmake/SDL3" ]]; then
	[[ -f "$src/SDL/CMakeLists.txt" ]] || { echo "The SDL sources are missing: git submodule update --init third_party/SDL" >&2; exit 1; }
	build "$src/SDL" SDL -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
fi

# glslang: only the compiler (no SPIRV-Tools optimizer, tests or HLSL front end needed)
build "$src/glslang" glslang -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DGLSLANG_ENABLE_INSTALL=ON \
	-DENABLE_HLSL=OFF -DENABLE_SPVREMAPPER=OFF -DENABLE_GLSLANG_BINARIES=ON
# SPIRV-Cross: static libraries for shadercross
build "$src/SPIRV-Cross" SPIRV-Cross -DSPIRV_CROSS_SHARED=OFF -DSPIRV_CROSS_STATIC=ON -DSPIRV_CROSS_CLI=OFF \
	-DSPIRV_CROSS_ENABLE_TESTS=OFF
# SDL_shadercross: the command-line program, SPIR-V input only
build "$src/SDL_shadercross" SDL_shadercross -DSDLSHADERCROSS_DXC=OFF -DSDLSHADERCROSS_VENDORED=OFF \
	-DSDLSHADERCROSS_SPIRVCROSS_SHARED=OFF -DSDLSHADERCROSS_SHARED=OFF -DSDLSHADERCROSS_STATIC=ON \
	-DSDLSHADERCROSS_CLI=ON -DSDLSHADERCROSS_CLI_STATIC=ON -DSDLSHADERCROSS_INSTALL=ON -DSDL3_DIR="$(native "$sdlPrefix/lib/cmake/SDL3")"

# FreeType for msdfgen's font loading: SDL_ttf's copy, only the library (no zlib, PNG, bzip2,
# Brotli or HarfBuzz: plain outlines are all msdfgen reads)
build "$src/SDL_ttf/external/freetype" freetype -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
	-DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
# msdf-atlas-gen and its msdfgen: the command-line program
build "$src/msdf-atlas-gen" msdf-atlas-gen -DMSDF_ATLAS_USE_VCPKG=OFF -DMSDFGEN_USE_VCPKG=OFF -DMSDF_ATLAS_USE_SKIA=OFF \
	-DMSDFGEN_USE_SKIA=OFF -DMSDFGEN_DISABLE_SVG=ON -DMSDFGEN_DISABLE_PNG=ON -DMSDF_ATLAS_NO_ARTERY_FONT=ON \
	-DMSDF_ATLAS_BUILD_STANDALONE=ON -DMSDF_ATLAS_INSTALL=ON -DMSDFGEN_BUILD_STANDALONE=OFF -DMSDFGEN_USE_OPENMP=OFF

cp "$prefix/bin/glslang$exe" "$out/glslang$exe"
cp "$prefix/bin/shadercross$exe" "$out/shadercross$exe"
cp "$prefix/bin/msdf-atlas-gen$exe" "$out/msdf-atlas-gen$exe"
echo "Shader tools in $out:"
ls -la "$out"
