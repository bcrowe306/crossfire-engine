package crossfire

import "core:encoding/uuid"
import "core:fmt"
import "core:log"
import "core:reflect"
import "core:strings"
import "core:sync"
import sdl "vendor:sdl3"

/*
The live link: a game run by an editor (the player's `--live`) answers it while it plays: what's
in the playing scene, a node's properties, how long each part of a frame takes. The editor can
change properties, and pause the game and step it a frame at a time.

The channel is the game's standard input and output, one line per message:

- **Commands** (the editor writes them to the game's stdin; a thread reads them and
  `LiveLink_Process` runs them at the start of each update):
  - `watch`: send stats four times a second and the scene's tree twice a second
  - `select <id>`: also send that node's properties with each tree (`select` alone: none)
  - `set <id> <property> <value>`: sets a property (`Node_WriteProperty`)
  - `pause`, `resume`, `step` (one frame of 1/60 s while paused)
  - `shapes on`, `shapes off`: shows or hides the physics debug shapes (`Physics_SetDebugDraw`,
    what F9 toggles in development runs); the next stats come at once and say so
  - `machine <id>`: send that StateMachine's state with each stats (its guards and conditions:
    an editor's States tab while it plays); `machine` alone stops it
  - `fields <Script> <id> <field> <field>...`: send those fields of that script on that node with
    each stats (any field of the struct, exported or not: what a code editor shows beside the
    declarations). One watch per script name: `fields <Script>` alone stops it, `fields` alone
    stops them all
- **Replies** (lines on stdout starting `@@live `, then JSON):
  - `{"type":"stats","fps":..,"frame":..,"update":..,"physics":..,"draw":..,"nodes":..,"drawn":..,"paused":..,"shapes":..}`
    (milliseconds, averaged over the last frames; `shapes`: the debug shapes are shown)
  - `{"type":"tree","scene":"..","nodes":[{"id":"..","name":"..","type":"..","parent":"..","visible":true,"scripts":["Hero"]}, ...]}`
    (`scripts`: the scripts the node runs, its node type's first; left out when none)
  - `{"type":"node","id":"..","properties":[{"name":"..","value":".."}, ...]}`
  - `{"type":"set","ok":true,"id":"..","property":".."}`
  - `{"type":"machine","id":"..","state":"..","previous":"..","time":..,"canExit":..,"exit":[..],"params":[{"name":"..","value":".."}],"transitions":[{"status":"Ready","when":[true,false],"guard":[]}, ...]}`
    (a watched machine: `exit`, `when` and `guard` say whether each clause of the current state's
    exit guard and of each transition's condition and guard holds, for flat conditions; a
    transition's `status` is a `StateMachineTransitionStatus`; code guards are called)
  - `{"type":"fields","script":"..","id":"..","values":[{"name":"..","value":".."}, ...]}` (a
    watched script's fields, `fmt`'s `%v` of each, strings quoted, a node pointer as its node's
    name, at most LIVE_FIELD_TEXT bytes; a field the struct doesn't have is left out; nothing
    when the node is gone or doesn't run the script)

Ids are the nodes' `EntityId`s as text. Exports never run with `--live`; on the web there's no
stdin, so `LiveLink_Start` does nothing there.
*/

// A game's live link (`Game.live`, made by `LiveLink_Start`)
LiveLink :: struct {
	// Lines read from stdin, waiting for the next update (guarded by `lock`)
	lock: sync.Mutex,
	incoming: [dynamic]string,
	// The game's updates are held (it still draws)
	paused: bool,
	// One update to run while paused
	step: bool,
	// Stats and the tree are being sent
	watching: bool,
	// The node whose properties are sent ("": none)
	selected: string,
	// Seconds to the next stats and tree
	statsTimer, treeTimer: f32,
	// The script fields being sent with the stats (`fields`; strings owned)
	fieldWatches: [dynamic]LiveFieldWatch,
	// The StateMachine whose state is sent with the stats (`machine`; "": none; owned)
	machine: string,
}

// A script's fields an editor watches on a node (`fields <Script> <id> <field>...`)
LiveFieldWatch :: struct {
	script, id: string,
	fields: []string,
}

