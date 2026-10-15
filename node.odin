package engine

import "core:log"
import "core:mem"
import sdl "vendor:sdl3"
import vmem "core:mem/virtual"

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
*/
Node :: struct {
	id: EntityId,
	layer: RenderLayer,
	scene: ^Scene,
	update: proc(node: ^Node, events: []sdl.Event, deltaTime: f64),
	draw: proc(node: ^Node, renderer: ^sdl.Renderer),
	// Optional. Called just before the node's memory is freed, to release anything that is
	// not in the node's arena (e.g. memory from another allocator, SDL resources it owns)
	destroy: proc(node: ^Node),
	onEnter: EventSubject,
	onExit: EventSubject,
	// Holds this node and everything allocated with Node_GetAllocator
	arena: vmem.Arena,
}

/*
Prepares a node's event subjects. `CreateNode` calls this; only call it yourself for a
node you allocated another way.

Inputs:
- node: The node to initialize
- allocator: Allocator for the event listener lists
*/
Node_Init :: proc(node: ^Node, allocator := context.allocator) {
	EventSubject_Init(&node.onEnter, allocator)
	EventSubject_Init(&node.onExit, allocator)
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
	return vmem.arena_allocator(&node.arena)
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
	if node.destroy != nil do node.destroy(node)

	// The arena lives inside its own memory, so destroy a copy: freeing the blocks would
	// otherwise also free the Arena struct while arena_destroy is still using it
	arena := node.arena
	vmem.arena_destroy(&arena)
}

// Allocates a node of type T inside a new arena that the node owns
@(private)
allocateNode :: proc($T: typeid) -> ^T {
	// T embeds Node as its first field, so the arena is at the same offset in T as in Node
	object, err := vmem.arena_growing_bootstrap_new_by_offset(T, offset_of(Node, arena), NODE_ARENA_BLOCK_SIZE)
	if err != nil {
		log.panicf("Failed to allocate node %v: %v", typeid_of(T), err)
	}
	return object
}
