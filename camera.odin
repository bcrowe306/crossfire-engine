/*
2D camera support for scenes.

A scene can optionally own one Camera2D. While the scene draws, every layer that is
not listed in `scene.screenLayers` is drawn through the camera: all of the engine's
Draw* helpers (shapes, DrawTexture and text) take world coordinates and are transformed
to the screen automatically. Layers in `scene.screenLayers` are drawn untransformed,
which is what HUDs and menus want. A scene without a camera draws everything in screen
space, exactly as before.

The camera uses the same model as raylib's Camera2D:

	screen = rotate(world - target, rotation) * zoom + offset

Example:
	package mygame

	import e "../engine"
	import sdl "vendor:sdl3"

	WORLD_SIZE :: [2]f32{3840, 2160}
	HUD_LAYER  :: e.RenderLayer.Layer8

	Player :: struct {
		using node: e.Node,
		pos: [2]f32,
	}

	CreateLevelScene :: proc(game: ^e.Game) -> ^e.Scene {
		scene := game->createScene("Level")

		// Give the scene a camera. Its offset starts at the center of the screen, zoom at 1
		camera := e.Scene_CreateCamera(scene)

		// Optional: never show anything outside the level
		e.Camera2D_SetBounds(camera, {0, 0}, WORLD_SIZE)

		// Optional: draw the HUD layer in screen space, ignoring the camera
		scene.screenLayers = {HUD_LAYER}

		// Optional: tune how the camera follows. Defaults to .Exponential with smoothing 6
		camera.follow.mode = .SmoothDamp
		camera.follow.smoothTime = 0.3
		camera.follow.deadzone = {200, 120} // Player can move this much before the camera does

		player := e.CreateNode(scene, Player)
		player.pos = WORLD_SIZE * 0.5
		player.update = Player_update
		player.draw = Player_draw

		// Start the camera on the player instead of easing in from elsewhere
		e.Camera2D_SnapTo(camera, player.pos)
		return scene
	}

	Player_update :: proc(node: ^e.Node, events: []sdl.Event, deltaTime: f64) {
		player := cast(^Player)node
		camera := node.scene.camera

		for &event in events {
			#partial switch event.type {
			case .MOUSE_WHEEL:
				// Zoom in and out, within limits
				camera.zoom = clamp(camera.zoom + event.wheel.y * 0.1, 0.5, 3)

			case .MOUSE_BUTTON_DOWN:
				// Event positions are in screen space; convert to find the clicked world point
				clicked := e.Scene_ScreenToWorld(node.scene, {event.button.x, event.button.y})
				player.pos = clicked

			case .KEY_DOWN:
				// Cinematic pan to the center of the level. Following pauses until it ends
				if event.key.scancode == .C {
					e.Camera2D_MoveTo(camera, WORLD_SIZE * 0.5, 1.5, .InOutCubic)
				}
			}
		}

		// Ease the camera toward the player using camera.follow. Bounds are applied by the scene afterwards
		e.Camera2D_Follow(camera, player.pos, deltaTime)
	}

	Player_draw :: proc(node: ^e.Node, renderer: ^sdl.Renderer) {
		player := cast(^Player)node
		// World coordinates; the camera moves, rotates and zooms this for us
		e.DrawCircle(renderer, sdl.FPoint(player.pos), 24, {120, 200, 255, 255})
	}
*/

package engine

import "core:math"
import vmem "core:mem/virtual"

/*
How a camera tracks a moving position in `Camera2D_Follow`.
*/
CameraFollowMode :: enum {
	// Jump straight to the position every frame. No easing
	Snap,
	// Close a fraction of the remaining distance every frame: fast at first, slowing as it arrives.
	// Controlled by `CameraFollow.smoothing`
	Exponential,
	// Critically damped spring: accelerates and decelerates smoothly with no overshoot.
	// Feels the most natural for player cameras. Controlled by `CameraFollow.smoothTime`
	SmoothDamp,
	// Move toward the position at a constant speed. Controlled by `CameraFollow.speed`
	Linear,
}

