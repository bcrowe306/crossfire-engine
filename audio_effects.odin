package crossfire

import "core:math"
import "core:sync"

/*
Audio effects on mix buses: what goes through a bus can be filtered (low-pass for muffled sound
under water or behind a wall, high-pass for a thin radio voice), echoed, or given a room's reverb.

A bus has a chain of up to `AUDIO_MAX_EFFECTS` effects (`AudioEffect`: plain settings), run in
order on everything the bus mixed, before its meter; Master's run on the final mix, before
Master's volume and pan. In project.xml they're `<effect>` children of a `<bus>`:

	<bus name="Music" volume="0.8">
		<effect kind="LowPass" cutoff="900"/>
		<effect kind="Reverb" roomSize="0.7" mix="0.25"/>
	</bus>

From code, `Audio_SetBusEffects` replaces a bus's chain and `Audio_SetBusEffect` changes one
effect (a low-pass sweeping down as the player dives, say); `Audio_GetBusEffects` reads them.

The effects run on the audio thread, in the bus group's post-mix callback (audio_meter.odin).
A chain's settings are changed under its lock, which the audio thread only tries to take: when
it's busy, that block plays with the previous settings, so the game never waits for audio and
audio never waits for the game. Filters, delay lines and reverb tanks keep their state across
blocks, sized for the stereo channels (other channels pass through untouched).
*/

// The most effects a bus has
AUDIO_MAX_EFFECTS :: 8

// What an effect does
AudioEffectKind :: enum {
	// Lets lows through, cuts above `cutoff`: muffled, far, under water
	LowPass,
	// Lets highs through, cuts below `cutoff`: thin, a radio, a phone
	HighPass,
	// Repeats the sound after `delay` seconds, each repeat `feedback` as loud
	Echo,
	// A room's reflections: `roomSize` (small to hall), `damping` (bright to dull)
	Reverb,
}

/*
One effect on a bus (scene and project files store those that differ from
`DEFAULT_AUDIO_EFFECT`).
*/
AudioEffect :: struct {
	// What it does
	kind: AudioEffectKind,
	// Skipped (kept in the chain, doing nothing)
	bypass: bool,
	// LowPass, HighPass: the corner frequency in Hz (20 to 20000)
	cutoff: f32 `min:"20" max:"20000"`,
	// LowPass, HighPass: how much the corner rings (0.5 soft, 0.707 flat, up to 10 a sharp peak)
	resonance: f32 `min:"0.3" max:"10"`,
	// Echo: seconds between repeats (0.01 to 2)
	delay: f32 `min:"0.01" max:"2"`,
	// Echo: how loud each repeat is, relative to the one before (0 to 0.95)
	feedback: f32 `min:"0" max:"0.95"`,
	// Reverb: 0 a small room to 1 a hall
	roomSize: f32 `min:"0" max:"1"`,
	// Reverb: 0 bright reflections to 1 dull ones
	damping: f32 `min:"0" max:"1"`,
	// Echo, Reverb: how much of the effect is heard (0 none, 1 only the effect)
	mix: f32 `min:"0" max:"1"`,
}

// A new effect's settings
DEFAULT_AUDIO_EFFECT :: AudioEffect{cutoff = 1000, resonance = 0.707, delay = 0.3, feedback = 0.4, roomSize = 0.5, damping = 0.5, mix = 0.3}

// An effect of a kind with the default settings
AudioEffect_Make :: proc(kind: AudioEffectKind) -> AudioEffect {
	e := DEFAULT_AUDIO_EFFECT
	e.kind = kind
	return e
}

/*
A bus's effect chain and the state its effects keep between blocks (filters' memory, the echo's
delay line, the reverb's tanks). Shared with the audio thread: change it through
`AudioEffects_Set` only.
*/
AudioEffectChain :: struct {
	lock: sync.Atomic_Mutex,
	// The effects, `count` of them
	effects: [AUDIO_MAX_EFFECTS]AudioEffect,
	count: int,
	// Each effect's state (heap, made by AudioEffects_Set for its kind, freed when replaced), and
	// the sample rate they were set up for
	states: [AUDIO_MAX_EFFECTS]^EffectState,
	rate: f32,
}

