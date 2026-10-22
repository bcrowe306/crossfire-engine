#+build !js
package crossfire

import "core:fmt"
import "core:log"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

// GPU particles (gpu_particles.odin): drawn by the GPU renderer (skipped without a GPU), runs
// starting, stopping and finishing; the CPU simulating them where there's no GPU renderer

@(private="file")
emitterScene :: proc(game: ^Game, scene: ^Scene, extra: string) -> ^ParticleEmitter {
	data, _ := ParseScene(tprint_scene(extra))
	defer SceneData_Destroy(&data)
	_ = Scene_Build(scene, &data, "testdata")
	Scene_Update(scene, nil, 0)
	return cast(^ParticleEmitter)Scene_FindNode(scene, "Sparks")
}

@(private="file")
tprint_scene :: proc(extra: string) -> string {
	return fmt_tprintf(`<scene formatVersion="13"><node name="Sparks" kind="ParticleEmitter" x="32" y="16"><particles gpu="true" gpuAmount="3000" lifetime="1" velocity="0" gravityVelocity="0" spread="6,6" size="3,3" useColorRamp="false" particleColor="#ff0000" colorEnd="#ff0000" %s/></node></scene>`, extra)
}

@(private="file")
fmt_tprintf :: proc(f: string, args: ..any) -> string {
	return fmt.tprintf(f, ..args)
}

@(test)
gpu_particles_draw_on_the_gpu :: proc(t: ^testing.T) {
	sync.guard(&gpuTestLock)
	renderer, game := gpuGame()
	if renderer == nil {
		log.info("No GPU renderer here: skipping the GPU particles test")
		return
	}
	defer sdl.DestroyRenderer(renderer)
	defer { Game_Destroy(game); free(game) }
	target := sdl.CreateTexture(renderer, RENDER_TARGET_FORMAT, .TARGET, 64, 32)
	defer sdl.DestroyTexture(target)
	_ = sdl.SetRenderTarget(renderer, target)
	scene := game->createScene("S")
	sparks := emitterScene(game, scene, `continuous="true"`)
	testing.expect(t, sparks != nil && sparks.settings.gpu && sparks.settings.gpuAmount == 3000, "built")
	draw :: proc(scene: ^Scene, renderer: ^sdl.Renderer) {
		_ = sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
		_ = sdl.RenderClear(renderer)
		Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	}
	// Half a cycle: half the particles are out, around the emitter
	for _ in 0 ..< 30 do Scene_Update(scene, nil, 1.0 / 60)
	draw(scene, renderer)
	testing.expect(t, ParticleEmitter_OnGPU(sparks), "drawn on the GPU")
	// (the CPU simulated until the first draw found the GPU renderer: its particles stay where they were)
	center := pixelAt(renderer, 32, 16)
	testing.expectf(t, (center >> 16) & 0xff > 150 && (center >> 8) & 0xff < 60, "red particles at the emitter: %08x", center)
	testing.expectf(t, pixelAt(renderer, 2, 2) & 0xffffff == 0, "nothing far away: %08x", pixelAt(renderer, 2, 2))
	// They follow the emitter: moved, new ones start where it is now
	sparks.position = {12, 16}
	for _ in 0 ..< 70 do Scene_Update(scene, nil, 1.0 / 60)
	draw(scene, renderer)
	testing.expectf(t, (pixelAt(renderer, 12, 16) >> 16) & 0xff > 150, "at its new place: %08x", pixelAt(renderer, 12, 16))
	testing.expectf(t, (pixelAt(renderer, 32, 16) >> 16) & 0xff < 40, "gone from the old one (a lifetime later): %08x", pixelAt(renderer, 32, 16))

	// Stopped: the last particles live out their lifetime, then onFinished
	finished := 0
	Event_Subscribe(&sparks.onFinished, proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) { (cast(^int)user)^ += 1 }, &finished)
	ParticleEmitter_Stop(sparks)
	for _ in 0 ..< 30 do Scene_Update(scene, nil, 1.0 / 60)
	draw(scene, renderer)
	testing.expectf(t, (pixelAt(renderer, 12, 16) >> 16) & 0xff > 100, "still some half a lifetime after: %08x", pixelAt(renderer, 12, 16))
	for _ in 0 ..< 40 do Scene_Update(scene, nil, 1.0 / 60)
	draw(scene, renderer)
	testing.expectf(t, (pixelAt(renderer, 12, 16) >> 16) & 0xff < 40, "none a lifetime after: %08x", pixelAt(renderer, 12, 16))
	testing.expect_value(t, finished, 1)
	// Started again
	ParticleEmitter_Start(sparks)
	for _ in 0 ..< 30 do Scene_Update(scene, nil, 1.0 / 60)
	draw(scene, renderer)
	testing.expectf(t, (pixelAt(renderer, 12, 16) >> 16) & 0xff > 150, "a new run: %08x", pixelAt(renderer, 12, 16))
	_ = sdl.SetRenderTarget(renderer, nil)
}

@(test)
gpu_particles_on_the_cpu_without_the_gpu_renderer :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(64, 32, .ARGB8888)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.renderer = renderer
	scene := game->createScene("S")
	sparks := emitterScene(game, scene, `continuous="true" amount="40"`)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	testing.expect(t, !ParticleEmitter_OnGPU(sparks), "not on the GPU")
	for _ in 0 ..< 30 do Scene_Update(scene, nil, 1.0 / 60)
	testing.expect(t, ParticleEmitter_AliveCount(sparks) > 10, "the CPU simulates them")
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	sdl.RenderPresent(renderer)
	p := (cast([^]u32)surface.pixels)[16 * 64 + 32]
	testing.expectf(t, (p >> 16) & 0xff > 100, "drawn: %08x", p)
}
