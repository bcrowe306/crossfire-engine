#+build !js
package crossfire

import "core:bytes"
import "core:os"
import "core:testing"
import sdl "vendor:sdl3"

// TileMap nodes: an Aseprite file written here (a tilemap layer whose tiles carry collision
// properties, one tile flipped), built from a scene file: its layer, its bodies (solid, one-way,
// an area), the tile lookups, and its pixels on a software renderer

// Little-endian writing, as the format wants
@(private="file")
put :: proc(b: ^bytes.Buffer, values: ..any) {
	for v in values {
		switch x in v {
		case u8:  bytes.buffer_write_byte(b, x)
		case u16: bytes.buffer_write(b, {u8(x), u8(x >> 8)})
		case u32: bytes.buffer_write(b, {u8(x), u8(x >> 8), u8(x >> 16), u8(x >> 24)})
		case i16: put(b, u16(x))
		case string:
			put(b, u16(len(x)))
			bytes.buffer_write_string(b, x)
		case []u8: bytes.buffer_write(b, x)
		}
	}
}

// A zlib stream of stored blocks (deflate without compression) with its Adler-32
@(private="file")
zlibStored :: proc(data: []u8) -> []u8 {
	b: bytes.Buffer
	bytes.buffer_init_allocator(&b, 0, len(data) + 64, context.temp_allocator)
	put(&b, u8(0x78), u8(0x01))
	at := 0
	for {
		n := min(len(data) - at, 65535)
		final := at + n >= len(data)
		put(&b, u8(final ? 1 : 0), u16(n), u16(~u16(n)))
		bytes.buffer_write(&b, data[at:][:n])
		at += n
		if final do break
	}
	a, s: u32 = 1, 0
	for v in data {
		a = (a + u32(v)) % 65521
		s = (s + a) % 65521
	}
	sum := s << 16 | a
	put(&b, u8(sum >> 24), u8(sum >> 16), u8(sum >> 8), u8(sum))
	return bytes.buffer_to_bytes(&b)
}

// A chunk: its size (with its 6-byte header), type, data
@(private="file")
chunk :: proc(frame: ^bytes.Buffer, type: u16, data: []u8) {
	put(frame, u32(len(data) + 6), type)
	bytes.buffer_write(frame, data)
}

// User data with one string property per pair (none: empty)
@(private="file")
userData :: proc(properties: ..[2]string) -> []u8 {
	b: bytes.Buffer
	bytes.buffer_init_allocator(&b, 0, 64, context.temp_allocator)
	if len(properties) == 0 {
		put(&b, u32(0))
		return bytes.buffer_to_bytes(&b)
	}
	maps: bytes.Buffer
	bytes.buffer_init_allocator(&maps, 0, 64, context.temp_allocator)
	put(&maps, u32(0), u32(len(properties)))
	for p in properties do put(&maps, p[0], u16(0x0D), p[1])
	body := bytes.buffer_to_bytes(&maps)
	put(&b, u32(4), u32(len(body) + 8), u32(1))
	bytes.buffer_write(&b, body)
	return bytes.buffer_to_bytes(&b)
}

