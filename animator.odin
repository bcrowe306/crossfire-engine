package crossfire

import "core:fmt"
import "core:log"
import "base:runtime"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
Animator nodes: keyframe animation of any node's properties (Godot's AnimationPlayer). An
Animator holds **clips** ("intro", "open", "hit"); a clip has a length and **tracks**; a track
animates one property of one node through **keys** (a time and a value). Between two keys the
value moves along the first key's easing curve (`EaseType`), or holds until the next key on a
`step` track. Uses: cutscenes, doors and platforms that move, UI that slides in, a hit flash,
a coin's bob and spin.

	<node kind="Animator" name="Anim" autoplay="bob">
		<clip name="bob" length="1" loop="true">
			<track node="Coin" property="position.y">
				<key time="0" value="0" ease="InOutSine"/>
				<key time="0.5" value="-6" ease="InOutSine"/>
				<key time="1" value="0"/>
			</track>
			<track property="event"><key time="0.5" value="top"/></track>
		</clip>
	</node>

- **Which node:** a track's `node` is a path from the Animator's parent (`Node_FindPath` from
  there: "Coin" is a sibling, "" or "." the parent itself, "Coin/Shine" a child of it, "/World"
  from the top level). Put the Animator inside what it animates.
- **Properties** (`ANIMATOR_PROPERTIES`): `position`, `position.x`, `position.y`, `rotation`,
  `scale`, `scale.x`, `scale.y`, `tint`, `opacity` (the tint's alpha, 0 to 1), `visible`,
  `zIndex`; an AnimatedSprite's `animation` (plays it by name); a Label's `text` and `color`; a
  script's exported field, `script.<field>` (numbers, vectors and colors move, the rest step).
  Values are text as in scene files: `"12"`, `"10, -4"`, `"#ff8000"`, `"true"`.
- **Events:** a track with the property `event` (its `node` unused) fires the Animator's
  `onEvent` with the key's value as each of its keys passes: listen to it in the inspector to call
  a script's procedure at that moment (a footstep sound, a camera shake, a spawned enemy).
- **Playing:** `autoplay` starts a clip when the scene starts; from code `Animator_Play`,
  `Animator_Stop`, `Animator_Pause`, `Animator_Seek`, `speed`. A clip that doesn't loop stops at
  its end and fires `onFinished` (data: its name). The Animator follows its process mode like any
  node (a paused scene pauses it).
- **Order:** an Animator sets values in its update, so a target updated after it (its own script)
  can still change them that frame.
- Clips can be made from code too: `Animator_SetClips` with `AnimatorSettings` data.
*/

// The kind of value a property holds, which says how keys move between each other
AnimatorValueKind :: enum {
	// A number: moves smoothly
	Float,
	// Two numbers ("x, y"): move smoothly
	Vector,
	// A color (`#rrggbb` or `#rrggbbaa`): moves smoothly, channel by channel
	Color,
	// true or false: steps
	Bool,
	// Text (an animation's name, a label's text, an enum's value): steps
	Text,
}

// A property tracks can animate (`ANIMATOR_PROPERTIES`)
AnimatorProperty :: struct {
	// Its name in scene files ("position.x")
	name: string,
	// The value it holds
	kind: AnimatorValueKind,
	// What tools show ("Position X")
	label: string,
	// The node type it needs (nil: any node). A type embedding it counts (`typeEmbeds`)
	type: typeid,
}

/*
The built-in properties an Animator's tracks animate, in the order tools list them. A script's
exported fields are animated as `script.<field>` besides these (`Animator_ScriptFieldKind`).
*/
ANIMATOR_PROPERTIES := [?]AnimatorProperty{
	{"position", .Vector, "Position", nil},
	{"position.x", .Float, "Position X", nil},
	{"position.y", .Float, "Position Y", nil},
	{"rotation", .Float, "Rotation", nil},
	{"scale", .Vector, "Scale", nil},
	{"scale.x", .Float, "Scale X", nil},
	{"scale.y", .Float, "Scale Y", nil},
	{"tint", .Color, "Tint", nil},
	{"opacity", .Float, "Opacity", nil},
	{"visible", .Bool, "Visible", nil},
	{"zIndex", .Float, "Z index", nil},
	{"animation", .Text, "Animation", AnimatedSprite},
	{"text", .Text, "Text", Label},
	{"color", .Color, "Text color", Label},
}

// The track property that fires the Animator's `onEvent` instead of setting a value
ANIMATOR_EVENT_PROPERTY :: "event"

// The prefix of a script field's property ("script.speed")
ANIMATOR_SCRIPT_PREFIX :: "script."

// A key in a scene file or in code (`AnimatorTrackData.keys`)
AnimatorKeyData :: struct {
	// Seconds from the clip's start
	time: f32,
	// The value, as text ("12", "10, -4", "#ff8000", "true", an event's name)
	value: string,
	// The curve from this key to the next (Linear when absent)
	ease: EaseType,
}

// A track in a scene file or in code (`AnimatorClipData.tracks`)
AnimatorTrackData :: struct {
	// The animated node: a path from the Animator's parent ("" for the parent; unused by events)
	node: string,
	// The property (`ANIMATOR_PROPERTIES`, "script.<field>" or "event")
	property: string,
	// Values hold until the next key instead of moving (Bool and Text values always do)
	step: bool,
	// Its keys, in time order (`AnimatorSettings_Sort` sorts them)
	keys: [dynamic]AnimatorKeyData,
}

// A clip in a scene file or in code (`AnimatorSettings.clips`)
AnimatorClipData :: struct {
	// Its name (`Animator_Play`)
	name: string,
	// Seconds; keys past it never play
	length: f32,
	// Starts again at its end (else it stops there and fires `onFinished`)
	loop: bool,
	// Its tracks
	tracks: [dynamic]AnimatorTrackData,
}

/*
An Animator's settings from a scene file (`SceneNodeData.animator`): its clips, the one it starts
with, its speed. Owned data: free it with `AnimatorSettings_Destroy`.
*/
AnimatorSettings :: struct {
	// Its clips
	clips: [dynamic]AnimatorClipData,
	// The clip it plays when the scene starts ("": none)
	autoplay: string,
	// How fast clips play (1: as made; 0 holds them)
	speed: f32,
}

// An Animator's settings when the scene file sets none
DEFAULT_ANIMATOR_SETTINGS :: AnimatorSettings{speed = 1}

// A key ready to play: its value parsed
AnimatorKey :: struct {
	// Seconds from the clip's start
	time: f32,
	// The value (the track's kind)
	value: AnimatorValue,
	// The curve to the next key
	ease: EaseType,
}

// A parsed key value
AnimatorValue :: union {
	f32,
	[2]f32,
	sdl.Color,
	bool,
	string,
}

// A track ready to play (in the Animator's arena)
AnimatorTrack :: struct {
	// The path from the Animator's parent
	path: string,
	// The property
	property: string,
	// The value's kind
	kind: AnimatorValueKind,
	// Values hold between keys
	step: bool,
	// The data's `step` (Bool and Text values step whatever it says)
	stepSet: bool,
	// Fires `onEvent` instead of setting a value
	event: bool,
	// Its keys in time order
	keys: []AnimatorKey,
	// The node found for the path, and its id (checked before each use: it may be gone)
	target: ^Node,
	targetId: EntityId,
	// The key whose value was set last by a stepping track (-2: none yet), so text and bools are
	// set only when they change
	applied: int,
}

// A clip ready to play (in the Animator's arena)
AnimatorClip :: struct {
	// Its name
	name: string,
	// Seconds
	length: f32,
	// Starts again at its end
	loop: bool,
	// Its tracks
	tracks: []AnimatorTrack,
}

/*
A node playing keyframe animations of other nodes' properties: see the file's overview. Made by
scene files (kind "Animator") or `CreateAnimator`.
*/
Animator :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Its clips (node arena)
	clips: []AnimatorClip,
	// The clip playing or paused (-1: none)
	current: int,
	// Seconds into the current clip
	time: f32,
	// The clip is moving (false: stopped or paused)
	playing: bool,
	// How fast clips play (1: as made; 0 holds)
	speed: f32,
	// The clip to start when the scene starts ("": none; node arena)
	autoplay: string,
	// Whether autoplay has run
	started: bool,
	// A clip that doesn't loop reached its end
	onFinished: EventSubject `event:"A clip that doesn't loop reached its end (data: its name)" data:"clip := data.(string)"`,
	// An event key passed
	onEvent: EventSubject `event:"An event key of the playing clip passed (data: the key's value)" data:"name := data.(string)"`,
}

