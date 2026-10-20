package engine

import "core:encoding/uuid"
import "core:log"
import "core:strings"
import "core:crypto"
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
	context.random_generator = crypto.random_generator()
	node.id = uuid.generate_v4()
	node.type = T
	node.scene = scene
	Node_Init(node, Node_GetAllocator(node))
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
	if node.inScene || listHas(scene.addQueue[:], node) do return
	removeFromList(&scene.detached, node)
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
	// By index: removing a node can queue more removals (a collision exit's handler)
	for i := 0; i < len(scene.removeQueue); i += 1 {
		nodeId := scene.removeQueue[i]
		node := findQueuedOrLive(scene, nodeId)
		if node != nil do removeSubtree(scene, node)
	}
	clear(&scene.removeQueue)

	// By index too: an onEnter handler can make more nodes, which join in the same pass
	for i := 0; i < len(scene.addQueue); i += 1 {
		node := scene.addQueue[i]
		node.inScene = true
		append(&scene.nodes, node)
		node.onEnter->notify(node, nil)
	}
	clear(&scene.addQueue)
}

Scene_Update :: proc(scene: ^Scene, events: []sdl.Event, deltaTime: f64) {
	Scene_ProcessQueues(scene)
	// New physics nodes get their bodies, so scripts can use them in `ready`
	Physics_Sync(scene)
	// Scripts get `ready` once, before their first update, when every node is in the scene
	Scene_ReadyScripts(scene)
	// Physics steps before nodes update: they see this frame's positions and collisions
	Physics_Update(scene, deltaTime)

	for node in scene.nodes {
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

	items := drawOrder(scene)
	for layer in RenderLayer {
		base := layer in scene.screenLayers && !screenLayersUseView ? TRANSFORM2D_IDENTITY : view
		for item in items {
			node := item.node
			scriptDraw := node.script.info != nil ? node.script.info.draw : nil
			if (node.draw == nil && scriptDraw == nil) || node.layer != layer do continue
			transform := Transform2D_Multiply(base, item.world)
			if node.transformMode == .Position_Only {
				transform = {x = {positionOnlyScale, 0}, y = {0, positionOnlyScale}, origin = transform.origin}
			}
			SetDrawState(transform, item.tint)
			if node.draw != nil do node.draw(node, renderer)
			// A script draws after its node, in the same local space
			if scriptDraw != nil do scriptDraw(node.script.data, renderer)
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

// A node to draw, with its world transform and inherited tint
@(private="file")
DrawItem :: struct {
	node: ^Node,
	world: Transform2D,
	tint: sdl.Color,
}

// Visible nodes in tree order, with world transforms computed top-down (temp allocated)
@(private="file")
drawOrder :: proc(scene: ^Scene) -> []DrawItem {
	items := make([dynamic]DrawItem, 0, len(scene.nodes), context.temp_allocator)
	visit :: proc(items: ^[dynamic]DrawItem, node: ^Node, parentWorld: Transform2D, parentTint: sdl.Color) {
		if !node.inScene || !node.visible do return
		// Smoothed for dynamic bodies (physics_debug.odin)
		world := Transform2D_Multiply(parentWorld, Node_GetRenderLocalTransform(node))
		tint := multiplyColor(parentTint, node.tint)
		append(items, DrawItem{node, world, tint})
		for child in node.children do visit(items, child, world, tint)
	}
	for node in scene.nodes {
		if node.parent == nil do visit(&items, node, TRANSFORM2D_IDENTITY, {255, 255, 255, 255})
	}
	return items[:]
}

@(private="file")
findQueuedOrLive :: proc(scene: ^Scene, id: EntityId) -> ^Node {
	for node in scene.nodes do if node.id == id do return node
	for node in scene.addQueue do if node.id == id do return node
	for node in scene.detached do if node.id == id do return node
	return nil
}

@(private="file")
listHas :: proc(list: []^Node, node: ^Node) -> bool {
	for n in list do if n == node do return true
	return false
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

// Removes a node and its descendants from the scene and frees them
@(private="file")
removeSubtree :: proc(scene: ^Scene, root: ^Node) {
	if root.parent != nil {
		removeChild(root.parent, root)
		root.parent = nil
	}

	subtree := make([dynamic]^Node, context.temp_allocator)
	collect :: proc(list: ^[dynamic]^Node, node: ^Node) {
		append(list, node)
		for child in node.children do collect(list, child)
	}
	collect(&subtree, root)

	for node in subtree {
		if node.inScene do node.onExit->notify(node, nil)
		node.inScene = false
		removeFromList(&scene.nodes, node)
		removeFromList(&scene.addQueue, node)
		removeFromList(&scene.detached, node)
		// The scene's camera went with it: draw without one rather than through freed memory
		if scene.camera != nil && node == cast(^Node)scene.camera do scene.camera = nil
	}
	// Children first: a parent's arena holds its children list
	#reverse for node in subtree do Node_Destroy(node)
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
	first, _, rest := strings.partition(path, "/")
	search :: proc(nodes: []^Node, first, rest, path: string) -> ^Node {
		for node in nodes {
			if rest == "" && strings.index_byte(path, '/') < 0 {
				// A bare name matches anywhere in the tree
				if node.name == first do return node
			} else if node.parent == nil && node.name == first {
				return Node_FindChild(node, rest)
			}
		}
		return nil
	}
	if found := search(scene.nodes[:], first, rest, path); found != nil do return found
	return search(scene.addQueue[:], first, rest, path)
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
