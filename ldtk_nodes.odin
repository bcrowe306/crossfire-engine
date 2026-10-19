package engine

import "core:c"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

/*
LDtk levels in scenes: an `LDtkLevel` node (scene files: `<node kind="LDtkLevel" ldtk="..."
level="..."/>`) builds a level of an LDtk project (ldtk.odin) under itself when the scene is
built. Its top-left corner is at the node's position; the nodes it makes aren't in the scene
file, like a component's.

	LDtkLevel (LDtkLevelNode)           the node in the scene file
	  Level_0 (LDtkLevelView)           the level: its background (color, image); getBounds
	    Bg_textures (LDtkTileLayer)     a layer's tiles, drawn in one batch; IntGrid cells
	    Collisions (LDtkTileLayer)      without tiles are drawn in their value's color
	    Entities (Node)                 an entity layer: one node per entity, at its pivot
	      Player ...
	    Collision (StaticBody)          IntGrid cells as rectangles (intGridCollision)

- **Layers** are made back to front, so LDtk's top layer draws last (on top). Every node is on
  the LDtkLevel node's render layer. Hidden layers (LDtk's eye) are made hidden.
- **Entities**, in order of preference, become: an instance of the component the node maps the
  entity to (`<entity name="Player" component="components/player.component.xml"/>`); what code
  registered for it (`LDtk_RegisterEntity`); else an `LDtkEntityNode` (draws the entity's tile
  if it has one from an image tileset; outlined in the editor). A script named like the entity
  (`Player`) is attached to it when it has none. **The entity's fields set the script's
  exported fields** with the same name (case and underscores ignored): ints, floats, bools,
  strings, enums (by value name), colors, points (the pixel middle of their cell). Code finds the
  entity's data with `LDtk_EntityOf(node)`.
- **Collision**: with `intGridCollision` naming an IntGrid layer, its cells (those in
  `collisionValues`, or every non-empty one) become one StaticBody per level, its rectangles
  merged (greedy: runs along rows, then down) so a wall is one shape, not a shape per cell. The
  body gets the node's `collisionLayer`, `collisionMask`, `friction` and `restitution`.
- **allLevels** builds every level of the level's world at its place in it (Free and GridVania:
  worldX, worldY; linear layouts: one after the other), for worlds that scroll from level to
  level.
- Projects are read once per game and kept (`Game_LoadLDtk`): every LDtkLevel node of a file
  shares one, and the data the nodes point at lives as long as the game (`Game_ForgetLDtk`
  drops it, for tools whose file changed).
- Tilesets draw with nearest filtering (pixel art) unless `smoothTiles`.

Later (not built): parallax layers, LDtk's tile render modes for entities (they're fitted inside),
entity references resolved to nodes, culling large layers to the view.

Example:
	// A coin in LDtk, with a "value" Int field, gets the Coin script with value set
	Coin :: struct {
		using script: e.Script,
		value: int `export:"" default=1`,
	}
	// Elsewhere: the level's data
	level := cast(^e.LDtkLevelNode)e.Scene_FindNode(self.scene, "Level")
	for mob in e.LDtk_FindEntityNodes(level, "Mob") do log.infof("a mob at %v", mob.position)
	solid := e.LDtk_IntGridAtPosition(level, "Collisions", e.Node_GetWorldPosition(self.node)) != 0
*/

// What a scene file's LDtkLevel node says (SceneNodeData.ldtk)
LDtkLevelSettings :: struct {
	// The .ldtk file, relative to the project folder
	file: string,
	// The level's identifier (or iid); "" for the first level
	level: string,
	// Every level of the level's world, each at its place in the world
	allLevels: bool,
	// The IntGrid layer whose cells become collision ("" for none), and which values (none: every
	// non-empty cell)
	collisionLayer: string,
	collisionValues: [dynamic]int,
	// Make nodes for entities
	spawnEntities: bool,
	// Draw the level's background color and image
	background: bool,
	// Linear filtering for tilesets (off: nearest, for pixel art)
	smoothTiles: bool,
	// Components entities become, by entity identifier
	entityComponents: [dynamic]LDtkEntityComponent,
}

