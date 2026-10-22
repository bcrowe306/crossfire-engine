package crossfire

import "core:log"
import "core:math"
import "core:strings"
import mix "vendor:sdl3/mixer"
import sdl "vendor:sdl3"

/*
Sound nodes and mix buses, on SDL3_mixer.

- `AudioPlayer` plays a sound: volume, pitch (playback speed), pan, looping, starting by itself.
- `AudioPlayer2D` is one in the world: panned by where it is relative to the listener (the
  scene's camera, or the middle of the game area), and quieter with distance (silent past
  `maxDistance`; `attenuation` shapes the curve).
- `MusicPlayer` streams music (a Music asset: decoded as it plays, not loaded whole), with
  fades, seeking and the same volume, pitch and pan.

Every player goes to a **bus** (`player.bus`; "" is Master), and every bus to **Master**.
A bus has a volume, a pan and a mute; what a player sounds like is its own settings times its
bus's times Master's (`Audio_Output`), so changing a bus changes everything on it at once. The
player's and its bus's gains go on its track (every frame); Master's go on the final mix
(audio_meter.odin), so each bus's level meter reads it after its fader, Master's the output.
Projects list their buses in project.xml (`<bus name="Music" volume="0.8"/>`, the editor's Mixer
tab); code can add more (`Audio_AddBus`). Each bus has an SDL3_mixer group its
players' tracks join, where effects will go.

Players in a scene that the game switches away from stop; ones that start by themselves start
again when it's back. Without an audio device everything still works, silently.

Example:
	jump := cast(^e.AudioPlayer)e.Scene_FindNode(scene, "JumpSound")
	e.AudioPlayer_Play(jump)
	e.Audio_SetBusVolume("Music", 0.5)
	music := cast(^e.MusicPlayer)e.Scene_FindNode(scene, "Theme")
	e.MusicPlayer_FadeOut(music, 2)
*/

// The bus every player and bus ends in
MASTER_BUS :: "Master"

// A mix bus: what goes through it is scaled by its volume, panned by its pan, silenced by mute
AudioBus :: struct {
	// Its name (MASTER_BUS for Master), in the game's memory
	name: string,
	// 0 (silent) to 1 (unchanged); up to 2 boosts
	volume: f32,
	// -1 left, 0 center, 1 right
	pan: f32,
	// Silences it (and everything on it), keeping its volume
	mute: bool,
	// Its SDL3_mixer group (nil without a device)
	group: ^mix.Group,
	// Its level (`Audio_GetBusLevel`); Master's is the final mix, where its gain and pan apply
	meter: ^AudioMeter,
	// Its effects (audio_effects.odin), run on what it mixed before its meter
	effects: ^AudioEffectChain,
}

// A bus in project.xml: `<bus name="Music" volume="0.8" pan="0" mute="false"/>` (format 10)
AudioBusData :: struct {
	// The bus's name ("Master" sets Master's own values)
	name: string,
	// 0 to 1, up to 2 boosts
	volume: f32,
	// -1 left, 0 center, 1 right
	pan: f32,
	// Starts muted
	mute: bool,
	// Its effects, in order (`<effect>` children: audio_effects.odin)
	effects: [dynamic]AudioEffect,
}

// A sound node's settings (scene files store those that differ from DEFAULT_AUDIO_SETTINGS)
AudioSettings :: struct {
	// 0 to 1 (up to 2 boosts)
	volume: f32,
	// Playback speed: 1 is normal, 2 an octave up and twice as fast, 0.5 an octave down
	pitch: f32,
	// -1 left, 0 center, 1 right
	pan: f32,
	// Plays again from the start when it ends, until stopped
	loop: bool,
	// Starts when its scene first updates (and again each time the game comes back to it)
	autostart: bool,
	// AudioPlayer2D: silent this far (px) from the listener (default 1000)
	maxDistance: f32,
	// AudioPlayer2D: how the volume falls with distance (1 linear, 2 faster; `Audio_Positional`)
	attenuation: f32,
	// MusicPlayer: seconds to fade in when it starts (0: no fade)
	fadeIn: f32,
	// MusicPlayer: seconds to fade out when `AudioPlayer_Stop` stops it (0: no fade)
	fadeOut: f32,
}

