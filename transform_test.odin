#+build !js
package engine

import "core:testing"
import sdl "vendor:sdl3"

// Tests for transforms, node hierarchy and the camera node. Run with: odin test .

@(private="file")
near :: proc(a, b: [2]f32, eps: f32 = 0.001) -> bool {
	return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
}

// Test node with a tag and a counter for destroy callbacks
@(private="file")
TestNode :: struct {
	using node: Node,
	tag: int,
	destroyed: ^int,
}

@(private="file")
newScene :: proc() -> ^Scene {
	scene := new(Scene)
	Scene_Init(scene)
	return scene
}

@(private="file")
freeScene :: proc(scene: ^Scene) {
	Scene_Destroy(scene)
	free(scene)
}

@(test)
transform_math :: proc(t: ^testing.T) {
	m := Transform2D_Make({100, 50}, 90, {2, 2})
	testing.expect(t, near(Transform2D_Apply(m, {1, 0}), {100, 52}), "90° clockwise turns +X toward +Y (down)")
	testing.expect(t, near(Transform2D_Apply(m, {0, 1}), {98, 50}), "+Y turns toward -X")

	inv := Transform2D_Inverse(m)
	p := [2]f32{-7, 13}
	testing.expect(t, near(Transform2D_Apply(inv, Transform2D_Apply(m, p)), p), "inverse undoes")

	a := Transform2D_Make({10, 0}, 30, {1, 3})
	b := Transform2D_Make({0, 5}, -45, {2, 1})
	ab := Transform2D_Multiply(a, b)
	testing.expect(t, near(Transform2D_Apply(ab, p), Transform2D_Apply(a, Transform2D_Apply(b, p))), "multiply applies b then a")

	testing.expect(t, abs(Transform2D_Rotation(Transform2D_Make({}, 37, {1, 1})) - 37) < 0.001, "rotation reads back")
	testing.expect(t, near(Transform2D_Scale(Transform2D_Make({}, 20, {2, 5})), {2, 5}), "scale reads back")
}

@(test)
world_transforms_follow_parents :: proc(t: ^testing.T) {
	scene := newScene()
	defer freeScene(scene)

	parent := CreateNode(scene, Node)
	child := CreateNode(scene, Node)
	grandchild := CreateNode(scene, Node)
	testing.expect_value(t, child.scale, [2]f32{1, 1}) // Defaults from Node_Init
	testing.expect_value(t, child.visible, true)
	Node_AddChild(parent, child)
	Node_AddChild(child, grandchild)

	parent.position = {100, 100}
	parent.rotation = 90
	parent.scale = {2, 2}
	child.position = {10, 0}
	grandchild.position = {5, 0}

	// Child: 10 along the parent's X axis, which points down and is doubled
	testing.expect(t, near(Node_GetWorldPosition(child), {100, 120}), "child follows parent rotation and scale")
	testing.expect(t, near(Node_GetWorldPosition(grandchild), {100, 130}), "grandchild composes both")

	parent.position = {0, 0}
	testing.expect(t, near(Node_GetWorldPosition(grandchild), {0, 30}), "moving the parent moves descendants")

	Node_SetWorldPosition(grandchild, {50, 50})
	testing.expect(t, near(Node_GetWorldPosition(grandchild), {50, 50}), "set world position through parents")
}

@(test)
reparenting :: proc(t: ^testing.T) {
	scene := newScene()
	defer freeScene(scene)

	a := CreateNode(scene, Node)
	b := CreateNode(scene, Node)
	child := CreateNode(scene, Node)
	a.position = {100, 0}
	b.position = {0, 200}
	b.rotation = 90
	Node_AddChild(a, child)
	child.position = {10, 0}
	before := Node_GetWorldPosition(child)

	testing.expect(t, Node_SetParent(child, b, keepWorld = true), "reparent")
	testing.expect_value(t, len(a.children), 0)
	testing.expect_value(t, len(b.children), 1)
	testing.expect(t, near(Node_GetWorldPosition(child), before), "keepWorld keeps the world position")
	testing.expect(t, abs(Node_GetWorldTransform(child).x.x - 1) < 0.001, "keepWorld keeps the world rotation")

	Node_SetParent(child, a)
	testing.expect(t, !near(Node_GetWorldPosition(child), before), "without keepWorld the node moves with its new parent")

	testing.expect(t, !Node_SetParent(a, child), "a node can't become its own descendant's child")
	testing.expect_value(t, a.parent, (^Node)(nil))
}

