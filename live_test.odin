#+build !js
package crossfire

import "core:encoding/json"
import "core:encoding/uuid"
import "core:strings"
import "core:testing"

// The live link (live.odin): an editor's commands, the stats, tree and node replies, setting a
// property, pausing and stepping, a script's fields watched

@(private="file")
LIVE_SCENE :: `<scene formatVersion="13" name="S">
	<node kind="Node2D" name="World">
		<node kind="Sprite" name="Box" x="10" y="20"/>
	</node>
	<node kind="Animator" name="Anim" autoplay="move">
		<clip name="move" length="10">
			<track node="/World" property="position.x">
				<key time="0" value="0"/>
				<key time="10" value="600"/>
			</track>
		</clip>
	</node>
</scene>`

// What the game printed (tests run on their own threads; only this one uses the link)
@(private="file")
liveLines: [dynamic]string

@(test)
the_live_link_answers_an_editor :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	data, _ := ParseScene(LIVE_SCENE)
	defer SceneData_Destroy(&data)
	created := Scene_Build(scene, &data, "testdata", attachScripts = false)
	game->switchScene("S")
	link := new(LiveLink)
	link.incoming = make([dynamic]string)
	game.live = link
	defer free(link)
	saved := liveOutput
	liveOutput = proc(line: string) { append(&liveLines, strings.clone(line)) }
	defer {
		liveOutput = saved
		for l in liveLines do delete(l)
		delete(liveLines)
		liveLines = nil
	}
	reply :: proc(type: string) -> (json.Object, bool) {
		for i := len(liveLines) - 1; i >= 0; i -= 1 {
			line := liveLines[i]
			if !strings.has_prefix(line, LIVE_PREFIX) do continue
			value, err := json.parse_string(line[len(LIVE_PREFIX):], allocator = context.temp_allocator)
			if err != nil do continue
			object := value.(json.Object) or_continue
			if object["type"].(json.String) == type do return object, true
		}
		return nil, false
	}

	// The scene starts (its nodes join it), then the editor watches
	Game_Update(game, nil, 1.0 / 60)
	LiveLink_Push(game, "watch")
	Game_Update(game, nil, 1.0 / 60)
	stats, hasStats := reply("stats")
	testing.expect(t, hasStats, "stats")
	if hasStats do testing.expect_value(t, stats["nodes"].(json.Float), 3)
	tree, hasTree := reply("tree")
	testing.expect(t, hasTree, "the tree")
	world := created[0]
	box := created[1]
	if hasTree {
		nodes := tree["nodes"].(json.Array)
		testing.expect_value(t, len(nodes), 3)
		testing.expect_value(t, nodes[0].(json.Object)["name"].(json.String), "World")
		testing.expect_value(t, nodes[1].(json.Object)["parent"].(json.String), uuid.to_string(world.id, context.temp_allocator))
	}

	// A node's properties, then one set
	boxId := uuid.to_string(box.id, context.temp_allocator)
	LiveLink_Push(game, strings.concatenate({"select ", boxId}, context.temp_allocator))
	Game_Update(game, nil, 1.0 / 60)
	props, hasProps := reply("node")
	testing.expect(t, hasProps, "the node's properties")
	if hasProps {
		found := false
		for p in props["properties"].(json.Array) {
			o := p.(json.Object)
			if o["name"].(json.String) == "position" {
				found = true
				testing.expect_value(t, o["value"].(json.String), "10, 20")
			}
		}
		testing.expect(t, found, "its position")
	}
	LiveLink_Push(game, strings.concatenate({"set ", boxId, " position 5, 6"}, context.temp_allocator))
	LiveLink_Push(game, strings.concatenate({"set ", boxId, " position nonsense"}, context.temp_allocator))
	Game_Update(game, nil, 1.0 / 60)
	testing.expect_value(t, box.position, [2]f32{5, 6})
	set, _ := reply("set")
	testing.expect(t, set["ok"].(json.Boolean) == false, "nonsense refused")

	// Paused: the Animator holds; a step moves it 1/60 s (60 px a second)
	LiveLink_Push(game, "pause")
	Game_Update(game, nil, 1.0 / 60)
	held := world.position.x
	for _ in 0..<5 do Game_Update(game, nil, 1.0 / 60)
	testing.expect_value(t, world.position.x, held)
	LiveLink_Push(game, "step")
	Game_Update(game, nil, 1.0)
	testing.expectf(t, abs(world.position.x - held - 1) < 0.01, "one step: %v", world.position.x - held)
	stats, _ = reply("stats")
	LiveLink_Push(game, "resume")
	Game_Update(game, nil, 1.0 / 60)
	testing.expect(t, world.position.x > held + 1, "moving again")

	// The debug shapes shown and hidden (the editor's toolbar button): the stats say so at once
	stats, _ = reply("stats")
	testing.expect(t, stats["shapes"].(json.Boolean) == false, "no shapes at first")
	LiveLink_Push(game, "shapes on")
	Game_Update(game, nil, 1.0 / 60)
	testing.expect(t, game.physics.debugDraw, "shown")
	stats, _ = reply("stats")
	testing.expect(t, stats["shapes"].(json.Boolean) == true, "the stats say they're shown")
	LiveLink_Push(game, "shapes off")
	Game_Update(game, nil, 1.0 / 60)
	testing.expect(t, !game.physics.debugDraw, "hidden")
	stats, _ = reply("stats")
	testing.expect(t, stats["shapes"].(json.Boolean) == false, "the stats say they're hidden")
	free_all(context.temp_allocator)

	liveFieldsCheck(t)
}

