#+build !js
package crossfire

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// Collision from images (collision_trace.odin): outlines of opaque pixels, convex pieces that
// cover them exactly, at most 8 points each

// An image from rows of text: '#' opaque, '.' clear, 'o' half transparent (alpha 100)
@(private="file")
art :: proc(rows: []string) -> (pixels: []u8, w, h: int) {
	h = len(rows)
	w = len(rows[0])
	pixels = make([]u8, w * h * 4, context.temp_allocator)
	for row, y in rows {
		for ch, x in row {
			a: u8 = 0
			if ch == '#' do a = 255
			if ch == 'o' do a = 100
			pixels[(y * w + x) * 4 + 3] = a
		}
	}
	return
}

@(private="file")
isConvex :: proc(piece: [][2]f32) -> bool {
	n := len(piece)
	for i in 0 ..< n {
		a, b, c := piece[i], piece[(i + 1) % n], piece[(i + 2) % n]
		if (b - a).x * (c - b).y - (b - a).y * (c - b).x < -1e-3 do return false
	}
	return true
}

// Every piece convex, at most 8 points; returns their total area
@(private="file")
checkPieces :: proc(t: ^testing.T, pieces: [][][2]f32) -> f32 {
	total: f32
	for piece in pieces {
		testing.expectf(t, len(piece) >= 3 && len(piece) <= COLLISION_POLYGON_MAX_POINTS, "3-8 points: %d", len(piece))
		testing.expectf(t, isConvex(piece), "convex: %v", piece)
		total += polygonArea(piece)
	}
	return total
}

@(test)
traced_rectangles_and_l_shapes_fit_exactly :: proc(t: ^testing.T) {
	pixels, w, h := art({
		"..........",
		".######...",
		".######...",
		".######...",
		"..........",
	})
	outlines := Image_TraceOutlines(pixels, w, h, tolerance = 0)
	testing.expect_value(t, len(outlines), 1)
	testing.expect_value(t, len(outlines[0]), 4)
	testing.expect_value(t, polygonArea(outlines[0]), f32(18))
	pieces := Polygon_ConvexPieces(outlines[0])
	testing.expect_value(t, len(pieces), 1)
	testing.expect_value(t, checkPieces(t, pieces), f32(18))

	l, lw, lh := art({
		"####....",
		"####....",
		"########",
		"########",
	})
	lpieces := Image_CollisionPolygons(l, lw, lh, tolerance = 0)
	testing.expect_value(t, checkPieces(t, lpieces), f32(24))
	testing.expect(t, len(lpieces) >= 2, "an L needs two pieces")
}

@(test)
traced_circles_stay_close_with_few_points :: proc(t: ^testing.T) {
	size :: 64
	r: f32 = 28
	pixels := make([]u8, size * size * 4, context.temp_allocator)
	for y in 0 ..< size do for x in 0 ..< size {
		dx, dy := f32(x) + 0.5 - 32, f32(y) + 0.5 - 32
		if dx * dx + dy * dy <= r * r do pixels[(y * size + x) * 4 + 3] = 255
	}
	outlines := Image_TraceOutlines(pixels, size, size, tolerance = 1.5)
	testing.expect_value(t, len(outlines), 1)
	testing.expectf(t, len(outlines[0]) < 60, "simplified: %d points", len(outlines[0]))
	pieces := Polygon_ConvexPieces(outlines[0])
	area := checkPieces(t, pieces)
	testing.expectf(t, abs(area - math.PI * r * r) / (math.PI * r * r) < 0.05, "area %v near %v", area, math.PI * r * r)
	// Centered as a sprite draws it
	centered := Image_CollisionPolygons(pixels, size, size, offset = {-32, -32})
	for piece in centered do for p in piece do testing.expect(t, abs(p.x) <= 32 && abs(p.y) <= 32, "around the origin")
}

@(test)
traced_islands_holes_and_alpha :: proc(t: ^testing.T) {
	// Two regions (and two touching only at a corner: apart), a ring (its hole ignored), faint pixels
	pixels, w, h := art({
		"##....#######",
		"##....#.....#",
		"......#.....#",
		"..#...#######",
		"...#.........",
		"oooo.........",
	})
	outlines := Image_TraceOutlines(pixels, w, h, threshold = 128, tolerance = 0)
	testing.expect_value(t, len(outlines), 4)
	total: f32
	for outline in outlines do total += checkPieces(t, Polygon_ConvexPieces(outline))
	// 4 + 1 + 1 + the ring's whole outer area 7 x 4
	testing.expect_value(t, total, f32(4 + 1 + 1 + 28))
	// A lower threshold takes the faint row too
	low := Image_TraceOutlines(pixels, w, h, threshold = 50, tolerance = 0)
	testing.expect(t, len(low) > len(outlines) - 1, "the faint row counts")
}

@(test)
traced_combs_split_into_small_convex_pieces :: proc(t: ^testing.T) {
	pixels, w, h := art({
		"#.#.#.#.#.#",
		"#.#.#.#.#.#",
		"###########",
	})
	pieces := Image_CollisionPolygons(pixels, w, h, tolerance = 0)
	area := checkPieces(t, pieces)
	testing.expect_value(t, area, f32(6 * 2 + 11))
}

@(test)
collision_shapes_from_a_texture :: proc(t: ^testing.T) {
	dir := "testdata_trace"
	os.make_directory(dir)
	defer os.remove_all(dir)
	surface := sdl.CreateSurface(20, 10, .RGBA32)
	defer sdl.DestroySurface(surface)
	px := ([^]u8)(surface.pixels)
	for y in 0 ..< 10 do for x in 0 ..< 20 {
		// An L: the left half full height, the bottom half full width
		if x < 10 || y >= 5 do px[y * int(surface.pitch) + x * 4 + 3] = 255
	}
	testing.expect(t, sdl.SaveBMP(surface, "testdata_trace/l.bmp"), "saved")

	game := testGame(dir)
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	body := CreateStaticBody(scene)
	count := CollisionShapes_FromTexture(body, "l.bmp", tolerance = 0)
	testing.expect(t, count >= 2, "an L needs two pieces")
	area: f32
	for child in body.children {
		shape := cast(^CollisionShape)child
		testing.expect(t, Node_Is(child, CollisionShape) && shape.shape == .Polygon && strings.has_prefix(shape.name, "Traced"), "traced polygons")
		area += polygonArea(shape.points[:])
		for p in shape.points do testing.expect(t, p.x >= -10 && p.x <= 10 && p.y >= -5 && p.y <= 5, "centered")
	}
	testing.expect_value(t, area, f32(150))
}
