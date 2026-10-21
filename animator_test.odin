#+build !js
package crossfire

import "core:testing"
import sdl "vendor:sdl3"

// Animator nodes (animator.odin): clips from a scene file playing other nodes' properties

@(private="file")
ANIMATOR_SCENE :: `<scene formatVersion="13" name="S">
	<node kind="Node2D" name="Room">
		<node kind="Sprite" name="Box" x="5" y="5"/>
		<node kind="Node2D" name="Hero">
			<script name="TestScript"/>
		</node>
		<node kind="Animator" name="Anim" autoplay="move" speed="1">
			<clip name="move" length="1">
				<track node="Box" property="position">
					<key time="1" value="100, 50"/>
					<key time="0" value="0, 10"/>
				</track>
				<track node="Box" property="opacity">
					<key time="0" value="1" ease="InQuad"/>
					<key time="1" value="0"/>
				</track>
				<track node="Box" property="visible">
					<key time="0" value="true"/>
					<key time="0.8" value="false"/>
				</track>
				<track node="Hero" property="script.speed">
					<key time="0" value="0"/>
					<key time="1" value="-10"/>
				</track>
				<track node="Hero" property="script.mood">
					<key time="0" value="Calm"/>
					<key time="0.5" value="Angry"/>
				</track>
				<track node="Hero" property="script.tint">
					<key time="0" value="#000000"/>
					<key time="1" value="#ffffff"/>
				</track>
				<track node="." property="rotation" step="true">
					<key time="0" value="0"/>
					<key time="0.5" value="90"/>
					<key time="1" value="180"/>
				</track>
				<track property="event">
					<key time="0" value="start"/>
					<key time="0.5" value="middle"/>
					<key time="1" value="end"/>
				</track>
			</clip>
			<clip name="spin" length="0.5" loop="true">
				<track node="Box" property="rotation">
					<key time="0" value="0"/>
					<key time="0.5" value="360"/>
				</track>
				<track property="event"><key time="0.25" value="lap"/></track>
			</clip>
		</node>
	</node>
</scene>`

@(private="file")
AnimatorLog :: struct {
	events: [dynamic]string,
	finished: [dynamic]string,
}

@(test)
animators_play_clips_from_scene_files :: proc(t: ^testing.T) {
	registerTestScript()
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	sceneData, err := ParseScene(ANIMATOR_SCENE)
	defer SceneData_Destroy(&sceneData)
	testing.expect_value(t, err, ProjectError.None)
	data := sceneData.nodes[3].animator
	testing.expect(t, len(data.clips) == 2 && data.autoplay == "move", "parsed")
	// Keys come sorted
	testing.expect_value(t, data.clips[0].tracks[0].keys[0].time, f32(0))
	testing.expect_value(t, data.clips[0].tracks[1].keys[0].ease, EaseType.InQuad)
	clone := AnimatorSettings_Clone(data)
	testing.expect(t, AnimatorSettings_Equal(clone, data), "a clone is equal")
	kept := clone.clips[0].tracks[0].keys[0].value
	clone.clips[0].tracks[0].keys[0].value = "1, 1"
	testing.expect(t, !AnimatorSettings_Equal(clone, data), "a changed key isn't")
	clone.clips[0].tracks[0].keys[0].value = kept
	AnimatorSettings_Destroy(&clone)

	created := Scene_Build(scene, &sceneData, "testdata")
	room, box, hero := created[0], created[1], created[2]
	anim := cast(^Animator)created[3]
	log := AnimatorLog{events = make([dynamic]string, context.temp_allocator), finished = make([dynamic]string, context.temp_allocator)}
	Event_Subscribe(&anim.onEvent, proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
		append(&(cast(^AnimatorLog)user).events, data.(string))
	}, &log)
	Event_Subscribe(&anim.onFinished, proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
		append(&(cast(^AnimatorLog)user).finished, data.(string))
	}, &log)

	// The first update starts the autoplay clip at 0: its first keys, the event at 0
	Scene_Update(scene, nil, 0)
	testing.expect(t, Animator_IsPlaying(anim) && Animator_CurrentClip(anim) == "move", "autoplay")
	testing.expect_value(t, box.position, [2]f32{0, 10})
	testing.expect_value(t, box.tint.a, u8(255))
	testing.expect(t, len(log.events) == 1 && log.events[0] == "start", "the event at 0")
	script := Node_GetScript(hero, TestScript)
	testing.expect_value(t, script.mood, TestMood.Calm)

	Scene_Update(scene, nil, 0.25)
	testing.expect_value(t, box.position, [2]f32{25, 20})
	// InQuad: 1 - 0.25² of the way from 1 to 0
	testing.expect_value(t, box.tint.a, u8(239))
	// The field's min (0) holds it
	testing.expect_value(t, script.speed, f32(0))
	testing.expect_value(t, script.tint, sdl.Color{64, 64, 64, 255})
	testing.expect_value(t, room.rotation, f32(0))

	Scene_Update(scene, nil, 0.5)
	testing.expect_value(t, box.position, [2]f32{75, 40})
	testing.expect(t, box.visible, "visible until 0.8")
	testing.expect_value(t, script.mood, TestMood.Angry)
	testing.expect_value(t, room.rotation, f32(90))
	testing.expect(t, len(log.events) == 2 && log.events[1] == "middle", "the event at 0.5")

	// Past the end: the last keys, the end's event, then finished
	Scene_Update(scene, nil, 0.5)
	testing.expect_value(t, box.position, [2]f32{100, 50})
	testing.expect(t, !box.visible, "hidden from 0.8")
	testing.expect_value(t, room.rotation, f32(180))
	testing.expect(t, len(log.events) == 3 && log.events[2] == "end", "the event at the end")
	testing.expect(t, len(log.finished) == 1 && log.finished[0] == "move", "finished")
	testing.expect(t, !Animator_IsPlaying(anim), "stopped")

	// A looping clip: around and around, its event once a lap
	clear(&log.events)
	testing.expect(t, Animator_Play(anim, "spin"), "spin")
	Scene_Update(scene, nil, 0.375)
	testing.expect_value(t, box.rotation, f32(270))
	Scene_Update(scene, nil, 0.25)
	testing.expect(t, abs(box.rotation - 90) < 0.01, "around")
	testing.expect(t, Animator_IsPlaying(anim), "still playing")
	testing.expect_value(t, len(log.events), 1)
	// Pausing holds it; seeking sets the values without events
	Animator_Pause(anim, true)
	Scene_Update(scene, nil, 0.1)
	testing.expect(t, abs(box.rotation - 90) < 0.01, "held")
	Animator_Seek(anim, 0.25)
	testing.expect_value(t, box.rotation, f32(180))
	testing.expect_value(t, len(log.events), 1)
	Animator_Play(anim, "spin")
	testing.expect(t, Animator_IsPlaying(anim) && anim.time == 0.25, "resumed where it was")
	testing.expect(t, !Animator_Play(anim, "nothing"), "an unknown clip")
	Animator_Stop(anim)
	testing.expect(t, !Animator_IsPlaying(anim), "stopped")

	// Editors' scrubbing: values at a time, no events
	Animator_Apply(anim, 0, 0.5)
	testing.expect_value(t, box.position, [2]f32{50, 30})
	testing.expect_value(t, len(log.events), 1)

	// A target removed: the track does nothing (no crash)
	scene->removeNode(box.id)
	Scene_ProcessQueues(scene)
	Animator_Apply(anim, 0, 1)
	free_all(context.temp_allocator)
}

