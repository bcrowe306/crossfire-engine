#+build js
package engine

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import sdl "vendor:sdl3"

/*
Platform services, browser version: a WebAssembly build linked by Emscripten (the editor's Web
export). Same procedures as platform_native.odin, without `core:os` (unsupported on js/wasm),
virtual memory (there is none), SDL3_image and SDL3_mixer (Emscripten has no ports of them yet):
- files are read through SDL, which reads Emscripten's virtual file system (the exported game's
  data is packaged into it)
- arenas grow from the context allocator, which `Web_Context` makes Emscripten's malloc
- images: PNG and BMP, with SDL's own loaders
- audio: none yet (loading returns nil)
*/

PLATFORM_WEB :: true

MemoryArena :: runtime.Arena

// Block size of web arenas; they grow by adding blocks
WEB_ARENA_BLOCK_SIZE :: 16 * 1024

MemoryArena_InitGrowing :: proc(arena: ^MemoryArena) -> bool {
	return runtime.arena_init(arena, WEB_ARENA_BLOCK_SIZE, context.allocator) == nil
}

MemoryArena_Allocator :: proc(arena: ^MemoryArena) -> runtime.Allocator {
	return runtime.Allocator{procedure = runtime.arena_allocator_proc, data = arena}
}

MemoryArena_Destroy :: proc(arena: ^MemoryArena) {
	runtime.arena_destroy(arena)
}

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

Platform_ReadFile :: proc(path: string) -> ([]byte, bool) {
	size: c.size_t
	data := sdl.LoadFile(fmt.ctprint(path), &size)
	if data == nil do return nil, false
	defer sdl.free(data)
	copy := make([]byte, int(size), context.temp_allocator)
	runtime.mem_copy(raw_data(copy), data, int(size))
	return copy, true
}

Platform_FileExists :: proc(path: string) -> bool {
	return sdl.GetPathInfo(fmt.ctprint(path), nil)
}

// The packaged game is at the root of the virtual file system
Platform_ExecutableDir :: proc() -> (string, bool) {
	return "/", true
}

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
