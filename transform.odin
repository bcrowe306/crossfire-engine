package engine

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
	x: [2]f32,
	y: [2]f32,
	origin: [2]f32,
}

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
*/
Transform2D_Multiply :: proc(a, b: Transform2D) -> Transform2D {
	return {
		x = Transform2D_ApplyVector(a, b.x),
		y = Transform2D_ApplyVector(a, b.y),
		origin = Transform2D_Apply(a, b.origin),
	}
}

// Transforms a point
Transform2D_Apply :: proc(t: Transform2D, p: [2]f32) -> [2]f32 {
	return t.x * p.x + t.y * p.y + t.origin
}

// Transforms a direction or size: like Apply, without the translation
Transform2D_ApplyVector :: proc(t: Transform2D, v: [2]f32) -> [2]f32 {
	return t.x * v.x + t.y * v.y
}

/*
The transform that undoes `t`. A transform that collapses space (zero scale) has no inverse;
identity is returned for it.
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

// Rotation of the transform's X axis, in degrees clockwise
Transform2D_Rotation :: proc(t: Transform2D) -> f32 {
	return math.to_degrees(math.atan2(t.x.y, t.x.x))
}

// Length of each axis: the scale, ignoring any mirroring
Transform2D_Scale :: proc(t: Transform2D) -> [2]f32 {
	return {math.sqrt(t.x.x * t.x.x + t.x.y * t.x.y), math.sqrt(t.y.x * t.y.x + t.y.y * t.y.y)}
}

// How much the transform scales areas, as a single length factor. Used for line widths and text
Transform2D_UniformScale :: proc(t: Transform2D) -> f32 {
	return math.sqrt(abs(t.x.x * t.y.y - t.y.x * t.x.y))
}

// Whether the transform keeps axis-aligned rectangles axis-aligned (no rotation or skew)
Transform2D_IsAxisAligned :: proc(t: Transform2D) -> bool {
	return t.x.y == 0 && t.y.x == 0
}


// NODE TRANSFORMS

/*
The node's transform relative to its parent, built from `position`, `rotation` and `scale`.
*/
Node_GetLocalTransform :: proc(node: ^Node) -> Transform2D {
	return Transform2D_Make(node.position, node.rotation, node.scale)
}

/*
The node's transform in world coordinates: its local transform combined with all of its
ancestors'. Computed from the current values, so it's correct even right after something moved
during an update.

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

// The node's origin in world coordinates
Node_GetWorldPosition :: proc(node: ^Node) -> [2]f32 {
	return Node_GetWorldTransform(node).origin
}

/*
Moves the node so its origin is at a world position, whatever its parent's transform is.

Inputs:
- node: The node
- world: Target position in world coordinates
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

Example:
	ship := e.CreateNode(scene, Ship)
	flame := e.CreateNode(scene, Sprite)
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
// While a scene draws a node, the Draw* helpers transform through `drawTransform` (camera view
// combined with the node's world transform) and multiply colors by `drawTint`.

@(private)
drawTransform := TRANSFORM2D_IDENTITY
@(private)
drawTint := sdl.Color{255, 255, 255, 255}

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
	return drawTransform
}

/*
Sets the transform and tint the Draw* helpers apply. Scenes do this for each node; call it only
when drawing outside a scene, and restore it afterwards.
*/
SetDrawState :: proc(transform: Transform2D, tint := sdl.Color{255, 255, 255, 255}) {
	drawTransform = transform
	drawTint = tint
}

// Local point to screen through the current draw transform
@(private)
toScreen :: proc(p: [2]f32) -> [2]f32 {
	return Transform2D_Apply(drawTransform, p)
}

// Local length to screen length through the current draw transform
@(private)
toScreenLength :: proc(length: f32) -> f32 {
	return length * Transform2D_UniformScale(drawTransform)
}

// A color multiplied by the current draw tint
@(private)
tinted :: proc(color: sdl.Color) -> sdl.Color {
	if drawTint == {255, 255, 255, 255} do return color
	return multiplyColor(color, drawTint)
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
