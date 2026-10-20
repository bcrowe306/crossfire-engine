#+build !js
package engine

import "core:testing"
import sdl "vendor:sdl3"

@(private="file")
keyEvent :: proc(scancode: sdl.Scancode, down: bool) -> sdl.Event {
	event: sdl.Event
	event.type = down ? .KEY_DOWN : .KEY_UP
	event.key.scancode = scancode
	event.key.down = down
	return event
}

@(private="file")
padButton :: proc(id: sdl.JoystickID, button: sdl.GamepadButton, down: bool) -> sdl.Event {
	event: sdl.Event
	event.type = down ? .GAMEPAD_BUTTON_DOWN : .GAMEPAD_BUTTON_UP
	event.gbutton.which = id
	event.gbutton.button = u8(button)
	event.gbutton.down = down
	return event
}

@(private="file")
padAxis :: proc(id: sdl.JoystickID, axis: sdl.GamepadAxis, value: i16) -> sdl.Event {
	event: sdl.Event
	event.type = .GAMEPAD_AXIS_MOTION
	event.gaxis.which = id
	event.gaxis.axis = u8(axis)
	event.gaxis.value = value
	return event
}

@(private="file")
rebindGame :: proc(game: ^Game) {
	Input_AddAction("jump", KeyBinding{.Space}, game = game)
	Input_AddAction("accept", KeyBinding{.Enter}, GamepadButtonBinding{.South, -1}, game = game)
	game.input.gamepads = make([dynamic]GamepadState)
	append(&game.input.gamepads, GamepadState{id = 3}, GamepadState{id = 4})
}

@(private="file")
endGame :: proc(game: ^Game) {
	Input_Destroy(&game.input)
	if game.arenaReady do MemoryArena_Destroy(&game.arena)
}

@(test)
input_captures_the_next_input :: proc(t: ^testing.T) {
	game: Game
	defer endGame(&game)
	rebindGame(&game)
	frame :: proc(game: ^Game, events: ..sdl.Event) { Input_Update(&game.input, events) }

	Input_StartCapture(game = &game)
	testing.expect(t, Input_IsCapturing(&game), "waiting")
	frame(&game)
	_, got := Input_GetCapturedBinding(&game)
	testing.expect(t, !got, "nothing yet")
	// Enter is bound to accept: captured, and accept doesn't press
	frame(&game, keyEvent(.RETURN, true))
	binding, ok := Input_GetCapturedBinding(&game)
	testing.expect(t, ok && binding == InputBinding(KeyBinding{.Enter}), "Enter captured")
	testing.expect(t, !Input_IsActionJustPressed("accept", &game), "the captured press doesn't act")
	_, again := Input_GetCapturedBinding(&game)
	testing.expect(t, !again && !Input_IsCapturing(&game), "handed out once")
	frame(&game)
	testing.expect(t, Input_IsActionPressed("accept", &game) && !Input_IsActionJustPressed("accept", &game), "held, but no press after the capture either")
	frame(&game, keyEvent(.RETURN, false))
	frame(&game, keyEvent(.RETURN, true))
	testing.expect(t, Input_IsActionJustPressed("accept", &game), "a new press acts")

	// Gamepad buttons: any gamepad, or the one used
	Input_StartCapture(game = &game)
	frame(&game, padButton(4, .WEST, true))
	binding, _ = Input_GetCapturedBinding(&game)
	testing.expect_value(t, binding, InputBinding(GamepadButtonBinding{.West, -1}))
	Input_StartCapture(anyDevice = false, game = &game)
	frame(&game, padButton(4, .NORTH, true))
	binding, _ = Input_GetCapturedBinding(&game)
	testing.expect_value(t, binding, InputBinding(GamepadButtonBinding{.North, 1}))

	// A stick resting pushed isn't captured; one pushed now is, with its direction
	frame(&game, padAxis(3, .LEFTX, 30000))
	Input_StartCapture(game = &game)
	frame(&game, padAxis(3, .LEFTX, 32000))
	testing.expect(t, Input_IsCapturing(&game), "the resting stick doesn't count")
	frame(&game, padAxis(3, .LEFTY, -20000))
	binding, _ = Input_GetCapturedBinding(&game)
	testing.expect_value(t, binding, InputBinding(GamepadAxisBinding{.LeftY, -1, -1}))

	// Cancelling
	Input_StartCapture(game = &game)
	Input_CancelCapture(&game)
	frame(&game, keyEvent(.A, true))
	_, got = Input_GetCapturedBinding(&game)
	testing.expect(t, !got, "cancelled")
}

@(test)
input_bindings_change_reset_and_keep :: proc(t: ^testing.T) {
	game: Game
	defer endGame(&game)
	rebindGame(&game)

	testing.expect(t, Input_SetBindings("jump", {KeyBinding{.W}, GamepadButtonBinding{.South, -1}}, &game), "set")
	testing.expect(t, !Input_SetBindings("nope", {KeyBinding{.W}}, &game), "no such action")
	testing.expect_value(t, len(Input_GetBindings("jump", &game)), 2)
	using_ := Input_ActionsUsing(GamepadButtonBinding{.South, -1}, &game)
	testing.expect(t, len(using_) == 2 && using_[0] == "jump" && using_[1] == "accept", "South is on both")
	Input_Update(&game.input, {keyEvent(.W, true)})
	testing.expect(t, Input_IsActionJustPressed("jump", &game), "the new binding works")

	text := Input_FormatBindings(&game, context.temp_allocator)
	testing.expect_value(t, text, "jump = key key=W | gamepad button=South\naccept = key key=Enter | gamepad button=South\n")
	Input_ResetBindings(&game)
	testing.expect(t, len(Input_GetBindings("jump", &game)) == 1 && Input_GetBindings("jump", &game)[0] == InputBinding(KeyBinding{.Space}), "reset")

	// Read back; unknown actions and bindings are skipped, unlisted actions keep theirs
	set := Input_ParseBindings("jump = key key=W | axis axis=LeftX direction=-1 device=1 | key key=NoSuchKey\nmissing = key key=A\n", &game)
	testing.expect_value(t, set, 1)
	jump := Input_GetBindings("jump", &game)
	testing.expect(t, len(jump) == 2 && jump[1] == InputBinding(GamepadAxisBinding{.LeftX, -1, 1}), "parsed")
	testing.expect_value(t, len(Input_GetBindings("accept", &game)), 2)

	// Through the save storage
	game.name = "Engine Test Bindings"
	testing.expect(t, Input_SaveBindings(game = &game), "saved")
	Input_ResetBindings(&game)
	testing.expect(t, Input_LoadBindings(game = &game), "loaded")
	testing.expect_value(t, len(Input_GetBindings("jump", &game)), 2)
	Save_Delete(INPUT_BINDINGS_SLOT, &game)
	testing.expect(t, !Input_LoadBindings(game = &game), "none after deleting")

	// Fake gamepads have no device to rumble
	testing.expect(t, !Input_Rumble(1, 1, 0.2, game = &game), "nothing took it")
	free_all(context.temp_allocator)
}
