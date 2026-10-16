#+build !js
package engine

import "core:testing"
import b2 "box2d"
import sdl "vendor:sdl3"

// Physics tests: real Box2D worlds in scenes without a window (no SDL needed)

@(private="file")
testScene :: proc() -> ^Scene {
	scene := new(Scene)
	Scene_Init(scene)
	return scene
}

@(private="file")
freeScene :: proc(scene: ^Scene) {
	Scene_Destroy(scene)
	free(scene)
}

// Runs the scene for some seconds at 60 frames per second
@(private="file")
run :: proc(scene: ^Scene, seconds: f64) {
	for _ in 0 ..< int(seconds * 60) do Scene_Update(scene, nil, 1.0 / 60.0)
}

@(private="file")
box :: proc(scene: ^Scene, body: ^Node, size: [2]f32) -> ^CollisionShape {
	shape := CreateCollisionShape(scene, .Rectangle)
	shape.size = size
	Node_AddChild(body, shape)
	return shape
}

// Counts a body's collision events and remembers the last one
@(private="file")
Counter :: struct {
	enters, exits: int,
	other: ^PhysicsBody,
	point, normal: [2]f32,
}

@(private="file")
count :: proc(body: ^PhysicsBody, counter: ^Counter) {
	body.onCollisionEnter->subscribe(proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
		c := cast(^Counter)user
		hit := Collision_FromEvent(data)
		c.enters += 1
		c.other, c.point, c.normal = hit.other, hit.point, hit.normal
	}, counter)
	body.onCollisionExit->subscribe(proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) {
		(cast(^Counter)user).exits += 1
	}, counter)
}

@(private="file")
near :: proc(a, b, tolerance: f32) -> bool {
	return abs(a - b) <= tolerance
}

@(test)
physics_body_falls_and_lands :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	ground := CreateStaticBody(scene)
	ground.name = "Ground"
	ground.position = {0, 300}
	box(scene, ground, {400, 20})
	// Under a moved parent: its node keeps the parent's offset
	holder := CreateNode(scene, Node)
	holder.position = {50, 0}
	crate := CreateDynamicBody(scene)
	crate.name = "Crate"
	crate.position = {0, 100}
	Node_AddChild(holder, crate)
	box(scene, crate, {20, 20})
	crateHits, groundHits: Counter
	count(crate, &crateHits)
	count(ground, &groundHits)

	run(scene, 0.5)
	testing.expect(t, crate.position.y > 100, "falls")
	run(scene, 2)
	// Resting on the ground's top (290), its center 10 above
	testing.expectf(t, near(crate.position.y, 280, 1), "landed at %v", crate.position.y)
	testing.expectf(t, near(crate.position.x, 0, 0.5), "local x stays %v", crate.position.x)
	testing.expect(t, near(Node_GetWorldPosition(crate).x, 50, 0.5))
	testing.expect_value(t, crateHits.enters, 1)
	testing.expect_value(t, groundHits.enters, 1)
	testing.expect(t, crateHits.other == ground && groundHits.other == crate)
	// Normal from the crate toward the ground: down
	testing.expectf(t, crateHits.normal.y > 0.9 && groundHits.normal.y < -0.9, "normals %v %v", crateHits.normal, groundHits.normal)
	testing.expectf(t, near(crateHits.point.y, 290, 2), "contact point %v", crateHits.point)

	// Code moving a static body moves it: the crate falls again
	ground.position.y = 400
	run(scene, 1)
	testing.expectf(t, near(crate.position.y, 380, 1), "followed the ground to %v", crate.position.y)
}

