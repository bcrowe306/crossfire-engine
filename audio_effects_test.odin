#+build !js
package crossfire

import "core:log"
import "core:math"
import "core:os"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"

// Bus effects (audio_effects.odin) on raw samples, and through a real mixer rendered offline
// (SDL3_mixer's Generate: no device); music layers and crossfades (music_layers.odin)

// SDL's audio and SDL3_mixer's init are process-wide: the audio tests take turns
@(private)
audioTestLock: sync.Mutex

@(private="file")
RATE :: 48000

// Stereo interleaved sine samples
@(private="file")
sine :: proc(freq: f32, frames: int, amplitude: f32 = 0.5) -> []f32 {
	out := make([]f32, frames * 2, context.temp_allocator)
	for i in 0 ..< frames {
		v := amplitude * math.sin(2 * math.PI * freq * f32(i) / RATE)
		out[i * 2], out[i * 2 + 1] = v, v
	}
	return out
}

// The loudest sample of the last half (after a filter settles)
@(private="file")
peakTail :: proc(pcm: []f32) -> f32 {
	p: f32
	for v in pcm[len(pcm) / 2:] do p = max(p, abs(v))
	return p
}

@(private="file")
run :: proc(effects: []AudioEffect, pcm: []f32) {
	chain: AudioEffectChain
	defer AudioEffects_Destroy(&chain)
	AudioEffects_Set(&chain, effects)
	AudioEffects_Process(&chain, raw_data(pcm), len(pcm), 2, RATE)
}

@(test)
filters_pass_and_cut_by_frequency :: proc(t: ^testing.T) {
	low := AudioEffect_Make(.LowPass)
	low.cutoff = 1000
	high := AudioEffect_Make(.HighPass)
	high.cutoff = 1000
	// A low-pass keeps 100 Hz, cuts 10 kHz to a fraction
	a, b := sine(100, RATE / 2), sine(10000, RATE / 2)
	run({low}, a)
	run({low}, b)
	testing.expectf(t, peakTail(a) > 0.45, "100 Hz passes: %v", peakTail(a))
	testing.expectf(t, peakTail(b) < 0.03, "10 kHz cut: %v", peakTail(b))
	// A high-pass the other way round
	c, d := sine(100, RATE / 2), sine(10000, RATE / 2)
	run({high}, c)
	run({high}, d)
	testing.expectf(t, peakTail(c) < 0.03, "100 Hz cut: %v", peakTail(c))
	testing.expectf(t, peakTail(d) > 0.45, "10 kHz passes: %v", peakTail(d))
	// Bypassed: untouched
	low.bypass = true
	e := sine(10000, 1000)
	before := e[500]
	run({low}, e)
	testing.expect_value(t, e[500], before)
}

@(test)
echoes_repeat_and_reverb_rings :: proc(t: ^testing.T) {
	// An impulse: the echo repeats it every 0.1 s, each repeat half the last
	echo := AudioEffect_Make(.Echo)
	echo.delay, echo.feedback, echo.mix = 0.1, 0.5, 1
	pcm := make([]f32, RATE * 2, context.temp_allocator)
	pcm[0], pcm[1] = 1, 1
	run({echo}, pcm)
	at :: proc(pcm: []f32, seconds: f32) -> f32 { return pcm[int(seconds * RATE) * 2] }
	testing.expect_value(t, at(pcm, 0), f32(1))
	testing.expectf(t, abs(at(pcm, 0.1) - 1) < 1e-4, "the first repeat: %v", at(pcm, 0.1))
	testing.expectf(t, abs(at(pcm, 0.2) - 0.5) < 1e-4, "the second, half: %v", at(pcm, 0.2))
	testing.expectf(t, abs(at(pcm, 0.15)) < 1e-6, "silence between")

	// A reverb: a tail after the impulse that fades; mix 0 leaves the sound dry
	reverb := AudioEffect_Make(.Reverb)
	reverb.mix = 0.5
	wet := make([]f32, RATE * 2, context.temp_allocator)
	wet[0], wet[1] = 1, 1
	run({reverb}, wet)
	energy :: proc(pcm: []f32, from, to: f32) -> f32 {
		sum: f32
		for v in pcm[int(from * RATE) * 2:int(to * RATE) * 2] do sum += v * v
		return sum
	}
	early, late := energy(wet, 0.05, 0.25), energy(wet, 0.75, 0.95)
	testing.expectf(t, early > 0.001 && late < early, "a tail that fades: %v then %v", early, late)
	reverb.mix = 0
	dry := sine(440, 2000)
	before := dry[1001]
	run({reverb}, dry)
	testing.expect_value(t, dry[1001], before)

	// A chain being changed: the block passes through untouched (the audio thread never waits)
	chain: AudioEffectChain
	defer AudioEffects_Destroy(&chain)
	AudioEffects_Set(&chain, {echo})
	busy := sine(440, 100)
	copyOf := make([]f32, len(busy), context.temp_allocator)
	copy(copyOf, busy)
	sync.atomic_mutex_lock(&chain.lock)
	AudioEffects_Process(&chain, raw_data(busy), len(busy), 2, RATE)
	sync.atomic_mutex_unlock(&chain.lock)
	testing.expect(t, busy[150] == copyOf[150], "untouched while locked")
	testing.expect_value(t, len(AudioEffects_Get(&chain)), 1)
}