/*
Settings for `Camera2D_Follow`. Each mode only reads its own strength setting;
`maxSpeed` and `deadzone` apply to every mode.
*/
CameraFollow :: struct {
	mode: CameraFollowMode,
	// .Exponential: how tightly to follow. Higher is tighter; around 4-10 feels natural
	smoothing: f32,
	// .SmoothDamp: roughly how many seconds the camera takes to catch up
	smoothTime: f32,
	// .Linear: world units per second
	speed: f32,
	// Caps how fast the camera can move, in world units per second. 0 = no limit
	maxSpeed: f32,
	// Size of a box, in world units and centered on the camera target, that the followed
	// position can move inside without moving the camera. {0, 0} disables it
	deadzone: [2]f32,
}

DEFAULT_CAMERA_FOLLOW :: CameraFollow{
	mode = .Exponential,
	smoothing = 6,
	smoothTime = 0.25,
	speed = 600,
}

/*
A 2D camera that maps world coordinates to screen coordinates.

	screen = rotate(world - target, rotation) * zoom + offset

Create one for a scene with `Scene_CreateCamera`, or assign your own to `scene.camera`.
A zero-initialized camera is usable: a zoom of 0 is treated as 1 and following snaps.
*/
Camera2D :: struct {
	// World position the camera looks at
	target: [2]f32,
	// Screen position where `target` appears. Usually the center of the screen (`game.size * 0.5`)
	offset: [2]f32,
	// Rotation in degrees, clockwise, around `offset`
	rotation: f32,
	// Scale factor. 1 is unscaled, 2 shows everything twice as big, 0.5 half as big
	zoom: f32,

	// When true, the scene clamps `target` every frame so the view stays inside `min..max`.
	// Set with `Camera2D_SetBounds`. Rotation is not taken into account, so a rotated
	// view can show slightly past the bounds at its corners
	bounded: bool,
	// Top-left corner of the world boundary, used when `bounded` is true
	min: [2]f32,
	// Bottom-right corner of the world boundary, used when `bounded` is true
	max: [2]f32,

	// How `Camera2D_Follow` eases toward the followed position
	follow: CameraFollow,

	// Internal state; read it if useful but don't modify it
	velocity: [2]f32, // Current follow velocity in world units per second (.SmoothDamp)
	move: CameraMove, // Active `Camera2D_MoveTo` pan
}

// State of a `Camera2D_MoveTo` pan
CameraMove :: struct {
	active: bool,
	from, to: [2]f32,
	duration, elapsed: f32,
	ease: EaseType,
}

/*
Creates a camera for a scene and makes it the scene's active camera.

The camera's offset and target are both set to the center of the game resolution,
so world and screen coordinates line up until the camera is moved. Following uses
`DEFAULT_CAMERA_FOLLOW`. The camera is allocated from the scene's arena and freed with the scene.

Inputs:
- scene: The scene to attach the camera to

Returns:
- The new camera, also stored in `scene.camera`

Example:
	camera := e.Scene_CreateCamera(scene)
	camera.zoom = 2
*/
Scene_CreateCamera :: proc(scene: ^Scene) -> ^Camera2D {
	camera := new(Camera2D, vmem.arena_allocator(&scene.arena))
	camera.zoom = 1
	camera.follow = DEFAULT_CAMERA_FOLLOW
	if scene.game != nil {
		camera.offset = scene.game.size * 0.5
		camera.target = camera.offset
	}
	scene.camera = camera
	return camera
}

/*
Restricts the camera so the visible area stays inside a world rectangle.

When the scene owns the camera, the bounds are applied automatically each frame after
the scene's nodes update. If the bounds are smaller than the view on an axis, the
camera is centered on that axis instead.

Inputs:
- camera: The camera to restrict
- min: Top-left corner of the allowed world area
- max: Bottom-right corner of the allowed world area

Example:
	e.Camera2D_SetBounds(camera, {0, 0}, {3840, 2160})
*/
Camera2D_SetBounds :: proc(camera: ^Camera2D, min, max: [2]f32) {
	camera.bounded = true
	camera.min = min
	camera.max = max
}

