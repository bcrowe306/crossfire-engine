package engine


import "core:c"
import "core:math"
import sdl "vendor:sdl3"

// SDL PRIMITIVE HELPERS
//
// Positions and sizes are in the drawing node's local coordinates. While a scene draws a node,
// they are transformed by the node's world transform and the camera (see GetDrawTransform), and
// colors are multiplied by the node's inherited tint. Outside of scene drawing nothing is
// transformed. 1px lines (DrawLine, *Outline) stay 1px wide at any scale.

// Upper bound on segments used to approximate curves (circles, ellipses, arcs)
MAX_CURVE_SEGMENTS :: 128
// Segments used per corner of a rounded rectangle
ROUNDED_CORNER_SEGMENTS :: 8
// Perimeter points of a rounded rectangle (four corners of ROUNDED_CORNER_SEGMENTS + 1 points)
ROUNDED_RECT_POINT_COUNT :: 4 * (ROUNDED_CORNER_SEGMENTS + 1)

/*
Draws a filled rectangle.

A rotated draw transform draws it as a rotated quad.

Inputs:
- renderer: The renderer to draw with
- rect: The rectangle, in local coordinates (x, y is its top-left corner)
- color: The color (multiplied by the node's tint)

Example:
	rect := sdl.FRect{10, 10, 200, 40}
	e.DrawRectangle(renderer, &rect, {40, 40, 60, 255})
*/
DrawRectangle :: proc(renderer: ^ sdl.Renderer, rect: ^sdl.FRect, color: sdl.Color) {
	if Transform2D_IsAxisAligned(drawState().transform) {
		color := tinted(color)
		screen := screenRect(rect)
		sdl.SetRenderDrawColor(renderer, color[0], color[1], color[2], color[3])
		sdl.RenderFillRect(renderer, &screen)
		return
	}
	// Rotation can turn the rectangle into any quad (fillScreenPolygon applies the tint)
	corners := rectCorners(rect)
	toScreenPoints(corners[:])
	fillScreenPolygon(renderer, corners[:], color)
}

/*
Draws a rectangle's 1-pixel outline.

Inputs:
- renderer: The renderer to draw with
- rect: The rectangle, in local coordinates (x, y is its top-left corner)
- color: The color (multiplied by the node's tint)
*/
DrawRectangleOutline :: proc(renderer: ^sdl.Renderer, rect: ^sdl.FRect, color: sdl.Color) {
	if Transform2D_IsAxisAligned(drawState().transform) {
		color := tinted(color)
		screen := screenRect(rect)
		sdl.SetRenderDrawColor(renderer, color[0], color[1], color[2], color[3])
		sdl.RenderRect(renderer, &screen)
		return
	}
	corners := rectCorners(rect)
	toScreenPoints(corners[:])
	strokeScreenPolygon(renderer, corners[:], color)
}

/*
Draws a single pixel.

Inputs:
- renderer: The renderer to draw with
- p: The point, in local coordinates
- color: The color (multiplied by the node's tint)
*/
DrawPoint :: proc(renderer: ^sdl.Renderer, p: sdl.FPoint, color: sdl.Color) {
	p, color := tp(p), tinted(color)
	sdl.SetRenderDrawColor(renderer, color[0], color[1], color[2], color[3])
	sdl.RenderPoint(renderer, p.x, p.y)
}

/*
Draws a 1-pixel line (1 pixel wide at any scale; `DrawLineThick` for wider lines).

Inputs:
- renderer: The renderer to draw with
- a: The start, in local coordinates
- b: The end, in local coordinates
- color: The color (multiplied by the node's tint)

Example:
	e.DrawLine(renderer, {0, 0}, {100, 50}, {255, 255, 255, 255})
*/
DrawLine :: proc(renderer: ^sdl.Renderer, a, b: sdl.FPoint, color: sdl.Color) {
	a, b := tp(a), tp(b)
	color := tinted(color)
	sdl.SetRenderDrawColor(renderer, color[0], color[1], color[2], color[3])
	sdl.RenderLine(renderer, a.x, a.y, b.x, b.y)
}

