#+build !js
package crossfire

import "core:testing"
import sdl "vendor:sdl3"

// Camera tools (camera_tools.odin): parallax layers following the camera by their factor, camera
// zones bounding it and sliding between rooms, smooth zoom, a camera view drawn on screen

@(private="file")
CAMERA_SCENE :: `<scene formatVersion="13" name="S" screenLayers="8">
	<node kind="ParallaxLayer" name="Far" x="10" y="20" factorX="0.25" factorY="0"/>
	<node kind="Camera" name="Cam" x="320" y="180"/>
	<node kind="CameraZone" name="Room1" x="0" y="0" width="640" height="360"/>
	<node kind="CameraZone" name="Room2" x="640" y="0" width="640" height="360" zoneTransition="0.5"/>
	<node kind="Camera" name="MapCam" x="100" y="100"/>
	<node kind="CameraView" name="Map" x="20" y="20" width="40" height="30" viewCamera="../MapCam" border="1" layer="7"/>
</scene>`

@(test)
camera_tools_move_with_the_camera :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	// A screen smaller than a room: the camera can move inside one
	game.size = {320, 180}
	scene := game->createScene("S")
	data, err := ParseScene(CAMERA_SCENE)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect(t, data.nodes[0].cameraTools.factor == {0.25, 0} && data.nodes[3].cameraTools.transition == 0.5 && data.nodes[5].viewCamera == "../MapCam", "parsed")
	created := Scene_Build(scene, &data, "testdata", attachScripts = false)
	far := cast(^ParallaxLayer)created[0]
	camera := scene.camera
	testing.expect(t, camera != nil, "a camera")
	Scene_Update(scene, nil, 0)
	testing.expect_value(t, far.position, [2]f32{10, 20})
	// The camera inside Room1: bounded by it
	testing.expect(t, camera.bounded && camera.min == {0, 0} && camera.max == {640, 360}, "Room1's bounds")

	// The camera moves 100 right: the far layer moves 75 (it follows a quarter: shows 25 of it)
	camera.position.x += 100
	Scene_Update(scene, nil, 0)
	testing.expect_value(t, far.position, [2]f32{85, 20})

	// Into Room2: the bounds slide over half a second
	camera.position.x = 900
	Scene_Update(scene, nil, 0.25)
	testing.expectf(t, camera.min.x > 0 && camera.min.x < 640, "sliding: %v", camera.min)
	for _ in 0..<5 do Scene_Update(scene, nil, 0.1)
	testing.expect(t, camera.min == {640, 0} && camera.max == {1280, 360}, "Room2's bounds")

	// A smooth zoom
	Camera2D_ZoomTo(camera, 2, 0.5)
	Scene_Update(scene, nil, 0.25)
	testing.expect(t, camera.zoom > 1 && camera.zoom < 2, "zooming")
	Scene_Update(scene, nil, 0.3)
	testing.expect_value(t, camera.zoom, f32(2))
	Camera2D_ZoomTo(camera, 1, 0)
	testing.expect_value(t, camera.zoom, f32(1))
}

@(test)
camera_views_draw_another_cameras_view :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(120, 80, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.renderer = renderer
	game.resourceManager.renderer = renderer
	game.size = {120, 80}
	game.backgroundColor = {0, 0, 255, 255}
	scene := game->createScene("S")
	data, _ := ParseScene(CAMERA_SCENE)
	defer SceneData_Destroy(&data)
	Scene_Build(scene, &data, "testdata", attachScripts = false)
	Scene_Update(scene, nil, 0)
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	sdl.FlushRenderer(renderer)
	pixel :: proc(s: ^sdl.Surface, x, y: int) -> [3]u8 {
		p := ([^]u8)(s.pixels)[y * int(s.pitch) + x * 4:][:4]
		return {p[0], p[1], p[2]}
	}
	// Inside the view: its scene's background (blue); its border; outside: what was there (black)
	testing.expect_value(t, pixel(surface, 40, 35), [3]u8{0, 0, 255})
	testing.expect_value(t, pixel(surface, 19, 30), [3]u8{235, 240, 255})
	testing.expect_value(t, pixel(surface, 100, 70), [3]u8{0, 0, 0})
}