@(test)
removing_a_node_removes_its_subtree :: proc(t: ^testing.T) {
	scene := newScene()
	defer freeScene(scene)

	destroyed := 0
	onDestroy :: proc(node: ^Node) { (cast(^TestNode)node).destroyed^ += 1 }
	make_node :: proc(scene: ^Scene, counter: ^int) -> ^TestNode {
		n := CreateNode(scene, TestNode)
		n.destroyed = counter
		n.destroy = onDestroy
		return n
	}
	root := make_node(scene, &destroyed)
	child := make_node(scene, &destroyed)
	grandchild := make_node(scene, &destroyed)
	other := make_node(scene, &destroyed)
	Node_AddChild(root, child)
	Node_AddChild(child, grandchild)
	Scene_ProcessQueues(scene)
	testing.expect_value(t, len(scene.nodes), 4)

	scene->removeNode(child.id)
	Scene_ProcessQueues(scene)
	testing.expect_value(t, destroyed, 2) // child and grandchild
	testing.expect_value(t, len(scene.nodes), 2)
	testing.expect_value(t, len(root.children), 0)
	_ = other
}

// Records what each node saw while drawing
@(private="file")
DrawRecord :: struct {
	name: int,
	origin: [2]f32,
	tint: sdl.Color,
}
@(private="file")
drawLog: [dynamic]DrawRecord

@(test)
drawing_uses_tree_order_transforms_tint_and_visibility :: proc(t: ^testing.T) {
	scene := newScene()
	defer freeScene(scene)
	defer delete(drawLog)
	clear(&drawLog)

	record :: proc(node: ^Node, renderer: ^sdl.Renderer) {
		append(&drawLog, DrawRecord{(cast(^TestNode)node).tag, GetDrawTransform().origin, drawTint})
	}
	make_node :: proc(scene: ^Scene, tag: int, layer: RenderLayer = .Layer1) -> ^TestNode {
		n := CreateNode(scene, TestNode)
		n.tag = tag
		n.draw = record
		n.layer = layer
		return n
	}
	a := make_node(scene, 1)
	make_node(scene, 2)
	aChild := make_node(scene, 3)
	hidden := make_node(scene, 4)
	hiddenChild := make_node(scene, 5)
	make_node(scene, 6, .Layer2)
	Node_AddChild(a, aChild)
	Node_AddChild(a, hidden)
	Node_AddChild(hidden, hiddenChild)
	a.position = {10, 20}
	a.tint = {255, 0, 255, 255}
	aChild.position = {1, 1}
	hidden.visible = false
	Scene_ProcessQueues(scene)

	Scene_Draw(scene, nil)
	tags := make([dynamic]int, context.temp_allocator)
	for r in drawLog do append(&tags, r.name)
	// Layer1 in tree order (a, its child, then b; hidden subtree skipped), then Layer2
	testing.expect_value(t, len(tags), 4)
	if len(tags) == 4 {
		testing.expect_value(t, tags[0], 1)
		testing.expect_value(t, tags[1], 3)
		testing.expect_value(t, tags[2], 2)
		testing.expect_value(t, tags[3], 6)
		testing.expect(t, near(drawLog[1].origin, {11, 21}), "child draws at its world position")
		testing.expect_value(t, drawLog[1].tint, sdl.Color{255, 0, 255, 255}) // Inherited tint
		testing.expect_value(t, drawLog[2].tint, sdl.Color{255, 255, 255, 255})
	}
	testing.expect_value(t, GetDrawTransform(), TRANSFORM2D_IDENTITY) // Reset after drawing
}

