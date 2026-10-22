#+build !js
package crossfire

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

// Shaders (shaders.odin, screen_effects.odin, shader_compile.odin): parameters read from GLSL,
// bundles, the built-in effects; drawn with SDL's GPU renderer (offscreen; skipped where there's
// no GPU): a node's shader, screen effects with and without the screen layers, the hit flash
// without the GPU renderer; Animator tracks; compiling with the shader tools when they're built

// The GPU tests take turns (SDL video, one GPU device at a time)
@(private)
gpuTestLock: sync.Mutex

TEST_SHADER :: `#version 450
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
layout(set = 2, binding = 0) uniform sampler2D u_texture;
layout(set = 3, binding = 0) uniform Params {
	float amount;      // default=0.5 min=0 max=2 label=How much
	vec2 offset;       // default=1, 2
	vec3 axis;
	vec4 tint;         // color default=#ff8000 label=Tint color
	vec4 plain;        // default=1,2,3,4
	float time;
	vec2 texelSize;
};
void main() { o_color = texture(u_texture, v_uv) * v_color * amount; }
`

@(test)
shader_parameters_and_bundles :: proc(t: ^testing.T) {
	params, size, problem := Shader_ParseParams(TEST_SHADER)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(params), 7)
	// std140: float 0, vec2 8, vec3 16, vec4 32, vec4 48, float 64, vec2 72; 80 rounded to 16
	offsets := []int{0, 8, 16, 32, 48, 64, 72}
	for p, i in params do testing.expectf(t, p.offset == offsets[i], "%s at %d, not %d", p.name, p.offset, offsets[i])
	testing.expect_value(t, size, 80)
	testing.expect_value(t, params[0].value, [4]f32{0.5, 0, 0, 0})
	testing.expect_value(t, params[0].max, 2)
	testing.expect_value(t, params[0].label, "How much")
	testing.expect_value(t, params[1].value, [4]f32{1, 2, 0, 0})
	testing.expect_value(t, params[3].type, ShaderParamType.Color)
	testing.expect_value(t, params[3].label, "Tint color")
	testing.expect_value(t, params[3].value, [4]f32{1, f32(0x80) / 255, 0, 1})
	testing.expect_value(t, params[4].type, ShaderParamType.Vec4)
	testing.expect_value(t, params[4].value, [4]f32{1, 2, 3, 4})
	testing.expect(t, params[5].builtin && params[6].builtin && !params[0].builtin, "time and texelSize are the engine's")
	_, _, bad := Shader_ParseParams("layout(set = 3, binding = 0) uniform Params { mat4 m; };")
	testing.expect(t, strings.contains(bad, "mat4"), "an unsupported type is named")

	// Values as text
	v, ok := ShaderParam_Parse(.Color, "#ff000080")
	testing.expect(t, ok && v == {1, 0, 0, f32(0x80) / 255}, "a color")
	testing.expect_value(t, ShaderParam_Format(.Vec2, {1, 2.5, 0, 0}), "1, 2.5")
	testing.expect_value(t, ShaderParam_Format(.Color, {1, 0, 0, 1}), "#ff0000")
	_, bad2 := ShaderParam_Parse(.Float, "nope")
	testing.expect(t, !bad2, "not a number")

	// A bundle survives its file
	bundle := ShaderBundle{version = SHADER_BUNDLE_VERSION, params = params, uniformSize = size, samplers = 1, uniformBuffers = 1, spirv = {1, 2, 3}, msl = {4, 5}}
	text := Shader_FormatBundle(bundle)
	back, read := Shader_ParseBundle(transmute([]byte)text, context.temp_allocator)
	testing.expect(t, read, "read back")
	testing.expect_value(t, len(back.params), 7)
	testing.expect_value(t, back.params[3].label, "Tint color")
	testing.expect_value(t, back.params[6].offset, 72)
	testing.expect(t, len(back.spirv) == 3 && back.spirv[2] == 3, "the code")
	testing.expect_value(t, back.samplers, 1)

	// Every built-in effect loads, with its parameters
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	for b in BuiltinShader {
		program := Game_LoadShader(game, fmt.tprintf("builtin:%v", b))
		testing.expectf(t, program != nil && len(program.bundle.spirv) > 0 && len(program.bundle.msl) > 0, "builtin:%v loads", b)
	}
	flash := Game_LoadShader(game, "builtin:hit_flash")
	testing.expect_value(t, flash.bundle.params[1].name, "amount")
	testing.expect(t, Game_LoadShader(game, "builtin:hit_flash") == flash, "loaded once")
	{
		context.logger = log.nil_logger()
		testing.expect(t, Game_LoadShader(game, "assets/missing.frag") == nil, "not compiled")
	}
}

