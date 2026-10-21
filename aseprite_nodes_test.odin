#+build !js
package crossfire

import "core:os"
import "core:testing"
import sdl "vendor:sdl3"

// Aseprite files in a game: frame events, layers, pivot and 9-patch slices, hitboxes following
// slices, animated tilemaps. The files are Aseprite's (testdata/aseprite/conformance/features,
// tilemap_animated; testdata/aseprite/slices-moving)

@(private="file")
featureGame :: proc(t: ^testing.T, size: [2]i32 = {32, 32}) -> (game: ^Game, scene: ^Scene, surface: ^sdl.Surface, renderer: ^sdl.Renderer) {
	surface = sdl.CreateSurface(size.x, size.y, .RGBA32)
	renderer = sdl.CreateSoftwareRenderer(surface)
	game = testGame("testdata/aseprite")
	game.resourceManager.renderer = renderer
	scene = game->createScene("S")
	return
}

@(private="file")
build :: proc(t: ^testing.T, scene: ^Scene, text: string, loc := #caller_location) -> []^Node {
	data, err := ParseScene(text)
	testing.expect_value(t, err, ProjectError.None, loc = loc)
	defer SceneData_Destroy(&data)
	created := Scene_Build(scene, &data, "testdata/aseprite", attachScripts = false)
	Scene_ProcessQueues(scene)
	return created
}

@(private="file")
pixel :: proc(surface: ^sdl.Surface, x, y: int) -> [4]u8 {
	p := ([^]u8)(surface.pixels)[y * int(surface.pitch) + x * 4:][:4]
	return {p[0], p[1], p[2], p[3]}
}

@(private="file")
draw :: proc(scene: ^Scene, renderer: ^sdl.Renderer, view := TRANSFORM2D_IDENTITY) {
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 0)
	sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, view)
	sdl.FlushRenderer(renderer)
}

@(test)
aseprite_frame_events_play :: proc(t: ^testing.T) {
	game, scene, surface, renderer := featureGame(t)
	defer { Game_Destroy(game); free(game); sdl.DestroyRenderer(renderer); sdl.DestroySurface(surface) }
	// The tag's frames: nothing, a cel's text ("step"), a cel's `event` property ("hit")
	ase := Game_LoadAseprite(game, "testdata/aseprite/conformance/features.aseprite")
	testing.expect(t, ase != nil, "read")
	if ase == nil do return
	testing.expect_value(t, Aseprite_FrameEvents(ase, 0), "")
	testing.expect_value(t, Aseprite_FrameEvents(ase, 1), "step")
	testing.expect_value(t, Aseprite_FrameEvents(ase, 2), "hit")

	created := build(t, scene, `<scene formatVersion="13" name="S"><node kind="AnimatedSprite" name="Hero" animations="conformance/features.aseprite"/></scene>`)
	hero := cast(^AnimatedSprite)created[0]
	heard := make([dynamic]string, context.temp_allocator)
	hero.animation.onFrameEvent->subscribe(proc(_: ^EventSubject, _: rawptr, data: EventData, userData: rawptr) {
		append(cast(^[dynamic]string)userData, data.(string))
	}, &heard)
	AnimationPlayer_Update(&hero.animation, 0.1)
	AnimationPlayer_Update(&hero.animation, 0.1)
	testing.expect(t, len(heard) == 2 && heard[0] == "step" && heard[1] == "hit", "step, then hit")
	// The event is a node event listeners can name
	testing.expect(t, Node_FindEvent(hero, "animation.onFrameEvent") != nil, "listeners find it")
	free_all(context.temp_allocator)
}

@(test)
aseprite_layers_pivots_and_nine_slices :: proc(t: ^testing.T) {
	game, scene, surface, renderer := featureGame(t, {48, 40})
	defer { Game_Destroy(game); free(game); sdl.DestroyRenderer(renderer); sdl.DestroySurface(surface) }
	created := build(t, scene, `<scene formatVersion="13" name="S">
		<node kind="Sprite" name="Sword" x="8" y="8" texture="conformance/features.aseprite" layers="Sword"/>
		<node kind="Sprite" name="Body" x="8" y="8" texture="conformance/features.aseprite" layers="Body" visible="false"/>
		<node kind="Sprite" name="Feet" x="20" y="20" texture="conformance/features.aseprite" pivotSlice="feet"/>
		<node kind="Sprite" name="Panel" x="24" y="20" texture="conformance/features.aseprite" nineSlice="panel" nineWidth="40" nineHeight="32"/>
	</scene>`)
	sword, body, feet, panel := created[0], created[1], created[2], created[3]
	// Only its layers: the sword's line at y 8 from x 9, no body
	(cast(^Sprite)feet).visible = false
	panel.visible = false
	draw(scene, renderer)
	testing.expect_value(t, pixel(surface, 12, 8), [4]u8{220, 220, 255, 255})
	testing.expect_value(t, pixel(surface, 6, 10)[3], 0)
	sword.visible, body.visible = false, true
	draw(scene, renderer)
	testing.expect_value(t, pixel(surface, 6, 10), [4]u8{200, 120, 60, 255})
	testing.expect_value(t, pixel(surface, 10, 8), [4]u8{200, 120, 60, 255})
	testing.expect_value(t, pixel(surface, 13, 8)[3], 0)

	// The feet slice's pivot (8, 16) on the origin
	bounds, _ := Node_GetLocalBounds(feet)
	testing.expect_value(t, bounds, sdl.FRect{-8, -16, 16, 16})
	testing.expect_value(t, Sprite_Origin(feet), [2]f32{8, 16})
	// The 9-patch at 40 x 32, centered: corners as they are
	bounds, _ = Node_GetLocalBounds(panel)
	testing.expect_value(t, bounds, sdl.FRect{-20, -16, 40, 32})
	body.visible, panel.visible = false, true
	draw(scene, renderer)
	ase := Game_LoadAseprite(game, "testdata/aseprite/conformance/features.aseprite")
	full := Aseprite_FramePixels(ase, 0, context.temp_allocator)
	at :: proc(p: []u8, x, y: int) -> [4]u8 { return {p[(y * 16 + x) * 4], p[(y * 16 + x) * 4 + 1], p[(y * 16 + x) * 4 + 2], p[(y * 16 + x) * 4 + 3]} }
	// The bottom-right corner (12..15 of 16) lands at the 9-patch's last 4 pixels: 40 + 4 - 4..
	testing.expect_value(t, pixel(surface, 24 + 20 - 4 + 1, 20 + 16 - 4 + 1), at(full, 13, 13))
	testing.expect_value(t, pixel(surface, 24 - 20 + 1, 20 - 16 + 1), at(full, 1, 1))
	free_all(context.temp_allocator)
}

