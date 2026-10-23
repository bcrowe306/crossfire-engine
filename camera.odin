package crossfire

import "core:log"
import "core:math"
import "core:math/rand"
import "core:strings"
import sdl "vendor:sdl3"

/*
2D camera support for scenes.

A camera is a node: it looks at its own world position, and its world rotation turns the view.
Parent it to a player and the view follows the player rigidly with no code; give it a follow
target (`Camera2D_SetFollowTarget`, or a Camera node's Target in the editor) and it eases after
that node by itself, with its follow settings (`CameraFollow`: mode, dead zone, offset,
look-ahead); or move it from code with `Camera2D_Follow` (smoothed) or `Camera2D_MoveTo` (timed
pans). Limits (`Camera2D_SetBounds`, `Camera2D_SetLimit`: any of the four sides) keep the view
inside the level. A scene draws every
layer not listed in `scene.screenLayers` through its current camera (`scene.camera`); layers in
`scene.screenLayers` (HUD, menus) are drawn in screen space.

	screen = zoom * rotate(world - cameraWorldPosition, -cameraWorldRotation) + offset

Rotating the camera clockwise turns the view clockwise, so the world appears to rotate
counter-clockwise on screen.

Example:
	package mygame

	import e "engine:."
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

		// Option 2: a top-level camera that eases after the player by itself (looking ahead the
		// way it moves) and stays inside the level
		camera := e.Scene_CreateCamera(scene)
		camera.follow.mode = .SmoothDamp
		camera.follow.smoothTime = 0.3
		camera.follow.deadzone = {200, 120}
		camera.follow.lookAhead = {120, 0}
		e.Camera2D_SetBounds(camera, {0, 0}, WORLD_SIZE)
		e.Camera2D_SetFollowTarget(camera, player)
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
				// A shake with the camera's shake settings
				if event.key.scancode == .S do e.Camera2D_Shake(camera)
			}
		}
	}

	Player_draw :: proc(node: ^e.Node, renderer: ^sdl.Renderer) {
		// Local coordinates: the node's transform and the camera are applied for us
		e.DrawCircle(renderer, {0, 0}, 24, {120, 200, 255, 255})
	}
*/

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
Settings for `Camera2D_Follow` (and a camera's follow target, which uses it). Each mode only
reads its own strength setting; `deadzone`, `offset` and `lookAhead` apply to every mode,
`maxSpeed` to every mode but `.Snap` (which always jumps).
*/
CameraFollow :: struct {
	// How it eases toward the position
	mode: CameraFollowMode,
	// .Exponential: how tightly to follow. Higher is tighter; around 4-10 feels natural
	smoothing: f32,
	// .SmoothDamp: roughly how many seconds the camera takes to catch up
	smoothTime: f32,
	// .Linear: world units per second
	speed: f32,
	// Caps how fast the camera can move, in world units per second (not in .Snap). 0 = no limit
	maxSpeed: f32,
	// Size of a box, in world units and centered on the camera, that the followed position can
	// move inside without moving the camera. {0, 0} disables it
	deadzone: [2]f32,
	// Where the camera aims relative to the followed position, in world units ({0, -40}: a little
	// above a player)
	offset: [2]f32,
	// How far ahead the camera looks, in world units on each axis, in the direction the followed
	// position moves (back to {0, 0} while it stands still). {0, 0} disables it
	lookAhead: [2]f32,
	// How quickly the look-ahead swings to a new direction, like `smoothing` (higher is quicker);
	// 0 swings at once
	lookAheadSmoothing: f32,
}

// The follow settings new cameras get: `.Exponential` with a smoothing of 6, no deadzone, speed
// cap, offset or look-ahead
DEFAULT_CAMERA_FOLLOW :: CameraFollow{
	mode = .Exponential,
	smoothing = 6,
	smoothTime = 0.25,
	speed = 600,
	lookAheadSmoothing = 3,
}

// The followed position must move faster than this (world units per second) for the look-ahead to
// lean that way
CAMERA_LOOK_AHEAD_MIN_SPEED :: 10

// A side of a camera's limits (`Camera2D_SetLimit`)
CameraSide :: enum {
	// The view's left edge stays right of `Camera2D.min.x`
	Left,
	// The view's top edge stays below `Camera2D.min.y`
	Top,
	// The view's right edge stays left of `Camera2D.max.x`
	Right,
	// The view's bottom edge stays above `Camera2D.max.y`
	Bottom,
}

// Some sides of a camera's limits
CameraSides :: bit_set[CameraSide]

// Every side: bounds that limit all four (`Camera2D_SetBounds`)
CAMERA_ALL_SIDES :: CameraSides{.Left, .Top, .Right, .Bottom}

/*
How a camera shakes when `Camera2D_Shake` is given no strength or duration, and how fast every
shake of it jitters.
*/
CameraShakeSettings :: struct {
	// Largest offset, in screen pixels (game coordinates)
	strength: f32,
	// Seconds until it settles
	duration: f32,
	// New positions per second, eased between; 0 jumps to a new one every frame
	frequency: f32,
}

// The shake new cameras get: 4 px for 0.2 s, a new position every frame
DEFAULT_CAMERA_SHAKE_SETTINGS :: CameraShakeSettings{strength = 4, duration = 0.2}

/*
A Camera node's settings as a scene file stores them (`SceneNodeData.camera`; its zoom and
follow target are fields of their own). `Camera2D_ApplySettings` gives them to a camera.
*/
CameraSettings :: struct {
	// How it follows its target (or `Camera2D_Follow`'s position)
	follow: CameraFollow,
	// The sides it can't show past ({} for none)
	limits: CameraSides,
	// The left (x) and top (y) limits, in world pixels
	limitMin: [2]f32,
	// The right (x) and bottom (y) limits, in world pixels
	limitMax: [2]f32,
	// How `Camera2D_Shake` shakes it without a strength or duration
	shake: CameraShakeSettings,
}

// A Camera node's settings when its scene file says nothing: the default follow and shake, no limits
DEFAULT_CAMERA_SETTINGS :: CameraSettings{
	follow = DEFAULT_CAMERA_FOLLOW,
	shake = DEFAULT_CAMERA_SHAKE_SETTINGS,
}

/*
A camera node. It looks at its world position (`Camera2D_GetTarget`), and its world rotation
turns the view. Create one with `Scene_CreateCamera`. With a follow target
(`Camera2D_SetFollowTarget` / `SetFollowTargetPath`) it moves there by itself every frame;
`Camera2D_GetTarget` / `SetTarget` are about the position it looks at, not that node.

A zero-initialized Camera2D also works as a plain value outside a scene: a zoom of 0 is treated
as 1 and following snaps.
*/
Camera2D :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Screen position the camera's target appears at, usually the center of the screen
	offset: [2]f32,
	// Scale factor. 1 is unscaled, 2 shows everything twice as big, 0.5 half as big
	zoom: f32,

	// When true, the camera's target is clamped every frame so the view stays inside `min..max`
	// (on the sides not in `freeSides`). Set with `Camera2D_SetBounds` or `Camera2D_SetLimit`.
	// Rotation is not taken into account, so a rotated view can show slightly past the bounds
	// at its corners
	bounded: bool,
	// Top-left corner of the world boundary, used when `bounded` is true
	min: [2]f32,
	// Bottom-right corner of the world boundary, used when `bounded` is true
	max: [2]f32,
	// Sides the bounds don't limit ({}: all four limit). `Camera2D_SetLimit` and
	// `Camera2D_ClearLimit` change one side
	freeSides: CameraSides,

	// How `Camera2D_Follow` (and the follow target) eases toward the followed position
	follow: CameraFollow,
	// How `Camera2D_Shake` shakes it when given no strength or duration, and how fast every
	// shake jitters
	shakeSettings: CameraShakeSettings,
	// The path to the node it follows by itself, from the camera (as `Node_FindPath` reads it:
	// "../Player"); "" for none. Set with `Camera2D_SetFollowTargetPath` (scene files' `target`)
	followTargetPath: string,

	// Internal state; read it if useful but don't modify it

	// The node it follows (`Camera2D_SetFollowTarget`, or found from `followTargetPath`), checked
	// by id before each use: read it with `Camera2D_GetFollowTarget`
	followTarget: ^Node,
	// The followed node's id
	followTargetId: EntityId,
	// It has snapped onto its follow target (the first frame it found it)
	followStarted: bool,
	// A missing follow target was reported
	followWarned: bool,
	// The look-ahead now, in world units, and the followed position last frame
	lookAhead: CameraLookAhead,
	// Current follow velocity in world units per second (.SmoothDamp)
	velocity: [2]f32,
	// Active `Camera2D_MoveTo` pan
	move: CameraMove,
	// Active `Camera2D_Shake`
	shake: CameraShake,
	// Active `Camera2D_ZoomTo` (the zoom in `from.x` / `to.x`: camera_tools.odin)
	zoomMove: CameraMove,
	// A `Camera2D_MoveTo` pan reached its end (not when replaced or cancelled)
	onPanFinished: EventSubject `event:"A timed pan (Camera2D_MoveTo) reached its end"`,
	// A `Camera2D_Shake` settled
	onShakeFinished: EventSubject `event:"A shake (Camera2D_Shake) settled"`,
}

