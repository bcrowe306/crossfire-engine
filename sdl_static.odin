#+build linux, darwin, windows
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

**Windows:** the vendor bindings name Odin's own `SDL3.lib` (and `SDL3_image.lib`...), import
libraries of the DLLs, by path: no search path can replace them. But MSVC's linker resolves a
symbol from the first library on its command line that has it, and Odin orders foreign imports by
`priority_index` first: this file's, -1, come before the bindings' (0), so the static libraries
define every SDL function and the import libraries go unused (the game doesn't load SDL3.dll).
The static libraries need Windows' own: user32, gdi32, winmm, imm32, ole32, oleaut32, version,
uuid, advapi32, setupapi, shell32.

`-define:SDL_STATIC=false` links the system's shared libraries (the DLLs on Windows) even when the
static ones are built.
*/

// Link the static SDL libraries when they're built (false: always the system's shared ones)
SDL_STATIC :: #config(SDL_STATIC, true)

// Where tools/build_sdl_static.sh puts this platform's static SDL: relative to the engine (foreign
// imports take that) and absolute (for the linker's -L, quoted: the linker runs through a shell,
// and the engine may be in a folder with a space, like a macOS app bundle's)
SDL_STATIC_LIBS :: "sdl/lib/" + ODIN_OS_STRING + "_" + ODIN_ARCH_STRING
// The same folder as an absolute path (for the linker's -L)
SDL_STATIC_DIR :: #directory + SDL_STATIC_LIBS

// Whether this build links SDL statically
SDL_LINKED_STATICALLY :: SDL_STATIC && (#exists(SDL_STATIC_LIBS + "/libSDL3.a") || #exists(SDL_STATIC_LIBS + "/sdl3_static.lib"))

when SDL_LINKED_STATICALLY {
	when ODIN_OS == .Darwin {
		// Odin's macOS link puts -L/usr/local/lib and -L/opt/homebrew/lib (when it exists) before
		// every library, so the bindings' -lSDL3 finds Homebrew's dylib first: these archives
		// come first instead (priority_index, as on Windows) and define SDL's symbols, and
		// -dead_strip_dylibs drops the then-unused Homebrew dylibs
		@(priority_index = -1)
		@(extra_linker_flags = "-Wl,-dead_strip_dylibs -L\"" + SDL_STATIC_DIR + "\" -framework Cocoa -framework IOKit -framework CoreAudio -framework AudioToolbox -framework CoreVideo -framework Carbon -framework ForceFeedback -framework GameController -framework CoreHaptics -framework Metal -framework QuartzCore -framework UniformTypeIdentifiers -framework AVFoundation -framework CoreMedia -framework CoreFoundation -framework ImageIO -framework CoreServices -liconv")
		foreign import sdl_static {
			SDL_STATIC_LIBS + "/libSDL3_image.a",
			SDL_STATIC_LIBS + "/libSDL3_ttf.a",
			SDL_STATIC_LIBS + "/libSDL3_mixer.a",
			SDL_STATIC_LIBS + "/libSDL3.a",
		}
	} else when ODIN_OS == .Windows {
		// Before the vendor bindings' import libraries (see above)
		when #exists(SDL_STATIC_LIBS + "/freetype_static.lib") {
			@(priority_index = -1)
			foreign import sdl_static {
				SDL_STATIC_LIBS + "/sdl3_image_static.lib",
				SDL_STATIC_LIBS + "/sdl3_ttf_static.lib",
				SDL_STATIC_LIBS + "/freetype_static.lib",
				SDL_STATIC_LIBS + "/sdl3_mixer_static.lib",
				SDL_STATIC_LIBS + "/sdl3_static.lib",
				"system:user32.lib", "system:gdi32.lib", "system:winmm.lib", "system:imm32.lib", "system:ole32.lib",
				"system:oleaut32.lib", "system:version.lib", "system:uuid.lib", "system:advapi32.lib",
				"system:setupapi.lib", "system:shell32.lib",
			}
		} else {
			@(priority_index = -1)
			foreign import sdl_static {
				SDL_STATIC_LIBS + "/sdl3_image_static.lib",
				SDL_STATIC_LIBS + "/sdl3_ttf_static.lib",
				SDL_STATIC_LIBS + "/sdl3_mixer_static.lib",
				SDL_STATIC_LIBS + "/sdl3_static.lib",
				"system:user32.lib", "system:gdi32.lib", "system:winmm.lib", "system:imm32.lib", "system:ole32.lib",
				"system:oleaut32.lib", "system:version.lib", "system:uuid.lib", "system:advapi32.lib",
				"system:setupapi.lib", "system:shell32.lib",
			}
		}
	} else {
		@(extra_linker_flags = "-L\"" + SDL_STATIC_DIR + "\" -pthread -lm")
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
