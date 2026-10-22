#+build !js
package crossfire

import "core:encoding/json"
import "core:encoding/uuid"
import "core:strings"
import "core:testing"

// The live link (live.odin): an editor's commands, the stats, tree and node replies, setting a
// property, pausing and stepping

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
	free_all(context.temp_allocator)
}
