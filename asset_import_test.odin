#+build !js
package crossfire

import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Asset import settings (asset_import.odin), atlases (atlas.odin), bitmap and MSDF fonts
// (fonts.odin, font_compile.odin): parsed, packed, applied, drawn

// A software renderer drawing into a surface, and a game using it
@(private="file")
softwareGame :: proc(size: i32) -> (^sdl.Surface, ^sdl.Renderer, ^Game) {
	surface := sdl.CreateSurface(size, size, .ARGB8888)
	renderer := sdl.CreateSoftwareRenderer(surface)
	game := testGame("testdata")
	game.renderer = renderer
	game.resourceManager.renderer = renderer
	return surface, renderer, game
}

@(private="file")
surfacePixel :: proc(surface: ^sdl.Surface, x, y: i32) -> u32 {
	return (cast([^]u32)surface.pixels)[y * (surface.pitch / 4) + x]
}

// A BMP of `size` in one color (ARGB), written to `path`
@(private="file")
writeImage :: proc(path: string, size: [2]i32, color: u32) {
	surface := sdl.CreateSurface(size.x, size.y, .ARGB8888)
	defer sdl.DestroySurface(surface)
	_ = sdl.FillSurfaceRect(surface, nil, color)
	_ = sdl.SaveBMP(surface, strings.clone_to_cstring(path, context.temp_allocator))
}

