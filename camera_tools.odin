package crossfire

import "core:math"
import sdl "vendor:sdl3"

/*
Camera tools: **parallax layers** (backgrounds that move slower than the world, for depth),
**camera zones** (rooms the camera stays inside), **smooth zoom**, and **camera views** (what
another camera sees, in a rectangle on the screen: split screen, a minimap, picture in picture).

- **ParallaxLayer** (`ParallaxSettings`): its image (`texture`) and children move with the camera
  by `factor` of its motion: 1 like the world, 0.5 half as fast (far away), 0 not at all (the
  sky). `repeatX` / `repeatY` tile the image across the screen that way. Its position is where it
  is when the camera is where the scene starts it (`ParallaxLayer.base`); scripts move `base`.
- **CameraZone** (`size` from its position, `transition` seconds): while the scene camera's
  position is inside a zone, the camera's bounds are the zone, so it can't show past the room;
  entering another zone slides the bounds over to it. Before the first zone, the camera's own
  bounds; outside every zone after that, the last zone's bounds stay (not the camera's own).
- **Smooth zoom:** `Camera2D_ZoomTo(camera, zoom, seconds)`.
- **CameraView** (`size`, `camera`: a path to a Camera node, `zoom`, `border`): draws what that
  camera sees into its rectangle (put it on a screen layer). Each player's camera in a split
  screen, a zoomed-out camera for a minimap. Other cameras than the scene's follow by being
  children of what they follow.
*/

// A ParallaxLayer's and CameraZone's and CameraView's settings (`SceneNodeData.cameraTools`)
CameraToolSettings :: struct {
	// ParallaxLayer: how much it moves with the camera (1: like the world, 0: fixed on screen)
	factor: [2]f32,
	// ParallaxLayer: its image tiles across the screen this way
	repeatX, repeatY: bool,
	// CameraZone: seconds the camera's bounds slide to it
	transition: f32,
	// CameraView: zoom (times its camera's)
	zoom: f32,
	// CameraView: its frame's width in pixels (0: none)
	border: f32,
}

// When a scene file sets none
DEFAULT_CAMERA_TOOL_SETTINGS :: CameraToolSettings{factor = {0.5, 0.5}, transition = 0.4, zoom = 1, border = 2}

// A background layer moving slower than the world: see the file's overview
ParallaxLayer :: struct {
	using node: Node,
	settings: CameraToolSettings,
	// Its image (nil: just its children)
	texture: ^sdl.Texture,
	// Where it is when the camera is where it started (its scene file position)
	base: [2]f32,
	// The camera's position when the scene started (the parallax is relative to it)
	cameraStart: [2]f32,
	started: bool,
}

// A room the camera stays inside: see the file's overview
CameraZone :: struct {
	using node: Node,
	// Its size from its position (its top-left corner)
	size: [2]f32,
	settings: CameraToolSettings,
}

// What another camera sees, on screen: see the file's overview
CameraView :: struct {
	using node: Node,
	// Its rectangle's size, from its position (its top-left corner)
	size: [2]f32,
	settings: CameraToolSettings,
	// The camera it shows: a path from it (node arena)
	cameraPath: string,
	target: ^RenderTarget,
}

// Bounds sliding from one zone to another (`Scene.cameraZones`)
CameraZoneState :: struct {
	// The zone the camera is in (zero: none)
	zone: EntityId,
	// The bounds sliding from, to, and how far (0 to 1) over `duration`
	fromMin, fromMax, toMin, toMax: [2]f32,
	elapsed, duration: f32,
	sliding: bool,
}

/*
Creates a ParallaxLayer and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- texture: Its image (nil: just its children)
- factor: How much it moves with the camera (1: like the world, 0: fixed on screen)

Returns:
- The layer

Example:
	// Given: hills: ^sdl.Texture
	far := e.CreateParallaxLayer(scene, hills, {0.3, 0})
	far.settings.repeatX = true
*/
CreateParallaxLayer :: proc(scene: ^Scene, texture: ^sdl.Texture, factor := [2]f32{0.5, 0.5}) -> ^ParallaxLayer {
	l := CreateNode(scene, ParallaxLayer)
	l.settings = DEFAULT_CAMERA_TOOL_SETTINGS
	l.settings.factor = factor
	l.texture = texture
	l.draw = parallaxDraw
	l.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
		l := cast(^ParallaxLayer)node
		if l.texture == nil do return {}, false
		w, h: f32
		sdl.GetTextureSize(l.texture, &w, &h)
		return {0, 0, w, h}, true
	}
	return l
}

