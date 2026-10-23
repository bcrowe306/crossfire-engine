#+build !js
package crossfire

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// Animation assets: frame durations, repeats and Aseprite's directions in the player; Aseprite
// tags as animations; .anim.xml files; scene files' AnimatedSprites playing one; scripts switching

// A 4-cell sheet animation with no texture (the player only counts cells)
@(private="file")
cells :: proc(name: string, count: int, mode := AnimationPlayMode.Forward, loop := false, fps: f32 = 10) -> ^SpriteSheetAnimation {
	return CreateSpriteSheetAnimation(name, nil, count, 1, fps, loop, playMode = mode)
}

@(test)
animations_have_frame_durations_repeats_and_reverse_ping_pong :: proc(t: ^testing.T) {
	player: AnimationPlayer
	AnimationPlayer_Init(&player)
	defer AnimationPlayer_Destroy(&player)

	// Each frame its own duration: 0.1, 0.3, 0.1, 0.1
	timed := cells("timed", 4, loop = true)
	Animation_SetDurations(timed, {0.1, 0.3, 0.1, 0.1})
	AnimationPlayer_Add(&player, timed)
	AnimationPlayer_Play(&player, "timed")
	AnimationPlayer_Update(&player, 0.15)
	testing.expect_value(t, player.frame, 1)
	AnimationPlayer_Update(&player, 0.2)
	testing.expect_value(t, player.frame, 1) // 0.35 in: frame 1 lasts until 0.4
	AnimationPlayer_Update(&player, 0.06)
	testing.expect_value(t, player.frame, 2)
	testing.expect_value(t, Animation_FrameDuration(timed, 3), f32(0.1))
	testing.expect_value(t, Animation_FrameDuration(timed, 7), f32(0.1)) // Past them: 1 / fps

	// Played twice, then it ends: 2 frames at 10 fps, so 0.4 s
	twice := cells("twice", 2)
	twice.repeat = 2
	AnimationPlayer_Add(&player, twice)
	AnimationPlayer_Play(&player, "twice")
	AnimationPlayer_Update(&player, 0.25)
	testing.expect(t, player.playing && player.frame == 0, "into its second time")
	AnimationPlayer_Update(&player, 0.2)
	testing.expect(t, !player.playing && player.finished, "done after two")

	// A ping-pong's repeat counts passes, as Aseprite does: 3 is there, back and there again,
	// stopping on the last frame; 0 is there and back
	passes := cells("passes", 3, .PingPong)
	passes.repeat = 3
	AnimationPlayer_Add(&player, passes)
	AnimationPlayer_Play(&player, "passes")
	path := make([dynamic]int)
	defer delete(path)
	append(&path, player.frame)
	for _ in 0 ..< 8 {
		AnimationPlayer_Update(&player, 0.1)
		append(&path, player.frame)
	}
	testing.expectf(t, slice.equal(path[:], []int{0, 1, 2, 1, 0, 1, 2, 2, 2}) && !player.playing, "0 1 2 1 0 1 2, then done: %v", path[:])
	passes.repeat = 0
	AnimationPlayer_Play(&player, "passes")
	clear(&path)
	append(&path, player.frame)
	for _ in 0 ..< 6 {
		AnimationPlayer_Update(&player, 0.1)
		append(&path, player.frame)
	}
	testing.expectf(t, slice.equal(path[:], []int{0, 1, 2, 1, 0, 0, 0}) && !player.playing, "there and back: %v", path[:])

	// A listener switching animations as a frame shows: no events of the frame left behind (and
	// the frame-event subject is freed with the player: the test's allocator checks)
	{
		evented: AnimationPlayer
		AnimationPlayer_Init(&evented)
		defer AnimationPlayer_Destroy(&evented)
		a := cells("a", 2, loop = true)
		b := cells("b", 2, loop = true)
		Animation_SetEvents(b, {"B0", "B1"})
		AnimationPlayer_Add(&evented, a)
		AnimationPlayer_Add(&evented, b)
		Seen :: struct { events: [dynamic]string }
		seen := Seen{}
		defer delete(seen.events)
		Event_Subscribe(&evented.onFrameEvent, proc(_: ^EventSubject, _: rawptr, data: EventData, userData: rawptr) {
			append(&(cast(^Seen)userData).events, data.(string))
		}, &seen)
		Event_Subscribe(&evented.onFrameChanged, proc(_: ^EventSubject, source: rawptr, data: EventData, _: rawptr) {
			p := cast(^AnimationPlayer)source
			if p.current == 1 && data.(int) == 1 do AnimationPlayer_Play(p, "a")
		}, nil)
		AnimationPlayer_Play(&evented, "b")
		AnimationPlayer_Update(&evented, 0.1)
		testing.expectf(t, evented.current == 0 && !slice.contains(seen.events[:], "B1"), "switched to a, no B1: %v", seen.events[:])
	}

	// Reverse ping-pong: from the end, to the start and back
	back := cells("back", 3, .PingPongReverse, loop = true)
	AnimationPlayer_Add(&player, back)
	AnimationPlayer_Play(&player, "back")
	seen := make([dynamic]int)
	defer delete(seen)
	append(&seen, player.frame)
	for _ in 0..<5 {
		AnimationPlayer_Update(&player, 0.1)
		append(&seen, player.frame)
	}
	testing.expectf(t, len(seen) == 6 && seen[0] == 2 && seen[1] == 1 && seen[2] == 0 && seen[3] == 1 && seen[4] == 2 && seen[5] == 1, "2 1 0 1 2 1: %v", seen[:])

	// Cleared: nothing plays
	AnimationPlayer_Clear(&player)
	testing.expect(t, len(player.animations) == 0 && player.current == -1 && len(player.names) == 0, "cleared")
}

