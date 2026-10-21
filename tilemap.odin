package crossfire

import "core:encoding/base64"
import "core:fmt"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

/*
TileMap nodes: the tilemap layers of an Aseprite file in a scene. This is the start of the
engine's tilemaps, and it takes **Aseprite's model as its own**: a tileset is tiles of one size,
tile 0 the empty one; a tilemap layer is a grid of 32-bit tile values, the tile's index in its
tileset (`ASEPRITE_TILE_ID`) with flip bits (`ASEPRITE_TILE_FLIP_X`, `_Y`, `_D`); tiles carry user
data properties. Painting tilemaps in the editor will write the same data.

	<node kind="TileMap" name="Ground" tilemap="assets/level.aseprite" layers="Ground,Walls"/>

- **Settings** (`TileMapSettings`): the file, the frame its tilemaps are taken from (`frame`), the
  tilemap layers built (`layers`, names separated by commas; none: every visible one), and
  `tileCollision` (default on).
- **What it builds:** a `TileMapLayer` child per tilemap layer, bottom first, at its cel's place,
  drawn in one batch (tile_batch.odin) with the layer's and cel's opacity; layers hidden in
  Aseprite are left out unless named.
- **Collision from the tiles' properties** (set in Aseprite: a tile's Properties, or the
  tileset's for every tile of it): `collision` = "solid", "one-way" or "area" (`solid` = true is
  solid too); an `area` property names the Area its tiles go in (and makes them area tiles).
  Solid and one-way tiles become one StaticBody, "Collision", their rectangles merged (one-way
  shapes have `oneWay`); area tiles an Area per name ("Area" without one). The bodies get the
  node's `collisionLayer`, `collisionMask`, `friction` and `restitution`.
- **Animated** (`animate`, `tag`): it plays the file's frames (or a tag's) at their durations,
  each layer showing its cel in that frame (water, torches); collision stays on `frame`'s tiles,
  so bodies aren't rebuilt as it plays.
- **Code:** `TileMap_TileAt` (the tile under a point), `TileMap_CellAt` (the cell),
  `TileMap_TileProperty`, `TileMap_TileCollision`, and `TileMap_SetTile` (a broken block, a door:
  drawn at once, an animated layer in every frame; its bodies rebuilt on the next update, so a
  script holding one of them must look it up again).
- **Development runs** (`Game.devKeys`) read a saved file again and rebuild the node's layers and
  collision (twice a second).
*/

// A TileMap node's settings (scene files' attributes)
TileMapSettings :: struct {
	// `tilemap`: the Aseprite file, relative to the project folder
	file: string,
	// `frame`: the frame its tilemaps come from
	frame: int,
	// `layers`: the tilemap layers built, by name, separated by commas ("": every visible one)
	layers: string,
	// `tileCollision`: tiles with collision properties become bodies (default true)
	collision: bool,
	// `animate`: plays the file's frames (or `tag`'s) at their durations; collision stays on
	// `frame`'s tiles
	animate: bool,
	// `tag`: the tag it plays ("": every frame)
	tag: string,
	// `<tiles>` children: layers painted in the editor (or by code), each replacing the file's
	// tilemap layer of its name, or a new layer on one of the file's tilesets (format 13)
	painted: [dynamic]TileLayerData,
}

/*
A tilemap layer painted in the editor, kept in the scene file:

	<tiles layer="Ground" tileset="0" x="0" y="0" columns="40" rows="12" data="AQAAAAEAAAA..."/>

`data` is the tile values (Aseprite's: `ASEPRITE_TILE_ID` with the flip bits), row by row, as
little-endian 32-bit numbers in base64 (`TileLayer_Encode`). A layer named like one of the file's
tilemap layers replaces its tiles in every frame (the file's layer keeps its tileset, opacity and
place among the others); any other name is a new layer, drawn over the file's, on the file's
tileset `tileset` (an index in `Aseprite.tilesets`).
*/
TileLayerData :: struct {
	// The layer's name
	layer: string,
	// A new layer's tileset (index in the file's tilesets)
	tileset: int,
	// Its top-left corner, in pixels (in the TileMap node's space)
	x, y: int,
	// Its grid's size in tiles
	columns, rows: int,
	// The tile values, row by row (columns * rows)
	tiles: [dynamic]u32,
}

/*
Tile values as the scene file's `data`: little-endian 32-bit numbers in base64.

Inputs:
- tiles: The tile values
- allocator: For the text

Returns:
- The text
*/
TileLayer_Encode :: proc(tiles: []u32, allocator := context.allocator) -> string {
	raw := make([]u8, len(tiles) * 4, context.temp_allocator)
	for t, i in tiles do raw[i * 4], raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3] = u8(t), u8(t >> 8), u8(t >> 16), u8(t >> 24)
	text, _ := base64.encode(raw, allocator = allocator)
	return text
}