// The longest echo (seconds)
AUDIO_MAX_ECHO :: 2
// The highest sample rate the delay lines are sized for
AUDIO_MAX_RATE :: 96000

/*
Replaces a chain's effects (the audio thread picks them up on its next block; their state starts
over). At most AUDIO_MAX_EFFECTS are kept.
*/
AudioEffects_Set :: proc(chain: ^AudioEffectChain, effects: []AudioEffect) {
	if chain == nil do return
	// Made before taking the lock (the audio thread waits for nothing): fresh, so silent
	count := min(len(effects), AUDIO_MAX_EFFECTS)
	fresh: [AUDIO_MAX_EFFECTS]^EffectState
	for i in 0 ..< count do fresh[i] = effectStateMake(effects[i].kind)
	sync.atomic_mutex_lock(&chain.lock)
	old := chain.states
	oldCount := chain.count
	chain.count = count
	for i in 0 ..< count do chain.effects[i] = clampEffect(effects[i])
	chain.states = fresh
	sync.atomic_mutex_unlock(&chain.lock)
	for i in 0 ..< oldCount do effectStateFree(old[i])
}

// Frees a chain's effects' state (the chain must no longer be attached: the bus's group destroyed)
AudioEffects_Destroy :: proc(chain: ^AudioEffectChain) {
	if chain == nil do return
	for i in 0 ..< chain.count do effectStateFree(chain.states[i])
	chain.count = 0
	chain.states = {}
}

// A copy of a chain's effects (temp allocated)
AudioEffects_Get :: proc(chain: ^AudioEffectChain) -> []AudioEffect {
	if chain == nil do return nil
	sync.atomic_mutex_lock(&chain.lock)
	defer sync.atomic_mutex_unlock(&chain.lock)
	out := make([]AudioEffect, chain.count, context.temp_allocator)
	copy(out, chain.effects[:chain.count])
	return out
}

/*
Changes one effect's settings, keeping its state when its kind stays (a filter swept while it
plays doesn't click).
*/
AudioEffects_SetOne :: proc(chain: ^AudioEffectChain, index: int, effect: AudioEffect) {
	if chain == nil || index < 0 do return
	sync.atomic_mutex_lock(&chain.lock)
	defer sync.atomic_mutex_unlock(&chain.lock)
	if index >= chain.count do return
	if chain.effects[index].kind != effect.kind {
		// Another kind needs other state: the whole chain set again
		effects := make([]AudioEffect, chain.count, context.temp_allocator)
		copy(effects, chain.effects[:chain.count])
		effects[index] = effect
		sync.atomic_mutex_unlock(&chain.lock)
		AudioEffects_Set(chain, effects)
		sync.atomic_mutex_lock(&chain.lock)
		return
	}
	chain.effects[index] = clampEffect(effect)
}

/*
Runs a chain over a block of interleaved samples, in place. Called on the audio thread (from a
post-mix callback); when the chain is being changed, the block passes through unchanged.

Inputs:
- chain: The chain (nil does nothing)
- pcm: Interleaved samples, `samples` of them
- channels: Channels per frame
- rate: Frames per second
*/
AudioEffects_Process :: proc "contextless" (chain: ^AudioEffectChain, pcm: [^]f32, samples, channels: int, rate: f32) {
	if chain == nil || samples <= 0 || channels <= 0 || rate <= 0 do return
	if !sync.atomic_mutex_try_lock(&chain.lock) do return
	defer sync.atomic_mutex_unlock(&chain.lock)
	if chain.count == 0 do return
	// Another sample rate (a new device): the delay lines' timing changed, start them over
	if chain.rate != rate {
		if chain.rate != 0 do for i in 0 ..< chain.count do effectClear(chain.states[i])
		chain.rate = rate
	}
	frames := samples / channels
	for i in 0 ..< chain.count {
		e := chain.effects[i]
		if e.bypass do continue
		st := chain.states[i]
		if st == nil do continue
		switch e.kind {
		case .LowPass, .HighPass: processFilter(st, e, pcm, frames, channels, rate)
		case .Echo:               processEcho(st, e, pcm, frames, channels, rate)
		case .Reverb:             processReverb(st, e, pcm, frames, channels, rate)
		}
	}
}

