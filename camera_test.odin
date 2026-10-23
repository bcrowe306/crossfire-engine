#+build !js
package crossfire

import "core:log"
import "core:testing"
import sdl "vendor:sdl3"

// A camera's follow target and settings (camera.odin): following a moving node by itself, the
// offset, look-ahead, per-side limits with zoom, shake settings, scene files

@(private="file")
near :: proc(a, b: [2]f32, tolerance: f32 = 0.5) -> bool {
	return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

@(private="file")
nearF :: proc(a, b: f32, tolerance: f32 = 0.5) -> bool {
	return abs(a - b) <= tolerance
}

// A node moving right at `speed` px/s
@(private="file")
Mover :: struct {
	using node: Node,
	speed: f32,
}

@(private="file")
moverUpdate :: proc(node: ^Node, _: []sdl.Event, deltaTime: f64) {
	m := cast(^Mover)node
	m.position.x += m.speed * f32(deltaTime)
}

@(test)
cameras_follow_their_target :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.size = {320, 180}
	scene := game->createScene("S")
	hero := CreateNode(scene, Mover)
	hero.update = moverUpdate
	hero.position = {1000, 500}
	camera := Scene_CreateCamera(scene)
	camera.follow.mode = .Exponential
	Camera2D_SetFollowTarget(camera, hero)
	testing.expect_value(t, Camera2D_GetFollowTarget(camera), cast(^Node)hero)

	// The first frame snaps onto it, plus the offset
	camera.follow.offset = {0, -40}
	Scene_Update(scene, nil, 1.0 / 60)
	testing.expectf(t, near(Camera2D_GetTarget(camera), {1000, 460}), "snapped onto the target: %v", Camera2D_GetTarget(camera))

	// It moves: an easing camera trails it, then catches up once it stops
	hero.speed = 300
	for _ in 0 ..< 30 do Scene_Update(scene, nil, 1.0 / 60)
	at := Camera2D_GetTarget(camera)
	testing.expectf(t, at.x > 1000 && at.x < hero.position.x, "trails the moving target: %v vs %v", at, hero.position)
	hero.speed = 0
	for _ in 0 ..< 240 do Scene_Update(scene, nil, 1.0 / 60)
	testing.expectf(t, near(Camera2D_GetTarget(camera), hero.position + {0, -40}), "caught up: %v", Camera2D_GetTarget(camera))

	// Snap mode: exactly on it every frame while it moves
	camera.follow.mode = .Snap
	hero.speed = 120
	for _ in 0 ..< 10 do Scene_Update(scene, nil, 1.0 / 60)
	testing.expect(t, near(Camera2D_GetTarget(camera), hero.position + {0, -40}, 0.01), "snaps every frame")

	// A pan pauses the following; afterwards it follows again
	hero.speed = 0
	Camera2D_MoveTo(camera, {0, 0}, 0.5, .Linear)
	for _ in 0 ..< 15 do Scene_Update(scene, nil, 1.0 / 60)
	testing.expect(t, Camera2D_IsMoving(camera) && Camera2D_GetTarget(camera).x < 1000, "panning, not following")
	for _ in 0 ..< 30 do Scene_Update(scene, nil, 1.0 / 60)
	testing.expect(t, !Camera2D_IsMoving(camera) && near(Camera2D_GetTarget(camera), hero.position + {0, -40}), "following again after the pan")

	// Removed: it stops following and stays put
	before := Camera2D_GetTarget(camera)
	Scene_RemoveNode(scene, hero.id)
	Scene_Update(scene, nil, 1.0 / 60)
	testing.expect(t, Camera2D_GetFollowTarget(camera) == nil, "the removed target is gone")
	testing.expect_value(t, Camera2D_GetTarget(camera), before)
	Camera2D_SetFollowTarget(camera, nil)
	testing.expect(t, Camera2D_GetFollowTarget(camera) == nil, "cleared")
}