/*
Draws a line with a thickness, as a quad. The thickness scales with the node's scale and the
camera's zoom. Nothing is drawn when `a` and `b` are the same point.

Inputs:
- renderer: The renderer to draw with
- a: The start, in local coordinates
- b: The end, in local coordinates
- thickness: The width, in local units
- color: The color (multiplied by the node's tint)
*/
DrawLineThick :: proc(renderer: ^sdl.Renderer, a, b: sdl.FPoint, thickness: f32, color: sdl.Color) {
	a, b := tp(a), tp(b)
	thickness := toScreenLength(thickness)

	dir := b - a
	length := math.sqrt(dir.x * dir.x + dir.y * dir.y)
	if length == 0 do return

	// Perpendicular offset of half the thickness
	n := sdl.FPoint{-dir.y, dir.x} * (thickness * 0.5 / length)
	quad := [4]sdl.FPoint{a + n, b + n, b - n, a - n}
	fillScreenPolygon(renderer, quad[:], color)
}

/*
Draws a filled triangle.

Inputs:
- renderer: The renderer to draw with
- a: The first corner, in local coordinates
- b: The second corner
- c: The third corner
- color: The color (multiplied by the node's tint)
*/
DrawTriangle :: proc(renderer: ^sdl.Renderer, a, b, c: sdl.FPoint, color: sdl.Color) {
	points := [3]sdl.FPoint{tp(a), tp(b), tp(c)}
	fillScreenPolygon(renderer, points[:], color)
}

/*
Draws a triangle's 1-pixel outline.

Inputs:
- renderer: The renderer to draw with
- a: The first corner, in local coordinates
- b: The second corner
- c: The third corner
- color: The color (multiplied by the node's tint)
*/
DrawTriangleOutline :: proc(renderer: ^sdl.Renderer, a, b, c: sdl.FPoint, color: sdl.Color) {
	points := [3]sdl.FPoint{tp(a), tp(b), tp(c)}
	strokeScreenPolygon(renderer, points[:], color)
}

/*
Draws a filled circle (a polygon with more segments the larger it is on screen).

Inputs:
- renderer: The renderer to draw with
- center: The center, in local coordinates
- radius: The radius, in local units
- color: The color (multiplied by the node's tint)

Example:
	e.DrawCircle(renderer, {0, 0}, 16, {120, 200, 255, 255})
*/
DrawCircle :: proc(renderer: ^sdl.Renderer, center: sdl.FPoint, radius: f32, color: sdl.Color) {
	DrawEllipse(renderer, center, radius, radius, color)
}

/*
Draws a circle's 1-pixel outline.

Inputs:
- renderer: The renderer to draw with
- center: The center, in local coordinates
- radius: The radius, in local units
- color: The color (multiplied by the node's tint)
*/
DrawCircleOutline :: proc(renderer: ^sdl.Renderer, center: sdl.FPoint, radius: f32, color: sdl.Color) {
	DrawEllipseOutline(renderer, center, radius, radius, color)
}

/*
Draws a filled ellipse, its axes along the local x and y axes.

Inputs:
- renderer: The renderer to draw with
- center: The center, in local coordinates
- rx: The horizontal radius, in local units
- ry: The vertical radius, in local units
- color: The color (multiplied by the node's tint)
*/
DrawEllipse :: proc(renderer: ^sdl.Renderer, center: sdl.FPoint, rx, ry: f32, color: sdl.Color) {
	points := ellipsePoints(center, rx, ry)
	fillScreenPolygon(renderer, points, color)
}

/*
Draws an ellipse's 1-pixel outline, its axes along the local x and y axes.

Inputs:
- renderer: The renderer to draw with
- center: The center, in local coordinates
- rx: The horizontal radius, in local units
- ry: The vertical radius, in local units
- color: The color (multiplied by the node's tint)
*/
DrawEllipseOutline :: proc(renderer: ^sdl.Renderer, center: sdl.FPoint, rx, ry: f32, color: sdl.Color) {
	points := ellipsePoints(center, rx, ry)
	strokeScreenPolygon(renderer, points, color)
}

