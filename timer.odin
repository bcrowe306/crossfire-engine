package engine

import "core:time"

/*
A countdown driven by the delta time it's given (`timer->update(timer, deltaTime)`, usually from a
node's update): it sends `onTick` on every update while running, and `onExpire` when `duration`
has passed. A looping timer starts over (keeping any overshoot, so it doesn't drift); otherwise
it stops. Being driven by delta time, it pauses with a hitstop and anything else that stops time.

Example:
	Spawner :: struct {
		using node: e.Node,
		timer: e.Timer,
	}
	e.TimerNode_Init(&spawner.timer, 2 * time.Second, auto_start = true, loop = true, allocator = e.Node_GetAllocator(spawner))
	spawner.timer.onExpire->subscribe(proc(_: ^e.EventSubject, _: rawptr, _: e.EventData, user: rawptr) {
		// every two seconds
	}, spawner)
	// In the node's update:
	spawner.timer->update(f32(deltaTime))
*/
Timer :: struct {
	// Time run since it (re)started
	elapsed: time.Duration,
	// Whether `update` advances it
	running: bool,
	// How long until it expires
	duration: time.Duration,
	// Start over when it expires (otherwise it stops)
	loop: bool,
	// Every update while running; the data is the elapsed seconds (f32)
	onTick: EventSubject,
	// When it expires; the data is the overshoot in seconds (f32)
	onExpire: EventSubject,
	// Method-style procedures: `timer->start()`, `timer->setDuration(seconds)`, `timer->update(dt)`
	start: proc(timer: ^Timer),
	setDuration: proc(timer: ^Timer, durationSec: f32),
	update: proc(timer: ^Timer, deltaTime: f32),
}

/*
Prepares a timer.

Inputs:
- timer: The timer
- duration: How long until it expires
- auto_start: Start running now
- loop: Start over each time it expires
- allocator: For the event listener lists; inside a node, pass `Node_GetAllocator(node)`
*/
TimerNode_Init :: proc(timer: ^Timer, duration: time.Duration, auto_start: bool = false, loop: bool = false, allocator := context.allocator) {
	EventSubject_Init(&timer.onTick, allocator)
	EventSubject_Init(&timer.onExpire, allocator)
	timer.start = TimerNode_Start
	timer.update = TimerNode_Update
	timer.setDuration = TimerNode_SetDuration
	timer.elapsed = 0
	timer.duration = duration
	timer.loop = loop
	timer.running = auto_start
}

/*
Makes and prepares a timer.

Inputs:
- durationSeconds: How long until it expires
- auto_start: Start running now
- loop: Start over each time it expires
- allocator: For the timer and its listener lists; inside a node, pass `Node_GetAllocator(node)`

Returns:
- The timer (freed with the allocator)
*/
TimerNode_Create :: proc(durationSeconds: f32, auto_start: bool = false, loop: bool = false, allocator := context.allocator) -> ^Timer {
	timer := new(Timer, allocator)
	TimerNode_Init(timer, time.Duration(f64(durationSeconds) * f64(time.Second)), auto_start, loop, allocator)
	return timer
}

// Starts (or restarts) a timer from zero
TimerNode_Start :: proc(timer: ^Timer) {
	timer.elapsed = 0
	timer.running = true
}

// Stops a timer where it is (`timer.running = true` resumes it)
TimerNode_Stop :: proc(timer: ^Timer) {
	timer.running = false
}

/*
Advances a running timer: `onTick`, then `onExpire` if its duration has passed (once per update,
however far past it is).

Inputs:
- timer: The timer
- deltaTime: Seconds since the last update
*/
TimerNode_Update :: proc(timer: ^Timer, deltaTime: f32) {
	if !timer.running do return
	timer.elapsed += time.Duration(f64(deltaTime) * f64(time.Second))
	timer.onTick->notify(timer, f32(time.duration_seconds(timer.elapsed)))
	if timer.elapsed < timer.duration do return
	overshoot := timer.elapsed - timer.duration
	if timer.loop {
		// Keep the overshoot, so a looping timer keeps its rhythm; at most one period's worth
		timer.elapsed = timer.duration > 0 ? overshoot % timer.duration : 0
	} else {
		timer.elapsed = 0
		timer.running = false
	}
	timer.onExpire->notify(timer, f32(time.duration_seconds(overshoot)))
}

// Sets how long a timer runs before it expires, in seconds (its elapsed time is kept)
TimerNode_SetDuration :: proc(timer: ^Timer, durationSec: f32) {
	timer.duration = time.Duration(f64(durationSec) * f64(time.Second))
}
