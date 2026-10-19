#+build linux, darwin
package engine

/*
Static SDL: when tools/build_sdl_static.sh has built SDL3, SDL3_image, SDL3_ttf and SDL3_mixer for
this OS and CPU (sdl/lib/<os>_<arch>/), every program that imports the engine links them instead
of the system's shared libraries. An exported game is then one executable that needs only libc
(and loads the OS's window system, graphics and audio at run time, as SDL always does).

How: Odin's vendor:sdl3 bindings ask the linker for `-lSDL3` (and _image, _ttf, _mixer). The
linker takes the first folder in its search path that has a match, so `-L` to a folder of only
static archives wins over the system's .so files. The archives are also listed again here, so
symbols SDL3_ttf, _image and _mixer need from SDL3 resolve whatever order the -l flags came in.

`-define:SDL_STATIC=false` links the system's shared libraries even when the static ones are
built. Windows isn't covered yet (its binding names a fixed SDL3.lib, an import library).
*/

// Link the static SDL libraries when they're built (false: always the system's shared ones)
SDL_STATIC :: #config(SDL_STATIC, true)

// Where tools/build_sdl_static.sh puts this platform's static SDL: relative to the engine (foreign
// imports take that) and absolute (for the linker's -L)
SDL_STATIC_LIBS :: "sdl/lib/" + ODIN_OS_STRING + "_" + ODIN_ARCH_STRING
SDL_STATIC_DIR :: #directory + SDL_STATIC_LIBS

// Whether this build links SDL statically
SDL_LINKED_STATICALLY :: SDL_STATIC && #exists(SDL_STATIC_LIBS + "/libSDL3.a")

when SDL_LINKED_STATICALLY {
	when ODIN_OS == .Darwin {
		@(extra_linker_flags = "-L" + SDL_STATIC_DIR + " -framework Cocoa -framework IOKit -framework CoreAudio -framework AudioToolbox -framework CoreVideo -framework Carbon -framework ForceFeedback -framework GameController -framework CoreHaptics -framework Metal -framework QuartzCore -framework UniformTypeIdentifiers -framework AVFoundation -framework CoreMedia -framework CoreFoundation -framework ImageIO -framework CoreServices -liconv")
		foreign import sdl_static {
			SDL_STATIC_LIBS + "/libSDL3_image.a",
			SDL_STATIC_LIBS + "/libSDL3_ttf.a",
			SDL_STATIC_LIBS + "/libSDL3_mixer.a",
			SDL_STATIC_LIBS + "/libSDL3.a",
		}
	} else {
		@(extra_linker_flags = "-L" + SDL_STATIC_DIR + " -pthread -lm")
		foreign import sdl_static {
			SDL_STATIC_LIBS + "/libSDL3_image.a",
			SDL_STATIC_LIBS + "/libSDL3_ttf.a",
			SDL_STATIC_LIBS + "/libSDL3_mixer.a",
			SDL_STATIC_LIBS + "/libSDL3.a",
		}
	}
	// The import must be used for Odin to pass it to the linker
	@(private="file", default_calling_convention = "c")
	foreign sdl_static {
		SDL_GetVersion :: proc() -> i32 ---
	}
	@(private="file", init)
	keepStaticSDL :: proc "contextless" () {
		_ = SDL_GetVersion
	}
}
