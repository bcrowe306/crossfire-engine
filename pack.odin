#+build !js
package crossfire

import "base:runtime"
import "core:encoding/endian"
import "core:os"
import "core:strings"

/*
The data pack: a game's files (project.xml, its scenes, its assets) appended to the end of its own
executable, so an exported game is one file. Executables ignore what follows them (ELF on Linux,
PE on Windows; macOS games keep their files in the .app instead: appending would break its code
signature).

At start, the player looks at the end of its executable (`Pack_Open`). With a pack there, the
project is `PACK_ROOT` and every file the engine reads under it comes from the pack: the platform
layer's `Platform_ReadFile` / `Platform_FileExists` / `Platform_LoadTexture`, sounds and music
(`Platform_OpenIO`), fonts. A file is read from the executable the first time it's asked for and
kept: SDL keeps reading music and fonts as they play, from that memory.

Layout (little-endian), after the program:

	the files' bytes, one after another
	the index: per file, u32 path length, the path ("/"-separated, relative to the project),
	           u64 offset (from the start of the executable), u64 size
	the footer (32 bytes): u64 index offset, u64 index size, u64 pack start, PACK_MAGIC (8 bytes)

`Pack_Append` writes one (the editor's desktop exports use it).

Example:
	files := []string{"project.xml", "scenes/Main.scene.xml", "assets/ship.png"}
	ok := e.Pack_Append("export/linux_x64/MyGame", "my_project", files)
*/

// The project folder of a packed game: paths under it are the pack's
PACK_ROOT :: "<pack>"
// The footer's last 8 bytes
PACK_MAGIC :: "ODINPAK1"

@(private="file")
PACK_FOOTER_SIZE :: 32

// A file in a pack: where its bytes are in the executable
PackEntry :: struct {
	// Byte offset from the start of the executable, and length in bytes
	offset, size: u64,
}

/*
An open pack: a file's index, and the files read from it so far (kept: SDL streams music and fonts
from them). The game's is `gamePack` (Pack_Open); tests and tools open their own.
*/
Pack :: struct {
	// An open was tried (`Pack_Open` only tries once)
	opened: bool,
	// The file the pack is in, nil when there's no pack
	file: ^os.File,
	// The index: each file's path (relative to the project) and where it is (heap-allocated)
	entries: map[string]PackEntry,
	// The files read so far, by path (heap-allocated, kept until `Pack_CloseFile`)
	loaded: map[string][]byte,
}

// The running game's pack (Pack_Open)
@(private="file")
gamePack: Pack

/*
Opens the pack at the end of the running executable, if it has one (once; later calls say whether
it did).

Returns:
- Whether there's a pack (paths under PACK_ROOT then read from it)
*/
Pack_Open :: proc() -> bool {
	if gamePack.opened do return gamePack.file != nil
	gamePack.opened = true
	exe, err := os.get_executable_path(context.temp_allocator)
	return err == nil && Pack_OpenFile(&gamePack, exe)
}

/*
Opens the pack at the end of a file into `p` (closing what it had). Pack_Open does it with the
running executable; tools and tests open their own. Close it with `Pack_CloseFile`.

Inputs:
- p: The pack to open into
- path: The file (an executable with a pack appended)

Returns:
- Whether the file ends in a pack

Example:
	pack: e.Pack
	defer e.Pack_CloseFile(&pack)
	if e.Pack_OpenFile(&pack, "export/linux_x64/MyGame") {
		data, ok := e.Pack_FileBytes(&pack, "project.xml")
		if ok do log.infof("project.xml: %d bytes", len(data))
	}
*/
Pack_OpenFile :: proc(p: ^Pack, path: string) -> bool {
	Pack_CloseFile(p)
	p.opened = true
	allocator := runtime.heap_allocator()
	file, openErr := os.open(path)
	if openErr != nil do return false
	size, sizeErr := os.file_size(file)
	footer: [PACK_FOOTER_SIZE]byte
	if sizeErr != nil || size < PACK_FOOTER_SIZE || !readAt(file, footer[:], size - PACK_FOOTER_SIZE) || string(footer[24:]) != PACK_MAGIC {
		os.close(file)
		return false
	}
	indexOffset, _ := endian.get_u64(footer[0:8], .Little)
	indexSize, _ := endian.get_u64(footer[8:16], .Little)
	// A damaged footer mustn't ask for more than the file holds
	if indexOffset > u64(size) || indexSize > u64(size) - indexOffset {
		os.close(file)
		return false
	}
	index := make([]byte, int(indexSize), context.temp_allocator)
	if !readAt(file, index, i64(indexOffset)) {
		os.close(file)
		return false
	}
	p.entries = make(map[string]PackEntry, allocator)
	p.loaded = make(map[string][]byte, allocator)
	for at := 0; at + 4 <= len(index); {
		length, _ := endian.get_u32(index[at:at + 4], .Little)
		at += 4
		if at + int(length) + 16 > len(index) do break
		path := strings.clone(string(index[at:at + int(length)]), allocator)
		at += int(length)
		offset, _ := endian.get_u64(index[at:at + 8], .Little)
		fileSize, _ := endian.get_u64(index[at + 8:at + 16], .Little)
		at += 16
		p.entries[path] = {offset, fileSize}
	}
	p.file = file
	return true
}

/*
Closes a pack and frees what was read from it (slices from `Pack_FileBytes` become invalid).

Inputs:
- p: The pack (a closed or zero one is fine)
*/
Pack_CloseFile :: proc(p: ^Pack) {
	allocator := runtime.heap_allocator()
	if p.file != nil do os.close(p.file)
	for path, data in p.loaded {
		delete(path, allocator)
		delete(data, allocator)
	}
	for path in p.entries do delete(path, allocator)
	delete(p.loaded)
	delete(p.entries)
	p^ = {}
}

