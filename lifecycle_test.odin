#+build !js
package engine

import "core:log"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

// Node, Scene and Game lifecycles: making, adding, removing, finding, reparenting and destroying,
// with their edge cases. Node arenas are virtual memory the test allocator doesn't track, so these
// count `destroy` hooks to prove each node is freed exactly once.

@(private="file")
Probe :: struct {
	using node: Node,
	log: ^[dynamic]string,
}

// A node whose enter, exit and destroy are written to `log` as "enter A", "exit A", "destroy A"
@(private="file")
probe :: proc(scene: ^Scene, name: string, log: ^[dynamic]string, add := true) -> ^Probe {
	p := CreateNode(scene, Probe, add)
	p.name = name
	p.log = log
	p.onEnter->subscribe(proc(_: ^EventSubject, source: rawptr, _: EventData, _: rawptr) {
		n := cast(^Probe)source
		append(n.log, concat("enter ", n.name))
	}, nil)
	p.onExit->subscribe(proc(_: ^EventSubject, source: rawptr, _: EventData, _: rawptr) {
		n := cast(^Probe)source
		append(n.log, concat("exit ", n.name))
	}, nil)
	p.destroy = proc(node: ^Node) {
		n := cast(^Probe)node
		// The parent must still be alive while its children go
		parent := n.parent != nil ? concat(" under ", n.parent.name) : ""
		append(n.log, concat(concat("destroy ", n.name), parent))
	}
	return p
}

@(private="file")
concat :: proc(a, b: string) -> string {
	bytes := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(bytes, a)
	copy(bytes[len(a):], b)
	return string(bytes)
}

@(private="file")
newScene :: proc() -> ^Scene {
	scene := new(Scene)
	Scene_Init(scene)
	return scene
}

@(private="file")
freeScene :: proc(scene: ^Scene) {
	Scene_Destroy(scene)
	free(scene)
}

@(private="file")
expectLog :: proc(t: ^testing.T, log: ^[dynamic]string, want: []string, loc := #caller_location) {
	ok := len(log) == len(want)
	if ok do for line, i in want do if log[i] != line do ok = false
	testing.expectf(t, ok, "log %v, want %v", log[:], want, loc = loc)
	clear(log)
}

@(test)
nodes_are_made_added_and_found :: proc(t: ^testing.T) {
	log := make([dynamic]string)
	defer delete(log)
	scene := newScene()
	defer freeScene(scene)

	a := probe(scene, "A", &log)
	b := probe(scene, "B", &log)
	testing.expect(t, a.id != b.id, "ids are unique")
	testing.expect(t, a.scene == scene && Node_Is(a, Probe) && !a.inScene, "made for the scene, not in it yet")
	testing.expect_value(t, a.scale, [2]f32{1, 1})
	testing.expect(t, a.visible && a.tint == {255, 255, 255, 255}, "visible, white")
	testing.expect(t, Scene_GetNode(scene, a.id) == a, "found while queued")
	testing.expect(t, Scene_FindNode(scene, "B") == b, "found by name while queued")

	Scene_ProcessQueues(scene)
	expectLog(t, &log, {"enter A", "enter B"})
	testing.expect(t, a.inScene && len(scene.nodes) == 2, "in the scene, in order")

	// Adding twice does nothing
	Scene_AddNode(scene, a)
	Scene_ProcessQueues(scene)
	testing.expect_value(t, len(scene.nodes), 2)

	// Made without adding: owned by the scene, found, added later
	c := probe(scene, "C", &log, add = false)
	testing.expect(t, Scene_GetNode(scene, c.id) == c && !c.inScene, "found, not in the scene")
	Scene_ProcessQueues(scene)
	testing.expect(t, !c.inScene, "still not added")
	Scene_AddNode(scene, c)
	Scene_ProcessQueues(scene)
	expectLog(t, &log, {"enter C"})
	testing.expect(t, c.inScene && len(scene.detached) == 0, "added")

	// A node made inside an onEnter handler joins in the same pass
	d := probe(scene, "D", &log)
	d.onEnter->subscribe(proc(_: ^EventSubject, source: rawptr, _: EventData, _: rawptr) {
		n := cast(^Probe)source
		probe(n.scene, "E", n.log)
	}, nil)
	Scene_ProcessQueues(scene)
	expectLog(t, &log, {"enter D", "enter E"})
	testing.expect(t, Scene_FindNode(scene, "E") != nil && Scene_FindNode(scene, "E").inScene, "E joined")
	testing.expect_value(t, len(scene.addQueue), 0)
	free_all(context.temp_allocator)
}

