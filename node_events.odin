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
	// Its script's ("script.onCoinCollected")
	// Its scripts' ("script.onCoinCollected"): the first script that has it
	if strings.has_prefix(name, SCRIPT_EVENT_PREFIX) {
		for s in Node_Scripts(node) do if found := Script_FindEvent(s.data, s.info, name); found != nil do return found
		return nil
	}
	for event in NodeType_Events(node.type) do if event.name == name do return cast(^EventSubject)(uintptr(node) + event.offset)
	return nil
}

// Script events are named with this before their field ("script.onCoinCollected")
SCRIPT_EVENT_PREFIX :: "script."

/*
A script's event by name: one of its struct's EventSubject fields tagged `event:"..."`.

Inputs:
- data: The script struct (a node's script, or a global)
- info: Its script
- name: The event, "script.<field>"

Returns:
- Its subject, or nil
*/
Script_FindEvent :: proc(data: rawptr, info: ^ScriptInfo, name: string) -> ^EventSubject {
	if data == nil || info == nil do return nil
	for event in info.events do if event.name == name do return cast(^EventSubject)(uintptr(data) + event.offset)
	return nil
}

// A script struct's events (Script_Register): its tagged EventSubject fields, "script.<field>"
@(private)
scriptEvents :: proc(T: typeid) -> []NodeEventInfo {
	events := make([dynamic]NodeEventInfo)
	for event in NodeType_Events(T, context.temp_allocator) {
		e := event
		e.name = strings.concatenate({SCRIPT_EVENT_PREFIX, event.name})
		e.description = strings.clone(event.description)
		e.dataHint = strings.clone(event.dataHint)
		append(&events, e)
	}
	return events[:]
}

// Prepares a script struct's events with its owner's allocator (a node's arena; the game's for
// globals), so subscribing never allocates from elsewhere
@(private)
initScriptEvents :: proc(data: rawptr, info: ^ScriptInfo, allocator: runtime.Allocator) {
	for event in info.events do EventSubject_Init(cast(^EventSubject)(uintptr(data) + event.offset), allocator)
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
	append(&node.listeners, NodeListenerData{strings.clone(listener.event, allocator), strings.clone(listener.target, allocator), strings.clone(listener.handler, allocator), strings.clone(listener.global, allocator)})
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
	// The target's script that has the handler
	scriptType: typeid,
	// A global's event: called only while the scene plays, unsubscribed when the listening node
	// leaves (the global outlives it)
	global: bool,
	subject: ^EventSubject,
	handle: ListenerHandle,
}

// Subscribes a node's listeners (Scene_ReadyScripts, before ready); bad ones are logged and skipped
@(private)
bindListeners :: proc(node: ^Node) {
	node.listenersBound = true
	for l in node.listeners {
		subject: ^EventSubject
		target := Node_FindPath(node, l.target == "" ? "." : l.target)
		if l.global != "" {
			// A global's event: the listener is on the listening node
			game := node.scene != nil ? node.scene.game : nil
			info := Script_Find(l.global)
			if game != nil do for g in game.globals do if g.info == info do subject = Script_FindEvent(g.data, info, l.event)
		} else {
			subject = Node_FindEvent(node, l.event)
		}
		handler: ScriptListenerProc
		scriptType: typeid
		switch {
		case subject == nil && l.global != "":
			log.warnf("%s: no global %s with an event '%s' (Project Settings > Globals)", node.name, l.global, l.event)
		case subject == nil:
			log.warnf("%s: no event '%s' (%v's events: NodeType_Events)", node.name, l.event, node.type)
		case target == nil:
			log.warnf("%s.%s: no node at '%s' to listen", node.name, l.event, l.target)
		case target.script.info == nil:
			log.warnf("%s.%s: %s has no script to listen with", node.name, l.event, target.name)
		case:
			// The first of the target's scripts with a handler of that name
			for s in Node_Scripts(target) {
				handler = Script_FindListener(s.info.type, l.handler)
				if handler != nil {
					scriptType = s.info.type
					break
				}
			}
			if handler == nil do log.warnf("%s.%s: %s has no handler '%s' (Script_Listener; are the scripts built?)", node.name, l.event, target.script.info.name, l.handler)
		}
		if handler == nil do continue
		binding := new(ListenerBinding, Node_GetAllocator(node))
		binding^ = {source = l.global != "" ? nil : node, scene = node.scene, target = target.id, handler = handler, scriptType = scriptType, global = l.global != "", subject = subject}
		binding.handle = Event_Subscribe(subject, proc(_: ^EventSubject, _: rawptr, data: EventData, userData: rawptr) {
			b := cast(^ListenerBinding)userData
			// A global's event reaches only the scene that's playing (a scene left keeps its nodes
			// until it's entered again)
			if b.global && b.scene.game != nil && b.scene.game.currentScene != b.scene do return
			target := Scene_GetNode(b.scene, b.target)
			if target == nil do return
			for s in Node_Scripts(target) do if s.info.type == b.scriptType {
				b.handler(s.data, b.source, data)
				return
			}
		}, binding)
		if binding.global {
			// The global outlives the node: its subscription goes when the node leaves
			Event_Subscribe(&node.onExit, proc(_: ^EventSubject, _: rawptr, _: EventData, userData: rawptr) {
				b := cast(^ListenerBinding)userData
				Event_Unsubscribe(b.subject, b.handle)
			}, binding)
		}
	}
}
