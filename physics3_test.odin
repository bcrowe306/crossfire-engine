#+build !js
package crossfire

import "core:slice"
import "core:testing"
import sdl "vendor:sdl3"

// Tests for physics queries and one-way platforms

@(private="file")
scene3 :: proc() -> ^Scene {
	scene := new(Scene)
	Scene_Init(scene)
	return scene
}

@(private="file")
free3 :: proc(scene: ^Scene) {
	Scene_Destroy(scene)
	free(scene)
}

@(private="file")
run3 :: proc(scene: ^Scene, seconds: f64) {
	for _ in 0 ..< int(seconds * 60) do Scene_Update(scene, nil, 1.0 / 60)
}

@(private="file")
rect3 :: proc(scene: ^Scene, body: ^Node, size: [2]f32) -> ^CollisionShape {
	shape := CreateCollisionShape(scene, .Rectangle)
	shape.size = size
	Node_AddChild(body, shape)
	return shape
}

@(private="file")
staticAt :: proc(scene: ^Scene, name: string, position, size: [2]f32, layer: u64 = 1) -> ^StaticBody {
	body := CreateStaticBody(scene)
	body.name = name
	body.position = position
	body.collisionLayer = layer
	rect3(scene, body, size)
	return body
}

@(private="file")
has :: proc(bodies: []^PhysicsBody, body: ^PhysicsBody) -> bool {
	return slice.contains(bodies, body)
}

@(test)
physics_queries :: proc(t: ^testing.T) {
	scene := scene3()
	defer free3(scene)
	a := staticAt(scene, "A", {0, 0}, {100, 100})
	b := staticAt(scene, "B", {200, 0}, {100, 100}, layer = 2)
	area := CreateArea(scene)
	area.position = {0, 0}
	rect3(scene, area, {40, 40})
	run3(scene, 1.0 / 60)

	found := Physics_QueryPoint(scene, {10, 10})
	testing.expectf(t, len(found) == 1 && found[0] == a, "the point is in A only (no Area by default): %v", len(found))
	found = Physics_QueryPoint(scene, {10, 10}, includeAreas = true)
	testing.expect(t, len(found) == 2 && has(found, a) && has(found, area), "with Areas")
	testing.expect(t, len(Physics_QueryPoint(scene, {120, 0})) == 0, "nothing between them")

	found = Physics_QueryRect(scene, {0, -10, 200, 20})
	testing.expect(t, len(found) == 2 && has(found, a) && has(found, b), "a rect over both")
	found = Physics_QueryRect(scene, {0, -10, 200, 20}, mask = 2)
	testing.expect(t, len(found) == 1 && found[0] == b, "the mask picks layer 2")

	found = Physics_QueryCircle(scene, {125, 0}, 30)
	testing.expect(t, len(found) == 1 && found[0] == b, "a circle reaching B's left side (at 150)")
	testing.expect(t, len(Physics_QueryCircle(scene, {100, 0}, 10)) == 0, "a circle between them")

	hit := Physics_ShapeCast(scene, 10, {100, 0}, {100, 0} + {200, 0})
	testing.expectf(t, hit.hit && hit.body == b, "the sweep hits B: %v", hit)
	// The circle's edge reaches B's left side (150) when its center is at 140: 40 of 200
	testing.expectf(t, abs(hit.fraction - 0.2) < 0.01, "fraction %v", hit.fraction)
	testing.expectf(t, abs(hit.normal.x + 1) < 0.01, "normal %v", hit.normal)
	miss := Physics_ShapeCast(scene, 10, {100, 0}, {100, 0} + {200, 0}, exclude = b)
	testing.expect(t, !miss.hit, "B excluded")
	// Started inside A: A doesn't count
	inside := Physics_ShapeCast(scene, 10, {0, 0}, {0, 300})
	testing.expect(t, !inside.hit, "shapes it starts in are ignored")
}

