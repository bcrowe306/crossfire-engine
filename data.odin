package crossfire

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"

/*
Data resources: reusable game data (enemy stats, items, levels, dialogue) as project files,
separate from code.

A data type is a struct registered like a script, with exported fields:

	EnemyStats :: struct {
		health: int `export:"default=10 min=1"`,
		speed: f32 `export:"default=100"`,
		sprite: e.TextureAsset `export:""`,
	}

	@(init)
	register_EnemyStats :: proc "contextless" () {
		e.Data_Register(EnemyStats)
	}

Each instance is a file, `data/<name>.data.json`, listed in project.xml as an asset of kind
"Data" (so exports ship it), made and edited in the editor:

	{"formatVersion": 1, "type": "EnemyStats", "values": {"health": "30", "speed": "80"}}

Values are text in the same forms as script fields in scene files (`Script_SetField`); missing
ones get their default. `Data(EnemyStats, DATA_GOBLIN)` loads a file the first time and returns
the same instance after that: everyone shares it, so treat it as read-only (copy it to change
it). It lives as long as the game.
*/

// A registered data type (`Data_Register`)
DataInfo :: struct {
	// The struct's type name without its package ("EnemyStats"): what data files name
	name: string,
	// The struct's type
	type: typeid,
	// size_of the struct, in bytes
	size: int,
	// align_of the struct
	align: int,
	// Where Data_Register was called, so the editor can open the file
	file: string,
	// The line of that call
	line: int,
	// Its exported fields, in declaration order
	fields: []ScriptField,
}

// What a data file holds (`ParseDataResource`): its type's name and its field values as text
DataResourceData :: struct {
	// The data type's name (`DataInfo.name`)
	type: string,
	// The field values as text, sorted by field name
	values: [dynamic]ScriptPropData,
}

// The data file format written by the editor
DATA_FORMAT_VERSION :: 1

/*
Registers a data type, so data files can hold it and the editor can make and edit them. Call it
from an `@(init) proc "contextless"` in the type's file, like `Script_Register`. Registering a
name again replaces it.

Inputs:
- T: The data struct (exported fields: `export:""` tags)
- loc: Where it's called from (filled in by the compiler)

Example:
	package mygame

	import e "../engine"

	EnemyStats :: struct {
		health: int `export:"default=10 min=1"`,
		speed: f32 `export:"default=100"`,
	}

	@(init)
	register_EnemyStats :: proc "contextless" () {
		e.Data_Register(EnemyStats)
	}
*/
Data_Register :: proc "contextless" ($T: typeid, loc := #caller_location) {
	context = Platform_DefaultContext()
	name := fmt.aprintf("%v", typeid_of(T))
	if dot := strings.last_index_byte(name, '.'); dot >= 0 do name = name[dot + 1:]
	info := new(DataInfo)
	info^ = {name = name, type = T, size = size_of(T), align = align_of(T), file = loc.file_path, line = int(loc.line), fields = exportedFields(T)}
	dataRegistry[name] = info
}

/*
The data type registered under a name.

Inputs:
- name: The type's name without its package ("EnemyStats")

Returns:
- Its info, or nil if no data type has that name
*/
Data_Find :: proc(name: string) -> ^DataInfo {
	return dataRegistry[name]
}

/*
Every registered data type, sorted by name.

Returns:
- The types' info (the slice is temp allocated)
*/
Data_All :: proc() -> []^DataInfo {
	all := make([dynamic]^DataInfo, context.temp_allocator)
	for _, info in dataRegistry do append(&all, info)
	slice.sort_by(all[:], proc(a, b: ^DataInfo) -> bool { return a.name < b.name })
	return all[:]
}

/*
A data resource, loaded the first time and shared after that.

Inputs:
- T: Its type (registered with `Data_Register`)
- asset: The data file (a `DATA_...` constant from the generated assets.odin, or an exported
  DataAsset field)
- game: The game (default: the one playing)

Returns:
- The instance (shared and kept for the game's life: treat it as read-only), or nil (logged) if
  the file is missing, isn't valid, or holds another type

Example:
	package mygame

	import e "../engine"

	EnemyStats :: struct {
		health: int `export:"default=10 min=1"`,
	}

	DATA_GOBLIN :: e.DataAsset{"data/goblin.data.json"}

	GoblinHealth :: proc() -> int {
		stats := e.Data(EnemyStats, DATA_GOBLIN)
		return stats != nil ? stats.health : 10
	}
*/
Data :: proc($T: typeid, asset: DataAsset, game: ^Game = nil) -> ^T {
	game := game != nil ? game : currentGame
	if game == nil || asset.path == "" do return nil
	if cached, ok := game.data[asset.path]; ok {
		if cached.type != T {
			log.errorf("Data %s holds %v, not %v", asset.path, cached.type, typeid_of(T))
			return nil
		}
		return cast(^T)cached.data
	}
	instance := loadData(game, asset.path)
	if instance.data == nil do return nil
	if instance.type != T {
		log.errorf("Data %s holds %v, not %v", asset.path, instance.type, typeid_of(T))
		return nil
	}
	return cast(^T)instance.data
}

