#+build !js
package crossfire

import "core:c"
import "core:testing"
import sdl "vendor:sdl3"

// Lines and trails (lines.odin): geometry, a line's pixels (width, gradient, round caps), a
// trail following its parent and fading out, scene files

@(test)
line_geometry_joints_and_caps :: proc(t: ^testing.T) {
	vertices := make([dynamic]sdl.Vertex, context.temp_allocator)
	indices := make([dynamic]c.int, context.temp_allocator)
	white := sdl.FColor{1, 1, 1, 1}
	// Three points, a right angle: two edge vertices a point, two triangles a segment
	points := [][2]f32{{0, 0}, {10, 0}, {10, 10}}
	widths := []f32{2, 2, 2}
	colors := []sdl.FColor{white, white, white}
	us := []f32{0, 0.5, 1}
	Line_Geometry(points, widths, colors, us, .Sharp, false, false, &vertices, &indices)
	testing.expect_value(t, len(vertices), 6)
	testing.expect_value(t, len(indices), 12)
	// The corner's miter: 1 / cos(45°) of the half width, out at (11, -1) and in at (9, 1)
	corner := [2]f32{vertices[2].position.x, vertices[2].position.y}
	other := [2]f32{vertices[3].position.x, vertices[3].position.y}
	near :: proc(a, b: [2]f32) -> bool { return abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 }
	testing.expectf(t, (near(corner, {11, -1}) && near(other, {9, 1})) || (near(corner, {9, 1}) && near(other, {11, -1})), "the miter: %v %v", corner, other)
	// Round joints and caps add fans; closed adds the last segment
	clear(&vertices); clear(&indices)
	Line_Geometry(points, widths, colors, us, .Round, true, false, &vertices, &indices)
	testing.expect(t, len(vertices) > 6 && len(indices) > 12, "fans")
	clear(&vertices); clear(&indices)
	Line_Geometry(points, widths, colors, us, .Sharp, false, true, &vertices, &indices)
	testing.expect_value(t, len(indices), 18)
	// A hairpin turn stays within the miter limit
	clear(&vertices); clear(&indices)
	Line_Geometry([][2]f32{{0, 0}, {10, 0}, {0, 0.1}}, widths, colors, us, .Sharp, false, false, &vertices, &indices)
	for v in vertices do testing.expectf(t, v.position.x < 10 + LINE_MITER_LIMIT * 2, "limited: %v", v.position)
}

@(test)
lines_draw_and_trails_follow :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(100, 40, .ARGB8888)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.renderer = renderer
	scene := game->createScene("S")
	data, err := ParseScene(`<scene formatVersion="13">
	<node name="Laser" kind="Line2D" points="10,20 90,20" lineWidth="10" lineColor="#ff0000" endColor="#0000ff" roundCaps="true"/>
	<node name="Ship" kind="Node2D" x="0" y="0"><node name="Trail" kind="Trail2D" lineWidth="6" endWidth="0" lifetime="0.5" minDistance="5"/></node>
</scene>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, data.nodes[0].line.width, 10)
	testing.expect_value(t, data.nodes[0].line.endColor, sdl.Color{0, 0, 255, 255})
	testing.expect(t, data.nodes[0].line.roundCaps, "round caps")
	testing.expect_value(t, len(data.nodes[0].points), 2)
	testing.expect_value(t, data.nodes[2].line.lifetime, 0.5)
	_ = Scene_Build(scene, &data, "testdata")
	Scene_Update(scene, nil, 0)
	laser := cast(^Line2D)Scene_FindNode(scene, "Laser")
	testing.expect(t, laser != nil && len(laser.points) == 2, "built")
	bounds, ok := Node_GetLocalBounds(laser)
	testing.expect(t, ok && bounds == {5, 15, 90, 10}, "bounds: its points and half its width")

	// Its pixels: red at the start, blue at the end, the width, nothing past it
	trail := cast(^Trail2D)Scene_FindNode(scene, "Trail")
	trail.visible = false
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	sdl.RenderPresent(renderer)
	px :: proc(s: ^sdl.Surface, x, y: int) -> u32 { return (cast([^]u32)s.pixels)[y * int(s.pitch / 4) + x] }
	start, end := px(surface, 12, 20), px(surface, 88, 20)
	testing.expectf(t, (start >> 16) & 0xff > 200 && start & 0xff < 60, "red at the start: %08x", start)
	testing.expectf(t, end & 0xff > 200 && (end >> 16) & 0xff < 60, "blue at the end: %08x", end)
	testing.expectf(t, px(surface, 50, 16) & 0xffffff != 0, "4 px off the middle is inside: %08x", px(surface, 50, 16))
	testing.expectf(t, px(surface, 50, 10) & 0xffffff == 0, "10 px off is outside: %08x", px(surface, 50, 10))
	testing.expectf(t, px(surface, 7, 20) & 0xffffff != 0, "the round cap reaches past the start: %08x", px(surface, 7, 20))
	// From code
	Line2D_SetPoints(laser, {{0, 0}, {5, 5}, {10, 0}})
	Line2D_AddPoint(laser, {20, 20})
	testing.expect_value(t, len(laser.points), 4)
	Line2D_Clear(laser)
	testing.expect_value(t, len(laser.points), 0)

	// The trail: a point each time its parent has moved minDistance; old ones go
	ship := Scene_FindNode(scene, "Ship")
	for i in 0 ..< 10 {
		ship.position = {f32(i) * 3, 0}
		Scene_Update(scene, nil, 0.05)
	}
	// 27 px in 3 px steps: a point every 6 px (the first move of 5 px or more), the head on the ship
	testing.expectf(t, len(trail.points) >= 4 && len(trail.points) <= 6, "points: %d", len(trail.points))
	testing.expect_value(t, trail.head, [2]f32{27, 0})
	// Stopped: no new points; the old ones age out
	Trail2D_SetEmitting(trail, false)
	ship.position = {100, 0}
	Scene_Update(scene, nil, 0.3)
	testing.expect(t, len(trail.points) < 7, "older points gone")
	Scene_Update(scene, nil, 0.6)
	testing.expect_value(t, len(trail.points), 0)
	// Again, then cleared at once
	Trail2D_SetEmitting(trail, true)
	Scene_Update(scene, nil, 0.05)
	ship.position = {120, 0}
	Scene_Update(scene, nil, 0.05)
	testing.expect(t, len(trail.points) >= 2, "a trail again")
	trail.visible = true
	sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	Trail2D_Clear(trail)
	testing.expect_value(t, len(trail.points), 0)
}