/*
Creates an Animator node with no clips and adds it to the scene (at the start of the next
update). Give it clips with `Animator_SetClips`.

Inputs:
- scene: The scene that owns it

Returns:
- The Animator

Example:
	anim := e.CreateAnimator(scene)
	e.Node_AddChild(node, anim)
*/
CreateAnimator :: proc(scene: ^Scene) -> ^Animator {
	a := CreateNode(scene, Animator)
	a.current = -1
	a.speed = 1
	EventSubject_Init(&a.onFinished, Node_GetAllocator(a))
	EventSubject_Init(&a.onEvent, Node_GetAllocator(a))
	a.update = animatorUpdate
	return a
}

/*
Replaces an Animator's clips with copies of these (parsed into its arena), and its autoplay clip
and speed. A playing clip stops.

Inputs:
- animator: The Animator
- settings: The clips (copied: the caller keeps them), autoplay and speed

Example:
	// Given: anim: ^e.Animator
	// Turns its parent once a second (the data is copied: temporary lists will do)
	track := e.AnimatorTrackData{property = "rotation", keys = make([dynamic]e.AnimatorKeyData, context.temp_allocator)}
	append(&track.keys, e.AnimatorKeyData{time = 0, value = "0"}, e.AnimatorKeyData{time = 1, value = "360"})
	clip := e.AnimatorClipData{name = "spin", length = 1, loop = true, tracks = make([dynamic]e.AnimatorTrackData, context.temp_allocator)}
	append(&clip.tracks, track)
	settings := e.AnimatorSettings{speed = 1, clips = make([dynamic]e.AnimatorClipData, context.temp_allocator)}
	append(&settings.clips, clip)
	e.Animator_SetClips(anim, settings)
	e.Animator_Play(anim, "spin")
*/
Animator_SetClips :: proc(animator: ^Animator, settings: AnimatorSettings) {
	allocator := Node_GetAllocator(animator)
	clips := make([]AnimatorClip, len(settings.clips), allocator)
	for clip, c in settings.clips {
		tracks := make([]AnimatorTrack, len(clip.tracks), allocator)
		for track, t in clip.tracks {
			kind, known := Animator_PropertyKind(track.property)
			event := track.property == ANIMATOR_EVENT_PROPERTY
			// Events, and script fields until their script is found, keep the keys' text
			script := strings.has_prefix(track.property, ANIMATOR_SCRIPT_PREFIX)
			if event || script do kind = .Text
			keys := make([dynamic]AnimatorKey, 0, len(track.keys), allocator)
			for key in track.keys {
				value, ok := Animator_ParseValue(kind, key.value, allocator)
				if !ok {
					log.warnf("Animator %s: clip %s, %s: can't read the key %q at %.3f", animator.name, clip.name, track.property, key.value, key.time)
					continue
				}
				append(&keys, AnimatorKey{key.time, value, key.ease})
			}
			sortKeys(keys[:])
			tracks[t] = {
				path = strings.clone(track.node, allocator),
				property = strings.clone(track.property, allocator),
				// Script fields' kinds are known once the target is found
				kind = kind,
				step = track.step || kind == .Bool || kind == .Text,
				stepSet = track.step,
				event = event,
				keys = keys[:],
				applied = -2,
			}
			if !known && !event && !script {
				log.warnf("Animator %s: clip %s has a track of an unknown property %q", animator.name, clip.name, track.property)
			}
		}
		clips[c] = {strings.clone(clip.name, allocator), max(clip.length, 0), clip.loop, tracks}
	}
	animator.clips = clips
	animator.current = -1
	animator.playing = false
	animator.time = 0
	animator.autoplay = strings.clone(settings.autoplay, allocator)
	animator.speed = settings.speed
}

