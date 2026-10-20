#+build !js
package crossfire

import "core:log"
import "core:testing"

// AnimationPlayer: frames over time in each play mode, looping and ending, speed, pause, stop,
// seeking, events, restarting, names. Sprite sheet animations without a texture: only frames.

@(private="file")
Events :: struct {
	frames: [dynamic]int,
	started, changed, ended, looped, stopped: int,
}

@(private="file")
listen :: proc(player: ^AnimationPlayer, ev: ^Events) {
	player.onFrameChanged->subscribe(proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
		append(&(cast(^Events)user).frames, data.(int))
	}, ev)
	count :: proc(subject: ^EventSubject, field: ^int) {
		subject->subscribe(proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) { (cast(^int)user)^ += 1 }, field)
	}
	count(&player.onAnimationStarted, &ev.started)
	count(&player.onAnimationChanged, &ev.changed)
	count(&player.onAnimationEnded, &ev.ended)
	count(&player.onAnimationLooped, &ev.looped)
	count(&player.onAnimationStopped, &ev.stopped)
}

// Frames visited by `steps` updates of one frame time each (after the first frame)
@(private="file")
run :: proc(player: ^AnimationPlayer, steps: int, fps: f32 = 10) -> [dynamic]int {
	frames := make([dynamic]int, context.temp_allocator)
	append(&frames, player.frame)
	for _ in 0 ..< steps {
		AnimationPlayer_Update(player, f64(1 / fps) + 1e-6)
		append(&frames, player.frame)
	}
	return frames
}

@(private="file")
same :: proc(a: []int, b: []int) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

@(test)
animations_step_through_their_frames :: proc(t: ^testing.T) {
	player: AnimationPlayer
	AnimationPlayer_Init(&player)
	defer AnimationPlayer_Destroy(&player)
	// A 4 x 2 sheet: "walk" plays cells 2..5
	AnimationPlayer_Add(&player, CreateSpriteSheetAnimation("walk", nil, 4, 2, fps = 10, loop = true, startFrame = 2, endFrame = 5))
	AnimationPlayer_Add(&player, CreateSpriteSheetAnimation("back", nil, 4, 1, fps = 10, loop = true, playMode = .Reverse))
	AnimationPlayer_Add(&player, CreateSpriteSheetAnimation("bounce", nil, 4, 1, fps = 10, loop = true, playMode = .PingPong))
	AnimationPlayer_Add(&player, CreateSpriteSheetAnimation("once", nil, 3, 1, fps = 10))
	AnimationPlayer_Add(&player, CreateSpriteSheetAnimation("bounceOnce", nil, 3, 1, fps = 10, playMode = .PingPong))
	testing.expect_value(t, AnimationPlayer_Get(&player, "walk")->totalFrames(), 4)

	ev: Events
	defer delete(ev.frames)
	listen(&player, &ev)

	testing.expect(t, AnimationPlayer_Play(&player, "walk"), "plays")
	testing.expect(t, same(run(&player, 5)[:], {0, 1, 2, 3, 0, 1}), "forward, looping")
	testing.expect_value(t, ev.looped, 1)

	AnimationPlayer_Play(&player, "back")
	testing.expect(t, same(run(&player, 5)[:], {3, 2, 1, 0, 3, 2}), "reverse, looping")
	AnimationPlayer_Play(&player, "bounce")
	testing.expect(t, same(run(&player, 7)[:], {0, 1, 2, 3, 2, 1, 0, 1}), "ping-pong")

	ev.ended = 0
	AnimationPlayer_Play(&player, "once")
	testing.expect(t, same(run(&player, 4)[:], {0, 1, 2, 2, 2}), "a one-shot holds its last frame")
	testing.expect(t, player.finished && !player.playing && ev.ended == 1, "ended once")
	AnimationPlayer_Resume(&player)
	testing.expect(t, !player.playing, "a finished animation doesn't resume")

	AnimationPlayer_Play(&player, "bounceOnce")
	testing.expect(t, same(run(&player, 6)[:], {0, 1, 2, 1, 0, 0, 0}), "a one-shot ping-pong ends back at the start")
	testing.expect_value(t, ev.ended, 2)

	// A long update covers several frames
	AnimationPlayer_Play(&player, "walk")
	AnimationPlayer_Update(&player, 0.35)
	testing.expect_value(t, player.frame, 3)
	// Speed multiplies time; 0 freezes it
	AnimationPlayer_Play(&player, "walk", restart = true)
	player.speed = 2
	AnimationPlayer_Update(&player, 0.1)
	testing.expect_value(t, player.frame, 2)
	player.speed = 0
	AnimationPlayer_Update(&player, 1)
	testing.expect_value(t, player.frame, 2)
	player.speed = 1
	free_all(context.temp_allocator)
}

