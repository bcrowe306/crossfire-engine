#+build !js
package crossfire

import "core:fmt"
import "core:os"
import "core:strings"

/*
Making MSDF fonts' atlases (fonts.odin) with msdf-atlas-gen, one of the shader tools
(tools/build_shader_tools.sh builds it into `shader_tools/<os>_<arch>/`): a TrueType or OpenType
font becomes `<font>.msdf.bmp` (three distance channels) and `<font>.msdf.json` (where each glyph
is, its metrics, the kerning) beside it. Editors call it when a font asset's MSDF setting is on,
and again when the font file changes; exports ship both files.
*/

// The characters an MSDF atlas holds by default: printable ASCII and Latin-1
MSDF_DEFAULT_CHARSET :: "[32, 126], [160, 255]"
// Pixels per em the atlas's glyphs are made at (bigger: finer corners, a bigger picture)
MSDF_DEFAULT_SIZE :: 48
// The distance range in the atlas's pixels (the shader's `pxRange`)
MSDF_DEFAULT_RANGE :: 4

/*
Makes a font's MSDF atlas beside it, when the font is newer than its atlas (or `force`).

Inputs:
- tools: The shader tools (`ShaderTools_Find`), with msdf-atlas-gen
- font: The `.ttf` / `.otf` file
- scratch: A folder for the charset file (made when missing)
- charset: msdf-atlas-gen's charset syntax: ranges `[32, 126]`, characters `'A'`, strings `"abc"`
- size: Pixels per em in the atlas
- force: Make it even when it's up to date

Returns:
- The tool's messages when it failed, whether it worked, and whether it made the atlas (false:
  up to date)
*/
Font_MakeMSDF :: proc(tools: ShaderTools, font, scratch: string, charset := MSDF_DEFAULT_CHARSET, size := MSDF_DEFAULT_SIZE, force := false) -> (messages: string, ok: bool, made: bool) {
	if tools.msdfAtlasGen == "" do return "No font tool (msdf-atlas-gen): build the shader tools again (tools/build_shader_tools.sh)", false, false
	layout := strings.concatenate({font, MSDF_ATLAS_SUFFIX}, context.temp_allocator)
	image := strings.concatenate({font, MSDF_IMAGE_SUFFIX}, context.temp_allocator)
	if !force && os.exists(image) {
		fontTime, e1 := os.modification_time_by_path(font)
		atlasTime, e2 := os.modification_time_by_path(layout)
		if e1 == nil && e2 == nil && atlasTime._nsec >= fontTime._nsec do return "", true, false
	}
	_ = os.make_directory_all(scratch)
	charsetFile := JoinPath(scratch, "msdf_charset.txt")
	if os.write_entire_file(charsetFile, transmute([]byte)charset) != nil do return fmt.tprintf("couldn't write %s", charsetFile), false, false
	state, stdout, stderr, err := Process_Exec({command = {
		tools.msdfAtlasGen, "-font", font, "-charset", charsetFile, "-type", "msdf", "-format", "bmp",
		"-imageout", image, "-json", layout, "-size", fmt.tprint(size), "-pxrange", fmt.tprint(MSDF_DEFAULT_RANGE),
	}}, context.temp_allocator)
	if err != nil do return fmt.tprintf("couldn't run %s: %v", tools.msdfAtlasGen, err), false, false
	if !state.exited || state.exit_code != 0 {
		return strings.trim_space(fmt.tprintf("%s: %s\n%s", font, string(stdout), string(stderr))), false, false
	}
	return "", true, true
}
