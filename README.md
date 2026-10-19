<p align="center"><img src="logo/crossfire.png" width="128" alt="Crossfire"></p>

# Crossfire Engine

[![Build](https://github.com/bcrowe306/odin_sdl_engine/actions/workflows/build.yml/badge.svg)](https://github.com/bcrowe306/odin_sdl_engine/actions/workflows/build.yml)

Crossfire (this repository: `odin_sdl_engine`) is a 2D game engine in [Odin](https://odin-lang.org) on SDL3: scenes of nodes with transforms, sprites
and animation, text and menus, a camera, Box2D physics (bodies, areas, ray casts, joints, a
character mover), particle emitters (with color ramps), sound (sound, positional sound and streamed music nodes, mix
buses), input actions (keys, mouse and gamepads, like Godot's
input map), components (reusable node trees, instanced in scenes or from code), levels made in the
[LDtk](https://ldtk.io) level editor (tile layers, entities that become components or scripted
nodes with their LDtk fields, IntGrid collision), scripts in Odin, global game state with JSON saves, data resources, and a player
that runs projects made with [odin_sdl_editor](https://github.com/bcrowe306/odin_sdl_editor). It
builds for Linux, Windows, macOS and the web (WebAssembly).

## Building

Needs Odin (`dev-2026-10`). With `tools/build_sdl_static.sh` (Linux, macOS and Windows; needs CMake, and Visual Studio on Windows) SDL3,
SDL3_image, SDL3_ttf and SDL3_mixer are built from the submodules and linked into every program,
so games are a single executable; without it, the system's SDL3 libraries are used (on Windows,
Odin ships them).

```bash
git clone --recursive https://github.com/bcrowe306/odin_sdl_engine
cd odin_sdl_engine
tools/build_box2d.sh                         # once: Box2D (third_party/box2d) into box2d/lib
tools/build_sdl_static.sh                    # once (Linux, macOS; needs CMake): SDL linked statically
odin check . -no-entry-point -vet-unused     # the library
odin test . -vet-unused                      # the tests
odin build player -out:player_bin            # the player: player_bin <project folder>
```

Use it from a game as a package: `import e "engine:."` with `-collection:engine=<this folder>`.

## Releases

Pushing a version tag (`v0.2.0`, or `v0.2.0-dev.1` for a pre-release) builds and tests the engine on
Linux x86_64, Windows x86_64 and macOS arm64 (`.github/workflows/build.yml`) and, when all pass,
publishes the player for each as a [release](https://github.com/bcrowe306/odin_sdl_engine/releases).
`tools/ci/` holds the scripts the workflow runs (and the editor's reuses).

## Documentation

`CLAUDE.md` describes the architecture and the rules that keep the engine correct; every public
procedure has an Odin doc comment (`odin doc .`).
