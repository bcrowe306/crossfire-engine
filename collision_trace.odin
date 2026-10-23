package crossfire

import "core:log"
import "core:math"
import "core:mem"
import "core:strings"
import sdl "vendor:sdl3"

/*
Collision from images: the outline of an image's opaque pixels, traced and cut into the convex
pieces Box2D takes (at most COLLISION_POLYGON_MAX_POINTS points each), so a rock, a ship or a
platform drawn in a sprite gets a body that fits it instead of a box.

1. `Image_TraceOutlines` follows the edges of the pixels whose alpha is at least `threshold`
   (4-connected: pixels touching only at a corner are apart), keeping each region's outer
   outline (holes are ignored), simplified so no point strays more than `tolerance` pixels from
   the traced edge (Ramer-Douglas-Peucker).
2. `Polygon_ConvexPieces` cuts an outline into triangles (ear clipping) and merges neighbours
   while they stay convex and small enough (Hertel-Mehlhorn).
3. `Image_CollisionPolygons` does both, `CollisionShapes_FromTexture` makes the CollisionShape
   nodes for a texture under a body. Editors (the Crossfire Editor's "Collision from sprite")
   make the same shapes as ordinary CollisionShape nodes in the scene, so they can be edited.

Points are in pixels with y down. Results are temp allocated unless an allocator is given.
*/

/*
The outer outlines of an image's opaque regions.

Inputs:
- pixels: RGBA8 rows, `width * height * 4` bytes
- threshold: The least alpha that counts as solid (1-255)
- tolerance: How far (pixels) a simplified outline may stray from the traced edge; 0 keeps every corner

Returns:
- One outline per region (points around it, the region on the right going forward in y-down
  coordinates: a positive shoelace area), in pixel coordinates (0, 0 the image's top-left)

Example:
	// Given: pixels: []u8
	outlines := e.Image_TraceOutlines(pixels, 64, 32, threshold = 128, tolerance = 1.5)
*/
Image_TraceOutlines :: proc(pixels: []u8, width, height: int, threshold: u8 = 128, tolerance: f32 = 1.5, allocator := context.temp_allocator) -> [][][2]f32 {
	if width <= 0 || height <= 0 || len(pixels) < width * height * 4 do return nil
	solid :: proc(pixels: []u8, width, height, x, y: int, threshold: u8) -> bool {
		if x < 0 || y < 0 || x >= width || y >= height do return false
		return pixels[(y * width + x) * 4 + 3] >= max(threshold, 1)
	}
	// Every boundary edge between a solid pixel and an empty one, going with the solid on the
	// right: by its start corner (corner index y * (width + 1) + x)
	Edge :: struct { from, to: [2]int, used: bool }
	edges := make([dynamic]Edge, context.temp_allocator)
	starts := make(map[[2]int][dynamic]int, allocator = context.temp_allocator)
	add :: proc(edges: ^[dynamic]Edge, starts: ^map[[2]int][dynamic]int, from, to: [2]int) {
		append(edges, Edge{from = from, to = to})
		if from not_in starts^ do starts[from] = make([dynamic]int, context.temp_allocator)
		append(&starts[from], len(edges) - 1)
	}
	for y in 0 ..< height {
		for x in 0 ..< width {
			if !solid(pixels, width, height, x, y, threshold) do continue
			if !solid(pixels, width, height, x, y - 1, threshold) do add(&edges, &starts, {x, y}, {x + 1, y})
			if !solid(pixels, width, height, x + 1, y, threshold) do add(&edges, &starts, {x + 1, y}, {x + 1, y + 1})
			if !solid(pixels, width, height, x, y + 1, threshold) do add(&edges, &starts, {x + 1, y + 1}, {x, y + 1})
			if !solid(pixels, width, height, x - 1, y, threshold) do add(&edges, &starts, {x, y + 1}, {x, y})
		}
	}
	outlines := make([dynamic][][2]f32, allocator)
	for &first, fi in edges {
		if first.used do continue
		loop := make([dynamic][2]int, context.temp_allocator)
		current := fi
		for {
			e := &edges[current]
			e.used = true
			append(&loop, e.from)
			if e.to == first.from do break
			// At a corner two regions touch diagonally there are two ways on: turning right keeps
			// to this region (they're apart)
			dir := e.to - e.from
			next := -1
			best := 3
			for candidate in starts[e.to] {
				c := &edges[candidate]
				if c.used && candidate != fi do continue
				d := c.to - c.from
				rank := 1 // straight
				if d == ([2]int{-dir.y, dir.x}) do rank = 0 // right (y down)
				else if d == ([2]int{dir.y, -dir.x}) do rank = 2 // left
				if rank < best do best, next = rank, candidate
			}
			if next < 0 || next == fi do break
			current = next
		}
		if len(loop) < 3 do continue
		points := make([dynamic][2]f32, context.temp_allocator)
		for p in loop do append(&points, [2]f32{f32(p.x), f32(p.y)})
		// Outer outlines only (holes go the other way round)
		if polygonArea(points[:]) <= 0 do continue
		simple := simplifyClosed(dropCollinear(points[:]), tolerance)
		if len(simple) < 3 || polygonArea(simple) <= 0 do continue
		append(&outlines, sliceClone(simple, allocator))
	}
	return outlines[:]
}

