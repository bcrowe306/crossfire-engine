package crossfire

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

	for layer, i in ase.layers {
		if layer.type != .Tilemap || layer.tileset < 0 || layer.tileset >= len(ase.tilesets) do continue
		if len(wanted) > 0 {
			named := false
			for w in wanted do if w == layer.name do named = true
			if !named do continue
		} else if !Aseprite_LayerShown(ase, i) {
			continue
		}
		// A cel in some frame it plays, or in its frame
		baseCel := Aseprite_Cel(ase, base, i)
		any := baseCel != nil
		for f in node.frames do if Aseprite_Cel(ase, f, i) != nil do any = true
		if !any do continue
		tileset := &ase.tilesets[layer.tileset]
		l := CreateNode(scene, TileMapLayer)
		layerAllocator := Node_GetAllocator(l)
		l.name = strings.clone(layer.name, layerAllocator)
		l.layerName = l.name
		l.layerIndex = i
		l.tileset = tileset
		l.opacity = layer.opacity
		l.base = baseCel
		l.tileSize = {f32(tileset.tileWidth), f32(tileset.tileHeight)}
		l.texture = scene.game.resourceManager->loadTexture(fmt.tprintf("%s%s%d", full, ASEPRITE_TILESET_SUFFIX, layer.tileset))
		l.frames = make([]TileMapLayerFrame, len(node.frames), layerAllocator)
		for f, at in node.frames {
			cel := Aseprite_Cel(ase, f, i)
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