/*
Removes the boundaries set with `Camera2D_SetBounds`, letting the camera move freely.

Inputs:
- camera: The camera to unrestrict
*/
Camera2D_ClearBounds :: proc(camera: ^Camera2D) {
	camera.bounded = false
}

/*
Converts a world position to the screen position it is drawn at.

Inputs:
- camera: The camera to transform through
- world: Position in world coordinates

Returns:
- Position in screen (game resolution) coordinates

Example:
	// Draw a screen-space marker over a world object
	markerPos := e.Camera2D_WorldToScreen(camera, enemy.pos)
*/
Camera2D_WorldToScreen :: proc(camera: ^Camera2D, world: [2]f32) -> [2]f32 {
	return rotateDegrees(world - camera.target, camera.rotation) * cameraZoom(camera) + camera.offset
}

/*
Converts a screen position to the world position under it. The inverse of `Camera2D_WorldToScreen`.

Inputs:
- camera: The camera to transform through
- screen: Position in screen (game resolution) coordinates, e.g. from a mouse event

Returns:
- Position in world coordinates

Example:
	worldPos := e.Camera2D_ScreenToWorld(camera, {event.button.x, event.button.y})
*/
Camera2D_ScreenToWorld :: proc(camera: ^Camera2D, screen: [2]f32) -> [2]f32 {
	return rotateDegrees((screen - camera.offset) / cameraZoom(camera), -camera.rotation) + camera.target
}

/*
Eases the camera's target toward a position using the settings in `camera.follow`.
Call once per frame, e.g. from the update of the node being followed.

Does nothing while a `Camera2D_MoveTo` pan is running, so pans aren't interrupted.
Frame rate independent in every mode.

Inputs:
- camera: The camera to move
- position: World position to follow, e.g. the player's center
- deltaTime: Seconds since the last frame

Example:
	camera.follow.mode = .SmoothDamp
	camera.follow.smoothTime = 0.3
	...
	e.Camera2D_Follow(node.scene.camera, player.pos, deltaTime)
*/
Camera2D_Follow :: proc(camera: ^Camera2D, position: [2]f32, deltaTime: f64) {
	if camera.move.active do return
	dt := f32(deltaTime)
	settings := &camera.follow

	// Inside the dead zone the camera holds still; outside it, aim for the point that puts
	// the followed position back on the dead zone's edge
	goal := position
	for axis in 0..<2 {
		half := settings.deadzone[axis] * 0.5
		if half <= 0 do continue
		diff := position[axis] - camera.target[axis]
		if abs(diff) <= half {
			goal[axis] = camera.target[axis]
		} else {
			goal[axis] = position[axis] - math.sign(diff) * half
		}
	}

	previous := camera.target
	switch settings.mode {
	case .Snap:
		camera.target = goal

	case .Exponential:
		if settings.smoothing <= 0 {
			camera.target = goal
		} else {
			camera.target += (goal - camera.target) * (1 - math.exp(-settings.smoothing * dt))
		}

	case .SmoothDamp:
		camera.target = smoothDamp(camera.target, goal, &camera.velocity, settings.smoothTime, settings.maxSpeed, dt)

	case .Linear:
		camera.target = moveTowards(camera.target, goal, settings.speed * dt)
	}

	if settings.maxSpeed > 0 && settings.mode != .Snap {
		camera.target = moveTowards(previous, camera.target, settings.maxSpeed * dt)
	}
	if settings.mode != .SmoothDamp && dt > 0 {
		camera.velocity = (camera.target - previous) / dt
	}
}

/*
Pans the camera's target to a position over a fixed time, following an easing curve.

The pan is advanced automatically by the scene that owns the camera (or by
`Camera2D_Update` for cameras outside a scene). While it runs, `Camera2D_Follow` does
nothing; afterwards following resumes from wherever the pan ended, using `camera.follow`.
Starting a new pan replaces the current one.

Inputs:
- camera: The camera to pan
- position: World position to pan to
- duration: Seconds the pan takes. 0 or less jumps immediately
- ease: Easing curve for the pan

Example:
	// Show the exit door, then return to the player
	e.Camera2D_MoveTo(camera, door.pos, 1.2, .InOutSine)
*/
Camera2D_MoveTo :: proc(camera: ^Camera2D, position: [2]f32, duration: f32, ease := EaseType.InOutCubic) {
	if duration <= 0 {
		Camera2D_SnapTo(camera, position)
		return
	}
	camera.move = {
		active = true,
		from = camera.target,
		to = position,
		duration = duration,
		ease = ease,
	}
	camera.velocity = {}
}

