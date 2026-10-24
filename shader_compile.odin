#+build !js
package crossfire

import "core:fmt"
import "core:os"
import "core:strings"

/*
Compiling GLSL fragment shaders into the `.frag.shader` files games load (shaders.odin): glslang
makes SPIR-V (Vulkan), SDL_shadercross MSL (Metal) and the resource counts, and the `Params`
block gives the parameters. Editors call it when a shader is saved, before Play and before
exports; tools/compile_shaders compiles the engine's built-in effects with it.

The tools are built by tools/build_shader_tools.sh into `shader_tools/<os>_<arch>/`
(`ShaderTools_Find`); releases ship them beside the editor.
*/

// Where the two shader compilers are
ShaderTools :: struct {
	glslang: string,
	shadercross: string,
	// The font tool beside them (font_compile.odin; "" when that build has none)
	msdfAtlasGen: string,
}

/*
Finds the shader tools in a folder of builds (`<dir>/<os>_<arch>/glslang`, `shadercross`, and
the font tool `msdf-atlas-gen` when it's there).

Inputs:
- dir: The folder holding the `<os>_<arch>` folders (the engine's `shader_tools`, or a release's)

Returns:
- The tools (temp allocated paths), and whether both are there
*/
ShaderTools_Find :: proc(dir: string) -> (ShaderTools, bool) {
	when ODIN_OS == .Linux do osName := "linux"
	else when ODIN_OS == .Darwin do osName := "darwin"
	else when ODIN_OS == .Windows do osName := "windows"
	else do osName := "unknown"
	when ODIN_ARCH == .arm64 do archName := "arm64"
	else do archName := "amd64"
	exe := ODIN_OS == .Windows ? ".exe" : ""
	folder := JoinPath(dir, fmt.tprintf("%s_%s", osName, archName))
	tools := ShaderTools{JoinPath(folder, fmt.tprintf("glslang%s", exe)), JoinPath(folder, fmt.tprintf("shadercross%s", exe)), JoinPath(folder, fmt.tprintf("msdf-atlas-gen%s", exe))}
	if !os.exists(tools.msdfAtlasGen) do tools.msdfAtlasGen = ""
	return tools, os.exists(tools.glslang) && os.exists(tools.shadercross)
}

