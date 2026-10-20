#+build !js
package crossfire

import "core:encoding/json"
import "core:strings"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

TestMood :: enum { Calm, Angry }

TestScript :: struct {
	using script: Script,
	speed: f32 `export:"default=250 min=0"`,
	lives: int `export:"default=3 max=9"`,
	alive: bool `export:""`,
	title: string `export:"default=Hero"`,
	next: string `export:"kind=scene"`,
	spawn: [2]f32 `export:"default=10, 20"`,
	tint: sdl.Color `export:"default=#ff8000"`,
	mood: TestMood `export:""`,
	// Not exported
	counter: int,
}

// Tests run on parallel threads: each counts its own calls
@(thread_local)
testReady, testUpdates, testDestroyed: int

// Registered once, by whichever test runs first. Not @(init): _test.odin files are also compiled
// into normal builds, and an @(init) here would register it in every game
@(private="file")
registerOnce: sync.Once

registerTestScript :: proc() {
	sync.once_do(&registerOnce, registerTestScriptNow)
}

@(private="file")
registerTestScriptNow :: proc() {
	Script_Register(TestScript, {
		ready = proc(self: ^TestScript) {
			testReady += 1
			self.counter = 100
		},
		update = proc(self: ^TestScript, events: []sdl.Event, dt: f64) {
			testUpdates += 1
			self.counter += 1
			self.node.position.x += self.speed * f32(dt)
		},
		destroy = proc(self: ^TestScript) { testDestroyed += 1 },
	})
}