/*
Moves the camera's target to a position immediately, cancelling any pan and easing.
Use it when a scene starts or the player respawns.

Inputs:
- camera: The camera to move
- position: World position to look at
*/
Camera2D_SnapTo :: proc(camera: ^Camera2D, position: [2]f32) {
	camera.target = position
	camera.velocity = {}
	camera.move.active = false
}

/*
Returns whether a `Camera2D_MoveTo` pan is in progress.

Inputs:
- camera: The camera to check

Returns:
- true while panning
*/
Camera2D_IsMoving :: proc(camera: ^Camera2D) -> bool {
	return camera.move.active
}

/*
Advances an active `Camera2D_MoveTo` pan, then applies the camera's bounds.

The scene calls this automatically for its own camera after its nodes update. Call it
yourself, once per frame, only for cameras you manage outside a scene.

Inputs:
- camera: The camera to update
- viewSize: Size of the visible area in screen coordinates, normally `game.size`
- deltaTime: Seconds since the last frame
*/
Camera2D_Update :: proc(camera: ^Camera2D, viewSize: [2]f32, deltaTime: f64) {
	if camera.move.active {
		move := &camera.move
		move.elapsed += f32(deltaTime)
		// Small tolerance so summed frame times (e.g. 90 x 1/60) finish on the expected frame
		t := move.elapsed / move.duration
		if t >= 0.9999 do t = 1
		camera.target = move.from + (move.to - move.from) * Ease(move.ease, t)
		if t >= 1 do move.active = false
	}
	Camera2D_ClampToBounds(camera, viewSize)
}

/*
Adjusts the camera's target so the visible area stays inside its bounds. Does nothing if
the camera is not bounded.

Called by `Camera2D_Update`, which the scene runs automatically for its own camera.

Inputs:
- camera: The camera to clamp
- viewSize: Size of the visible area in screen coordinates, normally `game.size`
*/
Camera2D_ClampToBounds :: proc(camera: ^Camera2D, viewSize: [2]f32) {
	if !camera.bounded do return
	zoom := cameraZoom(camera)

	// The view spans target - offset/zoom .. target + (viewSize - offset)/zoom
	lo := camera.min + camera.offset / zoom
	hi := camera.max - (viewSize - camera.offset) / zoom
	for axis in 0..<2 {
		if lo[axis] > hi[axis] {
			// The world is smaller than the view on this axis: center it
			camera.target[axis] = (camera.min[axis] + camera.max[axis]) * 0.5 + (camera.offset[axis] - viewSize[axis] * 0.5) / zoom
		} else {
			clamped := clamp(camera.target[axis], lo[axis], hi[axis])
			if clamped != camera.target[axis] {
				// Pressed against a bound: drop the velocity so the camera doesn't stick to it
				camera.velocity[axis] = 0
			}
			camera.target[axis] = clamped
		}
	}
}

/*
Converts a screen position to world coordinates using the scene's camera.

Safe to call on any scene: without a camera, screen and world coordinates are the same
and the position is returned unchanged.

Inputs:
- scene: The scene whose camera to use
- screen: Position in screen (game resolution) coordinates, e.g. from a mouse event

Returns:
- Position in world coordinates
*/
Scene_ScreenToWorld :: proc(scene: ^Scene, screen: [2]f32) -> [2]f32 {
	if scene.camera == nil do return screen
	return Camera2D_ScreenToWorld(scene.camera, screen)
}

