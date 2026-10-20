package crossfire

import "core:log"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import ttf "vendor:sdl3/ttf"


// Open Sans Regular, compiled into the binary. Pass DEFAULT_FONT as the path to `loadFont`
// to get it at other sizes
DEFAULT_FONT :: "engine:default_font"
// The point size of `ResourceManager.defaultFont`
DEFAULT_FONT_SIZE :: 16
@(private="file")
DEFAULT_FONT_DATA := #load("Open_Sans/static/OpenSans-Regular.ttf")

/*
The game's cache of textures, sounds and fonts (`Game.resourceManager`).

Assets are keyed by file path (fonts by path and size), so loading the same file twice returns
the handle already loaded. Paths are read as given (relative to the working directory, or
looked up in the game's data pack). The manager owns what it loads: `unload*` frees one asset,
`destroy` (called by `Game_Destroy`) frees everything still loaded. Call the procedures with
`->`.

Example:
	rm := &game.resourceManager
	ship := rm->loadTexture("assets/ship.png")
	laser := rm->loadAudio("assets/laser.wav")
	music := rm->loadAudio("assets/theme.ogg", predecode = false)
	title := rm->loadFont(e.DEFAULT_FONT, 48)
	_, _, _, _ = ship, laser, music, title
*/
ResourceManager :: struct {
	// The renderer textures are made for
	renderer: ^sdl.Renderer,
	// The mixer sounds are loaded for
	mixer: ^mix.Mixer,
	// Loaded textures, by path (the keys are owned)
	textures: map[string]^sdl.Texture,
	// Loaded sounds, by path (the keys are owned)
	audio: map[string]^mix.Audio,
	// Loaded fonts, by "path@size" (the keys are owned)
	fonts: map[string]^ttf.Font,
	// The embedded font at DEFAULT_FONT_SIZE, loaded by ResourceManager_Init
	defaultFont: ^ttf.Font,
	// Draws text through the renderer, caching glyphs in a GPU atlas. Used by the text primitives
	textEngine: ^ttf.TextEngine,
	// Loads an image (any format SDL_image reads: png, jpg, bmp, webp...) as a texture, or
	// returns the one already loaded. nil (logged) if it can't be read
	loadTexture: proc(rm: ^ResourceManager, filePath: string) -> ^sdl.Texture,
	// Loads a sound or music file, or returns the one already loaded. `predecode` decodes the
	// whole file up front (best for short effects); pass false to stream long music. nil (logged)
	// if it can't be read
	loadAudio: proc(rm: ^ResourceManager, filePath: string, predecode: bool = true) -> ^mix.Audio,
	// Loads a font at a point size (`DEFAULT_FONT` for the embedded one), or returns the one
	// already loaded at that size. nil (logged) if it can't be read
	loadFont: proc(rm: ^ResourceManager, filePath: string, size: f32) -> ^ttf.Font,
	// Frees a loaded texture. Anything still drawing it must stop first
	unloadTexture: proc(rm: ^ResourceManager, filePath: string),
	// Frees a loaded sound. Anything still playing it must stop first
	unloadAudio: proc(rm: ^ResourceManager, filePath: string),
	// Frees a font loaded at that size. Anything still using it must stop first
	unloadFont: proc(rm: ^ResourceManager, filePath: string, size: f32),
	// Frees the text engine and everything still loaded (`Game_Destroy` calls it)
	destroy: proc(rm: ^ResourceManager),
}

/*
Sets up a resource manager: its maps and procedures, the text engine, and the default font
(`DEFAULT_FONT` at `DEFAULT_FONT_SIZE`). `Game_Init` calls it for `Game.resourceManager`.

Inputs:
- rm: The resource manager
- renderer: The renderer textures and text are made for
- mixer: The mixer sounds are loaded for
*/
ResourceManager_Init :: proc(rm: ^ResourceManager, renderer: ^sdl.Renderer, mixer: ^mix.Mixer) {
	rm.renderer = renderer
	rm.mixer = mixer
	rm.textures = make(map[string]^sdl.Texture)
	rm.audio = make(map[string]^mix.Audio)
	rm.fonts = make(map[string]^ttf.Font)
	rm.loadTexture = ResourceManager_loadTexture
	rm.loadAudio = ResourceManager_loadAudio
	rm.loadFont = ResourceManager_loadFont
	rm.unloadTexture = ResourceManager_unloadTexture
	rm.unloadAudio = ResourceManager_unloadAudio
	rm.unloadFont = ResourceManager_unloadFont
	rm.destroy = ResourceManager_destroy

	rm.textEngine = ttf.CreateRendererTextEngine(renderer)
	if rm.textEngine == nil {
		log.errorf("Error creating text engine: %s", sdl.GetError())
	}

	rm.defaultFont = rm->loadFont(DEFAULT_FONT, DEFAULT_FONT_SIZE)
}

