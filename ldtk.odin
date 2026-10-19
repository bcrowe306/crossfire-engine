package engine

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

/*
LDtk projects (https://ldtk.io, the level editor by Deepnight): reading `.ldtk` files, so levels
drawn in LDtk play in the engine. The nodes that build them into a scene are in ldtk_nodes.odin.

`LDtk_Load` reads a project (JSON format 1.x; written against 1.5.3) into plain data:
- **Worlds and levels.** Without LDtk's "Multi-worlds" option a project has one world, made from
  the file's root (its `levels`, `worldLayout`, grid size); with it, every world of `worlds`.
  Levels saved as separate files ("Save levels to separate files": `.ldtkl` next to the project)
  are read too, so a level always has its layers.
- **Layers** in LDtk's order, **top-most first** (draw them back to front). Every kind keeps what
  a game needs: IntGrid values (row-major, 0 = empty), the tiles of Tiles layers and of
  auto-layers (an IntGrid layer with rules has both), entities. Offsets are the total ones
  (definition plus instance).
- **Entities**: identifier, iid, position (`px`: where its pivot is, in the level), size, pivot,
  tags, tile, color and **custom fields** (`LDtkValue`: ints, floats, bools, strings, colors,
  enums as their value's name, points, tiles, entity references, and arrays of those).
- **Definitions** a game uses: tilesets (image path, grid, spacing, padding, custom data, enum
  tags), layer definitions (IntGrid value names and colors, parallax), entity definitions, enums.

Paths in the data (`tileset.path`, `layer.tilesetPath`, `level.background.path`) are the
`.ldtk` file's folder joined with LDtk's relative path: pass them to the resource manager as they
are. Everything a project holds lives in its own arena: `LDtk_Destroy` frees it all.

Ignored: auto-layer rules (LDtk resolves them into tiles when it saves), editor-only settings,
LDtk's internal icon atlas (`embedAtlas`: entity icons with no image file).

Example:
	project, problem := e.LDtk_Load("assets/world.ldtk")
	if project == nil do log.errorf("Can't read the level: %s", problem)
	defer e.LDtk_Destroy(project)
	level := e.LDtk_FindLevel(project, "Level_0")
	walls := e.LDtk_FindLayer(level, "Collisions")
	if e.LDtk_IntGridAt(walls, 3, 7) == 1 do fmt.println("a wall at cell 3, 7")
*/

// A layer's kind
LDtkLayerType :: enum {
	IntGrid,
	Entities,
	Tiles,
	// An IntGrid-less auto-layer: tiles made by rules from another layer's IntGrid
	AutoLayer,
}

// How a world's levels are placed
LDtkWorldLayout :: enum {
	// Anywhere (worldX, worldY)
	Free,
	// On a grid (worldX, worldY are multiples of the world grid)
	GridVania,
	// In a row, in the order of the levels array
	LinearHorizontal,
	// In a column, in the order of the levels array
	LinearVertical,
}

// A rectangle of a tileset's image
LDtkTilesetRect :: struct {
	// The tileset's uid (LDtk_FindTileset)
	tileset: int,
	x, y, w, h: int,
}

// A cell of a grid: a Point field's value
LDtkGridPoint :: distinct [2]int

// Where an entity is: an EntityRef field's value
LDtkEntityRef :: struct {
	entityIid, layerIid, levelIid, worldIid: string,
}

/*
A custom field's value. nil when the field is null (no value). Enums are their value's name.
Arrays (`Array<Int>`...) are `[]LDtkValue`.
*/
LDtkValue :: union {
	i64,
	f64,
	bool,
	string,
	sdl.Color,
	LDtkGridPoint,
	LDtkTilesetRect,
	LDtkEntityRef,
	[]LDtkValue,
}

// A custom field of a level or an entity
LDtkField :: struct {
	identifier: string,
	// LDtk's type name: "Int", "Float", "Bool", "String", "Multilines", "Color", "Point",
	// "FilePath", "Tile", "EntityRef", "LocalEnum.Item", "ExternEnum.X", "Array<Int>"...
	type: string,
	value: LDtkValue,
}

// A tile of a Tiles layer or an auto-layer
LDtkTile :: struct {
	// Where it goes in the layer (its top-left corner, pixels; add the layer's offset)
	px: [2]f32,
	// Its top-left corner in the tileset image
	src: [2]f32,
	// Mirrored horizontally / vertically
	flipX, flipY: bool,
	// Opacity 0-1
	alpha: f32,
	// The tile's id in its tileset
	id: int,
}

