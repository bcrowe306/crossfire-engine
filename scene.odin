package engine

import "core:log"
import "core:slice"
import "core:strings"
import "core:mem"
import sdl "vendor:sdl3"


Scene :: struct {
	id: EntityId,
	// Its name in the game (`Game_CreateScene`); "" for scenes made another way
	name: string,
	game: ^Game,
	nodes: [dynamic]^Node,
	addQueue: [dynamic]^Node,
	removeQueue: [dynamic]EntityId,
	// Nodes made with `CreateNode(..., addToScene = false)` and not added yet: the scene still
	// owns them, so destroying the scene frees them
	detached: [dynamic]^Node,
	// Every node the scene owns (in it, queued, detached) by id: Scene_GetNode and removals
	index: map[EntityId]^Node,
	arena: MemoryArena,
	// Optional camera, nil by default. When set, every layer not in `screenLayers` is drawn
	// through it, and its pans and bounds are applied after each update. Create with `Scene_CreateCamera`
	camera: ^Camera2D,
	// Layers drawn in screen space, ignoring `camera`. Put HUDs and menus on these layers
	screenLayers: bit_set[RenderLayer],
	// The physics world (physics.odin), nil until the scene's first physics node is created
	physics: ^PhysicsWorld,
	// Don't step the physics (bodies still exist and can be queried). Editors set it: their
	// previews update scenes for animations, and bodies mustn't fall there
	physicsPaused: bool,
	// Paused (`Scene_SetPaused`): physics doesn't step, and only nodes whose process mode allows it
	// update (`Node_CanProcess`); everything still draws
	paused: bool,
	// It has been the current scene before: entering it again rebuilds it from its file
	// (Game.sceneFiles), so every visit starts fresh
	played: bool,
	addNode: proc(scene: ^Scene, node: ^Node),
	removeNode: proc(scene: ^Scene, nodeId: EntityId),
	getNode: proc(scene: ^Scene, nodeId: EntityId) -> ^Node,
	processQueues: proc(scene: ^Scene),
	update: proc(scene: ^Scene, events: []sdl.Event, deltaTime: f64),
	draw: proc(scene: ^Scene, renderer: ^sdl.Renderer),
	onEnter: EventSubject,
	onExit: EventSubject,
}

Scene_Init :: proc(scene: ^Scene) {
	log.debug("Initializing Scene")
	if !MemoryArena_InitGrowing(&scene.arena) {
		log.panic("Failed to initialize the scene's arena")
	}
	scene.addNode = Scene_AddNode
	scene.removeNode = Scene_RemoveNode
	scene.getNode = Scene_GetNode
	scene.update = Scene_Update
	scene.draw = Scene_Draw
	scene.processQueues = Scene_ProcessQueues
	scene.index = make(map[EntityId]^Node)
	EventSubject_Init(&scene.onEnter, Scene_GetAllocator(scene))
	EventSubject_Init(&scene.onExit, Scene_GetAllocator(scene))
}

/*
Allocator backed by the scene's arena. Anything allocated with it is freed all at once when
the scene is destroyed, so it suits data shared by the whole scene. For data that belongs
to one node, prefer `Node_GetAllocator` so it is freed when that node is removed.

Inputs:
- scene: The scene

Returns:
- The scene arena allocator
*/
Scene_GetAllocator :: proc(scene: ^Scene) -> mem.Allocator {
	return MemoryArena_Allocator(&scene.arena)
}

/*
Empties a scene: every node is destroyed and its physics world goes, as Scene_Destroy does, but
the scene itself stays (its name, game, screen layers, physicsPaused), ready to be built again.
Listeners on its onEnter / onExit are dropped with it.
*/
Scene_Clear :: proc(scene: ^Scene) {
	kept := scene^
	Scene_Destroy(scene)
	scene^ = {}
	Scene_Init(scene)
	scene.name, scene.game, scene.screenLayers, scene.physicsPaused, scene.played = kept.name, kept.game, kept.screenLayers, kept.physicsPaused, kept.played
	// Procedures a game replaced stay replaced
	scene.addNode, scene.removeNode, scene.getNode = kept.addNode, kept.removeNode, kept.getNode
	scene.processQueues, scene.update, scene.draw = kept.processQueues, kept.update, kept.draw
}

