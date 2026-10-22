package crossfire

import "core:log"
import "core:math"
import sdl "vendor:sdl3"

/*
A 2D affine transform: maps a point p to `x * p.x + y * p.y + origin`.

`x` and `y` are where the local X and Y axes point (their lengths are the scale) and `origin` is
where the local (0, 0) lands. Composing transforms of nodes with rotation and non-uniform scale can
produce skew, which a matrix represents exactly.

Example:
	t := e.Transform2D_Make({100, 50}, 90, {2, 2})
	p := e.Transform2D_Apply(t, {1, 0}) // {100, 52}: one unit along local X, rotated 90° clockwise, doubled
*/
Transform2D :: struct {
	// Where the local X axis points; its length is the X scale
	x: [2]f32,
	// Where the local Y axis points; its length is the Y scale
	y: [2]f32,
	// Where the local (0, 0) lands
	origin: [2]f32,
}

// The transform that changes nothing: axes {1, 0} and {0, 1}, origin {0, 0}
TRANSFORM2D_IDENTITY :: Transform2D{x = {1, 0}, y = {0, 1}}

/*
Builds a transform from a position, rotation and scale. Scale is applied first, then rotation,
then the position.

Inputs:
- position: Where the local origin goes
- rotation: Degrees, clockwise (screen Y points down)
- scale: Size multiplier per axis

Returns:
- The transform
*/
Transform2D_Make :: proc(position: [2]f32, rotation: f32, scale: [2]f32) -> Transform2D {
	// Most nodes aren't rotated: no sin / cos for them (draw order makes one per node per frame)
	if rotation == 0 do return {x = {scale.x, 0}, y = {0, scale.y}, origin = position}
	r := math.to_radians(rotation)
	c, s := math.cos(r), math.sin(r)
	return {
		x = [2]f32{c, s} * scale.x,
		y = [2]f32{-s, c} * scale.y,
		origin = position,
	}
}

/*
Combines two transforms: the result applies `b` first, then `a`. A child's world transform is
`Transform2D_Multiply(parentWorld, childLocal)`.

Inputs:
- a: The transform applied second (the parent's)
- b: The transform applied first (the child's)

Returns:
- The combined transform

Example:
	// Given: parentWorld: e.Transform2D
	world := e.Transform2D_Multiply(parentWorld, e.Node_GetLocalTransform(node))
	_ = world
*/
Transform2D_Multiply :: proc(a, b: Transform2D) -> Transform2D {
	return {
		x = Transform2D_ApplyVector(a, b.x),
		y = Transform2D_ApplyVector(a, b.y),
		origin = Transform2D_Apply(a, b.origin),
	}
}

/*
Transforms a point.

Inputs:
- t: The transform
- p: The point

Returns:
- `t.x * p.x + t.y * p.y + t.origin`
*/
Transform2D_Apply :: proc(t: Transform2D, p: [2]f32) -> [2]f32 {
	return t.x * p.x + t.y * p.y + t.origin
}

/*
Transforms a direction or size: like `Transform2D_Apply`, without the translation.

Inputs:
- t: The transform
- v: The direction or size

Returns:
- `t.x * v.x + t.y * v.y`
*/
Transform2D_ApplyVector :: proc(t: Transform2D, v: [2]f32) -> [2]f32 {
	return t.x * v.x + t.y * v.y
}

/*
The transform that undoes `t`. A transform that collapses space (zero scale) has no inverse;
identity is returned for it.

Inputs:
- t: The transform

Returns:
- The inverse transform, or `TRANSFORM2D_IDENTITY` when there is none
*/
Transform2D_Inverse :: proc(t: Transform2D) -> Transform2D {
	det := t.x.x * t.y.y - t.y.x * t.x.y
	if abs(det) < 1e-12 do return TRANSFORM2D_IDENTITY
	inv := 1 / det
	result := Transform2D{
		x = {t.y.y * inv, -t.x.y * inv},
		y = {-t.y.x * inv, t.x.x * inv},
	}
	result.origin = -Transform2D_ApplyVector(result, t.origin)
	return result
}

/*
Rotation of the transform's X axis.

Inputs:
- t: The transform

Returns:
- Degrees, clockwise, from -180 to 180
*/
Transform2D_Rotation :: proc(t: Transform2D) -> f32 {
	return math.to_degrees(math.atan2(t.x.y, t.x.x))
}

/*
Length of each axis: the scale, ignoring any mirroring.

Inputs:
- t: The transform

Returns:
- The X and Y scale, both positive
*/
Transform2D_Scale :: proc(t: Transform2D) -> [2]f32 {
	return {math.sqrt(t.x.x * t.x.x + t.x.y * t.x.y), math.sqrt(t.y.x * t.y.x + t.y.y * t.y.y)}
}

