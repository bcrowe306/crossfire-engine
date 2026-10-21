package crossfire

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:slice"
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
	    Collision (StaticBody)          IntGrid cells as rectangles (intGridCollision): solid and one-way
	    Spikes (Area)                   an area value's cells (areaValues), named after the value

- **Layers** are made back to front, so LDtk's top layer draws last (on top). Every node is on
  the LDtkLevel node's render layer. Hidden layers (LDtk's eye) are made hidden.
- **Entities**, by their type's rule (`<entity name make component script noScript/>`,
  `LDtkEntityRule`; none: Auto), become: Auto, in order of preference, an instance of the
  component the rule maps (`<entity name="Player" component="components/player.component.xml"/>`),
  what code registered for it (`LDtk_RegisterEntity`), else an `LDtkEntityNode` (draws the
  entity's tile if it has one from an image tileset; outlined in the editor); or what `make`
  says: `Component`, `Code` (its rectangle, warned, if nothing registered it), `Rectangle`, or
  `Skip` (not made). A script is attached when what was made has none: the rule's `script`, else
  (Auto) the one named like the entity (`Player`); `noScript="true"` attaches none. **The entity's fields set the script's
  exported fields** with the same name (case and underscores ignored): ints, floats, bools,
  strings, enums (by value name), colors, points (the pixel middle of their cell). Code finds the
  entity's data with `LDtk_EntityOf(node)`.
- **Collision**: with `intGridCollision` naming an IntGrid layer, each value is a kind
  (`LDtk_CollisionKind`): one-way (`oneWayValues`), an area (`areaValues`), solid (in
  `collisionValues`, or every other non-empty value when that's empty), or nothing. Solid and
  one-way cells become one StaticBody per level (one-way shapes have `oneWay`), each area value
  an Area named after the value, their rectangles merged (greedy: runs along rows, then down)
  so a wall is one shape, not a shape per cell. The body and areas get the node's
  `collisionLayer`, `collisionMask`, `friction` and `restitution`.
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
	// Given: self: ^e.Script
	// A coin in LDtk, with a "value" Int field, gets the Coin script with value set
	Coin :: struct {
		using script: e.Script,
		value: int `export:"default=1"`,
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
	// `collisionValues="1 3"`: the IntGrid values that are solid (empty: every non-empty cell
	// that isn't one-way or an area; "0" alone: none, 0 being LDtk's empty cell)
	collisionValues: [dynamic]int,
	// `oneWayValues="2"`: values that are one-way platforms (bodies pass up through them)
	oneWayValues: [dynamic]int,
	// `areaValues="4"`: values that become Areas (triggers: onCollisionEnter / Exit), one per value,
	// named after the value in LDtk ("Spikes")
	areaValues: [dynamic]int,
	// Make nodes for entities
	spawnEntities: bool,
	// Draw the level's background color and image
	background: bool,
	// Linear filtering for tilesets (off: nearest, for pixel art)
	smoothTiles: bool,
	// What entities become and run, by entity identifier (`<entity>` elements; types without one
	// follow the Auto rules)
	entityComponents: [dynamic]LDtkEntityComponent,
}

/*
What an entity type becomes and which script its entities run (`<entity name="Coin"
component=".." make=".." script=".." noScript="true"/>`, attributes only when not the default).
The first files had only a component: that still means the component.
*/
LDtkEntityComponent :: struct {
	// The entity's identifier in LDtk ("Player")
	entity: string,
	// The component file, relative to the project folder (`make` Component; Auto with one too)
	component: string,
	// What its entities become (Auto: the component when set, else code, else the rectangle)
	make: LDtkEntityMake,
	// The script they run: "" for the one named like the entity (when what's made has none)
	script: string,
	// No script, not even the one named like the entity
	noScript: bool,
}

// Another name for LDtkEntityComponent: what an entity type becomes and runs
LDtkEntityRule :: LDtkEntityComponent

// What an entity type's nodes are
LDtkEntityMake :: enum {
	// The mapped component, else what code registered (`LDtk_RegisterEntity`), else the rectangle
	Auto,
	// The rule's component
	Component,
	// What code registered (`LDtk_RegisterEntity`); the rectangle when nothing did
	Code,
	// Its rectangle (and tile), whatever is mapped or registered
	Rectangle,
	// Nothing: entities of the type aren't made
	Skip,
}

// What an IntGrid value of the collision layer becomes
LDtkCollisionKind :: enum {
	None,
	// Solid collision (a StaticBody's rectangles)
	Solid,
	// One-way platforms: solid from above only (`CollisionShape.oneWay`)
	One_Way,
	// An Area: reports bodies entering and leaving (triggers)
	Area,
}

// The settings an LDtkLevel node starts with
DEFAULT_LDTK_LEVEL_SETTINGS :: LDtkLevelSettings{
	spawnEntities = true,
	background = true,
}

/*
Frees what LDtkLevelSettings own and zeroes them. `SceneData_Destroy` calls it for every node.

Inputs:
- settings: The settings
- allocator: The allocator their strings and lists were made with
*/
LDtkLevelSettings_Destroy :: proc(settings: ^LDtkLevelSettings, allocator := context.allocator) {
	context.allocator = allocator
	delete(settings.file)
	delete(settings.level)
	delete(settings.collisionLayer)
	delete(settings.collisionValues)
	delete(settings.oneWayValues)
	delete(settings.areaValues)
	for m in settings.entityComponents {
		delete(m.entity)
		delete(m.component)
		delete(m.script)
	}
	delete(settings.entityComponents)
	settings^ = {}
}

/*
The LDtkLevel node: what it built, for code that looks at the level.
*/
LDtkLevelNode :: struct {
	// The node part: transform, hierarchy, hooks
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
	// The physics settings of the collision bodies it makes
	collision: LDtkCollisionBody,
	// An entity's node was made (when the level is built, and for entities a reload added)
	onEntitySpawned: EventSubject `event:"An entity's node was made (built, or added by a hot reload; data: the node)" data:"node := cast(^e.Node)data.(rawptr)"`,
	// Its LDtk file was saved and the level updated (hot reload, dev runs)
	onReloaded: EventSubject `event:"Its LDtk file changed and the level was updated (dev runs: Play from the editor)"`,
}

// The StaticBody an IntGrid layer becomes: the scene file node's physics attributes
LDtkCollisionBody :: struct {
	// The layers it's on and the layers it collides with (bits: layer n is bit n-1)
	layer, mask: u64,
	// Its surface: friction and bounciness
	friction, restitution: f32,
}

// A level, as built: draws its background
LDtkLevelView :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// The level's data (the project's)
	level: ^LDtkLevel,
	// Its background image (nil for none)
	background: ^sdl.Texture,
	// Draw the background color and image (the scene file's `background`)
	drawBackground: bool,
}

// A layer's tiles (or an IntGrid layer's colored cells, when it has no tiles), drawn in one batch
LDtkTileLayer :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// The layer's data (the project's)
	data: ^LDtkLayer,
	// The tileset's image (nil for an IntGrid layer drawn in colors)
	texture: ^sdl.Texture,
	// The tileset's tile size
	tileSize: f32,
	// IntGrid cells' colors, by value (layers without tiles)
	colors: map[int]sdl.Color,
	// Move with the camera by the layer's parallax factor
	parallax: bool,
	// SDL's software renderer: the whole layer drawn once into a texture of its size, then copied
	// each frame (`ldtkTileLayerDraw`); nil until then, and again after a reload
	cache: ^sdl.Texture,
	// The renderer it was made with
	cacheRenderer: ^sdl.Renderer,
}