// An entity identifier and the component its entities become
LDtkEntityComponent :: struct {
	entity: string,
	component: string,
}

// The settings an LDtkLevel node starts with
DEFAULT_LDTK_LEVEL_SETTINGS :: LDtkLevelSettings{
	spawnEntities = true,
	background = true,
}

// Frees what LDtkLevelSettings own (allocated with `allocator`)
LDtkLevelSettings_Destroy :: proc(settings: ^LDtkLevelSettings, allocator := context.allocator) {
	context.allocator = allocator
	delete(settings.file)
	delete(settings.level)
	delete(settings.collisionLayer)
	delete(settings.collisionValues)
	for m in settings.entityComponents {
		delete(m.entity)
		delete(m.component)
	}
	delete(settings.entityComponents)
	settings^ = {}
}

/*
The LDtkLevel node: what it built, for code that looks at the level.
*/
LDtkLevelNode :: struct {
	using node: Node,
	// The project (the game's: Game_LoadLDtk), nil when it couldn't be read
	project: ^LDtkProject,
	// One per level built
	views: [dynamic]^LDtkLevelView,
	// Every entity's node, with its data
	spawned: [dynamic]LDtkSpawned,
}

// A level, as built: draws its background
LDtkLevelView :: struct {
	using node: Node,
	level: ^LDtkLevel,
	background: ^sdl.Texture,
	drawBackground: bool,
}

// A layer's tiles (or an IntGrid layer's colored cells, when it has no tiles), drawn in one batch
LDtkTileLayer :: struct {
	using node: Node,
	// The layer's data (the project's)
	data: ^LDtkLayer,
	texture: ^sdl.Texture,
	// The tileset's tile size
	tileSize: f32,
	// IntGrid cells' colors, by value (layers without tiles)
	colors: map[int]sdl.Color,
}

// An entity that no component or spawner took: its rectangle, and its tile if it has one
LDtkEntityNode :: struct {
	using node: Node,
	entity: ^LDtkEntity,
	texture: ^sdl.Texture,
	src: sdl.FRect,
	// Outline it (tools that build without scripts: the editor)
	outline: bool,
}

// An entity's node and data
LDtkSpawned :: struct {
	node: ^Node,
	entity: ^LDtkEntity,
	level: ^LDtkLevel,
}

/*
Makes a node for an entity: called with the entity's data, it returns the node (the engine
positions and names it, and adds it to the level). Registered with LDtk_RegisterEntity.
*/
LDtkEntitySpawner :: #type proc(scene: ^Scene, entity: ^LDtkEntity) -> ^Node

/*
Registers what an entity becomes in code, for entities no component is mapped to. Callable from
`@(init)` (contextless, like Script_Register).

Example:
	@(init)
	registerSpawners :: proc "contextless" () {
		e.LDtk_RegisterEntity("Torch", proc(scene: ^e.Scene, entity: ^e.LDtkEntity) -> ^e.Node {
			return e.CreateParticleEmitter(scene, e.DEFAULT_PARTICLE_SETTINGS)
		})
	}
*/
LDtk_RegisterEntity :: proc "contextless" (identifier: string, spawn: LDtkEntitySpawner) {
	context = Platform_DefaultContext()
	if ldtkSpawners == nil do ldtkSpawners = make(map[string]LDtkEntitySpawner)
	ldtkSpawners[strings.clone(identifier)] = spawn
}

