package crossfire

import "core:math"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

/*
Aseprite files (`.aseprite`, `.ase`; https://www.aseprite.org, the pixel art editor), read with
the published format (Aseprite's docs/ase-file-specs.md), so sprites, animations and tilemaps
drawn in Aseprite play in the engine.

`Aseprite_Load` / `Aseprite_Parse` read a file into plain data (`Aseprite`):
- **The sprite**: size, color mode (RGBA, grayscale or indexed: every image is turned into RGBA
  pixels here, through the palette for indexed ones), its grid and its user data.
- **Layers** in Aseprite's order, bottom first: image, group and tilemap layers, with their
  parent group (`parent`), visibility, opacity, blend mode and user data.
- **Frames** with their duration (milliseconds; each frame has its own) and **cels**: a layer's
  image in that frame (`pixels`, RGBA, at `x`, `y`), or a tilemap layer's tiles. Linked cels are
  copies of the cel they link to.
- **Tags** (named frame ranges: Aseprite's animations), with direction, repeats and color;
  **slices** with their keys (9-patch centers, pivots); **tilesets** (tile size, the tiles'
  pixels as one column of tiles, tile 0 the empty one, and each tile's user data).
- **User data**: text, a color and properties (`AsepriteValue`) of the sprite, layers, cels,
  tags, slices, tilesets and tiles. Only the user's own properties are kept (not extensions').

`Aseprite_FramePixels` composites a frame exactly as Aseprite exports it (checked byte for byte
against Aseprite 1.3.17's own exports: aseprite_matches_aseprite): Aseprite's render plan (layers
numbered in tree order, groups flattened unless the file says to composite them, sorted by number
plus each cel's z-index), hidden layers and those in hidden groups left out, reference layers too,
cel opacity times layer opacity, Aseprite's 19 blend modes with its integer arithmetic and its
default "new blending" (blend_funcs.cpp, ported), tilemap layers drawn from their tileset with each
tile's flips. Aseprite 1.3.17 never writes the compose-groups flag (its compose-groups preference
only changes its own canvas), so files are flattened as its exports are; the composited path, for
files that do set it, couldn't be checked against Aseprite.
`Aseprite_SheetPixels` lays every frame out on a grid (an animation's sheet). Textures from
Aseprite files use nearest filtering: they're pixel art.

Everything a file holds lives in its own arena: `Aseprite_Destroy` frees it all. Reading never
trusts the file: anything truncated or malformed is an error, not a crash.
*/

// What went wrong reading an Aseprite file
AsepriteError :: enum {
	None,
	// The file couldn't be read
	Unreadable,
	// Not an Aseprite file (its magic numbers are wrong)
	Not_Aseprite,
	// It ends early, or a chunk runs past its frame
	Truncated,
	// A compressed image didn't inflate to its size
	Bad_Image,
	// A color depth other than 8, 16 or 32 bits
	Unsupported_Depth,
	// Larger than the engine reads (16384 pixels across)
	Too_Large,
}

// The largest sprite, cel or tileset side the reader takes, in pixels or tiles
ASEPRITE_MAX_SIZE :: 16384

// A sprite's color mode
AsepriteColorMode :: enum {
	RGBA,
	Grayscale,
	Indexed,
}

// What a layer is
AsepriteLayerType :: enum {
	Image,
	Group,
	Tilemap,
}

// How a layer is blended onto the layers under it (Aseprite's order and names)
AsepriteBlendMode :: enum {
	Normal,
	Multiply,
	Screen,
	Overlay,
	Darken,
	Lighten,
	Color_Dodge,
	Color_Burn,
	Hard_Light,
	Soft_Light,
	Difference,
	Exclusion,
	Hue,
	Saturation,
	Color,
	Luminosity,
	Addition,
	Subtract,
	Divide,
}

// Which way a tag plays its frames
AsepriteDirection :: enum {
	Forward,
	Reverse,
	Ping_Pong,
	Ping_Pong_Reverse,
}

// A property's point value (`POINT`)
AsepritePoint :: distinct [2]i32
// A property's size value (`SIZE`)
AsepriteSize :: distinct [2]i32
// A property's rectangle value (`RECT`): x, y, width, height
AsepriteRect :: distinct [4]i32
// A property's UUID value
AsepriteUUID :: distinct [16]u8

/*
A property's value: integers of every size as i64, fixed point and floats as f64, vectors as
slices, nested maps as maps (all the file's arena).
*/
AsepriteValue :: union {
	bool,
	i64,
	f64,
	string,
	AsepritePoint,
	AsepriteSize,
	AsepriteRect,
	AsepriteUUID,
	[]AsepriteValue,
	map[string]AsepriteValue,
}

// User data Aseprite attaches to a sprite, layer, cel, tag, slice, tileset or tile
AsepriteUserData :: struct {
	// Its text ("" for none)
	text: string,
	// Its color, when `hasColor`
	color: [4]u8,
	// Whether it has a color
	hasColor: bool,
	// The user's properties by name (nil when none; extensions' properties aren't kept)
	properties: map[string]AsepriteValue,
}

// A layer (bottom first in `Aseprite.layers`; its index is the one cels refer to)
AsepriteLayer :: struct {
	// Its name
	name: string,
	// Image, group or tilemap
	type: AsepriteLayerType,
	// The group it's in (-1: the top level)
	parent: int,
	// Visible in Aseprite (its eye); a hidden group hides what it holds
	visible: bool,
	// Aseprite's background layer (opaque, at the bottom)
	background: bool,
	// A reference layer (never exported, so never drawn here)
	reference: bool,
	// How it's blended onto what's under it
	blendMode: AsepriteBlendMode,
	// Its opacity (255 when the file doesn't set layer opacity)
	opacity: u8,
	// A tilemap layer's tileset (index in `Aseprite.tilesets`; -1 for other layers)
	tileset: int,
	// Its user data
	userData: AsepriteUserData,
}

/*
A layer's content in one frame: an image (`pixels`, RGBA, `width` x `height` at `x`, `y` in the
sprite) or, on a tilemap layer, tiles (`tiles`, `width` x `height` tiles from `x`, `y`).
*/
AsepriteCel :: struct {
	// The layer (index in `Aseprite.layers`)
	layer: int,
	// Where its top-left corner is in the sprite, in pixels
	x, y: int,
	// Its size: pixels for images, tiles for tilemaps
	width, height: int,
	// Its opacity
	opacity: u8,
	// Moves it up (+) or down (-) among the layers in this frame (Aseprite's z-index)
	zIndex: int,
	// An image's pixels: RGBA, row by row (nil on tilemap layers)
	pixels: []u8,
	// A tilemap's tiles, row by row: each a tile index with flip bits (ASEPRITE_TILE_*)
	tiles: []u32,
	// Its user data
	userData: AsepriteUserData,
}

