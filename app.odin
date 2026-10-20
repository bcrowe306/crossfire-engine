package engine

import "core:fmt"
import sdl "vendor:sdl3"
import log "core:log"
import mix "vendor:sdl3/mixer"
import ttf "vendor:sdl3/ttf"
import "core:c"

// Most SDL events `Application_Frame` collects in one frame; the rest wait for the next frame
MAX_EVENTS :: 1000

/*
The program's window, renderer and audio device, and the game they run.

Set it up with `Application_Setup`, run it with `Application_Run` and free it with
`Application_Cleanup`. One application runs one `Game` at a time; `App_SetGame` swaps it.
*/
Application :: struct {
	// The window opened by `Application_Setup`
	window: ^sdl.Window,
	// The window's renderer, shared by every game the application runs
	renderer: ^sdl.Renderer,
	// The audio mixer from `Audio_Init`
	mixer: ^mix.Mixer,
	// True while the frame loop runs; false once the game sets `shouldQuit`
	running: bool,
	// The game being played. nil until the first frame after `App_SetGame`
	game: ^Game,
	// The game `App_SetGame` asked for; the next frame switches to it
	queuedGame: ^Game,
}

/*
Starts SDL, opens the window with a renderer, the audio device and SDL_ttf.

The window is resizable; the game's resolution is scaled into it (see `Game_SetScaleMode`).
Call it once, before creating a game; free everything with `Application_Cleanup`.

Inputs:
- app: The application to fill in
- windowTitle: The window's title
- windowSize: The window's size in pixels (ignored when `window.fullscreen` is set)
- backend: The renderer to use (`RenderBackend`). `.Auto` lets SDL choose
- window: Fullscreen, vsync and high-DPI settings (vsync is applied later on the web)

Returns:
- false (logged) if SDL, the window, the renderer, the audio device or SDL_ttf couldn't start

Example:
	app := e.Application{}
	if !e.Application_Setup(&app, "My Game", {1280, 720}) do return
	defer e.Application_Cleanup(&app)
	e.Application_Run(&app, game)
*/
Application_Setup :: proc(app: ^Application, windowTitle: string, windowSize: [2]f32, backend := RenderBackend.Auto, window := DEFAULT_WINDOW_SETTINGS) -> bool {
	if !sdl.Init({ .VIDEO, .AUDIO, .GAMEPAD, .EVENTS}) {
		log.error("Error initializing SDL: ", sdl.GetError())
		return false
	}

	flags: sdl.WindowFlags = {.RESIZABLE}
	if window.fullscreen do flags += {.FULLSCREEN}
	if window.highDPI do flags += {.HIGH_PIXEL_DENSITY}
	app.window = sdl.CreateWindow(fmt.ctprint(windowTitle), c.int(windowSize[0]), c.int(windowSize[1]), flags)
	if app.window == nil {
		log.error("Error creating window: ", sdl.GetError())
		return false
	}

	// The Crossfire logo until the game sets its own (the project's `icon`, `Game_SetWindowIcon`)
	_ = Platform_SetWindowIcon(app.window, nil)

	app.renderer = Application_CreateRenderer(app.window, backend)
	if app.renderer == nil do return false

	// In the browser, vsync means "frames on requestAnimationFrame", which SDL can only set once
	// Emscripten's main loop exists (before that, Present blocks): see Player_StartWeb
	if !PLATFORM_WEB do sdl.SetRenderVSync(app.renderer, window.vsync ? 1 : 0)

	mixer, audioOk := Audio_Init()
	if !audioOk do return false
	app.mixer = mixer

	if !ttf.Init() {
		log.error("Error initializing SDL_ttf: ", sdl.GetError())
		return false
	}

	app.running = true
	return true
}


/*
Runs the game until it quits: `Application_Frame` in a loop.

The browser can't block like this; there, the page calls `Application_Frame` once per animation
frame (see `Player_StartWeb`).

Inputs:
- app: The application, set up with `Application_Setup`
- game: The game to play (queued with `App_SetGame`; initialized on the first frame if needed).
  nil keeps the game already set

Example:
	app := e.Application{}
	if !e.Application_Setup(&app, "My Game", {1280, 720}) do return
	defer e.Application_Cleanup(&app)
	e.Application_Run(&app, game)
*/
Application_Run :: proc(app: ^Application, game: ^Game = nil) {
	if game != nil {
		App_SetGame(app, game)
	}
	for app.running do Application_Frame(app)
}