// The longest a watched field's value is sent (longer ones are cut, ending with "...")
LIVE_FIELD_TEXT :: 80

/*
How long the parts of the last frames took (`Game.profile`): measured every frame, averaged over
`PROFILE_FRAMES`.
*/
GameProfile :: struct {
	// Milliseconds: globals and the scene's update (physics included), physics alone, drawing
	update, physics, draw: f32,
	// Nodes in the playing scene, and drawn last frame
	nodes, drawn: int,
}

// How many frames the profile averages
PROFILE_FRAMES :: 30

// The prefix of the live link's replies on stdout
LIVE_PREFIX :: "@@live "

/*
Runs the commands that came in since the last update, and sends what the editor watches. Game_Update
calls it first.

Inputs:
- game: The game
- deltaTime: Seconds since the last frame

Returns:
- false while the game is paused (no update this frame); true to update (a step included)
*/
LiveLink_Process :: proc(game: ^Game, deltaTime: f64) -> bool {
	link := game.live
	if link == nil do return true
	sync.mutex_lock(&link.lock)
	lines := link.incoming[:]
	link.incoming = make([dynamic]string)
	sync.mutex_unlock(&link.lock)
	defer {
		for line in lines do delete(line)
		delete(lines)
	}
	for line in lines do liveCommand(game, line)
	if link.watching {
		link.statsTimer -= f32(deltaTime)
		link.treeTimer -= f32(deltaTime)
		if link.statsTimer <= 0 {
			link.statsTimer = 0.25
			liveSendStats(game)
			for w in link.fieldWatches do liveSendFields(game, w)
			if link.machine != "" do liveSendMachine(game, link.machine)
		}
		if link.treeTimer <= 0 {
			link.treeTimer = 0.5
			liveSendTree(game)
			if link.selected != "" do liveSendNode(game, link.selected)
		}
	}
	if !link.paused do return true
	if link.step {
		link.step = false
		return true
	}
	return false
}

/*
Hands the live link a line, as if read from stdin (tests; the reader thread does it in games).

Inputs:
- game: The game (with a live link)
- line: A command
*/
LiveLink_Push :: proc(game: ^Game, line: string) {
	link := game.live
	if link == nil do return
	sync.mutex_lock(&link.lock)
	append(&link.incoming, strings.clone(line))
	sync.mutex_unlock(&link.lock)
}

/*
Frees a game's live link (Game_Destroy).
*/
LiveLink_Destroy :: proc(game: ^Game) {
	link := game.live
	if link == nil do return
	sync.mutex_lock(&link.lock)
	for line in link.incoming do delete(line)
	delete(link.incoming)
	sync.mutex_unlock(&link.lock)
	delete(link.selected)
	delete(link.machine)
	for &w in link.fieldWatches do liveFieldWatchFree(&w)
	delete(link.fieldWatches)
	// The reader thread may still hold it (it's blocked on stdin): it isn't freed
	game.live = nil
}

/*
A node by its id as text (as the live link sends them).

Inputs:
- scene: The scene
- id: The id

Returns:
- The node, or nil
*/
Scene_GetNodeByText :: proc(scene: ^Scene, id: string) -> ^Node {
	if scene == nil do return nil
	parsed, err := uuid.read(id)
	if err != nil do return nil
	return Scene_GetNode(scene, parsed)
}

// The line a reply is printed on (tests read them through `liveOutput`)
@(private)
liveOutput: proc(line: string) = proc(line: string) {
	fmt.println(line)
}