@(test)
aseprite_slices_are_hitboxes :: proc(t: ^testing.T) {
	game, scene, surface, renderer := featureGame(t)
	defer { Game_Destroy(game); free(game); sdl.DestroyRenderer(renderer); sdl.DestroySurface(surface) }
	// A body with a sprite playing slices-moving's 4 frames (its "square" slice moves every frame),
	// and a shape following it
	created := build(t, scene, `<scene formatVersion="13" name="S">
		<node kind="StaticBody" name="Box" x="100" y="50">
			<node kind="AnimatedSprite" name="Sprite" animations="slices-moving.aseprite"/>
			<node kind="CollisionShape" name="Hit" slice="square"/>
		</node>
	</scene>`)
	sprite := cast(^AnimatedSprite)created[1]
	hit := cast(^CollisionShape)created[2]
	testing.expect_value(t, hit.slice, "square")
	// Each frame's key, the 4 x 4 picture's middle on the origin: (x, y, w, h) -> center - 2
	want := [4][4]f32{{0, 0, 2, 2}, {0, 0, 4, 2}, {1, 1, 3, 2}, {0, 2, 4, 2}}
	for frame in 0..<4 {
		if frame > 0 do AnimationPlayer_Update(&sprite.animation, f64(Animation_FrameDuration(AnimationPlayer_Current(&sprite.animation), frame - 1)) + 0.0001)
		Scene_Update(scene, nil, 0)
		k := want[frame]
		testing.expectf(t, hit.position == [2]f32{k[0] + k[2] / 2 - 2, k[1] + k[3] / 2 - 2} && hit.size == [2]f32{k[2], k[3]} && !hit.disabled,
			"frame %d: at %v, %v", frame, hit.position, hit.size)
	}
	// Mirrored sprite: mirrored hitbox
	sprite.scale = {-1, 1}
	Scene_Update(scene, nil, 0)
	testing.expect_value(t, hit.position, [2]f32{0, 1})
	// Hidden in a frame (0 wide): off
	ase := Game_LoadAseprite(game, JoinPath("testdata/aseprite", "slices-moving.aseprite"))
	ase.slices[0].keys[3].bounds[2] = 0
	Scene_Update(scene, nil, 0)
	testing.expect(t, hit.disabled, "off where the slice is hidden")
	free_all(context.temp_allocator)
}

@(test)
tilemaps_animate :: proc(t: ^testing.T) {
	game, scene, surface, renderer := featureGame(t, {8, 4})
	defer { Game_Destroy(game); free(game); sdl.DestroyRenderer(renderer); sdl.DestroySurface(surface) }
	created := build(t, scene, `<scene formatVersion="13" name="S">
		<node kind="TileMap" name="Water" tilemap="conformance/tilemap_animated.aseprite" animate="true" tag="flow"/>
	</scene>`)
	water := cast(^TileMapNode)created[0]
	testing.expect_value(t, len(water.frames), 2)
	draw(scene, renderer)
	testing.expect_value(t, pixel(surface, 1, 1), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, pixel(surface, 5, 1), [4]u8{0, 200, 255, 255})
	// After its first frame's 200 ms: the second frame, the tiles swapped
	Scene_Update(scene, nil, 0.21)
	draw(scene, renderer)
	testing.expect_value(t, pixel(surface, 1, 1), [4]u8{0, 200, 255, 255})
	testing.expect_value(t, pixel(surface, 5, 1), [4]u8{0, 0, 255, 255})
	tile, _, _ := TileMap_TileAt(water, "Water", {1, 1})
	testing.expect_value(t, tile, u32(2))
	// After the second's 300 ms: back to the first
	Scene_Update(scene, nil, 0.3)
	testing.expect_value(t, water.shown, 0)
	// A tile set while it plays stays in every frame
	testing.expect(t, TileMap_SetTile(water, "Water", 0, 0, 0), "set")
	draw(scene, renderer)
	testing.expect_value(t, pixel(surface, 1, 1)[3], 0)
	Scene_Update(scene, nil, 0.21)
	draw(scene, renderer)
	testing.expect_value(t, pixel(surface, 1, 1)[3], 0)
	testing.expect(t, !TileMap_SetTile(water, "Water", 9, 0, 1), "off the grid")
	testing.expect(t, !TileMap_SetTile(water, "Nope", 0, 0, 1), "no such layer")
	_ = os.exists
	free_all(context.temp_allocator)
}