// An entity instance
LDtkEntity :: struct {
	identifier: string,
	// Unique id (other entities' EntityRef fields point at it)
	iid: string,
	// Where its pivot is, in pixels from the level's top-left corner (without the layer offset)
	px: [2]f32,
	// Its grid cell
	grid: [2]int,
	// The pivot in its rectangle: 0-1 ({0.5, 1}: bottom middle)
	pivot: [2]f32,
	size: [2]f32,
	tags: []string,
	// The tile LDtk shows it with (its definition's, or a field's); none for no tile
	tile: Maybe(LDtkTilesetRect),
	color: sdl.Color,
	fields: []LDtkField,
}

// A layer of a level
LDtkLayer :: struct {
	identifier: string,
	iid: string,
	type: LDtkLayerType,
	gridSize: int,
	// Width and height in cells
	cells: [2]int,
	// Total pixel offset (definition plus instance)
	offset: [2]f32,
	opacity: f32,
	visible: bool,
	// The tileset its tiles come from: its uid (-1 for none) and its image's path
	tileset: int,
	tilesetPath: string,
	// IntGrid layers: cells.x * cells.y values, row by row; 0 is empty
	intGrid: []i32,
	// Tiles layers' tiles, and auto-layers' (IntGrid layers with rules too), back to front
	tiles: []LDtkTile,
	entities: []LDtkEntity,
	// From the layer definition: how much slower it scrolls (-1 to 1, 0 = none), and whether
	// parallax also scales it
	parallax: [2]f32,
	parallaxScaling: bool,
}

// A level's background image, placed as LDtk shows it
LDtkBackground :: struct {
	// "" for none
	path: string,
	topLeft: [2]f32,
	scale: [2]f32,
	// The part of the image shown: x, y, width, height
	crop: [4]f32,
}

// A level touching this one in the world: its iid, and the side (n, s, e, w, ne..., or <, >, o
// for levels below, above, overlapping)
LDtkNeighbour :: struct {
	levelIid: string,
	dir: string,
}

// A level
LDtkLevel :: struct {
	identifier: string,
	iid: string,
	uid: int,
	// Its top-left corner in the world (Free and GridVania layouts; -1 for linear ones)
	world: [2]f32,
	worldDepth: int,
	size: [2]f32,
	bgColor: sdl.Color,
	background: LDtkBackground,
	neighbours: []LDtkNeighbour,
	fields: []LDtkField,
	// Top-most first, as LDtk lists them
	layers: []LDtkLayer,
}

// A world: its levels and how they're laid out
LDtkWorld :: struct {
	identifier: string,
	iid: string,
	layout: LDtkWorldLayout,
	// GridVania's cell size
	gridSize: [2]int,
	levels: []LDtkLevel,
}

// A tileset definition
LDtkTileset :: struct {
	uid: int,
	identifier: string,
	// The image, joined to the project's folder ("" for none, or LDtk's internal icons)
	path: string,
	// LDtk's own icon atlas (no image file the engine can load)
	embedded: bool,
	gridSize: int,
	spacing: int,
	padding: int,
	// Image size in pixels, and in cells
	size: [2]int,
	cells: [2]int,
	tags: []string,
	// Text attached to tiles in LDtk ("custom data"), by tile id
	customData: []LDtkTileData,
	// Tiles tagged with an enum's values
	enumTags: []LDtkEnumTag,
}

// A tile's custom data (a tileset's)
LDtkTileData :: struct {
	tileId: int,
	data: string,
}

// The tiles tagged with an enum value (a tileset's)
LDtkEnumTag :: struct {
	enumValue: string,
	tileIds: []int,
}

// An IntGrid value's name and color (a layer definition's)
LDtkIntGridValue :: struct {
	value: int,
	// "" when unnamed
	identifier: string,
	color: sdl.Color,
}

// A layer definition
LDtkLayerDef :: struct {
	uid: int,
	identifier: string,
	type: LDtkLayerType,
	gridSize: int,
	intGridValues: []LDtkIntGridValue,
	parallax: [2]f32,
	parallaxScaling: bool,
}