/*
A project, read the first time it's asked for and kept for the game's life (nil, logged, when it
can't be read; asked again, it stays nil until Game_ForgetLDtk).

Inputs:
- path: The .ldtk file, relative to the project folder
- projectDir: The project folder ("" for the game's, `Game.projectDir`; tools that build scenes
  pass theirs to Scene_Build)
*/
Game_LoadLDtk :: proc(game: ^Game, path: string, projectDir := "") -> ^LDtkProject {
	if project, found := game.ldtk[path]; found do return project
	if game.ldtk == nil do game.ldtk = make(map[string]^LDtkProject)
	project, problem := LDtk_Load(JoinPath(projectDir == "" ? game.projectDir : projectDir, path))
	if project == nil do log.errorf("LDtk: %s", problem)
	game.ldtk[strings.clone(path)] = project
	return project
}

// Drops a project the game read ("" for all), so it's read again: after the file changed
Game_ForgetLDtk :: proc(game: ^Game, path: string = "") {
	for key, project in game.ldtk {
		if path != "" && key != path do continue
		LDtk_Destroy(project)
		delete_key(&game.ldtk, key)
		delete(key)
		if path != "" do break
	}
	if path == "" {
		delete(game.ldtk)
		game.ldtk = nil
	}
}

/*
The nodes made for an entity identifier, in level and layer order (temp allocated).
*/
LDtk_FindEntityNodes :: proc(root: ^LDtkLevelNode, identifier: string) -> []^Node {
	nodes := make([dynamic]^Node, context.temp_allocator)
	if root == nil do return nodes[:]
	for s in root.spawned do if s.entity.identifier == identifier do append(&nodes, s.node)
	return nodes[:]
}

/*
The LDtk data of an entity's node (or of a node under it), or nil when it isn't one.

Example:
	entity := e.LDtk_EntityOf(self.node)
	speed := e.LDtk_FieldValue(entity.fields, "speed", f64(100))
*/
LDtk_EntityOf :: proc(node: ^Node) -> ^LDtkEntity {
	for n := node; n != nil; n = n.parent {
		for p := n.parent; p != nil; p = p.parent {
			if !Node_Is(p, LDtkLevelNode) do continue
			for s in (cast(^LDtkLevelNode)p).spawned do if s.node == n do return s.entity
			break
		}
	}
	return nil
}

/*
An IntGrid layer's value under a world position: 0 when empty, outside the levels, or when no
level has that layer.

Example:
	onLadder := e.LDtk_IntGridAtPosition(level, "Collisions", e.Node_GetWorldPosition(self.node)) == 3
*/
LDtk_IntGridAtPosition :: proc(root: ^LDtkLevelNode, layer: string, position: [2]f32) -> int {
	if root == nil do return 0
	for view in root.views {
		local := Transform2D_Apply(Transform2D_Inverse(Node_GetWorldTransform(view)), position)
		if local.x < 0 || local.y < 0 || local.x >= view.level.size.x || local.y >= view.level.size.y do continue
		l := LDtk_FindLayer(view.level, layer)
		if l == nil || l.gridSize <= 0 do return 0
		cell := (local - l.offset) / f32(l.gridSize)
		return LDtk_IntGridAt(l, int(cell.x), int(cell.y))
	}
	return 0
}

// INTERNAL

// Entity spawners by identifier (LDtk_RegisterEntity)
@(private="file")
ldtkSpawners: map[string]LDtkEntitySpawner

