package engine

import "core:log"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

/*
Input: the keyboard, mouse and gamepads as state a script can ask about, and **actions**: named
inputs ("jump", "move_left") that any of several keys, mouse buttons, gamepad buttons or stick
directions trigger, like Godot's input map. Scripts ask about actions, so players can remap them
and one game runs on a keyboard or a gamepad without code changes:

	update = proc(self: ^Player, _: []sdl.Event, dt: f64) {
		move := e.Input_GetVector("move_left", "move_right", "move_up", "move_down")
		self.node.position += move * 200 * f32(dt)
		if e.Input_IsActionJustPressed("jump") do jump(self)
	}

Projects define their actions in project.xml (the editor's Project Settings > Input):

	<action name="jump" deadzone="0.5">
		<key key="Space"/>
		<mouse button="Left"/>
		<gamepad button="South"/>
		<axis axis="LeftY" direction="-1"/>
	</action>

- `Pressed`: held down now. `JustPressed` / `JustReleased`: this frame only (a key's repeats
  don't count). `Strength`: 0 to 1 (1 for keys and buttons; how far a stick or trigger is pushed,
  0 inside the action's `deadzone`).
- Raw state without actions: `Input_IsKeyPressed(.Space)`, `Input_IsMouseButtonJustPressed(.Left)`,
  `Input_GetMousePosition()` (game coordinates), `Input_GetGamepadAxis(.LeftX)`... The engine's
  own `Key`, `MouseButton`, `GamepadButton` and `GamepadAxis` enums name them; SDL isn't needed.
  The SDL events passed to `update` are still there for code that wants them.
- Gamepads are numbered from 0 in the order they're connected; device -1 means any of them.
- The game's `input` is updated at the start of every frame (`Game_Update`), before globals and
  scenes. Procedures use the game that's playing (like `Global`) unless given one.
*/

// A keyboard key, by position (a US layout's names). Values are SDL scancodes
Key :: enum i32 {
	Unknown = 0,
	A = i32(sdl.Scancode.A), B = i32(sdl.Scancode.B), C = i32(sdl.Scancode.C), D = i32(sdl.Scancode.D),
	E = i32(sdl.Scancode.E), F = i32(sdl.Scancode.F), G = i32(sdl.Scancode.G), H = i32(sdl.Scancode.H),
	I = i32(sdl.Scancode.I), J = i32(sdl.Scancode.J), K = i32(sdl.Scancode.K), L = i32(sdl.Scancode.L),
	M = i32(sdl.Scancode.M), N = i32(sdl.Scancode.N), O = i32(sdl.Scancode.O), P = i32(sdl.Scancode.P),
	Q = i32(sdl.Scancode.Q), R = i32(sdl.Scancode.R), S = i32(sdl.Scancode.S), T = i32(sdl.Scancode.T),
	U = i32(sdl.Scancode.U), V = i32(sdl.Scancode.V), W = i32(sdl.Scancode.W), X = i32(sdl.Scancode.X),
	Y = i32(sdl.Scancode.Y), Z = i32(sdl.Scancode.Z),
	Num1 = i32(sdl.Scancode._1), Num2 = i32(sdl.Scancode._2), Num3 = i32(sdl.Scancode._3), Num4 = i32(sdl.Scancode._4),
	Num5 = i32(sdl.Scancode._5), Num6 = i32(sdl.Scancode._6), Num7 = i32(sdl.Scancode._7), Num8 = i32(sdl.Scancode._8),
	Num9 = i32(sdl.Scancode._9), Num0 = i32(sdl.Scancode._0),
	Enter = i32(sdl.Scancode.RETURN), Escape = i32(sdl.Scancode.ESCAPE), Backspace = i32(sdl.Scancode.BACKSPACE),
	Tab = i32(sdl.Scancode.TAB), Space = i32(sdl.Scancode.SPACE),
	Minus = i32(sdl.Scancode.MINUS), Equals = i32(sdl.Scancode.EQUALS), LeftBracket = i32(sdl.Scancode.LEFTBRACKET),
	RightBracket = i32(sdl.Scancode.RIGHTBRACKET), Backslash = i32(sdl.Scancode.BACKSLASH), Semicolon = i32(sdl.Scancode.SEMICOLON),
	Apostrophe = i32(sdl.Scancode.APOSTROPHE), Grave = i32(sdl.Scancode.GRAVE), Comma = i32(sdl.Scancode.COMMA),
	Period = i32(sdl.Scancode.PERIOD), Slash = i32(sdl.Scancode.SLASH), CapsLock = i32(sdl.Scancode.CAPSLOCK),
	F1 = i32(sdl.Scancode.F1), F2 = i32(sdl.Scancode.F2), F3 = i32(sdl.Scancode.F3), F4 = i32(sdl.Scancode.F4),
	F5 = i32(sdl.Scancode.F5), F6 = i32(sdl.Scancode.F6), F7 = i32(sdl.Scancode.F7), F8 = i32(sdl.Scancode.F8),
	F9 = i32(sdl.Scancode.F9), F10 = i32(sdl.Scancode.F10), F11 = i32(sdl.Scancode.F11), F12 = i32(sdl.Scancode.F12),
	PrintScreen = i32(sdl.Scancode.PRINTSCREEN), ScrollLock = i32(sdl.Scancode.SCROLLLOCK), Pause = i32(sdl.Scancode.PAUSE),
	Insert = i32(sdl.Scancode.INSERT), Home = i32(sdl.Scancode.HOME), PageUp = i32(sdl.Scancode.PAGEUP),
	Delete = i32(sdl.Scancode.DELETE), End = i32(sdl.Scancode.END), PageDown = i32(sdl.Scancode.PAGEDOWN),
	Right = i32(sdl.Scancode.RIGHT), Left = i32(sdl.Scancode.LEFT), Down = i32(sdl.Scancode.DOWN), Up = i32(sdl.Scancode.UP),
	NumLock = i32(sdl.Scancode.NUMLOCKCLEAR), KeypadDivide = i32(sdl.Scancode.KP_DIVIDE), KeypadMultiply = i32(sdl.Scancode.KP_MULTIPLY),
	KeypadMinus = i32(sdl.Scancode.KP_MINUS), KeypadPlus = i32(sdl.Scancode.KP_PLUS), KeypadEnter = i32(sdl.Scancode.KP_ENTER),
	Keypad1 = i32(sdl.Scancode.KP_1), Keypad2 = i32(sdl.Scancode.KP_2), Keypad3 = i32(sdl.Scancode.KP_3),
	Keypad4 = i32(sdl.Scancode.KP_4), Keypad5 = i32(sdl.Scancode.KP_5), Keypad6 = i32(sdl.Scancode.KP_6),
	Keypad7 = i32(sdl.Scancode.KP_7), Keypad8 = i32(sdl.Scancode.KP_8), Keypad9 = i32(sdl.Scancode.KP_9),
	Keypad0 = i32(sdl.Scancode.KP_0), KeypadPeriod = i32(sdl.Scancode.KP_PERIOD),
	LeftCtrl = i32(sdl.Scancode.LCTRL), LeftShift = i32(sdl.Scancode.LSHIFT), LeftAlt = i32(sdl.Scancode.LALT),
	LeftSuper = i32(sdl.Scancode.LGUI), RightCtrl = i32(sdl.Scancode.RCTRL), RightShift = i32(sdl.Scancode.RSHIFT),
	RightAlt = i32(sdl.Scancode.RALT), RightSuper = i32(sdl.Scancode.RGUI),
}

