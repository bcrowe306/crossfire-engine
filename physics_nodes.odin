package engine

import "core:math"
import b2 "box2d"
import sdl "vendor:sdl3"

/*
Physics nodes. A body node (StaticBody, DynamicBody, CharacterMover, Area) gets its shape from
the CollisionShape nodes under it:

	World
	  DynamicBody "Crate"          falls, bounces, is pushed
	    Sprite                     what it looks like
	    CollisionShape Rectangle   what it collides as
	  StaticBody "Ground"
	    CollisionShape Rectangle
	  Area "Coin"                  detects bodies entering and leaving; nothing collides with it
	    CollisionShape Circle

A shape belongs to its nearest body ancestor; the shape's position, rotation and scale relative to
that body are baked into the Box2D shape when the body is created (or its shapes are rebuilt with
`PhysicsBody_RebuildShapes`). Bodies are created in the physics world at the start of the scene's
first update after they entered it (physics.odin), and destroyed with their node.

Units are the engine's: pixels, degrees (clockwise), pixels per second. Collision layers are bit
sets of layers 1-64 (`PhysicsLayer`, `PHYSICS_ALL_LAYERS`): a body is on its `collisionLayer`
layers and collides with bodies whose layers are in its `collisionMask` (both ways).

Collisions come as events (event.odin) on the body: `onCollisionEnter` when two bodies start
touching (for an Area: when a body enters it), `onCollisionExit` when they stop. The event data
is a `^Collision` (`Collision_FromEvent`). Scripts on body nodes can use the `collisionEnter` and
`collisionExit` hooks instead (script.odin).

Example:
	crate := e.CreateDynamicBody(scene)
	crate.position = {400, 100}
	shape := e.CreateCollisionShape(scene, .Rectangle)
	shape.size = {48, 48}
	e.Node_AddChild(crate, shape)
	crate.onCollisionEnter->subscribe(proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, _: rawptr) {
		hit := e.Collision_FromEvent(data)
		log.infof("%s hit %s", hit.body.name, hit.other.name)
	}, nil)
*/

// The kinds of physics body
PhysicsBodyKind :: enum {
	// Doesn't move by itself; other bodies collide with it. Moving its node moves it (teleports)
	Static,
	// Moved by gravity, forces and collisions; its node follows it
	Dynamic,
	// Moved by code (`CharacterMover_Move`), sliding along what it hits
	Character,
	// A sensor region: reports bodies entering and leaving, collides with nothing
	Area,
}

// A collision layer, 1 to 64
PhysicsLayer :: distinct int

// Every collision layer: the default collision mask
PHYSICS_ALL_LAYERS :: max(u64)

/*
What every physics body node has. The body types embed it first (`using body: PhysicsBody`), so
any of them can be used as a `^PhysicsBody`.
*/
PhysicsBody :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Which body type it is (set by its Create procedure)
	kind: PhysicsBodyKind,
	// Layers this body is on, one bit per layer (layer 1 is bit 0)
	collisionLayer: u64,
	// Layers it collides with (and, for an Area, detects)
	collisionMask: u64,
	// Surface friction: 0 = ice, 1 = rubber (default 0.6)
	friction: f32,
	// Bounciness, 0 (none, the default) to 1 (bounces back as high)
	restitution: f32,
	// kg per square meter (100 x 100 px). Only dynamic bodies use it
	density: f32,
	// A body (or Area) started touching this one
	onCollisionEnter: EventSubject,
	// They stopped touching
	onCollisionExit: EventSubject,
	// This body entered an Area (`Collision.other` is the Area)
	onAreaEnter: EventSubject,
	// This body left an Area (`Collision.other` is the Area)
	onAreaExit: EventSubject,
	// Bodies touching it (for an Area: inside it), counted per shape pair (internal: use
	// `PhysicsBody_GetContacts`, physics_events.odin)
	contacts: [dynamic]BodyContact,
	// The Areas it's in, counted per shape pair (internal: use `PhysicsBody_GetAreas`)
	areas: [dynamic]BodyContact,
	// Its local position before the last step, for smoothing (physics_debug.odin)
	previousPosition: [2]f32,
	// Its local rotation before the last step, in degrees
	previousRotation: f32,

	// The Box2D body (internal; valid once the body is in the world)
	bodyId: b2.BodyId,
	// The node's world position when the physics world last saw it, to notice code moving the node
	syncedPosition: [2]f32,
	// The node's world rotation then, in degrees
	syncedRotation: f32,
	// Rebuild the Box2D shapes before the next step
	shapesDirty: bool,
}