/*
A 16 x 8 sprite with one tilemap layer, "Ground": 4 x 2 tiles of 4 x 4 from a tileset of 4 (0
empty). Tile 1 is solid (red left half, blue right), 2 one-way (green), 3 an area "spikes"
(yellow). The grid:

	1 1 2 0
	3 3 1 1(flipped across)
*/
@(private="file")
tilemapFile :: proc(tiles := []u32{1, 1, 2, 0, 3, 3, 1, 1 | 0x80000000}) -> []u8 {
	TILE :: 4
	frame: bytes.Buffer
	bytes.buffer_init_allocator(&frame, 0, 1024, context.temp_allocator)
	// The layer: visible, tilemap, tileset 0
	layer: bytes.Buffer
	bytes.buffer_init_allocator(&layer, 0, 64, context.temp_allocator)
	put(&layer, u16(1), u16(2), u16(0), u16(0), u16(0), u16(0), u8(255), u8(0), u8(0), u8(0), "Ground", u32(0))
	chunk(&frame, 0x2004, bytes.buffer_to_bytes(&layer))
	// The tileset's pixels: one column of 4 tiles
	pixels := make([]u8, TILE * TILE * 4 * 4, context.temp_allocator)
	colors := [4][2][4]u8{{}, {{255, 0, 0, 255}, {0, 0, 255, 255}}, {{0, 255, 0, 255}, {0, 255, 0, 255}}, {{255, 255, 0, 255}, {255, 255, 0, 255}}}
	for tile in 0..<4 do for y in 0..<TILE do for x in 0..<TILE {
		c := colors[tile][x < TILE / 2 ? 0 : 1]
		copy(pixels[((tile * TILE + y) * TILE + x) * 4:][:4], c[:])
	}
	compressed := zlibStored(pixels)
	tileset: bytes.Buffer
	bytes.buffer_init_allocator(&tileset, 0, 512, context.temp_allocator)
	put(&tileset, u32(0), u32(2 | 4), u32(4), u16(TILE), u16(TILE), i16(1))
	bytes.buffer_write(&tileset, make([]u8, 14, context.temp_allocator))
	put(&tileset, "Terrain", u32(len(compressed)), compressed)
	chunk(&frame, 0x2023, bytes.buffer_to_bytes(&tileset))
	// Its user data (none), then each tile's
	chunk(&frame, 0x2020, userData())
	chunk(&frame, 0x2020, userData())
	chunk(&frame, 0x2020, userData({"collision", "solid"}))
	chunk(&frame, 0x2020, userData({"collision", "one-way"}))
	chunk(&frame, 0x2020, userData({"area", "spikes"}))
	// The cel: 4 x 2 tiles, 32 bits each, Aseprite's masks
	raw := make([]u8, len(tiles) * 4, context.temp_allocator)
	for t, i in tiles do raw[i * 4], raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3] = u8(t), u8(t >> 8), u8(t >> 16), u8(t >> 24)
	cel: bytes.Buffer
	bytes.buffer_init_allocator(&cel, 0, 128, context.temp_allocator)
	put(&cel, u16(0), i16(0), i16(0), u8(255), u16(3), i16(0))
	bytes.buffer_write(&cel, make([]u8, 5, context.temp_allocator))
	put(&cel, u16(4), u16(2), u16(32), u32(0x1fffffff), u32(0x80000000), u32(0x40000000), u32(0x20000000))
	bytes.buffer_write(&cel, make([]u8, 10, context.temp_allocator))
	bytes.buffer_write(&cel, zlibStored(raw))
	chunk(&frame, 0x2005, bytes.buffer_to_bytes(&cel))

	frameData := bytes.buffer_to_bytes(&frame)
	file: bytes.Buffer
	bytes.buffer_init_allocator(&file, 0, 2048, context.temp_allocator)
	header := make([]u8, 128, context.temp_allocator)
	file2: bytes.Buffer
	bytes.buffer_init_allocator(&file2, 0, 128, context.temp_allocator)
	put(&file2, u32(128 + 16 + len(frameData)), u16(0xA5E0), u16(1), u16(16), u16(8), u16(32), u32(1), u16(100))
	copy(header, bytes.buffer_to_bytes(&file2))
	bytes.buffer_write(&file, header)
	put(&file, u32(16 + len(frameData)), u16(0xF1FA), u16(8), u16(100), u16(0), u32(8))
	bytes.buffer_write(&file, frameData)
	return bytes.buffer_to_bytes(&file)
}

