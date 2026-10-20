package crossfire

import "base:runtime"
import "core:log"
import "core:reflect"
import "core:strings"

/*
Node events for tools and scene files. Every event worth listening to is an `EventSubject` field
of a node type, tagged with what it means and how to read its data:

	onFinished: EventSubject `event:"It finished" data:"index := data.(int)"`,

`NodeType_Events` lists a type's tagged subjects (its own, those of the types it embeds, and those
of struct fields such as an AnimatedSprite's `animation`, named "animation.onAnimationEnded"), so
an editor shows them and scene files name them.

Scene files connect them to scripts: `<listener event target handler/>` inside a node
(`NodeListenerData`). A script registers its handlers by name with `Script_Listener`; just before
the scene's scripts get `ready`, each listener's handler is subscribed (`bindListeners`), and is
called with the listening script, the node whose event it is, and the event's data. The
listening node is looked up by id on each call: a removed one is skipped.

	Hero_onCoinCollected :: proc(self: ^Hero, source: ^e.Node, data: e.EventData) {
		self.coins += 1
	}

	@(init)
	register_Hero_onCoinCollected :: proc "contextless" () {
		e.Script_Listener(Hero, "onCoinCollected", Hero_onCoinCollected)
	}
*/

// An event a node type offers: one of its `EventSubject` fields tagged `event:"..."`
NodeEventInfo :: struct {
	// Its name in scene files: the field's ("onFinished"), through a struct field
	// ("animation.onAnimationEnded")
	name: string,
	// What it means (the `event` tag)
	description: string,
	// Code reading its data (the `data` tag: "index := data.(int)"); "" when it carries none
	dataHint: string,
	// The subject's byte offset in the node
	offset: uintptr,
}

/*
The events of a node type: its tagged `EventSubject` fields, those of the types it embeds
(`Node`'s onEnter and onExit last) and of its struct fields.

Inputs:
- type: The node type (`Sprite`, `CharacterMover`...; `node.type`)
- allocator: For the list

Returns:
- The events, the type's own first
*/
NodeType_Events :: proc(type: typeid, allocator := context.temp_allocator) -> []NodeEventInfo {
	events := make([dynamic]NodeEventInfo, allocator)
	walk :: proc(events: ^[dynamic]NodeEventInfo, type: typeid, prefix: string, offset: uintptr, depth: int, allocator: runtime.Allocator) {
		if depth > 4 || !reflect.is_struct(type_info_of(type)) do return
		for field in reflect.struct_fields_zipped(type) {
			at := offset + field.offset
			if field.type.id == EventSubject {
				description, tagged := reflect.struct_tag_lookup(field.tag, "event")
				if !tagged do continue
				name := prefix == "" ? field.name : strings.concatenate({prefix, field.name}, allocator)
				append(events, NodeEventInfo{name, string(description), string(reflect.struct_tag_get(field.tag, "data")), at})
			} else if reflect.is_struct(field.type) && field.type.id != Node {
				// Embedded types keep the names; other struct fields prefix theirs
				walk(events, field.type.id, field.is_using ? prefix : strings.concatenate({prefix, field.name, "."}, allocator), at, depth + 1, allocator)
			}
		}
	}
	walk(&events, type, "", 0, 0, allocator)
	// Node's own (every node has them) after the type's
	if type != Node && typeEmbeds(type, Node) do walk(&events, Node, "", 0, 0, allocator)
	return events[:]
}

/*
The events nodes of a scene file's kind offer (a Component instance: a Node's; its root's type
decides the rest).

Inputs:
- kind: The kind
- allocator: For the list

Returns:
- The events (`NodeType_Events`)
*/
SceneNodeKind_Events :: proc(kind: SceneNodeKind, allocator := context.temp_allocator) -> []NodeEventInfo {
	return NodeType_Events(SCENE_NODE_TYPES[kind], allocator)
}

/*
A node's event by name.

Inputs:
- node: The node
- name: The event (`NodeEventInfo.name`)

Returns:
- Its subject, or nil when the node's type has no such event

Example:
	// Given: emitter: ^e.Node
	if finished := e.Node_FindEvent(emitter, "onFinished"); finished != nil do log.info("it can finish")
*/
Node_FindEvent :: proc(node: ^Node, name: string) -> ^EventSubject {
	if node == nil do return nil
	for event in NodeType_Events(node.type) do if event.name == name do return cast(^EventSubject)(uintptr(node) + event.offset)
	return nil
}

