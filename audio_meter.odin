package engine

import "core:c"
import "core:math"
import "core:sync"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"

/*
Level meters and output stages for mix buses, on SDL3_mixer's mix callbacks (they run on the
audio thread; everything here is shared through atomics).

A meter attached to a group (`AudioMeter_AttachGroup`) measures what the group's tracks mixed
together; one attached to a mixer (`AudioMeter_AttachMixer`) is the final stage: it applies its
gains (`AudioMeter_SetGains`) to the whole mix, then measures it. The game's buses use both:
each bus's tracks carry the player's and the bus's gains, so its group's meter reads the bus
after its fader; Master's gain and pan are applied to the final mix, which Master's meter reads.
Editors use the same pieces for their own playback.

Example:
	left, right := e.Audio_GetBusLevel("Music")
	db := e.AudioLevel_ToDecibels(max(left, right))
*/

// A stage's peak levels since they were last read, and (final stage) its gains; f32 bits, atomic
AudioMeter :: struct {
	peakLeft, peakRight: u32,
	gainLeft, gainRight: u32,
	// Whether the gains are applied (only a mixer's meter)
	applyGains: bool,
}

/*
The loudest samples (0 = silence, 1 = full scale) per side since the last read, then starts over.
A meter shows the largest level it read and lets it fall; reading every frame suits that.
*/
AudioMeter_Read :: proc(meter: ^AudioMeter) -> (left, right: f32) {
	if meter == nil do return 0, 0
	left = transmute(f32)sync.atomic_exchange(&meter.peakLeft, 0)
	right = transmute(f32)sync.atomic_exchange(&meter.peakRight, 0)
	return
}

// The gains a final stage applies to the mix (0 silences a side)
AudioMeter_SetGains :: proc(meter: ^AudioMeter, left, right: f32) {
	if meter == nil do return
	sync.atomic_store(&meter.gainLeft, transmute(u32)max(left, 0))
	sync.atomic_store(&meter.gainRight, transmute(u32)max(right, 0))
}

// Measures a group's mix
AudioMeter_AttachGroup :: proc(meter: ^AudioMeter, group: ^mix.Group) {
	if group == nil do return
	_ = setGroupPostMixCallback(group, groupMixed, meter)
}

// Makes the meter a mixer's final stage: its gains applied to the whole mix, then measured
AudioMeter_AttachMixer :: proc(meter: ^AudioMeter, mixer: ^mix.Mixer) {
	if mixer == nil do return
	meter.applyGains = true
	if sync.atomic_load(&meter.gainLeft) == 0 && sync.atomic_load(&meter.gainRight) == 0 do AudioMeter_SetGains(meter, 1, 1)
	_ = setPostMixCallback(mixer, mixerMixed, meter)
}

/*
A bus's level since the last call (both sides, 0 to 1; Master: the final mix). Without an audio
device, or for a bus that doesn't exist, 0.
*/
Audio_GetBusLevel :: proc(name: string, game: ^Game = nil) -> (left, right: f32) {
	if b := Audio_GetBus(name, game); b != nil do return AudioMeter_Read(b.meter)
	return 0, 0
}

// A level (0 to 1+) in decibels relative to full scale; silence is `AUDIO_SILENCE_DB`
AudioLevel_ToDecibels :: proc(level: f32) -> f32 {
	if level <= 0.00001 do return AUDIO_SILENCE_DB
	return max(20 * math.log10(level), AUDIO_SILENCE_DB)
}

// Quieter than this is silence, for meters and faders
AUDIO_SILENCE_DB :: f32(-100)

// INTERNAL

/*
Odin's vendor:sdl3/mixer declares its mix callback types without the C calling convention, so a
callback passed through it would be called from C as an Odin proc (no context). These two are
declared again here with "c" callbacks, from the same library (the same import path, so the web
build's `system:SDL3_mixer..` aliases cover them too).
*/
when ODIN_OS == .Windows {
	foreign import mixLib "SDL3_mixer.lib"
} else {
	foreign import mixLib "system:SDL3_mixer"
}

@(private="file")
GroupMixedProc :: #type proc "c" (userdata: rawptr, group: ^mix.Group, spec: ^sdl.AudioSpec, pcm: ^c.float, samples: c.int)
@(private="file")
MixerMixedProc :: #type proc "c" (userdata: rawptr, mixer: ^mix.Mixer, spec: ^sdl.AudioSpec, pcm: ^c.float, samples: c.int)

@(default_calling_convention = "c", link_prefix = "MIX_", private = "file")
foreign mixLib {
	@(link_name = "MIX_SetGroupPostMixCallback")
	setGroupPostMixCallback :: proc(group: ^mix.Group, cb: GroupMixedProc, userdata: rawptr) -> c.bool ---
	@(link_name = "MIX_SetPostMixCallback")
	setPostMixCallback :: proc(mixer: ^mix.Mixer, cb: MixerMixedProc, userdata: rawptr) -> c.bool ---
}

@(private)
audioMeterMeasure :: proc "contextless" (meter: ^AudioMeter, spec: ^sdl.AudioSpec, pcm: [^]f32, samples: int, apply: bool) {
	channels := spec != nil ? max(int(spec.channels), 1) : 2
	gl := apply ? transmute(f32)sync.atomic_load(&meter.gainLeft) : 1
	gr := apply ? transmute(f32)sync.atomic_load(&meter.gainRight) : 1
	left, right: f32
	for i in 0 ..< samples {
		channel := i % channels
		// Left, right; a mono mix counts for both; other channels (surround) go with the nearer side
		gain := channel == 1 || (channel > 1 && channel % 2 == 1) ? gr : gl
		if apply && channels > 1 do pcm[i] *= gain
		else if apply do pcm[i] *= (gl + gr) * 0.5
		v := abs(pcm[i])
		if channels == 1 {
			left, right = max(left, v), max(right, v)
		} else if channel % 2 == 0 {
			left = max(left, v)
		} else {
			right = max(right, v)
		}
	}
	// One writer (the audio thread); a read in between just drops one update
	if left > transmute(f32)sync.atomic_load(&meter.peakLeft) do sync.atomic_store(&meter.peakLeft, transmute(u32)left)
	if right > transmute(f32)sync.atomic_load(&meter.peakRight) do sync.atomic_store(&meter.peakRight, transmute(u32)right)
}

@(private="file")
groupMixed :: proc "c" (userdata: rawptr, group: ^mix.Group, spec: ^sdl.AudioSpec, pcm: ^c.float, samples: c.int) {
	if userdata == nil || pcm == nil do return
	audioMeterMeasure((^AudioMeter)(userdata), spec, ([^]f32)(pcm), int(samples), false)
}

@(private="file")
mixerMixed :: proc "c" (userdata: rawptr, mixer: ^mix.Mixer, spec: ^sdl.AudioSpec, pcm: ^c.float, samples: c.int) {
	if userdata == nil || pcm == nil do return
	audioMeterMeasure((^AudioMeter)(userdata), spec, ([^]f32)(pcm), int(samples), true)
}
