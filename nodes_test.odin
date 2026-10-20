#+build !js
package crossfire

import "core:testing"
import sdl "vendor:sdl3"

// Per-node features: process modes and pausing, the game's time scale, groups, z-index and
// y-sort draw order, blend modes, and their scene-file attributes (format 13).

@(test)
pausing_follows_process_modes :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	Counted :: struct { using node: Node, updates: int }
	count :: proc(node: ^Node, _: []sdl.Event, _: f64) { (cast(^Counted)node).updates += 1 }
	make_ :: proc(scene: ^Scene, mode: ProcessMode, parent: ^Node = nil) -> ^Counted {
		n := CreateNode(scene, Counted)
		n.processMode = mode
		n.update = count
		if parent != nil do Node_AddChild(parent, n)
		return n
	}
	gameplay := make_(scene, .Inherit)
	child := make_(scene, .Inherit, gameplay)
	menu := make_(scene, .WhenPaused)
	menuItem := make_(scene, .Inherit, menu)
	always := make_(scene, .Always)
	disabled := make_(scene, .Disabled)

	Scene_Update(scene, nil, 1.0 / 60)
	testing.expect(t, gameplay.updates == 1 && child.updates == 1 && menu.updates == 0 && menuItem.updates == 0 && always.updates == 1 && disabled.updates == 0, "running")
	Scene_SetPaused(scene, true)
	Scene_Update(scene, nil, 1.0 / 60)
	testing.expect(t, gameplay.updates == 1 && child.updates == 1, "gameplay stopped")
	testing.expect(t, menu.updates == 1 && menuItem.updates == 1, "the menu (and what inherits from it) runs")
	testing.expect(t, always.updates == 2 && disabled.updates == 0, "always / never")
	testing.expect(t, Node_CanProcess(menuItem) && !Node_CanProcess(child), "CanProcess agrees")

	// Physics doesn't step while paused
	body := CreateDynamicBody(scene)
	shape := CreateCollisionShape(scene, .Circle)
	shape.radius = 5
	Node_AddChild(body, shape)
	Scene_Update(scene, nil, 1.0 / 60)
	for _ in 0 ..< 30 do Scene_Update(scene, nil, 1.0 / 60)
	testing.expect_value(t, body.position, [2]f32{0, 0})
	Scene_SetPaused(scene, false)
	for _ in 0 ..< 30 do Scene_Update(scene, nil, 1.0 / 60)
	testing.expect(t, body.position.y > 0, "falls once resumed")
	free_all(context.temp_allocator)
}

@(test)
time_scale_slows_scenes_not_hitstops :: proc(t: ^testing.T) {
	game: Game
	game.scenes = make(map[string]^Scene)
	defer delete(game.scenes)
	scene := new(Scene)
	Scene_Init(scene)
	scene.game = &game
	game.currentScene = scene
	defer { Scene_Destroy(scene); free(scene) }
	clock := CreateNode(scene, Node)
	clock.update = proc(node: ^Node, _: []sdl.Event, deltaTime: f64) { node.position.x += f32(deltaTime) }

	Game_Update(&game, nil, 0.1) // zero: normal speed
	testing.expect_value(t, clock.position.x, f32(0.1))
	Game_SetTimeScale(&game, 0.5)
	Game_Update(&game, nil, 0.1)
	testing.expect(t, abs(clock.position.x - 0.15) < 1e-6, "half speed")
	// A hitstop lasts its real time whatever the scale
	Game_HitStop(&game, 0.15)
	Game_Update(&game, nil, 0.1)
	Game_Update(&game, nil, 0.1)
	Game_Update(&game, nil, 0.1)
	testing.expect(t, abs(clock.position.x - 0.2) < 1e-6, "frozen for 0.15 s of real time, then half speed")
	free_all(context.temp_allocator)
}

@(test)
groups_name_sets_of_nodes :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	a := CreateNode(scene, Node)
	b := CreateNode(scene, Node)
	Node_AddToGroup(a, "enemies")
	Node_AddToGroup(a, "enemies") // once
	Node_AddToGroup(b, "enemies")
	Node_AddToGroup(b, "flying")
	testing.expect_value(t, len(a.groups), 1)
	testing.expect_value(t, len(Scene_GetGroup(scene, "enemies")), 2) // queued nodes too
	Scene_ProcessQueues(scene)
	flying := Scene_GetGroup(scene, "flying")
	testing.expect(t, len(flying) == 1 && flying[0] == b, "one flyer")
	Node_RemoveFromGroup(b, "enemies")
	testing.expect(t, !Node_IsInGroup(b, "enemies") && Node_IsInGroup(b, "flying"), "left one group")
	testing.expect_value(t, len(Scene_GetGroup(scene, "nobody")), 0)
	free_all(context.temp_allocator)
}

