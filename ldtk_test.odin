#+build !js
package engine

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

// LDtk tests: a small hand-written project (no tileset images, so nothing needs a renderer), one
// level in the file and one saved apart, read, then built into a scene

@(private="file")
PROJECT :: `{
	"jsonVersion": "1.5.3", "bgColor": "#40465B", "externalLevels": true, "worldLayout": "LinearHorizontal",
	"worldGridWidth": 256, "worldGridHeight": 256, "worlds": [],
	"defs": {
		"layers": [
			{"__type": "Entities", "identifier": "Things", "uid": 1, "gridSize": 16, "parallaxFactorX": 0.5, "parallaxFactorY": 0, "parallaxScaling": false, "intGridValues": []},
			{"__type": "IntGrid", "identifier": "Walls", "uid": 2, "gridSize": 16, "parallaxFactorX": 0.5, "parallaxFactorY": 0, "parallaxScaling": false,
			 "intGridValues": [{"value": 1, "identifier": "stone", "color": "#808080"}, {"value": 2, "identifier": "ladder", "color": "#A06020"}]}
		],
		"entities": [{"identifier": "Coin", "uid": 10, "width": 8, "height": 8, "pivotX": 0.5, "pivotY": 0.5, "color": "#FFD700", "tags": ["pickup"],
			"renderMode": "Ellipse", "tileRenderMode": "NineSlice", "nineSliceBorders": [2, 3, 4, 5], "hollow": true, "fillOpacity": 0.3, "lineOpacity": 0.6, "tileOpacity": 0.9,
			"tileRect": {"tilesetUid": 20, "x": 16, "y": 0, "w": 16, "h": 16}},
			{"identifier": "Lever", "uid": 11, "width": 16, "height": 16, "pivotX": 0, "pivotY": 0, "color": "#808080"}],
		"tilesets": [{"identifier": "Icons", "uid": 20, "relPath": null, "embedAtlas": "LdtkIcons", "tileGridSize": 16, "spacing": 0, "padding": 0,
			"pxWid": 256, "pxHei": 256, "__cWid": 16, "__cHei": 16, "tags": [], "customData": [{"tileId": 3, "data": "spikes"}],
			"enumTags": [{"enumValueId": "Hurts", "tileIds": [3, 4]}]},
			{"identifier": "Art", "uid": 21, "relPath": "art/tiles.png", "tileGridSize": 16, "spacing": 0, "padding": 0, "pxWid": 32, "pxHei": 32}],
		"enums": [{"identifier": "Kind", "uid": 30, "values": [{"id": "Gold"}, {"id": "Silver"}]}],
		"externalEnums": [],
		"levelFields": []
	},
	"levels": [
		{"identifier": "Level_0", "iid": "aaa", "uid": 0, "worldX": -1, "worldY": -1, "worldDepth": 0, "pxWid": 64, "pxHei": 48,
		 "__bgColor": "#102030", "bgRelPath": null, "externalRelPath": null, "__neighbours": [{"levelIid": "bbb", "dir": "e"}],
		 "fieldInstances": [{"__identifier": "music", "__type": "String", "__value": "cave"}],
		 "layerInstances": [
			{"__identifier": "Things", "__type": "Entities", "__cWid": 4, "__cHei": 3, "__gridSize": 16, "__opacity": 1,
			 "__pxTotalOffsetX": 0, "__pxTotalOffsetY": 0, "__tilesetDefUid": null, "__tilesetRelPath": null, "iid": "l1", "visible": true,
			 "intGridCsv": [], "gridTiles": [], "autoLayerTiles": [],
			 "entityInstances": [
				{"__identifier": "Coin", "iid": "c1", "__grid": [2, 1], "__pivot": [0.5, 0.5], "__tags": ["pickup"], "__smartColor": "#FFD700",
				 "__tile": {"tilesetUid": 20, "x": 0, "y": 0, "w": 16, "h": 16}, "px": [40, 24], "width": 8, "height": 8,
				 "fieldInstances": [
					{"__identifier": "Value", "__type": "Int", "__value": 5},
					{"__identifier": "kind", "__type": "LocalEnum.Kind", "__value": "Silver"},
					{"__identifier": "glow", "__type": "Color", "__value": "#FF0000"},
					{"__identifier": "home", "__type": "Point", "__value": {"cx": 3, "cy": 1}},
					{"__identifier": "path", "__type": "Array<Point>", "__value": [{"cx": 0, "cy": 0}, {"cx": 1, "cy": 2}]},
					{"__identifier": "target", "__type": "EntityRef", "__value": null},
					{"__identifier": "speed", "__type": "Float", "__value": 2}
				 ]},
				{"__identifier": "Lever", "iid": "lever1", "__grid": [0, 0], "__pivot": [0, 0], "__tags": [], "__smartColor": "#808080",
				 "__tile": null, "px": [0, 0], "width": 16, "height": 16,
				 "fieldInstances": [
					{"__identifier": "door", "__type": "EntityRef", "__value": {"entityIid": "c1", "layerIid": "l1", "levelIid": "aaa", "worldIid": "w"}},
					{"__identifier": "others", "__type": "Array<EntityRef>", "__value": [{"entityIid": "c1", "layerIid": "l1", "levelIid": "aaa", "worldIid": "w"}, {"entityIid": "elsewhere", "layerIid": "x", "levelIid": "bbb", "worldIid": "w"}]}
				 ]}
			 ]},
			{"__identifier": "Walls", "__type": "IntGrid", "__cWid": 4, "__cHei": 3, "__gridSize": 16, "__opacity": 0.5,
			 "__pxTotalOffsetX": 0, "__pxTotalOffsetY": 0, "__tilesetDefUid": null, "__tilesetRelPath": null, "iid": "l2", "visible": true,
			 "intGridCsv": [1,1,0,0, 1,1,0,2, 1,1,1,1], "gridTiles": [], "autoLayerTiles": [], "entityInstances": []}
		 ]},
		{"identifier": "Level_1", "iid": "bbb", "uid": 1, "worldX": -1, "worldY": -1, "pxWid": 32, "pxHei": 48,
		 "externalRelPath": "game/Level_1.ldtkl", "layerInstances": null, "fieldInstances": []}
	]
}`