/*
Destroys every node of a scene and frees what the scene owns (its lists, physics world and arena);
the Scene struct itself is the caller's. Nodes in the scene get `onExit` first, as removed nodes
do; then every node it made (in it, waiting to be added, or never added) is destroyed, children
before their parents, so a `destroy` hook can still reach its parent.

Inputs:
- scene: The scene
*/
Scene_Destroy :: proc(scene: ^Scene) {
	// onExit for nodes in the scene, parents before children (a snapshot: handlers may make or
	// queue nodes, which go below with the rest)
	for node in slice_clone_temp(scene.nodes[:]) {
		if node.parent == nil do notifyExit(node)
	}
	// Every node, once, children first (each lives in its own arena)
	visited := make(map[^Node]bool, context.temp_allocator)
	destroyTree :: proc(node: ^Node, visited: ^map[^Node]bool) {
		if node in visited do return
		visited[node] = true
		for child in node.children do destroyTree(child, visited)
		Node_Destroy(node)
	}
	topOf :: proc(node: ^Node) -> ^Node {
		top := node
		for top.parent != nil do top = top.parent
		return top
	}
	for list in ([][dynamic]^Node{scene.nodes, scene.addQueue, scene.detached}) {
		for node in list do if node not_in visited do destroyTree(topOf(node), &visited)
	}
	// After the nodes: destroying a body node destroys its Box2D body
	Physics_Destroy(scene)
	scene.camera = nil
	delete(scene.addQueue)
	delete(scene.removeQueue)
	delete(scene.detached)
	delete(scene.nodes)
	delete(scene.index)
	// Destroy, not free_all: free_all keeps the first block, which leaked once the scene was freed
	MemoryArena_Destroy(&scene.arena)
}

/*
Creates a node of type T in its own memory arena and (by default) adds it to the scene.

T must be `Node` or a struct that embeds it as its first field (`using node: e.Node`).
The node is freed, along with everything allocated with `Node_GetAllocator(node)`, when
it is removed from the scene or the scene is destroyed.

Inputs:
- scene: The scene the node belongs to
- T: The node type
- addToScene: Add it to the scene (at the start of the next update). Pass false to add it later with `scene->addNode`

Returns:
- The new node, zero-initialized apart from its id, scene and event subjects

Example:
	bullet := e.CreateNode(scene, Bullet)
	bullet.update = Bullet_update
	...
	scene->removeNode(bullet.id) // Freed at the start of the next update
*/
CreateNode :: proc(scene: ^Scene, $T: typeid, addToScene: bool = true) -> ^T {
	newObject := allocateNode(T)
	node := cast(^Node)newObject
	node.id = NewEntityId()
	node.type = T
	node.scene = scene
	Node_Init(node, Node_GetAllocator(node))
	scene.index[node.id] = node
	if addToScene {
		Scene_AddNode(scene, node)
	} else {
		append(&scene.detached, node)
	}
	return newObject
}

/*
Adds a node to its scene at the start of the next update (it gets `onEnter` then). For nodes made
with `CreateNode(..., addToScene = false)`; adding a node twice, or one of another scene, does
nothing.

Inputs:
- scene: The node's scene
- node: The node
*/
Scene_AddNode :: proc(scene: ^Scene, node: ^Node) {
	if node.scene != scene {
		log.errorf("Scene_AddNode: the node belongs to another scene")
		return
	}
	if node.inScene || node.queued do return
	if len(scene.detached) > 0 do removeFromList(&scene.detached, node)
	node.queued = true
	append(&scene.addQueue, node)
}

/*
Removes a node, with its children, at the start of the next update: they get `onExit`, then their
`destroy` hooks, then their memory is freed. Pointers to them are invalid after that. Removing
a node twice, or one already gone, does nothing.

Inputs:
- scene: The node's scene
- nodeId: The node's `id`
*/
Scene_RemoveNode :: proc(scene: ^Scene, nodeId: EntityId) {
	append(&scene.removeQueue, nodeId)
}

