#+build !js
package crossfire

import "core:math"
import "core:math/linalg"
import "core:testing"
import b2 "box2d"
import sdl "vendor:sdl3"

// Tests for smoothing, areas, per-body contacts and joints (physics_test.odin has the basics)

@(private="file")
scene2 :: proc() -> ^Scene {
	scene := new(Scene)
	Scene_Init(scene)
	return scene
}

@(private="file")
free2 :: proc(scene: ^Scene) {
	Scene_Destroy(scene)
	free(scene)
}

@(private="file")
run2 :: proc(scene: ^Scene, seconds: f64, fps: f64 = 60) {
	for _ in 0 ..< int(seconds * fps) do Scene_Update(scene, nil, 1.0 / fps)
}

@(private="file")
shape2 :: proc(scene: ^Scene, body: ^Node, kind: CollisionShapeKind, size: [2]f32, at: [2]f32 = {}) -> ^CollisionShape {
	shape := CreateCollisionShape(scene, kind)
	shape.size = size
	shape.radius = size.x * 0.5
	shape.position = at
	Node_AddChild(body, shape)
	return shape
}

@(private="file")
Events :: struct {
	enters, exits, areaEnters, areaExits: int,
	lastOther, lastArea: ^PhysicsBody,
}

@(private="file")
listen :: proc(body: ^PhysicsBody, events: ^Events) {
	body.onCollisionEnter->subscribe(proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
		e := cast(^Events)user
		e.enters += 1
		e.lastOther = Collision_FromEvent(data).other
	}, events)
	body.onCollisionExit->subscribe(proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) { (cast(^Events)user).exits += 1 }, events)
	body.onAreaEnter->subscribe(proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
		e := cast(^Events)user
		e.areaEnters += 1
		e.lastArea = Collision_FromEvent(data).other
	}, events)
	body.onAreaExit->subscribe(proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) { (cast(^Events)user).areaExits += 1 }, events)
}

@(test)
physics_smoothing :: proc(t: ^testing.T) {
	scene := scene2()
	defer free2(scene)
	Physics_SetGravity(scene, {0, 0})
	puck := CreateDynamicBody(scene)
	shape2(scene, puck, .Circle, {10, 10})
	DynamicBody_SetVelocity(puck, {120, 0})
	camera := CreateNode(scene, Camera2D)
	Node_AddChild(puck, camera)
	run2(scene, 0.5)

	// At 144 frames per second the body moves on some frames only; it's drawn moving every frame
	steps, drawnMoves := 0, 0
	lastPosition := puck.position.x
	lastDrawn := Node_GetRenderWorldTransform(puck).origin.x
	for _ in 0 ..< 144 {
		Scene_Update(scene, nil, 1.0 / 144.0)
		if puck.position.x != lastPosition do steps += 1
		drawn := Node_GetRenderWorldTransform(puck).origin.x
		testing.expect(t, drawn > lastDrawn)
		if drawn > lastDrawn do drawnMoves += 1
		// Between the last two physics poses
		testing.expect(t, drawn >= puck.previousPosition.x - 1e-3 && drawn <= puck.position.x + 1e-3)
		lastPosition, lastDrawn = puck.position.x, drawn
	}
	testing.expectf(t, steps >= 58 && steps <= 62, "%d steps in a second", steps)
	testing.expect_value(t, drawnMoves, 144)
	// The camera under it is drawn with it
	testing.expect(t, Node_GetRenderWorldTransform(camera).origin == Node_GetRenderWorldTransform(puck).origin)

	// Off: drawn where it is
	scene.physics.settings.smoothing = false
	Scene_Update(scene, nil, 1.0 / 144.0)
	testing.expect(t, Node_GetRenderWorldTransform(puck).origin == puck.position)
}

