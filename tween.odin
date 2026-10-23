package crossfire

import sdl "vendor:sdl3"

/*
Tweens: values animated over time, step by step, with easing (easing.odin). A tween belongs to a
node: it runs while that node may process (`Node_CanProcess`: pausing stops it), at the game's time
scale, and is killed when the node is removed, so it never writes into freed memory. Animate the
node's own fields (or anything that lives as long as it does).

Steps run one after another; `Tween_Parallel` makes the next step run together with the previous
one. A value step starts from wherever the value is when the step begins (`Tween_FromTo` for a
set start).

Tweens are freed when they finish or are killed: making one per hit or per pickup is fine.

Example:
	// Given: coin: ^e.Node
	// A coin pops up and fades out, then goes
	tween := e.Tween_Create(coin)
	e.Tween_To(tween, &coin.position, coin.position + {0, -24}, 0.4, .OutBack)
	e.Tween_Parallel(tween)
	e.Tween_To(tween, &coin.tint, sdl.Color{255, 255, 255, 0}, 0.4)
	e.Tween_Call(tween, proc(user: rawptr) {
		node := cast(^e.Node)user
		e.Scene_RemoveNode(node.scene, node.id)
	}, coin)
*/
Tween :: struct {
	// The node it belongs to (nil: the scene's own, `Scene_CreateTween`)
	owner: ^Node,
	// The scene whose update runs it
	scene: ^Scene,
	// Its steps, in order (heap-allocated, freed with the tween)
	steps: [dynamic]TweenStep,
	// Index of the first step of the group running now
	current: int,
	// Seconds into the group running now
	elapsed: f32,
	// Times to play it again after the first (-1: forever)
	loops: int,
	// Multiplies its time (1 normal)
	speed: f32,
	// Set by Tween_Pause; it stays where it is
	paused: bool,
	// Finished or killed: freed at the next update
	done: bool,
	// The next step added runs together with the last one
	parallelNext: bool,
}

// What a tween step changes
TweenValue :: union {
	^f32,
	^[2]f32,
	^sdl.Color,
}

// One step of a tween
TweenStep :: struct {
	// The value it animates; nil for a delay or a callback
	target: TweenValue,
	// Its start and end (as up to 4 floats: f32, [2]f32 or a color's channels)
	from, to: [4]f32,
	// The start was given (Tween_FromTo); otherwise it's read when the step begins
	fromGiven: bool,
	// It has begun in the current play (reset each loop)
	started: bool,
	// Seconds it lasts (0 for a callback)
	duration: f32,
	// The curve from `from` to `to` (easing.odin)
	ease: EaseType,
	// Called when the step runs (a Tween_Call step)
	callback: proc(user: rawptr),
	// Passed to `callback`
	user: rawptr,
	// Runs together with the step before it
	parallel: bool,
}

/*
Makes a tween owned by a node (in the node's scene). Add steps to it right away; it starts on the
scene's next update.

Inputs:
- owner: The node it belongs to: it runs while the node may process, and dies with it

Returns:
- The tween (freed when it finishes or is killed; don't keep the pointer past that)

Example:
	tween := e.Tween_Create(node)
	e.Tween_To(tween, &node.scale, [2]f32{1.2, 1.2}, 0.15, .OutQuad)
	e.Tween_To(tween, &node.scale, [2]f32{1, 1}, 0.15, .InQuad)
*/
Tween_Create :: proc(owner: ^Node) -> ^Tween {
	tween := makeTween(owner.scene)
	tween.owner = owner
	return tween
}

/*
Makes a tween that belongs to the scene itself (no node): it runs while the scene isn't paused,
and dies with the scene. Only animate values that live as long as the scene.

Inputs:
- scene: The scene

Returns:
- The tween (freed when it finishes or is killed; don't keep the pointer past that)
*/
Scene_CreateTween :: proc(scene: ^Scene) -> ^Tween {
	return makeTween(scene)
}

@(private="file")
makeTween :: proc(scene: ^Scene) -> ^Tween {
	// The heap, not the node's or scene's arena: tweens come and go, and arenas don't give memory back
	tween := new(Tween, heapAllocator())
	tween.scene = scene
	tween.steps = make([dynamic]TweenStep, heapAllocator())
	tween.speed = 1
	append(&scene.tweens, tween)
	return tween
}

/*
Adds a step that animates a value to `to` over `duration` seconds, from wherever it is when the
step begins.

Inputs:
- tween: The tween
- target: The value: an f32, a [2]f32 (positions, scales) or an sdl.Color (tints)
- to: The value at the end
- duration: Seconds
- ease: The curve (easing.odin)

Returns:
- The tween, to chain more steps

Example:
	// Given: tween: ^e.Tween
	e.Tween_To(tween, &node.position, node.position + {0, -40}, 0.5, .OutQuad)
	e.Tween_To(tween, &node.tint, sdl.Color{255, 255, 255, 0}, 0.3)
*/
Tween_To :: proc{Tween_ToF32, Tween_ToVector, Tween_ToColor}