/*
Creates a CameraZone and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- size: Its width and height, from its position (its top-left corner)

Returns:
- The zone

Example:
	room := e.CreateCameraZone(scene, {640, 360})
	room.position = {640, 0}
*/
CreateCameraZone :: proc(scene: ^Scene, size: [2]f32) -> ^CameraZone {
	z := CreateNode(scene, CameraZone)
	z.size = size
	z.settings = DEFAULT_CAMERA_TOOL_SETTINGS
	z.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
		z := cast(^CameraZone)node
		return {0, 0, z.size.x, z.size.y}, true
	}
	return z
}

/*
Creates a CameraView and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- size: Its rectangle's size
- cameraPath: The Camera node it shows (a path from it)

Returns:
- The view

Example:
	minimap := e.CreateCameraView(scene, {200, 120}, "../MapCamera")
	minimap.settings.zoom = 0.2
*/
CreateCameraView :: proc(scene: ^Scene, size: [2]f32, cameraPath: string) -> ^CameraView {
	v := CreateNode(scene, CameraView)
	v.size = size
	v.settings = DEFAULT_CAMERA_TOOL_SETTINGS
	v.cameraPath = cameraPath
	v.transformMode = .Position_Only
	v.draw = cameraViewDraw
	v.destroy = cameraViewDestroy
	v.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
		v := cast(^CameraView)node
		return {0, 0, v.size.x, v.size.y}, true
	}
	return v
}

/*
Zooms a camera smoothly to a zoom over some seconds.

Inputs:
- camera: The camera
- zoom: The zoom to reach (1: unscaled)
- duration: Seconds (0: at once)
- ease: The curve

Example:
	e.Camera2D_ZoomTo(scene.camera, 2, 0.5)
*/
Camera2D_ZoomTo :: proc(camera: ^Camera2D, zoom: f32, duration: f32, ease := EaseType.InOutCubic) {
	if duration <= 0 {
		camera.zoom = zoom
		camera.zoomMove.active = false
		return
	}
	camera.zoomMove = {active = true, from = {cameraZoom(camera), 0}, to = {zoom, 0}, duration = duration, ease = ease}
}

// INTERNAL

// Parallax layers follow the camera, camera zones bound it, a zoom moves (Scene_Update, after the
// nodes and before the camera's clamp)
@(private)
CameraTools_Update :: proc(scene: ^Scene, deltaTime: f64) {
	camera := scene.camera
	if camera == nil do return
	if camera.zoomMove.active {
		m := &camera.zoomMove
		m.elapsed += f32(deltaTime)
		t := min(m.elapsed / max(m.duration, 0.0001), 1)
		camera.zoom = m.from.x + (m.to.x - m.from.x) * Ease(m.ease, t)
		if t >= 1 do m.active = false
	}
	// The zone the camera is in
	at := Node_GetWorldPosition(camera)
	state := &scene.cameraZones
	zone: ^CameraZone
	for node in scene.nodes {
		if !Node_Is(node, CameraZone) || !Node_IsVisibleInTree(node) do continue
		z := cast(^CameraZone)node
		p := Node_GetWorldPosition(z)
		if at.x >= p.x && at.y >= p.y && at.x < p.x + z.size.x && at.y < p.y + z.size.y {
			zone = z
			break
		}
	}
	if zone != nil && zone.id != state.zone {
		p := Node_GetWorldPosition(zone)
		state.toMin, state.toMax = p, p + zone.size
		if camera.bounded && state.zone != {} && zone.settings.transition > 0 {
			state.fromMin, state.fromMax = camera.min, camera.max
			state.elapsed, state.duration = 0, zone.settings.transition
			state.sliding = true
		} else {
			Camera2D_SetBounds(camera, state.toMin, state.toMax)
		}
		state.zone = zone.id
	}
	if state.sliding {
		state.elapsed += f32(deltaTime)
		t := Ease(.InOutCubic, min(state.elapsed / max(state.duration, 0.0001), 1))
		Camera2D_SetBounds(camera, state.fromMin + (state.toMin - state.fromMin) * t, state.fromMax + (state.toMax - state.fromMax) * t)
		if state.elapsed >= state.duration do state.sliding = false
	}
}