// A tile's index in its tileset: `tile & ASEPRITE_TILE_ID` (0 is the empty tile)
ASEPRITE_TILE_ID :: u32(0x1fffffff)
// The tile is mirrored left to right
ASEPRITE_TILE_FLIP_X :: u32(0x80000000)
// The tile is mirrored top to bottom
ASEPRITE_TILE_FLIP_Y :: u32(0x40000000)
// The tile's axes are swapped (a transpose; with the X or Y flip it makes the quarter turns)
ASEPRITE_TILE_FLIP_D :: u32(0x20000000)

// A frame: how long it shows, and its cels
AsepriteFrame :: struct {
	// Milliseconds
	duration: int,
	// The layers' cels in this frame (layers without one are empty)
	cels: []AsepriteCel,
}

// A tag: a named range of frames, which is how Aseprite names animations
AsepriteTag :: struct {
	// Its name ("run")
	name: string,
	// The first and last frame (inclusive)
	from, to: int,
	// Which way it plays
	direction: AsepriteDirection,
	// Times it plays (0: unspecified, which Aseprite plays forever in its UI and once when exporting)
	repeat: int,
	// Its color in Aseprite's timeline
	color: [4]u8,
	// Its user data
	userData: AsepriteUserData,
}

// A slice's shape from a frame on
AsepriteSliceKey :: struct {
	// The frame it applies from (to the next key, or the end)
	frame: int,
	// Its rectangle in the sprite: x, y, width, height (0 wide: hidden from this frame)
	bounds: [4]int,
	// A 9-patch slice's center, relative to `bounds` (when `Aseprite.slices[i].nineSlice`)
	center: [4]int,
	// Its pivot, relative to `bounds`' origin (when `Aseprite.slices[i].hasPivot`)
	pivot: [2]int,
}

// A slice: a named rectangle (a hitbox, a 9-patch, a pivot) over frames
AsepriteSlice :: struct {
	// Its name
	name: string,
	// It's a 9-patch (its keys have a center)
	nineSlice: bool,
	// Its keys have a pivot
	hasPivot: bool,
	// Its rectangle from frame to frame
	keys: []AsepriteSliceKey,
	// Its user data
	userData: AsepriteUserData,
}

// A tileset: same-sized tiles that tilemap layers place by index
AsepriteTileset :: struct {
	// The id tilemap layers refer to it by
	id: int,
	// Its name
	name: string,
	// A tile's size in pixels
	tileWidth, tileHeight: int,
	// How many tiles (tile 0, the empty one, included)
	count: int,
	// The number Aseprite shows for tile 1 (UI only; 1 by default)
	baseIndex: int,
	// The tiles' pixels, RGBA: one column, tile i at row `i * tileHeight` (nil for a tileset
	// kept in an external file)
	pixels: []u8,
	// An external tileset's file (from the external files chunk; "" when it's in this file)
	externalFile: string,
	// Each tile's user data (by index; shorter than `count` when the last tiles have none)
	tileUserData: []AsepriteUserData,
	// Its user data
	userData: AsepriteUserData,
}

/*
An Aseprite file, read by `Aseprite_Load` or `Aseprite_Parse`. Everything in it is in its arena
(`Aseprite_Destroy`).
*/
Aseprite :: struct {
	// The sprite's size in pixels
	width, height: int,
	// Its color mode in Aseprite (its pixels here are all RGBA)
	colorMode: AsepriteColorMode,
	// Its grid: x, y, width, height (width 0: no grid)
	grid: [4]int,
	// The palette, RGBA
	palette: [][4]u8,
	// Indexed sprites: the palette entry that's transparent in layers other than the background
	transparentIndex: int,
	// Layers, bottom first
	layers: []AsepriteLayer,
	// Frames, in order
	frames: []AsepriteFrame,
	// Tags (animations)
	tags: []AsepriteTag,
	// Slices
	slices: []AsepriteSlice,
	// Tilesets
	tilesets: []AsepriteTileset,
	// The sprite's own user data
	userData: AsepriteUserData,
	// Layer blend modes and opacity apply to groups too (composited apart first)
	groupBlending: bool,
	// Where everything lives
	arena: MemoryArena,
}

/*
Reads an Aseprite file through the platform layer (a data pack first, then the disk).

Inputs:
- path: The file

Returns:
- The file's data (free it with `Aseprite_Destroy`), or nil and what went wrong

Example:
	ase, err := e.Aseprite_Load("assets/hero.aseprite")
	if err == .None {
		defer e.Aseprite_Destroy(ase)
		for tag in ase.tags do e.Debug_Text(scene, {0, 0}, tag.name)
	}
*/
Aseprite_Load :: proc(path: string) -> (^Aseprite, AsepriteError) {
	data, ok := Platform_ReadFile(path)
	if !ok do return nil, .Unreadable
	return Aseprite_Parse(data)
}

/*
Reads an Aseprite file's bytes.

Inputs:
- data: The file's contents (not kept)

Returns:
- The file's data (free it with `Aseprite_Destroy`), or nil and what went wrong
*/
Aseprite_Parse :: proc(data: []u8) -> (^Aseprite, AsepriteError) {
	ase := new(Aseprite)
	if !MemoryArena_InitGrowing(&ase.arena) {
		free(ase)
		return nil, .Unreadable
	}
	err := parseAseprite(ase, data)
	if err != .None {
		Aseprite_Destroy(ase)
		return nil, err
	}
	return ase, .None
}

/*
Frees an Aseprite file's data and everything in it.

Inputs:
- ase: The file (nil does nothing)
*/
Aseprite_Destroy :: proc(ase: ^Aseprite) {
	if ase == nil do return
	MemoryArena_Destroy(&ase.arena)
	free(ase)
}

// Whether a path is an Aseprite file, by its extension (.aseprite or .ase, any case)
Aseprite_IsFile :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	return strings.has_suffix(lower, ".aseprite") || strings.has_suffix(lower, ".ase")
}