// An entity layer's group: moves with the camera when the layer has a parallax factor
LDtkEntityLayer :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// The layer's data (the project's)
	data: ^LDtkLayer,
}

// An entity that no component or spawner took: its rectangle, and its tile if it has one
LDtkEntityNode :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// The entity's data (the project's)
	entity: ^LDtkEntity,
	// Its tile's tileset image (nil: no tile, or one from LDtk's internal icons without a copy)
	texture: ^sdl.Texture,
	// Its tile's rectangle in the image
	src: sdl.FRect,
	// Draw LDtk's shape when it has no tile (tools that build without scripts: the editor)
	outline: bool,
}

// An entity's node and data
LDtkSpawned :: struct {
	// The node made for it (it leaves the list when the node is removed)
	node: ^Node,
	// The entity's data (the project's)
	entity: ^LDtkEntity,
	// The level it's in
	level: ^LDtkLevel,
}

/*
Makes a node for an entity: called with the entity's data, it returns the node (the engine
positions and names it, and adds it to the level). Registered with LDtk_RegisterEntity.
*/
LDtkEntitySpawner :: #type proc(scene: ^Scene, entity: ^LDtkEntity) -> ^Node

/*
Registers what an entity becomes in code, for entities no component is mapped to. Callable from
`@(init)` (contextless, like Script_Register). Registering an identifier again replaces the first.

Inputs:
- identifier: The entity's identifier in LDtk ("Torch")
- spawn: Makes its node

Example:
	package scripts

	import e "engine:."

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
@(private)
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
- game: The game that keeps it
- path: The .ldtk file, relative to the project folder
- projectDir: The project folder ("" for the game's, `Game.projectDir`; tools that build scenes
  pass theirs to Scene_Build)

Returns:
- The project (the game's: don't free it), or nil
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

/*
Drops a project the game read, so it's read again: after the file changed. Nodes still pointing
into it must be gone first (rebuild their scenes).

Inputs:
- game: The game
- path: The .ldtk file as given to `Game_LoadLDtk` ("" for all, the projects replaced by
  reloads too)
*/
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

Inputs:
- root: The LDtkLevel node (nil gives none)
- identifier: The entity's identifier ("Mob")

Returns:
- The nodes
*/
LDtk_FindEntityNodes :: proc(root: ^LDtkLevelNode, identifier: string) -> []^Node {
	nodes := make([dynamic]^Node, context.temp_allocator)
	if root == nil do return nodes[:]
	for s in root.spawned do if s.entity.identifier == identifier do append(&nodes, s.node)
	return nodes[:]
}

