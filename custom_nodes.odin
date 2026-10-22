package crossfire

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:reflect"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

/*
Custom node types: a struct of the game's own that starts with a built-in node type, registered
under its name, and used in scene files as a kind of its own (`kind="Player"`).

	Player :: struct {
		using sprite: e.Sprite,              // the base kind: everything a Sprite is and does
		speed: f32 `export:"default=200"`,   // its own settings, set from scene files
		lives: int `export:"default=3"`,
	}

	@(init)
	register_Player :: proc "contextless" () {
		e.NodeType_Register(Player, .Sprite, {
			update = proc(self: ^Player, events: []sdl.Event, dt: f64) {
				self.position.x += self.speed * f32(dt)   // self is the node
			},
		})
	}

- **What it is:** a node of the base kind, built from the scene file's attributes as usual (a
  Sprite's texture, a body's shapes...), allocated as the bigger struct; `node.type` is the
  custom type (`Node_Is(node, Player)`, `cast(^Player)node`), and `Node_Is` with the base type is
  false: test with `SceneNodeKind_IsType` or `typeEmbeds` for "a kind of Sprite".
- **Its hooks and fields** are a script's (`ScriptHooks`, `export` tags: script.odin), with the
  node itself as `self`, run before any scripts attached to it (scripts attach as usual). Its
  exported fields' values are `<prop name value/>` children of the node.
- **Scene files** say `kind="Player" baseKind="Sprite"`: where Player isn't registered (an
  editor, a player without the game's scripts) the node is built as its base kind.
- The base type must be the struct's first field (`using sprite: e.Sprite`); one that isn't, or
  whose base kind's type differs, isn't registered (printed on stderr).
*/

// A registered custom node type
NodeTypeInfo :: struct {
	// Its name, hooks and fields, as a script's (data: the node itself)
	using info: ScriptInfo,
	// The built-in kind it extends
	base: SceneNodeKind,
}

@(private="file")
nodeTypes: map[string]^NodeTypeInfo

// The type the next CreateNode allocates (the loader sets it for one node)
@(private)
nodeTypeOverride: ^NodeTypeInfo

/*
Registers a custom node type: call it from an `@(init) proc "contextless"` in the game's scripts.

Inputs:
- T: The struct; its first field is the base kind's type (`using sprite: e.Sprite`)
- base: The built-in kind it extends (`.Sprite`)
- hooks: Its procedures, as a script's (self: the node)
- loc: Where it's called from (the editor opens the file)
*/
NodeType_Register :: proc "contextless" ($T: typeid, base: SceneNodeKind, hooks: ScriptHooks(T), loc := #caller_location) {
	context = Platform_DefaultContext()
	name := fmt.aprintf("%v", typeid_of(T))
	if dot := strings.last_index_byte(name, '.'); dot >= 0 do name = name[dot + 1:]
	first := reflect.struct_field_at(T, 0)
	if first.type == nil || first.offset != 0 || first.type.id != SCENE_NODE_TYPES[base] {
		fmt.eprintfln("Node type %s: its first field must be `using x: e.%v` (the %v kind's type); not registered", name, SCENE_NODE_TYPES[base], base)
		return
	}
	if _, builtin := reflect.enum_from_name(SceneNodeKind, name); builtin {
		fmt.eprintfln("Node type %s: a built-in kind has that name; not registered", name)
		return
	}
	info := new(NodeTypeInfo)
	info.base = base
	info.info = {
		name = name,
		type = T,
		pointerType = typeid_of(^T),
		size = size_of(T),
		align = align_of(T),
		file = loc.file_path,
		line = int(loc.line),
		ready = transmute(proc(self: rawptr))hooks.ready,
		update = transmute(proc(self: rawptr, events: []sdl.Event, deltaTime: f64))hooks.update,
		draw = transmute(proc(self: rawptr, renderer: ^sdl.Renderer))hooks.draw,
		destroy = transmute(proc(self: rawptr))hooks.destroy,
		collisionEnter = transmute(proc(self: rawptr, collision: ^Collision))hooks.collisionEnter,
		collisionExit = transmute(proc(self: rawptr, collision: ^Collision))hooks.collisionExit,
		areaEnter = transmute(proc(self: rawptr, collision: ^Collision))hooks.areaEnter,
		areaExit = transmute(proc(self: rawptr, collision: ^Collision))hooks.areaExit,
	}
	info.fields = exportedFields(T)
	info.events = scriptEvents(T)
	nodeTypes[name] = info
}

// The custom node type registered under a name, or nil
NodeType_Find :: proc(name: string) -> ^NodeTypeInfo {
	return nodeTypes[name]
}

// Every registered custom node type, by name (temp allocated)
NodeType_All :: proc() -> []^NodeTypeInfo {
	all := make([dynamic]^NodeTypeInfo, context.temp_allocator)
	for _, info in nodeTypes do append(&all, info)
	slice.sort_by(all[:], proc(a, b: ^NodeTypeInfo) -> bool { return a.name < b.name })
	return all[:]
}

// INTERNAL

// The loader's: the next CreateNode allocates this type (nil: the base kind's own)
@(private)
nodeTypeBegin :: proc(info: ^NodeTypeInfo) {
	nodeTypeOverride = info
}

// The loader's: a node built as a custom type gets its hooks and fields
@(private)
nodeTypeAttach :: proc(node: ^Node, info: ^NodeTypeInfo, values: []ScriptPropData) {
	nodeTypeOverride = nil
	if node == nil || node.type != info.type do return
	nodePaths := scriptInitFields(node, &info.info, values, Node_GetAllocator(node))
	node.custom = {info = &info.info, data = node, nodePaths = nodePaths}
}

_ :: runtime
_ :: log
_ :: fmt
_ :: reflect
_ :: strings
_ :: sdl
