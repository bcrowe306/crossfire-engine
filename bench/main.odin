/*
Engine benchmarks: the per-frame costs that matter for performance work, timed so a change can
be measured before and after.

	odin run bench -o:speed                     # every scenario
	odin run bench -o:speed -- particles physics   # some (names below)
	odin run bench -o:speed -- ldtk <file.ldtk>    # the LDtk scenario on another level

Each scenario prints the median time of its repetitions. Drawing uses SDL's software renderer on
an offscreen surface, so where the engine's own cost is what's measured, nodes draw nothing
(empty draw procedures): drawOrder, transforms and dispatch, not SDL's pixel work.

Scenarios: churn (making and removing nodes), update (Scene_Update over many nodes), draw
(Scene_DrawWithView overhead), deep (world transforms down a deep tree), remove (removing many
nodes in one frame), lookup (Scene_GetNode, Scene_FindNode), events (subscribe and notify),
particles (emitters update and draw), physics (bodies stepping), ldtk (a level's tile layers
drawing), text (labels drawn each frame), sizes (struct sizes).
*/
package bench

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import e ".."
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Median milliseconds of `reps` runs of `body`
measure :: proc(reps: int, body: proc(data: rawptr), data: rawptr) -> f64 {
	// Not the temp allocator: draw scenarios free it every repetition
	times := make([]f64, reps)
	defer delete(times)
	for i in 0 ..< reps {
		start := time.tick_now()
		body(data)
		times[i] = time.duration_milliseconds(time.tick_since(start))
	}
	slice.sort(times)
	return times[reps / 2]
}

report :: proc(name: string, ms: f64, note := "") {
	fmt.printfln("%-44s %10.4f ms  %s", name, ms, note)
}

newScene :: proc(game: ^e.Game) -> ^e.Scene {
	scene := new(e.Scene)
	e.Scene_Init(scene)
	scene.game = game
	scene.physicsPaused = false
	return scene
}

freeScene :: proc(scene: ^e.Scene) {
	e.Scene_Destroy(scene)
	free(scene)
}

// Reads the draw transform the scene set (so the call isn't optimized away)
noDraw :: proc(node: ^e.Node, renderer: ^sdl.Renderer) { sink += e.GetDrawTransform().origin.x * 0 + 1 }
noUpdate :: proc(node: ^e.Node, events: []sdl.Event, deltaTime: f64) {}

// --- Scenarios ------------------------------------------------------------------------------

Churn :: struct { scene: ^e.Scene, count: int }

benchChurn :: proc(game: ^e.Game) {
	for count in ([]int{100, 1000}) {
		state := Churn{newScene(game), count}
		ms := measure(20, proc(data: rawptr) {
			s := cast(^Churn)data
			ids := make([]e.EntityId, s.count, context.temp_allocator)
			for i in 0 ..< s.count {
				n := e.CreateNode(s.scene, e.Node)
				ids[i] = n.id
			}
			e.Scene_ProcessQueues(s.scene)
			for id in ids do e.Scene_RemoveNode(s.scene, id)
			e.Scene_ProcessQueues(s.scene)
		}, &state)
		report(fmt.tprintf("churn: make + remove %d nodes", count), ms, fmt.tprintf("(%.2f µs per node)", ms * 1000 / f64(count)))
		freeScene(state.scene)
	}
}

Frame :: struct { scene: ^e.Scene, renderer: ^sdl.Renderer }

// A flat scene of `count` nodes (10% with children), each updating and drawing nothing
buildFlat :: proc(game: ^e.Game, count: int) -> ^e.Scene {
	scene := newScene(game)
	for i in 0 ..< count {
		n := e.CreateNode(scene, e.Node)
		n.position = {f32(i % 100), f32(i / 100)}
		n.update = noUpdate
		n.draw = noDraw
		if i % 10 == 0 {
			child := e.CreateNode(scene, e.Node)
			child.draw = noDraw
			e.Node_AddChild(n, child)
		}
	}
	e.Scene_ProcessQueues(scene)
	return scene
}

