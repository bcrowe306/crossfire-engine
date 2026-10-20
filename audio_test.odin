#+build !js
package crossfire

import "core:log"
import "core:testing"
import mix "vendor:sdl3/mixer"
import sdl "vendor:sdl3"

// Audio tests: buses, panning and distance math, sound nodes from scene files (no audio device)

@(private="file")
near :: proc(a, b: f32) -> bool { return abs(a - b) < 0.001 }

@(test)
buses_scale_and_pan_what_goes_through :: proc(t: ^testing.T) {
	game: Game
	defer if game.arenaReady do MemoryArena_Destroy(&game.arena)
	Audio_SetBuses(&game, {{name = "Music", volume = 0.5, pan = 0}, {name = MASTER_BUS, volume = 0.8}})
	testing.expect_value(t, len(game.buses), 2)
	testing.expect_value(t, game.buses[0].name, MASTER_BUS) // Always first

	gain, left, right := Audio_Output(&game, "Music", 1, 0)
	testing.expect(t, near(gain, 0.4) && near(left, 1) && near(right, 1), "volume times bus times Master")
	gain, _, _ = Audio_Output(&game, "", 0.5, 0)
	testing.expect(t, near(gain, 0.4), "no bus: straight to Master")
	gain, _, _ = Audio_Output(&game, "Nope", 1, 0)
	testing.expect(t, near(gain, 0.8), "an unknown bus: Master")

	// Pans multiply as balances: the player right, the bus left
	Audio_SetBusPan("Music", -0.5, &game)
	_, left, right = Audio_Output(&game, "Music", 1, 0.5)
	testing.expect(t, near(left, 0.5) && near(right, 0.5), "right then left")
	Audio_SetBusMute("Music", true, &game)
	gain, _, _ = Audio_Output(&game, "Music", 1, 0)
	testing.expect(t, gain == 0, "muted")
	Audio_SetBusMute(MASTER_BUS, true, &game)
	Audio_SetBusMute("Music", false, &game)
	gain, _, _ = Audio_Output(&game, "Music", 1, 0)
	testing.expect(t, gain == 0, "Master muted silences everything")

	bus := Audio_AddBus("Effects", 0.3, &game)
	testing.expect(t, bus != nil && len(game.buses) == 3, "added from code")
}

@(test)
positional_sound_fades_and_pans :: proc(t: ^testing.T) {
	settings := DEFAULT_AUDIO_SETTINGS
	settings.maxDistance = 100
	volume, pan := Audio_Positional({0, 0}, {0, 0}, settings, 200)
	testing.expect(t, near(volume, 1) && near(pan, 0), "at the listener")
	volume, pan = Audio_Positional({50, 0}, {0, 0}, settings, 200)
	testing.expect(t, near(volume, 0.5) && near(pan, 0.5), "halfway, to the right")
	volume, _ = Audio_Positional({-200, 0}, {0, 0}, settings, 200)
	testing.expect(t, volume == 0, "out of reach")
	settings.attenuation = 2
	volume, pan = Audio_Positional({-50, 0}, {0, 0}, settings, 200)
	testing.expect(t, near(volume, 0.25) && near(pan, -0.5), "faster falloff, to the left")
}