// A new sound node's settings: full volume, normal pitch, centered, 1000 px reach, linear falloff
DEFAULT_AUDIO_SETTINGS :: AudioSettings{
	volume = 1,
	pitch = 1,
	maxDistance = 1000,
	attenuation = 1,
}

// Which kind of sound node
AudioPlayerKind :: enum {
	// A sound, not placed
	Sound,
	// A sound in the world: panned and fading with distance from the listener
	Positional,
	// Music, streamed
	Music,
}

/*
A node that plays a sound (AudioPlayer, AudioPlayer2D) or music (MusicPlayer: the same struct,
`kind` says which). Change `settings` at any time: they apply the next frame.
*/
AudioPlayer :: struct {
	// The node part: transform (a 2D player's position), hierarchy, hooks
	using node: Node,
	// Sound, Positional or Music (set by `CreateAudioPlayer`)
	kind: AudioPlayerKind,
	// Volume, pitch, pan, looping... (read every frame)
	settings: AudioSettings,
	// The bus it goes to ("" or "Master": straight to Master); in the node's memory
	bus: string,
	// The sound or music file, relative to the project folder (`AudioPlayer_SetSound`)
	sound: string,
	// The loaded sound or music (nil: none, or no audio device)
	audio: ^mix.Audio,
	// Music is the node's own (streamed); sounds are the resource manager's (shared)
	ownsAudio: bool,
	// Its SDL3_mixer track (made by the first Play; nil without a device)
	track: ^mix.Track,
	// Playing (or paused) since the last Play, until it stops or ends
	playing: bool,
	// Paused by `AudioPlayer_Pause`
	paused: bool,
	// Autostart happened this time its scene is current
	started: bool,
	// MusicPlayer: layers played in step with it, and songs fading out after a crossfade
	// (music_layers.odin)
	layers: [dynamic]MusicLayer,
	fading: [dynamic]FadingTrack,
	// What it played ended on its own (not looping, not stopped); noticed in its update
	onFinished: EventSubject `event:"What it played ended on its own (not when stopped; a looping sound never ends)"`,
}

// A positional sound player; the same struct as AudioPlayer
AudioPlayer2D :: AudioPlayer
// A music player; the same struct as AudioPlayer
MusicPlayer :: AudioPlayer

/*
Creates a sound node of a kind, on Master. Set its sound with `AudioPlayer_SetSound` (after it's
in a scene of a game) and its bus with `AudioPlayer_SetBus`.

Inputs:
- scene: The scene
- kind: Sound, Positional (AudioPlayer2D) or Music (MusicPlayer)
- settings: Volume, pitch, pan... (DEFAULT_AUDIO_SETTINGS unless given)

Returns:
- The player

Example:
	music := e.CreateAudioPlayer(scene, .Music)
	music.settings.loop = true
	music.settings.fadeIn = 1.5
	e.AudioPlayer_SetSound(music, "music/theme.ogg")
	e.AudioPlayer_SetBus(music, "Music")
	e.AudioPlayer_Play(music)
*/
CreateAudioPlayer :: proc(scene: ^Scene, kind := AudioPlayerKind.Sound, settings := DEFAULT_AUDIO_SETTINGS) -> ^AudioPlayer {
	player := CreateNode(scene, AudioPlayer)
	player.kind = kind
	player.settings = settings
	player.update = audioPlayerUpdate
	player.destroy = audioPlayerDestroyed
	EventSubject_Init(&player.onFinished, Node_GetAllocator(player))
	if game := scene.game; game != nil {
		if game.audioPlayers == nil do game.audioPlayers = make([dynamic]^AudioPlayer)
		append(&game.audioPlayers, player)
	}
	return player
}