// A mouse button. The wheel's four directions count as buttons pressed for the frame it turns
MouseButton :: enum {
	Left,
	Middle,
	Right,
	// The back side button (SDL's X1)
	Back,
	// The forward side button (SDL's X2)
	Forward,
	// The wheel turned up (away from the player), for one frame
	WheelUp,
	WheelDown,
	WheelLeft,
	WheelRight,
}

// A gamepad button, by position (South is Xbox A, PlayStation Cross, Nintendo B). Values are SDL's
GamepadButton :: enum i32 {
	South = i32(sdl.GamepadButton.SOUTH),
	East = i32(sdl.GamepadButton.EAST),
	West = i32(sdl.GamepadButton.WEST),
	North = i32(sdl.GamepadButton.NORTH),
	Back = i32(sdl.GamepadButton.BACK),
	Guide = i32(sdl.GamepadButton.GUIDE),
	Start = i32(sdl.GamepadButton.START),
	LeftStick = i32(sdl.GamepadButton.LEFT_STICK),
	RightStick = i32(sdl.GamepadButton.RIGHT_STICK),
	LeftShoulder = i32(sdl.GamepadButton.LEFT_SHOULDER),
	RightShoulder = i32(sdl.GamepadButton.RIGHT_SHOULDER),
	DpadUp = i32(sdl.GamepadButton.DPAD_UP),
	DpadDown = i32(sdl.GamepadButton.DPAD_DOWN),
	DpadLeft = i32(sdl.GamepadButton.DPAD_LEFT),
	DpadRight = i32(sdl.GamepadButton.DPAD_RIGHT),
	Misc = i32(sdl.GamepadButton.MISC1),
	Touchpad = i32(sdl.GamepadButton.TOUCHPAD),
}

