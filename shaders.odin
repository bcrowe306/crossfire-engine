package crossfire

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
Shaders: small GPU programs that change how a node's pictures are drawn (a hit flash, an outline,
dissolving away, swapped colors), and screen effects over the whole scene (CRT, bloom, color
grading).

- **On a node** (`Node_SetShader`, a scene file's `shader` attribute and `<shaderParam>` children):
  the shader colors every pixel the node draws from an image or text (sprites, animated sprites,
  tilemaps, labels, textured particles), and its children's, unless a child has a shader of its
  own (a shader on a character's body colors the sprite under it). Shapes drawn with lines and
  fills aren't affected.
- **On the screen** (a ScreenEffect node): the scene is drawn into a picture first, then drawn
  through the shader. Several ScreenEffects run one after the other.
- **Built-in effects** (`builtin:hit_flash`, `builtin:outline`, `builtin:dissolve`,
  `builtin:palette_swap`, `builtin:crt`, `builtin:bloom`, `builtin:color_grade`) ship with the
  engine; **your own** are GLSL fragment shaders in the project (assets of kind "Shader",
  `.frag`), compiled by the editor into a `.frag.shader` file beside them (shader_compile.odin).
- **Parameters** are the members of the shader's `Params` uniform block (std140): floats,
  vec2, vec3, vec4 (a color when its comment says `color`). Their comments give a default and a
  range for editors: `float amount; // default=0.5 min=0 max=1`. Names `time`, `texelSize` and
  `textureSize` are filled by the engine: seconds the game has run, 1 / the picture's size in
  pixels, the picture's size. `Node_SetShaderParam` sets the others, and so can an Animator
  (`shader.<name>` tracks).

**Where shaders run:** SDL's GPU renderer only (the project's Renderer set to GPU; Auto picks it
when the project has shaders: Game_LoadProject). Shaders are SPIR-V (Vulkan: Linux, Windows) and
MSL (Metal: macOS); on Windows the GPU renderer is asked for Vulkan. On other renderers, and on
the web, nodes draw as if they had no shader (logged once), except `builtin:hit_flash`, which
draws the picture a second time added in the flash color: it brightens (an approximation).

`Params` must be used by `main` for the engine to fill it: the compiler drops a block nothing
reads.

A shader written for it (the inputs and outputs SDL's renderer gives every fragment shader):

	#version 450
	layout(location = 0) in vec4 v_color;   // the vertex color: tint and opacity
	layout(location = 1) in vec2 v_uv;      // where in the picture, 0 to 1
	layout(location = 0) out vec4 o_color;
	layout(set = 2, binding = 0) uniform sampler2D u_texture;
	layout(set = 3, binding = 0) uniform Params {
		float amount;     // default=1 min=0 max=1
		vec4 tint;        // color default=#ff0000
		float time;       // filled by the engine
	};
	void main() {
		vec4 c = texture(u_texture, v_uv) * v_color;
		o_color = vec4(mix(c.rgb, tint.rgb, amount * (0.5 + 0.5 * sin(time * 6.0))), c.a);
	}

Example:
	// Given: hero: ^e.Sprite
	e.Node_SetShader(hero, "builtin:hit_flash")
	e.Node_SetShaderParam(hero, "amount", 1)
*/

// A shader parameter's type
ShaderParamType :: enum {
	Float,
	Vec2,
	Vec3,
	Vec4,
	// A vec4 shown as a color (its comment says `color`)
	Color,
}

// A shader parameter: a member of its `Params` block
ShaderParam :: struct {
	// Its name in the shader
	name: string,
	// Its type
	type: ShaderParamType,
	// Its byte offset in the uniform block (std140)
	offset: int,
	// Its default (unused components 0), and the range editors give it
	value: [4]f32,
	min, max: f32,
	// What editors call it ("" its name)
	label: string,
	// The engine fills it (`time`, `texelSize`, `textureSize`): editors don't show it
	builtin: bool,
}

// A shader's stage: what it computes
ShaderStage :: enum {
	// Each pixel's color (nodes' and screen effects' shaders)
	Fragment,
	// Each vertex's position (the engine's own: GPU particles)
	Vertex,
}

// A compiled shader: what a `.frag.shader` (or `.vert.shader`) file holds
ShaderBundle :: struct {
	// The format of the file
	version: int,
	// Its stage
	stage: ShaderStage,
	// How many storage buffers it reads (vertex shaders: the engine's GPU particles)
	storageBuffers: int,
	// Its parameters, and the size of its uniform block in bytes (0: none)
	params: []ShaderParam,
	uniformSize: int,
	// How many samplers (textures) and uniform blocks it uses
	samplers, uniformBuffers: int,
	// The code: SPIR-V and MSL (base64 in the file)
	spirv, msl: []byte,
}

// A loaded shader (Game_LoadShader), shared by every node using it
ShaderProgram :: struct {
	// Its path ("builtin:outline", or a project path)
	path: string,
	bundle: ShaderBundle,
	// It couldn't be made on a renderer (logged once)
	failed: bool,
	// The GPU shader made per GPU device
	gpu: [dynamic]ShaderOnDevice,
}

// A shader's code on one GPU device
@(private)
ShaderOnDevice :: struct {
	device: ^sdl.GPUDevice,
	shader: ^sdl.GPUShader,
}

// A node's shader and its parameter values (`Node.shader`)
ShaderMaterial :: struct {
	program: ^ShaderProgram,
	// One per parameter, in the program's order
	values: [dynamic][4]f32,
	// The render state made per renderer (SDL keeps uniform values per state)
	states: [dynamic]ShaderState,
}

@(private)
ShaderState :: struct {
	renderer: ^sdl.Renderer,
	state: ^sdl.GPURenderState,
}

// The file format version `Shader_Compile` writes
SHADER_BUNDLE_VERSION :: 1

// The built-in effects (shaders/builtin/<name>.frag, compiled by tools/compile_shaders)
BuiltinShader :: enum {
	hit_flash,
	outline,
	dissolve,
	palette_swap,
	crt,
	bloom,
	color_grade,
}

// What each built-in effect does, and whether it's for the screen (a ScreenEffect) or a node
BUILTIN_SHADER_INFO := [BuiltinShader]struct { description: string, screen: bool }{
	.hit_flash    = {"Flashes the picture toward a color: hits, pickups", false},
	.outline      = {"Draws a line around the picture's opaque pixels: selection, highlights", false},
	.dissolve     = {"Eats the picture away in a noisy pattern with a glowing edge: deaths, teleports", false},
	.palette_swap = {"Replaces up to four colors with others: team colors, skins", false},
	.crt          = {"An old TV: scanlines, curved glass, a dark border", true},
	.bloom        = {"Bright parts glow into their surroundings", true},
	.color_grade  = {"Brightness, contrast, saturation, tint and a vignette over the scene", true},
}

@(private="file")
BUILTIN_SHADER_FILES := [BuiltinShader][]byte{
	.hit_flash    = #load("shaders/builtin/hit_flash.frag.shader"),
	.outline      = #load("shaders/builtin/outline.frag.shader"),
	.dissolve     = #load("shaders/builtin/dissolve.frag.shader"),
	.palette_swap = #load("shaders/builtin/palette_swap.frag.shader"),
	.crt          = #load("shaders/builtin/crt.frag.shader"),
	.bloom        = #load("shaders/builtin/bloom.frag.shader"),
	.color_grade  = #load("shaders/builtin/color_grade.frag.shader"),
}

// The prefix of a built-in effect's path ("builtin:outline")
SHADER_BUILTIN_PREFIX :: "builtin:"

/*
A built-in effect's path from its name, and the name from a path.

Inputs:
- path: "builtin:outline"

Returns:
- The effect, and whether the path is one
*/
Shader_BuiltinOf :: proc(path: string) -> (BuiltinShader, bool) {
	if !strings.has_prefix(path, SHADER_BUILTIN_PREFIX) do return {}, false
	name := path[len(SHADER_BUILTIN_PREFIX):]
	for b in BuiltinShader do if fmt.tprint(b) == name do return b, true
	return {}, false
}

/*
A built-in effect's compiled bundle (its parameters: what editors show).

Returns:
- The bundle (temp allocated), and false if it can't be read
*/
Shader_BuiltinBundle :: proc(b: BuiltinShader) -> (ShaderBundle, bool) {
	return Shader_ParseBundle(BUILTIN_SHADER_FILES[b], context.temp_allocator)
}

/*
Frees the game's shaders' GPU code: call before destroying the renderer when a game isn't
destroyed with Game_Destroy (editors' previews). Game_Destroy does it.
*/
Game_ReleaseShaders :: proc(game: ^Game) {
	if game != nil do shadersDestroy(game)
}

/*
Reads a compiled shader (a `.frag.shader` file's text) into a bundle allocated with `allocator`.

Returns:
- The bundle, and false when the text isn't one (or another version)
*/
Shader_ParseBundle :: proc(text: []byte, allocator := context.allocator) -> (bundle: ShaderBundle, ok: bool) {
	File :: struct {
		version: int,
		stage: ShaderStage,
		storageBuffers: int,
		params: []struct { name: string, type: ShaderParamType, offset: int, value: [4]f32, min, max: f32, label: string, builtin: bool },
		uniformSize: int,
		samplers, uniformBuffers: int,
		spirv, msl: string,
	}
	file: File
	if json.unmarshal(text, &file, allocator = context.temp_allocator) != nil do return {}, false
	if file.version != SHADER_BUNDLE_VERSION do return {}, false
	bundle.version = file.version
	bundle.stage, bundle.storageBuffers = file.stage, file.storageBuffers
	bundle.uniformSize = file.uniformSize
	bundle.samplers, bundle.uniformBuffers = file.samplers, file.uniformBuffers
	bundle.params = make([]ShaderParam, len(file.params), allocator)
	for p, i in file.params {
		bundle.params[i] = {strings.clone(p.name, allocator), p.type, p.offset, p.value, p.min, p.max, strings.clone(p.label, allocator), p.builtin}
	}
	spirv, e1 := base64.decode(file.spirv, allocator = allocator)
	msl, e2 := base64.decode(file.msl, allocator = allocator)
	if e1 != nil || e2 != nil do return {}, false
	bundle.spirv, bundle.msl = spirv, msl
	return bundle, true
}

/*
Writes a bundle as a `.frag.shader` file's text (temp allocated).
*/
Shader_FormatBundle :: proc(bundle: ShaderBundle) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "{{\n\t\"version\": %d,\n\t\"stage\": %q,\n\t\"storageBuffers\": %d,\n\t\"uniformSize\": %d,\n\t\"samplers\": %d,\n\t\"uniformBuffers\": %d,\n\t\"params\": [",
		bundle.version, fmt.tprint(bundle.stage), bundle.storageBuffers, bundle.uniformSize, bundle.samplers, bundle.uniformBuffers)
	for p, i in bundle.params {
		fmt.sbprintf(&b, "%s\n\t\t{{\"name\": %q, \"type\": %q, \"offset\": %d, \"value\": [%v, %v, %v, %v], \"min\": %v, \"max\": %v, \"label\": %q, \"builtin\": %v}",
			i == 0 ? "" : ",", p.name, fmt.tprint(p.type), p.offset, p.value[0], p.value[1], p.value[2], p.value[3], p.min, p.max, p.label, p.builtin)
	}
	fmt.sbprintf(&b, "\n\t],\n\t\"spirv\": %q,\n\t\"msl\": %q\n}}\n",
		base64.encode(bundle.spirv, allocator = context.temp_allocator), base64.encode(bundle.msl, allocator = context.temp_allocator))
	return strings.to_string(b)
}

