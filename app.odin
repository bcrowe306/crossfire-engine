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

	app.renderer = sdl.CreateRenderer(app.window, "opengl")
	if app.renderer == nil {
		log.error("Error creating renderer:", sdl.GetError())
		return false
	}

	sdl.SetRenderVSync(app.renderer, 1)

	mixerInitOk := mix.Init()
	if !mixerInitOk {
		log.error("Error initializing SDL_mixer: ", sdl.GetError())
		return false
	}

	app.mixer = mix.CreateMixerDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
	if app.mixer == nil {
		log.error("Error creating mixer device: ", sdl.GetError())
		return false
	}

	if !ttf.Init() {
		log.error("Error initializing SDL_ttf: ", sdl.GetError())
		return false
	}

	app.running = true
	return true
}


Application_Run :: proc(app: ^Application, game: ^Game = nil) {
	if game != nil {
		App_SetGame(app, game)
	}

	lastTime := sdl.GetPerformanceCounter()
	freq := sdl.GetPerformanceFrequency()

	events := [MAX_EVENTS]sdl.Event{}
	eventCount := 0

	for app.running {

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
		deltaTime :=  (f64(now) - f64(lastTime) ) / f64(freq)
		lastTime = now

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
	if app.mixer != nil {
		mix.DestroyMixer(app.mixer)
	}
	mix.Quit()
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