/*
Cuts an outline into convex pieces of at most `max_points` points each (Box2D's polygons).

Inputs:
- outline: A simple polygon (no crossing edges), either way round
- max_points: The most points a piece may have (3-8)

Returns:
- The pieces, each going the same way as a positive-area outline; slivers under a square pixel
  are dropped
*/
Polygon_ConvexPieces :: proc(outline: [][2]f32, max_points := COLLISION_POLYGON_MAX_POINTS, allocator := context.temp_allocator) -> [][][2]f32 {
	pts := make([dynamic][2]f32, context.temp_allocator)
	append(&pts, ..outline)
	if polygonArea(pts[:]) < 0 do reversePoints(pts[:])
	clean := dropCollinear(pts[:])
	n := len(clean)
	if n < 3 do return nil
	limit := clamp(max_points, 3, COLLISION_POLYGON_MAX_POINTS)

	// Ear clipping: triangles as index triples into `clean`
	tris := make([dynamic][dynamic]int, context.temp_allocator)
	remaining := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< n do append(&remaining, i)
	for guard := 0; len(remaining) > 3 && guard < n * n; guard += 1 {
		m := len(remaining)
		clipped := false
		for k in 0 ..< m {
			a, b, c := remaining[(k + m - 1) % m], remaining[k], remaining[(k + 1) % m]
			if cross2(clean[b] - clean[a], clean[c] - clean[b]) <= 1e-6 do continue
			inside := false
			for j in remaining {
				if j == a || j == b || j == c do continue
				if pointInTriangle(clean[j], clean[a], clean[b], clean[c]) { inside = true; break }
			}
			if inside do continue
			tri := make([dynamic]int, context.temp_allocator)
			append(&tri, a, b, c)
			append(&tris, tri)
			ordered_remove(&remaining, k)
			clipped = true
			break
		}
		// A damaged outline (crossing edges): drop a point and go on rather than loop forever
		if !clipped do ordered_remove(&remaining, 0)
	}
	if len(remaining) == 3 && cross2(clean[remaining[1]] - clean[remaining[0]], clean[remaining[2]] - clean[remaining[1]]) > 1e-6 {
		tri := make([dynamic]int, context.temp_allocator)
		append(&tri, ..remaining[:])
		append(&tris, tri)
	}

	// Merge neighbours that share an edge while the result is convex and small enough
	for merged := true; merged; {
		merged = false
		outer: for i in 0 ..< len(tris) {
			for j in i + 1 ..< len(tris) {
				if joined, ok := mergeConvex(clean[:], tris[i][:], tris[j][:], limit); ok {
					tris[i] = joined
					ordered_remove(&tris, j)
					merged = true
					break outer
				}
			}
		}
	}

	pieces := make([dynamic][][2]f32, allocator)
	for poly in tris {
		piece := make([dynamic][2]f32, context.temp_allocator)
		for index in poly do append(&piece, clean[index])
		reduced := dropCollinear(piece[:])
		if len(reduced) < 3 || len(reduced) > limit || polygonArea(reduced) < 1 do continue
		append(&pieces, sliceClone(reduced, allocator))
	}
	return pieces[:]
}

