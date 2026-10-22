package crossfire

import "core:fmt"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"

/*
Music that changes with the game: crossfades between songs, and adaptive layers.

- **Crossfades** (`MusicPlayer_CrossfadeTo`): the song playing fades out while the next fades in,
  both at once, on the player's bus. The old song keeps playing until its fade ends, then is
  freed.
- **Layers** (`MusicPlayer_AddLayer`, a MusicPlayer's `<layer>` children in scene files): extra
  music files played in step with the main one (stems of one song: drums, strings, a danger
  theme), each at its own volume. They start on the same sample as the main music
  (SDL3_mixer's tags) and loop with it. `MusicPlayer_SetLayerVolume` fades a layer in or out
  (combat starts: the drums come in over two seconds). Each layer goes through the player's
  volume, pan and bus, times its own volume.

Layers' files should be as long as the main one, so they loop together. A crossfade fades the
layers out with the old song (the new song starts without them: add its own).

Example:
	// Given: music: ^e.MusicPlayer
	e.MusicPlayer_AddLayer(music, "drums", "music/battle_drums.ogg", volume = 0)
	e.AudioPlayer_Play(music)
	// Later, in a fight:
	e.MusicPlayer_SetLayerVolume(music, "drums", 1, seconds = 2)
*/

// A layer of a MusicPlayer: a music file played in step with the main one
MusicLayer :: struct {
	// Its name (to set its volume), in the node's memory
	name: string,
	// Its music file, relative to the project folder, in the node's memory
	sound: string,
	// The loaded music (the player's own; nil without a device or when it couldn't be read)
	audio: ^mix.Audio,
	// Its SDL3_mixer track (made when added; nil without a device)
	track: ^mix.Track,
	// Its volume now (0 to 1, up to 2 boosts), the volume it's fading to, and how fast (per second)
	volume, target, speed: f32,
}

// A layer in a scene file: `<layer name="drums" sound="music/drums.ogg" volume="0"/>` (format 13)
MusicLayerData :: struct {
	name: string,
	sound: string,
	volume: f32,
}

// A song fading out after a crossfade (freed when it's silent)
@(private)
FadingTrack :: struct {
	track: ^mix.Track,
	audio: ^mix.Audio,
}

/*
Adds a layer to a music player. When the player is playing, the layer starts at once, in step.

Inputs:
- player: The music player
- name: The layer's name (a name already used replaces that layer)
- path: Its music file, relative to the project folder
- volume: Its volume (0 silent: fade it in later with MusicPlayer_SetLayerVolume)

Returns:
- The layer (nil when the player isn't a MusicPlayer); valid until a layer is added or removed
*/
MusicPlayer_AddLayer :: proc(player: ^MusicPlayer, name, path: string, volume: f32 = 1) -> ^MusicLayer {
	if player == nil || player.kind != .Music do return nil
	MusicPlayer_RemoveLayer(player, name)
	allocator := Node_GetAllocator(player)
	if player.layers == nil do player.layers = make([dynamic]MusicLayer, allocator)
	layer := MusicLayer{name = strings.clone(name, allocator), sound = strings.clone(path, allocator), volume = max(volume, 0), target = max(volume, 0)}
	game := player.scene != nil ? player.scene.game : nil
	if game != nil && game.mixer != nil {
		if path != "" {
			full := game.projectDir == "" ? path : JoinPath(game.projectDir, path)
			layer.audio = Audio_Load(game.mixer, full, false)
			if layer.audio == nil do log.warnf("%s: couldn't open the layer %s: %s", player.name, path, sdl.GetError())
		}
		layer.track = mix.CreateTrack(game.mixer)
		if layer.track != nil {
			_ = mix.SetTrackAudio(layer.track, layer.audio)
			_ = mix.SetTrackGroup(layer.track, busGroup(game, player.bus))
			_ = mix.TagTrack(layer.track, musicTag(player))
		}
	}
	append(&player.layers, layer)
	added := &player.layers[len(player.layers) - 1]
	// Playing: it joins at the main music's place
	if player.playing && player.track != nil && added.track != nil {
		applyOutput(player)
		props := sdl.CreateProperties()
		defer sdl.DestroyProperties(props)
		_ = sdl.SetNumberProperty(props, mix.PROP_PLAY_LOOPS_NUMBER, player.settings.loop ? -1 : 0)
		_ = sdl.SetNumberProperty(props, mix.PROP_PLAY_START_FRAME_NUMBER, mix.GetTrackPlaybackPosition(player.track))
		_ = mix.PlayTrack(added.track, props)
		if player.paused do _ = mix.PauseTrack(added.track)
	}
	return added
}