/*
The parameters of a GLSL fragment shader: the members of its uniform block at set 3, binding 0
(`Params`), with std140 offsets and what their comments say (`default=`, `min=`, `max=`,
`label=`, `color`). Names the engine fills (`time`, `texelSize`, `textureSize`) are marked
`builtin`.

Inputs:
- source: The shader's text

Returns:
- The parameters (temp allocated) and the block's size in bytes; `problem` names what couldn't be
  read ("" when fine)
*/
Shader_ParseParams :: proc(source: string) -> (params: []ShaderParam, size: int, problem: string) {
	list := make([dynamic]ShaderParam, context.temp_allocator)
	// The block: `uniform <Name> {` after a layout naming set = 3
	start := -1
	rest := source
	for {
		i := strings.index(rest, "uniform")
		if i < 0 do break
		before := source[:len(source) - len(rest) + i]
		lineStart := strings.last_index_byte(before, '\n') + 1
		line := source[lineStart:len(source) - len(rest) + i]
		after := rest[i + len("uniform"):]
		brace := strings.index_byte(after, '{')
		semi := strings.index_byte(after, ';')
		if brace >= 0 && (semi < 0 || brace < semi) && strings.contains(strings.to_lower(line, context.temp_allocator), "set") && strings.contains(line, "3") {
			start = len(source) - len(after) + brace + 1
			break
		}
		rest = after
	}
	if start < 0 do return nil, 0, ""
	end := strings.index_byte(source[start:], '}')
	if end < 0 do return nil, 0, "the Params block has no closing brace"
	body := source[start:start + end]
	offset := 0
	for raw in strings.split_lines_iterator(&body) {
		code, _, comment := strings.partition(raw, "//")
		code = strings.trim_space(code)
		if code == "" do continue
		decl := strings.trim_suffix(code, ";")
		fields := strings.fields(decl, context.temp_allocator)
		if len(fields) != 2 do return nil, 0, fmt.tprintf("can't read %q in Params (one `type name;` a line)", code)
		p := ShaderParam{name = fields[1], min = 0, max = 1}
		align, bytes: int
		switch fields[0] {
		case "float": p.type, align, bytes = .Float, 4, 4
		case "vec2":  p.type, align, bytes = .Vec2, 8, 8
		case "vec3":  p.type, align, bytes = .Vec3, 16, 12
		case "vec4":  p.type, align, bytes = .Vec4, 16, 16
		case: return nil, 0, fmt.tprintf("%s in Params: use float, vec2, vec3 or vec4", fields[0])
		}
		offset = (offset + align - 1) / align * align
		p.offset = offset
		offset += bytes
		// Its comment: default=, min=, max=, label=, color
		readParamComment(&p, comment)
		switch p.name {
		case "time", "texelSize", "textureSize": p.builtin = true
		}
		append(&list, p)
	}
	// std140: a block's size rounds up to 16
	size = (offset + 15) / 16 * 16
	return list[:], size, ""
}