// A gamepad stick axis (-1 to 1; down and right are positive) or trigger (0 to 1). Values are SDL's
GamepadAxis :: enum i32 {
	LeftX = i32(sdl.GamepadAxis.LEFTX),
	LeftY = i32(sdl.GamepadAxis.LEFTY),
	RightX = i32(sdl.GamepadAxis.RIGHTX),
	RightY = i32(sdl.GamepadAxis.RIGHTY),
	LeftTrigger = i32(sdl.GamepadAxis.LEFT_TRIGGER),
	RightTrigger = i32(sdl.GamepadAxis.RIGHT_TRIGGER),
}

// What triggers an action
InputBinding :: union {
	KeyBinding,
	MouseBinding,
	GamepadButtonBinding,
	GamepadAxisBinding,
}

// A keyboard key triggers the action
KeyBinding :: struct {
	// The key
	key: Key,
}

// A mouse button (or a wheel direction) triggers the action
MouseBinding :: struct {
	// The button
	button: MouseButton,
}

// A gamepad button triggers the action
GamepadButtonBinding :: struct {
	// The button
	button: GamepadButton,
	// Which gamepad (0 the first connected); -1 any
	device: int,
}

// A stick or trigger pushed one way: `direction` +1 (right, down, pressed) or -1 (left, up)
GamepadAxisBinding :: struct {
	// The stick axis or trigger
	axis: GamepadAxis,
	// +1 (right, down, pressed) or -1 (left, up)
	direction: f32,
	// Which gamepad (0 the first connected); -1 any
	device: int,
}

// The deadzone actions get unless they set one: how far a stick must move to count
DEFAULT_ACTION_DEADZONE :: 0.5

// A named input and what triggers it: project.xml's `<action>` (format version 8)
InputActionData :: struct {
	// The action's name, as scripts ask for it ("jump")
	name: string,
	// Sticks and triggers below this count as not pressed
	deadzone: f32,
	// What triggers it: any one of them
	bindings: [dynamic]InputBinding,
}

// A connected gamepad's state
@(private)
GamepadState :: struct {
	id: sdl.JoystickID,
	handle: ^sdl.Gamepad,
	down, pressed, released: #sparse[GamepadButton]bool,
	axes: [GamepadAxis]f32,
}

// An action's state this frame
@(private)
ActionState :: struct {
	data: InputActionData,
	// The bindings it started with (project.xml, Input_AddAction): Input_ResetBindings
	defaults: [dynamic]InputBinding,
	strength: f32,
	down, pressed, released: bool,
}

// The game's input: what's held, what changed this frame, and the actions (Game.input)
InputState :: struct {
	// Keys held, gone down this frame, and let go this frame
	keys, keysPressed, keysReleased: #sparse[Key]bool,
	// Mouse buttons held, gone down this frame, and let go this frame
	mouse, mousePressed, mouseReleased: [MouseButton]bool,
	// Where the mouse is, in game coordinates (the app converts window positions)
	mousePosition: [2]f32,
	// How far it moved this frame, in game coordinates
	mouseMotion: [2]f32,
	// This frame's wheel turn (y up positive, x right positive)
	wheel: [2]f32,
	// The connected gamepads, in the order they connected (their index is the device number)
	gamepads: [dynamic]GamepadState,
	// The actions and their state this frame (`Input_SetActions`, `Input_AddAction`)
	actions: [dynamic]ActionState,
	// Unknown action names already reported, so a typo warns once (owned keys)
	warned: map[string]bool,
	// Waiting for the next input to bind (input_rebind.odin)
	capture: InputCapture,
}

/*
Sets the game's actions (replacing any): Game_LoadProject does this with the project's. Names,
bindings and the list are copied into the game's memory; the bindings also become each action's
defaults (`Input_ResetBindings`).

Inputs:
- game: The game
- actions: The actions
*/
Input_SetActions :: proc(game: ^Game, actions: []InputActionData) {
	input := &game.input
	allocator := Game_GetAllocator(game)
	input.actions = make([dynamic]ActionState, 0, len(actions), allocator)
	for a in actions {
		data := InputActionData{name = strings.clone(a.name, allocator), deadzone = a.deadzone, bindings = make([dynamic]InputBinding, 0, len(a.bindings), allocator)}
		append(&data.bindings, ..a.bindings[:])
		defaults := make([dynamic]InputBinding, 0, len(a.bindings), allocator)
		append(&defaults, ..a.bindings[:])
		append(&input.actions, ActionState{data = data, defaults = defaults})
	}
}

