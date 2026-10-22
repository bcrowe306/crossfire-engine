package crossfire

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

/*
Restarting a game where it was: what an editor's hot reload does when scripts change (the editor
rebuilds the game, then restarts it in the same state).

- `Game_Snapshot` writes the game's state as JSON: the scene playing, the globals (what
  `Save_Game` writes) and every node of the scene's properties (`Node_Properties`: position,
  rotation, scale, tint, visibility, an AnimatedSprite's animation, a state machine's state, every
  script field...), by the node's path of names ("World/Ship").
- `Game_RestoreSnapshot` puts it back into a freshly started game: the globals at once, the nodes
  after the scene's scripts' `ready` (so a script's ready doesn't undo it). Nodes the new scene
  doesn't have, and properties that no longer exist (a field renamed), are skipped.
- The editor asks over the live link (`snapshot <file>`: live.odin) and starts the new game with
  `player --restore <file>`.

What isn't carried over: nodes made at run time (bullets, spawned enemies), physics velocities,
timers and tweens in flight, sounds playing, and the fields of scripts that aren't exported and
aren't in globals. The game restarts its scene from the scene file, then those values go on top.
*/

// The format `Game_Snapshot` writes
GAME_SNAPSHOT_VERSION :: 1

/*
The game's state as JSON (temp allocated): the scene, the globals, every node's properties.

Inputs:
- game: The game

Returns:
- The JSON text
*/
Game_Snapshot :: proc(game: ^Game) -> string {
	b := strings.builder_make(context.temp_allocator)
	scene := game.currentScene
	globals, _ := Save_ToJSON(game, context.temp_allocator)
	fmt.sbprintf(&b, "{{\"version\": %d, \"scene\": %q, \"globals\": %q, \"nodes\": [", GAME_SNAPSHOT_VERSION, scene != nil ? scene.name : "", globals)
	first := true
	if scene != nil {
		for node in scene.nodes {
			if !node.inScene do continue
			if !first do strings.write_string(&b, ",")
			first = false
			fmt.sbprintf(&b, "\n{{\"path\": %q, \"props\": {{", Node_NamePath(node))
			for property, i in Node_Properties(node, context.temp_allocator) {
				value, ok := Animator_ReadProperty(node, property, context.temp_allocator)
				if !ok do continue
				fmt.sbprintf(&b, "%s%q: %q", i == 0 ? "" : ", ", property, value)
			}
			strings.write_string(&b, "}}")
		}
	}
	strings.write_string(&b, "]}\n")
	return strings.to_string(b)
}

/*
Puts a snapshot back (`Game_Snapshot`'s JSON): the globals now, the nodes' properties after the
next update of the scene (its scripts' ready). The game must be playing the snapshot's scene
(the player's `--restore` starts it there).

Inputs:
- game: The game
- text: The snapshot

Returns:
- false when the text isn't a snapshot
*/
Game_RestoreSnapshot :: proc(game: ^Game, text: string) -> bool {
	snapshot, ok := Snapshot_Parse(text)
	if !ok do return false
	if snapshot.globals != "" && !Save_FromJSON(game, snapshot.globals) do log.warn("Hot reload: the globals couldn't be restored")
	// The nodes wait for the scene's first update (Game_Update calls snapshotApply)
	game.pendingSnapshot = strings.clone(text, Game_GetAllocator(game))
	return true
}

// A snapshot's contents (temp allocated)
Snapshot :: struct {
	version: int,
	scene: string,
	globals: string,
	nodes: []struct { path: string, props: map[string]string },
}

// Reads a snapshot's JSON (temp allocated); false when it isn't one
Snapshot_Parse :: proc(text: string) -> (snapshot: Snapshot, ok: bool) {
	if json.unmarshal(transmute([]byte)text, &snapshot, allocator = context.temp_allocator) != nil do return {}, false
	return snapshot, snapshot.version == GAME_SNAPSHOT_VERSION
}

/*
A node's path of names from the top of its scene ("World/Ship"), what `Scene_FindNode` takes
(temp allocated).
*/
Node_NamePath :: proc(node: ^Node) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for n := node; n != nil; n = n.parent do inject_at(&names, 0, n.name)
	return strings.join(names[:], "/", context.temp_allocator)
}

// INTERNAL

// Applies a pending snapshot's nodes (Game_Update, after the scene's update)
@(private)
snapshotApply :: proc(game: ^Game) {
	text := game.pendingSnapshot
	game.pendingSnapshot = ""
	snapshot, ok := Snapshot_Parse(text)
	scene := game.currentScene
	if !ok || scene == nil do return
	if snapshot.scene != scene.name {
		log.warnf("Hot reload: the game is in %s, not %s: nodes not restored", scene.name, snapshot.scene)
		return
	}
	restored, missing := 0, 0
	for n in snapshot.nodes {
		node := Scene_FindNode(scene, n.path)
		if node == nil {
			missing += 1
			continue
		}
		for property, value in n.props do _ = Node_WriteProperty(node, property, value)
		restored += 1
	}
	log.infof("Hot reload: restored %d node%s%s", restored, restored == 1 ? "" : "s", missing > 0 ? fmt.tprintf(" (%d no longer in the scene)", missing) : "")
}