@(private="file")
LEVEL_1 :: `{"identifier": "Level_1", "iid": "bbb", "uid": 1, "worldX": -1, "worldY": -1, "pxWid": 32, "pxHei": 48, "__bgColor": "#000000",
	"fieldInstances": [],
	"layerInstances": [
		{"__identifier": "Walls", "__type": "IntGrid", "__cWid": 2, "__cHei": 3, "__gridSize": 16, "__opacity": 1,
		 "__pxTotalOffsetX": 0, "__pxTotalOffsetY": 0, "iid": "l3", "visible": false,
		 "intGridCsv": [0,0, 0,0, 1,1], "gridTiles": [],
		 "autoLayerTiles": [{"px": [0, 32], "src": [16, 0], "f": 3, "t": 1, "a": 0.5}], "entityInstances": []}
	]}`

// A script named like the entity: the LDtk fields set its fields
@(private="file")
Coin :: struct {
	using script: Script,
	value: int `export:"" default=1`,
	kind: string `export:""`,
	glow: sdl.Color `export:""`,
	home: [2]f32 `export:""`,
	speed: f32 `export:""`,
}

@(private="file")
registerCoin :: proc() {
	@(static) once: sync.Once
	sync.once_do(&once, proc() { Script_Register(Coin, {}) })
}

// Each test its own folder: tests run in parallel, and each deletes its folder when done
@(private="file")
writeFixture :: proc(name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, name}, context.temp_allocator)
	_ = os.remove_all(dir)
	_ = os.make_directory_all(filepath.join({dir, "game"}, context.temp_allocator) or_else dir)
	_ = os.write_entire_file(filepath.join({dir, "game.ldtk"}, context.temp_allocator) or_else "", PROJECT)
	_ = os.write_entire_file(filepath.join({dir, "game/Level_1.ldtkl"}, context.temp_allocator) or_else "", LEVEL_1)
	return dir
}