/*
Adds an action from code, or more bindings to one that exists (its deadzone then stays). The
bindings also become part of its defaults (`Input_ResetBindings`).

Inputs:
- name: The action's name (copied)
- bindings: What triggers it
- deadzone: How far a stick or trigger must move to count (0 to 1), for a new action
- game: The game (nil: the one playing)

Example:
	e.Input_AddAction("dash", e.KeyBinding{.LeftShift}, e.GamepadButtonBinding{.East, -1})
*/
Input_AddAction :: proc(name: string, bindings: ..InputBinding, deadzone: f32 = DEFAULT_ACTION_DEADZONE, game: ^Game = nil) {
	game := game != nil ? game : currentGame
	if game == nil do return
	allocator := Game_GetAllocator(game)
	if game.input.actions == nil do game.input.actions = make([dynamic]ActionState, allocator)
	for &a in game.input.actions {
		if a.data.name == name {
			append(&a.data.bindings, ..bindings)
			append(&a.defaults, ..bindings)
			return
		}
	}
	data := InputActionData{name = strings.clone(name, allocator), deadzone = deadzone, bindings = make([dynamic]InputBinding, allocator)}
	append(&data.bindings, ..bindings)
	defaults := make([dynamic]InputBinding, allocator)
	append(&defaults, ..bindings)
	append(&game.input.actions, ActionState{data = data, defaults = defaults})
}

/*
Tells whether the game has an action by that name (without warning when it doesn't).

Inputs:
- name: The action's name
- game: The game (nil: the one playing)

Returns:
- true if it exists
*/
Input_HasAction :: proc(name: string, game: ^Game = nil) -> bool {
	return findAction(game, name, warn = false) != nil
}

/*
Tells whether an action is held: any of its bindings is down (a stick past its deadzone). An
unknown name logs a warning once and counts as not pressed.

Inputs:
- name: The action's name
- game: The game (nil: the one playing)

Returns:
- true while it's held

Example:
	if e.Input_IsActionPressed("fire") do log.info("firing")
*/
Input_IsActionPressed :: proc(name: string, game: ^Game = nil) -> bool {
	a := findAction(game, name)
	return a != nil && a.down
}

/*
Tells whether an action went down this frame. Not while an input is being captured for
rebinding (input_rebind.odin).

Inputs:
- name: The action's name
- game: The game (nil: the one playing)

Returns:
- true on the frame it was pressed

Example:
	if e.Input_IsActionJustPressed("jump") do log.info("jump")
*/
Input_IsActionJustPressed :: proc(name: string, game: ^Game = nil) -> bool {
	a := findAction(game, name)
	return a != nil && a.pressed
}

/*
Tells whether an action was let go this frame. Not while an input is being captured for
rebinding (input_rebind.odin).

Inputs:
- name: The action's name
- game: The game (nil: the one playing)

Returns:
- true on the frame it was released
*/
Input_IsActionJustReleased :: proc(name: string, game: ^Game = nil) -> bool {
	a := findAction(game, name)
	return a != nil && a.released
}

/*
How hard an action is pressed: the strongest of its bindings.

Inputs:
- name: The action's name
- game: The game (nil: the one playing)

Returns:
- 0 to 1: 1 for keys and buttons, a stick's or trigger's travel past the deadzone (rescaled so it starts at 0 there); 0 for an unknown action
*/
Input_GetActionStrength :: proc(name: string, game: ^Game = nil) -> f32 {
	a := findAction(game, name)
	return a != nil ? a.strength : 0
}

/*
One axis from two actions: positive's strength minus negative's.

Inputs:
- negative: The action for -1 (left, up)
- positive: The action for +1 (right, down)
- game: The game (nil: the one playing)

Returns:
- -1 to 1

Example:
	steer := e.Input_GetAxis("turn_left", "turn_right")
*/
Input_GetAxis :: proc(negative, positive: string, game: ^Game = nil) -> f32 {
	return Input_GetActionStrength(positive, game) - Input_GetActionStrength(negative, game)
}

/*
A direction from four actions (x right, y down), at most 1 long: diagonals aren't faster.

Inputs:
- negativeX: The action for left
- positiveX: The action for right
- negativeY: The action for up
- positiveY: The action for down
- game: The game (nil: the one playing)

Returns:
- The direction, each axis -1 to 1, length at most 1

Example:
	// Given: speed: f32
	velocity := e.Input_GetVector("move_left", "move_right", "move_up", "move_down") * speed
	node.position += velocity * f32(dt)
*/
Input_GetVector :: proc(negativeX, positiveX, negativeY, positiveY: string, game: ^Game = nil) -> [2]f32 {
	v := [2]f32{Input_GetAxis(negativeX, positiveX, game), Input_GetAxis(negativeY, positiveY, game)}
	length := math.sqrt(v.x * v.x + v.y * v.y)
	return length > 1 ? v / length : v
}