/*
Loads a shader for the game (once: later calls return the same one).

Inputs:
- game: The game
- path: "builtin:<name>", or a project shader's path (its compiled `<path>.shader` is read)

Returns:
- The shader, or nil (logged) when it isn't there or can't be read
*/
Game_LoadShader :: proc(game: ^Game, path: string) -> ^ShaderProgram {
	if game == nil || path == "" do return nil
	if p, found := game.shaders[path]; found do return p
	allocator := Game_GetAllocator(game)
	data: []byte
	if b, builtin := Shader_BuiltinOf(path); builtin {
		data = BUILTIN_SHADER_FILES[b]
	} else {
		full := game.projectDir == "" ? path : JoinPath(game.projectDir, path)
		file, ok := Platform_ReadFile(fmt.tprintf("%s.shader", full))
		if !ok {
			log.warnf("Shader %s isn't compiled (no %s.shader): the editor compiles it on save", path, path)
			return nil
		}
		data = file
	}
	bundle, ok := Shader_ParseBundle(data, allocator)
	if !ok {
		log.warnf("Shader %s can't be read (compile it again)", path)
		return nil
	}
	program := new(ShaderProgram, allocator)
	program.path = strings.clone(path, allocator)
	program.bundle = bundle
	if game.shaders == nil do game.shaders = make(map[string]^ShaderProgram, allocator = allocator)
	game.shaders[program.path] = program
	return program
}

