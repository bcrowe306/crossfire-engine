package crossfire

import "base:runtime"
import "core:log"
import "core:mem"
import "core:strings"
import sdl "vendor:sdl3"

/*
How a node's world transform applies when it draws.
*/
TransformMode :: enum {
	// Position, rotation and scale (parents' and the camera's included)
	Full,
	// Only the position: drawn upright and unscaled at the node's screen position. Used by UI
	// nodes (Label, Menu), whose input handling works in unrotated screen space
	Position_Only,
}

/*
Whether a node updates (its `update` procedure, its script's update), depending on whether its
scene is paused (`Scene_SetPaused`). Drawing isn't affected.
*/
ProcessMode :: enum u8 {
	// Its parent's mode (a top-level node's: Pausable)
	Inherit,
	// Updates while the scene runs, stops while it's paused (gameplay)
	Pausable,
	// Updates only while the scene is paused (a pause menu)
	WhenPaused,
	// Updates whether the scene is paused or not
	Always,
	// Never updates (it still draws)
	Disabled,
}

/*
How a node's drawing combines with what's under it. Not inherited by children.
*/
BlendMode :: enum u8 {
	// Normal alpha blending
	Blend,
	// Adds its colors (glows, fire, light)
	Add,
	// Multiplies the colors under it (shadows, tinting)
	Multiply,
	// Multiplies the colors under it by its own; its alpha is ignored
	Modulate,
	// Replaces what's under it, alpha included
	None,
}

// Initial (and minimum) size of each block of a node's arena. Small, because most nodes only
// hold a few event listener lists; the arena adds blocks if a node needs more
NODE_ARENA_BLOCK_SIZE :: 4 * mem.Kilobyte

/*
A node's memory: an arena of heap blocks (Odin's `runtime.Arena`) holding the node itself and
whatever it allocates with `Node_GetAllocator`, freed in one step with the node. Heap blocks, not
virtual memory: making and freeing a node then costs no system calls (scenes, games and LDtk
projects, which are few and large, keep `MemoryArena`).
*/
NodeArena :: runtime.Arena

