#+build !js
package engine

import "core:testing"
import sdl "vendor:sdl3"

// Tweens: values over time, sequences and parallel groups, delays, callbacks, loops, pausing
// with their owner, the time scale, and dying with their owner.

@(private="file")
near :: proc(a, b: f32, tolerance: f32 = 0.001) -> bool { return abs(a - b) <= tolerance }

@(test)
tweens_animate_in_sequence_and_in_parallel :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	node := CreateNode(scene, Node)
	Scene_ProcessQueues(scene)

	@(static) calls: int
	calls = 0
	tween := Tween_Create(node)
	Tween_To(tween, &node.position, [2]f32{100, 0}, 1)  // 0..1 s
	Tween_Parallel(tween)
	Tween_To(tween, &node.rotation, 90, 0.5)            // with it, shorter
	Tween_Delay(tween, 0.5)                             // 1..1.5 s
	Tween_Call(tween, proc(_: rawptr) { calls += 1 }, nil)
	Tween_To(tween, &node.tint, sdl.Color{255, 255, 255, 0}, 1, .InQuad) // 1.5..2.5 s

	step :: proc(scene: ^Scene, seconds: f64) { Scene_UpdateTweens(scene, seconds) }
	step(scene, 0.25)
	testing.expect(t, near(node.position.x, 25) && near(node.rotation, 45), "both run")
	step(scene, 0.5)
	testing.expect(t, near(node.position.x, 75) && near(node.rotation, 90), "rotation done, position going")
	step(scene, 0.5) // 1.25: in the delay
	testing.expect(t, near(node.position.x, 100) && calls == 0, "position done; waiting")
	step(scene, 0.5) // 1.75: the call ran, the fade a quarter in (InQuad: 1/16)
	testing.expect_value(t, calls, 1)
	testing.expect_value(t, node.tint.a, u8(255 - 16))
	step(scene, 1)
	testing.expect(t, node.tint.a == 0 && !Tween_IsRunning(tween), "faded, finished")
	testing.expect_value(t, len(scene.tweens), 0) // freed
	free_all(context.temp_allocator)
}

@(test)
tweens_loop_start_from_given_values_and_carry_time :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	node := CreateNode(scene, Node)
	Scene_ProcessQueues(scene)
	tween := Tween_Create(node)
	Tween_FromTo(tween, &node.position, [2]f32{0, 0}, [2]f32{0, 10}, 1)
	Tween_SetLoops(tween, 1) // twice in all
	Scene_UpdateTweens(scene, 1.5)
	// Time past the end carries into the next play
	testing.expect(t, near(node.position.y, 5), "half way through the second play")
	Scene_UpdateTweens(scene, 1)
	testing.expect(t, !Tween_IsRunning(tween) && near(node.position.y, 10), "done after two")
	// Forever, until killed
	forever := Tween_Create(node)
	Tween_FromTo(forever, &node.rotation, 0, 10, 0.1)
	Tween_SetLoops(forever, -1)
	for _ in 0 ..< 100 do Scene_UpdateTweens(scene, 0.07)
	testing.expect(t, Tween_IsRunning(forever), "still looping")
	Tween_Kill(forever)
	Scene_UpdateTweens(scene, 0.01)
	testing.expect_value(t, len(scene.tweens), 0)
	free_all(context.temp_allocator)
}

@(test)
tweens_pause_scale_and_die_with_their_owner :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	node := CreateNode(scene, Node)
	ui := CreateNode(scene, Node)
	ui.processMode = .Always
	Scene_ProcessQueues(scene)
	a := Tween_Create(node)
	Tween_To(a, &node.position, [2]f32{10, 0}, 1)
	b := Tween_Create(ui)
	Tween_To(b, &ui.position, [2]f32{10, 0}, 1)

	// Paused scene: the gameplay node's tween waits, the UI's runs
	Scene_SetPaused(scene, true)
	Scene_Update(scene, nil, 0.5)
	testing.expect(t, node.position.x == 0 && near(ui.position.x, 5), "paused vs always")
	Scene_SetPaused(scene, false)
	// Pausing a tween itself
	Tween_Pause(a, true)
	Scene_Update(scene, nil, 0.25)
	testing.expect_value(t, node.position.x, f32(0))
	Tween_Pause(a, false)

	// Removing the owner kills its tween (it would write into freed memory)
	Scene_RemoveNode(scene, node.id)
	Scene_Update(scene, nil, 0.1)
	// a went with its node; the UI's tween is still running
	testing.expect(t, len(scene.tweens) == 1 && scene.tweens[0] == b, "only the UI's tween is left")
	// A scene's own tween, and a tween still running when the scene is destroyed, are freed
	value: f32
	Tween_To(Scene_CreateTween(scene), &value, 1, 10)
	free_all(context.temp_allocator)
}
