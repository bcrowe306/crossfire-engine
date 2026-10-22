package crossfire

import "core:c"
import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

/*
Lines and trails: thick polylines drawn as triangles (one geometry call each).

- **Line2D** nodes draw a line through their points (the node's space; `points="0,0 100,20"` in
  scene files, `Line2D_SetPoints` / `AddPoint` from code): ropes, lasers, paths, outlines. A width,
  a color fading to `endColor` along it, joints (sharp, clamped to `LINE_MITER_LIMIT` widths, or
  round), round caps, closed loops, and an optional texture stretched along it or tiled every
  `width` pixels.
- **Trail2D** nodes leave a ribbon behind their parent as it moves (swords, dashes, comets, tire
  tracks): they record the parent's world position as it moves at least `minDistance`, forget
  points older than `lifetime`, and draw them in the world, from `width` / `color` at the newest
  point to `endWidth` / `endColor` at the oldest. `emitting` off stops adding points (the trail
  fades away); `Trail2D_Clear` empties it (after a teleport).

Both draw through a node's shader (shaders.odin) when they have a texture.

Example:
	laser := e.CreateLine2D(scene, {{0, 0}, {400, 0}})
	laser.settings.width = 6
	laser.settings.color = {255, 60, 60, 255}
	laser.settings.endColor = {255, 60, 60, 0}
	trail := e.CreateTrail2D(scene)
	e.Node_AddChild(sword, trail)
*/

// How a line's corners are drawn
LineJoint :: enum {
	// Pointed (a miter), cut at LINE_MITER_LIMIT widths
	Sharp,
	// Rounded
	Round,
}

// How a line's texture covers it
LineTextureMode :: enum {
	// Once along the whole line
	Stretch,
	// Repeated every `width` pixels of length
	Tile,
}

// A Line2D's or Trail2D's look (scene files' attributes; a plain value)
LineSettings :: struct {
	// Thickness in pixels (a trail's at its newest point)
	width: f32,
	// A trail's thickness at its oldest point (lines: unused)
	endWidth: f32,
	// The color at the start (a trail's newest point) and at the end, blended along the length
	color, endColor: sdl.Color,
	// Corners and ends
	joint: LineJoint,
	roundCaps: bool,
	// A Line2D joins its last point to its first
	closed: bool,
	// How a texture (the node's `texture`) covers it
	textureMode: LineTextureMode,
	// Trail2D: seconds a point lasts; the distance the parent must move to add one; adding points
	lifetime: f32,
	minDistance: f32,
	emitting: bool,
}

// A line's defaults (a trail's too)
DEFAULT_LINE_SETTINGS :: LineSettings{width = 4, endWidth = 0, color = {255, 255, 255, 255}, endColor = {255, 255, 255, 255}, lifetime = 0.4, minDistance = 4, emitting = true}

// How far a sharp corner may stick out, in widths (sharper corners are cut flat)
LINE_MITER_LIMIT :: 2

// A line through points
Line2D :: struct {
	using node: Node,
	settings: LineSettings,
	// The points, in the node's space (the node's arena)
	points: [dynamic][2]f32,
	// Drawn along it (nil: plain color)
	texture: ^sdl.Texture,
}

// A ribbon left behind its parent
Trail2D :: struct {
	using node: Node,
	settings: LineSettings,
	// The points (world space), newest last, with the time each was added; the parent's position
	// now (the trail's head, drawn after the newest point)
	points: [dynamic]TrailPoint,
	head: [2]f32,
	// Seconds since it started (points' clock)
	clock: f32,
	texture: ^sdl.Texture,
}

// One of a trail's points
TrailPoint :: struct {
	position: [2]f32,
	time: f32,
}

/*
Creates a Line2D and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- points: Its points, in its own space (copied)
- settings: Its look

Returns:
- The line
*/
CreateLine2D :: proc(scene: ^Scene, points: [][2]f32 = nil, settings := DEFAULT_LINE_SETTINGS) -> ^Line2D {
	l := CreateNode(scene, Line2D)
	l.settings = settings
	l.points = make([dynamic][2]f32, Node_GetAllocator(l))
	append(&l.points, ..points)
	l.draw = line2DDraw
	l.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
		l := cast(^Line2D)node
		if len(l.points) == 0 do return {}, false
		lo, hi := l.points[0], l.points[0]
		for p in l.points {
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x), max(hi.y, p.y)}
		}
		w := l.settings.width * 0.5
		return {lo.x - w, lo.y - w, hi.x - lo.x + w * 2, hi.y - lo.y + w * 2}, true
	}
	return l
}