@(private="file")
liveCommand :: proc(game: ^Game, line: string) {
	link := game.live
	command, _, rest := strings.partition(strings.trim_space(line), " ")
	switch command {
	case "watch":
		link.watching = true
		link.statsTimer, link.treeTimer = 0, 0
	case "unwatch":
		link.watching = false
	case "select":
		delete(link.selected)
		link.selected = strings.clone(strings.trim_space(rest))
		if link.selected != "" do liveSendNode(game, link.selected)
	case "pause":
		link.paused = true
	case "resume":
		link.paused = false
	case "step":
		link.step = true
	case "shapes":
		// The physics debug shapes (an editor's toolbar button; F9 does the same in the game)
		on := strings.trim_space(rest) == "on"
		Physics_SetDebugDraw(game, on)
		log.infof("Collision shapes %s (the editor)", on ? "shown" : "hidden")
		link.statsTimer = 0
	case "snapshot":
		// A hot reload: the game's state into a file, for the restarted game (hot_reload.odin)
		path := strings.trim_space(rest)
		ok := path != "" && Platform_WriteFile(path, transmute([]byte)Game_Snapshot(game))
		liveOutput(fmt.tprintf(`%s{{"type":"snapshot","ok":%v,"path":%q}}`, LIVE_PREFIX, ok, path))
	case "fields":
		// A code editor's live values (the script's fields beside their declarations)
		words := strings.fields(rest, context.temp_allocator)
		if len(words) == 0 {
			for &w in link.fieldWatches do liveFieldWatchFree(&w)
			clear(&link.fieldWatches)
			break
		}
		for i := len(link.fieldWatches) - 1; i >= 0; i -= 1 {
			if link.fieldWatches[i].script != words[0] do continue
			liveFieldWatchFree(&link.fieldWatches[i])
			ordered_remove(&link.fieldWatches, i)
		}
		if len(words) < 3 do break
		w := LiveFieldWatch{script = strings.clone(words[0]), id = strings.clone(words[1]), fields = make([]string, len(words) - 2)}
		for name, i in words[2:] do w.fields[i] = strings.clone(name)
		append(&link.fieldWatches, w)
		liveSendFields(game, w)
	case "machine":
		delete(link.machine)
		link.machine = strings.clone(strings.trim_space(rest))
		if link.machine != "" do liveSendMachine(game, link.machine)
	case "set":
		id, _, more := strings.partition(rest, " ")
		property, _, value := strings.partition(more, " ")
		node := Scene_GetNodeByText(game.currentScene, id)
		ok := node != nil && Node_WriteProperty(node, property, value)
		liveOutput(fmt.tprintf(`%s{{"type":"set","ok":%v,"id":%q,"property":%q}}`, LIVE_PREFIX, ok, id, property))
		if ok && id == link.selected do liveSendNode(game, id)
	}
}

@(private="file")
liveSendStats :: proc(game: ^Game) {
	fps, frame, _ := Game_GetFrameStats(game)
	p := game.profile
	liveOutput(fmt.tprintf(`%s{{"type":"stats","fps":%.1f,"frame":%.2f,"update":%.2f,"physics":%.2f,"draw":%.2f,"nodes":%d,"drawn":%d,"paused":%v,"shapes":%v}}`,
		LIVE_PREFIX, fps, frame, p.update, p.physics, p.draw, p.nodes, p.drawn, game.live.paused, game.physics.debugDraw))
}

@(private="file")
liveSendTree :: proc(game: ^Game) {
	scene := game.currentScene
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `%s{{"type":"tree","scene":%q,"nodes":[`, LIVE_PREFIX, scene != nil ? scene.name : "")
	if scene != nil {
		first := true
		// Depth first: parents before children, siblings in order
		visit :: proc(b: ^strings.Builder, node: ^Node, first: ^bool) {
			if !first^ do strings.write_string(b, ",")
			first^ = false
			parent := node.parent != nil ? uuid.to_string(node.parent.id, context.temp_allocator) : ""
			fmt.sbprintf(b, `{{"id":%q,"name":%q,"type":%q,"parent":%q,"visible":%v`,
				uuid.to_string(node.id, context.temp_allocator), node.name, fmt.tprint(node.type), parent, node.visible)
			if scripts := Node_Scripts(node); len(scripts) > 0 {
				strings.write_string(b, `,"scripts":[`)
				for s, i in scripts {
					if i > 0 do strings.write_string(b, ",")
					fmt.sbprintf(b, "%q", s.info.name)
				}
				strings.write_string(b, "]")
			}
			strings.write_string(b, "}")
			for child in node.children do visit(b, child, first)
		}
		for node in scene.nodes do if node.parent == nil do visit(&b, node, &first)
	}
	strings.write_string(&b, "]}")
	liveOutput(strings.to_string(b))
}