@(test)
camera_is_a_node :: proc(t: ^testing.T) {
	scene := newScene()
	defer freeScene(scene)

	camera := Scene_CreateCamera(scene)
	camera.offset = {640, 360}
	camera.position = {100, 100}
	testing.expect(t, near(Camera2D_WorldToScreen(camera, {100, 100}), {640, 360}), "target at offset")

	camera.zoom = 2
	testing.expect(t, near(Camera2D_WorldToScreen(camera, {110, 100}), {660, 360}), "zoom")
	camera.zoom = 1

	// Rotating the camera clockwise turns the world counter-clockwise on screen
	camera.rotation = 90
	testing.expect(t, near(Camera2D_WorldToScreen(camera, {200, 100}), {640, 260}), "camera rotation")
	w := [2]f32{321, -45}
	testing.expect(t, near(Camera2D_ScreenToWorld(camera, Camera2D_WorldToScreen(camera, w)), w, 0.01), "round trip")
	camera.rotation = 0

	// A camera parented to a moving node follows it
	player := CreateNode(scene, Node)
	player.position = {500, 500}
	attached := Scene_CreateCamera(scene, parent = player)
	attached.offset = {640, 360}
	testing.expect_value(t, scene.camera, attached)
	player.position = {900, 50}
	testing.expect(t, near(Camera2D_GetTarget(attached), {900, 50}), "parented camera follows its parent")
	testing.expect(t, near(Scene_WorldToScreen(scene, {900, 50}), {640, 360}), "scene uses the new camera")

	// Follow and bounds move the camera node
	Scene_SetCamera(scene, camera)
	camera.follow.mode = .Snap
	Camera2D_Follow(camera, {1000, 1000}, 1.0 / 60)
	testing.expect(t, near(camera.position, {1000, 1000}), "follow moves the node")
	Camera2D_SetBounds(camera, {0, 0}, {1280, 720})
	Camera2D_Update(camera, {1280, 720}, 1.0 / 60)
	testing.expect(t, near(camera.position, {640, 360}), "bounds clamp the node")
}

@(test)
scene_format_v1_is_migrated :: proc(t: ^testing.T) {
	text := `<scene formatVersion="1" name="Old">
	<node kind="Node2D" name="Group" x="100" y="100">
		<node kind="Sprite" name="Ship" x="150" y="130"/>
		<node kind="Camera" name="Camera" x="100" y="100" rotation="30"/>
	</node>
</scene>`
	scene, err := ParseScene(text)
	defer SceneData_Destroy(&scene)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect(t, near(scene.nodes[1].position, {50, 30}), "world position becomes local")
	testing.expect(t, abs(scene.nodes[2].rotation + 30) < 0.001, "camera rotation is negated")
	testing.expect(t, near(scene.nodes[0].position, {100, 100}), "top-level positions don't change")
}