/*
A layer by name.

Inputs:
- ase: The file
- name: The layer's name

Returns:
- Its index in `ase.layers`, or -1
*/
Aseprite_FindLayer :: proc(ase: ^Aseprite, name: string) -> int {
	for layer, i in ase.layers do if layer.name == name do return i
	return -1
}

/*
A tag by name.

Inputs:
- ase: The file
- name: The tag's name

Returns:
- The tag, or nil
*/
Aseprite_FindTag :: proc(ase: ^Aseprite, name: string) -> ^AsepriteTag {
	for &tag in ase.tags do if tag.name == name do return &tag
	return nil
}

/*
A layer's cel in a frame.

Inputs:
- ase: The file
- frame: The frame's index
- layer: The layer's index

Returns:
- The cel, or nil when the layer is empty in that frame
*/
Aseprite_Cel :: proc(ase: ^Aseprite, frame, layer: int) -> ^AsepriteCel {
	if frame < 0 || frame >= len(ase.frames) do return nil
	for &cel in ase.frames[frame].cels do if cel.layer == layer do return &cel
	return nil
}

/*
Whether a layer is drawn: it's visible, so are the groups it's in, and it isn't a reference layer.

Inputs:
- ase: The file
- layer: The layer's index
*/
Aseprite_LayerShown :: proc(ase: ^Aseprite, layer: int) -> bool {
	for i := layer; i >= 0; i = ase.layers[i].parent {
		if !ase.layers[i].visible || ase.layers[i].reference do return false
	}
	return true
}

/*
A frame as Aseprite shows it: the shown layers composited bottom up (see the file's overview).

Inputs:
- ase: The file
- frame: The frame's index
- allocator: For the pixels
- layers: Only these layers (by index; nil: every shown layer). A listed layer is drawn even
  when hidden in Aseprite

Returns:
- RGBA pixels, `ase.width` x `ase.height`, row by row (all transparent for a frame out of range)
*/
Aseprite_FramePixels :: proc(ase: ^Aseprite, frame: int, allocator := context.allocator, layers: []int = nil) -> []u8 {
	out := make([]u8, ase.width * ase.height * 4, allocator)
	if frame < 0 || frame >= len(ase.frames) do return out
	composeGroup(ase, frame, -1, out, layers)
	return out
}

/*
Every frame on one picture: a grid of `columns` x `rows` cells of the sprite's size, frame `i`
at column `i % columns`, row `i / columns` (an animation's sheet).

Inputs:
- ase: The file
- allocator: For the pixels
- layers: As in `Aseprite_FramePixels`

Returns:
- RGBA pixels (`columns * ase.width` x `rows * ase.height`), and the grid's columns and rows
*/
Aseprite_SheetPixels :: proc(ase: ^Aseprite, allocator := context.allocator, layers: []int = nil) -> (pixels: []u8, columns, rows: int) {
	columns, rows = Aseprite_SheetGrid(ase)
	sheetWidth := columns * ase.width
	pixels = make([]u8, sheetWidth * rows * ase.height * 4, allocator)
	for f in 0..<len(ase.frames) {
		frame := Aseprite_FramePixels(ase, f, context.temp_allocator, layers)
		left, top := (f % columns) * ase.width, (f / columns) * ase.height
		for y in 0..<ase.height {
			copy(pixels[((top + y) * sheetWidth + left) * 4:][:ase.width * 4], frame[y * ase.width * 4:][:ase.width * 4])
		}
	}
	return
}

/*
The grid `Aseprite_SheetPixels` lays frames out on: about square, kept under ASEPRITE_MAX_SIZE.

Inputs:
- ase: The file

Returns:
- Columns and rows
*/
Aseprite_SheetGrid :: proc(ase: ^Aseprite) -> (columns, rows: int) {
	count := max(1, len(ase.frames))
	columns = max(1, int(math.ceil(math.sqrt(f64(count)))))
	if ase.width > 0 do columns = min(columns, max(1, ASEPRITE_MAX_SIZE / ase.width))
	rows = (count + columns - 1) / columns
	return
}

/*
A texture of a frame (or of every frame as a sheet), with nearest filtering.

Inputs:
- renderer: The renderer
- ase: The file
- frame: The frame (-1: the sheet of every frame, `Aseprite_SheetPixels`)

Returns:
- The texture (the caller's), or nil
*/
Aseprite_CreateTexture :: proc(renderer: ^sdl.Renderer, ase: ^Aseprite, frame := 0) -> ^sdl.Texture {
	pixels: []u8
	width, height := ase.width, ase.height
	if frame < 0 {
		columns, rows: int
		pixels, columns, rows = Aseprite_SheetPixels(ase, context.temp_allocator)
		width, height = columns * ase.width, rows * ase.height
	} else {
		pixels = Aseprite_FramePixels(ase, frame, context.temp_allocator)
	}
	if width <= 0 || height <= 0 do return nil
	surface := sdl.CreateSurfaceFrom(i32(width), i32(height), .RGBA32, raw_data(pixels), i32(width * 4))
	if surface == nil do return nil
	defer sdl.DestroySurface(surface)
	texture := sdl.CreateTextureFromSurface(renderer, surface)
	if texture != nil do sdl.SetTextureScaleMode(texture, .NEAREST)
	return texture
}

/*
A tile's pixels from a tileset, with the tile's flips applied.

Inputs:
- tileset: The tileset
- tile: The tile value (index and flip bits)
- allocator: For the pixels

Returns:
- RGBA pixels, `tileWidth` x `tileHeight` (a diagonal flip of a non-square tile is left out), or
  nil for the empty tile or an index past the tileset
*/
Aseprite_TilePixels :: proc(tileset: ^AsepriteTileset, tile: u32, allocator := context.allocator) -> []u8 {
	id := int(tile & ASEPRITE_TILE_ID)
	if id == 0 || id >= tileset.count || tileset.pixels == nil do return nil
	w, h := tileset.tileWidth, tileset.tileHeight
	out := make([]u8, w * h * 4, allocator)
	src := tileset.pixels[id * w * h * 4:][:w * h * 4]
	for y in 0..<h do for x in 0..<w {
		sx, sy := tileSource(tile, x, y, w, h)
		copy(out[(y * w + x) * 4:][:4], src[(sy * w + sx) * 4:][:4])
	}
	return out
}

/*
A user data's property, by name.

Inputs:
- data: The user data
- name: The property's name

Returns:
- The value, and whether it's there
*/
Aseprite_Property :: proc(data: AsepriteUserData, name: string) -> (AsepriteValue, bool) {
	if data.properties == nil do return nil, false
	value, ok := data.properties[name]
	return value, ok
}