/*
Converts a world position to screen coordinates using the scene's camera.

Safe to call on any scene: without a camera, the position is returned unchanged.

Inputs:
- scene: The scene whose camera to use
- world: Position in world coordinates

Returns:
- Position in screen (game resolution) coordinates
*/
Scene_WorldToScreen :: proc(scene: ^Scene, world: [2]f32) -> [2]f32 {
	if scene.camera == nil do return world
	return Camera2D_WorldToScreen(scene.camera, world)
}

/*
Returns the world position currently under the mouse cursor, for code that polls the
mouse instead of handling events.

Inputs:
- scene: The scene whose camera to use

Returns:
- Mouse position in world coordinates
*/
Scene_GetMouseWorldPosition :: proc(scene: ^Scene) -> [2]f32 {
	return Scene_ScreenToWorld(scene, Game_GetMousePosition(scene.game))
}


// ACTIVE CAMERA
// Set by Scene_Draw while drawing world layers. The Draw* helpers transform through it.

@(private)
activeCamera: ^Camera2D

/*
Returns the camera currently being applied to drawing, or nil.

It is only set while a scene draws its world layers. Use it in custom drawing code
that calls SDL directly, which bypasses the camera, to transform positions yourself.

Returns:
- The active camera, or nil when drawing in screen space

Example:
	MyNode_draw :: proc(node: ^e.Node, renderer: ^sdl.Renderer) {
		pos := [2]f32{100, 100}
		if camera := e.GetActiveCamera(); camera != nil {
			pos = e.Camera2D_WorldToScreen(camera, pos)
		}
		sdl.RenderPoint(renderer, pos.x, pos.y)
	}
*/
GetActiveCamera :: proc() -> ^Camera2D {
	return activeCamera
}

// World point to render point through the active camera
@(private)
toScreen :: proc(p: [2]f32) -> [2]f32 {
	if activeCamera == nil do return p
	return Camera2D_WorldToScreen(activeCamera, p)
}

// World length to render length through the active camera
@(private)
toScreenLength :: proc(length: f32) -> f32 {
	if activeCamera == nil do return length
	return length * cameraZoom(activeCamera)
}

@(private)
cameraZoom :: proc(camera: ^Camera2D) -> f32 {
	// Guard against a zero-initialized camera collapsing everything to a point
	return camera.zoom > 0.0001 ? camera.zoom : 1
}

@(private="file")
rotateDegrees :: proc(v: [2]f32, degrees: f32) -> [2]f32 {
	if degrees == 0 do return v
	r := math.to_radians(degrees)
	s, c := math.sin(r), math.cos(r)
	return {v.x * c - v.y * s, v.x * s + v.y * c}
}

// Unity-style SmoothDamp: a critically damped spring toward goal (Game Programming Gems 4, 1.10)
@(private="file")
smoothDamp :: proc(current, goal: [2]f32, velocity: ^[2]f32, smoothTime, maxSpeed, dt: f32) -> [2]f32 {
	if dt <= 0 do return current
	smoothTime := max(smoothTime, 0.0001)
	omega := 2 / smoothTime
	x := omega * dt
	decay := 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)

	change := current - goal
	if maxSpeed > 0 {
		change = clampLength(change, maxSpeed * smoothTime)
	}
	target := current - change

	temp := (velocity^ + omega * change) * dt
	velocity^ = (velocity^ - omega * temp) * decay
	result := target + (change + temp) * decay

	// Don't overshoot the goal
	if dot2(goal - current, result - goal) > 0 {
		result = goal
		velocity^ = {}
	}
	return result
}

@(private="file")
moveTowards :: proc(current, goal: [2]f32, maxDistance: f32) -> [2]f32 {
	delta := goal - current
	distance := math.sqrt(delta.x * delta.x + delta.y * delta.y)
	if distance <= maxDistance || distance == 0 do return goal
	return current + delta / distance * maxDistance
}

@(private="file")
clampLength :: proc(v: [2]f32, maxLength: f32) -> [2]f32 {
	length := math.sqrt(v.x * v.x + v.y * v.y)
	if length <= maxLength || length == 0 do return v
	return v / length * maxLength
}

@(private="file")
dot2 :: proc(a, b: [2]f32) -> f32 {
	return a.x * b.x + a.y * b.y
}