/*
How much the transform scales areas, as a single length factor (the square root of the area
scale). Used for line widths and text.

Inputs:
- t: The transform

Returns:
- The length factor (1 for no scaling)
*/
Transform2D_UniformScale :: proc(t: Transform2D) -> f32 {
	return math.sqrt(abs(t.x.x * t.y.y - t.y.x * t.x.y))
}

/*
Whether the transform keeps axis-aligned rectangles axis-aligned (no rotation or skew; mirroring
is fine).

Inputs:
- t: The transform

Returns:
- true if its axes are along X and Y
*/
Transform2D_IsAxisAligned :: proc(t: Transform2D) -> bool {
	return t.x.y == 0 && t.y.x == 0
}


// NODE TRANSFORMS

/*
The node's transform relative to its parent, built from `position`, `rotation` and `scale`.

Inputs:
- node: The node

Returns:
- The local transform
*/
Node_GetLocalTransform :: proc(node: ^Node) -> Transform2D {
	return Transform2D_Make(node.position, node.rotation, node.scale)
}

/*
The node's transform in world coordinates: its local transform combined with all of its
ancestors'. Computed from the current values, so it's correct even right after something moved
during an update. The camera isn't included.

Inputs:
- node: The node

Returns:
- The world transform
*/
Node_GetWorldTransform :: proc(node: ^Node) -> Transform2D {
	world := Node_GetLocalTransform(node)
	for p := node.parent; p != nil; p = p.parent {
		world = Transform2D_Multiply(Node_GetLocalTransform(p), world)
	}
	return world
}

/*
The node's origin in world coordinates.

Inputs:
- node: The node

Returns:
- The world position

Example:
	// Given: target: ^e.Node
	toTarget := e.Node_GetWorldPosition(target) - e.Node_GetWorldPosition(node)
	node.rotation = math.to_degrees(math.atan2(toTarget.y, toTarget.x))
*/
Node_GetWorldPosition :: proc(node: ^Node) -> [2]f32 {
	return Node_GetWorldTransform(node).origin
}

/*
Moves the node so its origin is at a world position, whatever its parent's transform is.

Inputs:
- node: The node
- world: Target position in world coordinates

Example:
	// Given: target: ^e.Node
	e.Node_SetWorldPosition(node, e.Node_GetWorldPosition(target) + {0, -32})
*/
Node_SetWorldPosition :: proc(node: ^Node, world: [2]f32) {
	if node.parent == nil {
		node.position = world
		return
	}
	parentWorld := Node_GetWorldTransform(node.parent)
	node.position = Transform2D_Apply(Transform2D_Inverse(parentWorld), world)
}

/*
Where the node's origin appears on screen (game resolution coordinates): through the scene's
camera, unless the node's layer is in `scene.screenLayers`. Use it to hit-test UI nodes against
mouse events.

Inputs:
- node: The node

Returns:
- The screen position, in game coordinates
*/
Node_GetScreenPosition :: proc(node: ^Node) -> [2]f32 {
	world := Node_GetWorldPosition(node)
	scene := node.scene
	if scene == nil || scene.camera == nil || node.layer in scene.screenLayers do return world
	return Camera2D_WorldToScreen(scene.camera, world)
}

/*
Makes `child` a child of `parent`, or a top-level node when `parent` is nil. Both must be in
the same scene.

Inputs:
- child: The node to move
- parent: New parent, or nil
- keepWorld: Keep the node where it is in the world (its local position, rotation and scale
  are recalculated). Otherwise its local values are kept, so it moves with the new parent.
  Skew from a non-uniformly scaled parent can't be kept

Returns:
- false if `parent` is `child` or one of its descendants (that would make a loop), or is in
  another scene (logged)

Example:
	// Given: hand: ^e.Node, sword: ^e.Node
	e.Node_SetParent(sword, hand, keepWorld = true) // picked up where it lay
	e.Node_SetParent(sword, nil, keepWorld = true) // dropped where it is
*/
Node_SetParent :: proc(child: ^Node, parent: ^Node, keepWorld := false) -> bool {
	if child.parent == parent do return true
	// Nodes of different scenes can't be related: removing one would free the other's nodes
	// behind its scene's back
	if parent != nil && parent.scene != child.scene {
		log.errorf("Node_SetParent: the parent is in another scene")
		return false
	}
	for p := parent; p != nil; p = p.parent {
		if p == child do return false
	}

	world := Node_GetWorldTransform(child)
	if child.parent != nil do removeChild(child.parent, child)
	child.parent = parent
	if parent != nil do append(&parent.children, child)

	if keepWorld {
		local := world
		if parent != nil {
			local = Transform2D_Multiply(Transform2D_Inverse(Node_GetWorldTransform(parent)), world)
		}
		child.position = local.origin
		child.rotation = Transform2D_Rotation(local)
		child.scale = Transform2D_Scale(local)
	}
	return true
}