@(test)
bus_effects_and_music_layers_through_a_mixer :: proc(t: ^testing.T) {
	sync.guard(&audioTestLock)
	if !sdl.InitSubSystem({.AUDIO}) || !mix.Init() {
		log.warnf("No SDL audio here (%s): skipped", sdl.GetError())
		return
	}
	defer { mix.Quit(); sdl.QuitSubSystem({.AUDIO}) }
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = RATE}
	mixer := mix.CreateMixer(&spec)
	if mixer == nil {
		log.warnf("No offline mixer here (%s): skipped", sdl.GetError())
		return
	}
	defer mix.DestroyMixer(mixer)
	game := testGame("testdata")
	defer { Audio_DestroyBuses(game); Game_Destroy(game); free(game) }
	game.mixer = mixer
	// A bus with a low-pass, one without
	low := AudioEffect_Make(.LowPass)
	low.cutoff = 500
	effects := make([dynamic]AudioEffect, context.temp_allocator)
	append(&effects, low)
	Audio_SetBuses(game, {{name = "Muffled", volume = 1, effects = effects}, {name = "Clear", volume = 1}})
	testing.expect_value(t, len(Audio_GetBusEffects("Muffled", game)), 1)

	tone := sine(8000, RATE)
	audio := mix.LoadRawAudio(mixer, raw_data(tone), uint(len(tone) * size_of(f32)), spec)
	defer mix.DestroyAudio(audio)
	render :: proc(mixer: ^mix.Mixer, game: ^Game, audio: ^mix.Audio, bus: string) -> f32 {
		track := mix.CreateTrack(mixer)
		defer mix.DestroyTrack(track)
		_ = mix.SetTrackAudio(track, audio)
		_ = mix.SetTrackGroup(track, Audio_GetBus(bus, game).group)
		_ = mix.PlayTrack(track, 0)
		out := make([]f32, RATE / 4 * 2, context.temp_allocator)
		_ = mix.Generate(mixer, raw_data(out), i32(len(out) * size_of(f32)))
		return peakTail(out)
	}
	clear, muffled := render(mixer, game, audio, "Clear"), render(mixer, game, audio, "Muffled")
	testing.expectf(t, clear > 0.4 && muffled < clear * 0.1, "the low-pass muffles 8 kHz: %v against %v", muffled, clear)
	// Bypassed from code: as loud as the clear bus
	low.bypass = true
	Audio_SetBusEffect("Muffled", 0, low, game)
	bypassed := render(mixer, game, audio, "Muffled")
	testing.expectf(t, abs(bypassed - clear) < 0.05, "bypassed: %v", bypassed)

	// Music layers: started together on the same sample, each at its own volume
	scene := game->createScene("S")
	music := CreateAudioPlayer(scene, .Music)
	music.audio = audio // the main track: the tone (not the player's to free)
	layerTone := sine(8000, RATE)
	layer := MusicPlayer_AddLayer(music, "drums", "", volume = 0)
	testing.expect(t, layer != nil && layer.track != nil, "a layer with a track")
	layerAudio := mix.LoadRawAudio(mixer, raw_data(layerTone), uint(len(layerTone) * size_of(f32)), spec)
	defer mix.DestroyAudio(layerAudio)
	_ = mix.SetTrackAudio(layer.track, layerAudio)
	AudioPlayer_Play(music)
	out := make([]f32, 4800 * 2, context.temp_allocator)
	_ = mix.Generate(mixer, raw_data(out), i32(len(out) * size_of(f32)))
	single := peakTail(out)
	// The drums come in: two tones in phase (started on the same sample) add up to twice as loud
	MusicPlayer_SetLayerVolume(music, "drums", 1)
	_ = mix.Generate(mixer, raw_data(out), i32(len(out) * size_of(f32)))
	both := peakTail(out)
	testing.expectf(t, abs(both - 2 * single) < 0.05, "in step: %v is twice %v", both, single)
	// A fade over a second, through the player's update
	MusicPlayer_SetLayerVolume(music, "drums", 0, seconds = 1)
	musicUpdate(music, 0.5)
	testing.expectf(t, abs(MusicPlayer_GetLayer(music, "drums").volume - 0.5) < 0.01, "half way")
	musicUpdate(music, 0.6)
	testing.expect_value(t, MusicPlayer_GetLayer(music, "drums").volume, f32(0))
	testing.expect(t, MusicPlayer_RemoveLayer(music, "drums"), "removed")
	music.audio = nil
}

