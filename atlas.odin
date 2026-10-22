package crossfire

import "core:encoding/xml"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
Texture atlases: many small images packed into one picture, so the game loads one texture and
draws them all from it (fewer textures to switch between, one file to ship).

An atlas is an asset of kind "Atlas", a `.atlas.xml` file beside its packed picture:

	<atlas formatVersion="13" image="atlases/items.png" filter="Pixel" padding="2">
		<region name="coin" source="assets/coin.png" x="0" y="0" w="16" h="16"/>
		<region name="gem" source="assets/gem.png" x="18" y="0" w="12" h="20"/>
	</atlas>

- **Packing** is `Atlas_Pack` (rectangles of the images' sizes into the smallest power-of-two
  picture, tallest first along shelves, `padding` pixels apart); editors pack the pixels and
  write both files (the Crossfire Editor's atlas inspector: Pack).
- **Using one:** a Sprite whose `texture` is the atlas file and `region` a region's name draws
  that region (scene files: `<node kind="Sprite" texture="atlases/items.atlas.xml"
  region="coin"/>`). From code: `Sprite_SetRegion(sprite, ATLAS_ITEMS, "coin")`, or
  `Game_AtlasRegion` for the texture and the rectangle to draw with `DrawTexture`.
- `Game_LoadAtlas` reads each file once (`Game.atlases`, the game's arena; editors put theirs
  there before building, like animation sets). The picture is an ordinary texture of the
  resource manager, filtered as the atlas says.
*/

// An atlas file's extension
ATLAS_EXTENSION :: ".atlas.xml"
// The largest picture `Atlas_Pack` makes, each way
ATLAS_MAX_SIZE :: 8192

// An atlas: its packed picture and the regions in it (`ParseAtlas`)
AtlasData :: struct {
	// The packed picture, relative to the project folder
	image: string,
	// How it's filtered (asset_import.odin; Default: the project's)
	filter: TextureFilter,
	// Pixels between regions (packing)
	padding: int,
	// The regions, in the order they were packed
	regions: [dynamic]AtlasRegion,
}

// One image packed into an atlas
AtlasRegion :: struct {
	// What code and scene files call it (unique in the atlas)
	name: string,
	// The image it was packed from, relative to the project folder (for packing it again)
	source: string,
	// Where it is in the picture: x, y, width, height in pixels
	rect: [4]int,
}

// Whether a path is an atlas file
Atlas_IsFile :: proc(path: string) -> bool {
	return strings.has_suffix(strings.to_lower(path, context.temp_allocator), ATLAS_EXTENSION)
}

/*
Reads an atlas file.

Inputs:
- text: The file's contents
- allocator: For the atlas's strings and regions

Returns:
- The atlas (free with `AtlasData_Destroy`), or an error
*/
ParseAtlas :: proc(text: string, allocator := context.allocator) -> (AtlasData, ProjectError) {
	doc, err := xml.parse_string(text)
	if err != .None do return {}, .Invalid_XML
	defer xml.destroy(doc)
	if doc.element_count == 0 || doc.elements[0].ident != "atlas" do return {}, .Invalid_XML
	atlas := AtlasData{regions = make([dynamic]AtlasRegion, allocator)}
	for a in doc.elements[0].attribs {
		switch a.key {
		case "formatVersion":
			if v, ok := strconv.parse_int(a.val); ok && v > PROJECT_FORMAT_VERSION {
				AtlasData_Destroy(&atlas, allocator)
				return {}, .Unsupported_Version
			}
		case "image":   atlas.image = strings.clone(a.val, allocator)
		case "padding": atlas.padding = strconv.parse_int(a.val) or_else 0
		case "filter":
			for f in TextureFilter do if fmt.tprint(f) == a.val do atlas.filter = f
		}
	}
	for child in doc.elements[0].value {
		id, isElement := child.(xml.Element_ID)
		if !isElement || doc.elements[id].ident != "region" do continue
		region: AtlasRegion
		for a in doc.elements[id].attribs {
			switch a.key {
			case "name":   region.name = strings.clone(a.val, allocator)
			case "source": region.source = strings.clone(a.val, allocator)
			case "x":      region.rect[0] = strconv.parse_int(a.val) or_else 0
			case "y":      region.rect[1] = strconv.parse_int(a.val) or_else 0
			case "w":      region.rect[2] = strconv.parse_int(a.val) or_else 0
			case "h":      region.rect[3] = strconv.parse_int(a.val) or_else 0
			}
		}
		append(&atlas.regions, region)
	}
	return atlas, .None
}

/*
Writes an atlas file.

Inputs:
- atlas: The atlas
- allocator: For the text

Returns:
- The file's text
*/
FormatAtlas :: proc(atlas: AtlasData, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, `<atlas formatVersion="%d" image="%s"`, PROJECT_FORMAT_VERSION, atlasEscape(atlas.image))
	if atlas.filter != .Default do fmt.sbprintf(&b, ` filter="%v"`, atlas.filter)
	if atlas.padding != 0 do fmt.sbprintf(&b, ` padding="%d"`, atlas.padding)
	strings.write_string(&b, ">\n")
	for r in atlas.regions {
		fmt.sbprintf(&b, "\t<region name=\"%s\" source=\"%s\" x=\"%d\" y=\"%d\" w=\"%d\" h=\"%d\"/>\n",
			atlasEscape(r.name), atlasEscape(r.source), r.rect[0], r.rect[1], r.rect[2], r.rect[3])
	}
	strings.write_string(&b, "</atlas>\n")
	return strings.to_string(b)
}

