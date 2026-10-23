package crossfire

import "core:log"
import "core:math"
import "core:strings"
import sdl "vendor:sdl3"

/*
Moving between scenes: **transitions** (a fade or a wipe over the switch), **scenes over
scenes** (a pause menu or an inventory opened over the level, which waits under it) and a
**loading screen** (a scene shown while the next one's images and sounds load).

- **Transitions** (`Transition`, `Game_ChangeScene`): the screen is covered (`Fade` to a color, a
  `Wipe` from a side, a closing `Circle`) over the first half of `duration`, the scene changes
  under the cover, and it's uncovered over the second half. The project's transition
  (project.xml's `transition`, `transitionTime`, `transitionColor`; `Game.flow.transition`) is used
  by Menu and Button actions `scene:<Name>` and by `Game_ChangeScene` without one.
- **Scenes over scenes** (`Game_PushScene`, `Game_PopScene`; actions `push:<Name>` and `pop`):
  the pushed scene is drawn over the others and updated; with `pauseBelow` (the default) the
  scenes under it don't update (they still draw), so a pause menu freezes the level. A change of
  scene closes them all. Like a scene that's entered, a pushed scene starts fresh every time
  it's opened (built again from its file once it has been open: its scripts' `ready` runs
  again), and its controls ignore the frame's presses: the press that opened it doesn't also
  press the button focused in it.
- **The loading screen** (project.xml's `loadingScene`; `Game.flow.loadingScene`): with one, the
  game builds only its start scene and the loading scene when it starts; any other scene is built
  when it's entered, after the loading scene has been shown while its images and sounds load (a
  few a frame: `LOADING_PER_FRAME`, at least `LOADING_MIN_SECONDS` on screen).
  `Game_LoadingProgress` (0 to 1) feeds its progress bar (a ProgressBar whose
  `showLoading` is set does it by itself).
*/

// What covers the screen between two scenes
TransitionKind :: enum {
	// None: the scene changes at once
	None,
	// The screen fades to `color` and back
	Fade,
	// `color` sweeps across from a side
	Wipe_Left,
	Wipe_Right,
	Wipe_Up,
	Wipe_Down,
	// A circle of `color` closes on the middle, then opens
	Circle,
}

// How a scene change looks (`Game_ChangeScene`)
Transition :: struct {
	kind: TransitionKind,
	// Seconds, covering and uncovering together
	duration: f32,
	// The cover's color
	color: sdl.Color,
}

// The transition when the project sets none: a black fade of half a second, off
DEFAULT_TRANSITION :: Transition{kind = .None, duration = 0.5, color = {0, 0, 0, 255}}

// Images and sounds a loading screen loads each frame
LOADING_PER_FRAME :: 4

// The least time a loading screen shows (it doesn't flash by)
LOADING_MIN_SECONDS :: 0.4

// Where a scene change is (`SceneFlow.phase`)
FlowPhase :: enum {
	Idle,
	// Covering the old scene
	Covering,
	// Uncovering the loading scene
	Showing_Loading,
	// Loading the target's images and sounds under the loading scene
	Loading,
	// Covering the loading scene
	Leaving_Loading,
	// Uncovering the new scene
	Uncovering,
}

// A scene over the game's scene (`Game_PushScene`)
SceneOverlay :: struct {
	scene: ^Scene,
	// The scenes under it don't update while it's there
	pauseBelow: bool,
}

// A game's scene changes, overlays and loading (`Game.flow`)
SceneFlow :: struct {
	// The project's transition (used when a change names none)
	transition: Transition,
	// The project's loading scene ("": none)
	loadingScene: string,
	// The change under way
	phase: FlowPhase,
	active: Transition,
	time: f32,
	// The scene being changed to (game arena)
	target: string,
	// Its images and sounds still to load, how many there were, and seconds the loading scene showed
	toLoad: [dynamic]string,
	loadTotal: int,
	loadingTime: f32,
	// Scenes over the game's scene, bottom first
	overlays: [dynamic]SceneOverlay,
}