@(test)
node_shaders_parameters_and_animator_tracks :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	node := CreateNode(scene, Node)
	testing.expect(t, Node_SetShader(node, "builtin:hit_flash"), "set")
	testing.expect(t, Node_SetShaderParam(node, "amount", 0.75), "amount")
	testing.expect(t, Node_SetShaderParam(node, "flashColor", sdl.Color{255, 0, 0, 255}), "color")
	testing.expect(t, !Node_SetShaderParam(node, "nope", 1), "unknown")
	v, _ := Node_GetShaderParam(node, "amount")
	testing.expect_value(t, v[0], 0.75)
	// The Animator's properties and live writes see them
	props := Node_Properties(node, context.temp_allocator)
	has := false
	for p in props do if p == "shader.amount" do has = true
	testing.expect(t, has, "shader.amount is a property")
	testing.expect(t, Node_WriteProperty(node, "shader.amount", "0.25"), "written")
	v, _ = Node_GetShaderParam(node, "amount")
	testing.expect_value(t, v[0], 0.25)
	text, ok := Animator_ReadProperty(node, "shader.flashColor", context.temp_allocator)
	testing.expect(t, ok && text == "#ff0000", "a color reads back")

	// A scene file: the shader, its parameters, and an Animator flashing it
	data, err := ParseScene(`<scene formatVersion="13">
	<node name="Hero" kind="Node2D" shader="builtin:hit_flash"><shaderParam name="amount" value="0.5"/><shaderParam name="flashColor" value="#00ff00"/></node>
	<node name="Flash" kind="Animator" autoplay="hit" parent="Hero">
		<clip name="hit" length="1"><track path="." property="shader.amount"><key time="0" value="1"/><key time="1" value="0"/></track></clip>
	</node>
	<node name="TV" kind="ScreenEffect" shader="builtin:crt" effectScreenLayers="false"/>
</scene>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, data.nodes[0].shader, "builtin:hit_flash")
	testing.expect_value(t, len(data.nodes[0].shaderParams), 2)
	scene2 := game->createScene("S2")
	_ = Scene_Build(scene2, &data, "testdata")
	Scene_Update(scene2, nil, 0)
	hero := Scene_FindNode(scene2, "Hero")
	testing.expect(t, hero != nil && hero.shader != nil, "built with its shader")
	color, _ := Node_GetShaderParam(hero, "flashColor")
	testing.expect_value(t, color, [4]f32{0, 1, 0, 1})
	Scene_Update(scene2, nil, 0.5)
	amount, _ := Node_GetShaderParam(hero, "amount")
	testing.expectf(t, amount[0] > 0.3 && amount[0] < 0.7, "the Animator fades it: %v", amount[0])
	tv := cast(^ScreenEffect)Scene_FindNode(scene2, "TV")
	testing.expect(t, tv != nil && tv.shader != nil && !tv.includeScreenLayers, "a screen effect")
	testing.expect_value(t, len(scene2.screenEffects), 1)
	Scene_RemoveNode(scene2, tv.id)
	Scene_Update(scene2, nil, 0)
	testing.expect_value(t, len(scene2.screenEffects), 0)
}

// An offscreen GPU renderer and a game drawing with it (nil, nil when there's no GPU here). SDL
// video stays initialized: quitting it destroys every renderer, other tests' software ones too
// (a segfault on macOS CI, where the GPU tests run)
@(private)
gpuGame :: proc() -> (^sdl.Renderer, ^Game) {
	if !sdl.InitSubSystem({.VIDEO}) do return nil, nil
	// As games get it: Vulkan on Windows (its default, Direct3D 12, takes neither SPIR-V nor MSL)
	when ODIN_OS == .Windows do _ = sdl.SetHint(sdl.HINT_GPU_DRIVER, "vulkan")
	renderer := sdl.CreateGPURenderer(nil, nil)
	when ODIN_OS == .Windows do _ = sdl.ResetHint(sdl.HINT_GPU_DRIVER)
	// No GPU, or one that can't run these shaders (CI's runners): the test is skipped
	if renderer != nil && !Renderer_SupportsShaders(renderer) {
		sdl.DestroyRenderer(renderer)
		renderer = nil
	}
	if renderer == nil do return nil, nil
	game := testGame("testdata")
	game.renderer = renderer
	return renderer, game
}

@(private="file")
solidTexture :: proc(renderer: ^sdl.Renderer, color: u32, size: i32 = 8) -> ^sdl.Texture {
	texture := sdl.CreateTexture(renderer, .BGRA32, .STATIC, size, size)
	pixels := make([]u32, size * size, context.temp_allocator)
	for &p in pixels do p = color
	_ = sdl.UpdateTexture(texture, nil, raw_data(pixels), size * 4)
	return texture
}

// The target's pixel (BGRA32: 0xAARRGGBB)
@(private)
pixelAt :: proc(renderer: ^sdl.Renderer, x, y: i32) -> u32 {
	surface := sdl.RenderReadPixels(renderer, nil)
	if surface == nil do return 0
	defer sdl.DestroySurface(surface)
	converted := sdl.ConvertSurface(surface, .ARGB8888)
	defer sdl.DestroySurface(converted)
	return (cast([^]u32)converted.pixels)[y * (converted.pitch / 4) + x]
}

@(test)
shaders_draw_with_the_gpu_renderer :: proc(t: ^testing.T) {
	sync.guard(&gpuTestLock)
	renderer, game := gpuGame()
	if renderer == nil {
		log.info("No GPU renderer here: skipping the shader drawing test")
		return
	}
	defer sdl.DestroyRenderer(renderer)
	defer { Game_Destroy(game); free(game) }
	testing.expect(t, Renderer_SupportsShaders(renderer), "the GPU renderer runs shaders")
	target := sdl.CreateTexture(renderer, RENDER_TARGET_FORMAT, .TARGET, 32, 16)
	defer sdl.DestroyTexture(target)
	_ = sdl.SetRenderTarget(renderer, target)
	red := solidTexture(renderer, 0xffff0000)
	defer sdl.DestroyTexture(red)

	// A node's hit flash: the left half flashes green, the right half draws as it is
	scene := game->createScene("S")
	flash := CreateNode(scene, Node)
	Node_SetShader(flash, "builtin:hit_flash")
	Node_SetShaderParam(flash, "flashColor", sdl.Color{0, 255, 0, 255})
	Node_SetShaderParam(flash, "amount", 1)
	_ = sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
	_ = sdl.RenderClear(renderer)
	SetDrawState(TRANSFORM2D_IDENTITY)
	drawState().material = flash.shader
	DrawTexture(renderer, red, {0, 0, 16, 16})
	drawState().material = nil
	DrawTexture(renderer, red, {16, 0, 16, 16})
	testing.expectf(t, pixelAt(renderer, 4, 8) == 0xff00ff00, "flashed green: %08x", pixelAt(renderer, 4, 8))
	testing.expectf(t, pixelAt(renderer, 24, 8) == 0xffff0000, "plain red: %08x", pixelAt(renderer, 24, 8))
	// Half way: between
	Node_SetShaderParam(flash, "amount", 0.5)
	drawState().material = flash.shader
	DrawTexture(renderer, red, {0, 0, 16, 16})
	drawState().material = nil
	p := pixelAt(renderer, 4, 8)
	testing.expectf(t, (p >> 16) & 0xff > 100 && (p >> 8) & 0xff > 100, "half flashed: %08x", p)

	// A screen effect: color grading to gray over the world, not the HUD on its screen layer
	world := CreateNode(scene, Sprite)
	world.texture = red
	world.draw = Sprite_draw
	world.position = {8, 8}
	hud := CreateNode(scene, Sprite)
	hud.texture = red
	hud.draw = Sprite_draw
	hud.position = {24, 8}
	hud.layer = .Layer8
	scene.screenLayers = {.Layer8}
	gray := CreateScreenEffect(scene, "builtin:color_grade")
	Node_SetShaderParam(gray, "saturation", 0)
	gray.includeScreenLayers = false
	Scene_Update(scene, nil, 0)
	_ = sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	w := pixelAt(renderer, 8, 8)
	r, g, b := (w >> 16) & 0xff, (w >> 8) & 0xff, w & 0xff
	testing.expectf(t, r == g && g == b && r > 20, "the world is gray: %08x", w)
	testing.expectf(t, pixelAt(renderer, 24, 8) == 0xffff0000, "the HUD isn't: %08x", pixelAt(renderer, 24, 8))
	// Covering the screen layers too
	gray.includeScreenLayers = true
	_ = sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	h := pixelAt(renderer, 24, 8)
	testing.expectf(t, (h >> 16) & 0xff == (h >> 8) & 0xff, "now the HUD is gray too: %08x", h)
	// Hidden: no effect
	gray.visible = false
	_ = sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	testing.expectf(t, pixelAt(renderer, 8, 8) == 0xffff0000, "a hidden effect does nothing: %08x", pixelAt(renderer, 8, 8))
	_ = sdl.SetRenderTarget(renderer, nil)
}

@(test)
hit_flash_without_the_gpu_renderer :: proc(t: ^testing.T) {
	surface := sdl.CreateSurface(16, 16, .ARGB8888)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	node := CreateNode(scene, Node)
	Node_SetShader(node, "builtin:hit_flash")
	Node_SetShaderParam(node, "amount", 1)
	dark := solidTexture(renderer, 0xff400000)
	defer sdl.DestroyTexture(dark)
	testing.expect(t, !Renderer_SupportsShaders(renderer), "software draws no shaders")
	SetDrawState(TRANSFORM2D_IDENTITY)
	{
		context.logger = log.nil_logger()
		drawState().material = node.shader
		DrawTexture(renderer, dark, {0, 0, 16, 16})
		drawState().material = nil
	}
	_ = sdl.RenderPresent(renderer)
	p := (cast([^]u32)surface.pixels)[8 * 16 + 8]
	// Without the GPU renderer: the picture added again, brighter (an approximation of the flash)
	testing.expectf(t, (p >> 16) & 0xff >= 0x7f, "the flash brightens it: %08x", p)
}

@(test)
shaders_compile_with_the_tools :: proc(t: ^testing.T) {
	tools, found := ShaderTools_Find("shader_tools")
	if !found {
		log.info("No shader tools (tools/build_shader_tools.sh): skipping the compile test")
		return
	}
	dir := tempFolder("engine_test_shaders")
	defer os.remove_all(dir)
	bundle, messages, ok := Shader_Compile(tools, TEST_SHADER, "assets/test.frag", JoinPath(dir, "scratch"))
	testing.expectf(t, ok, "compiled: %s", messages)
	testing.expect(t, len(bundle.spirv) > 0 && len(bundle.msl) > 0, "SPIR-V and MSL")
	testing.expect(t, strings.contains(string(bundle.msl), "main0"), "Metal's entry point")
	testing.expect_value(t, bundle.samplers, 1)
	testing.expect_value(t, bundle.uniformBuffers, 1)
	testing.expect_value(t, bundle.uniformSize, 80)
	// A mistake: the file's own name and line
	broken, _ := strings.replace(TEST_SHADER, "o_color = texture", "o_color = textur", 1, context.temp_allocator)
	_, messages, ok = Shader_Compile(tools, broken, "assets/test.frag", JoinPath(dir, "scratch"))
	testing.expect(t, !ok, "doesn't compile")
	testing.expectf(t, strings.contains(messages, "assets/test.frag:15:"), "says where: %s", messages)
	// A file: compiled beside it, then up to date
	path := JoinPath(dir, "wave.frag")
	_ = os.write_entire_file(path, transmute([]byte)string(TEST_SHADER))
	m, good, compiled := Shader_CompileFile(tools, path, "wave.frag", JoinPath(dir, "scratch"))
	testing.expectf(t, good && compiled, "compiled the file: %s", m)
	testing.expect(t, os.exists(strings.concatenate({path, ".shader"}, context.temp_allocator)), "its .shader")
	_, good, compiled = Shader_CompileFile(tools, path, "wave.frag", JoinPath(dir, "scratch"))
	testing.expect(t, good && !compiled, "up to date")
	// The game loads it from the project folder
	game := testGame(dir)
	defer { Game_Destroy(game); free(game) }
	program := Game_LoadShader(game, "wave.frag")
	testing.expect(t, program != nil && len(program.bundle.params) == 7, "loaded")
}