/*
Draws a filled convex polygon (filled as a triangle fan from the first point; concave shapes
draw wrong).

Inputs:
- renderer: The renderer to draw with
- points: The corners in order, in local coordinates (at least 3). Not modified
- color: The color (multiplied by the node's tint)

Example:
	points := []sdl.FPoint{{0, -20}, {15, 15}, {-15, 15}}
	e.DrawPolygon(renderer, points, {255, 200, 0, 255})
*/
DrawPolygon :: proc(renderer: ^sdl.Renderer, points: []sdl.FPoint, color: sdl.Color) {
	fillScreenPolygon(renderer, transformedCopy(points), color)
}

/*
Draws a closed 1-pixel outline through the points (the last joins the first).

Inputs:
- renderer: The renderer to draw with
- points: The corners in order, in local coordinates (at least 2). Not modified
- color: The color (multiplied by the node's tint)
*/
DrawPolygonOutline :: proc(renderer: ^sdl.Renderer, points: []sdl.FPoint, color: sdl.Color) {
	strokeScreenPolygon(renderer, transformedCopy(points), color)
}

/*
Draws a filled rectangle with rounded corners.

Inputs:
- renderer: The renderer to draw with
- rect: The rectangle, in local coordinates (x, y is its top-left corner)
- radius: The corners' radius, in local units (clamped to half the shorter side)
- color: The color (multiplied by the node's tint)

Example:
	button := sdl.FRect{20, 20, 160, 48}
	e.DrawRoundedRectangle(renderer, &button, 8, {60, 60, 90, 255})
*/
DrawRoundedRectangle :: proc(renderer: ^sdl.Renderer, rect: ^sdl.FRect, radius: f32, color: sdl.Color) {
	points := RoundedRectanglePoints(rect, radius)
	toScreenPoints(points[:])
	fillScreenPolygon(renderer, points[:], color)
}

/*
Draws the 1-pixel outline of a rectangle with rounded corners.

Inputs:
- renderer: The renderer to draw with
- rect: The rectangle, in local coordinates (x, y is its top-left corner)
- radius: The corners' radius, in local units (clamped to half the shorter side)
- color: The color (multiplied by the node's tint)
*/
DrawRoundedRectangleOutline :: proc(renderer: ^sdl.Renderer, rect: ^sdl.FRect, radius: f32, color: sdl.Color) {
	points := RoundedRectanglePoints(rect, radius)
	toScreenPoints(points[:])
	strokeScreenPolygon(renderer, points[:], color)
}

/*
Draws a texture (or part of one) into a rectangle, with optional rotation, tint and flip.

`dest` is in the drawing node's local coordinates; the node's world transform and the camera
move, scale and rotate the texture. Prefer this over `sdl.RenderTexture`, which bypasses them.

Inputs:
- renderer: The renderer to draw with
- texture: The texture to draw. Nothing is drawn if nil
- dest: Where to draw, as a rectangle in local coordinates
- rotation: Degrees, clockwise around the center of `dest`
- src: Part of the texture to draw, in texture pixels (e.g. one sprite sheet frame). nil draws the whole texture
- tint: Multiplies the texture's colors and alpha. White leaves it unchanged
- flip: Mirror the texture horizontally and/or vertically (a draw transform with a negative scale,
  like a sprite node with scale.x -1, mirrors it too)

Example:
	// Given: rm: ^e.ResourceManager, pos: [2]f32, heading: f32, sheet: ^sdl.Texture, x: f32, y: f32
	ship := rm->loadTexture("ship.png")
	e.DrawTexture(renderer, ship, {pos.x, pos.y, 64, 64}, rotation = heading)

	// Second 32x32 frame of a sprite sheet, faded to half transparency
	e.DrawTexture(renderer, sheet, {x, y, 32, 32}, src = sdl.FRect{32, 0, 32, 32}, tint = {255, 255, 255, 128})
*/
DrawTexture :: proc(
	renderer: ^sdl.Renderer,
	texture: ^sdl.Texture,
	dest: sdl.FRect,
	rotation: f32 = 0,
	src: Maybe(sdl.FRect) = nil,
	tint := sdl.Color{255, 255, 255, 255},
	flip := sdl.FlipMode.NONE,
) {
	if texture == nil do return

	center := tp({dest.x + dest.w * 0.5, dest.y + dest.h * 0.5})
	scale := Transform2D_Scale(drawState().transform)
	w, h := dest.w * scale.x, dest.h * scale.y
	angle := rotation + Transform2D_Rotation(drawState().transform)
	tint := tinted(tint)
	// A mirroring transform (a negative scale: a sprite turned to face left): its x axis gives the
	// angle, so flipping vertically before SDL rotates draws the mirror image
	t := drawState().transform
	flip := flip
	if t.x.x * t.y.y - t.x.y * t.y.x < 0 do flip = sdl.FlipMode(u32(flip) ~ u32(sdl.FlipMode.VERTICAL))

	dst := sdl.FRect{center.x - w * 0.5, center.y - h * 0.5, w, h}
	srcRect, hasSrc := src.?

	sdl.SetTextureColorMod(texture, tint[0], tint[1], tint[2])
	sdl.SetTextureAlphaMod(texture, tint[3])
	sdl.SetTextureBlendMode(texture, SDLBlendMode(drawState().blend))
	// Unturned and unflipped: a plain copy. SDL's software renderer clips it to the screen, while
	// its rotated copy scales the whole image first (a level background at 3x zoom, about
	// 9600 x 1440 px, took most of 100 ms a frame)
	if angle == 0 && flip == .NONE {
		// And only the part on screen: SDL's software renderer scales the whole source first
		source := hasSrc ? srcRect : sdl.FRect{0, 0, f32(texture.w), f32(texture.h)}
		if !clipToScreen(renderer, &source, &dst) do return
		sdl.RenderTexture(renderer, texture, &source, &dst)
		return
	}
	sdl.RenderTextureRotated(renderer, texture, hasSrc ? &srcRect : nil, &dst, f64(angle), nil, flip)
}