/*
A node of the scene by its id: in the scene, waiting to be added, or made without being added.

Returns:
- The node, or nil (never made here, or already removed)
*/
Scene_GetNode :: proc(scene: ^Scene, nodeId: EntityId) -> ^Node {
	return findQueuedOrLive(scene, nodeId)
}

/*
Applies queued removals, then queued additions (`onEnter` for each, in the order they were
added). `Scene_Update` does it first; editors and tests call it to apply changes without
updating.
*/
Scene_ProcessQueues :: proc(scene: ^Scene) {
	if len(scene.removeQueue) > 0 do processRemovals(scene)

	// By index: an onEnter handler can make more nodes, which join in the same pass
	for i := 0; i < len(scene.addQueue); i += 1 {
		node := scene.addQueue[i]
		node.queued = false
		node.inScene = true
		append(&scene.nodes, node)
		node.onEnter->notify(node, nil)
	}
	clear(&scene.addQueue)
}

/*
The frame's removals, as one batch: each removed subtree gets onExit (parents first) while every
node is still alive; then the scene's lists drop them in one pass each (the rest keep their
order); then they're freed, children before parents. Cost O(nodes + removed), not O(nodes x
removed): removing 500 of 5500 nodes took 17 ms one by one.
*/
@(private="file")
processRemovals :: proc(scene: ^Scene) {
	pending := make(map[^Node]bool, 2 * len(scene.removeQueue), context.temp_allocator)
	roots := make([dynamic]^Node, 0, len(scene.removeQueue), context.temp_allocator)
	exit :: proc(node: ^Node, pending: ^map[^Node]bool) {
		pending[node] = true
		if node.inScene do node.onExit->notify(node, nil)
		node.inScene = false
		node.queued = false
		for child in slice_clone_temp(node.children[:]) do if child not_in pending do exit(child, pending)
	}
	// By index: an exit handler can queue more removals, which join this batch
	for i := 0; i < len(scene.removeQueue); i += 1 {
		node := scene.index[scene.removeQueue[i]] or_else nil
		if node == nil || node in pending do continue
		if node.parent != nil && node.parent not_in pending {
			removeChild(node.parent, node)
			node.parent = nil
		}
		append(&roots, node)
		exit(node, &pending)
	}
	clear(&scene.removeQueue)

	keep :: proc(list: ^[dynamic]^Node, pending: ^map[^Node]bool) {
		kept := 0
		for node in list^ {
			if node in pending do continue
			list[kept] = node
			kept += 1
		}
		resize(list, kept)
	}
	keep(&scene.nodes, &pending)
	keep(&scene.addQueue, &pending)
	keep(&scene.detached, &pending)
	for node in pending {
		delete_key(&scene.index, node.id)
		// The scene's camera went with it: draw without one rather than through freed memory
		if scene.camera != nil && node == cast(^Node)scene.camera do scene.camera = nil
	}

	// Freed children first: a parent's arena holds its children list
	destroyTree :: proc(node: ^Node) {
		for child in node.children do destroyTree(child)
		Node_Destroy(node)
	}
	for root in roots do destroyTree(root)
}

Scene_Update :: proc(scene: ^Scene, events: []sdl.Event, deltaTime: f64) {
	Scene_ProcessQueues(scene)
	// New physics nodes get their bodies, so scripts can use them in `ready`
	Physics_Sync(scene)
	// Scripts get `ready` once, before their first update, when every node is in the scene
	Scene_ReadyScripts(scene)
	// Physics steps before nodes update: they see this frame's positions and collisions
	if !scene.paused do Physics_Update(scene, deltaTime)

	for node in scene.nodes {
		if !Node_CanProcess(node) do continue
		if node.update != nil {
			node.update(node, events, deltaTime)
		}
		if script := node.script; script.info != nil && script.info.update != nil {
			script.info.update(script.data, events, deltaTime)
		}
	}

	// After nodes have moved the camera (e.g. following a player), advance any pan and keep
	// it inside its bounds
	if scene.camera != nil && scene.game != nil {
		Camera2D_Update(scene.camera, scene.game.size, deltaTime)
	}
}