/*
Sets what a player plays, stopping what played (no fade). Sounds are loaded once by the resource
manager and shared; music streams from its file and is the node's own. Nothing is loaded when the
scene has no game or the game has no audio device (a warning when music can't be opened).

Inputs:
- player: The player
- path: A sound or music file, relative to the project folder ("" for none)
*/
AudioPlayer_SetSound :: proc(player: ^AudioPlayer, path: string) {
	AudioPlayer_Stop(player, fade = false)
	releaseAudio(player)
	allocator := Node_GetAllocator(player)
	player.sound = strings.clone(path, allocator)
	player.audio = nil
	game := player.scene != nil ? player.scene.game : nil
	if path == "" || game == nil || game.mixer == nil do return
	full := game.projectDir == "" ? path : JoinPath(game.projectDir, path)
	if player.kind == .Music {
		player.audio = Audio_Load(game.mixer, full, false)
		player.ownsAudio = player.audio != nil
		if player.audio == nil do log.warnf("%s: couldn't open music %s: %s", player.name, path, sdl.GetError())
	} else {
		player.audio = game.resourceManager->loadAudio(full)
	}
}

/*
Sets the bus a player goes to; it takes effect at once, also while playing.

Inputs:
- player: The player
- bus: The bus's name ("" or "Master" for Master; an unknown bus is Master too)
*/
AudioPlayer_SetBus :: proc(player: ^AudioPlayer, bus: string) {
	player.bus = strings.clone(bus, Node_GetAllocator(player))
	if player.track != nil do _ = mix.SetTrackGroup(player.track, busGroup(player.scene.game, bus))
}

/*
Plays from the start (again, if it was playing), looping if `settings.loop`. Music fades in over
`settings.fadeIn`. Without a sound or a device, it only marks the player as playing.

Inputs:
- player: The player
*/
AudioPlayer_Play :: proc(player: ^AudioPlayer) {
	player.playing, player.paused = true, false
	if player.audio == nil do return
	game := player.scene.game
	if player.track == nil {
		player.track = mix.CreateTrack(game.mixer)
		if player.track == nil do return
		_ = mix.SetTrackGroup(player.track, busGroup(game, player.bus))
	}
	_ = mix.SetTrackAudio(player.track, player.audio)
	applyOutput(player)
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	_ = sdl.SetNumberProperty(props, mix.PROP_PLAY_LOOPS_NUMBER, player.settings.loop ? -1 : 0)
	if player.kind == .Music && player.settings.fadeIn > 0 {
		_ = sdl.SetNumberProperty(props, mix.PROP_PLAY_FADE_IN_MILLISECONDS_NUMBER, i64(player.settings.fadeIn * 1000))
	}
	// Music with layers: they all start on the same sample (music_layers.odin)
	played := len(player.layers) > 0 ? musicPlayTogether(player, props) : mix.PlayTrack(player.track, props)
	if !played do log.warnf("%s: couldn't play %s: %s", player.name, player.sound, sdl.GetError())
}

/*
Stops playing. Music fades out over `settings.fadeOut` unless `fade` is false.

Inputs:
- player: The player
- fade: Fade music out (sounds stop at once either way)
*/
AudioPlayer_Stop :: proc(player: ^AudioPlayer, fade := true) {
	player.playing, player.paused = false, false
	if player.track == nil do return
	fadeFrames: i64
	if fade && player.kind == .Music && player.settings.fadeOut > 0 {
		fadeFrames = mix.TrackMSToFrames(player.track, i64(player.settings.fadeOut * 1000))
	}
	_ = mix.StopTrack(player.track, fadeFrames)
	musicLayersStop(player, fadeFrames)
}

