package engine

import "core:fmt"
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
bus's times Master's (`Audio_Output`), applied every frame, so changing a bus changes everything
on it at once. Projects list their buses in project.xml (`<bus name="Music" volume="0.8"/>`, the
editor's Mixer tab); code can add more (`Audio_AddBus`). Each bus has an SDL3_mixer group its
players' tracks join, where effects will go.

Players in a scene that the game switches away from stop; ones that start by themselves start
again when it's back. Without an audio device everything still works, silently.

Example:
	jump := cast(^e.AudioPlayer)e.Scene_FindNode(self.scene, "JumpSound")
	e.AudioPlayer_Play(jump)
	e.Audio_SetBusVolume("Music", 0.5)
	music := cast(^e.MusicPlayer)e.Scene_FindNode(self.scene, "Theme")
	e.MusicPlayer_FadeOut(music, 2)
*/

// The bus every player and bus ends in
MASTER_BUS :: "Master"

// A mix bus: what goes through it is scaled by its volume, panned by its pan, silenced by mute
AudioBus :: struct {
	name: string,
	// 0 (silent) to 1 (unchanged); up to 2 boosts
	volume: f32,
	// -1 left, 0 center, 1 right
	pan: f32,
	mute: bool,
	// Its SDL3_mixer group (nil without a device), where effects will go
	group: ^mix.Group,
}

// A bus in project.xml: `<bus name="Music" volume="0.8" pan="0" mute="false"/>` (format 10)
AudioBusData :: struct {
	name: string,
	volume: f32,
	pan: f32,
	mute: bool,
}

// A sound node's settings (scene files store those that differ from DEFAULT_AUDIO_SETTINGS)
AudioSettings :: struct {
	// 0 to 1 (up to 2 boosts)
	volume: f32,
	// Playback speed: 1 is normal, 2 an octave up and twice as fast, 0.5 an octave down
	pitch: f32,
	// -1 left, 0 center, 1 right
	pan: f32,
	loop: bool,
	// Starts when its scene first updates (and again each time the game comes back to it)
	autostart: bool,
	// AudioPlayer2D: silent this far (px) from the listener; how the volume falls (1 linear, 2 faster)
	maxDistance: f32,
	attenuation: f32,
	// MusicPlayer: seconds to fade in when it starts, and out when it stops
	fadeIn: f32,
	fadeOut: f32,
}

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
	using node: Node,
	kind: AudioPlayerKind,
	settings: AudioSettings,
	// The bus it goes to ("" or "Master": straight to Master); in the node's memory
	bus: string,
	// The sound or music file, relative to the project folder (`AudioPlayer_SetSound`)
	sound: string,
	audio: ^mix.Audio,
	// Music is the node's own (streamed); sounds are the resource manager's (shared)
	ownsAudio: bool,
	track: ^mix.Track,
	// Playing (or paused) since the last Play
	playing: bool,
	paused: bool,
	// Autostart happened this time its scene is current
	started: bool,
}

// A positional sound player; the same struct as AudioPlayer
AudioPlayer2D :: AudioPlayer
// A music player; the same struct as AudioPlayer
MusicPlayer :: AudioPlayer

/*
Creates a sound node of a kind. Set its sound with `AudioPlayer_SetSound`.

Inputs:
- scene: The scene
- kind: Sound, Positional (AudioPlayer2D) or Music (MusicPlayer)
- settings: Volume, pitch, pan... (DEFAULT_AUDIO_SETTINGS unless given)
*/
CreateAudioPlayer :: proc(scene: ^Scene, kind := AudioPlayerKind.Sound, settings := DEFAULT_AUDIO_SETTINGS) -> ^AudioPlayer {
	player := CreateNode(scene, AudioPlayer)
	player.kind = kind
	player.settings = settings
	player.update = audioPlayerUpdate
	player.destroy = audioPlayerDestroyed
	if game := scene.game; game != nil {
		if game.audioPlayers == nil do game.audioPlayers = make([dynamic]^AudioPlayer)
		append(&game.audioPlayers, player)
	}
	return player
}

