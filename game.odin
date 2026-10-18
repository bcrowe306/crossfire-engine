package engine

import "base:runtime"
import "core:fmt"
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

Game :: struct {
	mixer: ^mix.Mixer,
	window: ^sdl.Window,
	renderer: ^sdl.Renderer,
	shouldQuit: bool,
	// Quit when Escape is pressed. Set to false in build if the game uses Escape itself
	quitOnEscape: bool,
	// Developer keys, for games run from the editor (the player's --dev; never in exports):
	// F9 shows / hides the physics shapes (DEV_KEY_PHYSICS_DEBUG)
	devKeys: bool,
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
	// The folder asset paths are relative to (owned; set by Game_LoadProject, "" for the working directory)
	projectDir: string,
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
	Globals_Destroy(game)
	Input_Destroy(&game.input)
	// Their memory is the game's arena, freed below
	game.components = nil
	for name, scene in game.scenes {
		Scene_Destroy(scene)
		free(scene)
		delete(name)
	}
	delete(game.scenes)
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
	fmt.println(name)
	log.infof("Switching to scene: %s on next frame", name)
	game.nextScenePtr = scene
	return true
}

Game_Update :: proc(game: ^Game, events: []sdl.Event, deltaTime: f64) {
	// Input first: everything this frame sees the same state
	Input_Update(&game.input, events)
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
		game.nextScenePtr.onEnter->notify(game.nextScenePtr, nil)
		game.currentScene = game.nextScenePtr
		game.nextScenePtr = nil
		Globals_SceneChanged(game, game.currentScene)
	}


	// Globals first: the scene's nodes see what they changed this frame
	Globals_Update(game, events, deltaTime)

	if game.currentScene != nil {
		if game.currentScene.update != nil {
			game.currentScene->update(events, deltaTime)
		}
		else {
			log.warn("Current scene update function is not set")
		}
	}
	else {
		log.warn("No current scene to update")
	}
}


Game_Draw :: proc(game: ^Game) {
	if game.currentScene != nil {
		if game.currentScene.draw != nil {
			game.currentScene->draw(game.renderer)
		}
		else {
			log.warn("Current scene draw function is not set")
		}
	}
	else {
		log.warn("No current scene to draw")
	}
	// Globals that draw (a HUD) go over the scene, in screen space
	Globals_Draw(game)
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