@(test)
texture_filters_follow_assets_and_the_project :: proc(t: ^testing.T) {
	project, err := ParseProject(`<project formatVersion="13" name="P" textureFilter="Pixel">
	<asset path="assets/smooth.png" kind="Image" filter="Smooth"/>
	<asset path="assets/plain.png" kind="Image"/>
	<asset path="fonts/Sans.ttf" kind="Font" msdf="true"/>
</project>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, project.textureFilter, TextureFilter.Pixel)
	testing.expect_value(t, project.assets[0].filter, TextureFilter.Smooth)
	testing.expect_value(t, project.assets[1].filter, TextureFilter.Default)
	testing.expect(t, project.assets[2].msdf, "an MSDF font")

	dir := tempFolder("engine_test_filters")
	defer os.remove_all(dir)
	_ = os.make_directory_all(JoinPath(dir, "assets"))
	writeImage(JoinPath(dir, "assets/smooth.png"), {4, 4}, 0xffff0000)
	writeImage(JoinPath(dir, "assets/plain.png"), {4, 4}, 0xff00ff00)
	surface, renderer, game := softwareGame(8)
	defer sdl.DestroySurface(surface)
	defer sdl.DestroyRenderer(renderer)
	defer { Game_Destroy(game); free(game) }
	rm := &game.resourceManager
	ResourceManager_SetImportSettings(rm, project.assets[:], dir, project.textureFilter)
	testing.expect(t, JoinPath(dir, "fonts/Sans.ttf") in rm.msdfFonts, "the font has an atlas")
	mode :: proc(texture: ^sdl.Texture) -> sdl.ScaleMode {
		m: sdl.ScaleMode
		_ = sdl.GetTextureScaleMode(texture, &m)
		return m
	}
	smooth := rm->loadTexture(JoinPath(dir, "assets/smooth.png"))
	plain := rm->loadTexture(JoinPath(dir, "assets/plain.png"))
	testing.expect_value(t, mode(smooth), sdl.ScaleMode.LINEAR)
	// The project's Pixel
	testing.expect_value(t, mode(plain), sdl.ScaleMode.NEAREST)
	// Changed while loaded (an editor's setting)
	ResourceManager_SetTextureFilter(rm, JoinPath(dir, "assets/plain.png"), .Smooth)
	testing.expect_value(t, mode(plain), sdl.ScaleMode.LINEAR)
	ResourceManager_SetTextureFilter(rm, JoinPath(dir, "assets/plain.png"), .Default)
	testing.expect_value(t, mode(plain), sdl.ScaleMode.NEAREST)
	// Without a project setting: Smooth, and Aseprite files Pixel
	rm.defaultFilter = .Default
	testing.expect_value(t, ResourceManager_TextureFilter(rm, "a.png"), TextureFilter.Smooth)
	testing.expect_value(t, ResourceManager_TextureFilter(rm, "a.aseprite"), TextureFilter.Pixel)
	// No longer marked: no atlas
	ResourceManager_SetImportSettings(rm, project.assets[:2], dir, .Default)
	testing.expect(t, !(JoinPath(dir, "fonts/Sans.ttf") in rm.msdfFonts), "unmarked")
}

@(test)
atlases_pack_and_sprites_draw_their_regions :: proc(t: ^testing.T) {
	// Packing: inside the picture, apart by the padding, smallest power of two
	sizes := [][2]int{{16, 16}, {32, 8}, {8, 30}, {10, 10}, {16, 16}}
	positions, size, ok := Atlas_Pack(sizes, padding = 2)
	testing.expect(t, ok, "packed")
	testing.expect(t, size.x <= 64 && size.y <= 64, "small")
	for p, i in positions {
		s := sizes[i]
		testing.expect(t, p.x >= 0 && p.y >= 0 && p.x + s.x <= size.x && p.y + s.y <= size.y, "inside")
		for q, j in positions do if j != i {
			o := sizes[j]
			apart := p.x + s.x + 2 <= q.x || q.x + o.x + 2 <= p.x || p.y + s.y + 2 <= q.y || q.y + o.y + 2 <= p.y
			testing.expectf(t, apart, "%d and %d apart", i, j)
		}
	}
	_, _, fits := Atlas_Pack({{100, 100}}, maxSize = 64)
	testing.expect(t, !fits, "too big")

	// The file round trip
	source := AtlasData{image = "atlases/items.png", filter = .Pixel, padding = 2}
	regions := []AtlasRegion{{"red", "assets/red.png", {0, 0, 4, 4}}, {"green", "assets/green.png", {6, 0, 4, 4}}}
	for r in regions do append(&source.regions, r)
	atlas := AtlasData_Clone(source)
	delete(source.regions)
	defer AtlasData_Destroy(&atlas)
	text := FormatAtlas(atlas, context.temp_allocator)
	read, err := ParseAtlas(text)
	defer AtlasData_Destroy(&read)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect(t, AtlasData_Equal(atlas, read), "read back")
	green, found := Atlas_Find(&read, "green")
	testing.expect(t, found && green.rect == {6, 0, 4, 4}, "a region")

	// A scene's Sprite drawing a region: only that part of the picture
	dir := tempFolder("engine_test_atlas")
	defer os.remove_all(dir)
	_ = os.make_directory_all(JoinPath(dir, "atlases"))
	{
		picture := sdl.CreateSurface(10, 4, .ARGB8888)
		defer sdl.DestroySurface(picture)
		_ = sdl.FillSurfaceRect(picture, &sdl.Rect{0, 0, 4, 4}, 0xffff0000)
		_ = sdl.FillSurfaceRect(picture, &sdl.Rect{6, 0, 4, 4}, 0xff00ff00)
		_ = sdl.SaveBMP(picture, strings.clone_to_cstring(JoinPath(dir, "atlases/items.png"), context.temp_allocator))
	}
	_ = os.write_entire_file(JoinPath(dir, "atlases/items.atlas.xml"), transmute([]byte)text)
	surface, renderer, game := softwareGame(16)
	defer sdl.DestroySurface(surface)
	defer sdl.DestroyRenderer(renderer)
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	data, perr := ParseScene(`<scene formatVersion="13">
	<node name="Gem" kind="Sprite" texture="atlases/items.atlas.xml" region="green" x="8" y="8" scaleX="4" scaleY="4"/>
	<node name="Missing" kind="Sprite" texture="atlases/items.atlas.xml" region="blue"/>
</scene>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, perr, ProjectError.None)
	{
		context.logger = log.nil_logger()
		_ = Scene_Build(scene, &data, dir)
		Scene_Update(scene, nil, 0)
	}
	// Code's lookups go through the game's project folder
	delete(game.projectDir)
	game.projectDir = strings.clone(dir)
	gem := cast(^Sprite)Scene_FindNode(scene, "Gem")
	testing.expect(t, gem.region == {6, 0, 4, 4}, "its region")
	bounds, _ := Node_GetLocalBounds(gem)
	testing.expect(t, bounds.w == 4 && bounds.h == 4, "the region's size")
	// The atlas's Pixel filtering reached its picture
	testing.expect_value(t, ResourceManager_TextureFilter(&game.resourceManager, JoinPath(dir, "atlases/items.png")), TextureFilter.Pixel)
	_ = sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	_ = sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	_ = sdl.RenderPresent(renderer)
	p := surfacePixel(surface, 8, 8)
	testing.expectf(t, (p >> 8) & 0xff > 0xc0 && (p >> 16) & 0xff < 0x40, "green, not red: %08x", p)
	// From code
	testing.expect(t, Sprite_SetRegion(gem, "atlases/items.atlas.xml", "red"), "another region")
	testing.expect(t, gem.region == {0, 0, 4, 4}, "red now")
	{
		context.logger = log.nil_logger()
		testing.expect(t, !Sprite_SetRegion(gem, "atlases/items.atlas.xml", "blue"), "no such region")
	}
}

