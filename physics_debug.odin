package engine

import "core:math"
import "core:math/linalg"
import b2 "box2d"
import sdl "vendor:sdl3"

/*
Smoothing and debug drawing.

Smoothing (Box2D's recommendation: a fixed time step, see "Fix Your Timestep!"): the world steps
at PHYSICS_TIMESTEP whatever the frame rate, so at 144 frames per second a body would move on some
frames and not others. Instead, dynamic bodies are drawn between their pose before the last step
and after it, `PhysicsWorld.alpha` of the way (the share of a step the frame's time has
accumulated toward the next one). The simulation itself is untouched: `node.position` is the
body's real position; only drawing (`Node_GetRenderWorldTransform`: the scene's draw order, the
camera, the debug shapes) uses the in-between pose. It's one step behind at most, which is what
the technique costs. `PhysicsSettings.smoothing` turns it off. Bodies moved by code
(CharacterMover, Areas, static bodies, teleports) are drawn where they are.

Debug drawing (`settings.debugDraw`, the project's physicsDebug, `--physics-debug` for the
player, `Physics_SetDebugDraw` at run time): every shape filled and outlined in its body's color
(static green, dynamic blue, sleeping dynamic grey-blue, movers orange, Areas purple), joints
(anchors and the lines between them), and rays.
*/

/*
Shows or hides the physics debug shapes (bodies, joints, rays) in every scene of a game, now and
in scenes made later (it sets `Game.physics.debugDraw`).

Inputs:
- game: The game
- on: Show them

Example:
	if e.Input_IsKeyJustPressed(.F3) do e.Physics_SetDebugDraw(game, !game.physics.debugDraw)
*/
Physics_SetDebugDraw :: proc(game: ^Game, on: bool) {
	if game.physics.pixelsPerMeter <= 0 do game.physics = DEFAULT_PHYSICS
	game.physics.debugDraw = on
	for _, scene in game.scenes do if scene.physics != nil do scene.physics.settings.debugDraw = on
}

/*
A node's transform relative to its parent as it's drawn: for a dynamic body with smoothing on
(and physics not paused), between its last two physics poses; otherwise its local transform.

Inputs:
- node: The node

Returns:
- The transform (position, rotation and scale relative to the parent)
*/
Node_GetRenderLocalTransform :: proc(node: ^Node) -> Transform2D {
	if Node_Is(node, DynamicBody) {
		body := cast(^PhysicsBody)node
		world := node.scene.physics
		if world != nil && world.settings.smoothing && !node.scene.physicsPaused && b2.Body_IsValid(body.bodyId) {
			t := world.alpha
			position := linalg.lerp(body.previousPosition, node.position, t)
			rotation := body.previousRotation + angleDifference(node.rotation, body.previousRotation) * t
			return Transform2D_Make(position, rotation, node.scale)
		}
	}
	return Node_GetLocalTransform(node)
}

/*
A node's world transform as it's drawn (see `Node_GetRenderLocalTransform`): use it to draw at a
smoothed body, or to follow one with something drawn. It's `Node_GetWorldTransform` for nodes
with no dynamic body among them and their parents.

Inputs:
- node: The node

Returns:
- The transform, node space to world

Example:
	// Given: ball: ^e.DynamicBody
	// A shadow that follows the ball smoothly
	shadowAt := e.Node_GetRenderWorldTransform(ball).origin + {0, 20}
*/
Node_GetRenderWorldTransform :: proc(node: ^Node) -> Transform2D {
	transform := Node_GetRenderLocalTransform(node)
	for p := node.parent; p != nil; p = p.parent {
		transform = Transform2D_Multiply(Node_GetRenderLocalTransform(p), transform)
	}
	return transform
}

// Before a step: where dynamic bodies are, to draw from (after code moved them: a teleport isn't smoothed)
@(private)
rememberPoses :: proc(world: ^PhysicsWorld) {
	for body in world.bodies {
		body.previousPosition, body.previousRotation = body.position, body.rotation
	}
}

