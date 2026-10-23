package crossfire

import "core:c"
import "core:fmt"
import "core:log"
import "core:strings"
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
How a game's sound output is opened: the format the mixer asks the device for (SDL converts it to
whatever the device really is), and which device. Projects set the format (project.xml's
`audioFrequency`, `audioChannels`); the device is the machine's choice (the player's
`--audio-device`, the editor's Settings for Play).

Asking for the device's own format (0 for both) was the old way, and failed on outputs whose
channel layout SDL doesn't take ("Unsupported audio channels": multichannel interfaces, some
Bluetooth and HDMI outputs on macOS).
*/
AudioOutputSettings :: struct {
	// Samples per second (44100, 48000...); 0 for the device's own
	frequency: int,
	// 1 mono, 2 stereo, up to 8; 0 for the device's own
	channels: int,
	// The playback device, by its name (`Audio_PlaybackDevices`); "" for the system's default
	device: string,
}

// Stereo at 48 kHz: what every device can be given (a project's output without settings)
DEFAULT_AUDIO_OUTPUT :: AudioOutputSettings{frequency = 48000, channels = 2}

/*
Starts SDL3_mixer and opens a playback device (`Audio_OpenMixer`). A machine without one (or a
browser that refuses) isn't an error: the game runs silently.

Inputs:
- output: The format and device to ask for

Returns:
- The mixer (nil when silent), and false only if SDL3_mixer itself couldn't start
*/
Audio_Init :: proc(output := DEFAULT_AUDIO_OUTPUT) -> (^mix.Mixer, bool) {
	if !mix.Init() {
		log.error("Error initializing SDL_mixer: ", sdl.GetError())
		return nil, false
	}
	return Audio_OpenMixer(output), true
}

/*
Opens a playback device for SDL3_mixer, trying until one opens: the asked device (else the
default) with the asked format, then stereo at 48 and 44.1 kHz, mono, 16-bit stereo, the
device's own format; then the default device; then every other device in stereo. Logs the device
and format it got ("Audio: MacBook Speakers, 48000 Hz, 2 channels"), and what failed before it.
SDL3_mixer must be started (`mix.Init`; `Audio_Init` does it).

Inputs:
- output: The format and device to ask for

Returns:
- The mixer, or nil (logged) when no device opens: the game runs silently

Example:
	// Given: mixer: ^mix.Mixer (an editor's own previews, apart from any game)
	mixer = e.Audio_OpenMixer({frequency = 44100, channels = 2})
*/
Audio_OpenMixer :: proc(output := DEFAULT_AUDIO_OUTPUT) -> ^mix.Mixer {
	// The formats to try, the asked one first (nil: the device's own)
	Attempt :: struct { spec: sdl.AudioSpec, own: bool }
	attempts := make([dynamic]Attempt, context.temp_allocator)
	if output.frequency > 0 || output.channels > 0 {
		append(&attempts, Attempt{{format = .F32, channels = c.int(output.channels > 0 ? clamp(output.channels, 1, 8) : 2), freq = c.int(output.frequency > 0 ? output.frequency : 48000)}, false})
	} else {
		append(&attempts, Attempt{own = true})
	}
	append(&attempts, Attempt{{.F32, 2, 48000}, false}, Attempt{{.F32, 2, 44100}, false}, Attempt{{.F32, 1, 48000}, false}, Attempt{{.S16, 2, 44100}, false}, Attempt{own = true})

	// The devices: the asked one (if it's there), the default, then the others
	devices := make([dynamic]sdl.AudioDeviceID, context.temp_allocator)
	count: c.int
	ids := sdl.GetAudioPlaybackDevices(&count)
	defer if ids != nil do sdl.free(ids)
	if output.device != "" {
		found := false
		for i in 0 ..< int(count) do if string(sdl.GetAudioDeviceName(ids[i])) == output.device {
			append(&devices, ids[i])
			found = true
		}
		if !found do log.warnf("Audio: no device named '%s'; using the default (Audio_PlaybackDevices lists them)", output.device)
	}
	append(&devices, sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK)
	for i in 0 ..< int(count) do append(&devices, ids[i])

	failures := make([dynamic]string, context.temp_allocator)
	for device, d in devices {
		name := device == sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK ? "the default device" : string(sdl.GetAudioDeviceName(device))
		// Every format on the first two (the asked device, the default); others in stereo only
		tries := d < 2 ? attempts[:] : attempts[1:2]
		for &attempt in tries {
			mixer := mix.CreateMixerDevice(device, attempt.own ? nil : &attempt.spec)
			if mixer == nil {
				append(&failures, attempt.own ? fmt.tprintf("%s, its own format: %s", name, sdl.GetError()) :
					fmt.tprintf("%s, %d Hz, %d channels: %s", name, attempt.spec.freq, attempt.spec.channels, sdl.GetError()))
				continue
			}
			got: sdl.AudioSpec
			_ = mix.GetMixerFormat(mixer, &got)
			if len(failures) > 0 do log.warnf("Audio: these didn't open: %s", strings.join(failures[:], "; ", context.temp_allocator))
			log.infof("Audio: %s, %d Hz, %d channels", name, got.freq, got.channels)
			return mixer
		}
	}
	log.warnf("No audio device; the game runs without sound (%s)", strings.join(failures[:], "; ", context.temp_allocator))
	return nil
}