/*
Builds a scene file's LDtkLevel node: the levels, their layers, entities and collision (called by
buildNodes, which sets its name, transform and parent after).
*/
@(private)
ldtkBuildNode :: proc(scene: ^Scene, data: ^SceneNodeData, projectDir: string, attachScripts: bool, depth: int) -> ^Node {
	root := CreateNode(scene, LDtkLevelNode)
	allocator := Node_GetAllocator(root)
	root.views = make([dynamic]^LDtkLevelView, allocator)
	root.spawned = make([dynamic]LDtkSpawned, allocator)
	root.getBounds = ldtkLevelNodeBounds
	settings := &data.ldtk
	if settings.file == "" do return root
	project := Game_LoadLDtk(scene.game, settings.file, projectDir)
	root.project = project
	if project == nil || len(project.worlds) == 0 do return root

	// The level, and its world
	world := &project.worlds[0]
	chosen: ^LDtkLevel
	if settings.level != "" {
		for &w in project.worlds {
			for &l in w.levels do if l.identifier == settings.level || l.iid == settings.level {
				chosen, world = &l, &w
			}
		}
		if chosen == nil {
			log.errorf("LDtk: %s has no level '%s'", settings.file, settings.level)
			return root
		}
	} else if len(world.levels) > 0 {
		chosen = &world.levels[0]
	}
	if chosen == nil do return root

	if settings.allLevels {
		at: [2]f32
		for &level in world.levels {
			position := level.world
			if world.layout == .LinearHorizontal || world.layout == .LinearVertical do position = at
			buildLevel(root, &level, position, data, projectDir, attachScripts, depth)
			if world.layout == .LinearHorizontal do at.x += level.size.x
			if world.layout == .LinearVertical do at.y += level.size.y
		}
	} else {
		buildLevel(root, chosen, {}, data, projectDir, attachScripts, depth)
	}
	return root
}

@(private="file")
buildLevel :: proc(root: ^LDtkLevelNode, level: ^LDtkLevel, position: [2]f32, data: ^SceneNodeData, projectDir: string, attachScripts: bool, depth: int) {
	scene := root.scene
	settings := &data.ldtk
	rm := &scene.game.resourceManager
	layer := RenderLayer(clamp(data.layer, 0, len(RenderLayer) - 1))

	view := CreateNode(scene, LDtkLevelView)
	view.name = strings.clone(level.identifier, Node_GetAllocator(view))
	view.position = position
	view.layer = layer
	view.level = level
	view.drawBackground = settings.background
	view.draw = ldtkLevelViewDraw
	view.getBounds = ldtkLevelViewBounds
	if settings.background && level.background.path != "" do view.background = rm->loadTexture(level.background.path)
	Node_AddChild(root, view)
	append(&root.views, view)

	// Back to front: LDtk lists the top layer first
	#reverse for &l in level.layers {
		switch l.type {
		case .Entities:
			group := CreateNode(scene, Node)
			group.name = strings.clone(l.identifier, Node_GetAllocator(group))
			group.position = l.offset
			group.layer = layer
			group.visible = l.visible
			Node_AddChild(view, group)
			if settings.spawnEntities {
				for &entity in l.entities do spawnEntity(root, group, level, &l, &entity, settings, projectDir, attachScripts, depth)
			}
		case .IntGrid, .Tiles, .AutoLayer:
			if len(l.tiles) == 0 && len(l.intGrid) == 0 do continue
			tiles := CreateNode(scene, LDtkTileLayer)
			tiles.name = strings.clone(l.identifier, Node_GetAllocator(tiles))
			tiles.position = l.offset
			tiles.layer = layer
			tiles.visible = l.visible
			tiles.data = &l
			tiles.draw = ldtkTileLayerDraw
			tiles.getBounds = ldtkTileLayerBounds
			tiles.tileSize = f32(l.gridSize)
			if len(l.tiles) > 0 && l.tilesetPath != "" {
				tiles.texture = rm->loadTexture(l.tilesetPath)
				if tiles.texture != nil do sdl.SetTextureScaleMode(tiles.texture, settings.smoothTiles ? .LINEAR : .NEAREST)
				if tileset := LDtk_FindTileset(root.project, l.tileset); tileset != nil && tileset.gridSize > 0 do tiles.tileSize = f32(tileset.gridSize)
			} else if len(l.intGrid) > 0 {
				tiles.colors = make(map[int]sdl.Color, Node_GetAllocator(tiles))
				if def := LDtk_FindLayerDef(root.project, l.identifier); def != nil {
					for v in def.intGridValues do tiles.colors[v.value] = v.color
				}
			}
			Node_AddChild(view, tiles)
		}
	}

	if settings.collisionLayer != "" {
		if l := LDtk_FindLayer(level, settings.collisionLayer); l != nil && len(l.intGrid) > 0 {
			buildCollision(view, l, data)
		} else if l == nil {
			log.warnf("LDtk: level %s has no layer '%s' for collision", level.identifier, settings.collisionLayer)
		}
	}
}