// A body that doesn't move by itself: walls, floors, platforms
StaticBody :: struct {
	// The body part: node, layers, surface, collision events
	using body: PhysicsBody,
}

// A body moved by the simulation: gravity, collisions, forces, impulses
DynamicBody :: struct {
	// The body part: node, layers, surface, collision events
	using body: PhysicsBody,
	// Multiplies the world's gravity (0 = floats)
	gravityScale: f32,
	// Slows its movement down over time (0 = no damping)
	linearDamping: f32,
	// Slows its spin down over time (0 = no damping)
	angularDamping: f32,
	// It never rotates (characters, upright crates)
	fixedRotation: bool,
	// Continuous collision against other dynamic bodies, for fast small things like bullets
	bullet: bool,
	// Velocity it starts with, pixels per second (used when the body is created)
	initialVelocity: [2]f32,
}

/*
A body moved by code that slides along whatever it hits, like characters in platformers and
top-down games. Set `velocity` and call `CharacterMover_Move` every frame (gravity is up to the
game: add it to the velocity). It's a kinematic body for the rest of the world: it pushes dynamic
bodies and Areas detect it, but forces don't move it.

Its shape is its first Capsule or Circle CollisionShape (Box2D movers are capsules).
*/
CharacterMover :: struct {
	// The body part: node, layers, surface, collision events
	using body: PhysicsBody,
	// Pixels per second. `CharacterMover_Move` moves by it and removes the part that ran into
	// something (landing stops the fall, a wall stops the run)
	velocity: [2]f32,
	// Steepest slope that counts as floor, in degrees (default 45)
	floorMaxAngle: f32,
	// The last move ended standing on a floor (a surface no steeper than floorMaxAngle)
	onFloor: bool,
	// The last move ended touching a wall
	onWall: bool,
	// The last move ended touching a ceiling
	onCeiling: bool,
	// The floor's normal (pointing up, away from the floor) while onFloor
	floorNormal: [2]f32,
	// One-way platforms don't stop it while set (hold it to drop through one)
	dropThrough: bool,
	// Bodies touched by the last move (internal; for collision events)
	touching: [dynamic]^PhysicsBody,
}

// A region that reports bodies entering (`onCollisionEnter`) and leaving (`onCollisionExit`)
Area :: struct {
	// The body part: node, layers, collision events
	using body: PhysicsBody,
}

// The shapes a CollisionShape can be
CollisionShapeKind :: enum {
	// `size` wide and tall, centered on the node
	Rectangle,
	// `radius`
	Circle,
	// Vertical: `height` tall overall (caps included), `radius` wide on each side
	Capsule,
	// A convex polygon through `points` (up to 8; concave outlines are made convex)
	Polygon,
	// A line from points[0] to points[1]: thin walls, ground outlines
	Segment,
}

// The most points a Polygon shape keeps (Box2D's limit)
COLLISION_POLYGON_MAX_POINTS :: 8

/*
The shape of the body it's under (its nearest body ancestor). In the node's local space: it
moves, rotates and scales with the node. After changing a shape in code, call
`PhysicsBody_RebuildShapes` on its body.
*/
CollisionShape :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Which shape it is; the fields below say which ones each uses
	shape: CollisionShapeKind,
	// Rectangle: width and height
	size: [2]f32,
	// Circle, Capsule
	radius: f32,
	// Capsule: total height
	height: f32,
	// Polygon, Segment: points in the node's space
	points: [dynamic][2]f32,
	// Left out of its body
	disabled: bool,
	// A one-way platform: only its top surface stops bodies and movers coming down onto it; from
	// below or the side they pass through (`CharacterMover.dropThrough` falls through it).
	// Change it in code with `PhysicsBody_RebuildShapes`
	oneWay: bool,
	// The Box2D shape (internal)
	shapeId: b2.ShapeId,
}