@(test)
animation_controls_and_events :: proc(t: ^testing.T) {
	player: AnimationPlayer
	AnimationPlayer_Init(&player)
	defer AnimationPlayer_Destroy(&player)
	idle := AnimationPlayer_Add(&player, CreateSpriteSheetAnimation("idle", nil, 4, 1, fps = 10, loop = true))
	AnimationPlayer_Add(&player, CreateSpriteSheetAnimation("run", nil, 4, 1, fps = 10, loop = true))
	ev: Events
	defer delete(ev.frames)
	listen(&player, &ev)

	// Names and indices
	{
		context.logger = log.nil_logger() // the refusals warn
		testing.expect_value(t, AnimationPlayer_Add(&player, CreateSpriteSheetAnimation("idle", nil, 1, 1, fps = 1, allocator = context.temp_allocator)), -1)
		testing.expect(t, !AnimationPlayer_Play(&player, "missing") && !AnimationPlayer_Play(&player, 9), "unknown")
	}
	index, found := AnimationPlayer_IndexOf(&player, "run")
	testing.expect(t, found && index == 1, "index of run")
	testing.expect(t, AnimationPlayer_Current(&player) == nil && AnimationPlayer_CurrentName(&player) == "", "nothing playing")

	AnimationPlayer_Play(&player, idle)
	testing.expect(t, ev.started == 1 && ev.changed == 1 && len(ev.frames) == 1, "started, changed, first frame")
	AnimationPlayer_Update(&player, 0.15)
	// Playing it again doesn't restart it; restart does
	AnimationPlayer_Play(&player, "idle")
	testing.expect(t, player.frame == 1 && ev.started == 1, "kept going")
	AnimationPlayer_Play(&player, "idle", restart = true)
	testing.expect(t, player.frame == 0 && ev.started == 2 && ev.changed == 1, "restarted, not changed")
	AnimationPlayer_Play(&player, "run")
	testing.expect(t, ev.changed == 2 && player.previous == idle && AnimationPlayer_IsPlaying(&player, "run"), "changed to run")

	// Pause keeps the frame; resume goes on
	AnimationPlayer_Update(&player, 0.15)
	AnimationPlayer_Pause(&player)
	AnimationPlayer_Update(&player, 1)
	testing.expect_value(t, player.frame, 1)
	AnimationPlayer_Resume(&player)
	AnimationPlayer_Update(&player, 0.1)
	testing.expect_value(t, player.frame, 2)
	// Seeking clamps and doesn't change whether it plays
	AnimationPlayer_SetFrame(&player, 99)
	testing.expect(t, player.frame == 3 && player.playing, "clamped, still playing")
	// Stop rewinds and says so
	AnimationPlayer_Stop(&player)
	testing.expect(t, player.frame == 0 && !player.playing && ev.stopped == 1, "stopped, rewound")
	// A listener switching animations mid-update stops that update
	player.onAnimationLooped->subscribe(proc(_: ^EventSubject, source: rawptr, _: EventData, _: rawptr) {
		AnimationPlayer_Play(cast(^AnimationPlayer)source, "idle")
	}, nil)
	AnimationPlayer_Play(&player, "run")
	AnimationPlayer_Update(&player, 0.45) // would loop at 0.4 and carry on
	testing.expect(t, AnimationPlayer_CurrentName(&player) == "idle" && player.frame == 0, "switched by the listener, not advanced")
	free_all(context.temp_allocator)
}