@(private="file")
spawnEntity :: proc(root: ^LDtkLevelNode, group: ^Node, level: ^LDtkLevel, layer: ^LDtkLayer, entity: ^LDtkEntity, settings: ^LDtkLevelSettings, projectDir: string, attachScripts: bool, depth: int) {
	scene := root.scene
	n: ^Node
	// A component mapped to it
	for m in settings.entityComponents {
		if m.entity != entity.identifier || m.component == "" do continue
		instance := DEFAULT_SCENE_NODE
		instance.kind = .Component
		instance.component = m.component
		instance.name = entity.identifier
		n = buildNodes(scene, {instance}, projectDir, context.temp_allocator, attachScripts, depth + 1)[0]
		break
	}
	// Code that makes it
	if n == nil {
		if spawn, found := ldtkSpawners[entity.identifier]; found do n = spawn(scene, entity)
	}
	// Its rectangle (and tile)
	if n == nil {
		node := CreateNode(scene, LDtkEntityNode)
		node.entity = entity
		node.outline = !attachScripts
		node.draw = ldtkEntityDraw
		node.getBounds = ldtkEntityBounds
		if tile, ok := entity.tile.?; ok {
			if tileset := LDtk_FindTileset(root.project, tile.tileset); tileset != nil && !tileset.embedded && tileset.path != "" {
				node.texture = scene.game.resourceManager->loadTexture(tileset.path)
				node.src = {f32(tile.x), f32(tile.y), f32(tile.w), f32(tile.h)}
			}
		}
		n = node
	}
	n.name = strings.clone(entity.identifier, Node_GetAllocator(n))
	n.position = entity.px
	n.layer = group.layer
	Node_AddChild(group, n)
	append(&root.spawned, LDtkSpawned{n, entity, level})

	if !attachScripts do return
	// A script named like the entity, its fields from the entity's
	if n.script.info == nil {
		if info := Script_Find(entity.identifier); info != nil {
			Node_AttachScript(n, info, entityProps(info, entity, layer.gridSize))
		}
	} else {
		for prop in entityProps(n.script.info, entity, layer.gridSize) {
			for field in n.script.info.fields do if field.name == prop.name {
				if !Script_SetField(n.script.data, field, prop.value, Node_GetAllocator(n)) {
					log.warnf("%s.%s: can't use the LDtk value '%s'", n.script.info.name, field.name, prop.value)
				}
			}
		}
	}
}

// An entity's fields as values of the script's fields that have their name (temp allocated)
@(private="file")
entityProps :: proc(info: ^ScriptInfo, entity: ^LDtkEntity, gridSize: int) -> []ScriptPropData {
	props := make([dynamic]ScriptPropData, context.temp_allocator)
	for field in info.fields {
		for f in entity.fields {
			if !sameFieldName(field.name, f.identifier) do continue
			if text, ok := LDtk_ValueText(f.value, gridSize); ok do append(&props, ScriptPropData{field.name, text})
		}
	}
	return props[:]
}

// "maxSpeed" matches LDtk's "max_speed", "MaxSpeed" and "Max_speed"
@(private="file")
sameFieldName :: proc(a, b: string) -> bool {
	normalize :: proc(s: string) -> string {
		lower := strings.to_lower(s, context.temp_allocator)
		result, _ := strings.remove_all(lower, "_", context.temp_allocator)
		return result
	}
	return normalize(a) == normalize(b)
}