// Loads any image format supported by SDL_image (png, jpg, bmp, webp, ...)
@(private)
ResourceManager_loadTexture :: proc(rm: ^ResourceManager, filePath: string) -> ^sdl.Texture {
	if tex, ok := rm.textures[filePath]; ok {
		return tex
	}

	tex := Platform_LoadTexture(rm.renderer, filePath)
	if tex == nil {
		log.errorf("Error loading texture: %s, %s", filePath, sdl.GetError())
		return nil
	}

	rm.textures[strings.clone(filePath)] = tex
	return tex
}

// Loads a sound or music file. predecode decodes the whole file up front, which is best
// for short sound effects. Pass false for long music tracks to stream them instead.
@(private)
ResourceManager_loadAudio :: proc(rm: ^ResourceManager, filePath: string, predecode: bool = true) -> ^mix.Audio {
	if audio, ok := rm.audio[filePath]; ok {
		return audio
	}

	audio := Audio_Load(rm.mixer, filePath, predecode)
	if audio == nil {
		log.errorf("Error loading audio: %s, %s", filePath, sdl.GetError())
		return nil
	}

	rm.audio[strings.clone(filePath)] = audio
	return audio
}

// Fonts are cached per point size, so the same file can be loaded at several sizes
@(private)
ResourceManager_loadFont :: proc(rm: ^ResourceManager, filePath: string, size: f32) -> ^ttf.Font {
	key := fontKey(filePath, size, context.temp_allocator)
	if font, ok := rm.fonts[key]; ok {
		return font
	}

	font: ^ttf.Font
	if filePath == DEFAULT_FONT {
		// The embedded data is static, so the stream can read from it directly. closeio = true
		// frees the stream (not the data) when the font is closed
		io := sdl.IOFromConstMem(raw_data(DEFAULT_FONT_DATA), len(DEFAULT_FONT_DATA))
		font = ttf.OpenFontIO(io, true, size)
	} else if data, packed := Pack_Bytes(filePath); packed {
		// The data pack's memory lives as long as the program
		font = ttf.OpenFontIO(sdl.IOFromConstMem(raw_data(data), uint(len(data))), true, size)
	} else {
		font = ttf.OpenFont(fmt.ctprint(filePath), size)
	}
	if font == nil {
		log.errorf("Error loading font: %s, %s", filePath, sdl.GetError())
		return nil
	}

	rm.fonts[strings.clone(key)] = font
	return font
}

@(private)
ResourceManager_unloadTexture :: proc(rm: ^ResourceManager, filePath: string) {
	if filePath not_in rm.textures do return
	key, tex := delete_key(&rm.textures, filePath)
	sdl.DestroyTexture(tex)
	delete(key)
}

@(private)
ResourceManager_unloadAudio :: proc(rm: ^ResourceManager, filePath: string) {
	if filePath not_in rm.audio do return
	key, audio := delete_key(&rm.audio, filePath)
	Audio_Destroy(audio)
	delete(key)
}

@(private)
ResourceManager_unloadFont :: proc(rm: ^ResourceManager, filePath: string, size: f32) {
	lookup := fontKey(filePath, size, context.temp_allocator)
	if lookup not_in rm.fonts do return
	key, font := delete_key(&rm.fonts, lookup)
	if font == rm.defaultFont do rm.defaultFont = nil
	ttf.CloseFont(font)
	delete(key)
}

@(private)
ResourceManager_destroy :: proc(rm: ^ResourceManager) {
	if rm.textEngine != nil {
		ttf.DestroyRendererTextEngine(rm.textEngine)
		rm.textEngine = nil
	}

	for key, texture in rm.textures {
		sdl.DestroyTexture(texture)
		delete(key)
	}
	delete(rm.textures)

	for key, audio in rm.audio {
		Audio_Destroy(audio)
		delete(key)
	}
	delete(rm.audio)

	for key, font in rm.fonts {
		ttf.CloseFont(font)
		delete(key)
	}
	delete(rm.fonts)
}

@(private="file")
fontKey :: proc(filePath: string, size: f32, allocator := context.allocator) -> string {
	return fmt.aprintf("%s@%v", filePath, size, allocator = allocator)
}
