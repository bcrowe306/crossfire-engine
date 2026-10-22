package crossfire

import "core:c"
import "core:math"
import sdl "vendor:sdl3"

/*
Tiles drawn in one batch (TileMap layers: tilemap.odin): quads of one texture, each its tile's
part of it with Aseprite's flips (`ASEPRITE_TILE_FLIP_X`, `_Y`, `_D`), drawn through the draw
transform and tint as one `RenderGeometry`, only those the screen shows.

SDL's software renderer (the editor's viewport) is handled as the LDtk tile layers are
(ldtk_nodes.odin says why): the whole batch is drawn once into a texture of its size, then the
part that shows is copied each frame; and triangles never share vertices there.
*/

// A tile of a batch
@(private)
TileQuad :: struct {
	// Its top-left corner in the batch (pixels)
	px: [2]f32,
	// Its top-left corner in the texture
	src: [2]f32,
	// Aseprite's flip bits (ASEPRITE_TILE_FLIP_X / _Y / _D)
	flips: u32,
	// Opacity 0-1
	alpha: f32,
}

// Tiles of one texture, and the software renderer's cache of them
@(private)
TileBatch :: struct {
	// The tiles' image (the resource manager's)
	texture: ^sdl.Texture,
	// A tile's size in pixels
	tileSize: [2]f32,
	// The batch's size in pixels (what the cache holds)
	size: [2]f32,
	// Its tiles (owned by the node's arena)
	quads: []TileQuad,
	// SDL's software renderer: every tile drawn once (nil until first drawn, and after a change)
	cache: ^sdl.Texture,
	cacheRenderer: ^sdl.Renderer,
}

// Where a quad's corner (0 or 1 each way) takes its texture from, with the tile's flips: the same
// mapping as `Aseprite_TilePixels` (X, then Y, then the diagonal swap)
@(private="file")
cornerSource :: proc(flips: u32, cx, cy: f32) -> (f32, f32) {
	sx, sy := cx, cy
	if flips & ASEPRITE_TILE_FLIP_X != 0 do sx = 1 - sx
	if flips & ASEPRITE_TILE_FLIP_Y != 0 do sy = 1 - sy
	if flips & ASEPRITE_TILE_FLIP_D != 0 do sx, sy = sy, sx
	return sx, sy
}

// The batch's triangles: those inside lo..hi (batch pixels), at `at + p` through the draw
// transform; separate triangles for the software renderer
@(private="file")
tileGeometry :: proc(batch: ^TileBatch, base: sdl.FColor, lo, hi: [2]f32, software, screen: bool) -> ([dynamic]sdl.Vertex, [dynamic]c.int) {
	vertices := make([dynamic]sdl.Vertex, 0, len(batch.quads) * 6, context.temp_allocator)
	indices := make([dynamic]c.int, 0, len(batch.quads) * 6, context.temp_allocator)
	if batch.texture == nil do return vertices, indices
	tw, th := f32(batch.texture.w), f32(batch.texture.h)
	size := batch.tileSize
	place :: proc(p: [2]f32, screen: bool) -> sdl.FPoint {
		if !screen do return {p.x, p.y}
		// On whole pixels: neighbouring tiles then share exact edges (see the LDtk layers)
		q := toScreen(p)
		return {math.round(q.x), math.round(q.y)}
	}
	for quad in batch.quads {
		p := quad.px
		if p.x + size.x < lo.x || p.y + size.y < lo.y || p.x > hi.x || p.y > hi.y do continue
		color := base
		color.a *= quad.alpha
		corners: [4]sdl.Vertex
		for corner, i in ([4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}) {
			sx, sy := cornerSource(quad.flips, corner.x, corner.y)
			corners[i] = {position = place(p + corner * size, screen), color = color, tex_coord = {(quad.src.x + sx * size.x) / tw, (quad.src.y + sy * size.y) / th}}
		}
		at := c.int(len(vertices))
		if software {
			append(&vertices, corners[0], corners[1], corners[2], corners[0], corners[2], corners[3])
			append(&indices, at, at + 1, at + 2, at + 3, at + 4, at + 5)
		} else {
			append(&vertices, ..corners[:])
			append(&indices, at, at + 1, at + 2, at, at + 2, at + 3)
		}
	}
	return vertices, indices
}

/*
Draws a batch in the drawing node's space (its top-left at the node's origin), tinted.
*/
@(private)
drawTileBatch :: proc(batch: ^TileBatch, renderer: ^sdl.Renderer, base: sdl.FColor) {
	if batch.texture == nil || len(batch.quads) == 0 do return
	lo, hi := tileVisibleBox(renderer)
	software := tileIsSoftwareRenderer(renderer)
	if software && drawTileCache(batch, renderer, lo, hi, base) do return
	vertices, indices := tileGeometry(batch, base, lo, hi, software, true)
	if len(vertices) == 0 do return
	sdl.SetTextureBlendMode(batch.texture, GetDrawBlend())
	sdl.RenderGeometry(renderer, batch.texture, raw_data(vertices), c.int(len(vertices)), raw_data(indices), c.int(len(indices)))
}

