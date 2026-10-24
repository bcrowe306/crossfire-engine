#+build !js
package crossfire

import "core:log"
import "core:math"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

// 2D lighting (lighting.odin): what lights reach, occluders' shadows, spot cones, the light map
// over the world (and not over screen layers), scene files

@(private="file")
LIGHT_SCENE :: `<scene formatVersion="13" name="S" lighting="true" ambient="#000000" bodyShadows="true">
	<node kind="Light2D" name="Lamp" x="50" y="50" lightColor="#ffffff" energy="1" lightRadius="60" shadows="true"/>
	<node kind="LightOccluder" name="Wall" x="80" y="50" width="10" height="30"/>
	<node kind="Light2D" name="Spot" x="0" y="0" lightKind="Spot" spotAngle="90" lightRadius="30" energy="0"/>
</scene>`

@(test)
lights_reach_what_occluders_leave :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	data, err := ParseScene(LIGHT_SCENE)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect(t, data.settings.lighting && data.settings.ambient == {0, 0, 0, 255} && data.settings.bodyShadows, "the scene's lighting")
	testing.expect(t, data.nodes[0].light.radius == 60 && data.nodes[2].light.kind == .Spot && data.nodes[2].light.angle == 90, "lights")
	created := Scene_Build(scene, &data, "testdata", attachScripts = false)
	Scene_ProcessQueues(scene)
	testing.expect(t, scene.lighting.enabled && scene.lighting.bodyShadows, "applied")
	lamp := cast(^Light2D)created[0]

	// Toward the wall (its near face at x 75) the light stops; away from it, at the radius
	ring := Light_Visibility(lamp, context.temp_allocator)
	nearest := func_nearest(ring, {50, 50}, 0)
	farthest := func_nearest(ring, {50, 50}, math.PI)
	testing.expectf(t, abs(nearest - 25) < 0.5, "stopped by the wall: %v", nearest)
	testing.expectf(t, abs(farthest - 60) < 0.5, "free the other way: %v", farthest)
	// Without shadows it goes through
	lamp.settings.shadows = false
	testing.expectf(t, abs(func_nearest(Light_Visibility(lamp, context.temp_allocator), {50, 50}, 0) - 60) < 0.5, "no shadows")

	// A spot cone: 90 degrees facing right (rotation 0), so nothing to the left
	spot := cast(^Light2D)created[2]
	for p in Light_Visibility(spot, context.temp_allocator) do testing.expectf(t, p.x > -0.01, "in the cone: %v", p)
	spot.rotation = 90
	for p in Light_Visibility(spot, context.temp_allocator) do testing.expectf(t, p.y > -0.01, "turned down: %v", p)
	free_all(context.temp_allocator)
}

// The distance to the ring point closest to an angle
@(private="file")
func_nearest :: proc(ring: [][2]f32, center: [2]f32, angle: f32) -> f32 {
	best, distance := max(f32), f32(0)
	for p in ring {
		d := p - center
		a := math.atan2(d.y, d.x)
		diff := abs(math.mod(a - angle + math.PI * 3, math.TAU) - math.PI)
		if diff < best do best, distance = diff, math.sqrt(d.x * d.x + d.y * d.y)
	}
	return distance
}

@(test)
lit_scenes_draw_dark_outside_lights :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(120, 100, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.resourceManager.renderer = renderer
	game.renderer = renderer
	scene := game->createScene("S")
	data, _ := ParseScene(LIGHT_SCENE)
	defer SceneData_Destroy(&data)
	Scene_Build(scene, &data, "testdata", attachScripts = false)
	Scene_ProcessQueues(scene)
	// A white floor (a node that draws, on layer 1), and a white square on a screen layer
	Floor :: struct { using node: Node }
	floor := CreateNode(scene, Floor)
	floor.draw = proc(node: ^Node, renderer: ^sdl.Renderer) {
		r := sdl.FRect{0, 0, 120, 100}
		DrawRectangle(renderer, &r, {255, 255, 255, 255})
	}
	hud := CreateNode(scene, Floor)
	hud.layer = .Layer8
	hud.draw = proc(node: ^Node, renderer: ^sdl.Renderer) {
		r := sdl.FRect{110, 0, 10, 10}
		DrawRectangle(renderer, &r, {255, 255, 255, 255})
	}
	scene.screenLayers = {.Layer8}
	Scene_ProcessQueues(scene)
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	sdl.FlushRenderer(renderer)
	pixel :: proc(s: ^sdl.Surface, x, y: int) -> u8 { return ([^]u8)(s.pixels)[y * int(s.pitch) + x * 4] }
	// Bright at the lamp, fading out; black past its reach and in the wall's shadow; the screen
	// layer not lit
	testing.expectf(t, pixel(surface, 50, 50) > 240, "at the lamp: %d", pixel(surface, 50, 50))
	testing.expectf(t, pixel(surface, 50, 80) > 80 && pixel(surface, 50, 80) < 180, "halfway: %d", pixel(surface, 50, 80))
	testing.expect_value(t, pixel(surface, 5, 95), u8(0))
	testing.expectf(t, pixel(surface, 100, 50) == 0, "behind the wall: %d", pixel(surface, 100, 50))
	testing.expect_value(t, pixel(surface, 115, 5), u8(255))
	free_all(context.temp_allocator)
}

