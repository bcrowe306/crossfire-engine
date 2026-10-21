#+build !js
package crossfire

import "core:fmt"
import "core:testing"
import sdl "vendor:sdl3"

// Painted tilemap layers and terrains (autotiling), on a tileset Aseprite made
// (testdata/aseprite/conformance/terrain: 16 grass tiles, one per combination of edges, tile i+1
// for the edges in i's bits: N, E, S, W; tile 17 dirt)

// The grass tile drawn for these same-terrain edges
@(private="file")
grass :: proc(n, e, s, w: bool) -> u32 {
	i := 0
	if n do i |= 1
	if e do i |= 2
	if s do i |= 4
	if w do i |= 8
	return u32(i + 1)
}

@(test)
terrains_pick_tiles_from_their_neighbours :: proc(t: ^testing.T) {
	ase, err := Aseprite_Load("testdata/aseprite/conformance/terrain.aseprite")
	testing.expect_value(t, err, AsepriteError.None)
	if ase == nil do return
	defer Aseprite_Destroy(ase)
	tileset := &ase.tilesets[ase.layers[0].tileset]
	terrains := Tileset_Terrains(tileset, context.temp_allocator)
	testing.expect(t, len(terrains) == 1 && terrains[0] == "grass", "one terrain")
	testing.expect_value(t, Tileset_TerrainOf(tileset, 17), "")
	// An edge set: corners don't matter
	testing.expect_value(t, Terrain_TileFor(tileset, "grass", 0), grass(false, false, false, false))
	testing.expect_value(t, Terrain_TileFor(tileset, "grass", TERRAIN_N | TERRAIN_E), grass(true, true, false, false))
	testing.expect_value(t, Terrain_TileFor(tileset, "grass", 0xff), grass(true, true, true, true))

	// Painted into a 5 x 5 grid: alone, then with a neighbour, then erased again
	tiles := make([]u32, 25, context.temp_allocator)
	at :: proc(tiles: []u32, x, y: int) -> u32 { return tiles[y * 5 + x] }
	testing.expect(t, TileGrid_PaintTerrain(tileset, tiles, 5, 5, 2, 2, "grass"), "painted")
	testing.expect_value(t, at(tiles, 2, 2), grass(false, false, false, false))
	TileGrid_PaintTerrain(tileset, tiles, 5, 5, 3, 2, "grass")
	testing.expect_value(t, at(tiles, 2, 2), grass(false, true, false, false))
	testing.expect_value(t, at(tiles, 3, 2), grass(false, false, false, true))
	TileGrid_PaintTerrain(tileset, tiles, 5, 5, 2, 3, "grass")
	testing.expect_value(t, at(tiles, 2, 2), grass(false, true, true, false))
	TileGrid_PaintTerrain(tileset, tiles, 5, 5, 3, 2, "")
	testing.expect_value(t, at(tiles, 3, 2), u32(0))
	testing.expect_value(t, at(tiles, 2, 2), grass(false, false, true, false))
	// At the map's edge the terrain goes on (no border): the corner cell has N and W
	TileGrid_PaintTerrain(tileset, tiles, 5, 5, 0, 0, "grass")
	testing.expect_value(t, at(tiles, 0, 0), grass(true, false, false, true))
	testing.expect(t, !TileGrid_PaintTerrain(tileset, tiles, 5, 5, 9, 0, "grass"), "off the grid")
	// A tile of no terrain next to grass stays as it is
	tiles[1 * 5 + 1] = 17
	TileGrid_PaintTerrain(tileset, tiles, 5, 5, 1, 0, "grass")
	testing.expect_value(t, at(tiles, 1, 1), u32(17))
	free_all(context.temp_allocator)
}

@(test)
painted_tile_layers_build :: proc(t: ^testing.T) {
	// The encoding: little-endian base64, and a damaged one
	data := []u32{1, 0, 17 | ASEPRITE_TILE_FLIP_X, 4}
	text := TileLayer_Encode(data, context.temp_allocator)
	back, ok := TileLayer_Decode(text, 4, context.temp_allocator)
	testing.expect(t, ok && len(back) == 4 && back[2] == 17 | ASEPRITE_TILE_FLIP_X, "round trip")
	short, shortOk := TileLayer_Decode("AQAAAA==", 3, context.temp_allocator)
	testing.expect(t, !shortOk && len(short) == 3 && short[0] == 1 && short[2] == 0, "too short: the rest empty")

	surface := sdl.CreateSurface(32, 16, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := testGame("testdata/aseprite")
	defer { Game_Destroy(game); free(game) }
	game.resourceManager.renderer = renderer
	scene := game->createScene("S")
	// Ground painted over (2 x 1 tiles: dirt, then the lone grass); a new layer, Decor, on the
	// same tileset at x 16
	ground := TileLayer_Encode([]u32{17, 1}, context.temp_allocator)
	decor := TileLayer_Encode([]u32{16}, context.temp_allocator)
	sceneData, err := ParseScene(fmt.tprintf(`<scene formatVersion="13" name="S">
		<node kind="TileMap" name="Level" tilemap="conformance/terrain.aseprite">
			<tiles layer="Ground" columns="2" rows="1" data="%s"/>
			<tiles layer="Decor" tileset="0" x="16" columns="1" rows="1" data="%s"/>
		</node>
	</scene>`, ground, decor))
	defer SceneData_Destroy(&sceneData)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, len(sceneData.nodes[0].tilemap.painted), 2)
	created := Scene_Build(scene, &sceneData, "testdata/aseprite", attachScripts = false)
	Scene_ProcessQueues(scene)
	level := cast(^TileMapNode)created[0]
	testing.expect_value(t, len(level.tileLayers), 2)
	if len(level.tileLayers) != 2 do return
	testing.expect(t, level.tileLayers[0].layerName == "Ground" && level.tileLayers[0].cells == {2, 1}, "Ground, painted")
	testing.expect(t, level.tileLayers[1].layerName == "Decor" && level.tileLayers[1].position == {16, 0}, "Decor, its own")
	// Drawn: dirt, the lone grass tile, then the full grass tile (each tile's top-left pixel)
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 0)
	sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	sdl.FlushRenderer(renderer)
	pixel :: proc(s: ^sdl.Surface, x, y: int) -> [3]u8 {
		p := ([^]u8)(s.pixels)[y * int(s.pitch) + x * 4:][:4]
		return {p[0], p[1], p[2]}
	}
	testing.expect_value(t, pixel(surface, 0, 0), [3]u8{120, 80, 40})
	testing.expect_value(t, pixel(surface, 4, 0), [3]u8{0, 255, 0})
	testing.expect_value(t, pixel(surface, 16, 0), [3]u8{240, 15, 0})
	// A terrain painted from code: the grass on its right joins it
	testing.expect(t, TileMap_SetTerrain(level, "Ground", 0, 0, "grass"), "painted")
	testing.expect_value(t, level.tileLayers[0].tiles[0], grass(true, true, true, true))
	free_all(context.temp_allocator)
}