@(test)
ldtk_project_is_read :: proc(t: ^testing.T) {
	dir := writeFixture("engine_test_ldtk_read")
	defer os.remove_all(dir)
	project, problem := LDtk_Load(JoinPath(dir, "game.ldtk"))
	defer LDtk_Destroy(project)
	testing.expect_value(t, problem, "")
	if project == nil do return

	// One world from the root, both levels (the second from its own file)
	testing.expect_value(t, len(project.worlds), 1)
	testing.expect_value(t, project.worlds[0].layout, LDtkWorldLayout.LinearHorizontal)
	testing.expect_value(t, len(project.worlds[0].levels), 2)
	level := LDtk_FindLevel(project, "Level_0")
	testing.expect(t, level != nil && LDtk_FindLevel(project, "bbb") != nil, "levels by identifier and iid")
	testing.expect_value(t, level.size, [2]f32{64, 48})
	testing.expect_value(t, level.bgColor, sdl.Color{0x10, 0x20, 0x30, 255})
	testing.expect_value(t, level.neighbours[0].dir, "e")
	testing.expect_value(t, LDtk_FieldValue(level.fields, "music", ""), "cave")

	// IntGrid, with its definition's names and parallax
	walls := LDtk_FindLayer(level, "Walls")
	testing.expect_value(t, walls.type, LDtkLayerType.IntGrid)
	testing.expect_value(t, walls.opacity, 0.5)
	testing.expect_value(t, LDtk_IntGridAt(walls, 3, 1), 2)
	testing.expect_value(t, LDtk_IntGridAt(walls, 2, 0), 0)
	testing.expect_value(t, LDtk_IntGridAt(walls, 9, 9), 0)
	testing.expect_value(t, walls.parallax, [2]f32{0.5, 0})
	def := LDtk_FindLayerDef(project, "Walls")
	testing.expect_value(t, def.intGridValues[1].identifier, "ladder")

	// An entity and every kind of field
	coin := &LDtk_FindLayer(level, "Things").entities[0]
	testing.expect_value(t, coin.identifier, "Coin")
	testing.expect_value(t, coin.px, [2]f32{40, 24})
	testing.expect_value(t, coin.grid, [2]int{2, 1})
	testing.expect_value(t, coin.tags[0], "pickup")
	testing.expect_value(t, LDtk_FieldValue(coin.fields, "Value", i64(0)), 5)
	testing.expect_value(t, LDtk_FieldValue(coin.fields, "Value", 0), 5)
	testing.expect_value(t, LDtk_FieldValue(coin.fields, "speed", f32(0)), 2)
	testing.expect_value(t, LDtk_FieldValue(coin.fields, "kind", ""), "Silver")
	testing.expect_value(t, LDtk_FieldValue(coin.fields, "glow", sdl.Color{}), sdl.Color{255, 0, 0, 255})
	testing.expect_value(t, LDtk_FieldValue(coin.fields, "home", LDtkGridPoint{}), LDtkGridPoint{3, 1})
	path := LDtk_FindField(coin.fields, "path").value.([]LDtkValue)
	testing.expect_value(t, len(path), 2)
	testing.expect_value(t, path[1].(LDtkGridPoint), LDtkGridPoint{1, 2})
	testing.expect(t, LDtk_FindField(coin.fields, "target").value == nil, "null is nil")
	text, _ := LDtk_ValueText(LDtk_FindField(coin.fields, "home").value, 16)
	testing.expect_value(t, text, "56,24")

	// The separate level: tiles with flips and alpha
	other := LDtk_FindLevel(project, "Level_1")
	tiles := other.layers[0].tiles
	testing.expect_value(t, len(tiles), 1)
	testing.expect(t, tiles[0].flipX && tiles[0].flipY && tiles[0].alpha == 0.5, "flip bits and alpha")
	testing.expect(t, !other.layers[0].visible, "visibility")

	// Definitions
	icons := LDtk_FindTileset(project, 20)
	testing.expect(t, icons.embedded && icons.path == "", "LDtk's icon atlas has no image")
	testing.expect_value(t, icons.customData[0].data, "spikes")
	testing.expect_value(t, icons.enumTags[0].tileIds[1], 4)
	testing.expect_value(t, project.enums[0].values[1], "Silver")

	// Entity definitions: how LDtk draws them, and each entity's definition
	coinDef := coin.def
	testing.expect(t, coinDef != nil && coinDef.identifier == "Coin", "the entity's definition")
	if coinDef != nil {
		testing.expect_value(t, coinDef.renderMode, LDtkEntityRenderMode.Ellipse)
		testing.expect_value(t, coinDef.tileRenderMode, LDtkTileRenderMode.NineSlice)
		testing.expect_value(t, coinDef.nineSlice, [4]f32{2, 3, 4, 5})
		testing.expect(t, coinDef.hollow && coinDef.fillOpacity == 0.3 && coinDef.lineOpacity == 0.6 && coinDef.tileOpacity == 0.9, "opacities")
		testing.expect_value(t, coinDef.tile.?, LDtkTilesetRect{20, 16, 0, 16, 16})
	}
	testing.expect_value(t, LDtk_FindLayerDef(project, "Things").parallax, [2]f32{0.5, 0})
	// Paths outlive the frame (they're the project's, not temp memory)
	free_all(context.temp_allocator)
	art := LDtk_FindTileset(project, 21)
	testing.expect(t, strings.has_suffix(art.path, "engine_test_ldtk_read/art/tiles.png"), art.path)

	deps := LDtk_Dependencies(PROJECT)
	testing.expect_value(t, len(deps), 2)
	testing.expect_value(t, deps[0], "art/tiles.png")
	testing.expect_value(t, deps[1], "game/Level_1.ldtkl")

	_, bad := LDtk_Parse(`{"not": "ldtk"}`, "x.ldtk")
	testing.expect(t, bad != "", "a JSON file that isn't LDtk")
	free_all(context.temp_allocator)
}