@(test)
physics_areas_for_bodies :: proc(t: ^testing.T) {
	scene := scene2()
	defer free2(scene)
	// An Area of two overlapping shapes, a ball of two shapes: still one enter and one exit each
	area := CreateArea(scene)
	area.name = "Zone"
	area.position = {0, 300}
	shape2(scene, area, .Rectangle, {200, 40})
	shape2(scene, area, .Rectangle, {200, 40}, {0, 10})
	ball := CreateDynamicBody(scene)
	ball.name = "Ball"
	shape2(scene, ball, .Circle, {20, 20})
	shape2(scene, ball, .Circle, {20, 20}, {0, -5})
	// The floor it ends on, well below the Area
	ground := CreateStaticBody(scene)
	ground.position = {0, 1500}
	shape2(scene, ground, .Rectangle, {400, 20})
	areaEvents, ballEvents: Events
	listen(area, &areaEvents)
	listen(ball, &ballEvents)

	sawInside := false
	for _ in 0 ..< 180 {
		Scene_Update(scene, nil, 1.0 / 60.0)
		if PhysicsBody_IsInArea(ball, area) {
			sawInside = true
			areas := PhysicsBody_GetAreas(ball)
			testing.expect(t, len(areas) == 1 && areas[0] == area)
			testing.expect(t, PhysicsBody_IsTouching(area, ball))
		}
	}
	testing.expect(t, sawInside)
	testing.expect_value(t, ballEvents.areaEnters, 1)
	testing.expect_value(t, ballEvents.areaExits, 1)
	testing.expect(t, ballEvents.lastArea == area)
	testing.expect_value(t, areaEvents.enters, 1)
	testing.expect_value(t, areaEvents.exits, 1)
	testing.expect_value(t, len(PhysicsBody_GetAreas(ball)), 0)

	// Landing with two shapes is one collision
	run2(scene, 1)
	testing.expect_value(t, ballEvents.enters, 1)
	testing.expect(t, PhysicsBody_IsTouching(ball, ground))

	// Removing a body ends its contacts on the other side
	groundEvents: Events
	listen(ground, &groundEvents)
	scene->removeNode(ball.id)
	run2(scene, 0.1)
	testing.expect_value(t, groundEvents.exits, 1)
	testing.expect_value(t, len(PhysicsBody_GetContacts(ground)), 0)

	// A body inside an Area that's removed leaves it
	box := CreateDynamicBody(scene)
	box.position = {500, 0}
	shape2(scene, box, .Rectangle, {20, 20})
	zone := CreateArea(scene)
	zone.position = {500, 0}
	shape2(scene, zone, .Rectangle, {100, 100})
	Physics_SetGravity(scene, {0, 0})
	boxEvents: Events
	listen(box, &boxEvents)
	run2(scene, 0.1)
	testing.expect(t, PhysicsBody_IsInArea(box, cast(^Area)zone))
	scene->removeNode(zone.id)
	run2(scene, 0.1)
	testing.expect_value(t, boxEvents.areaExits, 1)
	testing.expect_value(t, len(box.areas), 0)
	// Rebuilding shapes while inside doesn't leave stale contacts behind
	zone2 := CreateArea(scene)
	zone2.position = {500, 0}
	shape2(scene, zone2, .Rectangle, {100, 100})
	run2(scene, 0.1)
	PhysicsBody_RebuildShapes(box)
	run2(scene, 0.2)
	testing.expect_value(t, len(box.areas), 1)
	testing.expect(t, box.areas[0].count >= 1)
}