// Prepares a camera made by Scene_CreateCamera or a scene file: its event subjects, its update
// (following its target when it isn't the scene's camera) and its default settings
@(private)
initCamera :: proc(camera: ^Camera2D) {
	EventSubject_Init(&camera.onPanFinished, Node_GetAllocator(camera))
	EventSubject_Init(&camera.onShakeFinished, Node_GetAllocator(camera))
	camera.update = cameraNodeUpdate
	camera.zoom = 1
	camera.follow = DEFAULT_CAMERA_FOLLOW
	camera.shakeSettings = DEFAULT_CAMERA_SHAKE_SETTINGS
}

// State of a `Camera2D_Shake`
CameraShake :: struct {
	// Screen pixels at the start, seconds in all, seconds left
	strength, duration, left: f32,
	// New positions per second (0: every frame), and how far it is from `from` to `to` (0..1)
	frequency, phase: f32,
	// The positions it eases between (unit directions; with a frequency)
	from, to: [2]f32,
	// The view's offset this frame, in screen pixels
	offset: [2]f32,
}

// A camera's look-ahead (`CameraFollow.lookAhead`) as it follows
CameraLookAhead :: struct {
	// How far it looks ahead now, in world units
	offset: [2]f32,
	// The followed position last frame
	last: [2]f32,
	// `last` holds a position
	started: bool,
}