// --- Compositing ---

// Where a tile's pixel (x, y) comes from in its tile image: the diagonal flip, then X, then Y
@(private="file")
tileSource :: proc(tile: u32, x, y, w, h: int) -> (int, int) {
	sx, sy := x, y
	if tile & ASEPRITE_TILE_FLIP_X != 0 do sx = w - 1 - sx
	if tile & ASEPRITE_TILE_FLIP_Y != 0 do sy = h - 1 - sy
	if tile & ASEPRITE_TILE_FLIP_D != 0 && w == h do sx, sy = sy, sx
	return sx, sy
}

// A layer to draw in a frame, in Aseprite's render plan: its place in the layer order, and its cel
@(private="file")
PlanItem :: struct {
	order, zIndex: int,
	layer: int,
	cel: ^AsepriteCel,
}

/*
The layers under `parent` (-1: the top level) in the order Aseprite draws them (its RenderPlan):
numbered in tree order (groups take a number too), flattened into their layers unless groups are
composited apart (the file's flag), then sorted by number + the cel's z-index (ties: the lower
z-index first); hidden ones (or, with `only`, those not listed) left out after sorting.
*/
@(private="file")
renderPlan :: proc(ase: ^Aseprite, frame, parent: int, only: []int) -> [dynamic]PlanItem {
	items := make([dynamic]PlanItem, context.temp_allocator)
	order := 0
	add :: proc(ase: ^Aseprite, frame, layer: int, order: ^int, items: ^[dynamic]PlanItem) {
		order^ += 1
		if ase.layers[layer].type == .Group && !ase.groupBlending {
			for child, i in ase.layers do if child.parent == layer do add(ase, frame, i, order, items)
			return
		}
		cel := Aseprite_Cel(ase, frame, layer)
		append(items, PlanItem{order = order^, zIndex = cel != nil ? cel.zIndex : 0, layer = layer, cel = cel})
	}
	for layer, i in ase.layers do if layer.parent == parent do add(ase, frame, i, &order, &items)
	hasZ := false
	for item in items do if item.zIndex != 0 do hasZ = true
	if hasZ {
		for &item in items do item.order += item.zIndex
		slice.stable_sort_by(items[:], proc(a, b: PlanItem) -> bool { return a.order < b.order || (a.order == b.order && a.zIndex < b.zIndex) })
	}
	kept := make([dynamic]PlanItem, context.temp_allocator)
	for item in items {
		if only != nil {
			if ase.layers[item.layer].type != .Group && !slice.contains(only, item.layer) do continue
		} else if !Aseprite_LayerShown(ase, item.layer) {
			continue
		}
		append(&kept, item)
	}
	return kept
}

// Composites the layers under `parent` (-1: the top level) onto `target`, as Aseprite renders them
@(private="file")
composeGroup :: proc(ase: ^Aseprite, frame, parent: int, target: []u8, only: []int) {
	for item in renderPlan(ase, frame, parent, only) {
		layer := &ase.layers[item.layer]
		switch layer.type {
		case .Group:
			// Composited apart (the file says so), then blended as one picture
			group := make([]u8, len(target), context.temp_allocator)
			composeGroup(ase, frame, item.layer, group, only)
			blendImage(target, ase.width, ase.height, group, 0, 0, ase.width, ase.height, layer.opacity, layer.blendMode)
		case .Image:
			cel := item.cel
			if cel == nil || cel.pixels == nil do continue
			blendImage(target, ase.width, ase.height, cel.pixels, cel.x, cel.y, cel.width, cel.height, mul8(cel.opacity, layer.opacity), layer.blendMode)
		case .Tilemap:
			cel := item.cel
			if cel == nil || cel.tiles == nil || layer.tileset < 0 || layer.tileset >= len(ase.tilesets) do continue
			tileset := &ase.tilesets[layer.tileset]
			for row in 0..<cel.height do for column in 0..<cel.width {
				pixels := Aseprite_TilePixels(tileset, cel.tiles[row * cel.width + column], context.temp_allocator)
				if pixels == nil do continue
				blendImage(target, ase.width, ase.height, pixels, cel.x + column * tileset.tileWidth, cel.y + row * tileset.tileHeight,
					tileset.tileWidth, tileset.tileHeight, mul8(cel.opacity, layer.opacity), layer.blendMode)
			}
		}
	}
}

// Aseprite's MUL_UN8 (pixman's): a * b / 255, rounded
@(private="file")
mulUn8 :: #force_inline proc(a, b: int) -> int {
	t := a * b + 0x80
	return ((t >> 8) + t) >> 8
}

// Aseprite's DIV_UN8: a * 255 / b, rounded
@(private="file")
divUn8 :: #force_inline proc(a, b: int) -> int {
	return (a * 0xff + b / 2) / b
}

@(private="file")
mul8 :: proc(a, b: u8) -> u8 {
	return u8(mulUn8(int(a), int(b)))
}

// Blends an image onto the target at (x, y), clipped to it
@(private="file")
blendImage :: proc(target: []u8, targetWidth, targetHeight: int, image: []u8, x, y, width, height: int, opacity: u8, mode: AsepriteBlendMode) {
	if opacity == 0 do return
	for row in max(0, -y)..<min(height, targetHeight - y) {
		for column in max(0, -x)..<min(width, targetWidth - x) {
			src := image[(row * width + column) * 4:][:4]
			// Aseprite skips the image's mask color (0: fully transparent black)
			if src[0] == 0 && src[1] == 0 && src[2] == 0 && src[3] == 0 do continue
			dst := target[((y + row) * targetWidth + x + column) * 4:][:4]
			out := blendPixel({int(dst[0]), int(dst[1]), int(dst[2]), int(dst[3])}, {int(src[0]), int(src[1]), int(src[2]), int(src[3])}, int(opacity), mode)
			dst[0], dst[1], dst[2], dst[3] = u8(out[0]), u8(out[1]), u8(out[2]), u8(out[3])
		}
	}
}

/*
A pixel blended as Aseprite blends it (its blend_funcs.cpp, with its default "new blending"):
normal is source over backdrop in integers; the other modes blend the colors, then mix that with
normal by the backdrop's alpha.
*/
@(private="file")
blendPixel :: proc(b, s: [4]int, opacity: int, mode: AsepriteBlendMode) -> [4]int {
	if mode == .Normal || b[3] == 0 do return blendNormal(b, s, opacity)
	normal := blendNormal(b, s, opacity)
	blend := blendNormal(b, {0, 0, 0, s[3]} + blendColor(b, s, mode), opacity)
	normalToBlend := blendMerge(normal, blend, b[3])
	srcTotalAlpha := mulUn8(s[3], opacity)
	return blendMerge(normalToBlend, blend, mulUn8(b[3], srcTotalAlpha))
}

