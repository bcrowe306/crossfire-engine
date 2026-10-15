package engine

import "core:time"

Timer :: struct {
	elapsed: time.Duration,
	running: bool,
	duration: time.Duration,
	loop: bool,
	onTick: EventSubject,
	onExpire: EventSubject,
	start: proc(timer: ^Timer),
	setDuration: proc(timer: ^Timer, durationSec: f32),
	update: proc(timer: ^Timer, deltaTime: f32),
}

// allocator holds the event listener lists. Inside a node, pass Node_GetAllocator(node)
TimerNode_Init :: proc(timer: ^Timer, duration: time.Duration, auto_start: bool = false, loop: bool = false, allocator := context.allocator) {
	EventSubject_Init(&timer.onTick, allocator)
	EventSubject_Init(&timer.onExpire, allocator)
	timer.update = TimerNode_Update
	timer.setDuration = TimerNode_SetDuration
	timer.elapsed = 0
	timer->setDuration(f32(duration / time.Second))
	timer.loop = loop
	timer.running = auto_start
}

// The timer and its listener lists use allocator. Inside a node, pass Node_GetAllocator(node)
TimerNode_Create :: proc(durationSeconds: f32, auto_start: bool = false, loop: bool = false, allocator := context.allocator) -> ^Timer {
	timer := new(Timer, allocator)
	TimerNode_Init(timer, time.Duration(durationSeconds * f32(time.Second)), auto_start, loop, allocator)
	return timer
}

TimerNode_Update :: proc(timer: ^Timer, deltaTime: f32) {
	if timer.running {
		timer.elapsed += time.Duration(deltaTime * f32(time.Second))
	}
	if timer.elapsed >= timer.duration {
		timer.onExpire->notify(timer, f32(0))
		if timer.loop {
			timer.elapsed = 0
			timer.running = true
		}
		else {
			timer.elapsed = 0
			timer.running = false
		}
	}
}

TimerNode_SetDuration :: proc(timer: ^Timer, durationSec: f32) {
	timer.duration = time.Duration(durationSec * f32(time.Second))
}