// `Tween_To` for an f32
Tween_ToF32 :: proc(tween: ^Tween, target: ^f32, to: f32, duration: f32, ease := EaseType.Linear) -> ^Tween {
	return addValueStep(tween, target, {to, 0, 0, 0}, duration, ease)
}

// `Tween_To` for a [2]f32 (positions, scales)
Tween_ToVector :: proc(tween: ^Tween, target: ^[2]f32, to: [2]f32, duration: f32, ease := EaseType.Linear) -> ^Tween {
	return addValueStep(tween, target, {to.x, to.y, 0, 0}, duration, ease)
}

// `Tween_To` for an sdl.Color (each channel animated, rounded to the nearest value)
Tween_ToColor :: proc(tween: ^Tween, target: ^sdl.Color, to: sdl.Color, duration: f32, ease := EaseType.Linear) -> ^Tween {
	return addValueStep(tween, target, {f32(to.r), f32(to.g), f32(to.b), f32(to.a)}, duration, ease)
}

/*
Like `Tween_To`, from a given start (the value jumps to `from` when the step begins, and again on
each loop).

Inputs:
- tween: The tween
- target: The value: an f32, a [2]f32 (positions, scales) or an sdl.Color (tints)
- from: The value at the start
- to: The value at the end
- duration: Seconds
- ease: The curve (easing.odin)

Returns:
- The tween, to chain more steps

Example:
	// Given: tween: ^e.Tween
	e.Tween_FromTo(tween, &node.tint, sdl.Color{255, 255, 255, 0}, sdl.Color{255, 255, 255, 255}, 0.5)
*/
Tween_FromTo :: proc{Tween_FromToF32, Tween_FromToVector, Tween_FromToColor}

// `Tween_FromTo` for an f32
Tween_FromToF32 :: proc(tween: ^Tween, target: ^f32, from, to: f32, duration: f32, ease := EaseType.Linear) -> ^Tween {
	addValueStep(tween, target, {to, 0, 0, 0}, duration, ease)
	setFrom(tween, {from, 0, 0, 0})
	return tween
}

// `Tween_FromTo` for a [2]f32 (positions, scales)
Tween_FromToVector :: proc(tween: ^Tween, target: ^[2]f32, from, to: [2]f32, duration: f32, ease := EaseType.Linear) -> ^Tween {
	addValueStep(tween, target, {to.x, to.y, 0, 0}, duration, ease)
	setFrom(tween, {from.x, from.y, 0, 0})
	return tween
}

// `Tween_FromTo` for an sdl.Color
Tween_FromToColor :: proc(tween: ^Tween, target: ^sdl.Color, from, to: sdl.Color, duration: f32, ease := EaseType.Linear) -> ^Tween {
	addValueStep(tween, target, {f32(to.r), f32(to.g), f32(to.b), f32(to.a)}, duration, ease)
	setFrom(tween, {f32(from.r), f32(from.g), f32(from.b), f32(from.a)})
	return tween
}

/*
Adds a pause before the next step.

Inputs:
- tween: The tween
- seconds: Length of the pause (negative counts as 0)

Returns:
- The tween, to chain more steps
*/
Tween_Delay :: proc(tween: ^Tween, seconds: f32) -> ^Tween {
	addStep(tween, TweenStep{duration = max(seconds, 0)})
	return tween
}

/*
Adds a step that calls `callback(user)` (once per play, including each loop), then goes on.

Inputs:
- tween: The tween
- callback: Called when the step is reached
- user: Passed to the callback (nil if unused); it must still be valid then

Returns:
- The tween, to chain more steps

Example:
	// Given: tween: ^e.Tween
	e.Tween_Call(tween, proc(user: rawptr) { log.info("done") }, nil)
*/
Tween_Call :: proc(tween: ^Tween, callback: proc(user: rawptr), user: rawptr) -> ^Tween {
	addStep(tween, TweenStep{callback = callback, user = user})
	return tween
}

/*
Makes the next step added run together with the last one. Consecutive parallel steps form a group,
which ends with its longest step. Does nothing when the tween has no steps yet.

Inputs:
- tween: The tween

Returns:
- The tween, to chain more steps
*/
Tween_Parallel :: proc(tween: ^Tween) -> ^Tween {
	tween.parallelNext = true
	return tween
}

/*
Sets how many more times the tween plays after the first. Each loop starts its steps again from
the values as they are then (`Tween_FromTo` steps jump back to their start).

Inputs:
- tween: The tween
- count: Extra plays after the first (0: once, -1: forever)

Returns:
- The tween, to chain more steps
*/
Tween_SetLoops :: proc(tween: ^Tween, count: int) -> ^Tween {
	tween.loops = count
	return tween
}

/*
Pauses or resumes a tween where it is.

Inputs:
- tween: The tween
- paused: true to pause, false to resume
*/
Tween_Pause :: proc(tween: ^Tween, paused: bool) {
	tween.paused = paused
}

/*
Stops a tween where it is; it's freed at the scene's next update. Its remaining callbacks don't run.

Inputs:
- tween: The tween
*/
Tween_Kill :: proc(tween: ^Tween) {
	tween.done = true
}