// rgba_blender_normal
@(private="file")
blendNormal :: proc(b, s: [4]int, opacity: int) -> [4]int {
	if b[3] == 0 do return {s[0], s[1], s[2], mulUn8(s[3], opacity)}
	if s[3] == 0 do return b
	sa := mulUn8(s[3], opacity)
	ra := sa + b[3] - mulUn8(b[3], sa)
	return {b[0] + (s[0] - b[0]) * sa / ra, b[1] + (s[1] - b[1]) * sa / ra, b[2] + (s[2] - b[2]) * sa / ra, ra}
}

// rgba_blender_merge
@(private="file")
blendMerge :: proc(b, s: [4]int, opacity: int) -> [4]int {
	r: [4]int
	switch {
	case b[3] == 0: r.rgb = s.rgb
	case s[3] == 0: r.rgb = b.rgb
	case:
		for i in 0..<3 do r[i] = b[i] + mulUn8(s[i] - b[i], opacity)
	}
	r[3] = b[3] + mulUn8(s[3] - b[3], opacity)
	if r[3] == 0 do r.rgb = 0
	return r
}

// A blend mode's color (its alpha 0), from the backdrop's and the source's
@(private="file")
blendColor :: proc(b, s: [4]int, mode: AsepriteBlendMode) -> [4]int {
	#partial switch mode {
	case .Hue, .Saturation, .Color, .Luminosity:
		bf := [3]f64{f64(b[0]), f64(b[1]), f64(b[2])} / 255
		sf := [3]f64{f64(s[0]), f64(s[1]), f64(s[2])} / 255
		out: [3]f64
		#partial switch mode {
		case .Hue:        out = setLum(setSat(sf, sat(bf)), lum(bf))
		case .Saturation: out = setLum(setSat(bf, sat(sf)), lum(bf))
		case .Color:      out = setLum(sf, lum(bf))
		case .Luminosity: out = setLum(bf, lum(sf))
		}
		// Truncated, as Aseprite does
		return {int(255 * out[0]), int(255 * out[1]), int(255 * out[2]), 0}
	}
	r: [4]int
	for i in 0..<3 do r[i] = blendChannel(b[i], s[i], mode)
	return r
}

@(private="file")
blendChannel :: proc(b, s: int, mode: AsepriteBlendMode) -> int {
	multiply :: proc(b, s: int) -> int { return mulUn8(b, s) }
	screen :: proc(b, s: int) -> int { return b + s - mulUn8(b, s) }
	hardLight :: proc(b, s: int) -> int { return s < 128 ? multiply(b, s << 1) : screen(b, (s << 1) - 255) }
	#partial switch mode {
	case .Multiply:   return multiply(b, s)
	case .Screen:     return screen(b, s)
	case .Overlay:    return hardLight(s, b)
	case .Darken:     return min(b, s)
	case .Lighten:    return max(b, s)
	case .Color_Dodge:
		if b == 0 do return 0
		if b >= 255 - s do return 255
		return divUn8(b, 255 - s)
	case .Color_Burn:
		if b == 255 do return 255
		if 255 - b >= s do return 0
		return 255 - divUn8(255 - b, s)
	case .Hard_Light: return hardLight(b, s)
	case .Soft_Light:
		bf, sf := f64(b) / 255, f64(s) / 255
		d := bf <= 0.25 ? ((16 * bf - 12) * bf + 4) * bf : math.sqrt(bf)
		r := sf <= 0.5 ? bf - (1 - 2 * sf) * bf * (1 - bf) : bf + (2 * sf - 1) * (d - bf)
		return int(r * 255 + 0.5)
	case .Difference: return abs(b - s)
	case .Exclusion:
		t := mulUn8(b, s)
		return b + s - 2 * t
	case .Addition:   return min(b + s, 255)
	case .Subtract:   return max(b - s, 0)
	case .Divide:
		if b == 0 do return 0
		if b >= s do return 255
		return divUn8(b, s)
	}
	return s
}

@(private="file")
lum :: proc(c: [3]f64) -> f64 { return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2] }

@(private="file")
sat :: proc(c: [3]f64) -> f64 { return max(c[0], c[1], c[2]) - min(c[0], c[1], c[2]) }

// set_lum with clip_color
@(private="file")
setLum :: proc(c: [3]f64, l: f64) -> [3]f64 {
	out := c + (l - lum(c))
	l2 := lum(out)
	n := min(out[0], out[1], out[2])
	x := max(out[0], out[1], out[2])
	if n < 0 do out = l2 + ((out - l2) * l2) / (l2 - n)
	if x > 1 do out = l2 + ((out - l2) * (1 - l2)) / (x - l2)
	return out
}

@(private="file")
setSat :: proc(c: [3]f64, s: f64) -> [3]f64 {
	lo := min(c[0], c[1], c[2])
	range := max(c[0], c[1], c[2]) - lo
	if range > 0 do return ((c - lo) * s) / range
	return {0, 0, 0}
}

// --- Reading ---

@(private="file")
Reader :: struct {
	data: []u8,
	at: int,
	ok: bool,
}

@(private="file")
take :: proc(r: ^Reader, n: int) -> []u8 {
	if !r.ok || n < 0 || r.at + n > len(r.data) {
		r.ok = false
		return nil
	}
	out := r.data[r.at:][:n]
	r.at += n
	return out
}

@(private="file")
readU8 :: proc(r: ^Reader) -> u8 {
	b := take(r, 1)
	return b == nil ? 0 : b[0]
}

@(private="file")
readU16 :: proc(r: ^Reader) -> int {
	b := take(r, 2)
	return b == nil ? 0 : int(b[0]) | int(b[1]) << 8
}

@(private="file")
readI16 :: proc(r: ^Reader) -> int {
	return int(i16(u16(readU16(r))))
}

@(private="file")
readU32 :: proc(r: ^Reader) -> u32 {
	b := take(r, 4)
	return b == nil ? 0 : u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private="file")
readI32 :: proc(r: ^Reader) -> i32 {
	return i32(readU32(r))
}