@(private="file")
LIVE_FIELDS_SCENE :: `<scene formatVersion="13">
	<node name="World" kind="Node2D">
		<node name="Ship" kind="Node2D"><script name="TestScript"><prop name="title" value="Lucky"/></script></node>
		<node name="Rock" kind="Node2D"/>
	</node>
</scene>`

// A script's fields watched (`fields`): part of the test above, since `liveOutput` is the
// package's and tests run on several threads
@(private="file")
liveFieldsCheck :: proc(t: ^testing.T) {
	registerTestScript()
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	data, _ := ParseScene(LIVE_FIELDS_SCENE)
	defer SceneData_Destroy(&data)
	_ = Scene_Build(scene, &data, "testdata")
	game->switchScene("S")
	link := new(LiveLink)
	link.incoming = make([dynamic]string)
	game.live = link
	defer free(link)
	saved := liveOutput
	liveOutput = proc(line: string) { append(&liveLines, strings.clone(line)) }
	defer {
		liveOutput = saved
		for l in liveLines do delete(l)
		delete(liveLines)
		liveLines = nil
	}
	last :: proc(type: string) -> (json.Object, int) {
		count := 0
		found: json.Object
		for line in liveLines {
			if !strings.has_prefix(line, LIVE_PREFIX) do continue
			value, err := json.parse_string(line[len(LIVE_PREFIX):], allocator = context.temp_allocator)
			if err != nil do continue
			object := value.(json.Object) or_continue
			if object["type"].(json.String) != type do continue
			found = object
			count += 1
		}
		return found, count
	}
	values :: proc(o: json.Object) -> map[string]string {
		out := make(map[string]string, context.temp_allocator)
		for v in o["values"].(json.Array) do out[v.(json.Object)["name"].(json.String)] = v.(json.Object)["value"].(json.String)
		return out
	}

	Game_Update(game, nil, 1.0 / 60)
	LiveLink_Push(game, "watch")
	Game_Update(game, nil, 1.0 / 60)
	// The tree says which nodes run which scripts
	tree, _ := last("tree")
	ship := Scene_FindNode(game.currentScene, "World/Ship")
	shipId := uuid.to_string(ship.id, context.temp_allocator)
	for n in tree["nodes"].(json.Array) {
		o := n.(json.Object)
		scripts, has := o["scripts"].(json.Array)
		if o["name"].(json.String) == "Ship" {
			testing.expect(t, has && len(scripts) == 1 && scripts[0].(json.String) == "TestScript", "the ship runs TestScript")
		} else {
			testing.expect(t, !has, "the others run none")
		}
	}

	// Any field, exported or not; a string quoted; one the struct hasn't left out
	script := Node_GetScript(ship, TestScript)
	script.counter = 7
	LiveLink_Push(game, strings.concatenate({"fields TestScript ", shipId, " speed counter title spawn nothing"}, context.temp_allocator))
	Game_Update(game, nil, 1.0 / 60)
	fields, sent := last("fields")
	testing.expect_value(t, sent, 1)
	got := values(fields)
	testing.expect_value(t, got["speed"], "250")
	testing.expect_value(t, got["counter"], "7")
	testing.expect_value(t, got["title"], `"Lucky"`)
	testing.expect_value(t, got["spawn"], "[10, 20]")
	_, hasNothing := got["nothing"]
	testing.expect(t, !hasNothing, "no such field: left out")

	// Sent again with each stats (four times a second), with the game's values (TestScript's
	// update counts frames)
	for _ in 0..<20 do Game_Update(game, nil, 1.0 / 60)
	fields, sent = last("fields")
	testing.expect(t, sent >= 2, "sent with the stats")
	testing.expect(t, values(fields)["counter"] != "7", "the new value")

	// Another node that doesn't run it, then the watch stopped: nothing more
	rock := Scene_FindNode(game.currentScene, "World/Rock")
	LiveLink_Push(game, strings.concatenate({"fields TestScript ", uuid.to_string(rock.id, context.temp_allocator), " speed"}, context.temp_allocator))
	Game_Update(game, nil, 1.0 / 60)
	_, before := last("fields")
	for _ in 0..<20 do Game_Update(game, nil, 1.0 / 60)
	_, after := last("fields")
	testing.expect_value(t, after, before)
	LiveLink_Push(game, strings.concatenate({"fields TestScript ", shipId, " speed"}, context.temp_allocator))
	LiveLink_Push(game, "fields TestScript")
	Game_Update(game, nil, 1.0 / 60)
	_, before = last("fields")
	for _ in 0..<20 do Game_Update(game, nil, 1.0 / 60)
	_, after = last("fields")
	testing.expect_value(t, after, before)

	// Long values are cut
	script.title = strings.repeat("x", 200, context.temp_allocator)
	text, ok := LiveLink_FieldText(TestScript, script, "title", context.temp_allocator)
	testing.expect(t, ok && len(text) == LIVE_FIELD_TEXT && strings.has_suffix(text, "..."), "cut")
	script.title = ""
	free_all(context.temp_allocator)
}