/*
The names of the playback devices SDL sees now (for picking one: `AudioOutputSettings.device`, the
player's `--audio-device`). SDL's audio must be started (SDL_Init's .AUDIO).

Inputs:
- allocator: For the list and the names

Returns:
- The names; empty when there's no device (or no audio)
*/
Audio_PlaybackDevices :: proc(allocator := context.allocator) -> []string {
	count: c.int
	ids := sdl.GetAudioPlaybackDevices(&count)
	if ids == nil do return {}
	defer sdl.free(ids)
	names := make([]string, int(count), allocator)
	for i in 0 ..< int(count) do names[i] = strings.clone(string(sdl.GetAudioDeviceName(ids[i])), allocator)
	return names
}

/*
Closes the playback device and SDL3_mixer. `Application_Cleanup` calls it.

Inputs:
- mixer: The mixer from `Audio_Init` (nil when silent)
*/
Audio_Quit :: proc(mixer: ^mix.Mixer) {
	if mixer != nil do mix.DestroyMixer(mixer)
	mix.Quit()
}

/*
Loads a sound file, from the data pack if it's there, else from disk. Most code loads through
`ResourceManager` (`loadAudio`), which caches the sound.

Inputs:
- mixer: The mixer to load it for
- path: The file's path
- predecode: Decode it all now (short effects); false streams it while it plays (music)

Returns:
- The sound (free it with `Audio_Destroy`), or nil if it can't be read (SDL's error says why)
*/
Audio_Load :: proc(mixer: ^mix.Mixer, path: string, predecode: bool) -> ^mix.Audio {
	// From the data pack's memory, which lives as long as the program (music streams from it)
	if data, packed := Pack_Bytes(path); packed {
		return mix.LoadAudio_IO(mixer, sdl.IOFromConstMem(raw_data(data), uint(len(data))), predecode, true)
	}
	return mix.LoadAudio(mixer, fmt.ctprint(path), predecode)
}

/*
Frees a sound loaded with `Audio_Load`. Sounds in the resource manager are freed by it instead.

Inputs:
- audio: The sound
*/
Audio_Destroy :: proc(audio: ^mix.Audio) {
	mix.DestroyAudio(audio)
}