/*
Tells whether a key is held.

Inputs:
- key: The key
- game: The game (nil: the one playing)

Returns:
- true while it's down

Example:
	if e.Input_IsKeyPressed(.LeftShift) do log.info("running")
*/
Input_IsKeyPressed :: proc(key: Key, game: ^Game = nil) -> bool {
	input := inputOf(game)
	return input != nil && input.keys[key]
}

/*
Tells whether a key went down this frame (its repeats don't count).

Inputs:
- key: The key
- game: The game (nil: the one playing)

Returns:
- true on the frame it was pressed

Example:
	if e.Input_IsKeyJustPressed(.Escape) do log.info("pause")
*/
Input_IsKeyJustPressed :: proc(key: Key, game: ^Game = nil) -> bool {
	input := inputOf(game)
	return input != nil && input.keysPressed[key]
}

/*
Tells whether a key was let go this frame (or the window lost focus while it was held).

Inputs:
- key: The key
- game: The game (nil: the one playing)

Returns:
- true on the frame it was released
*/
Input_IsKeyJustReleased :: proc(key: Key, game: ^Game = nil) -> bool {
	input := inputOf(game)
	return input != nil && input.keysReleased[key]
}

/*
Tells whether a mouse button is held. A wheel direction counts as held on the frame the wheel turns.

Inputs:
- button: The button
- game: The game (nil: the one playing)

Returns:
- true while it's down
*/
Input_IsMouseButtonPressed :: proc(button: MouseButton, game: ^Game = nil) -> bool {
	input := inputOf(game)
	return input != nil && input.mouse[button]
}

/*
Tells whether a mouse button went down this frame (a wheel direction: the wheel turned this frame).

Inputs:
- button: The button
- game: The game (nil: the one playing)

Returns:
- true on the frame it was pressed

Example:
	if e.Input_IsMouseButtonJustPressed(.Left) do log.infof("click at %v", e.Input_GetMousePosition())
*/
Input_IsMouseButtonJustPressed :: proc(button: MouseButton, game: ^Game = nil) -> bool {
	input := inputOf(game)
	return input != nil && input.mousePressed[button]
}

/*
Tells whether a mouse button was let go this frame (a wheel direction: the frame after it turned).

Inputs:
- button: The button
- game: The game (nil: the one playing)

Returns:
- true on the frame it was released
*/
Input_IsMouseButtonJustReleased :: proc(button: MouseButton, game: ^Game = nil) -> bool {
	input := inputOf(game)
	return input != nil && input.mouseReleased[button]
}

/*
Where the mouse is, in game coordinates (`Scene_ScreenToWorld` gives the world point under it).

Inputs:
- game: The game (nil: the one playing)

Returns:
- The position in game coordinates (zero without a game)
*/
Input_GetMousePosition :: proc(game: ^Game = nil) -> [2]f32 {
	input := inputOf(game)
	return input != nil ? input.mousePosition : {}
}

/*
How far the mouse moved this frame.

Inputs:
- game: The game (nil: the one playing)

Returns:
- The movement in game coordinates
*/
Input_GetMouseMotion :: proc(game: ^Game = nil) -> [2]f32 {
	input := inputOf(game)
	return input != nil ? input.mouseMotion : {}
}

/*
How far the wheel turned this frame.

Inputs:
- game: The game (nil: the one playing)

Returns:
- The turn: y positive up, x positive right (SDL's wheel units)
*/
Input_GetMouseWheel :: proc(game: ^Game = nil) -> [2]f32 {
	input := inputOf(game)
	return input != nil ? input.wheel : {}
}

/*
How many gamepads are connected (devices 0 to the count minus 1).

Inputs:
- game: The game (nil: the one playing)

Returns:
- The count
*/
Input_GamepadCount :: proc(game: ^Game = nil) -> int {
	input := inputOf(game)
	return input != nil ? len(input.gamepads) : 0
}

/*
Tells whether a gamepad button is held.

Inputs:
- button: The button
- device: Which gamepad (0 the first connected); -1 any
- game: The game (nil: the one playing)

Returns:
- true while it's down (false for a device that isn't connected)
*/
Input_IsGamepadButtonPressed :: proc(button: GamepadButton, device := -1, game: ^Game = nil) -> bool {
	for &pad in gamepadsOf(game, device) do if pad.down[button] do return true
	return false
}

/*
Tells whether a gamepad button went down this frame.

Inputs:
- button: The button
- device: Which gamepad (0 the first connected); -1 any
- game: The game (nil: the one playing)

Returns:
- true on the frame it was pressed

Example:
	if e.Input_IsGamepadButtonJustPressed(.Start) do log.info("pause")
*/
Input_IsGamepadButtonJustPressed :: proc(button: GamepadButton, device := -1, game: ^Game = nil) -> bool {
	for &pad in gamepadsOf(game, device) do if pad.pressed[button] do return true
	return false
}

