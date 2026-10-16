package engine

import "core:fmt"
import sdl "vendor:sdl3"
import log "core:log"
import mix "vendor:sdl3/mixer"
import ttf "vendor:sdl3/ttf"
import "core:c"

MAX_EVENTS :: 1000

Application :: struct {
	window: ^sdl.Window,
	renderer: ^sdl.Renderer,
	mixer: ^mix.Mixer,
	running: bool,
	game: ^Game,
	queuedGame: ^Game,
}

Application_Setup :: proc(app: ^Application, windowTitle: string, windowSize: [2]f32) -> bool {
	if !sdl.Init({ .VIDEO, .AUDIO, .GAMEPAD, .EVENTS}) {
		log.error("Error initializing SDL: ", sdl.GetError())
		return false
	}

	app.window = sdl.CreateWindow(fmt.ctprint(windowTitle), c.int(windowSize[0]), c.int(windowSize[1]), {.RESIZABLE})
	if app.window == nil {
		log.error("Error creating window: ", sdl.GetError())
		return false
	}

	// The browser has WebGL only: let SDL pick there
	app.renderer = sdl.CreateRenderer(app.window, PLATFORM_WEB ? nil : "opengl")
	if app.renderer == nil {
		log.error("Error creating renderer:", sdl.GetError())
		return false
	}

	// In the browser, vsync means "frames on requestAnimationFrame", which SDL can only set once
	// Emscripten's main loop exists (before that, Present blocks): see Player_StartWeb
	if !PLATFORM_WEB do sdl.SetRenderVSync(app.renderer, 1)

	mixer, audioOk := Platform_AudioInit()
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
Runs the game until it quits: `Application_Frame` in a loop. The browser can't block like this;
there, the page calls `Application_Frame` once per animation frame (see `Player_StartWeb`).
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
the frame's temporary memory. Sets `app.running` to false when the game quits.
*/
Application_Frame :: proc(app: ^Application) {
	freq := sdl.GetPerformanceFrequency()
	if frameState.lastTime == 0 do frameState.lastTime = sdl.GetPerformanceCounter()
	events := &frameState.events
	eventCount := 0
	{

		if app.queuedGame != nil {
			log.info("Switching to new game")
			if app.game != nil {
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

Application_Cleanup :: proc(app: ^Application) {
	if app.game != nil {
		Game_Destroy(app.game)
	}
	Platform_AudioQuit(app.mixer)
	ttf.Quit()
	if app.renderer != nil {
		sdl.DestroyRenderer(app.renderer)
	}
	if app.window != nil {
		sdl.DestroyWindow(app.window)
	}
	sdl.Quit()
}

App_SetGame :: proc(app: ^Application, game: ^Game) {
	app.queuedGame = game
}