/*
Base type of everything in a scene. Node types embed it as their first field:

	Player :: struct {
		using node: e.Node,
		...
	}

Create nodes with `CreateNode`. Each node owns a memory arena that holds the node itself
and anything allocated with `Node_GetAllocator`: its event listener lists, animation
players, strings, etc. When the node is destroyed (removed from its scene, or the scene
is destroyed) the arena is freed in one step, so none of that needs freeing by hand.

Every node has a transform (`position`, `rotation`, `scale`) relative to its parent, set with
`Node_AddChild` / `Node_SetParent`. A node's `draw` procedure draws in its own local space: the
scene applies its world transform (and the camera) to every Draw* call. Children also inherit
`visible` (hidden nodes aren't drawn, but still update) and `tint`. Removing a node removes its
children too.
*/
Node :: struct {
	// Unique id, set by `CreateNode`. Pass it to `Scene_RemoveNode` and `Scene_GetNode`
	id: EntityId,
	// The type `CreateNode` made it as (`Sprite`, `DynamicBody`, ...); see `Node_Is`
	type: typeid,
	// The name from the scene file ("" for nodes made in code unless set). Used by
	// `Scene_FindNode` and `Node_FindChild`; owned by the node's arena when set by `Scene_Build`
	name: string,
	// The root of a component instance: the component's file (`Scene_AddComponent`,
	// `Node_GetComponent`; in the node's arena). "" for any other node
	component: string,
	// The layer it draws on (Layer1 first, Layer8 on top). Not inherited by children
	layer: RenderLayer,
	// The scene that made it (`CreateNode`)
	scene: ^Scene,
	// Optional. Called every frame while the node is in its scene and may process
	// (`Node_CanProcess`); `deltaTime` is in seconds
	update: proc(node: ^Node, events: []sdl.Event, deltaTime: f64),
	// Optional. Draws the node in its local space: (0, 0) is its position, and the scene applies
	// its world transform, the camera and its tint to every Draw* call
	draw: proc(node: ^Node, renderer: ^sdl.Renderer),
	// Optional. Called just before the node's memory is freed, to release anything that is
	// not in the node's arena (e.g. memory from another allocator, SDL resources it owns)
	destroy: proc(node: ^Node),
	// Optional. The rectangle the node draws, in its local space. Editors use it for picking and
	// selection boxes; see `Node_GetLocalBounds`
	getBounds: proc(node: ^Node) -> (bounds: sdl.FRect, ok: bool),

	// Transform relative to the parent (or the world, for top-level nodes)
	position: [2]f32,
	// Degrees, clockwise
	rotation: f32,
	// Scale on each axis ({1, 1} by default; a negative x mirrors it)
	scale: [2]f32,
	// UI nodes use .Position_Only: they follow their world position but aren't rotated or scaled
	transformMode: TransformMode,
	// Whether it updates while its scene is paused or running (`Node_CanProcess`)
	processMode: ProcessMode,
	// How its drawing combines with what's under it
	blendMode: BlendMode,
	// Draw order within its layer: higher draws later (on top). Equal values keep tree order
	zIndex: i32,
	// Its children draw sorted by their world y (lower first: things further down the screen
	// draw on top), for top-down games
	ySort: bool,
	// Groups it belongs to (`Node_AddToGroup`, `Scene_GetGroup`); names in the node's arena
	groups: [dynamic]string,
	// A hidden node and its children aren't drawn. They still update; check
	// `Node_IsVisibleInTree` in update code that should pause while hidden
	visible: bool,
	// Multiplies the colors of everything the node and its children draw
	tint: sdl.Color,
	// Its parent, nil for a top-level node. Set with `Node_AddChild` / `Node_SetParent`
	parent: ^Node,
	// Its children, in the order they were added (in the node's arena)
	children: [dynamic]^Node,
	// Set while the node is part of its scene (after it was added, until it's removed)
	inScene: bool,
	// Set while it waits to be added (Scene_AddNode until the next Scene_ProcessQueues)
	queued: bool,
	// The script attached to the node, if any (script.odin)
	script: NodeScript,
	// Scripts listening to its events, subscribed before the scene's scripts get `ready`
	// (`Node_AddListener`, node_events.odin; in its arena)
	listeners: [dynamic]NodeListenerData,
	// Its listeners were subscribed (`listeners` added later aren't)
	listenersBound: bool,

	// Notified when the node joins its scene, at the start of the update after it was added
	// (source: the node)
	onEnter: EventSubject `event:"It joined the scene (the update after it was added)"`,
	// Notified when the node leaves its scene (removed, or the scene destroyed), before it's
	// freed (source: the node)
	onExit: EventSubject `event:"It's leaving the scene (removed, or the scene ended), before it's freed"`,
	// Holds this node and everything allocated with Node_GetAllocator
	arena: NodeArena,
}

/*
Prepares a node's event subjects and children list, and sets its defaults (scale 1, visible,
white tint). `CreateNode` calls this; inside the engine, call it only for a node allocated
another way.

Inputs:
- node: The node to initialize
- allocator: Allocator for the event listener lists
*/
@(private)
Node_Init :: proc(node: ^Node, allocator := context.allocator) {
	EventSubject_Init(&node.onEnter, allocator)
	EventSubject_Init(&node.onExit, allocator)
	node.scale = {1, 1}
	node.visible = true
	node.tint = {255, 255, 255, 255}
	node.children = make([dynamic]^Node, allocator)
	node.groups = make([dynamic]string, allocator)
}

/*
Whether a node updates now: its process mode (resolving Inherit through its parents; Pausable at
the top) against whether its scene is paused. The scene checks it before each update.

Inputs:
- node: The node

Returns:
- true if the node updates this frame

Example:
	// Given: pauseMenu: ^e.Node
	pauseMenu.processMode = .WhenPaused
	e.Scene_SetPaused(scene, true) // gameplay stops, the menu runs
*/
Node_CanProcess :: proc(node: ^Node) -> bool {
	mode := ProcessMode.Pausable
	for n := node; n != nil; n = n.parent {
		if n.processMode != .Inherit {
			mode = n.processMode
			break
		}
	}
	paused := node.scene != nil && node.scene.paused
	switch mode {
	case .Inherit, .Pausable: return !paused
	case .WhenPaused:         return paused
	case .Always:             return true
	case .Disabled:           return false
	}
	return true
}

