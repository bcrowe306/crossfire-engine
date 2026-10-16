# odin_sdl_engine

A 2D game engine in Odin on SDL3 (renderer, SDL_image, SDL_ttf, SDL_mixer). It is a library
package, `package engine`, used by games (the `asteroids` sample in the workspace) and by the
**odin_sdl_editor**. Consumers import it as `e`:

```odin
import e "odin_sdl_engine"   // or "../odin_sdl_engine" from a sibling package
```

## Commands

```bash
odin check . -no-entry-point -vet-unused    # type-check the library (it has no main)
odin test . -vet-unused                     # unit tests (format parser, transforms, scripts)
odin check player -vet-unused               # type-check the player program
odin build player -out:player_bin           # build the player: player_bin <project folder>
```

To run something, build a game that uses it. In the workspace root, `odin run .` runs asteroids.

Runtime libraries: `libSDL3`, `libSDL3_image`, `libSDL3_ttf`, `libSDL3_mixer`. The default font is
compiled in with `#load` (`Open_Sans/static/OpenSans-Regular.ttf`).

## Architecture

```
Application (app.odin)     window, SDL renderer, mixer, SDL_ttf; main loop; converts event coords to game coords
  └─ Game (game.odin)      fixed resolution + ScaleMode, ResourceManager, scenes by name, scene switching
      └─ Scene (scene.odin) nodes, add/remove queues, current camera, screenLayers, own memory arena
          └─ Node (node.odin) transform + parent/children, layer, visible, tint, update/draw/destroy procs,
                              onEnter/onExit; lives in ITS OWN arena. Camera2D is a node too
```

| File | Purpose |
|---|---|
| `resource_manager.odin` | Cached textures (any format, via SDL_image), audio, fonts by path and size; embedded `DEFAULT_FONT`; text engine |
| `transform.odin` | `Transform2D` (2x3 matrix) math; node world transforms, `Node_SetParent` / `Node_AddChild`, screen positions; the draw transform and tint |
| `primitives.odin` | Shapes and `DrawTexture`, in the drawing node's local space |
| `text_primitives.odin` | `DrawText`, `DrawTextCentered`, `DrawTextWrapped`, `MeasureText`; positioned and scaled by the draw transform, never rotated |
| `camera.odin` | `Camera2D` node (looks at its world position; offset, zoom, bounds), follow modes, timed pans |
| `easing.odin` | `Ease(EaseType, t)`, 18 curves |
| `animation.odin` | `Animation` base, `SpriteSheetAnimation`, `FrameAnimation` |
| `animation_player.odin` | Plays animations by name or index, with events |
| `event.odin` | `EventSubject`: subscribe / unsubscribe / notify |
| `timer.odin`, `ticker.odin` | Time-based events |
| `ui_menu*.odin`, `ui_style.odin`, `ui_label.odin` | In-game `Menu` (button, checkbox, radio, slider, select) and `Label` nodes |
| `layers.odin` | `RenderLayer` (draw order, `Layer1` first) |
| `project_format.odin` | **Project/scene XML format spec** (doc comment) and parser: `ParseProject`, `ParseScene` → plain data (`ProjectData`, `SceneData`), no SDL |
| `project_loader.odin` | Builds scenes from parsed data: `LoadProjectFile`, `Game_LoadProject`, `Scene_Build`; data-driven `Sprite` and `AnimatedSprite` nodes; menu actions `scene:<Name>` / `quit` |
| `script.odin` | **Scripts**: Odin game code attached to nodes. `Script_Register`, the registry, exported fields (`export:""` tags) set from scene files by reflection, `Node_AttachScript`, `Script_DescribeJSON` |
| `player.odin` | `Player_Run(args)`: the whole player program (`player <project folder>`, `player --describe-scripts`) |
| `player/main.odin` | The **player** for projects without scripts: calls `Player_Run`. A project with scripts gets its own generated main that also imports its `scripts` package. Used by the editor's Play and, later, exports |
| `script_test.odin` | Tests: script registration, fields and tags, lifecycle on a node, bad values, `Scene_FindNode` paths, format v3 scripts |
| `project_format_test.odin`, `transform_test.odin` | Tests: parser and v1 migration; transform math, hierarchy, subtree removal, draw order/transform/tint/visibility, camera node |

## Rules that keep the engine correct

**Memory ownership:**
- `CreateNode` puts each node in its **own** virtual-memory arena. Anything the node owns is allocated
  with `Node_GetAllocator(node)`: event subjects, animation players and animations, timers, tickers,
  strings. It's all freed in one step when the node is destroyed.