/*
Plays a clip from its start. The clip already playing goes on, and a paused one resumes, unless
`restart`. Event keys at time 0 fire.

Inputs:
- animator: The Animator
- name: The clip's name
- restart: Start again even when it's the clip playing

Returns:
- false when it has no clip of that name

Example:
	// Given: anim: ^e.Animator
	e.Animator_Play(anim, "open")
*/
Animator_Play :: proc(animator: ^Animator, name: string, restart := false) -> bool {
	index := Animator_FindClip(animator, name)
	if index < 0 {
		log.warnf("Animator %s has no clip %q", animator.name, name)
		return false
	}
	if index == animator.current && animator.playing && !restart do return true
	// A paused clip resumes where it is; anything else starts at 0 (a finished clip too)
	paused := index == animator.current && !animator.playing && animator.time > 0 && animator.time < animator.clips[index].length
	if restart || !paused do animator.time = 0
	animator.current = index
	animator.playing = true
	animator.started = true
	for &track in animator.clips[index].tracks do track.applied = -2
	clip := &animator.clips[index]
	// Events at the start
	if animator.time == 0 do fireEvents(animator, clip, -1, 0)
	applyClip(animator, clip, animator.time)
	return true
}

/*
Stops the current clip. Its values stay as they are, unless `reset`, which sets them to the
clip's start.

Inputs:
- animator: The Animator
- reset: Put the clip's values back to its first keys

Example:
	// Given: anim: ^e.Animator
	e.Animator_Stop(anim, reset = true)
*/
Animator_Stop :: proc(animator: ^Animator, reset := false) {
	if reset && animator.current >= 0 do applyClip(animator, &animator.clips[animator.current], 0)
	animator.playing = false
	animator.time = 0
}