/*
Pauses or resumes a scene: while paused, physics doesn't step and only nodes that may process then
update (process mode WhenPaused or Always, or inheriting one); drawing goes on.

Example:
	e.Scene_SetPaused(scene, !scene.paused) // the pause key
*/
Scene_SetPaused :: proc(scene: ^Scene, paused: bool) {
	scene.paused = paused
}

/*
The scene's nodes in a group, in tree order (nodes waiting to be added included; temp allocated).

Example:
	for enemy in e.Scene_GetGroup(scene, "enemies") do enemy.visible = false
*/
Scene_GetGroup :: proc(scene: ^Scene, group: string) -> []^Node {
	found := make([dynamic]^Node, context.temp_allocator)
	for list in ([2][]^Node{scene.nodes[:], scene.addQueue[:]}) {
		for node in list do if Node_IsInGroup(node, group) do append(&found, node)
	}
	return found[:]
}

/*
Draws the scene: layer by layer, and within a layer in tree order (a parent before its children,
siblings in the order they were added). Each node draws in its local space; the scene sets the
draw transform to the camera view combined with the node's world transform (only the position,
for `.Position_Only` nodes), and the draw tint to its inherited tint. Hidden nodes and their
children are skipped.
*/
Scene_Draw :: proc(scene: ^Scene, renderer: ^sdl.Renderer) {
	view := scene.camera != nil ? Camera2D_ViewTransform(scene.camera) : TRANSFORM2D_IDENTITY
	Scene_DrawWithView(scene, renderer, view)
}

/*
Draws the scene through a given view transform (world to screen) instead of its camera. Editors
use it to show a scene with their own pan and zoom.

Inputs:
- scene: The scene
- renderer: The renderer to draw with
- view: World-to-screen transform for world layers
- screenLayersUseView: Also draw `scene.screenLayers` through `view` (an editor shows HUD nodes
  where they sit relative to the game area); otherwise they're drawn untransformed
- positionOnlyScale: Size multiplier for `.Position_Only` nodes (labels, menus). The game uses 1;
  an editor passes its zoom so UI keeps its size relative to the game area
*/
Scene_DrawWithView :: proc(scene: ^Scene, renderer: ^sdl.Renderer, view: Transform2D, screenLayersUseView := false, positionOnlyScale: f32 = 1) {
	defer SetDrawState(TRANSFORM2D_IDENTITY)
	// Shapes blend with the node's blend mode; afterwards normal alpha blending again
	defer if renderer != nil do sdl.SetRenderDrawBlendMode(renderer, sdl.BLENDMODE_BLEND)

	layers := drawOrder(scene)
	for &items, layer in layers {
		base := layer in scene.screenLayers && !screenLayersUseView ? TRANSFORM2D_IDENTITY : view
		for item in items {
			node := item.node
			transform := Transform2D_Multiply(base, item.world)
			if node.transformMode == .Position_Only {
				transform = {x = {positionOnlyScale, 0}, y = {0, positionOnlyScale}, origin = transform.origin}
			}
			SetDrawState(transform, item.tint, node.blendMode)
			if renderer != nil do sdl.SetRenderDrawBlendMode(renderer, SDLBlendMode(node.blendMode))
			if node.draw != nil do node.draw(node, renderer)
			// A script draws after its node, in the same local space
			if item.scriptDraw != nil do item.scriptDraw(node.script.data, renderer)
		}
	}
	if scene.physics != nil && scene.physics.settings.debugDraw do Physics_DrawDebug(scene, renderer, view)
}

/*
Whether a node and all of its ancestors are visible.
*/
Node_IsVisibleInTree :: proc(node: ^Node) -> bool {
	for n := node; n != nil; n = n.parent {
		if !n.visible do return false
	}
	return true
}

// A node to draw, with its world transform, inherited tint and its script's draw
@(private="file")
DrawItem :: struct {
	node: ^Node,
	world: Transform2D,
	tint: sdl.Color,
	scriptDraw: proc(self: rawptr, renderer: ^sdl.Renderer),
}

