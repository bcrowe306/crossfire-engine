#+build !js
package engine

import "core:log"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// The rest of the core API: visibility and screen positions, drawing through a view (layers,
// screen layers, position-only nodes), game scaling on a real (software) renderer, and the
// application's game swap.

@(test)
visibility_and_screen_positions :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	parent := CreateNode(scene, Node)
	child := CreateNode(scene, Node)
	Node_AddChild(parent, child)
	testing.expect(t, Node_IsVisibleInTree(child), "visible")
	parent.visible = false
	testing.expect(t, !Node_IsVisibleInTree(child), "hidden by its parent")
	testing.expect(t, child.visible, "its own flag is untouched")
	parent.visible = true

	parent.position = {100, 50}
	child.position = {10, 0}
	// No camera: screen is world
	testing.expect_value(t, Node_GetScreenPosition(child), [2]f32{110, 50})
	// A camera at (100, 50), zoom 2, its target drawn at (160, 90)
	camera := CreateNode(scene, Camera2D)
	camera.zoom = 2
	camera.offset = {160, 90}
	camera.position = {100, 50}
	scene.camera = camera
	testing.expect_value(t, Node_GetScreenPosition(child), [2]f32{180, 90})
	// A node on a screen layer ignores the camera
	child.layer = .Layer8
	scene.screenLayers = {.Layer8}
	testing.expect_value(t, Node_GetScreenPosition(child), [2]f32{110, 50})
	free_all(context.temp_allocator)
}

@(test)
drawing_through_a_view_orders_layers_and_screen_space :: proc(t: ^testing.T) {
	Drawn :: struct { name: string, transform: Transform2D }
	@(static) drawn: [dynamic]Drawn
	drawn = make([dynamic]Drawn, context.temp_allocator)
	record :: proc(node: ^Node, _: ^sdl.Renderer) {
		append(&drawn, Drawn{node.name, GetDrawTransform()})
	}
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	drawer :: proc(scene: ^Scene, name: string, layer: RenderLayer, position: [2]f32) -> ^Node {
		n := CreateNode(scene, Node)
		n.name, n.layer, n.position, n.draw = name, layer, position, record
		return n
	}
	top := drawer(scene, "Top", .Layer3, {10, 0})
	drawer(scene, "Bottom", .Layer1, {20, 0})
	hud := drawer(scene, "Hud", .Layer8, {5, 5})
	label := drawer(scene, "Label", .Layer2, {30, 0})
	label.transformMode = .Position_Only
	label.rotation = 45
	nothing := CreateNode(scene, Node) // draws nothing: skipped
	nothing.name = "Nothing"
	scene.screenLayers = {.Layer8}
	Scene_ProcessQueues(scene)

	view := Transform2D{x = {2, 0}, y = {0, 2}, origin = {100, 0}}
	Scene_DrawWithView(scene, nil, view, positionOnlyScale = 3)
	// Layer order, whatever the tree order
	testing.expect_value(t, len(drawn), 4)
	if len(drawn) == 4 {
		testing.expect_value(t, drawn[0].name, "Bottom")
		testing.expect_value(t, drawn[1].name, "Label")
		testing.expect_value(t, drawn[2].name, "Top")
		testing.expect_value(t, drawn[3].name, "Hud")
		// World layers through the view
		testing.expect_value(t, Transform2D_Apply(drawn[2].transform, {0, 0}), [2]f32{120, 0})
		// Position-only: placed through the view, sized by positionOnlyScale, never rotated
		testing.expect_value(t, drawn[1].transform, Transform2D{x = {3, 0}, y = {0, 3}, origin = {160, 0}})
		// A screen layer ignores the view
		testing.expect_value(t, Transform2D_Apply(drawn[3].transform, {0, 0}), [2]f32{5, 5})
	}
	// An editor shows screen layers through its view too
	clear(&drawn)
	Scene_DrawWithView(scene, nil, view, screenLayersUseView = true)
	testing.expect(t, len(drawn) == 4 && Transform2D_Apply(drawn[3].transform, {0, 0}) == {110, 10}, "the HUD through the view")
	// After drawing, the draw state is back to identity
	testing.expect_value(t, GetDrawTransform(), TRANSFORM2D_IDENTITY)
	_ = top
	_ = hud
	free_all(context.temp_allocator)
}

@(test)
game_scaling_maps_window_to_game :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(800, 600, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game: Game
	game.renderer = renderer
	game.size = {400, 300}
	Game_SetScaleMode(&game, .Letterbox)
	// 400 x 300 fills 800 x 600 at 2x
	testing.expect_value(t, Game_WindowToGame(&game, {400, 300}), [2]f32{200, 150})
	testing.expect_value(t, Game_WindowToGame(&game, {0, 0}), [2]f32{0, 0})
	// A wider game letterboxes: bars above and below
	Game_SetSize(&game, {800, 300})
	testing.expect_value(t, game.size, [2]f32{800, 300})
	testing.expect_value(t, Game_WindowToGame(&game, {400, 300}), [2]f32{400, 150})
	testing.expect_value(t, Game_WindowToGame(&game, {0, 150}), [2]f32{0, 0})
	// Stretch fills both axes
	Game_SetScaleMode(&game, .Stretch)
	testing.expect_value(t, Game_WindowToGame(&game, {800, 600}), [2]f32{800, 300})
	// None: window coordinates are game coordinates
	Game_SetScaleMode(&game, .None)
	testing.expect_value(t, Game_WindowToGame(&game, {123, 45}), [2]f32{123, 45})
}

