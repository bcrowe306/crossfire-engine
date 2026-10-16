package engine

import "core:log"
import "core:mem"
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

// Initial (and minimum) size of each block of a node's arena. Small, because most nodes only
// hold a few event listener lists; the arena adds blocks if a node needs more
NODE_ARENA_BLOCK_SIZE :: 16 * mem.Kilobyte

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
	id: EntityId,
	// The name from the scene file ("" for nodes made in code unless set). Used by
	// `Scene_FindNode` and `Node_FindChild`; owned by the node's arena when set by `Scene_Build`
	name: string,
	layer: RenderLayer,
	scene: ^Scene,
	update: proc(node: ^Node, events: []sdl.Event, deltaTime: f64),
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
	scale: [2]f32,
	// UI nodes use .Position_Only: they follow their world position but aren't rotated or scaled
	transformMode: TransformMode,
	// A hidden node and its children aren't drawn. They still update; check
	// `Node_IsVisibleInTree` in update code that should pause while hidden
	visible: bool,
	// Multiplies the colors of everything the node and its children draw
	tint: sdl.Color,
	parent: ^Node,
	children: [dynamic]^Node,
	// Set while the node is part of its scene (after it was added, until it's removed)
	inScene: bool,
	// The script attached to the node, if any (script.odin)
	script: NodeScript,

	onEnter: EventSubject,
	onExit: EventSubject,
	// Holds this node and everything allocated with Node_GetAllocator
	arena: MemoryArena,
}

/*
Prepares a node's event subjects and children list, and sets its defaults (scale 1, visible,
white tint). `CreateNode` calls this; only call it yourself for a node you allocated another way.

Inputs:
- node: The node to initialize
- allocator: Allocator for the event listener lists
*/
Node_Init :: proc(node: ^Node, allocator := context.allocator) {
	EventSubject_Init(&node.onEnter, allocator)
	EventSubject_Init(&node.onExit, allocator)
	node.scale = {1, 1}
	node.visible = true
	node.tint = {255, 255, 255, 255}
	node.children = make([dynamic]^Node, allocator)
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
	enemy := e.CreateNode(scene, Enemy)
	allocator := e.Node_GetAllocator(enemy)
	e.AnimationPlayer_Init(&enemy.anim, allocator)
	e.EventSubject_Init(&enemy.onHit, allocator)
*/
Node_GetAllocator :: proc(node: ^Node) -> mem.Allocator {
	return MemoryArena_Allocator(&node.arena)
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
	MemoryArena_Destroy(&arena)
}

// Allocates a node of type T inside a new arena that the node owns
@(private)
allocateNode :: proc($T: typeid) -> ^T {
	// T embeds Node as its first field, so the arena is at the same offset in T as in Node
	object, ok := MemoryArena_BootstrapNew(T, offset_of(Node, arena), NODE_ARENA_BLOCK_SIZE)
	if !ok {
		log.panicf("Failed to allocate node %v", typeid_of(T))
	}
	return object
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