@(test)
physics_dynamic_api :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	Physics_SetGravity(scene, {0, 0})
	puck := CreateDynamicBody(scene)
	shape := CreateCollisionShape(scene, .Circle)
	shape.radius = 10
	Node_AddChild(puck, shape)
	// Before its body exists, a velocity is kept for it
	DynamicBody_SetVelocity(puck, {120, 0})
	run(scene, 1)
	testing.expectf(t, near(puck.position.x, 120, 3), "moved %v at 120 px/s", puck.position.x)
	testing.expect(t, near(DynamicBody_GetVelocity(puck).x, 120, 0.1))
	// An impulse of mass x 60 adds 60 px/s
	DynamicBody_ApplyImpulse(puck, {0, DynamicBody_GetMass(puck) * 60})
	testing.expectf(t, near(DynamicBody_GetVelocity(puck).y, 60, 0.5), "impulse gave %v", DynamicBody_GetVelocity(puck))
	DynamicBody_SetAngularVelocity(puck, 90)
	before := puck.rotation
	run(scene, 1)
	testing.expectf(t, near(puck.rotation - before, 90, 3), "turned %v degrees", puck.rotation - before)
}

@(test)
physics_area_and_layers :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	area := CreateArea(scene)
	area.position = {0, 200}
	area.collisionMask = PhysicsLayers(1)
	box(scene, area, {200, 40})
	ball := CreateDynamicBody(scene)
	ball.name = "Ball"
	circle := CreateCollisionShape(scene, .Circle)
	circle.radius = 10
	Node_AddChild(ball, circle)
	// On layer 2: the area doesn't watch it
	ghost := CreateDynamicBody(scene)
	ghost.position = {60, 0}
	ghost.collisionLayer = PhysicsLayers(2)
	box(scene, ghost, {10, 10})
	areaHits: Counter
	count(area, &areaHits)

	inside := false
	for _ in 0 ..< 120 {
		Scene_Update(scene, nil, 1.0 / 60.0)
		overlaps := Area_GetOverlaps(area)
		if len(overlaps) == 1 && overlaps[0] == ball do inside = true
	}
	testing.expect_value(t, areaHits.enters, 1)
	testing.expect_value(t, areaHits.exits, 1)
	testing.expect(t, areaHits.other == ball)
	testing.expect(t, inside, "Area_GetOverlaps saw the ball inside")
	// Sensors don't stop anything
	testing.expect(t, ball.position.y > 300)

	// Layers: a floor that only collides with layer 1 lets layer 2 fall through
	floor := CreateStaticBody(scene)
	floor.position = {0, 2000}
	floor.collisionMask = PhysicsLayers(1)
	box(scene, floor, {1000, 20})
	run(scene, 4)
	testing.expectf(t, near(ball.position.y, 1980, 2), "the ball lands at %v", ball.position.y)
	testing.expectf(t, ghost.position.y > 2100, "layer 2 falls through, at %v", ghost.position.y)
	testing.expect_value(t, PhysicsLayers(1, 3, 64), u64(1) | 4 | 1 << 63)
}

@(test)
physics_raycast :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	wall := CreateStaticBody(scene)
	wall.name = "Wall"
	wall.position = {0, 100}
	wallShape := box(scene, wall, {40, 20})
	ray := CreateRayCast(scene, {0, 200})
	ray.position = {15, 0}
	// A ray under a body ignores that body
	owner := CreateStaticBody(scene)
	box(scene, owner, {10, 10})
	ownRay := CreateRayCast(scene, {0, 200})
	Node_AddChild(owner, ownRay)
	run(scene, 0.1)

	testing.expect(t, ray.colliding)
	testing.expect(t, ray.collider == wall && ray.colliderShape == wallShape)
	testing.expectf(t, near(ray.point.y, 90, 0.5) && near(ray.point.x, 15, 0.5), "hit at %v", ray.point)
	testing.expectf(t, near(ray.normal.y, -1, 0.01), "normal %v", ray.normal)
	testing.expect(t, ownRay.colliding && ownRay.collider == wall)

	miss := Physics_RayCast(scene, {100, 0}, {100, 300})
	testing.expect(t, !miss.hit)
	masked := Physics_RayCast(scene, {0, 0}, {0, 300}, mask = PhysicsLayers(5))
	testing.expect(t, !masked.hit)

	// A rotated parent turns the ray: pointing along +x now, it misses
	turner := CreateNode(scene, Node)
	turner.position = {15, 0}
	turner.rotation = -90
	turned := CreateRayCast(scene, {0, 200})
	Node_AddChild(turner, turned)
	run(scene, 0.1)
	testing.expect(t, !turned.colliding)
}