/*
The LDtk data of an entity's node (or of a node under it), or nil when it isn't one.

Inputs:
- node: The entity's node, or a node under it

Returns:
- The entity's data (the project's), or nil

Example:
	// Given: self: ^e.Script
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

Inputs:
- root: The LDtkLevel node (nil gives 0)
- layer: The IntGrid layer's identifier
- position: The world position, in game coordinates

Returns:
- The cell's value

Example:
	// Given: self: ^e.Script, level: ^e.LDtkLevelNode
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
	result.oneWayValues = make([dynamic]int)
	append(&result.oneWayValues, ..settings.oneWayValues[:])
	result.areaValues = make([dynamic]int)
	append(&result.areaValues, ..settings.areaValues[:])
	result.entityComponents = make([dynamic]LDtkEntityComponent)
	for m in settings.entityComponents do append(&result.entityComponents, LDtkEntityComponent{strings.clone(m.entity), strings.clone(m.component), m.make, strings.clone(m.script), m.noScript})
	return result
}

/*
Points a built LDtkLevel node at a reloaded project (LDtk_WatchFiles), in place: each level view
at its level (by iid), its layers matched by identifier (updated; layers the file gained are
made and those it lost removed, in LDtk's order again), new tilesets and backgrounds loaded, the
collision body made again. Entities are matched by iid: new ones are spawned, deleted ones
removed, and the others keep running where they are (scripts keep their nodes). Levels the new
file doesn't have keep the old data (alive in the retired project).
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
		for &s in root.spawned do if s.level != nil && s.level.iid == level.iid do s.level = level

		// The layers in LDtk's order (back to front), reusing the nodes there are
		ordered := make([dynamic]^Node, context.temp_allocator)
		#reverse for &l in level.layers {
			switch l.type {
			case .Entities:
				group: ^LDtkEntityLayer
				for child in view.children do if Node_Is(child, LDtkEntityLayer) && (cast(^LDtkEntityLayer)child).data.identifier == l.identifier do group = cast(^LDtkEntityLayer)child
				if group == nil {
					group = makeEntityLayer(root, view, &l)
				} else {
					group.data = &l
					group.position = l.offset
					group.visible = l.visible
				}
				if root.settings.spawnEntities do reloadEntities(root, group, level, &l)
				append(&ordered, group)
			case .IntGrid, .Tiles, .AutoLayer:
				if len(l.tiles) == 0 && len(l.intGrid) == 0 do continue
				tiles: ^LDtkTileLayer
				for child in view.children do if Node_Is(child, LDtkTileLayer) && (cast(^LDtkTileLayer)child).data.identifier == l.identifier do tiles = cast(^LDtkTileLayer)child
				if tiles == nil do tiles = makeTileLayer(root, view, &l)
				else do updateTileLayer(root, tiles, &l)
				append(&ordered, tiles)
			}
		}
		// Layers the file doesn't have any more go; the collision body is made again
		others := make([dynamic]^Node, context.temp_allocator)
		for child in view.children {
			isLayer := Node_Is(child, LDtkTileLayer) || Node_Is(child, LDtkEntityLayer)
			if isLayer && !slice.contains(ordered[:], child) do Scene_RemoveNode(scene, child.id)
			if child.name == "Collision" && Node_Is(child, StaticBody) do Scene_RemoveNode(scene, child.id)
			if !isLayer || !slice.contains(ordered[:], child) do append(&others, child)
		}
		// Draw order is child order: the layers as LDtk has them, then the rest (going ones too:
		// their removal takes them out)
		clear(&view.children)
		append(&view.children, ..ordered[:])
		append(&view.children, ..others[:])
		if root.settings.collisionLayer != "" {
			if l := LDtk_FindLayer(level, root.settings.collisionLayer); l != nil && len(l.intGrid) > 0 {
				buildCollision(view, l, &root.settings, root.collision, root.project)
			}
		}
	}
	Event_Notify(&root.onReloaded, root, nil)
}

/*
A reloaded entity layer's entities, matched by iid against what was spawned in it: new ones
spawned, deleted ones removed, the rest pointed at their new data (their nodes keep running).
*/
@(private="file")
reloadEntities :: proc(root: ^LDtkLevelNode, group: ^LDtkEntityLayer, level: ^LDtkLevel, layer: ^LDtkLayer) {
	spawnedHere := make(map[string]int, context.temp_allocator)
	for s, i in root.spawned do if s.node.parent == group && s.entity != nil do spawnedHere[s.entity.iid] = i
	kept := make(map[string]bool, context.temp_allocator)
	for &entity in layer.entities {
		kept[entity.iid] = true
		if i, found := spawnedHere[entity.iid]; found {
			root.spawned[i].entity = &entity
			continue
		}
		// Scripts attach as when the level was built (`parallax` is set exactly when they did)
		spawnEntity(root, group, level, layer, &entity, &root.settings, root.scene.game.projectDir, root.parallax, 1)
	}
	for iid, i in spawnedHere do if !kept[iid] do Scene_RemoveNode(root.scene, root.spawned[i].node.id)
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
	EventSubject_Init(&root.onEntitySpawned, allocator)
	EventSubject_Init(&root.onReloaded, allocator)
	root.getBounds = ldtkLevelNodeBounds
	root.parallax = attachScripts
	root.settings = cloneSettings(data.ldtk, allocator)
	root.collision = {data.collisionLayer, data.collisionMask, data.friction, data.restitution}
	settings := &data.ldtk
	if settings.file == "" do return root
	project := Game_LoadLDtk(scene.game, settings.file, projectDir)
	root.project = project
	if project == nil || len(project.worlds) == 0 do return root

	placed, found := LDtk_PlacedLevels(project, settings^, context.temp_allocator)
	if !found {
		log.errorf("LDtk: %s has no level '%s'", settings.file, settings.level)
		return root
	}
	for p in placed do buildLevel(root, p.level, p.position, data, projectDir, attachScripts, depth)
	return root
}

