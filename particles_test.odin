#+build !js
package crossfire

import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// Particle tests: emitters in scenes without a window; drawing into a software-rendered surface

@(private="file")
testScene :: proc() -> ^Scene {
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
run :: proc(scene: ^Scene, seconds: f64) {
	for _ in 0 ..< int(seconds * 60 + 0.5) do Scene_Update(scene, nil, 1.0 / 60.0)
}

@(test)
color_ramp_evaluates_sorts_adds_and_removes :: proc(t: ^testing.T) {
	ramp := DEFAULT_COLOR_RAMP
	testing.expect_value(t, ColorRamp_Evaluate(ramp, 0), sdl.Color{255, 230, 100, 255})
	testing.expect_value(t, ColorRamp_Evaluate(ramp, 0.5), sdl.Color{230, 50, 40, 255})
	testing.expect_value(t, ColorRamp_Evaluate(ramp, 2), sdl.Color{40, 40, 40, 0}) // Clamped
	// Halfway between the last two stops
	testing.expect_value(t, ColorRamp_Evaluate(ramp, 0.75), sdl.Color{135, 45, 40, 128})

	index := ColorRamp_AddStop(&ramp, 0.25, {0, 0, 255, 255})
	testing.expect_value(t, index, 1)
	testing.expect_value(t, ramp.count, 4)
	testing.expect_value(t, ramp.stops[2].position, f32(0.5))

	// Moving a stop past another keeps track of it
	selected := 1
	ramp.stops[1].position = 0.9
	ColorRamp_Sort(&ramp, &selected)
	testing.expect_value(t, selected, 2)
	testing.expect_value(t, ramp.stops[2].color, sdl.Color{0, 0, 255, 255})

	testing.expect(t, ColorRamp_RemoveStop(&ramp, 2), "removed")
	testing.expect(t, ColorRamp_RemoveStop(&ramp, 0), "removed")
	testing.expect(t, !ColorRamp_RemoveStop(&ramp, 0), "keeps two")
	for _ in 0 ..< 10 do ColorRamp_AddStop(&ramp, 0.3, {})
	testing.expect_value(t, ramp.count, MAX_COLOR_STOPS)

	parsed, ok := ParseColorRamp(FormatColorRamp(DEFAULT_COLOR_RAMP, context.temp_allocator))
	testing.expect(t, ok, "parses")
	testing.expect_value(t, parsed, DEFAULT_COLOR_RAMP)
	unsorted, _ := ParseColorRamp("1:#000000 0:#ffffff")
	testing.expect_value(t, unsorted.stops[0].color, sdl.Color{255, 255, 255, 255})
	_, bad := ParseColorRamp("0:#fff 1:red")
	testing.expect(t, !bad, "bad pairs are reported")
}

@(test)
particle_settings_text_round_trip :: proc(t: ^testing.T) {
	testing.expect_value(t, len(FormatParticleSettings(DEFAULT_PARTICLE_SETTINGS)), 0)

	settings := DEFAULT_PARTICLE_SETTINGS
	settings.amount = 80
	settings.size = {3, 7.5}
	settings.shape = .Line
	settings.continuous = false
	settings.particleColor = {10, 20, 30, 40}
	ColorRamp_AddStop(&settings.colorRamp, 0.2, {1, 2, 3, 4})
	pairs := FormatParticleSettings(settings)
	testing.expect_value(t, len(pairs), 6)

	loaded := DEFAULT_PARTICLE_SETTINGS
	for pair in pairs do testing.expectf(t, ParticleSettings_Set(&loaded, pair.name, pair.value), "%s=%s", pair.name, pair.value)
	testing.expect_value(t, loaded, settings)

	testing.expect(t, !ParticleSettings_Set(&loaded, "nope", "1"), "unknown name")
	testing.expect(t, !ParticleSettings_Set(&loaded, "amount", "lots"), "bad value")
	testing.expect(t, !ParticleSettings_Set(&loaded, "shape", "Star"), "bad enum")
	testing.expect_value(t, loaded.amount, 80) // Unchanged

	// Every field has a label; ranged ones a range
	fields := ParticleSettings_Fields()
	testing.expect(t, len(fields) > 30, "fields")
	for f in fields {
		testing.expectf(t, f.label != f.name, "%s has a label", f.name)
		if f.ranged do testing.expectf(t, f.max > f.min, "%s range", f.name)
	}
	testing.expect_value(t, fields[0].group, "Emission")
}

@(test)
emitter_emits_cycles_and_stops :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	settings := DEFAULT_PARTICLE_SETTINGS
	settings.amount = 20
	settings.lifetime = 1
	settings.burst = 1
	emitter := CreateParticleEmitter(scene, settings)
	Scene_ProcessQueues(scene)

	// A full burst: all at once on the first update
	Scene_Update(scene, nil, 1.0 / 60.0)
	testing.expect_value(t, ParticleEmitter_AliveCount(emitter), 20)
	// Continuous: the next cycle's burst comes as the first one dies
	run(scene, 1)
	testing.expect_value(t, ParticleEmitter_AliveCount(emitter), 20)

	// Spread over the cycle: about half emitted halfway through
	ParticleEmitter_Clear(emitter)
	emitter.settings.burst = 0
	ParticleEmitter_Start(emitter)
	run(scene, 0.5)
	alive := ParticleEmitter_AliveCount(emitter)
	testing.expectf(t, alive >= 9 && alive <= 11, "halfway: %d", alive)

	// One cycle only: stops, and its particles die
	emitter.settings.continuous = false
	ParticleEmitter_Start(emitter)
	run(scene, 1.1)
	testing.expect(t, !emitter.emitting, "stopped after a cycle")
	run(scene, 1.1)
	testing.expect_value(t, ParticleEmitter_AliveCount(emitter), 0)

	// Not emitting from the start
	settings.emitting = false
	idle := CreateParticleEmitter(scene, settings)
	run(scene, 0.5)
	testing.expect_value(t, ParticleEmitter_AliveCount(idle), 0)
}

