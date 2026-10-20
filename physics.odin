package crossfire

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:sync"
import b2 "box2d"
import sdl "vendor:sdl3"

/*
The physics world: Box2D 3.1 (the box2d/ package), one world per scene, created when the scene's
first physics node is. Physics nodes are in physics_nodes.odin.

Every scene update (`Scene_Update`) runs `Physics_Update`:
1. Bodies whose nodes entered the scene get their Box2D bodies and shapes; bodies whose shapes
   changed get them rebuilt.
2. The world steps at a fixed PHYSICS_TIMESTEP (as many steps as the frame's time covers, at most
   PHYSICS_MAX_STEPS). Before each step, nodes the game moved move their bodies; after it,
   dynamic bodies move their nodes, collision events are sent and RayCasts update.
Then the nodes and scripts update, so they see this frame's physics.

Units: Box2D works in meters; the engine API in pixels. `PhysicsSettings.pixelsPerMeter` (100 by
default) converts, so a 50 px crate is half a meter, which Box2D handles best (0.1 to 10 m).
Gravity is in px/s² (980 = Earth's, at 100 px per meter). Rotation maps directly: Box2D angles
in the engine's y-down space turn clockwise, like `Node.rotation` (converted to radians).
*/

// How the physics behaves; a project's comes from project.xml (`ProjectData.physics`)
PhysicsSettings :: struct {
	// Pixels per meter of the simulation. 0 means the defaults (DEFAULT_PHYSICS)
	pixelsPerMeter: f32,
	// px/s²; y points down
	gravity: [2]f32,
	// Draw every body's shapes over the scene (`Physics_DrawDebug`)
	debugDraw: bool,
	// Draw dynamic bodies between their last two physics steps (physics_debug.odin)
	smoothing: bool,
}

// The settings a world uses when the game has none: 100 px per meter, Earth's gravity, smoothing on
DEFAULT_PHYSICS :: PhysicsSettings{pixelsPerMeter = 100, gravity = {0, 980}, smoothing = true}

// Seconds per physics step (60 per second)
PHYSICS_TIMESTEP :: 1.0 / 60.0
// Box2D substeps per step: more is stiffer stacking at more cost
PHYSICS_SUBSTEPS :: 4
// Steps a frame may run to catch up, so a slow frame doesn't make the next one slower
PHYSICS_MAX_STEPS :: 5
// How close (pixels) a CharacterMover must be to something to count as touching it
MOVER_SKIN :: 1.0

// A scene's physics world (internal state; use the procedures)
PhysicsWorld :: struct {
	// The Box2D world
	id: b2.WorldId,
	// The settings it was made with (gravity and debugDraw change at run time)
	settings: PhysicsSettings,
	// Time not yet simulated
	accumulator: f64,
	// How far between the last two steps this frame is drawn (0-1), for smoothing
	alpha: f32,
	// Every body node made in the scene, in the scene or not yet
	bodies: [dynamic]^PhysicsBody,
	// Every RayCast node, cast after each step
	rayCasts: [dynamic]^RayCast,
	// Every Joint node, created in Box2D once both its bodies exist
	joints: [dynamic]^Joint,
	// Every Box2D shape's body and node (physics_events.odin)
	shapes: map[b2.ShapeId]ShapeOwner,
	// The body joints attach to when they have no body A: the world itself (static, at the origin)
	ground: b2.BodyId,
}

// Box2D keeps its worlds in one global table, unlocked: creating and destroying them is serialized
// (scenes on other threads, the tests running in parallel; a race crashed CI's tests)
@(private="file")
worldTableLock: sync.Mutex

/*
The scene's physics world, created the first time it's needed, with the game's settings
(`Game.physics`; `DEFAULT_PHYSICS` when the game has none). Creating any physics node calls it.
The scene owns the world and frees it with itself.

Inputs:
- scene: The scene

Returns:
- The world (internal state: use the `Physics_*` procedures on the scene)
*/
Scene_GetPhysics :: proc(scene: ^Scene) -> ^PhysicsWorld {
	if scene.physics != nil do return scene.physics
	world := new(PhysicsWorld)
	world.settings = DEFAULT_PHYSICS
	if scene.game != nil && scene.game.physics.pixelsPerMeter > 0 do world.settings = scene.game.physics
	if gravity, set := scene.gravity.?; set do world.settings.gravity = gravity
	world.bodies = make([dynamic]^PhysicsBody)
	world.rayCasts = make([dynamic]^RayCast)
	world.joints = make([dynamic]^Joint)
	world.shapes = make(map[b2.ShapeId]ShapeOwner)
	def := b2.DefaultWorldDef()
	def.gravity = world.settings.gravity / world.settings.pixelsPerMeter
	sync.guard(&worldTableLock)
	world.id = b2.CreateWorld(def)
	b2.World_SetPreSolveCallback(world.id, oneWayPreSolve, nil)
	scene.physics = world
	return world
}