/*
Gives a node a shader (replacing its own), with the shader's default parameters.

Inputs:
- node: The node
- path: "builtin:<name>", a project shader's path, or "" for none

Returns:
- Whether it has the shader now
*/
Node_SetShader :: proc(node: ^Node, path: string) -> bool {
	if node == nil do return false
	if node.shader != nil {
		shaderMaterialDestroy(node.shader)
		node.shader = nil
	}
	if path == "" do return true
	game := node.scene != nil ? node.scene.game : nil
	program := Game_LoadShader(game, path)
	if program == nil do return false
	allocator := Node_GetAllocator(node)
	m := new(ShaderMaterial, allocator)
	m.program = program
	m.values = make([dynamic][4]f32, len(program.bundle.params), allocator)
	for p, i in program.bundle.params do m.values[i] = p.value
	m.states = make([dynamic]ShaderState, allocator)
	node.shader = m
	return true
}

/*
Sets one of a node's shader parameters.

Inputs:
- node: The node (with a shader)
- name: The parameter
- value: A number, a 2, 3 or 4 component vector, or a color

Returns:
- Whether the node's shader has that parameter

Example:
	// Given: hero: ^e.Sprite with builtin:hit_flash
	e.Node_SetShaderParam(hero, "amount", 1)
	e.Node_SetShaderParam(hero, "flashColor", sdl.Color{255, 80, 80, 255})
*/
Node_SetShaderParam :: proc{shaderParamFloat, shaderParamVec2, shaderParamVec4, shaderParamColor}