/*
Parses a data file's text.

Inputs:
- text: The file's JSON
- allocator: For the result

Returns:
- data: Its type name and values (allocated with `allocator`; free with `DataResourceData_Destroy`)
- err: .None; .Invalid_XML when it isn't JSON (the error for any unreadable file); .Wrong_Root when
  it isn't an object with a "type"; .Unsupported_Version when it's from a newer `DATA_FORMAT_VERSION`
*/
ParseDataResource :: proc(text: string, allocator := context.allocator) -> (data: DataResourceData, err: ProjectError) {
	value, parseErr := json.parse_string(text, allocator = context.temp_allocator)
	if parseErr != nil do return {}, .Invalid_XML
	root, isObject := value.(json.Object)
	if !isObject do return {}, .Wrong_Root
	if version, ok := root["formatVersion"].(json.Float); ok && int(version) > DATA_FORMAT_VERSION do return {}, .Unsupported_Version
	typeName, hasType := root["type"].(json.String)
	if !hasType do return {}, .Wrong_Root
	context.allocator = allocator
	data.type = strings.clone(typeName)
	data.values = make([dynamic]ScriptPropData)
	if values, ok := root["values"].(json.Object); ok {
		keys := make([dynamic]string, context.temp_allocator)
		for key in values do append(&keys, key)
		slice.sort(keys[:])
		for key in keys {
			text: string
			#partial switch v in values[key] {
			case json.String:  text = v
			case json.Float:   text = fmt.tprint(v)
			case json.Integer: text = fmt.tprint(v)
			case json.Boolean: text = v ? "true" : "false"
			case: continue
			}
			append(&data.values, ScriptPropData{strings.clone(key), strings.clone(text)})
		}
	}
	return data, .None
}

/*
Writes the text of a data file (what the editor saves; `ParseDataResource` reads it back).
Values are written as JSON strings in the given order, so the output is deterministic.

Inputs:
- type: The data type's name
- values: The field values as text
- allocator: For the text

Returns:
- The file's JSON (allocated with `allocator`)
*/
FormatDataResource :: proc(type: string, values: []ScriptPropData, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "{{\n\t\"formatVersion\": %d,\n\t\"type\": %q,\n\t\"values\": {{", DATA_FORMAT_VERSION, type)
	for v, i in values {
		fmt.sbprintf(&b, "%s\n\t\t%q: %q", i > 0 ? "," : "", v.name, v.value)
	}
	strings.write_string(&b, len(values) > 0 ? "\n\t}\n}\n" : "}\n}\n")
	return strings.to_string(b)
}

/*
Frees what `ParseDataResource` allocated and zeroes the data.

Inputs:
- data: The parsed data
- allocator: The allocator that was given to `ParseDataResource`
*/
DataResourceData_Destroy :: proc(data: ^DataResourceData, allocator := context.allocator) {
	context.allocator = allocator
	delete(data.type)
	for v in data.values { delete(v.name); delete(v.value) }
	delete(data.values)
	data^ = {}
}

// A loaded data resource (Game.data)
@(private)
DataInstance :: struct {
	type: typeid,
	data: rawptr,
}

@(private="file")
dataRegistry: map[string]^DataInfo

// The game playing: what `Data` and `Global` use when not given one (Game_LoadProject sets it)
@(private)
currentGame: ^Game

// Reads, parses and builds a data file into the game's memory; caches failures as nil
@(private="file")
loadData :: proc(game: ^Game, path: string) -> DataInstance {
	key := strings.clone(path, Game_GetAllocator(game))
	text, ok := Platform_ReadFile(projectPath(game, path))
	if !ok {
		log.errorf("Data %s: no such file", path)
		game.data[key] = {}
		return {}
	}
	parsed, err := ParseDataResource(string(text), context.temp_allocator)
	if err != .None {
		log.errorf("Data %s: can't read it (%v)", path, err)
		game.data[key] = {}
		return {}
	}
	info := Data_Find(parsed.type)
	if info == nil {
		log.errorf("Data %s: no data type named %s (is it registered with e.Data_Register?)", path, parsed.type)
		game.data[key] = {}
		return {}
	}
	allocator := Game_GetAllocator(game)
	memory, allocErr := runtime.mem_alloc(info.size, info.align, allocator)
	if allocErr != nil do return {}
	self := raw_data(memory)
	setFields(self, info.name, info.fields, parsed.values[:], allocator)
	instance := DataInstance{type = info.type, data = self}
	game.data[key] = instance
	return instance
}

// Sets exported fields from text values (defaults for the missing ones, and for bad values: warned)
@(private)
setFields :: proc(self: rawptr, owner: string, fields: []ScriptField, values: []ScriptPropData, allocator: runtime.Allocator) {
	for field in fields {
		value := field.defaultValue
		for v in values do if v.name == field.name do value = v.value
		if !Script_SetField(self, field, value, allocator) {
			log.warnf("%s.%s: can't use '%s'; using the default", owner, field.name, value)
			_ = Script_SetField(self, field, field.defaultValue, allocator)
		}
	}
}