// Frame timing and the event buffer, kept between frames
@(private="file")
frameState: struct {
	lastTime: u64,
	events: [MAX_EVENTS]sdl.Event,
}

/*
Runs one frame: switches to a queued game, polls events, updates, draws and presents, and frees
the frame's temporary memory (`context.temp_allocator`).

Switching destroys the previous game (`Game_Destroy`) and initializes the new one if it isn't
yet. Event positions are converted to the game's resolution. Sets `app.running` to false when
the game sets `shouldQuit`.

Inputs:
- app: The application, set up with `Application_Setup`
*/
Application_Frame :: proc(app: ^Application) {
	freq := sdl.GetPerformanceFrequency()
	if frameState.lastTime == 0 do frameState.lastTime = sdl.GetPerformanceCounter()
	events := &frameState.events
	eventCount := 0
	{

		if app.queuedGame != nil {
			log.info("Switching to new game")
			// Setting the game that's already playing again only re-applies its scaling
			if app.game != nil && app.game != app.queuedGame {
				Game_Destroy(app.game)
			}
			app.game = app.queuedGame
			if !app.game.initialized {
				Game_Init(app.game, app.window, app.renderer, app.mixer)
			} else {
				// Already initialized games still need their resolution applied to the shared renderer
				Game_ApplyScaling(app.game)
			}
			app.queuedGame = nil
		}

		// Poll for events and build events buffer
		now := sdl.GetPerformanceCounter()
		deltaTime :=  (f64(now) - f64(frameState.lastTime) ) / f64(freq)
		frameState.lastTime = now

		for sdl.PollEvent(&events[eventCount]) {
			// Map mouse/touch/pen positions from window space into the game's resolution
			sdl.ConvertEventToRenderCoordinates(app.renderer, &events[eventCount])
			eventCount += 1
			if eventCount >= MAX_EVENTS {
				log.warn("Event buffer overflow, some events may be lost")
				break
			}
		}

		if game := app.game; game != nil {
			sdl.SetRenderDrawColor(app.renderer, game.backgroundColor.r, game.backgroundColor.g, game.backgroundColor.b, game.backgroundColor.a)
			sdl.RenderClear(app.renderer)
			if game.update != nil {
				game->update(events[:eventCount], deltaTime)
			}
			else {
				log.warn("Game update function is not set")
			}


			if game.draw != nil {
				game->draw()
			}
			else {
				log.warn("Game draw function is not set")
			}
		}
		else {
			log.warn("Game is not set in application")
			sdl.SetRenderDrawColor(app.renderer, 0, 0, 0, 255)
			sdl.RenderClear(app.renderer)
		}

		// Present the rendered frame
		sdl.RenderPresent(app.renderer)
		eventCount = 0
		if app.game != nil && app.game.shouldQuit {
			app.running = false
		}

		// Release per-frame scratch allocations (fmt.ctprint, etc.)
		free_all(context.temp_allocator)
	}
}

/*
Destroys the current game, then closes audio, SDL_ttf, the renderer, the window and SDL.

A game that is only queued (`queuedGame`) is not destroyed: the caller owns it.

Inputs:
- app: The application to shut down
*/
Application_Cleanup :: proc(app: ^Application) {
	if app.game != nil {
		Game_Destroy(app.game)
		app.game = nil
	}
	app.queuedGame = nil
	Audio_Quit(app.mixer)
	ttf.Quit()
	if app.renderer != nil {
		sdl.DestroyRenderer(app.renderer)
	}
	if app.window != nil {
		sdl.DestroyWindow(app.window)
	}
	sdl.Quit()
}

/*
Queues a game to play. The next `Application_Frame` destroys the current game (if it's a
different one) and switches to this one, initializing it if needed.

Inputs:
- app: The application
- game: The game to switch to. Setting the current game again only re-applies its scaling
*/
App_SetGame :: proc(app: ^Application, game: ^Game) {
	app.queuedGame = game
}