/*
Tells whether a gamepad button was let go this frame.

Inputs:
- button: The button
- device: Which gamepad (0 the first connected); -1 any
- game: The game (nil: the one playing)

Returns:
- true on the frame it was released
*/
Input_IsGamepadButtonJustReleased :: proc(button: GamepadButton, device := -1, game: ^Game = nil) -> bool {
	for &pad in gamepadsOf(game, device) do if pad.released[button] do return true
	return false
}

/*
A gamepad's stick axis or trigger, raw (no deadzone).

Inputs:
- axis: The stick axis or trigger
- device: Which gamepad (0 the first connected, the default); -1 the one pushed furthest
- game: The game (nil: the one playing)

Returns:
- -1 to 1 for a stick (down and right positive), 0 to 1 for a trigger; 0 for a device that isn't connected

Example:
	aim := [2]f32{e.Input_GetGamepadAxis(.RightX), e.Input_GetGamepadAxis(.RightY)}
	_ = aim
*/
Input_GetGamepadAxis :: proc(axis: GamepadAxis, device := 0, game: ^Game = nil) -> f32 {
	value: f32
	for &pad in gamepadsOf(game, device) do if abs(pad.axes[axis]) > abs(value) do value = pad.axes[axis]
	return value
}

/*
Starts a frame: forgets last frame's presses and releases, applies this frame's events, and works
out every action. Game_Update calls it; call it yourself only for input outside a game loop.

Inputs:
- input: The input state (usually `&game.input`)
- events: This frame's SDL events
*/
Input_Update :: proc(input: ^InputState, events: []sdl.Event) {
	input.keysPressed, input.keysReleased = {}, {}
	input.mousePressed, input.mouseReleased = {}, {}
	input.mouseMotion, input.wheel = {}, {}
	for wheel in ([4]MouseButton{.WheelUp, .WheelDown, .WheelLeft, .WheelRight}) {
		if input.mouse[wheel] do input.mouseReleased[wheel] = true
		input.mouse[wheel] = false
	}
	for &pad in input.gamepads do pad.pressed, pad.released = {}, {}

	for &event in events {
		#partial switch event.type {
		case .KEY_DOWN, .KEY_UP:
			key := Key(i32(event.key.scancode))
			if !validKey(key) do continue
			if event.type == .KEY_DOWN {
				if !event.key.repeat && !input.keys[key] do input.keysPressed[key] = true
				input.keys[key] = true
			} else {
				if input.keys[key] do input.keysReleased[key] = true
				input.keys[key] = false
			}
		case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
			button, ok := mouseButtonOf(event.button.button)
			if !ok do continue
			input.mousePosition = {event.button.x, event.button.y}
			if event.type == .MOUSE_BUTTON_DOWN {
				if !input.mouse[button] do input.mousePressed[button] = true
				input.mouse[button] = true
			} else {
				if input.mouse[button] do input.mouseReleased[button] = true
				input.mouse[button] = false
			}
		case .MOUSE_MOTION:
			position := [2]f32{event.motion.x, event.motion.y}
			input.mouseMotion += position - input.mousePosition
			input.mousePosition = position
		case .MOUSE_WHEEL:
			input.wheel += {event.wheel.x, event.wheel.y}
			turned :: proc(input: ^InputState, button: MouseButton) {
				input.mouse[button] = true
				input.mousePressed[button] = true
			}
			if event.wheel.y > 0 do turned(input, .WheelUp)
			if event.wheel.y < 0 do turned(input, .WheelDown)
			if event.wheel.x < 0 do turned(input, .WheelLeft)
			if event.wheel.x > 0 do turned(input, .WheelRight)
		case .GAMEPAD_ADDED:
			if gamepadIndex(input, event.gdevice.which) >= 0 do continue
			handle := sdl.OpenGamepad(event.gdevice.which)
			if handle == nil {
				log.warnf("Couldn't open a gamepad: %s", sdl.GetError())
				continue
			}
			if input.gamepads == nil do input.gamepads = make([dynamic]GamepadState)
			append(&input.gamepads, GamepadState{id = event.gdevice.which, handle = handle})
			log.infof("Gamepad %d connected: %s", len(input.gamepads) - 1, sdl.GetGamepadName(handle))
		case .GAMEPAD_REMOVED:
			if i := gamepadIndex(input, event.gdevice.which); i >= 0 {
				sdl.CloseGamepad(input.gamepads[i].handle)
				ordered_remove(&input.gamepads, i)
			}
		case .GAMEPAD_BUTTON_DOWN, .GAMEPAD_BUTTON_UP:
			i := gamepadIndex(input, event.gbutton.which)
			button := GamepadButton(event.gbutton.button)
			if i < 0 || !validGamepadButton(button) do continue
			pad := &input.gamepads[i]
			if event.gbutton.down {
				if !pad.down[button] do pad.pressed[button] = true
			} else if pad.down[button] {
				pad.released[button] = true
			}
			pad.down[button] = event.gbutton.down
		case .GAMEPAD_AXIS_MOTION:
			i := gamepadIndex(input, event.gaxis.which)
			axis := GamepadAxis(event.gaxis.axis)
			if i < 0 || axis < .LeftX || axis > .RightTrigger do continue
			input.gamepads[i].axes[axis] = math.clamp(f32(event.gaxis.value) / 32767, -1, 1)
		case .WINDOW_FOCUS_LOST:
			// Keys let go while another window had focus would stay down
			for key in Key do if input.keys[key] do input.keysReleased[key] = true
			input.keys = {}
			for button in MouseButton do if input.mouse[button] do input.mouseReleased[button] = true
			input.mouse = {}
		}
	}

	// While waiting for an input to bind, and on the frame it comes, actions follow what's held
	// but don't press or release: the press being bound doesn't also act (a menu's ui_accept)
	capturing := input.capture.state == .Waiting
	if capturing do captureInput(input)
	for &a in input.actions {
		strength: f32
		for binding in a.data.bindings do strength = max(strength, bindingStrength(input, binding, a.data.deadzone))
		down := strength > 0
		a.pressed = down && !a.down && !capturing
		a.released = !down && a.down && !capturing
		a.down = down
		a.strength = strength
	}
}