@(test)
particles_move_in_the_world_or_with_the_emitter :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	settings := DEFAULT_PARTICLE_SETTINGS
	settings.amount = 1
	settings.burst = 1
	settings.gravityVelocity = 0
	settings.velocity = 60
	settings.angle = 0
	emitter := CreateParticleEmitter(scene, settings)
	emitter.position = {100, 50}
	emitter.rotation = 90 // Emits along world +Y
	Scene_ProcessQueues(scene)
	Scene_Update(scene, nil, 0)
	run(scene, 0.5)
	p := emitter.particles[0]
	testing.expectf(t, abs(p.position.x - 100) < 0.5 && abs(p.position.y - 80) < 1, "world: %v", p.position)

	// Gravity and wind push it; scale and color change over its life
	ParticleEmitter_Clear(emitter)
	emitter.settings.velocity = 0
	emitter.settings.wind = {120, 0}
	emitter.settings.scaleEnd = {0, 0}
	emitter.settings.useColorRamp = false
	emitter.settings.particleColor = {255, 0, 0, 255}
	emitter.settings.colorEnd = {0, 0, 255, 255}
	ParticleEmitter_Start(emitter)
	run(scene, 1)
	p = emitter.particles[1]
	testing.expectf(t, p.position.x > 150, "wind: %v", p.position)
	testing.expectf(t, abs(p.scale.x - 0.5) < 0.05, "scale halfway: %v", p.scale)
	testing.expectf(t, p.color.r > 100 && p.color.b > 100, "color halfway: %v", p.color)

	// Local space: relative to the emitter, unrotated
	local := CreateParticleEmitter(scene, settings)
	local.settings.localSpace = true
	local.position = {500, 500}
	local.rotation = 90
	Scene_ProcessQueues(scene)
	run(scene, 0.5)
	q := local.particles[0]
	testing.expectf(t, abs(q.position.x - 29.5) < 1.5 && abs(q.position.y) < 0.5, "local: %v", q.position)
}