// A copy of an atlas (in `allocator`)
AtlasData_Clone :: proc(atlas: AtlasData, allocator := context.allocator) -> AtlasData {
	copy := AtlasData{image = strings.clone(atlas.image, allocator), filter = atlas.filter, padding = atlas.padding, regions = make([dynamic]AtlasRegion, 0, len(atlas.regions), allocator)}
	for r in atlas.regions do append(&copy.regions, AtlasRegion{strings.clone(r.name, allocator), strings.clone(r.source, allocator), r.rect})
	return copy
}

// Frees what `ParseAtlas` or `AtlasData_Clone` made
AtlasData_Destroy :: proc(atlas: ^AtlasData, allocator := context.allocator) {
	delete(atlas.image, allocator)
	for r in atlas.regions {
		delete(r.name, allocator)
		delete(r.source, allocator)
	}
	delete(atlas.regions)
	atlas^ = {}
}

// Whether two atlases are the same
AtlasData_Equal :: proc(a, b: AtlasData) -> bool {
	if a.image != b.image || a.filter != b.filter || a.padding != b.padding || len(a.regions) != len(b.regions) do return false
	for r, i in a.regions do if r != b.regions[i] do return false
	return true
}

/*
A region of an atlas by name.

Returns:
- The region, and whether the atlas has it
*/
Atlas_Find :: proc(atlas: ^AtlasData, name: string) -> (AtlasRegion, bool) {
	if atlas == nil do return {}, false
	for r in atlas.regions do if r.name == name do return r, true
	return {}, false
}

/*
Packs rectangles into the smallest picture that holds them: power-of-two sides (the narrower
side first tried as wide as the wider), the tallest rectangles first, left to right along
shelves, `padding` pixels apart.

Inputs:
- sizes: Each rectangle's width and height
- padding: Pixels between rectangles (and none at the picture's edges)
- maxSize: The largest side allowed (ATLAS_MAX_SIZE when 0)

Returns:
- Each rectangle's x and y (same order as `sizes`; temp allocated), the picture's size, and
  false when they don't fit in `maxSize`
*/
Atlas_Pack :: proc(sizes: [][2]int, padding := 0, maxSize := 0) -> (positions: [][2]int, size: [2]int, ok: bool) {
	limit := maxSize > 0 ? maxSize : ATLAS_MAX_SIZE
	positions = make([][2]int, len(sizes), context.temp_allocator)
	if len(sizes) == 0 do return positions, {1, 1}, true
	order := make([]int, len(sizes), context.temp_allocator)
	for i in 0..<len(sizes) do order[i] = i
	// Tallest first, then widest (a stable order for equal ones)
	context.user_ptr = raw_data(sizes)
	slice.sort_by(order, proc(a, b: int) -> bool {
		s := ([^][2]int)(context.user_ptr)
		if s[a].y != s[b].y do return s[a].y > s[b].y
		if s[a].x != s[b].x do return s[a].x > s[b].x
		return a < b
	})
	area, widest := 0, 0
	for s in sizes {
		area += (s.x + padding) * (s.y + padding)
		widest = max(widest, s.x)
	}
	// Candidate pictures, smallest area first: w x h with h in {w / 2, w, w * 2}
	for side := 1; side <= limit; side *= 2 {
		for candidate in ([3][2]int{{side, side / 2}, {side, side}, {side / 2, side}}) {
			if candidate.x < 1 || candidate.y < 1 || candidate.x > limit || candidate.y > limit do continue
			if candidate.x * candidate.y < area / 2 || candidate.x < widest do continue
			if shelfPack(sizes, order, padding, candidate, positions) do return positions, candidate, true
		}
	}
	return positions, {}, false
}