@(test)
aseprite_tags_are_animations :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("testdata/aseprite/tags3.aseprite", context.temp_allocator)
	testing.expect(t, err == nil, "read")
	ase, parseErr := Aseprite_Parse(data)
	testing.expect_value(t, parseErr, AsepriteError.None)
	if ase == nil do return
	defer Aseprite_Destroy(ase)
	set := AnimationSet_FromAseprite(ase, "assets/tags3.aseprite")
	defer AnimationSetData_Destroy(&set)
	testing.expect_value(t, len(set.animations), 3)
	for a in set.animations {
		testing.expect_value(t, a.sheet, "assets/tags3.aseprite#sheet")
		testing.expect_value(t, a.grid, SheetGrid{mode = .Cells, columns = 4, rows = 3})
	}
	if len(set.animations) == 3 {
		forward, reverse, pingpong := set.animations[0], set.animations[1], set.animations[2]
		testing.expect(t, forward.name == "forward" && forward.start == 0 && forward.end == 3 && forward.playMode == .Forward, "forward 0-3")
		testing.expect(t, reverse.start == 4 && reverse.end == 7 && reverse.playMode == .Reverse, "reverse 4-7")
		testing.expect_value(t, pingpong.playMode, AnimationPlayMode.PingPong)
		testing.expect(t, forward.loop && forward.repeat == 0, "no repeat count: it loops, as in Aseprite")
		testing.expect_value(t, len(forward.durations), 4)
		testing.expect_value(t, forward.durations[0], f32(ase.frames[0].duration) / 1000)
	}

	// Repeat counts: plays that many times, then ends
	repsData, _ := os.read_entire_file("testdata/aseprite/tags3x123reps.aseprite", context.temp_allocator)
	reps, _ := Aseprite_Parse(repsData)
	if reps == nil do return
	defer Aseprite_Destroy(reps)
	counted := AnimationSet_FromAseprite(reps, "reps.aseprite")
	defer AnimationSetData_Destroy(&counted)
	for a, i in counted.animations {
		testing.expectf(t, a.repeat == reps.tags[i].repeat && a.loop == (reps.tags[i].repeat == 0), "%s: repeat %d", a.name, a.repeat)
	}
	testing.expect(t, reps.tags[0].repeat > 0, "the file has repeat counts")
}