@(test)
physics_character_mover :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	ground := CreateStaticBody(scene)
	ground.name = "Ground"
	ground.position = {0, 300}
	box(scene, ground, {2000, 20})
	wall := CreateStaticBody(scene)
	wall.name = "Wall"
	wall.position = {300, 200}
	box(scene, wall, {20, 400})

	mover := CreateCharacterMover(scene)
	mover.position = {0, 100}
	capsule := CreateCollisionShape(scene, .Capsule)
	capsule.radius = 10
	capsule.height = 40
	Node_AddChild(mover, capsule)
	hits: Counter
	count(mover, &hits)
	groundHits: Counter
	count(ground, &groundHits)
	mover.update = proc(node: ^Node, _: []sdl.Event, dt: f64) {
		m := cast(^CharacterMover)node
		m.velocity.y += 980 * f32(dt)
		m.velocity.x = 150
		CharacterMover_Move(m, dt)
	}

	run(scene, 0.6)
	testing.expect(t, mover.onFloor, "landed")
	// The capsule's bottom on the ground's top: 290 - 20
	testing.expectf(t, near(mover.position.y, 270, 1.5), "standing at %v", mover.position.y)
	testing.expectf(t, near(mover.velocity.y, 0, 1), "landing stopped the fall: %v", mover.velocity)
	testing.expectf(t, near(mover.floorNormal.y, -1, 0.01), "floor normal %v", mover.floorNormal)
	testing.expect(t, hits.enters >= 1 && groundHits.enters >= 1)
	testing.expect(t, hits.other == ground)

	run(scene, 3)
	// Stopped by the wall (its left side at 290, the capsule 10 wide on each side)
	testing.expectf(t, near(mover.position.x, 280, 1.5), "stopped at %v", mover.position.x)
	testing.expect(t, mover.onWall && mover.onFloor)
	testing.expectf(t, near(mover.position.y, 270, 1.5), "still standing at %v", mover.position.y)

	// It pushes a crate in its way (kinematic for the rest of the world)
	crate := CreateDynamicBody(scene)
	crate.position = {200, 280}
	box(scene, crate, {20, 20})
	mover.position.x = 100
	mover.update = proc(node: ^Node, _: []sdl.Event, dt: f64) {
		m := cast(^CharacterMover)node
		m.velocity = {-100, 0}
		CharacterMover_Move(m, dt)
	}
	run(scene, 0.1)
	mover.position.x = 160
	mover.update = proc(node: ^Node, _: []sdl.Event, dt: f64) {
		m := cast(^CharacterMover)node
		m.velocity = {80, m.velocity.y + 980 * f32(dt)}
		CharacterMover_Move(m, dt)
	}
	run(scene, 1)
	testing.expectf(t, crate.position.x > 205, "the crate was pushed to %v", crate.position.x)
}