@(test)
ldtk_level_is_built :: proc(t: ^testing.T) {
	registerCoin()
	dir := writeFixture("engine_test_ldtk_build")
	defer os.remove_all(dir)
	game: Game
	game.projectDir = dir
	defer Game_ForgetLDtk(&game)
	defer if game.arenaReady do MemoryArena_Destroy(&game.arena)
	scene := new(Scene)
	Scene_Init(scene)
	scene.game = &game
	scene.physicsPaused = true
	defer { Scene_Destroy(scene); free(scene) }

	text := `<scene formatVersion="12" name="S">
		<node kind="LDtkLevel" name="Level" x="100" y="200" ldtk="game.ldtk" level="Level_0" intGridCollision="Walls" collisionValues="1" collisionLayer="2" friction="0.1"/>
		<node kind="LDtkLevel" name="World" ldtk="game.ldtk" allLevels="true" spawnEntities="false">
			<entity name="Coin" component="components/coin.component.xml"/>
		</node>
	</scene>`
	data, err := ParseScene(text)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, data.nodes[0].ldtk.file, "game.ldtk")
	testing.expect_value(t, data.nodes[0].ldtk.collisionValues[0], 1)
	testing.expect(t, data.nodes[1].ldtk.allLevels && !data.nodes[1].ldtk.spawnEntities, "flags")
	testing.expect_value(t, data.nodes[1].ldtk.entityComponents[0].component, "components/coin.component.xml")

	created := Scene_Build(scene, &data, dir)
	Scene_ProcessQueues(scene)
	level := cast(^LDtkLevelNode)created[0]
	testing.expect(t, Node_Is(level, LDtkLevelNode) && level.project != nil, "the project was read")
	testing.expect_value(t, level.position, [2]f32{100, 200})
	testing.expect_value(t, len(level.views), 1)
	bounds, _ := level.getBounds(level)
	testing.expect_value(t, bounds, sdl.FRect{0, 0, 64, 48})

	// Layers back to front (Walls was LDtk's lower one), then the collision
	view := level.views[0]
	testing.expect_value(t, view.name, "Level_0")
	testing.expect_value(t, view.children[0].name, "Walls")
	testing.expect_value(t, view.children[1].name, "Things")
	collision := Scene_FindNode(scene, "Level/Level_0/Collision")
	testing.expect(t, Node_Is(collision, StaticBody), "a StaticBody for the IntGrid")
	if collision == nil do return
	body := cast(^StaticBody)collision
	testing.expect_value(t, body.collisionLayer, PhysicsLayers(2))
	testing.expect_value(t, body.friction, 0.1)
	// Value 1 only: a 2x3 block and a 2x1 run, merged; the ladder (2) is left out
	testing.expect_value(t, len(collision.children), 2)
	first := cast(^CollisionShape)collision.children[0]
	testing.expect_value(t, first.size, [2]f32{32, 48})
	testing.expect_value(t, first.position, [2]f32{16, 24})
	second := cast(^CollisionShape)collision.children[1]
	testing.expect_value(t, second.size, [2]f32{32, 16})
	testing.expect_value(t, second.position, [2]f32{48, 40})

	// Entity references, to the nodes built for them (one points at a level that isn't built)
	lever := LDtk_FindEntityNodes(level, "Lever")
	testing.expect_value(t, len(lever), 1)
	if len(lever) == 1 {
		door := LDtk_EntityRefNode(lever[0], "door")
		testing.expect(t, door != nil && door.name == "Coin", "door -> the coin's node")
		testing.expect_value(t, len(LDtk_EntityRefNodes(lever[0], "others")), 1)
		testing.expect(t, LDtk_EntityRefNode(lever[0], "nothing") == nil, "no such field")
		testing.expect(t, LDtk_FindEntityByIid(level, "lever1") == lever[0], "by iid")
	}

	// The entity got the script named like it, its fields from LDtk
	coins := LDtk_FindEntityNodes(level, "Coin")
	testing.expect_value(t, len(coins), 1)
	coin := coins[0]
	testing.expect_value(t, coin.position, [2]f32{40, 24})
	script := Node_GetScript(coin, Coin)
	testing.expect(t, script != nil, "the Coin script is attached")
	if script != nil {
		testing.expect_value(t, script.value, 5) // "Value" in LDtk
		testing.expect_value(t, script.kind, "Silver")
		testing.expect_value(t, script.glow, sdl.Color{255, 0, 0, 255})
		testing.expect_value(t, script.home, [2]f32{56, 24})
		testing.expect_value(t, script.speed, 2)
	}
	testing.expect(t, LDtk_EntityOf(coin) != nil && LDtk_EntityOf(coin).iid == "c1", "the entity's data from its node")
	testing.expect(t, LDtk_EntityOf(level) == nil, "not an entity")

	// Parallax: the Things layer (factor 0.5 across, no scaling) follows the camera once the
	// scene updates; at rest it's at its offset
	things := Scene_FindNode(scene, "Level/Level_0/Things")
	testing.expect_value(t, things.position, [2]f32{0, 0})
	camera := CreateNode(scene, Camera2D)
	camera.zoom = 1
	camera.position = {100 + 64, 200 + 24}
	scene.camera = camera
	Scene_Update(scene, nil, 1.0 / 60)
	// Camera at (64, 24) in the level: 64 * 0.5 - 64 * 0.5 * 0.5 = 16 across
	testing.expect_value(t, things.position, [2]f32{16, 0})

	// IntGrid values under world positions (the node is at 100, 200)
	testing.expect_value(t, LDtk_IntGridAtPosition(level, "Walls", {100 + 50, 200 + 20}), 2)
	testing.expect_value(t, LDtk_IntGridAtPosition(level, "Walls", {100 + 40, 200 + 5}), 0)
	testing.expect_value(t, LDtk_IntGridAtPosition(level, "Walls", {0, 0}), 0)

	// A removed entity (a collected coin) leaves the lookups: they never return a freed node
	spawnedBefore := len(level.spawned)
	Scene_RemoveNode(scene, coin.id)
	Scene_Update(scene, nil, 1.0 / 60)
	testing.expect_value(t, len(level.spawned), spawnedBefore - 1)
	testing.expect_value(t, len(LDtk_FindEntityNodes(level, "Coin")), 0)
	testing.expect(t, len(lever) == 1 && LDtk_EntityRefNode(lever[0], "door") == nil, "a reference to a removed entity is nil")

	// Every level of the world, one after the other (a linear layout); no entities
	world := cast(^LDtkLevelNode)created[1]
	testing.expect_value(t, len(world.views), 2)
	testing.expect_value(t, world.views[1].position, [2]f32{64, 0})
	testing.expect_value(t, len(world.spawned), 0)
	worldBounds, _ := world.getBounds(world)
	testing.expect_value(t, worldBounds, sdl.FRect{0, 0, 96, 48})
	testing.expect(t, !world.views[1].children[0].visible, "a hidden LDtk layer is hidden")
	testing.expect(t, level.project == world.project, "one project per file, shared")

	// No file: an empty node (a missing file or level is the same, and logs an error)
	missing, _ := ParseScene(`<scene formatVersion="12" name="M"><node kind="LDtkLevel" name="L"/></scene>`)
	defer SceneData_Destroy(&missing)
	empty := cast(^LDtkLevelNode)Scene_Build(scene, &missing, dir)[0]
	testing.expect_value(t, len(empty.views), 0)
	free_all(context.temp_allocator)
}

