/*
Compiles the engine's built-in effects (the .frag files in shaders/builtin) into the .frag.shader files the
engine loads (#load in shaders.odin). Run after changing one, then commit both:

	odin run tools/compile_shaders -collection:engine=.

It needs the shader tools (tools/build_shader_tools.sh).
*/
package compile_shaders

import "core:fmt"
import "core:os"
import e "engine:."

main :: proc() {
	tools, found := e.ShaderTools_Find("shader_tools")
	if !found {
		fmt.eprintln("No shader tools: run tools/build_shader_tools.sh")
		os.exit(1)
	}
	failed := false
	for b in e.BuiltinShader {
		path := fmt.tprintf("shaders/builtin/%v.frag", b)
		messages, ok, compiled := e.Shader_CompileFile(tools, path, path, "shader_tools/build/scratch", force = len(os.args) > 1 && os.args[1] == "-force")
		if !ok {
			fmt.eprintln(messages)
			failed = true
			continue
		}
		fmt.printfln("%s %s", path, compiled ? "compiled" : "up to date")
	}
	// The GPU particles' shaders (gpu_particles.odin)
	for name in ([]string{"particles.vert", "particles.frag"}) {
		path := fmt.tprintf("shaders/particles/%s", name)
		stage := name == "particles.vert" ? e.ShaderStage.Vertex : e.ShaderStage.Fragment
		messages, ok, compiled := e.Shader_CompileFile(tools, path, path, "shader_tools/build/scratch", force = len(os.args) > 1 && os.args[1] == "-force", stage = stage)
		if !ok {
			fmt.eprintln(messages)
			failed = true
			continue
		}
		fmt.printfln("%s %s", path, compiled ? "compiled" : "up to date")
	}
	// Text from MSDF atlases (fonts.odin)
	{
		path := "shaders/text/msdf.frag"
		messages, ok, compiled := e.Shader_CompileFile(tools, path, path, "shader_tools/build/scratch", force = len(os.args) > 1 && os.args[1] == "-force")
		if !ok {
			fmt.eprintln(messages)
			failed = true
		} else {
			fmt.printfln("%s %s", path, compiled ? "compiled" : "up to date")
		}
	}
	if failed do os.exit(1)
}
