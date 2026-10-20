#+build !js
package crossfire

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// Node events: what each type offers (NodeType_Events), scene file listeners bound before ready,
// and the events of cameras and menus

ListenScript :: struct {
	using script: Script,
	heard: int,
	lastSource: ^Node,
	lastData: EventData,
	heardBeforeReady: bool,
	readied: bool,
}

@(private="file")
listenOnce: sync.Once

@(private="file")
registerListenScript :: proc() {
	sync.once_do(&listenOnce, proc() {
		Script_Register(ListenScript, {ready = proc(self: ^ListenScript) { self.readied = true }})
		Script_Listener(ListenScript, "onHeard", proc(self: ^ListenScript, source: ^Node, data: EventData) {
			self.heard += 1
			self.lastSource = source
			self.lastData = data
		})
	})
}

@(private="file")
hasEvent :: proc(events: []NodeEventInfo, name: string) -> bool {
	for e in events do if e.name == name do return true
	return false
}

@(test)
node_types_list_their_events :: proc(t: ^testing.T) {
	emitter := NodeType_Events(ParticleEmitter)
	testing.expect(t, len(emitter) == 3 && emitter[0].name == "onFinished", "its own first")
	testing.expect(t, emitter[1].name == "onEnter" && emitter[2].name == "onExit", "then Node's")
	mover := NodeType_Events(CharacterMover)
	for name in ([]string{"onLanded", "onLeftFloor", "onWallHit", "onCeilingHit", "onCollisionEnter", "onAreaExit", "onEnter"}) {
		testing.expectf(t, hasEvent(mover, name), "CharacterMover has %s", name)
	}
	for e in mover do if e.name == "onCollisionEnter" do testing.expect(t, strings.contains(e.dataHint, "Collision_FromEvent"), "a data hint")
	testing.expect(t, hasEvent(NodeType_Events(AnimatedSprite), "animation.onAnimationEnded"), "a struct field's events")
	for name in ([]string{"onButtonPressed", "onValueChanged", "onFocusChanged", "onBackPressed"}) do testing.expect(t, hasEvent(NodeType_Events(Menu), name), name)
	testing.expect(t, hasEvent(NodeType_Events(RayCast), "onHitEnter") && hasEvent(NodeType_Events(AudioPlayer), "onFinished"))
	testing.expect(t, hasEvent(NodeType_Events(Camera2D), "onPanFinished") && hasEvent(NodeType_Events(LDtkLevelNode), "onReloaded"))
	for kind in SceneNodeKind {
		for e in SceneNodeKind_Events(kind) do testing.expectf(t, e.description != "", "%v.%s is described", kind, e.name)
	}
	free_all(context.temp_allocator)
}