/*
A scene file's `data` as tile values (`TileLayer_Encode`'s inverse).

Inputs:
- text: The base64 text
- count: How many tiles it should hold (columns * rows)
- allocator: For the tiles

Returns:
- The tiles (always `count` of them: missing ones empty), and false when the text is damaged
*/
TileLayer_Decode :: proc(text: string, count: int, allocator := context.allocator) -> ([dynamic]u32, bool) {
	tiles := make([dynamic]u32, max(count, 0), allocator)
	raw, err := base64.decode(text, allocator = context.temp_allocator)
	if err != nil do return tiles, false
	for i in 0..<min(count, len(raw) / 4) {
		tiles[i] = u32(raw[i * 4]) | u32(raw[i * 4 + 1]) << 8 | u32(raw[i * 4 + 2]) << 16 | u32(raw[i * 4 + 3]) << 24
	}
	return tiles, len(raw) == count * 4
}

// Frees a painted layer's strings and tiles
TileLayerData_Destroy :: proc(layer: ^TileLayerData, allocator := context.allocator) {
	delete(layer.layer, allocator)
	delete(layer.tiles)
	layer^ = {}
}

// A copy of a painted layer (owning its name and tiles)
TileLayerData_Clone :: proc(layer: TileLayerData, allocator := context.allocator) -> TileLayerData {
	copy := layer
	copy.layer = strings.clone(layer.layer, allocator)
	copy.tiles = make([dynamic]u32, len(layer.tiles), allocator)
	for t, i in layer.tiles do copy.tiles[i] = t
	return copy
}

// Whether two painted layers are the same
TileLayerData_Equal :: proc(a, b: TileLayerData) -> bool {
	if a.layer != b.layer || a.tileset != b.tileset || a.x != b.x || a.y != b.y || a.columns != b.columns || a.rows != b.rows || len(a.tiles) != len(b.tiles) do return false
	for t, i in a.tiles do if t != b.tiles[i] do return false
	return true
}

// A TileMap node's settings by default
DEFAULT_TILEMAP_SETTINGS :: TileMapSettings{collision = true}

// What a tile becomes in the physics world (`TileMap_TileCollision`)
TileCollisionKind :: enum {
	None,
	Solid,
	One_Way,
	Area,
}

// A TileMap node: its layers and collision are its children
TileMapNode :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Its settings (strings in the node's arena)
	settings: TileMapSettings,
	// The file as read (its own: freed with the node)
	ase: ^Aseprite,
	// The project folder its path is relative to (node arena)
	projectDir: string,
	// The physics settings its bodies get
	physics: TileMapPhysics,
	// The file's time when read, and seconds to the next look (development runs)
	modified: i64,
	watchTimer: f64,
	// The nodes it made (layers, bodies), replaced when the file is read again
	built: [dynamic]^Node,
	// Its tile layers, bottom first
	tileLayers: [dynamic]^TileMapLayer,
	// Its bodies (rebuilt when `TileMap_SetTile` changes collision: `collisionDirty`)
	bodies: [dynamic]^Node,
	collisionDirty: bool,
	// The file's frames it plays (`animate`: every frame, or its tag's; else just `frame`), the one
	// showing (index in `frames`) and how long it has shown
	frames: []int,
	shown: int,
	clock: f64,
	// Files replaced by rebuilds: freed once their layers are gone (the next update)
	retired: [dynamic]^Aseprite,
}

// The physics settings a TileMap's bodies get (the node's)
TileMapPhysics :: struct {
	layer, mask: u64,
	friction, restitution: f32,
}

// A tilemap layer of a TileMap node, drawn in one batch
TileMapLayer :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Its tiles
	using batch: TileBatch,
	// The layer in the file (index in `Aseprite.layers`), and its name
	layerIndex: int,
	layerName: string,
	// Its grid as it shows now: tiles across and down, and the tile values (the file's)
	cells: [2]int,
	tiles: []u32,
	// The tileset (in the file)
	tileset: ^AsepriteTileset,
	// Its cel in the TileMap's `frame`: what collision comes from (nil when it has none there)
	base: ^AsepriteCel,
	// Its cel and tiles in each frame the TileMap plays (by index in `TileMapNode.frames`)
	frames: []TileMapLayerFrame,
	// The layer's and its cels' opacity
	opacity: u8,
}

// A layer's cel in one frame, and its tiles to draw (filled in place: never more than its cells)
TileMapLayerFrame :: struct {
	cel: ^AsepriteCel,
	quads: [dynamic]TileQuad,
}

