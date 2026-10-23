package crossfire

import "core:encoding/uuid"
import "core:fmt"
import "core:log"
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
- **Replies** (lines on stdout starting `@@live `, then JSON):
  - `{"type":"stats","fps":..,"frame":..,"update":..,"physics":..,"draw":..,"nodes":..,"drawn":..,"paused":..,"shapes":..}`
    (milliseconds, averaged over the last frames; `shapes`: the debug shapes are shown)
  - `{"type":"tree","scene":"..","nodes":[{"id":"..","name":"..","type":"..","parent":"..","visible":true}, ...]}`
  - `{"type":"node","id":"..","properties":[{"name":"..","value":".."}, ...]}`
  - `{"type":"set","ok":true,"id":"..","property":".."}`

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
}

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
			fmt.sbprintf(b, `{{"id":%q,"name":%q,"type":%q,"parent":%q,"visible":%v}}`,
				uuid.to_string(node.id, context.temp_allocator), node.name, fmt.tprint(node.type), parent, node.visible)
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

// Times a part of the frame into the profile (a running average over PROFILE_FRAMES)
@(private)
profileAdd :: proc(slot: ^f32, start: u64) {
	ms := f32(f64(sdl.GetPerformanceCounter() - start) * 1000 / f64(sdl.GetPerformanceFrequency()))
	slot^ += (ms - slot^) / PROFILE_FRAMES
}