@(test)
script_registry_and_fields :: proc(t: ^testing.T) {
	registerTestScript()
	info := Script_Find("TestScript")
	testing.expect(t, info != nil)
	if info == nil do return
	testing.expect_value(t, info.size, size_of(TestScript))
	testing.expect(t, strings.has_suffix(info.file, "script_test.odin"))
	names := make([dynamic]string, context.temp_allocator)
	for f in info.fields do append(&names, f.name)
	testing.expect_value(t, len(names), 8)
	testing.expect_value(t, info.fields[0].type, ScriptFieldType.Float)
	testing.expect_value(t, info.fields[0].defaultValue, "250")
	testing.expect_value(t, info.fields[0].min.? or_else -1, 0)
	testing.expect_value(t, info.fields[4].hint, "scene")
	testing.expect_value(t, info.fields[5].defaultValue, "10, 20")
	testing.expect_value(t, info.fields[7].type, ScriptFieldType.Enum)
	testing.expect_value(t, info.fields[7].enumNames[1], "Angry")

	// The description the editor reads is valid JSON
	text := Script_DescribeJSON(context.temp_allocator)
	value, err := json.parse_string(text, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	_ = value
	free_all(context.temp_allocator)
}

@(test)
script_lifecycle_on_a_node :: proc(t: ^testing.T) {
	registerTestScript()
	testReady, testUpdates, testDestroyed = 0, 0, 0
	scene := new(Scene)
	defer free(scene)
	Scene_Init(scene)
	node := CreateNode(scene, Node)
	self := cast(^TestScript)Node_AttachScript(node, Script_Find("TestScript"), {
		{"speed", "100"}, {"lives", "42"}, {"alive", "true"}, {"spawn", "1.5, -2"},
		{"tint", "#102030"}, {"mood", "Angry"}, {"title", "not a number is fine"},
	})
	testing.expect(t, self != nil)
	testing.expect_value(t, self.node, node)
	testing.expect_value(t, self.speed, 100)
	// Clamped to max=9
	testing.expect_value(t, self.lives, 9)
	testing.expect_value(t, self.alive, true)
	testing.expect_value(t, self.spawn, [2]f32{1.5, -2})
	testing.expect_value(t, self.tint, sdl.Color{0x10, 0x20, 0x30, 255})
	testing.expect_value(t, self.mood, TestMood.Angry)
	testing.expect_value(t, self.next, "")
	testing.expect_value(t, Node_GetScript(node, TestScript), self)
	// One script per node
	testing.expect(t, Node_AttachScript(node, Script_Find("TestScript"), nil) == nil)

	// ready once before the first update, then update every frame
	Scene_Update(scene, nil, 0.5)
	Scene_Update(scene, nil, 0.5)
	testing.expect_value(t, testReady, 1)
	testing.expect_value(t, testUpdates, 2)
	testing.expect_value(t, self.counter, 102)
	testing.expect_value(t, node.position.x, 100)

	Scene_Destroy(scene)
	testing.expect_value(t, testDestroyed, 1)
}

@(test)
script_bad_values_use_defaults :: proc(t: ^testing.T) {
	registerTestScript()
	scene := new(Scene)
	defer free(scene)
	Scene_Init(scene)
	defer Scene_Destroy(scene)
	node := CreateNode(scene, Node)
	self := cast(^TestScript)Node_AttachScript(node, Script_Find("TestScript"), {{"speed", "fast"}, {"mood", "Sleepy"}, {"speed2", "1"}})
	testing.expect_value(t, self.speed, 250)
	testing.expect_value(t, self.lives, 3)
	testing.expect_value(t, self.title, "Hero")
	testing.expect_value(t, self.mood, TestMood.Calm)
	testing.expect_value(t, self.tint, sdl.Color{255, 128, 0, 255})
}

@(test)
find_nodes_by_name_and_path :: proc(t: ^testing.T) {
	scene := new(Scene)
	defer free(scene)
	Scene_Init(scene)
	defer Scene_Destroy(scene)
	world := CreateNode(scene, Node); world.name = "World"
	ship := CreateNode(scene, Node); ship.name = "Ship"
	flame := CreateNode(scene, Node); flame.name = "Flame"
	Node_AddChild(world, ship)
	Node_AddChild(ship, flame)
	// Found while still queued, and after joining the scene
	testing.expect_value(t, Scene_FindNode(scene, "Flame"), flame)
	Scene_ProcessQueues(scene)
	testing.expect_value(t, Scene_FindNode(scene, "World/Ship/Flame"), flame)
	testing.expect_value(t, Scene_FindNode(scene, "World/Ship"), ship)
	testing.expect_value(t, Node_FindChild(world, "Ship/Flame"), flame)
	testing.expect(t, Scene_FindNode(scene, "Ship/Flame") == nil)
	testing.expect(t, Scene_FindNode(scene, "World/Nope") == nil)
}

@(test)
scene_format_v3_scripts :: proc(t: ^testing.T) {
	text := `<?xml version="1.0" encoding="UTF-8"?>
<scene formatVersion="3" name="S">
	<node kind="Sprite" name="Player" x="1" y="2">
		<script name="PlayerController">
			<prop name="speed" value="250"/>
			<prop name="title" value="Hi &amp; bye"/>
		</script>
		<script name="Ignored"/>
	</node>
	<node kind="Node2D" name="Plain"/>
</scene>`
	scene, err := ParseScene(text)
	defer SceneData_Destroy(&scene)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, scene.nodes[0].script, "PlayerController")
	testing.expect_value(t, len(scene.nodes[0].props), 2)
	testing.expect_value(t, scene.nodes[0].props[1].value, "Hi & bye")
	testing.expect_value(t, scene.nodes[1].script, "")
	// Version 4 isn't read
	_, newer := ParseScene(`<scene formatVersion="99" name="S"/>`)
	testing.expect_value(t, newer, ProjectError.Unsupported_Version)
}

@(test)
player_command_line :: proc(t: ^testing.T) {
	options, ok := Player_ParseArgs({"player", "MyGame"})
	testing.expect(t, ok)
	testing.expect_value(t, options.projectDir, "MyGame")
	testing.expect_value(t, options.scene, "")
	testing.expect(t, options.folderGiven)
	options, ok = Player_ParseArgs({"player", "MyGame", "--scene", "Level2"})
	testing.expect(t, ok)
	testing.expect_value(t, options.scene, "Level2")
	options, ok = Player_ParseArgs({"player", "--describe-scripts"})
	testing.expect(t, ok && options.describe)
	options, ok = Player_ParseArgs({"player"})
	testing.expect(t, ok && options.projectDir == "." && !options.folderGiven)
	_, ok = Player_ParseArgs({"player", "MyGame", "--scene"})
	testing.expect(t, !ok)
	_, ok = Player_ParseArgs({"player", "A", "B"})
	testing.expect(t, !ok)
}