/*
Casts a ray from the node toward `target` (in the node's space) after every physics step and
reports the first thing it hits: `colliding`, `point`, `normal`, `collider`.
*/
RayCast :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// End of the ray, relative to the node
	target: [2]f32,
	// Layers it hits
	collisionMask: u64,
	// Casts after every step while set (the results keep their last values when not)
	enabled: bool,
	// Ignore the body the ray is under (a character's own body)
	excludeParent: bool,
	// The last cast hit something
	colliding: bool,
	// Where, in world pixels
	point: [2]f32,
	// The surface normal there
	normal: [2]f32,
	// The body hit (nil when not colliding)
	collider: ^PhysicsBody,
	// Which of its shapes was hit
	colliderShape: ^CollisionShape,
}

/*
What a collision event reports (`onCollisionEnter`, `onCollisionExit`, the script hooks).
Valid during the event only.
*/
Collision :: struct {
	// The body the event is for
	body: ^PhysicsBody,
	// What it touched (for an Area: the body that entered or left)
	other: ^PhysicsBody,
	// `body`'s shape that touched (nil for a CharacterMover's contacts and for exits caused by a
	// removed body)
	shape: ^CollisionShape,
	// `other`'s shape that touched (nil in the same cases)
	otherShape: ^CollisionShape,
	// Where they touch, in world pixels. Zero for exits, Areas and CharacterMover contacts
	point: [2]f32,
	// The contact normal, from `body` toward `other`. Zero like `point`
	normal: [2]f32,
}

/*
The Collision a physics event carries, in an `onCollisionEnter` / `onCollisionExit` /
`onAreaEnter` / `onAreaExit` listener.

Inputs:
- data: The event's data

Returns:
- The collision (valid during the event only), or nil if the data isn't one

Example:
	// Given: coin: ^e.Area
	coin.onCollisionEnter->subscribe(proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, _: rawptr) {
		hit := e.Collision_FromEvent(data)
		log.infof("%s picked up %s", hit.other.name, hit.body.name)
	}, nil)
*/
Collision_FromEvent :: proc(data: EventData) -> ^Collision {
	pointer, ok := data.(rawptr)
	return ok ? cast(^Collision)pointer : nil
}

/*
A collision layer set from layer numbers (1-64), for `collisionLayer` and `collisionMask`.
Numbers outside 1-64 are ignored.

Inputs:
- layers: Layer numbers

Returns:
- One bit per layer (layer 1 is bit 0)

Example:
	// Given: body: ^e.PhysicsBody
	body.collisionLayer = e.PhysicsLayers(2)
	body.collisionMask = e.PhysicsLayers(1, 3)
*/
PhysicsLayers :: proc(layers: ..PhysicsLayer) -> u64 {
	bits: u64
	for layer in layers do if layer >= 1 && layer <= 64 do bits |= 1 << u64(layer - 1)
	return bits
}

/*
Creates a StaticBody (no shape yet: add CollisionShape children). It's on layer 1 and collides
with every layer; its Box2D body is made on the scene's first update after it's in the scene.

Inputs:
- scene: The scene

Returns:
- The body (owned by the scene, like every node)

Example:
	ground := e.CreateStaticBody(scene)
	ground.position = {640, 700}
	shape := e.CreateCollisionShape(scene, .Rectangle)
	shape.size = {1280, 40}
	e.Node_AddChild(ground, shape)
*/
CreateStaticBody :: proc(scene: ^Scene) -> ^StaticBody {
	body := CreateNode(scene, StaticBody)
	initBody(body, .Static)
	return body
}

/*
Creates a DynamicBody (no shape yet: add CollisionShape children; see the example at the top of
physics_nodes.odin). Gravity scale 1, density 1, friction 0.6, on layer 1, colliding with every
layer.

Inputs:
- scene: The scene

Returns:
- The body
*/
CreateDynamicBody :: proc(scene: ^Scene) -> ^DynamicBody {
	body := CreateNode(scene, DynamicBody)
	initBody(body, .Dynamic)
	body.gravityScale = 1
	return body
}

