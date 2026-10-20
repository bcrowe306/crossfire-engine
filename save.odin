package crossfire

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:reflect"
import "core:strings"

/*
Saving and loading game state as JSON: what's in the globals (globals.odin).

	e.Save_Game()          // into the "save" slot
	e.Load_Game()          // false if there's no save yet
	e.Save_Game("slot2")

A save holds every global's state by field name:
- Fields that aren't exported are the game's state: saved, unless tagged `save:"-"` (caches,
  pointers to nodes).
- Exported fields (`export:""`) are settings from the editor: not saved, so changing them in the
  editor reaches players who have a save. Tag one `save:""` when the player changes it too (a
  chosen ship, a volume): then the save's value wins.
Fields that can't be written as JSON are skipped with a warning. Numbers, bools, strings, enums (by name), arrays, slices, dynamic arrays, maps,
nested structs and asset handles all work. Loading sets the fields a save has and leaves the
others (fields added to a global since the save keep their values), then calls the globals'
`loaded` hook.

	{
		"formatVersion": 1,
		"globals": {
			"GameState": {"score": 120, "lives": 2, "highScore": 900}
		}
	}

Where saves go:
- Desktop: the per-user data folder SDL picks (`SDL_GetPrefPath`): `<user data>/<game name>/saves/<slot>.json`.
  Games run from the editor (`--dev`) use `<game name> (dev)`, so testing never touches the
  saves of an exported game.
- Web: the browser's localStorage, under `<game name>/<slot>`.
*/

// The save format written by `Save_ToJSON`; saves from a newer version aren't loaded
SAVE_FORMAT_VERSION :: 1

/*
Saves the game: every global's fields, as JSON, in a slot.

Inputs:
- slot: The save's name (letters, digits, - and _ are safest: it's a file name)
- game: The game (default: the one playing)

Returns:
- Whether it was written (failures are logged); false when there's no game

Example:
	if e.Save_Game() do log.info("saved")
*/
Save_Game :: proc(slot := "save", game: ^Game = nil) -> bool {
	game := game != nil ? game : currentGame
	if game == nil do return false
	text, ok := Save_ToJSON(game, context.temp_allocator)
	if !ok do return false
	if !Platform_SaveWrite(saveName(game, slot), transmute([]byte)text) {
		log.errorf("Couldn't save the game to slot %s", slot)
		return false
	}
	log.infof("Saved the game (%s)", slot)
	return true
}

/*
Loads a save into the globals and calls their `loaded` hooks.

Inputs:
- slot: The save's name, as given to `Save_Game`
- game: The game (default: the one playing)

Returns:
- false if there's no such save or it can't be read (the globals are left as they were)

Example:
	if e.Save_Exists() && !e.Load_Game() do log.warn("the save couldn't be loaded")
*/
Load_Game :: proc(slot := "save", game: ^Game = nil) -> bool {
	game := game != nil ? game : currentGame
	if game == nil do return false
	data, ok := Platform_SaveRead(saveName(game, slot))
	if !ok do return false
	if !Save_FromJSON(game, string(data)) {
		log.errorf("The save %s can't be read", slot)
		return false
	}
	for g in game.globals do if g.info.loaded != nil do g.info.loaded(g.data)
	log.infof("Loaded the game (%s)", slot)
	return true
}

/*
Whether a save slot exists.

Inputs:
- slot: The save's name
- game: The game (default: the one playing)

Returns:
- true if it exists; false too when there's no game
*/
Save_Exists :: proc(slot := "save", game: ^Game = nil) -> bool {
	game := game != nil ? game : currentGame
	return game != nil && Platform_SaveExists(saveName(game, slot))
}

/*
Deletes a save slot (nothing happens if there's none).

Inputs:
- slot: The save's name
- game: The game (default: the one playing)
*/
Save_Delete :: proc(slot := "save", game: ^Game = nil) {
	game := game != nil ? game : currentGame
	if game != nil do Platform_SaveDelete(saveName(game, slot))
}