// An entity definition
LDtkEntityDef :: struct {
	uid: int,
	identifier: string,
	size: [2]f32,
	pivot: [2]f32,
	color: sdl.Color,
	tags: []string,
}

// An enum definition: its values, in order
LDtkEnumDef :: struct {
	uid: int,
	identifier: string,
	values: []string,
}

/*
An LDtk project. Made by LDtk_Load; everything in it is in its arena (LDtk_Destroy).
*/
LDtkProject :: struct {
	arena: MemoryArena,
	// The .ldtk file, and its folder (paths in the data are joined to it)
	path, dir: string,
	jsonVersion: string,
	bgColor: sdl.Color,
	// At least one (projects without Multi-worlds have one, from the file's root)
	worlds: []LDtkWorld,
	tilesets: []LDtkTileset,
	layers: []LDtkLayerDef,
	entities: []LDtkEntityDef,
	enums: []LDtkEnumDef,
}

/*
Reads an LDtk project file (and its separate level files, if it has them).

Inputs:
- path: The .ldtk file (read through the platform layer: the data pack, the browser's files)

Returns:
- The project (LDtk_Destroy frees it), or nil and what went wrong (temp allocated)
*/
LDtk_Load :: proc(path: string) -> (^LDtkProject, string) {
	text, ok := Platform_ReadFile(path)
	if !ok do return nil, fmt.tprintf("can't read %s", path)
	return LDtk_Parse(string(text), path)
}

/*
Parses an LDtk project's JSON. Separate level files are read relative to `path`.

Inputs:
- text: The .ldtk file's contents
- path: Where it is (the folder paths in it are relative to)

Returns:
- The project (LDtk_Destroy frees it), or nil and what went wrong (temp allocated)
*/
LDtk_Parse :: proc(text, path: string) -> (^LDtkProject, string) {
	// On the heap whatever the caller's allocator: LDtk_Destroy frees it there
	project := new(LDtkProject, runtime.heap_allocator())
	if !MemoryArena_InitGrowing(&project.arena) {
		free(project, runtime.heap_allocator())
		return nil, "out of memory"
	}
	allocator := MemoryArena_Allocator(&project.arena)
	context.allocator = allocator

	// The JSON tree goes in a scratch arena, dropped once it's copied
	scratch: MemoryArena
	if !MemoryArena_InitGrowing(&scratch) {
		LDtk_Destroy(project)
		return nil, "out of memory"
	}
	defer MemoryArena_Destroy(&scratch)
	scratchAllocator := MemoryArena_Allocator(&scratch)
	root, err := json.parse_string(text, .JSON, true, scratchAllocator)
	if err != .None {
		LDtk_Destroy(project)
		return nil, fmt.tprintf("%s isn't valid JSON (%v)", path, err)
	}
	object, isObject := root.(json.Object)
	if !isObject || !("defs" in object) {
		LDtk_Destroy(project)
		return nil, fmt.tprintf("%s isn't an LDtk project", path)
	}

	project.path = strings.clone(path)
	project.dir = strings.clone(ldtkFolder(path))
	project.jsonVersion = jString(object, "jsonVersion")
	project.bgColor = jColor(object, "bgColor", {64, 70, 89, 255})

	defs := jObject(object, "defs")
	parser := ldtkParser{project = project, scratch = scratchAllocator}
	parseDefinitions(&parser, defs)

	worlds := make([dynamic]LDtkWorld)
	for w in jArray(object, "worlds") {
		wo := w.(json.Object) or_continue
		world := LDtkWorld{
			identifier = jString(wo, "identifier"),
			iid = jString(wo, "iid"),
			layout = parseLayout(jString(wo, "worldLayout")),
			gridSize = {jInt(wo, "worldGridWidth"), jInt(wo, "worldGridHeight")},
		}
		levels, problem := parseLevels(&parser, jArray(wo, "levels"))
		if problem != "" {
			LDtk_Destroy(project)
			return nil, problem
		}
		world.levels = levels
		append(&worlds, world)
	}
	// Without Multi-worlds: one world, from the root
	if len(worlds) == 0 {
		world := LDtkWorld{
			identifier = "World",
			iid = jString(object, "dummyWorldIid"),
			layout = parseLayout(jString(object, "worldLayout")),
			gridSize = {jInt(object, "worldGridWidth"), jInt(object, "worldGridHeight")},
		}
		levels, problem := parseLevels(&parser, jArray(object, "levels"))
		if problem != "" {
			LDtk_Destroy(project)
			return nil, problem
		}
		world.levels = levels
		append(&worlds, world)
	}
	project.worlds = worlds[:]
	return project, ""
}