// Closes the gamepads (Game_Destroy)
@(private)
Input_Destroy :: proc(input: ^InputState) {
	for pad in input.gamepads do sdl.CloseGamepad(pad.handle)
	delete(input.gamepads)
	for name in input.warned do delete(name)
	delete(input.warned)
	input^ = {}
}

/*
A binding as project files store it: its element and attributes, e.g. `key key="Space"`,
`axis axis="LeftX" direction="-1"`. `ParseInputBinding` reads it back.

Inputs:
- binding: The binding

Returns:
- element: The element name ("key", "mouse", "gamepad", "axis")
- attributes: Its attributes as name / value pairs (temp allocated); device is left out when it is -1
*/
FormatInputBinding :: proc(binding: InputBinding) -> (element: string, attributes: []ScriptPropData) {
	list := make([dynamic]ScriptPropData, context.temp_allocator)
	device :: proc(list: ^[dynamic]ScriptPropData, d: int) {
		if d != -1 do append(list, ScriptPropData{"device", fmt_int(d)})
	}
	switch b in binding {
	case KeyBinding:
		element = "key"
		append(&list, ScriptPropData{"key", enumName(b.key)})
	case MouseBinding:
		element = "mouse"
		append(&list, ScriptPropData{"button", enumName(b.button)})
	case GamepadButtonBinding:
		element = "gamepad"
		append(&list, ScriptPropData{"button", enumName(b.button)})
		device(&list, b.device)
	case GamepadAxisBinding:
		element = "axis"
		append(&list, ScriptPropData{"axis", enumName(b.axis)}, ScriptPropData{"direction", b.direction < 0 ? "-1" : "1"})
		device(&list, b.device)
	}
	return element, list[:]
}

/*
Reads a binding element (`FormatInputBinding`'s). A missing device is -1 (any gamepad), a missing
direction +1.

Inputs:
- element: The element name ("key", "mouse", "gamepad", "axis")
- get: Returns an attribute's value by name, and whether it is there
- user: Passed to `get` (e.g. the XML element being read)

Returns:
- The binding, and false for an unknown element or value
*/
ParseInputBinding :: proc(element: string, get: proc(user: rawptr, key: string) -> (string, bool), user: rawptr) -> (InputBinding, bool) {
	attr :: proc(get: proc(user: rawptr, key: string) -> (string, bool), user: rawptr, key, default: string) -> string {
		value, found := get(user, key)
		return found ? value : default
	}
	deviceOf :: proc(text: string) -> int {
		n, ok := strconv.parse_int(text)
		return ok ? n : -1
	}
	switch element {
	case "key":
		key, ok := reflect.enum_from_name(Key, attr(get, user, "key", ""))
		if !ok || key == .Unknown do return nil, false
		return KeyBinding{key}, true
	case "mouse":
		button, ok := reflect.enum_from_name(MouseButton, attr(get, user, "button", ""))
		if !ok do return nil, false
		return MouseBinding{button}, true
	case "gamepad":
		button, ok := reflect.enum_from_name(GamepadButton, attr(get, user, "button", ""))
		if !ok do return nil, false
		return GamepadButtonBinding{button, deviceOf(attr(get, user, "device", "-1"))}, true
	case "axis":
		axis, ok := reflect.enum_from_name(GamepadAxis, attr(get, user, "axis", ""))
		if !ok do return nil, false
		direction: f32 = strings.has_prefix(attr(get, user, "direction", "1"), "-") ? -1 : 1
		return GamepadAxisBinding{axis, direction, deviceOf(attr(get, user, "device", "-1"))}, true
	}
	return nil, false
}