/*
Changes the scene's gravity (creating its world if it has none).

Inputs:
- scene: The scene
- gravity: px/s², y down (`{0, 980}` is Earth's at 100 px per meter)

Example:
	e.Physics_SetGravity(scene, {0, 490}) // a low-gravity level
*/
Physics_SetGravity :: proc(scene: ^Scene, gravity: [2]f32) {
	world := Scene_GetPhysics(scene)
	world.settings.gravity = gravity
	b2.World_SetGravity(world.id, gravity / world.settings.pixelsPerMeter)
}

// Frees the scene's world (Scene_Destroy, after its nodes)
@(private)
Physics_Destroy :: proc(scene: ^Scene) {
	world := scene.physics
	if world == nil do return
	{
		sync.guard(&worldTableLock)
		if b2.World_IsValid(world.id) do b2.DestroyWorld(world.id)
	}
	delete(world.bodies)
	delete(world.rayCasts)
	delete(world.joints)
	delete(world.shapes)
	free(world)
	scene.physics = nil
}

/*
Creates the Box2D bodies of nodes that entered the scene, and rebuilds shapes that changed.
`Scene_Update` calls it (before scripts' `ready`, so they can use their bodies).
*/
@(private)
Physics_Sync :: proc(scene: ^Scene) {
	world := scene.physics
	if world == nil do return
	for body in world.bodies {
		if !body.inScene do continue
		if !b2.Body_IsValid(body.bodyId) {
			createBody(world, body)
		} else if body.shapesDirty {
			buildShapes(world, body)
		}
	}
	// Joints once both their bodies exist (physics_joints.odin)
	for joint in world.joints {
		if joint.inScene && !b2.Joint_IsValid(joint.jointId) && !joint.failed do createJoint(world, joint)
	}
}

/*
Steps the scene's physics for a frame (see the top of this file). `Scene_Update` calls it.

Inputs:
- deltaTime: Seconds since the last frame
*/
@(private)
Physics_Update :: proc(scene: ^Scene, deltaTime: f64) {
	world := scene.physics
	if world == nil || scene.physicsPaused do return
	world.accumulator = min(world.accumulator + deltaTime, PHYSICS_TIMESTEP * PHYSICS_MAX_STEPS)
	for world.accumulator >= PHYSICS_TIMESTEP {
		world.accumulator -= PHYSICS_TIMESTEP
		Physics_Sync(scene)
		pushNodePoses(world)
		rememberPoses(world)
		b2.World_Step(world.id, PHYSICS_TIMESTEP, PHYSICS_SUBSTEPS)
		pullBodyPoses(world)
		sendEvents(world)
		updateRayCasts(world)
	}
	// What's left of the frame's time: how far toward the next step drawing is (smoothing)
	world.alpha = f32(world.accumulator / PHYSICS_TIMESTEP)
}

// What a ray (or `Physics_RayCast`) hit
RayHit :: struct {
	// Whether it hit anything (the other fields are zero when not)
	hit: bool,
	// Where it hit, in world pixels
	point: [2]f32,
	// The surface's normal there (unit length, pointing out of the surface hit)
	normal: [2]f32,
	// The body hit
	body: ^PhysicsBody,
	// Which of its CollisionShapes was hit
	shape: ^CollisionShape,
	// How far along the ray, 0-1
	fraction: f32,
}

/*
Casts a ray through the scene's physics world and returns the first body it hits. Areas (sensors)
are ignored. For a ray cast after every step, use a `RayCast` node.

Inputs:
- scene: The scene
- from, to: Where the ray starts and ends, in world pixels
- mask: Layers to hit (`PhysicsLayers`; every layer by default)
- exclude: A body to ignore (the caster's own)

Returns:
- The hit: `hit` is false when nothing is in the way

Example:
	// Given: hero: ^e.CharacterMover
	// Is there ground within 40 px below the hero?
	ground := e.Physics_RayCast(scene, hero.position, hero.position + {0, 40}, exclude = hero)
	if ground.hit do log.infof("ground at %v", ground.point)
*/
Physics_RayCast :: proc(scene: ^Scene, from, to: [2]f32, mask: u64 = PHYSICS_ALL_LAYERS, exclude: ^PhysicsBody = nil) -> RayHit {
	world := Scene_GetPhysics(scene)
	ppm := world.settings.pixelsPerMeter
	Context :: struct {
		exclude: ^PhysicsBody,
		hit: RayHit,
	}
	ctx := Context{exclude = exclude}
	callback :: proc "c" (shapeId: b2.ShapeId, point, normal: b2.Vec2, fraction: f32, userData: rawptr) -> f32 {
		ctx := cast(^Context)userData
		body := cast(^PhysicsBody)b2.Body_GetUserData(b2.Shape_GetBody(shapeId))
		// -1: ignore this shape and go on; the fraction: only nearer hits from now on
		if body == nil || body == ctx.exclude || b2.Shape_IsSensor(shapeId) do return -1
		ctx.hit = {hit = true, point = point, normal = normal, body = body,
			shape = cast(^CollisionShape)b2.Shape_GetUserData(shapeId), fraction = fraction}
		return fraction
	}
	filter := b2.QueryFilter{categoryBits = PHYSICS_ALL_LAYERS, maskBits = mask}
	_ = b2.World_CastRay(world.id, from / ppm, (to - from) / ppm, filter, callback, &ctx)
	ctx.hit.point *= ppm
	return ctx.hit
}