// Frees a project and everything in it
LDtk_Destroy :: proc(project: ^LDtkProject) {
	if project == nil do return
	MemoryArena_Destroy(&project.arena)
	free(project, runtime.heap_allocator())
}

/*
A level by identifier ("Level_0") or iid, in any world.

Returns:
- The level, or nil
*/
LDtk_FindLevel :: proc(project: ^LDtkProject, name: string) -> ^LDtkLevel {
	if project == nil do return nil
	for &world in project.worlds {
		for &level in world.levels do if level.identifier == name || level.iid == name do return &level
	}
	return nil
}

// A level's layer by identifier, or nil
LDtk_FindLayer :: proc(level: ^LDtkLevel, identifier: string) -> ^LDtkLayer {
	if level == nil do return nil
	for &layer in level.layers do if layer.identifier == identifier do return &layer
	return nil
}

// A tileset by uid, or nil
LDtk_FindTileset :: proc(project: ^LDtkProject, uid: int) -> ^LDtkTileset {
	if project == nil do return nil
	for &tileset in project.tilesets do if tileset.uid == uid do return &tileset
	return nil
}

// A layer definition by identifier, or nil
LDtk_FindLayerDef :: proc(project: ^LDtkProject, identifier: string) -> ^LDtkLayerDef {
	if project == nil do return nil
	for &def in project.layers do if def.identifier == identifier do return &def
	return nil
}

/*
An IntGrid layer's value at a cell: 0 when empty, outside the layer, or not an IntGrid layer.

Example:
	walls := e.LDtk_FindLayer(level, "Collisions")
	cell := [2]int{int(x) / walls.gridSize, int(y) / walls.gridSize}
	solid := e.LDtk_IntGridAt(walls, cell.x, cell.y) != 0
*/
LDtk_IntGridAt :: proc(layer: ^LDtkLayer, cx, cy: int) -> int {
	if layer == nil || cx < 0 || cy < 0 || cx >= layer.cells.x || cy >= layer.cells.y do return 0
	index := cy * layer.cells.x + cx
	if index >= len(layer.intGrid) do return 0
	return int(layer.intGrid[index])
}

// A field by identifier (of a level or an entity), or nil
LDtk_FindField :: proc(fields: []LDtkField, identifier: string) -> ^LDtkField {
	for &field in fields do if field.identifier == identifier do return &field
	return nil
}

/*
A custom field's value as a type, or the default when it's missing, null or another type. Ints
read as floats too.

Example:
	hp := e.LDtk_FieldValue(entity.fields, "hp", i64(3))
	name := e.LDtk_FieldValue(entity.fields, "name", "nobody")
*/
LDtk_FieldValue :: proc(fields: []LDtkField, identifier: string, default: $T) -> T {
	field := LDtk_FindField(fields, identifier)
	if field == nil do return default
	when T == f64 || T == f32 {
		if v, ok := field.value.(i64); ok do return T(v)
		if v, ok := field.value.(f64); ok do return T(v)
		return default
	} else when T == int {
		if v, ok := field.value.(i64); ok do return int(v)
		return default
	} else {
		v, ok := field.value.(T)
		return ok ? v : default
	}
}

/*
A field's value in the text form scene files and script fields use: "12", "0.5", "true", a
string, "#rrggbbaa", a point as the pixel position of its cell's middle ("x,y", from `gridSize`).
Arrays, tiles and entity references have none.

Returns:
- The text (temp allocated), and whether the value has a text form
*/
LDtk_ValueText :: proc(value: LDtkValue, gridSize: int) -> (string, bool) {
	switch v in value {
	case i64:      return fmt.tprintf("%d", v), true
	case f64:      return fmt.tprintf("%v", v), true
	case bool:     return v ? "true" : "false", true
	case string:   return v, true
	case sdl.Color: return fmt.tprintf("#%02x%02x%02x%02x", v.r, v.g, v.b, v.a), true
	case LDtkGridPoint:
		half := f32(gridSize) * 0.5
		return fmt.tprintf("%v,%v", f32(v.x * gridSize) + half, f32(v.y * gridSize) + half), true
	case LDtkTilesetRect, LDtkEntityRef, []LDtkValue:
	}
	return "", false
}

