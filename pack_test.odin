#+build !js
package crossfire

import "core:os"
import "core:strings"
import "core:testing"

@(test)
pack_round_trip :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "engine_pack_test", context.temp_allocator)
	testing.expect(t, err == nil, "a temp folder")
	defer os.remove_all(dir)
	program := JoinPath(dir, "game")
	_ = os.write_entire_file(program, transmute([]byte)string("\\x7fELF pretend program bytes"))
	_ = os.make_directory(JoinPath(dir, "assets"))
	_ = os.write_entire_file(JoinPath(dir, "assets/a.txt"), transmute([]byte)string("alpha"))
	_ = os.write_entire_file(JoinPath(dir, "scene.xml"), transmute([]byte)string("<scene/>"))
	extra := make(map[string]string, context.temp_allocator)
	extra["project.xml"] = "<project/>"

	// Its own Pack: the game's (Pack_Open) is the test program's, which other tests read through
	p: Pack
	testing.expect(t, !Pack_OpenFile(&p, program), "no pack before")
	testing.expect_value(t, Pack_Append(program, dir, {"assets/a.txt", "scene.xml"}, extra), "")
	defer Pack_CloseFile(&p)
	testing.expect(t, Pack_OpenFile(&p, program), "a pack after")
	// The program's own bytes are untouched in front of it
	data, _ := os.read_entire_file(program, context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(data), "\\x7fELF pretend program bytes"), "the program first")

	alpha, ok := Pack_FileBytes(&p, JoinPath(PACK_ROOT, "assets/a.txt"))
	testing.expect(t, ok && string(alpha) == "alpha", "a file by its pack path")
	scene, _ := Pack_FileBytes(&p, "./scene.xml")
	testing.expect_value(t, string(scene), "<scene/>")
	project, _ := Pack_FileBytes(&p, "<pack>/project.xml")
	testing.expect_value(t, string(project), "<project/>")
	testing.expect(t, Pack_FileHas(&p, "<pack>/scene.xml") && !Pack_FileHas(&p, "<pack>/nope.png") && !Pack_FileHas(&p, "/etc/passwd"), "has")
	// The test program itself has no pack: the platform layer reads from disk
	testing.expect(t, !Pack_Has("<pack>/project.xml"), "the game's pack is the test program's")
}

// A footer whose index runs past the end of the file is refused (no huge allocation)
@(test)
damaged_packs_are_refused :: proc(t: ^testing.T) {
	dir := tempFolder("engine_test_bad_pack")
	defer os.remove_all(dir)
	path := strings.concatenate({dir, "/game"}, context.temp_allocator)
	// 64 bytes, then the 32-byte footer
	data := make([]byte, 64 + 32, context.temp_allocator)
	footer := data[64:]
	footer[0] = 10                       // index offset 10
	for i in 8 ..< 16 do footer[i] = 0xff // index size: 2^64 - 1
	copy(footer[24:], PACK_MAGIC)
	_ = os.write_entire_file(path, data)
	p: Pack
	defer Pack_CloseFile(&p)
	testing.expect(t, !Pack_OpenFile(&p, path), "refused")
	free_all(context.temp_allocator)
}