/*
Creates a CharacterMover (give it a Capsule or Circle CollisionShape child). `floorMaxAngle` is
45 degrees. Move it with `CharacterMover_Move`.

Inputs:
- scene: The scene

Returns:
- The mover

Example:
	hero := e.CreateCharacterMover(scene)
	hero.position = {200, 300}
	e.Node_AddChild(hero, e.CreateCollisionShape(scene, .Capsule)) // 64 tall, radius 16
*/
CreateCharacterMover :: proc(scene: ^Scene) -> ^CharacterMover {
	mover := CreateNode(scene, CharacterMover)
	initBody(mover, .Character)
	mover.floorMaxAngle = 45
	mover.touching = make([dynamic]^PhysicsBody, Node_GetAllocator(mover))
	return mover
}

/*
Creates an Area (give it CollisionShape children: the region). It detects bodies on the layers in
its `collisionMask` (all by default).

Inputs:
- scene: The scene

Returns:
- The Area
*/
CreateArea :: proc(scene: ^Scene) -> ^Area {
	area := CreateNode(scene, Area)
	initBody(area, .Area)
	return area
}

/*
Creates a CollisionShape with default dimensions (a 32 x 32 rectangle, radius 16, a 64 tall
capsule; Polygon and Segment need their `points`). Make it a child of a body node (or of a node
under one): its body includes it from the next physics step after it enters the scene.

Inputs:
- scene: The scene
- kind: The shape

Returns:
- The shape node
*/
CreateCollisionShape :: proc(scene: ^Scene, kind: CollisionShapeKind) -> ^CollisionShape {
	shape := CreateNode(scene, CollisionShape)
	shape.shape = kind
	shape.size = {32, 32}
	shape.radius = 16
	shape.height = 64
	shape.points = make([dynamic][2]f32, Node_GetAllocator(shape))
	shape.destroy = collisionShapeDestroyed
	shape.getBounds = collisionShapeBounds
	// Its body (once it has one) includes it from the next step
	shape.onEnter->subscribe(proc(_: ^EventSubject, source: rawptr, _: EventData, _: rawptr) {
		if body := CollisionShape_GetBody(cast(^CollisionShape)source); body != nil do body.shapesDirty = true
	}, nil)
	return shape
}

/*
Creates a RayCast, enabled, hitting every layer and ignoring the body it's under. Parent it to
the node it casts from.

Inputs:
- scene: The scene
- target: The ray's end, relative to the node (pixels; 50 down by default)

Returns:
- The RayCast

Example:
	// Given: hero: ^e.CharacterMover
	feet := e.CreateRayCast(scene, {0, 40})
	e.Node_AddChild(hero, feet)
	// Later, in the hero's update:
	if feet.colliding do log.infof("standing on %s", feet.collider.name)
*/
CreateRayCast :: proc(scene: ^Scene, target: [2]f32 = {0, 50}) -> ^RayCast {
	ray := CreateNode(scene, RayCast)
	ray.target = target
	ray.collisionMask = PHYSICS_ALL_LAYERS
	ray.enabled = true
	ray.excludeParent = true
	world := Scene_GetPhysics(scene)
	append(&world.rayCasts, ray)
	ray.destroy = proc(node: ^Node) {
		if world := node.scene.physics; world != nil do removeFromSlice(&world.rayCasts, cast(^RayCast)node)
	}
	return ray
}

/*
Whether a node is a physics body of any kind (StaticBody, DynamicBody, CharacterMover, Area).

Inputs:
- node: The node (nil is no body)

Returns:
- true if it can be used as a `^PhysicsBody`
*/
Node_IsPhysicsBody :: proc(node: ^Node) -> bool {
	return node != nil && (node.type == StaticBody || node.type == DynamicBody || node.type == CharacterMover || node.type == Area)
}

/*
The body a shape belongs to: its nearest body ancestor.

Inputs:
- shape: The shape

Returns:
- The body, or nil if no body is above it
*/
CollisionShape_GetBody :: proc(shape: ^CollisionShape) -> ^PhysicsBody {
	for n := shape.parent; n != nil; n = n.parent {
		if Node_IsPhysicsBody(n) do return cast(^PhysicsBody)n
	}
	return nil
}