// A two-glyph BMFont: "A" a 4 x 6 block, "B" the same on page 1; a kerning pair
@(private="file")
BMFONT_TEXT :: `info face="Test" size=8 bold=0 italic=0 charset="" unicode=1
common lineHeight=10 base=8 scaleW=16 scaleH=16 pages=2 packed=0
page id=0 file="test_0.png"
page id=1 file="test_1.png"
chars count=2
char id=65 x=0 y=0 width=4 height=6 xoffset=1 yoffset=2 xadvance=6 page=0 chnl=15
char id=66 x=0 y=0 width=4 height=6 xoffset=1 yoffset=2 xadvance=6 page=1 chnl=15
kernings count=1
kerning first=65 second=66 amount=-1
`

@(test)
bitmap_fonts_read_measure_and_draw :: proc(t: ^testing.T) {
	data, ok := ParseBMFont(BMFONT_TEXT)
	defer BMFontData_Destroy(&data)
	testing.expect(t, ok, "read")
	testing.expect(t, data.size == 8 && data.lineHeight == 10 && data.base == 8, "metrics")
	testing.expect(t, len(data.pages) == 2 && data.pages[1] == "test_1.png", "pages")
	testing.expect(t, len(data.chars) == 2 && data.chars[0].id == 'A' && data.chars[0].xadvance == 6, "glyphs")
	testing.expect(t, len(data.kernings) == 1 && data.kernings[0].amount == -1, "kerning")
	xml, xmlOk := ParseBMFont(`<?xml version="1.0"?>
<font><info face="Test" size="8"/><common lineHeight="10" base="8" pages="1"/>
<pages><page id="0" file="test_0.png"/></pages>
<chars count="1"><char id="65" x="0" y="0" width="4" height="6" xoffset="1" yoffset="2" xadvance="6" page="0"/></chars></font>`)
	defer BMFontData_Destroy(&xml)
	testing.expect(t, xmlOk && len(xml.chars) == 1 && xml.lineHeight == 10, "the XML kind")
	bad, notFont := ParseBMFont("hello")
	defer BMFontData_Destroy(&bad)
	testing.expect(t, !notFont, "not a font")

	dir := tempFolder("engine_test_bmfont")
	defer os.remove_all(dir)
	path := JoinPath(dir, "test.fnt")
	_ = os.write_entire_file(path, transmute([]byte)string(BMFONT_TEXT))
	writeImage(JoinPath(dir, "test_0.png"), {16, 16}, 0xffffffff)
	writeImage(JoinPath(dir, "test_1.png"), {16, 16}, 0xffffffff)
	surface, renderer, game := softwareGame(32)
	defer sdl.DestroySurface(surface)
	defer sdl.DestroyRenderer(renderer)
	defer { Game_Destroy(game); free(game) }
	rm := &game.resourceManager
	// Measured: A (6) + kerning (-1) + B (6), one line; twice the size, twice that; wrapped
	testing.expect_value(t, MeasureText(rm, "AB", path, 8), sdl.FPoint{11, 10})
	testing.expect_value(t, MeasureText(rm, "AB", path, 16), sdl.FPoint{22, 20})
	testing.expect_value(t, MeasureText(rm, "A\nB", path, 8), sdl.FPoint{6, 20})
	testing.expect_value(t, MeasureText(rm, "AA AA", path, 8, wrapWidth = 20).y, 20)
	// Drawn: glyph pictures where the layout puts them, in the text's color
	_ = sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	_ = sdl.RenderClear(renderer)
	SetDrawState(TRANSFORM2D_IDENTITY)
	DrawText(rm, {0, 0}, "AB", path, 16, {255, 0, 0, 255})
	_ = sdl.RenderPresent(renderer)
	inA := surfacePixel(surface, 4, 8)
	gap := surfacePixel(surface, 1, 1)
	inB := surfacePixel(surface, 14, 8)
	testing.expectf(t, (inA >> 16) & 0xff > 0xc0 && (inA >> 8) & 0xff < 0x40, "A drawn red: %08x", inA)
	testing.expectf(t, (gap >> 16) & 0xff < 0x40, "nothing above it: %08x", gap)
	testing.expectf(t, (inB >> 16) & 0xff > 0xc0, "B from its own page: %08x", inB)
}