/*
Pauses where it is (`AudioPlayer_Resume` carries on). Does nothing if it isn't playing.

Inputs:
- player: The player
*/
AudioPlayer_Pause :: proc(player: ^AudioPlayer) {
	if !player.playing do return
	player.paused = true
	if player.track != nil do _ = mix.PauseTrack(player.track)
	musicLayersPause(player, true)
}

/*
Carries on from where `AudioPlayer_Pause` paused it. Does nothing if it isn't paused.

Inputs:
- player: The player
*/
AudioPlayer_Resume :: proc(player: ^AudioPlayer) {
	if !player.paused do return
	player.paused = false
	if player.track != nil do _ = mix.ResumeTrack(player.track)
	musicLayersPause(player, false)
}

/*
Whether a player is playing.

Inputs:
- player: The player

Returns:
- true if it was played and isn't paused, stopped or finished (a finished sound is noticed on
  its next update)
*/
AudioPlayer_IsPlaying :: proc(player: ^AudioPlayer) -> bool {
	return player.playing && !player.paused
}

/*
Fades music out and stops it, whatever its `settings.fadeOut`.

Inputs:
- player: The music player
- seconds: How long the fade takes (0: stops at once)
*/
MusicPlayer_FadeOut :: proc(player: ^MusicPlayer, seconds: f32) {
	player.playing, player.paused = false, false
	if player.track == nil do return
	frames := mix.TrackMSToFrames(player.track, i64(seconds * 1000))
	_ = mix.StopTrack(player.track, frames)
	musicLayersStop(player, frames)
}

/*
Where the music is.

Inputs:
- player: The music player

Returns:
- Seconds from its start (0 before it has played)
*/
MusicPlayer_GetPosition :: proc(player: ^MusicPlayer) -> f32 {
	if player.track == nil do return 0
	return f32(mix.TrackFramesToMS(player.track, mix.GetTrackPlaybackPosition(player.track))) / 1000
}

/*
How long the music is.

Inputs:
- player: The music player

Returns:
- Seconds (0 if unknown, as for some streams, or with no music loaded)
*/
MusicPlayer_GetDuration :: proc(player: ^MusicPlayer) -> f32 {
	if player.audio == nil do return 0
	frames := mix.GetAudioDuration(player.audio)
	if frames < 0 do return 0
	return f32(mix.AudioFramesToMS(player.audio, frames)) / 1000
}

/*
Jumps to a time in the music. Does nothing before it has played.

Inputs:
- player: The music player
- seconds: From the start (negative is 0)
*/
MusicPlayer_Seek :: proc(player: ^MusicPlayer, seconds: f32) {
	if player.track == nil do return
	frame := mix.TrackMSToFrames(player.track, i64(max(seconds, 0) * 1000))
	_ = mix.SetTrackPlaybackPosition(player.track, frame)
	musicLayersSeek(player, frame)
}

// BUSES

/*
Sets the game's buses, replacing any: `Game_LoadProject` does it with the project's. Master is
always there (the first), whether listed or not. The buses live in the game's memory.

Inputs:
- game: The game
- buses: The buses (a "Master" entry sets Master's volume, pan and mute)
*/
Audio_SetBuses :: proc(game: ^Game, buses: []AudioBusData) {
	allocator := Game_GetAllocator(game)
	game.buses = make([dynamic]AudioBus, allocator)
	append(&game.buses, AudioBus{name = MASTER_BUS, volume = 1})
	for b in buses {
		if b.name == MASTER_BUS {
			game.buses[0].volume, game.buses[0].pan, game.buses[0].mute = b.volume, b.pan, b.mute
			continue
		}
		append(&game.buses, AudioBus{name = strings.clone(b.name, allocator), volume = b.volume, pan = b.pan, mute = b.mute})
	}
	for &b in game.buses {
		b.meter = new(AudioMeter, allocator)
		b.effects = new(AudioEffectChain, allocator)
		b.meter.effects = b.effects
	}
	for b in buses {
		bus := b.name == MASTER_BUS ? &game.buses[0] : Audio_GetBus(b.name, game)
		if bus != nil && len(b.effects) > 0 do AudioEffects_Set(bus.effects, b.effects[:])
	}
	if game.mixer != nil {
		for &b in game.buses {
			b.group = mix.CreateGroup(game.mixer)
			AudioMeter_AttachGroup(b.meter, b.group)
		}
		AudioMeter_AttachMixer(game.buses[0].meter, game.mixer)
	}
	Audio_Update(game)
}