/*
A tile's collision: its own properties, else its tileset's (see the file's overview).

Inputs:
- tileset: The tileset
- tile: The tile value (its index; flips don't matter)

Returns:
- What it becomes, and an area tile's Area name ("" for the default)
*/
TileMap_TileCollision :: proc(tileset: ^AsepriteTileset, tile: u32) -> (kind: TileCollisionKind, area: string) {
	id := int(tile & ASEPRITE_TILE_ID)
	if id == 0 do return .None, ""
	from :: proc(data: AsepriteUserData) -> (kind: TileCollisionKind, area: string, found: bool) {
		if name, ok := Aseprite_Property(data, "area"); ok {
			if text, isText := name.(string); isText do return .Area, text, true
		}
		if value, ok := Aseprite_Property(data, "collision"); ok {
			text, _ := value.(string)
			switch strings.to_lower(text, context.temp_allocator) {
			case "solid":                          return .Solid, "", true
			case "one-way", "oneway", "one_way":   return .One_Way, "", true
			case "area":                           return .Area, "", true
			case "none", "":                       return .None, "", true
			}
		}
		if value, ok := Aseprite_Property(data, "solid"); ok {
			if solid, isBool := value.(bool); isBool do return solid ? .Solid : .None, "", true
		}
		return .None, "", false
	}
	if id < len(tileset.tileUserData) {
		if k, a, found := from(tileset.tileUserData[id]); found do return k, a
	}
	k, a, _ := from(tileset.userData)
	return k, a
}

/*
The tile under a point of the world, in a layer of a TileMap.

Inputs:
- node: The TileMap
- layer: The layer's name ("": the top-most layer with a tile there)
- position: A point in the world

Returns:
- The tile value (0: empty), its layer, and false when the point is off every grid
*/
TileMap_TileAt :: proc(node: ^TileMapNode, layer: string, position: [2]f32) -> (tile: u32, at: ^TileMapLayer, ok: bool) {
	#reverse for l in node.tileLayers {
		if layer != "" && l.layerName != layer do continue
		local := Transform2D_Apply(Transform2D_Inverse(Node_GetWorldTransform(l)), position)
		column, row := int(local.x / l.tileSize.x), int(local.y / l.tileSize.y)
		if local.x < 0 || local.y < 0 || column >= l.cells.x || row >= l.cells.y do continue
		t := l.tiles[row * l.cells.x + column]
		if layer != "" || t & ASEPRITE_TILE_ID != 0 do return t, l, true
		ok = true
	}
	return 0, nil, ok
}

/*
A property of a tile (its own, else its tileset's).

Inputs:
- layer: The tile's layer (`TileMap_TileAt`)
- tile: The tile value
- name: The property

Returns:
- The value, and whether there's one

Example:
	// Given: level: ^e.TileMapNode, hero: ^e.Node
	if tile, layer, ok := e.TileMap_TileAt(level, "Ground", e.Node_GetWorldPosition(hero)); ok {
		if value, has := e.TileMap_TileProperty(layer, tile, "damage"); has do log.info(value)
	}
*/
TileMap_TileProperty :: proc(layer: ^TileMapLayer, tile: u32, name: string) -> (AsepriteValue, bool) {
	if layer == nil || layer.tileset == nil do return nil, false
	id := int(tile & ASEPRITE_TILE_ID)
	if id > 0 && id < len(layer.tileset.tileUserData) {
		if value, ok := Aseprite_Property(layer.tileset.tileUserData[id], name); ok do return value, true
	}
	return Aseprite_Property(layer.tileset.userData, name)
}

// Builds a TileMap node from scene data (project_loader.odin)
@(private)
tileMapBuildNode :: proc(scene: ^Scene, data: ^SceneNodeData, projectDir: string) -> ^Node {
	node := CreateNode(scene, TileMapNode)
	allocator := Node_GetAllocator(node)
	node.settings = data.tilemap
	node.settings.file = strings.clone(data.tilemap.file, allocator)
	node.settings.layers = strings.clone(data.tilemap.layers, allocator)
	node.projectDir = strings.clone(projectDir, allocator)
	node.physics = {data.collisionLayer, data.collisionMask, data.friction, data.restitution}
	node.built = make([dynamic]^Node, allocator)
	node.tileLayers = make([dynamic]^TileMapLayer, allocator)
	node.bodies = make([dynamic]^Node, allocator)
	node.settings.tag = strings.clone(data.tilemap.tag, allocator)
	node.settings.painted = make([dynamic]TileLayerData, allocator)
	for layer in data.tilemap.painted do append(&node.settings.painted, TileLayerData_Clone(layer, allocator))
	node.retired = make([dynamic]^Aseprite, allocator)
	node.getBounds = tileMapBounds
	node.update = tileMapUpdate
	node.destroy = proc(node: ^Node) {
		t := cast(^TileMapNode)node
		Aseprite_Destroy(t.ase)
		for old in t.retired do Aseprite_Destroy(old)
	}
	if node.settings.file == "" do return node
	full := JoinPath(projectDir, node.settings.file)
	ase, err := Aseprite_Load(full)
	if err != .None {
		log.errorf("TileMap %s: couldn't read %s (%v)", data.name, full, err)
		return node
	}
	node.ase = ase
	node.modified = fileModified(full)
	buildTileMap(node)
	return node
}

