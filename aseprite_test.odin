#+build !js
package crossfire

import "core:math/rand"
import "core:slice"
import "core:os"
import "core:testing"
import sdl "vendor:sdl3"

// Aseprite files: Aseprite's own test sprites (testdata/aseprite, MIT) read, composited (its
// z-order test's expected colors), tilemaps, tags, linked cels, indexed transparency, user data;
// broken files are errors, never crashes

@(private="file")
loadFixture :: proc(t: ^testing.T, name: string, loc := #caller_location) -> ^Aseprite {
	data, err := os.read_entire_file(JoinPath("testdata/aseprite", name), context.temp_allocator)
	testing.expectf(t, err == nil, "read %s", name, loc = loc)
	ase, parseErr := Aseprite_Parse(data)
	testing.expectf(t, parseErr == .None, "%s: %v", name, parseErr, loc = loc)
	return ase
}

@(private="file")
pixelAt :: proc(pixels: []u8, width, x, y: int) -> [4]u8 {
	p := pixels[(y * width + x) * 4:][:4]
	return {p[0], p[1], p[2], p[3]}
}

@(test)
aseprite_composites_like_aseprite :: proc(t: ^testing.T) {
	// Aseprite's tests/scripts/z_order.lua, with the same changes to the sprite
	ase := loadFixture(t, "z-order.aseprite")
	if ase == nil do return
	defer Aseprite_Destroy(ase)
	L3, L4, G1, L5 := Aseprite_FindLayer(ase, "L3"), Aseprite_FindLayer(ase, "L4"), Aseprite_FindLayer(ase, "G1"), Aseprite_FindLayer(ase, "L5")
	testing.expect(t, L3 >= 0 && L4 >= 0 && G1 >= 0 && L5 >= 0, "its layers")
	testing.expect_value(t, ase.layers[Aseprite_FindLayer(ase, "G1-2")].parent, G1)
	Aseprite_Cel(ase, 0, L4).zIndex = -1
	ase.layers[G1].visible = false
	ase.layers[L5].visible = false
	testing.expect_value(t, pixelAt(Aseprite_FramePixels(ase, 0, context.temp_allocator), ase.width, 1, 5), [4]u8{0, 255, 0, 255})
	ase.layers[L3].visible = false
	testing.expect_value(t, pixelAt(Aseprite_FramePixels(ase, 0, context.temp_allocator), ase.width, 1, 5), [4]u8{255, 0, 0, 255})
	ase.layers[L3].visible = true
	Aseprite_Cel(ase, 0, L4).zIndex = 1
	ase.layers[G1].visible = true
	ase.layers[L5].visible = true
	testing.expect_value(t, pixelAt(Aseprite_FramePixels(ase, 0, context.temp_allocator), ase.width, 0, 0), [4]u8{64, 64, 64, 255})
	ase.layers[G1].visible = false
	testing.expect_value(t, pixelAt(Aseprite_FramePixels(ase, 0, context.temp_allocator), ase.width, 0, 0), [4]u8{64, 64, 64, 255})

	// Hidden groups hide their layers
	groups := loadFixture(t, "groups3abc.aseprite")
	if groups == nil do return
	defer Aseprite_Destroy(groups)
	testing.expect_value(t, len(groups.layers), 12)
	testing.expect(t, !Aseprite_LayerShown(groups, 11), "c/c is visible, but in the hidden group c")
	testing.expect(t, Aseprite_LayerShown(groups, 1), "a/a")
	free_all(context.temp_allocator)
}

