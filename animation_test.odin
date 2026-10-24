#+build !js
package crossfire

import "core:fmt"
import "core:log"
import "core:slice"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

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

// Sheet grids starting off the corner, sheets cut into rectangles, their format
@(test)
sheet_grids_with_offsets_and_rectangles :: proc(t: ^testing.T) {
	// The grid starts 4 px right and 10 px down: cells share (or fill) what's past that
	cells := SheetGrid{mode = .Cells, columns = 2, rows = 1, margin = 1, offset = {4, 10}}
	_, _, cell := SheetGrid_Layout(cells, {46, 30})
	testing.expect_value(t, cell, [2]f32{20, 18})
	testing.expect_value(t, SheetGrid_CellRect(cells, {46, 30}, 1), sdl.FRect{25, 11, 20, 18})
	sized := SheetGrid{mode = .Size, cellSize = {8, 8}, offset = {3, 0}}
	columns, rows, _ := SheetGrid_Layout(sized, {36, 8})
	testing.expect(t, columns == 4 && rows == 1, "4 cells fit past the offset")
	testing.expect_value(t, SheetGrid_CellRect(sized, {36, 8}, 0), sdl.FRect{3, 0, 8, 8})
	testing.expect_value(t, SheetGrid_Leftover(sized, {36, 8}), [2]f32{1, 0})

	// Rectangles instead of the grid
	rects := []sdl.FRect{{0, 4, 20, 12}, {24, 0, 18, 16}}
	testing.expect_value(t, Sheet_CellCount(cells, rects, {64, 16}), 2)
	testing.expect_value(t, Sheet_CellCount(cells, nil, {46, 30}), 2)
	testing.expect_value(t, Sheet_CellRect(cells, rects, {64, 16}, 1), sdl.FRect{24, 0, 18, 16})
	testing.expect_value(t, Sheet_CellRect(cells, rects, {64, 16}, 9), sdl.FRect{24, 0, 18, 16})
	testing.expect_value(t, Sheet_CellRect(cells, nil, {46, 30}, 0), sdl.FRect{5, 11, 20, 18})
	animation := CreateRectSheetAnimation("hop", nil, rects, 10, loop = true)
	defer Animation_Destroy(animation)
	testing.expect_value(t, animation->sourceFrameCount(), 2)
	testing.expect_value(t, animation->frameSize(0), [2]f32{20, 12})
	testing.expect_value(t, SpriteSheetAnimation_FrameRect(animation, 1), sdl.FRect{24, 0, 18, 16})
	grid := CreateSheetAnimation("walk", nil, cells, 8)
	defer Animation_Destroy(grid)
	testing.expect_value(t, grid.offset, [2]f32{4, 10})

	// The format: offsets and rectangles round trip, unreadable rectangles are left out
	text := FormatSheetRects(rects, context.temp_allocator)
	testing.expect_value(t, text, "0,4,20,12 24,0,18,16")
	back := ParseSheetRects(fmt.tprintf("%s 1,2,3 x,1,1,1 5,5,0,2", text))
	defer delete(back)
	testing.expect(t, slice.equal(back[:], rects), "read back")
	set, err := ParseAnimationSet(`<animations formatVersion="14">
		<animation name="hop" sheet="slime.png" rects="0,4,20,12 24,0,18,16" fps="10"/>
		<animation name="walk" sheet="walk.png" columns="2" offsetX="4" offsetY="10" margin="1"/>
	</animations>`)
	defer AnimationSetData_Destroy(&set)
	testing.expect_value(t, err, ProjectError.None)
	if testing.expect_value(t, len(set.animations), 2) {
		testing.expect(t, slice.equal(set.animations[0].rects[:], rects), "the rectangles")
		testing.expect_value(t, set.animations[1].grid.offset, [2]f32{4, 10})
		testing.expect_value(t, len(set.animations[1].rects), 0)
	}
	free_all(context.temp_allocator)
}