benchUpdateDraw :: proc(game: ^e.Game, renderer: ^sdl.Renderer) {
	for count in ([]int{1000, 5000, 20000}) {
		state := Frame{buildFlat(game, count), renderer}
		update := measure(30, proc(data: rawptr) {
			s := cast(^Frame)data
			e.Scene_Update(s.scene, nil, 1.0 / 60)
		}, &state)
		report(fmt.tprintf("update: %d nodes", count), update)
		draw := measure(30, proc(data: rawptr) {
			s := cast(^Frame)data
			e.Scene_DrawWithView(s.scene, s.renderer, e.TRANSFORM2D_IDENTITY)
			free_all(context.temp_allocator)
		}, &state)
		report(fmt.tprintf("draw (engine overhead): %d nodes", count), draw)
		freeScene(state.scene)
	}
}

Deep :: struct { leaf: ^e.Node }

benchDeep :: proc(game: ^e.Game) {
	scene := newScene(game)
	defer freeScene(scene)
	parent: ^e.Node
	for i in 0 ..< 64 {
		n := e.CreateNode(scene, e.Node)
		n.position = {1, 0}
		n.rotation = 1
		if parent != nil do e.Node_AddChild(parent, n)
		parent = n
	}
	state := Deep{parent}
	ms := measure(50, proc(data: rawptr) {
		s := cast(^Deep)data
		// Summed into a global, so the optimizer can't drop the calls
		for _ in 0 ..< 1000 do sink += e.Node_GetWorldTransform(s.leaf).origin.x
	}, &state)
	report("deep: 1000 world transforms at depth 64", ms)
}

Remove :: struct { game: ^e.Game }

benchRemove :: proc(game: ^e.Game) {
	state := Remove{game}
	ms := measure(10, proc(data: rawptr) {
		s := cast(^Remove)data
		scene := buildFlat(s.game, 5000)
		start := time.tick_now()
		for node, i in scene.nodes do if i % 10 == 0 do e.Scene_RemoveNode(scene, node.id)
		e.Scene_ProcessQueues(scene)
		elapsed = time.duration_milliseconds(time.tick_since(start))
		freeScene(scene)
	}, &state)
	_ = ms
	report("remove: 500 of 5500 nodes in one frame", elapsed)
}

@(private="file")
elapsed: f64

// Results summed here so the optimizer keeps the measured work; printed at the end
sink: f32

Lookup :: struct { scene: ^e.Scene, ids: []e.EntityId }

benchLookup :: proc(game: ^e.Game) {
	scene := buildFlat(game, 5000)
	defer freeScene(scene)
	for node, i in scene.nodes do node.name = fmt.aprintf("node%d", i, allocator = e.Node_GetAllocator(node))
	ids := make([]e.EntityId, 100)
	defer delete(ids)
	for i in 0 ..< 100 do ids[i] = scene.nodes[i * 50].id
	state := Lookup{scene, ids}
	byId := measure(20, proc(data: rawptr) {
		s := cast(^Lookup)data
		for id in s.ids do if e.Scene_GetNode(s.scene, id) != nil do sink += 1
	}, &state)
	report("lookup: 100 Scene_GetNode in 5500 nodes", byId)
	byName := measure(20, proc(data: rawptr) {
		s := cast(^Lookup)data
		for _ in 0 ..< 100 do if e.Scene_FindNode(s.scene, "node4999") != nil do sink += 1
	}, &state)
	report("lookup: 100 Scene_FindNode (last) in 5500 nodes", byName)
}

Events :: struct { subject: e.EventSubject, sum: int }

