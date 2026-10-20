package engine

import "core:c"
import "core:log"
import "core:mem"
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

- **Parallax** (layers with a parallax factor), as LDtk does it: with the camera's middle at c in
  the level, the layer's points p show at c * factor + scale * p (scale = 1 - factor.x with
  parallax scaling; without it, minus half the layer's size times the factor). Tile layers do it
  as they draw; entity layers move their group node in its update (a frame behind a camera that
  moves later). Not in tools (built without scripts): the level shows as it was made.
- **Entities draw as LDtk draws them:** a tile by its definition's tile render mode (Cover,
  FitInside, Repeat, Stretch, FullSizeCropped, FullSizeUncropped, NineSlice) at its tile opacity;
  in tools, without a tile, the definition's shape (Rectangle, Ellipse, Cross; hollow, fill and
  line opacities). LDtk's internal icons only with a copy of them (LDTK_ICONS_FILE).
- **Entity references:** `LDtk_EntityRefNode` / `LDtk_EntityRefNodes` (an EntityRef field's node),
  `LDtk_FindEntityByIid`.
- **Culling:** tile layers draw only the tiles touching the screen (its corners taken back into
  the layer through the draw transform and the parallax).
- **Development runs reload** saved LDtk files (LDtk_WatchFiles).

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
	door := e.LDtk_EntityRefNode(self.node, "door")    // this entity's "door" field's entity
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
	// Layers with a parallax factor move with the camera (not in tools that build without
	// scripts, like the editor: the level shows as it was made)
	parallax: bool,
	// What it was built with (in its arena): for reloading when the file changes
	settings: LDtkLevelSettings,
	collision: LDtkCollisionBody,
}

// The StaticBody an IntGrid layer becomes: the scene file node's physics attributes
LDtkCollisionBody :: struct {
	layer, mask: u64,
	friction, restitution: f32,
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
	// Move with the camera by the layer's parallax factor
	parallax: bool,
}

// An entity layer's group: moves with the camera when the layer has a parallax factor
LDtkEntityLayer :: struct {
	using node: Node,
	data: ^LDtkLayer,
}