// The cells of an IntGrid layer as rectangles under a StaticBody (merged: runs along rows, then down)
@(private="file")
buildCollision :: proc(view: ^LDtkLevelView, layer: ^LDtkLayer, data: ^SceneNodeData) {
	scene := view.scene
	values := data.ldtk.collisionValues[:]
	w, h := layer.cells.x, layer.cells.y
	if w <= 0 || h <= 0 do return
	solid :: proc(layer: ^LDtkLayer, values: []int, x, y: int) -> bool {
		v := LDtk_IntGridAt(layer, x, y)
		if v == 0 do return false
		if len(values) == 0 do return true
		for wanted in values do if wanted == v do return true
		return false
	}
	used := make([]bool, w * h, context.temp_allocator)
	body := CreateStaticBody(scene)
	body.name = strings.clone("Collision", Node_GetAllocator(body))
	body.position = layer.offset
	body.layer = view.layer
	body.collisionLayer = data.collisionLayer
	body.collisionMask = data.collisionMask
	body.friction = data.friction
	body.restitution = data.restitution
	Node_AddChild(view, body)
	grid := f32(layer.gridSize)
	for y in 0 ..< h {
		for x in 0 ..< w {
			if used[y * w + x] || !solid(layer, values, x, y) do continue
			width := 1
			for x + width < w && !used[y * w + x + width] && solid(layer, values, x + width, y) do width += 1
			height := 1
			grow: for y + height < h {
				for i in 0 ..< width do if used[(y + height) * w + x + i] || !solid(layer, values, x + i, y + height) do break grow
				height += 1
			}
			for j in 0 ..< height do for i in 0 ..< width do used[(y + j) * w + x + i] = true
			shape := CreateCollisionShape(scene, .Rectangle)
			shape.size = {f32(width) * grid, f32(height) * grid}
			shape.position = {(f32(x) + f32(width) * 0.5) * grid, (f32(y) + f32(height) * 0.5) * grid}
			shape.layer = view.layer
			Node_AddChild(body, shape)
		}
	}
}

@(private="file")
ldtkLevelNodeBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	root := cast(^LDtkLevelNode)node
	if len(root.views) == 0 do return {}, false
	lo, hi := root.views[0].position, root.views[0].position
	for view in root.views {
		lo = {min(lo.x, view.position.x), min(lo.y, view.position.y)}
		hi = {max(hi.x, view.position.x + view.level.size.x), max(hi.y, view.position.y + view.level.size.y)}
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, true
}

@(private="file")
ldtkLevelViewBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	view := cast(^LDtkLevelView)node
	return {0, 0, view.level.size.x, view.level.size.y}, true
}

@(private="file")
ldtkLevelViewDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	view := cast(^LDtkLevelView)node
	if !view.drawBackground do return
	rect := sdl.FRect{0, 0, view.level.size.x, view.level.size.y}
	DrawRectangle(renderer, &rect, view.level.bgColor)
	if view.background != nil {
		bg := view.level.background
		crop := bg.crop
		if crop.z <= 0 || crop.w <= 0 do crop = {0, 0, f32(view.background.w), f32(view.background.h)}
		dest := sdl.FRect{bg.topLeft.x, bg.topLeft.y, crop.z * bg.scale.x, crop.w * bg.scale.y}
		DrawTexture(renderer, view.background, dest, src = sdl.FRect{crop.x, crop.y, crop.z, crop.w})
	}
}

@(private="file")
ldtkTileLayerBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	tiles := cast(^LDtkTileLayer)node
	l := tiles.data
	return {0, 0, f32(l.cells.x * l.gridSize), f32(l.cells.y * l.gridSize)}, true
}