@(test)
msdf_fonts_are_made_and_drawn :: proc(t: ^testing.T) {
	tools, found := ShaderTools_Find("shader_tools")
	if !found || tools.msdfAtlasGen == "" {
		log.info("No font tool (tools/build_shader_tools.sh): skipping the MSDF test")
		return
	}
	dir := tempFolder("engine_test_msdf")
	defer os.remove_all(dir)
	font := JoinPath(dir, "Sans.ttf")
	_ = os.write_entire_file(font, #load("Open_Sans/static/OpenSans-Regular.ttf"))
	if ttf.WasInit() == 0 do ttf.Init()
	messages, ok, made := Font_MakeMSDF(tools, font, JoinPath(dir, "scratch"))
	testing.expectf(t, ok && made, "made: %s", messages)
	testing.expect(t, os.exists(strings.concatenate({font, MSDF_IMAGE_SUFFIX}, context.temp_allocator)), "its picture")
	_, ok, made = Font_MakeMSDF(tools, font, JoinPath(dir, "scratch"))
	testing.expect(t, ok && !made, "up to date")

	sync.guard(&gpuTestLock)
	renderer, game := gpuGame()
	if renderer == nil {
		log.info("No GPU renderer here: skipping the MSDF drawing")
		return
	}
	defer sdl.DestroyRenderer(renderer)
	defer { Game_Destroy(game); free(game) }
	rm := &game.resourceManager
	rm.renderer = renderer
	ResourceManager_SetFontMSDF(rm, font, true)
	glyphs := glyphFontFor(rm, font)
	testing.expect(t, glyphs != nil && glyphs.msdf && len(glyphs.glyphs) > 150, "the atlas read")
	// Measured like the TrueType font, near enough (the same font)
	msdfSize := MeasureText(rm, "Hello", font, 32)
	ResourceManager_SetFontMSDF(rm, font, false)
	ttfSize := MeasureText(rm, "Hello", font, 32)
	testing.expectf(t, abs(msdfSize.x - ttfSize.x) < 4, "widths %v and %v", msdfSize, ttfSize)
	ResourceManager_SetFontMSDF(rm, font, true)
	// Drawn big: a solid stroke in the middle of an "I", clear around it
	target := sdl.CreateTexture(renderer, RENDER_TARGET_FORMAT, .TARGET, 64, 96)
	defer sdl.DestroyTexture(target)
	_ = sdl.SetRenderTarget(renderer, target)
	_ = sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	_ = sdl.RenderClear(renderer)
	SetDrawState(TRANSFORM2D_IDENTITY)
	DrawText(rm, {8, 0}, "I", font, 80, {255, 255, 255, 255})
	extent := MeasureText(rm, "I", font, 80)
	stroke := pixelAt(renderer, i32(8 + extent.x * 0.5), 48)
	beside := pixelAt(renderer, 2, 48)
	_ = sdl.SetRenderTarget(renderer, nil)
	testing.expectf(t, stroke & 0xff > 0xc0, "the stroke: %08x", stroke)
	testing.expectf(t, beside & 0xff < 0x40, "clear beside it: %08x", beside)
}