// Frees a batch's cache (made again when next drawn: after its tiles or texture change)
@(private)
dropTileBatchCache :: proc(batch: ^TileBatch) {
	if batch.cache != nil do sdl.DestroyTexture(batch.cache)
	batch.cache, batch.cacheRenderer = nil, nil
}

// The largest batch, in pixels across, drawn through a cache texture (bigger ones draw tile by tile)
@(private="file")
TILE_CACHE_MAX_SIZE :: 8192

// From the cache (made the first time): the part that shows, as one copy; false when it can't
// (a rotated or mirrored view, a batch too big)
@(private="file")
drawTileCache :: proc(batch: ^TileBatch, renderer: ^sdl.Renderer, lo, hi: [2]f32, color: sdl.FColor) -> bool {
	t := drawState().transform
	if !Transform2D_IsAxisAligned(t) || t.x.x <= 0 || t.y.y <= 0 do return false
	size := batch.size
	if size.x <= 0 || size.y <= 0 || size.x > TILE_CACHE_MAX_SIZE || size.y > TILE_CACHE_MAX_SIZE do return false
	if batch.cache == nil || batch.cacheRenderer != renderer {
		dropTileBatchCache(batch)
		texture := sdl.CreateTexture(renderer, RENDER_TARGET_FORMAT, .TARGET, i32(size.x), i32(size.y))
		if texture == nil do return false
		sdl.SetTextureScaleMode(texture, .NEAREST)
		target := RenderTarget{texture = texture, size = size}
		RenderTarget_Begin(renderer, &target, clear = true)
		// 1:1, every tile, triangles apart (the software renderer's rectangle copies were the problem)
		vertices, indices := tileGeometry(batch, {1, 1, 1, 1}, {-1e30, -1e30}, {1e30, 1e30}, true, false)
		sdl.SetTextureBlendMode(batch.texture, sdl.BLENDMODE_BLEND)
		if len(vertices) > 0 do sdl.RenderGeometry(renderer, batch.texture, raw_data(vertices), c.int(len(vertices)), raw_data(indices), c.int(len(indices)))
		RenderTarget_End(renderer, &target)
		batch.cache, batch.cacheRenderer = texture, renderer
	}
	from := [2]f32{max(math.floor(lo.x), 0), max(math.floor(lo.y), 0)}
	to := [2]f32{min(math.ceil(hi.x), size.x), min(math.ceil(hi.y), size.y)}
	if to.x <= from.x || to.y <= from.y do return true
	a := toScreen(from)
	b := toScreen(to)
	src := sdl.FRect{from.x, from.y, to.x - from.x, to.y - from.y}
	dst := sdl.FRect{math.round(a.x), math.round(a.y), math.round(b.x) - math.round(a.x), math.round(b.y) - math.round(a.y)}
	sdl.SetTextureColorModFloat(batch.cache, color.r, color.g, color.b)
	sdl.SetTextureAlphaModFloat(batch.cache, color.a)
	sdl.SetTextureBlendMode(batch.cache, GetDrawBlend())
	sdl.RenderTexture(renderer, batch.cache, &src, &dst)
	return true
}

@(private="file")
tileIsSoftwareRenderer :: proc(renderer: ^sdl.Renderer) -> bool {
	name := sdl.GetRendererName(renderer)
	return name != nil && string(name) == "software"
}

// The part of the node's space the screen shows (everything when the output size isn't known)
@(private="file")
tileVisibleBox :: proc(renderer: ^sdl.Renderer) -> (lo, hi: [2]f32) {
	w, h: c.int
	mode: sdl.RendererLogicalPresentation
	if !sdl.GetRenderLogicalPresentation(renderer, &w, &h, &mode) || w <= 0 || h <= 0 {
		if !sdl.GetCurrentRenderOutputSize(renderer, &w, &h) || w <= 0 || h <= 0 do return {-1e30, -1e30}, {1e30, 1e30}
	}
	inverse := Transform2D_Inverse(drawState().transform)
	lo, hi = {1e30, 1e30}, {-1e30, -1e30}
	for corner in ([4][2]f32{{0, 0}, {f32(w), 0}, {f32(w), f32(h)}, {0, f32(h)}}) {
		p := Transform2D_Apply(inverse, corner)
		lo = {min(lo.x, p.x), min(lo.y, p.y)}
		hi = {max(hi.x, p.x), max(hi.y, p.y)}
	}
	return
}