// Applies Master's volume, pan and mute to the final mix (Game_Update, every frame)
@(private)
Audio_Update :: proc(game: ^Game) {
	if len(game.buses) == 0 do return
	master := game.buses[0]
	gain := master.mute ? 0 : max(master.volume, 0)
	left, right := balance(master.pan)
	AudioMeter_SetGains(master.meter, gain * left, gain * right)
}

/*
Adds a bus from code, going to Master. If one by that name already exists, it's kept as it is.

Inputs:
- name: The bus's name
- volume: Its volume (0 to 1, up to 2 boosts)
- game: The game (nil: the current game)

Returns:
- The bus (nil without a game). The pointer is valid until the next bus is added

Example:
	e.Audio_AddBus("Voices", 0.9)
	e.Audio_SetBusMute("Voices", true)
*/
Audio_AddBus :: proc(name: string, volume: f32 = 1, game: ^Game = nil) -> ^AudioBus {
	game := game != nil ? game : currentGame
	if game == nil do return nil
	// "" is Master, like Audio_GetBus says
	if b := Audio_GetBus(name, game); b != nil && (b.name == name || name == "") do return b
	if len(game.buses) == 0 do Audio_SetBuses(game, nil)
	bus := AudioBus{name = strings.clone(name, Game_GetAllocator(game)), volume = volume}
	bus.meter = new(AudioMeter, Game_GetAllocator(game))
	bus.effects = new(AudioEffectChain, Game_GetAllocator(game))
	bus.meter.effects = bus.effects
	if game.mixer != nil {
		bus.group = mix.CreateGroup(game.mixer)
		AudioMeter_AttachGroup(bus.meter, bus.group)
	}
	append(&game.buses, bus)
	return &game.buses[len(game.buses) - 1]
}

/*
A bus by name. A game with no buses yet gets Master.

Inputs:
- name: The bus's name ("" is Master)
- game: The game (nil: the current game)

Returns:
- The bus, or nil if there's none by that name. The pointer is valid until a bus is added
*/
Audio_GetBus :: proc(name: string, game: ^Game = nil) -> ^AudioBus {
	game := game != nil ? game : currentGame
	if game == nil do return nil
	if len(game.buses) == 0 do Audio_SetBuses(game, nil)
	name := name == "" ? MASTER_BUS : name
	for &b in game.buses do if b.name == name do return &b
	return nil
}

/*
Sets a bus's volume (everything on it changes from the next frame). Unknown buses are ignored.

Inputs:
- name: The bus's name ("" is Master)
- volume: 0 (silent) to 1 (unchanged), up to 2 boosts; negative is 0
- game: The game (nil: the current game)

Example:
	e.Audio_SetBusVolume("Music", 0.5)
*/
Audio_SetBusVolume :: proc(name: string, volume: f32, game: ^Game = nil) {
	if b := Audio_GetBus(name, game); b != nil do b.volume = max(volume, 0)
}

/*
Sets a bus's pan (a balance). Unknown buses are ignored.

Inputs:
- name: The bus's name ("" is Master)
- pan: -1 left, 0 center, 1 right (clamped)
- game: The game (nil: the current game)
*/
Audio_SetBusPan :: proc(name: string, pan: f32, game: ^Game = nil) {
	if b := Audio_GetBus(name, game); b != nil do b.pan = math.clamp(pan, -1, 1)
}