// Two lamps overlapping, a wall: on the GPU every fan is added straight into the light map
// (Lighting_Apply), on the software renderer through the scratch target; the pictures agree
@(private="file")
TWO_LAMPS :: `<scene formatVersion="13" name="S" lighting="true" ambient="#000000" bodyShadows="true">
	<node kind="Light2D" name="Lamp" x="40" y="50" lightColor="#ffffff" energy="0.5" lightRadius="50" shadows="true"/>
	<node kind="Light2D" name="Lamp2" x="70" y="50" lightColor="#ffffff" energy="0.5" lightRadius="50" shadows="true"/>
	<node kind="LightOccluder" name="Wall" x="100" y="50" width="6" height="40"/>
</scene>`

// The lamps' picture on a white floor, as rows of the red channel
@(private="file")
drawTwoLamps :: proc(renderer: ^sdl.Renderer) -> [100][120]u8 {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.resourceManager.renderer = renderer
	game.renderer = renderer
	scene := game->createScene("S")
	data, _ := ParseScene(TWO_LAMPS)
	defer SceneData_Destroy(&data)
	Scene_Build(scene, &data, "testdata", attachScripts = false)
	Floor :: struct { using node: Node }
	floor := CreateNode(scene, Floor)
	floor.draw = proc(node: ^Node, renderer: ^sdl.Renderer) {
		r := sdl.FRect{0, 0, 120, 100}
		DrawRectangle(renderer, &r, {255, 255, 255, 255})
	}
	Scene_ProcessQueues(scene)
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	sdl.FlushRenderer(renderer)
	out: [100][120]u8
	surface := sdl.RenderReadPixels(renderer, nil)
	if surface == nil do return out
	defer sdl.DestroySurface(surface)
	converted := sdl.ConvertSurface(surface, .ARGB8888)
	defer sdl.DestroySurface(converted)
	for y in 0 ..< 100 do for x in 0 ..< 120 {
		out[y][x] = u8(((cast([^]u32)converted.pixels)[y * int(converted.pitch / 4) + x] >> 16) & 0xff)
	}
	return out
}

@(test)
lit_scenes_draw_alike_on_the_gpu :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(120, 100, .RGBA32)
	defer sdl.DestroySurface(surface)
	software := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(software)
	soft := drawTwoLamps(software)
	// Where the lamps overlap their light adds up: brighter than near one alone
	testing.expectf(t, soft[50][55] > soft[50][15], "overlap %d against one lamp %d", soft[50][55], soft[50][15])
	testing.expectf(t, soft[50][115] < 30, "behind the wall: %d", soft[50][115])

	sync.guard(&gpuTestLock)
	renderer, game := gpuGame()
	if renderer == nil {
		log.info("No GPU renderer here: skipping the GPU lighting test")
		return
	}
	defer sdl.DestroyRenderer(renderer)
	Game_Destroy(game)
	free(game)
	target := sdl.CreateTexture(renderer, RENDER_TARGET_FORMAT, .TARGET, 120, 100)
	defer sdl.DestroyTexture(target)
	_ = sdl.SetRenderTarget(renderer, target)
	gpu := drawTwoLamps(renderer)
	// The same picture: the renderers round triangle edges differently, so pixels on a shadow's
	// edge may differ; everywhere else within a few levels
	off := 0
	for y in 0 ..< 100 do for x in 0 ..< 120 do if abs(int(gpu[y][x]) - int(soft[y][x])) > 6 do off += 1
	testing.expectf(t, off < 120, "%d of 12000 pixels differ by more than 6 levels", off)
	testing.expectf(t, gpu[50][55] > gpu[50][15], "the GPU's overlap %d against one lamp %d", gpu[50][55], gpu[50][15])
	testing.expectf(t, abs(int(gpu[50][55]) - int(soft[50][55])) <= 6, "the overlap: GPU %d, software %d", gpu[50][55], soft[50][55])
	testing.expectf(t, gpu[50][115] < 30, "behind the wall on the GPU: %d", gpu[50][115])
}