/*
Compiles a GLSL fragment shader.

Inputs:
- tools: The compilers (ShaderTools_Find)
- source: The shader's text
- name: The file's name in messages ("assets/fx/water.frag")
- scratch: A folder for the compilers' files (made when missing)

Returns:
- The bundle (its code temp allocated), and the compilers' messages with the file's name and
  line ("assets/fx/water.frag:12: 'colr' : undeclared identifier"); ok false when it failed
*/
Shader_Compile :: proc(tools: ShaderTools, source, name, scratch: string, stage := ShaderStage.Fragment) -> (bundle: ShaderBundle, messages: string, ok: bool) {
	// A fragment shader's parameters are its Params block; the engine's vertex shaders' uniforms
	// are its own business
	params: []ShaderParam
	size: int
	if stage == .Fragment {
		problem: string
		params, size, problem = Shader_ParseParams(source)
		if problem != "" do return {}, fmt.tprintf("%s: %s", name, problem), false
	}
	glslStage, crossStage := stage == .Vertex ? "vert" : "frag", stage == .Vertex ? "vertex" : "fragment"
	_ = os.make_directory_all(scratch)
	base := strings.trim_suffix(strings.trim_suffix(filepathBase(name), ".frag"), ".vert")
	input := JoinPath(scratch, fmt.tprintf("%s.%s", base, glslStage))
	spv := JoinPath(scratch, fmt.tprintf("%s.spv", base))
	msl := JoinPath(scratch, fmt.tprintf("%s.msl", base))
	reflection := JoinPath(scratch, fmt.tprintf("%s.json", base))
	if os.write_entire_file(input, transmute([]byte)source) != nil do return {}, fmt.tprintf("%s: couldn't write %s", name, input), false

	run :: proc(command: []string) -> (output: string, ok: bool) {
		state, stdout, stderr, err := Process_Exec({command = command}, context.temp_allocator)
		if err != nil do return fmt.tprintf("couldn't run %s: %v", command[0], err), false
		text := strings.trim_space(fmt.tprintf("%s\n%s", string(stdout), string(stderr)))
		return text, state.exited && state.exit_code == 0
	}
	// GLSL -> SPIR-V; glslang names the scratch copy: give its lines the real name
	out, compiled := run({tools.glslang, "-V", "-S", glslStage, input, "-o", spv})
	if !compiled {
		lines := make([dynamic]string, context.temp_allocator)
		for line in strings.split_lines(out, context.temp_allocator) {
			l := strings.trim_space(line)
			// glslang's summary lines say nothing the errors don't
			if l == "" || l == input || strings.has_prefix(l, "ERROR: Linking") || strings.contains(l, "compilation error") || strings.contains(l, "compilation terminated") || strings.has_prefix(l, "SPIR-V is not generated") do continue
			l, _ = strings.replace_all(l, fmt.tprintf("%s:", input), fmt.tprintf("%s:", name), context.temp_allocator)
			l = strings.trim_prefix(l, "ERROR: ")
			append(&lines, l)
		}
		return {}, strings.join(lines[:], "\n", context.temp_allocator), false
	}
	// SPIR-V -> MSL, and the resources it uses
	if text, good := run({tools.shadercross, spv, "-s", "SPIRV", "-d", "MSL", "-t", crossStage, "-o", msl}); !good do return {}, fmt.tprintf("%s: %s", name, text), false
	if text, good := run({tools.shadercross, spv, "-s", "SPIRV", "-d", "JSON", "-t", crossStage, "-o", reflection}); !good do return {}, fmt.tprintf("%s: %s", name, text), false
	spirvData, e1 := os.read_entire_file(spv, context.temp_allocator)
	mslData, e2 := os.read_entire_file(msl, context.temp_allocator)
	jsonData, e3 := os.read_entire_file(reflection, context.temp_allocator)
	if e1 != nil || e2 != nil || e3 != nil do return {}, fmt.tprintf("%s: the compilers wrote nothing", name), false
	bundle = {version = SHADER_BUNDLE_VERSION, stage = stage, params = params, uniformSize = size, spirv = spirvData, msl = mslData}
	bundle.storageBuffers = reflectionCount(string(jsonData), "\"storage_buffers\"")
	bundle.samplers = reflectionCount(string(jsonData), "\"samplers\"")
	bundle.uniformBuffers = reflectionCount(string(jsonData), "\"uniform_buffers\"")
	if stage == .Fragment && bundle.uniformBuffers > 0 && size == 0 do return {}, fmt.tprintf("%s: its uniform block must be at set 3, binding 0 (layout(set = 3, binding = 0) uniform Params { ... })", name), false
	return bundle, "", true
}

/*
Compiles a shader file into its `.shader` file beside it (`water.frag` -> `water.frag.shader`),
when the source is newer than it (or `force`).

Inputs:
- tools: The compilers
- path: The `.frag` file
- name: Its name in messages
- scratch: A folder for the compilers' files
- force: Compile even when it's up to date

Returns:
- The messages ("" none), whether it compiled (or was up to date), and whether it compiled now
*/
Shader_CompileFile :: proc(tools: ShaderTools, path, name, scratch: string, force := false, stage := ShaderStage.Fragment) -> (messages: string, ok: bool, compiled: bool) {
	out := fmt.tprintf("%s.shader", path)
	if !force {
		src, e1 := os.stat(path, context.temp_allocator)
		dst, e2 := os.stat(out, context.temp_allocator)
		if e1 == nil && e2 == nil && dst.modification_time._nsec >= src.modification_time._nsec do return "", true, false
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return fmt.tprintf("%s: can't be read", name), false, false
	bundle, messages_, good := Shader_Compile(tools, string(data), name, scratch, stage)
	if !good do return messages_, false, false
	text := Shader_FormatBundle(bundle)
	if os.write_entire_file(out, transmute([]byte)text) != nil do return fmt.tprintf("%s: couldn't write %s", name, out), false, false
	return "", true, true
}

@(private="file")
reflectionCount :: proc(json, key: string) -> int {
	i := strings.index(json, key)
	if i < 0 do return 0
	rest := strings.trim_left(json[i + len(key):], " :")
	n := 0
	for c in rest {
		if c < '0' || c > '9' do break
		n = n * 10 + int(c - '0')
	}
	return n
}

@(private="file")
filepathBase :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return path[i + 1:]
}