@(private="file")
readU64 :: proc(r: ^Reader) -> u64 {
	low := u64(readU32(r))
	return low | u64(readU32(r)) << 32
}

@(private="file")
readString :: proc(r: ^Reader) -> string {
	n := readU16(r)
	b := take(r, n)
	return b == nil ? "" : strings.clone(string(b))
}

// Inflates a zlib stream to exactly `size` bytes (temp allocated; `Inflate_Exact`)
@(private="file")
inflate :: proc(compressed: []u8, size: int) -> ([]u8, bool) {
	if size == 0 do return nil, true
	return Inflate_Exact(compressed, size, context.temp_allocator)
}

// What the next user data chunk belongs to
@(private="file")
UserDataTarget :: enum {
	None,
	Sprite,
	Layer,
	Cel,
	Tag,
	Slice,
	Tileset,
	Tile,
}

@(private="file")
parseAseprite :: proc(ase: ^Aseprite, data: []u8) -> AsepriteError {
	context.allocator = MemoryArena_Allocator(&ase.arena)
	r := Reader{data = data, ok = true}

	// The header (128 bytes)
	_ = readU32(&r)
	if readU16(&r) != 0xA5E0 do return r.ok ? .Not_Aseprite : .Truncated
	frameCount := readU16(&r)
	ase.width, ase.height = readU16(&r), readU16(&r)
	depth := readU16(&r)
	flags := readU32(&r)
	speed := readU16(&r)
	take(&r, 8)
	ase.transparentIndex = int(readU8(&r))
	take(&r, 3)
	colorCount := readU16(&r)
	take(&r, 2)
	ase.grid = {readI16(&r), readI16(&r), readU16(&r), readU16(&r)}
	take(&r, 84)
	if !r.ok do return .Truncated
	switch depth {
	case 32: ase.colorMode = .RGBA
	case 16: ase.colorMode = .Grayscale
	case 8:  ase.colorMode = .Indexed
	case:    return .Unsupported_Depth
	}
	if ase.width > ASEPRITE_MAX_SIZE || ase.height > ASEPRITE_MAX_SIZE do return .Too_Large
	ase.groupBlending = flags & 2 != 0
	layerOpacity := flags & 1 != 0
	hasUUIDs := flags & 4 != 0
	bpp := depth / 8

	palette := make([dynamic][4]u8)
	resize(&palette, colorCount == 0 ? 256 : colorCount)
	for &c, i in palette do c = {u8(i), u8(i), u8(i), 255}
	newPalette := false
	layers := make([dynamic]AsepriteLayer)
	frames := make([dynamic]AsepriteFrame)
	tags := make([dynamic]AsepriteTag)
	slices := make([dynamic]AsepriteSlice)
	tilesets := make([dynamic]AsepriteTileset)
	externalFiles := make(map[u32]string)
	// Cels' raw pixels, converted to RGBA once the palette is known
	RawCel :: struct { frame, cel: int, data: []u8 }
	raw := make([dynamic]RawCel, context.temp_allocator)
	RawTileset :: struct { index: int, data: []u8 }
	rawTilesets := make([dynamic]RawTileset, context.temp_allocator)
	tileUserData := make(map[int][dynamic]AsepriteUserData, 0, context.temp_allocator)
	// Linked cels: their pixels are the linked cel's, once converted
	Link :: struct { frame, cel, from: int }
	links := make([dynamic]Link, context.temp_allocator)

	target := UserDataTarget.Sprite
	targetIndex := 0
	// Tags' user data come one per tag after the tags chunk; tiles' after their tileset's
	nextTag := 0

	for f in 0..<frameCount {
		frameStart := r.at
		frameSize := int(readU32(&r))
		if readU16(&r) != 0xF1FA do return r.ok ? .Not_Aseprite : .Truncated
		oldChunks := readU16(&r)
		duration := readU16(&r)
		take(&r, 2)
		newChunks := int(readU32(&r))
		if !r.ok do return .Truncated
		chunks := newChunks != 0 ? newChunks : oldChunks
		cels := make([dynamic]AsepriteCel)

		for _ in 0..<chunks {
			chunkStart := r.at
			chunkSize := int(readU32(&r))
			chunkType := readU16(&r)
			if !r.ok || chunkSize < 6 || chunkStart + chunkSize > len(data) do return .Truncated
			end := chunkStart + chunkSize
			c := Reader{data = data[:end], at = r.at, ok = true}

			switch chunkType {
			case 0x0004, 0x0011:
				// Old palettes: only without the new chunk
				target = .Sprite
				if newPalette do break
				packets := readU16(&c)
				index := 0
				for _ in 0..<packets {
					index += int(readU8(&c))
					count := int(readU8(&c))
					if count == 0 do count = 256
					for _ in 0..<count {
						rgb := [3]u8{readU8(&c), readU8(&c), readU8(&c)}
						if chunkType == 0x0011 do for &v in rgb do v = u8(min(255, int(v) * 255 / 63))
						if index >= len(palette) do resize(&palette, index + 1)
						palette[index] = {rgb[0], rgb[1], rgb[2], 255}
						index += 1
					}
				}
			case 0x2019:
				newPalette = true
				target = .Sprite
				size := int(readU32(&c))
				first, last := int(readU32(&c)), int(readU32(&c))
				take(&c, 8)
				if size > 65536 || last >= 65536 do break
				resize(&palette, max(size, last + 1))
				for i in first..=last {
					entryFlags := readU16(&c)
					palette[i] = {readU8(&c), readU8(&c), readU8(&c), readU8(&c)}
					if entryFlags & 1 != 0 do _ = readString(&c)
				}
			case 0x2004:
				layerFlags := readU16(&c)
				layer := AsepriteLayer{tileset = -1, parent = -1}
				switch readU16(&c) {
				case 1: layer.type = .Group
				case 2: layer.type = .Tilemap
				case:   layer.type = .Image
				}
				level := readU16(&c)
				take(&c, 4)
				mode := readU16(&c)
				layer.blendMode = mode < len(AsepriteBlendMode) ? AsepriteBlendMode(mode) : .Normal
				layer.opacity = readU8(&c)
				if !layerOpacity do layer.opacity = 255
				take(&c, 3)
				layer.name = readString(&c)
				if layer.type == .Tilemap do layer.tileset = int(readU32(&c))
				if hasUUIDs do take(&c, 16)
				layer.visible = layerFlags & 1 != 0
				layer.background = layerFlags & 8 != 0
				layer.reference = layerFlags & 64 != 0
				// Its group: the last layer read one level up
				if level > 0 {
					#reverse for other, i in layers do if other.type == .Group {
						if levelOf(layers[:], i) == level - 1 {
							layer.parent = i
							break
						}
					}
				}
				append(&layers, layer)
				target, targetIndex = .Layer, len(layers) - 1
			case 0x2005:
				cel := AsepriteCel{}
				cel.layer = readU16(&c)
				cel.x, cel.y = readI16(&c), readI16(&c)
				cel.opacity = readU8(&c)
				celType := readU16(&c)
				cel.zIndex = readI16(&c)
				take(&c, 5)
				switch celType {
				case 0, 2:
					cel.width, cel.height = readU16(&c), readU16(&c)
					if cel.width > ASEPRITE_MAX_SIZE || cel.height > ASEPRITE_MAX_SIZE do return .Too_Large
					size := cel.width * cel.height * bpp
					pixels: []u8
					ok: bool
					if celType == 0 {
						pixels = take(&c, size)
						ok = pixels != nil || size == 0
					} else {
						pixels, ok = inflate(data[c.at:end], size)
					}
					if !ok do return .Bad_Image
					append(&raw, RawCel{f, len(cels), pixels})
				case 1:
					// Linked: the same image and place as the layer's cel in another frame
					linked := readU16(&c)
					if linked < f do for other in frames[linked].cels do if other.layer == cel.layer {
						zIndex := cel.zIndex
						cel = other
						cel.zIndex = zIndex
						cel.userData = {}
						append(&links, Link{f, len(cels), linked})
					}
				case 3:
					cel.width, cel.height = readU16(&c), readU16(&c)
					if cel.width > ASEPRITE_MAX_SIZE || cel.height > ASEPRITE_MAX_SIZE do return .Too_Large
					bits := readU16(&c)
					idMask, xMask, yMask, dMask := readU32(&c), readU32(&c), readU32(&c), readU32(&c)
					take(&c, 10)
					tileBytes := bits / 8
					if !c.ok || (tileBytes != 1 && tileBytes != 2 && tileBytes != 4) do return .Bad_Image
					packed, ok := inflate(data[c.at:end], cel.width * cel.height * tileBytes)
					if !ok do return .Bad_Image
					cel.tiles = make([]u32, cel.width * cel.height)
					for &t, i in cel.tiles {
						v: u32
						for b in 0..<tileBytes do v |= u32(packed[i * tileBytes + b]) << u32(8 * b)
						t = v & idMask
						if v & xMask != 0 && xMask != 0 do t |= ASEPRITE_TILE_FLIP_X
						if v & yMask != 0 && yMask != 0 do t |= ASEPRITE_TILE_FLIP_Y
						if v & dMask != 0 && dMask != 0 do t |= ASEPRITE_TILE_FLIP_D
					}
				}
				if !c.ok do return .Truncated
				append(&cels, cel)
				target, targetIndex = .Cel, len(cels) - 1
			case 0x2008:
				count := int(readU32(&c))
				take(&c, 8)
				for _ in 0..<count {
					if !c.ok do break
					id := readU32(&c)
					_ = readU8(&c)
					take(&c, 7)
					externalFiles[id] = readString(&c)
				}
			case 0x2018:
				count := readU16(&c)
				take(&c, 8)
				nextTag = len(tags)
				for _ in 0..<count {
					tag := AsepriteTag{}
					tag.from, tag.to = readU16(&c), readU16(&c)
					direction := int(readU8(&c))
					tag.direction = direction < len(AsepriteDirection) ? AsepriteDirection(direction) : .Forward
					tag.repeat = readU16(&c)
					take(&c, 6)
					tag.color = {readU8(&c), readU8(&c), readU8(&c), 255}
					take(&c, 1)
					tag.name = readString(&c)
					if !c.ok do break
					append(&tags, tag)
				}
				target = .Tag
			case 0x2020:
				userData := readUserData(&c)
				switch target {
				case .None:
				case .Sprite:  ase.userData = userData
				case .Layer:   layers[targetIndex].userData = userData
				case .Cel:     cels[targetIndex].userData = userData
				case .Slice:   slices[targetIndex].userData = userData
				case .Tag:
					if nextTag < len(tags) {
						tags[nextTag].userData = userData
						// A color in the user data replaces the old one in the tag
						if userData.hasColor do tags[nextTag].color = userData.color
						nextTag += 1
					}
				case .Tileset:
					tilesets[targetIndex].userData = userData
					target = .Tile
				case .Tile:
					list := tileUserData[targetIndex]
					if list == nil do list = make([dynamic]AsepriteUserData, context.temp_allocator)
					append(&list, userData)
					tileUserData[targetIndex] = list
				}
			case 0x2022:
				keyCount := int(readU32(&c))
				sliceFlags := readU32(&c)
				take(&c, 4)
				s := AsepriteSlice{name = readString(&c), nineSlice = sliceFlags & 1 != 0, hasPivot = sliceFlags & 2 != 0}
				keys := make([dynamic]AsepriteSliceKey)
				for _ in 0..<keyCount {
					if !c.ok do break
					key := AsepriteSliceKey{frame = int(readU32(&c))}
					key.bounds = {int(readI32(&c)), int(readI32(&c)), int(readU32(&c)), int(readU32(&c))}
					if s.nineSlice do key.center = {int(readI32(&c)), int(readI32(&c)), int(readU32(&c)), int(readU32(&c))}
					if s.hasPivot do key.pivot = {int(readI32(&c)), int(readI32(&c))}
					append(&keys, key)
				}
				s.keys = keys[:]
				append(&slices, s)
				target, targetIndex = .Slice, len(slices) - 1
			case 0x2023:
				tileset := AsepriteTileset{}
				tileset.id = int(readU32(&c))
				tilesetFlags := readU32(&c)
				tileset.count = int(readU32(&c))
				tileset.tileWidth, tileset.tileHeight = readU16(&c), readU16(&c)
				tileset.baseIndex = readI16(&c)
				take(&c, 14)
				tileset.name = readString(&c)
				if tilesetFlags & 1 != 0 {
					file := readU32(&c)
					_ = readU32(&c)
					tileset.externalFile = externalFiles[file]
				}
				if tilesetFlags & 2 != 0 {
					length := int(readU32(&c))
					if !c.ok || length > end - c.at do return .Truncated
					if tileset.tileWidth > ASEPRITE_MAX_SIZE || tileset.tileHeight * tileset.count > ASEPRITE_MAX_SIZE * 64 do return .Too_Large
					pixels, ok := inflate(data[c.at:][:length], tileset.tileWidth * tileset.tileHeight * tileset.count * bpp)
					if !ok do return .Bad_Image
					append(&rawTilesets, RawTileset{len(tilesets), pixels})
				}
				if !c.ok do return .Truncated
				append(&tilesets, tileset)
				target, targetIndex = .Tileset, len(tilesets) - 1
			}
			r.at = end
		}
		append(&frames, AsepriteFrame{duration = duration > 0 ? duration : speed, cels = cels[:]})
		// The next frame starts where this one says it ends
		if frameSize >= 16 && frameStart + frameSize <= len(data) do r.at = frameStart + frameSize
	}

	ase.palette = palette[:]
	ase.layers = layers[:]
	ase.frames = frames[:]
	ase.tags = tags[:]
	ase.slices = slices[:]
	ase.tilesets = tilesets[:]
	// Cels on layers that don't exist would index past them
	for &frame in ase.frames {
		kept := make([dynamic]AsepriteCel)
		for cel in frame.cels do if cel.layer < len(ase.layers) do append(&kept, cel)
		frame.cels = kept[:]
	}

	// Pixels to RGBA, now that the palette is known
	for rc in raw {
		frame := &frames[rc.frame]
		if rc.cel >= len(frame.cels) do continue
		cel := &frame.cels[rc.cel]
		if cel.layer >= len(ase.layers) do continue
		cel.pixels = toRGBA(ase, rc.data, ase.layers[cel.layer].background)
	}
	// Linked cels copied their cel before its pixels were converted (in frame order, so a link to
	// a link finds the pixels already there)
	for link in links {
		cel := &frames[link.frame].cels[link.cel]
		for other in frames[link.from].cels do if other.layer == cel.layer do cel.pixels = other.pixels
	}
	for rt in rawTilesets do ase.tilesets[rt.index].pixels = toRGBA(ase, rt.data, false)
	for index, list in tileUserData do if index < len(ase.tilesets) {
		ase.tilesets[index].tileUserData = slice.clone(list[:])
	}
	// Tilemap layers refer to tilesets by id
	for &layer in ase.layers do if layer.type == .Tilemap {
		id := layer.tileset
		layer.tileset = -1
		for tileset, i in ase.tilesets do if tileset.id == id do layer.tileset = i
	}
	return .None
}

