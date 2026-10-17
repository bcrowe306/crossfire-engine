#!/usr/bin/env bash
# CI setup for the engine and the editor (GitHub Actions; bash on every runner, Git Bash on
# Windows): installs Odin and the SDL3 libraries, and builds Odin's STB libraries.
#
#   Linux:   Odin from its GitHub release; SDL3, SDL3_image, SDL3_ttf, SDL3_mixer built from
#            source into $SDL_PREFIX (the workflow caches it) and installed into /usr/local,
#            because Ubuntu has no SDL3 packages
#   macOS:   (Apple Silicon) Odin from its GitHub release, SDL3 from Homebrew. Not Homebrew's
#            odin: it lags behind (2026-08 when dev-2026-10 was current), and the code needs dev-2026-10
#   Windows: Odin from its GitHub release; it carries SDL3's .lib/.dll files, whose folders go
#            on PATH so tests and tools find the DLLs
#
# Writes to $GITHUB_PATH and $GITHUB_ENV (ODIN_ROOT, ODIN_LINK_FLAGS: extra linker flags for
# `odin build`/`odin test`, empty where none are needed).
set -euo pipefail

ODIN_VERSION=${ODIN_VERSION:-dev-2026-10}
SDL_VERSION=${SDL_VERSION:-3.4.16}
SDL_IMAGE_VERSION=${SDL_IMAGE_VERSION:-3.4.6}
SDL_TTF_VERSION=${SDL_TTF_VERSION:-3.2.2}
SDL_MIXER_VERSION=${SDL_MIXER_VERSION:-3.2.4}
SDL_PREFIX=${SDL_PREFIX:-$HOME/sdl3}
GITHUB_PATH=${GITHUB_PATH:-/dev/null}
GITHUB_ENV=${GITHUB_ENV:-/dev/null}

step() { echo "::group::$*"; }
done_() { echo "::endgroup::"; }

install_odin_release() { # <asset>
	local asset=$1 dir="$HOME/odin"
	step "Odin $ODIN_VERSION ($asset)"
	rm -rf "$dir" "$HOME/odin-download"
	mkdir -p "$dir" "$HOME/odin-download"
	curl -fsSL -o "$HOME/odin-download/$asset" "https://github.com/odin-lang/Odin/releases/download/$ODIN_VERSION/$asset"
	case "$asset" in
	*.zip) unzip -q "$HOME/odin-download/$asset" -d "$HOME/odin-download/x" ;;
	*) mkdir -p "$HOME/odin-download/x" && tar -xzf "$HOME/odin-download/$asset" -C "$HOME/odin-download/x" ;;
	esac
	# The archive holds one folder (or the files themselves): find odin wherever it is
	local exe
	exe=$(find "$HOME/odin-download/x" -maxdepth 3 -type f \( -name odin -o -name odin.exe \) | head -1)
	[[ -n "$exe" ]] || { echo "odin not found in $asset" >&2; exit 1; }
	cp -a "$(dirname "$exe")"/. "$dir"/
	chmod +x "$dir"/odin* 2>/dev/null || true
	export PATH="$dir:$PATH"
	done_
}

build_sdl_library() { # <repo> <version> <cmake options...>
	local repo=$1 version=$2
	shift 2
	step "$repo $version"
	rm -rf "$HOME/build-$repo"
	git clone --quiet --depth 1 --branch "release-$version" "https://github.com/libsdl-org/$repo" "$HOME/build-$repo"
	git -C "$HOME/build-$repo" submodule update --init --depth 1 --quiet || true
	cmake -S "$HOME/build-$repo" -B "$HOME/build-$repo/out" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$SDL_PREFIX" -DCMAKE_PREFIX_PATH="$SDL_PREFIX" "$@" > /dev/null
	cmake --build "$HOME/build-$repo/out" --parallel > /dev/null
	cmake --install "$HOME/build-$repo/out" > /dev/null
	done_
}