/*
The bodies with a shape under a point.

Inputs:
- scene: The scene
- point: World pixels
- mask: Layers to find
- includeAreas: Areas count too (they're left out by default)
- allocator: For the result (the frame's temp allocator by default)

Returns:
- Each body once, in no particular order

Example:
	// What did the player click on? (The mouse is in game coordinates, not the world's)
	click := e.Scene_ScreenToWorld(scene, e.Input_GetMousePosition(scene.game))
	for body in e.Physics_QueryPoint(scene, click) {
		log.infof("clicked %s", body.name)
	}
*/
Physics_QueryPoint :: proc(scene: ^Scene, point: [2]f32, mask: u64 = PHYSICS_ALL_LAYERS, includeAreas := false, allocator := context.temp_allocator) -> []^PhysicsBody {
	ppm := Scene_GetPhysics(scene).settings.pixelsPerMeter
	points := [1]b2.Vec2{point / ppm}
	return queryOverlap(scene, b2.MakeProxy(points[:], 0), mask, includeAreas, allocator)
}

/*
The bodies with a shape overlapping an axis-aligned rectangle.

Inputs:
- scene: The scene
- rect: World pixels (x, y the top-left corner)
- mask: Layers to find
- includeAreas: Areas count too (they're left out by default)
- allocator: For the result (the frame's temp allocator by default)

Returns:
- Each body once, in no particular order

Example:
	// Given: blast: [2]f32, hurt: proc(body: ^e.PhysicsBody)
	// An explosion's square of damage
	for body in e.Physics_QueryRect(scene, {blast.x - 64, blast.y - 64, 128, 128}) do hurt(body)
*/
Physics_QueryRect :: proc(scene: ^Scene, rect: sdl.FRect, mask: u64 = PHYSICS_ALL_LAYERS, includeAreas := false, allocator := context.temp_allocator) -> []^PhysicsBody {
	ppm := Scene_GetPhysics(scene).settings.pixelsPerMeter
	points := [4]b2.Vec2{{rect.x, rect.y}, {rect.x + rect.w, rect.y}, {rect.x + rect.w, rect.y + rect.h}, {rect.x, rect.y + rect.h}}
	for &p in points do p /= ppm
	return queryOverlap(scene, b2.MakeProxy(points[:], 0), mask, includeAreas, allocator)
}

/*
The bodies with a shape overlapping a circle.

Inputs:
- scene: The scene
- center: World pixels
- radius: Pixels
- mask: Layers to find
- includeAreas: Areas count too (they're left out by default)
- allocator: For the result (the frame's temp allocator by default)

Returns:
- Each body once, in no particular order

Example:
	// Given: hero: ^e.CharacterMover, ENEMY_LAYER: u64, hit: proc(body: ^e.PhysicsBody)
	// Enemies within reach of the hero's sword
	for body in e.Physics_QueryCircle(scene, hero.position, 48, ENEMY_LAYER) do hit(body)
*/
Physics_QueryCircle :: proc(scene: ^Scene, center: [2]f32, radius: f32, mask: u64 = PHYSICS_ALL_LAYERS, includeAreas := false, allocator := context.temp_allocator) -> []^PhysicsBody {
	ppm := Scene_GetPhysics(scene).settings.pixelsPerMeter
	points := [1]b2.Vec2{center / ppm}
	return queryOverlap(scene, b2.MakeProxy(points[:], max(radius, 0) / ppm), mask, includeAreas, allocator)
}