- Data shared by a whole scene uses `Scene_GetAllocator(scene)`. The camera does.
- `EventSubject_Init(subject, allocator)`, `Ticker_Init(..., allocator)`, `TimerNode_Init(..., allocator)`
  and `AnimationPlayer_Init(player, allocator)` must get the owner's allocator. The default
  allocator leaks once the owner is freed.
- `scene->removeNode(id)` is deferred. At the start of the next update the node gets `onExit`, then
  its `destroy` callback, then its arena is freed. Pointers to it are invalid after that. A node that
  subscribed to another object's events must unsubscribe in `destroy`.
- `context.temp_allocator` is freed every frame (`Application_Run`). Only use it for data that dies
  within the frame.
- A node arena's `Arena` struct lives inside its own memory: always destroy a **copy** (see
  `Node_Destroy`).

**Transforms and hierarchy:**
- Every node has `position`, `rotation` (degrees, clockwise) and `scale` **relative to its parent**.
  The world transform is computed on demand by walking up the parents
  (`Node_GetWorldTransform`), so it's always current. Parent with `Node_AddChild` /
  `Node_SetParent` (`keepWorld` keeps it in place); loops are refused.
- Removing a node removes its whole subtree. Children are destroyed before parents, because a
  parent's children list lives in its arena.
- Hidden nodes (`visible = false`) and their subtrees aren't drawn, but they **still update**.
  Use `Node_IsVisibleInTree` in update code that should pause. `tint` multiplies down the tree.
- UI nodes (`Label`, `Menu`) are `transformMode = .Position_Only`: they follow their screen position
  but aren't rotated or scaled, and `Menu` hit-tests input relative to `Node_GetScreenPosition`.

**Coordinates and drawing:**
- Everything is in **game coordinates** (`game.size`). SDL logical presentation scales them to the
  window, and the app converts event positions back.
- **A node's `draw` works in its local space.** `Scene_Draw` sets the draw transform to camera view
  × node world transform before each `draw` call, and the `Draw*` helpers apply it (plus the
  inherited tint). Draw a sprite centered on (0, 0) and let the node's transform place it. Layers in
  `scene.screenLayers` skip the camera.
- Draw order: layer first, then tree order (parent before children, siblings in insertion order).
- `Scene_DrawWithView(scene, renderer, view, ...)` draws through any view transform instead of the
  camera. The editor's viewport uses it with `positionOnlyScale` set to its zoom.
- `Node.getBounds` (optional) reports the local rectangle a node draws (`Node_GetLocalBounds`).
  The editor uses it for picking and selection boxes. Sprite, AnimatedSprite, Label and Menu set
  it; **give new drawable node types (including game-code nodes) a `getBounds`**.
- `Scene_Build` returns the nodes it created, in scene-data order, so tools can keep them in sync.
- Raw `sdl.Render*` calls bypass all of this. Use the engine helpers, or transform points yourself
  with `GetDrawTransform()`.
- **Camera:** `scene.camera` is a `Camera2D` node. It looks at its world position, and its world
  rotation turns the view; parent it to a node to follow that node. `Camera2D_Follow`, `MoveTo`
  and bounds move the camera node (`Camera2D_SetTarget`).

**Node types** embed `using node: e.Node` as their **first** field. Casting and node allocation both
depend on it.

**Scripts** (`script.odin`, doc comment at the top has the full example):
- A script struct's first field is `using script: e.Script` (checked at registration). It's
  allocated in its node's arena by `Node_AttachScript`, so it's freed with the node.
- Scripts register from `@(init)` procedures, which **this Odin requires to be
  `proc "contextless"`**; `Script_Register` is contextless and sets up its own context.
- **Never use `@(init)` in a `_test.odin` file**: those files are compiled into normal builds too,
  so it would run in every game. Register test scripts lazily (`sync.once_do`, see script_test.odin).
- Lifecycle: `ready` once on the first `Scene_Update` after the node is in the scene (all nodes exist
  then; `Scene_FindNode(scene, "World/Ship")`), `update` after the node's own update, `draw` after
  its draw in the same local space, `destroy` in `Node_Destroy`.
- Exported fields: tagged `export:""`, options `default=`, `min=`, `max=`, `kind=scene` (each runs to
  the next key, so values may contain spaces/commas). Types: f32, f64, int, i32, bool, string,
  [2]f32, enums, sdl.Color. Values are text in scene files (`Script_SetField`); bad ones fall back
  to the default with a warning.
- Hooks are stored type-erased (`transmute` of `proc(^T)` to `proc(rawptr)`).
- One script per node. `Scene_Build(..., attachScripts = false)` is for the editor viewport, where
  scripts don't run.
