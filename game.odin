package engine

import "base:runtime"
import "core:strings"

import sdl "vendor:sdl3"
import log "core:log"
import mix "vendor:sdl3/mixer"
import "core:c"


// How the game's fixed resolution is fit into the window
ScaleMode :: enum {
	Letterbox,    // Keep aspect ratio, fill the rest with black bars
	Stretch,      // Fill the window, distorting the aspect ratio
	IntegerScale, // Scale by whole multiples only, for crisp pixel art
	Overscan,     // Keep aspect ratio, crop the edges that don't fit
	None,         // No scaling, game coordinates are window coordinates
}


// With `Game.devKeys`: shows and hides the physics shapes while the game runs
DEV_KEY_PHYSICS_DEBUG :: sdl.Scancode.F9
// With `Game.devKeys`: shows and hides the debug overlay (debug.odin)
DEV_KEY_DEBUG_OVERLAY :: sdl.Scancode.F10

Game :: struct {
	mixer: ^mix.Mixer,
	window: ^sdl.Window,
	renderer: ^sdl.Renderer,
	shouldQuit: bool,
	// Quit when Escape is pressed. Set to false in build if the game uses Escape itself
	quitOnEscape: bool,
	// Developer keys, for games run from the editor (the player's --dev; never in exports):
	// F9 shows / hides the physics shapes (DEV_KEY_PHYSICS_DEBUG), F10 the debug overlay
	// (DEV_KEY_DEBUG_OVERLAY)
	devKeys: bool,
	// Show the debug overlay (debug.odin): frame rate, frame times, the scene's counts
	debugOverlay: bool,
	// Recent frame times, for the overlay (`Game_GetFrameStats`)
	frameStats: FrameStats,
	initialized: bool,
	backgroundColor: sdl.Color,
	// Resolution the game is designed for. All drawing and event positions are in this
	// coordinate space. Leave as zero to use the window size at init
	size: [2]f32,
	scaleMode: ScaleMode,
	// Current size of the window, kept up to date as it is resized
	windowSize: [2]f32,
	resourceManager: ResourceManager,
	// Scenes are heap allocated so pointers to them stay valid as more scenes are added
	scenes: map[string]^Scene,
	nextScenePtr: ^Scene,
	currentScene: ^Scene,
	name: string,
	// Global scripts, in their start order (globals.odin)
	globals: [dynamic]GlobalInstance,
	// Data resources loaded so far, by path (data.odin)
	data: map[string]DataInstance,
	// Memory that lives as long as the game: globals, data resources (Game_GetAllocator)
	arena: MemoryArena,
	arenaReady: bool,
	// How its scenes' physics behave (physics.odin); zero means DEFAULT_PHYSICS. Set before
	// scenes create physics nodes
	physics: PhysicsSettings,
	// The keyboard, mouse, gamepads and the project's actions (input.odin)
	input: InputState,
	// Mix buses, Master first, and every sound node (audio_nodes.odin)
	buses: [dynamic]AudioBus,
	audioPlayers: [dynamic]^AudioPlayer,
	// Components read so far, by path (nil: couldn't be read); in the game's memory (project_loader.odin)
	components: map[string]^SceneData,
	// LDtk projects read so far, by path (nil: couldn't be read); each in its own arena (ldtk_nodes.odin)
	ldtk: map[string]^LDtkProject,
	// Development runs: the files' modification times when read, projects replaced by a reload
	// (kept until the end: entity nodes point into them), when to look at the files next
	ldtkTimes: map[string]i64,
	ldtkRetired: [dynamic]^LDtkProject,
	ldtkWatchTimer: f64,
	// The folder asset paths are relative to (owned; set by Game_LoadProject, "" for the working directory)
	projectDir: string,
	// Seconds left of a hitstop (Game_HitStop): scenes and globals get a delta time of 0
	hitStop: f64,
	// Multiplies the time scenes and globals see: 0.5 is slow motion, 2 double speed
	// (`Game_SetTimeScale`). 0 counts as 1, so a game that never sets it runs normally; to stop
	// time, pause the scene (`Scene_SetPaused`)
	timeScale: f32,
	// Each scene's file, by scene name (Game_LoadProject; in the game's arena): a scene entered
	// again is rebuilt from it
	sceneFiles: map[string]string,
	update: proc(game: ^Game, events: []sdl.Event, deltaTime: f64),
	draw: proc(game: ^Game),
	createScene: proc(game: ^Game, name: string) -> ^Scene,
	switchScene: proc(game: ^Game, name: string) -> bool,
	build: proc(game: ^Game),
}

