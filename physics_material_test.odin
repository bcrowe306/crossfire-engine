#+build !js
package crossfire

import "core:os"
import "core:testing"
import b2 "box2d"

// Physics materials (physics_material.odin) and traced collision in a real Box2D world

@(test)
physics_materials_round_trip_and_apply :: proc(t: ^testing.T) {
	m, err := ParsePhysicsMaterial(`<material formatVersion="13" friction="0.05" restitution="0.8"/>`)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect(t, m == PhysicsMaterial{friction = 0.05, restitution = 0.8, density = 1}, "read, density defaulted")
	back, _ := ParsePhysicsMaterial(FormatPhysicsMaterial(m, context.temp_allocator))
	testing.expect(t, back == m, "written and read back")
	_, bad := ParsePhysicsMaterial(`<theme/>`)
	testing.expect_value(t, bad, ProjectError.Invalid_XML)

	// A scene's body names a material file: it replaces the body's own values
	dir := "testdata_material"
	os.make_directory(dir)
	defer os.remove_all(dir)
	_ = os.write_entire_file("testdata_material/ice.material.xml", transmute([]byte)string(`<material friction="0.02" restitution="0.1" density="0.5"/>`))
	game := testGame(dir)
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	data, perr := ParseScene(`<scene formatVersion="13" name="S">
		<node kind="DynamicBody" name="Puck" friction="0.9" material="ice.material.xml">
			<node kind="CollisionShape" name="Shape" shape="Circle" radius="10"/>
		</node>
		<node kind="StaticBody" name="Plain" friction="0.9"/>
	</scene>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, perr, ProjectError.None)
	testing.expect_value(t, data.nodes[0].material, "ice.material.xml")
	created := Scene_Build(scene, &data, dir, attachScripts = false)
	puck := cast(^PhysicsBody)created[0]
	testing.expect(t, puck.friction == 0.02 && puck.restitution == 0.1 && puck.density == 0.5, "the material's values")
	testing.expect_value(t, (cast(^PhysicsBody)created[2]).friction, f32(0.9))

	// Changed at run time: the Box2D shapes follow
	Scene_Update(scene, nil, 1.0 / 60)
	PhysicsBody_SetMaterial(puck, {friction = 0.7, restitution = 0.3, density = 2})
	shapes := b2.Body_GetShapes(puck.bodyId, make([]b2.ShapeId, 1, context.temp_allocator))
	testing.expect(t, len(shapes) == 1 && b2.Shape_GetFriction(shapes[0]) == 0.7 && b2.Shape_GetRestitution(shapes[0]) == 0.3, "the shape's surface")
}

@(test)
traced_ground_holds_a_falling_crate :: proc(t: ^testing.T) {
	// Ground from an image: a bowl (a floor with walls: concave, so several pieces)
	w, h := 80, 40
	pixels := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h do for x in 0 ..< w {
		if y >= h - 10 || x < 6 || x >= w - 6 do pixels[(y * w + x) * 4 + 3] = 255
	}
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	ground := CreateStaticBody(scene)
	ground.position = {0, 200}
	for piece in Image_CollisionPolygons(pixels, w, h, offset = {-f32(w) / 2, -f32(h) / 2}) {
		shape := CreateCollisionShape(scene, .Polygon)
		append(&shape.points, ..piece)
		Node_AddChild(ground, shape)
	}
	testing.expect(t, len(ground.children) > 0, "pieces")
	crate := CreateDynamicBody(scene)
	crate.position = {5, 100}
	shape := CreateCollisionShape(scene, .Rectangle)
	shape.size = {8, 8}
	Node_AddChild(crate, shape)
	for _ in 0 ..< 180 do Scene_Update(scene, nil, 1.0 / 60.0)
	testing.expect(t, len(ground.children) >= 2, "a bowl needs several pieces")
	// Resting on the bowl's floor (its top at 200 + 20 - 10 = 210; the crate's middle 4 above)
	testing.expectf(t, abs(crate.position.y - 206) < 1.5 && abs(crate.position.x) < 34, "resting on the floor: %v", crate.position)
}