// State of a `Camera2D_MoveTo` pan
CameraMove :: struct {
	// A pan is going
	active: bool,
	// Start and end of the pan, in world pixels
	from, to: [2]f32,
	// Seconds the pan takes, and seconds into it
	duration, elapsed: f32,
	// The pan's curve (easing.odin)
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
	initCamera(camera)
	if scene.game != nil {
		camera.offset = scene.game.size * 0.5
		if parent == nil do camera.position = camera.offset
	}
	if parent != nil do Node_AddChild(parent, camera)
	scene.camera = camera
	return camera
}

/*
Makes a camera the one the scene draws through (`scene.camera`). Pass nil to draw without a
camera.

Inputs:
- scene: The scene
- camera: The camera (normally one of the scene's nodes), or nil
*/
Scene_SetCamera :: proc(scene: ^Scene, camera: ^Camera2D) {
	scene.camera = camera
}

/*
The world position the camera looks at (its world position).

Inputs:
- camera: The camera

Returns:
- The position, in world pixels
*/
Camera2D_GetTarget :: proc(camera: ^Camera2D) -> [2]f32 {
	return Node_GetWorldPosition(camera)
}

/*
Moves the camera to look at a world position, whatever its parent is. Unlike `Camera2D_SnapTo`,
a pan or follow velocity going on is left alone.

Inputs:
- camera: The camera
- target: The world position to look at, in world pixels
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
	// Given: camera: ^e.Camera2D
	e.Camera2D_SetBounds(camera, {0, 0}, {3840, 2160})
*/
Camera2D_SetBounds :: proc(camera: ^Camera2D, min, max: [2]f32) {
	camera.bounded = true
	camera.min = min
	camera.max = max
	camera.freeSides = {}
}

/*
Removes the boundaries set with `Camera2D_SetBounds` or `Camera2D_SetLimit`, letting the camera
move freely.

Inputs:
- camera: The camera
*/
Camera2D_ClearBounds :: proc(camera: ^Camera2D) {
	camera.bounded = false
	camera.freeSides = {}
}

