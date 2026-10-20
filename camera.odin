/*
2D camera support for scenes.

A camera is a node: it looks at its own world position, and its world rotation turns the view.
Parent it to a player and the view follows the player with no code; or leave it top-level and
move it with `Camera2D_Follow` (smoothed) or `Camera2D_MoveTo` (timed pans). A scene draws every
layer not listed in `scene.screenLayers` through its current camera (`scene.camera`); layers in
`scene.screenLayers` (HUD, menus) are drawn in screen space.

	screen = zoom * rotate(world - cameraWorldPosition, -cameraWorldRotation) + offset

Rotating the camera clockwise turns the view clockwise, so the world appears to rotate
counter-clockwise on screen.

Example:
	package mygame

	import e "../engine"
	import sdl "vendor:sdl3"

	WORLD_SIZE :: [2]f32{3840, 2160}
	HUD_LAYER  :: e.RenderLayer.Layer8

	Player :: struct {
		using node: e.Node,
	}

	CreateLevelScene :: proc(game: ^e.Game) -> ^e.Scene {
		scene := game->createScene("Level")
		scene.screenLayers = {HUD_LAYER} // Optional: the HUD ignores the camera

		player := e.CreateNode(scene, Player)
		player.position = WORLD_SIZE * 0.5
		player.update = Player_update
		player.draw = Player_draw

		// Option 1: a camera that's rigidly attached to the player
		//	camera := e.Scene_CreateCamera(scene, parent = player)

		// Option 2: a top-level camera that eases after the player and stays inside the level
		camera := e.Scene_CreateCamera(scene)
		camera.follow.mode = .SmoothDamp
		camera.follow.smoothTime = 0.3
		camera.follow.deadzone = {200, 120}
		e.Camera2D_SetBounds(camera, {0, 0}, WORLD_SIZE)
		e.Camera2D_SnapTo(camera, player.position)
		return scene
	}

	Player_update :: proc(node: ^e.Node, events: []sdl.Event, deltaTime: f64) {
		camera := node.scene.camera
		for &event in events {
			#partial switch event.type {
			case .MOUSE_WHEEL:
				camera.zoom = clamp(camera.zoom + event.wheel.y * 0.1, 0.5, 3)
			case .MOUSE_BUTTON_DOWN:
				// Event positions are in screen space; convert to find the clicked world point
				node.position = e.Scene_ScreenToWorld(node.scene, {event.button.x, event.button.y})
			case .KEY_DOWN:
				// Cinematic pan to the center of the level. Following pauses until it ends
				if event.key.scancode == .C do e.Camera2D_MoveTo(camera, WORLD_SIZE * 0.5, 1.5, .InOutCubic)
			}
		}
		e.Camera2D_Follow(camera, e.Node_GetWorldPosition(node), deltaTime)
	}

	Player_draw :: proc(node: ^e.Node, renderer: ^sdl.Renderer) {
		// Local coordinates: the node's transform and the camera are applied for us
		e.DrawCircle(renderer, {0, 0}, 24, {120, 200, 255, 255})
	}
*/

package engine

import "core:math"
import "core:math/rand"

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
	// Size of a box, in world units and centered on the camera, that the followed position can
	// move inside without moving the camera. {0, 0} disables it
	deadzone: [2]f32,
}

DEFAULT_CAMERA_FOLLOW :: CameraFollow{
	mode = .Exponential,
	smoothing = 6,
	smoothTime = 0.25,
	speed = 600,
}

/*
A camera node. It looks at its world position (`Camera2D_GetTarget`), and its world rotation
turns the view. Create one with `Scene_CreateCamera`.

A zero-initialized Camera2D also works as a plain value outside a scene: a zoom of 0 is treated
as 1 and following snaps.
*/
Camera2D :: struct {
	using node: Node,
	// Screen position the camera's target appears at, usually the center of the screen
	offset: [2]f32,
	// Scale factor. 1 is unscaled, 2 shows everything twice as big, 0.5 half as big
	zoom: f32,

	// When true, the camera's target is clamped every frame so the view stays inside `min..max`.
	// Set with `Camera2D_SetBounds`. Rotation is not taken into account, so a rotated view can
	// show slightly past the bounds at its corners
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
	shake: CameraShake, // Active `Camera2D_Shake`
}