/*
Pauses or resumes the current clip where it is.

Inputs:
- animator: The Animator
- paused: true pauses, false resumes

Example:
	// Given: anim: ^e.Animator
	e.Animator_Pause(anim, true)
*/
Animator_Pause :: proc(animator: ^Animator, paused: bool) {
	if animator.current < 0 do return
	animator.playing = !paused
}

/*
Jumps the current clip to a time and sets its values there (no events fire).

Inputs:
- animator: The Animator
- time: Seconds from the clip's start (clamped to its length)

Example:
	// Given: anim: ^e.Animator
	e.Animator_Seek(anim, 0.5)
*/
Animator_Seek :: proc(animator: ^Animator, time: f32) {
	if animator.current < 0 do return
	clip := &animator.clips[animator.current]
	animator.time = clamp(time, 0, clip.length)
	applyClip(animator, clip, animator.time)
}

/*
Whether a clip is playing (not stopped, paused or finished).

Inputs:
- animator: The Animator

Returns:
- true while one plays
*/
Animator_IsPlaying :: proc(animator: ^Animator) -> bool {
	return animator.playing && animator.current >= 0
}

/*
The current clip's name (playing, paused or finished; "" when none has played).

Inputs:
- animator: The Animator

Returns:
- Its name (the Animator's)
*/
Animator_CurrentClip :: proc(animator: ^Animator) -> string {
	return animator.current >= 0 ? animator.clips[animator.current].name : ""
}

/*
Finds a clip by name.

Inputs:
- animator: The Animator
- name: The clip's name

Returns:
- Its index in `animator.clips`, or -1
*/
Animator_FindClip :: proc(animator: ^Animator, name: string) -> int {
	for clip, i in animator.clips do if clip.name == name do return i
	return -1
}

/*
Sets every track of a clip to its value at a time, without playing it or firing events: what an
editor's timeline shows while scrubbing.

Inputs:
- animator: The Animator
- clip: The clip's index
- time: Seconds from its start
*/
Animator_Apply :: proc(animator: ^Animator, clip: int, time: f32) {
	if clip < 0 || clip >= len(animator.clips) do return
	for &track in animator.clips[clip].tracks do track.applied = -2
	applyClip(animator, &animator.clips[clip], time)
}

/*
The kind of a built-in property's value (`ANIMATOR_PROPERTIES`).

Inputs:
- property: The property's name

Returns:
- Its kind, and false when it isn't a built-in one (a script field, an event, or unknown)
*/
Animator_PropertyKind :: proc(property: string) -> (AnimatorValueKind, bool) {
	for p in ANIMATOR_PROPERTIES do if p.name == property do return p.kind, true
	return .Float, false
}

/*
Whether a node type has a property (a built-in one needing a type, like `animation`).

Inputs:
- type: The node's type (`node.type`, or a kind's `SCENE_NODE_TYPES`)
- property: The property

Returns:
- true when nodes of the type have it
*/
Animator_TypeHasProperty :: proc(type: typeid, property: AnimatorProperty) -> bool {
	return property.type == nil || type == property.type || typeEmbeds(type, property.type)
}

