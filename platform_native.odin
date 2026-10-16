#+build !js
package engine

import "base:runtime"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

/*
Platform services, desktop version (Linux, macOS, Windows). platform_web.odin has the same
procedures for the browser (Emscripten), where `core:os`, virtual memory, SDL3_image and SDL3_mixer
aren't available. Code elsewhere calls these instead of those packages directly.
*/

// Is this the browser build?
PLATFORM_WEB :: false

// A growing memory arena: nodes and scenes each own one
MemoryArena :: vmem.Arena

MemoryArena_InitGrowing :: proc(arena: ^MemoryArena) -> bool {
	return vmem.arena_init_growing(arena) == nil
}

MemoryArena_Allocator :: proc(arena: ^MemoryArena) -> runtime.Allocator {
	return vmem.arena_allocator(arena)
}

MemoryArena_Destroy :: proc(arena: ^MemoryArena) {
	vmem.arena_destroy(arena)
}

/*
Allocates a T inside a new arena that it owns, at `offset` within T (the arena frees the T with
everything else). Used for nodes.
*/
MemoryArena_BootstrapNew :: proc($T: typeid, offset: uintptr, blockSize: uint) -> (^T, bool) {
	object, err := vmem.arena_growing_bootstrap_new_by_offset(T, offset, blockSize)
	return object, err == nil
}

// A whole file's contents (temp allocated), or false
Platform_ReadFile :: proc(path: string) -> ([]byte, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return data, err == nil
}

Platform_FileExists :: proc(path: string) -> bool {
	return os.exists(path)
}

// The folder the program is in (temp allocated)
Platform_ExecutableDir :: proc() -> (string, bool) {
	dir, err := os.get_executable_directory(context.temp_allocator)
	return dir, err == nil
}

// An image file as a texture: any format SDL3_image reads
Platform_LoadTexture :: proc(renderer: ^sdl.Renderer, path: string) -> ^sdl.Texture {
	return img.LoadTexture(renderer, fmt.ctprint(path))
}

// A context for contextless code (`@(init)` procedures): Odin's default
Platform_DefaultContext :: proc "contextless" () -> runtime.Context {
	return runtime.default_context()
}

/*
The whole player program: `Player_Run` with the command line, exiting with its code. A player's
`main` is just this call, so the same `main` builds for the desktop and the browser (where this
does nothing: the page starts the game through `odin_web_main`).
*/
Player_Main :: proc() {
	os.exit(Player_Run(os.args))
}

// Where saves go (tests set it to a scratch folder); "" = SDL's per-user folder for the game
@(private)
saveRootOverride: string

// Saves: <SDL's per-user folder for the game>/saves/<slot>.json. `name` is "<game>/<slot>"
@(private="file")
savePath :: proc(name: string) -> (string, bool) {
	app, _, slot := strings.partition(name, "/")
	root := saveRootOverride
	if root == "" {
		pref := sdl.GetPrefPath("", strings.clone_to_cstring(app, context.temp_allocator))
		if pref == nil do return "", false
		root = strings.clone(string(cstring(pref)), context.temp_allocator)
		sdl.free(rawptr(pref))
	} else {
		root = JoinPath(root, app)
	}
	dir := JoinPath(root, "saves")
	_ = os.make_directory_all(dir)
	return JoinPath(dir, fmt.tprintf("%s.json", slot)), true
}

Platform_SaveWrite :: proc(name: string, data: []byte) -> bool {
	path, ok := savePath(name)
	if !ok do return false
	// Written next to it first, then moved over it: a crash mid-write can't leave half a save
	temp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(temp, data) != nil do return false
	return os.rename(temp, path) == nil
}

Platform_SaveRead :: proc(name: string) -> ([]byte, bool) {
	path, ok := savePath(name)
	if !ok do return nil, false
	data, err := os.read_entire_file(path, context.temp_allocator)
	return data, err == nil
}

Platform_SaveExists :: proc(name: string) -> bool {
	path, ok := savePath(name)
	return ok && os.exists(path)
}

Platform_SaveDelete :: proc(name: string) {
	if path, ok := savePath(name); ok do _ = os.remove(path)
}
