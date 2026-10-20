package crossfire

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
Scripts: game code written in Odin, attached to the nodes of a scene.

A script is a struct whose first field is `using script: Script`, plus the procedures the engine
calls for it. It's registered once, by name, and scene files attach it to a node by that name
(`<script name="Player">`). When the scene is built, the engine allocates the struct in the
node's memory arena (it's freed with the node), fills in its exported fields from the scene
file, and calls its procedures:

	ready    once, on the first update after the node entered the scene (every node of the scene
	         exists by then, so it can look others up)
	update   every frame, after the node's own update
	draw     after the node draws, in the node's local space (optional)
	destroy  when the node is freed (optional; the struct's memory is freed anyway)

A project keeps its scripts in one Odin package (`scripts/`); each file registers its script
from an `@(init)` procedure, so linking the package in is enough:

	package scripts

	import "core:log"
	import e "engine:."
	import sdl "vendor:sdl3"

	Player :: struct {
		using script: e.Script,
		speed: f32 `export:"default=250 min=0"`,
		lives: int `export:"default=3"`,
		// Not exported: state the script keeps for itself
		velocity: [2]f32,
	}

	@(init)
	register_Player :: proc "contextless" () {
		e.Script_Register(Player, {
			ready = proc(self: ^Player) {
				log.infof("%s is ready", self.node.name)
			},
			update = proc(self: ^Player, events: []sdl.Event, dt: f64) {
				self.node.position.x += self.speed * f32(dt)
			},
		})
	}

Exported fields are the ones tagged `export:""`; they show in the editor's inspector and are
saved in the scene. Supported types: f32, f64, int, i32, bool, string, [2]f32, enums,
sdl.Color (`#rrggbb`), and the asset handles of assets.odin (`TextureAsset`, `SoundAsset`,
`FontAsset`, `DataAsset`, `ComponentAsset`, `MusicAsset`), and pointers to nodes (`^e.Node`,
`^e.Sprite`, `^e.CharacterMover`...). Tag options, space-separated inside the quotes:
`default=<value>` (else the type's zero value; white for colors, the first value for enums),
`min=<n>`, `max=<n>`, and `kind=scene` for a string naming a scene (`kind=<DataType>` for a
`DataAsset`).

**Node fields** hold a path to another node (`Node_FindPath`: relative to the script's node, as
`Sword` or `../Camera`; from the scene's root with a leading `/`). Just before `ready` they're
set to that node, if it's there and of the field's type (or a type that embeds it: a
`^e.PhysicsBody` field takes a DynamicBody); otherwise they stay nil, with a warning. An empty
path leaves the field nil. Only node scripts get them (globals and data resources have no node).

	Hero :: struct {
		using script: e.Script,
		sword: ^e.Area `export:"default=Sword"`,
		camera: ^e.Camera2D `export:"default=../Camera"`,
	}

One script per node. The registry is global (scripts register before `main`).
*/

// The first field of every script struct: what the script is attached to
Script :: struct {
	// The node it's attached to (nil for globals: globals.odin)
	node: ^Node,
	// The node's scene (a global's: nil, see globals.odin)
	scene: ^Scene,
	// The game it runs in
	game: ^Game,
	// Globals: skip `draw` while set
	hidden: bool,
}

// The procedures a script can have; all optional
ScriptHooks :: struct($T: typeid) {
	// Once, on the first update after the node entered the scene (every node of it exists then)
	ready: proc(self: ^T),
	// Every frame the node may process, after the node's own update (deltaTime in seconds)
	update: proc(self: ^T, events: []sdl.Event, deltaTime: f64),
	// After the node draws, in the node's local space
	draw: proc(self: ^T, renderer: ^sdl.Renderer),
	// When the node is freed (the struct's memory is freed with the node anyway)
	destroy: proc(self: ^T),
	// Physics body nodes only: another body started / stopped touching this one (or entered /
	// left it, for an Area). `collision` is valid during the call
	collisionEnter: proc(self: ^T, collision: ^Collision),
	// Physics body nodes only: another body stopped touching this one (or left it, for an Area)
	collisionExit: proc(self: ^T, collision: ^Collision),
	// Physics body nodes only: this body entered / left an Area (`collision.other`)
	areaEnter: proc(self: ^T, collision: ^Collision),
	// Physics body nodes only: this body left an Area (`collision.other`)
	areaExit: proc(self: ^T, collision: ^Collision),
	// Globals only (globals.odin): the game switched to `scene`; Load_Game restored the fields
	sceneChanged: proc(self: ^T, scene: ^Scene),
	// Globals only (globals.odin): `Load_Game` restored the fields
	loaded: proc(self: ^T),
}

// A registered script (`Script_Register`): its type, its exported fields and its hooks, untyped
ScriptInfo :: struct {
	// The struct's type name without its package ("Player"): what scene files attach
	name: string,
	// The script struct's type
	type: typeid,
	// typeid_of(^T): what JSON loading needs (save.odin)
	pointerType: typeid,
	// size_of the struct, in bytes
	size: int,
	// align_of the struct
	align: int,
	// Where Script_Register was called, so the editor can open the file
	file: string,
	// The line of that call
	line: int,
	// Its exported fields, in declaration order
	fields: []ScriptField,
	// The hooks of `ScriptHooks`, taking the struct as a rawptr (nil: not given)
	ready: proc(self: rawptr),
	// ScriptHooks.update
	update: proc(self: rawptr, events: []sdl.Event, deltaTime: f64),
	// ScriptHooks.draw
	draw: proc(self: rawptr, renderer: ^sdl.Renderer),
	// ScriptHooks.destroy
	destroy: proc(self: rawptr),
	// ScriptHooks.collisionEnter
	collisionEnter: proc(self: rawptr, collision: ^Collision),
	// ScriptHooks.collisionExit
	collisionExit: proc(self: rawptr, collision: ^Collision),
	// ScriptHooks.areaEnter
	areaEnter: proc(self: rawptr, collision: ^Collision),
	// ScriptHooks.areaExit
	areaExit: proc(self: rawptr, collision: ^Collision),
	// ScriptHooks.sceneChanged
	sceneChanged: proc(self: rawptr, scene: ^Scene),
	// ScriptHooks.loaded
	loaded: proc(self: rawptr),
}

// What an exported field holds, as the scene file and the editor see it
ScriptFieldType :: enum {
	// f32 or f64
	Float,
	// int or i32
	Int,
	Bool,
	String,
	// [2]f32, as "x, y"
	Vector2,
	// sdl.Color, as `#rrggbb` or `#rrggbbaa`
	Color,
	// Any enum, by value name
	Enum,
	// Asset handles (assets.odin): the value is the asset's path
	Texture,
	Sound,
	Font,
	Data,
	Component,
	Music,
	// A pointer to a node (`^e.Sprite`...): the value is a path (`Node_FindPath`), resolved
	// before `ready`
	Node,
}

// An exported field of a script
ScriptField :: struct {
	// The field's name in the struct (and in `<prop name="...">`)
	name: string,
	// What kind of value it holds
	type: ScriptFieldType,
	// Its byte offset in the script struct
	offset: uintptr,
	// The field's Odin type (f32 vs f64, int vs i32, which enum)
	odinType: typeid,
	// Text form of the value used when the scene file has none
	defaultValue: string,
	// The tag's `min=`: numbers below it are raised to it (nil: no minimum)
	min: Maybe(f64),
	// The tag's `max=`: numbers above it are lowered to it (nil: no maximum)
	max: Maybe(f64),
	// "scene" for a string naming a scene; for a Data field, the data type it holds (`kind=EnemyStats`);
	// for a Node field, the node type it points to, without its package ("CharacterMover")
	hint: string,
	// Node fields: the node type the pointer points to (`Node`, `Sprite`...)
	nodeType: typeid,
	// Enum fields: the names, in order
	enumNames: []string,
}

// The running node's script (set when a scene with scripts is built)
@(private)
NodeScript :: struct {
	info: ^ScriptInfo,
	data: rawptr,
	ready: bool,
	// Node fields' paths, by field index ("" for other fields and empty paths), resolved before
	// `ready`; nil without node fields. In the node's arena
	nodePaths: []string,
}

@(private="file")
registry: map[string]^ScriptInfo

/*
Registers a script type under its type name. Call it from an `@(init)` procedure in the script's
file; Odin requires those to be `proc "contextless"`, and this procedure is too, so it can be
called there directly. Registering the same name twice replaces the first. A struct whose first
field isn't `using script: Script` isn't registered (an error is printed to stderr).

Inputs:
- T: The script struct; its first field must be `using script: Script`
- hooks: Its procedures (all optional)
- loc: Where it's called from (kept so the editor can open the file)

Example:
	package scripts

	import e "engine:."
	import sdl "vendor:sdl3"

	Spinner :: struct {
		using script: e.Script,
		speed: f32 `export:"default=90"`,
	}

	@(init)
	register_Spinner :: proc "contextless" () {
		e.Script_Register(Spinner, {
			update = proc(self: ^Spinner, events: []sdl.Event, dt: f64) {
				self.node.rotation += self.speed * f32(dt)
			},
		})
	}
*/
Script_Register :: proc "contextless" ($T: typeid, hooks: ScriptHooks(T), loc := #caller_location) {
	// @(init) procedures run before main and must be contextless, so this sets up its own context
	context = Platform_DefaultContext()
	info := new(ScriptInfo)
	name := fmt.aprintf("%v", typeid_of(T))
	// "scripts.Player" -> "Player"
	if dot := strings.last_index_byte(name, '.'); dot >= 0 do name = name[dot + 1:]
	info^ = {
		name = name,
		type = T,
		pointerType = typeid_of(^T),
		size = size_of(T),
		align = align_of(T),
		file = loc.file_path,
		line = int(loc.line),
		// ^T and rawptr are passed the same way, so the typed procedures can be stored untyped
		ready = transmute(proc(self: rawptr))hooks.ready,
		update = transmute(proc(self: rawptr, events: []sdl.Event, deltaTime: f64))hooks.update,
		draw = transmute(proc(self: rawptr, renderer: ^sdl.Renderer))hooks.draw,
		destroy = transmute(proc(self: rawptr))hooks.destroy,
		collisionEnter = transmute(proc(self: rawptr, collision: ^Collision))hooks.collisionEnter,
		collisionExit = transmute(proc(self: rawptr, collision: ^Collision))hooks.collisionExit,
		areaEnter = transmute(proc(self: rawptr, collision: ^Collision))hooks.areaEnter,
		areaExit = transmute(proc(self: rawptr, collision: ^Collision))hooks.areaExit,
		sceneChanged = transmute(proc(self: rawptr, scene: ^Scene))hooks.sceneChanged,
		loaded = transmute(proc(self: rawptr))hooks.loaded,
	}

	first := reflect.struct_field_at(T, 0)
	if first.type == nil || first.type.id != Script || first.offset != 0 {
		// No logger exists yet before main
		fmt.eprintfln("Script %s: its first field must be `using script: e.Script`; not registered", name)
		return
	}
	info.fields = exportedFields(T)
	registry[name] = info
}

/*
The script registered under a name, or nil.

Inputs:
- name: The script's name ("Player")

Returns:
- Its info, or nil when no script has that name
*/
Script_Find :: proc(name: string) -> ^ScriptInfo {
	return registry[name]
}

// Every registered script, sorted by name (temp allocated)
Script_All :: proc() -> []^ScriptInfo {
	all := make([dynamic]^ScriptInfo, context.temp_allocator)
	for _, info in registry do append(&all, info)
	slice.sort_by(all[:], proc(a, b: ^ScriptInfo) -> bool { return a.name < b.name })
	return all[:]
}

/*
Attaches a script to a node: allocates its struct in the node's arena and sets its exported fields
from `values` (name, value text; missing ones get their default).

Inputs:
- node: The node
- info: The script
- values: Field values from the scene file

Returns:
- The script's struct, or nil if the node already has one
*/
Node_AttachScript :: proc(node: ^Node, info: ^ScriptInfo, values: []ScriptPropData) -> rawptr {
	if node.script.info != nil do return nil
	allocator := Node_GetAllocator(node)
	data, err := runtime.mem_alloc(info.size, info.align, allocator)
	if err != nil do return nil
	self := raw_data(data)
	script := cast(^Script)self
	script.node = node
	script.scene = node.scene
	script.game = node.scene != nil ? node.scene.game : nil
	nodePaths: []string
	for field, i in info.fields {
		value := field.defaultValue
		for v in values do if v.name == field.name do value = v.value
		if field.type == .Node {
			// Resolved before ready (Scene_ReadyScripts): the other nodes may not exist yet
			if nodePaths == nil do nodePaths = make([]string, len(info.fields), allocator)
			nodePaths[i] = strings.clone(strings.trim_space(value), allocator)
			continue
		}
		if !Script_SetField(self, field, value, allocator) {
			log.warnf("%s.%s: can't use '%s'; using the default", info.name, field.name, value)
			_ = Script_SetField(self, field, field.defaultValue, allocator)
		}
	}
	node.script = {info = info, data = self, nodePaths = nodePaths}
	return self
}

/*
The script attached to a node, as its struct type, or nil if it has none or another script.

Inputs:
- node: The node (nil gives nil)
- T: The script struct's type

Returns:
- The node's script struct, or nil

Example:
	Player :: struct {
		using script: e.Script,
		lives: int `export:"default=3"`,
	}
	if player := e.Node_GetScript(node, Player); player != nil do player.lives -= 1
*/
Node_GetScript :: proc(node: ^Node, $T: typeid) -> ^T {
	if node == nil || node.script.info == nil || node.script.info.type != T do return nil
	return cast(^T)node.script.data
}

/*
Sets a script field from its text form, as stored in scene files.

Inputs:
- self: The script struct
- field: Which field
- text: The value
- allocator: For string fields

Returns:
- Whether the text was a valid value for the field
*/
Script_SetField :: proc(self: rawptr, field: ScriptField, text: string, allocator := context.allocator) -> bool {
	at := rawptr(uintptr(self) + field.offset)
	text := strings.trim_space(text)
	switch field.type {
	case .Float:
		v, ok := strconv.parse_f64(text == "" ? "0" : text)
		if !ok do return false
		v = clampField(v, field)
		if field.odinType == f64 do (cast(^f64)at)^ = v
		else do (cast(^f32)at)^ = f32(v)
	case .Int:
		v, ok := strconv.parse_int(text == "" ? "0" : text)
		if !ok do return false
		v = int(clampField(f64(v), field))
		if field.odinType == i32 do (cast(^i32)at)^ = i32(v)
		else do (cast(^int)at)^ = v
	case .Bool:
		switch text {
		case "true", "1": (cast(^bool)at)^ = true
		case "false", "0", "": (cast(^bool)at)^ = false
		case: return false
		}
	case .String, .Texture, .Sound, .Font, .Data, .Component, .Music:
		// The handles are a struct holding a path: laid out like a string
		(cast(^string)at)^ = strings.clone(text, allocator)
	case .Node:
		// A path, found when the scene is ready (Node_AttachScript keeps it): nothing to set here
		(cast(^rawptr)at)^ = nil
	case .Vector2:
		v, ok := parseVector2(text)
		if !ok do return false
		(cast(^[2]f32)at)^ = v
	case .Color:
		if text == "" {
			(cast(^sdl.Color)at)^ = {255, 255, 255, 255}
			return true
		}
		c, ok := ParseColor(text)
		if !ok do return false
		(cast(^sdl.Color)at)^ = c
	case .Enum:
		index := -1
		for name, i in field.enumNames do if name == text do index = i
		if text == "" do index = 0
		if index < 0 do return false
		values := reflect.enum_field_values(field.odinType)
		ti := runtime.type_info_base(type_info_of(field.odinType))
		size := ti.size
		v := values[index]
		switch size {
		case 1: (cast(^i8)at)^ = i8(v)
		case 2: (cast(^i16)at)^ = i16(v)
		case 4: (cast(^i32)at)^ = i32(v)
		case: (cast(^i64)at)^ = i64(v)
		}
	}
	return true
}

/*
A description of every registered script and data type, as JSON: what `player --describe-scripts`
prints so the editor can show exported fields in its inspector. `{"scripts": [...], "data": [...]}`,
each with name, file, line, and for each field name, type, default, min/max (when set), hint, and
enum names.

Inputs:
- allocator: Allocator for the string

Returns:
- The JSON text
*/
Script_DescribeJSON :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "{\"scripts\": [")
	for info, i in Script_All() {
		if i > 0 do strings.write_string(&b, ", ")
		fmt.sbprintf(&b, "{{\"name\": %q, \"file\": %q, \"line\": %d, \"fields\": ", info.name, info.file, info.line)
		describeFields(&b, info.fields)
		strings.write_string(&b, "}")
	}
	// Data types (data.odin): the same, without hooks
	strings.write_string(&b, "], \"data\": [")
	for info, i in Data_All() {
		if i > 0 do strings.write_string(&b, ", ")
		fmt.sbprintf(&b, "{{\"name\": %q, \"file\": %q, \"line\": %d, \"fields\": ", info.name, info.file, info.line)
		describeFields(&b, info.fields)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

@(private="file")
describeFields :: proc(b: ^strings.Builder, fields: []ScriptField) {
	strings.write_string(b, "[")
	for field, j in fields {
		if j > 0 do strings.write_string(b, ", ")
		fmt.sbprintf(b, "{{\"name\": %q, \"type\": %q, \"default\": %q, \"hint\": %q", field.name, fmt.tprint(field.type), field.defaultValue, field.hint)
		if v, ok := field.min.?; ok do fmt.sbprintf(b, ", \"min\": %v", v)
		if v, ok := field.max.?; ok do fmt.sbprintf(b, ", \"max\": %v", v)
		if len(field.enumNames) > 0 {
			strings.write_string(b, ", \"enum\": [")
			for name, k in field.enumNames {
				if k > 0 do strings.write_string(b, ", ")
				fmt.sbprintf(b, "%q", name)
			}
			strings.write_string(b, "]")
		}
		strings.write_string(b, "}")
	}
	strings.write_string(b, "]")
}

// Runs scripts' `ready` for nodes that haven't had it yet. Called by Scene_Update before updates
@(private)
Scene_ReadyScripts :: proc(scene: ^Scene) {
	// Listeners first, so a ready that sets something off is heard
	for node in scene.nodes do if !node.listenersBound && len(node.listeners) > 0 do bindListeners(node)
	for node in scene.nodes {
		s := &node.script
		if s.info == nil || s.ready do continue
		s.ready = true
		if s.nodePaths != nil do resolveNodeFields(node)
		if s.info.ready != nil do s.info.ready(s.data)
	}
}

// Sets a script's node fields to the nodes their paths name (Node_AttachScript kept the paths)
@(private="file")
resolveNodeFields :: proc(node: ^Node) {
	s := &node.script
	for field, i in s.info.fields {
		path := s.nodePaths[i]
		if field.type != .Node || path == "" do continue
		target := Node_FindPath(node, path)
		at := cast(^rawptr)(uintptr(s.data) + field.offset)
		switch {
		case target == nil:
			log.warnf("%s.%s: no node at '%s' from %s", s.info.name, field.name, path, node.name)
		case !typeEmbeds(target.type, field.nodeType):
			log.warnf("%s.%s: '%s' is a %v, not a %s", s.info.name, field.name, path, target.type, field.hint)
		case:
			at^ = target
		}
	}
}

// Whether a node type is `want`, or embeds it through its first field (`using node: Node`...)
@(private)
typeEmbeds :: proc(have, want: typeid) -> bool {
	if have == want do return true
	if have == nil || !reflect.is_struct(type_info_of(have)) || len(reflect.struct_field_names(have)) == 0 do return false
	first := reflect.struct_field_at(have, 0)
	return first.is_using && typeEmbeds(first.type.id, want)
}

// The node type a pointer field points to, or nil when it isn't a pointer to a node type
@(private="file")
pointedNodeType :: proc(id: typeid) -> typeid {
	pointer, ok := runtime.type_info_base(type_info_of(id)).variant.(runtime.Type_Info_Pointer)
	if !ok || pointer.elem == nil do return nil
	elem := pointer.elem.id
	return typeEmbeds(elem, Node) ? elem : nil
}

// The exported fields of a script or data type
@(private)
exportedFields :: proc(T: typeid) -> []ScriptField {
	fields := make([dynamic]ScriptField)
	for f in reflect.struct_fields_zipped(T) {
		options, exported := reflect.struct_tag_lookup(f.tag, "export")
		if !exported do continue
		field := ScriptField{name = f.name, offset = f.offset, odinType = f.type.id}
		base := runtime.type_info_base(f.type)
		switch {
		case f.type.id == f32 || f.type.id == f64: field.type = .Float
		case f.type.id == int || f.type.id == i32: field.type = .Int
		case f.type.id == bool: field.type = .Bool
		case f.type.id == string: field.type = .String
		case f.type.id == [2]f32: field.type = .Vector2
		case f.type.id == sdl.Color: field.type = .Color
		case f.type.id == TextureAsset: field.type = .Texture
		case f.type.id == SoundAsset: field.type = .Sound
		case f.type.id == FontAsset: field.type = .Font
		case f.type.id == DataAsset: field.type = .Data
		case f.type.id == ComponentAsset: field.type = .Component
		case f.type.id == MusicAsset: field.type = .Music
		case reflect.is_enum(base):
			field.type = .Enum
			field.enumNames = reflect.enum_field_names(f.type.id)
		case pointedNodeType(f.type.id) != nil:
			field.type = .Node
			field.nodeType = pointedNodeType(f.type.id)
			field.hint = "Node"
			if named, isNamed := type_info_of(field.nodeType).variant.(runtime.Type_Info_Named); isNamed do field.hint = named.name
		case:
			log.warnf("%v.%s: %v can't be exported (use f32, f64, int, i32, bool, string, [2]f32, an enum, sdl.Color, an asset handle or a node pointer)", T, f.name, f.type.id)
			continue
		}
		for option in tagOptions(options) {
			switch option.key {
			case "default": field.defaultValue = option.value
			case "min": if v, ok := strconv.parse_f64(option.value); ok do field.min = v
			case "max": if v, ok := strconv.parse_f64(option.value); ok do field.max = v
			case "kind": if field.type != .Node do field.hint = option.value
			}
		}
		if field.defaultValue == "" {
			#partial switch field.type {
			case .Float, .Int: field.defaultValue = "0"
			case .Bool: field.defaultValue = "false"
			case .Vector2: field.defaultValue = "0, 0"
			case .Color: field.defaultValue = "#ffffff"
			case .Enum: if len(field.enumNames) > 0 do field.defaultValue = field.enumNames[0]
			}
		}
		append(&fields, field)
	}
	return fields[:]
}

@(private="file")
clampField :: proc(v: f64, field: ScriptField) -> f64 {
	v := v
	if lo, ok := field.min.?; ok do v = max(v, lo)
	if hi, ok := field.max.?; ok do v = min(v, hi)
	return v
}

// "12, -3.5" -> {12, -3.5}
@(private="file")
parseVector2 :: proc(text: string) -> ([2]f32, bool) {
	if text == "" do return {}, true
	x, _, y := strings.partition(text, ",")
	a, okA := strconv.parse_f32(strings.trim_space(x))
	b, okB := strconv.parse_f32(strings.trim_space(y))
	return {a, b}, okA && okB
}

// `default=10, 20 min=0`: each option runs from its key to the next known key, so values can hold
// spaces and commas (temp allocated)
@(private="file")
tagOptions :: proc(text: string) -> []struct { key, value: string } {
	KEYS :: [?]string{"default=", "min=", "max=", "kind="}
	Option :: struct { key, value: string }
	starts := make([dynamic]int, context.temp_allocator)
	for i in 0..<len(text) {
		if i > 0 && text[i - 1] != ' ' do continue
		for key in KEYS do if strings.has_prefix(text[i:], key) do append(&starts, i)
	}
	options := make([]Option, len(starts), context.temp_allocator)
	for start, n in starts {
		end := n + 1 < len(starts) ? starts[n + 1] : len(text)
		key, _, value := strings.partition(text[start:end], "=")
		options[n] = {key, strings.trim_space(value)}
	}
	return transmute([]struct { key, value: string })options
}