benchEvents :: proc() {
	state: Events
	e.EventSubject_Init(&state.subject)
	defer e.Event_Destroy(&state.subject)
	sub := measure(20, proc(data: rawptr) {
		s := cast(^Events)data
		clear(&s.subject.listeners)
		for _ in 0 ..< 1000 do s.subject->subscribe(proc(_: ^e.EventSubject, _: rawptr, _: e.EventData, user: rawptr) { (cast(^Events)user).sum += 1 }, s)
	}, &state)
	report("events: 1000 subscribes", sub)
	notify := measure(20, proc(data: rawptr) {
		s := cast(^Events)data
		for _ in 0 ..< 100 do s.subject->notify(nil, nil)
	}, &state)
	report("events: 100 notifies of 1000 listeners", notify)
}

benchParticles :: proc(game: ^e.Game, renderer: ^sdl.Renderer) {
	for amount in ([]int{50, 500, 1000}) {
		for collide in ([]bool{false, true}) {
			if collide && amount > 500 do continue
			scene := newScene(game)
			settings := e.DEFAULT_PARTICLE_SETTINGS
			settings.amount = amount
			settings.lifetime = 2
			settings.collisionEnabled = collide
			settings.shape = .Rectangle
			for i in 0 ..< 4 {
				emitter := e.CreateParticleEmitter(scene, settings)
				emitter.position = {f32(100 + i * 200), 300}
			}
			e.Scene_ProcessQueues(scene)
			// Fill them up
			for _ in 0 ..< 120 do e.Scene_Update(scene, nil, 1.0 / 60)
			state := Frame{scene, renderer}
			update := measure(30, proc(data: rawptr) {
				s := cast(^Frame)data
				e.Scene_Update(s.scene, nil, 1.0 / 60)
			}, &state)
			report(fmt.tprintf("particles: 4 emitters x %d%s, update", amount, collide ? " colliding" : ""), update)
			if !collide {
				draw := measure(30, proc(data: rawptr) {
					s := cast(^Frame)data
					e.Scene_DrawWithView(s.scene, s.renderer, e.TRANSFORM2D_IDENTITY)
					sdl.FlushRenderer(s.renderer)
					free_all(context.temp_allocator)
				}, &state)
				report(fmt.tprintf("particles: 4 emitters x %d, draw (with SDL)", amount), draw)
			}
			freeScene(scene)
		}
	}
}

benchPhysics :: proc(game: ^e.Game) {
	scene := newScene(game)
	defer freeScene(scene)
	for i in 0 ..< 500 {
		body := e.CreateStaticBody(scene)
		body.position = {f32(i % 50) * 40, 1000 + f32(i / 50) * 40}
		shape := e.CreateCollisionShape(scene, .Rectangle)
		shape.size = {30, 30}
		e.Node_AddChild(body, shape)
	}
	for i in 0 ..< 500 {
		body := e.CreateDynamicBody(scene)
		body.position = {f32(i % 50) * 40, f32(i / 50) * 40}
		shape := e.CreateCollisionShape(scene, .Circle)
		shape.radius = 10
		e.Node_AddChild(body, shape)
	}
	e.Scene_ProcessQueues(scene)
	for _ in 0 ..< 10 do e.Scene_Update(scene, nil, 1.0 / 60)
	state := Frame{scene, nil}
	ms := measure(60, proc(data: rawptr) {
		s := cast(^Frame)data
		e.Scene_Update(s.scene, nil, 1.0 / 60)
	}, &state)
	report("physics: 500 static + 500 dynamic, a frame", ms)
}

LDtkFrame :: struct { scene: ^e.Scene, renderer: ^sdl.Renderer, view: e.Transform2D }