/*
Draws every body's shapes, the joints and the rays through `view` (world to screen).
`Scene_DrawWithView` calls it when `settings.debugDraw` is on.
*/
@(private)
Physics_DrawDebug :: proc(scene: ^Scene, renderer: ^sdl.Renderer, view: Transform2D) {
	world := scene.physics
	if world == nil do return
	ppm := world.settings.pixelsPerMeter
	var_blend: sdl.BlendMode
	sdl.GetRenderDrawBlendMode(renderer, &var_blend)
	sdl.SetRenderDrawBlendMode(renderer, sdl.BLENDMODE_BLEND)
	defer sdl.SetRenderDrawBlendMode(renderer, var_blend)
	SetDrawState(view)
	defer SetDrawState(TRANSFORM2D_IDENTITY)

	for body in world.bodies {
		if !b2.Body_IsValid(body.bodyId) || !body.inScene do continue
		color := debugColor(body)
		// Where the body is drawn (smoothed), as a frame without scale: shapes are in body space
		xf := Node_GetRenderWorldTransform(body)
		frame := Transform2D_Make(xf.origin, Transform2D_Rotation(xf), {1, 1})
		shapes: [32]b2.ShapeId
		for shapeId in b2.Body_GetShapes(body.bodyId, shapes[:]) {
			drawShape(renderer, shapeId, frame, ppm, color)
		}
	}
	for joint in world.joints {
		if !joint.inScene do continue
		a, b, ok := Joint_GetAnchors(joint)
		if !ok do continue
		color := sdl.Color{255, 220, 120, 255}
		// From each body's center to its anchor, then between the anchors
		if joint.connectedA != nil do DrawLine(renderer, point(Node_GetRenderWorldTransform(joint.connectedA).origin), point(a), {150, 150, 150, 200})
		if joint.connectedB != nil do DrawLine(renderer, point(Node_GetRenderWorldTransform(joint.connectedB).origin), point(b), {150, 150, 150, 200})
		DrawLine(renderer, point(a), point(b), color)
		DrawCircleOutline(renderer, point(a), 4, color)
		DrawCircle(renderer, point(b), 2.5, color)
	}
	for ray in world.rayCasts {
		if !ray.inScene || !ray.enabled do continue
		xf := Node_GetRenderWorldTransform(ray)
		to := ray.colliding ? ray.point : Transform2D_Apply(xf, ray.target)
		DrawLine(renderer, point(xf.origin), point(to), ray.colliding ? {255, 90, 90, 255} : {255, 220, 80, 255})
		if ray.colliding do DrawCircle(renderer, point(ray.point), 3, {255, 90, 90, 255})
	}
}

@(private="file")
point :: proc(p: [2]f32) -> sdl.FPoint {
	return {p.x, p.y}
}

@(private="file")
debugColor :: proc(body: ^PhysicsBody) -> sdl.Color {
	switch body.kind {
	case .Static:    return {120, 200, 120, 255}
	case .Dynamic:   return b2.Body_IsAwake(body.bodyId) ? {110, 170, 255, 255} : {90, 110, 150, 255}
	case .Character: return {255, 170, 70, 255}
	case .Area:      return {200, 120, 255, 255}
	}
	return {255, 255, 255, 255}
}

// One shape, filled (translucent) and outlined. `frame` maps body space (pixels) to the world
@(private="file")
drawShape :: proc(renderer: ^sdl.Renderer, shapeId: b2.ShapeId, frame: Transform2D, ppm: f32, color: sdl.Color) {
	toWorld :: proc(frame: Transform2D, p: b2.Vec2, ppm: f32) -> sdl.FPoint {
		return point(Transform2D_Apply(frame, p * ppm))
	}
	fill := color
	fill.a = b2.Shape_IsSensor(shapeId) ? 30 : 60
	#partial switch b2.Shape_GetType(shapeId) {
	case .polygonShape:
		polygon := b2.Shape_GetPolygon(shapeId)
		points := make([]sdl.FPoint, polygon.count, context.temp_allocator)
		for &p, i in points do p = toWorld(frame, polygon.vertices[i], ppm)
		DrawPolygon(renderer, points, fill)
		DrawPolygonOutline(renderer, points, color)
	case .circleShape:
		circle := b2.Shape_GetCircle(shapeId)
		center := toWorld(frame, circle.center, ppm)
		radius := circle.radius * ppm
		DrawCircle(renderer, center, radius, fill)
		DrawCircleOutline(renderer, center, radius, color)
		// A spoke, so rotation shows
		DrawLine(renderer, center, toWorld(frame, circle.center + {circle.radius, 0}, ppm), color)
	case .capsuleShape:
		capsule := b2.Shape_GetCapsule(shapeId)
		a, b := toWorld(frame, capsule.center1, ppm), toWorld(frame, capsule.center2, ppm)
		radius := capsule.radius * ppm
		// The outline: half circles at both ends joined by the sides
		axis := linalg.normalize0([2]f32{b.x - a.x, b.y - a.y})
		if axis == {} do axis = {0, 1}
		start := math.atan2(axis.y, axis.x)
		SEGMENTS :: 12
		outline := make([dynamic]sdl.FPoint, 0, 2 * SEGMENTS + 2, context.temp_allocator)
		for i in 0 ..= SEGMENTS {
			angle := start + math.PI * 0.5 + math.PI * f32(i) / SEGMENTS
			append(&outline, sdl.FPoint{a.x + math.cos(angle) * radius, a.y + math.sin(angle) * radius})
		}
		for i in 0 ..= SEGMENTS {
			angle := start - math.PI * 0.5 + math.PI * f32(i) / SEGMENTS
			append(&outline, sdl.FPoint{b.x + math.cos(angle) * radius, b.y + math.sin(angle) * radius})
		}
		DrawPolygon(renderer, outline[:], fill)
		DrawPolygonOutline(renderer, outline[:], color)
	case .segmentShape:
		segment := b2.Shape_GetSegment(shapeId)
		DrawLineThick(renderer, toWorld(frame, segment.point1, ppm), toWorld(frame, segment.point2, ppm), 2, color)
	}
}