/*
Limits one side of the view: the camera never shows past `value` on that side (left of it for
`.Left`, above it for `.Top`, and so on), whatever its zoom. The other sides keep their limits,
or stay free on a camera that had none. With both sides of an axis limited and closer together
than the view is wide, the view is centered between them.

Inputs:
- camera: The camera
- side: The side to limit
- value: The limit, in world pixels (an x for `.Left` and `.Right`, a y for `.Top` and `.Bottom`)

Example:
	// Given: camera: ^e.Camera2D
	// A side-scroller: never below the ground or left of the level's start
	e.Camera2D_SetLimit(camera, .Left, 0)
	e.Camera2D_SetLimit(camera, .Bottom, 720)
*/
Camera2D_SetLimit :: proc(camera: ^Camera2D, side: CameraSide, value: f32) {
	if !camera.bounded {
		camera.bounded = true
		camera.freeSides = CAMERA_ALL_SIDES
	}
	camera.freeSides -= {side}
	switch side {
	case .Left:   camera.min.x = value
	case .Top:    camera.min.y = value
	case .Right:  camera.max.x = value
	case .Bottom: camera.max.y = value
	}
}

/*
Frees one side of the view from its limit (`Camera2D_SetLimit`, `Camera2D_SetBounds`); the other
sides keep theirs. Freeing the last one leaves the camera unbounded.

Inputs:
- camera: The camera
- side: The side to free
*/
Camera2D_ClearLimit :: proc(camera: ^Camera2D, side: CameraSide) {
	if !camera.bounded do return
	camera.freeSides += {side}
	if camera.freeSides == CAMERA_ALL_SIDES do Camera2D_ClearBounds(camera)
}

/*
The sides the camera's view is limited on (none when it isn't bounded).

Inputs:
- camera: The camera

Returns:
- The limited sides
*/
Camera2D_GetLimits :: proc(camera: ^Camera2D) -> CameraSides {
	return camera.bounded ? CAMERA_ALL_SIDES - camera.freeSides : {}
}

/*
Gives a camera a Camera node's settings, as the loader does for scene files: its follow settings,
its limits (replacing any bounds; no sides: unbounded) and its shake settings. Its zoom and follow
target are set apart (`camera.zoom`, `Camera2D_SetFollowTargetPath`).

Inputs:
- camera: The camera
- settings: The settings

Example:
	// Given: camera: ^e.Camera2D
	settings := e.DEFAULT_CAMERA_SETTINGS
	settings.limits = {.Left, .Right}
	settings.limitMax = {3840, 0}
	e.Camera2D_ApplySettings(camera, settings)
*/
Camera2D_ApplySettings :: proc(camera: ^Camera2D, settings: CameraSettings) {
	camera.follow = settings.follow
	camera.shakeSettings = settings.shake
	camera.min, camera.max = settings.limitMin, settings.limitMax
	camera.bounded = settings.limits != {}
	camera.freeSides = camera.bounded ? CAMERA_ALL_SIDES - settings.limits : {}
}

/*
Makes the camera follow a node by itself: every frame it eases toward the node's (drawn)
position using `camera.follow` (offset, look-ahead and dead zone included), then its limits
apply. On the first frame it snaps onto it, so a scene starts with the node in view. Pass nil to
stop following. A pan (`Camera2D_MoveTo`) pauses the following until it ends.

The scene's camera follows after every node has updated (`Scene_Update`); another camera (one a
`CameraView` shows) in its own update, so it may lag a frame behind a node updated after it.
Removing the node stops the following; the camera stays where it is.

Inputs:
- camera: The camera
- target: The node to follow, or nil

Example:
	// Given: camera: ^e.Camera2D, hero: ^e.Node
	camera.follow.mode = .SmoothDamp
	camera.follow.offset = {0, -40}
	e.Camera2D_SetFollowTarget(camera, hero)
*/
Camera2D_SetFollowTarget :: proc(camera: ^Camera2D, target: ^Node) {
	camera.followTargetPath = ""
	camera.followTarget = target
	camera.followTargetId = target != nil ? target.id : {}
	camera.followStarted = false
	camera.followWarned = false
	camera.lookAhead = {}
}

/*
Makes the camera follow the node at a path from it (as `Node_FindPath` reads it: "../Player",
"/World/Hero"), like a scene file's `target`. The node is looked for when the camera next
updates, and again whenever it's gone (a node spawned later is found then). "" stops following.
See `Camera2D_SetFollowTarget`.

Inputs:
- camera: The camera
- path: The path from the camera (copied into the camera's memory)

Example:
	// Given: camera: ^e.Camera2D
	e.Camera2D_SetFollowTargetPath(camera, "../Hero")
*/
Camera2D_SetFollowTargetPath :: proc(camera: ^Camera2D, path: NodePath) {
	Camera2D_SetFollowTarget(camera, nil)
	camera.followTargetPath = strings.clone(path, Node_GetAllocator(camera))
}