// The layers and bodies of a TileMap from its file
@(private="file")
buildTileMap :: proc(node: ^TileMapNode) {
	scene := node.scene
	ase := node.ase
	if ase == nil do return
	allocator := Node_GetAllocator(node)
	wanted := make([dynamic]string, context.temp_allocator)
	for name in strings.split(node.settings.layers, ",", context.temp_allocator) {
		if trimmed := strings.trim_space(name); trimmed != "" do append(&wanted, trimmed)
	}
	full := JoinPath(node.projectDir, node.settings.file)
	base := clamp(node.settings.frame, 0, max(len(ase.frames) - 1, 0))
	// The frames it plays: its tag's, else every one; not animated: its frame
	frames := make([dynamic]int, allocator)
	if node.settings.animate && len(ase.frames) > 1 {
		from, to := 0, len(ase.frames) - 1
		if tag := node.settings.tag != "" ? Aseprite_FindTag(ase, node.settings.tag) : nil; tag != nil do from, to = clamp(tag.from, 0, to), clamp(tag.to, 0, to)
		for f in from..=to do append(&frames, f)
	}
	if len(frames) == 0 do append(&frames, base)
	node.frames = frames[:]
	node.shown, node.clock = 0, 0
	for f, i in node.frames do if f == base do node.shown = i

	named :: proc(wanted: []string, name: string) -> bool {
		for w in wanted do if w == name do return true
		return false
	}
	painted :: proc(node: ^TileMapNode, name: string) -> ^TileLayerData {
		for &p in node.settings.painted do if p.layer == name do return &p
		return nil
	}
	// The layers it builds: the file's tilemap layers (named, or none named and shown, or
	// painted), then painted layers of their own
	Source :: struct { name: string, layer: int, tileset: int, opacity: u8, painted: ^TileLayerData }
	sources := make([dynamic]Source, context.temp_allocator)
	for layer, i in ase.layers {
		if layer.type != .Tilemap || layer.tileset < 0 || layer.tileset >= len(ase.tilesets) do continue
		p := painted(node, layer.name)
		if len(wanted) > 0 ? !named(wanted[:], layer.name) : !Aseprite_LayerShown(ase, i) && p == nil do continue
		append(&sources, Source{layer.name, i, layer.tileset, layer.opacity, p})
	}
	for &p in node.settings.painted {
		if Aseprite_FindLayer(ase, p.layer) >= 0 && ase.layers[Aseprite_FindLayer(ase, p.layer)].type == .Tilemap do continue
		if p.tileset < 0 || p.tileset >= len(ase.tilesets) do continue
		if len(wanted) > 0 && !named(wanted[:], p.layer) do continue
		append(&sources, Source{p.layer, -1, p.tileset, 255, &p})
	}

	for source in sources {
		// A painted layer's tiles, the same in every frame: a cel of its own (the node's memory)
		paintedCel: ^AsepriteCel
		if p := source.painted; p != nil {
			paintedCel = new(AsepriteCel, allocator)
			paintedCel^ = {layer = source.layer, x = p.x, y = p.y, width = p.columns, height = p.rows, opacity = 255}
			paintedCel.tiles = make([]u32, p.columns * p.rows, allocator)
			copy(paintedCel.tiles, p.tiles[:])
		}
		celIn :: proc(ase: ^Aseprite, frame, layer: int, painted: ^AsepriteCel) -> ^AsepriteCel {
			if painted != nil do return painted
			return layer >= 0 ? Aseprite_Cel(ase, frame, layer) : nil
		}
		// A cel in some frame it plays, or in its frame
		baseCel := celIn(ase, base, source.layer, paintedCel)
		any := baseCel != nil
		for f in node.frames do if celIn(ase, f, source.layer, paintedCel) != nil do any = true
		if !any do continue
		tileset := &ase.tilesets[source.tileset]
		l := CreateNode(scene, TileMapLayer)
		layerAllocator := Node_GetAllocator(l)
		l.name = strings.clone(source.name, layerAllocator)
		l.layerName = l.name
		l.layerIndex = source.layer
		l.tileset = tileset
		l.opacity = source.opacity
		l.base = baseCel
		l.tileSize = {f32(tileset.tileWidth), f32(tileset.tileHeight)}
		l.texture = scene.game.resourceManager->loadTexture(fmt.tprintf("%s%s%d", full, ASEPRITE_TILESET_SUFFIX, source.tileset))
		l.frames = make([]TileMapLayerFrame, len(node.frames), layerAllocator)
		for f, at in node.frames {
			cel := celIn(ase, f, source.layer, paintedCel)
			l.frames[at] = {cel = cel, quads = make([dynamic]TileQuad, 0, cel != nil ? len(cel.tiles) : 0, layerAllocator)}
			fillQuads(l, &l.frames[at])
		}
		l.layer = node.layer
		l.draw = tileMapLayerDraw
		l.destroy = proc(node: ^Node) { dropTileBatchCache(&(cast(^TileMapLayer)node).batch) }
		l.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
			l := cast(^TileMapLayer)node
			return {0, 0, l.size.x, l.size.y}, true
		}
		Node_AddChild(node, l)
		append(&node.built, l)
		append(&node.tileLayers, l)
	}
	showFrame(node, node.shown)
	if node.settings.collision do buildTileCollision(node)
}