/*
Changes scene with a transition: the screen is covered, the scene changes, it's uncovered (and
with a loading scene, that one shows while the new scene loads).

Inputs:
- game: The game
- name: The scene
- transition: How (nil: the project's; `{kind = .None}`: at once)

Returns:
- false when there's no such scene

Example:
	e.Game_ChangeScene(game, "Level2", e.Transition{kind = .Fade, duration = 0.6, color = {0, 0, 0, 255}})
*/
Game_ChangeScene :: proc(game: ^Game, name: SceneName, transition: Maybe(Transition) = nil) -> bool {
	if name not_in game.scenes {
		log.warnf("No scene named '%s'", name)
		return false
	}
	t := transition.? or_else game.flow.transition
	flow := &game.flow
	delete(flow.target)
	flow.target = strings.clone(name)
	flow.active = t
	flow.time = 0
	loading := needsLoading(game, name)
	if t.kind == .None || t.duration <= 0 {
		if loading {
			// The loading scene at once, then the target when it's loaded
			enterScene(game, flow.loadingScene)
			startLoading(game)
			flow.phase = .Loading
			return true
		}
		flow.phase = .Idle
		enterScene(game, name)
		return true
	}
	flow.phase = .Covering
	return true
}

/*
Opens a scene over the playing one (a pause menu, an inventory): drawn over it and updated; with
`pauseBelow` the scenes under it wait (they still draw). It starts fresh (built again if it was
open before), and its controls don't take this frame's presses.

Inputs:
- game: The game
- name: The scene
- pauseBelow: The scenes under it don't update while it's open

Returns:
- false when there's no such scene

Example:
	e.Game_PushScene(game, "PauseMenu")
*/
Game_PushScene :: proc(game: ^Game, name: SceneName, pauseBelow := true) -> bool {
	scene, exists := game.scenes[name]
	if !exists {
		log.warnf("No scene named '%s'", name)
		return false
	}
	for o in game.flow.overlays do if o.scene == scene do return false
	// Fresh on every push, as on every visit: pushed before, it's built again (its scripts ready again)
	if scene.played && !scene.unbuilt do Game_RebuildScene(game, scene)
	prepareScene(game, scene)
	scene.played = true
	// Its controls don't take the press that opened it (the overlays update after the scene
	// that pushed it, the same frame): a focused button would be pressed by it
	scene.ui.opened = game.input.frame
	append(&game.flow.overlays, SceneOverlay{scene, pauseBelow})
	scene.onEnter->notify(scene, nil)
	return true
}

/*
Closes the scene on top (the last `Game_PushScene`'s).

Inputs:
- game: The game

Returns:
- false when no scene is open over the game's
*/
Game_PopScene :: proc(game: ^Game) -> bool {
	if len(game.flow.overlays) == 0 do return false
	top := pop(&game.flow.overlays)
	top.scene.onExit->notify(top.scene, nil)
	Audio_SceneExited(game, top.scene)
	return true
}

/*
The scene on top: the last one pushed, else the game's.
*/
Game_TopScene :: proc(game: ^Game) -> ^Scene {
	if n := len(game.flow.overlays); n > 0 do return game.flow.overlays[n - 1].scene
	return game.currentScene
}

/*
How far the loading screen has got: 0 to 1 (1 when nothing is loading).
*/
Game_LoadingProgress :: proc(game: ^Game) -> f32 {
	flow := &game.flow
	if flow.loadTotal == 0 || (flow.phase != .Loading && flow.phase != .Showing_Loading) do return 1
	return f32(flow.loadTotal - len(flow.toLoad)) / f32(flow.loadTotal)
}

/*
Whether a scene change or an uncovering is under way.
*/
Game_IsChangingScene :: proc(game: ^Game) -> bool {
	return game.flow.phase != .Idle
}

/*
Runs a scene action string (Menu items', Buttons'): "scene:<Name>" (with the project's
transition), "push:<Name>", "pop", "quit".

Inputs:
- game: The game
- action: The action

Returns:
- false when it isn't one of these (logged by the caller)
*/
Game_RunAction :: proc(game: ^Game, action: string) -> bool {
	switch {
	case action == "quit":
		game.shouldQuit = true
	case action == "pop":
		Game_PopScene(game)
	case strings.has_prefix(action, "scene:"):
		Game_ChangeScene(game, action[len("scene:"):])
	case strings.has_prefix(action, "push:"):
		Game_PushScene(game, action[len("push:"):])
	case:
		return false
	}
	return true
}