@(test)
scene_file_listeners_are_bound_before_ready :: proc(t: ^testing.T) {
	registerListenScript()
	data, err := ParseScene(`<scene formatVersion="13" name="S">
		<node kind="Node2D" name="Hero"><script name="ListenScript"/></node>
		<node kind="ParticleEmitter" name="Blood">
			<listener event="onFinished" target="../Hero" handler="onHeard"/>
			<listener event="onEnter" target="../Hero" handler="onHeard"/>
			<listener event="onNothing" target="../Hero" handler="onHeard"/>
			<listener event="onFinished" target="../Hero" handler="noSuchHandler"/>
			<listener event="onFinished" target="../Nobody" handler="onHeard"/>
		</node>
	</scene>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, len(data.nodes[1].listeners), 5)
	testing.expect_value(t, data.nodes[1].listeners[0], NodeListenerData{"onFinished", "../Hero", "onHeard", ""})

	game := testGame("")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	created := Scene_Build(scene, &data, "")
	hero, blood := created[0], cast(^ParticleEmitter)created[1]
	self := Node_GetScript(hero, ListenScript)
	if !testing.expect(t, self != nil) do return
	Scene_ProcessQueues(scene) // onEnter: not bound yet
	testing.expect_value(t, self.heard, 0)
	Scene_ReadyScripts(scene)
	testing.expect(t, self.readied && blood.listenersBound, "bound, then ready")

	// The emitter finishing calls the hero's handler with the emitter as the source
	Event_Notify(&blood.onFinished, blood, 7)
	testing.expect_value(t, self.heard, 1)
	testing.expect(t, self.lastSource == blood && self.lastData == EventData(7), "source and data")
	// The bad ones were skipped (logged): one handler call per notification
	Event_Notify(&blood.onFinished, blood, nil)
	testing.expect_value(t, self.heard, 2)
	// The listener gone: nothing called, nothing crashes
	Scene_RemoveNode(scene, hero.id)
	Scene_ProcessQueues(scene)
	Event_Notify(&blood.onFinished, blood, nil)
	free_all(context.temp_allocator)
}

@(test)
cameras_and_menus_notify :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	camera := Scene_CreateCamera(scene)
	Scene_ProcessQueues(scene)
	panned, shaken := 0, 0
	bump :: proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) { (cast(^int)user)^ += 1 }
	Event_Subscribe(&camera.onPanFinished, bump, &panned)
	Event_Subscribe(&camera.onShakeFinished, bump, &shaken)
	Camera2D_MoveTo(camera, {100, 0}, 0.5)
	for _ in 0 ..< 40 do Camera2D_Update(camera, {640, 360}, 1.0 / 60)
	testing.expect_value(t, panned, 1)
	Camera2D_Shake(camera, 4, 0.2)
	for _ in 0 ..< 20 do Camera2D_UpdateShake(camera, 1.0 / 60)
	testing.expect_value(t, shaken, 1)

	menu := CreateMenu(scene, {0, 0})
	Menu_AddButton(menu, "Play", nil)
	Menu_AddCheckbox(menu, "Sound", true, nil)
	Scene_ProcessQueues(scene)
	pressed, changed, focused, back := 0, 0, 0, 0
	lastIndex := -1
	index :: proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) { (cast(^int)user)^ = data.(int) }
	Event_Subscribe(&menu.onButtonPressed, bump, &pressed)
	Event_Subscribe(&menu.onValueChanged, bump, &changed)
	Event_Subscribe(&menu.onValueChanged, index, &lastIndex)
	Event_Subscribe(&menu.onFocusChanged, bump, &focused)
	Event_Subscribe(&menu.onBackPressed, bump, &back)
	Menu_update(menu, nil, 1.0 / 60) // the first update only notes the focus
	Menu_Command(menu, .Accept)
	testing.expect_value(t, pressed, 1)
	Menu_Command(menu, .Down)
	Menu_update(menu, nil, 1.0 / 60)
	testing.expect_value(t, focused, 1)
	Menu_Command(menu, .Accept)
	testing.expect(t, changed == 1 && lastIndex == 1, "the checkbox, by index")
	testing.expect(t, Menu_Command(menu, .Cancel) && back == 1, "back, handled by its listener")
}

// A script publishing its own event, and a global publishing one
BellScript :: struct {
	using script: Script,
	onPing: EventSubject `event:"It was rung" data:"text := data.(string)"`,
}

ScoreGlobal :: struct {
	using script: Script,
	score: int,
	onScored: EventSubject `event:"The score changed" data:"score := data.(int)"`,
}

@(private="file")
scriptEventsOnce: sync.Once

@(private="file")
registerScriptEventTypes :: proc() {
	registerListenScript()
	sync.once_do(&scriptEventsOnce, proc() {
		Script_Register(BellScript, {})
		Script_Register(ScoreGlobal, {})
	})
}

@(test)
scripts_publish_events :: proc(t: ^testing.T) {
	registerScriptEventTypes()
	info := Script_Find("BellScript")
	if !testing.expect(t, info != nil && len(info.events) == 1) do return
	testing.expect_value(t, info.events[0].name, "script.onPing")
	testing.expect_value(t, info.events[0].description, "It was rung")
	testing.expect(t, strings.contains(Script_DescribeJSON(context.temp_allocator), `"events": [{"name": "script.onPing", "description": "It was rung", "data": "text := data.(string)"}]`), "described")

	data, _ := ParseScene(`<scene formatVersion="13" name="S">
		<node kind="Node2D" name="Hero"><script name="ListenScript"/></node>
		<node kind="Node2D" name="Bell">
			<script name="BellScript"/>
			<listener event="script.onPing" target="../Hero" handler="onHeard"/>
		</node>
	</scene>`)
	defer SceneData_Destroy(&data)
	game := testGame("")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	created := Scene_Build(scene, &data, "")
	Scene_ProcessQueues(scene)
	Scene_ReadyScripts(scene)
	hero, bell := Node_GetScript(created[0], ListenScript), Node_GetScript(created[1], BellScript)
	testing.expect(t, bell.onPing.notify != nil && bell.onPing.listeners.allocator.procedure != nil, "its event set up with the node's memory")
	testing.expect(t, Node_FindEvent(created[1], "script.onPing") == &bell.onPing, "found by name")
	Event_Notify(&bell.onPing, bell.node, "ding")
	testing.expect_value(t, hero.heard, 1)
	text, isText := hero.lastData.(string)
	testing.expect(t, isText && text == "ding" && hero.lastSource == created[1], "string data, the bell as the source")
	free_all(context.temp_allocator)
}

@(test)
nodes_listen_to_globals_while_their_scene_plays :: proc(t: ^testing.T) {
	registerScriptEventTypes()
	dir := tempFolder("engine_test_global_events")
	defer os.remove_all(dir)
	_ = os.write_entire_file(JoinPath(dir, "a.scene.xml"), transmute([]u8)string(`<scene formatVersion="13" name="A">
		<node kind="Node2D" name="Hero"><script name="ListenScript"/><listener global="ScoreGlobal" event="script.onScored" handler="onHeard"/></node>
	</scene>`))
	_ = os.write_entire_file(JoinPath(dir, "b.scene.xml"), transmute([]u8)string(`<scene formatVersion="13" name="B"/>`))
	project, _ := ParseProject(`<project formatVersion="13" name="G" startScene="A"><global script="ScoreGlobal"/><scene name="A" path="a.scene.xml"/><scene name="B" path="b.scene.xml"/></project>`)
	defer ProjectData_Destroy(&project)
	game := testGame(dir)
	defer { Game_Destroy(game); free(game) }
	testing.expect(t, Game_LoadProject(game, &project, dir), "loads")
	Game_Update(game, nil, 1.0 / 60)
	score := Global(ScoreGlobal, game)
	if !testing.expect(t, score != nil) do return
	hero := Node_GetScript(Scene_FindNode(game.scenes["A"], "Hero"), ListenScript)
	Event_Notify(&score.onScored, nil, 10)
	testing.expect(t, hero.heard == 1 && hero.lastData == EventData(10) && hero.lastSource == nil, "heard, no source node")

	// Another scene plays: A's nodes stay until it's entered again, but don't hear it
	game->switchScene("B")
	Game_Update(game, nil, 1.0 / 60)
	Event_Notify(&score.onScored, nil, 20)
	testing.expect_value(t, hero.heard, 1)
	// Back: A is built afresh; the old hero's subscription went with it, the new one listens
	for _ in 0 ..< 3 {
		game->switchScene("A")
		Game_Update(game, nil, 1.0 / 60)
		game->switchScene("B")
		Game_Update(game, nil, 1.0 / 60)
	}
	game->switchScene("A")
	Game_Update(game, nil, 1.0 / 60)
	testing.expect_value(t, len(score.onScored.listeners), 1) // not one per visit
	again := Node_GetScript(Scene_FindNode(game.scenes["A"], "Hero"), ListenScript)
	Event_Notify(&score.onScored, nil, 30)
	testing.expect(t, again.heard == 1 && again.lastData == EventData(30), "the new hero hears it")

	// Saves leave events out
	score.score = 7
	saved, _ := Save_ToJSON(game, context.temp_allocator)
	testing.expect(t, strings.contains(saved, `"score": 7`) && !strings.contains(saved, "onScored"), saved)
	free_all(context.temp_allocator)
}