// A frame's tiles as quads, refilled in place (a cel has no more tiles than its cells)
@(private="file")
fillQuads :: proc(l: ^TileMapLayer, frame: ^TileMapLayerFrame) {
	clear(&frame.quads)
	cel := frame.cel
	if cel == nil || cel.tiles == nil do return
	alpha := f32(cel.opacity) / 255 * f32(l.opacity) / 255
	for tile, at in cel.tiles {
		id := int(tile & ASEPRITE_TILE_ID)
		if id == 0 || id >= l.tileset.count do continue
		column, row := at % cel.width, at / cel.width
		append(&frame.quads, TileQuad{px = {f32(column), f32(row)} * l.tileSize, src = {0, f32(id) * l.tileSize.y}, flips = tile & ~ASEPRITE_TILE_ID, alpha = alpha})
	}
}

// Shows a frame it plays (by index in `frames`): every layer's tiles and place from its cel there
@(private="file")
showFrame :: proc(node: ^TileMapNode, index: int) {
	node.shown = index
	for l in node.tileLayers {
		frame := &l.frames[index]
		l.quads = frame.quads[:]
		if cel := frame.cel; cel != nil {
			l.cells = {cel.width, cel.height}
			l.tiles = cel.tiles
			l.position = {f32(cel.x), f32(cel.y)}
		} else {
			l.cells, l.tiles = {}, nil
		}
		l.size = {f32(l.cells.x) * l.tileSize.x, f32(l.cells.y) * l.tileSize.y}
		dropTileBatchCache(&l.batch)
	}
}

/*
The tile cell under a point of the world, in a layer as it shows now.

Inputs:
- node: The TileMap
- layer: The layer's name
- position: A point in the world

Returns:
- The column and row, and false when the point is off the layer's grid (or there's no such layer)
*/
TileMap_CellAt :: proc(node: ^TileMapNode, layer: string, position: [2]f32) -> (column, row: int, ok: bool) {
	for l in node.tileLayers {
		if l.layerName != layer do continue
		local := Transform2D_Apply(Transform2D_Inverse(Node_GetWorldTransform(l)), position)
		column, row = int(local.x / l.tileSize.x), int(local.y / l.tileSize.y)
		return column, row, local.x >= 0 && local.y >= 0 && column < l.cells.x && row < l.cells.y
	}
	return 0, 0, false
}

/*
Changes a tile: drawn at once, collision rebuilt on the node's next update (a broken block, a
door opening). An animated layer gets it in every frame it plays, so it stays.

Inputs:
- node: The TileMap
- layer: The layer's name
- column, row: The cell (in the layer's grid, as `TileMap_CellAt` gives it)
- tile: The tile value (an index in the layer's tileset, with flip bits; 0 empties it)

Returns:
- false when there's no such layer or cell

Example:
	// Given: level: ^e.TileMapNode, hit: [2]f32
	if column, row, ok := e.TileMap_CellAt(level, "Ground", hit); ok do e.TileMap_SetTile(level, "Ground", column, row, 0)
*/
TileMap_SetTile :: proc(node: ^TileMapNode, layer: string, column, row: int, tile: u32) -> bool {
	for l in node.tileLayers {
		if l.layerName != layer do continue
		changed := false
		set :: proc(cel: ^AsepriteCel, column, row: int, tile: u32) -> bool {
			if cel == nil || cel.tiles == nil || column < 0 || row < 0 || column >= cel.width || row >= cel.height do return false
			cel.tiles[row * cel.width + column] = tile
			return true
		}
		if set(l.base, column, row, tile) do changed = true
		for &frame in l.frames do if set(frame.cel, column, row, tile) do changed = true
		if !changed do return false
		for &frame in l.frames do fillQuads(l, &frame)
		showFrame(node, node.shown)
		node.collisionDirty = node.settings.collision
		return true
	}
	return false
}