// A level a level node builds, and where in the node it goes
LDtkPlacedLevel :: struct {
	level: ^LDtkLevel,
	position: [2]f32,
}

/*
The levels a level node builds, where each goes in the node: the chosen one (`settings.level`, by
identifier or iid; "" for the first) at the node's origin, or with `allLevels` every level of its
world, at its world position (laid end to end in linear worlds).

Inputs:
- project: The parsed project
- settings: The level node's settings
- allocator: For the list

Returns:
- The levels, and false when the chosen level isn't in the project
*/
LDtk_PlacedLevels :: proc(project: ^LDtkProject, settings: LDtkLevelSettings, allocator := context.allocator) -> ([]LDtkPlacedLevel, bool) {
	placed := make([dynamic]LDtkPlacedLevel, allocator)
	if project == nil || len(project.worlds) == 0 do return placed[:], true
	world := &project.worlds[0]
	chosen: ^LDtkLevel
	if settings.level != "" {
		for &w in project.worlds {
			for &l in w.levels do if l.identifier == settings.level || l.iid == settings.level {
				chosen, world = &l, &w
			}
		}
		if chosen == nil do return placed[:], false
	} else if len(world.levels) > 0 {
		chosen = &world.levels[0]
	}
	if chosen == nil do return placed[:], true
	if !settings.allLevels {
		append(&placed, LDtkPlacedLevel{chosen, {}})
		return placed[:], true
	}
	at: [2]f32
	for &level in world.levels {
		position := level.world
		if world.layout == .LinearHorizontal || world.layout == .LinearVertical do position = at
		append(&placed, LDtkPlacedLevel{&level, position})
		if world.layout == .LinearHorizontal do at.x += level.size.x
		if world.layout == .LinearVertical do at.y += level.size.y
	}
	return placed[:], true
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
			group := makeEntityLayer(root, view, &l)
			if settings.spawnEntities {
				for &entity in l.entities do spawnEntity(root, group, level, &l, &entity, settings, projectDir, attachScripts, depth)
			}
		case .IntGrid, .Tiles, .AutoLayer:
			if len(l.tiles) == 0 && len(l.intGrid) == 0 do continue
			makeTileLayer(root, view, &l)
		}
	}

	if settings.collisionLayer != "" {
		if l := LDtk_FindLayer(level, settings.collisionLayer); l != nil && len(l.intGrid) > 0 {
			buildCollision(view, l, &root.settings, root.collision, root.project)
		} else if l == nil {
			log.warnf("LDtk: level %s has no layer '%s' for collision", level.identifier, settings.collisionLayer)
		}
	}
}

// An entity layer's group node under a level view (buildLevel, reloadLevelNode)
@(private="file")
makeEntityLayer :: proc(root: ^LDtkLevelNode, view: ^LDtkLevelView, l: ^LDtkLayer) -> ^LDtkEntityLayer {
	group := CreateNode(root.scene, LDtkEntityLayer)
	group.name = strings.clone(l.identifier, Node_GetAllocator(group))
	group.position = l.offset
	group.layer = view.layer
	group.visible = l.visible
	group.data = l
	if root.parallax && l.parallax != {} do group.update = ldtkEntityLayerUpdate
	Node_AddChild(view, group)
	return group
}

// A tile (or IntGrid) layer's node under a level view (buildLevel, reloadLevelNode)
@(private="file")
makeTileLayer :: proc(root: ^LDtkLevelNode, view: ^LDtkLevelView, l: ^LDtkLayer) -> ^LDtkTileLayer {
	tiles := CreateNode(root.scene, LDtkTileLayer)
	tiles.name = strings.clone(l.identifier, Node_GetAllocator(tiles))
	tiles.layer = view.layer
	tiles.draw = ldtkTileLayerDraw
	tiles.getBounds = ldtkTileLayerBounds
	tiles.destroy = ldtkTileLayerDestroy
	tiles.parallax = root.parallax && l.parallax != {}
	if len(l.intGrid) > 0 && (len(l.tiles) == 0 || l.tilesetPath == "") do tiles.colors = make(map[int]sdl.Color, Node_GetAllocator(tiles))
	updateTileLayer(root, tiles, l)
	Node_AddChild(view, tiles)
	return tiles
}