@(test)
removing_nodes_exits_and_frees_them_once :: proc(t: ^testing.T) {
	log := make([dynamic]string)
	defer delete(log)
	scene := newScene()
	defer freeScene(scene)

	parent := probe(scene, "P", &log)
	child := probe(scene, "C", &log)
	grandchild := probe(scene, "G", &log)
	Node_AddChild(parent, child)
	Node_AddChild(child, grandchild)
	other := probe(scene, "O", &log)
	Scene_ProcessQueues(scene)
	clear(&log)

	// A parent and its child removed in the same frame, one twice, and an unknown id
	parentId := parent.id
	Scene_RemoveNode(scene, child.id)
	Scene_RemoveNode(scene, parent.id)
	Scene_RemoveNode(scene, parent.id)
	Scene_RemoveNode(scene, EntityId{})
	Scene_ProcessQueues(scene)
	// Exits parents first; destroys children first, each while its parent is alive
	expectLog(t, &log, {"exit C", "exit G", "destroy G under C", "destroy C", "exit P", "destroy P"})
	testing.expect(t, Scene_GetNode(scene, parentId) == nil, "gone")
	testing.expect_value(t, len(scene.nodes), 1)
	testing.expect(t, scene.nodes[0] == other, "the other node stays")

	// Removed while still queued: never enters, freed
	queued := probe(scene, "Q", &log)
	Scene_RemoveNode(scene, queued.id)
	Scene_ProcessQueues(scene)
	expectLog(t, &log, {"destroy Q"})
	testing.expect_value(t, len(scene.addQueue), 0)

	// Made without adding, then removed
	detached := probe(scene, "D", &log, add = false)
	Scene_RemoveNode(scene, detached.id)
	Scene_ProcessQueues(scene)
	expectLog(t, &log, {"destroy D"})
	testing.expect_value(t, len(scene.detached), 0)

	// A removal queued by an exit handler runs in the same pass
	first := probe(scene, "F", &log)
	second := probe(scene, "S", &log)
	Scene_ProcessQueues(scene)
	clear(&log)
	first.onExit->subscribe(proc(_: ^EventSubject, source: rawptr, _: EventData, user: rawptr) {
		n := cast(^Probe)source
		Scene_RemoveNode(n.scene, (cast(^Node)user).id)
	}, second)
	Scene_RemoveNode(scene, first.id)
	Scene_ProcessQueues(scene)
	expectLog(t, &log, {"exit F", "destroy F", "exit S", "destroy S"})
	free_all(context.temp_allocator)
}

@(test)
destroying_a_scene_exits_and_frees_every_node :: proc(t: ^testing.T) {
	log := make([dynamic]string)
	defer delete(log)
	scene := newScene()

	root := probe(scene, "R", &log)
	kid := probe(scene, "K", &log)
	Node_AddChild(root, kid)
	Scene_ProcessQueues(scene)
	// One waiting to be added, one never added, one under a node never added
	probe(scene, "Q", &log)
	loose := probe(scene, "L", &log, add = false)
	under := probe(scene, "U", &log)
	Node_AddChild(loose, under)
	clear(&log)

	freeScene(scene)
	// onExit only for nodes in the scene (parents first); then each node once, children first
	testing.expect_value(t, len(log), 7)
	if len(log) == 7 {
		testing.expect_value(t, log[0], "exit R")
		testing.expect_value(t, log[1], "exit K")
		destroyed := map[string]bool{}
		defer delete(destroyed)
		for line in log[2:] do destroyed[line] = true
		for want in ([]string{"destroy K under R", "destroy R", "destroy Q", "destroy U under L", "destroy L"}) {
			testing.expectf(t, want in destroyed, "%s in %v", want, log[:])
		}
		// Children before parents
		indexOf :: proc(log: []string, line: string) -> int {
			for l, i in log do if l == line do return i
			return -1
		}
		testing.expect(t, indexOf(log[:], "destroy K under R") < indexOf(log[:], "destroy R"), "K before R")
		testing.expect(t, indexOf(log[:], "destroy U under L") < indexOf(log[:], "destroy L"), "U before L")
	}
	free_all(context.temp_allocator)
}