/*
The files a project needs besides the .ldtk itself: its separate level files, tileset images and
level backgrounds, relative to the .ldtk's folder (temp allocated). Exports copy them with it.
*/
LDtk_Dependencies :: proc(text: string) -> []string {
	context.allocator = context.temp_allocator
	files := make([dynamic]string)
	add :: proc(files: ^[dynamic]string, path: string) {
		if path == "" do return
		for f in files do if f == path do return
		append(files, strings.clone(path, context.temp_allocator))
	}
	root, err := json.parse_string(text, .JSON, true, context.temp_allocator)
	if err != .None do return files[:]
	object := root.(json.Object) or_else nil
	defs := jObject(object, "defs")
	for t in jArray(defs, "tilesets") do if to, ok := t.(json.Object); ok do add(&files, jString(to, "relPath"))
	levels := make([dynamic]json.Value, context.temp_allocator)
	append(&levels, ..jArray(object, "levels"))
	for w in jArray(object, "worlds") do if wo, ok := w.(json.Object); ok do append(&levels, ..jArray(wo, "levels"))
	for l in levels {
		lo := l.(json.Object) or_continue
		add(&files, jString(lo, "externalRelPath"))
		add(&files, jString(lo, "bgRelPath"))
	}
	return files[:]
}

// INTERNAL

@(private="file")
ldtkParser :: struct {
	project: ^LDtkProject,
	scratch: runtime.Allocator,
}

@(private="file")
parseDefinitions :: proc(p: ^ldtkParser, defs: json.Object) {
	project := p.project
	tilesets := make([dynamic]LDtkTileset)
	for t in jArray(defs, "tilesets") {
		to := t.(json.Object) or_continue
		relPath := jString(to, "relPath")
		tileset := LDtkTileset{
			uid = jInt(to, "uid"),
			identifier = jString(to, "identifier"),
			path = relPath == "" ? "" : strings.clone(JoinPath(project.dir, relPath)),
			embedded = jString(to, "embedAtlas") != "",
			gridSize = jInt(to, "tileGridSize"),
			spacing = jInt(to, "spacing"),
			padding = jInt(to, "padding"),
			size = {jInt(to, "pxWid"), jInt(to, "pxHei")},
			cells = {jInt(to, "__cWid"), jInt(to, "__cHei")},
			tags = jStrings(to, "tags"),
		}
		data := make([dynamic]LDtkTileData)
		for d in jArray(to, "customData") {
			do_ := d.(json.Object) or_continue
			append(&data, LDtkTileData{jInt(do_, "tileId"), jString(do_, "data")})
		}
		tileset.customData = data[:]
		tags := make([dynamic]LDtkEnumTag)
		for e in jArray(to, "enumTags") {
			eo := e.(json.Object) or_continue
			ids := make([dynamic]int)
			for id in jArray(eo, "tileIds") do append(&ids, valueInt(id))
			append(&tags, LDtkEnumTag{jString(eo, "enumValueId"), ids[:]})
		}
		tileset.enumTags = tags[:]
		append(&tilesets, tileset)
	}
	project.tilesets = tilesets[:]

	layers := make([dynamic]LDtkLayerDef)
	for l in jArray(defs, "layers") {
		lo := l.(json.Object) or_continue
		def := LDtkLayerDef{
			uid = jInt(lo, "uid"),
			identifier = jString(lo, "identifier"),
			type = parseLayerType(jString(lo, "__type")),
			gridSize = jInt(lo, "gridSize"),
			parallax = {jFloat(lo, "parallaxFactorX"), jFloat(lo, "parallaxFactorY")},
			parallaxScaling = jBool(lo, "parallaxScaling", true),
		}
		values := make([dynamic]LDtkIntGridValue)
		for v in jArray(lo, "intGridValues") {
			vo := v.(json.Object) or_continue
			append(&values, LDtkIntGridValue{jInt(vo, "value"), jString(vo, "identifier"), jColor(vo, "color", {255, 255, 255, 255})})
		}
		def.intGridValues = values[:]
		append(&layers, def)
	}
	project.layers = layers[:]

	entities := make([dynamic]LDtkEntityDef)
	for e in jArray(defs, "entities") {
		eo := e.(json.Object) or_continue
		append(&entities, LDtkEntityDef{
			uid = jInt(eo, "uid"),
			identifier = jString(eo, "identifier"),
			size = {f32(jInt(eo, "width")), f32(jInt(eo, "height"))},
			pivot = {jFloat(eo, "pivotX"), jFloat(eo, "pivotY")},
			color = jColor(eo, "color", {255, 255, 255, 255}),
			tags = jStrings(eo, "tags"),
		})
	}
	project.entities = entities[:]

	enums := make([dynamic]LDtkEnumDef)
	lists := [2]string{"enums", "externalEnums"}
	for list in lists {
		for e in jArray(defs, list) {
			eo := e.(json.Object) or_continue
			names := make([dynamic]string)
			for v in jArray(eo, "values") {
				vo := v.(json.Object) or_continue
				append(&names, jString(vo, "id"))
			}
			append(&enums, LDtkEnumDef{jInt(eo, "uid"), jString(eo, "identifier"), names[:]})
		}
	}
	project.enums = enums[:]
}