@(test)
ldtk_reloads_while_playing :: proc(t: ^testing.T) {
	registerCoin()
	dir := writeFixture("engine_test_ldtk_reload")
	defer os.remove_all(dir)
	game: Game
	game.projectDir = dir
	game.devKeys = true
	defer Game_ForgetLDtk(&game)
	defer if game.arenaReady do MemoryArena_Destroy(&game.arena)
	scene := new(Scene)
	Scene_Init(scene)
	scene.game = &game
	scene.physicsPaused = true
	defer { Scene_Destroy(scene); free(scene) }
	game.scenes = make(map[string]^Scene)
	defer delete(game.scenes)
	game.scenes["S"] = scene

	data, _ := ParseScene(`<scene formatVersion="12" name="S"><node kind="LDtkLevel" name="Level" ldtk="game.ldtk" intGridCollision="Walls" collisionValues="1"/></scene>`)
	defer SceneData_Destroy(&data)
	level := cast(^LDtkLevelNode)Scene_Build(scene, &data, dir)[0]
	Scene_ProcessQueues(scene)
	coins := LDtk_FindEntityNodes(level, "Coin")
	coin := len(coins) > 0 ? coins[0] : nil
	testing.expect_value(t, len(Scene_FindNode(scene, "Level/Level_0/Collision").children), 2)

	// Nothing changed: nothing reloaded
	before := level.project
	LDtk_WatchFiles(&game, 1)
	testing.expect(t, level.project == before, "same file, same project")

	// Saved in LDtk: a cell of the wall block is empty now (the 2x3 block splits), and the
	// background is another color. A later modification time, whatever the clock's resolution
	time.sleep(20 * time.Millisecond)
	changed, _ := strings.replace(PROJECT, `"intGridCsv": [1,1,0,0, 1,1,0,2, 1,1,1,1]`, `"intGridCsv": [1,1,0,0, 0,1,0,2, 1,1,1,1]`, 1, context.temp_allocator)
	changed, _ = strings.replace(changed, `"__bgColor": "#102030"`, `"__bgColor": "#405060"`, 1, context.temp_allocator)
	_ = os.write_entire_file(filepath.join({dir, "game.ldtk"}, context.temp_allocator) or_else "", changed)
	LDtk_WatchFiles(&game, 1)
	Scene_ProcessQueues(scene)
	testing.expect(t, level.project != before, "read again")
	testing.expect_value(t, level.views[0].level.bgColor, sdl.Color{0x40, 0x50, 0x60, 255})
	walls := cast(^LDtkTileLayer)Scene_FindNode(scene, "Level/Level_0/Walls")
	testing.expect_value(t, LDtk_IntGridAt(walls.data, 0, 1), 0)
	collision := Scene_FindNode(scene, "Level/Level_0/Collision")
	// 1 1 . .     the top pair, the column under its right cell, the bottom-left cell, the
	// . 1 . 2     bottom-right pair (the ladder, 2, isn't collision)
	// 1 1 1 1
	testing.expect(t, collision != nil && len(collision.children) == 4, "the collision made again from the new cells")
	// Entities keep running: the same node, its data still readable
	after := LDtk_FindEntityNodes(level, "Coin")
	testing.expect(t, len(after) == 1 && after[0] == coin, "the coin is the same node")
	testing.expect(t, LDtk_EntityOf(coin) != nil && LDtk_EntityOf(coin).iid == "c1", "its data (the replaced project's) still there")
	free_all(context.temp_allocator)
}