Game_Init :: proc(game: ^Game, window: ^sdl.Window, renderer: ^sdl.Renderer, mixer: ^mix.Mixer) {
	game.window = window
	game.renderer = renderer
	game.mixer = mixer
	ResourceManager_Init(&game.resourceManager, renderer, mixer)
	game.scenes = make(map[string]^Scene)
	game.update = Game_Update
	game.draw = Game_Draw
	game.createScene = Game_CreateScene
	game.switchScene = Game_SwitchScene
	game.shouldQuit = false
	game.quitOnEscape = true
	game.backgroundColor = sdl.Color{0, 0, 0, 255}

	w, h: c.int
	sdl.GetWindowSize(window, &w, &h)
	game.windowSize = {f32(w), f32(h)}
	if game.size == {} {
		game.size = game.windowSize
	}
	Game_ApplyScaling(game)

	if game.build != nil {
		game.build(game)
	}
	game.initialized = true
}

/*
Memory that lives as long as the game (globals and data resources use it). Freed by Game_Destroy.
*/
Game_GetAllocator :: proc(game: ^Game) -> runtime.Allocator {
	if !game.arenaReady {
		game.arenaReady = MemoryArena_InitGrowing(&game.arena)
	}
	return MemoryArena_Allocator(&game.arena)
}

Game_Destroy :: proc(game: ^Game) {
	// The scene that's playing exits first, then every scene's nodes go (their scripts' destroy
	// hooks can still reach the globals), then the globals
	if game.currentScene != nil {
		game.currentScene.onExit->notify(game.currentScene, nil)
		Audio_SceneExited(game, game.currentScene)
	}
	for name, scene in game.scenes {
		Scene_Destroy(scene)
		free(scene)
		delete(name)
	}
	delete(game.scenes)
	game.scenes = nil
	game.currentScene = nil
	game.nextScenePtr = nil
	Globals_Destroy(game)
	Input_Destroy(&game.input)
	// Their memory is the game's arena, freed below
	game.components = nil
	game.sceneFiles = nil
	Game_ForgetLDtk(game)
	Audio_DestroyBuses(game)
	delete(game.projectDir)
	game.resourceManager->destroy()
	delete(game.globals)
	delete(game.data)
	if game.arenaReady do MemoryArena_Destroy(&game.arena)
	game.arenaReady = false
	if currentGame == game do currentGame = nil
}

Game_CreateScene :: proc(game: ^Game, name: string) -> ^Scene {
	if name in game.scenes {
		log.warn("Scene with name already exists: ", name)
		return nil
	}
	scene := new(Scene)
	Scene_Init(scene)
	scene.game = game
	// The map keeps its own copy of the name, so callers can pass temporary strings; the scene
	// shares it (freed with the map's keys)
	key := strings.clone(name)
	scene.name = key
	game.scenes[key] = scene
	return scene
}

Game_SwitchScene :: proc(game: ^Game, name: string) -> bool {
	scene, exists := game.scenes[name]
	if !exists {
		log.warn("Scene with name does not exist: ", name)
		return false
	}
	log.infof("Switching to scene: %s on next frame", name)
	game.nextScenePtr = scene
	return true
}