case "$(uname -s)" in
Linux)
	step "apt packages"
	sudo apt-get update -qq
	sudo apt-get install -y -qq build-essential cmake ninja-build pkg-config \
		libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxss-dev libxtst-dev libxfixes-dev \
		libxkbcommon-dev libwayland-dev wayland-protocols libdecor-0-dev libegl1-mesa-dev libgl1-mesa-dev \
		libdrm-dev libgbm-dev libpulse-dev libasound2-dev libpipewire-0.3-dev libudev-dev libdbus-1-dev \
		libfreetype-dev libharfbuzz-dev > /dev/null
	done_
	install_odin_release "odin-linux-amd64-$ODIN_VERSION.tar.gz"
	stamp="$SDL_PREFIX/.versions"
	want="$SDL_VERSION $SDL_IMAGE_VERSION $SDL_TTF_VERSION $SDL_MIXER_VERSION"
	if [[ ! -f "$stamp" || "$(cat "$stamp")" != "$want" ]]; then
		rm -rf "$SDL_PREFIX"
		build_sdl_library SDL "$SDL_VERSION" -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
		build_sdl_library SDL_image "$SDL_IMAGE_VERSION" -DSDLIMAGE_VENDORED=ON -DSDLIMAGE_AVIF=OFF -DSDLIMAGE_JXL=OFF -DSDLIMAGE_WEBP=OFF -DSDLIMAGE_TIF=OFF
		build_sdl_library SDL_ttf "$SDL_TTF_VERSION" -DSDLTTF_VENDORED=ON
		build_sdl_library SDL_mixer "$SDL_MIXER_VERSION" -DSDLMIXER_VENDORED=ON -DSDLMIXER_EXAMPLES=OFF -DSDLMIXER_TESTS=OFF
		echo "$want" > "$stamp"
	else
		echo "SDL3 $want: from the cache"
	fi
	# Where the linker and the loader look by default
	sudo cp -a "$SDL_PREFIX"/lib/. /usr/local/lib/
	sudo cp -a "$SDL_PREFIX"/include/. /usr/local/include/
	sudo ldconfig
	echo "ODIN_LINK_FLAGS=" >> "$GITHUB_ENV"
	;;
Darwin)
	# Apple Silicon (the workflow's macOS runner): Odin's release; SDL3 from Homebrew
	install_odin_release "odin-macos-arm64-$ODIN_VERSION.tar.gz"
	step "Homebrew: SDL3"
	brew install sdl3 sdl3_image sdl3_ttf sdl3_mixer > /dev/null
	done_
	prefix=$(brew --prefix)
	echo "ODIN_LINK_FLAGS=-extra-linker-flags:-L$prefix/lib" >> "$GITHUB_ENV"
	;;
MINGW* | MSYS* | CYGWIN*)
	install_odin_release "odin-windows-amd64-$ODIN_VERSION.zip"
	echo "ODIN_LINK_FLAGS=" >> "$GITHUB_ENV"
	;;
*)
	echo "No CI setup for $(uname -s)" >&2
	exit 1
	;;
esac

root=$(odin root)
root=${root%/}
odin version
echo "ODIN_ROOT=$root" >> "$GITHUB_ENV"
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
	cygpath -w "$HOME/odin" >> "$GITHUB_PATH"
	for d in sdl3 sdl3/image sdl3/ttf sdl3/mixer; do cygpath -w "$root/vendor/$d" >> "$GITHUB_PATH"; done
	;;
Linux | Darwin)
	echo "$HOME/odin" >> "$GITHUB_PATH"
	;;
esac

# Odin's STB libraries (Skald needs them), checked for this OS: the Linux release carries the
# macOS ones (lib/darwin/) but not its own; Windows' are built
case "$(uname -s)" in
Linux) stb="$root/vendor/stb/lib/stb_truetype.a" ;;
Darwin) stb="$root/vendor/stb/lib/darwin/stb_truetype.a" ;;
*) stb="$root/vendor/stb/lib/stb_truetype.lib" ;;
esac
if [[ ! -f "$stb" ]]; then
	step "STB"
	(cd "$root/vendor/stb/src" && sh build_stb.sh) > /dev/null
	done_
fi