// --- the effects ---------------------------------------------------------------------------

// A biquad's coefficients (RBJ's audio EQ cookbook) and per-channel memory
@(private)
Biquad :: struct {
	b0, b1, b2, a1, a2: f32,
	x1, x2, y1, y2: [2]f32,
}

// Freeverb's tunings at 44.1 kHz (Jezar's public-domain reverb): 8 combs and 4 all-passes per side
@(private="file")
COMB_TUNING :: [8]int{1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617}
@(private="file")
ALLPASS_TUNING :: [4]int{556, 441, 341, 225}
@(private="file")
STEREO_SPREAD :: 23
@(private="file")
COMB_MAX :: 1617 + STEREO_SPREAD + 1
@(private="file")
REVERB_SCALE :: AUDIO_MAX_RATE / 44100 + 1

// An effect's state: a filter's memory, or an echo's delay lines, or a reverb's tanks
@(private)
EffectState :: struct {
	filter: Biquad,
	// The settings and rate the filter's coefficients are for
	coefficientsFor: struct { cutoff, resonance, rate: f32, kind: AudioEffectKind },
	// Echo: one delay line per side (AUDIO_MAX_ECHO seconds at AUDIO_MAX_RATE), written at `cursor`
	echo: [2][]f32,
	cursor: int,
	// Reverb (only for a Reverb)
	reverb: ^ReverbTanks,
}

// A reverb's combs and all-passes per side, their write positions, the combs' filter memory
@(private)
ReverbTanks :: struct {
	comb: [2][8][COMB_MAX * REVERB_SCALE]f32,
	combAt: [2][8]int,
	combStore: [2][8]f32,
	allpass: [2][4][(556 + STEREO_SPREAD) * REVERB_SCALE + 1]f32,
	allpassAt: [2][4]int,
}

// The state an effect of a kind needs, silent (heap)
@(private="file")
effectStateMake :: proc(kind: AudioEffectKind) -> ^EffectState {
	st := new(EffectState)
	switch kind {
	case .Echo:
		for &line in st.echo do line = make([]f32, AUDIO_MAX_ECHO * AUDIO_MAX_RATE)
	case .Reverb:
		st.reverb = new(ReverbTanks)
	case .LowPass, .HighPass:
	}
	return st
}

@(private="file")
effectStateFree :: proc(st: ^EffectState) {
	if st == nil do return
	for line in st.echo do delete(line)
	free(st.reverb)
	free(st)
}

// Silences an effect's memory (on the audio thread: a new sample rate)
@(private="file")
effectClear :: proc "contextless" (st: ^EffectState) {
	if st == nil do return
	st.filter = {}
	st.coefficientsFor = {}
	for line in st.echo do for &v in line do v = 0
	st.cursor = 0
	if st.reverb != nil do st.reverb^ = {}
}

@(private="file")
clampEffect :: proc(e: AudioEffect) -> AudioEffect {
	c := e
	c.cutoff = clamp(c.cutoff, 20, 20000)
	c.resonance = clamp(c.resonance, 0.3, 10)
	c.delay = clamp(c.delay, 0.01, AUDIO_MAX_ECHO)
	c.feedback = clamp(c.feedback, 0, 0.95)
	c.roomSize = clamp(c.roomSize, 0, 1)
	c.damping = clamp(c.damping, 0, 1)
	c.mix = clamp(c.mix, 0, 1)
	return c
}