// A layer's child level: how many groups it's in
@(private="file")
levelOf :: proc(layers: []AsepriteLayer, index: int) -> int {
	level := 0
	for i := layers[index].parent; i >= 0; i = layers[i].parent do level += 1
	return level
}

// A cel's or tileset's pixels in the sprite's color mode, as RGBA (the file's arena)
@(private="file")
toRGBA :: proc(ase: ^Aseprite, data: []u8, background: bool) -> []u8 {
	switch ase.colorMode {
	case .RGBA:
		return slice.clone(data)
	case .Grayscale:
		out := make([]u8, len(data) * 2)
		for i in 0..<len(data) / 2 {
			v, a := data[i * 2], data[i * 2 + 1]
			out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = v, v, v, a
		}
		return out
	case .Indexed:
		out := make([]u8, len(data) * 4)
		for index, i in data {
			if !background && int(index) == ase.transparentIndex do continue
			c := int(index) < len(ase.palette) ? ase.palette[index] : [4]u8{0, 0, 0, 255}
			copy(out[i * 4:][:4], c[:])
		}
		return out
	}
	return nil
}

@(private="file")
readUserData :: proc(r: ^Reader) -> AsepriteUserData {
	data := AsepriteUserData{}
	flags := readU32(r)
	if flags & 1 != 0 do data.text = readString(r)
	if flags & 2 != 0 {
		data.color = {readU8(r), readU8(r), readU8(r), readU8(r)}
		data.hasColor = true
	}
	if flags & 4 != 0 {
		start := r.at
		size := int(readU32(r))
		maps := int(readU32(r))
		for _ in 0..<maps {
			if !r.ok do break
			key := readU32(r)
			properties := readProperties(r, 0)
			// The user's own; extensions' maps (key != 0) are skipped
			if key == 0 do data.properties = properties
		}
		if size >= 8 && start + size <= len(r.data) do r.at = start + size
	}
	return data
}

