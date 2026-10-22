#+build js
package crossfire

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import sdl "vendor:sdl3"

/*
Platform services, browser version: a WebAssembly build linked by Emscripten (the editor's Web
export). Same procedures as platform_native.odin, without `core:os` (unsupported on js/wasm),
virtual memory (there is none) and SDL3_image (no Emscripten build of it yet):
- files are read through SDL, which reads Emscripten's virtual file system (the exported game's
  data is packaged into it)
- arenas grow from the context allocator, which `Web_Context` makes Emscripten's malloc
- images: PNG and BMP, with SDL's own loaders
- audio: SDL3_mixer, built with Emscripten, as on the desktop (audio.odin)
*/

// Whether this is the browser build (true here; false in platform_native.odin)
PLATFORM_WEB :: true

// A growing memory arena: nodes, scenes and the game each own one (blocks from the context allocator in the browser)
MemoryArena :: runtime.Arena

// Block size of web arenas; they grow by adding blocks
WEB_ARENA_BLOCK_SIZE :: 16 * 1024

/*
Sets up a growing arena, which adds `WEB_ARENA_BLOCK_SIZE` blocks as it fills.

Inputs:
- arena: The arena to set up

Returns:
- false if the memory couldn't be allocated
*/
MemoryArena_InitGrowing :: proc(arena: ^MemoryArena) -> bool {
	return runtime.arena_init(arena, WEB_ARENA_BLOCK_SIZE, context.allocator) == nil
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
	return runtime.Allocator{procedure = runtime.arena_allocator_proc, data = arena}
}

/*
Frees all of the arena's memory.

Inputs:
- arena: The arena
*/
MemoryArena_Destroy :: proc(arena: ^MemoryArena) {
	runtime.arena_destroy(arena)
}

/*
Allocates a T inside a new arena that it owns, at `offset` within T (the arena frees the T with
everything else). Used for nodes.

Inputs:
- T: The type to allocate
- offset: Byte offset of the `MemoryArena` field inside T (`offset_of`)
- blockSize: Size in bytes of the arena's memory blocks

Returns:
- The new T (zeroed) and true, or nil and false if the memory couldn't be allocated
*/
MemoryArena_BootstrapNew :: proc($T: typeid, offset: uintptr, blockSize: uint) -> (^T, bool) {
	// Make the arena, allocate T in it, then move the arena into T (it has no pointers to itself)
	arena: runtime.Arena
	if runtime.arena_init(&arena, blockSize, context.allocator) != nil do return nil, false
	object, err := runtime.new(T, MemoryArena_Allocator(&arena))
	if err != nil {
		runtime.arena_destroy(&arena)
		return nil, false
	}
	(^runtime.Arena)(uintptr(object) + offset)^ = arena
	return object, true
}

/*
Reads a whole file from Emscripten's virtual file system (through SDL).

Inputs:
- path: The file's path

Returns:
- The contents (temp allocated) and true; false if it can't be read
*/
Platform_ReadFile :: proc(path: string) -> ([]byte, bool) {
	size: c.size_t
	data := sdl.LoadFile(fmt.ctprint(path), &size)
	if data == nil do return nil, false
	defer sdl.free(data)
	copy := make([]byte, int(size), context.temp_allocator)
	runtime.mem_copy(raw_data(copy), data, int(size))
	return copy, true
}

// The data pack is the desktop exports' (pack.odin): the browser preloads files instead.
// The project folder of a packed game: paths under it are the pack's
PACK_ROOT :: "<pack>"
// No data pack in the browser: always false
Pack_Open :: proc() -> bool { return false }
/*
A file in the game's data pack. The browser has no data pack.

Inputs:
- path: The file's path (ignored)

Returns:
- Always nil, false
*/
Pack_Bytes :: proc(path: string) -> ([]byte, bool) { return nil, false }

/*
Whether the game's data pack has a file. The browser has no data pack.

Inputs:
- path: The file's path (ignored)

Returns:
- Always false
*/
Pack_Has :: proc(path: string) -> bool { return false }

/*
Whether a file exists in Emscripten's virtual file system.

Inputs:
- path: The file's path

Returns:
- true if it exists
*/
Platform_FileExists :: proc(path: string) -> bool {
	return sdl.GetPathInfo(fmt.ctprint(path), nil)
}