// Every tile (or IntGrid cell) as two triangles through the draw transform, in one RenderGeometry
@(private="file")
ldtkTileLayerDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	tiles := cast(^LDtkTileLayer)node
	l := tiles.data
	tint := drawTint
	opacity := l.opacity * f32(tint.a) / 255
	base := sdl.FColor{f32(tint.r) / 255, f32(tint.g) / 255, f32(tint.b) / 255, opacity}

	if tiles.texture != nil && len(l.tiles) > 0 {
		vertices := make([]sdl.Vertex, len(l.tiles) * 4, context.temp_allocator)
		indices := make([]c.int, len(l.tiles) * 6, context.temp_allocator)
		size := tiles.tileSize
		tw, th := f32(tiles.texture.w), f32(tiles.texture.h)
		for tile, i in l.tiles {
			u0, v0 := tile.src.x / tw, tile.src.y / th
			u1, v1 := (tile.src.x + size) / tw, (tile.src.y + size) / th
			if tile.flipX do u0, u1 = u1, u0
			if tile.flipY do v0, v1 = v1, v0
			color := base
			color.a *= tile.alpha
			p := tile.px
			corners := [4][2]f32{p, {p.x + size, p.y}, {p.x + size, p.y + size}, {p.x, p.y + size}}
			uvs := [4]sdl.FPoint{{u0, v0}, {u1, v0}, {u1, v1}, {u0, v1}}
			for k in 0 ..< 4 {
				vertices[i * 4 + k] = {position = sdl.FPoint(toScreen(corners[k])), color = color, tex_coord = uvs[k]}
			}
			quad(indices, i)
		}
		sdl.RenderGeometry(renderer, tiles.texture, raw_data(vertices), c.int(len(vertices)), raw_data(indices), c.int(len(indices)))
		return
	}

	// IntGrid cells in their value's color
	if len(l.intGrid) == 0 do return
	count := 0
	for v in l.intGrid do if v != 0 do count += 1
	vertices := make([]sdl.Vertex, count * 4, context.temp_allocator)
	indices := make([]c.int, count * 6, context.temp_allocator)
	grid := f32(l.gridSize)
	i := 0
	for v, index in l.intGrid {
		if v == 0 do continue
		cell := [2]f32{f32(index % l.cells.x), f32(index / l.cells.x)} * grid
		c8 := tiles.colors[int(v)] or_else sdl.Color{255, 255, 255, 255}
		color := sdl.FColor{base.r * f32(c8.r) / 255, base.g * f32(c8.g) / 255, base.b * f32(c8.b) / 255, base.a * f32(c8.a) / 255}
		corners := [4][2]f32{cell, {cell.x + grid, cell.y}, {cell.x + grid, cell.y + grid}, {cell.x, cell.y + grid}}
		for k in 0 ..< 4 do vertices[i * 4 + k] = {position = sdl.FPoint(toScreen(corners[k])), color = color}
		quad(indices, i)
		i += 1
	}
	sdl.RenderGeometry(renderer, nil, raw_data(vertices), c.int(len(vertices)), raw_data(indices), c.int(len(indices)))
}

// The six indices of quad i (corners 0-1-2, 0-2-3)
@(private="file")
quad :: proc(indices: []c.int, i: int) {
	at := c.int(i * 4)
	indices[i * 6 + 0], indices[i * 6 + 1], indices[i * 6 + 2] = at, at + 1, at + 2
	indices[i * 6 + 3], indices[i * 6 + 4], indices[i * 6 + 5] = at, at + 2, at + 3
}

@(private="file")
ldtkEntityBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	entity := (cast(^LDtkEntityNode)node).entity
	return {-entity.pivot.x * entity.size.x, -entity.pivot.y * entity.size.y, entity.size.x, entity.size.y}, true
}

@(private="file")
ldtkEntityDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	self := cast(^LDtkEntityNode)node
	entity := self.entity
	rect, _ := ldtkEntityBounds(node)
	if self.texture != nil && self.src.w > 0 && self.src.h > 0 {
		// Fitted inside the rectangle, keeping its shape, at the middle
		scale := min(rect.w / self.src.w, rect.h / self.src.h)
		w, h := self.src.w * scale, self.src.h * scale
		DrawTexture(renderer, self.texture, {rect.x + (rect.w - w) * 0.5, rect.y + (rect.h - h) * 0.5, w, h}, src = self.src)
	} else if self.outline {
		fill := entity.color
		fill.a = 60
		DrawRectangle(renderer, &rect, fill)
	}
	if self.outline do DrawRectangleOutline(renderer, &rect, entity.color)
}