@(test)
physics_shapes_and_removal :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	Physics_SetGravity(scene, {0, 0})
	body := CreateStaticBody(scene)
	body.scale = {2, 2}
	body.rotation = 90
	poly := CreateCollisionShape(scene, .Polygon)
	append(&poly.points, [2]f32{-10, -10}, [2]f32{10, -10}, [2]f32{0, 10})
	Node_AddChild(body, poly)
	segment := CreateCollisionShape(scene, .Segment)
	append(&segment.points, [2]f32{0, 0}, [2]f32{100, 0})
	segment.position = {0, 50}
	Node_AddChild(body, segment)
	circle := CreateCollisionShape(scene, .Circle)
	circle.radius = 5
	circle.disabled = true
	Node_AddChild(body, circle)
	run(scene, 0.1)
	shapes: [8]b2.ShapeId
	testing.expect_value(t, len(b2.Body_GetShapes(body.bodyId, shapes[:])), 2)
	// Scale and rotation are baked in: the triangle's tip (0, 10) x2, turned 90° clockwise, is at (-20, 0)
	// (The segment, at local y 50, is at world x -100: start the ray after it)
	hit := Physics_RayCast(scene, {-60, 0}, {0, 0})
	testing.expectf(t, hit.hit && near(hit.point.x, -20, 0.5), "tip at %v", hit.point)

	// Rebuilding after a change
	circle.disabled = false
	PhysicsBody_RebuildShapes(body)
	run(scene, 0.1)
	testing.expect_value(t, len(b2.Body_GetShapes(body.bodyId, shapes[:])), 3)

	// Bounds for editors: the rectangle the shape covers, in its own space
	bounds, hasBounds := Node_GetLocalBounds(poly)
	testing.expect(t, hasBounds && bounds == sdl.FRect{-10, -10, 20, 20})

	// Paused physics doesn't step (editors), but bodies exist
	falling := CreateDynamicBody(scene)
	box(scene, falling, {10, 10})
	Physics_SetGravity(scene, {0, 980})
	scene.physicsPaused = true
	run(scene, 0.5)
	testing.expect(t, falling.position.y == 0 && b2.Body_IsValid(falling.bodyId))
	scene.physicsPaused = false
	run(scene, 0.5)
	testing.expect(t, falling.position.y > 50)
	scene->removeNode(falling.id)
	run(scene, 0.05)

	// Removing a body removes it from the world; its shapes' nodes go with it
	world := scene.physics
	testing.expect_value(t, len(world.bodies), 1)
	scene->removeNode(body.id)
	run(scene, 0.1)
	testing.expect_value(t, len(world.bodies), 0)
	testing.expect(t, !Physics_RayCast(scene, {-60, 0}, {0, 0}).hit)
}