/*
Sweeps a circle from `from` to `to` and returns the first body it would hit: a thick ray, for
checking whether something of that size fits through (a bullet, a dash). Areas and shapes the
circle starts in are ignored.

Inputs:
- scene: The scene
- radius: The circle's, in pixels
- from, to: World pixels (the circle's center)
- mask: Layers to hit
- exclude: A body to ignore (the caster's own)

Returns:
- The hit: `point` and `normal` where the circle touches, `fraction` of the way along

Example:
	// Given: hero: ^e.CharacterMover
	// How far right can the hero dash?
	hit := e.Physics_ShapeCast(scene, 12, hero.position, hero.position + {200, 0}, exclude = hero)
	dashTo := hero.position + [2]f32{200, 0} * (hit.hit ? hit.fraction : 1)
*/
Physics_ShapeCast :: proc(scene: ^Scene, radius: f32, from, to: [2]f32, mask: u64 = PHYSICS_ALL_LAYERS, exclude: ^PhysicsBody = nil) -> RayHit {
	world := Scene_GetPhysics(scene)
	ppm := world.settings.pixelsPerMeter
	Context :: struct {
		exclude: ^PhysicsBody,
		hit: RayHit,
	}
	ctx := Context{exclude = exclude}
	callback :: proc "c" (shapeId: b2.ShapeId, point, normal: b2.Vec2, fraction: f32, userData: rawptr) -> f32 {
		ctx := cast(^Context)userData
		body := cast(^PhysicsBody)b2.Body_GetUserData(b2.Shape_GetBody(shapeId))
		if fraction <= 0 || body == nil || body == ctx.exclude || b2.Shape_IsSensor(shapeId) do return -1
		ctx.hit = {hit = true, point = point, normal = normal, body = body,
			shape = cast(^CollisionShape)b2.Shape_GetUserData(shapeId), fraction = fraction}
		return fraction
	}
	points := [1]b2.Vec2{from / ppm}
	proxy := b2.MakeProxy(points[:], max(radius, 0.01) / ppm)
	filter := b2.QueryFilter{categoryBits = PHYSICS_ALL_LAYERS, maskBits = mask}
	_ = b2.World_CastShape(world.id, proxy, (to - from) / ppm, filter, callback, &ctx)
	ctx.hit.point *= ppm
	return ctx.hit
}

@(private="file")
queryOverlap :: proc(scene: ^Scene, proxy: b2.ShapeProxy, mask: u64, includeAreas: bool, allocator: runtime.Allocator) -> []^PhysicsBody {
	world := Scene_GetPhysics(scene)
	Context :: struct {
		bodies: [dynamic]^PhysicsBody,
		includeAreas: bool,
		// The caller's context, for appending from Box2D's C callback
		odin: runtime.Context,
	}
	ctx := Context{bodies = make([dynamic]^PhysicsBody, allocator), includeAreas = includeAreas, odin = context}
	callback :: proc "c" (shapeId: b2.ShapeId, userData: rawptr) -> bool {
		ctx := cast(^Context)userData
		body := cast(^PhysicsBody)b2.Body_GetUserData(b2.Shape_GetBody(shapeId))
		if body == nil || (!ctx.includeAreas && b2.Shape_IsSensor(shapeId)) do return true
		for known in ctx.bodies do if known == body do return true
		context = ctx.odin
		append(&ctx.bodies, body)
		return true
	}
	filter := b2.QueryFilter{categoryBits = PHYSICS_ALL_LAYERS, maskBits = mask}
	_ = b2.World_OverlapShape(world.id, proxy, filter, callback, &ctx)
	return ctx.bodies[:]
}