@(private="file")
parseLevels :: proc(p: ^ldtkParser, list: []json.Value) -> ([]LDtkLevel, string) {
	levels := make([dynamic]LDtkLevel)
	for l in list {
		lo := l.(json.Object) or_continue
		// Saved apart: the level file has the whole level (layers included)
		if external := jString(lo, "externalRelPath"); external != "" && !hasLayers(lo) {
			file := JoinPath(p.project.dir, external)
			text, ok := Platform_ReadFile(file)
			if !ok do return nil, fmt.tprintf("can't read the level file %s", file)
			value, err := json.parse_string(string(text), .JSON, true, p.scratch)
			if err != .None do return nil, fmt.tprintf("%s isn't valid JSON (%v)", file, err)
			levelObject, isObject := value.(json.Object)
			if !isObject do return nil, fmt.tprintf("%s isn't an LDtk level", file)
			lo = levelObject
		}
		append(&levels, parseLevel(p, lo))
	}
	return levels[:], ""
}

@(private="file")
hasLayers :: proc(o: json.Object) -> bool {
	_, isArray := o["layerInstances"].(json.Array)
	return isArray
}

@(private="file")
parseLevel :: proc(p: ^ldtkParser, lo: json.Object) -> LDtkLevel {
	level := LDtkLevel{
		identifier = jString(lo, "identifier"),
		iid = jString(lo, "iid"),
		uid = jInt(lo, "uid"),
		world = {f32(jInt(lo, "worldX")), f32(jInt(lo, "worldY"))},
		worldDepth = jInt(lo, "worldDepth"),
		size = {f32(jInt(lo, "pxWid")), f32(jInt(lo, "pxHei"))},
		bgColor = jColor(lo, "__bgColor", p.project.bgColor),
		fields = parseFields(jArray(lo, "fieldInstances")),
	}
	if bg := jString(lo, "bgRelPath"); bg != "" {
		level.background.path = strings.clone(JoinPath(p.project.dir, bg))
		pos := jObject(lo, "__bgPos")
		topLeft := jFloats(pos, "topLeftPx")
		scale := jFloats(pos, "scale")
		crop := jFloats(pos, "cropRect")
		if len(topLeft) == 2 do level.background.topLeft = {topLeft[0], topLeft[1]}
		level.background.scale = len(scale) == 2 ? {scale[0], scale[1]} : {1, 1}
		if len(crop) == 4 do level.background.crop = {crop[0], crop[1], crop[2], crop[3]}
	}
	neighbours := make([dynamic]LDtkNeighbour)
	for n in jArray(lo, "__neighbours") {
		no := n.(json.Object) or_continue
		append(&neighbours, LDtkNeighbour{jString(no, "levelIid"), jString(no, "dir")})
	}
	level.neighbours = neighbours[:]

	layers := make([dynamic]LDtkLayer)
	for li in jArray(lo, "layerInstances") {
		o := li.(json.Object) or_continue
		layer := LDtkLayer{
			identifier = jString(o, "__identifier"),
			iid = jString(o, "iid"),
			type = parseLayerType(jString(o, "__type")),
			gridSize = jInt(o, "__gridSize"),
			cells = {jInt(o, "__cWid"), jInt(o, "__cHei")},
			offset = {f32(jInt(o, "__pxTotalOffsetX")), f32(jInt(o, "__pxTotalOffsetY"))},
			opacity = jFloat(o, "__opacity", 1),
			visible = jBool(o, "visible", true),
			tileset = jInt(o, "__tilesetDefUid", -1),
		}
		if relPath := jString(o, "__tilesetRelPath"); relPath != "" do layer.tilesetPath = strings.clone(JoinPath(p.project.dir, relPath))
		if override := jInt(o, "overrideTilesetUid", -1); override >= 0 {
			if tileset := LDtk_FindTileset(p.project, override); tileset != nil {
				layer.tileset = override
				layer.tilesetPath = tileset.path
			}
		}
		if def := LDtk_FindLayerDef(p.project, layer.identifier); def != nil {
			layer.parallax = def.parallax
			layer.parallaxScaling = def.parallaxScaling
		}
		csv := jArray(o, "intGridCsv")
		if len(csv) > 0 {
			grid := make([]i32, len(csv))
			for v, i in csv do grid[i] = i32(valueInt(v))
			layer.intGrid = grid
		}
		tiles := make([dynamic]LDtkTile)
		lists := [2]string{"gridTiles", "autoLayerTiles"}
		for list in lists {
			for t in jArray(o, list) {
				to := t.(json.Object) or_continue
				px := jFloats(to, "px")
				src := jFloats(to, "src")
				if len(px) < 2 || len(src) < 2 do continue
				flip := jInt(to, "f")
				append(&tiles, LDtkTile{
					px = {px[0], px[1]},
					src = {src[0], src[1]},
					flipX = flip & 1 != 0,
					flipY = flip & 2 != 0,
					alpha = jFloat(to, "a", 1),
					id = jInt(to, "t"),
				})
			}
		}
		layer.tiles = tiles[:]
		entities := make([dynamic]LDtkEntity)
		for e in jArray(o, "entityInstances") {
			eo := e.(json.Object) or_continue
			px := jFloats(eo, "px")
			grid := jFloats(eo, "__grid")
			pivot := jFloats(eo, "__pivot")
			entity := LDtkEntity{
				identifier = jString(eo, "__identifier"),
				iid = jString(eo, "iid"),
				px = len(px) == 2 ? {px[0], px[1]} : {},
				grid = len(grid) == 2 ? {int(grid[0]), int(grid[1])} : {},
				pivot = len(pivot) == 2 ? {pivot[0], pivot[1]} : {0.5, 0.5},
				size = {f32(jInt(eo, "width")), f32(jInt(eo, "height"))},
				tags = jStrings(eo, "__tags"),
				color = jColor(eo, "__smartColor", {255, 255, 255, 255}),
				fields = parseFields(jArray(eo, "fieldInstances")),
			}
			if tile, ok := parseTileRect(jObject(eo, "__tile")); ok do entity.tile = tile
			append(&entities, entity)
		}
		layer.entities = entities[:]
		append(&layers, layer)
	}
	level.layers = layers[:]
	return level
}