/*
Plays a sound file once, loading it the first time (it stays cached in the resource manager).
`Game_PlaySound` with a path.

The sound goes through a mix bus like a sound node's (`bus`: "" is Master), so the bus's
volume, pan, mute and effects apply to it, and at the volume, pitch (playback speed: 1.1 a
little higher and faster) and pan given. A bus's volume changing while it plays changes it too.
Each sound plays on a track of the game's (`Game.sounds`), reused once its sound has ended; past
`MAX_SOUND_TRACKS` at once the oldest is cut off.

Inputs:
- game: The game
- path: The sound file, relative to the project folder (`game.projectDir`) like other assets
- bus: The mix bus it plays on ("" is Master; an unknown one is Master, with a warning)
- volume: 0 (silent) to 1 (as recorded), more boosts
- pitch: The playback speed: 1 as recorded, 2 an octave up and twice as fast
- pan: -1 left, 0 center, 1 right

Returns:
- false if there's no audio device, or (logged) it couldn't be loaded or played

Example:
	e.Game_PlaySound(game, "assets/laser.wav") // or a SoundAsset (assets.odin)
	// On the project's "SFX" bus, a little quieter and higher than recorded
	e.Game_PlaySound(game, "assets/coin.ogg", bus = "SFX", volume = 0.8, pitch = 1.1)
*/
Game_PlaySoundFile :: proc(game: ^Game, path: string, bus := "", volume: f32 = 1, pitch: f32 = 1, pan: f32 = 0) -> bool {
	if game.mixer == nil do return false
	audio := game.resourceManager->loadAudio(game.projectDir == "" ? path : JoinPath(game.projectDir, path))
	if audio == nil do return false
	if len(game.buses) == 0 do Audio_SetBuses(game, nil)
	busIndex := 0
	busName := bus == "" ? MASTER_BUS : bus
	for b, i in game.buses do if b.name == busName do busIndex = i
	if busIndex == 0 && busName != MASTER_BUS do log.warnf("Game_PlaySound: no bus named '%s': playing %s on Master", bus, path)

	// A track whose sound ended, else a new one, else the oldest playing: the list is kept in
	// the order the sounds started, so the one taken goes to its end
	slot := -1
	for s, i in game.sounds do if !mix.TrackPlaying(s.track) {
		slot = i
		break
	}
	if slot < 0 && len(game.sounds) >= MAX_SOUND_TRACKS do slot = 0
	sound: SoundTrack
	if slot >= 0 {
		sound = game.sounds[slot]
		ordered_remove(&game.sounds, slot)
		if mix.TrackPlaying(sound.track) do _ = mix.StopTrack(sound.track, 0)
	} else {
		sound.track = mix.CreateTrack(game.mixer)
		if sound.track == nil {
			log.warnf("Couldn't play %s: %s", path, sdl.GetError())
			return false
		}
	}
	sound.bus, sound.volume, sound.pan = busIndex, max(volume, 0), clamp(pan, -1, 1)
	if game.sounds == nil do game.sounds = make([dynamic]SoundTrack)
	append(&game.sounds, sound)
	_ = mix.SetTrackGroup(sound.track, game.buses[busIndex].group)
	_ = mix.SetTrackAudio(sound.track, audio)
	_ = mix.SetTrackFrequencyRatio(sound.track, clamp(pitch, 0.01, 100))
	soundOutput(game, sound)
	if !mix.PlayTrack(sound.track, 0) {
		log.warnf("Couldn't play %s: %s", path, sdl.GetError())
		return false
	}
	return true
}

// A sound `Game_PlaySound` plays (`Game.sounds`): its track, reused for later sounds once it ends
SoundTrack :: struct {
	// Its SDL3_mixer track
	track: ^mix.Track,
	// The bus it plays on: an index in `Game.buses` (0 is Master)
	bus: int,
	// Its volume, times its bus's
	volume: f32,
	// Its pan, with its bus's
	pan: f32,
}

// The most sounds `Game_PlaySound` plays at once; another cuts the oldest off
MAX_SOUND_TRACKS :: 32

// A sound's gains from its volume, pan and bus (Master's go on the final mix, as for sound nodes)
@(private)
soundOutput :: proc(game: ^Game, sound: SoundTrack) {
	if sound.bus >= len(game.buses) do return
	gain, left, right := Audio_Output(game, game.buses[sound.bus].name, sound.volume, sound.pan, master = false)
	_ = mix.SetTrackGain(sound.track, gain)
	gains := mix.StereoGains{left, right}
	_ = mix.SetTrackStereo(sound.track, &gains)
}

// Frees `Game_PlaySound`'s tracks (Audio_DestroyBuses, before the buses' groups go)
@(private)
soundsDestroy :: proc(game: ^Game) {
	for s in game.sounds do mix.DestroyTrack(s.track)
	delete(game.sounds)
	game.sounds = nil
}