// INTERNAL

// The scene change's progress, each update (Game_Update, before the scenes)
@(private)
SceneFlow_Update :: proc(game: ^Game, deltaTime: f64) {
	flow := &game.flow
	half := max(flow.active.duration * 0.5, 0.001)
	dt := f32(deltaTime)
	switch flow.phase {
	case .Idle:
	case .Covering:
		flow.time += dt
		if flow.time < half do break
		flow.time = 0
		if needsLoading(game, flow.target) {
			enterScene(game, flow.loadingScene)
			startLoading(game)
			flow.phase = .Showing_Loading
		} else {
			enterScene(game, flow.target)
			flow.phase = .Uncovering
		}
	case .Showing_Loading:
		flow.time += dt
		loadSome(game)
		if flow.time >= half {
			flow.time = 0
			flow.phase = .Loading
		}
	case .Loading:
		flow.loadingTime += dt
		loadSome(game)
		if len(flow.toLoad) > 0 || flow.loadingTime < LOADING_MIN_SECONDS do break
		if flow.active.kind == .None || flow.active.duration <= 0 {
			enterScene(game, flow.target)
			flow.phase = .Idle
		} else {
			flow.time = 0
			flow.phase = .Leaving_Loading
		}
	case .Leaving_Loading:
		flow.time += dt
		if flow.time < half do break
		flow.time = 0
		enterScene(game, flow.target)
		flow.phase = .Uncovering
	case .Uncovering:
		flow.time += dt
		if flow.time >= half {
			flow.time = 0
			flow.phase = .Idle
		}
	}
}

// How much of the screen the transition covers now: 0 (none) to 1
@(private)
SceneFlow_Cover :: proc(game: ^Game) -> f32 {
	flow := &game.flow
	half := max(flow.active.duration * 0.5, 0.001)
	t := clamp(flow.time / half, 0, 1)
	switch flow.phase {
	case .Covering, .Leaving_Loading: return t
	case .Showing_Loading, .Uncovering: return 1 - t
	case .Idle, .Loading:
	}
	return 0
}

// Draws the transition's cover over everything (Game_Draw)
@(private)
SceneFlow_Draw :: proc(game: ^Game) {
	cover := SceneFlow_Cover(game)
	if cover <= 0 || game.renderer == nil do return
	SetDrawState(TRANSFORM2D_IDENTITY)
	r := game.renderer
	c := game.flow.active.color
	w, h := game.size.x, game.size.y
	sdl.SetRenderDrawBlendMode(r, sdl.BLENDMODE_BLEND)
	#partial switch game.flow.active.kind {
	case .Fade:
		rect := sdl.FRect{0, 0, w, h}
		DrawRectangle(r, &rect, {c.r, c.g, c.b, u8(f32(c.a) * cover)})
	case .Wipe_Left:
		rect := sdl.FRect{w * (1 - cover), 0, w * cover, h}
		DrawRectangle(r, &rect, c)
	case .Wipe_Right:
		rect := sdl.FRect{0, 0, w * cover, h}
		DrawRectangle(r, &rect, c)
	case .Wipe_Up:
		rect := sdl.FRect{0, h * (1 - cover), w, h * cover}
		DrawRectangle(r, &rect, c)
	case .Wipe_Down:
		rect := sdl.FRect{0, 0, w, h * cover}
		DrawRectangle(r, &rect, c)
	case .Circle:
		// The color everywhere outside a circle shrinking to nothing: the circle's radius from
		// the corners' distance down to 0, drawn as a ring of quads
		full := math.sqrt(w * w + h * h) * 0.5
		radius := full * (1 - cover)
		center := [2]f32{w * 0.5, h * 0.5}
		SEGMENTS :: 48
		vertices := make([dynamic]sdl.Vertex, 0, SEGMENTS * 2, context.temp_allocator)
		indices := make([dynamic]i32, 0, SEGMENTS * 6, context.temp_allocator)
		color := sdl.FColor{f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
		for i in 0..<SEGMENTS {
			a := f32(i) * math.TAU / SEGMENTS
			d := [2]f32{math.cos(a), math.sin(a)}
			inner := center + d * radius
			outer := center + d * full * 1.5
			append(&vertices, sdl.Vertex{position = {inner.x, inner.y}, color = color}, sdl.Vertex{position = {outer.x, outer.y}, color = color})
		}
		for i in 0..<i32(SEGMENTS) {
			a, b := i * 2, ((i + 1) % SEGMENTS) * 2
			append(&indices, a, a + 1, b + 1, a, b + 1, b)
		}
		sdl.RenderGeometry(r, nil, raw_data(vertices), i32(len(vertices)), raw_data(indices), i32(len(indices)))
	}
}