// State of a `Camera2D_Shake`
CameraShake :: struct {
	// Screen pixels at the start, seconds in all, seconds left
	strength, duration, left: f32,
	// The view's offset this frame, in screen pixels
	offset: [2]f32,
}

// State of a `Camera2D_MoveTo` pan
CameraMove :: struct {
	active: bool,
	from, to: [2]f32,
	duration, elapsed: f32,
	ease: EaseType,
}

/*
Creates a camera node in a scene and makes it the scene's camera.

A top-level camera starts at the center of the game resolution, so world and screen
coordinates line up until it moves. A camera with a parent starts at the parent's origin and
moves with it.

Inputs:
- scene: The scene
- parent: Node to attach the camera to, or nil for a top-level camera

Returns:
- The new camera, also stored in `scene.camera`

Example:
	camera := e.Scene_CreateCamera(scene)
	camera.zoom = 2
*/
Scene_CreateCamera :: proc(scene: ^Scene, parent: ^Node = nil) -> ^Camera2D {
	camera := CreateNode(scene, Camera2D)
	camera.zoom = 1
	camera.follow = DEFAULT_CAMERA_FOLLOW
	if scene.game != nil {
		camera.offset = scene.game.size * 0.5
		if parent == nil do camera.position = camera.offset
	}
	if parent != nil do Node_AddChild(parent, camera)
	scene.camera = camera
	return camera
}

/*
Makes a camera the one the scene draws through. Pass nil to draw without a camera.
*/
Scene_SetCamera :: proc(scene: ^Scene, camera: ^Camera2D) {
	scene.camera = camera
}

// The world position the camera looks at
Camera2D_GetTarget :: proc(camera: ^Camera2D) -> [2]f32 {
	return Node_GetWorldPosition(camera)
}

/*
Moves the camera to look at a world position, whatever its parent is.
*/
Camera2D_SetTarget :: proc(camera: ^Camera2D, target: [2]f32) {
	Node_SetWorldPosition(camera, target)
}

/*
Restricts the camera so the visible area stays inside a world rectangle.

When the camera is the scene's camera, the bounds are applied automatically each frame after
the scene's nodes update. If the bounds are smaller than the view on an axis, the camera is
centered on that axis instead.

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
*/
Camera2D_ClearBounds :: proc(camera: ^Camera2D) {
	camera.bounded = false
}

/*
The transform from world coordinates to screen coordinates for this camera.

Returns:
- offset × zoom × rotate(-world rotation) × translate(-world position)
*/
Camera2D_ViewTransform :: proc(camera: ^Camera2D) -> Transform2D {
	// As drawn: a camera under a smoothed body moves with what's drawn, not ahead of it
	world := Node_GetRenderWorldTransform(camera)
	zoom := cameraZoom(camera)
	view := Transform2D_Make(camera.offset + camera.shake.offset, 0, {zoom, zoom})
	view = Transform2D_Multiply(view, Transform2D_Make({0, 0}, -Transform2D_Rotation(world), {1, 1}))
	return Transform2D_Multiply(view, Transform2D_Make(-world.origin, 0, {1, 1}))
}

/*
Converts a world position to the screen position it is drawn at.

Example:
	// Draw a screen-space marker over a world object
	markerPos := e.Camera2D_WorldToScreen(camera, e.Node_GetWorldPosition(enemy))
*/
Camera2D_WorldToScreen :: proc(camera: ^Camera2D, world: [2]f32) -> [2]f32 {
	return Transform2D_Apply(Camera2D_ViewTransform(camera), world)
}

/*
Converts a screen position (e.g. from a mouse event) to the world position under it.
*/
Camera2D_ScreenToWorld :: proc(camera: ^Camera2D, screen: [2]f32) -> [2]f32 {
	return Transform2D_Apply(Transform2D_Inverse(Camera2D_ViewTransform(camera)), screen)
}

