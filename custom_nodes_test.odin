#+build !js
package crossfire

import "core:encoding/json"
import "core:log"
import "core:strings"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

// Several scripts on one node (script.odin) and custom node types (custom_nodes.odin): from scene
// files, hooks in order, fields, events, listeners, Animator properties, the catalog

TestPlayerNode :: struct {
	using sprite: Sprite,
	speed: f32 `export:"default=100"`,
	lives: int `export:"default=3"`,
	onHurt: EventSubject `event:"It was hurt"`,
	steps: int,
}

TestHealth :: struct {
	using script: Script,
	hp: int `export:"default=10"`,
	hits: int,
}

@(thread_local)
testOrder: [dynamic]string

@(private="file")
registerOnce: sync.Once

@(private="file")
registerNow :: proc() {
	registerTestScript()
	Script_Register(TestHealth, {
		update = proc(self: ^TestHealth, events: []sdl.Event, dt: f64) { append(&testOrder, "health") },
	})
	Script_Listener(TestHealth, "onHurt", proc(self: ^TestHealth, source: ^Node, data: EventData) { self.hits += 1 })
	NodeType_Register(TestPlayerNode, .Sprite, {
		ready = proc(self: ^TestPlayerNode) { self.steps = 1000 },
		update = proc(self: ^TestPlayerNode, events: []sdl.Event, dt: f64) {
			append(&testOrder, "player")
			self.steps += 1
			self.position.x += self.speed * f32(dt)
		},
	})
}

@(test)
several_scripts_and_custom_node_types :: proc(t: ^testing.T) {
	sync.once_do(&registerOnce, registerNow)
	defer { delete(testOrder); testOrder = nil }
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	data, err := ParseScene(`<scene formatVersion="13">
	<node name="Hero" kind="TestPlayerNode" baseKind="Sprite" x="10">
		<prop name="speed" value="60"/>
		<script name="TestScript"><prop name="speed" value="0"/></script>
		<script name="TestHealth"><prop name="hp" value="25"/></script>
		<listener event="script.onHurt" target="." handler="onHurt"/>
	</node>
	<node name="Ghost" kind="NotRegistered" baseKind="Sprite"/>
	<node name="Twice" kind="Node2D"><script name="TestHealth"/><script name="TestHealth"/></node>
</scene>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, data.nodes[0].customKind, "TestPlayerNode")
	testing.expect_value(t, data.nodes[0].kind, SceneNodeKind.Sprite)
	testing.expect_value(t, len(data.nodes[0].customProps), 1)
	testing.expect_value(t, data.nodes[0].script, "TestScript")
	testing.expect_value(t, len(data.nodes[0].moreScripts), 1)
	testing.expect_value(t, data.nodes[0].moreScripts[0].name, "TestHealth")
	{
		context.logger = log.nil_logger()
		_ = Scene_Build(scene, &data, "testdata")
		Scene_Update(scene, nil, 0)
	}

	// The custom type: a Sprite allocated as TestPlayerNode, its fields set, ready run
	hero := Scene_FindNode(scene, "Hero")
	testing.expect(t, hero != nil && Node_Is(hero, TestPlayerNode), "a TestPlayerNode")
	player := cast(^TestPlayerNode)hero
	testing.expect_value(t, player.speed, 60)
	testing.expect_value(t, player.lives, 3)
	// ready, then this frame's update
	testing.expect_value(t, player.steps, 1001)
	testing.expect(t, SceneNodeKind_IsType(.Sprite, "Sprite") && typeEmbeds(hero.type, Sprite), "still a kind of Sprite")
	// Its two scripts
	testing.expect_value(t, len(Node_Scripts(hero)), 3)
	health := Node_GetScript(hero, TestHealth)
	testing.expect(t, health != nil && health.hp == 25, "the second script, its field")
	testing.expect(t, Node_GetScript(hero, TestScript) != nil, "the first script")
	// Hooks in order: the node type's, then the scripts'
	clear(&testOrder)
	Scene_Update(scene, nil, 0.5)
	testing.expect(t, len(testOrder) >= 2 && testOrder[0] == "player" && testOrder[len(testOrder) - 1] == "health", "custom first, scripts after")
	testing.expect_value(t, hero.position.x, 40)
	// Its event, heard by a listener on its second script
	Event_Notify(Node_FindEvent(hero, "script.onHurt"), hero, nil)
	testing.expect_value(t, health.hits, 1)
	// The Animator reaches its fields and its scripts'
	testing.expect(t, Node_WriteProperty(hero, "script.hp", "5"), "a second script's field")
	testing.expect_value(t, health.hp, 5)
	testing.expect(t, Node_WriteProperty(hero, "script.lives", "7"), "the node type's field")
	testing.expect_value(t, player.lives, 7)

	// Unregistered: the base kind
	ghost := Scene_FindNode(scene, "Ghost")
	testing.expect(t, ghost != nil && Node_Is(ghost, Sprite), "built as a Sprite")
	// The same script twice: once
	testing.expect_value(t, len(Node_Scripts(Scene_FindNode(scene, "Twice"))), 1)

	// The catalog lists the node type
	text := Script_DescribeJSON(context.temp_allocator)
	Catalog :: struct { nodeTypes: []struct { name, base: string, fields: []struct { name: string } } }
	catalog: Catalog
	testing.expect(t, json.unmarshal(transmute([]byte)text, &catalog, allocator = context.temp_allocator) == nil, "valid JSON")
	found := false
	for nt in catalog.nodeTypes do if nt.name == "TestPlayerNode" && nt.base == "Sprite" && len(nt.fields) == 2 do found = true
	testing.expect(t, found, "described")
	_ = strings.contains
}