@(test)
cameras_look_ahead_and_offset :: proc(t: ^testing.T) {
	camera: Camera2D
	camera.zoom = 1
	camera.follow = {mode = .Snap, offset = {10, 20}, lookAhead = {50, 30}}
	// Still: only the offset
	for _ in 0 ..< 3 do Camera2D_Follow(&camera, {100, 100}, 1.0 / 60)
	testing.expect_value(t, camera.position, [2]f32{110, 120})
	// Moving right and up at 120 px/s: looks 50 ahead to the right, 30 up (at once: no smoothing)
	p := [2]f32{100, 100}
	for _ in 0 ..< 10 {
		p += {2, -2}
		Camera2D_Follow(&camera, p, 1.0 / 60)
	}
	testing.expectf(t, near(camera.position, p + {10, 20} + {50, -30}, 0.01), "looks ahead: %v", camera.position - p)
	// Moving left: it swings to the left
	for _ in 0 ..< 3 {
		p.x -= 2
		Camera2D_Follow(&camera, p, 1.0 / 60)
	}
	testing.expect(t, nearF(camera.position.x, p.x + 10 - 50, 0.01), "swung left")
	// Standing still: back to none
	Camera2D_Follow(&camera, p, 1.0 / 60)
	testing.expect(t, near(camera.position, p + {10, 20}, 0.01), "centered again when still")

	// Smoothed: it eases toward the full distance
	camera.follow.lookAheadSmoothing = 4
	camera.lookAhead = {}
	Camera2D_Follow(&camera, p, 1.0 / 60)
	for _ in 0 ..< 15 {
		p.x += 2
		Camera2D_Follow(&camera, p, 1.0 / 60)
	}
	ahead := camera.position.x - p.x - 10
	testing.expectf(t, ahead > 5 && ahead < 50, "easing ahead: %v", ahead)
	for _ in 0 ..< 240 {
		p.x += 2
		Camera2D_Follow(&camera, p, 1.0 / 60)
	}
	testing.expect(t, nearF(camera.position.x, p.x + 10 + 50, 0.1), "all the way ahead")
	// A hitstop's zero delta changes nothing
	before := camera.position
	Camera2D_Follow(&camera, p, 0)
	testing.expect_value(t, camera.position, before)
}

@(test)
camera_limits_clamp_per_side :: proc(t: ^testing.T) {
	camera: Camera2D
	camera.zoom = 1
	camera.offset = {160, 90}
	view := [2]f32{320, 180}
	// The left side only: never left of 0, free to the right and up and down
	Camera2D_SetLimit(&camera, .Left, 0)
	testing.expect_value(t, Camera2D_GetLimits(&camera), CameraSides{.Left})
	camera.position = {-500, -500}
	Camera2D_ClampToBounds(&camera, view)
	testing.expect_value(t, camera.position, [2]f32{160, -500})
	camera.position = {99999, 99999}
	Camera2D_ClampToBounds(&camera, view)
	testing.expect_value(t, camera.position, [2]f32{99999, 99999})
	// And the bottom, zoomed in 2x: half the view is 80 x 45 world pixels
	Camera2D_SetLimit(&camera, .Bottom, 720)
	camera.zoom = 2
	Camera2D_ClampToBounds(&camera, view)
	testing.expect_value(t, camera.position, [2]f32{99999, 675})
	camera.position = {-500, 0}
	Camera2D_ClampToBounds(&camera, view)
	testing.expect_value(t, camera.position, [2]f32{80, 0})
	// Top and bottom closer than the view is tall: centered between them
	Camera2D_SetLimit(&camera, .Top, 700)
	Camera2D_ClampToBounds(&camera, view)
	testing.expect_value(t, camera.position.y, f32(710))
	// Freeing sides: the last one unbounds it
	Camera2D_ClearLimit(&camera, .Top)
	Camera2D_ClearLimit(&camera, .Bottom)
	testing.expect(t, camera.bounded && Camera2D_GetLimits(&camera) == {.Left}, "the left still limits")
	Camera2D_ClearLimit(&camera, .Left)
	testing.expect(t, !camera.bounded && Camera2D_GetLimits(&camera) == {}, "unbounded")
	// SetBounds limits all four again
	Camera2D_SetLimit(&camera, .Right, 100)
	Camera2D_SetBounds(&camera, {0, 0}, {1000, 1000})
	testing.expect_value(t, Camera2D_GetLimits(&camera), CAMERA_ALL_SIDES)
}

@(private="file")
FOLLOW_SCENE :: `<scene formatVersion="14" name="S">
	<node kind="Node2D" name="World">
		<node kind="Node2D" name="Hero" x="400" y="300"/>
	</node>
	<node kind="Camera" name="Cam" x="0" y="0" zoom="2" target="../World/Hero" followMode="Snap"
	      deadzoneX="40" deadzoneY="20" targetOffsetX="0" targetOffsetY="-30" lookAheadX="60"
	      lookAheadSmoothing="0" limitLeft="0" limitTop="-50" limitBottom="400" limitsOff="Top" shakeStrength="9" shakeDuration="0.5"
	      shakeFrequency="20"/>
	<node kind="Camera" name="Second" x="0" y="0" target="/World/Hero" followMode="Snap"/>
	<node kind="Camera" name="Lost" target="Nobody"/>
</scene>`