/*
Eases the camera toward a world position using the settings in `camera.follow`.
Call once per frame, e.g. from the update of the node being followed.

Does nothing while a `Camera2D_MoveTo` pan is running, so pans aren't interrupted.
Frame rate independent in every mode. A camera parented to the followed node doesn't need this.

Inputs:
- camera: The camera to move
- position: World position to follow, e.g. `Node_GetWorldPosition(player)`
- deltaTime: Seconds since the last frame

Example:
	e.Camera2D_Follow(node.scene.camera, e.Node_GetWorldPosition(player), deltaTime)
*/
Camera2D_Follow :: proc(camera: ^Camera2D, position: [2]f32, deltaTime: f64) {
	if camera.move.active do return
	dt := f32(deltaTime)
	settings := &camera.follow
	current := Camera2D_GetTarget(camera)

	// Inside the dead zone the camera holds still; outside it, aim for the point that puts
	// the followed position back on the dead zone's edge
	goal := position
	for axis in 0..<2 {
		half := settings.deadzone[axis] * 0.5
		if half <= 0 do continue
		diff := position[axis] - current[axis]
		if abs(diff) <= half {
			goal[axis] = current[axis]
		} else {
			goal[axis] = position[axis] - math.sign(diff) * half
		}
	}

	next := current
	switch settings.mode {
	case .Snap:
		next = goal
	case .Exponential:
		if settings.smoothing <= 0 {
			next = goal
		} else {
			next += (goal - current) * (1 - math.exp(-settings.smoothing * dt))
		}
	case .SmoothDamp:
		next = smoothDamp(current, goal, &camera.velocity, settings.smoothTime, settings.maxSpeed, dt)
	case .Linear:
		next = moveTowards(current, goal, settings.speed * dt)
	}

	if settings.maxSpeed > 0 && settings.mode != .Snap {
		next = moveTowards(current, next, settings.maxSpeed * dt)
	}
	if settings.mode != .SmoothDamp && dt > 0 {
		camera.velocity = (next - current) / dt
	}
	Camera2D_SetTarget(camera, next)
}

/*
Pans the camera to a world position over a fixed time, following an easing curve.

The pan is advanced automatically by the scene whose camera it is (or by `Camera2D_Update`).
While it runs, `Camera2D_Follow` does nothing; afterwards following resumes from wherever the
pan ended. Starting a new pan replaces the current one.

Inputs:
- camera: The camera to pan
- position: World position to pan to
- duration: Seconds the pan takes. 0 or less jumps immediately
- ease: Easing curve for the pan

Example:
	// Show the exit door, then return to the player
	e.Camera2D_MoveTo(camera, e.Node_GetWorldPosition(door), 1.2, .InOutSine)
*/
Camera2D_MoveTo :: proc(camera: ^Camera2D, position: [2]f32, duration: f32, ease := EaseType.InOutCubic) {
	if duration <= 0 {
		Camera2D_SnapTo(camera, position)
		return
	}
	camera.move = {
		active = true,
		from = Camera2D_GetTarget(camera),
		to = position,
		duration = duration,
		ease = ease,
	}
	camera.velocity = {}
}

/*
Moves the camera to look at a world position immediately, cancelling any pan and easing.
Use it when a scene starts or the player respawns.
*/
Camera2D_SnapTo :: proc(camera: ^Camera2D, position: [2]f32) {
	Camera2D_SetTarget(camera, position)
	camera.velocity = {}
	camera.move.active = false
}

/*
Returns whether a `Camera2D_MoveTo` pan is in progress.
*/
Camera2D_IsMoving :: proc(camera: ^Camera2D) -> bool {
	return camera.move.active
}