// Replaces a line's points (copied)
Line2D_SetPoints :: proc(line: ^Line2D, points: [][2]f32) {
	clear(&line.points)
	append(&line.points, ..points)
}

// Adds a point at the end of a line
Line2D_AddPoint :: proc(line: ^Line2D, point: [2]f32) {
	append(&line.points, point)
}

// Removes a line's points
Line2D_Clear :: proc(line: ^Line2D) {
	clear(&line.points)
}

/*
Creates a Trail2D and adds it to the scene (at the start of the next update). Make it a child
of what leaves the trail.

Inputs:
- scene: The scene
- settings: Its look and how long points last

Returns:
- The trail
*/
CreateTrail2D :: proc(scene: ^Scene, settings := DEFAULT_LINE_SETTINGS) -> ^Trail2D {
	t := CreateNode(scene, Trail2D)
	t.settings = settings
	t.points = make([dynamic]TrailPoint, Node_GetAllocator(t))
	t.update = trail2DUpdate
	t.draw = trail2DDraw
	return t
}

// Forgets a trail's points (after a teleport: no streak across the screen)
Trail2D_Clear :: proc(trail: ^Trail2D) {
	clear(&trail.points)
}

// Starts or stops adding points (stopped, the trail fades away as its points age)
Trail2D_SetEmitting :: proc(trail: ^Trail2D, emitting: bool) {
	trail.settings.emitting = emitting
}