@(test)
tilemaps_draw_collide_and_answer :: proc(t: ^testing.T) {
	data := tilemapFile()
	ase, err := Aseprite_Parse(data)
	testing.expect_value(t, err, AsepriteError.None)
	if ase == nil do return
	tileset := &ase.tilesets[0]
	kind, area := TileMap_TileCollision(tileset, 1)
	testing.expect_value(t, kind, TileCollisionKind.Solid)
	kind, _ = TileMap_TileCollision(tileset, 2 | ASEPRITE_TILE_FLIP_X)
	testing.expect_value(t, kind, TileCollisionKind.One_Way)
	kind, area = TileMap_TileCollision(tileset, 3)
	testing.expect(t, kind == .Area && area == "spikes", "an area tile")
	kind, _ = TileMap_TileCollision(tileset, 0)
	testing.expect_value(t, kind, TileCollisionKind.None)
	testing.expect_value(t, len(ase.layers), 1)
	testing.expect_value(t, ase.layers[0].type, AsepriteLayerType.Tilemap)
	testing.expect_value(t, ase.layers[0].tileset, 0)
	cel := Aseprite_Cel(ase, 0, 0)
	testing.expect(t, cel != nil && len(cel.tiles) == 8 && cel.tiles[7] == 1 | ASEPRITE_TILE_FLIP_X, "the cel's tiles")
	Aseprite_Destroy(ase)

	dir := tempFolder("engine_test_tilemap")
	defer os.remove_all(dir)
	_ = os.write_entire_file(JoinPath(dir, "level.aseprite"), data)
	surface := sdl.CreateSurface(16, 8, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := testGame(dir)
	defer { Game_Destroy(game); free(game) }
	game.resourceManager.renderer = renderer
	scene := game->createScene("S")
	sceneData, parseErr := ParseScene(`<scene formatVersion="13" name="S">
		<node kind="TileMap" name="Level" tilemap="level.aseprite" friction="0.7"/>
	</scene>`)
	defer SceneData_Destroy(&sceneData)
	testing.expect_value(t, parseErr, ProjectError.None)
	testing.expect(t, sceneData.nodes[0].tilemap.file == "level.aseprite" && sceneData.nodes[0].tilemap.collision, "its settings")
	created := Scene_Build(scene, &sceneData, dir, attachScripts = false)
	Scene_ProcessQueues(scene)
	level := cast(^TileMapNode)created[0]
	testing.expect(t, Node_Is(level, TileMapNode), "a TileMap")
	testing.expect_value(t, len(level.tileLayers), 1)
	if len(level.tileLayers) != 1 do return
	ground := level.tileLayers[0]
	testing.expect_value(t, ground.layerName, "Ground")
	testing.expect_value(t, len(ground.quads), 7)
	bounds, _ := Node_GetLocalBounds(level)
	testing.expect_value(t, bounds, sdl.FRect{0, 0, 16, 8})

	// Its bodies: solid and one-way tiles merged into 3 shapes, the spikes an Area
	collision := Scene_FindNode(scene, "Level/Collision")
	spikes := Scene_FindNode(scene, "Level/spikes")
	testing.expect(t, collision != nil && Node_Is(collision, StaticBody), "a StaticBody")
	testing.expect(t, spikes != nil && Node_Is(spikes, Area), "an Area named after its tiles")
	if collision != nil {
		testing.expect_value(t, len(collision.children), 3)
		oneWay := 0
		for c in collision.children do if (cast(^CollisionShape)c).oneWay do oneWay += 1
		testing.expect_value(t, oneWay, 1)
		testing.expect_value(t, (cast(^PhysicsBody)collision).friction, f32(0.7))
	}
	if spikes != nil {
		testing.expect_value(t, len(spikes.children), 1)
		shape := cast(^CollisionShape)spikes.children[0]
		testing.expect(t, shape.size == {8, 4} && shape.position == {4, 6}, "the two spike tiles, merged")
	}

	// The tile under a point
	tile, layer, ok := TileMap_TileAt(level, "", {9, 1})
	testing.expect(t, ok && tile == 2 && layer == ground, "the one-way tile")
	value, has := TileMap_TileProperty(layer, tile, "collision")
	testing.expect(t, has && value.(string) == "one-way", "its property")
	tile, _, ok = TileMap_TileAt(level, "Ground", {13, 1})
	testing.expect(t, ok && tile == 0, "an empty tile")
	_, _, ok = TileMap_TileAt(level, "", {40, 1})
	testing.expect(t, !ok, "off the grid")

	// Drawn: red then blue across a solid tile; the flipped one blue then red
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 0)
	sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	sdl.FlushRenderer(renderer)
	at :: proc(surface: ^sdl.Surface, x, y: int) -> [3]u8 {
		p := ([^]u8)(surface.pixels)[y * int(surface.pitch) + x * 4:][:4]
		return {p[0], p[1], p[2]}
	}
	testing.expect_value(t, at(surface, 1, 1), [3]u8{255, 0, 0})
	testing.expect_value(t, at(surface, 2, 1), [3]u8{0, 0, 255})
	testing.expect_value(t, at(surface, 9, 1), [3]u8{0, 255, 0})
	testing.expect_value(t, at(surface, 13, 5), [3]u8{0, 0, 255})
	testing.expect_value(t, at(surface, 14, 5), [3]u8{255, 0, 0})
	testing.expect_value(t, at(surface, 13, 1), [3]u8{0, 0, 0})

	// A tile changed from code: drawn at once, the bodies on the next update (a one-way tile made
	// solid: the solid tiles of row 0 merge into one wider shape)
	column, row, inGrid := TileMap_CellAt(level, "Ground", {9, 1})
	testing.expect(t, inGrid && column == 2 && row == 0, "the cell under a point")
	testing.expect(t, TileMap_SetTile(level, "Ground", 2, 0, 1), "set")
	tile, _, _ = TileMap_TileAt(level, "Ground", {9, 1})
	testing.expect_value(t, tile, u32(1))
	Scene_Update(scene, nil, 0)
	// The old body leaves with the next queue pass
	Scene_ProcessQueues(scene)
	collision = Scene_FindNode(scene, "Level/Collision")
	if collision != nil {
		testing.expect_value(t, len(collision.children), 2)
		oneWay := 0
		for c in collision.children do if (cast(^CollisionShape)c).oneWay do oneWay += 1
		testing.expect_value(t, oneWay, 0)
	}

	// A development run: the file saved again (two tiles left) is read again and the node rebuilt
	game.devKeys = true
	_ = os.write_entire_file(JoinPath(dir, "level.aseprite"), tilemapFile({1, 0, 0, 0, 0, 0, 0, 2}))
	// Its modification time must differ: SDL's is in nanoseconds, but some file systems round it
	level.modified -= 1
	Scene_Update(scene, nil, 1)
	testing.expect_value(t, len(level.tileLayers), 1)
	if len(level.tileLayers) == 1 do testing.expect_value(t, len(level.tileLayers[0].quads), 2)
	Scene_Update(scene, nil, 0.01)
	testing.expect(t, Scene_FindNode(scene, "Level/spikes") == nil, "no area tiles any more")
	// The replaced file goes on the update after its rebuild. Windows CI once saw the save's time
	// land a check later (one more rebuild, its file freed on the update after): allow a few
	for _ in 0 ..< 3 {
		if len(level.retired) == 0 do break
		Scene_Update(scene, nil, 0.01)
	}
	testing.expect_value(t, len(level.retired), 0)
	game.devKeys = false

	// Rebuilt from no file: no layers, no bodies
	TileMap_Rebuild(level, nil)
	testing.expect_value(t, len(level.tileLayers), 0)
	Scene_ProcessQueues(scene)
	free_all(context.temp_allocator)
}