// SDL_ttf isn't thread-safe; tests that make text engines take turns
@(private="file")
ttfLock: sync.Mutex

@(test)
the_application_swaps_games :: proc(t: ^testing.T) {
	sync.guard(&ttfLock)
	if ttf.WasInit() == 0 do ttf.Init()
	surface := sdl.CreateSurface(320, 240, .RGBA32)
	defer sdl.DestroySurface(surface)
	app := Application{renderer = sdl.CreateSoftwareRenderer(surface), running = true}
	// No window here: what that costs (its size) is logged, and isn't what's tested
	context.logger = log.nil_logger()

	Built :: struct { builds: int }
	@(static) built: Built
	built = {}
	first := new(Game)
	first.size = {320, 240}
	first.build = proc(game: ^Game) {
		built.builds += 1
		scene := Game_CreateScene(game, "Main")
		_ = Game_SwitchScene(game, "Main")
		CreateNode(scene, Node).name = "Thing"
	}
	App_SetGame(&app, first)
	Application_Frame(&app)
	testing.expect(t, app.game == first && first.initialized && built.builds == 1, "the first game started")
	testing.expect(t, first.currentScene != nil && Scene_FindNode(first.currentScene, "Thing") != nil, "its scene runs")

	// Setting the playing game again doesn't destroy it
	App_SetGame(&app, first)
	Application_Frame(&app)
	testing.expect(t, app.game == first && first.currentScene != nil && built.builds == 1, "still the same, still running")

	// Another game: the first one is destroyed
	second := new(Game)
	second.size = {320, 240}
	App_SetGame(&app, second)
	Application_Frame(&app)
	testing.expect(t, app.game == second && second.initialized, "switched")
	testing.expect(t, first.scenes == nil && first.currentScene == nil, "the first was torn down")
	free(first)

	// A quitting game stops the loop
	second.shouldQuit = true
	Application_Frame(&app)
	testing.expect(t, !app.running, "stopped")

	// Cleanup without SDL_Quit's side effects on other tests: destroy what the app owns by hand
	Game_Destroy(app.game)
	free(app.game)
	app.game = nil
	sdl.DestroyRenderer(app.renderer)
}

@(test)
scenes_draw_into_render_targets :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(200, 100, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game: Game
	game.renderer = renderer
	game.size = {100, 50}
	Game_ApplyScaling(&game)
	scene := new(Scene)
	Scene_Init(scene)
	scene.game = &game
	defer { Scene_Destroy(scene); free(scene) }
	// A red square in the game's top-left quarter (0..50, 0..25)
	square := CreateNode(scene, Node)
	square.draw = proc(_: ^Node, renderer: ^sdl.Renderer) {
		rect := sdl.FRect{0, 0, 50, 25}
		DrawRectangle(renderer, &rect, {255, 0, 0, 255})
	}
	Scene_ProcessQueues(scene)

	target := RenderTarget_Create(&game, {50, 26})
	defer RenderTarget_Destroy(target)
	testing.expect(t, target != nil && target.size == {50, 26}, "made")
	if target == nil do return
	Scene_DrawToTarget(scene, target)
	// Read the target: the game view fitted to 50 x 26, so the square fills its top-left quarter
	RenderTarget_Begin(renderer, target)
	pixels := sdl.RenderReadPixels(renderer, nil)
	RenderTarget_End(renderer, target)
	defer sdl.DestroySurface(pixels)
	at :: proc(s: ^sdl.Surface, x, y: int) -> [4]u8 {
		converted := sdl.ConvertSurface(s, .RGBA32)
		defer sdl.DestroySurface(converted)
		row := ([^]u8)(converted.pixels)[y * int(converted.pitch):]
		return {row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]}
	}
	testing.expect_value(t, at(pixels, 5, 5), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, at(pixels, 40, 20), [4]u8{0, 0, 0, 0}) // cleared, transparent
	// Drawing goes back to the screen with the game's logical size
	current := sdl.GetRenderTarget(renderer).? or_else nil
	testing.expect(t, current == nil, "back on the screen")
	w, h: i32
	mode: sdl.RendererLogicalPresentation
	sdl.GetRenderLogicalPresentation(renderer, &w, &h, &mode)
	testing.expect(t, w == 100 && h == 50 && mode == .LETTERBOX, "logical presentation restored")
	free_all(context.temp_allocator)
}