/*
Rebuilds a body's Box2D shapes from its CollisionShape nodes before the next step. Call it after
changing a shape's size, points, position, `oneWay` or `disabled` in code, or the body's
`friction`, `restitution` or `density`.

Inputs:
- body: The body
*/
PhysicsBody_RebuildShapes :: proc(body: ^PhysicsBody) {
	body.shapesDirty = true
}

/*
Changes the layers a body is on and collides with (its shapes are rebuilt before the next step).

Inputs:
- body: The body
- layer: Layers it's on (`PhysicsLayers`)
- mask: Layers it collides with (for an Area: detects)
*/
PhysicsBody_SetLayers :: proc(body: ^PhysicsBody, layer, mask: u64) {
	body.collisionLayer, body.collisionMask = layer, mask
	if b2.Body_IsValid(body.bodyId) do body.shapesDirty = true
}

/*
A dynamic body's velocity.

Inputs:
- body: The body

Returns:
- Pixels per second (before its Box2D body exists: `initialVelocity`)
*/
DynamicBody_GetVelocity :: proc(body: ^DynamicBody) -> [2]f32 {
	if !b2.Body_IsValid(body.bodyId) do return body.initialVelocity
	return b2.Body_GetLinearVelocity(body.bodyId) * pixelsPerMeter(body.scene)
}

/*
Sets a dynamic body's velocity (before its Box2D body exists: its `initialVelocity`).

Inputs:
- body: The body
- velocity: Pixels per second

Example:
	// Given: ball: ^e.DynamicBody
	e.DynamicBody_SetVelocity(ball, {300, -400})
*/
DynamicBody_SetVelocity :: proc(body: ^DynamicBody, velocity: [2]f32) {
	if !b2.Body_IsValid(body.bodyId) {
		body.initialVelocity = velocity
		return
	}
	b2.Body_SetLinearVelocity(body.bodyId, velocity / pixelsPerMeter(body.scene))
}

/*
A dynamic body's spin speed.

Inputs:
- body: The body

Returns:
- Degrees per second, clockwise (0 before its Box2D body exists)
*/
DynamicBody_GetAngularVelocity :: proc(body: ^DynamicBody) -> f32 {
	if !b2.Body_IsValid(body.bodyId) do return 0
	return math.to_degrees(b2.Body_GetAngularVelocity(body.bodyId))
}

/*
Sets a dynamic body's spin speed. Does nothing before its Box2D body exists (the scene's first
update after it entered).

Inputs:
- body: The body
- degreesPerSecond: Clockwise
*/
DynamicBody_SetAngularVelocity :: proc(body: ^DynamicBody, degreesPerSecond: f32) {
	if b2.Body_IsValid(body.bodyId) do b2.Body_SetAngularVelocity(body.bodyId, math.to_radians(degreesPerSecond))
}

/*
Gives a dynamic body an instant push at its center: its velocity changes by impulse / mass, and
it wakes up. Does nothing before its Box2D body exists.

Inputs:
- body: The body
- impulse: kg·px/s, so an impulse of mass × 300 changes the velocity by 300 px/s whatever the
  body weighs (`DynamicBody_GetMass`)

Example:
	// Given: crate: ^e.DynamicBody
	// Knock the crate up and right by 300 px/s
	e.DynamicBody_ApplyImpulse(crate, e.DynamicBody_GetMass(crate) * [2]f32{150, -260})
*/
DynamicBody_ApplyImpulse :: proc(body: ^DynamicBody, impulse: [2]f32) {
	if b2.Body_IsValid(body.bodyId) do b2.Body_ApplyLinearImpulseToCenter(body.bodyId, impulse / pixelsPerMeter(body.scene), true)
}

/*
Pushes a dynamic body at its center during the next step, waking it (Box2D clears forces after
each step: call it every frame for a steady force). Does nothing before its Box2D body exists.

Inputs:
- body: The body
- force: kg·px/s² (mass × acceleration in px/s²)
*/
DynamicBody_ApplyForce :: proc(body: ^DynamicBody, force: [2]f32) {
	if b2.Body_IsValid(body.bodyId) do b2.Body_ApplyForceToCenter(body.bodyId, force / pixelsPerMeter(body.scene), true)
}