benchLDtk :: proc(game: ^e.Game, renderer: ^sdl.Renderer, file: string) {
	if !os.exists(file) {
		report("ldtk: (no level file)", 0, file)
		return
	}
	scene := newScene(game)
	defer freeScene(scene)
	text := fmt.tprintf(`<scene formatVersion="12" name="B"><node kind="LDtkLevel" name="Level" ldtk="%s" spawnEntities="false"/></scene>`, file)
	data, err := e.ParseScene(text)
	defer e.SceneData_Destroy(&data)
	if err != .None {
		report("ldtk: (couldn't parse)", 0)
		return
	}
	e.Scene_Build(scene, &data, "", attachScripts = false)
	e.Scene_ProcessQueues(scene)
	for zoom in ([]f32{3, 0.4}) {
		state := LDtkFrame{scene, renderer, {x = {zoom, 0}, y = {0, zoom}, origin = {}}}
		ms := measure(20, proc(data: rawptr) {
			s := cast(^LDtkFrame)data
			e.Scene_DrawWithView(s.scene, s.renderer, s.view)
			sdl.FlushRenderer(s.renderer)
			free_all(context.temp_allocator)
		}, &state)
		report(fmt.tprintf("ldtk: draw at zoom %.1f (with SDL, software)", zoom), ms, zoom < 1 ? "(the whole level)" : "(a screenful)")
	}
}

Text :: struct { rm: ^e.ResourceManager, renderer: ^sdl.Renderer }

benchText :: proc(game: ^e.Game, renderer: ^sdl.Renderer) {
	state := Text{&game.resourceManager, renderer}
	ms := measure(30, proc(data: rawptr) {
		s := cast(^Text)data
		for i in 0 ..< 30 {
			e.DrawTextCentered(s.rm, {640, f32(20 + i * 22)}, fmt.tprintf("Label %d: score 12345", i % 10), e.DEFAULT_FONT, 18, {255, 255, 255, 255})
		}
		sdl.FlushRenderer(s.renderer)
		free_all(context.temp_allocator)
	}, &state)
	report("text: 30 centered labels (with SDL, software)", ms)
}

benchSizes :: proc() {
	report("size_of(Node)", f64(size_of(e.Node)), "bytes (shown in the ms column)")
	report("size_of(PhysicsBody)", f64(size_of(e.PhysicsBody)), "bytes")
	report("size_of(ParticleEmitter)", f64(size_of(e.ParticleEmitter)), "bytes")
	report("size_of(Particle)", f64(size_of(e.Particle)), "bytes")
	report("size_of(EventSubject)", f64(size_of(e.EventSubject)), "bytes")
	report("size_of(Camera2D)", f64(size_of(e.Camera2D)), "bytes")
	report("size_of(AnimatedSprite)", f64(size_of(e.AnimatedSprite)), "bytes")
}

main :: proc() {
	context.logger = log.create_console_logger(.Warning)
	args := os.args[1:]
	want :: proc(args: []string, name: string) -> bool {
		if len(args) == 0 do return true
		for a in args do if a == name do return true
		return false
	}
	ldtkFile := "../odin_sdl_editor/examples/demo_project/assets/levels/legacy.ldtk"
	for a, i in args do if strings.has_suffix(a, ".ldtk") do ldtkFile = args[i]

	surface := sdl.CreateSurface(1280, 720, .RGBA32)
	renderer := sdl.CreateSoftwareRenderer(surface)
	game := new(e.Game)
	game.physics = e.DEFAULT_PHYSICS
	game.size = {1280, 720}
	game.renderer = renderer
	game.scenes = make(map[string]^e.Scene)
	ttf.Init()
	e.ResourceManager_Init(&game.resourceManager, renderer, nil)

	fmt.println("Crossfire Engine benchmarks (median of the repetitions)")
	if want(args, "sizes") do benchSizes()
	if want(args, "churn") do benchChurn(game)
	if want(args, "update") || want(args, "draw") do benchUpdateDraw(game, renderer)
	if want(args, "deep") do benchDeep(game)
	if want(args, "remove") do benchRemove(game)
	if want(args, "lookup") do benchLookup(game)
	if want(args, "events") do benchEvents()
	if want(args, "particles") do benchParticles(game, renderer)
	if want(args, "physics") do benchPhysics(game)
	if want(args, "ldtk") do benchLDtk(game, renderer, ldtkFile)
	if want(args, "text") do benchText(game, renderer)
	fmt.printfln("(checksum %v)", sink)
}
