#+build !js
package engine

import "core:log"
import "core:strings"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

@(test)
debug_shapes_last_their_time :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }

	Debug_Line(scene, {0, 0}, {10, 10})
	Debug_Text(scene, {0, 0}, "one frame")
	Debug_Circle(scene, {5, 5}, 3, seconds = 0.5)
	testing.expect_value(t, len(scene.debugShapes), 3)
	// The next update: the one-frame shapes go
	Scene_Update(scene, nil, 0.1)
	testing.expect_value(t, len(scene.debugShapes), 1)
	testing.expect(t, scene.debugShapes[0].kind == .Circle, "the lasting one stays")
	for _ in 0 ..< 4 do Scene_Update(scene, nil, 0.1)
	testing.expect_value(t, len(scene.debugShapes), 1)
	for _ in 0 ..< 2 do Scene_Update(scene, nil, 0.1)
	testing.expect_value(t, len(scene.debugShapes), 0)

	// Clearing frees lasting text too (the leak check sees it)
	Debug_Text(scene, {0, 0}, "lasting", seconds = 10)
	Debug_Rect(scene, {0, 0, 4, 4}, seconds = 10)
	Debug_Clear(scene)
	testing.expect_value(t, len(scene.debugShapes), 0)
	// And a scene destroyed with shapes queued frees them
	Debug_Text(scene, {0, 0}, "at the end", seconds = 10)
}

@(test)
debug_shapes_draw_through_the_view :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(100, 100, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }

	Debug_Rect(scene, {10, 10, 10, 10}, {255, 0, 0, 255}, filled = true)
	Debug_Circle(scene, {70, 20}, 5, {0, 0, 255, 255}, filled = true)
	// The view moves the world 20 px right
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, Transform2D_Make({20, 0}, 0, {1, 1}))
	sdl.FlushRenderer(renderer)
	at :: proc(s: ^sdl.Surface, x, y: int) -> [4]u8 {
		row := ([^]u8)(s.pixels)[y * int(s.pitch):]
		return {row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]}
	}
	testing.expect_value(t, at(surface, 35, 15), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(surface, 15, 15), [4]u8{0, 0, 0, 255})
	testing.expect_value(t, at(surface, 90, 20), [4]u8{0, 0, 255, 255})
	testing.expect(t, GetDrawTransform() == TRANSFORM2D_IDENTITY, "the draw state is put back")
}

@(test)
debug_overlay_shows_frame_stats :: proc(t: ^testing.T) {
	sync.guard(&ttfLock)
	if ttf.WasInit() == 0 do ttf.Init()
	surface := sdl.CreateSurface(320, 240, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	context.logger = log.nil_logger()

	game := new(Game)
	defer free(game)
	Game_Init(game, nil, renderer, nil)
	game.size = {320, 240}
	defer Game_Destroy(game)
	fps, average, worst := Game_GetFrameStats(game)
	testing.expect(t, fps == 0 && average == 0 && worst == 0, "nothing before the first frame")

	scene := Game_CreateScene(game, "Level")
	_ = Game_SwitchScene(game, "Level")
	CreateNode(scene, Node)
	CreateNode(scene, Node)
	for _ in 0 ..< 9 do Game_Update(game, nil, 0.01)
	Game_Update(game, nil, 0.1)
	fps, average, worst = Game_GetFrameStats(game)
	// Ten frames in 0.19 s
	testing.expectf(t, abs(average - 19) < 0.01 && abs(worst - 100) < 0.01 && abs(fps - 1 / 0.019) < 0.1, "%v fps %v ms worst %v", fps, average, worst)
	// The history is a ring: old frames drop out
	for _ in 0 ..< DEBUG_FRAME_HISTORY do Game_Update(game, nil, 0.02)
	_, _, worst = Game_GetFrameStats(game)
	testing.expectf(t, abs(worst - 20) < 0.01, "worst of the recent frames %v", worst)

	lines := debugOverlayLines(game)
	text := strings.join(lines, "\n", context.temp_allocator)
	testing.expectf(t, strings.contains(text, "50 fps") && strings.contains(text, "Level") && strings.contains(text, "2 nodes"), "overlay: %s", text)

	// Drawn in the top-left corner, over a white game
	game.debugOverlay = true
	sdl.SetRenderDrawColor(renderer, 255, 255, 255, 255)
	sdl.RenderClear(renderer)
	Game_Draw(game)
	sdl.FlushRenderer(renderer)
	row := ([^]u8)(surface.pixels)[10 * int(surface.pitch):]
	testing.expect(t, row[10 * 4] < 128, "the overlay's dark panel")
	free_all(context.temp_allocator)
}