/*
How a script field is animated: numbers, vectors and colors move, booleans step, and text, enums
and asset handles step as text. Node fields can't be animated.

Inputs:
- type: The field's type

Returns:
- Its kind, and false for node fields
*/
Animator_ScriptFieldKind :: proc(type: ScriptFieldType) -> (AnimatorValueKind, bool) {
	#partial switch type {
	case .Float, .Int: return .Float, true
	case .Vector2: return .Vector, true
	case .Color: return .Color, true
	case .Bool: return .Bool, true
	case .Node: return .Text, false
	}
	return .Text, true
}

/*
Reads a key's value of a kind from text.

Inputs:
- kind: The value's kind
- text: The text ("12", "10, -4", "#ff8000", "true")
- allocator: For text values

Returns:
- The value, and false when the text isn't one
*/
Animator_ParseValue :: proc(kind: AnimatorValueKind, text: string, allocator := context.allocator) -> (AnimatorValue, bool) {
	text := strings.trim_space(text)
	switch kind {
	case .Float:
		v, ok := strconv.parse_f32(text)
		return v, ok
	case .Vector:
		x, _, y := strings.partition(text, ",")
		a, okA := strconv.parse_f32(strings.trim_space(x))
		b, okB := strconv.parse_f32(strings.trim_space(y))
		return [2]f32{a, b}, okA && okB
	case .Color:
		c, ok := ParseColor(text)
		return c, ok
	case .Bool:
		switch text {
		case "true", "1": return true, true
		case "false", "0", "": return false, true
		}
		return false, false
	case .Text:
		return strings.clone(text, allocator), true
	}
	return nil, false
}

/*
Writes a value as key text (what `Animator_ParseValue` reads).

Inputs:
- value: The value
- allocator: For the text

Returns:
- Its text
*/
Animator_FormatValue :: proc(value: AnimatorValue, allocator := context.allocator) -> string {
	switch v in value {
	case f32: return formatNumber(v, allocator)
	case [2]f32: return fmt.aprintf("%s, %s", formatNumber(v.x, context.temp_allocator), formatNumber(v.y, context.temp_allocator), allocator = allocator)
	case sdl.Color: return FormatColor(v, allocator)
	case bool: return strings.clone(v ? "true" : "false", allocator)
	case string: return strings.clone(v, allocator)
	}
	return strings.clone("", allocator)
}

/*
A node's current value of a property, as key text: what an editor records as a key. Script
fields need the node's script.

Inputs:
- node: The node
- property: The property (`ANIMATOR_PROPERTIES` or "script.<field>")
- allocator: For the text

Returns:
- The text, and false when the node has no such property
*/
Animator_ReadProperty :: proc(node: ^Node, property: string, allocator := context.allocator) -> (string, bool) {
	value, ok := readProperty(node, property)
	if !ok do return "", false
	return Animator_FormatValue(value, allocator), true
}

/*
Sorts every track's keys by time (stable): call it after changing keys' times.

Inputs:
- settings: The settings
*/
AnimatorSettings_Sort :: proc(settings: ^AnimatorSettings) {
	for &clip in settings.clips do for &track in clip.tracks {
		keys := track.keys[:]
		for i in 1..<len(keys) {
			for j := i; j > 0 && keys[j].time < keys[j - 1].time; j -= 1 do keys[j], keys[j - 1] = keys[j - 1], keys[j]
		}
	}
}

/*
A deep copy of Animator settings.

Inputs:
- settings: The settings to copy
- allocator: For the copy

Returns:
- The copy (free it with `AnimatorSettings_Destroy`)
*/
AnimatorSettings_Clone :: proc(settings: AnimatorSettings, allocator := context.allocator) -> AnimatorSettings {
	out := AnimatorSettings{autoplay = strings.clone(settings.autoplay, allocator), speed = settings.speed}
	out.clips = make([dynamic]AnimatorClipData, 0, len(settings.clips), allocator)
	for clip in settings.clips {
		c := AnimatorClipData{name = strings.clone(clip.name, allocator), length = clip.length, loop = clip.loop}
		c.tracks = make([dynamic]AnimatorTrackData, 0, len(clip.tracks), allocator)
		for track in clip.tracks {
			t := AnimatorTrackData{node = strings.clone(track.node, allocator), property = strings.clone(track.property, allocator), step = track.step}
			t.keys = make([dynamic]AnimatorKeyData, 0, len(track.keys), allocator)
			for key in track.keys do append(&t.keys, AnimatorKeyData{key.time, strings.clone(key.value, allocator), key.ease})
			append(&c.tracks, t)
		}
		append(&out.clips, c)
	}
	return out
}