/*
Mutes or unmutes a bus, keeping its volume. Unknown buses are ignored.

Inputs:
- name: The bus's name ("" is Master)
- mute: Silence it
- game: The game (nil: the current game)
*/
Audio_SetBusMute :: proc(name: string, mute: bool, game: ^Game = nil) {
	if b := Audio_GetBus(name, game); b != nil do b.mute = mute
}

/*
What a player on a bus sounds like: its volume times its bus's and Master's (0 if either is
muted), and its stereo gains, its pan's times theirs. A pan is a balance: centered changes
nothing, fully right silences the left side. An unknown bus is Master.

Inputs:
- game: The game (nil: the current game)
- bus: The player's bus ("" is Master)
- volume, pan: The player's own (positional players: with distance and position applied)
- master: Include Master's stage (false: the track's part; the final mix applies Master's)

Returns:
- The track gain, and the left and right gains
*/
Audio_Output :: proc(game: ^Game, bus: string, volume, pan: f32, master := true) -> (gain, left, right: f32) {
	gain = max(volume, 0)
	left, right = balance(pan)
	stage :: proc(b: ^AudioBus, gain, left, right: ^f32) {
		if b == nil do return
		gain^ *= b.mute ? 0 : max(b.volume, 0)
		l, r := balance(b.pan)
		left^ *= l
		right^ *= r
	}
	own := Audio_GetBus(bus, game)
	masterBus := Audio_GetBus(MASTER_BUS, game)
	if own != nil && own != masterBus do stage(own, &gain, &left, &right)
	if master do stage(masterBus, &gain, &left, &right)
	return
}

/*
A positional sound's volume factor and pan, from its world position and the listener's (the
scene's camera, or the middle of the game area). Silent at `maxDistance`; between, the volume
falls as (1 - distance / maxDistance) ^ attenuation. Pan follows the horizontal offset, full at
half the view's width.

Inputs:
- position: The sound's world position (pixels)
- listener: The listener's world position
- settings: The player's settings (`maxDistance`, `attenuation`)
- viewWidth: The width the listener hears across, in pixels (the game's width)

Returns:
- volume: 0 to 1, to multiply the player's volume by
- pan: -1 to 1, to add to the player's pan
*/
Audio_Positional :: proc(position, listener: [2]f32, settings: AudioSettings, viewWidth: f32) -> (volume, pan: f32) {
	d := position - listener
	distance := math.sqrt(d.x * d.x + d.y * d.y)
	reach := max(settings.maxDistance, 1)
	if distance >= reach do return 0, 0
	volume = math.pow(1 - distance / reach, max(settings.attenuation, 0.01))
	pan = math.clamp(d.x / max(viewWidth * 0.5, 1), -1, 1)
	return
}

// Stops the players of a scene the game leaves (Game_Update): they start again with it
@(private)
Audio_SceneExited :: proc(game: ^Game, scene: ^Scene) {
	for player in game.audioPlayers {
		if player.scene != scene do continue
		AudioPlayer_Stop(player, fade = false)
		player.started = false
	}
}

// Frees the buses' groups and forgets the players (Game_Destroy; the players go with their scenes)
@(private)
Audio_DestroyBuses :: proc(game: ^Game) {
	if game.mixer != nil do _ = mix.SetPostMixCallback(game.mixer, nil, nil)
	for b in game.buses do if b.group != nil do mix.DestroyGroup(b.group)
	// After their groups are gone (nothing runs them now)
	for b in game.buses do AudioEffects_Destroy(b.effects)
	game.buses = nil
	delete(game.audioPlayers)
	game.audioPlayers = nil
}

/*
Replaces a bus's effects (audio_effects.odin): they run on what it mixes from its next block.

Inputs:
- name: The bus ("" is Master)
- effects: Up to AUDIO_MAX_EFFECTS, in order
- game: The game (nil: the current game)

Example:
	// Under water: everything muffled
	e.Audio_SetBusEffects("", {e.AudioEffect_Make(.LowPass)})
*/
Audio_SetBusEffects :: proc(name: string, effects: []AudioEffect, game: ^Game = nil) {
	if b := Audio_GetBus(name, game); b != nil do AudioEffects_Set(b.effects, effects)
}