/*
Tells whether a tween is still going. Only valid until the update that frees a finished tween:
don't call it on a pointer you kept longer.

Inputs:
- tween: The tween

Returns:
- true while it isn't finished or killed (a paused tween is running)
*/
Tween_IsRunning :: proc(tween: ^Tween) -> bool {
	return !tween.done
}

/*
Moves a scene's tweens on by `deltaTime` seconds and frees finished ones. Scene_Update calls it
after the nodes update.
*/
@(private)
Scene_UpdateTweens :: proc(scene: ^Scene, deltaTime: f64) {
	// By index: a callback may make more tweens
	for i := 0; i < len(scene.tweens); i += 1 {
		tween := scene.tweens[i]
		if tween.done || tween.paused do continue
		canRun := tween.owner != nil ? Node_CanProcess(tween.owner) : !scene.paused
		if canRun do advance(tween, f32(deltaTime) * tween.speed)
	}
	kept := 0
	for tween in scene.tweens {
		if tween.done {
			freeTween(tween)
			continue
		}
		scene.tweens[kept] = tween
		kept += 1
	}
	resize(&scene.tweens, kept)
}

// Kills the tweens a removed node owned (processRemovals), before the node's memory goes
@(private)
killTweensOf :: proc(scene: ^Scene, pending: ^map[^Node]bool) {
	for tween in scene.tweens do if tween.owner != nil && tween.owner in pending {
		tween.done = true
		tween.owner = nil
	}
}

// Frees every tween of a scene (Scene_Destroy)
@(private)
destroyTweens :: proc(scene: ^Scene) {
	for tween in scene.tweens do freeTween(tween)
	delete(scene.tweens)
}

@(private="file")
freeTween :: proc(tween: ^Tween) {
	delete(tween.steps)
	free(tween, heapAllocator())
}

@(private="file")
addValueStep :: proc(tween: ^Tween, target: TweenValue, to: [4]f32, duration: f32, ease: EaseType) -> ^Tween {
	addStep(tween, TweenStep{target = target, to = to, duration = max(duration, 0), ease = ease})
	return tween
}

@(private="file")
addStep :: proc(tween: ^Tween, step: TweenStep) {
	step := step
	step.parallel = tween.parallelNext && len(tween.steps) > 0
	tween.parallelNext = false
	append(&tween.steps, step)
}

@(private="file")
setFrom :: proc(tween: ^Tween, from: [4]f32) {
	step := &tween.steps[len(tween.steps) - 1]
	step.from = from
	step.fromGiven = true
}

// The group of steps starting at `first`: up to the next step that isn't parallel
@(private="file")
groupEnd :: proc(tween: ^Tween, first: int) -> int {
	end := first + 1
	for end < len(tween.steps) && tween.steps[end].parallel do end += 1
	return end
}

@(private="file")
advance :: proc(tween: ^Tween, dt: f32) {
	dt := dt
	// Several short groups can pass in one update; a bound keeps zero-length loops finite
	for _ in 0 ..< 1024 {
		if tween.current >= len(tween.steps) {
			if tween.loops == 0 {
				tween.done = true
				return
			}
			if tween.loops > 0 do tween.loops -= 1
			tween.current = 0
			for &step in tween.steps do step.started = false
			if len(tween.steps) == 0 {
				tween.done = true
				return
			}
		}
		end := groupEnd(tween, tween.current)
		groupTime: f32 = 0
		for &step in tween.steps[tween.current:end] {
			groupTime = max(groupTime, step.duration)
			if !step.started do beginStep(&step)
		}
		tween.elapsed += dt
		for &step in tween.steps[tween.current:end] do applyStep(&step, tween.elapsed)
		if tween.elapsed < groupTime || tween.done do return
		// The group's done: carry the rest of the time into the next one
		dt = tween.elapsed - groupTime
		tween.elapsed = 0
		tween.current = end
		if dt <= 0 && tween.current < len(tween.steps) do dt = 0
	}
}

@(private="file")
beginStep :: proc(step: ^TweenStep) {
	step.started = true
	if step.callback != nil {
		step.callback(step.user)
		return
	}
	if step.fromGiven do return
	switch target in step.target {
	case ^f32:       step.from = {target^, 0, 0, 0}
	case ^[2]f32:    step.from = {target.x, target.y, 0, 0}
	case ^sdl.Color: step.from = {f32(target.r), f32(target.g), f32(target.b), f32(target.a)}
	}
}

@(private="file")
applyStep :: proc(step: ^TweenStep, elapsed: f32) {
	if step.target == nil do return
	t: f32 = step.duration > 0 ? clamp(elapsed / step.duration, 0, 1) : 1
	k := Ease(step.ease, t)
	v := step.from + (step.to - step.from) * k
	switch target in step.target {
	case ^f32:       target^ = v[0]
	case ^[2]f32:    target^ = {v[0], v[1]}
	case ^sdl.Color: target^ = {u8(clamp(v[0] + 0.5, 0, 255)), u8(clamp(v[1] + 0.5, 0, 255)), u8(clamp(v[2] + 0.5, 0, 255)), u8(clamp(v[3] + 0.5, 0, 255))}
	}
}