// The packaged game is at the root of the virtual file system
Platform_ExecutableDir :: proc() -> (string, bool) {
	return "/", true
}

/*
Loads an image file as a texture. The browser build reads PNG and BMP only (SDL's own loaders).

Most code loads through `ResourceManager` (`loadTexture`), which caches the texture.

Inputs:
- renderer: The renderer the texture is for
- path: The image's path

Returns:
- The texture (the caller destroys it), or nil (logged) if it can't be read
*/
Platform_LoadTexture :: proc(renderer: ^sdl.Renderer, path: string) -> ^sdl.Texture {
	surface := sdl.LoadPNG(fmt.ctprint(path))
	if surface == nil do surface = sdl.LoadBMP(fmt.ctprint(path))
	if surface == nil {
		log.warnf("Couldn't load %s (the web build reads PNG and BMP images): %s", path, sdl.GetError())
		return nil
	}
	defer sdl.DestroySurface(surface)
	return sdl.CreateTextureFromSurface(renderer, surface)
}

/*
Reads an image file into a surface: PNG or BMP in the browser.

Inputs:
- path: The file

Returns:
- The surface (the caller's), or nil
*/
Platform_LoadSurface :: proc(path: string) -> ^sdl.Surface {
	surface := sdl.LoadPNG(fmt.ctprint(path))
	if surface == nil do surface = sdl.LoadBMP(fmt.ctprint(path))
	return surface
}

// Saves in the browser: localStorage (web/odin_env.js), keyed "<game>/<slot>"
foreign import storage "env.o"

@(default_calling_convention = "c")
foreign storage {
	// Stores a value under a key; nonzero on success
	odin_storage_set :: proc(key: [^]u8, keyLength: i32, value: [^]u8, valueLength: i32) -> i32 ---
	// The value's size in bytes, or -1 if there's none
	odin_storage_size :: proc(key: [^]u8, keyLength: i32) -> i32 ---
	// Copies the value into the buffer; the bytes copied, or -1 if there's none
	odin_storage_get :: proc(key: [^]u8, keyLength: i32, buffer: [^]u8, capacity: i32) -> i32 ---
	// Removes the key's value
	odin_storage_remove :: proc(key: [^]u8, keyLength: i32) ---
}

/*
Writes a save: in the browser, to localStorage under "<game>/<slot>". Use `Save_Write`
(save.odin) rather than calling this directly.

Inputs:
- name: "<game>/<slot>"
- data: The save's contents

Returns:
- false if it couldn't be stored
*/
Platform_SaveWrite :: proc(name: string, data: []byte) -> bool {
	return odin_storage_set(raw_data(name), i32(len(name)), raw_data(data), i32(len(data))) != 0
}

/*
Reads a save written by `Platform_SaveWrite`.

Inputs:
- name: "<game>/<slot>"

Returns:
- The contents (temp allocated) and true; false if there's no such save
*/
Platform_SaveRead :: proc(name: string) -> ([]byte, bool) {
	size := odin_storage_size(raw_data(name), i32(len(name)))
	if size < 0 do return nil, false
	buffer := make([]byte, size, context.temp_allocator)
	got := odin_storage_get(raw_data(name), i32(len(name)), raw_data(buffer), size)
	return buffer[:max(got, 0)], got >= 0
}

/*
Whether a save exists.

Inputs:
- name: "<game>/<slot>"

Returns:
- true if it exists
*/
Platform_SaveExists :: proc(name: string) -> bool {
	return odin_storage_size(raw_data(name), i32(len(name))) >= 0
}

/*
Deletes a save, if it exists.

Inputs:
- name: "<game>/<slot>"
*/
Platform_SaveDelete :: proc(name: string) {
	odin_storage_remove(raw_data(name), i32(len(name)))
}

// Browsers show the page's favicon: games' window icons do nothing there
Platform_SetWindowIcon :: proc(window: ^sdl.Window, data: []byte) -> bool {
	return false
}

// Writes a file: the browser has none to write (false)
Platform_WriteFile :: proc(path: string, data: []byte) -> bool {
	return false
}
