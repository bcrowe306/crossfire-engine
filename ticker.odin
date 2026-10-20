package engine

import "core:time"

TickerCallBack :: proc(ticker: ^Ticker, currentTick: int, user_data: rawptr)

Ticker :: struct {
	framesPerSecond: f32,
	secondsPerFrame: time.Duration,
	elapsedTime: time.Duration,
	lastTick: time.Tick,
	currentTick: int,
	user_data: rawptr,
	running: bool,
	setFPS: proc(ticker: ^Ticker, framesPerSecond: f32),
	start: proc(ticker: ^Ticker, resetCounter: bool),
	stop: proc(ticker: ^Ticker),
	pause: proc(ticker: ^Ticker),
	resume: proc(ticker: ^Ticker),
	togglePause: proc(ticker: ^Ticker),
	reset: proc(ticker: ^Ticker),
	process: proc(ticker: ^Ticker),
	onTick: EventSubject,
}

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

// allocator holds the event listener list. Inside a node, pass Node_GetAllocator(node)
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

Ticker_Start :: proc(ticker: ^Ticker, resetCounter: bool = true){
	ticker.running = true
	ticker.elapsedTime = 0
	ticker.lastTick = time.tick_now()
	if resetCounter do ticker.currentTick = 0
}
Ticker_Stop :: proc(ticker: ^Ticker) {
	ticker.running = false
}

Ticker_TogglePause :: proc(ticker: ^Ticker) {
	ticker.running = !ticker.running
}

Ticker_Pause :: proc(ticker: ^Ticker) {
	ticker.running = false
}
Ticker_Resume :: proc(ticker: ^Ticker) {
	ticker.running = true
}

// Sets the tick rate (0 to 120 per second; 0 never ticks)
Ticker_SetFPS :: proc(ticker: ^Ticker, framesPerSecond: f32) {
	framesPerSecond := clamp(framesPerSecond, 0, 120)
	ticker.framesPerSecond = framesPerSecond
	ticker.secondsPerFrame = framesPerSecond > 0 ? time.Duration(f64(time.Second) / f64(framesPerSecond)) : 0
}

Ticker_Reset :: proc(ticker: ^Ticker) {
	ticker.elapsedTime = 0
	ticker.currentTick = 0
}
