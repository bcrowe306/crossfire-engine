package crossfire

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

/*
A level meter: a stage's peak levels since they were last read, and (a final stage) the gains it
applies. Shared with the audio thread: read and set it through the procedures, never the fields.
Zero-initialized is ready to attach.
*/
AudioMeter :: struct {
	// The loudest sample per side since the last read: f32 bits, atomic
	peakLeft, peakRight: u32,
	// A final stage's gain per side: f32 bits, atomic
	gainLeft, gainRight: u32,
	// Whether the gains are applied (only a mixer's meter)
	applyGains: bool,
	// Effects run on the block before it's measured (a bus's chain: audio_effects.odin; nil none)
	effects: ^AudioEffectChain,
}

/*
The loudest samples per side since the last read, then starts over. A meter shows the largest
level it read and lets it fall; reading every frame suits that.

Inputs:
- meter: The meter (nil reads silence)

Returns:
- left, right: 0 (silence) to 1 (full scale); more when the mix clips
*/
AudioMeter_Read :: proc(meter: ^AudioMeter) -> (left, right: f32) {
	if meter == nil do return 0, 0
	left = transmute(f32)sync.atomic_exchange(&meter.peakLeft, 0)
	right = transmute(f32)sync.atomic_exchange(&meter.peakRight, 0)
	return
}

/*
Sets the gains a final stage (`AudioMeter_AttachMixer`) applies to the mix, from the next mixed
block. A group's meter ignores them.

Inputs:
- meter: The meter (nil does nothing)
- left, right: Gains per side (1 unchanged, 0 silences that side; negative is 0)
*/
AudioMeter_SetGains :: proc(meter: ^AudioMeter, left, right: f32) {
	if meter == nil do return
	sync.atomic_store(&meter.gainLeft, transmute(u32)max(left, 0))
	sync.atomic_store(&meter.gainRight, transmute(u32)max(right, 0))
}

/*
Measures a group's mix: the meter becomes the group's post-mix callback (replacing any). The
meter must outlive the attachment (until the group is destroyed).

Inputs:
- meter: The meter
- group: The SDL3_mixer group (nil does nothing)
*/
AudioMeter_AttachGroup :: proc(meter: ^AudioMeter, group: ^mix.Group) {
	if group == nil do return
	_ = setGroupPostMixCallback(group, groupMixed, meter)
}

/*
Makes the meter a mixer's final stage (its post-mix callback, replacing any): its gains are
applied to the whole mix, then it's measured. A meter whose gains are both 0 starts at 1, 1. The
meter must outlive the attachment.

Inputs:
- meter: The meter
- mixer: The SDL3_mixer mixer (nil does nothing)
*/
AudioMeter_AttachMixer :: proc(meter: ^AudioMeter, mixer: ^mix.Mixer) {
	if mixer == nil do return
	meter.applyGains = true
	if sync.atomic_load(&meter.gainLeft) == 0 && sync.atomic_load(&meter.gainRight) == 0 do AudioMeter_SetGains(meter, 1, 1)
	_ = setPostMixCallback(mixer, mixerMixed, meter)
}

/*
A bus's level since the last call (for Master: the final mix). Reading it starts the peaks over,
so one reader per bus (a mixer view reading every frame).

Inputs:
- name: The bus's name ("" is Master)
- game: The game (nil: the current game)

Returns:
- left, right: 0 to 1 (0 without an audio device, or for a bus that doesn't exist)

Example:
	left, right := e.Audio_GetBusLevel("Music")
	db := e.AudioLevel_ToDecibels(max(left, right))
	// A bar over the top 60 dB
	bar := sdl.FRect{20, 20, 200 * max(1 + db / 60, 0), 8}
	e.DrawRectangle(renderer, &bar, {80, 220, 120, 255})
*/
Audio_GetBusLevel :: proc(name: string, game: ^Game = nil) -> (left, right: f32) {
	if b := Audio_GetBus(name, game); b != nil do return AudioMeter_Read(b.meter)
	return 0, 0
}

/*
A level in decibels relative to full scale.

Inputs:
- level: 0 to 1 (more when clipping)

Returns:
- dBFS: 0 at full scale, negative below it, never under `AUDIO_SILENCE_DB` (silence)
*/
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
	// Odin's own import library, the one vendor:sdl3/mixer names (a bare "SDL3_mixer.lib" would
	// be looked for next to this file); with the static SDL, sdl_static.odin's comes first
	foreign import mixLib "vendor:sdl3/mixer/SDL3_mixer.lib"
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
	if meter.effects != nil && spec != nil do AudioEffects_Process(meter.effects, pcm, samples, channels, f32(spec.freq))
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