@(private="file")
moverIn :: proc(scene: ^Scene, position: [2]f32) -> ^CharacterMover {
	mover := CreateCharacterMover(scene)
	mover.position = position
	capsule := CreateCollisionShape(scene, .Capsule)
	capsule.radius = 10
	capsule.height = 40
	Node_AddChild(mover, capsule)
	mover.update = proc(node: ^Node, _: []sdl.Event, dt: f64) {
		m := cast(^CharacterMover)node
		m.velocity.y += 980 * f32(dt)
		CharacterMover_Move(m, dt)
	}
	return mover
}

@(test)
physics_one_way_mover :: proc(t: ^testing.T) {
	scene := scene3()
	defer free3(scene)
	staticAt(scene, "Ground", {0, 400}, {1000, 20})
	platform := staticAt(scene, "Platform", {0, 200}, {200, 10})
	(cast(^CollisionShape)platform.children[0]).oneWay = true

	// Below the platform, jumping: through it on the way up, onto it on the way down
	mover := moverIn(scene, {0, 260})
	mover.velocity.y = -700
	run3(scene, 0.25)
	testing.expectf(t, mover.position.y < 175, "went up through it: %v", mover.position.y)
	run3(scene, 1.5)
	testing.expect(t, mover.onFloor, "landed")
	// The platform's top is 195; the capsule's bottom is 20 below its middle
	testing.expectf(t, abs(mover.position.y - 175) < 1.5, "on the platform: %v", mover.position.y)

	mover.dropThrough = true
	run3(scene, 1)
	testing.expectf(t, abs(mover.position.y - 370) < 1.5, "dropped through to the ground: %v", mover.position.y)
	testing.expect(t, mover.onFloor)

	// A mover walking at its height from the side passes through its edge
	side := moverIn(scene, {-200, 200})
	side.update = proc(node: ^Node, _: []sdl.Event, dt: f64) {
		m := cast(^CharacterMover)node
		m.velocity = {300, 0}
		CharacterMover_Move(m, dt)
	}
	run3(scene, 0.6)
	// 180 px in 0.6 s: unstopped by the platform's edge at -100
	testing.expectf(t, abs(side.position.x + 20) < 1, "passed into it from the side: %v", side.position.x)
}

@(test)
physics_one_way_dynamic :: proc(t: ^testing.T) {
	scene := scene3()
	defer free3(scene)
	staticAt(scene, "Ground", {0, 400}, {1000, 20})
	platform := staticAt(scene, "Platform", {0, 200}, {200, 10})
	(cast(^CollisionShape)platform.children[0]).oneWay = true

	falling := CreateDynamicBody(scene)
	falling.position = {-50, 100}
	rect3(scene, falling, {20, 20})
	rising := CreateDynamicBody(scene)
	rising.position = {50, 300}
	rect3(scene, rising, {20, 20})
	run3(scene, 1.0 / 60)
	DynamicBody_SetVelocity(rising, {0, -800})
	run3(scene, 2)

	// The platform's top is 195: a 20 px box rests at 185
	testing.expectf(t, abs(falling.position.y - 185) < 1.5, "the falling box landed on it: %v", falling.position.y)
	testing.expectf(t, abs(rising.position.y - 185) < 1.5, "the rising box went through and landed on top: %v", rising.position.y)
}

@(test)
scene_files_carry_one_way_shapes :: proc(t: ^testing.T) {
	text := `<scene formatVersion="13" name="S">
	<node kind="StaticBody" name="Platform">
		<node kind="CollisionShape" name="Top" shape="Rectangle" width="200" height="10" oneWay="true"/>
		<node kind="CollisionShape" name="Solid" shape="Rectangle" width="20" height="20"/>
	</node>
</scene>`
	data, err := ParseScene(text)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	if len(data.nodes) != 3 do return
	testing.expect(t, data.nodes[1].oneWay && !data.nodes[2].oneWay, "parsed")
	scene := scene3()
	defer free3(scene)
	built := Scene_Build(scene, &data, ".")
	testing.expect(t, (cast(^CollisionShape)built[1]).oneWay && !(cast(^CollisionShape)built[2]).oneWay, "built")
	free_all(context.temp_allocator)
}