/*
A file in the game's pack: its bytes (kept for the program's life: don't free them), or false when
there's no pack or no such file. Opens the pack on first use (`Pack_Open`).

Inputs:
- path: Under PACK_ROOT ("<pack>/assets/ship.png") or relative to it ("assets/ship.png"); absolute
  paths are never in the pack

Returns:
- The bytes and true, or nil and false
*/
Pack_Bytes :: proc(path: string) -> ([]byte, bool) {
	if !Pack_Open() do return nil, false
	return Pack_FileBytes(&gamePack, path)
}

/*
Whether the game's pack has a file, without reading it. Opens the pack on first use (`Pack_Open`).

Inputs:
- path: The file's path (see `Pack_Bytes`)

Returns:
- true when there's a pack and it has the file
*/
Pack_Has :: proc(path: string) -> bool {
	return Pack_Open() && Pack_FileHas(&gamePack, path)
}

/*
A file in an open pack (`Pack_Bytes` for the game's own pack). The first call reads it from disk;
later ones return the same bytes.

Inputs:
- p: The pack (`Pack_OpenFile`)
- path: The file's path (see `Pack_Bytes`)

Returns:
- The bytes (the pack's: valid until `Pack_CloseFile`, don't free them) and true, or nil and false
  when the pack isn't open, has no such file, or it can't be read
*/
Pack_FileBytes :: proc(p: ^Pack, path: string) -> ([]byte, bool) {
	if p.file == nil do return nil, false
	key, ok := packKey(path)
	if !ok do return nil, false
	if data, loaded := p.loaded[key]; loaded do return data, true
	entry, known := p.entries[key]
	if !known do return nil, false
	data := make([]byte, int(entry.size), runtime.heap_allocator())
	if !readAt(p.file, data, i64(entry.offset)) {
		delete(data, runtime.heap_allocator())
		return nil, false
	}
	p.loaded[strings.clone(key, runtime.heap_allocator())] = data
	return data, true
}

/*
Whether an open pack has a file, without reading it.

Inputs:
- p: The pack (`Pack_OpenFile`)
- path: The file's path (see `Pack_Bytes`)

Returns:
- true when the pack is open and has the file
*/
Pack_FileHas :: proc(p: ^Pack, path: string) -> bool {
	if p.file == nil do return false
	key, ok := packKey(path)
	return ok && key in p.entries
}

/*
Appends a pack of a project's files to an executable (a desktop export's last step).

Inputs:
- executable: The built game
- root: The folder the files are relative to
- files: Their paths under it, "/"-separated (they're found in the pack by these)
- extra: More files given by content (an export's own project.xml), by path; they win over `files`

Returns:
- "" or what went wrong
*/
Pack_Append :: proc(executable, root: string, files: []string, extra: map[string]string = nil) -> string {
	out, err := os.open(executable, {.Write})
	if err != nil do return "can't open the executable to write to it"
	defer os.close(out)
	start, sizeErr := os.file_size(out)
	if sizeErr != nil do return "can't size the executable"
	if _, seekErr := os.seek(out, 0, .End); seekErr != nil do return "can't seek in the executable"

	index := strings.builder_make(context.temp_allocator)
	at := u64(start)
	add :: proc(out: ^os.File, index: ^strings.Builder, at: ^u64, path: string, data: []byte) -> bool {
		if _, writeErr := os.write(out, data); writeErr != nil do return false
		buf: [8]byte
		endian.put_u32(buf[:4], .Little, u32(len(path)))
		strings.write_bytes(index, buf[:4])
		strings.write_string(index, path)
		endian.put_u64(buf[:], .Little, at^)
		strings.write_bytes(index, buf[:])
		endian.put_u64(buf[:], .Little, u64(len(data)))
		strings.write_bytes(index, buf[:])
		at^ += u64(len(data))
		return true
	}
	for path in files {
		if path in extra do continue
		data, readErr := os.read_entire_file(JoinPath(root, path), context.temp_allocator)
		if readErr != nil do return strings.concatenate({"can't read ", path}, context.temp_allocator)
		if !add(out, &index, &at, path, data) do return "can't write the pack"
	}
	for path, text in extra {
		if !add(out, &index, &at, path, transmute([]byte)text) do return "can't write the pack"
	}
	indexBytes := index.buf[:]
	indexOffset := at
	if _, writeErr := os.write(out, indexBytes); writeErr != nil do return "can't write the pack's index"
	footer: [PACK_FOOTER_SIZE]byte
	endian.put_u64(footer[0:8], .Little, indexOffset)
	endian.put_u64(footer[8:16], .Little, u64(len(indexBytes)))
	endian.put_u64(footer[16:24], .Little, u64(start))
	copy(footer[24:], PACK_MAGIC)
	if _, writeErr := os.write(out, footer[:]); writeErr != nil do return "can't write the pack's footer"
	return ""
}

// The pack's key for a path: relative to PACK_ROOT, "/"-separated, no "./"
@(private="file")
packKey :: proc(path: string) -> (string, bool) {
	p := path
	if strings.has_prefix(p, PACK_ROOT) {
		p = p[len(PACK_ROOT):]
		for strings.has_prefix(p, "/") do p = p[1:]
	} else if strings.has_prefix(p, "/") {
		// An absolute path isn't in the pack
		return "", false
	}
	for strings.has_prefix(p, "./") do p = p[2:]
	return p, true
}

@(private="file")
readAt :: proc(file: ^os.File, buffer: []byte, offset: i64) -> bool {
	n, err := os.read_at(file, buffer, offset)
	return err == nil && n == len(buffer)
}