/*
Moves a CharacterMover by its `velocity` for `deltaTime` seconds, sliding along what it hits, and
updates `onFloor` / `onWall` / `onCeiling` and `floorNormal`. The part of the velocity that ran
into something is removed (it stops falling when it lands). Call it from the mover's update or
script every frame.

Uses Box2D's mover functions: collide the capsule with the world to get contact planes, solve
the planes for the move, sweep the capsule along the result (up to 5 times), then clip the
velocity against the planes.

Nothing happens until the mover's body exists (from the scene's first update after it entered),
or without a Capsule or Circle shape (a warning, once).

Inputs:
- mover: The mover
- deltaTime: Seconds to move for

Example:
	// Given: hero: ^e.CharacterMover
	hero.velocity.y += 980 * f32(deltaTime) // gravity is the game's to add
	if hero.onFloor && e.Input_IsKeyJustPressed(.Space) do hero.velocity.y = -500
	e.CharacterMover_Move(hero, deltaTime)
*/
CharacterMover_Move :: proc(mover: ^CharacterMover, deltaTime: f64) {
	world := mover.scene.physics
	if world == nil || !b2.Body_IsValid(mover.bodyId) do return
	ppm := world.settings.pixelsPerMeter
	capsule, ok := moverCapsule(mover)
	if !ok do return

	Planes :: struct {
		self: ^PhysicsBody,
		// One-way platforms count only under a mover coming down (or standing) on them
		landing: bool,
		planes: [16]b2.CollisionPlane,
		bodies: [16]^PhysicsBody,
		count: int,
	}
	collect :: proc "c" (shapeId: b2.ShapeId, result: ^b2.PlaneResult, userData: rawptr) -> bool {
		p := cast(^Planes)userData
		body := cast(^PhysicsBody)b2.Body_GetUserData(b2.Shape_GetBody(shapeId))
		if body == p.self || body == nil || !result.hit || b2.Shape_IsSensor(shapeId) do return true
		if isOneWay(shapeId) && (!p.landing || result.plane.normal.y > -ONE_WAY_NORMAL) do return true
		if p.count < len(p.planes) {
			p.planes[p.count] = {plane = result.plane, pushLimit = max(f32), push = 0, clipVelocity = true}
			p.bodies[p.count] = body
			p.count += 1
		}
		return true
	}

	xf := Node_GetWorldTransform(mover)
	position := xf.origin / ppm
	rotation := b2.MakeRot(math.to_radians(Transform2D_Rotation(xf)))
	target := position + mover.velocity * f32(deltaTime) / ppm
	filter := b2.QueryFilter{categoryBits = mover.collisionLayer, maskBits = mover.collisionMask}
	landing := !mover.dropThrough && mover.velocity.y >= 0
	planes := Planes{self = mover, landing = landing}
	tolerance: f32 = 0.01 / ppm * 100 // a hundredth of a meter at the default scale
	for _ in 0 ..< 5 {
		planes.count = 0
		world_capsule := b2.Capsule{
			center1 = position + b2.RotateVector(rotation, capsule.center1),
			center2 = position + b2.RotateVector(rotation, capsule.center2),
			radius = capsule.radius,
		}
		b2.World_CollideMover(world.id, world_capsule, filter, collect, &planes)
		result := b2.SolvePlanes(target - position, planes.planes[:planes.count])
		fraction := castMover(world.id, world_capsule, result.translation, filter, mover, landing)
		delta := fraction * result.translation
		position += delta
		if linalg.length2(delta) < tolerance * tolerance do break
	}

	// The sweep stops just short of what it hits, and planes only count when the capsule
	// touches: what the mover rests against comes from a capsule MOVER_SKIN pixels larger
	all := Planes{self = mover, landing = landing}
	contact := b2.Capsule{
		center1 = position + b2.RotateVector(rotation, capsule.center1),
		center2 = position + b2.RotateVector(rotation, capsule.center2),
		radius = capsule.radius + MOVER_SKIN / ppm,
	}
	b2.World_CollideMover(world.id, contact, filter, collect, &all)
	// Remove the part of the velocity going into each surface (b2ClipVector only clips planes
	// SolvePlanes pushed against, and these come from the probe)
	for plane in all.planes[:all.count] {
		if into := linalg.dot(mover.velocity, plane.plane.normal); into < 0 do mover.velocity -= into * plane.plane.normal
	}

	// Floor, walls and ceiling from the contact normals (they point from the surface to the mover)
	floorLimit := math.cos(math.to_radians(mover.floorMaxAngle))
	mover.onFloor, mover.onWall, mover.onCeiling = false, false, false
	mover.floorNormal = {}
	for plane in all.planes[:all.count] {
		normal := plane.plane.normal
		switch {
		case -normal.y >= floorLimit:
			mover.onFloor = true
			mover.floorNormal = normal
		case normal.y >= floorLimit:
			mover.onCeiling = true
		case:
			mover.onWall = true
		}
	}

	Node_SetWorldPosition(mover, position * ppm)
	moverContacts(mover, all.bodies[:all.count])
	// Moved by code: drawn where it is, not smoothed
	mover.previousPosition, mover.previousRotation = mover.position, mover.rotation
}

// INTERNAL

// How far up a one-way platform's contact normal must point to stop something (cos 60°)
@(private="file")
ONE_WAY_NORMAL :: 0.5

@(private="file")
isOneWay :: proc "contextless" (shapeId: b2.ShapeId) -> bool {
	shape := cast(^CollisionShape)b2.Shape_GetUserData(shapeId)
	return shape != nil && shape.oneWay
}

/*
Box2D's pre-solve for dynamic bodies: a contact with a one-way shape is kept only while the other
body is on its top side (the normal, from A to B, points up from the platform). Only shapes with
`enablePreSolveEvents` (one-way ones) get here.
*/
@(private="file")
oneWayPreSolve :: proc "c" (shapeIdA, shapeIdB: b2.ShapeId, manifold: ^b2.Manifold, ctx: rawptr) -> bool {
	// y grows downward: "up from A" is a negative y
	if isOneWay(shapeIdA) && -manifold.normal.y < ONE_WAY_NORMAL do return false
	if isOneWay(shapeIdB) && manifold.normal.y < ONE_WAY_NORMAL do return false
	return true
}