@(test)
removing_the_camera_clears_the_scene_camera :: proc(t: ^testing.T) {
	scene := newScene()
	defer freeScene(scene)
	holder := CreateNode(scene, Node)
	camera := Scene_CreateCamera(scene, holder)
	Scene_ProcessQueues(scene)
	testing.expect(t, scene.camera == camera, "the scene's camera")
	// Removing its parent takes the camera with it
	Scene_RemoveNode(scene, holder.id)
	Scene_Update(scene, nil, 1.0 / 60)
	testing.expect(t, scene.camera == nil, "no dangling camera")
	free_all(context.temp_allocator)
}

@(test)
nodes_of_different_scenes_cannot_be_related :: proc(t: ^testing.T) {
	a := newScene()
	defer freeScene(a)
	b := newScene()
	defer freeScene(b)
	parent := CreateNode(a, Node)
	child := CreateNode(b, Node)
	// The refusals are logged as errors, which fail a test: not this one
	context.logger = log.nil_logger()
	testing.expect(t, !Node_SetParent(child, parent), "refused")
	testing.expect(t, child.parent == nil && len(parent.children) == 0, "unchanged")
	// Adding a node to a scene it doesn't belong to is refused too
	stray := CreateNode(b, Node, false)
	Scene_AddNode(a, stray)
	testing.expect_value(t, len(a.addQueue), 1)
	free_all(context.temp_allocator)
}

@(test)
clearing_a_scene_keeps_what_the_game_set :: proc(t: ^testing.T) {
	scene := newScene()
	defer freeScene(scene)
	scene.name = "Kept"
	scene.screenLayers = {.Layer8}
	scene.update = proc(scene: ^Scene, events: []sdl.Event, deltaTime: f64) {}
	custom := scene.update
	CreateNode(scene, Node)
	Scene_ProcessQueues(scene)
	Scene_Clear(scene)
	testing.expect_value(t, len(scene.nodes), 0)
	testing.expect(t, scene.name == "Kept" && scene.screenLayers == {.Layer8}, "kept its settings")
	testing.expect(t, scene.update == custom, "kept a replaced update")
	free_all(context.temp_allocator)
}

@(test)
listeners_can_change_while_notified :: proc(t: ^testing.T) {
	State :: struct {
		subject: EventSubject,
		calls: [dynamic]string,
		handles: [3]ListenerHandle,
		addedD: bool,
	}
	state: State
	EventSubject_Init(&state.subject)
	defer Event_Destroy(&state.subject)
	defer delete(state.calls)
	// A removes B, C adds D; B isn't called, D only from the next notification
	state.handles[0] = state.subject->subscribe(proc(s: ^EventSubject, _: rawptr, _: EventData, user: rawptr) {
		st := cast(^State)user
		append(&st.calls, "A")
		Event_Unsubscribe(s, st.handles[1])
	}, &state)
	state.handles[1] = state.subject->subscribe(proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) {
		append(&(cast(^State)user).calls, "B")
	}, &state)
	state.handles[2] = state.subject->subscribe(proc(s: ^EventSubject, _: rawptr, _: EventData, user: rawptr) {
		st := cast(^State)user
		append(&st.calls, "C")
		if !st.addedD {
			st.addedD = true
			s->subscribe(proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) {
				append(&(cast(^State)user).calls, "D")
			}, st)
		}
	}, &state)
	state.subject->notify(nil, nil)
	testing.expect_value(t, len(state.calls), 2)
	testing.expect(t, len(state.calls) == 2 && state.calls[0] == "A" && state.calls[1] == "C", "A, C")
	testing.expect_value(t, len(state.subject.listeners), 3) // A, C, D: B compacted away
	clear(&state.calls)
	state.subject->notify(nil, nil)
	testing.expect(t, len(state.calls) == 3 && state.calls[2] == "D", "D in order, after A and C")
	// Unsubscribing outside a notification keeps the order
	Event_Unsubscribe(&state.subject, state.handles[0])
	clear(&state.calls)
	state.subject->notify(nil, nil)
	testing.expect(t, len(state.calls) == 2 && state.calls[0] == "C" && state.calls[1] == "D", "C, D")
}

