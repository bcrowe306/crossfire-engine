package crossfire

import "core:encoding/json"
import "core:encoding/xml"
import "core:log"
import "core:math"
import "core:path/slashpath"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
Fonts besides TrueType: bitmap fonts (BMFont) and MSDF fonts. Every text the engine draws goes
through `DrawText` / `MeasureText` with a font's path, so Labels, Menus, Buttons and RichText
use them with no change.

- **Bitmap fonts:** a `.fnt` file (AngelCode BMFont, text or XML, the format Hiero, BMFont,
  Littera and Snow's tools write) and its page images beside it. Each glyph is a picture: right
  for pixel-art lettering, drawn at whole multiples of its size (`size` scales it; the font's
  own size draws it as made).
- **MSDF fonts:** a TrueType font whose asset says `msdf="true"` (asset_import.odin) gets an
  MSDF atlas made by the editor (msdf-atlas-gen: `<font>.msdf.bmp` and `<font>.msdf.json`
  beside it). On the GPU renderer, text in it is drawn from the atlas through an MSDF shader
  (shaders/text/msdf.frag): sharp at any size and zoom, and turned with its node. Elsewhere (no
  GPU renderer, the web) the font draws as a TrueType font, the same letters.

Both are laid out by the engine (`fontLayout`): lines broken at newlines and wrapped at spaces,
kerning pairs, the line height and ascent the font gives. A glyph the font lacks draws as
nothing (an MSDF font's atlas has the characters it was made with: printable ASCII and Latin-1
by default).
*/

// A bitmap font file's extension
BMFONT_EXTENSION :: ".fnt"
// What an MSDF font's atlas files end with, after the font's own name ("Font.ttf.msdf.json")
MSDF_ATLAS_SUFFIX :: ".msdf.json"
MSDF_IMAGE_SUFFIX :: ".msdf.bmp"

// A font drawn from pictures of its glyphs: a bitmap font, or an MSDF font's atlas
GlyphFont :: struct {
	msdf: bool,
	// Pixels per em the glyphs were made at (sizes scale from it)
	size: f32,
	// At that size: from one line to the next, and from a line's top to its baseline
	lineHeight, ascent: f32,
	glyphs: map[rune]FontGlyph,
	kerning: map[[2]rune]f32,
	// The pictures, by page
	pages: [dynamic]^sdl.Texture,
	// MSDF: the atlas's distance range in its pixels, and the shader drawing it
	pxRange: f32,
	material: ^ShaderMaterial,
}

// One glyph of a GlyphFont, at the font's size
FontGlyph :: struct {
	page: int,
	// Its picture in the page, in pixels
	src: sdl.FRect,
	// Where the picture goes from the pen (x) and the line's top (y), and its size
	offset, size: [2]f32,
	// How far the pen moves after it
	advance: f32,
}

// A BMFont file's contents (`ParseBMFont`)
BMFontData :: struct {
	// `info size` (pixels per em; positive), `common lineHeight`, `base`
	size, lineHeight, base: f32,
	// The page images, relative to the .fnt file
	pages: [dynamic]string,
	chars: [dynamic]BMFontChar,
	kernings: [dynamic]BMFontKerning,
}

BMFontChar :: struct {
	id: rune,
	x, y, width, height, xoffset, yoffset, xadvance: f32,
	page: int,
}

BMFontKerning :: struct {
	first, second: rune,
	amount: f32,
}

// Whether a font path is a bitmap font
Font_IsBitmap :: proc(path: string) -> bool {
	return strings.has_suffix(strings.to_lower(path, context.temp_allocator), BMFONT_EXTENSION)
}

/*
Reads a BMFont file, text or XML (binary .fnt files aren't read: export text or XML).

Inputs:
- text: The file's contents
- allocator: For the lists and page names

Returns:
- The font's data (free with `BMFontData_Destroy`), and false when it isn't a BMFont file
*/
ParseBMFont :: proc(text: string, allocator := context.allocator) -> (data: BMFontData, ok: bool) {
	data.pages = make([dynamic]string, allocator)
	data.chars = make([dynamic]BMFontChar, allocator)
	data.kernings = make([dynamic]BMFontKerning, allocator)
	// One element's key=value pairs, either format
	Pair :: struct { key, value: string }
	element :: proc(data: ^BMFontData, tag: string, pairs: []Pair, allocator := context.allocator) {
		get :: proc(pairs: []Pair, key: string) -> string {
			for p in pairs do if p.key == key do return p.value
			return ""
		}
		num :: proc(pairs: []Pair, key: string) -> f32 { return strconv.parse_f32(get(pairs, key)) or_else 0 }
		switch tag {
		case "info":
			data.size = abs(num(pairs, "size"))
		case "common":
			data.lineHeight = num(pairs, "lineHeight")
			data.base = num(pairs, "base")
		case "page":
			id := int(num(pairs, "id"))
			for len(data.pages) <= id do append(&data.pages, "")
			data.pages[id] = strings.clone(get(pairs, "file"), allocator)
		case "char":
			append(&data.chars, BMFontChar{
				id = rune(num(pairs, "id")), x = num(pairs, "x"), y = num(pairs, "y"),
				width = num(pairs, "width"), height = num(pairs, "height"),
				xoffset = num(pairs, "xoffset"), yoffset = num(pairs, "yoffset"),
				xadvance = num(pairs, "xadvance"), page = int(num(pairs, "page")),
			})
		case "kerning":
			append(&data.kernings, BMFontKerning{rune(num(pairs, "first")), rune(num(pairs, "second")), num(pairs, "amount")})
		}
	}
	trimmed := strings.trim_space(text)
	if strings.has_prefix(trimmed, "<") {
		doc, err := xml.parse_string(text)
		if err != .None do return data, false
		defer xml.destroy(doc)
		if doc.element_count == 0 || doc.elements[0].ident != "font" do return data, false
		for i in 0 ..< doc.element_count {
			e := doc.elements[i]
			pairs := make([dynamic]Pair, context.temp_allocator)
			for a in e.attribs do append(&pairs, Pair{a.key, a.val})
			element(&data, e.ident, pairs[:], allocator)
		}
	} else {
		if !strings.has_prefix(trimmed, "info") do return data, false
		for line in strings.split_lines(text, context.temp_allocator) {
			rest := strings.trim_space(line)
			tag, _, after := strings.partition(rest, " ")
			pairs := make([dynamic]Pair, context.temp_allocator)
			// key=value, values may be quoted (with spaces inside)
			for len(after) > 0 {
				after = strings.trim_left_space(after)
				key, found, value := strings.partition(after, "=")
				if found == "" do break
				if strings.has_prefix(value, "\"") {
					end := strings.index_byte(value[1:], '"')
					if end < 0 do end = len(value) - 1
					append(&pairs, Pair{strings.trim_space(key), value[1:end + 1]})
					after = value[min(end + 2, len(value)):]
				} else {
					v, _, next := strings.partition(value, " ")
					append(&pairs, Pair{strings.trim_space(key), v})
					after = next
				}
			}
			element(&data, tag, pairs[:], allocator)
		}
	}
	if data.size <= 0 do data.size = data.lineHeight
	return data, data.lineHeight > 0 && len(data.pages) > 0
}

// Frees what `ParseBMFont` made
BMFontData_Destroy :: proc(data: ^BMFontData, allocator := context.allocator) {
	for p in data.pages do delete(p, allocator)
	delete(data.pages)
	delete(data.chars)
	delete(data.kernings)
	data^ = {}
}

/*
Turns a font's MSDF atlas on or off (asset_import.odin: `Game_LoadProject` does it for the
project's font assets with `msdf="true"`). The atlas files are read the first time text in the
font draws on the GPU renderer.

Inputs:
- rm: The resource manager
- path: The font, as text is drawn with it (the project folder joined)
- on: Whether it has an atlas
*/
ResourceManager_SetFontMSDF :: proc(rm: ^ResourceManager, path: string, on: bool) {
	if on == (path in rm.msdfFonts) do return
	if on {
		rm.msdfFonts[strings.clone(path)] = {}
	} else {
		key, _ := delete_key(&rm.msdfFonts, path)
		delete(key)
	}
	// Read again next time (the editor made a new atlas, or it's a plain font now)
	if key, font := delete_key(&rm.glyphFonts, path); key != "" {
		delete(key)
		glyphFontDestroy(font)
	}
}

/*
Forgets a font's glyph pictures, so the next text reads its files again (an editor made a new
MSDF atlas, or saved a bitmap font).
*/
ResourceManager_ForgetGlyphFont :: proc(rm: ^ResourceManager, path: string) {
	if key, font := delete_key(&rm.glyphFonts, path); key != "" {
		delete(key)
		glyphFontDestroy(font)
	}
}

// INTERNAL

// The font text in `path` draws with: a bitmap or MSDF font, or nil for TrueType
@(private)
glyphFontFor :: proc(rm: ^ResourceManager, path: string) -> ^GlyphFont {
	bitmap := Font_IsBitmap(path)
	msdf := !bitmap && path in rm.msdfFonts && Renderer_SupportsShaders(rm.renderer)
	if !bitmap && !msdf do return nil
	if font, found := rm.glyphFonts[path]; found do return font
	font := bitmap ? bitmapFontLoad(rm, path) : msdfFontLoad(rm, path)
	if rm.glyphFonts == nil do rm.glyphFonts = make(map[string]^GlyphFont)
	rm.glyphFonts[strings.clone(path)] = font
	return font
}

@(private="file")
bitmapFontLoad :: proc(rm: ^ResourceManager, path: string) -> ^GlyphFont {
	text, read := Platform_ReadFile(path)
	if !read {
		log.errorf("Couldn't read the font %s", path)
		return nil
	}
	data, ok := ParseBMFont(string(text), context.temp_allocator)
	if !ok {
		log.errorf("%s isn't a BMFont file (text or XML)", path)
		return nil
	}
	font := new(GlyphFont)
	font.size, font.lineHeight, font.ascent = data.size, data.lineHeight, data.base
	dir := slashpath.dir(path, context.temp_allocator)
	for page in data.pages {
		texture := rm->loadTexture(JoinPath(dir == "." ? "" : dir, page))
		append(&font.pages, texture)
	}
	for c in data.chars {
		font.glyphs[c.id] = {page = c.page, src = {c.x, c.y, c.width, c.height}, offset = {c.xoffset, c.yoffset}, size = {c.width, c.height}, advance = c.xadvance}
	}
	for k in data.kernings do font.kerning[{k.first, k.second}] = k.amount
	return font
}

@(private="file")
msdfFontLoad :: proc(rm: ^ResourceManager, path: string) -> ^GlyphFont {
	Bounds :: struct { left, bottom, right, top: f32 }
	Layout :: struct {
		atlas: struct { distanceRange, size, width, height: f32, yOrigin: string },
		metrics: struct { emSize, lineHeight, ascender: f32 },
		glyphs: []struct { unicode: int, advance: f32, planeBounds, atlasBounds: Maybe(Bounds) },
		kerning: []struct { unicode1, unicode2: int, advance: f32 },
	}
	text, read := Platform_ReadFile(strings.concatenate({path, MSDF_ATLAS_SUFFIX}, context.temp_allocator))
	layout: Layout
	if !read || json.unmarshal(text, &layout, allocator = context.temp_allocator) != nil || layout.atlas.size <= 0 {
		log.warnf("%s has no MSDF atlas (the editor makes it): drawn as TrueType", path)
		return nil
	}
	texture := rm->loadTexture(strings.concatenate({path, MSDF_IMAGE_SUFFIX}, context.temp_allocator))
	if texture == nil do return nil
	// Distances are read between texels
	sdl.SetTextureScaleMode(texture, .LINEAR)
	font := new(GlyphFont)
	font.msdf = true
	s := layout.atlas.size
	font.size, font.lineHeight, font.ascent = s, layout.metrics.lineHeight * s, layout.metrics.ascender * s
	font.pxRange = layout.atlas.distanceRange
	append(&font.pages, texture)
	bottomUp := layout.atlas.yOrigin != "top"
	for g in layout.glyphs {
		glyph := FontGlyph{advance = g.advance * s}
		if plane, hasPlane := g.planeBounds.?; hasPlane {
			ab := g.atlasBounds.? or_else Bounds{}
			// The atlas's y runs up from its bottom by default (msdf-atlas-gen's yOrigin)
			top := bottomUp ? layout.atlas.height - ab.top : min(ab.top, ab.bottom)
			glyph.src = {ab.left, top, ab.right - ab.left, abs(ab.top - ab.bottom)}
			glyph.offset = {plane.left * s, (layout.metrics.ascender - plane.top) * s}
			glyph.size = {(plane.right - plane.left) * s, (plane.top - plane.bottom) * s}
		}
		font.glyphs[rune(g.unicode)] = glyph
	}
	for k in layout.kerning do font.kerning[{rune(k.unicode1), rune(k.unicode2)}] = k.advance * s
	// Its own material: SDL keeps a state's uniforms, and fonts have their own ranges
	font.material = new(ShaderMaterial)
	font.material.program = msdfProgram(rm)
	append(&font.material.values, [4]f32{font.pxRange, 0, 0, 0})
	return font
}

// The MSDF shader, one per resource manager (its GPU code is made per device: shaderOnRenderer)
@(private="file")
msdfProgram :: proc(rm: ^ResourceManager) -> ^ShaderProgram {
	if rm.msdfProgram == nil {
		bundle, ok := Shader_ParseBundle(MSDF_FRAG)
		if !ok do return nil
		rm.msdfProgram = new_clone(ShaderProgram{path = "msdf", bundle = bundle})
	}
	return rm.msdfProgram
}

@(private="file")
MSDF_FRAG :: #load("shaders/text/msdf.frag.shader")

@(private)
glyphFontDestroy :: proc(font: ^GlyphFont) {
	if font == nil do return
	delete(font.glyphs)
	delete(font.kerning)
	delete(font.pages)
	if font.material != nil {
		shaderMaterialDestroy(font.material)
		delete(font.material.states)
		delete(font.material.values)
		free(font.material)
	}
	free(font)
}

// Frees the GPU objects of the resource manager's MSDF fonts (before the renderer goes)
@(private)
glyphFontsReleaseGPU :: proc(rm: ^ResourceManager) {
	for _, font in rm.glyphFonts do if font != nil && font.material != nil do shaderMaterialDestroy(font.material)
	if program := rm.msdfProgram; program != nil {
		for g in program.gpu do sdl.ReleaseGPUShader(g.device, g.shader)
		clear(&program.gpu)
		program.failed = false
	}
}

// Frees the MSDF shader's memory (ResourceManager_destroy; its GPU code went first)
@(private)
msdfProgramDestroy :: proc(rm: ^ResourceManager) {
	program := rm.msdfProgram
	if program == nil do return
	delete(program.gpu)
	b := &program.bundle
	for p in b.params { delete(p.name); delete(p.label) }
	delete(b.params)
	delete(b.spirv)
	delete(b.msl)
	free(program)
	rm.msdfProgram = nil
}

// A line of laid-out text: the glyphs' indices in `glyphs` and the line's width
@(private="file")
FontLine :: struct { start, end: int, width: f32 }

// A glyph placed by fontLayout, at the font's size from the text's top-left
@(private="file")
PlacedGlyph :: struct { glyph: FontGlyph, position: [2]f32 }

/*
Lays out text in a glyph font at `size`: newlines break lines, `wrapWidth` (> 0) wraps them at
spaces. Returns the glyphs placed (temp allocated) and the text's size.
*/
@(private="file")
fontLayout :: proc(font: ^GlyphFont, text: string, size, wrapWidth: f32) -> (placed: []PlacedGlyph, extent: [2]f32) {
	scale := size / max(font.size, 1)
	glyphs := make([dynamic]PlacedGlyph, context.temp_allocator)
	lineHeight := font.lineHeight * scale
	y: f32 = 0
	lines := 0
	for paragraph in strings.split_lines(text, context.temp_allocator) {
		x: f32 = 0
		lineStart := len(glyphs)
		previous: rune = -1
		// The glyph index after the last space, and the pen there, to wrap at
		lastSpace := -1
		for r in paragraph {
			g, found := font.glyphs[r]
			// A font without a space still spaces words (a quarter of its size)
			if !found && r == ' ' do g, found = FontGlyph{advance = font.size * 0.25}, true
			if !found do continue
			if previous >= 0 do x += font.kerning[{previous, r}] * scale
			advance := g.advance * scale
			if wrapWidth > 0 && r != ' ' && x + advance > wrapWidth && lastSpace > lineStart {
				// Move the word after the last space onto a new line
				shift := glyphs[lastSpace].position.x
				for &p in glyphs[lastSpace:] do p.position += {-shift, lineHeight}
				extent.x = max(extent.x, shift)
				y += lineHeight
				lines += 1
				x -= shift
				lineStart = lastSpace
				lastSpace = -1
			}
			append(&glyphs, PlacedGlyph{scaleGlyph(g, scale), {x, y}})
			x += advance
			if r == ' ' do lastSpace = len(glyphs)
			previous = r
		}
		extent.x = max(extent.x, x)
		y += lineHeight
		lines += 1
	}
	extent.y = lines > 0 ? y : 0
	return glyphs[:], extent
}

@(private="file")
scaleGlyph :: proc(g: FontGlyph, scale: f32) -> FontGlyph {
	g := g
	g.offset *= scale
	g.size *= scale
	g.advance *= scale
	return g
}

// The size text in a glyph font takes (MeasureText)
@(private)
glyphFontMeasure :: proc(font: ^GlyphFont, text: string, size, wrapWidth: f32) -> [2]f32 {
	_, extent := fontLayout(font, text, size, wrapWidth)
	return extent
}

/*
Draws text in a glyph font, its top-left at `pos` in local coordinates: each glyph a quad
through the draw transform (so it turns and scales with its node), tinted, one batch per page;
an MSDF font through its shader.
*/
@(private)
glyphFontDraw :: proc(rm: ^ResourceManager, font: ^GlyphFont, pos: [2]f32, text: string, size: f32, color: sdl.Color, wrapWidth: f32) {
	placed, _ := fontLayout(font, text, size, wrapWidth)
	if len(placed) == 0 do return
	tint := tinted(color)
	c := sdl.FColor{f32(tint[0]) / 255, f32(tint[1]) / 255, f32(tint[2]) / 255, f32(tint[3]) / 255}
	t := drawState().transform
	// A bitmap font drawn at its own size, unturned, goes on whole pixels (crisp pixel lettering)
	snap := !font.msdf && t.x.y == 0 && t.y.x == 0
	for page, pageIndex in font.pages {
		if page == nil do continue
		vertices := make([dynamic]sdl.Vertex, context.temp_allocator)
		indices := make([dynamic]i32, context.temp_allocator)
		tw, th := f32(page.w), f32(page.h)
		for p in placed {
			g := p.glyph
			if g.page != pageIndex || g.size.x <= 0 || g.size.y <= 0 do continue
			corner := pos + p.position + g.offset
			quad := [4][2]f32{corner, corner + {g.size.x, 0}, corner + g.size, corner + {0, g.size.y}}
			uv := [4][2]f32{{g.src.x, g.src.y}, {g.src.x + g.src.w, g.src.y}, {g.src.x + g.src.w, g.src.y + g.src.h}, {g.src.x, g.src.y + g.src.h}}
			base := i32(len(vertices))
			for i in 0 ..< 4 {
				screen := Transform2D_Apply(t, quad[i])
				if snap do screen = {math.round(screen.x), math.round(screen.y)}
				append(&vertices, sdl.Vertex{position = {screen.x, screen.y}, color = c, tex_coord = {uv[i].x / tw, uv[i].y / th}})
			}
			append(&indices, base, base + 1, base + 2, base, base + 2, base + 3)
		}
		if len(indices) == 0 do continue
		sdl.SetTextureBlendMode(page, GetDrawBlend())
		on := false
		if font.material != nil {
			if state := shaderMaterialState(font.material, rm.renderer, {tw, th}, 0); state != nil do on = sdl.SetGPURenderState(rm.renderer, state)
		} else {
			on = shaderDrawBegin(rm.renderer, {tw, th})
		}
		sdl.RenderGeometry(rm.renderer, page, raw_data(vertices), i32(len(vertices)), raw_data(indices), i32(len(indices)))
		shaderDrawEnd(rm.renderer, on)
	}
}