// The bodies from the tiles' collision properties: solid and one-way tiles in one StaticBody,
// area tiles in an Area per name; rectangles merged (runs along rows, then down)
@(private="file")
buildTileCollision :: proc(node: ^TileMapNode) {
	scene := node.scene
	setUp :: proc(node: ^TileMapNode, body: ^PhysicsBody, name: string) {
		body.name = strings.clone(name, Node_GetAllocator(body))
		body.layer = node.layer
		body.collisionLayer = node.physics.layer
		body.collisionMask = node.physics.mask
		body.friction = node.physics.friction
		body.restitution = node.physics.restitution
		Node_AddChild(node, body)
		append(&node.built, body)
		append(&node.bodies, body)
	}
	// From each layer's cel in the TileMap's `frame` (an animated map's collision doesn't move)
	Want :: struct { kind: TileCollisionKind, area: string }
	matches :: proc(l: ^TileMapLayer, want: Want, column, row: int) -> bool {
		kind, area := TileMap_TileCollision(l.tileset, l.base.tiles[row * l.base.width + column])
		return kind == want.kind && (want.kind != .Area || area == want.area)
	}
	shapes :: proc(scene: ^Scene, node: ^TileMapNode, parent: ^Node, l: ^TileMapLayer, want: Want) -> int {
		if l.base == nil || l.base.tiles == nil do return 0
		w, h := l.base.width, l.base.height
		origin := [2]f32{f32(l.base.x), f32(l.base.y)}
		used := make([]bool, w * h, context.temp_allocator)
		made := 0
		for y in 0 ..< h do for x in 0 ..< w {
			if used[y * w + x] || !matches(l, want, x, y) do continue
			width := 1
			for x + width < w && !used[y * w + x + width] && matches(l, want, x + width, y) do width += 1
			height := 1
			grow: for y + height < h {
				for i in 0 ..< width do if used[(y + height) * w + x + i] || !matches(l, want, x + i, y + height) do break grow
				height += 1
			}
			for j in 0 ..< height do for i in 0 ..< width do used[(y + j) * w + x + i] = true
			shape := CreateCollisionShape(scene, .Rectangle)
			shape.size = {f32(width) * l.tileSize.x, f32(height) * l.tileSize.y}
			shape.position = origin + {(f32(x) + f32(width) * 0.5) * l.tileSize.x, (f32(y) + f32(height) * 0.5) * l.tileSize.y}
			shape.layer = node.layer
			shape.oneWay = want.kind == .One_Way
			Node_AddChild(parent, shape)
			made += 1
		}
		return made
	}
	// Solid and one-way tiles: "Collision"
	body := CreateStaticBody(scene)
	setUp(node, body, "Collision")
	made := 0
	for l in node.tileLayers {
		made += shapes(scene, node, body, l, {.Solid, ""})
		made += shapes(scene, node, body, l, {.One_Way, ""})
	}
	if made == 0 do Scene_RemoveNode(scene, body.id)
	// Area tiles: an Area per name
	names := make([dynamic]string, context.temp_allocator)
	for l in node.tileLayers do if l.base != nil do for tile in l.base.tiles {
		kind, area := TileMap_TileCollision(l.tileset, tile)
		if kind != .Area do continue
		known := false
		for n in names do if n == area do known = true
		if !known do append(&names, area)
	}
	for name in names {
		area := CreateArea(scene)
		setUp(node, area, name == "" ? "Area" : name)
		count := 0
		for l in node.tileLayers do count += shapes(scene, node, area, l, {.Area, name})
		if count == 0 do Scene_RemoveNode(scene, area.id)
	}
}

@(private="file")
tileMapLayerDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	l := cast(^TileMapLayer)node
	tint := drawState().tint
	drawTileBatch(&l.batch, renderer, {f32(tint.r) / 255, f32(tint.g) / 255, f32(tint.b) / 255, f32(tint.a) / 255})
}

// Every layer's rectangle together, in the node's space (picking, selection boxes)
@(private="file")
tileMapBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	t := cast(^TileMapNode)node
	if len(t.tileLayers) == 0 {
		if t.ase != nil && t.ase.width > 0 do return {0, 0, f32(t.ase.width), f32(t.ase.height)}, true
		return {}, false
	}
	lo, hi := [2]f32{1e30, 1e30}, [2]f32{-1e30, -1e30}
	for l in t.tileLayers {
		lo = {min(lo.x, l.position.x), min(lo.y, l.position.y)}
		hi = {max(hi.x, l.position.x + l.size.x), max(hi.y, l.position.y + l.size.y)}
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, true
}

// Plays an animated map's frames, rebuilds bodies after tile changes; development runs read a file
// saved since again and rebuild the node
@(private="file")
tileMapUpdate :: proc(node: ^Node, _: []sdl.Event, deltaTime: f64) {
	t := cast(^TileMapNode)node
	// The layers a rebuild replaced were removed before this update: their file can go
	for old in t.retired do Aseprite_Destroy(old)
	clear(&t.retired)
	// Tiles changed (TileMap_SetTile): its bodies again
	if t.collisionDirty {
		t.collisionDirty = false
		for b in t.bodies do Scene_RemoveNode(t.scene, b.id)
		clear(&t.bodies)
		buildTileCollision(t)
	}
	// Animated: the next frame once this one has shown its duration
	if len(t.frames) > 1 && t.ase != nil {
		t.clock += deltaTime
		for {
			f := t.frames[t.shown]
			d := f < len(t.ase.frames) ? f64(t.ase.frames[f].duration) / 1000 : 0.1
			if d <= 0 || t.clock < d do break
			t.clock -= d
			showFrame(t, (t.shown + 1) % len(t.frames))
		}
	}
	if !t.scene.game.devKeys || t.settings.file == "" do return
	t.watchTimer -= deltaTime
	if t.watchTimer > 0 do return
	t.watchTimer = LDTK_WATCH_SECONDS
	full := JoinPath(t.projectDir, t.settings.file)
	modified := fileModified(full)
	if modified == 0 || modified == t.modified do return
	t.modified = modified
	ase, err := Aseprite_Load(full)
	if err != .None {
		log.errorf("TileMap %s: reloading %s: %v", t.name, full, err)
		return
	}
	TileMap_Rebuild(t, ase)
	log.infof("TileMap %s: reloaded %s", t.name, t.settings.file)
}

