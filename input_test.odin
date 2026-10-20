#+build !js
package crossfire

import "core:testing"
import sdl "vendor:sdl3"

// Input tests: synthetic SDL events into a game's input state (no window, no devices)

@(private="file")
key :: proc(scancode: sdl.Scancode, down: bool, repeat := false) -> sdl.Event {
	event: sdl.Event
	event.type = down ? .KEY_DOWN : .KEY_UP
	event.key.scancode = scancode
	event.key.down = down
	event.key.repeat = repeat
	return event
}

@(private="file")
mouseButton :: proc(button: u8, down: bool, position: [2]f32) -> sdl.Event {
	event: sdl.Event
	event.type = down ? .MOUSE_BUTTON_DOWN : .MOUSE_BUTTON_UP
	event.button.button = button
	event.button.down = down
	event.button.x, event.button.y = position.x, position.y
	return event
}

// A connected pad without SDL's device (tests can't open one)
@(private="file")
fakeGamepad :: proc(game: ^Game, id: sdl.JoystickID) {
	if game.input.gamepads == nil do game.input.gamepads = make([dynamic]GamepadState)
	append(&game.input.gamepads, GamepadState{id = id})
}

@(private="file")
padEvent :: proc(id: sdl.JoystickID, button: sdl.GamepadButton, down: bool) -> sdl.Event {
	event: sdl.Event
	event.type = down ? .GAMEPAD_BUTTON_DOWN : .GAMEPAD_BUTTON_UP
	event.gbutton.which = id
	event.gbutton.button = u8(button)
	event.gbutton.down = down
	return event
}

@(private="file")
axisEvent :: proc(id: sdl.JoystickID, axis: sdl.GamepadAxis, value: i16) -> sdl.Event {
	event: sdl.Event
	event.type = .GAMEPAD_AXIS_MOTION
	event.gaxis.which = id
	event.gaxis.axis = u8(axis)
	event.gaxis.value = value
	return event
}

// The input and the game's memory (a test game has no window or resources for Game_Destroy)
@(private="file")
freeGame :: proc(game: ^Game) {
	Input_Destroy(&game.input)
	if game.arenaReady do MemoryArena_Destroy(&game.arena)
}

@(private="file")
frame :: proc(game: ^Game, events: ..sdl.Event) {
	Input_Update(&game.input, events)
}

@(test)
keys_mouse_and_wheel_state :: proc(t: ^testing.T) {
	game: Game
	defer freeGame(&game)
	frame(&game, key(.SPACE, true))
	testing.expect(t, Input_IsKeyPressed(.Space, &game) && Input_IsKeyJustPressed(.Space, &game), "down and just pressed")
	frame(&game, key(.SPACE, true, repeat = true))
	testing.expect(t, Input_IsKeyPressed(.Space, &game) && !Input_IsKeyJustPressed(.Space, &game), "held: a repeat isn't a press")
	frame(&game, key(.SPACE, false))
	testing.expect(t, !Input_IsKeyPressed(.Space, &game) && Input_IsKeyJustReleased(.Space, &game), "released")
	frame(&game)
	testing.expect(t, !Input_IsKeyJustReleased(.Space, &game), "only for a frame")

	frame(&game, mouseButton(3, true, {100, 50}))
	testing.expect(t, Input_IsMouseButtonJustPressed(.Right, &game), "right button")
	testing.expect_value(t, Input_GetMousePosition(&game), [2]f32{100, 50})
	motion: sdl.Event
	motion.type = .MOUSE_MOTION
	motion.motion.x, motion.motion.y = 110, 40
	frame(&game, motion)
	testing.expect_value(t, Input_GetMouseMotion(&game), [2]f32{10, -10})
	testing.expect(t, Input_IsMouseButtonPressed(.Right, &game), "still held")

	wheel: sdl.Event
	wheel.type = .MOUSE_WHEEL
	wheel.wheel.y = 1
	frame(&game, wheel)
	testing.expect(t, Input_IsMouseButtonJustPressed(.WheelUp, &game), "wheel up is a button")
	testing.expect_value(t, Input_GetMouseWheel(&game).y, 1)
	frame(&game)
	testing.expect(t, !Input_IsMouseButtonPressed(.WheelUp, &game) && Input_IsMouseButtonJustReleased(.WheelUp, &game), "for one frame")

	// Losing focus lets everything go
	frame(&game, key(.A, true))
	focus: sdl.Event
	focus.type = .WINDOW_FOCUS_LOST
	frame(&game, focus)
	testing.expect(t, !Input_IsKeyPressed(.A, &game) && Input_IsKeyJustReleased(.A, &game), "released on focus loss")
}