/*
Changes one of a bus's effects (a filter swept while the game plays keeps sounding smooth).

Example:
	// Given: depth: f32
	muffle := e.AudioEffect_Make(.LowPass)
	muffle.cutoff = 4000 - depth * 30
	e.Audio_SetBusEffect("Music", 0, muffle)
*/
Audio_SetBusEffect :: proc(name: string, index: int, effect: AudioEffect, game: ^Game = nil) {
	if b := Audio_GetBus(name, game); b != nil do AudioEffects_SetOne(b.effects, index, effect)
}

// A bus's effects (a temp copy; none for a bus that doesn't exist)
Audio_GetBusEffects :: proc(name: string, game: ^Game = nil) -> []AudioEffect {
	if b := Audio_GetBus(name, game); b != nil do return AudioEffects_Get(b.effects)
	return nil
}

// INTERNAL

// A balance pan: center 1, 1; right 0, 1; left 1, 0
@(private)
balance :: proc(pan: f32) -> (left, right: f32) {
	p := math.clamp(pan, -1, 1)
	return min(1, 1 - p), min(1, 1 + p)
}

@(private)
busGroup :: proc(game: ^Game, name: string) -> ^mix.Group {
	if b := Audio_GetBus(name, game); b != nil do return b.group
	return nil
}

// Sets the track's gain, pitch and stereo from the settings, the bus, Master and (positional) the listener
@(private)
applyOutput :: proc(player: ^AudioPlayer) {
	if player.track == nil do return
	game := player.scene.game
	volume, pan := player.settings.volume, player.settings.pan
	if player.kind == .Positional {
		listener := game.size * 0.5
		if camera := player.scene.camera; camera != nil do listener = Camera2D_GetTarget(camera)
		distanceVolume, distancePan := Audio_Positional(Node_GetWorldPosition(player), listener, player.settings, game.size.x)
		volume *= distanceVolume
		pan = math.clamp(pan + distancePan, -1, 1)
	}
	gain, left, right := Audio_Output(game, player.bus, volume, pan, master = false)
	_ = mix.SetTrackGain(player.track, gain)
	gains := mix.StereoGains{left, right}
	_ = mix.SetTrackStereo(player.track, &gains)
	pitch := math.clamp(player.settings.pitch, 0.01, 100)
	_ = mix.SetTrackFrequencyRatio(player.track, pitch)
	if len(player.layers) > 0 do musicLayersOutput(player, gain, gains, pitch)
}

@(private="file")
audioPlayerUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	player := cast(^AudioPlayer)node
	if player.settings.autostart && !player.started {
		player.started = true
		AudioPlayer_Play(player)
	}
	// A sound that ended on its own isn't playing any more
	if player.playing && !player.paused && player.track != nil && !mix.TrackPlaying(player.track) {
		player.playing = false
		Event_Notify(&player.onFinished, player, nil)
	}
	if player.kind == .Music do musicUpdate(player, deltaTime)
	applyOutput(player)
}

@(private="file")
audioPlayerDestroyed :: proc(node: ^Node) {
	player := cast(^AudioPlayer)node
	if player.track != nil do mix.DestroyTrack(player.track)
	player.track = nil
	releaseAudio(player)
	musicFree(player)
	if game := player.scene != nil ? player.scene.game : nil; game != nil {
		for p, i in game.audioPlayers {
			if p == player {
				unordered_remove(&game.audioPlayers, i)
				break
			}
		}
	}
}

@(private="file")
releaseAudio :: proc(player: ^AudioPlayer) {
	if player.ownsAudio && player.audio != nil do mix.DestroyAudio(player.audio)
	player.ownsAudio = false
	player.audio = nil
}