/*
Builds a TileMap's layers and collision again, from a file's data (the node takes it and frees
the old). Development runs do it when the file is saved; editors when it changes.

Inputs:
- node: The TileMap
- ase: The file, read again
*/
TileMap_Rebuild :: proc(node: ^TileMapNode, ase: ^Aseprite) {
	for n in node.built do Scene_RemoveNode(node.scene, n.id)
	clear(&node.built)
	clear(&node.tileLayers)
	clear(&node.bodies)
	node.collisionDirty = false
	// The old file goes when its layers do (they point into it): on the next update
	if node.ase != nil do append(&node.retired, node.ase)
	node.ase = ase
	// The tilesets' textures follow the file (in place when their size is the same)
	ResourceManager_ReloadChangedTextures(&node.scene.game.resourceManager)
	buildTileMap(node)
}

// Terrains (autotiling): see the file's overview

// The neighbour bits of a terrain tile's `mask` property: the neighbours of the same terrain it's
// drawn for (a corner counts only with both its edges: the "blob" rule)
TERRAIN_N  :: 1
TERRAIN_NE :: 2
TERRAIN_E  :: 4
TERRAIN_SE :: 8
TERRAIN_S  :: 16
TERRAIN_SW :: 32
TERRAIN_W  :: 64
TERRAIN_NW :: 128

/*
The terrain a tile belongs to: its `terrain` property in Aseprite ("" for none).

Inputs:
- tileset: The tileset
- tile: A tile value (flips don't matter)
*/
Tileset_TerrainOf :: proc(tileset: ^AsepriteTileset, tile: u32) -> string {
	id := int(tile & ASEPRITE_TILE_ID)
	if id <= 0 || id >= len(tileset.tileUserData) do return ""
	value, ok := Aseprite_Property(tileset.tileUserData[id], "terrain")
	if !ok do return ""
	text, _ := value.(string)
	return text
}

/*
A tileset's terrains, in the order their first tiles come.

Inputs:
- tileset: The tileset
- allocator: For the list

Returns:
- The terrains' names
*/
Tileset_Terrains :: proc(tileset: ^AsepriteTileset, allocator := context.allocator) -> []string {
	names := make([dynamic]string, allocator)
	for id in 1..<tileset.count {
		name := Tileset_TerrainOf(tileset, u32(id))
		if name == "" do continue
		known := false
		for n in names do if n == name do known = true
		if !known do append(&names, name)
	}
	return names[:]
}

// A tile's `mask` property (-1 when it has none)
@(private="file")
terrainMask :: proc(tileset: ^AsepriteTileset, id: int) -> int {
	if id <= 0 || id >= len(tileset.tileUserData) do return -1
	value, ok := Aseprite_Property(tileset.tileUserData[id], "mask")
	if !ok do return -1
	switch v in value {
	case i64: return int(v) & 0xff
	case f64: return int(v) & 0xff
	case string:
		// "N,E,S" (names) or a number
		mask := 0
		for part in strings.split(v, ",", context.temp_allocator) {
			switch strings.to_upper(strings.trim_space(part), context.temp_allocator) {
			case "N": mask |= TERRAIN_N
			case "NE": mask |= TERRAIN_NE
			case "E": mask |= TERRAIN_E
			case "SE": mask |= TERRAIN_SE
			case "S": mask |= TERRAIN_S
			case "SW": mask |= TERRAIN_SW
			case "W": mask |= TERRAIN_W
			case "NW": mask |= TERRAIN_NW
			}
		}
		return mask
	case bool, AsepritePoint, AsepriteSize, AsepriteRect, AsepriteUUID, []AsepriteValue, map[string]AsepriteValue:
	}
	return -1
}

// The blob rule: a corner counts only with both of its edges
@(private="file")
reduceMask :: proc(mask: int) -> int {
	m := mask
	if m & TERRAIN_N == 0 || m & TERRAIN_E == 0 do m &~= TERRAIN_NE
	if m & TERRAIN_S == 0 || m & TERRAIN_E == 0 do m &~= TERRAIN_SE
	if m & TERRAIN_S == 0 || m & TERRAIN_W == 0 do m &~= TERRAIN_SW
	if m & TERRAIN_N == 0 || m & TERRAIN_W == 0 do m &~= TERRAIN_NW
	return m
}