/*
The convex pieces of an image's opaque regions (Image_TraceOutlines, then Polygon_ConvexPieces),
moved by `offset`: `-{width, height} / 2` centers them on the image, as a Sprite draws it.

Returns:
- The pieces (each at most COLLISION_POLYGON_MAX_POINTS points)

Example:
	// Given: pixels: []u8
	pieces := e.Image_CollisionPolygons(pixels, 64, 32, offset = {-32, -16})
*/
Image_CollisionPolygons :: proc(pixels: []u8, width, height: int, threshold: u8 = 128, tolerance: f32 = 1.5, offset: [2]f32 = {}, allocator := context.temp_allocator) -> [][][2]f32 {
	all := make([dynamic][][2]f32, allocator)
	for outline in Image_TraceOutlines(pixels, width, height, threshold, tolerance) {
		for piece in Polygon_ConvexPieces(outline, allocator = allocator) {
			for &p in piece do p += offset
			append(&all, piece)
		}
	}
	return all[:]
}

/*
Gives a body CollisionShapes that fit an image's opaque pixels, centered on its origin as a Sprite
of that image draws (scale them with the node if the sprite is scaled).

Inputs:
- body: The body (or any node: the shapes join its nearest body)
- texture: The image, a path relative to the project (an Aseprite file's first frame too)
- threshold: The least alpha that counts as solid
- tolerance: How far the outline may stray from the pixels (larger: fewer points)

Returns:
- How many shapes were made (0 when the image couldn't be read or has nothing opaque)

Example:
	// Given: rock: ^e.StaticBody
	e.CollisionShapes_FromTexture(rock, "assets/rock.png")
*/
CollisionShapes_FromTexture :: proc(body: ^Node, texture: string, threshold: u8 = 128, tolerance: f32 = 1.5) -> int {
	if body == nil || body.scene == nil do return 0
	game := body.scene.game
	full := texture
	if game != nil && game.projectDir != "" do full = JoinPath(game.projectDir, texture)
	surface := Platform_LoadSurface(full)
	if surface == nil {
		log.errorf("CollisionShapes_FromTexture: couldn't read %s", full)
		return 0
	}
	defer sdl.DestroySurface(surface)
	rgba := sdl.ConvertSurface(surface, .RGBA32)
	if rgba == nil do return 0
	defer sdl.DestroySurface(rgba)
	w, h := int(rgba.w), int(rgba.h)
	pixels := make([]u8, w * h * 4, context.temp_allocator)
	src := ([^]u8)(rgba.pixels)
	for y in 0 ..< h do mem.copy(&pixels[y * w * 4], &src[y * int(rgba.pitch)], w * 4)
	pieces := Image_CollisionPolygons(pixels, w, h, threshold, tolerance, offset = {-f32(w) / 2, -f32(h) / 2})
	for piece, i in pieces {
		shape := CreateCollisionShape(body.scene, .Polygon)
		shape.name = strings.clone(i == 0 ? "Traced" : strings.concatenate({"Traced", itoa(i + 1)}, context.temp_allocator), Node_GetAllocator(shape))
		append(&shape.points, ..piece)
		Node_AddChild(body, shape)
	}
	if Node_IsPhysicsBody(body) do PhysicsBody_RebuildShapes(cast(^PhysicsBody)body)
	return len(pieces)
}

// --- geometry --------------------------------------------------------------------------------

// The shoelace area (positive: the region on the right going forward, y down)
@(private)
polygonArea :: proc(points: [][2]f32) -> f32 {
	sum: f32
	for p, i in points {
		q := points[(i + 1) % len(points)]
		sum += p.x * q.y - q.x * p.y
	}
	return sum / 2
}

@(private="file")
cross2 :: proc(a, b: [2]f32) -> f32 {
	return a.x * b.y - a.y * b.x
}

@(private="file")
reversePoints :: proc(points: [][2]f32) {
	for i in 0 ..< len(points) / 2 do points[i], points[len(points) - 1 - i] = points[len(points) - 1 - i], points[i]
}

@(private="file")
sliceClone :: proc(points: [][2]f32, allocator: mem.Allocator) -> [][2]f32 {
	out := make([][2]f32, len(points), allocator)
	copy(out, points)
	return out
}