/*
The node the camera follows by itself (`Camera2D_SetFollowTarget`, or found from its
`followTargetPath`), or nil when there's none or it's gone.

Inputs:
- camera: The camera

Returns:
- The node, or nil
*/
Camera2D_GetFollowTarget :: proc(camera: ^Camera2D) -> ^Node {
	if camera.followTarget != nil {
		// Checked by id: a removed node's memory is gone
		if camera.scene == nil || Scene_GetNode(camera.scene, camera.followTargetId) == camera.followTarget do return camera.followTarget
		camera.followTarget = nil
		camera.followStarted = false
	}
	if camera.followTargetPath == "" do return nil
	found := Node_FindPath(camera, camera.followTargetPath)
	if found == nil || found == cast(^Node)camera do return nil
	camera.followTarget, camera.followTargetId = found, found.id
	return found
}

// Follows the camera's target this frame, if it has one (after the nodes moved)
@(private="file")
cameraFollowTarget :: proc(camera: ^Camera2D, deltaTime: f64) {
	if camera.followTarget == nil && camera.followTargetPath == "" do return
	target := Camera2D_GetFollowTarget(camera)
	if target == nil {
		if !camera.followWarned && camera.followTargetPath != "" {
			camera.followWarned = true
			log.warnf("Camera %s: no node at its target path %q (yet)", camera.name, camera.followTargetPath)
		}
		return
	}
	// Where it's drawn: a body smoothed between physics steps doesn't jitter in the view
	position := Node_GetRenderWorldTransform(target).origin
	if !camera.followStarted {
		camera.followStarted = true
		Camera2D_SnapTo(camera, position + camera.follow.offset)
		camera.lookAhead = {last = position, started = true}
		return
	}
	Camera2D_Follow(camera, position, deltaTime)
}

// A camera's own update: one that isn't its scene's camera follows its target here (the scene's
// camera does in Camera2D_Update, after every node moved)
@(private="file")
cameraNodeUpdate :: proc(node: ^Node, _: []sdl.Event, deltaTime: f64) {
	camera := cast(^Camera2D)node
	if node.scene != nil && node.scene.camera == camera do return
	if !camera.move.active do cameraFollowTarget(camera, deltaTime)
}

/*
The transform from world coordinates to screen coordinates for this camera, including any
shake. Uses the camera's interpolated (drawn) transform.

Inputs:
- camera: The camera

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

Inputs:
- camera: The camera
- world: A position in world pixels

Returns:
- The screen position, in game coordinates

Example:
	// Given: camera: ^e.Camera2D, enemy: ^e.Node
	// Draw a screen-space marker over a world object
	markerPos := e.Camera2D_WorldToScreen(camera, e.Node_GetWorldPosition(enemy))
*/
Camera2D_WorldToScreen :: proc(camera: ^Camera2D, world: [2]f32) -> [2]f32 {
	return Transform2D_Apply(Camera2D_ViewTransform(camera), world)
}

/*
Converts a screen position (e.g. from a mouse event) to the world position under it.

Inputs:
- camera: The camera
- screen: A screen position, in game coordinates

Returns:
- The world position, in world pixels

Example:
	// Given: camera: ^e.Camera2D
	world := e.Camera2D_ScreenToWorld(camera, e.Input_GetMousePosition())
	_ = world
*/
Camera2D_ScreenToWorld :: proc(camera: ^Camera2D, screen: [2]f32) -> [2]f32 {
	return Transform2D_Apply(Transform2D_Inverse(Camera2D_ViewTransform(camera)), screen)
}