/*
Sets what a player plays: a sound or music file relative to the project folder (stopping what
played). Sounds are loaded once and shared; music streams from its file.
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
		player.audio = mix.LoadAudio(game.mixer, fmt.ctprint(full), false)
		player.ownsAudio = player.audio != nil
		if player.audio == nil do log.warnf("%s: couldn't open music %s: %s", player.name, path, sdl.GetError())
	} else {
		player.audio = game.resourceManager->loadAudio(full)
	}
}

// Sets the bus a player goes to ("" for Master)
AudioPlayer_SetBus :: proc(player: ^AudioPlayer, bus: string) {
	player.bus = strings.clone(bus, Node_GetAllocator(player))
	if player.track != nil do _ = mix.SetTrackGroup(player.track, busGroup(player.scene.game, bus))
}

/*
Plays from the start (again, if it was playing). Music fades in over `settings.fadeIn`.
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
	if !mix.PlayTrack(player.track, props) do log.warnf("%s: couldn't play %s: %s", player.name, player.sound, sdl.GetError())
}

/*
Stops. Music fades out over `settings.fadeOut` unless `fade` is false.
*/
AudioPlayer_Stop :: proc(player: ^AudioPlayer, fade := true) {
	player.playing, player.paused = false, false
	if player.track == nil do return
	fadeFrames: i64
	if fade && player.kind == .Music && player.settings.fadeOut > 0 {
		fadeFrames = mix.TrackMSToFrames(player.track, i64(player.settings.fadeOut * 1000))
	}
	_ = mix.StopTrack(player.track, fadeFrames)
}

// Pauses where it is (Resume carries on)
AudioPlayer_Pause :: proc(player: ^AudioPlayer) {
	if !player.playing do return
	player.paused = true
	if player.track != nil do _ = mix.PauseTrack(player.track)
}

AudioPlayer_Resume :: proc(player: ^AudioPlayer) {
	if !player.paused do return
	player.paused = false
	if player.track != nil do _ = mix.ResumeTrack(player.track)
}

// Whether it's playing (not paused, not finished)
AudioPlayer_IsPlaying :: proc(player: ^AudioPlayer) -> bool {
	return player.playing && !player.paused
}

// Fades music out over `seconds` and stops it
MusicPlayer_FadeOut :: proc(player: ^MusicPlayer, seconds: f32) {
	player.playing, player.paused = false, false
	if player.track != nil do _ = mix.StopTrack(player.track, mix.TrackMSToFrames(player.track, i64(seconds * 1000)))
}

// Where the music is, in seconds
MusicPlayer_GetPosition :: proc(player: ^MusicPlayer) -> f32 {
	if player.track == nil do return 0
	return f32(mix.TrackFramesToMS(player.track, mix.GetTrackPlaybackPosition(player.track))) / 1000
}

// How long the music is, in seconds (0 if unknown, as for some streams)
MusicPlayer_GetDuration :: proc(player: ^MusicPlayer) -> f32 {
	if player.audio == nil do return 0
	frames := mix.GetAudioDuration(player.audio)
	if frames < 0 do return 0
	return f32(mix.AudioFramesToMS(player.audio, frames)) / 1000
}

// Jumps to a time in the music, in seconds
MusicPlayer_Seek :: proc(player: ^MusicPlayer, seconds: f32) {
	if player.track == nil do return
	_ = mix.SetTrackPlaybackPosition(player.track, mix.TrackMSToFrames(player.track, i64(max(seconds, 0) * 1000)))
}

// BUSES