/*
Adds a listener to a node: before the scene's scripts next get `ready` (for a node built from a
scene file: before they first do), the target's script's handler is subscribed to the event.
Scene files' `<listener>` elements come here.

Inputs:
- node: The node whose event it is
- listener: The event, the listening node (a path from `node`) and the handler's name (copied)
*/
Node_AddListener :: proc(node: ^Node, listener: NodeListenerData) {
	allocator := Node_GetAllocator(node)
	if node.listeners == nil do node.listeners = make([dynamic]NodeListenerData, allocator)
	append(&node.listeners, NodeListenerData{strings.clone(listener.event, allocator), strings.clone(listener.target, allocator), strings.clone(listener.handler, allocator)})
	node.listenersBound = false
}

// A script's handler for an event: the script struct, the node whose event it is, its data
ScriptListenerProc :: proc(self: rawptr, source: ^Node, data: EventData)

@(private="file")
listenerRegistry: map[typeid]map[string]ScriptListenerProc

/*
Registers a script's event handler by name, for scene files' listeners (`<listener handler=...>`)
to call. Like `Script_Register`, call it from an `@(init) proc "contextless"`; the editor writes
these when you attach a listener in the inspector.

Inputs:
- T: The script struct
- name: The handler's name, as scene files give it
- handler: Called with the listening script, the node whose event it is, and the event's data

Example:
	Hero :: struct {
		using script: e.Script,
		coins: int,
	}
	Hero_onCoinCollected :: proc(self: ^Hero, source: ^e.Node, data: e.EventData) {
		self.coins += 1
	}
	register_Hero_onCoinCollected :: proc "contextless" () {
		e.Script_Listener(Hero, "onCoinCollected", Hero_onCoinCollected)
	}
*/
Script_Listener :: proc "contextless" ($T: typeid, name: string, handler: proc(self: ^T, source: ^Node, data: EventData)) {
	context = Platform_DefaultContext()
	if T not_in listenerRegistry do listenerRegistry[T] = make(map[string]ScriptListenerProc)
	handlers := &listenerRegistry[T]
	handlers[strings.clone(name)] = transmute(ScriptListenerProc)handler
}

/*
A script's handler registered with `Script_Listener`.

Inputs:
- type: The script struct's type
- name: The handler's name

Returns:
- The handler, or nil
*/
Script_FindListener :: proc(type: typeid, name: string) -> ScriptListenerProc {
	handlers, found := listenerRegistry[type]
	if !found do return nil
	return handlers[name]
}

// A subscribed listener: what the event calls
@(private="file")
ListenerBinding :: struct {
	source: ^Node,
	scene: ^Scene,
	target: EntityId,
	handler: ScriptListenerProc,
}

// Subscribes a node's listeners (Scene_ReadyScripts, before ready); bad ones are logged and skipped
@(private)
bindListeners :: proc(node: ^Node) {
	node.listenersBound = true
	for l in node.listeners {
		subject := Node_FindEvent(node, l.event)
		target := Node_FindPath(node, l.target)
		handler: ScriptListenerProc
		switch {
		case subject == nil:
			log.warnf("%s: no event '%s' (%v's events: NodeType_Events)", node.name, l.event, node.type)
		case target == nil:
			log.warnf("%s.%s: no node at '%s' to listen", node.name, l.event, l.target)
		case target.script.info == nil:
			log.warnf("%s.%s: %s has no script to listen with", node.name, l.event, target.name)
		case:
			handler = Script_FindListener(target.script.info.type, l.handler)
			if handler == nil do log.warnf("%s.%s: %s has no handler '%s' (Script_Listener; are the scripts built?)", node.name, l.event, target.script.info.name, l.handler)
		}
		if handler == nil do continue
		binding := new(ListenerBinding, Node_GetAllocator(node))
		binding^ = {node, node.scene, target.id, handler}
		Event_Subscribe(subject, proc(_: ^EventSubject, _: rawptr, data: EventData, userData: rawptr) {
			b := cast(^ListenerBinding)userData
			target := Scene_GetNode(b.scene, b.target)
			if target == nil || target.script.data == nil do return
			b.handler(target.script.data, b.source, data)
		}, binding)
	}
}