@(private="file")
liveSendNode :: proc(game: ^Game, id: string) {
	node := Scene_GetNodeByText(game.currentScene, id)
	if node == nil do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `%s{{"type":"node","id":%q,"name":%q,"properties":[`, LIVE_PREFIX, id, node.name)
	for property, i in Node_Properties(node, context.temp_allocator) {
		value, _ := Animator_ReadProperty(node, property, context.temp_allocator)
		if i > 0 do strings.write_string(&b, ",")
		fmt.sbprintf(&b, `{{"name":%q,"value":%q}}`, property, value)
	}
	strings.write_string(&b, "]}")
	liveOutput(strings.to_string(b))
}

// A watched StateMachine's state (nothing when the node is gone or isn't one)
@(private="file")
liveSendMachine :: proc(game: ^Game, id: string) {
	node := Scene_GetNodeByText(game.currentScene, id)
	if node == nil || !Node_Is(node, StateMachine) do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `%s{{"type":"machine","id":%q,`, LIVE_PREFIX, id)
	StateMachine_LiveJSON(cast(^StateMachine)node, &b)
	strings.write_byte(&b, '}')
	liveOutput(strings.to_string(b))
}

// A watched script's fields on its node (nothing when the node is gone or doesn't run it)
@(private="file")
liveSendFields :: proc(game: ^Game, w: LiveFieldWatch) {
	node := Scene_GetNodeByText(game.currentScene, w.id)
	if node == nil do return
	script: ^NodeScript
	for s in Node_Scripts(node) do if s.info.name == w.script {
		script = s
		break
	}
	if script == nil || script.data == nil do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `%s{{"type":"fields","script":%q,"id":%q,"values":[`, LIVE_PREFIX, w.script, w.id)
	first := true
	for name in w.fields {
		value, found := LiveLink_FieldText(script.info.type, script.data, name, context.temp_allocator)
		if !found do continue
		if !first do strings.write_string(&b, ",")
		first = false
		fmt.sbprintf(&b, `{{"name":%q,"value":%q}}`, name, value)
	}
	strings.write_string(&b, "]}")
	liveOutput(strings.to_string(b))
}

@(private="file")
liveFieldWatchFree :: proc(w: ^LiveFieldWatch) {
	delete(w.script)
	delete(w.id)
	for f in w.fields do delete(f)
	delete(w.fields)
	w^ = {}
}

/*
A struct field's value as the live link sends it: `fmt`'s `%v`, a string quoted, a pointer to a
node its node's name (`nil` when none), cut to LIVE_FIELD_TEXT bytes.

Inputs:
- type: The struct's type (a script's: `ScriptInfo.type`)
- data: The struct
- name: The field's name (any field, exported or not)
- allocator: For the text

Returns:
- The text, and false when the struct has no such field

Example:
	Hero :: struct {
		using script: e.Script,
		hp: int,
	}
	hero := Hero{hp = 3}
	text, _ := e.LiveLink_FieldText(Hero, &hero, "hp", context.temp_allocator) // "3"
*/
LiveLink_FieldText :: proc(type: typeid, data: rawptr, name: string, allocator := context.allocator) -> (string, bool) {
	if data == nil || name == "" do return "", false
	field := reflect.struct_field_by_name(type, name)
	if field.type == nil do return "", false
	ptr := rawptr(uintptr(data) + field.offset)
	text: string
	switch {
	case field.type.id == string:
		text = fmt.tprintf("%q", (^string)(ptr)^)
	case pointedNodeType(field.type.id) != nil:
		node := (^^Node)(ptr)^
		text = node == nil ? "nil" : node.name
	case:
		text = fmt.tprintf("%v", any{ptr, field.type.id})
	}
	if len(text) > LIVE_FIELD_TEXT {
		cut := LIVE_FIELD_TEXT - 3
		// Not inside a UTF-8 sequence
		for cut > 0 && text[cut] & 0xC0 == 0x80 do cut -= 1
		text = fmt.tprintf("%s...", text[:cut])
	}
	return strings.clone(text, allocator), true
}

// Times a part of the frame into the profile (a running average over PROFILE_FRAMES)
@(private)
profileAdd :: proc(slot: ^f32, start: u64) {
	ms := f32(f64(sdl.GetPerformanceCounter() - start) * 1000 / f64(sdl.GetPerformanceFrequency()))
	slot^ += (ms - slot^) / PROFILE_FRAMES
}