/*
Frees Animator settings (made by the parser or `AnimatorSettings_Clone`) and empties them.

Inputs:
- settings: The settings
*/
AnimatorSettings_Destroy :: proc(settings: ^AnimatorSettings) {
	for &clip in settings.clips {
		for &track in clip.tracks {
			for key in track.keys do delete(key.value)
			delete(track.keys)
			delete(track.node)
			delete(track.property)
		}
		delete(clip.tracks)
		delete(clip.name)
	}
	delete(settings.clips)
	delete(settings.autoplay)
	settings^ = {speed = settings.speed}
}

/*
Whether two Animator settings are the same: every clip, track and key.

Inputs:
- a, b: The settings

Returns:
- true when equal
*/
AnimatorSettings_Equal :: proc(a, b: AnimatorSettings) -> bool {
	if a.autoplay != b.autoplay || a.speed != b.speed || len(a.clips) != len(b.clips) do return false
	for clip, c in a.clips {
		other := b.clips[c]
		if clip.name != other.name || clip.length != other.length || clip.loop != other.loop || len(clip.tracks) != len(other.tracks) do return false
		for track, t in clip.tracks {
			o := other.tracks[t]
			if track.node != o.node || track.property != o.property || track.step != o.step || len(track.keys) != len(o.keys) do return false
			for key, k in track.keys do if key != o.keys[k] do return false
		}
	}
	return true
}

/*
The value a track has at a time: the keys around it blended along the first one's curve (or the
key before it on stepping tracks).

Inputs:
- track: The track (its keys in time order)
- time: Seconds from the clip's start

Returns:
- The value, and the index of the key at or before the time (-1 before the first: its value then)
*/
AnimatorTrack_ValueAt :: proc(track: ^AnimatorTrack, time: f32) -> (AnimatorValue, int) {
	keys := track.keys
	if len(keys) == 0 do return nil, -1
	if time < keys[0].time do return keys[0].value, -1
	at := len(keys) - 1
	for i in 0..<len(keys) - 1 do if time < keys[i + 1].time {
		at = i
		break
	}
	if track.step || at == len(keys) - 1 do return keys[at].value, at
	from, to := keys[at], keys[at + 1]
	span := to.time - from.time
	t := span > 0 ? Ease(from.ease, (time - from.time) / span) : 1
	return blend(from.value, to.value, t), at
}

@(private="file")
blend :: proc(a, b: AnimatorValue, t: f32) -> AnimatorValue {
	switch x in a {
	case f32:
		if y, ok := b.(f32); ok do return x + (y - x) * t
	case [2]f32:
		if y, ok := b.([2]f32); ok do return x + (y - x) * t
	case sdl.Color:
		if y, ok := b.(sdl.Color); ok {
			mix :: proc(p, q: u8, t: f32) -> u8 { return u8(clamp(math.round(f32(p) + (f32(q) - f32(p)) * t), 0, 255)) }
			return sdl.Color{mix(x.r, y.r, t), mix(x.g, y.g, t), mix(x.b, y.b, t), mix(x.a, y.a, t)}
		}
	case bool, string:
	}
	return a
}

@(private="file")
sortKeys :: proc(keys: []AnimatorKey) {
	for i in 1..<len(keys) {
		for j := i; j > 0 && keys[j].time < keys[j - 1].time; j -= 1 do keys[j], keys[j - 1] = keys[j - 1], keys[j]
	}
}

// "12" for 12, "0.5" for 0.5: short numbers for scene files
@(private="file")
formatNumber :: proc(v: f32, allocator := context.allocator) -> string {
	text := fmt.tprintf("%.4f", v)
	text = strings.trim_right(text, "0")
	text = strings.trim_right(text, ".")
	if text == "-0" do text = "0"
	return strings.clone(text, allocator)
}