Game_Update :: proc(game: ^Game, events: []sdl.Event, deltaTime: f64) {
	// Input first: everything this frame sees the same state
	Input_Update(&game.input, events)
	Audio_Update(game)
	for &event in events {
		if event.type == .WINDOW_RESIZED {
			game.windowSize = {f32(event.window.data1), f32(event.window.data2)}
		}

		if event.type == .QUIT {
			game.shouldQuit = true
		}

		if game.devKeys && event.type == .KEY_DOWN && !event.key.repeat && event.key.scancode == DEV_KEY_PHYSICS_DEBUG {
			Physics_SetDebugDraw(game, !game.physics.debugDraw)
			log.infof("Collision shapes %s (F9)", game.physics.debugDraw ? "shown" : "hidden")
		}
		if game.devKeys && event.type == .KEY_DOWN && !event.key.repeat && event.key.scancode == DEV_KEY_DEBUG_OVERLAY {
			game.debugOverlay = !game.debugOverlay
		}

		if game.quitOnEscape && event.type == .KEY_DOWN && event.key.scancode == .ESCAPE {
			game.shouldQuit = true
		}
	}
	if game.nextScenePtr != nil {
		log.info("Switching to next scene: ")
		if game.currentScene != nil {
			game.currentScene.onExit->notify(game.currentScene, nil)
			// Its sounds stop (and start again when it's back)
			Audio_SceneExited(game, game.currentScene)
		}
		// Every visit starts fresh: a scene played before is built again from its file (switching
		// to the current scene restarts it)
		if game.nextScenePtr.played do Game_RebuildScene(game, game.nextScenePtr)
		game.nextScenePtr.played = true
		game.nextScenePtr.onEnter->notify(game.nextScenePtr, nil)
		game.currentScene = game.nextScenePtr
		game.nextScenePtr = nil
		Globals_SceneChanged(game, game.currentScene)
	}


	// A hitstop freezes the game (scripts still run, with 0 seconds: they see input); the camera
	// shake moves on in real time
	realDeltaTime := deltaTime
	recordFrameTime(game, realDeltaTime)
	deltaTime := deltaTime * f64(game.timeScale > 0 ? game.timeScale : 1)
	if game.hitStop > 0 {
		game.hitStop -= realDeltaTime
		deltaTime = 0
	}
	if scene := game.currentScene; scene != nil && scene.camera != nil do Camera2D_UpdateShake(scene.camera, realDeltaTime)

	// Development runs: LDtk files saved since are read again (ldtk_nodes.odin)
	if game.devKeys && len(game.ldtk) > 0 do LDtk_WatchFiles(game, deltaTime)

	// Globals first: the scene's nodes see what they changed this frame
	Globals_Update(game, events, deltaTime)

	// No scene yet (before the first switch) is fine: nothing to update
	if game.currentScene != nil && game.currentScene.update != nil {
		game.currentScene->update(events, deltaTime)
	}
}


/*
Builds a scene again from its file (`Game.sceneFiles`): its nodes are destroyed and made anew, as
when the game started. The game does it when a scene that has been played is entered again; a
scene made by code (no file) is left as it is.
*/
Game_RebuildScene :: proc(game: ^Game, scene: ^Scene) {
	path, known := game.sceneFiles[scene.name]
	if !known do return
	data, err := LoadSceneFile(path)
	if err != .None {
		log.errorf("Couldn't rebuild scene '%s' from %s: %v", scene.name, path, err)
		return
	}
	defer SceneData_Destroy(&data)
	Scene_Clear(scene)
	Scene_Build(scene, &data, game.projectDir)
}

