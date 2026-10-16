package engine

import "core:fmt"
import "core:log"
import mix "vendor:sdl3/mixer"
import sdl "vendor:sdl3"

/*
Audio: SDL3_mixer, playing on the default device. The same on the desktop and in the browser,
where the web export links an SDL3_mixer built with Emscripten (WAV, OGG, MP3, FLAC, AIFF, VOC).
Browsers only start sound after the player clicks or presses a key on the page; SDL resumes it
then by itself.

Play sounds with `Game_PlaySound`, or with SDL3_mixer directly (`game.mixer`, and
`game.resourceManager->loadAudio` for cached sounds).
*/

/*
Starts SDL3_mixer and opens the default playback device. A machine without one (or a browser
that refuses) isn't an error: the game runs silently.

Returns:
- The mixer (nil when silent), and false only if SDL3_mixer itself couldn't start
*/
Audio_Init :: proc() -> (^mix.Mixer, bool) {
	if !mix.Init() {
		log.error("Error initializing SDL_mixer: ", sdl.GetError())
		return nil, false
	}
	mixer := mix.CreateMixerDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
	if mixer == nil {
		log.warn("No audio device; the game runs without sound: ", sdl.GetError())
	}
	return mixer, true
}

// Closes the device and SDL3_mixer
Audio_Quit :: proc(mixer: ^mix.Mixer) {
	if mixer != nil do mix.DestroyMixer(mixer)
	mix.Quit()
}

// Loads a sound file (predecode: decode it all now, for short effects)
Audio_Load :: proc(mixer: ^mix.Mixer, path: string, predecode: bool) -> ^mix.Audio {
	return mix.LoadAudio(mixer, fmt.ctprint(path), predecode)
}

Audio_Destroy :: proc(audio: ^mix.Audio) {
	mix.DestroyAudio(audio)
}

/*
Plays a sound once, loading it the first time (it stays cached in the resource manager).

Inputs:
- game: The game
- path: The sound file, relative to the project folder (`game.projectDir`) like other assets

Returns:
- false (logged) if it couldn't be loaded or played

Example:
	e.Game_PlaySound(self.game, "assets/laser.wav")  // or a SoundAsset (assets.odin)
*/
Game_PlaySoundFile :: proc(game: ^Game, path: string) -> bool {
	if game.mixer == nil do return false
	audio := game.resourceManager->loadAudio(game.projectDir == "" ? path : JoinPath(game.projectDir, path))
	if audio == nil do return false
	if !mix.PlayAudio(game.mixer, audio) {
		log.warnf("Couldn't play %s: %s", path, sdl.GetError())
		return false
	}
	return true
}