@(test)
z_index_y_sort_and_blend_modes_order_drawing :: proc(t: ^testing.T) {
	@(static) order: [dynamic]string
	@(static) blends: [dynamic]sdl.BlendMode
	order = make([dynamic]string, context.temp_allocator)
	blends = make([dynamic]sdl.BlendMode, context.temp_allocator)
	record :: proc(node: ^Node, _: ^sdl.Renderer) {
		append(&order, node.name)
		append(&blends, GetDrawBlend())
	}
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	drawer :: proc(scene: ^Scene, name: string, z: i32 = 0, y: f32 = 0, parent: ^Node = nil) -> ^Node {
		n := CreateNode(scene, Node)
		n.name, n.zIndex, n.position.y, n.draw = name, z, y, record
		if parent != nil do Node_AddChild(parent, n)
		return n
	}
	drawer(scene, "front", z = 5)
	back := drawer(scene, "back", z = -1)
	back.blendMode = .Add
	drawer(scene, "middle")
	// A y-sorted group: its children by their y, the group itself first (it draws, at y 0)
	ground := drawer(scene, "ground")
	ground.ySort = true
	drawer(scene, "low", y = 90, parent = ground)
	drawer(scene, "high", y = 10, parent = ground)
	drawer(scene, "mid", y = 50, parent = ground)
	Scene_ProcessQueues(scene)
	Scene_DrawWithView(scene, nil, TRANSFORM2D_IDENTITY)
	want := []string{"back", "middle", "ground", "high", "mid", "low", "front"}
	ok := len(order) == len(want)
	if ok do for name, i in want do if order[i] != name do ok = false
	testing.expectf(t, ok, "draw order %v", order[:])
	testing.expect(t, len(blends) > 1 && blends[0] == sdl.BLENDMODE_ADD && blends[1] == sdl.BLENDMODE_BLEND, "each node's blend mode")
	free_all(context.temp_allocator)
}

@(test)
scene_files_carry_node_settings :: proc(t: ^testing.T) {
	text := `<scene formatVersion="13" name="S">
	<node kind="Node2D" name="Menu" processMode="WhenPaused" blendMode="Add" zIndex="3" ySort="true" groups="ui, overlay"/>
	<node kind="Node2D" name="Plain"/>
</scene>`
	data, err := ParseScene(text)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	if len(data.nodes) != 2 do return
	menu := data.nodes[0]
	testing.expect(t, menu.processMode == .WhenPaused && menu.blendMode == .Add && menu.zIndex == 3 && menu.ySort, "parsed")
	testing.expect(t, len(menu.groups) == 2 && menu.groups[0] == "ui" && menu.groups[1] == "overlay", "groups, trimmed")
	plain := data.nodes[1]
	testing.expect(t, plain.processMode == .Inherit && plain.blendMode == .Blend && plain.zIndex == 0 && !plain.ySort && len(plain.groups) == 0, "defaults")

	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	built := Scene_Build(scene, &data, ".")
	n := built[0]
	testing.expect(t, n.processMode == .WhenPaused && n.blendMode == .Add && n.zIndex == 3 && n.ySort && Node_IsInGroup(n, "overlay"), "built")
	free_all(context.temp_allocator)
}

@(test)
projects_carry_window_settings :: proc(t: ^testing.T) {
	plain, err := ParseProject(`<project formatVersion="12" name="P"/>`)
	defer ProjectData_Destroy(&plain)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, plain.window, DEFAULT_WINDOW_SETTINGS) // windowed, vsync, not high-DPI
	set, _ := ParseProject(`<project formatVersion="13" name="P" fullscreen="true" vsync="false" highDPI="true" icon="assets/icon.png"/>`)
	defer ProjectData_Destroy(&set)
	testing.expect_value(t, set.window, WindowSettings{fullscreen = true, vsync = false, highDPI = true})
	testing.expect(t, set.icon == "assets/icon.png" && plain.icon == "", "the window icon")
	// No window: the runtime switches say so instead of crashing
	game: Game
	testing.expect(t, !Game_SetFullscreen(&game, true) && !Game_IsFullscreen(&game), "no window")
	Game_SetVSync(&game, false)
	testing.expect(t, !Game_SetWindowIcon(&game, "assets/icon.png"), "no window, no icon")
}