// INTERNAL HELPERS

/*
Clips a copy (source and destination rectangles) to the renderer's screen (the logical size when
it has one), keeping the mapping between them. Returns false when nothing of it shows.
*/
@(private="file")
clipToScreen :: proc(renderer: ^sdl.Renderer, src, dst: ^sdl.FRect) -> bool {
	w, h: i32
	mode: sdl.RendererLogicalPresentation
	if !sdl.GetRenderLogicalPresentation(renderer, &w, &h, &mode) || w <= 0 || h <= 0 {
		if !sdl.GetCurrentRenderOutputSize(renderer, &w, &h) || w <= 0 || h <= 0 do return true
	}
	if dst.w <= 0 || dst.h <= 0 do return false
	x0, y0 := max(dst.x, 0), max(dst.y, 0)
	x1, y1 := min(dst.x + dst.w, f32(w)), min(dst.y + dst.h, f32(h))
	if x1 <= x0 || y1 <= y0 do return false
	if x0 == dst.x && y0 == dst.y && x1 == dst.x + dst.w && y1 == dst.y + dst.h do return true
	// Source per destination pixel
	sx, sy := src.w / dst.w, src.h / dst.h
	src^ = {src.x + (x0 - dst.x) * sx, src.y + (y0 - dst.y) * sy, (x1 - x0) * sx, (y1 - y0) * sy}
	dst^ = {x0, y0, x1 - x0, y1 - y0}
	return true
}

@(private="file")
ColorToFColor :: proc(color: sdl.Color) -> sdl.FColor {
	return {f32(color[0]) / 255, f32(color[1]) / 255, f32(color[2]) / 255, f32(color[3]) / 255}
}

// Local point to screen point through the draw transform
@(private="file")
tp :: proc(p: sdl.FPoint) -> sdl.FPoint {
	return sdl.FPoint(toScreen(cast([2]f32)p))
}

@(private="file")
toScreenPoints :: proc(points: []sdl.FPoint) {
	if drawState().transform == TRANSFORM2D_IDENTITY do return
	for &p in points do p = tp(p)
}

// Caller's points are left untouched; the copy lives until the end of the frame
@(private="file")
transformedCopy :: proc(points: []sdl.FPoint) -> []sdl.FPoint {
	if drawState().transform == TRANSFORM2D_IDENTITY do return points
	out := make([]sdl.FPoint, len(points), context.temp_allocator)
	for p, i in points do out[i] = tp(p)
	return out
}