// After the camera's clamp: parallax layers take their place for this frame's view
@(private)
CameraTools_Parallax :: proc(scene: ^Scene) {
	camera := scene.camera
	cam := camera != nil ? Camera2D_GetTarget(camera) : [2]f32{}
	for node in scene.nodes {
		if !Node_Is(node, ParallaxLayer) do continue
		l := cast(^ParallaxLayer)node
		if !l.started {
			l.started = true
			l.base = l.position
			l.cameraStart = cam
		}
		l.position = l.base + (cam - l.cameraStart) * ([2]f32{1, 1} - l.settings.factor)
	}
}

@(private="file")
parallaxDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	l := cast(^ParallaxLayer)node
	if l.texture == nil do return
	w, h: f32
	sdl.GetTextureSize(l.texture, &w, &h)
	if w <= 0 || h <= 0 do return
	if !l.settings.repeatX && !l.settings.repeatY {
		DrawTexture(renderer, l.texture, {0, 0, w, h})
		return
	}
	// The screen in the layer's space: the tiles that cover it
	inverse := Transform2D_Inverse(GetDrawTransform())
	size := l.scene != nil && l.scene.game != nil ? l.scene.game.size : [2]f32{1280, 720}
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	for c in ([4][2]f32{{0, 0}, {size.x, 0}, size, {0, size.y}}) {
		p := Transform2D_Apply(inverse, c)
		lo, hi = {min(lo.x, p.x), min(lo.y, p.y)}, {max(hi.x, p.x), max(hi.y, p.y)}
	}
	x0, x1 := 0, 0
	y0, y1 := 0, 0
	if l.settings.repeatX {
		x0, x1 = int(math.floor(lo.x / w)), int(math.floor(hi.x / w))
	}
	if l.settings.repeatY {
		y0, y1 = int(math.floor(lo.y / h)), int(math.floor(hi.y / h))
	}
	// A screenful's worth at most (a far zoom-out would ask for thousands)
	if (x1 - x0 + 1) * (y1 - y0 + 1) > 4096 do return
	for y in y0..=y1 do for x in x0..=x1 do DrawTexture(renderer, l.texture, {f32(x) * w, f32(y) * h, w, h})
}

// Camera views draw the scene again into their target: not themselves (they'd never end)
@(private="file", thread_local)
drawingView: bool

@(private="file")
cameraViewDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	v := cast(^CameraView)node
	if drawingView || v.scene == nil || v.scene.game == nil || renderer == nil do return
	target := Node_FindPath(v, v.cameraPath)
	if target == nil || !Node_Is(target, Camera2D) do return
	camera := cast(^Camera2D)target
	if v.target != nil && v.target.size != v.size {
		RenderTarget_Destroy(v.target)
		v.target = nil
	}
	if v.target == nil {
		game := v.scene.game
		saved := game.renderer
		game.renderer = renderer
		v.target = RenderTarget_Create(game, v.size)
		game.renderer = saved
		if v.target == nil do return
	}
	// The camera's view, centered in the rectangle
	world := Node_GetRenderWorldTransform(camera)
	zoom := cameraZoom(camera) * max(v.settings.zoom, 0.0001)
	view := Transform2D_Make(v.size * 0.5, 0, {zoom, zoom})
	view = Transform2D_Multiply(view, Transform2D_Make({0, 0}, -Transform2D_Rotation(world), {1, 1}))
	view = Transform2D_Multiply(view, Transform2D_Make(-world.origin, 0, {1, 1}))
	saved := GetDrawTransform()
	drawingView = true
	background := v.scene.background.? or_else v.scene.game.backgroundColor
	Scene_DrawToTarget(v.scene, v.target, view, background)
	drawingView = false
	SetDrawState(saved)
	DrawTexture(renderer, v.target.texture, {0, 0, v.size.x, v.size.y})
	if v.settings.border > 0 {
		for i in 0..<int(math.round(v.settings.border)) {
			r := sdl.FRect{f32(-i - 1), f32(-i - 1), v.size.x + f32(i + 1) * 2, v.size.y + f32(i + 1) * 2}
			DrawRectangleOutline(renderer, &r, {235, 240, 255, 255})
		}
	}
}

// Frees a camera view's target (its node's destroy)
@(private)
cameraViewDestroy :: proc(node: ^Node) {
	v := cast(^CameraView)node
	RenderTarget_Destroy(v.target)
	v.target = nil
}