@(test)
sound_nodes_from_scene_files :: proc(t: ^testing.T) {
	project, perr := ParseProject(`<project formatVersion="10" name="P"><bus name="Music" volume="0.7" mute="true"/><bus name="Master" pan="0.2"/></project>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, perr, ProjectError.None)
	testing.expect_value(t, len(project.buses), 2)
	testing.expect_value(t, project.buses[0], AudioBusData{"Music", 0.7, 0, true})

	text := `<scene formatVersion="10" name="S">
		<node kind="AudioPlayer" name="Jump" sound="assets/jump.wav" volume="0.5" pitch="1.5" pan="-0.25" bus="Effects"/>
		<node kind="AudioPlayer2D" name="Fire" sound="assets/fire.ogg" loop="true" autostart="true" maxDistance="300" attenuation="2"/>
		<node kind="MusicPlayer" name="Theme" sound="music/theme.ogg" fadeIn="1.5" fadeOut="2" bus="Music"/>
		<node kind="AnimatedSprite" name="Anim"/>
	</scene>`
	data, err := ParseScene(text)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	jump := data.nodes[0]
	testing.expect_value(t, jump.sound, "assets/jump.wav")
	testing.expect_value(t, jump.bus, "Effects")
	testing.expect(t, jump.audio.volume == 0.5 && jump.audio.pitch == 1.5 && jump.audio.pan == -0.25 && !jump.audio.loop, "settings")
	testing.expect(t, data.nodes[1].audio.loop && data.nodes[1].audio.autostart && data.nodes[1].audio.maxDistance == 300, "2D")
	testing.expect(t, data.nodes[2].audio.fadeIn == 1.5 && data.nodes[2].audio.fadeOut == 2, "music fades")
	testing.expect(t, !data.nodes[3].audio.loop, "an AnimatedSprite's loop isn't a sound's")

	// Built without a device: they keep their state, silently
	game: Game
	defer if game.arenaReady do MemoryArena_Destroy(&game.arena)
	scene := new(Scene)
	Scene_Init(scene)
	scene.game = &game
	defer { Scene_Destroy(scene); free(scene); delete(game.audioPlayers) }
	created := Scene_Build(scene, &data, ".")
	Scene_ProcessQueues(scene)
	theme := cast(^MusicPlayer)created[2]
	testing.expect_value(t, theme.kind, AudioPlayerKind.Music)
	testing.expect_value(t, theme.bus, "Music")
	fire := cast(^AudioPlayer2D)created[1]
	testing.expect_value(t, fire.kind, AudioPlayerKind.Positional)
	testing.expect_value(t, len(game.audioPlayers), 3)

	Scene_Update(scene, nil, 1.0 / 60)
	testing.expect(t, fire.started && fire.playing, "autostart")
	jumpPlayer := cast(^AudioPlayer)created[0]
	testing.expect(t, !jumpPlayer.playing, "not without autostart")
	AudioPlayer_Play(jumpPlayer)
	AudioPlayer_Pause(jumpPlayer)
	testing.expect(t, !AudioPlayer_IsPlaying(jumpPlayer) && jumpPlayer.paused, "paused")
	AudioPlayer_Resume(jumpPlayer)
	testing.expect(t, AudioPlayer_IsPlaying(jumpPlayer), "resumed")

	// Leaving the scene stops them; autostart starts again when it's back
	Audio_SceneExited(&game, scene)
	testing.expect(t, !fire.playing && !fire.started && !jumpPlayer.playing, "stopped")
}

@(test)
audio_meters_measure_and_apply :: proc(t: ^testing.T) {
	// A group's meter measures; a mixer's applies its gains first
	meter: AudioMeter
	spec := sdl.AudioSpec{format = .F32, channels = 2, freq = 48000}
	pcm := []f32{0.5, -0.25, -0.75, 0.1}
	audioMeterMeasure(&meter, &spec, raw_data(pcm), len(pcm), false)
	left, right := AudioMeter_Read(&meter)
	testing.expect_value(t, left, 0.75)
	testing.expect_value(t, right, 0.25)
	left, right = AudioMeter_Read(&meter)
	testing.expect_value(t, left, 0)

	AudioMeter_SetGains(&meter, 0.5, 0)
	audioMeterMeasure(&meter, &spec, raw_data(pcm), len(pcm), true)
	testing.expect_value(t, pcm[0], 0.25)
	testing.expect_value(t, pcm[1], 0)
	left, right = AudioMeter_Read(&meter)
	testing.expect_value(t, left, 0.375)
	testing.expect_value(t, right, 0)

	testing.expect_value(t, AudioLevel_ToDecibels(0), AUDIO_SILENCE_DB)
	testing.expect(t, abs(AudioLevel_ToDecibels(0.5) + 6.0206) < 0.001, "half is -6 dB")
}

@(test)
audio_output_opens_with_the_asked_format_and_falls_back :: proc(t: ^testing.T) {
	// SDL's dummy audio driver: a device that takes any format, on every machine
	sdl.SetHint(sdl.HINT_AUDIO_DRIVER, "dummy")
	if !sdl.InitSubSystem({.AUDIO}) || !mix.Init() {
		log.warnf("No SDL audio here (%s): skipped", sdl.GetError())
		return
	}
	defer { mix.Quit(); sdl.QuitSubSystem({.AUDIO}) }
	got :: proc(mixer: ^mix.Mixer) -> sdl.AudioSpec {
		spec: sdl.AudioSpec
		_ = mix.GetMixerFormat(mixer, &spec)
		return spec
	}
	// The asked rate is the mixer's (the channels too where the device takes them: SDL's dummy
	// device mixes in stereo whatever it's asked)
	mono := Audio_OpenMixer({frequency = 44100, channels = 1})
	if testing.expect(t, mono != nil, "opens") {
		spec := got(mono)
		testing.expectf(t, spec.freq == 44100 && spec.channels >= 1 && spec.channels <= 2, "at 44.1 kHz: got %v", spec)
		mix.DestroyMixer(mono)
	}
	// Stereo at 48 kHz without settings
	stereo := Audio_OpenMixer()
	if testing.expect(t, stereo != nil) {
		spec := got(stereo)
		testing.expect(t, spec.freq == 48000 && spec.channels == 2, "the default")
		mix.DestroyMixer(stereo)
	}
	// A device that isn't there: the default instead (logged)
	{
		context.logger = log.nil_logger()
		other := Audio_OpenMixer({frequency = 48000, channels = 2, device = "No Such Device"})
		testing.expect(t, other != nil, "the default device")
		if other != nil do mix.DestroyMixer(other)
	}
	testing.expect(t, len(Audio_PlaybackDevices(context.temp_allocator)) >= 1, "the dummy device is listed")
	// A project's format, from project.xml (stereo 48 kHz without one)
	project, _ := ParseProject(`<project formatVersion="13" name="A" audioFrequency="44100" audioChannels="1"/>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, project.audioOutput, AudioOutputSettings{frequency = 44100, channels = 1})
	plain, _ := ParseProject(`<project formatVersion="13" name="B"/>`)
	defer ProjectData_Destroy(&plain)
	testing.expect_value(t, plain.audioOutput, DEFAULT_AUDIO_OUTPUT)
	free_all(context.temp_allocator)
}