/*
The tile of a terrain drawn for a cell whose same-terrain neighbours are `mask`: the one whose
own mask matches best (exactly, else in the most neighbours; corners only when the terrain's tiles
use them, so a 16-tile set of edges works too), else any tile of the terrain.

Inputs:
- tileset: The tileset
- terrain: The terrain's name
- mask: The cell's neighbours of the same terrain (TERRAIN_* bits)

Returns:
- The tile (an index; 0 when the tileset has no tile of that terrain)
*/
Terrain_TileFor :: proc(tileset: ^AsepriteTileset, terrain: string, mask: int) -> u32 {
	corners := false
	for id in 1..<tileset.count {
		if Tileset_TerrainOf(tileset, u32(id)) != terrain do continue
		if m := terrainMask(tileset, id); m > 0 && m & (TERRAIN_NE | TERRAIN_SE | TERRAIN_SW | TERRAIN_NW) != 0 do corners = true
	}
	considered := corners ? 0xff : (TERRAIN_N | TERRAIN_E | TERRAIN_S | TERRAIN_W)
	want := reduceMask(mask) & considered
	best, bestScore := u32(0), -1
	for id in 1..<tileset.count {
		if Tileset_TerrainOf(tileset, u32(id)) != terrain do continue
		m := terrainMask(tileset, id)
		score := 0
		if m >= 0 {
			have := reduceMask(m) & considered
			if have == want do return u32(id)
			for bit := 1; bit <= 128; bit <<= 1 do if bit & considered != 0 && (have & bit) == (want & bit) do score += 1
		}
		if score > bestScore do best, bestScore = u32(id), score
	}
	return best
}

/*
Paints a terrain into a grid of tiles (autotiling): the cell takes the terrain, then it and its
eight neighbours of a terrain take the tile that fits their neighbours (`Terrain_TileFor`).
Painting "" erases the cell and fixes its neighbours. Cells off the grid count as the same terrain,
so a terrain reaches the map's edges without a border.

Inputs:
- tileset: The tileset
- tiles: The grid, row by row (changed in place)
- columns, rows: Its size
- column, row: The cell
- terrain: The terrain ("" to erase)

Returns:
- false when the cell is off the grid
*/
TileGrid_PaintTerrain :: proc(tileset: ^AsepriteTileset, tiles: []u32, columns, rows, column, row: int, terrain: string) -> bool {
	if column < 0 || row < 0 || column >= columns || row >= rows do return false
	tiles[row * columns + column] = terrain == "" ? 0 : max(Terrain_TileFor(tileset, terrain, 0xff), 1)
	OFFSETS :: [8][2]int{{0, -1}, {1, -1}, {1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}}
	offsets := OFFSETS
	for dy in -1..=1 do for dx in -1..=1 {
		x, y := column + dx, row + dy
		if x < 0 || y < 0 || x >= columns || y >= rows do continue
		name := Tileset_TerrainOf(tileset, tiles[y * columns + x])
		if name == "" do continue
		mask := 0
		for offset, bit in offsets {
			nx, ny := x + offset.x, y + offset.y
			same := nx < 0 || ny < 0 || nx >= columns || ny >= rows || Tileset_TerrainOf(tileset, tiles[ny * columns + nx]) == name
			if same do mask |= 1 << uint(bit)
		}
		if tile := Terrain_TileFor(tileset, name, mask); tile != 0 do tiles[y * columns + x] = tile
	}
	return true
}

/*
Paints a terrain into a TileMap's layer from code (`TileGrid_PaintTerrain`): drawn at once,
collision on the next update, every frame of an animated layer.

Inputs:
- node: The TileMap
- layer: The layer's name
- column, row: The cell
- terrain: The terrain's name ("" erases)

Returns:
- false when there's no such layer or cell

Example:
	// Given: level: ^e.TileMapNode, hit: [2]f32
	if column, row, ok := e.TileMap_CellAt(level, "Ground", hit); ok do e.TileMap_SetTerrain(level, "Ground", column, row, "")
*/
TileMap_SetTerrain :: proc(node: ^TileMapNode, layer: string, column, row: int, terrain: string) -> bool {
	for l in node.tileLayers {
		if l.layerName != layer do continue
		changed := false
		if l.base != nil && TileGrid_PaintTerrain(l.tileset, l.base.tiles, l.base.width, l.base.height, column, row, terrain) do changed = true
		for &frame in l.frames {
			if frame.cel == nil || frame.cel == l.base || raw_data(frame.cel.tiles) == raw_data(l.base.tiles) do continue
			if TileGrid_PaintTerrain(l.tileset, frame.cel.tiles, frame.cel.width, frame.cel.height, column, row, terrain) do changed = true
		}
		if !changed do return false
		for &frame in l.frames do fillQuads(l, &frame)
		showFrame(node, node.shown)
		node.collisionDirty = node.settings.collision
		return true
	}
	return false
}