/*
Advances an active `Camera2D_MoveTo` pan, then applies the camera's bounds.

The scene calls this automatically for its camera after its nodes update. Call it yourself,
once per frame, only for cameras you manage outside a scene.

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
		Camera2D_SetTarget(camera, move.from + (move.to - move.from) * Ease(move.ease, t))
		if t >= 1 do move.active = false
	}
	Camera2D_ClampToBounds(camera, viewSize)
}

/*
Shakes the view: it jumps around its place by up to `strength` screen pixels, less and less over
`duration` seconds (a hit, an explosion). A stronger shake replaces a weaker one; a weaker one
started during a stronger one is ignored. The shake only moves what's drawn (the view transform),
never the camera node, so following, bounds and scripts reading its position are unaffected.

The game advances it in real time (`Camera2D_UpdateShake`, from Game_Update), so it keeps going
through a hitstop (`Game_HitStop`).

Inputs:
- camera: The camera
- strength: Largest offset, in screen pixels (game coordinates)
- duration: Seconds until it settles

Example:
	e.Camera2D_Shake(self.scene.camera, 4, 0.2)
*/
Camera2D_Shake :: proc(camera: ^Camera2D, strength, duration: f32) {
	if camera == nil || duration <= 0 do return
	current := camera.shake.duration > 0 ? camera.shake.strength * camera.shake.left / camera.shake.duration : 0
	if strength < current do return
	camera.shake = {strength = strength, duration = duration, left = duration}
}

/*
Moves a shake on by `deltaTime` real seconds: a new random offset, scaled by the square of the
time left (strong at first, settling softly). Game_Update calls it for the current scene's camera.
*/
Camera2D_UpdateShake :: proc(camera: ^Camera2D, deltaTime: f64) {
	shake := &camera.shake
	if shake.left <= 0 {
		shake.offset = {}
		return
	}
	shake.left = max(shake.left - f32(deltaTime), 0)
	fade := shake.left / shake.duration
	amount := shake.strength * fade * fade
	angle := rand.float32() * math.TAU
	shake.offset = {math.cos(angle), math.sin(angle)} * amount
}

/*
Adjusts the camera so the visible area stays inside its bounds. Does nothing if the camera is
not bounded. Called by `Camera2D_Update`.

Inputs:
- camera: The camera to clamp
- viewSize: Size of the visible area in screen coordinates, normally `game.size`
*/
Camera2D_ClampToBounds :: proc(camera: ^Camera2D, viewSize: [2]f32) {
	if !camera.bounded do return
	zoom := cameraZoom(camera)
	target := Camera2D_GetTarget(camera)

	// The view spans target - offset/zoom .. target + (viewSize - offset)/zoom
	lo := camera.min + camera.offset / zoom
	hi := camera.max - (viewSize - camera.offset) / zoom
	for axis in 0..<2 {
		if lo[axis] > hi[axis] {
			// The world is smaller than the view on this axis: center it
			target[axis] = (camera.min[axis] + camera.max[axis]) * 0.5 + (camera.offset[axis] - viewSize[axis] * 0.5) / zoom
		} else {
			clamped := clamp(target[axis], lo[axis], hi[axis])
			if clamped != target[axis] {
				// Pressed against a bound: drop the velocity so the camera doesn't stick to it
				camera.velocity[axis] = 0
			}
			target[axis] = clamped
		}
	}
	if target != Camera2D_GetTarget(camera) do Camera2D_SetTarget(camera, target)
}

/*
Converts a screen position to world coordinates using the scene's camera. Without a camera,
screen and world coordinates are the same.
*/
Scene_ScreenToWorld :: proc(scene: ^Scene, screen: [2]f32) -> [2]f32 {
	if scene.camera == nil do return screen
	return Camera2D_ScreenToWorld(scene.camera, screen)
}

/*
Converts a world position to screen coordinates using the scene's camera.
*/
Scene_WorldToScreen :: proc(scene: ^Scene, world: [2]f32) -> [2]f32 {
	if scene.camera == nil do return world
	return Camera2D_WorldToScreen(scene.camera, world)
}

/*
The world position currently under the mouse cursor, for code that polls the mouse instead of
handling events.
*/
Scene_GetMouseWorldPosition :: proc(scene: ^Scene) -> [2]f32 {
	return Scene_ScreenToWorld(scene, Game_GetMousePosition(scene.game))
}

@(private)
cameraZoom :: proc(camera: ^Camera2D) -> f32 {
	// Guard against a zero-initialized camera collapsing everything to a point
	return camera.zoom > 0.0001 ? camera.zoom : 1
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
