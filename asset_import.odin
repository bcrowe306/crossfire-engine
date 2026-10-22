package crossfire

import "core:strings"
import sdl "vendor:sdl3"

/*
Import settings of a project's assets: how its images are filtered, and which fonts have MSDF
atlases (fonts.odin).

An image drawn bigger, smaller or turned is sampled either **smoothly** (linear filtering: soft
edges, right for painted art and photos) or by **pixels** (nearest: hard square pixels, right for
pixel art). Each image asset can say which (`<asset path=... filter="Pixel"/>`, `AssetRef.filter`),
else the project's `textureFilter` decides, else Smooth for images and Pixel for Aseprite files.
`Game_LoadProject` hands the assets' settings to the resource manager
(`ResourceManager_SetImportSettings`), which applies them to each texture it loads; editors call
`ResourceManager_SetTextureFilter` when one changes, which also changes the textures already
loaded.
*/

// How an image is sampled when drawn scaled or turned
TextureFilter :: enum {
	// The project's setting (an asset's), or Smooth (Aseprite files: Pixel) for the project
	Default,
	// Linear filtering: soft, for painted art
	Smooth,
	// Nearest filtering: hard pixels, for pixel art
	Pixel,
}

/*
Sets the resource manager's import settings from a project: image filtering (the default and
each image asset's; textures already loaded change too) and which fonts have MSDF atlases.

Inputs:
- rm: The resource manager
- assets: The project's assets (`ProjectData.assets`)
- projectDir: Their folder (what their paths are joined to when loaded)
- default: The project's filtering (`ProjectData.textureFilter`)
*/
ResourceManager_SetImportSettings :: proc(rm: ^ResourceManager, assets: []AssetRef, projectDir: string, default: TextureFilter) {
	for key in rm.textureFilters do delete(key)
	clear(&rm.textureFilters)
	rm.defaultFilter = default
	// Fonts no longer marked lose their atlas
	stale := make([dynamic]string, context.temp_allocator)
	for key in rm.msdfFonts do append(&stale, strings.clone(key, context.temp_allocator))
	for key in stale {
		marked := false
		for asset in assets do if asset.msdf && JoinPath(projectDir, asset.path) == key do marked = true
		if !marked do ResourceManager_SetFontMSDF(rm, key, false)
	}
	for asset in assets {
		path := JoinPath(projectDir, asset.path)
		if asset.filter != .Default do rm.textureFilters[strings.clone(path)] = asset.filter
		ResourceManager_SetFontMSDF(rm, path, asset.msdf)
	}
	textureFiltersApply(rm)
}

/*
Sets one image's filtering (Default: the project's), the texture too if it's loaded (its
Aseprite sheets and layers with it).

Inputs:
- rm: The resource manager
- path: The image's path as textures are loaded with it (the project folder joined)
- filter: Its filtering
*/
ResourceManager_SetTextureFilter :: proc(rm: ^ResourceManager, path: string, filter: TextureFilter) {
	if path in rm.textureFilters {
		if filter == .Default {
			key, _ := delete_key(&rm.textureFilters, path)
			delete(key)
		} else {
			rm.textureFilters[path] = filter
		}
	} else if filter != .Default {
		rm.textureFilters[strings.clone(path)] = filter
	}
	textureFiltersApply(rm)
}

/*
The filtering an image is drawn with: its own, the project's, else Smooth (Aseprite files Pixel).

Inputs:
- rm: The resource manager
- path: The image's file
*/
ResourceManager_TextureFilter :: proc(rm: ^ResourceManager, path: string) -> TextureFilter {
	if filter, found := rm.textureFilters[path]; found && filter != .Default do return filter
	if rm.defaultFilter != .Default do return rm.defaultFilter
	return Aseprite_IsFile(path) ? .Pixel : .Smooth
}

// INTERNAL

// SDL's scale mode for an image file
@(private)
textureScaleMode :: proc(rm: ^ResourceManager, file: string) -> sdl.ScaleMode {
	return ResourceManager_TextureFilter(rm, file) == .Pixel ? .NEAREST : .LINEAR
}

// Applies the filtering to every loaded texture (an Aseprite sheet's key ends after its file)
@(private="file")
textureFiltersApply :: proc(rm: ^ResourceManager) {
	for key, texture in rm.textures {
		file, _, _ := asepriteTextureKey(key)
		sdl.SetTextureScaleMode(texture, textureScaleMode(rm, file))
	}
}