/*
Freezes the game for a moment: a hitstop, the short pause that makes a hit feel heavy. For
`seconds` of real time, scenes and globals update with a delta time of 0: physics, animations,
particles, timers and anything scripts move by the delta stop, while input, drawing and the
camera's shake (`Camera2D_Shake`) go on. A longer hitstop extends a running one; a shorter one
doesn't cut it.

Inputs:
- game: The game
- seconds: How long, in real seconds (around 0.05 to 0.12 for a hit)

Example:
	e.Game_HitStop(self.game, 0.08)
	e.Camera2D_Shake(self.scene.camera, 3, 0.15)
*/
/*
Switches the game's window between fullscreen (the desktop's resolution, the game scaled into it)
and windowed.

Returns:
- false if the window couldn't change (logged), or there's no window
*/
Game_SetFullscreen :: proc(game: ^Game, fullscreen: bool) -> bool {
	if game.window == nil do return false
	if !sdl.SetWindowFullscreen(game.window, fullscreen) {
		log.errorf("Game_SetFullscreen: %s", sdl.GetError())
		return false
	}
	return true
}

// Whether the game's window is fullscreen
Game_IsFullscreen :: proc(game: ^Game) -> bool {
	return game.window != nil && .FULLSCREEN in sdl.GetWindowFlags(game.window)
}

/*
Turns vsync on (frames wait for the display's refresh: no tearing) or off (as fast as it can).
Not in the browser, where frames always follow the display.
*/
Game_SetVSync :: proc(game: ^Game, vsync: bool) {
	if game.renderer != nil && !PLATFORM_WEB do sdl.SetRenderVSync(game.renderer, vsync ? 1 : 0)
}

/*
Sets how fast time runs for scenes and globals (physics, animations, particles, timers, tweens,
scripts' delta time): 1 is normal, 0.5 slow motion, 2 double speed. Hitstops and camera shakes
run in real time.

Inputs:
- game: The game
- scale: The speed (above 0; to stop time, pause the scene)
*/
Game_SetTimeScale :: proc(game: ^Game, scale: f32) {
	game.timeScale = max(scale, 0.0001)
}

Game_HitStop :: proc(game: ^Game, seconds: f64) {
	game.hitStop = max(game.hitStop, seconds)
}

Game_Draw :: proc(game: ^Game) {
	if game.currentScene != nil && game.currentScene.draw != nil {
		game.currentScene->draw(game.renderer)
	}
	// Globals that draw (a HUD) go over the scene, in screen space
	Globals_Draw(game)
	if game.debugOverlay do drawDebugOverlay(game)
}


// Tells the renderer to draw at game.size and scale the result into the window.
// The renderer recalculates the scale on its own whenever the window is resized
Game_ApplyScaling :: proc(game: ^Game) {
	mode: sdl.RendererLogicalPresentation
	switch game.scaleMode {
	case .Letterbox:    mode = .LETTERBOX
	case .Stretch:      mode = .STRETCH
	case .IntegerScale: mode = .INTEGER_SCALE
	case .Overscan:     mode = .OVERSCAN
	case .None:         mode = .DISABLED
	}
	if !sdl.SetRenderLogicalPresentation(game.renderer, c.int(game.size.x), c.int(game.size.y), mode) {
		log.errorf("Error setting logical presentation: %s", sdl.GetError())
	}
}

Game_SetSize :: proc(game: ^Game, size: [2]f32) {
	game.size = size
	Game_ApplyScaling(game)
}

Game_SetScaleMode :: proc(game: ^Game, mode: ScaleMode) {
	game.scaleMode = mode
	Game_ApplyScaling(game)
}

// Converts a point in window coordinates to game coordinates
Game_WindowToGame :: proc(game: ^Game, point: [2]f32) -> [2]f32 {
	result: [2]f32
	sdl.RenderCoordinatesFromWindow(game.renderer, point.x, point.y, &result.x, &result.y)
	return result
}

// Current mouse position in game coordinates, for nodes that poll instead of using events
Game_GetMousePosition :: proc(game: ^Game) -> [2]f32 {
	mouse: [2]f32
	_ = sdl.GetMouseState(&mouse.x, &mouse.y)
	return Game_WindowToGame(game, mouse)
}