@(test)
music_layers_in_scene_files :: proc(t: ^testing.T) {
	data, err := ParseScene(`<scene formatVersion="13" name="S">
		<node kind="MusicPlayer" name="Theme" sound="music/theme.ogg">
			<layer name="drums" sound="music/drums.ogg" volume="0"/>
			<layer name="strings" sound="music/strings.ogg"/>
		</node>
	</scene>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	layers := data.nodes[0].musicLayers
	testing.expect(t, len(layers) == 2 && layers[0].name == "drums" && layers[0].volume == 0 && layers[1].volume == 1 && layers[1].sound == "music/strings.ogg", "both layers")

	project, perr := ParseProject(`<project formatVersion="13" name="P"><bus name="Music"><effect kind="Reverb" roomSize="0.8" mix="0.2"/><effect kind="LowPass" cutoff="900" bypass="true"/></bus></project>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, perr, ProjectError.None)
	fx := project.buses[0].effects
	testing.expect(t, len(fx) == 2 && fx[0].kind == .Reverb && fx[0].roomSize == 0.8 && fx[0].mix == 0.2 && fx[1].cutoff == 900 && fx[1].bypass, "the bus's effects")
}

// A float WAV file of stereo samples (SDL's binding has no SaveWAV)
@(private="file")
writeWav :: proc(path: string, pcm: []f32) -> bool {
	data := len(pcm) * 4
	header := make([dynamic]u8, context.temp_allocator)
	u32le :: proc(b: ^[dynamic]u8, v: u32) { append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)) }
	u16le :: proc(b: ^[dynamic]u8, v: u16) { append(b, u8(v), u8(v >> 8)) }
	append(&header, "RIFF")
	u32le(&header, u32(36 + data))
	append(&header, "WAVEfmt ")
	u32le(&header, 16)
	u16le(&header, 3) // IEEE float
	u16le(&header, 2)
	u32le(&header, RATE)
	u32le(&header, RATE * 8)
	u16le(&header, 8)
	u16le(&header, 32)
	append(&header, "data")
	u32le(&header, u32(data))
	append(&header, ..(([^]u8)(raw_data(pcm)))[:data])
	return os.write_entire_file(path, header[:]) == nil
}

@(test)
music_crossfades_between_songs :: proc(t: ^testing.T) {
	sync.guard(&audioTestLock)
	if !sdl.InitSubSystem({.AUDIO}) || !mix.Init() {
		log.warnf("No SDL audio here (%s): skipped", sdl.GetError())
		return
	}
	defer { mix.Quit(); sdl.QuitSubSystem({.AUDIO}) }
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = RATE}
	mixer := mix.CreateMixer(&spec)
	if mixer == nil do return
	defer mix.DestroyMixer(mixer)
	dir := "testdata_crossfade"
	os.make_directory(dir)
	defer os.remove_all(dir)
	testing.expect(t, writeWav("testdata_crossfade/a.wav", sine(440, RATE, 0.4)), "a")
	testing.expect(t, writeWav("testdata_crossfade/b.wav", sine(440, RATE, 0.4)), "b")
	game := testGame(dir)
	defer { Audio_DestroyBuses(game); Game_Destroy(game); free(game) }
	game.mixer = mixer
	Audio_SetBuses(game, nil)
	scene := game->createScene("S")
	music := CreateAudioPlayer(scene, .Music)
	music.settings.loop = true
	AudioPlayer_SetSound(music, "a.wav")
	AudioPlayer_Play(music)
	block := make([]f32, RATE / 10 * 2, context.temp_allocator)
	_ = mix.Generate(mixer, raw_data(block), i32(len(block) * 4))
	testing.expectf(t, peakTail(block) > 0.35, "a plays: %v", peakTail(block))

	// Crossfade to b over half a second: a fades out on its own track while b fades in
	MusicPlayer_CrossfadeTo(music, "b.wav", 0.5)
	testing.expect_value(t, music.sound, "b.wav")
	testing.expect_value(t, len(music.fading), 1)
	testing.expect(t, music.playing && music.track != nil, "b playing")
	_ = mix.Generate(mixer, raw_data(block), i32(len(block) * 4))
	testing.expectf(t, peakTail(block) > 0.2, "both sound during the fade: %v", peakTail(block))
	// After the fade a has stopped and is freed; b carries on at full volume
	for _ in 0 ..< 8 do _ = mix.Generate(mixer, raw_data(block), i32(len(block) * 4))
	musicUpdate(music, 0.1)
	testing.expect_value(t, len(music.fading), 0)
	testing.expectf(t, peakTail(block) > 0.35, "b alone: %v", peakTail(block))
	AudioPlayer_Stop(music, fade = false)
}
