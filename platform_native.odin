#+build !js
package engine

import "base:runtime"
import "core:fmt"
import "core:log"
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

// Whether this is the browser build (false here; true in platform_web.odin)
PLATFORM_WEB :: false

// A growing memory arena: nodes, scenes and the game each own one (virtual memory on the desktop)
MemoryArena :: vmem.Arena

/*
Sets up a growing arena, which reserves more memory as it fills.

Inputs:
- arena: The arena to set up

Returns:
- false if the memory couldn't be reserved
*/
MemoryArena_InitGrowing :: proc(arena: ^MemoryArena) -> bool {
	return vmem.arena_init_growing(arena) == nil
}

/*
An allocator that allocates from the arena. Its memory is freed all at once by
`MemoryArena_Destroy`; individual frees do nothing.

Inputs:
- arena: An arena set up with `MemoryArena_InitGrowing`

Returns:
- The arena's allocator
*/
MemoryArena_Allocator :: proc(arena: ^MemoryArena) -> runtime.Allocator {
	return vmem.arena_allocator(arena)
}

/*
Frees all of the arena's memory.

Inputs:
- arena: The arena
*/
MemoryArena_Destroy :: proc(arena: ^MemoryArena) {
	vmem.arena_destroy(arena)
}

/*
Allocates a T inside a new arena that it owns, at `offset` within T (the arena frees the T with
everything else). Used for nodes.

Inputs:
- T: The type to allocate
- offset: Byte offset of the `MemoryArena` field inside T (`offset_of`)
- blockSize: Size in bytes of the arena's memory blocks

Returns:
- The new T (zeroed) and true, or nil and false if the memory couldn't be reserved
*/
MemoryArena_BootstrapNew :: proc($T: typeid, offset: uintptr, blockSize: uint) -> (^T, bool) {
	object, err := vmem.arena_growing_bootstrap_new_by_offset(T, offset, blockSize)
	return object, err == nil
}

/*
Reads a whole file, from the data pack if it's there, else from disk.

Inputs:
- path: The file's path

Returns:
- The contents (temp allocated, or the data pack's memory: don't free them) and true; false if
  it can't be read
*/
Platform_ReadFile :: proc(path: string) -> ([]byte, bool) {
	if data, packed := Pack_Bytes(path); packed do return data, true
	data, err := os.read_entire_file(path, context.temp_allocator)
	return data, err == nil
}

/*
Whether a file exists, in the data pack or on disk.

Inputs:
- path: The file's path

Returns:
- true if it exists
*/
Platform_FileExists :: proc(path: string) -> bool {
	return Pack_Has(path) || os.exists(path)
}

/*
The folder the program is in.

Returns:
- The folder's path (temp allocated) and true; false if it couldn't be found
*/
Platform_ExecutableDir :: proc() -> (string, bool) {
	dir, err := os.get_executable_directory(context.temp_allocator)
	return dir, err == nil
}

/*
Loads an image file as a texture: any format SDL3_image reads. Reads the data pack first, then
the disk.

Most code loads through `ResourceManager` (`loadTexture`), which caches the texture.

Inputs:
- renderer: The renderer the texture is for
- path: The image's path

Returns:
- The texture (the caller destroys it), or nil if it can't be read (SDL's error says why)
*/
Platform_LoadTexture :: proc(renderer: ^sdl.Renderer, path: string) -> ^sdl.Texture {
	if data, packed := Pack_Bytes(path); packed {
		return img.LoadTexture_IO(renderer, sdl.IOFromConstMem(raw_data(data), uint(len(data))), true)
	}
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

/*
Writes a save. On the desktop, `<SDL's per-user folder for the game>/saves/<slot>.json`,
written to a temporary file first and then moved over the old save, so a crash mid-write can't
leave half a save. Use `Save_Write` (save.odin) rather than calling this directly.

Inputs:
- name: "<game>/<slot>"
- data: The save's contents

Returns:
- false if it couldn't be written
*/
Platform_SaveWrite :: proc(name: string, data: []byte) -> bool {
	path, ok := savePath(name)
	if !ok do return false
	// Written next to it first, then moved over it: a crash mid-write can't leave half a save
	temp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(temp, data) != nil do return false
	return os.rename(temp, path) == nil
}

/*
Reads a save written by `Platform_SaveWrite`.

Inputs:
- name: "<game>/<slot>"

Returns:
- The contents (temp allocated) and true; false if there's no such save or it can't be read
*/
Platform_SaveRead :: proc(name: string) -> ([]byte, bool) {
	path, ok := savePath(name)
	if !ok do return nil, false
	data, err := os.read_entire_file(path, context.temp_allocator)
	return data, err == nil
}

/*
Whether a save exists.

Inputs:
- name: "<game>/<slot>"

Returns:
- true if it exists
*/
Platform_SaveExists :: proc(name: string) -> bool {
	path, ok := savePath(name)
	return ok && os.exists(path)
}

/*
Deletes a save, if it exists.

Inputs:
- name: "<game>/<slot>"
*/
Platform_SaveDelete :: proc(name: string) {
	if path, ok := savePath(name); ok do _ = os.remove(path)
}

// The window icon games get unless their project names one: the Crossfire logo (256 px)
@(private="file")
DEFAULT_WINDOW_ICON :: #load("logo/crossfire.png", []byte)

/*
Gives a window an icon from an image file's bytes (PNG, JPEG...: what SDL_image reads).

Inputs:
- window: The window
- data: The image file's contents; nil for the engine's default icon (the Crossfire logo)

Returns:
- false when the image can't be read (logged)
*/
Platform_SetWindowIcon :: proc(window: ^sdl.Window, data: []byte) -> bool {
	data := data != nil ? data : DEFAULT_WINDOW_ICON
	surface := img.Load_IO(sdl.IOFromConstMem(raw_data(data), uint(len(data))), true)
	if surface == nil {
		log.warnf("Couldn't read the window icon: %s", sdl.GetError())
		return false
	}
	defer sdl.DestroySurface(surface)
	return sdl.SetWindowIcon(window, surface)
}
