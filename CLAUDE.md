# odin_sdl_engine: the Crossfire Engine

The product name is **Crossfire Engine** (its editor: **Crossfire Editor**, the odin_sdl_editor
repository). Use the names in anything users see (docs, release titles and archives, the
player's window); the repository, the Odin package (`engine`) and file names keep `odin_sdl`.

A 2D game engine in Odin on SDL3 (renderer, SDL_image, SDL_ttf, SDL_mixer). It is a library
package, `package engine`, used by games (the `asteroids` sample in the workspace) and by the
**odin_sdl_editor**. Consumers import it as `e`:

```odin
import e "odin_sdl_engine"   // or "../odin_sdl_engine" from a sibling package
```

## Commands

```bash
tools/build_box2d.sh [<emsdk>]              # once: build Box2D into box2d/lib/ (with an emsdk: the web library too)
tools/build_sdl_static.sh                   # once: SDL3 + _image/_ttf/_mixer as static libraries (Linux, macOS; needs CMake)
odin check . -no-entry-point -vet-unused    # type-check the library (it has no main)
odin test . -vet-unused -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true   # unit tests; a leak or bad free fails the test
odin check player -vet-unused               # type-check the player program
odin check . -no-entry-point -vet-unused -target:js_wasm32   # the browser build (web export)
odin build player -out:player_bin           # build the player: player_bin <project folder>
```

To run something, build a game that uses it. In the workspace root, `odin run .` runs asteroids.

**SDL is linked statically** once `tools/build_sdl_static.sh` has built it (sdl/lib/<os>_<arch>/,
from the `third_party/SDL*` submodules: SDL 3.4.16, SDL_image 3.4.6, SDL_ttf 3.2.2, SDL_mixer
3.2.4): every program that imports the engine (the player, project players, the editor, the
sample) then needs no SDL libraries, only libc (SDL itself loads the window system, GL/Vulkan and
the audio server at run time). `sdl_static.odin` does it: an `extra_linker_flags` `-L` to that
folder makes the vendor bindings' `-lSDL3`... resolve to the archives, which are listed again so
their order doesn't matter. Without the build, or with `-define:SDL_STATIC=false`, the system's
shared libraries are linked: `libSDL3`, `libSDL3_image`, `libSDL3_ttf`, `libSDL3_mixer`.
- **macOS:** Odin's link command puts `-L/usr/local/lib -L/opt/homebrew/lib` (when it exists)
  before every library, so the bindings' `-lSDL3` finds Homebrew's dylib first on any Mac with
  Homebrew's SDL: sdl_static.odin's archives have `@(priority_index = -1)` (first, so they define
  SDL's symbols) and `-Wl,-dead_strip_dylibs` drops the unused dylibs. `package_player.sh`
  checks with `otool -L`.
- The `-L` folder is **quoted**: the linker runs through a shell, and an engine inside
  "Crossfire Editor.app" (or any folder with a space) failed to link.
- **Windows** (the script builds with Visual Studio and the static CRT, `/MT`, like Odin and
  Box2D): the bindings name Odin's own `SDL3.lib` import libraries by path, which no search path
  replaces. MSVC's linker takes each symbol from the first library on its command line that has
  it, and Odin sorts foreign imports by `@(priority_index)` first: sdl_static.odin's are -1, before
  the bindings' 0, so the static `sdl3_static.lib`... define everything and SDL3.dll isn't loaded.
  The names avoid `SDL3.lib` on purpose. Odin ignores `priority_index` elsewhere (its order only
  matters to MSVC).
- What's built in: images through stb_image (PNG, JPEG) plus SDL_image's own formats (no AVIF,
  TIFF, WebP, JXL, animated PNG); SDL_ttf with its bundled FreeType (no HarfBuzz shaping, no
  color emoji); SDL_mixer with WAV, AIFF, VOC, AU, FLAC, MP3, Ogg Vorbis, MIDI. FreeType's
  license asks games to credit it.
- **glibc:** a Linux build runs on the glibc it was built against or newer. Built on this Arch
  machine (2.44) a game needs GLIBC_2.43 (C23 `__isoc23_*`, versioned math), so it won't start on
  Ubuntu 24.04 (2.39) or Steam's runtime (2.31): release builds belong on an old glibc (CI's
  Ubuntu, a Steam Runtime container, or `zig cc` with a glibc target: the planned experiment).

Runtime libraries without the static build: `libSDL3`, `libSDL3_image`, `libSDL3_ttf`, `libSDL3_mixer`. Box2D is linked
statically from `box2d/lib/` (built from the `third_party/box2d` submodule, v3.1.1, by
`tools/build_box2d.sh`; nothing to install). Without it, compiling stops with a message saying so. The default font is
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
| `render_backend.odin` | **Renderer choice**: `RenderBackend` (Auto, OpenGL, OpenGLES2, Vulkan, GPU, Direct3D11/12, Metal, Software), `RENDER_BACKENDS` (SDL driver names, labels, platforms), `RenderBackend_Available` / `Parse`, `Application_CreateRenderer` (falls back to SDL's choice, logs the one in use) |
| `player.odin` | `Player_Run(args)`: the whole player program (`player <project folder>`, `player --scene <name>`, `player --describe-scripts`); `Player_Setup`, shared with the web; with no folder, an exported game finds its project next to itself (`data/project.xml`) |
| `platform_native.odin`, `platform_web.odin` | **Platform layer** (`#+build !js` / `#+build js`): memory arenas, reading files, the executable's folder, loading textures. Code outside these files must not import `core:os`, `core:mem/virtual`, `core:path/filepath` or SDL_image: they don't build for the browser (SDL_mixer does: see "Web build") |
| `player_web.odin` | The browser player: `odin_web_main` (called by `web/main.c`), `Web_Context` (Emscripten's malloc, a per-frame temp arena, console logger), `Player_StartWeb` (Emscripten's main loop drives `Application_Frame`) |
| `web/` | Files the web export links: `main.c` (C `main`), `odin_env.js` and `odin_env_pre.js` (what Odin's js runtime imports from "odin_env") |
| `paths.odin` | `JoinPath` ("/"-separated, works everywhere) |
| `globals.odin` | **Global scripts**: scripts listed in project.xml (`<global>`), one instance per run, before the scenes; `Global(T)`; ready / update / draw (screen space, `hidden`) / sceneChanged / destroy |
| `data.odin` | **Data resources**: `Data_Register(T)`, `.data.json` files (`ParseDataResource` / `FormatDataResource`), `Data(T, asset)` (loaded once, shared) |
| `save.odin` | **Saves**: `Save_Game` / `Load_Game` / `Save_Exists` / `Save_Delete`: every global's fields as JSON (`save:"-"` skips one); desktop files in SDL's pref path, web localStorage; `--dev` runs save apart |
| `assets.odin` | **Typed asset handles**: `TextureAsset`, `SoundAsset`, `FontAsset`, `DataAsset`, `ComponentAsset`; `Asset_Texture` / `Asset_Sound` / `Asset_Font`, `Game_PlaySound` (handle or path) |
| `globals_test.odin` | Tests: globals' lifecycle and reset per run, data resources, saves (nested structs, arrays, maps, enums, `save:"-"`, older saves) |
| `physics.odin` | **Physics world** (Box2D, one per scene): settings and units, `Physics_Sync` / `Physics_Update` (fixed steps, pose sync, ray casts), `Physics_RayCast`, `CharacterMover_Move` |
| `physics_events.odin` | Contact and Area events per body pair (counted over shape pairs), `PhysicsBody_GetAreas` / `IsInArea` / `GetContacts` / `IsTouching`, exits when a body is removed, the world's shape table |
| `physics_joints.odin` | `Joint` nodes: Revolute, Distance, Prismatic, Weld, Wheel (anchor = the node; body A = its body or the world; body B by name), limits, motors, springs |
| `physics_debug.odin` | **Smoothing** (`Node_GetRenderLocalTransform` / `Node_GetRenderWorldTransform`) and debug drawing (`Physics_DrawDebug`, `Physics_SetDebugDraw`) |
| `physics_nodes.odin` | Physics nodes: `PhysicsBody` (layers, surface, `onCollisionEnter/Exit`), `StaticBody`, `DynamicBody` (+ velocity, impulse, force), `CharacterMover`, `Area` (+ `Area_GetOverlaps`), `CollisionShape`, `RayCast`, `Collision` |
| `box2d/` | Box2D 3.1.1 bindings: a copy of Odin's `vendor:box2d` linking our own `box2d/lib/` (why: its doc comment). `lib/` is built, not committed |
| `third_party/box2d`, `tools/build_box2d.sh` | Box2D's sources (submodule) and the script that compiles them (no CMake) |
| `physics_test.odin`, `physics2_test.odin` | Tests: falling and landing, events, layers, Areas, ray casts, the mover (landing, walls, pushing), shapes with baked transforms, removal, scene files, debug drawing; smoothing at 144 fps, areas seen from bodies, one event per body pair, exits on removal, every joint kind |
| `lifecycle_test.odin` | Tests: nodes made, added (twice, late, during onEnter), found, removed (queued, parent and child together, twice, unknown, by exit handlers); scene destroy order and ownership; the camera's removal; cross-scene parenting refused; Scene_Clear; listeners changing during notify; Timer, Ticker; game switch and teardown |
| `core_test.odin` | Tests: visibility in the tree, screen positions (camera, screen layers), drawing through a view (layer order, screen layers, position-only nodes, draw state reset), game scaling and window-to-game coordinates on a software renderer, the application's game swap |
| `animation_test.odin` | Tests: AnimationPlayer frames in each play mode, looping and ending, speed, pause / resume / stop / seek, events, restart, names; Camera2D follow modes, dead zone, speed cap, bounds, timed pans, screen / world round trips |
| `component_test.odin` | Tests: component files, instances in scene files (names, transforms, under parents, nested), `Scene_Instantiate` |
| `input.odin` | **Input**: keyboard, mouse and gamepad state (`Input_IsKeyPressed`, `Input_IsMouseButtonJustPressed`, `Input_GetMousePosition`, `Input_GetGamepadAxis`...) through the engine's own `Key`, `MouseButton`, `GamepadButton`, `GamepadAxis`; **actions** like Godot's input map (`Input_IsActionPressed` / `JustPressed` / `JustReleased`, `Input_GetActionStrength`, `Input_GetAxis`, `Input_GetVector`); bindings' text format; `Game.input`, updated first in `Game_Update` |
| `input_test.odin` | Tests: key, mouse and wheel edges, focus loss, actions from keys, buttons and sticks (deadzones, strength, vectors), project file actions |
| `particles.odin` | **Particle emitters**: `ParticleEmitter` node (`CreateParticleEmitter`), `ParticleSettings` (every setting; tags describe them for editors: `ParticleSettings_Fields`), `ColorRamp` (stops, `ColorRamp_Evaluate` / `Sort` / `AddStop` / `RemoveStop`), Start / Stop / Clear, text format (`ParticleSettings_Get` / `Set`, `FormatParticleSettings`) |
| `particles_test.odin` | Tests: ramps, settings text round trip, cycles and bursts, world and local space, forces, collisions with the view, scene files, batched drawing (pixels) |
| `audio_nodes.odin` | **Sound nodes and mix buses**: `AudioPlayer` (a sound: volume, pitch, pan, loop, autostart), `AudioPlayer2D` (panned and faded by its position from the listener: the camera, else the game area's middle; `Audio_Positional`), `MusicPlayer` (streams a Music asset; fades, seek, position); `AudioSettings`; buses (`Game.buses`, Master first: `Audio_SetBuses` from project.xml, `Audio_AddBus`, `Audio_SetBusVolume` / `Pan` / `Mute`), `Audio_Output` (node × bus × Master, applied per track every frame) |
| `audio_meter.odin` | **Level meters** on SDL3_mixer's mix callbacks: `AudioMeter` (atomic peaks), `AudioMeter_AttachGroup` (a bus's group) / `AttachMixer` (the final stage: applies Master's gains, then meters), `Audio_GetBusLevel`, `AudioLevel_ToDecibels`; its own C-convention declarations of the two callback setters |
| `audio_test.odin` | Tests: bus output (volume, pan laws, mute, unknown bus), positional volume and pan, sound nodes and buses from scene files (no device needed) |
| `audio.odin` | SDL3_mixer setup (`Audio_Init`: no device means silence, not an error), loading, and `Game_PlaySound(game, path)` (paths relative to `game.projectDir`, cached). The same on desktop and web |
| `ldtk.odin` | **LDtk projects** (ldtk.io): `LDtk_Load` / `LDtk_Parse` into plain data (`LDtkProject`: worlds, levels, layers top-most first, tiles, IntGrid, entities and their `LDtkValue` fields, tilesets, layer/entity/enum definitions) in the project's own arena (`LDtk_Destroy`); lookups (`LDtk_FindLevel`, `LDtk_FindLayer`, `LDtk_IntGridAt`, `LDtk_FieldValue`), `LDtk_ValueText`, `LDtk_Dependencies` |
| `ldtk_nodes.odin` | **LDtkLevel nodes**: `LDtkLevelSettings` (scene files), `LDtkLevelNode` / `LDtkLevelView` / `LDtkTileLayer` (one batched RenderGeometry per layer) / `LDtkEntityNode`; entities as mapped components, `LDtk_RegisterEntity` spawners or rectangles, scripts named like them with their fields; merged IntGrid collision; `Game_LoadLDtk` / `Game_ForgetLDtk`, `LDtk_FindEntityNodes`, `LDtk_EntityOf`, `LDtk_IntGridAtPosition` |
| `ldtk_test.odin` | Tests: a hand-written project (one level in the file, one apart): every field kind, IntGrid, tiles' flips, definitions, paths outliving the frame; built: layer order, merged collision, the script's fields from LDtk, allLevels in a linear world, scene files |
| `pack.odin` | **The data pack**: a game's files appended to its own executable (`Pack_Append`; the footer's `ODINPAK1`), read back by `Pack_Open` at start (the project is then `PACK_ROOT`); `Pack_Bytes` / `Pack_Has`, a `Pack` value for tools and tests (`Pack_OpenFile`) |
| `pack_test.odin` | Tests: a pack appended to a file and read back by path |
| `sdl_static.odin` | Links the static SDL (tools/build_sdl_static.sh) when it's built: `SDL_STATIC`, `SDL_LINKED_STATICALLY` |
| `player/main.odin` | The **player** for projects without scripts: calls `Player_Main` (`Player_Run` with the command line; nothing in the browser). A project with scripts gets its own generated main that also imports its `scripts` package. Used by the editor's Play and, later, exports |
| `script_test.odin` | Tests: script registration, fields and tags, lifecycle on a node, bad values, `Scene_FindNode` paths, format v3 scripts |
| `project_format_test.odin`, `transform_test.odin` | Tests: parser and v1 migration; transform math, hierarchy, subtree removal, draw order/transform/tint/visibility, camera node |

## Rules that keep the engine correct

**The data pack** (pack.odin): a single-file export is the player with the project's files
appended (ELF and PE ignore trailing bytes; macOS games will keep theirs in the .app, since
appending breaks code signing). `Player_FindExportedProject` takes the pack first. Everything
that reads a project file goes through the platform layer, which looks in the pack first:
`Platform_ReadFile` / `Platform_FileExists` / `Platform_LoadTexture`, `Audio_Load` (sounds and
streamed music: `LoadAudio_IO` from memory), fonts (`OpenFontIO`). A file is read from the
executable the first time it's asked for and **kept for the program's life**: SDL keeps
streaming music and fonts from that memory. **New file loading must go through these** (or
`Pack_Bytes`), or packed games won't find the file. The web build stubs them (it preloads files).

**Renderer** (render_backend.odin): the window's SDL renderer comes from the project's
`renderer` (`Application_Setup`'s `backend`), or the player's `--renderer <name>`. It used to be
hard-coded to "opengl"; Auto lets SDL choose, which is OpenGL on Linux too, so Linux games draw
as before (Windows gets Direct3D 11, macOS Metal). A backend this SDL lacks or that fails to
start falls back to SDL's choice with a warning; the one in use is logged ("Renderer: vulkan").
The browser always uses WebGL. Checked on Linux: OpenGL, OpenGL ES 2, Vulkan, GPU and Software
draw shapes and SDL_ttf text alike (pixels read back), and the demo runs with each.

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
- `context.temp_allocator` is freed every frame (`Application_Frame`). Only use it for data that dies
  within the frame.
- A node arena's `Arena` struct lives inside its own memory: always destroy a **copy** (see
  `Node_Destroy`). Arenas are `MemoryArena` (platform layer): virtual memory on the desktop, a
  growing block arena on the heap in the browser.
- Contextless code (`@(init)`) gets its context from `Platform_DefaultContext`, never
  `runtime.default_context()`: in the browser Odin's default allocator would grow the wasm memory
  behind Emscripten's heap.

**Lifecycles (lifecycle_test.odin tests each):**
- A scene owns every node it made: in it, queued to be added, or made with
  `CreateNode(..., addToScene = false)` and not added yet (`Scene.detached`). Removing or
  destroying frees each one exactly once.
- `Scene_ProcessQueues`: removals first (by index: an exit handler may queue more), then
  additions in order (by index: an `onEnter` handler may make nodes, which join in the same pass).
  Adding a node twice, or to a scene it doesn't belong to, does nothing.
- Removal and `Scene_Destroy` send `onExit` parents first, then destroy children before parents
  (a `destroy` hook can still read its parent). Removing the scene's camera node (or its parent)
  sets `scene.camera` to nil.
- Nodes of different scenes can't be parent and child (`Node_SetParent` refuses): removing one
  would free the other's nodes behind its scene's back.
- `Scene_Clear` keeps the scene's settings and any procedures a game replaced.
- `Game_Destroy`: the playing scene gets `onExit`, every scene's nodes go (their scripts can still
  reach the globals), then the globals; `currentScene`, `nextScenePtr` and `scenes` are cleared.
  Strings the game owns live in its arena (`game.name` from the project).
- `EventSubject`: listeners may subscribe or unsubscribe during a notification (unsubscribing
  then marks the listener; the list is compacted after the outermost notification), and order
  is always subscription order.
- The test runner fails a test that logs at error level: wrap expected refusals with
  `context.logger = log.nil_logger()`.

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
- **A negative scale mirrors**: `DrawTexture` flips the texture when the draw transform's
  determinant is negative (`scale.x = -1` faces a sprite the other way), since
  `RenderTextureRotated` only takes a rotation.
- `Scene_DrawWithView(scene, renderer, view, ...)` draws through any view transform instead of the
  camera.
- **Camera shake** (`Camera2D_Shake`) is a screen-space offset in `Camera2D_ViewTransform` only:
  the camera node, following and bounds don't see it. Game_Update advances it with the real
  frame time, so it runs through a hitstop.
- **Scenes start fresh on every visit:** Game_LoadProject keeps each scene's file
  (`Game.sceneFiles`); entering a scene that has been played before (`Scene.played`) rebuilds it
  from its file (`Game_RebuildScene`: `Scene_Clear`, then `Scene_Build`), and switching to the
  current scene restarts it. Scenes made by code (no file) keep their nodes. Scripts holding
  pointers to nodes must drop them in their `destroy` hook.
- **Hitstop** (`Game_HitStop`, `Game.hitStop`): for that many real seconds Game_Update hands
  scenes and globals a delta of 0 (physics, animations, particles freeze; scripts still run and
  see input). The editor's viewport uses it with `positionOnlyScale` set to its zoom.
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
depend on it. `CreateNode` records the type (`node.type`, `Node_Is(node, T)`).

**Globals, data, saves** (globals.odin, data.odin, save.odin):
- `currentGame` (set by `Game_LoadProject`) is the game `Global`, `Data` and `Save_Game` use by
  default: there's one game per process. Globals and data live in the game's arena
  (`Game_GetAllocator`), freed by `Game_Destroy`.
- Order: `Globals_Start` (fields from project.xml) → scenes built → `Globals_Ready`; every frame
  `Globals_Update` before the scene, `Globals_Draw` after it (screen space).
- **What a save holds:** a global's state, not its settings. Fields that aren't exported are
  saved (unless `save:"-"`); exported fields are editor settings and aren't (unless `save:""`),
  so changing one in the editor reaches players who already have a save.
- Saves marshal each saved field with `core:encoding/json`, and load by unmarshalling a global's
  object into the whole struct (`ScriptInfo.pointerType`: `unmarshal_any` needs a pointer type,
  which can't be made at run time), so fields the save lacks keep their values.
- Asset handles are a struct with one string: `Script_SetField` writes them as strings.

**Physics** (physics.odin, physics_nodes.odin; their doc comments have the details):
- The engine API is in pixels, degrees and px/s; Box2D in meters (`pixelsPerMeter`, 100). Box2D's
  angle in the y-down world is the engine's clockwise rotation, in radians.
- A body's Box2D body is created by `Physics_Sync` (in `Scene_Update`, before scripts' `ready`)
  once its node is in the scene; its shapes come from the CollisionShape nodes under it (nearest
  body ancestor), with their transforms relative to the body **baked in**. Changing a shape in
  code needs `PhysicsBody_RebuildShapes`.
- Who moves what: dynamic bodies move their nodes (after each step); a node of a static or
  dynamic body moved in code teleports its body (waking what rests on it); Areas and
  CharacterMovers are kinematic: before each step they're put back at their last pose with the
  velocity that reaches the node's pose, so they push what's in the way.
- `CharacterMover_Move` uses Box2D's mover API. Two Box2D facts it depends on: `World_CastMover`
  ignores shapes it starts inside (so the mover's own body doesn't block it), and planes count as
  hits only when touching, while the sweep stops just short. So the contacts (floor flags,
  velocity clipping, events) come from one more `CollideMover` with the capsule `MOVER_SKIN` px
  bigger, and the velocity is clipped by hand: `b2ClipVector` skips planes with `push == 0`.
- Box2D makes no contacts between kinematic and static bodies: mover collision events come from
  its move's contact planes (`moverContacts`).
- **Events are per body pair**: each body counts its contacts per other body (`contacts`, and
  `areas`); enter on the first shape pair, exit on the last. Box2D reports the ends of destroyed
  shapes' contacts a step later with stale ids, so events are looked up in the world's `shapes`
  table (body and node per shape id), never through the ids: rebuilt shapes stay mapped to their
  living body for two steps; a removed body's shapes are dropped after `physicsForgetBody` sent
  everyone their exits. Scene_ProcessQueues walks its remove queue by index: those exits may
  queue more removals.
- **Smoothing** (Box2D's advice: fixed step + "Fix Your Timestep!"): only drawing is interpolated.
  `node.position` stays the simulated pose; `drawOrder`, `Camera2D_ViewTransform` and the debug
  drawing use `Node_GetRenderWorldTransform`, which blends dynamic bodies between
  `previousPosition` (set before each step, after code moved nodes, so teleports don't streak)
  and the current pose by `world.alpha`. New code that draws a node at its position should use
  the render transform too.
- **Joints** are created in `Physics_Sync` once both bodies exist, from their pose then; Box2D
  destroys a joint with either body. Units: degrees and px in, radians and meters to Box2D;
  torque / ppm², force / ppm.
- Debug shapes: the project's `physicsDebug` is a development setting (the editor's exports write
  it off); the player's `--physics-debug` forces it on, and `--dev` (the editor's Play, never
  exports) sets `Game.devKeys`: F9 (`DEV_KEY_PHYSICS_DEBUG`) toggles the shapes while it runs.
- `scene.physicsPaused` stops stepping (bodies stay queryable); the editor preview sets it.
  CollisionShape has a `getBounds` (its extent), so editors can pick and outline it.
- The web build links `box2d/lib/box2d_web.o`: one relocatable object, because Odin keeps plain C
  symbol names on wasm only for `.o` foreign imports (an `.a` gets `lib/x.a..b2Foo` names).

**Components** (project_loader.odin, project_format.odin's `ParseComponent`):
- A component is a node tree in its own file (`<component>` root, the first node is the root),
  an asset of kind "Component". A `Component` node in a scene is an instance: `buildNodes` builds
  the component's nodes in its place, and the root takes the instance's name, position,
  rotation, scale, layer and visibility (replacing the root's own transform). The instance's
  children in the scene file go under the root; its script, if any, only when the root has none.
- `Game_LoadComponent` reads each file once (`Game.components`, in the game's arena); editors
  fill that map with their in-memory components before building, so unsaved edits show.
- `Scene_Instantiate(scene, COMPONENT_X, parent, position)` adds one from code (scripts attach,
  `ready` next update). Components nest, at most MAX_COMPONENT_DEPTH deep (one holding itself
  stops there with an error).

**Input** (input.odin):
- `Input_Update` runs first in `Game_Update` with the frame's SDL events: it clears last frame's
  just-pressed/released, applies the events, opens gamepads as they're added (numbered 0.. in
  connection order; device -1 = any), and works out every action. Everything after (globals,
  scenes, scripts) sees the same state. The raw `[]sdl.Event` still reach `update` hooks.
- Enum values are SDL's (`Key` is a scancode, `#sparse`), so converting is a cast; their names are
  the file format's and the editor's.
- An action's strength is the strongest binding: 1 for keys and buttons, a stick's travel past
  the deadzone rescaled to 0..1. The wheel's directions are buttons pressed for one frame.
- Losing window focus releases every key and mouse button.

**Sound** (audio_nodes.odin; its doc comment has the details):
- Each player owns one SDL3_mixer track (made on first use, so no device means no track and
  silence). Sounds come from the resource manager (decoded once, shared); music is loaded per node
  with predecode off (streamed) and freed with the node.
- Output is recomputed every frame (`applyOutput`): gain = node volume × bus volume × Master volume
  (0 when either is muted), stereo gains from the balance law `L = min(1, 1 - p)`, `R = min(1, 1 + p)`
  multiplied across the node's pan, a 2D player's positional pan, its bus and Master. Pitch is the
  track's frequency ratio (speed and pitch together).
- A bus also has a `mix.Group` its players' tracks join: that's where bus effects go later. Its
  post-mix callback meters it (audio_meter.odin).
- **Master's gain and pan go on the final mix** (the mixer's post-mix callback, gains set every
  frame by `Audio_Update`), not on the tracks: tracks carry player × bus (`Audio_Output(...,
  master = false)`), so a bus's meter reads it after its fader and Master's meter the output.
  `Game_PlaySound`'s tracks (no bus) get Master too.
- **Odin's `vendor:sdl3/mixer` declares the mix callback types without `"c"`**: passing a
  `proc "c"` doesn't compile and an Odin proc would be called from C without a context.
  audio_meter.odin declares `MIX_SetGroupPostMixCallback` / `MIX_SetPostMixCallback` again with C
  callbacks, from the same import path (so the web's `system:SDL3_mixer..` aliases match). The
  callbacks run on the audio thread: contextless, atomics only.
- A scene switch stops the old scene's players (`Audio_SceneExited`) and clears `started`, so
  autostart players start again when the scene is back. Players unregister in their destroy.

**LDtk** (ldtk.odin, ldtk_nodes.odin; their doc comments have the details):
- A project is parsed from LDtk's JSON (`core:encoding/json` into a scratch arena, copied into
  the project's arena, the tree dropped). **Every string and path in it is the project's**:
  `JoinPath` is temp allocated, so joined paths are cloned (they once died at the end of the
  frame and textures loaded from garbage). The struct itself is on the heap whatever the
  caller's allocator (`LDtk_Destroy` frees it there).
- Separate level files (`.ldtkl`) are read when a level's `layerInstances` is null. Without
  Multi-worlds the root is one world.
- An LDtkLevel node builds like a component instance: children made at build time, not in the
  scene file; `buildNodes` (package-private for this) builds mapped components. Projects are
  cached per game (`Game.ldtk`, `Game_LoadLDtk`, keyed by path; the build passes its project
  folder, since editors' preview games have none): nodes point into that data, so
  `Game_ForgetLDtk` only after the scene that used it is gone. Game_Destroy forgets them all.
- LDtk lists layers top-most first: they're built in reverse. Entity `px` is the pivot.
- Tile layers draw as one `RenderGeometry` through the draw transform and tint; tilesets get
  nearest filtering unless `smoothTiles`. IntGrid layers without tiles draw their values' colors.
- Script fields from LDtk fields: names match ignoring case and underscores; points become the
  pixel middle of their cell; arrays, tiles and references are left to code (`LDtk_EntityOf`).
- **Parallax** is LDtk's (its Camera.hx): offset camera-in-level × factor (− half the layer ×
  factor without scaling), scale 1 − factor.x; tile layers apply it while drawing (exact), entity
  groups in their update. Off when built without scripts (the editor). **Culling** maps the
  screen's corners back through the draw transform and the parallax.
- **Entity tiles** follow LDtk's EntityRender.hx per tile render mode (the tile's pivot on the
  entity's position); shapes only in tools. LDtk's internal icons (FinalBossBlues' paid pack)
  can't ship: a copy beside the .ldtk (`finalbossblues-icons_full_16.png`) is used.
- **Removed entities** (a collected coin) leave `LDtkLevelNode.spawned` through an `onExit`
  listener, so lookups (`LDtk_FindEntityNodes`, `LDtk_EntityRefNode`) never return a freed node.
- **Tile vertices are on whole pixels**: SDL's software renderer (the editor's viewport) draws
  axis-aligned quads as rectangles rounded one by one, which left 1 px cracks between tiles at
  some camera positions.
- **In SDL's software renderer every tile triangle has its own vertices** (`isSoftwareRenderer`):
  SDL turns two triangles sharing an edge into a scaled rectangle copy of the RLE-encoded
  tileset, and after zooming at a corner of the editor's viewport those copies stopped drawing
  for good (the ground vanished; keeping them away from the edges crashed the editor once).
  Triangles are correct but slower (a whole 200 x 30 level at 1000 x 600: ~38 ms against 23).
  GPU renderers keep shared vertices.
- **Hot reload** (`LDtk_WatchFiles`, dev runs only, from Game_Update): reloaded projects replace
  the game's; the old ones are kept to the end (`Game.ldtkRetired`: entity nodes point into
  them). Built nodes are updated in place, not rebuilt: tile layers, colors, backgrounds and the
  collision body; entities keep running, so scripts' pointers stay valid. A node keeps its
  settings (`LDtkLevelNode.settings`, `collision`) to do it.
- Checked against all 14 of LDtk's sample projects (parsed; the platformer rendered: the same
  picture as LDtk's), not committed: their art has its own licenses.

**Particles** (particles.odin; its doc comment has the details):
- A `ParticleEmitter`'s `settings` is a plain value (no pointers): scene files store it as a
  `<particles>` element of the fields that differ from `DEFAULT_PARTICLE_SETTINGS`, by reflection
  (`FormatParticleSettings`, `ParticleSettings_Set`), so **a new setting needs only the field**
  (with its tags and a default), plus a case in `ParticleSettings_Get` / `Set` for a new field type.
  Field order is the editor's order; `group` starts a group.
- Each update moves the live particles first, then emits (new ones start at age 0), so those
  emitted at the start of a cycle die exactly as the next cycle starts.
- Particles live in the world (positions there, emission turned by the node's world rotation) or,
  with `localSpace`, in the node's space. Drawing is batched: one `RenderGeometry` for all shapes
  (another for the texture), through `view × inverse(render world)` for world-space particles.
- `settings.emitting` is how an emitter starts; `emitter.emitting` is whether it's emitting now (a
  non-continuous one stops after a cycle).

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

## CI and releases (`.github/workflows/build.yml`)

Pushing a `v*` tag builds and tests on Linux x86_64 (ubuntu-24.04), Windows x86_64 (windows-2022)
and macOS arm64 (macos-15), then publishes a GitHub release of the three archives if all
pass (tags with a `-`, like `v0.1.0-dev.1`, make pre-releases). The README's badge shows the
latest run. The workspace's `ci-fix` skill (`.claude/skills/ci-fix/`) watches a run, finds why it
failed, fixes it and builds again with the next tag.
- `tools/ci/setup.sh` installs Odin (`dev-2026-10` from its release on every OS; not Homebrew's,
  which lags behind) and SDL3 (built from source on Linux, cached; Homebrew on macOS; Odin's
  own files on Windows), and builds Odin's STB libraries. The editor's workflow runs it too.
- `tools/build_box2d.sh` builds Box2D for each (Windows: clang targeting MSVC, `llvm-lib`).
- `tools/ci/package_player.sh` packs the player, with its SDL3 libraries unless SDL is static; a
  static player is checked with `ldd` (no SDL library may show up).
- **Odin's Windows `process_wait` always sets `Process_State.success`**: check `exit_code`.

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

## Web build (js_wasm32 + Emscripten)

The editor's Web export builds the player for `js_wasm32` with `-build-mode:obj` and links it with
Emscripten (the editor pins emsdk as a submodule). The link line is in `player_web.odin`'s doc
comment. What was needed, and why:
- Odin's `vendor:sdl3` and `vendor:sdl3/ttf` link Emscripten's SDL3 and SDL3_ttf ports on wasm
  (`-sUSE_SDL=3 -sUSE_SDL_TTF=3`). **There is no SDL3_image port**, so the web loads images with
  SDL's own `SDL_LoadPNG` / `SDL_LoadBMP` (PNG and BMP only).
- **Audio:** there's no SDL3_mixer port either, so the editor builds SDL3_mixer from source with
  Emscripten (its `tools/build_web_mixer.sh`, the `third_party/SDL_mixer` submodule at the native
  version, 3.2.4) with the decoders it carries (WAV, OGG via stb_vorbis, MP3 via dr_mp3, FLAC via
  dr_flac, AIFF, AU, VOC), and links `libSDL3_mixer.a`. **Odin's `vendor:sdl3/mixer` has no wasm
  branch:** it imports from the module "system:SDL3_mixer", so the object asks for symbols literally
  named `system:SDL3_mixer..MIX_Init`. The build script compiles SDL_mixer.c with an alias under that
  name for every public function, so the game links to the library directly and scripts can use
  all of SDL3_mixer. SDL resumes the browser's AudioContext after the first click or key press
  (autoplay rule); until then the game runs silently.
- `js_wasm32` (not `freestanding`), because `core:log` and `core:fmt` need it. Its runtime imports
  `write`, `rand_bytes` and some math from a JS module "odin_env": `web/odin_env.js` defines them
  as an Emscripten library, and `web/odin_env_pre.js` passes Emscripten's imports under that name.
- Memory comes from Emscripten's `malloc` (`Web_Context`; it honors alignments above 8 through
  `aligned_alloc`, which Odin's maps need), and the temp allocator is an arena on it.
- The browser can't block, so `Application_Run` is `for app.running do Application_Frame(app)`
  and the web calls `Application_Frame` from `emscripten_set_main_loop`.
- `SetRenderVSync` must come after the main loop exists (`Player_StartWeb`); before it, the first
  `RenderPresent` blocks forever. The renderer is SDL's choice (WebGL) instead of "opengl".
- Test in headless Chromium in **real time** (`timeout 8 chromium --headless=new
  --use-angle=swiftshader --enable-unsafe-swiftshader --enable-logging=stderr <url>`, served by
  `python3 -m http.server`), reading `CONSOLE` lines. `--virtual-time-budget` stops delivering
  animation frames after a few. Rendering can be checked from inside the page by drawing the canvas
  into a 2D canvas and counting colors (a `--post-js`); never by screenshots.

## Known gaps

- Asset paths are relative to the project folder given to the player (or found next to an
  exported executable).
- **Scene loading limits.** These are documented in `project_format.odin`, and the editor's
  writer must stay in sync with it.
  - Menus and labels in a scene with a camera are drawn through it, because scene files can't set
    `screenLayers` yet.
  - Sound nodes load their sound when the scene is built (`Scene_Build` with scripts attached; the
    editor's viewport doesn't); `Game_PlaySound` still plays any sound from code, loaded on first use.
- **Format version 12** adds `LDtkLevel` nodes (`ldtk`, `level`, `allLevels`, `intGridCollision`,
  `collisionValues`, `spawnEntities`, `background`, `smoothTiles`, `<entity name component/>`)
  and assets of kind "LDtk".
- **Format version 11** adds the project's `renderer` (a `RenderBackend`; Auto when absent).
- **Format version 10** adds sound nodes (`AudioPlayer`, `AudioPlayer2D`, `MusicPlayer`: `sound`,
  `bus`, `volume`, `pitch`, `pan`, `loop`, `autostart`, `maxDistance`, `attenuation`, `fadeIn`,
  `fadeOut`), `<bus>` elements in project.xml and assets of kind "Music".
- **Format version 9** adds components (`.component.xml` files, assets of kind "Component") and
  `Component` nodes.
- **Format version 8** adds input actions (`<action>` in project.xml).
- **Format version 7** adds AnimatedSprite `<animation>` elements (named cell ranges), `margin`,
  `spacing` and `autoplay`; without them the node plays one "default" animation as before.
- **Format version 6** adds ParticleEmitter nodes and their `<particles>` element.
- **Format version 5** adds `<global>` elements to project.xml and assets of kind "Data".
- **Format version 4** adds the physics node kinds and the project's physics settings.
- **Format version 3** adds `<script>` elements; version 2 stores local positions, and version 1
  files are migrated when parsed (`migrateSceneFromV1`). Bump `PROJECT_FORMAT_VERSION` and add a migration for any incompatible
  format change.
- `RenderLayer` has 8 fixed layers. The editor will probably want named layers.

## Performance (measured: `odin run bench -o:speed`)

`bench/main.odin` times the per-frame costs (each scenario's median; `-- <names>` for some).
Measure before and after any performance change and record it here. Baseline (2026-10-20, this
machine: Intel UHD 620 laptop, -o:speed):

| Scenario | Baseline | Now |
|---|---|---|
| make + remove a node | 13 µs per node | 0.6 µs (heap-block node arenas, 4 KB; fast random ids) |
| remove 500 of 5500 nodes in one frame | 17.1 ms | 0.4-0.7 ms (one batch: lists compacted once) |
| Scene_GetNode / Scene_FindNode (5500 nodes) | 18.6 µs / 285 µs per lookup | 0.014 µs (id index) / 31 µs |
| update / draw overhead, 20000 nodes | 0.75 ms / 6.7 ms | 0.46 ms / 3.2 ms (one walk into per-layer buckets; no trig for unrotated nodes) |
| 1000 world transforms at depth 64 | 0.69 ms | 0.53 ms |
| 1000 subscribes / 100 notifies of 1000 listeners | 0.84 ms / 0.26 ms | 0.026 ms / 0.33 ms |
| particles, 4 emitters x 1000: update / draw (SDL) | 0.09 ms / 2.0 ms; colliding x 500: 2.1 ms | same |
| physics, 500 static + 500 dynamic bodies, a frame | 0.37 ms | 0.29 ms |
| LDtk forest, software renderer: a screenful / the whole level | 101 ms / 19 ms (SDL's pixel work) | same |

Measured and left alone (not worth it at these numbers): particles' `#soa` layout and update
(0.1 ms for 4000 particles), physics multithreading (0.3 ms for 1000 bodies), EventSubject's
proc fields (notify is cheap), Node struct reordering (update over 20000 nodes is 0.46 ms).
Worth doing later if games need it: particle collisions on a grid (O(n²) now: 2 ms for 4 x 500),
LDtk culling by grid for very large levels (it tests every tile; fine for the forest), a faster
correct software path for tiles (the triangles' fill is SDL's).

## Verifying work

- `odin check . -no-entry-point -vet-unused` must pass.
- Behavior is tested with throwaway headless programs: a hidden SDL window, the engine imported via
  `-collection:proj=<workspace>`, synthetic `sdl.Event`s, `sdl.RenderReadPixels` for pixel checks, and
  `mem.Tracking_Allocator` for leaks. Delete them afterwards. Logic without SDL goes in `odin test`.
- Then run the asteroids sample from the workspace root to make sure nothing regressed.