// Points a tile layer node at its layer's data: position, visibility, tileset, colors
@(private="file")
updateTileLayer :: proc(root: ^LDtkLevelNode, tiles: ^LDtkTileLayer, l: ^LDtkLayer) {
	rm := &root.scene.game.resourceManager
	// Drawn again from the new data
	dropTileCache(tiles)
	tiles.data = l
	tiles.position = l.offset
	tiles.visible = l.visible
	tiles.tileSize = f32(l.gridSize)
	if len(l.tiles) > 0 && l.tilesetPath != "" {
		tiles.texture = rm->loadTexture(l.tilesetPath)
		if tiles.texture != nil do sdl.SetTextureScaleMode(tiles.texture, root.settings.smoothTiles ? .LINEAR : .NEAREST)
		if tileset := LDtk_FindTileset(root.project, l.tileset); tileset != nil && tileset.gridSize > 0 do tiles.tileSize = f32(tileset.gridSize)
	}
	if tiles.colors != nil {
		clear(&tiles.colors)
		if def := LDtk_FindLayerDef(root.project, l.identifier); def != nil do for v in def.intGridValues do tiles.colors[v.value] = v.color
	}
}

@(private="file")
spawnEntity :: proc(root: ^LDtkLevelNode, group: ^Node, level: ^LDtkLevel, layer: ^LDtkLayer, entity: ^LDtkEntity, settings: ^LDtkLevelSettings, projectDir: string, attachScripts: bool, depth: int) {
	scene := root.scene
	n: ^Node
	made := LDtk_EntityMade(settings, entity.identifier)
	if made == .Skip do return
	// The component it's mapped to
	if made == .Component {
		instance := DEFAULT_SCENE_NODE
		instance.kind = .Component
		instance.component = LDtk_EntityComponent(settings, entity.identifier)
		instance.name = entity.identifier
		n = buildNodes(scene, {instance}, projectDir, context.temp_allocator, attachScripts, depth + 1)[0]
	}
	// Code that makes it
	if made == .Code {
		if spawn, found := ldtkSpawners[entity.identifier]; found do n = spawn(scene, entity)
		else do log.warnf("LDtk: %s is made by code, but nothing registered it (e.LDtk_RegisterEntity): its rectangle instead", entity.identifier)
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
	// A removed entity (a collected coin) leaves the list, so lookups never return a freed node
	n.onExit->subscribe(proc(_: ^EventSubject, source: rawptr, _: EventData, userData: rawptr) {
		root := cast(^LDtkLevelNode)userData
		for s, i in root.spawned do if rawptr(s.node) == source {
			ordered_remove(&root.spawned, i)
			return
		}
	}, root)
	// Once its script and fields are set
	defer Event_Notify(&root.onEntitySpawned, root, rawptr(n))

	if !attachScripts do return
	// The rule's script, else one named like the entity; its fields from the entity's
	if n.script.info == nil {
		name, _ := LDtk_EntityScript(settings, entity.identifier, false)
		if info := name != "" ? Script_Find(name) : nil; info != nil {
			Node_AttachScript(n, info, entityProps(info, entity, layer.gridSize))
		} else if rule := LDtk_EntityRule(settings, entity.identifier); rule.script != "" {
			log.warnf("LDtk: %s's script %s isn't registered (are the scripts built?)", entity.identifier, rule.script)
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
			if !LDtk_FieldMatches(field.name, f.identifier) do continue
			if text, ok := LDtk_ValueText(f.value, gridSize); ok do append(&props, ScriptPropData{field.name, text})
		}
	}
	return props[:]
}

/*
How a level node builds an entity (`spawnEntity`), in order: the component mapped to its type
(`LDtkLevelSettings.entityComponents`), else code registered for it (`LDtk_RegisterEntity`), else
its rectangle (and tile); then, if what was built has no script, the script named like the type
(`Script_Find(identifier)`). Its LDtk fields set the script fields whose names match
(`LDtk_FieldMatches`). Editors describe it with these procedures.

Inputs:
- settings: The level node's settings
- identifier: The entity type ("Coin")

Returns:
- The component its type is mapped to, or "" for none
*/
LDtk_EntityComponent :: proc(settings: ^LDtkLevelSettings, identifier: string) -> string {
	rule := LDtk_EntityRule(settings, identifier)
	if rule.make != .Auto && rule.make != .Component do return ""
	return rule.component
}

/*
An entity type's rule: what its entities become and run (zero, Auto everything, when the node
has none for it).

Inputs:
- settings: The level node's settings
- identifier: The entity type

Returns:
- The rule (its strings are the settings')
*/
LDtk_EntityRule :: proc(settings: ^LDtkLevelSettings, identifier: string) -> LDtkEntityRule {
	for m in settings.entityComponents do if m.entity == identifier do return m
	return {entity = identifier}
}

/*
What an entity type's nodes are, its rule resolved: Auto becomes the mapped component, else Code
when code registered it (`LDtk_HasSpawner`: never in an editor), else Rectangle; a Component rule
without a component is a Rectangle.

Inputs:
- settings: The level node's settings
- identifier: The entity type

Returns:
- Component, Code, Rectangle or Skip
*/
LDtk_EntityMade :: proc(settings: ^LDtkLevelSettings, identifier: string) -> LDtkEntityMake {
	rule := LDtk_EntityRule(settings, identifier)
	switch rule.make {
	case .Auto:
		if rule.component != "" do return .Component
		if LDtk_HasSpawner(identifier) do return .Code
		return .Rectangle
	case .Component:
		return rule.component != "" ? .Component : .Rectangle
	case .Code, .Rectangle, .Skip:
		return rule.make
	}
	return .Rectangle
}

/*
The script an entity type's nodes run: the rule's, else (Auto) the one named like the type, but
only when what's made has no script of its own (a component's root may).

Inputs:
- settings: The level node's settings
- identifier: The entity type
- builtHasScript: What's made has a script already

Returns:
- The script's name ("" for none) and whether the rule names it (false: named like the entity)
*/
LDtk_EntityScript :: proc(settings: ^LDtkLevelSettings, identifier: string, builtHasScript: bool) -> (name: string, chosen: bool) {
	rule := LDtk_EntityRule(settings, identifier)
	if rule.noScript || builtHasScript do return "", false
	if rule.script != "" do return rule.script, true
	return identifier, false
}

/*
What an IntGrid value of the collision layer becomes: one-way or an area when listed so, solid
when listed solid, or (no solid values listed) every other non-empty value.

Inputs:
- settings: The level node's settings
- value: The cell's value

Returns:
- Its kind (None for 0)
*/
LDtk_CollisionKind :: proc(settings: ^LDtkLevelSettings, value: int) -> LDtkCollisionKind {
	if value == 0 do return .None
	for v in settings.oneWayValues do if v == value do return .One_Way
	for v in settings.areaValues do if v == value do return .Area
	if LDtk_IsCollisionValue(settings.collisionValues[:], value) do return .Solid
	return .None
}

/*
Whether code registered a spawner for an entity type (`LDtk_RegisterEntity`): the game's own
build has them; an editor (without the game's scripts) never does.

Inputs:
- identifier: The entity type

Returns:
- true when a spawner makes its nodes
*/
LDtk_HasSpawner :: proc(identifier: string) -> bool {
	return identifier in ldtkSpawners
}

/*
Whether an IntGrid value is solid for a level node's collision: any value but 0 when the node
lists none, else one it lists.

Inputs:
- values: The node's collision values (`LDtkLevelSettings.collisionValues`)
- value: The cell's value

Returns:
- true when the cell becomes collision
*/
LDtk_IsCollisionValue :: proc(values: []int, value: int) -> bool {
	if value == 0 do return false
	if len(values) == 0 do return true
	for wanted in values do if wanted == value do return true
	return false
}

/*
Whether a script field takes an LDtk field's value: their names match, ignoring case and
underscores ("maxSpeed" matches LDtk's "max_speed", "MaxSpeed" and "Max_speed").

Inputs:
- scriptField: The script field's name
- ldtkField: The LDtk field's identifier

Returns:
- true when they match
*/
LDtk_FieldMatches :: proc(scriptField, ldtkField: string) -> bool {
	a, b := scriptField, ldtkField
	normalize :: proc(s: string) -> string {
		lower := strings.to_lower(s, context.temp_allocator)
		result, _ := strings.remove_all(lower, "_", context.temp_allocator)
		return result
	}
	return normalize(a) == normalize(b)
}

// The cells of an IntGrid layer as rectangles under a StaticBody (merged: runs along rows, then down)
@(private="file")
buildCollision :: proc(view: ^LDtkLevelView, layer: ^LDtkLayer, settings: ^LDtkLevelSettings, physics: LDtkCollisionBody, project: ^LDtkProject = nil) {
	scene := view.scene
	w, h := layer.cells.x, layer.cells.y
	if w <= 0 || h <= 0 do return
	// The cells of one kind (Area: of one value), merged into rectangles: runs along rows, then down
	Want :: struct { kind: LDtkCollisionKind, value: int }
	cellIs :: proc(layer: ^LDtkLayer, settings: ^LDtkLevelSettings, want: Want, x, y: int) -> bool {
		v := LDtk_IntGridAt(layer, x, y)
		kind := LDtk_CollisionKind(settings, v)
		// One-way and solid cells merge with their own kind only
		return kind == want.kind && (want.kind != .Area || v == want.value)
	}
	shapes :: proc(scene: ^Scene, view: ^LDtkLevelView, parent: ^Node, layer: ^LDtkLayer, settings: ^LDtkLevelSettings, want: Want, w, h: int) -> int {
		used := make([]bool, w * h, context.temp_allocator)
		grid := f32(layer.gridSize)
		made := 0
		for y in 0 ..< h {
			for x in 0 ..< w {
				if used[y * w + x] || !cellIs(layer, settings, want, x, y) do continue
				width := 1
				for x + width < w && !used[y * w + x + width] && cellIs(layer, settings, want, x + width, y) do width += 1
				height := 1
				grow: for y + height < h {
					for i in 0 ..< width do if used[(y + height) * w + x + i] || !cellIs(layer, settings, want, x + i, y + height) do break grow
					height += 1
				}
				for j in 0 ..< height do for i in 0 ..< width do used[(y + j) * w + x + i] = true
				shape := CreateCollisionShape(scene, .Rectangle)
				shape.size = {f32(width) * grid, f32(height) * grid}
				shape.position = {(f32(x) + f32(width) * 0.5) * grid, (f32(y) + f32(height) * 0.5) * grid}
				shape.layer = view.layer
				shape.oneWay = want.kind == .One_Way
				Node_AddChild(parent, shape)
				made += 1
			}
		}
		return made
	}
	setUp :: proc(body: ^PhysicsBody, name: string, view: ^LDtkLevelView, layer: ^LDtkLayer, physics: LDtkCollisionBody) {
		body.name = strings.clone(name, Node_GetAllocator(body))
		body.position = layer.offset
		body.layer = view.layer
		body.collisionLayer = physics.layer
		body.collisionMask = physics.mask
		body.friction = physics.friction
		body.restitution = physics.restitution
		Node_AddChild(view, body)
	}
	// Solid and one-way cells: one StaticBody, "Collision"
	body := CreateStaticBody(scene)
	setUp(body, "Collision", view, layer, physics)
	shapes(scene, view, body, layer, settings, {.Solid, 0}, w, h)
	shapes(scene, view, body, layer, settings, {.One_Way, 0}, w, h)
	// Each area value: an Area named after it in LDtk ("Spikes"; else "Area<value>")
	for value in settings.areaValues {
		name := fmt.tprintf("Area%d", value)
		if def := project != nil ? LDtk_FindLayerDef(project, layer.identifier) : nil; def != nil {
			for v in def.intGridValues do if v.value == value && v.identifier != "" do name = v.identifier
		}
		area := CreateArea(scene)
		setUp(area, name, view, layer, physics)
		if shapes(scene, view, area, layer, settings, {.Area, value}, w, h) == 0 do Scene_RemoveNode(scene, area.id)
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
	tint := drawState().tint
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
	// On whole pixels: neighbouring tiles then share exact edges. SDL's software renderer (the
	// editor's viewport) draws axis-aligned quads as rectangles, each rounded on its own, which
	// left 1 px cracks between tiles at some camera positions; pixel art stays crisp too
	place :: proc(p, shift: [2]f32, scale: f32) -> sdl.FPoint {
		q := toScreen(shift + p * scale)
		return {math.round(q.x), math.round(q.y)}
	}
	lo, hi := visibleBox(renderer, shift, scale)

	cell := tiles.tileSize
	// SDL's software renderer: the layer drawn once into a texture, then the part that shows
	// copied each frame (far cheaper than rasterizing every tile's triangles; see below)
	if tiles.texture != nil && len(l.tiles) > 0 && isSoftwareRenderer(renderer) && drawCachedTiles(tiles, renderer, shift, scale, lo, hi, base) do return
	if tiles.texture != nil && len(l.tiles) > 0 {
		// SDL's software renderer (the editor's viewport) turns two triangles sharing an edge into
		// a scaled rectangle copy of the (RLE-encoded) tileset. After zooming at a corner of the
		// viewport those copies stopped drawing for good (the ground vanished; keeping them for
		// tiles away from the edges crashed the editor once). So there each triangle gets its own
		// vertices and SDL rasterizes triangles: correct, if slower (a whole 200 x 30 level at
		// 1000 x 600: about 38 ms against 23)
		software := isSoftwareRenderer(renderer)
		vertices := make([dynamic]sdl.Vertex, 0, len(l.tiles) * 6, context.temp_allocator)
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
			corners := [4]sdl.Vertex{
				{position = place(p, shift, scale), color = color, tex_coord = {u0, v0}},
				{position = place({p.x + cell, p.y}, shift, scale), color = color, tex_coord = {u1, v0}},
				{position = place({p.x + cell, p.y + cell}, shift, scale), color = color, tex_coord = {u1, v1}},
				{position = place({p.x, p.y + cell}, shift, scale), color = color, tex_coord = {u0, v1}},
			}
			if software {
				append(&vertices, corners[0], corners[1], corners[2], corners[0], corners[2], corners[3])
				append(&indices, at, at + 1, at + 2, at + 3, at + 4, at + 5)
			} else {
				append(&vertices, ..corners[:])
				append(&indices, at, at + 1, at + 2, at, at + 2, at + 3)
			}
		}
		if len(vertices) > 0 {
			sdl.SetTextureBlendMode(tiles.texture, GetDrawBlend())
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

// The largest layer, in pixels across, drawn through a cache texture (bigger ones draw tile by tile)
@(private="file")
LDTK_CACHE_MAX_SIZE :: 8192

/*
Draws a tile layer from its cache (made the first time): the visible part of the layer, as one
copy. Only for SDL's software renderer, and only through an unrotated, unmirrored view.

Returns:
- false when it can't (a rotated or mirrored view, a layer too big, no texture): the caller
  draws the tiles one by one
*/
@(private="file")
drawCachedTiles :: proc(tiles: ^LDtkTileLayer, renderer: ^sdl.Renderer, shift: [2]f32, scale: f32, lo, hi: [2]f32, color: sdl.FColor) -> bool {
	t := drawState().transform
	if !Transform2D_IsAxisAligned(t) || t.x.x <= 0 || t.y.y <= 0 do return false
	l := tiles.data
	size := [2]f32{f32(l.cells.x * l.gridSize), f32(l.cells.y * l.gridSize)}
	if size.x <= 0 || size.y <= 0 || size.x > LDTK_CACHE_MAX_SIZE || size.y > LDTK_CACHE_MAX_SIZE do return false
	if tiles.cache == nil || tiles.cacheRenderer != renderer {
		dropTileCache(tiles)
		tiles.cache = buildTileCache(tiles, renderer, size)
		tiles.cacheRenderer = renderer
		if tiles.cache == nil do return false
	}
	// The part that shows, in the layer's pixels: copied to where the draw transform puts it
	from := [2]f32{max(math.floor(lo.x), 0), max(math.floor(lo.y), 0)}
	to := [2]f32{min(math.ceil(hi.x), size.x), min(math.ceil(hi.y), size.y)}
	if to.x <= from.x || to.y <= from.y do return true
	a := toScreen(shift + from * scale)
	b := toScreen(shift + to * scale)
	src := sdl.FRect{from.x, from.y, to.x - from.x, to.y - from.y}
	// On whole pixels, as the tiles are
	dst := sdl.FRect{math.round(a.x), math.round(a.y), math.round(b.x) - math.round(a.x), math.round(b.y) - math.round(a.y)}
	sdl.SetTextureColorModFloat(tiles.cache, color.r, color.g, color.b)
	sdl.SetTextureAlphaModFloat(tiles.cache, color.a)
	sdl.SetTextureBlendMode(tiles.cache, GetDrawBlend())
	sdl.RenderTexture(renderer, tiles.cache, &src, &dst)
	return true
}

// The layer's tiles at 1:1 into a new target texture (transparent elsewhere), or nil
@(private="file")
buildTileCache :: proc(tiles: ^LDtkTileLayer, renderer: ^sdl.Renderer, size: [2]f32) -> ^sdl.Texture {
	texture := sdl.CreateTexture(renderer, .RGBA32, .TARGET, i32(size.x), i32(size.y))
	if texture == nil do return nil
	sdl.SetTextureScaleMode(texture, .NEAREST)
	target := RenderTarget{texture = texture, size = size}
	RenderTarget_Begin(renderer, &target, clear = true)
	defer RenderTarget_End(renderer, &target)
	// The tiles unscaled, so SDL copies rectangles 1:1 (the scaled copies were what broke)
	sdl.SetTextureBlendMode(tiles.texture, sdl.BLENDMODE_BLEND)
	sdl.SetTextureColorMod(tiles.texture, 255, 255, 255)
	cell := tiles.tileSize
	for tile in tiles.data.tiles {
		src := sdl.FRect{tile.src.x, tile.src.y, cell, cell}
		dst := sdl.FRect{tile.px.x, tile.px.y, cell, cell}
		sdl.SetTextureAlphaModFloat(tiles.texture, tile.alpha)
		flip := sdl.FlipMode(c.int(tile.flipX ? 1 : 0) | c.int(tile.flipY ? 2 : 0))
		if flip == .NONE do sdl.RenderTexture(renderer, tiles.texture, &src, &dst)
		else do sdl.RenderTextureRotated(renderer, tiles.texture, &src, &dst, 0, nil, flip)
	}
	sdl.SetTextureAlphaModFloat(tiles.texture, 1)
	return texture
}

// Frees a tile layer's cache texture (it's made again when next drawn)
@(private="file")
dropTileCache :: proc(tiles: ^LDtkTileLayer) {
	if tiles.cache != nil do sdl.DestroyTexture(tiles.cache)
	tiles.cache, tiles.cacheRenderer = nil, nil
}

@(private="file")
ldtkTileLayerDestroy :: proc(node: ^Node) {
	dropTileCache(cast(^LDtkTileLayer)node)
}

// Whether a renderer is SDL's software renderer
@(private="file")
isSoftwareRenderer :: proc(renderer: ^sdl.Renderer) -> bool {
	name := sdl.GetRendererName(renderer)
	return name != nil && string(name) == "software"
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
	inverse := Transform2D_Inverse(drawState().transform)
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

Inputs:
- node: The entity's node, or a node under it
- field: The EntityRef field's identifier

Returns:
- The referenced entity's node, or nil

Example:
	// Given: self: ^e.Script
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

/*
The nodes an `Array<EntityRef>` field points at (temp allocated; entities that weren't built
are left out).

Inputs:
- node: The entity's node, or a node under it
- field: The field's identifier

Returns:
- The nodes (none when the node isn't an entity's or the field isn't an EntityRef array)
*/
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

/*
An entity's node by its iid (what EntityRef fields hold).

Inputs:
- root: The LDtkLevel node (nil gives nil)
- iid: The entity's iid

Returns:
- The node, or nil when no entity built under `root` has that iid
*/
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