@(private="file")
parseFields :: proc(list: []json.Value) -> []LDtkField {
	fields := make([dynamic]LDtkField)
	for f in list {
		fo := f.(json.Object) or_continue
		type := jString(fo, "__type")
		append(&fields, LDtkField{
			identifier = jString(fo, "__identifier"),
			type = type,
			value = parseValue(type, fo["__value"]),
		})
	}
	return fields[:]
}

// A field's JSON value as an LDtkValue, from its LDtk type
@(private="file")
parseValue :: proc(type: string, value: json.Value) -> LDtkValue {
	if strings.has_prefix(type, "Array<") && strings.has_suffix(type, ">") {
		element := type[len("Array<"):len(type) - 1]
		list, isArray := value.(json.Array)
		if !isArray do return nil
		values := make([]LDtkValue, len(list))
		for v, i in list do values[i] = parseValue(element, v)
		return values
	}
	if _, isNull := value.(json.Null); isNull do return nil
	switch {
	case type == "Int":
		return i64(valueInt(value))
	case type == "Float":
		#partial switch v in value {
		case json.Integer: return f64(v)
		case json.Float:   return f64(v)
		}
		return nil
	case type == "Bool":
		b, _ := value.(json.Boolean)
		return b
	case type == "Color":
		text, _ := value.(json.String)
		c, ok := ParseColor(text)
		return ok ? LDtkValue(c) : nil
	case type == "Point":
		o, _ := value.(json.Object)
		return LDtkGridPoint{jInt(o, "cx"), jInt(o, "cy")}
	case type == "Tile":
		rect, ok := parseTileRect(value.(json.Object) or_else nil)
		return ok ? LDtkValue(rect) : nil
	case type == "EntityRef":
		o, _ := value.(json.Object)
		return LDtkEntityRef{jString(o, "entityIid"), jString(o, "layerIid"), jString(o, "levelIid"), jString(o, "worldIid")}
	}
	// String, Multilines, FilePath, enums: their text
	if text, ok := value.(json.String); ok do return strings.clone(text)
	return nil
}