// Removes a layer (stopping it). Returns whether there was one by that name
MusicPlayer_RemoveLayer :: proc(player: ^MusicPlayer, name: string) -> bool {
	if player == nil do return false
	for &layer, i in player.layers {
		if layer.name != name do continue
		layerFree(&layer)
		ordered_remove(&player.layers, i)
		return true
	}
	return false
}

/*
Fades a layer to a volume.

Inputs:
- player: The music player
- name: The layer
- volume: 0 silent, 1 full (up to 2 boosts)
- seconds: How long the fade takes (0: at once)

Returns:
- Whether there was a layer by that name
*/
MusicPlayer_SetLayerVolume :: proc(player: ^MusicPlayer, name: string, volume: f32, seconds: f32 = 0) -> bool {
	layer := MusicPlayer_GetLayer(player, name)
	if layer == nil do return false
	layer.target = max(volume, 0)
	if seconds <= 0 {
		layer.volume = layer.target
		layer.speed = 0
	} else {
		layer.speed = abs(layer.target - layer.volume) / seconds
	}
	applyOutput(player)
	return true
}

// A layer by name (nil: none)
MusicPlayer_GetLayer :: proc(player: ^MusicPlayer, name: string) -> ^MusicLayer {
	if player == nil do return nil
	for &layer in player.layers do if layer.name == name do return &layer
	return nil
}

/*
Fades from the song playing to another: the old one fades out while the new one fades in, over
`seconds`. Not playing: it plays the new one, fading in. The old song's layers fade out with it.

Inputs:
- player: The music player
- path: The next song, relative to the project folder
- seconds: How long the crossfade takes

Example:
	// Given: music: ^e.MusicPlayer
	e.MusicPlayer_CrossfadeTo(music, "music/boss.ogg", 3)
*/
MusicPlayer_CrossfadeTo :: proc(player: ^MusicPlayer, path: string, seconds: f32) {
	if player == nil || player.kind != .Music do return
	allocator := Node_GetAllocator(player)
	if !player.playing || player.track == nil {
		AudioPlayer_SetSound(player, path)
		fadeIn := player.settings.fadeIn
		player.settings.fadeIn = max(seconds, 0)
		AudioPlayer_Play(player)
		player.settings.fadeIn = fadeIn
		return
	}
	game := player.scene.game
	fadeFrames := mix.TrackMSToFrames(player.track, i64(max(seconds, 0) * 1000))
	// The old song (and its layers) fade out on their own tracks
	if player.fading == nil do player.fading = make([dynamic]FadingTrack, allocator)
	_ = mix.StopTrack(player.track, fadeFrames)
	append(&player.fading, FadingTrack{player.track, player.ownsAudio ? player.audio : nil})
	for &layer in player.layers {
		if layer.track != nil {
			_ = mix.StopTrack(layer.track, fadeFrames)
			append(&player.fading, FadingTrack{layer.track, layer.audio})
		}
		layer.track, layer.audio = nil, nil
		layerFree(&layer)
	}
	clear(&player.layers)
	player.track, player.audio, player.ownsAudio = nil, nil, false
	// The new one fades in on a new track
	player.sound = strings.clone(path, allocator)
	full := game.projectDir == "" ? path : JoinPath(game.projectDir, path)
	player.audio = Audio_Load(game.mixer, full, false)
	player.ownsAudio = player.audio != nil
	if player.audio == nil {
		log.warnf("%s: couldn't open music %s: %s", player.name, path, sdl.GetError())
		player.playing = false
		return
	}
	fadeIn := player.settings.fadeIn
	player.settings.fadeIn = max(seconds, 0)
	AudioPlayer_Play(player)
	player.settings.fadeIn = fadeIn
}

