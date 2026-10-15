package engine

import "core:encoding/uuid"
import "core:log"
import "core:crypto"
import "core:mem"
import sdl "vendor:sdl3"
import vmem "core:mem/virtual"


Scene :: struct {
	id: EntityId,
	game: ^Game,
	nodes: [dynamic]^Node,
	addQueue: [dynamic]^Node,
	removeQueue: [dynamic]EntityId,
	arena: vmem.Arena,
	// Optional camera, nil by default. When set, every layer not in `screenLayers` is drawn
	// through it, and its pans and bounds are applied after each update. Create with `Scene_CreateCamera`
	camera: ^Camera2D,
	// Layers drawn in screen space, ignoring `camera`. Put HUDs and menus on these layers
	screenLayers: bit_set[RenderLayer],
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
	err := vmem.arena_init_growing(&scene.arena)
	if err != nil {
		log.panic("Failed to initialize arena: ", err)
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
	return vmem.arena_allocator(&scene.arena)
}

Scene_Destroy :: proc(scene: ^Scene) {
	// Nodes live in their own arenas, so each one is freed individually
	for node in scene.nodes do Node_Destroy(node)
	for node in scene.addQueue do Node_Destroy(node)
	delete(scene.addQueue)
	delete(scene.removeQueue)
	delete(scene.nodes)
	// Destroy, not free_all: free_all keeps the first block, which leaked once the scene was freed
	vmem.arena_destroy(&scene.arena)
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
	node.scene = scene
	Node_Init(node, Node_GetAllocator(node))
	if addToScene {
		Scene_AddNode(scene, node)
	}
	return newObject

}


Scene_AddNode :: proc(scene: ^Scene, node: ^Node) {
	log.debug("Adding Node on next frame")
	append(&scene.addQueue, node)
}


Scene_RemoveNode :: proc(scene: ^Scene, nodeId: EntityId) {
	append(&scene.removeQueue, nodeId)
}


Scene_GetNode :: proc(scene: ^Scene, nodeId: EntityId) -> ^Node {
	for node in scene.nodes {
		if node.id == nodeId {
			return node
		}
	}
	return nil
}

Scene_ProcessQueues :: proc(scene: ^Scene) {
	for nodeId in scene.removeQueue {
		for node, i in scene.nodes {
			if node.id == nodeId {
				log.debug("Removing Node with ID: ", nodeId)
				node.onExit->notify(node, nil)
				unordered_remove(&scene.nodes, i)
				// Frees the node and everything in its arena, including its event listeners
				Node_Destroy(node)
				break
			}
		}
	}

	clear(&scene.removeQueue)


	for &node in scene.addQueue {
		node.onEnter->notify(node, nil)
		append(&scene.nodes, node)
	}
	clear(&scene.addQueue)
}

Scene_Update :: proc(scene: ^Scene, events: []sdl.Event, deltaTime: f64) {
	Scene_ProcessQueues(scene)


	for node in scene.nodes {
		if node.update != nil {
			node.update(node, events, deltaTime)
		}
	}

	// After nodes have moved the camera (e.g. following a player), advance any pan and keep
	// it inside its bounds
	if scene.camera != nil && scene.game != nil {
		Camera2D_Update(scene.camera, scene.game.size, deltaTime)
	}
}

Scene_Draw :: proc(scene: ^Scene, renderer: ^sdl.Renderer) {
	defer activeCamera = nil

	for layer in RenderLayer {
		activeCamera = layer in scene.screenLayers ? nil : scene.camera
		for node in scene.nodes {
			if node.draw != nil && node.layer == layer {
				node.draw(node, renderer)
			}
		}
	}
}