@(private="file")
processFilter :: proc "contextless" (st: ^EffectState, e: AudioEffect, pcm: [^]f32, frames, channels: int, rate: f32) {
	f := &st.filter
	want := type_of(st.coefficientsFor){e.cutoff, e.resonance, rate, e.kind}
	if st.coefficientsFor != want {
		st.coefficientsFor = want
		w := 2 * math.PI * min(e.cutoff, rate * 0.45) / rate
		cw, sw := math.cos(w), math.sin(w)
		alpha := sw / (2 * e.resonance)
		a0 := 1 + alpha
		if e.kind == .LowPass {
			f.b0, f.b1, f.b2 = (1 - cw) / 2 / a0, (1 - cw) / a0, (1 - cw) / 2 / a0
		} else {
			f.b0, f.b1, f.b2 = (1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0
		}
		f.a1, f.a2 = -2 * cw / a0, (1 - alpha) / a0
	}
	for i in 0 ..< frames {
		for c in 0 ..< min(channels, 2) {
			x := pcm[i * channels + c]
			y := f.b0 * x + f.b1 * f.x1[c] + f.b2 * f.x2[c] - f.a1 * f.y1[c] - f.a2 * f.y2[c]
			f.x2[c], f.x1[c] = f.x1[c], x
			f.y2[c], f.y1[c] = f.y1[c], y
			pcm[i * channels + c] = y
		}
		// Mono goes to both sides' memory alike; more than two channels: the rest pass through
	}
}

@(private="file")
processEcho :: proc "contextless" (st: ^EffectState, e: AudioEffect, pcm: [^]f32, frames, channels: int, rate: f32) {
	size := len(st.echo[0])
	if size == 0 do return
	length := clamp(int(e.delay * rate), 1, size - 1)
	for i in 0 ..< frames {
		read := (st.cursor - length + size) % size
		for c in 0 ..< min(channels, 2) {
			x := pcm[i * channels + c]
			delayed := st.echo[c][read]
			st.echo[c][st.cursor] = x + delayed * e.feedback
			pcm[i * channels + c] = x + delayed * e.mix
		}
		st.cursor = (st.cursor + 1) % size
	}
}

@(private="file")
processReverb :: proc "contextless" (state: ^EffectState, e: AudioEffect, pcm: [^]f32, frames, channels: int, rate: f32) {
	st := state.reverb
	if st == nil do return
	scale := rate / 44100
	feedback := 0.7 + e.roomSize * 0.28
	damp := e.damping * 0.4
	gain: f32 = 0.015
	combTuning := COMB_TUNING
	allTuning := ALLPASS_TUNING
	for i in 0 ..< frames {
		for c in 0 ..< min(channels, 2) {
			x := pcm[i * channels + c]
			in_ := x * gain
			out: f32
			for k in 0 ..< 8 {
				length := min(int(f32(combTuning[k] + c * STEREO_SPREAD) * scale), len(st.comb[c][k]) - 1)
				at := st.combAt[c][k]
				y := st.comb[c][k][at]
				st.combStore[c][k] = y * (1 - damp) + st.combStore[c][k] * damp
				st.comb[c][k][at] = in_ + st.combStore[c][k] * feedback
				st.combAt[c][k] = (at + 1) % max(length, 1)
				out += y
			}
			for k in 0 ..< 4 {
				length := min(int(f32(allTuning[k] + c * STEREO_SPREAD) * scale), len(st.allpass[c][k]) - 1)
				at := st.allpassAt[c][k]
				buffered := st.allpass[c][k][at]
				st.allpass[c][k][at] = out + buffered * 0.5
				out = buffered - out
				st.allpassAt[c][k] = (at + 1) % max(length, 1)
			}
			pcm[i * channels + c] = x * (1 - e.mix) + out * e.mix * 3
		}
	}
}