/*
Puts a node in a group (once): groups name sets of nodes to find or act on together, like
"enemies" or "pickups". Find them with `Scene_GetGroup`.

Inputs:
- node: The node
- group: The group's name (copied into the node's arena)

Example:
	e.Node_AddToGroup(node, "enemies")
	for enemy in e.Scene_GetGroup(scene, "enemies") do enemy.tint = {255, 80, 80, 255}
*/
Node_AddToGroup :: proc(node: ^Node, group: string) {
	if Node_IsInGroup(node, group) do return
	append(&node.groups, strings.clone(group, Node_GetAllocator(node)))
}

/*
Takes a node out of a group (nothing if it isn't in it).

Inputs:
- node: The node
- group: The group's name
*/
Node_RemoveFromGroup :: proc(node: ^Node, group: string) {
	for name, i in node.groups do if name == group {
		ordered_remove(&node.groups, i)
		return
	}
}

/*
Whether a node is in a group.

Inputs:
- node: The node
- group: The group's name

Returns:
- true if it's in the group
*/
Node_IsInGroup :: proc(node: ^Node, group: string) -> bool {
	for name in node.groups do if name == group do return true
	return false
}

/*
Allocator backed by the node's arena. Everything allocated with it is freed when the node
is destroyed, so use it for data the node owns: event subjects, animation players,
animations, copies of strings.

Inputs:
- node: A node made by `CreateNode`

Returns:
- The node's arena allocator

Example:
	package mygame

	import e "../engine"

	Enemy :: struct {
		using node: e.Node,
		anim: e.AnimationPlayer,
		onHit: e.EventSubject,
	}

	CreateEnemy :: proc(scene: ^e.Scene) -> ^Enemy {
		enemy := e.CreateNode(scene, Enemy)
		allocator := e.Node_GetAllocator(enemy)
		e.AnimationPlayer_Init(&enemy.anim, allocator)
		e.EventSubject_Init(&enemy.onHit, allocator)
		return enemy
	}
*/
Node_GetAllocator :: proc(node: ^Node) -> mem.Allocator {
	return runtime.Allocator{procedure = runtime.arena_allocator_proc, data = &node.arena}
}

/*
Frees a node and everything in its arena, after calling its `destroy` callback.

The scene does this for you: for removed nodes at the start of the next update (after
`onExit`), and for all of its nodes when the scene is destroyed. Any pointer to the node
is invalid afterwards.

Inputs:
- node: A node made by `CreateNode`
*/
Node_Destroy :: proc(node: ^Node) {
	if node == nil do return
	if node.script.info != nil && node.script.info.destroy != nil do node.script.info.destroy(node.script.data)
	if node.destroy != nil do node.destroy(node)

	// The arena lives inside its own memory, so destroy a copy: freeing the blocks would
	// otherwise also free the Arena struct while arena_destroy is still using it
	arena := node.arena
	runtime.arena_destroy(&arena)
}

// Allocates a node of type T inside a new arena that the node owns
@(private)
allocateNode :: proc($T: typeid) -> ^T {
	// The arena's blocks come from the heap whatever the caller's allocator is (a temp allocator
	// would free a live node at the end of the frame)
	arena: runtime.Arena
	if runtime.arena_init(&arena, NODE_ARENA_BLOCK_SIZE, runtime.heap_allocator()) != nil {
		log.panicf("Failed to allocate node %v", typeid_of(T))
	}
	object, err := runtime.new(T, runtime.Allocator{procedure = runtime.arena_allocator_proc, data = &arena})
	if err != nil {
		runtime.arena_destroy(&arena)
		log.panicf("Failed to allocate node %v", typeid_of(T))
	}
	// Then the arena moves into the node (T embeds Node first, and the arena has no pointers to
	// itself), so the node owns the memory it lives in
	(cast(^Node)object).arena = arena
	return object
}

/*
Whether a node was created as type T (`CreateNode(scene, T)`), so it can be cast to `^T`.

Inputs:
- node: The node (nil returns false)
- T: The node type

Returns:
- true if the node's type is exactly T

Example:
	if e.Node_Is(node, e.DynamicBody) do e.DynamicBody_ApplyImpulse(cast(^e.DynamicBody)node, {0, -300})
*/
Node_Is :: proc(node: ^Node, $T: typeid) -> bool {
	return node != nil && node.type == T
}

/*
The rectangle a node draws, in its local space (before its transform).

Inputs:
- node: The node

Returns:
- The bounds, and false for nodes that draw nothing measurable (no `getBounds`)
*/
Node_GetLocalBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	if node.getBounds == nil do return {}, false
	return node.getBounds(node)
}