/*
World_CastMover with one-way platforms: the sweep of the mover's capsule, ignoring its own body,
sensors, shapes it starts in (as World_CastMover does) and one-way shapes unless it's landing on
their top. Returns the fraction of `translation` it can move.
*/
@(private="file")
castMover :: proc(worldId: b2.WorldId, capsule: b2.Capsule, translation: b2.Vec2, filter: b2.QueryFilter, self: ^PhysicsBody, landing: bool) -> f32 {
	Cast :: struct {
		self: ^PhysicsBody,
		landing: bool,
		fraction: f32,
	}
	cast_ := Cast{self = self, landing = landing, fraction = 1}
	callback :: proc "c" (shapeId: b2.ShapeId, point, normal: b2.Vec2, fraction: f32, userData: rawptr) -> f32 {
		c := cast(^Cast)userData
		body := cast(^PhysicsBody)b2.Body_GetUserData(b2.Shape_GetBody(shapeId))
		if fraction <= 0 || body == nil || body == c.self || b2.Shape_IsSensor(shapeId) do return -1
		if isOneWay(shapeId) && (!c.landing || normal.y > -ONE_WAY_NORMAL) do return -1
		c.fraction = min(c.fraction, fraction)
		return fraction
	}
	points := [2]b2.Vec2{capsule.center1, capsule.center2}
	proxy := b2.MakeProxy(points[:], capsule.radius)
	_ = b2.World_CastShape(worldId, proxy, translation, filter, callback, &cast_)
	return cast_.fraction
}

@(private)
pixelsPerMeter :: proc(scene: ^Scene) -> f32 {
	if scene.physics != nil do return scene.physics.settings.pixelsPerMeter
	return DEFAULT_PHYSICS.pixelsPerMeter
}

@(private="file")
createBody :: proc(world: ^PhysicsWorld, body: ^PhysicsBody) {
	ppm := world.settings.pixelsPerMeter
	xf := Node_GetWorldTransform(body)
	rotation := Transform2D_Rotation(xf)
	def := b2.DefaultBodyDef()
	def.position = xf.origin / ppm
	def.rotation = b2.MakeRot(math.to_radians(rotation))
	def.userData = body
	switch body.kind {
	case .Static:
		def.type = .staticBody
	case .Dynamic:
		d := cast(^DynamicBody)body
		def.type = .dynamicBody
		def.gravityScale = d.gravityScale
		def.linearDamping = d.linearDamping
		def.angularDamping = d.angularDamping
		def.fixedRotation = d.fixedRotation
		def.isBullet = d.bullet
		def.linearVelocity = d.initialVelocity / ppm
	case .Character, .Area:
		// Moved by code: kinematic, so it pushes dynamic bodies and isn't pushed back
		def.type = .kinematicBody
	}
	body.bodyId = b2.CreateBody(world.id, def)
	body.syncedPosition, body.syncedRotation = xf.origin, rotation
	buildShapes(world, body)
}

// (Re)creates a body's Box2D shapes from the CollisionShape nodes it owns
@(private="file")
buildShapes :: proc(world: ^PhysicsWorld, body: ^PhysicsBody) {
	body.shapesDirty = false
	existing: [32]b2.ShapeId
	for shapeId in b2.Body_GetShapes(body.bodyId, existing[:]) {
		// Its late end events still find the body (physics_events.odin)
		if owner, ok := &world.shapes[shapeId]; ok do owner.expires = 2
		b2.DestroyShape(shapeId, false)
	}

	ppm := world.settings.pixelsPerMeter
	bodyWorld := Node_GetWorldTransform(body)
	// The Box2D body has the node's position and rotation; its scale goes into the shapes
	frame := Transform2D_Inverse(Transform2D_Make(bodyWorld.origin, Transform2D_Rotation(bodyWorld), {1, 1}))

	def := b2.DefaultShapeDef()
	def.material.friction = body.friction
	def.material.restitution = body.restitution
	def.density = body.density
	def.filter = {categoryBits = body.collisionLayer, maskBits = body.collisionMask}
	def.isSensor = body.kind == .Area
	def.enableSensorEvents = true
	def.enableContactEvents = body.kind != .Area
	def.updateBodyMass = false

	visit :: proc(world: ^PhysicsWorld, node: ^Node, body: ^PhysicsBody, frame: Transform2D, ppm: f32, def: ^b2.ShapeDef) {
		for child in node.children {
			// A body under this one owns the shapes under it
			if Node_IsPhysicsBody(child) do continue
			if Node_Is(child, CollisionShape) {
				shape := cast(^CollisionShape)child
				if !shape.disabled {
					local := Transform2D_Multiply(frame, Node_GetWorldTransform(shape))
					createShape(body, shape, local, ppm, def)
					if b2.Shape_IsValid(shape.shapeId) do world.shapes[shape.shapeId] = {body = body, shape = shape}
				}
			}
			visit(world, child, body, frame, ppm, def)
		}
	}
	visit(world, body, body, frame, ppm, &def)
	b2.Body_ApplyMassFromShapes(body.bodyId)
}