/*
An atlas, read once per game (`Game.atlases`): the file relative to the project folder.

Returns:
- The atlas (the game's; nil when it can't be read, logged), and whether it was read
*/
Game_LoadAtlas :: proc(game: ^Game, path: string) -> (^AtlasData, bool) {
	return atlasLoad(game, game.projectDir, path)
}

/*
An atlas region's picture and where it is in it, to draw with `DrawTexture(..., src = rect)`.

Inputs:
- game: The game
- atlas: The atlas file, relative to the project folder (`ATLAS_X` in scripts/assets.odin)
- name: The region

Returns:
- The texture, the region's rectangle in it, and whether the atlas has the region
*/
Game_AtlasRegion :: proc(game: ^Game, atlas: string, name: string) -> (^sdl.Texture, sdl.FRect, bool) {
	return atlasRegion(game, game.projectDir, atlas, name)
}

/*
Makes a Sprite draw a region of an atlas (its size the region's).

Inputs:
- sprite: The Sprite
- atlas: The atlas file, relative to the project folder
- name: The region

Returns:
- false (the sprite unchanged, logged) when the atlas has no such region

Example:
	// Given: sprite: ^e.Sprite
	e.Sprite_SetRegion(sprite, "atlases/items.atlas.xml", "coin")
*/
Sprite_SetRegion :: proc(sprite: ^Sprite, atlas: string, name: string) -> bool {
	texture, rect, ok := Game_AtlasRegion(sprite.scene.game, atlas, name)
	if !ok {
		log.warnf("%s has no region %s", atlas, name)
		return false
	}
	sprite.texture = texture
	sprite.region = rect
	return true
}

// INTERNAL

// Reads an atlas through a project folder (the build's, which editors' preview games have apart
// from game.projectDir), and sets its picture's filtering before the texture loads
@(private)
atlasLoad :: proc(game: ^Game, projectDir: string, path: string) -> (^AtlasData, bool) {
	if atlas, found := game.atlases[path]; found do return atlas, atlas != nil
	allocator := Game_GetAllocator(game)
	if game.atlases == nil do game.atlases = make(map[string]^AtlasData, allocator)
	full := JoinPath(projectDir, path)
	atlas: ^AtlasData
	if text, read := Platform_ReadFile(full); !read {
		log.errorf("Couldn't read the atlas %s", full)
	} else if parsed, err := ParseAtlas(string(text), allocator); err != .None {
		log.errorf("Couldn't load the atlas %s: %v", full, err)
	} else {
		atlas = new_clone(parsed, allocator)
	}
	game.atlases[strings.clone(path, allocator)] = atlas
	if atlas != nil && atlas.filter != .Default {
		ResourceManager_SetTextureFilter(&game.resourceManager, JoinPath(projectDir, atlas.image), atlas.filter)
	}
	return atlas, atlas != nil
}

@(private)
atlasRegion :: proc(game: ^Game, projectDir: string, atlasPath: string, name: string) -> (^sdl.Texture, sdl.FRect, bool) {
	atlas, ok := atlasLoad(game, projectDir, atlasPath)
	if !ok do return nil, {}, false
	region, found := Atlas_Find(atlas, name)
	if !found do return nil, {}, false
	texture := game.resourceManager->loadTexture(JoinPath(projectDir, atlas.image))
	r := region.rect
	return texture, {f32(r[0]), f32(r[1]), f32(r[2]), f32(r[3])}, texture != nil
}

// Places rectangles along shelves in a picture of `size`; false when they don't fit
@(private="file")
shelfPack :: proc(sizes: [][2]int, order: []int, padding: int, size: [2]int, positions: [][2]int) -> bool {
	x, y, shelf := 0, 0, 0
	for i in order {
		s := sizes[i]
		if s.x > size.x do return false
		if x > 0 && x + s.x > size.x {
			x = 0
			y += shelf + padding
			shelf = 0
		}
		if y + s.y > size.y do return false
		positions[i] = {x, y}
		x += s.x + padding
		shelf = max(shelf, s.y)
	}
	return true
}

@(private="file")
atlasEscape :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in text {
		switch r {
		case '&': strings.write_string(&b, "&amp;")
		case '"': strings.write_string(&b, "&quot;")
		case '<': strings.write_string(&b, "&lt;")
		case '>': strings.write_string(&b, "&gt;")
		case: strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}
