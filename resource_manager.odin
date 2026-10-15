package engine

import "core:log"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"
import mix "vendor:sdl3/mixer"
import ttf "vendor:sdl3/ttf"


// Open Sans Regular, compiled into the binary. Pass DEFAULT_FONT as the path to loadFont
// to get it at other sizes.
DEFAULT_FONT :: "engine:default_font"
DEFAULT_FONT_SIZE :: 16
@(private="file")
DEFAULT_FONT_DATA := #load("Open_Sans/static/OpenSans-Regular.ttf")

// Central cache for all game assets. Assets are keyed by file path (fonts by path + size),
// so loading the same file twice returns the already loaded handle.
// Everything still loaded is freed by destroy.
ResourceManager :: struct {
	renderer: ^sdl.Renderer,
	mixer: ^mix.Mixer,
	textures: map[string]^sdl.Texture,
	audio: map[string]^mix.Audio,
	fonts: map[string]^ttf.Font,
	// The embedded font at DEFAULT_FONT_SIZE, loaded by ResourceManager_Init
	defaultFont: ^ttf.Font,
	// Draws text through the renderer, caching glyphs in a GPU atlas. Used by the text primitives
	textEngine: ^ttf.TextEngine,
	loadTexture: proc(rm: ^ResourceManager, filePath: string) -> ^sdl.Texture,
	loadAudio: proc(rm: ^ResourceManager, filePath: string, predecode: bool = true) -> ^mix.Audio,
	loadFont: proc(rm: ^ResourceManager, filePath: string, size: f32) -> ^ttf.Font,
	unloadTexture: proc(rm: ^ResourceManager, filePath: string),
	unloadAudio: proc(rm: ^ResourceManager, filePath: string),
	unloadFont: proc(rm: ^ResourceManager, filePath: string, size: f32),
	destroy: proc(rm: ^ResourceManager),
}

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
ResourceManager_loadTexture :: proc(rm: ^ResourceManager, filePath: string) -> ^sdl.Texture {
	if tex, ok := rm.textures[filePath]; ok {
		return tex
	}

	tex := img.LoadTexture(rm.renderer, fmt.ctprint(filePath))
	if tex == nil {
		log.errorf("Error loading texture: %s, %s", filePath, sdl.GetError())
		return nil
	}

	rm.textures[strings.clone(filePath)] = tex
	return tex
}

// Loads a sound or music file. predecode decodes the whole file up front, which is best
// for short sound effects. Pass false for long music tracks to stream them instead.
ResourceManager_loadAudio :: proc(rm: ^ResourceManager, filePath: string, predecode: bool = true) -> ^mix.Audio {
	if audio, ok := rm.audio[filePath]; ok {
		return audio
	}

	audio := mix.LoadAudio(rm.mixer, fmt.ctprint(filePath), predecode)
	if audio == nil {
		log.errorf("Error loading audio: %s, %s", filePath, sdl.GetError())
		return nil
	}

	rm.audio[strings.clone(filePath)] = audio
	return audio
}

// Fonts are cached per point size, so the same file can be loaded at several sizes
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

ResourceManager_unloadTexture :: proc(rm: ^ResourceManager, filePath: string) {
	if filePath not_in rm.textures do return
	key, tex := delete_key(&rm.textures, filePath)
	sdl.DestroyTexture(tex)
	delete(key)
}

ResourceManager_unloadAudio :: proc(rm: ^ResourceManager, filePath: string) {
	if filePath not_in rm.audio do return
	key, audio := delete_key(&rm.audio, filePath)
	mix.DestroyAudio(audio)
	delete(key)
}

ResourceManager_unloadFont :: proc(rm: ^ResourceManager, filePath: string, size: f32) {
	lookup := fontKey(filePath, size, context.temp_allocator)
	if lookup not_in rm.fonts do return
	key, font := delete_key(&rm.fonts, lookup)
	if font == rm.defaultFont do rm.defaultFont = nil
	ttf.CloseFont(font)
	delete(key)
}

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
		mix.DestroyAudio(audio)
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