/*
Sets the game's buses (replacing any): Game_LoadProject does with the project's. Master is
always there (the first), whether listed or not.
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
	if game.mixer != nil do for &b in game.buses do b.group = mix.CreateGroup(game.mixer)
}

// Adds a bus from code (going to Master); one by that name already there is kept
Audio_AddBus :: proc(name: string, volume: f32 = 1, game: ^Game = nil) -> ^AudioBus {
	game := game != nil ? game : currentGame
	if game == nil do return nil
	if b := Audio_GetBus(name, game); b != nil && (b.name == name) do return b
	if len(game.buses) == 0 do Audio_SetBuses(game, nil)
	bus := AudioBus{name = strings.clone(name, Game_GetAllocator(game)), volume = volume}
	if game.mixer != nil do bus.group = mix.CreateGroup(game.mixer)
	append(&game.buses, bus)
	return &game.buses[len(game.buses) - 1]
}

// A bus by name ("" is Master); nil if there's none
Audio_GetBus :: proc(name: string, game: ^Game = nil) -> ^AudioBus {
	game := game != nil ? game : currentGame
	if game == nil do return nil
	if len(game.buses) == 0 do Audio_SetBuses(game, nil)
	name := name == "" ? MASTER_BUS : name
	for &b in game.buses do if b.name == name do return &b
	return nil
}

Audio_SetBusVolume :: proc(name: string, volume: f32, game: ^Game = nil) {
	if b := Audio_GetBus(name, game); b != nil do b.volume = max(volume, 0)
}

Audio_SetBusPan :: proc(name: string, pan: f32, game: ^Game = nil) {
	if b := Audio_GetBus(name, game); b != nil do b.pan = math.clamp(pan, -1, 1)
}

Audio_SetBusMute :: proc(name: string, mute: bool, game: ^Game = nil) {
	if b := Audio_GetBus(name, game); b != nil do b.mute = mute
}

/*
What a player on a bus sounds like: its volume times its bus's and Master's (0 if either is
muted), and its stereo gains, its pan's times theirs. A pan is a balance: centered changes
nothing, fully right silences the left side. An unknown bus is Master.

Inputs:
- volume, pan: The player's own (positional players: with distance and position applied)

Returns:
- The track gain, and the left and right gains
*/
Audio_Output :: proc(game: ^Game, bus: string, volume, pan: f32) -> (gain, left, right: f32) {
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
	master := Audio_GetBus(MASTER_BUS, game)
	if own != nil && own != master do stage(own, &gain, &left, &right)
	stage(master, &gain, &left, &right)
	return
}

/*
A positional sound's volume factor and pan: from its world position and the listener's (the
scene's camera, or the middle of the game area). Silent at `maxDistance`; between, the volume
falls as (1 - distance / maxDistance) ^ attenuation. Pan follows the horizontal offset, full at
half the game's width.
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
Audio_SceneExited :: proc(game: ^Game, scene: ^Scene) {
	for player in game.audioPlayers {
		if player.scene != scene do continue
		AudioPlayer_Stop(player, fade = false)
		player.started = false
	}
}

// Frees the buses' groups and forgets the players (Game_Destroy; the players go with their scenes)
Audio_DestroyBuses :: proc(game: ^Game) {
	for b in game.buses do if b.group != nil do mix.DestroyGroup(b.group)
	game.buses = nil
	delete(game.audioPlayers)
	game.audioPlayers = nil
}

// INTERNAL

// A balance pan: center 1, 1; right 0, 1; left 1, 0
@(private="file")
balance :: proc(pan: f32) -> (left, right: f32) {
	p := math.clamp(pan, -1, 1)
	return min(1, 1 - p), min(1, 1 + p)
}

@(private="file")
busGroup :: proc(game: ^Game, name: string) -> ^mix.Group {
	if b := Audio_GetBus(name, game); b != nil do return b.group
	return nil
}

// Sets the track's gain, pitch and stereo from the settings, the bus, Master and (positional) the listener
@(private="file")
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
	gain, left, right := Audio_Output(game, player.bus, volume, pan)
	_ = mix.SetTrackGain(player.track, gain)
	gains := mix.StereoGains{left, right}
	_ = mix.SetTrackStereo(player.track, &gains)
	_ = mix.SetTrackFrequencyRatio(player.track, math.clamp(player.settings.pitch, 0.01, 100))
}

@(private="file")
audioPlayerUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	player := cast(^AudioPlayer)node
	if player.settings.autostart && !player.started {
		player.started = true
		AudioPlayer_Play(player)
	}
	// A sound that ended on its own isn't playing any more
	if player.playing && !player.paused && player.track != nil && !mix.TrackPlaying(player.track) do player.playing = false
	applyOutput(player)
}

@(private="file")
audioPlayerDestroyed :: proc(node: ^Node) {
	player := cast(^AudioPlayer)node
	if player.track != nil do mix.DestroyTrack(player.track)
	player.track = nil
	releaseAudio(player)
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