@(private="file")
animatorUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	animator := cast(^Animator)node
	if !animator.started {
		animator.started = true
		if animator.autoplay != "" do Animator_Play(animator, animator.autoplay)
		return
	}
	if !animator.playing || animator.current < 0 do return
	clip := &animator.clips[animator.current]
	step := f32(deltaTime) * max(animator.speed, 0)
	if step <= 0 do return
	from := animator.time
	to := from + step
	if to >= clip.length {
		if clip.loop && clip.length > 0 {
			// To the end, then around (more than one lap in a long frame plays the events once)
			fireEvents(animator, clip, from, clip.length)
			to = math.mod(to - clip.length, clip.length)
			animator.time = to
			// A key at the very end and one at the start are the same moment: the end's fired
			fireEvents(animator, clip, 0, to)
			applyClip(animator, clip, to)
			return
		}
		fireEvents(animator, clip, from, clip.length)
		animator.time = clip.length
		animator.playing = false
		applyClip(animator, clip, clip.length)
		Event_Notify(&animator.onFinished, animator, clip.name)
		return
	}
	fireEvents(animator, clip, from, to)
	animator.time = to
	applyClip(animator, clip, to)
}

// Event keys with from < time <= to (from -1: from the start, a key at 0 included)
@(private="file")
fireEvents :: proc(animator: ^Animator, clip: ^AnimatorClip, from, to: f32) {
	index := animator.current
	for &track in clip.tracks {
		if !track.event do continue
		for key in track.keys {
			if key.time > from && key.time <= to {
				name, _ := key.value.(string)
				Event_Notify(&animator.onEvent, animator, name)
				// A listener may have played another clip, or removed clips
				if animator.current != index do return
			}
		}
	}
}

@(private="file")
applyClip :: proc(animator: ^Animator, clip: ^AnimatorClip, time: f32) {
	for &track in clip.tracks {
		if track.event || len(track.keys) == 0 do continue
		target := trackTarget(animator, &track)
		if target == nil do continue
		value, at := AnimatorTrack_ValueAt(&track, time)
		if track.step {
			if at == track.applied do continue
			track.applied = at
		}
		writeProperty(target, track.property, value)
	}
}

// The track's node, found once and checked each time (it may have been removed)
@(private="file")
trackTarget :: proc(animator: ^Animator, track: ^AnimatorTrack) -> ^Node {
	if track.target != nil {
		if animator.scene != nil && Scene_GetNode(animator.scene, track.targetId) == track.target do return track.target
		track.target = nil
	}
	path := strings.trim_space(track.path)
	target: ^Node
	switch {
	case strings.has_prefix(path, "/"):
		target = Node_FindPath(animator, path)
	case path == "" || path == ".":
		target = animator.parent
	case:
		if animator.parent != nil {
			target = Node_FindPath(animator.parent, path)
		} else {
			target = Node_FindPath(animator, strings.concatenate({"/", path}, context.temp_allocator))
		}
	}
	if target == nil do return nil
	track.target = target
	track.targetId = target.id
	// A script field's kind comes from the script
	if strings.has_prefix(track.property, ANIMATOR_SCRIPT_PREFIX) {
		if field, ok := scriptField(target, track.property); ok {
			kind, _ := Animator_ScriptFieldKind(field.type)
			if kind != track.kind {
				// Kept as text until the field was known: read the keys again
				reparseKeys(animator, track, kind)
			}
		}
	}
	return target
}

@(private="file")
reparseKeys :: proc(animator: ^Animator, track: ^AnimatorTrack, kind: AnimatorValueKind) {
	// The keys hold their text until the field's kind is known
	allocator := Node_GetAllocator(animator)
	for &key in track.keys {
		text := Animator_FormatValue(key.value, context.temp_allocator)
		if value, ok := Animator_ParseValue(kind, text, allocator); ok do key.value = value
	}
	track.kind = kind
	track.step = track.stepSet || kind == .Bool || kind == .Text
	track.applied = -2
}

@(private="file")
scriptField :: proc(node: ^Node, property: string) -> (ScriptField, bool) {
	if node.script.info == nil do return {}, false
	name := property[len(ANIMATOR_SCRIPT_PREFIX):]
	for field in node.script.info.fields do if field.name == name do return field, true
	return {}, false
}