@(test)
cameras_follow_clamp_and_pan :: proc(t: ^testing.T) {
	near :: proc(a, b: [2]f32, tolerance: f32 = 0.5) -> bool {
		return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
	}
	camera: Camera2D
	camera.zoom = 1
	camera.offset = {160, 90}

	// Each mode reaches the target, frame-rate independent
	for mode in CameraFollowMode {
		camera.position = {}
		camera.velocity = {}
		camera.follow = DEFAULT_CAMERA_FOLLOW
		camera.follow.mode = mode
		for _ in 0 ..< 240 do Camera2D_Follow(&camera, {100, 50}, 1.0 / 60)
		testing.expectf(t, near(Camera2D_GetTarget(&camera), {100, 50}), "%v reaches the target: %v", mode, Camera2D_GetTarget(&camera))
	}
	// Snap: at once
	camera.position = {}
	camera.follow = {mode = .Snap}
	Camera2D_Follow(&camera, {30, 40}, 1.0 / 60)
	testing.expect_value(t, camera.position, [2]f32{30, 40})
	// Linear: at its speed
	camera.position = {}
	camera.follow = {mode = .Linear, speed = 60}
	Camera2D_Follow(&camera, {1000, 0}, 0.5)
	testing.expect(t, near(camera.position, {30, 0}), "30 px in half a second")
	// A dead zone: small moves don't move it; past it, it keeps the target on its edge
	camera.position = {}
	camera.follow = {mode = .Snap, deadzone = {40, 40}}
	Camera2D_Follow(&camera, {15, 0}, 1.0 / 60)
	testing.expect_value(t, camera.position, [2]f32{0, 0})
	Camera2D_Follow(&camera, {50, 0}, 1.0 / 60)
	testing.expect_value(t, camera.position, [2]f32{30, 0})
	// A speed cap (every mode but Snap, which always jumps)
	camera.position = {}
	camera.follow = {mode = .Exponential, smoothing = 1000, maxSpeed = 100}
	Camera2D_Follow(&camera, {1000, 0}, 0.1)
	testing.expect(t, near(camera.position, {10, 0}), "capped at 100 px/s")

	// Bounds keep the view inside; a world smaller than the view is centered
	camera.follow = {mode = .Snap}
	Camera2D_SetBounds(&camera, {0, 0}, {1000, 500})
	camera.position = {-50, 9999}
	Camera2D_Update(&camera, {320, 180}, 1.0 / 60)
	testing.expect_value(t, camera.position, [2]f32{160, 410})
	Camera2D_SetBounds(&camera, {0, 0}, {100, 100})
	Camera2D_Update(&camera, {320, 180}, 1.0 / 60)
	testing.expect_value(t, camera.position, [2]f32{50, 50})
	Camera2D_ClearBounds(&camera)

	// A timed pan: following waits for it; it lands exactly
	camera.position = {}
	Camera2D_MoveTo(&camera, {200, 100}, 1, .Linear)
	Camera2D_Follow(&camera, {-500, -500}, 1.0 / 60)
	testing.expect_value(t, camera.position, [2]f32{0, 0})
	for _ in 0 ..< 30 do Camera2D_Update(&camera, {320, 180}, 1.0 / 60)
	testing.expect(t, near(camera.position, {100, 50}), "halfway at half time")
	for _ in 0 ..< 30 do Camera2D_Update(&camera, {320, 180}, 1.0 / 60)
	testing.expect(t, camera.position == {200, 100} && !camera.move.active, "landed")

	// Screen and world agree, zoomed and rotated
	camera.zoom = 2.5
	camera.rotation = 30
	for point in ([][2]f32{{0, 0}, {123, -45}, {-300, 700}}) {
		back := Camera2D_ScreenToWorld(&camera, Camera2D_WorldToScreen(&camera, point))
		testing.expectf(t, near(back, point, 0.01), "%v round trips: %v", point, back)
	}
	testing.expect(t, near(Camera2D_WorldToScreen(&camera, camera.position), camera.offset, 0.001), "the target is at the offset")
}
