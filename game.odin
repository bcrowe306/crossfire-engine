package engine

import "core:fmt"

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


Game :: struct {
	mixer: ^mix.Mixer,
	window: ^sdl.Window,
	renderer: ^sdl.Renderer,
	shouldQuit: bool,
	// Quit when Escape is pressed. Set to false in build if the game uses Escape itself
	quitOnEscape: bool,
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

Game_Destroy :: proc(game: ^Game) {
	for _, scene in game.scenes {
		Scene_Destroy(scene)
		free(scene)
	}
	delete(game.scenes)
	game.resourceManager->destroy()
}

Game_CreateScene :: proc(game: ^Game, name: string) -> ^Scene {
	if name in game.scenes {
		log.warn("Scene with name already exists: ", name)
		return nil
	}
	scene := new(Scene)
	Scene_Init(scene)
	scene.game = game
	game.scenes[name] = scene
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
	for &event in events {
		if event.type == .WINDOW_RESIZED {
			game.windowSize = {f32(event.window.data1), f32(event.window.data2)}
		}

		if event.type == .QUIT {
			game.shouldQuit = true
		}

		if game.quitOnEscape && event.type == .KEY_DOWN && event.key.scancode == .ESCAPE {
			game.shouldQuit = true
		}
	}
	if game.nextScenePtr != nil {
		log.info("Switching to next scene: ")
		if game.currentScene != nil {
			game.currentScene.onExit->notify(game.currentScene, nil)
		}
		game.nextScenePtr.onEnter->notify(game.nextScenePtr, nil)
		game.currentScene = game.nextScenePtr
		game.nextScenePtr = nil
	}


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