@(test)
animation_set_files_and_sprites_using_them :: proc(t: ^testing.T) {
	text := `<?xml version="1.0" encoding="UTF-8"?>
<animations formatVersion="13" texture="tags3.aseprite#sheet" columns="4" rows="3" autoplay="hit">
	<animation name="idle" start="0" end="3" fps="6" loop="true"/>
	<animation name="hit" start="4" end="6" durations="100 60 200" repeat="2" playMode="PingPongReverse"/>
</animations>`
	set, err := ParseAnimationSet(text)
	defer AnimationSetData_Destroy(&set)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect(t, set.autoplay == "hit", "the first")
	for a in set.animations do testing.expect(t, a.sheet == "tags3.aseprite#sheet" && a.grid.columns == 4 && a.grid.rows == 3, "the file's sheet is every animation's (format 13)")
	testing.expect_value(t, len(set.animations), 2)
	if len(set.animations) == 2 {
		hit := set.animations[1]
		testing.expect(t, len(hit.durations) == 3 && hit.durations[1] == 0.06 && hit.repeat == 2 && hit.playMode == .PingPongReverse, "hit")
	}
	_, wrong := ParseAnimationSet(`<scene name="S"/>`)
	testing.expect_value(t, wrong, ProjectError.Wrong_Root)

	// A scene's AnimatedSprite playing an Aseprite file (its tags, on its sheet)
	surface := sdl.CreateSurface(32, 32, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := testGame("testdata/aseprite")
	defer { Game_Destroy(game); free(game) }
	game.resourceManager.renderer = renderer
	scene := game->createScene("S")
	data, parseErr := ParseScene(`<scene formatVersion="13" name="S">
		<node kind="AnimatedSprite" name="Hero" animations="tags3.aseprite" autoplay="pingpong"/>
		<node kind="AnimatedSprite" name="Plain" texture="tags3.aseprite" columns="2" rows="2"/>
	</scene>`)
	// Format 14: a sheet per animation (the file's frames; its first frame cut into 2 x 2 px cells)
	twoData, twoErr := ParseScene(`<scene formatVersion="14" name="S">
		<node kind="AnimatedSprite" name="Two" autoplay="frames">
			<animation name="frames" sheet="tags3.aseprite#sheet" columns="4" rows="3" end="3" loop="true"/>
			<animation name="cells" sheet="tags3.aseprite" grid="Size" cellWidth="2" cellHeight="2" loop="true"/>
		</node>
	</scene>`)
	defer SceneData_Destroy(&twoData)
	testing.expect_value(t, twoErr, ProjectError.None)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, parseErr, ProjectError.None)
	testing.expect_value(t, data.nodes[0].animationSet, "tags3.aseprite")
	created := Scene_Build(scene, &data, game.projectDir)
	hero := cast(^AnimatedSprite)created[0]
	testing.expect_value(t, len(hero.animation.animations), 3)
	testing.expect_value(t, AnimationPlayer_CurrentName(&hero.animation), "pingpong")
	testing.expect_value(t, AnimationPlayer_FrameSize(&hero.animation), [2]f32{4, 4})
	testing.expect_value(t, len(AnimationPlayer_Current(&hero.animation).durations), 4)
	// Its own sheet and animations still work beside it: the file's first frame, 2 x 2 cells
	plain := cast(^AnimatedSprite)created[1]
	testing.expect_value(t, AnimationPlayer_FrameSize(&plain.animation), [2]f32{2, 2})
	two := cast(^AnimatedSprite)Scene_Build(scene, &twoData, game.projectDir)[0]
	testing.expect_value(t, AnimationPlayer_CurrentName(&two.animation), "frames")
	testing.expect_value(t, AnimationPlayer_FrameSize(&two.animation), [2]f32{4, 4})
	file, frames := AnimatedSprite_Source(two)
	testing.expect(t, strings.has_suffix(file, "tags3.aseprite") && frames, "the file's frames: slices follow them")
	testing.expect(t, AnimationPlayer_Play(&two.animation, "cells"), "the other sheet")
	testing.expect_value(t, AnimationPlayer_FrameSize(&two.animation), [2]f32{2, 2})
	testing.expect_value(t, AnimationPlayer_Current(&two.animation)->sourceFrameCount(), 4)
	file, frames = AnimatedSprite_Source(two)
	testing.expect(t, file != "" && !frames, "the file's first frame in cells")
	// Read once
	testing.expect_value(t, len(game.animationSets), 1)

	// Scripts switch a sprite to another set; an unknown file is refused
	game.animationSets["more.anim.xml"] = new_clone(ParseAnimationSet(text, Game_GetAllocator(game)) or_else AnimationSetData{}, Game_GetAllocator(game))
	testing.expect(t, AnimatedSprite_UseAnimations(hero, AnimationAsset{"more.anim.xml"}), "switched")
	testing.expect_value(t, len(hero.animation.animations), 2)
	testing.expect_value(t, AnimationPlayer_CurrentName(&hero.animation), "hit")
	{
		context.logger = log.nil_logger()
		testing.expect(t, !AnimatedSprite_UseAnimations(hero, AnimationAsset{"missing.anim.xml"}), "a missing file")
	}
	free_all(context.temp_allocator)
}