@(test)
animator_values_read_write_and_format :: proc(t: ^testing.T) {
	v, ok := Animator_ParseValue(.Vector, " 3, -4.5 ")
	testing.expect(t, ok && v.([2]f32) == {3, -4.5}, "vector")
	testing.expect_value(t, Animator_FormatValue([2]f32{3, -4.5}, context.temp_allocator), "3, -4.5")
	testing.expect_value(t, Animator_FormatValue(f32(0.25), context.temp_allocator), "0.25")
	testing.expect_value(t, Animator_FormatValue(f32(-0.00001), context.temp_allocator), "0")
	_, bad := Animator_ParseValue(.Float, "x")
	testing.expect(t, !bad, "not a number")
	c, cok := Animator_ParseValue(.Color, "#ff800080")
	testing.expect(t, cok && c.(sdl.Color) == {255, 128, 0, 128}, "color")
	kind, known := Animator_PropertyKind("scale.y")
	testing.expect(t, known && kind == .Float, "scale.y")
	_, unknown := Animator_PropertyKind("script.speed")
	testing.expect(t, !unknown, "script fields aren't built in")
	testing.expect(t, Animator_TypeHasProperty(AnimatedSprite, ANIMATOR_PROPERTIES[11]), "AnimatedSprite has animation")
	testing.expect(t, !Animator_TypeHasProperty(Sprite, ANIMATOR_PROPERTIES[11]), "Sprite hasn't")

	// Reading a node's values: what an editor records
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	node := CreateNode(scene, Node)
	node.position = {1.5, 2}
	node.tint = {255, 255, 255, 128}
	text, has := Animator_ReadProperty(node, "position", context.temp_allocator)
	testing.expect(t, has && text == "1.5, 2", "position")
	opacity, _ := Animator_ReadProperty(node, "opacity", context.temp_allocator)
	testing.expect_value(t, opacity, "0.502")
	_, none := Animator_ReadProperty(node, "text", context.temp_allocator)
	testing.expect(t, !none, "a Node has no text")

	// Clips from code
	anim := CreateAnimator(scene)
	Node_AddChild(node, anim)
	settings := AnimatorSettings{speed = 2}
	clip := AnimatorClipData{name = "grow", length = 1}
	track := AnimatorTrackData{property = "scale"}
	append(&track.keys, AnimatorKeyData{time = 0, value = "1, 1"}, AnimatorKeyData{time = 1, value = "3, 3"})
	append(&clip.tracks, track)
	append(&settings.clips, clip)
	Animator_SetClips(anim, settings)
	// Copied: the caller's to free (literals here, so only the lists)
	delete(track.keys)
	delete(clip.tracks)
	delete(settings.clips)
	Scene_ProcessQueues(scene)
	Animator_Play(anim, "grow")
	// Twice as fast: half way after a quarter second
	Scene_Update(scene, nil, 0.25)
	testing.expect_value(t, node.scale, [2]f32{2, 2})
	free_all(context.temp_allocator)
}