@(private="file")
readProperties :: proc(r: ^Reader, depth: int) -> map[string]AsepriteValue {
	count := int(readU32(r))
	properties := make(map[string]AsepriteValue)
	for _ in 0..<count {
		if !r.ok do break
		name := readString(r)
		type := readU16(r)
		properties[name] = readValue(r, type, depth)
	}
	return properties
}

@(private="file")
readValue :: proc(r: ^Reader, type: int, depth: int) -> AsepriteValue {
	if depth > 128 {
		r.ok = false
		return nil
	}
	switch type {
	case 0x01: return readU8(r) != 0
	case 0x02: return i64(i8(readU8(r)))
	case 0x03: return i64(readU8(r))
	case 0x04: return i64(readI16(r))
	case 0x05: return i64(readU16(r))
	case 0x06: return i64(readI32(r))
	case 0x07: return i64(readU32(r))
	case 0x08: return i64(readU64(r))
	case 0x09: return i64(readU64(r))
	case 0x0A: return f64(readI32(r)) / 65536
	case 0x0B: return f64(transmute(f32)readU32(r))
	case 0x0C: return transmute(f64)readU64(r)
	case 0x0D: return readString(r)
	case 0x0E: return AsepritePoint{readI32(r), readI32(r)}
	case 0x0F: return AsepriteSize{readI32(r), readI32(r)}
	case 0x10: return AsepriteRect{readI32(r), readI32(r), readI32(r), readI32(r)}
	case 0x11:
		count := int(readU32(r))
		elementType := readU16(r)
		if count > len(r.data) {
			r.ok = false
			return nil
		}
		values := make([]AsepriteValue, count)
		for &v in values {
			if !r.ok do break
			t := elementType
			if t == 0 do t = readU16(r)
			v = readValue(r, t, depth + 1)
		}
		return values
	case 0x12: return readProperties(r, depth + 1)
	case 0x13:
		uuid: AsepriteUUID
		if b := take(r, 16); b != nil do copy(uuid[:], b)
		return uuid
	}
	// An unknown type: nothing after it can be read
	r.ok = false
	return nil
}