@(test)
aseprite_tags_linked_cels_and_indexed_transparency :: proc(t: ^testing.T) {
	tags := loadFixture(t, "tags3.aseprite")
	if tags == nil do return
	defer Aseprite_Destroy(tags)
	testing.expect_value(t, len(tags.frames), 12)
	testing.expect_value(t, len(tags.tags), 3)
	if len(tags.tags) == 3 {
		testing.expect(t, tags.tags[0].name == "forward" && tags.tags[0].from == 0 && tags.tags[0].to == 3, "forward 0-3")
		testing.expect_value(t, tags.tags[1].direction, AsepriteDirection.Reverse)
		testing.expect_value(t, tags.tags[2].direction, AsepriteDirection.Ping_Pong)
	}
	testing.expect(t, Aseprite_FindTag(tags, "pingpong") != nil && Aseprite_FindTag(tags, "nope") == nil, "found by name")
	// Its linked cels have their pixels
	for frame in tags.frames do for cel in frame.cels do testing.expect(t, cel.pixels != nil, "a cel's pixels")
	columns, rows := Aseprite_SheetGrid(tags)
	testing.expect(t, columns == 4 && rows == 3, "12 frames on a 4 x 3 sheet")
	sheet, _, _ := Aseprite_SheetPixels(tags, context.temp_allocator)
	testing.expect_value(t, len(sheet), 4 * 4 * 3 * 4 * 4)
	// Every frame of the sheet is that frame
	frame5 := Aseprite_FramePixels(tags, 5, context.temp_allocator)
	for y in 0..<4 do for x in 0..<4 {
		testing.expect_value(t, pixelAt(sheet, 16, 4 + x, 4 + y), pixelAt(frame5, 4, x, y))
	}

	// Indexed: palette entry 3 is transparent in layers other than the background
	indexed := loadFixture(t, "bg-index-3.aseprite")
	if indexed == nil do return
	defer Aseprite_Destroy(indexed)
	testing.expect_value(t, indexed.colorMode, AsepriteColorMode.Indexed)
	testing.expect_value(t, indexed.transparentIndex, 3)
	pixels := Aseprite_FramePixels(indexed, 0, context.temp_allocator)
	clear, solid := 0, 0
	for p in 0..<16 do if pixels[p * 4 + 3] == 0 do clear += 1; else do solid += 1
	testing.expectf(t, clear > 0 && solid > 0, "index 3 is see-through, the rest isn't (%d clear, %d solid)", clear, solid)
	free_all(context.temp_allocator)
}

@(test)
aseprite_tilemaps_and_user_data :: proc(t: ^testing.T) {
	// A 2 x 2 tilemap of 2 x 2 tiles: the frame is the tiles drawn at the cel
	ase := loadFixture(t, "2x2tilemap2x2tile.aseprite")
	if ase == nil do return
	defer Aseprite_Destroy(ase)
	testing.expect_value(t, len(ase.tilesets), 1)
	testing.expect_value(t, ase.layers[0].type, AsepriteLayerType.Tilemap)
	testing.expect_value(t, ase.layers[0].tileset, 0)
	tileset := &ase.tilesets[0]
	testing.expect(t, tileset.tileWidth == 2 && tileset.tileHeight == 2 && tileset.count == 5, "5 tiles of 2 x 2")
	cel := Aseprite_Cel(ase, 0, 0)
	testing.expect(t, cel != nil && len(cel.tiles) == 4, "2 x 2 tiles")
	if cel != nil && len(cel.tiles) == 4 {
		frame := Aseprite_FramePixels(ase, 0, context.temp_allocator)
		for tile, i in cel.tiles {
			pixels := Aseprite_TilePixels(tileset, tile, context.temp_allocator)
			if pixels == nil do continue
			for y in 0..<2 do for x in 0..<2 {
				testing.expect_value(t, pixelAt(frame, ase.width, cel.x + (i % 2) * 2 + x, cel.y + (i / 2) * 2 + y), pixelAt(pixels, 2, x, y))
			}
		}
	}
	// A flipped tile reads its pixels mirrored
	flipped := Aseprite_TilePixels(tileset, 1 | ASEPRITE_TILE_FLIP_X, context.temp_allocator)
	plain := Aseprite_TilePixels(tileset, 1, context.temp_allocator)
	testing.expect_value(t, pixelAt(flipped, 2, 0, 0), pixelAt(plain, 2, 1, 0))
	testing.expect(t, Aseprite_TilePixels(tileset, 0, context.temp_allocator) == nil, "tile 0 is empty")

	// Grayscale and indexed tilemaps read too
	for name in ([]string{"3x2tilemap-grayscale.aseprite", "2x3tilemap-indexed.aseprite"}) {
		other := loadFixture(t, name)
		if other == nil do continue
		testing.expectf(t, len(other.tilesets) == 1 && other.tilesets[0].pixels != nil, "%s: its tileset", name)
		Aseprite_Destroy(other)
	}

	// User data of every kind
	props := loadFixture(t, "file-tests-props.aseprite")
	if props == nil do return
	defer Aseprite_Destroy(props)
	a, hasA := Aseprite_Property(props.userData, "a")
	testing.expect(t, hasA && a.(bool) == true, "a = true")
	b, _ := Aseprite_Property(props.userData, "b")
	testing.expect_value(t, b.(i64), 1)
	c, _ := Aseprite_Property(props.userData, "c")
	testing.expect_value(t, c.(string), "hi")
	testing.expect_value(t, len(props.slices), 2)
	testing.expect_value(t, len(props.tags), 1)

	// Slices with a key per frame
	moving := loadFixture(t, "slices-moving.aseprite")
	if moving == nil do return
	defer Aseprite_Destroy(moving)
	testing.expect_value(t, len(moving.slices[0].keys), 4)
	free_all(context.temp_allocator)
}