/*
A binding as a person reads it, for a controls menu: "Space", "Mouse Left", "Gamepad South",
"Gamepad LeftX −", "Gamepad 1 South" (one gamepad, numbered from 1).

Inputs:
- binding: The binding

Returns:
- The text (temp allocated, or a constant)
*/
InputBinding_Describe :: proc(binding: InputBinding) -> string {
	pad :: proc(device: int) -> string {
		return device < 0 ? "Gamepad" : strings.concatenate({"Gamepad ", fmt_int(device + 1)}, context.temp_allocator)
	}
	switch b in binding {
	case KeyBinding:           return enumName(b.key)
	case MouseBinding:         return strings.concatenate({"Mouse ", enumName(b.button)}, context.temp_allocator)
	case GamepadButtonBinding: return strings.concatenate({pad(b.device), " ", enumName(b.button)}, context.temp_allocator)
	case GamepadAxisBinding:   return strings.concatenate({pad(b.device), " ", enumName(b.axis), b.direction < 0 ? " −" : " +"}, context.temp_allocator)
	}
	return ""
}

// INTERNAL

@(private)
inputOf :: proc(game: ^Game) -> ^InputState {
	game := game != nil ? game : currentGame
	return game != nil ? &game.input : nil
}

// The gamepads a query looks at: one, or all for device -1 (temp allocated view)
@(private="file")
gamepadsOf :: proc(game: ^Game, device: int) -> []GamepadState {
	input := inputOf(game)
	if input == nil do return nil
	if device < 0 do return input.gamepads[:]
	if device >= len(input.gamepads) do return nil
	return input.gamepads[device:device + 1]
}

@(private)
findAction :: proc(game: ^Game, name: string, warn := true) -> ^ActionState {
	input := inputOf(game)
	if input == nil do return nil
	for &a in input.actions do if a.data.name == name do return &a
	if warn && !(name in input.warned) {
		input.warned[strings.clone(name)] = true
		log.warnf("No input action named '%s' (Project Settings > Input lists them)", name)
	}
	return nil
}

@(private="file")
bindingStrength :: proc(input: ^InputState, binding: InputBinding, deadzone: f32) -> f32 {
	switch b in binding {
	case KeyBinding:
		return input.keys[b.key] ? 1 : 0
	case MouseBinding:
		return input.mouse[b.button] ? 1 : 0
	case GamepadButtonBinding:
		for &pad in gamepadsIn(input, b.device) do if pad.down[b.button] do return 1
	case GamepadAxisBinding:
		best: f32
		for &pad in gamepadsIn(input, b.device) {
			value := pad.axes[b.axis] * b.direction
			if value <= deadzone do continue
			// Rescaled so the strength starts at 0 at the deadzone's edge
			best = max(best, math.clamp((value - deadzone) / max(1 - deadzone, 0.0001), 0, 1))
		}
		return best
	}
	return 0
}

@(private="file")
gamepadsIn :: proc(input: ^InputState, device: int) -> []GamepadState {
	if device < 0 do return input.gamepads[:]
	if device >= len(input.gamepads) do return nil
	return input.gamepads[device:device + 1]
}

@(private="file")
gamepadIndex :: proc(input: ^InputState, id: sdl.JoystickID) -> int {
	for pad, i in input.gamepads do if pad.id == id do return i
	return -1
}

@(private="file")
mouseButtonOf :: proc(sdlButton: u8) -> (MouseButton, bool) {
	switch sdlButton {
	case 1: return .Left, true
	case 2: return .Middle, true
	case 3: return .Right, true
	case 4: return .Back, true
	case 5: return .Forward, true
	}
	return .Left, false
}

@(private="file")
validKey :: proc(key: Key) -> bool {
	_, ok := reflect.enum_name_from_value(key)
	return ok && key != .Unknown
}

@(private="file")
validGamepadButton :: proc(button: GamepadButton) -> bool {
	_, ok := reflect.enum_name_from_value(button)
	return ok
}

@(private="file")
enumName :: proc(value: $E) -> string {
	name, _ := reflect.enum_name_from_value(value)
	return name
}

@(private="file")
fmt_int :: proc(n: int) -> string {
	buffer := make([]byte, 24, context.temp_allocator)
	return strconv.write_int(buffer, i64(n), 10)
}
