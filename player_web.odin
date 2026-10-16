#+build js
package engine

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

/*
The player in a browser. The editor's Web export builds the game's player (the same `main`
package as a desktop build) for `js_wasm32` with `-build-mode:obj`, and links it with Emscripten:

	emcc <engine>/web/main.c game.wasm.o libSDL3_mixer.a -o index.html -sUSE_SDL=3 -sUSE_SDL_TTF=3
		-sALLOW_MEMORY_GROWTH --js-library <engine>/web/odin_env.js
		--pre-js <engine>/web/odin_env_pre.js --preload-file <project>@/data

Emscripten starts at C `main` (web/main.c), which calls `odin_web_main` below; the player's own
`main` isn't used. The browser can't run a blocking loop, so instead of `Application_Run`,
Emscripten calls `Application_Frame` once per animation frame.

- Memory: Emscripten owns the wasm heap, so the allocator is its `malloc` (`Web_Context`).
- Files: the project is packaged into Emscripten's virtual file system under /data.
- web/odin_env.js and web/odin_env_pre.js supply what Odin's js runtime imports from the
  "odin_env" module (console output, random bytes, some math).
- Audio: SDL3_mixer, built for the web by the editor (`tools/build_web_mixer.sh`: Emscripten has
  no SDL3_mixer port). Browsers start sound only after the player clicks or presses a key.
- Limits: images load with SDL's built-in PNG and BMP loaders (no SDL_image port exists).
*/

// Where the Web export packages the project
WEB_PROJECT_DIR :: "/data"

foreign import emscripten "env.o"

@(default_calling_convention = "c")
foreign emscripten {
	emscripten_set_main_loop :: proc(callback: proc "c" (), fps: c.int, simulateInfiniteLoop: bool) ---
	emscripten_cancel_main_loop :: proc() ---
	@(link_name = "calloc") web_calloc :: proc(count, size: c.size_t) -> rawptr ---
	@(link_name = "aligned_alloc") web_aligned_alloc :: proc(alignment, size: c.size_t) -> rawptr ---
	@(link_name = "realloc") web_realloc :: proc(ptr: rawptr, size: c.size_t) -> rawptr ---
	@(link_name = "free") web_free :: proc(ptr: rawptr) ---
	@(link_name = "puts") web_puts :: proc(text: cstring) -> c.int ---
}

/*
The web build's entry point, called from web/main.c: runs the game's `@(init)` procedures (script
registration) and starts the project packaged under /data.
*/
@(export)
odin_web_main :: proc "c" () {
	context = Web_Context()
	runtime._startup_runtime()
	Player_StartWeb()
}

/*
Does nothing in the browser: a player's `main` isn't called there (Emscripten calls C `main`,
which calls `odin_web_main`). On the desktop it runs the player; see platform_native.odin.
*/
Player_Main :: proc() {}

@(private="file")
web: struct {
	app: Application,
	temp: runtime.Arena,
	ready: bool,
}

// A context for contextless code (`@(init)` procedures): `Web_Context`, so it allocates from Emscripten's heap
Platform_DefaultContext :: proc "contextless" () -> runtime.Context {
	return Web_Context()
}

/*
A context for code running in the browser: Emscripten's malloc as the allocator, a temporary
arena (freed each frame), and a logger that writes to the browser console. Call at the start of
every entry point the page calls into (`context = e.Web_Context()`).
*/
Web_Context :: proc "contextless" () -> runtime.Context {
	ctx := runtime.default_context()
	ctx.allocator = {procedure = webAllocatorProc}
	if web.temp.minimum_block_size == 0 {
		context = ctx
		_ = runtime.arena_init(&web.temp, 1024 * 1024, ctx.allocator)
	}
	ctx.temp_allocator = {procedure = runtime.arena_allocator_proc, data = &web.temp}
	ctx.logger = {procedure = webLoggerProc, lowest_level = .Info}
	return ctx
}

/*
Starts the game in the browser: loads the packaged project and hands Emscripten the frame
callback. Returns at once; the game keeps running from the browser's animation frames.

Inputs:
- scene: Start in this scene instead of the project's start scene ("" for the start scene)
*/
Player_StartWeb :: proc(scene := "") {
	options := PlayerOptions{projectDir = WEB_PROJECT_DIR, folderGiven = true, scene = scene}
	if !Player_Setup(options, &web.app) {
		log.error("The game couldn't start")
		return
	}
	web.ready = true
	emscripten_set_main_loop(webFrame, 0, false)
	sdl.SetRenderVSync(web.app.renderer, 1)
}

@(private="file")
webFrame :: proc "c" () {
	context = Web_Context()
	if !web.ready do return
	Application_Frame(&web.app)
	if !web.app.running {
		// A web page can't quit; stop the frames
		emscripten_cancel_main_loop()
		Application_Cleanup(&web.app)
		web.ready = false
		log.info("Game closed")
	}
}

// malloc's alignment; larger alignments (Odin's maps want 64) go through aligned_alloc
@(private="file")
WEB_MALLOC_ALIGNMENT :: 8

@(private="file")
webAllocatorProc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, oldSize: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	alloc :: proc(size, alignment: int) -> rawptr {
		if alignment <= WEB_MALLOC_ALIGNMENT do return web_calloc(1, c.size_t(max(size, 1)))
		// aligned_alloc wants a size that's a multiple of the alignment
		rounded := (max(size, 1) + alignment - 1) / alignment * alignment
		p := web_aligned_alloc(c.size_t(alignment), c.size_t(rounded))
		if p != nil do runtime.mem_zero(p, rounded)
		return p
	}
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		p := alloc(size, alignment)
		if p == nil do return nil, .Out_Of_Memory
		return ([^]byte)(p)[:size], nil
	case .Free:
		web_free(old)
	case .Resize, .Resize_Non_Zeroed:
		p: rawptr
		if alignment <= WEB_MALLOC_ALIGNMENT {
			p = web_realloc(old, c.size_t(max(size, 1)))
			if p != nil && size > oldSize do runtime.mem_zero(rawptr(uintptr(p) + uintptr(oldSize)), size - oldSize)
		} else {
			p = alloc(size, alignment)
			if p != nil && old != nil do runtime.mem_copy_non_overlapping(p, old, min(size, oldSize))
			if p != nil do web_free(old)
		}
		if p == nil do return nil, .Out_Of_Memory
		return ([^]byte)(p)[:size], nil
	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old)
		if set != nil do set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
	}
	return nil, nil
}

@(private="file")
webLoggerProc :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	tag := "INFO"
	switch level {
	case .Debug:   tag = "DEBUG"
	case .Info:    tag = "INFO"
	case .Warning: tag = "WARN"
	case .Error:   tag = "ERROR"
	case .Fatal:   tag = "FATAL"
	}
	web_puts(strings.clone_to_cstring(fmt.tprintf("[%s] %s", tag, text), context.temp_allocator))
}