// Which scenes update this frame: the game's, unless an overlay above pauses it, then each
// overlay unless one above it pauses it (Game_Update)
@(private)
SceneFlow_Updating :: proc(game: ^Game) -> (base: bool, from: int) {
	from = 0
	for o, i in game.flow.overlays do if o.pauseBelow do from = i
	if len(game.flow.overlays) == 0 do return true, 0
	blocked := false
	for o in game.flow.overlays do if o.pauseBelow do blocked = true
	return !blocked, from
}

// Frees the flow's memory (Game_Destroy)
@(private)
SceneFlow_Destroy :: proc(game: ^Game) {
	flow := &game.flow
	delete(flow.target)
	for p in flow.toLoad do delete(p)
	delete(flow.toLoad)
	delete(flow.overlays)
	delete(flow.loadingScene)
	flow^ = {}
}

// The game's scene becomes `name` (overlays closed), on the next update's switch
@(private="file")
enterScene :: proc(game: ^Game, name: string) {
	for len(game.flow.overlays) > 0 do Game_PopScene(game)
	if scene, ok := game.scenes[name]; ok do prepareScene(game, scene)
	Game_SwitchScene(game, name)
}

// A scene that's entered is built when it hasn't been (a project with a loading scene builds
// them when they're entered); the switch rebuilds scenes played before
@(private="file")
prepareScene :: proc(game: ^Game, scene: ^Scene) {
	if scene.unbuilt {
		scene.unbuilt = false
		scene.played = false
		Game_RebuildScene(game, scene)
	}
}

// Whether entering a scene goes through the loading scene: one is set, it's another scene, and
// this one hasn't been built (or played: it's built again on every visit)
@(private="file")
needsLoading :: proc(game: ^Game, name: string) -> bool {
	flow := &game.flow
	if flow.loadingScene == "" || name == flow.loadingScene || flow.loadingScene not_in game.scenes do return false
	scene, ok := game.scenes[name]
	return ok && (scene.unbuilt || scene.played)
}

// The target's images and sounds, from its file, to load a few a frame
@(private="file")
startLoading :: proc(game: ^Game) {
	flow := &game.flow
	for p in flow.toLoad do delete(p)
	clear(&flow.toLoad)
	flow.loadingTime = 0
	path, known := game.sceneFiles[flow.target]
	if known {
		if data, err := LoadSceneFile(path); err == .None {
			for &node in data.nodes {
				if node.texture != "" do append(&flow.toLoad, strings.concatenate({"t:", node.texture}))
				if node.sound != "" do append(&flow.toLoad, strings.concatenate({"s:", node.sound}))
				if node.tilemap.file != "" do append(&flow.toLoad, strings.concatenate({"t:", node.tilemap.file}))
			}
			SceneData_Destroy(&data)
		}
	}
	flow.loadTotal = len(flow.toLoad)
}

@(private="file")
loadSome :: proc(game: ^Game) {
	flow := &game.flow
	rm := &game.resourceManager
	for _ in 0..<LOADING_PER_FRAME {
		if len(flow.toLoad) == 0 do return
		item := pop(&flow.toLoad)
		defer delete(item)
		full := JoinPath(game.projectDir, item[2:])
		if strings.has_prefix(item, "t:") {
			if rm.renderer != nil do _ = loadAsset(rm, game.projectDir, item[2:])
		} else if game.mixer != nil {
			_ = ResourceManager_loadAudio(rm, full)
		}
	}
}