/*
The nodes to draw, by layer, each layer in tree order, with world transforms and tints computed
top-down (temp allocated). One walk of the tree; nodes that draw nothing (no draw procedure, no
script draw) aren't listed, though their children are. A ySort node's children are visited by
their world y; then each layer is sorted by zIndex, keeping that order among equal ones.
*/
@(private="file")
drawOrder :: proc(scene: ^Scene) -> [RenderLayer][dynamic]DrawItem {
	layers: [RenderLayer][dynamic]DrawItem
	for &items in layers do items = make([dynamic]DrawItem, 0, 64, context.temp_allocator)
	zIndexed := false
	visit :: proc(layers: ^[RenderLayer][dynamic]DrawItem, zIndexed: ^bool, node: ^Node, parentWorld: Transform2D, parentTint: sdl.Color) {
		if !node.inScene || !node.visible do return
		// Smoothed for dynamic bodies (physics_debug.odin)
		world := Transform2D_Multiply(parentWorld, Node_GetRenderLocalTransform(node))
		tint := multiplyColor(parentTint, node.tint)
		scriptDraw := node.script.info != nil ? node.script.info.draw : nil
		if node.draw != nil || scriptDraw != nil {
			append(&layers[node.layer], DrawItem{node, world, tint, scriptDraw})
			if node.zIndex != 0 do zIndexed^ = true
		}
		if !node.ySort || len(node.children) < 2 {
			for child in node.children do visit(layers, zIndexed, child, world, tint)
			return
		}
		// By their world y: further down the screen draws later
		Sorted :: struct { node: ^Node, y: f32 }
		sorted := make([]Sorted, len(node.children), context.temp_allocator)
		for child, i in node.children do sorted[i] = {child, Transform2D_Apply(world, child.position).y}
		slice.stable_sort_by(sorted, proc(a, b: Sorted) -> bool { return a.y < b.y })
		for s in sorted do visit(layers, zIndexed, s.node, world, tint)
	}
	for node in scene.nodes {
		if node.parent == nil do visit(&layers, &zIndexed, node, TRANSFORM2D_IDENTITY, {255, 255, 255, 255})
	}
	if zIndexed {
		for &items in layers do slice.stable_sort_by(items[:], proc(a, b: DrawItem) -> bool { return a.node.zIndex < b.node.zIndex })
	}
	return layers
}

@(private="file")
findQueuedOrLive :: proc(scene: ^Scene, id: EntityId) -> ^Node {
	return scene.index[id] or_else nil
}

// A temp copy of a node list, to walk while handlers change the original
@(private="file")
slice_clone_temp :: proc(nodes: []^Node) -> []^Node {
	copied := make([]^Node, len(nodes), context.temp_allocator)
	copy(copied, nodes)
	return copied
}

// onExit for a node in the scene and its descendants, parents first
@(private="file")
notifyExit :: proc(node: ^Node) {
	if node.inScene do node.onExit->notify(node, nil)
	node.inScene = false
	for child in slice_clone_temp(node.children[:]) do notifyExit(child)
}

@(private="file")
removeFromList :: proc(list: ^[dynamic]^Node, node: ^Node) {
	for n, i in list {
		if n == node {
			ordered_remove(list, i)
			return
		}
	}
}

/*
Finds a node by its name, or by a path of names from a top-level node: "World/Ship/Flame".

Inputs:
- scene: The scene
- path: A name, or names separated by "/"

Returns:
- The first match in tree order (nodes waiting to be added included), or nil
*/
Scene_FindNode :: proc(scene: ^Scene, path: string) -> ^Node {
	lists := [2][]^Node{scene.nodes[:], scene.addQueue[:]}
	// A bare name matches anywhere in the tree
	if strings.index_byte(path, '/') < 0 {
		for list in lists do for node in list do if node.name == path do return node
		return nil
	}
	// A path starts at a top-level node
	first, _, rest := strings.partition(path, "/")
	for list in lists do for node in list do if node.parent == nil && node.name == first do return Node_FindChild(node, rest)
	return nil
}

/*
Finds a descendant of a node by a path of child names: "Ship/Flame".

Returns:
- The node, or nil
*/
Node_FindChild :: proc(node: ^Node, path: string) -> ^Node {
	if path == "" do return node
	first, _, rest := strings.partition(path, "/")
	for child in node.children {
		if child.name == first do return Node_FindChild(child, rest)
	}
	return nil
}