@(private="file")
readProperty :: proc(node: ^Node, property: string) -> (AnimatorValue, bool) {
	switch property {
	case "position": return node.position, true
	case "position.x": return node.position.x, true
	case "position.y": return node.position.y, true
	case "rotation": return node.rotation, true
	case "scale": return node.scale, true
	case "scale.x": return node.scale.x, true
	case "scale.y": return node.scale.y, true
	case "tint": return node.tint, true
	case "opacity": return f32(node.tint.a) / 255, true
	case "visible": return node.visible, true
	case "zIndex": return f32(node.zIndex), true
	case "animation":
		if Node_Is(node, AnimatedSprite) do return AnimationPlayer_CurrentName(&(cast(^AnimatedSprite)node).animation), true
	case "text":
		if Node_Is(node, Label) do return (cast(^Label)node).text, true
	case "color":
		if Node_Is(node, Label) do return (cast(^Label)node).color, true
	}
	if strings.has_prefix(property, ANIMATOR_SCRIPT_PREFIX) {
		field, ok := scriptField(node, property)
		if !ok do return nil, false
		at := rawptr(uintptr(node.script.data) + field.offset)
		#partial switch field.type {
		case .Float: return field.odinType == f64 ? f32((cast(^f64)at)^) : (cast(^f32)at)^, true
		case .Int: return field.odinType == i32 ? f32((cast(^i32)at)^) : f32((cast(^int)at)^), true
		case .Vector2: return (cast(^[2]f32)at)^, true
		case .Color: return (cast(^sdl.Color)at)^, true
		case .Bool: return (cast(^bool)at)^, true
		case .String, .Texture, .Sound, .Font, .Data, .Component, .Music, .Animation: return (cast(^string)at)^, true
		case .Enum:
			// Its name, by value
			v := enumValue(at, field)
			for name, i in field.enumNames do if i == v do return name, true
		}
	}
	return nil, false
}

@(private="file")
enumValue :: proc(at: rawptr, field: ScriptField) -> int {
	values := reflect.enum_field_values(field.odinType)
	raw: i64
	switch runtime.type_info_base(type_info_of(field.odinType)).size {
	case 1: raw = i64((cast(^i8)at)^)
	case 2: raw = i64((cast(^i16)at)^)
	case 4: raw = i64((cast(^i32)at)^)
	case: raw = (cast(^i64)at)^
	}
	for v, i in values do if i64(v) == raw do return i
	return -1
}

@(private="file")
writeProperty :: proc(node: ^Node, property: string, value: AnimatorValue) {
	f, isF := value.(f32)
	v, isV := value.([2]f32)
	c, isC := value.(sdl.Color)
	switch property {
	case "position": if isV do node.position = v
	case "position.x": if isF do node.position.x = f
	case "position.y": if isF do node.position.y = f
	case "rotation": if isF do node.rotation = f
	case "scale": if isV do node.scale = v
	case "scale.x": if isF do node.scale.x = f
	case "scale.y": if isF do node.scale.y = f
	case "tint": if isC do node.tint = c
	case "opacity": if isF do node.tint.a = u8(clamp(math.round(f * 255), 0, 255))
	case "visible": if b, ok := value.(bool); ok do node.visible = b
	case "zIndex": if isF do node.zIndex = i32(math.round(f))
	case "animation":
		if Node_Is(node, AnimatedSprite) {
			if name, isText := value.(string); isText && name != "" do AnimationPlayer_Play(&(cast(^AnimatedSprite)node).animation, name)
		}
	case "text":
		if Node_Is(node, Label) {
			if text, isText := value.(string); isText do (cast(^Label)node).text = strings.clone(text, Node_GetAllocator(node))
		}
	case "color":
		if Node_Is(node, Label) && isC do (cast(^Label)node).color = c
	case:
		if !strings.has_prefix(property, ANIMATOR_SCRIPT_PREFIX) do return
		field, ok := scriptField(node, property)
		if !ok do return
		at := rawptr(uintptr(node.script.data) + field.offset)
		#partial switch field.type {
		case .Float:
			if !isF do return
			x := f64(f)
			if lo, has := field.min.?; has do x = max(x, lo)
			if hi, has := field.max.?; has do x = min(x, hi)
			if field.odinType == f64 do (cast(^f64)at)^ = x
			else do (cast(^f32)at)^ = f32(x)
		case .Int:
			if !isF do return
			n := int(math.round(f))
			if field.odinType == i32 do (cast(^i32)at)^ = i32(n)
			else do (cast(^int)at)^ = n
		case .Vector2: if isV do (cast(^[2]f32)at)^ = v
		case .Color: if isC do (cast(^sdl.Color)at)^ = c
		case .Bool: if b, isB := value.(bool); isB do (cast(^bool)at)^ = b
		case .Node:
		case:
			if text, isText := value.(string); isText do Script_SetField(node.script.data, field, text, Node_GetAllocator(node))
		}
	}
}
