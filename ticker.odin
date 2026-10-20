package crossfire

import "core:time"

// A tick callback: the ticker, its tick count and user data. (Not used by `Ticker`, which notifies `onTick`)
TickerCallBack :: proc(ticker: ^Ticker, currentTick: int, user_data: rawptr)

/*
Sends `onTick` at a fixed rate, measured in real (wall clock) time: unlike `Timer`, it doesn't
follow the delta time, so the time scale, hitstops and paused scenes don't slow it.

Set it up with `Ticker_Init`, then call `ticker->process()` every frame; it ticks at most once
per call. The data sent with `onTick` is the tick count (f32). The procedures are called with
`->`.

Example:
	// Given: ticker: ^e.Ticker
	e.Ticker_Init(ticker, allocator = e.Node_GetAllocator(node))
	ticker->setFPS(4)
	ticker.onTick->subscribe(proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, _: rawptr) {
		log.infof("tick %v", data)
	}, nil)
	// Every frame:
	ticker->process()
*/
Ticker :: struct {
	// Ticks per second (0 to 120). Change it with `setFPS`
	framesPerSecond: f32,
	// Time between ticks (0: never ticks)
	secondsPerFrame: time.Duration,
	// Time since the last tick
	elapsedTime: time.Duration,
	// When `process` last measured the time
	lastTick: time.Tick,
	// Ticks so far
	currentTick: int,
	// Free for the game's use; the ticker doesn't read it
	user_data: rawptr,
	// Whether `process` advances it
	running: bool,
	// `Ticker_SetFPS`
	setFPS: proc(ticker: ^Ticker, framesPerSecond: f32),
	// `Ticker_Start`
	start: proc(ticker: ^Ticker, resetCounter: bool),
	// `Ticker_Stop`
	stop: proc(ticker: ^Ticker),
	// `Ticker_Pause`
	pause: proc(ticker: ^Ticker),
	// `Ticker_Resume`
	resume: proc(ticker: ^Ticker),
	// `Ticker_TogglePause`
	togglePause: proc(ticker: ^Ticker),
	// `Ticker_Reset`
	reset: proc(ticker: ^Ticker),
	// Measures the time and ticks if a tick is due. Call it every frame
	process: proc(ticker: ^Ticker),
	// Notified on each tick (source: the ticker; data: the tick count, f32)
	onTick: EventSubject,
}

@(private)
Ticker_Process :: proc(ticker: ^Ticker) {
	if !ticker.running do return
	tick := time.tick_now()
	ticker.elapsedTime += time.tick_diff(ticker.lastTick, tick)
	ticker.lastTick = tick
	// No rate (0 fps): it never ticks
	if ticker.secondsPerFrame <= 0 do return
	if ticker.elapsedTime >= ticker.secondsPerFrame {
		// Keep the remainder, so ticks don't drift later and later; after a long stall, one tick
		// and on from there rather than a burst
		ticker.elapsedTime = (ticker.elapsedTime - ticker.secondsPerFrame) % ticker.secondsPerFrame
		ticker.currentTick += 1
		ticker.onTick->notify(ticker, f32(ticker.currentTick))
	}
}

/*
Prepares a ticker: its procedures and `onTick`, at 1 tick per second.

Inputs:
- ticker: The ticker
- auto_start: Start it now (counter at 0)
- allocator: Holds the event listener list. Inside a node, pass `Node_GetAllocator(node)`
*/
Ticker_Init :: proc(ticker: ^Ticker, auto_start: bool = true, allocator := context.allocator) {
	ticker.process = Ticker_Process
	ticker.setFPS = Ticker_SetFPS
	ticker.reset = Ticker_Reset
	ticker.start = Ticker_Start
	ticker.stop = Ticker_Stop
	ticker.pause = Ticker_Pause
	ticker.resume = Ticker_Resume
	ticker.togglePause = Ticker_TogglePause
	EventSubject_Init(&ticker.onTick, allocator)
	ticker->setFPS(1)
	if auto_start {
		ticker->start(true)
	}
}

/*
Starts the ticker: the time to the next tick starts from now. Also `ticker->start(resetCounter)`.

Inputs:
- ticker: The ticker
- resetCounter: Set the tick count back to 0
*/
Ticker_Start :: proc(ticker: ^Ticker, resetCounter: bool = true){
	ticker.running = true
	ticker.elapsedTime = 0
	ticker.lastTick = time.tick_now()
	if resetCounter do ticker.currentTick = 0
}
/*
Stops the ticker. Also `ticker->stop()`.

Inputs:
- ticker: The ticker
*/
Ticker_Stop :: proc(ticker: ^Ticker) {
	ticker.running = false
}

/*
Pauses a running ticker, or resumes a stopped one. Also `ticker->togglePause()`.

Inputs:
- ticker: The ticker
*/
Ticker_TogglePause :: proc(ticker: ^Ticker) {
	if ticker.running do Ticker_Pause(ticker)
	else do Ticker_Resume(ticker)
}

/*
Pauses the ticker (the same as `Ticker_Stop`). Also `ticker->pause()`.

Inputs:
- ticker: The ticker
*/
Ticker_Pause :: proc(ticker: ^Ticker) {
	ticker.running = false
}
/*
Resumes the ticker where it was paused: the time it was paused doesn't count toward the next
tick. Also `ticker->resume()`.

Inputs:
- ticker: The ticker
*/
Ticker_Resume :: proc(ticker: ^Ticker) {
	if !ticker.running do ticker.lastTick = time.tick_now()
	ticker.running = true
}

/*
Sets the tick rate. Also `ticker->setFPS(rate)`.

Inputs:
- ticker: The ticker
- framesPerSecond: Ticks per second, clamped to 0 to 120 (0 never ticks)
*/
Ticker_SetFPS :: proc(ticker: ^Ticker, framesPerSecond: f32) {
	framesPerSecond := clamp(framesPerSecond, 0, 120)
	ticker.framesPerSecond = framesPerSecond
	ticker.secondsPerFrame = framesPerSecond > 0 ? time.Duration(f64(time.Second) / f64(framesPerSecond)) : 0
}

/*
Sets the tick count and the time since the last tick back to 0. Also `ticker->reset()`.

Inputs:
- ticker: The ticker
*/
Ticker_Reset :: proc(ticker: ^Ticker) {
	ticker.elapsedTime = 0
	ticker.currentTick = 0
}