@(test)
particles_collide_with_the_view_edges :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	game: Game
	game.size = {200, 200}
	scene.game = &game
	settings := DEFAULT_PARTICLE_SETTINGS
	settings.amount = 1
	settings.burst = 1
	settings.lifetime = 5
	settings.velocity = 0
	settings.gravityVelocity = 2000
	settings.collisionEnabled = true
	emitter := CreateParticleEmitter(scene, settings)
	emitter.position = {100, 100}
	Scene_ProcessQueues(scene)
	run(scene, 1)
	p := emitter.particles[0]
	testing.expectf(t, p.alive && p.position.y <= 200, "stays in the view: %v", p.position)
}

@(test)
particles_from_a_scene_file :: proc(t: ^testing.T) {
	text := `<scene formatVersion="6" name="S">
		<node kind="ParticleEmitter" name="Sparks" x="10" y="20" texture="assets/spark.png">
			<particles amount="80" shape="Texture" size="3,4" useColorRamp="false" colorRamp="0:#ff0000 1:#0000ff" bogus="1" angle="x"/>
		</node>
		<node kind="ParticleEmitter" name="Plain"/>
	</scene>`
	data, err := ParseScene(text)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	s := data.nodes[0].particles
	testing.expect_value(t, s.amount, 80)
	testing.expect_value(t, s.shape, ParticleShape.Texture)
	testing.expect_value(t, s.size, [2]f32{3, 4})
	testing.expect_value(t, s.useColorRamp, false)
	testing.expect_value(t, s.colorRamp.count, 2)
	testing.expect_value(t, s.angle, DEFAULT_PARTICLE_SETTINGS.angle) // Bad value: the default
	testing.expect_value(t, data.nodes[0].texture, "assets/spark.png")
	testing.expect_value(t, data.nodes[1].particles, DEFAULT_PARTICLE_SETTINGS)

	// Without a resource manager to load it from
	delete(data.nodes[0].texture)
	data.nodes[0].texture = strings.clone("")
	scene := testScene()
	defer freeScene(scene)
	game: Game
	scene.game = &game
	created := Scene_Build(scene, &data, ".")
	emitter := cast(^ParticleEmitter)created[0]
	testing.expect(t, Node_Is(emitter, ParticleEmitter), "an emitter")
	testing.expect_value(t, emitter.settings.amount, 80)
}

@(test)
particles_draw_batched_shapes :: proc(t: ^testing.T) {
	scene := testScene()
	defer freeScene(scene)
	settings := DEFAULT_PARTICLE_SETTINGS
	settings.amount = 1
	settings.burst = 1
	settings.velocity = 0
	settings.gravityVelocity = 0
	settings.size = {10, 10}
	settings.useColorRamp = false
	settings.particleColor = {0, 255, 0, 255}
	settings.colorEnd = {0, 255, 0, 255}
	emitter := CreateParticleEmitter(scene, settings)
	emitter.position = {30, 30}
	other := CreateParticleEmitter(scene, settings)
	other.position = {70, 70}
	other.settings.shape = .Rectangle
	other.settings.particleColor = {255, 0, 0, 255}
	other.settings.colorEnd = {255, 0, 0, 255}
	Scene_ProcessQueues(scene)
	run(scene, 0.1)

	surface := sdl.CreateSurface(100, 100, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	Scene_Draw(scene, renderer)
	sdl.RenderPresent(renderer)
	pixel :: proc(surface: ^sdl.Surface, x, y: int) -> [4]u8 {
		row := ([^]u8)(surface.pixels)[y * int(surface.pitch):]
		return {row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]}
	}
	testing.expectf(t, pixel(surface, 30, 30).g == 255, "circle %v", pixel(surface, 30, 30))
	testing.expectf(t, pixel(surface, 37, 30).g == 255, "circle edge %v", pixel(surface, 37, 30))
	testing.expectf(t, pixel(surface, 30, 42).g == 0, "outside the circle %v", pixel(surface, 30, 42))
	testing.expectf(t, pixel(surface, 73, 73).r == 255, "rectangle %v", pixel(surface, 73, 73))
	testing.expectf(t, pixel(surface, 77, 77).r == 0, "outside the rectangle %v", pixel(surface, 77, 77))
}
