package engine

import "core:log"
import mix "vendor:sdl3/mixer"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

/*
Typed asset handles: a project asset's path, with its kind in the type, so code can't play a
texture or draw a sound. Scripts get them two ways:
- The editor writes `scripts/assets.odin` with a constant for every project asset
  (`TEXTURE_SHIP`, `SOUND_LASER`, `DATA_GOBLIN`, ...): checked by the compiler, completed by the
  code editor, and only naming assets exports ship.
- As exported fields (`ship: e.TextureAsset \`export:""\``): the inspector shows a picker of the
  project's assets of that kind.

Handles resolve against the project folder (`Game.projectDir`) and are loaded on first use, then
cached by the resource manager.

Example:
	e.Game_PlaySound(self.game, SOUND_LASER)
	texture := e.Asset_Texture(self.game, TEXTURE_SHIP)
	stats := e.Data(ShipStats, DATA_FAST_SHIP)
*/

// An image in the project (Sprite textures)
TextureAsset :: struct {
	path: string,
}

// A sound in the project
SoundAsset :: struct {
	path: string,
}

// A font in the project
FontAsset :: struct {
	path: string,
}

// A data resource in the project (data.odin): a `.data.json` file holding a registered data type
DataAsset :: struct {
	path: string,
}

// A component in the project (a saved node tree, `.component.xml`): `Scene_Instantiate` adds one
ComponentAsset :: struct {
	path: string,
}

// A texture asset's texture, loaded the first time (nil, logged, if it can't be)
Asset_Texture :: proc(game: ^Game, asset: TextureAsset) -> ^sdl.Texture {
	if asset.path == "" do return nil
	return game.resourceManager->loadTexture(projectPath(game, asset.path))
}

// A sound asset's audio, loaded (decoded) the first time
Asset_Sound :: proc(game: ^Game, asset: SoundAsset) -> ^mix.Audio {
	if asset.path == "" do return nil
	return game.resourceManager->loadAudio(projectPath(game, asset.path))
}

// A font asset at a size, loaded the first time
Asset_Font :: proc(game: ^Game, asset: FontAsset, size: f32) -> ^ttf.Font {
	if asset.path == "" do return nil
	return game.resourceManager->loadFont(projectPath(game, asset.path), size)
}

// Plays a sound asset once (see `Game_PlaySoundFile`)
Game_PlaySoundAsset :: proc(game: ^Game, asset: SoundAsset) -> bool {
	if asset.path == "" {
		log.warn("Game_PlaySound: an empty SoundAsset")
		return false
	}
	return Game_PlaySoundFile(game, asset.path)
}

// Plays a sound once: from a SoundAsset or a path relative to the project folder
Game_PlaySound :: proc{Game_PlaySoundAsset, Game_PlaySoundFile}

// A path relative to the project folder as the player opens it
@(private)
projectPath :: proc(game: ^Game, path: string) -> string {
	return game.projectDir == "" ? path : JoinPath(game.projectDir, path)
}