/*
A thick polyline's triangles: `points` in screen space, each with its width and color, and its
`u` along the line (texture coordinates). Closed lines join the last point to the first.

Inputs:
- points, widths, colors, us: Per point (same length)
- joint, roundCaps, closed: The look
- vertices, indices: Appended to
*/
Line_Geometry :: proc(points: [][2]f32, widths: []f32, colors: []sdl.FColor, us: []f32, joint: LineJoint, roundCaps, closed: bool, vertices: ^[dynamic]sdl.Vertex, indices: ^[dynamic]c.int) {
	n := len(points)
	if n < 2 do return
	segments := closed ? n : n - 1
	dir :: proc(a, b: [2]f32) -> [2]f32 {
		d := b - a
		l := linalg.length(d)
		return l > 1e-6 ? d / l : {1, 0}
	}
	normal :: proc(d: [2]f32) -> [2]f32 { return {-d.y, d.x} }
	vertex :: proc(p: [2]f32, color: sdl.FColor, u, v: f32) -> sdl.Vertex {
		return {position = {p.x, p.y}, color = color, tex_coord = {u, v}}
	}
	// Round joints and caps: a fan from `from` to `to` bulging toward `through`
	fan :: proc(center: [2]f32, from, to, through: [2]f32, radius: f32, color: sdl.FColor, u: f32, vertices: ^[dynamic]sdl.Vertex, indices: ^[dynamic]c.int) {
		a0 := math.atan2(from.y, from.x)
		a1 := math.atan2(to.y, to.x)
		sweep := a1 - a0
		for sweep > math.PI do sweep -= math.TAU
		for sweep < -math.PI do sweep += math.TAU
		// The other way round when the short way doesn't pass `through` (a cap's half turn)
		mid := a0 + sweep * 0.5
		if math.cos(mid) * through.x + math.sin(mid) * through.y < 0 do sweep -= math.TAU * math.sign(sweep)
		steps := clamp(int(abs(sweep) * radius / 3), 2, 24)
		c0 := c.int(len(vertices))
		append(vertices, sdl.Vertex{position = {center.x, center.y}, color = color, tex_coord = {u, 0.5}})
		for k in 0 ..= steps {
			a := a0 + sweep * f32(k) / f32(steps)
			p := center + [2]f32{math.cos(a), math.sin(a)} * radius
			append(vertices, sdl.Vertex{position = {p.x, p.y}, color = color, tex_coord = {u, 0.5}})
		}
		for k in 0 ..< steps do append(indices, c0, c0 + 1 + c.int(k), c0 + 2 + c.int(k))
	}
	if joint == .Round {
		// Each segment its own quad, and a fan on the outer side of each turn
		for s in 0 ..< segments {
			a, b := s, (s + 1) % n
			nrm := normal(dir(points[a], points[b]))
			q := c.int(len(vertices))
			append(vertices,
				vertex(points[a] + nrm * widths[a] * 0.5, colors[a], us[a], 0), vertex(points[a] - nrm * widths[a] * 0.5, colors[a], us[a], 1),
				vertex(points[b] + nrm * widths[b] * 0.5, colors[b], us[b], 0), vertex(points[b] - nrm * widths[b] * 0.5, colors[b], us[b], 1))
			append(indices, q, q + 2, q + 1, q + 1, q + 2, q + 3)
		}
		for i in 0 ..< n {
			if !closed && (i == 0 || i == n - 1) do continue
			prev := (i + n - 1) % n
			next := (i + 1) % n
			dIn, dOut := dir(points[prev], points[i]), dir(points[i], points[next])
			nIn, nOut := normal(dIn), normal(dOut)
			// Turning toward its normals' side: the outer side is the other one
			side: f32 = dIn.x * dOut.y - dIn.y * dOut.x > 0 ? -1 : 1
			fan(points[i], nIn * side, nOut * side, (nIn + nOut) * side, widths[i] * 0.5, colors[i], us[i], vertices, indices)
		}
	} else {
		// Each point's two edge vertices: offsets along the miter of its segments' normals, cut at
		// the limit
		first := c.int(len(vertices))
		for i in 0 ..< n {
			prev := closed ? (i + n - 1) % n : max(i - 1, 0)
			next := closed ? (i + 1) % n : min(i + 1, n - 1)
			dIn := dir(points[prev], points[i])
			dOut := dir(points[i], points[next])
			if !closed && i == 0 do dIn = dOut
			if !closed && i == n - 1 do dOut = dIn
			nIn, nOut := normal(dIn), normal(dOut)
			half := widths[i] * 0.5
			miter := nIn + nOut
			ml := linalg.length(miter)
			offset := nOut * half
			if ml >= 1e-6 {
				miter /= ml
				offset = miter * min(half / max(linalg.dot(miter, nOut), 1e-3), half * LINE_MITER_LIMIT)
			}
			append(vertices, vertex(points[i] + offset, colors[i], us[i], 0), vertex(points[i] - offset, colors[i], us[i], 1))
		}
		for s in 0 ..< segments {
			a := first + c.int(s * 2)
			b := first + c.int(((s + 1) % n) * 2)
			append(indices, a, b, a + 1, a + 1, b, b + 1)
		}
	}
	if roundCaps && !closed {
		d0 := dir(points[0], points[1])
		fan(points[0], normal(d0), -normal(d0), -d0, widths[0] * 0.5, colors[0], us[0], vertices, indices)
		d1 := dir(points[n - 2], points[n - 1])
		fan(points[n - 1], -normal(d1), normal(d1), d1, widths[n - 1] * 0.5, colors[n - 1], us[n - 1], vertices, indices)
	}
}

// INTERNAL

@(private="file")
toF :: proc(color: sdl.Color) -> sdl.FColor {
	return {f32(color.r) / 255, f32(color.g) / 255, f32(color.b) / 255, f32(color.a) / 255}
}

@(private="file")
blend :: proc(a, b: sdl.Color, t: f32) -> sdl.Color {
	mixc :: proc(x, y: u8, t: f32) -> u8 { return u8(clamp(f32(x) + (f32(y) - f32(x)) * t + 0.5, 0, 255)) }
	return {mixc(a.r, b.r, t), mixc(a.g, b.g, t), mixc(a.b, b.b, t), mixc(a.a, b.a, t)}
}