/*
A dynamic body's mass, from its shapes.

Inputs:
- body: The body

Returns:
- kg: its shapes' area in square meters × `density` (0 before its Box2D body exists)
*/
DynamicBody_GetMass :: proc(body: ^DynamicBody) -> f32 {
	if !b2.Body_IsValid(body.bodyId) do return 0
	return b2.Body_GetMass(body.bodyId)
}

/*
The bodies inside an Area right now (the same as `PhysicsBody_GetContacts` on it). Areas see
bodies whose layers are in their mask. Kept up to date by every physics step (physics_events.odin).

Inputs:
- area: The Area
- allocator: For the result (the frame's temp allocator by default)

Returns:
- The bodies, in the order they entered
*/
Area_GetOverlaps :: proc(area: ^Area, allocator := context.temp_allocator) -> []^PhysicsBody {
	return PhysicsBody_GetContacts(area, allocator)
}

@(private="file")
initBody :: proc(body: ^PhysicsBody, kind: PhysicsBodyKind) {
	allocator := Node_GetAllocator(body)
	body.kind = kind
	body.collisionLayer = PhysicsLayers(1)
	body.collisionMask = PHYSICS_ALL_LAYERS
	body.friction = 0.6
	body.density = 1
	EventSubject_Init(&body.onCollisionEnter, allocator)
	EventSubject_Init(&body.onCollisionExit, allocator)
	EventSubject_Init(&body.onAreaEnter, allocator)
	EventSubject_Init(&body.onAreaExit, allocator)
	body.contacts = make([dynamic]BodyContact, allocator)
	body.areas = make([dynamic]BodyContact, allocator)
	world := Scene_GetPhysics(body.scene)
	append(&world.bodies, body)
	body.destroy = physicsBodyDestroyed
}

@(private="file")
physicsBodyDestroyed :: proc(node: ^Node) {
	body := cast(^PhysicsBody)node
	// Exits for everything it touched, first: they still see it as it was
	if world := node.scene.physics; world != nil do physicsForgetBody(world, body)
	if b2.Body_IsValid(body.bodyId) do b2.DestroyBody(body.bodyId)
	body.bodyId = {}
	if world := node.scene.physics; world != nil do removeFromSlice(&world.bodies, body)
}

// The shape's extent in its own space: editors pick and outline shapes by it (shapes draw nothing)
@(private="file")
collisionShapeBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	shape := cast(^CollisionShape)node
	switch shape.shape {
	case .Rectangle:
		return {-shape.size.x * 0.5, -shape.size.y * 0.5, shape.size.x, shape.size.y}, true
	case .Circle:
		return {-shape.radius, -shape.radius, shape.radius * 2, shape.radius * 2}, true
	case .Capsule:
		half := max(shape.height * 0.5, shape.radius)
		return {-shape.radius, -half, shape.radius * 2, half * 2}, true
	case .Polygon, .Segment:
		if len(shape.points) == 0 do return {}, false
		lo, hi := shape.points[0], shape.points[0]
		for p in shape.points[1:] {
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x), max(hi.y, p.y)}
		}
		return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, true
	}
	return {}, false
}

@(private="file")
collisionShapeDestroyed :: proc(node: ^Node) {
	shape := cast(^CollisionShape)node
	// A body destroyed first took its Box2D shapes with it
	if b2.Shape_IsValid(shape.shapeId) {
		// Its late end events still find its body, not the freed node (physics_events.odin)
		if world := node.scene.physics; world != nil {
			if owner, ok := &world.shapes[shape.shapeId]; ok do owner.shape, owner.expires = nil, 2
		}
		bodyId := b2.Shape_GetBody(shape.shapeId)
		b2.DestroyShape(shape.shapeId, true)
		if body := cast(^PhysicsBody)b2.Body_GetUserData(bodyId); body != nil do body.shapesDirty = true
	}
	shape.shapeId = {}
}

// The body node a Box2D shape belongs to
@(private)
bodyOfShape :: proc(shapeId: b2.ShapeId) -> ^PhysicsBody {
	return cast(^PhysicsBody)b2.Body_GetUserData(b2.Shape_GetBody(shapeId))
}

@(private)
removeFromSlice :: proc(list: ^[dynamic]$T, item: T) {
	for x, i in list {
		if x == item {
			ordered_remove(list, i)
			return
		}
	}
}
