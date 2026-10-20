package engine

import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

/*
Rebinding: letting players change what triggers an action, from the game's options menu, and
keeping their choice. And gamepad rumble.

1. `Input_StartCapture(game)`, then each frame `Input_GetCapturedBinding(game)`: the next key,
   mouse button, gamepad button, or stick or trigger pushed past halfway comes back once
   (Escape too: the game decides whether it cancels). Until then, and on the frame it comes,
   actions don't press or release, so the press being bound doesn't also act.
2. `Input_SetBindings(name, bindings)` changes an action's bindings (`Input_GetBindings` reads
   them; `Input_ActionsUsing` finds actions a binding is already on; `Input_ResetBindings` puts
   back the project's).
3. `Input_SaveBindings()` keeps every action's bindings with the game's saves (`Input_LoadBindings`
   at start, after the project is loaded: actions the save doesn't have keep the project's).

Example:
	// The options menu's "Jump" button
	e.Input_StartCapture()
	// Its update:
	if binding, ok := e.Input_GetCapturedBinding(); ok {
		if binding != e.InputBinding(e.KeyBinding{.Escape}) {
			e.Input_SetBindings("jump", {binding})
			e.Input_SaveBindings()
		}
	}
*/

// The save slot bindings are kept in (`Input_SaveBindings`)
INPUT_BINDINGS_SLOT :: "bindings"

// How far a stick or trigger must move to be captured
INPUT_CAPTURE_AXIS :: 0.5

// Where a capture is (InputState.capture)
InputCaptureState :: enum u8 {
	Off,
	// Waiting for the next input
	Waiting,
	// Got it: Input_GetCapturedBinding hands it out once
	Done,
}

// A capture of the next input (`Input_StartCapture`)
InputCapture :: struct {
	state: InputCaptureState,
	binding: InputBinding,
	// Gamepad bindings for any gamepad (device -1), or the one used
	anyDevice: bool,
	// Each gamepad's axes when the capture started: a stick resting off-center isn't a push
	baseline: [8][GamepadAxis]f32,
}

/*
Starts waiting for the next input to bind (see above).

Inputs:
- anyDevice: A gamepad binding works on any gamepad (else only on the one pressed)
- game: The game (nil: the one playing)
*/
Input_StartCapture :: proc(anyDevice := true, game: ^Game = nil) {
	input := inputOf(game)
	if input == nil do return
	input.capture = {state = .Waiting, anyDevice = anyDevice}
	for pad, i in input.gamepads do if i < len(input.capture.baseline) do input.capture.baseline[i] = pad.axes
}

// Stops waiting for an input to bind (a captured one not taken yet is dropped)
Input_CancelCapture :: proc(game: ^Game = nil) {
	if input := inputOf(game); input != nil do input.capture = {}
}

// Whether a capture is waiting for its input
Input_IsCapturing :: proc(game: ^Game = nil) -> bool {
	input := inputOf(game)
	return input != nil && input.capture.state == .Waiting
}

/*
The input a capture got, once: from the frame it came (Game_Update's Input_Update), then the
capture is over.

Returns:
- The binding, and whether there is one
*/
Input_GetCapturedBinding :: proc(game: ^Game = nil) -> (InputBinding, bool) {
	input := inputOf(game)
	if input == nil || input.capture.state != .Done do return nil, false
	binding := input.capture.binding
	input.capture = {}
	return binding, true
}

/*
An action's bindings.

Returns:
- The game's list (don't keep it past a change), nil when there's no such action
*/
Input_GetBindings :: proc(name: string, game: ^Game = nil) -> []InputBinding {
	a := findAction(game, name)
	return a != nil ? a.data.bindings[:] : nil
}

/*
Replaces an action's bindings (copied).

Returns:
- false when there's no such action
*/
Input_SetBindings :: proc(name: string, bindings: []InputBinding, game: ^Game = nil) -> bool {
	a := findAction(game, name)
	if a == nil do return false
	clear(&a.data.bindings)
	append(&a.data.bindings, ..bindings)
	return true
}

/*
The actions a binding triggers (to warn about, or take it off, before binding it to another).

Returns:
- Their names (the game's strings; the list is temp allocated)
*/
Input_ActionsUsing :: proc(binding: InputBinding, game: ^Game = nil) -> []string {
	input := inputOf(game)
	if input == nil do return nil
	names := make([dynamic]string, context.temp_allocator)
	for &a in input.actions {
		for b in a.data.bindings do if b == binding {
			append(&names, a.data.name)
			break
		}
	}
	return names[:]
}

// Puts every action's bindings back as the project (or `Input_AddAction`) made them
Input_ResetBindings :: proc(game: ^Game = nil) {
	input := inputOf(game)
	if input == nil do return
	for &a in input.actions {
		clear(&a.data.bindings)
		append(&a.data.bindings, ..a.defaults[:])
	}
}

