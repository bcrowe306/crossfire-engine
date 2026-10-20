#!/usr/bin/env bash
# Linux: builds against an old glibc with zig, so Linux games and the editor run on older
# distributions (Ubuntu 20.04, Steam's runtime) and not only on the glibc they were built with.
#
#   tools/ci/zig_toolchain.sh [<folder>]     (default: $HOME/zig-toolchain)
#
# Installs zig (ZIG_VERSION) and writes three wrappers into <folder>/bin, calling `zig cc` /
# `zig c++` with -target x86_64-linux-gnu.$GLIBC:
#   clang    what Odin links with (it calls clang from PATH); archives given as -l:<path> are
#            passed as files, which zig wants; the system's library folders searched last
#   zcc, zc++ C and C++ compilers for CMake (tools/build_sdl_static.sh: CC, CXX)
# On GitHub Actions the folder goes first in PATH and CC / CXX are set for the following steps;
# elsewhere it prints what to set. Build the static SDL and Box2D after it (with it), then games.
# Checked: a player built this way needs GLIBC_2.29 at most (2.43 when built on Arch), and runs.
set -euo pipefail
ZIG_VERSION=${ZIG_VERSION:-0.17.0}
GLIBC=${GLIBC:-2.31}
root=${1:-$HOME/zig-toolchain}
[[ "$(uname -s)" == Linux ]] || { echo "Only for Linux builds" >&2; exit 1; }
case "$(uname -m)" in
	x86_64) arch=x86_64 ;;
	aarch64) arch=aarch64 ;;
	*) echo "Unknown CPU $(uname -m)" >&2; exit 1 ;;
esac
zig="$root/zig-$arch-linux-$ZIG_VERSION/zig"
if [[ ! -x "$zig" ]]; then
	mkdir -p "$root"
	curl -fL --silent --show-error -o "$root/zig.tar.xz" "https://ziglang.org/download/$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz"
	tar -xf "$root/zig.tar.xz" -C "$root"
	rm "$root/zig.tar.xz"
fi
target="$arch-linux-gnu.$GLIBC"
syslib=""
for d in /usr/lib/$arch-linux-gnu /usr/lib64 /usr/lib; do [[ -d "$d" ]] && syslib+=" -L$d"; done
mkdir -p "$root/bin"
cat > "$root/bin/clang" <<WRAP
#!/usr/bin/env bash
args=()
for a in "\$@"; do
	case "\$a" in
	-l:/*) args+=("\${a#-l:}") ;;
	-l/*) args+=("\${a#-l}") ;;
	*) args+=("\$a") ;;
	esac
done
# The system's libraries last (zig searches none for a glibc target): X11 and the like are
# linked by name only, so their glibc doesn't matter
exec "$zig" cc -target $target "\${args[@]}" $syslib
WRAP
printf '#!/bin/sh\nexec "%s" cc -target %s "$@"\n' "$zig" "$target" > "$root/bin/zcc"
printf '#!/bin/sh\nexec "%s" c++ -target %s "$@"\n' "$zig" "$target" > "$root/bin/zc++"
chmod +x "$root/bin/clang" "$root/bin/zcc" "$root/bin/zc++"
"$root/bin/zcc" --version | head -1
if [[ -n "${GITHUB_PATH:-}" ]]; then
	echo "$root/bin" >> "$GITHUB_PATH"
	# GLIBC_MAX: the packaging scripts check their programs need no newer glibc
	{ echo "CC=$root/bin/zcc"; echo "CXX=$root/bin/zc++"; echo "GLIBC_MAX=$GLIBC"; } >> "$GITHUB_ENV"
else
	echo "Now: export PATH=\"$root/bin:\$PATH\" CC=\"$root/bin/zcc\" CXX=\"$root/bin/zc++\""
fi