// One CollisionShape as a Box2D shape. `local` maps the shape node's space to the body's (pixels)
@(private="file")
createShape :: proc(body: ^PhysicsBody, shape: ^CollisionShape, local: Transform2D, ppm: f32, def: ^b2.ShapeDef) {
	def.userData = shape
	def.enablePreSolveEvents = shape.oneWay
	point :: proc(local: Transform2D, p: [2]f32, ppm: f32) -> b2.Vec2 { return Transform2D_Apply(local, p) / ppm }
	scale := Transform2D_UniformScale(local)
	shape.shapeId = {}
	switch shape.shape {
	case .Rectangle:
		half := shape.size * 0.5
		corners := [4]b2.Vec2{
			point(local, {-half.x, -half.y}, ppm), point(local, {half.x, -half.y}, ppm),
			point(local, {half.x, half.y}, ppm), point(local, {-half.x, half.y}, ppm),
		}
		shape.shapeId = polygonShape(body, def, corners[:], shape)
	case .Circle:
		circle := b2.Circle{center = point(local, {0, 0}, ppm), radius = shape.radius * scale / ppm}
		shape.shapeId = b2.CreateCircleShape(body.bodyId, def^, &circle)
	case .Capsule:
		radius := shape.radius
		half := max(shape.height * 0.5 - radius, 0)
		if half <= 0 {
			circle := b2.Circle{center = point(local, {0, 0}, ppm), radius = radius * scale / ppm}
			shape.shapeId = b2.CreateCircleShape(body.bodyId, def^, &circle)
		} else {
			capsule := b2.Capsule{center1 = point(local, {0, -half}, ppm), center2 = point(local, {0, half}, ppm), radius = radius * scale / ppm}
			shape.shapeId = b2.CreateCapsuleShape(body.bodyId, def^, &capsule)
		}
	case .Polygon:
		if len(shape.points) < 3 {
			log.warnf("%s: a Polygon shape needs at least 3 points", shape.name)
			return
		}
		points := make([]b2.Vec2, min(len(shape.points), COLLISION_POLYGON_MAX_POINTS), context.temp_allocator)
		for &p, i in points do p = point(local, shape.points[i], ppm)
		shape.shapeId = polygonShape(body, def, points, shape)
	case .Segment:
		if len(shape.points) < 2 {
			log.warnf("%s: a Segment shape needs 2 points", shape.name)
			return
		}
		segment := b2.Segment{point1 = point(local, shape.points[0], ppm), point2 = point(local, shape.points[1], ppm)}
		shape.shapeId = b2.CreateSegmentShape(body.bodyId, def^, &segment)
	}
}

@(private="file")
polygonShape :: proc(body: ^PhysicsBody, def: ^b2.ShapeDef, points: []b2.Vec2, shape: ^CollisionShape) -> b2.ShapeId {
	hull := b2.ComputeHull(points)
	if hull.count == 0 {
		log.warnf("%s: the shape's points don't make a polygon (too small, or all in a line)", shape.name)
		return {}
	}
	polygon := b2.MakePolygon(hull, 0)
	return b2.CreatePolygonShape(body.bodyId, def^, &polygon)
}