@(private="file")
parseTileRect :: proc(o: json.Object) -> (LDtkTilesetRect, bool) {
	if o == nil || !("tilesetUid" in o) do return {}, false
	return {jInt(o, "tilesetUid"), jInt(o, "x"), jInt(o, "y"), jInt(o, "w"), jInt(o, "h")}, true
}

@(private="file")
parseLayerType :: proc(text: string) -> LDtkLayerType {
	switch text {
	case "Entities":  return .Entities
	case "Tiles":     return .Tiles
	case "AutoLayer": return .AutoLayer
	}
	return .IntGrid
}

@(private="file")
parseLayout :: proc(text: string) -> LDtkWorldLayout {
	switch text {
	case "GridVania":        return .GridVania
	case "LinearHorizontal": return .LinearHorizontal
	case "LinearVertical":   return .LinearVertical
	}
	return .Free
}

// The folder of a "/"-separated path ("" for a bare file name)
@(private="file")
ldtkFolder :: proc(path: string) -> string {
	slash := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return slash < 0 ? "" : path[:slash]
}

// JSON readers: missing or mistyped values give the default (strings are cloned with
// context.allocator, the project's arena)

@(private="file")
jObject :: proc(o: json.Object, key: string) -> json.Object {
	if o == nil do return nil
	v, _ := o[key].(json.Object)
	return v
}

@(private="file")
jArray :: proc(o: json.Object, key: string) -> []json.Value {
	if o == nil do return nil
	v, _ := o[key].(json.Array)
	return v[:]
}

@(private="file")
jString :: proc(o: json.Object, key: string) -> string {
	if o == nil do return ""
	v, ok := o[key].(json.String)
	return ok ? strings.clone(v) : ""
}

@(private="file")
jInt :: proc(o: json.Object, key: string, default := 0) -> int {
	if o == nil || !(key in o) do return default
	if _, isNull := o[key].(json.Null); isNull do return default
	return valueInt(o[key])
}

@(private="file")
jFloat :: proc(o: json.Object, key: string, default: f32 = 0) -> f32 {
	if o == nil do return default
	#partial switch v in o[key] {
	case json.Integer: return f32(v)
	case json.Float:   return f32(v)
	}
	return default
}

@(private="file")
jBool :: proc(o: json.Object, key: string, default := false) -> bool {
	if o == nil do return default
	v, ok := o[key].(json.Boolean)
	return ok ? v : default
}

@(private="file")
jColor :: proc(o: json.Object, key: string, default: sdl.Color) -> sdl.Color {
	if o == nil do return default
	text, ok := o[key].(json.String)
	if !ok do return default
	c, valid := ParseColor(text)
	return valid ? c : default
}

@(private="file")
jFloats :: proc(o: json.Object, key: string) -> []f32 {
	list := jArray(o, key)
	values := make([]f32, len(list), context.temp_allocator)
	for v, i in list {
		#partial switch n in v {
		case json.Integer: values[i] = f32(n)
		case json.Float:   values[i] = f32(n)
		}
	}
	return values
}

@(private="file")
jStrings :: proc(o: json.Object, key: string) -> []string {
	list := jArray(o, key)
	values := make([dynamic]string)
	for v in list do if text, ok := v.(json.String); ok do append(&values, strings.clone(text))
	return values[:]
}

@(private="file")
valueInt :: proc(v: json.Value) -> int {
	#partial switch n in v {
	case json.Integer: return int(n)
	case json.Float:   return int(n)
	}
	return 0
}
