#!/usr/bin/env bash
# Builds the API documentation site into docs/build/ with Odin's own generator (the one behind
# pkg.odin-lang.org): `odin doc` writes the engine's .odin-doc file (docs/all imports the
# engine), then the generator turns it into HTML (docs/config.json).
#
#   tools/build_docs.sh <odin-doc generator>
#
# The generator: `odin build . -out:odin-doc` in a checkout of
# github.com/odin-lang/pkg.odin-lang.org (it links libcmark: `apt install libcmark-dev`, or build
# github.com/commonmark/cmark and pass its folder with -extra-linker-flags:-L<folder>/src).
# Box2D must be built (tools/build_box2d.sh): the bindings check for its library.
set -euo pipefail
generator=$(realpath "${1:?usage: tools/build_docs.sh <odin-doc generator>}")
cd "$(dirname "$0")/.."
rm -rf docs/build
mkdir -p docs/build
odin doc docs/all -all-packages -doc-format -out:docs/build/engine
cd docs/build
"$generator" engine.odin-doc ../config.json
rm engine.odin-doc
echo "Docs in docs/build (open docs/build/engine/index.html through a web server)"