/*
Sets one of a node's shader parameters from text (`ShaderParam_Parse`): what scene files and
editors give.

Returns:
- Whether the node's shader has that parameter and the text is a value of it
*/
Node_SetShaderParamText :: proc(node: ^Node, name, text: string) -> bool {
	if node == nil || node.shader == nil do return false
	for p, i in node.shader.program.bundle.params do if p.name == name {
		value, ok := ShaderParam_Parse(p.type, text)
		if ok do node.shader.values[i] = value
		return ok
	}
	return false
}

// Puts every one of a node's shader parameters back to the shader's defaults
Node_ResetShaderParams :: proc(node: ^Node) {
	if node == nil || node.shader == nil do return
	for p, i in node.shader.program.bundle.params do node.shader.values[i] = p.value
}

/*
One of a node's shader parameters (all four components; a float's is the first).

Returns:
- The value, and whether the node's shader has that parameter
*/
Node_GetShaderParam :: proc(node: ^Node, name: string) -> ([4]f32, bool) {
	if node == nil || node.shader == nil do return {}, false
	for p, i in node.shader.program.bundle.params do if p.name == name do return node.shader.values[i], true
	return {}, false
}

/*
A shader parameter's value from text: "0.5", "1, 2", "1, 0, 0, 1", or a color ("#ff8000",
"#ff800080").

Returns:
- The four components (missing ones 0; a color's alpha 1 unless given), and whether it read
*/
ShaderParam_Parse :: proc(type: ShaderParamType, text: string) -> ([4]f32, bool) {
	t := strings.trim_space(text)
	if strings.has_prefix(t, "#") {
		c, ok := ParseColor(t)
		if !ok do return {}, false
		return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}, true
	}
	out: [4]f32
	n := 0
	rest := t
	for part in strings.split_iterator(&rest, ",") {
		if n >= 4 do return {}, false
		v, ok := strconv.parse_f32(strings.trim_space(part))
		if !ok do return {}, false
		out[n] = v
		n += 1
	}
	if n == 0 do return {}, false
	return out, true
}

/*
A shader parameter's value as text (temp allocated): a number, comma-separated components, or a
color (`#rrggbbaa`) for colors.
*/
ShaderParam_Format :: proc(type: ShaderParamType, value: [4]f32) -> string {
	switch type {
	case .Float: return fmt.tprint(value[0])
	case .Vec2:  return fmt.tprintf("%v, %v", value[0], value[1])
	case .Vec3:  return fmt.tprintf("%v, %v, %v", value[0], value[1], value[2])
	case .Vec4:  return fmt.tprintf("%v, %v, %v, %v", value[0], value[1], value[2], value[3])
	case .Color:
		c := sdl.Color{u8(clamp(value[0], 0, 1) * 255 + 0.5), u8(clamp(value[1], 0, 1) * 255 + 0.5), u8(clamp(value[2], 0, 1) * 255 + 0.5), u8(clamp(value[3], 0, 1) * 255 + 0.5)}
		return FormatColor(c, context.temp_allocator)
	}
	return ""
}

/*
Whether a renderer runs shaders: SDL's GPU renderer, on a device taking SPIR-V or MSL.
*/
Renderer_SupportsShaders :: proc(renderer: ^sdl.Renderer) -> bool {
	if renderer == nil do return false
	device := sdl.GetGPURendererDevice(renderer)
	if device == nil do return false
	formats := sdl.GetGPUShaderFormats(device)
	return .SPIRV in formats || .MSL in formats
}

// INTERNAL

@(private="file")
shaderParamFloat :: proc(node: ^Node, name: string, value: f32) -> bool { return shaderParamSet(node, name, {value, 0, 0, 0}) }
@(private="file")
shaderParamVec2 :: proc(node: ^Node, name: string, value: [2]f32) -> bool { return shaderParamSet(node, name, {value.x, value.y, 0, 0}) }
@(private="file")
shaderParamVec4 :: proc(node: ^Node, name: string, value: [4]f32) -> bool { return shaderParamSet(node, name, value) }
@(private="file")
shaderParamColor :: proc(node: ^Node, name: string, value: sdl.Color) -> bool {
	return shaderParamSet(node, name, {f32(value.r) / 255, f32(value.g) / 255, f32(value.b) / 255, f32(value.a) / 255})
}