@(test)
aseprite_broken_files_are_errors :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("testdata/aseprite/file-tests-props.aseprite", context.temp_allocator)
	testing.expect(t, err == nil, "read it")
	if err != nil do return
	_, notAse := Aseprite_Parse(transmute([]u8)string("not an aseprite file at all, but long enough to be read as a header ......................................................................"))
	testing.expect_value(t, notAse, AsepriteError.Not_Aseprite)
	_, empty := Aseprite_Parse(nil)
	testing.expect(t, empty != .None, "empty")
	// Cut anywhere, or with bytes changed: an error or a file, never a crash
	for n in ([]int{0, 10, 127, 128, 140, 300, len(data) / 2, len(data) - 1}) {
		ase, _ := Aseprite_Parse(data[:n])
		if ase != nil do Aseprite_FramePixels(ase, 0, context.temp_allocator)
		Aseprite_Destroy(ase)
	}
	r := rand.create(7)
	context.random_generator = rand.default_random_generator(&r)
	damaged := make([]u8, len(data), context.temp_allocator)
	for _ in 0..<200 {
		copy(damaged, data)
		for _ in 0..<8 do damaged[128 + rand.int_max(len(data) - 128)] = u8(rand.int_max(256))
		ase, _ := Aseprite_Parse(damaged)
		if ase != nil do for f in 0..<len(ase.frames) do Aseprite_FramePixels(ase, f, context.temp_allocator)
		Aseprite_Destroy(ase)
	}
	free_all(context.temp_allocator)
}

// The strict inflater: stored blocks, sizes that don't match, a wrong checksum
@(test)
inflate_is_strict :: proc(t: ^testing.T) {
	// "hello" in one stored block: header, final stored block (5, ~5), the bytes, Adler-32
	stream := []u8{0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, 'h', 'e', 'l', 'l', 'o', 0x06, 0x2c, 0x02, 0x15}
	out, ok := Inflate_Exact(stream, 5, context.temp_allocator)
	testing.expect(t, ok && string(out) == "hello", "a stored block")
	_, longer := Inflate_Exact(stream, 6, context.temp_allocator)
	testing.expect(t, !longer, "it holds 5 bytes, not 6")
	_, shorter := Inflate_Exact(stream, 4, context.temp_allocator)
	testing.expect(t, !shorter, "nor 4")
	bad := slice.clone(stream, context.temp_allocator)
	bad[15] ~= 1
	_, sum := Inflate_Exact(bad, 5, context.temp_allocator)
	testing.expect(t, !sum, "a wrong checksum")
	_, cut := Inflate_Exact(stream[:10], 5, context.temp_allocator)
	testing.expect(t, !cut, "cut short")
	_, huge := Inflate_Exact(stream, 1 << 30, context.temp_allocator)
	testing.expect(t, !huge, "a size it can't hold isn't even allocated")
	free_all(context.temp_allocator)
}

// An Aseprite file is a texture like any image: its first frame, drawn pixel for pixel
@(test)
aseprite_files_are_textures :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(64, 64, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	rm := ResourceManager{renderer = renderer}
	defer {
		for path, texture in rm.textures {
			sdl.DestroyTexture(texture)
			delete(path)
		}
		delete(rm.textures)
	}
	path := "testdata/aseprite/z-order.aseprite"
	texture := ResourceManager_loadTexture(&rm, path)
	testing.expect(t, texture != nil, "loaded")
	if texture == nil do return
	testing.expect_value(t, ResourceManager_loadTexture(&rm, path), texture)
	w, h: f32
	sdl.GetTextureSize(texture, &w, &h)
	testing.expect(t, w == 7 && h == 15, "the sprite's size")
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 0)
	sdl.RenderClear(renderer)
	sdl.RenderTexture(renderer, texture, nil, &sdl.FRect{0, 0, w, h})
	sdl.FlushRenderer(renderer)
	ase := loadFixture(t, "z-order.aseprite")
	if ase == nil do return
	defer Aseprite_Destroy(ase)
	frame := Aseprite_FramePixels(ase, 0, context.temp_allocator)
	pixels := ([^]u8)(surface.pixels)
	for y in 0..<15 do for x in 0..<7 {
		want := pixelAt(frame, 7, x, y)
		if want[3] != 255 do continue
		got := pixels[int(y) * int(surface.pitch) + x * 4:][:4]
		testing.expectf(t, got[0] == want[0] && got[1] == want[1] && got[2] == want[2], "(%d, %d): %v, want %v", x, y, got, want)
	}
	free_all(context.temp_allocator)
}