/*
The globals as save JSON (what `Save_Game` writes). Fields that can't be written as JSON are
skipped with a warning.

Inputs:
- game: The game
- allocator: For the text

Returns:
- The JSON text (allocated with `allocator`), and true
*/
Save_ToJSON :: proc(game: ^Game, allocator := context.allocator) -> (string, bool) {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "{{\n\t\"formatVersion\": %d,\n\t\"globals\": {{", SAVE_FORMAT_VERSION)
	for g, i in game.globals {
		fmt.sbprintf(&b, "%s\n\t\t%q: {{", i > 0 ? "," : "", g.info.name)
		first := true
		for field in savedFields(g.info.type) {
			value, err := json.marshal(any{rawptr(uintptr(g.data) + field.offset), field.type.id}, {use_enum_names = true}, context.temp_allocator)
			if err != nil {
				log.warnf("Save: %s.%s (%v) can't be saved as JSON (%v); tag it save:\"-\"", g.info.name, field.name, field.type.id, err)
				continue
			}
			fmt.sbprintf(&b, "%s\n\t\t\t%q: %s", first ? "" : ",", field.name, string(value))
			first = false
		}
		strings.write_string(&b, first ? "}" : "\n\t\t}")
	}
	strings.write_string(&b, len(game.globals) > 0 ? "\n\t}\n}\n" : "}\n}\n")
	return strings.to_string(b), true
}

/*
Sets the globals' fields from save JSON (what `Load_Game` reads). Fields the save doesn't have are
left alone; globals it doesn't name too. Doesn't call the `loaded` hooks (`Load_Game` does).
Strings and other memory it reads go in the game's arena.

Inputs:
- game: The game
- text: The save's JSON

Returns:
- false if the text isn't a save (or is from a newer `SAVE_FORMAT_VERSION`)
*/
Save_FromJSON :: proc(game: ^Game, text: string) -> bool {
	value, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil do return false
	root, ok := value.(json.Object)
	if !ok do return false
	if version, has := root["formatVersion"].(json.Float); has && int(version) > SAVE_FORMAT_VERSION do return false
	globals, hasGlobals := root["globals"].(json.Object)
	if !hasGlobals do return false
	allocator := Game_GetAllocator(game)
	for g in game.globals {
		saved, found := globals[g.info.name].(json.Object)
		if !found do continue
		// Only what the save may hold: the header and save:"-" fields stay as they are
		allowed := make(json.Object, allocator = context.temp_allocator)
		for field in savedFields(g.info.type) {
			if value, has := saved[field.name]; has do allowed[field.name] = value
		}
		raw, marshalErr := json.marshal(json.Value(allowed), allocator = context.temp_allocator)
		if marshalErr != nil do continue
		// Into the whole struct at once (fields the save lacks are left alone)
		target := g.data
		if unmarshalErr := json.unmarshal_any(raw, any{&target, g.info.pointerType}, allocator = allocator); unmarshalErr != nil {
			log.warnf("Load: %s: %v", g.info.name, unmarshalErr)
		}
	}
	return true
}

// A struct's fields that saves hold (temp allocated): not the Script header; not exported fields
// unless tagged `save:""`; not `save:"-"` ones
@(private="file")
savedFields :: proc(T: typeid) -> []reflect.Struct_Field {
	fields := make([dynamic]reflect.Struct_Field, context.temp_allocator)
	for field, i in reflect.struct_fields_zipped(T) {
		if i == 0 && field.type.id == Script do continue
		save, tagged := reflect.struct_tag_lookup(field.tag, "save")
		if tagged && save == "-" do continue
		if tag, has := reflect.struct_tag_lookup(field.tag, "json"); has && tag == "-" do continue
		_, exported := reflect.struct_tag_lookup(field.tag, "export")
		if exported && !tagged do continue
		append(&fields, field)
	}
	return fields[:]
}

// The storage name of a slot: <game>/<slot>, with the dev suffix for runs from the editor
@(private)
saveName :: proc(game: ^Game, slot: string) -> string {
	name := game.name != "" ? game.name : "game"
	if game.devKeys do name = fmt.tprintf("%s (dev)", name)
	return fmt.tprintf("%s/%s", name, slot)
}

_ :: runtime