// Before a step: bodies whose nodes the game moved follow them
@(private="file")
pushNodePoses :: proc(world: ^PhysicsWorld) {
	ppm := world.settings.pixelsPerMeter
	for body in world.bodies {
		if !body.inScene || !b2.Body_IsValid(body.bodyId) do continue
		xf := Node_GetWorldTransform(body)
		position, rotation := xf.origin, Transform2D_Rotation(xf)
		moved := linalg.length2(position - body.syncedPosition) > 1e-6 || abs(angleDifference(rotation, body.syncedRotation)) > 1e-4
		switch body.kind {
		case .Static, .Dynamic:
			// Teleports: the node was set in code. What rests on it wakes up (or it would hang in the air)
			if moved {
				b2.Body_SetTransform(body.bodyId, position / ppm, b2.MakeRot(math.to_radians(rotation)))
				contacts: [64]b2.ContactData
				for contact in b2.Body_GetContactData(body.bodyId, contacts[:]) {
					for shapeId in ([2]b2.ShapeId{contact.shapeIdA, contact.shapeIdB}) {
						if b2.Shape_IsValid(shapeId) do b2.Body_SetAwake(b2.Shape_GetBody(shapeId), true)
					}
				}
			}
		case .Character, .Area:
			// Back at the last pose, with the velocity that reaches the node's pose in one step:
			// what touches it sees it move (a mover pushes crates) instead of appearing elsewhere
			b2.Body_SetTransform(body.bodyId, body.syncedPosition / ppm, b2.MakeRot(math.to_radians(body.syncedRotation)))
			b2.Body_SetLinearVelocity(body.bodyId, (position - body.syncedPosition) / ppm / PHYSICS_TIMESTEP)
			b2.Body_SetAngularVelocity(body.bodyId, math.to_radians(angleDifference(rotation, body.syncedRotation)) / PHYSICS_TIMESTEP)
		}
		body.syncedPosition, body.syncedRotation = position, rotation
	}
}

// After a step: dynamic bodies' nodes follow them; kinematic bodies stop
@(private="file")
pullBodyPoses :: proc(world: ^PhysicsWorld) {
	ppm := world.settings.pixelsPerMeter
	for body in world.bodies {
		if !body.inScene || !b2.Body_IsValid(body.bodyId) do continue
		switch body.kind {
		case .Dynamic:
			position := b2.Body_GetPosition(body.bodyId) * ppm
			rotation := math.to_degrees(b2.Rot_GetAngle(b2.Body_GetRotation(body.bodyId)))
			setWorldPose(body, position, rotation)
			// What the node now says, so the next step doesn't take it for a move by the game
			xf := Node_GetWorldTransform(body)
			body.syncedPosition, body.syncedRotation = xf.origin, Transform2D_Rotation(xf)
		case .Character, .Area:
			b2.Body_SetLinearVelocity(body.bodyId, {})
			b2.Body_SetAngularVelocity(body.bodyId, 0)
		case .Static:
		}
	}
}

// Puts a node at a world position and rotation, whatever its parents are
@(private="file")
setWorldPose :: proc(node: ^Node, position: [2]f32, rotation: f32) {
	Node_SetWorldPosition(node, position)
	parentRotation: f32 = node.parent != nil ? Transform2D_Rotation(Node_GetWorldTransform(node.parent)) : 0
	node.rotation = rotation - parentRotation
}

// a - b in degrees, in -180..180
@(private)
angleDifference :: proc(a, b: f32) -> f32 {
	d := math.mod(a - b, 360)
	if d > 180 do d -= 360
	if d < -180 do d += 360
	return d
}

// The mover's capsule in body space (meters), from its first Capsule or Circle shape
@(private="file")
moverCapsule :: proc(mover: ^CharacterMover) -> (b2.Capsule, bool) {
	shapes: [32]b2.ShapeId
	for shapeId in b2.Body_GetShapes(mover.bodyId, shapes[:]) {
		#partial switch b2.Shape_GetType(shapeId) {
		case .capsuleShape:
			return b2.Shape_GetCapsule(shapeId), true
		case .circleShape:
			circle := b2.Shape_GetCircle(shapeId)
			return {center1 = circle.center, center2 = circle.center, radius = circle.radius}, true
		}
	}
	@(static) warned: bool
	if !warned {
		log.warnf("%s: a CharacterMover needs a Capsule or Circle CollisionShape", mover.name)
		warned = true
	}
	return {}, false
}

@(private="file")
updateRayCasts :: proc(world: ^PhysicsWorld) {
	for ray in world.rayCasts {
		if !ray.inScene || !ray.enabled do continue
		RayCast_ForceUpdate(ray)
	}
}

/*
Casts a RayCast now, updating its results (`colliding`, `point`, `normal`, `collider`,
`colliderShape`). RayCasts cast after every physics step by themselves; call this after moving
one to see the result before the next step. It casts even when the ray isn't `enabled`.

Inputs:
- ray: The RayCast node
*/
RayCast_ForceUpdate :: proc(ray: ^RayCast) {
	xf := Node_GetWorldTransform(ray)
	exclude: ^PhysicsBody
	if ray.excludeParent {
		for n := ray.parent; n != nil; n = n.parent do if Node_IsPhysicsBody(n) {
			exclude = cast(^PhysicsBody)n
			break
		}
	}
	hit := Physics_RayCast(ray.scene, xf.origin, Transform2D_Apply(xf, ray.target), ray.collisionMask, exclude)
	ray.colliding, ray.point, ray.normal, ray.collider, ray.colliderShape = hit.hit, hit.point, hit.normal, hit.body, hit.shape
}
