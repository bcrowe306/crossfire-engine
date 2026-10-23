package crossfire

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
	package mygame

	import e "engine:."

	// What the editor writes in scripts/assets.odin
	SOUND_LASER :: e.SoundAsset{"assets/laser.wav"}
	TEXTURE_SHIP :: e.TextureAsset{"assets/ship.png"}
	DATA_FAST_SHIP :: e.DataAsset{"data/fast_ship.data.json"}

	ShipStats :: struct {
		speed: f32 `export:"default=300"`,
	}

	Fire :: proc(game: ^e.Game) {
		e.Game_PlaySound(game, SOUND_LASER)
		texture := e.Asset_Texture(game, TEXTURE_SHIP)
		stats := e.Data(ShipStats, DATA_FAST_SHIP)
		_, _ = texture, stats
	}
*/

// An image in the project (Sprite textures)
TextureAsset :: struct {
	// The image's path, relative to the project folder ("" for none)
	path: string,
}

// A sound in the project
SoundAsset :: struct {
	// The sound's path, relative to the project folder ("" for none)
	path: string,
}

// A font in the project
FontAsset :: struct {
	// The font's path, relative to the project folder ("" for none)
	path: string,
}

// A data resource in the project (data.odin): a `.data.json` file holding a registered data type
DataAsset :: struct {
	// The data file's path, relative to the project folder ("" for none)
	path: string,
}

// Music in the project: streamed by a MusicPlayer as it plays (not loaded whole like a sound)
MusicAsset :: struct {
	// The music file's path, relative to the project folder ("" for none)
	path: string,
}

// A component in the project (a saved node tree, `.component.xml`): `Scene_AddComponent` adds one
ComponentAsset :: struct {
	// The component file's path, relative to the project folder ("" for none)
	path: string,
}

// An animation asset (an `.anim.xml` file, or an Aseprite file: its tags): animations AnimatedSprite
// nodes share (`AnimatedSprite_UseAnimations`, animation_sets.odin)
AnimationAsset :: struct {
	// The file's path, relative to the project folder ("" for none)
	path: string,
}

// An LDtk project in the project (`.ldtk`: ldtk.odin): its levels go in scenes as LDtkLevel nodes
LDtkAsset :: struct {
	// The .ldtk file's path, relative to the project folder ("" for none)
	path: string,
}

/*
An LDtk asset's project, read the first time and kept for the game's life (nil, logged, if it
can't be read): `Game_LoadLDtk`.

Inputs:
- game: The game that keeps it
- asset: The LDtk asset

Returns:
- The project (the game's: don't free it), or nil for an empty asset or a file that can't be read

Example:
	// Given: LDTK_WORLD: e.LDtkAsset
	world := e.Asset_LDtk(game, LDTK_WORLD)
	for &level in world.worlds[0].levels do log.infof("%s: %v", level.identifier, level.size)
*/
Asset_LDtk :: proc(game: ^Game, asset: LDtkAsset) -> ^LDtkProject {
	if asset.path == "" do return nil
	return Game_LoadLDtk(game, asset.path)
}

/*
A texture asset's texture, loaded the first time and cached by the resource manager.

Inputs:
- game: The game
- asset: The texture asset

Returns:
- The texture (the resource manager's: don't destroy it), or nil for an empty asset or (logged)
  a file that can't be loaded

Example:
	// Given: TEXTURE_SHIP: e.TextureAsset
	ship := e.Asset_Texture(game, TEXTURE_SHIP)
	e.DrawTexture(renderer, ship, {-32, -32, 64, 64})
*/
Asset_Texture :: proc(game: ^Game, asset: TextureAsset) -> ^sdl.Texture {
	if asset.path == "" do return nil
	return game.resourceManager->loadTexture(projectPath(game, asset.path))
}

/*
A sound asset's audio, loaded (decoded whole) the first time and cached by the resource manager.

Inputs:
- game: The game
- asset: The sound asset

Returns:
- The audio (the resource manager's: don't destroy it), or nil for an empty asset or (logged) a
  file that can't be loaded
*/
Asset_Sound :: proc(game: ^Game, asset: SoundAsset) -> ^mix.Audio {
	if asset.path == "" do return nil
	return game.resourceManager->loadAudio(projectPath(game, asset.path))
}

/*
A font asset at a point size, loaded the first time and cached by the resource manager.

Inputs:
- game: The game
- asset: The font asset
- size: The point size

Returns:
- The font (the resource manager's: don't close it), or nil for an empty asset or (logged) a
  file that can't be loaded
*/
Asset_Font :: proc(game: ^Game, asset: FontAsset, size: f32) -> ^ttf.Font {
	if asset.path == "" do return nil
	return game.resourceManager->loadFont(projectPath(game, asset.path), size)
}

// `Game_PlaySound` for a `SoundAsset` (see `Game_PlaySoundFile`); false (logged) for an empty one
Game_PlaySoundAsset :: proc(game: ^Game, asset: SoundAsset, bus := "", volume: f32 = 1, pitch: f32 = 1, pan: f32 = 0) -> bool {
	if asset.path == "" {
		log.warn("Game_PlaySound: an empty SoundAsset")
		return false
	}
	return Game_PlaySoundFile(game, asset.path, bus, volume, pitch, pan)
}

/*
Plays a sound once, loading it the first time (cached by the resource manager), on a mix bus
at a volume, pitch and pan (`Game_PlaySoundFile` has the details).

Inputs:
- game: The game
- asset or path: A `SoundAsset`, or a path relative to the project folder
- bus: The mix bus ("" is Master)
- volume: 0 to 1 (more boosts)
- pitch: The playback speed (1 as recorded)
- pan: -1 left, 0 center, 1 right

Returns:
- false if there's no audio device, or (logged) the sound couldn't be loaded or played

Example:
	// Given: SOUND_LASER: e.SoundAsset
	e.Game_PlaySound(game, SOUND_LASER)
	e.Game_PlaySound(game, "assets/explosion.wav", bus = "SFX", pitch = 0.9)
*/
Game_PlaySound :: proc{Game_PlaySoundAsset, Game_PlaySoundFile}

// A path relative to the project folder as the player opens it
@(private)
projectPath :: proc(game: ^Game, path: string) -> string {
	return game.projectDir == "" ? path : JoinPath(game.projectDir, path)
}