// An entity that no component or spawner took: its rectangle, and its tile if it has one
LDtkEntityNode :: struct {
	using node: Node,
	entity: ^LDtkEntity,
	texture: ^sdl.Texture,
	src: sdl.FRect,
	// Draw LDtk's shape when it has no tile (tools that build without scripts: the editor)
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
Development runs (`Game.devKeys`: the editor's Play) watch the LDtk files the game read: saved in
LDtk, a file is read again and every LDtkLevel node of it updated in place (LDtk_WatchFiles,
twice a second). What's updated: tile layers (their tiles, tileset, visibility, IntGrid colors),
backgrounds and the collision body. Entity nodes are left running (scripts may hold them), so
entity changes and layers added or removed show on the next Play. The project replaced is kept
until the game ends: entity nodes point into it.
*/
LDtk_WatchFiles :: proc(game: ^Game, deltaTime: f64) {
	game.ldtkWatchTimer -= deltaTime
	if game.ldtkWatchTimer > 0 do return
	game.ldtkWatchTimer = LDTK_WATCH_SECONDS
	changed := make([dynamic]string, context.temp_allocator)
	for path, _ in game.ldtk {
		if fileModified(JoinPath(game.projectDir, path)) != game.ldtkTimes[path] do append(&changed, path)
	}
	for path in changed {
		project, problem := LDtk_Load(JoinPath(game.projectDir, path))
		game.ldtkTimes[path] = fileModified(JoinPath(game.projectDir, path))
		if project == nil {
			log.errorf("LDtk: reloading %s: %s", path, problem)
			continue
		}
		old := game.ldtk[path]
		if old != nil do append(&game.ldtkRetired, old)
		game.ldtk[path] = project
		count := 0
		reload :: proc(scene: ^Scene, path: string, project: ^LDtkProject, count: ^int) {
			if scene == nil do return
			for node in scene.nodes {
				if !Node_Is(node, LDtkLevelNode) do continue
				root := cast(^LDtkLevelNode)node
				if root.settings.file != path do continue
				reloadLevelNode(root, project)
				count^ += 1
			}
		}
		for _, scene in game.scenes do reload(scene, path, project, &count)
		log.infof("LDtk: reloaded %s (%d level node%s)", path, count, count == 1 ? "" : "s")
	}
}

// How often development runs look at the LDtk files (seconds)
LDTK_WATCH_SECONDS :: 0.5

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
	full := JoinPath(projectDir == "" ? game.projectDir : projectDir, path)
	project, problem := LDtk_Load(full)
	if project == nil do log.errorf("LDtk: %s", problem)
	key := strings.clone(path)
	game.ldtk[key] = project
	// For LDtk_WatchFiles
	if game.ldtkTimes == nil do game.ldtkTimes = make(map[string]i64)
	game.ldtkTimes[key] = fileModified(full)
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
		for project in game.ldtkRetired do LDtk_Destroy(project)
		delete(game.ldtkRetired)
		game.ldtkRetired = nil
		delete(game.ldtkTimes)
		game.ldtkTimes = nil
	} else {
		delete_key(&game.ldtkTimes, path)
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

// A file's modification time (SDL's: on the desktop and in the browser), 0 when it's missing
@(private="file")
fileModified :: proc(path: string) -> i64 {
	info: sdl.PathInfo
	if !sdl.GetPathInfo(strings.clone_to_cstring(path, context.temp_allocator), &info) do return 0
	return i64(info.modify_time)
}

// A copy of a node's settings in an allocator (an LDtkLevel node keeps its own)
@(private="file")
cloneSettings :: proc(settings: LDtkLevelSettings, allocator: mem.Allocator) -> LDtkLevelSettings {
	context.allocator = allocator
	result := settings
	result.file = strings.clone(settings.file)
	result.level = strings.clone(settings.level)
	result.collisionLayer = strings.clone(settings.collisionLayer)
	result.collisionValues = make([dynamic]int)
	append(&result.collisionValues, ..settings.collisionValues[:])
	result.entityComponents = make([dynamic]LDtkEntityComponent)
	for m in settings.entityComponents do append(&result.entityComponents, LDtkEntityComponent{strings.clone(m.entity), strings.clone(m.component)})
	return result
}

/*
Points a built LDtkLevel node at a reloaded project (LDtk_WatchFiles): each level view at its
level (by iid), each tile layer and entity group at its layer (by identifier), new tilesets and
backgrounds loaded, the collision body made again. Layers and levels the new file doesn't have
keep the old data (alive in the retired project).
*/
@(private="file")
reloadLevelNode :: proc(root: ^LDtkLevelNode, project: ^LDtkProject) {
	root.project = project
	scene := root.scene
	rm := &scene.game.resourceManager
	for view in root.views {
		level := LDtk_FindLevel(project, view.level.iid)
		if level == nil do continue
		view.level = level
		view.background = nil
		if root.settings.background && level.background.path != "" do view.background = rm->loadTexture(level.background.path)
		for child in view.children {
			if child.name == "Collision" && Node_Is(child, StaticBody) {
				Scene_RemoveNode(scene, child.id)
				continue
			}
			if Node_Is(child, LDtkEntityLayer) {
				group := cast(^LDtkEntityLayer)child
				if l := LDtk_FindLayer(level, group.data.identifier); l != nil do group.data = l
				continue
			}
			if !Node_Is(child, LDtkTileLayer) do continue
			tiles := cast(^LDtkTileLayer)child
			l := LDtk_FindLayer(level, tiles.data.identifier)
			if l == nil do continue
			tiles.data = l
			tiles.position = l.offset
			tiles.visible = l.visible
			if len(l.tiles) > 0 && l.tilesetPath != "" {
				tiles.texture = rm->loadTexture(l.tilesetPath)
				if tiles.texture != nil do sdl.SetTextureScaleMode(tiles.texture, root.settings.smoothTiles ? .LINEAR : .NEAREST)
				if tileset := LDtk_FindTileset(project, l.tileset); tileset != nil && tileset.gridSize > 0 do tiles.tileSize = f32(tileset.gridSize)
			}
			if tiles.colors != nil {
				clear(&tiles.colors)
				if def := LDtk_FindLayerDef(project, l.identifier); def != nil do for v in def.intGridValues do tiles.colors[v.value] = v.color
			}
		}
		if root.settings.collisionLayer != "" {
			if l := LDtk_FindLayer(level, root.settings.collisionLayer); l != nil && len(l.intGrid) > 0 {
				buildCollision(view, l, root.settings.collisionValues[:], root.collision)
			}
		}
	}
}

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
	root.parallax = attachScripts
	root.settings = cloneSettings(data.ldtk, allocator)
	root.collision = {data.collisionLayer, data.collisionMask, data.friction, data.restitution}
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
			group := CreateNode(scene, LDtkEntityLayer)
			group.name = strings.clone(l.identifier, Node_GetAllocator(group))
			group.position = l.offset
			group.layer = layer
			group.visible = l.visible
			group.data = &l
			if root.parallax && l.parallax != {} do group.update = ldtkEntityLayerUpdate
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
			tiles.parallax = root.parallax && l.parallax != {}
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
			buildCollision(view, l, root.settings.collisionValues[:], root.collision)
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
			// LDtk's internal icons only when the project has a copy (LDTK_ICONS_FILE)
			if tileset := LDtk_FindTileset(root.project, tile.tileset); tileset != nil && tileset.path != "" {
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
buildCollision :: proc(view: ^LDtkLevelView, layer: ^LDtkLayer, values: []int, physics: LDtkCollisionBody) {
	scene := view.scene
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
	body.collisionLayer = physics.layer
	body.collisionMask = physics.mask
	body.friction = physics.friction
	body.restitution = physics.restitution
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

/*
LDtk's parallax for a layer (its Camera.hx): with the camera's middle at `camera` (in the level),
a point `p` of the layer shows at `offset + scale * p`, where offset = camera * factor (minus
half the layer's size times the factor when it doesn't scale) and scale = 1 - factor.x when it
scales, else 1. Without a parallax factor: offset 0, scale 1.
*/
@(private="file")
parallaxOf :: proc(layer: ^LDtkLayer, view: ^Node) -> (offset: [2]f32, scale: f32) {
	scale = 1
	if layer.parallax == {} || view == nil || view.scene == nil do return
	scene := view.scene
	// The camera looks at its world position; without one the view is the game area
	center := scene.camera != nil ? Node_GetWorldPosition(scene.camera) : (scene.game != nil ? scene.game.size * 0.5 : {})
	camera := Transform2D_Apply(Transform2D_Inverse(Node_GetWorldTransform(view)), center)
	offset = camera * layer.parallax
	if layer.parallaxScaling {
		scale = max(0.01, 1 - layer.parallax.x)
	} else {
		size := [2]f32{f32(layer.cells.x * layer.gridSize), f32(layer.cells.y * layer.gridSize)}
		offset -= size * 0.5 * layer.parallax
	}
	return
}

// An entity layer with a parallax factor follows the camera (from its update: a frame behind
// a camera that moves later in the frame; tile layers do it as they draw)
@(private="file")
ldtkEntityLayerUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	group := cast(^LDtkEntityLayer)node
	offset, scale := parallaxOf(group.data, group.parent)
	group.position = offset + scale * group.data.offset
	group.scale = {scale, scale}
}

/*
Every tile (or IntGrid cell) as two triangles through the draw transform, in one RenderGeometry.
Tiles off the screen are skipped: the screen's corners are taken back into the layer and only
tiles touching that box are drawn. A parallax layer moves and scales as it draws (parallaxOf).
*/
@(private="file")
ldtkTileLayerDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	tiles := cast(^LDtkTileLayer)node
	l := tiles.data
	tint := drawTint
	opacity := l.opacity * f32(tint.a) / 255
	base := sdl.FColor{f32(tint.r) / 255, f32(tint.g) / 255, f32(tint.b) / 255, opacity}

	// In the layer's own space, a point p draws at shift + scale * p (parallax; in the level the
	// layer's origin is its offset, which the node's position already holds)
	shift: [2]f32
	scale: f32 = 1
	if tiles.parallax {
		offset, s := parallaxOf(l, node.parent)
		shift, scale = offset + (s - 1) * l.offset, s
	}
	place :: proc(p, shift: [2]f32, scale: f32) -> sdl.FPoint {
		return sdl.FPoint(toScreen(shift + p * scale))
	}
	lo, hi := visibleBox(renderer, shift, scale)

	cell := tiles.tileSize
	if tiles.texture != nil && len(l.tiles) > 0 {
		vertices := make([dynamic]sdl.Vertex, 0, len(l.tiles) * 4, context.temp_allocator)
		indices := make([dynamic]c.int, 0, len(l.tiles) * 6, context.temp_allocator)
		tw, th := f32(tiles.texture.w), f32(tiles.texture.h)
		for tile in l.tiles {
			p := tile.px
			if p.x + cell < lo.x || p.y + cell < lo.y || p.x > hi.x || p.y > hi.y do continue
			u0, v0 := tile.src.x / tw, tile.src.y / th
			u1, v1 := (tile.src.x + cell) / tw, (tile.src.y + cell) / th
			if tile.flipX do u0, u1 = u1, u0
			if tile.flipY do v0, v1 = v1, v0
			color := base
			color.a *= tile.alpha
			at := c.int(len(vertices))
			append(&vertices,
				sdl.Vertex{position = place(p, shift, scale), color = color, tex_coord = {u0, v0}},
				sdl.Vertex{position = place({p.x + cell, p.y}, shift, scale), color = color, tex_coord = {u1, v0}},
				sdl.Vertex{position = place({p.x + cell, p.y + cell}, shift, scale), color = color, tex_coord = {u1, v1}},
				sdl.Vertex{position = place({p.x, p.y + cell}, shift, scale), color = color, tex_coord = {u0, v1}})
			append(&indices, at, at + 1, at + 2, at, at + 2, at + 3)
		}
		if len(vertices) > 0 {
			sdl.RenderGeometry(renderer, tiles.texture, raw_data(vertices), c.int(len(vertices)), raw_data(indices), c.int(len(indices)))
		}
		return
	}

	// IntGrid cells in their value's color
	if len(l.intGrid) == 0 do return
	grid := f32(l.gridSize)
	vertices := make([dynamic]sdl.Vertex, 0, 64, context.temp_allocator)
	indices := make([dynamic]c.int, 0, 96, context.temp_allocator)
	for v, index in l.intGrid {
		if v == 0 do continue
		p := [2]f32{f32(index % l.cells.x), f32(index / l.cells.x)} * grid
		if p.x + grid < lo.x || p.y + grid < lo.y || p.x > hi.x || p.y > hi.y do continue
		c8 := tiles.colors[int(v)] or_else sdl.Color{255, 255, 255, 255}
		color := sdl.FColor{base.r * f32(c8.r) / 255, base.g * f32(c8.g) / 255, base.b * f32(c8.b) / 255, base.a * f32(c8.a) / 255}
		at := c.int(len(vertices))
		append(&vertices,
			sdl.Vertex{position = place(p, shift, scale), color = color},
			sdl.Vertex{position = place({p.x + grid, p.y}, shift, scale), color = color},
			sdl.Vertex{position = place({p.x + grid, p.y + grid}, shift, scale), color = color},
			sdl.Vertex{position = place({p.x, p.y + grid}, shift, scale), color = color})
		append(&indices, at, at + 1, at + 2, at, at + 2, at + 3)
	}
	if len(vertices) > 0 {
		sdl.RenderGeometry(renderer, nil, raw_data(vertices), c.int(len(vertices)), raw_data(indices), c.int(len(indices)))
	}
}

/*
The part of a layer the screen shows, in the layer's space (before parallax): the screen's
corners through the inverse of the draw transform and the parallax. Everything when the output
size isn't known.
*/
@(private="file")
visibleBox :: proc(renderer: ^sdl.Renderer, shift: [2]f32, scale: f32) -> (lo, hi: [2]f32) {
	w, h: c.int
	mode: sdl.RendererLogicalPresentation
	if !sdl.GetRenderLogicalPresentation(renderer, &w, &h, &mode) || w <= 0 || h <= 0 {
		if !sdl.GetCurrentRenderOutputSize(renderer, &w, &h) || w <= 0 || h <= 0 do return {-1e30, -1e30}, {1e30, 1e30}
	}
	inverse := Transform2D_Inverse(drawTransform)
	corners := [4][2]f32{{0, 0}, {f32(w), 0}, {f32(w), f32(h)}, {0, f32(h)}}
	lo, hi = {1e30, 1e30}, {-1e30, -1e30}
	for corner in corners {
		p := (Transform2D_Apply(inverse, corner) - shift) / max(scale, 0.01)
		lo = {min(lo.x, p.x), min(lo.y, p.y)}
		hi = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	return
}

@(private="file")
ldtkEntityBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	entity := (cast(^LDtkEntityNode)node).entity
	return {-entity.pivot.x * entity.size.x, -entity.pivot.y * entity.size.y, entity.size.x, entity.size.y}, true
}

/*
An entity as LDtk draws it: its tile by its definition's tile render mode (LDtkEntityRender.hx's
rules), at its tile opacity; without a tile, in tools (outline), its definition's shape with its
fill and line opacities.
*/
@(private="file")
ldtkEntityDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	self := cast(^LDtkEntityNode)node
	entity := self.entity
	def := entity.def
	rect, _ := ldtkEntityBounds(node)
	pivot := entity.pivot
	if self.texture != nil && self.src.w > 0 && self.src.h > 0 && (def == nil || def.renderMode == .Tile || entity.tile != nil) {
		mode := def != nil ? def.tileRenderMode : LDtkTileRenderMode.FitInside
		alpha := u8(clamp(def != nil ? def.tileOpacity : 1, 0, 1) * 255)
		drawEntityTile(renderer, self.texture, self.src, rect, pivot, mode, def != nil ? def.nineSlice : {}, alpha)
		return
	}
	if !self.outline do return
	color := entity.color
	line := sdl.Color{u8((u32(color.r) * 7 + 255 * 3) / 10), u8((u32(color.g) * 7 + 255 * 3) / 10), u8((u32(color.b) * 7 + 255 * 3) / 10), 255}
	fillOpacity, lineOpacity := f32(0.25), f32(1)
	hollow := false
	shape := LDtkEntityRenderMode.Rectangle
	if def != nil {
		fillOpacity, lineOpacity, hollow = def.fillOpacity, def.lineOpacity, def.hollow
		if def.renderMode != .Tile do shape = def.renderMode
	}
	fill := color
	fill.a = u8(clamp(fillOpacity, 0, 1) * 255)
	line.a = u8(clamp(lineOpacity, 0, 1) * 255)
	switch shape {
	case .Ellipse:
		center := sdl.FPoint{rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
		if !hollow do DrawEllipse(renderer, center, rect.w * 0.5, rect.h * 0.5, fill)
		DrawEllipseOutline(renderer, center, rect.w * 0.5, rect.h * 0.5, line)
	case .Cross:
		DrawLine(renderer, {rect.x, rect.y}, {rect.x + rect.w, rect.y + rect.h}, line)
		DrawLine(renderer, {rect.x + rect.w, rect.y}, {rect.x, rect.y + rect.h}, line)
	case .Rectangle, .Tile:
		if !hollow do DrawRectangle(renderer, &rect, fill)
		DrawRectangleOutline(renderer, &rect, line)
	}
}

/*
A tile in an entity's rectangle, by mode (LDtk's EntityRender.hx): the tile's pivot point (the
entity's pivot, in the tile) goes on the entity's position, the rectangle's origin here.
*/
@(private="file")
drawEntityTile :: proc(renderer: ^sdl.Renderer, texture: ^sdl.Texture, src, rect: sdl.FRect, pivot: [2]f32, mode: LDtkTileRenderMode, nineSlice: [4]f32, alpha: u8) {
	tint := sdl.Color{255, 255, 255, alpha}
	// A tile part of size `size` (in tile pixels) shown at `scale`, pivot on the origin
	atPivot :: proc(size: [2]f32, scale: f32, pivot: [2]f32) -> sdl.FRect {
		return {-size.x * scale * pivot.x, -size.y * scale * pivot.y, size.x * scale, size.y * scale}
	}
	t := [2]f32{src.w, src.h}
	w, h := rect.w, rect.h
	switch mode {
	case .Stretch:
		DrawTexture(renderer, texture, rect, src = src, tint = tint)
	case .FitInside:
		s := min(w / t.x, h / t.y)
		DrawTexture(renderer, texture, atPivot(t, s, pivot), src = src, tint = tint)
	case .Cover:
		s := max(w / t.x, h / t.y)
		f := [2]f32{min(w, t.x * s) / s, min(h, t.y * s) / s}
		part := sdl.FRect{src.x + t.x * pivot.x - f.x * pivot.x, src.y + t.y * pivot.y - f.y * pivot.y, f.x, f.y}
		DrawTexture(renderer, texture, atPivot(f, s, pivot), src = part, tint = tint)
	case .FullSizeCropped:
		f := [2]f32{min(w, t.x), min(h, t.y)}
		part := sdl.FRect{src.x + t.x * pivot.x - f.x * pivot.x, src.y + t.y * pivot.y - f.y * pivot.y, f.x, f.y}
		DrawTexture(renderer, texture, atPivot(f, 1, pivot), src = part, tint = tint)
	case .FullSizeUncropped:
		DrawTexture(renderer, texture, atPivot(t, 1, pivot), src = src, tint = tint)
	case .Repeat:
		tiledRegion(renderer, texture, src, rect, tint)
	case .NineSlice:
		// Borders: top, right, bottom, left; corners at their size, edges and middle repeated
		top, right, bottom, left := nineSlice[0], nineSlice[1], nineSlice[2], nineSlice[3]
		cols := [3][2]f32{{0, left}, {left, t.x - right}, {t.x - right, t.x}}
		rows := [3][2]f32{{0, top}, {top, t.y - bottom}, {t.y - bottom, t.y}}
		dcols := [3][2]f32{{rect.x, rect.x + left}, {rect.x + left, rect.x + w - right}, {rect.x + w - right, rect.x + w}}
		drows := [3][2]f32{{rect.y, rect.y + top}, {rect.y + top, rect.y + h - bottom}, {rect.y + h - bottom, rect.y + h}}
		for r in 0 ..< 3 do for col in 0 ..< 3 {
			part := sdl.FRect{src.x + cols[col][0], src.y + rows[r][0], cols[col][1] - cols[col][0], rows[r][1] - rows[r][0]}
			dest := sdl.FRect{dcols[col][0], drows[r][0], dcols[col][1] - dcols[col][0], drows[r][1] - drows[r][0]}
			if part.w <= 0 || part.h <= 0 || dest.w <= 0 || dest.h <= 0 do continue
			tiledRegion(renderer, texture, part, dest, tint)
		}
	}
}

// A tile part repeated at its size across a rectangle from its top-left corner, the last row and
// column cut to fit
@(private="file")
tiledRegion :: proc(renderer: ^sdl.Renderer, texture: ^sdl.Texture, src, dest: sdl.FRect, tint: sdl.Color) {
	if src.w <= 0 || src.h <= 0 do return
	for y := f32(0); y < dest.h; y += src.h {
		for x := f32(0); x < dest.w; x += src.w {
			cw, ch := min(src.w, dest.w - x), min(src.h, dest.h - y)
			DrawTexture(renderer, texture, {dest.x + x, dest.y + y, cw, ch}, src = sdl.FRect{src.x, src.y, cw, ch}, tint = tint)
		}
	}
}

/*
The node of the entity an EntityRef field points at (`field` on the entity whose node, or a node
under it, is `node`), when that entity was built under the same LDtkLevel node; nil otherwise (no
such field, null, or an entity in a level that wasn't built).

Example:
	// A lever whose "door" field points at a door
	door := e.LDtk_EntityRefNode(self.node, "door")
	if door != nil do door.visible = false
*/
LDtk_EntityRefNode :: proc(node: ^Node, field: string) -> ^Node {
	entity := LDtk_EntityOf(node)
	if entity == nil do return nil
	f := LDtk_FindField(entity.fields, field)
	if f == nil do return nil
	ref, ok := f.value.(LDtkEntityRef)
	if !ok do return nil
	return LDtk_FindEntityByIid(ldtkRootOf(node), ref.entityIid)
}

// The nodes an `Array<EntityRef>` field points at (temp allocated; entities that weren't built
// are left out)
LDtk_EntityRefNodes :: proc(node: ^Node, field: string) -> []^Node {
	nodes := make([dynamic]^Node, context.temp_allocator)
	entity := LDtk_EntityOf(node)
	if entity == nil do return nodes[:]
	f := LDtk_FindField(entity.fields, field)
	if f == nil do return nodes[:]
	list, ok := f.value.([]LDtkValue)
	if !ok do return nodes[:]
	root := ldtkRootOf(node)
	for v in list {
		ref := v.(LDtkEntityRef) or_continue
		if n := LDtk_FindEntityByIid(root, ref.entityIid); n != nil do append(&nodes, n)
	}
	return nodes[:]
}

// An entity's node by its iid (what EntityRef fields hold), or nil
LDtk_FindEntityByIid :: proc(root: ^LDtkLevelNode, iid: string) -> ^Node {
	if root == nil || iid == "" do return nil
	for s in root.spawned do if s.entity.iid == iid do return s.node
	return nil
}

// The LDtkLevel node a node is under (or is), or nil
@(private="file")
ldtkRootOf :: proc(node: ^Node) -> ^LDtkLevelNode {
	for n := node; n != nil; n = n.parent do if Node_Is(n, LDtkLevelNode) do return cast(^LDtkLevelNode)n
	return nil
}