@(test)
physics_joints :: proc(t: ^testing.T) {
	scene := scene2()
	defer free2(scene)

	// A pendulum: a ball pinned to the world at (0, 0), 100 px to the right; it swings and keeps its distance
	ball := CreateDynamicBody(scene)
	ball.name = "Ball"
	ball.position = {100, 0}
	shape2(scene, ball, .Circle, {10, 10})
	pin := CreateJoint(scene, .Revolute)
	pin.bodyB = "Ball"
	run2(scene, 0.5)
	testing.expect(t, Joint_IsActive(pin))
	distance := linalg.length(ball.position)
	testing.expectf(t, abs(distance - 100) < 1, "kept %v from the pin", distance)
	testing.expectf(t, ball.position.y > 50, "swung down to %v", ball.position)
	testing.expect(t, abs(Joint_GetAngle(pin)) > 30)

	// A rope (Distance with a length limit): a block hangs 80 px under a static anchor at most
	anchor := CreateStaticBody(scene)
	anchor.name = "Anchor"
	anchor.position = {400, 0}
	shape2(scene, anchor, .Rectangle, {10, 10})
	block := CreateDynamicBody(scene)
	block.name = "Block"
	block.position = {400, 40}
	shape2(scene, block, .Rectangle, {10, 10})
	rope := CreateJoint(scene, .Distance)
	Node_AddChild(anchor, rope)
	rope.bodyB = "Block"
	rope.offset = {0, 40}
	rope.enableSpring, rope.hertz = true, 0 // slack: only the limit holds it
	rope.enableLimit, rope.lower, rope.upper = true, 0, 80
	run2(scene, 2)
	testing.expectf(t, block.position.y > 70 && block.position.y < 81.5, "hangs at %v", block.position.y)
	testing.expectf(t, abs(Joint_GetTranslation(rope) - 80) < 2, "rope length %v", Joint_GetTranslation(rope))

	// A slider along y (the joint turned 90°): x stays put while it falls, until the limit
	slider := CreateDynamicBody(scene)
	slider.name = "Slider"
	slider.position = {800, 0}
	slider.rotation = 10
	shape2(scene, slider, .Rectangle, {10, 10})
	rail := CreateJoint(scene, .Prismatic)
	rail.position = {800, 0}
	rail.rotation = 90
	rail.bodyB = "Slider"
	rail.enableLimit, rail.lower, rail.upper = true, 0, 50
	run2(scene, 1)
	testing.expectf(t, abs(slider.position.x - 800) < 0.5 && abs(slider.position.y - 50) < 1, "slid to %v", slider.position)
	testing.expectf(t, abs(slider.rotation - 10) < 0.5, "didn't turn: %v", slider.rotation)

	// Welded: two bodies fall as one
	a := CreateDynamicBody(scene)
	a.name = "WeldA"
	a.position = {1200, 0}
	shape2(scene, a, .Rectangle, {20, 20})
	b := CreateDynamicBody(scene)
	b.name = "WeldB"
	b.position = {1230, 0}
	shape2(scene, b, .Rectangle, {20, 20})
	weld := CreateJoint(scene, .Weld)
	weld.position = {1215, 0}
	weld.bodyA, weld.bodyB = "WeldA", "WeldB"
	run2(scene, 0.5)
	testing.expectf(t, abs(linalg.length(b.position - a.position) - 30) < 0.5 && abs(b.position.y - a.position.y) < 0.5, "%v %v", a.position, b.position)

	// A motor turns a wheel at its speed
	Physics_SetGravity(scene, {0, 0})
	wheel := CreateDynamicBody(scene)
	wheel.name = "Wheel"
	wheel.position = {1600, 0}
	shape2(scene, wheel, .Circle, {20, 20})
	axle := CreateJoint(scene, .Revolute)
	axle.position = {1600, 0}
	axle.bodyB = "Wheel"
	axle.enableMotor, axle.motorSpeed, axle.maxMotor = true, 180, 1e9
	run2(scene, 0.5)
	testing.expectf(t, abs(DynamicBody_GetAngularVelocity(cast(^DynamicBody)wheel) - 180) < 1, "spins at %v", DynamicBody_GetAngularVelocity(cast(^DynamicBody)wheel))
	Joint_SetMotorSpeed(axle, -90)
	run2(scene, 0.2)
	testing.expect(t, abs(DynamicBody_GetAngularVelocity(cast(^DynamicBody)wheel) + 90) < 1)

	// A wheel joint: suspension along y on a spring, free to spin
	car := CreateDynamicBody(scene)
	car.name = "Car"
	car.position = {2000, 0}
	shape2(scene, car, .Rectangle, {60, 20})
	tyre := CreateDynamicBody(scene)
	tyre.name = "Tyre"
	tyre.position = {2000, 30}
	shape2(scene, tyre, .Circle, {16, 16})
	suspension := CreateJoint(scene, .Wheel)
	Node_AddChild(car, suspension)
	suspension.position = {0, 30}
	suspension.rotation = 90
	suspension.bodyB = "Tyre"
	suspension.enableSpring, suspension.hertz = true, 4
	run2(scene, 0.1)
	testing.expect(t, Joint_IsActive(suspension) && suspension.connectedA == car)

	// Removing a body removes its joint; a missing body is reported, not retried
	scene->removeNode(ball.id)
	run2(scene, 0.05)
	testing.expect(t, !Joint_IsActive(pin))
	lost := CreateJoint(scene, .Weld)
	lost.bodyB = "Nobody"
	run2(scene, 0.05)
	testing.expect(t, lost.failed && !Joint_IsActive(lost))
	_ = math.PI
	_ = b2.Joint_IsValid
}