@(private="file")
rectCorners :: proc(rect: ^sdl.FRect) -> [4]sdl.FPoint {
	return {
		{rect.x, rect.y},
		{rect.x + rect.w, rect.y},
		{rect.x + rect.w, rect.y + rect.h},
		{rect.x, rect.y + rect.h},
	}
}

// Perimeter of an ellipse, already transformed to screen space
@(private="file")
ellipsePoints :: proc(center: sdl.FPoint, rx, ry: f32) -> []sdl.FPoint {
	segments := CurveSegments(toScreenLength(max(rx, ry)))
	points := make([]sdl.FPoint, segments, context.temp_allocator)
	for i in 0..<segments {
		angle := f32(i) / f32(segments) * math.TAU
		points[i] = tp({center.x + math.cos(angle) * rx, center.y + math.sin(angle) * ry})
	}
	return points
}

// Fills a convex polygon given in screen coordinates, as a triangle fan from the first point
@(private="file")
fillScreenPolygon :: proc(renderer: ^sdl.Renderer, points: []sdl.FPoint, color: sdl.Color) {
	if len(points) < 3 do return

	fc := ColorToFColor(tinted(color))
	vertices := make([]sdl.Vertex, len(points), context.temp_allocator)
	indices := make([]c.int, (len(points) - 2) * 3, context.temp_allocator)

	for p, i in points {
		vertices[i] = {position = p, color = fc}
	}
	for i in 0..<len(points) - 2 {
		indices[i * 3 + 0] = 0
		indices[i * 3 + 1] = c.int(i + 1)
		indices[i * 3 + 2] = c.int(i + 2)
	}

	sdl.RenderGeometry(renderer, nil, raw_data(vertices), c.int(len(vertices)), raw_data(indices), c.int(len(indices)))
}

// Closed 1px outline through points given in screen coordinates
@(private="file")
strokeScreenPolygon :: proc(renderer: ^sdl.Renderer, points: []sdl.FPoint, color: sdl.Color) {
	if len(points) < 2 do return

	color := tinted(color)
	sdl.SetRenderDrawColor(renderer, color[0], color[1], color[2], color[3])
	sdl.RenderLines(renderer, raw_data(points), c.int(len(points)))
	first, last := points[0], points[len(points) - 1]
	sdl.RenderLine(renderer, last.x, last.y, first.x, first.y)
}

// Pick a segment count that keeps curves smooth without wasting vertices on small shapes
@(private="file")
CurveSegments :: proc(radius: f32) -> int {
	return clamp(int(radius * 0.5), 12, MAX_CURVE_SEGMENTS)
}

// Perimeter points of a rounded rectangle, clockwise starting at the top-left corner
@(private="file")
RoundedRectanglePoints :: proc(rect: ^sdl.FRect, radius: f32) -> (points: [ROUNDED_RECT_POINT_COUNT]sdl.FPoint) {
	r := clamp(radius, 0, min(rect.w, rect.h) * 0.5)

	// Corner arc centers and their starting angles (clockwise in screen space)
	centers := [4]sdl.FPoint{
		{rect.x + r,          rect.y + r},
		{rect.x + rect.w - r, rect.y + r},
		{rect.x + rect.w - r, rect.y + rect.h - r},
		{rect.x + r,          rect.y + rect.h - r},
	}
	start_angles := [4]f32{math.PI, math.PI * 1.5, 0, math.PI * 0.5}

	for corner in 0..<4 {
		for i in 0..=ROUNDED_CORNER_SEGMENTS {
			angle := start_angles[corner] + f32(i) / ROUNDED_CORNER_SEGMENTS * (math.PI * 0.5)
			points[corner * (ROUNDED_CORNER_SEGMENTS + 1) + i] = {
				centers[corner].x + math.cos(angle) * r,
				centers[corner].y + math.sin(angle) * r,
			}
		}
	}
	return
}

// A local rectangle on screen, for transforms without rotation (mirroring is normalized)
@(private="file")
screenRect :: proc(rect: ^sdl.FRect) -> sdl.FRect {
	a := toScreen({rect.x, rect.y})
	b := toScreen({rect.x + rect.w, rect.y + rect.h})
	return {min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y)}
}