@(test)
actions_from_keys_buttons_and_sticks :: proc(t: ^testing.T) {
	game: Game
	defer freeGame(&game)
	jump := InputActionData{name = "jump", deadzone = 0.5}
	append(&jump.bindings, KeyBinding{.Space}, MouseBinding{.Left}, GamepadButtonBinding{.South, -1})
	left := InputActionData{name = "left", deadzone = 0.2}
	append(&left.bindings, KeyBinding{.Left}, GamepadAxisBinding{.LeftX, -1, -1})
	right := InputActionData{name = "right", deadzone = 0.2}
	append(&right.bindings, KeyBinding{.Right}, GamepadAxisBinding{.LeftX, 1, -1})
	up := InputActionData{name = "up", deadzone = 0.2}
	append(&up.bindings, KeyBinding{.Up})
	down := InputActionData{name = "down", deadzone = 0.2}
	append(&down.bindings, KeyBinding{.Down})
	Input_SetActions(&game, {jump, left, right, up, down})
	for a in ([]InputActionData{jump, left, right, up, down}) do delete(a.bindings)

	// Any binding: a key, then a gamepad button (on any pad)
	frame(&game, key(.SPACE, true))
	testing.expect(t, Input_IsActionJustPressed("jump", &game) && Input_IsActionPressed("jump", &game), "key")
	testing.expect_value(t, Input_GetActionStrength("jump", &game), 1)
	fakeGamepad(&game, 7)
	frame(&game, padEvent(7, .SOUTH, true))
	testing.expect(t, Input_IsActionPressed("jump", &game) && !Input_IsActionJustPressed("jump", &game), "still held: no second press")
	frame(&game, key(.SPACE, false))
	testing.expect(t, Input_IsActionPressed("jump", &game), "the button still holds it")
	frame(&game, padEvent(7, .SOUTH, false))
	testing.expect(t, Input_IsActionJustReleased("jump", &game), "released when the last binding lets go")
	testing.expect(t, Input_IsGamepadButtonJustReleased(.South, 0, &game), "raw button")

	// Sticks: nothing inside the deadzone, then strength rescaled past it
	frame(&game, axisEvent(7, .LEFTX, -3000))
	testing.expect(t, !Input_IsActionPressed("left", &game), "inside the deadzone")
	frame(&game, axisEvent(7, .LEFTX, -32767))
	testing.expectf(t, abs(Input_GetActionStrength("left", &game) - 1) < 0.001, "full: %v", Input_GetActionStrength("left", &game))
	testing.expectf(t, abs(Input_GetAxis("left", "right", &game) + 1) < 0.001, "axis: %v", Input_GetAxis("left", "right", &game))
	testing.expectf(t, abs(Input_GetGamepadAxis(.LeftX, 0, &game) + 1) < 0.001, "raw axis")
	frame(&game, axisEvent(7, .LEFTX, 0), key(.RIGHT, true), key(.DOWN, true))
	v := Input_GetVector("left", "right", "up", "down", &game)
	testing.expectf(t, abs(v.x - 0.7071) < 0.001 && abs(v.y - 0.7071) < 0.001, "diagonals aren't faster: %v", v)

	// Unknown actions: false (and a warning, once)
	testing.expect(t, !Input_HasAction("fly", &game), "unknown")
	testing.expect(t, Input_HasAction("jump", &game), "known")
	// Actions added in code
	Input_AddAction("dash", KeyBinding{.LeftShift}, game = &game)
	frame(&game, key(.LSHIFT, true))
	testing.expect(t, Input_IsActionJustPressed("dash", &game), "code action")
}

@(test)
actions_in_project_files :: proc(t: ^testing.T) {
	text := `<project formatVersion="8" name="P">
		<action name="jump" deadzone="0.3">
			<key key="Space"/>
			<mouse button="Left"/>
			<gamepad button="South"/>
			<axis axis="LeftY" direction="-1" device="1"/>
			<key key="NoSuchKey"/>
			<wiimote button="A"/>
		</action>
		<action name="pause"><key key="Escape"/></action>
	</project>`
	project, err := ParseProject(text)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, len(project.actions), 2)
	jump := project.actions[0]
	testing.expect_value(t, jump.deadzone, 0.3)
	testing.expect_value(t, len(jump.bindings), 4) // Unknown ones skipped
	testing.expect_value(t, jump.bindings[3], InputBinding(GamepadAxisBinding{.LeftY, -1, 1}))
	testing.expect_value(t, project.actions[1].deadzone, DEFAULT_ACTION_DEADZONE)

	// Formatting gives back what was parsed
	element, attrs := FormatInputBinding(jump.bindings[3])
	testing.expect_value(t, element, "axis")
	testing.expect_value(t, len(attrs), 3)
	testing.expect_value(t, InputBinding_Describe(jump.bindings[3]), "Gamepad 2 LeftY −")
	testing.expect_value(t, InputBinding_Describe(jump.bindings[1]), "Mouse Left")
}