@(private="file")
itoa :: proc(n: int) -> string {
	buf := make([]u8, 20, context.temp_allocator)
	i := len(buf)
	v := n
	for {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 do break
	}
	return string(buf[i:])
}

// Points that don't turn (straight runs, repeats) taken out
@(private="file")
dropCollinear :: proc(points: [][2]f32) -> [][2]f32 {
	out := make([dynamic][2]f32, context.temp_allocator)
	n := len(points)
	for p, i in points {
		prev := points[(i + n - 1) % n]
		next := points[(i + 1) % n]
		if p == prev do continue
		if abs(cross2(p - prev, next - p)) < 1e-4 && math.sign(linalg_dot(p - prev, next - p)) >= 0 do continue
		append(&out, p)
	}
	return out[:]
}

@(private="file")
linalg_dot :: proc(a, b: [2]f32) -> f32 {
	return a.x * b.x + a.y * b.y
}

// Ramer-Douglas-Peucker on a closed outline: split at the point farthest from the first
@(private="file")
simplifyClosed :: proc(points: [][2]f32, tolerance: f32) -> [][2]f32 {
	n := len(points)
	if tolerance <= 0 || n < 4 do return points
	far, farDist := 0, f32(-1)
	for p, i in points {
		d := linalg_dot(p - points[0], p - points[0])
		if d > farDist do far, farDist = i, d
	}
	keep := make([]bool, n, context.temp_allocator)
	keep[0], keep[far] = true, true
	rdp :: proc(points: [][2]f32, keep: []bool, from, to: int, tolerance: f32) {
		n := len(points)
		count := (to - from + n) % n
		if count < 2 do return
		a, b := points[from], points[to]
		best, bestDist := -1, tolerance
		for k in 1 ..< count {
			i := (from + k) % n
			d := pointSegmentDistance(points[i], a, b)
			if d > bestDist do best, bestDist = i, d
		}
		if best < 0 do return
		keep[best] = true
		rdp(points, keep, from, best, tolerance)
		rdp(points, keep, best, to, tolerance)
	}
	rdp(points, keep, 0, far, tolerance)
	rdp(points, keep, far, 0, tolerance)
	out := make([dynamic][2]f32, context.temp_allocator)
	for p, i in points do if keep[i] do append(&out, p)
	return out[:]
}

@(private="file")
pointSegmentDistance :: proc(p, a, b: [2]f32) -> f32 {
	ab := b - a
	length := linalg_dot(ab, ab)
	if length == 0 do return math.sqrt(linalg_dot(p - a, p - a))
	t := clamp(linalg_dot(p - a, ab) / length, 0, 1)
	q := a + ab * t
	return math.sqrt(linalg_dot(p - q, p - q))
}

@(private="file")
pointInTriangle :: proc(p, a, b, c: [2]f32) -> bool {
	d1 := cross2(b - a, p - a)
	d2 := cross2(c - b, p - b)
	d3 := cross2(a - c, p - c)
	return d1 >= 0 && d2 >= 0 && d3 >= 0
}

// Two convex pieces sharing an edge as one, if that's convex and has at most `limit` points
@(private="file")
mergeConvex :: proc(pts: [][2]f32, p, q: []int, limit: int) -> ([dynamic]int, bool) {
	np, nq := len(p), len(q)
	for i in 0 ..< np {
		a, b := p[i], p[(i + 1) % np]
		for j in 0 ..< nq {
			if q[j] != b || q[(j + 1) % nq] != a do continue
			// p from b round to a, then q after a round to before b
			joined := make([dynamic]int, context.temp_allocator)
			for k in 0 ..< np do append(&joined, p[(i + 1 + k) % np])
			for k in 2 ..< nq do append(&joined, q[(j + k) % nq])
			corners := 0
			m := len(joined)
			for k in 0 ..< m {
				u, v, w := pts[joined[(k + m - 1) % m]], pts[joined[k]], pts[joined[(k + 1) % m]]
				turn := cross2(v - u, w - v)
				if turn < -1e-4 do return nil, false
				if turn > 1e-4 do corners += 1
			}
			if corners > limit do return nil, false
			return joined, true
		}
	}
	return nil, false
}