@(private="file")
shaderParamSet :: proc(node: ^Node, name: string, value: [4]f32) -> bool {
	if node == nil || node.shader == nil do return false
	for p, i in node.shader.program.bundle.params do if p.name == name {
		node.shader.values[i] = value
		return true
	}
	return false
}

// A parameter's comment: `color default=#ff0000 min=0 max=1 label=Glow strength` (the label runs
// to the next key or the end; `color` is a word of its own, outside the label)
@(private="file")
readParamComment :: proc(p: ^ShaderParam, comment: string) {
	text := strings.trim_space(comment)
	keys := []string{"default=", "min=", "max=", "label="}
	// Where each key's value ends: at the next key
	valueOf :: proc(text, key: string, keys: []string) -> (value: string, start, end: int, ok: bool) {
		i := strings.index(text, key)
		if i < 0 do return "", 0, 0, false
		v := text[i + len(key):]
		stop := len(v)
		for k in keys do if j := strings.index(v, k); j >= 0 && j < stop do stop = j
		return strings.trim_space(v[:stop]), i, i + len(key) + stop, true
	}
	// The words outside the label: `color`, and the other keys' values (one word each)
	outside := text
	if _, a, b, ok := valueOf(text, "label=", keys); ok do outside = fmt.tprintf("%s %s", text[:a], text[b:])
	for word in strings.fields(outside, context.temp_allocator) do if word == "color" && p.type == .Vec4 do p.type = .Color
	if p.type == .Color do p.value = {1, 1, 1, 1}
	word :: proc(v: string) -> string {
		if sp := strings.index_byte(v, ' '); sp >= 0 do return v[:sp]
		return v
	}
	// A default runs to the next key (vectors: "1, 2"), less a `color` word after it
	if v, _, _, ok := valueOf(outside, "default=", keys); ok {
		d := strings.trim_space(strings.trim_suffix(strings.trim_space(v), "color"))
		if parsed, good := ShaderParam_Parse(p.type, d); good do p.value = parsed
	}
	if v, _, _, ok := valueOf(outside, "min=", keys); ok do p.min = strconv.parse_f32(word(v)) or_else p.min
	if v, _, _, ok := valueOf(outside, "max=", keys); ok do p.max = strconv.parse_f32(word(v)) or_else p.max
	if v, _, _, ok := valueOf(text, "label=", keys); ok do p.label = v
}

// The shader on this renderer's device (made the first time); nil when it can't run here
@(private="file")
shaderOnRenderer :: proc(program: ^ShaderProgram, renderer: ^sdl.Renderer) -> ^sdl.GPUShader {
	if program == nil || program.failed do return nil
	device := sdl.GetGPURendererDevice(renderer)
	if device == nil {
		if !shaderWarned {
			shaderWarned = true
			log.warnf("Shaders draw only with the GPU renderer (Project Settings > Renderer): %s draws without its shader", program.path)
		}
		return nil
	}
	for g in program.gpu do if g.device == device do return g.shader
	formats := sdl.GetGPUShaderFormats(device)
	b := &program.bundle
	info := sdl.GPUShaderCreateInfo{stage = .FRAGMENT, num_samplers = u32(b.samplers), num_uniform_buffers = u32(b.uniformBuffers)}
	if .SPIRV in formats && len(b.spirv) > 0 {
		info.format = {.SPIRV}
		info.code, info.code_size, info.entrypoint = raw_data(b.spirv), len(b.spirv), "main"
	} else if .MSL in formats && len(b.msl) > 0 {
		info.format = {.MSL}
		info.code, info.code_size, info.entrypoint = raw_data(b.msl), len(b.msl), "main0"
	} else {
		log.warnf("Shader %s: this GPU takes neither SPIR-V nor MSL", program.path)
		program.failed = true
		return nil
	}
	shader := sdl.CreateGPUShader(device, info)
	if shader == nil {
		log.errorf("Shader %s: %s", program.path, sdl.GetError())
		program.failed = true
		return nil
	}
	append(&program.gpu, ShaderOnDevice{device, shader})
	return shader
}