/*
Every action's bindings as text, one line per action (what `Input_SaveBindings` writes):

	jump = key key=Space | gamepad button=South
	move_left = key key=A | axis axis=LeftX direction=-1

Returns:
- The text, allocated with `allocator`
*/
Input_FormatBindings :: proc(game: ^Game = nil, allocator := context.allocator) -> string {
	input := inputOf(game)
	if input == nil do return ""
	b := strings.builder_make(context.temp_allocator)
	for &a in input.actions {
		strings.write_string(&b, a.data.name)
		strings.write_string(&b, " =")
		for binding, i in a.data.bindings {
			strings.write_string(&b, i == 0 ? " " : " | ")
			element, attributes := FormatInputBinding(binding)
			strings.write_string(&b, element)
			for attribute in attributes {
				strings.write_byte(&b, ' ')
				strings.write_string(&b, attribute.name)
				strings.write_byte(&b, '=')
				strings.write_string(&b, attribute.value)
			}
		}
		strings.write_byte(&b, '\n')
	}
	return strings.clone(strings.to_string(b), allocator)
}

/*
Sets actions' bindings from `Input_FormatBindings` text. Actions the text doesn't list keep
theirs; lines for actions the game doesn't have, and bindings that can't be read, are skipped.

Returns:
- How many actions it set
*/
Input_ParseBindings :: proc(text: string, game: ^Game = nil) -> int {
	input := inputOf(game)
	if input == nil do return 0
	set := 0
	text := text
	for line in strings.split_lines_iterator(&text) {
		equals := strings.index(line, "=")
		if equals < 0 do continue
		name := strings.trim_space(line[:equals])
		a := findAction(game, name, warn = false)
		if a == nil do continue
		bindings := make([dynamic]InputBinding, context.temp_allocator)
		rest := line[equals + 1:]
		for part in strings.split_iterator(&rest, "|") {
			words := strings.fields(part, context.temp_allocator)
			if len(words) == 0 do continue
			Attributes :: struct { words: []string }
			attributes := Attributes{words[1:]}
			get :: proc(user: rawptr, key: string) -> (string, bool) {
				for word in (cast(^Attributes)user).words {
					if k, _, v := strings.partition(word, "="); k == key do return v, true
				}
				return "", false
			}
			if binding, ok := ParseInputBinding(words[0], get, &attributes); ok do append(&bindings, binding)
		}
		clear(&a.data.bindings)
		append(&a.data.bindings, ..bindings[:])
		set += 1
	}
	return set
}

/*
Keeps every action's bindings with the game's saves (save.odin's storage: a file in the player's
data folder, the browser's localStorage).

Returns:
- Whether it was written (failures are logged)
*/
Input_SaveBindings :: proc(slot := INPUT_BINDINGS_SLOT, game: ^Game = nil) -> bool {
	game := game != nil ? game : currentGame
	if game == nil do return false
	text := Input_FormatBindings(game, context.temp_allocator)
	if !Platform_SaveWrite(saveName(game, slot), transmute([]byte)text) {
		log.errorf("Couldn't save the input bindings (%s)", slot)
		return false
	}
	return true
}

/*
Loads bindings `Input_SaveBindings` kept (call it once the project is loaded).

Returns:
- false when there's none
*/
Input_LoadBindings :: proc(slot := INPUT_BINDINGS_SLOT, game: ^Game = nil) -> bool {
	game := game != nil ? game : currentGame
	if game == nil do return false
	data, ok := Platform_SaveRead(saveName(game, slot))
	if !ok do return false
	Input_ParseBindings(string(data), game)
	return true
}

/*
Rumbles gamepads (those that can; others ignore it).

Inputs:
- low, high: The low- and high-frequency motors' strength, 0 to 1
- seconds: How long (a new rumble replaces one still going)
- device: Which gamepad (0 the first connected); -1 all of them
- game: The game (nil: the one playing)

Returns:
- Whether any gamepad took it

Example:
	// A hit: a short, strong thump
	e.Input_Rumble(0.8, 0.4, 0.15)
*/
Input_Rumble :: proc(low, high: f32, seconds: f32, device := -1, game: ^Game = nil) -> bool {
	input := inputOf(game)
	if input == nil do return false
	took := false
	for &pad, i in input.gamepads {
		if device >= 0 && i != device do continue
		if pad.handle == nil do continue
		strength :: proc(v: f32) -> u16 { return u16(clamp(v, 0, 1) * 65535) }
		if sdl.RumbleGamepad(pad.handle, strength(low), strength(high), u32(max(seconds, 0) * 1000)) do took = true
	}
	return took
}

// Input_Update while capturing: this frame's first new input, if any
@(private)
captureInput :: proc(input: ^InputState) {
	capture := &input.capture
	done :: proc(capture: ^InputCapture, binding: InputBinding) {
		capture.binding = binding
		capture.state = .Done
	}
	for key in Key do if input.keysPressed[key] {
		done(capture, KeyBinding{key})
		return
	}
	for button in MouseButton do if input.mousePressed[button] {
		done(capture, MouseBinding{button})
		return
	}
	for &pad, i in input.gamepads {
		device := capture.anyDevice ? -1 : i
		for button in GamepadButton do if pad.pressed[button] {
			done(capture, GamepadButtonBinding{button, device})
			return
		}
		for axis in GamepadAxis {
			value := pad.axes[axis]
			rest := i < len(capture.baseline) ? capture.baseline[i][axis] : 0
			if abs(value) >= INPUT_CAPTURE_AXIS && abs(rest) < INPUT_CAPTURE_AXIS {
				done(capture, GamepadAxisBinding{axis, value < 0 ? -1 : 1, device})
				return
			}
		}
	}
}