// Draws a polyline through the draw transform: widths in the node's units (scaled with it)
@(private="file")
drawPolyline :: proc(renderer: ^sdl.Renderer, points: [][2]f32, widths: []f32, colors: []sdl.Color, s: LineSettings, closed: bool, texture: ^sdl.Texture, view: Transform2D) {
	n := len(points)
	if n < 2 || renderer == nil do return
	scale := Transform2D_UniformScale(view)
	tint := drawState().tint
	screen := make([][2]f32, n, context.temp_allocator)
	w := make([]f32, n, context.temp_allocator)
	fc := make([]sdl.FColor, n, context.temp_allocator)
	us := make([]f32, n, context.temp_allocator)
	total: f32
	for i in 0 ..< n {
		screen[i] = Transform2D_Apply(view, points[i])
		w[i] = max(widths[i] * scale, 1)
		fc[i] = toF(multiplyColor(colors[i], tint))
		if i > 0 do total += linalg.length(points[i] - points[i - 1])
		us[i] = total
	}
	// Texture coordinates: once along it, or every `width` of length
	for i in 0 ..< n {
		switch s.textureMode {
		case .Stretch: us[i] = total > 0 ? us[i] / total : 0
		case .Tile:    us[i] = us[i] / max(s.width, 1)
		}
	}
	vertices := make([dynamic]sdl.Vertex, 0, n * 2 + 16, context.temp_allocator)
	indices := make([dynamic]c.int, 0, n * 6 + 32, context.temp_allocator)
	Line_Geometry(screen, w, fc, us, s.joint, s.roundCaps, closed, &vertices, &indices)
	if len(indices) == 0 do return
	if texture != nil {
		sdl.SetTextureBlendMode(texture, GetDrawBlend())
		if s.textureMode == .Tile do _ = sdl.SetRenderTextureAddressMode(renderer, .WRAP, .CLAMP)
		on := shaderDrawBegin(renderer, {f32(texture.w), f32(texture.h)})
		sdl.RenderGeometry(renderer, texture, raw_data(vertices), c.int(len(vertices)), raw_data(indices), c.int(len(indices)))
		shaderDrawEnd(renderer, on)
		if s.textureMode == .Tile do _ = sdl.SetRenderTextureAddressMode(renderer, .AUTO, .AUTO)
	} else {
		sdl.RenderGeometry(renderer, nil, raw_data(vertices), c.int(len(vertices)), raw_data(indices), c.int(len(indices)))
	}
}

@(private="file")
line2DDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	l := cast(^Line2D)node
	n := len(l.points)
	if n < 2 do return
	widths := make([]f32, n, context.temp_allocator)
	colors := make([]sdl.Color, n, context.temp_allocator)
	for i in 0 ..< n {
		t := f32(i) / f32(n - 1)
		widths[i] = l.settings.width
		colors[i] = blend(l.settings.color, l.settings.endColor, t)
	}
	drawPolyline(renderer, l.points[:], widths, colors, l.settings, l.settings.closed, l.texture, drawState().transform)
}

@(private="file")
trail2DUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	t := cast(^Trail2D)node
	t.clock += f32(deltaTime)
	// Points older than the lifetime go
	keep := 0
	for p in t.points do if t.clock - p.time < t.settings.lifetime {
		t.points[keep] = p
		keep += 1
	}
	resize(&t.points, keep)
	if !t.settings.emitting do return
	// The parent's world position (the trail's own when it has none): a point each time it has
	// moved minDistance from the last one; the head follows it between points
	at := Node_GetWorldPosition(t.parent != nil ? t.parent : t)
	t.head = at
	if len(t.points) == 0 || linalg.length(at - t.points[len(t.points) - 1].position) >= max(t.settings.minDistance, 0.1) {
		append(&t.points, TrailPoint{at, t.clock})
	}
}

@(private="file")
trail2DDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	t := cast(^Trail2D)node
	// The recorded points, and the head when emitting and it has moved past the newest
	n := len(t.points)
	withHead := t.settings.emitting && n > 0 && t.head != t.points[n - 1].position
	if withHead do n += 1
	if n < 2 do return
	// World space: the draw transform without the node's own
	world := Node_GetRenderWorldTransform(node)
	if abs(world.x.x * world.y.y - world.y.x * world.x.y) < 1e-12 do return
	view := Transform2D_Multiply(drawState().transform, Transform2D_Inverse(world))
	points := make([][2]f32, n, context.temp_allocator)
	widths := make([]f32, n, context.temp_allocator)
	colors := make([]sdl.Color, n, context.temp_allocator)
	s := t.settings
	life := max(s.lifetime, 0.0001)
	// Newest first: from width / color to endWidth / endColor by age
	for i in 0 ..< n {
		// Newest first: the head, then the recorded points from the newest
		recorded := withHead ? i - 1 : i
		p := recorded < 0 ? TrailPoint{t.head, t.clock} : t.points[len(t.points) - 1 - recorded]
		age := clamp((t.clock - p.time) / life, 0, 1)
		points[i] = p.position
		widths[i] = s.width + (s.endWidth - s.width) * age
		colors[i] = blend(s.color, s.endColor, age)
	}
	drawPolyline(renderer, points, widths, colors, s, false, t.texture, view)
}