@(test)
camera_settings_from_scene_files :: proc(t: ^testing.T) {
	data, err := ParseScene(FOLLOW_SCENE)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	c := data.nodes[2].camera
	testing.expect(t, data.nodes[2].cameraTarget == "../World/Hero" && c.follow.mode == .Snap && c.follow.deadzone == {40, 20}, "follow parsed")
	testing.expect(t, c.follow.offset == {0, -30} && c.follow.lookAhead == {60, 0} && c.follow.lookAheadSmoothing == 0, "offset and look-ahead parsed")
	// limitsOff: the top's value is kept, but the top isn't limited
	testing.expectf(t, c.limits == {.Left, .Bottom} && c.limitMin == {0, -50} && c.limitMax.y == 400, "limits parsed: %v", c)
	testing.expect(t, c.shake == CameraShakeSettings{9, 0.5, 20}, "shake parsed")
	testing.expect(t, data.nodes[4].camera == DEFAULT_CAMERA_SETTINGS && data.nodes[0].cameraTarget == "", "defaults elsewhere")

	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.size = {320, 180}
	scene := game->createScene("S")
	created := Scene_Build(scene, &data, "testdata", attachScripts = false)
	hero, camera, second := created[1], cast(^Camera2D)created[2], cast(^Camera2D)created[3]
	testing.expect_value(t, scene.camera, camera)
	testing.expect(t, camera.bounded && Camera2D_GetLimits(camera) == {.Left, .Bottom} && camera.shakeSettings.frequency == 20, "built with its settings")
	{
		// "Lost" warns once that its target isn't there
		context.logger = log.nil_logger()
		Scene_Update(scene, nil, 1.0 / 60)
	}
	// Snapped onto the hero, 30 above; the bottom limit (400, zoom 2: 45 px below the middle)
	// holds it at 355 at most
	testing.expectf(t, near(Camera2D_GetTarget(camera), {400, 270}), "on the hero: %v", Camera2D_GetTarget(camera))
	testing.expectf(t, near(Camera2D_GetTarget(second), {400, 300}), "the second camera follows too: %v", Camera2D_GetTarget(second))

	// The hero walks right past the dead zone: the camera looks 60 ahead
	for _ in 0 ..< 20 {
		hero.position.x += 3
		Scene_Update(scene, nil, 1.0 / 60)
	}
	at := Camera2D_GetTarget(camera)
	testing.expectf(t, near(at, {hero.position.x + 60 - 20, 270}), "ahead, held at the dead zone's edge: %v (hero %v)", at, hero.position)
	// Down past the bottom limit: held there
	hero.position.y = 2000
	for _ in 0 ..< 5 do Scene_Update(scene, nil, 1.0 / 60)
	testing.expectf(t, nearF(Camera2D_GetTarget(camera).y, 355), "the bottom limit: %v", Camera2D_GetTarget(camera))
	// Left of the left limit: held 80 right of it (zoom 2)
	hero.position.x = -1000
	for _ in 0 ..< 5 do Scene_Update(scene, nil, 1.0 / 60)
	testing.expectf(t, nearF(Camera2D_GetTarget(camera).x, 80), "the left limit: %v", Camera2D_GetTarget(camera))

	// Its shake settings: a shake without arguments uses them, eased at 20 Hz
	Camera2D_Shake(camera)
	testing.expect(t, camera.shake.strength == 9 && camera.shake.duration == 0.5 && camera.shake.frequency == 20, "shakes by its settings")
	for _ in 0 ..< 3 do Camera2D_UpdateShake(camera, 0.01)
	offset := camera.shake.offset
	testing.expect(t, offset != {} && abs(offset.x) <= 9 && abs(offset.y) <= 9, "shaking within its strength")
	Camera2D_Shake(camera, 2, 0.1) // weaker than what's left: ignored
	testing.expect_value(t, camera.shake.strength, f32(9))
	for _ in 0 ..< 60 do Camera2D_UpdateShake(camera, 0.01)
	testing.expect_value(t, camera.shake.offset, [2]f32{})
	free_all(context.temp_allocator)
}