// Sprites found on sheets of uneven sprites: islands, merging, specks, reading order, a
// background color, a big sheet
@(test)
sheets_find_their_sprites :: proc(t: ^testing.T) {
	Sheet :: struct { pixels: []u8, w, h: int }
	make_sheet :: proc(w, h: int) -> Sheet { return {make([]u8, w * h * 4), w, h} }
	fill :: proc(s: Sheet, x, y, w, h: int, color := [4]u8{200, 50, 50, 255}) {
		for yy in y ..< y + h do for xx in x ..< x + w {
			p := s.pixels[(yy * s.w + xx) * 4:][:4]
			p[0], p[1], p[2], p[3] = color[0], color[1], color[2], color[3]
		}
	}
	sheet := make_sheet(64, 40)
	defer delete(sheet.pixels)
	// Row one: a body and its sword a pixel apart (one sprite), an L touching at a corner, a speck
	fill(sheet, 2, 2, 10, 12)
	fill(sheet, 13, 4, 2, 6)
	fill(sheet, 20, 2, 5, 5)
	fill(sheet, 25, 7, 4, 4)
	fill(sheet, 40, 3, 1, 1)
	// Row two, unevenly placed: drawn right first, it still reads left to right
	fill(sheet, 40, 24, 8, 10)
	fill(sheet, 4, 22, 12, 14)
	// Faint pixels don't count
	fill(sheet, 55, 2, 5, 5, {255, 255, 255, 40})
	found := Sheet_FindSprites(sheet.pixels, 64, 40)
	defer delete(found)
	expected := []sdl.FRect{{2, 2, 13, 12}, {20, 2, 9, 9}, {4, 22, 12, 14}, {40, 24, 8, 10}}
	testing.expectf(t, slice.equal(found, expected), "found %v", found)
	// Merging off: the sword is its own sprite; specks kept
	apart := Sheet_FindSprites(sheet.pixels, 64, 40, {threshold = 128, mergeDistance = 0, minSize = 0})
	defer delete(apart)
	testing.expect_value(t, len(apart), 6)
	// A low threshold takes the faint pixels too
	faint := Sheet_FindSprites(sheet.pixels, 64, 40, {threshold = 30, mergeDistance = 2, minSize = 4})
	defer delete(faint)
	testing.expect_value(t, len(faint), 5)
	// A far merge makes the first row one sprite
	far := Sheet_FindSprites(sheet.pixels, 64, 40, {threshold = 128, mergeDistance = 8, minSize = 4})
	defer delete(far)
	testing.expect_value(t, len(far), 2)

	// A sheet without transparency: its corner's color is the background
	opaque := make_sheet(32, 16)
	defer delete(opaque.pixels)
	fill(opaque, 0, 0, 32, 16, {255, 0, 255, 255})
	fill(opaque, 3, 3, 6, 6)
	fill(opaque, 20, 2, 8, 10)
	key, hasKey := Sheet_BackgroundKey(opaque.pixels, 32, 16)
	testing.expect(t, hasKey && key == {255, 0, 255}, "the corner's color")
	keyed := Sheet_FindSprites(opaque.pixels, 32, 16, {threshold = 128, mergeDistance = 2, minSize = 4, useKey = true, key = key})
	defer delete(keyed)
	testing.expect(t, slice.equal(keyed, []sdl.FRect{{3, 3, 6, 6}, {20, 2, 8, 10}}), "two sprites on magenta")
	_, transparentCorner := Sheet_BackgroundKey(sheet.pixels, 64, 40)
	testing.expect(t, !transparentCorner, "a transparent corner: no key")
	testing.expect_value(t, len(Sheet_FindSprites(nil, 0, 0)), 0)

	// A big sheet: 4096 x 4096, a 64 x 64 grid of uneven sprites
	big := make_sheet(4096, 4096)
	defer delete(big.pixels)
	for row in 0 ..< 64 do for column in 0 ..< 64 do fill(big, column * 64 + 4 + column % 7, row * 64 + 2 + row % 5, 30 + row % 20, 40 + column % 15)
	start := time.tick_now()
	many := Sheet_FindSprites(big.pixels, 4096, 4096)
	defer delete(many)
	elapsed := time.duration_milliseconds(time.tick_since(start))
	log.infof("Sheet_FindSprites on 4096 x 4096 (4096 sprites): %.0f ms", elapsed)
	testing.expect_value(t, len(many), 64 * 64)
	if len(many) == 64 * 64 {
		testing.expect_value(t, many[0], sdl.FRect{4, 2, 30, 40})
		testing.expect_value(t, many[65], sdl.FRect{64 + 4 + 1, 64 + 2 + 1, 31, 41})
	}
}