// --- the player's procedures call these (audio_nodes.odin) ------------------------------------

// The tag a player's main track and layers share (they start together)
@(private)
musicTag :: proc(player: ^AudioPlayer) -> cstring {
	return strings.clone_to_cstring(fmt.tprintf("music-%v", player.id), context.temp_allocator)
}

// Plays the main track and its layers in step (AudioPlayer_Play, a music player with layers)
@(private)
musicPlayTogether :: proc(player: ^AudioPlayer, props: sdl.PropertiesID) -> bool {
	game := player.scene.game
	tag := musicTag(player)
	_ = mix.TagTrack(player.track, tag)
	for layer in player.layers do if layer.track != nil {
		_ = mix.SetTrackGroup(layer.track, busGroup(game, player.bus))
		_ = mix.TagTrack(layer.track, tag)
	}
	return mix.PlayTag(game.mixer, tag, props)
}

// Every layer track: stop (with fade frames), pause, resume, or move to a frame
@(private)
musicLayersStop :: proc(player: ^AudioPlayer, fadeFrames: i64) {
	for layer in player.layers do if layer.track != nil do _ = mix.StopTrack(layer.track, fadeFrames)
}
@(private)
musicLayersPause :: proc(player: ^AudioPlayer, pause: bool) {
	for layer in player.layers do if layer.track != nil {
		if pause do _ = mix.PauseTrack(layer.track)
		else do _ = mix.ResumeTrack(layer.track)
	}
}
@(private)
musicLayersSeek :: proc(player: ^AudioPlayer, frame: i64) {
	for layer in player.layers do if layer.track != nil do _ = mix.SetTrackPlaybackPosition(layer.track, frame)
}

// The layers' gains (the player's output times each layer's volume), each update
@(private)
musicLayersOutput :: proc(player: ^AudioPlayer, gain: f32, gains: mix.StereoGains, pitch: f32) {
	for layer in player.layers do if layer.track != nil {
		_ = mix.SetTrackGain(layer.track, gain * layer.volume)
		g := gains
		_ = mix.SetTrackStereo(layer.track, &g)
		_ = mix.SetTrackFrequencyRatio(layer.track, pitch)
	}
}

// Layers' fades, and freeing songs that finished fading out (the player's update)
@(private)
musicUpdate :: proc(player: ^AudioPlayer, deltaTime: f64) {
	for &layer in player.layers {
		if layer.volume == layer.target || layer.speed <= 0 {
			layer.volume = layer.target
			continue
		}
		step := layer.speed * f32(deltaTime)
		if layer.volume < layer.target do layer.volume = min(layer.volume + step, layer.target)
		else do layer.volume = max(layer.volume - step, layer.target)
	}
	for i := 0; i < len(player.fading); {
		f := player.fading[i]
		if f.track != nil && mix.TrackPlaying(f.track) {
			i += 1
			continue
		}
		fadingFree(f)
		unordered_remove(&player.fading, i)
	}
}

// Frees the layers and fading songs (the player's destroy)
@(private)
musicFree :: proc(player: ^AudioPlayer) {
	for &layer in player.layers do layerFree(&layer)
	clear(&player.layers)
	for f in player.fading do fadingFree(f)
	clear(&player.fading)
}

@(private="file")
layerFree :: proc(layer: ^MusicLayer) {
	if layer.track != nil do mix.DestroyTrack(layer.track)
	if layer.audio != nil do mix.DestroyAudio(layer.audio)
	layer.track, layer.audio = nil, nil
}

@(private="file")
fadingFree :: proc(f: FadingTrack) {
	if f.track != nil do mix.DestroyTrack(f.track)
	if f.audio != nil do mix.DestroyAudio(f.audio)
}