@(test)
physics_scene_file :: proc(t: ^testing.T) {
	text := `<?xml version="1.0" encoding="UTF-8"?>
<scene formatVersion="4" name="Physics">
	<node kind="StaticBody" name="Ground" x="0" y="300" collisionLayer="1 2" collisionMask="all" friction="0.2">
		<node kind="CollisionShape" name="GroundShape" shape="Rectangle" width="400" height="20"/>
	</node>
	<node kind="DynamicBody" name="Ball" x="0" y="0" restitution="0.5" density="2" gravityScale="1"
	      linearDamping="0.1" fixedRotation="true" bullet="true" collisionLayer="2" collisionMask="1">
		<node kind="CollisionShape" shape="Circle" radius="10"/>
		<node kind="RayCast" name="Down" targetX="0" targetY="100" excludeParent="true" collisionMask="1"/>
	</node>
	<node kind="CharacterMover" name="Hero" x="-100" y="0" floorMaxAngle="50">
		<node kind="CollisionShape" shape="Capsule" radius="8" height="30"/>
	</node>
	<node kind="Area" name="Zone" x="0" y="150" collisionMask="2">
		<node kind="CollisionShape" shape="Polygon" points="-50,-10 50,-10 50,10 -50,10" disabled="false"/>
		<node kind="CollisionShape" shape="Segment" points="0,0 10,5" disabled="true"/>
	</node>
</scene>`
	data, err := ParseScene(text)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, len(data.nodes), 10)
	ground, ball, hero, zone := data.nodes[0], data.nodes[2], data.nodes[5], data.nodes[7]
	testing.expect_value(t, ground.kind, SceneNodeKind.StaticBody)
	testing.expect_value(t, ground.collisionLayer, u64(3))
	testing.expect_value(t, ground.collisionMask, PHYSICS_ALL_LAYERS)
	testing.expect_value(t, ground.friction, 0.2)
	testing.expect_value(t, data.nodes[1].shapeSize, [2]f32{400, 20})
	testing.expect(t, ball.restitution == 0.5 && ball.density == 2 && ball.linearDamping == 0.1 && ball.fixedRotation && ball.bullet)
	testing.expect_value(t, data.nodes[3].radius, 10)
	ray := data.nodes[4]
	testing.expect(t, ray.kind == .RayCast && ray.target == {0, 100} && ray.excludeParent && ray.collisionMask == 1)
	testing.expect_value(t, hero.floorMaxAngle, 50)
	testing.expect(t, data.nodes[6].shape == .Capsule && data.nodes[6].shapeSize.y == 30)
	testing.expect_value(t, zone.collisionMask, u64(2))
	testing.expect(t, len(data.nodes[8].points) == 4 && !data.nodes[8].disabled)
	testing.expect(t, len(data.nodes[9].points) == 2 && data.nodes[9].disabled)

	// Built and run: the ball falls through the zone (an Area watching layer 2) and lands
	game: Game
	scene := new(Scene)
	Scene_Init(scene)
	scene.game = &game
	defer freeScene(scene)
	created := Scene_Build(scene, &data, ".")
	testing.expect(t, Node_Is(created[2], DynamicBody) && Node_Is(created[5], CharacterMover) && Node_Is(created[7], Area))
	zoneHits: Counter
	count(cast(^PhysicsBody)created[7], &zoneHits)
	run(scene, 3)
	testing.expectf(t, near(created[2].position.y, 280, 1.5), "the ball lands at %v", created[2].position.y)
	testing.expect_value(t, zoneHits.enters, 1)
	down := cast(^RayCast)created[4]
	testing.expect(t, down.colliding && down.collider == cast(^PhysicsBody)created[0])

	// Layers and points as text
	testing.expect_value(t, FormatPhysicsLayers(PhysicsLayers(1, 3, 64), context.temp_allocator), "1 3 64")
	testing.expect_value(t, FormatPhysicsLayers(PHYSICS_ALL_LAYERS, context.temp_allocator), "all")
	testing.expect_value(t, FormatPhysicsLayers(0, context.temp_allocator), "")
	layers, ok := ParsePhysicsLayers("2, 5 7")
	testing.expect(t, ok && layers == PhysicsLayers(2, 5, 7))
	_, ok = ParsePhysicsLayers("0 65")
	testing.expect(t, !ok)
	points := [][2]f32{{-1.5, 2}, {3, 4}}
	parsed, pointsOk := ParsePoints(FormatPoints(points, context.temp_allocator))
	testing.expect(t, pointsOk && len(parsed) == 2 && parsed[0] == points[0] && parsed[1] == points[1])

	project, projectErr := ParseProject(`<project formatVersion="4" name="P" pixelsPerMeter="50" gravityX="10" gravityY="500" physicsDebug="true"/>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, projectErr, ProjectError.None)
	testing.expect(t, project.physics.pixelsPerMeter == 50 && project.physics.gravity == {10, 500} && project.physics.debugDraw)
	free_all(context.temp_allocator)
}

@(test)
physics_debug_draw :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	ground := CreateStaticBody(scene)
	ground.position = {50, 50}
	box(scene, ground, {60, 20})
	ray := CreateRayCast(scene, {0, 30})
	ray.position = {10, 0}
	scene.physics.settings.debugDraw = true
	run(scene, 0.1)

	surface := sdl.CreateSurface(100, 100, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	Scene_Draw(scene, renderer)
	sdl.RenderPresent(renderer)
	pixel :: proc(surface: ^sdl.Surface, x, y: int) -> [4]u8 {
		row := ([^]u8)(surface.pixels)[y * int(surface.pitch):]
		return {row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]}
	}
	// The ground's outline (static: green) on its top edge, nothing inside it; the ray (yellow)
	testing.expectf(t, pixel(surface, 50, 40).g == 200, "outline %v", pixel(surface, 50, 40))
	testing.expect_value(t, pixel(surface, 50, 50).a, 0)
	testing.expectf(t, pixel(surface, 10, 15).r == 255, "ray %v", pixel(surface, 10, 15))
}