/*
Adds a child to a node. Same as `Node_SetParent(child, parent)`: the child keeps its local values.

Inputs:
- parent: The new parent
- child: The node to add

Returns:
- false if that would make a loop, or the nodes are in different scenes (see `Node_SetParent`)

Example:
	// Given: ship: ^e.Node
	flame := e.CreateNode(scene, e.Sprite)
	e.Node_AddChild(ship, flame)
	flame.position = {0, 40} // 40 below the ship, wherever the ship goes
*/
Node_AddChild :: proc(parent, child: ^Node) -> bool {
	return Node_SetParent(child, parent)
}

@(private)
removeChild :: proc(parent, child: ^Node) {
	for c, i in parent.children {
		if c == child {
			ordered_remove(&parent.children, i)
			return
		}
	}
}


// DRAW STATE
// While a scene draws a node, the Draw* helpers transform through the draw state's transform
// (camera view combined with the node's world transform) and multiply colors by its tint.
// Per thread: renderers on other threads (an editor's previews, tests running in parallel) each
// have their own (a shared one once made a test draw through another test's transform).

@(private)
DrawState :: struct {
	transform: Transform2D,
	tint: sdl.Color,
	blend: BlendMode,
	// The drawing node's shader (shaders.odin; nil none) and the time it sees: kept by SetDrawState
	material: ^ShaderMaterial,
	time: f32,
	// Set up (thread-local storage starts zeroed: a zero transform would draw nothing)
	ready: bool,
}

@(private, thread_local)
drawStateStorage: DrawState

// The calling thread's draw state
@(private)
drawState :: #force_inline proc "contextless" () -> ^DrawState {
	if !drawStateStorage.ready do drawStateStorage = {transform = TRANSFORM2D_IDENTITY, tint = {255, 255, 255, 255}, blend = .Blend, ready = true}
	return &drawStateStorage
}

/*
The transform the Draw* helpers currently apply: from the drawing node's local space to the
screen. Identity outside of scene drawing. Use it in custom drawing code that calls SDL directly.

Example:
	MyNode_draw :: proc(node: ^e.Node, renderer: ^sdl.Renderer) {
		p := e.Transform2D_Apply(e.GetDrawTransform(), {0, 0})
		sdl.RenderPoint(renderer, p.x, p.y)
	}
*/
GetDrawTransform :: proc() -> Transform2D {
	return drawState().transform
}

/*
Sets the transform, tint and blend mode the Draw* helpers apply (on the calling thread). Scenes
do this for each node; call it only when drawing outside a scene, and restore it afterwards.

Inputs:
- transform: Local space to screen
- tint: Multiplies every color drawn (white: unchanged)
- blend: The blend mode `DrawTexture` uses (shapes use the renderer's draw blend mode)

Example:
	e.SetDrawState(e.Transform2D_Make({200, 100}, 45, {2, 2}))
	e.DrawCircle(renderer, {0, 0}, 10, {255, 255, 255, 255})
	e.SetDrawState(e.TRANSFORM2D_IDENTITY)
*/
SetDrawState :: proc(transform: Transform2D, tint := sdl.Color{255, 255, 255, 255}, blend := BlendMode.Blend) {
	ds := drawState()
	// The node's shader stays: nodes' own drawing sets the transform again (particles)
	ds^ = {transform = transform, tint = tint, blend = blend, material = ds.material, time = ds.time, ready = true}
}

/*
The SDL blend mode of a `BlendMode`.

Inputs:
- blend: The engine's blend mode

Returns:
- The matching SDL blend mode
*/
SDLBlendMode :: proc(blend: BlendMode) -> sdl.BlendMode {
	switch blend {
	case .Blend:    return sdl.BLENDMODE_BLEND
	case .Add:      return sdl.BLENDMODE_ADD
	case .Multiply: return sdl.BLENDMODE_MUL
	case .Modulate: return sdl.BLENDMODE_MOD
	case .None:     return sdl.BLENDMODE_NONE
	}
	return sdl.BLENDMODE_BLEND
}

// The blend mode of the node drawing now, for drawing code that sets its own (geometry)
GetDrawBlend :: proc() -> sdl.BlendMode {
	return SDLBlendMode(drawState().blend)
}

// Local point to screen through the current draw transform
@(private)
toScreen :: proc(p: [2]f32) -> [2]f32 {
	return Transform2D_Apply(drawState().transform, p)
}

// Local length to screen length through the current draw transform
@(private)
toScreenLength :: proc(length: f32) -> f32 {
	return length * Transform2D_UniformScale(drawState().transform)
}

// A color multiplied by the current draw tint
@(private)
tinted :: proc(color: sdl.Color) -> sdl.Color {
	if drawState().tint == {255, 255, 255, 255} do return color
	return multiplyColor(color, drawState().tint)
}

@(private)
multiplyColor :: proc(a, b: sdl.Color) -> sdl.Color {
	return {
		u8(u16(a.r) * u16(b.r) / 255),
		u8(u16(a.g) * u16(b.g) / 255),
		u8(u16(a.b) * u16(b.b) / 255),
		u8(u16(a.a) * u16(b.a) / 255),
	}
}