/*
Eases the camera toward a world position using the settings in `camera.follow`.
Call once per frame, e.g. from the update of the node being followed.

The camera aims at `position + follow.offset`, plus the look-ahead: up to `follow.lookAhead` in
the direction the position moves between calls (eased by `follow.lookAheadSmoothing`, back to
none while it stands still). Does nothing while a `Camera2D_MoveTo` pan is running, so pans
aren't interrupted. Frame rate independent in every mode. A camera parented to the followed node
doesn't need this, nor one following a node by itself (`Camera2D_SetFollowTarget`).

Inputs:
- camera: The camera to move
- position: World position to follow, e.g. `Node_GetWorldPosition(player)`
- deltaTime: Seconds since the last frame

Example:
	// Given: player: ^e.Node
	e.Camera2D_Follow(node.scene.camera, e.Node_GetWorldPosition(player), deltaTime)
*/
Camera2D_Follow :: proc(camera: ^Camera2D, position: [2]f32, deltaTime: f64) {
	if camera.move.active do return
	dt := f32(deltaTime)
	settings := &camera.follow
	current := Camera2D_GetTarget(camera)

	// The look-ahead leans the way the position moves (by its velocity since the last call)
	ahead := &camera.lookAhead
	if settings.lookAhead != {} && ahead.started && dt > 0 {
		velocity := (position - ahead.last) / dt
		for axis in 0..<2 {
			aim: f32 = 0
			if abs(velocity[axis]) > CAMERA_LOOK_AHEAD_MIN_SPEED do aim = math.sign(velocity[axis]) * settings.lookAhead[axis]
			if settings.lookAheadSmoothing <= 0 {
				ahead.offset[axis] = aim
			} else {
				ahead.offset[axis] += (aim - ahead.offset[axis]) * (1 - math.exp(-settings.lookAheadSmoothing * dt))
			}
		}
	} else if settings.lookAhead == {} {
		ahead.offset = {}
	}
	if dt > 0 || !ahead.started do ahead.last, ahead.started = position, true
	followed := position + settings.offset + ahead.offset

	// Inside the dead zone the camera holds still; outside it, aim for the point that puts
	// the followed position back on the dead zone's edge
	goal := followed
	for axis in 0..<2 {
		half := settings.deadzone[axis] * 0.5
		if half <= 0 do continue
		diff := followed[axis] - current[axis]
		if abs(diff) <= half {
			goal[axis] = current[axis]
		} else {
			goal[axis] = followed[axis] - math.sign(diff) * half
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

The pan is advanced automatically by the scene whose camera it is, after its nodes update.
While it runs, `Camera2D_Follow` does nothing; afterwards following resumes from wherever the
pan ended. Starting a new pan replaces the current one.

Inputs:
- camera: The camera to pan
- position: World position to pan to
- duration: Seconds the pan takes. 0 or less jumps immediately
- ease: Easing curve for the pan

Example:
	// Given: camera: ^e.Camera2D, door: ^e.Node
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

Inputs:
- camera: The camera
- position: The world position to look at, in world pixels

Example:
	// Given: camera: ^e.Camera2D, spawn: [2]f32
	e.Camera2D_SnapTo(camera, spawn)
*/
Camera2D_SnapTo :: proc(camera: ^Camera2D, position: [2]f32) {
	Camera2D_SetTarget(camera, position)
	camera.velocity = {}
	camera.move.active = false
	camera.lookAhead = {}
}

/*
Tells whether a `Camera2D_MoveTo` pan is in progress.

Inputs:
- camera: The camera

Returns:
- true while it pans
*/
Camera2D_IsMoving :: proc(camera: ^Camera2D) -> bool {
	return camera.move.active
}

/*
Follows the camera's follow target (if it has one), advances an active `Camera2D_MoveTo` pan,
then applies the camera's bounds.

The scene calls this automatically for its camera after its nodes update (engine-internal).

Inputs:
- camera: The camera to update
- viewSize: Size of the visible area in screen coordinates, normally `game.size`
- deltaTime: Seconds since the last frame
*/
@(private)
Camera2D_Update :: proc(camera: ^Camera2D, viewSize: [2]f32, deltaTime: f64) {
	if !camera.move.active do cameraFollowTarget(camera, deltaTime)
	if camera.move.active {
		move := &camera.move
		move.elapsed += f32(deltaTime)
		// Small tolerance so summed frame times (e.g. 90 x 1/60) finish on the expected frame
		t := move.elapsed / move.duration
		if t >= 0.9999 do t = 1
		Camera2D_SetTarget(camera, move.from + (move.to - move.from) * Ease(move.ease, t))
		if t >= 1 {
			move.active = false
			Event_Notify(&camera.onPanFinished, camera, nil)
		}
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

A strength or duration of 0 (or left out) takes the camera's `shakeSettings` (a Camera node's
Shake settings in the editor), whose `frequency` sets how fast every shake of it jitters: that
many new positions a second, eased between (0: a new one every frame).

Inputs:
- camera: The camera
- strength: Largest offset, in screen pixels (game coordinates); 0 for the camera's setting
- duration: Seconds until it settles; 0 for the camera's setting

Example:
	e.Camera2D_Shake(node.scene.camera, 4, 0.2)
*/
Camera2D_Shake :: proc(camera: ^Camera2D, strength: f32 = 0, duration: f32 = 0) {
	if camera == nil do return
	strength := strength > 0 ? strength : camera.shakeSettings.strength
	duration := duration > 0 ? duration : camera.shakeSettings.duration
	if duration <= 0 || strength <= 0 do return
	current := camera.shake.duration > 0 ? camera.shake.strength * camera.shake.left / camera.shake.duration : 0
	if strength < current do return
	camera.shake = {strength = strength, duration = duration, left = duration, frequency = max(camera.shakeSettings.frequency, 0), from = camera.shake.offset / strength, to = randomDirection()}
}

/*
Moves a shake on by `deltaTime` real seconds: a new random offset (or, with a frequency, a step
toward the next one), scaled by the square of the time left (strong at first, settling softly).
Game_Update calls it for the current scene's camera.
*/
@(private)
Camera2D_UpdateShake :: proc(camera: ^Camera2D, deltaTime: f64) {
	shake := &camera.shake
	if shake.left <= 0 {
		shake.offset = {}
		return
	}
	shake.left = max(shake.left - f32(deltaTime), 0)
	if shake.left == 0 do Event_Notify(&camera.onShakeFinished, camera, nil)
	fade := shake.left / shake.duration
	amount := shake.strength * fade * fade
	if shake.frequency <= 0 {
		shake.offset = randomDirection() * amount
		return
	}
	shake.phase += f32(deltaTime) * shake.frequency
	for shake.phase >= 1 {
		shake.phase -= 1
		shake.from, shake.to = shake.to, randomDirection()
	}
	shake.offset = (shake.from + (shake.to - shake.from) * shake.phase) * amount
}

// A random unit direction
@(private="file")
randomDirection :: proc() -> [2]f32 {
	angle := rand.float32() * math.TAU
	return {math.cos(angle), math.sin(angle)}
}

/*
Adjusts the camera so the visible area stays inside its bounds, on the sides they limit (see
`freeSides`), taking its zoom and the view's size into account. Does nothing if the camera is
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
	lowSides := [2]CameraSide{.Left, .Top}
	highSides := [2]CameraSide{.Right, .Bottom}
	for axis in 0..<2 {
		hasLo, hasHi := lowSides[axis] not_in camera.freeSides, highSides[axis] not_in camera.freeSides
		if !hasLo && !hasHi do continue
		if hasLo && hasHi && lo[axis] > hi[axis] {
			// The world is smaller than the view on this axis: center it
			target[axis] = (camera.min[axis] + camera.max[axis]) * 0.5 + (camera.offset[axis] - viewSize[axis] * 0.5) / zoom
		} else {
			clamped := target[axis]
			if hasLo do clamped = max(clamped, lo[axis])
			if hasHi do clamped = min(clamped, hi[axis])
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

Inputs:
- scene: The scene
- screen: A screen position, in game coordinates

Returns:
- The world position, in world pixels
*/
Scene_ScreenToWorld :: proc(scene: ^Scene, screen: [2]f32) -> [2]f32 {
	if scene.camera == nil do return screen
	return Camera2D_ScreenToWorld(scene.camera, screen)
}

/*
Converts a world position to screen coordinates using the scene's camera. Without a camera,
screen and world coordinates are the same.

Inputs:
- scene: The scene
- world: A position in world pixels

Returns:
- The screen position, in game coordinates
*/
Scene_WorldToScreen :: proc(scene: ^Scene, world: [2]f32) -> [2]f32 {
	if scene.camera == nil do return world
	return Camera2D_WorldToScreen(scene.camera, world)
}

/*
The world position currently under the mouse cursor, for code that polls the mouse instead of
handling events.

Inputs:
- scene: The scene (its camera and game)

Returns:
- The world position, in world pixels

Example:
	target := e.Scene_GetMouseWorldPosition(scene)
	e.Debug_Circle(scene, target, 4)
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