- **Later (decided, not built):** several scripts per node; custom node kinds registered by game code
  (a struct embedding e.g. `e.Sprite`, used as `kind="Player"`); hot reload of scripts as a shared
  library (`core:dynlib`) in development builds.

## Conventions

- Types are `PascalCase`.
- Procedures are `Type_Action` (`Camera2D_Follow`, `AnimationPlayer_Play`), and constructors are
  `CreateThing`.
- Some structs expose method-style procedure fields called with `->` (`game->switchScene`,
  `rm->loadTexture`, `anim->totalFrames()`). Keep that where it exists. Use proc groups for
  name-or-index overloads (`AnimationPlayer_Play`).
- Fields and locals are `camelCase`. Constants are `SCREAMING_SNAKE_CASE`. Indent with tabs.
- Helpers are `@(private="file")`. Cross-file internals are `@(private)`.
- Prefer defaults that work zero-initialized (e.g. a camera with `zoom == 0` acts as 1).

## Documentation (required)

All public code has **Odin-style doc comments** in the format of Odin's own `core` library, which
`odin doc` and pkg.odin-lang.org render. `camera.odin`, `transform.odin`, `animation*.odin`, `easing.odin` and
`node.odin` are the reference examples.

```odin
/*
One-line summary.

Details: behavior, ownership, when to call it.

Inputs:
- camera: The camera to move
- deltaTime: Seconds since the last frame

Returns:
- What comes back (omit for procedures that return nothing)

Example:
	e.Camera2D_Follow(node.scene.camera, player.pos, deltaTime)
*/
```

- **Coverage:** every public type, procedure, constant and enum, plus struct fields.
- **Code blocks:** tab-indented under `Example:`, and they must compile. Check them by extracting them
  into a scratch package that imports the engine, then running `odin check`.
- **Package docs:** the package overview goes in `doc.odin` (not created yet), as a `/* */` block
  directly above `package engine`. Other file overviews (like the one at the top of `camera.odin`)
  must have a blank line before `package`, so they don't become the package doc.
- **Still to convert:** older files use short `//` comments: `app.odin`, `game.odin`, `event.odin`,
  `resource_manager.odin`, `text_primitives.odin`, `primitives.odin` (except `DrawTexture`),
  `ui_*.odin`, `timer.odin`, `ticker.odin`. Convert them when you touch them.

### Generating the GitHub Pages site

Use Odin's generator, the one behind pkg.odin-lang.org (github.com/odin-lang/pkg.odin-lang.org):

1. Build the generator: `odin build . -out:odin-doc` in a checkout of that repo.
2. `docs/all/all.odin` imports the engine package.
3. Run `odin doc docs/all/all.odin -file -all-packages -doc-format -out:engine`.
4. `docs/config.json` holds `hide_core`, `hide_base`, `url_prefix`, and a `collections` entry for the
   engine: `name`, `source_url` (GitHub blob URL), `base_url`, `root_path`, `license`, and `home`
   with `embed_readme`.
5. Run `odin-doc engine.odin-doc docs/config.json` inside the output directory.
6. Deploy with `.github/workflows/docs.yml` to GitHub Pages.

The generator needs `vendor:commonmark` installed on Linux CI. `docs/`, the workflow and the README
don't exist yet.

## Known gaps (needed by the editor's export feature)

- `app.odin` hard-codes the `"opengl"` renderer. The web needs WebGL/GLES and macOS should use Metal,
  so pass `nil` or choose per platform.
- Asset paths are relative to the working directory. Exported games need a base path
  (`sdl.GetBasePath()` or a configured asset root).
- `Application_Run` blocks in a `for` loop. The web needs a callback-driven frame (SDL3 main callbacks
  or Emscripten's main loop).
- **Scene loading limits.** These are documented in `project_format.odin`, and the editor's
  writer must stay in sync with it.
  - Menus and labels in a scene with a camera are drawn through it, because scene files can't set
    `screenLayers` yet.
  - Audio assets aren't loaded.
- **Format version 3** adds `<script>` elements; version 2 stores local positions, and version 1
  files are migrated when parsed (`migrateSceneFromV1`). Bump `PROJECT_FORMAT_VERSION` and add a migration for any incompatible
  format change.
- `RenderLayer` has 8 fixed layers. The editor will probably want named layers.

## Verifying work

- `odin check . -no-entry-point -vet-unused` must pass.
- Behavior is tested with throwaway headless programs: a hidden SDL window, the engine imported via
  `-collection:proj=<workspace>`, synthetic `sdl.Event`s, `sdl.RenderReadPixels` for pixel checks, and
  `mem.Tracking_Allocator` for leaks. Delete them afterwards. Logic without SDL goes in `odin test`.
- Then run the asteroids sample from the workspace root to make sure nothing regressed.