// A negative scale mirrors textures (a sprite facing left), not turns them upside down
@(test)
negative_scale_mirrors_textures :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(40, 40, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	// 2 x 2: red, blue on top; green, yellow below
	source := sdl.CreateSurface(2, 2, .RGBA32)
	defer sdl.DestroySurface(source)
	colors := [4][4]u8{{255, 0, 0, 255}, {0, 0, 255, 255}, {0, 255, 0, 255}, {255, 255, 0, 255}}
	for c, i in colors {
		row := ([^]u8)(source.pixels)[(i / 2) * int(source.pitch):]
		for k in 0 ..< 4 do row[(i % 2) * 4 + k] = c[k]
	}
	texture := sdl.CreateTextureFromSurface(renderer, source)
	defer sdl.DestroyTexture(texture)
	sdl.SetTextureScaleMode(texture, .NEAREST)
	pixel :: proc(surface: ^sdl.Surface, x, y: int) -> [4]u8 {
		row := ([^]u8)(surface.pixels)[y * int(surface.pitch):]
		return {row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]}
	}
	draw :: proc(renderer: ^sdl.Renderer, texture: ^sdl.Texture, transform: Transform2D) {
		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
		sdl.RenderClear(renderer)
		SetDrawState(transform)
		DrawTexture(renderer, texture, {-10, -10, 20, 20})
		SetDrawState(TRANSFORM2D_IDENTITY)
		sdl.RenderPresent(renderer)
	}
	// Facing right: red top-left
	draw(renderer, texture, Transform2D{x = {1, 0}, y = {0, 1}, origin = {20, 20}})
	testing.expect_value(t, pixel(surface, 15, 15), colors[0])
	// scale.x -1: mirrored, blue top-left, yellow bottom-left (not turned: yellow would be top-left)
	draw(renderer, texture, Transform2D{x = {-1, 0}, y = {0, 1}, origin = {20, 20}})
	testing.expect_value(t, pixel(surface, 15, 15), colors[1])
	testing.expect_value(t, pixel(surface, 15, 25), colors[3])
	// scale.y -1: upside down, green top-left
	draw(renderer, texture, Transform2D{x = {1, 0}, y = {0, -1}, origin = {20, 20}})
	testing.expect_value(t, pixel(surface, 15, 15), colors[2])
}

// A hitstop gives scenes 0 seconds for its length (in real time); a camera shake moves only the
// view, settles in its duration, keeps going through a hitstop, and a weaker shake doesn't cut a stronger one
@(test)
hitstop_and_camera_shake :: proc(t: ^testing.T) {
	game: Game
	game.scenes = make(map[string]^Scene)
	defer delete(game.scenes)
	scene := new(Scene)
	Scene_Init(scene)
	scene.game = &game
	game.size = {320, 180}
	game.currentScene = scene
	defer { Scene_Destroy(scene); free(scene) }
	ticker := CreateNode(scene, Node)
	ticker.update = proc(node: ^Node, _: []sdl.Event, deltaTime: f64) { node.position.x += f32(deltaTime) }
	camera := Scene_CreateCamera(scene)
	camera.zoom = 2
	Game_Update(&game, nil, 0.1)
	testing.expect_value(t, ticker.position.x, f32(0.1))

	Game_HitStop(&game, 0.25)
	Game_HitStop(&game, 0.1) // shorter: doesn't cut it
	Camera2D_Shake(camera, 4, 0.5)
	before := Camera2D_GetTarget(camera)
	for _ in 0 ..< 2 do Game_Update(&game, nil, 0.1)
	testing.expect_value(t, ticker.position.x, f32(0.1)) // frozen
	testing.expect(t, camera.shake.left < 0.31 && camera.shake.left > 0.29, "the shake goes on in real time")
	offset := camera.shake.offset
	testing.expect(t, offset != {} && abs(offset.x) <= 4 && abs(offset.y) <= 4, "shaken, within its strength")
	testing.expect_value(t, Camera2D_GetTarget(camera), before) // the node doesn't move
	view := Camera2D_ViewTransform(camera)
	testing.expect_value(t, Transform2D_Apply(view, before), camera.offset + offset)
	Camera2D_Shake(camera, 1, 0.5) // weaker than what's left
	testing.expect(t, camera.shake.strength == 4, "a weaker shake is ignored")

	Game_Update(&game, nil, 0.1) // the hitstop's last 0.05 s, then it's over
	Game_Update(&game, nil, 0.1)
	testing.expect_value(t, ticker.position.x, f32(0.2))
	for _ in 0 ..< 4 do Game_Update(&game, nil, 0.1)
	testing.expect_value(t, camera.shake.offset, [2]f32{})
	free_all(context.temp_allocator)
}