@(test)
timers_count_down_and_loop :: proc(t: ^testing.T) {
	Counts :: struct { ticks, expiries: int }
	counts: Counts
	timer: Timer
	TimerNode_Init(&timer, 500 * time.Millisecond)
	defer { Event_Destroy(&timer.onTick); Event_Destroy(&timer.onExpire) }
	testing.expect_value(t, timer.duration, 500 * time.Millisecond) // not cut to whole seconds
	timer.onTick->subscribe(proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) { (cast(^Counts)user).ticks += 1 }, &counts)
	timer.onExpire->subscribe(proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) { (cast(^Counts)user).expiries += 1 }, &counts)

	// Not running: nothing happens, even past its duration
	for _ in 0 ..< 10 do timer->update(0.1)
	testing.expect(t, counts == {}, "a stopped timer is quiet")

	timer->start()
	for _ in 0 ..< 4 do timer->update(0.1)
	testing.expect(t, counts.ticks == 4 && counts.expiries == 0, "ticking")
	timer->update(0.15)
	testing.expect_value(t, counts.expiries, 1)
	testing.expect(t, !timer.running, "a one-shot stops")

	// A loop keeps its overshoot
	timer.loop = true
	timer->setDuration(0.25)
	timer->start()
	timer->update(0.3)
	testing.expect_value(t, counts.expiries, 2)
	testing.expect(t, timer.running && abs(time.duration_seconds(timer.elapsed) - 0.05) < 0.001, "overshoot kept")
	timer->update(0.2)
	testing.expect_value(t, counts.expiries, 3)

	// Zero length: fires once per update while running, never while stopped
	TimerNode_Stop(&timer)
	timer->setDuration(0)
	timer->update(0.1)
	testing.expect_value(t, counts.expiries, 3)
}

@(test)
tickers_survive_zero_rate :: proc(t: ^testing.T) {
	ticker: Ticker
	Ticker_Init(&ticker, auto_start = true)
	defer Event_Destroy(&ticker.onTick)
	ticker->setFPS(0)
	testing.expect_value(t, ticker.secondsPerFrame, time.Duration(0))
	ticker.elapsedTime = time.Second
	ticker->process()
	testing.expect_value(t, ticker.currentTick, 0)
	// A rate keeps the remainder instead of dropping it
	ticker->setFPS(10)
	ticker.lastTick = time.tick_now()
	ticker.elapsedTime = 130 * time.Millisecond
	ticker->process()
	testing.expect_value(t, ticker.currentTick, 1)
	testing.expect(t, ticker.elapsedTime >= 30 * time.Millisecond && ticker.elapsedTime < 100 * time.Millisecond, "remainder kept")
}

@(test)
games_switch_scenes_and_tear_down :: proc(t: ^testing.T) {
	log := make([dynamic]string)
	defer delete(log)
	dir := tempFolder("engine_test_game_lifecycle")
	game := testGame(dir)
	defer free(game)

	a := Game_CreateScene(game, "A")
	testing.expect(t, a != nil && a.game == game && a.name == "A", "made")
	testing.expect(t, Game_CreateScene(game, "A") == nil, "a name only once")
	testing.expect(t, !Game_SwitchScene(game, "Missing"), "no such scene")
	probe(a, "N", &log)
	_ = Game_SwitchScene(game, "A")
	Game_Update(game, nil, 1.0 / 60)
	testing.expect(t, game.currentScene == a, "switched")
	expectLog(t, &log, {"enter N"})

	// Destroying the game: the playing scene's nodes exit, then everything is freed, pointers cleared
	Game_Destroy(game)
	expectLog(t, &log, {"exit N", "destroy N"})
	testing.expect(t, game.currentScene == nil && game.nextScenePtr == nil && game.scenes == nil, "no dangling pointers")
	free_all(context.temp_allocator)
}