@(private="file", thread_local)
shaderWarned: bool

// The material's render state on a renderer, with its uniforms for a picture of `size` pixels
@(private)
shaderMaterialState :: proc(m: ^ShaderMaterial, renderer: ^sdl.Renderer, size: [2]f32, time: f32) -> ^sdl.GPURenderState {
	if m == nil do return nil
	state: ^sdl.GPURenderState
	for s in m.states do if s.renderer == renderer do state = s.state
	if state == nil {
		shader := shaderOnRenderer(m.program, renderer)
		if shader == nil do return nil
		state = sdl.CreateGPURenderState(renderer, {fragment_shader = shader})
		if state == nil {
			log.errorf("Shader %s: %s", m.program.path, sdl.GetError())
			m.program.failed = true
			return nil
		}
		append(&m.states, ShaderState{renderer, state})
	}
	b := &m.program.bundle
	// Only when the shader reads them (unused, the compiler drops the block)
	if b.uniformSize > 0 && b.uniformBuffers > 0 {
		data := make([]byte, b.uniformSize, context.temp_allocator)
		for p, i in b.params {
			v := m.values[i]
			switch p.name {
			case "time": if p.builtin do v = {time, 0, 0, 0}
			case "texelSize": if p.builtin do v = {1 / max(size.x, 1), 1 / max(size.y, 1), 0, 0}
			case "textureSize": if p.builtin do v = {size.x, size.y, 0, 0}
			}
			count := 1
			switch p.type {
			case .Float: count = 1
			case .Vec2: count = 2
			case .Vec3: count = 3
			case .Vec4, .Color: count = 4
			}
			if p.offset + count * 4 > len(data) do continue
			for c in 0 ..< count do (cast(^f32)&data[p.offset + c * 4])^ = v[c]
		}
		_ = sdl.SetGPURenderStateFragmentUniforms(state, 0, raw_data(data), u32(len(data)))
	}
	return state
}

// Frees a material's render states (its node goes, or gets another shader)
@(private)
shaderMaterialDestroy :: proc(m: ^ShaderMaterial) {
	if m == nil do return
	for s in m.states do sdl.DestroyGPURenderState(s.state)
	clear(&m.states)
}

// Frees the game's shaders' GPU code (Game_Destroy, before the renderer goes)
@(private)
shadersDestroy :: proc(game: ^Game) {
	gpuParticleResourcesDestroy(game)
	glyphFontsReleaseGPU(&game.resourceManager)
	for _, program in game.shaders {
		for g in program.gpu do sdl.ReleaseGPUShader(g.device, g.shader)
		delete(program.gpu)
	}
	game.shaders = nil
}

/*
Turns the draw state's shader on around one textured draw (`size`: the picture's, for
`texelSize`): call before drawing, and
`shaderDrawEnd` after. Returns whether a shader is on (false: draw as usual).
*/
@(private)
shaderDrawBegin :: proc(renderer: ^sdl.Renderer, size: [2]f32) -> bool {
	ds := drawState()
	if ds.material == nil || renderer == nil do return false
	state := shaderMaterialState(ds.material, renderer, size, ds.time)
	if state == nil do return false
	return sdl.SetGPURenderState(renderer, state)
}

@(private)
shaderDrawEnd :: proc(renderer: ^sdl.Renderer, on: bool) {
	if on do _ = sdl.SetGPURenderState(renderer, nil)
}

// The hit flash without the GPU renderer: the picture again, added in the flash color
@(private)
shaderFallbackFlash :: proc(renderer: ^sdl.Renderer, texture: ^sdl.Texture) -> (color: sdl.Color, ok: bool) {
	ds := drawState()
	if ds.material == nil || ds.material.program.path != "builtin:hit_flash" do return {}, false
	if Renderer_SupportsShaders(renderer) do return {}, false
	amount, flash: f32
	tint: [4]f32 = {1, 1, 1, 1}
	for p, i in ds.material.program.bundle.params {
		switch p.name {
		case "amount": amount = ds.material.values[i][0]
		case "flashColor": tint = ds.material.values[i]; flash = 1
		}
	}
	_ = flash
	a := clamp(amount * tint[3], 0, 1)
	if a <= 0 do return {}, false
	return {u8(tint[0] * 255 * a), u8(tint[1] * 255 * a), u8(tint[2] * 255 * a), 255}, true
}