@(test)
physics_joint_file :: proc(t: ^testing.T) {
	text := `<scene formatVersion="4" name="J">
	<node kind="DynamicBody" name="Door" x="100" y="0"><node kind="CollisionShape" shape="Rectangle" width="10" height="60"/></node>
	<node kind="Joint" name="Hinge" x="100" y="-30" joint="Revolute" bodyB="Door" limit="true" lower="-45" upper="45"
	      motor="true" motorSpeed="30" maxMotor="1000" spring="true" hertz="2" damping="0.3" collideConnected="true" offsetX="5" offsetY="6"/>
</scene>`
	data, err := ParseScene(text)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	j := data.nodes[2]
	testing.expect(t, j.kind == .Joint && j.jointKind == .Revolute && j.bodyA == "" && j.bodyB == "Door")
	testing.expect(t, j.enableLimit && j.lower == -45 && j.upper == 45 && j.enableMotor && j.motorSpeed == 30 && j.maxMotor == 1000)
	testing.expect(t, j.enableSpring && j.hertz == 2 && j.dampingRatio == 0.3 && j.collideConnected && j.jointOffset == {5, 6})

	game: Game
	scene := scene2()
	scene.game = &game
	defer free2(scene)
	created := Scene_Build(scene, &data, ".")
	run2(scene, 0.5)
	hinge := cast(^Joint)created[2]
	testing.expect(t, Joint_IsActive(hinge) && hinge.connectedB == cast(^PhysicsBody)created[0])
	// Limited to 45° either way
	testing.expectf(t, abs(Joint_GetAngle(hinge)) <= 46, "angle %v", Joint_GetAngle(hinge))

	options, ok := Player_ParseArgs({"player", "game", "--physics-debug", "--dev"})
	testing.expect(t, ok && options.physicsDebug && options.dev)

	// Developer keys: F9 toggles the shapes, only with devKeys
	g: Game
	g.physics = DEFAULT_PHYSICS
	g.scenes = make(map[string]^Scene)
	defer delete(g.scenes)
	g.update = Game_Update
	press := sdl.Event{key = {type = .KEY_DOWN, scancode = .F9}}
	Game_Update(&g, {press}, 0)
	testing.expect(t, !g.physics.debugDraw)
	g.devKeys = true
	Game_Update(&g, {press}, 0)
	testing.expect(t, g.physics.debugDraw)
	Game_Update(&g, {press}, 0)
	testing.expect(t, !g.physics.debugDraw)
	project, _ := ParseProject(`<project formatVersion="4" name="P" physicsSmoothing="false"/>`)
	defer ProjectData_Destroy(&project)
	testing.expect(t, !project.physics.smoothing)
}
