#+build !js
package crossfire

import "core:slice"
import "core:testing"
import sdl "vendor:sdl3"

// Local players (players.odin): joining with a device, per-player actions, unplugging and
// plugging back, leaving, the join action, split-screen rectangles, project files

@(private="file")
key :: proc(scancode: sdl.Scancode, down: bool) -> sdl.Event {
	event: sdl.Event
	event.type = down ? .KEY_DOWN : .KEY_UP
	event.key.scancode = scancode
	event.key.down = down
	return event
}

@(private="file")
pad :: proc(id: sdl.JoystickID, button: sdl.GamepadButton, down: bool) -> sdl.Event {
	event: sdl.Event
	event.type = down ? .GAMEPAD_BUTTON_DOWN : .GAMEPAD_BUTTON_UP
	event.gbutton.which = id
	event.gbutton.button = u8(button)
	event.gbutton.down = down
	return event
}

@(private="file")
stick :: proc(id: sdl.JoystickID, axis: sdl.GamepadAxis, value: i16) -> sdl.Event {
	event: sdl.Event
	event.type = .GAMEPAD_AXIS_MOTION
	event.gaxis.which = id
	event.gaxis.axis = u8(axis)
	event.gaxis.value = value
	return event
}

// A connected pad without SDL's device (tests can't open one)
@(private="file")
plugIn :: proc(game: ^Game, id: sdl.JoystickID) {
	if game.input.gamepads == nil do game.input.gamepads = make([dynamic]GamepadState)
	append(&game.input.gamepads, GamepadState{id = id})
	playersGamepadAdded(&game.input, id)
}

@(private="file")
unplug :: proc(game: ^Game, id: sdl.JoystickID) {
	if i := gamepadIndex(&game.input, id); i >= 0 do ordered_remove(&game.input.gamepads, i)
	playersGamepadRemoved(&game.input, id)
}

@(private="file")
frame :: proc(game: ^Game, events: ..sdl.Event) {
	Input_Update(&game.input, events)
}

@(private="file")
PlayerEvents :: struct {
	joined, left, disconnected, reconnected: [dynamic]int,
}

@(private="file")
record :: proc(list: ^[dynamic]int) -> proc(event: ^EventSubject, source: rawptr, data: EventData, user: rawptr) {
	return proc(event: ^EventSubject, source: rawptr, data: EventData, user: rawptr) {
		append(cast(^[dynamic]int)user, data.(int))
	}
}

@(test)
local_players_join_and_play_apart :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	Input_AddAction("jump", KeyBinding{.Space}, GamepadButtonBinding{.South, 0}, game = game)
	Input_AddAction("right", KeyBinding{.D}, GamepadAxisBinding{.LeftX, 1, -1}, game = game)
	Players_Setup(game, {maxPlayers = 3, keyboard = true})
	events: PlayerEvents
	defer { delete(events.joined); delete(events.left); delete(events.disconnected); delete(events.reconnected) }
	p := &game.input.players
	Event_Subscribe(&p.onJoined, record(nil), &events.joined)
	Event_Subscribe(&p.onLeft, record(nil), &events.left)
	Event_Subscribe(&p.onDisconnected, record(nil), &events.disconnected)
	Event_Subscribe(&p.onReconnected, record(nil), &events.reconnected)
	plugIn(game, 10)
	plugIn(game, 20)

	// Not joining: presses join nobody
	frame(game, pad(10, .SOUTH, true))
	frame(game, pad(10, .SOUTH, false))
	testing.expect_value(t, Players_Count(game), 0)

	// The lobby: pad 20's A, then the keyboard's Enter, then pad 10's Start
	Players_StartJoining(game)
	testing.expect(t, Players_IsJoining(game), "joining")
	frame(game, pad(20, .SOUTH, true))
	testing.expect_value(t, Players_Count(game), 1)
	testing.expect_value(t, Players_Get(0, game).gamepad, sdl.JoystickID(20))
	// Pressing again doesn't join it twice
	frame(game, pad(20, .SOUTH, false))
	frame(game, pad(20, .SOUTH, true))
	frame(game, pad(20, .SOUTH, false))
	testing.expect_value(t, Players_Count(game), 1)
	frame(game, key(.RETURN, true))
	frame(game, key(.RETURN, false))
	testing.expect_value(t, Players_Get(1, game).device, PlayerDeviceKind.Keyboard)
	testing.expect_value(t, Player_DeviceName(1, game), "Keyboard")
	frame(game, pad(10, .START, true))
	frame(game, pad(10, .START, false))
	testing.expect_value(t, Players_Count(game), 3)
	testing.expect(t, slice.equal(events.joined[:], []int{0, 1, 2}), "joined")
	// Full: a fourth device can't join
	testing.expect_value(t, Players_Join(.Gamepad, 0, game), -1)
	Players_StopJoining(game)

	// Each reads its own device. Pad 20's A: player 0 jumps (the binding's device 0 is ignored:
	// the player's own pad), not 2; the game-wide action sees it
	frame(game, pad(20, .SOUTH, true))
	testing.expect(t, Player_IsActionJustPressed(0, "jump", game), "player 0 jumps")
	testing.expect(t, !Player_IsActionPressed(2, "jump", game), "player 2 doesn't")
	testing.expect(t, !Player_IsActionPressed(1, "jump", game), "nor the keyboard player")
	frame(game, pad(20, .SOUTH, false))
	testing.expect(t, Player_IsActionJustReleased(0, "jump", game), "released")
	// The keyboard player: D and Space
	frame(game, key(.D, true), key(.SPACE, true))
	testing.expect_value(t, Player_GetActionStrength(1, "right", game), 1)
	testing.expect(t, Player_IsActionPressed(1, "jump", game), "the keyboard player jumps")
	testing.expect(t, !Player_IsActionPressed(0, "jump", game) && !Player_IsActionPressed(2, "jump", game), "the pads' players don't")
	frame(game, key(.D, false), key(.SPACE, false))
	// Pad 10's stick: player 2, past the deadzone, rescaled
	frame(game, stick(10, .LEFTX, 32767))
	testing.expect_value(t, Player_GetVector(2, "right", "right", "jump", "jump", game).x, 0)
	testing.expect_value(t, Player_GetAxis(2, "jump", "right", game), 1)
	testing.expect_value(t, Player_GetActionStrength(0, "right", game), 0)

	// Unplugged: player 2 stays, silent; the next pad plugged in goes back to it
	unplug(game, 10)
	frame(game)
	testing.expect_value(t, Players_Count(game), 3)
	testing.expect(t, !Players_Get(2, game).connected, "unplugged")
	testing.expect_value(t, Player_DeviceName(2, game), "(unplugged)")
	testing.expect_value(t, Player_GetActionStrength(2, "right", game), 0)
	testing.expect(t, slice.equal(events.disconnected[:], []int{2}), "disconnected")
	plugIn(game, 30)
	frame(game, pad(30, .SOUTH, true))
	testing.expect(t, Players_Get(2, game).connected && Players_Get(2, game).gamepad == 30, "back on the new pad")
	testing.expect(t, Player_IsActionPressed(2, "jump", game), "and it plays")
	testing.expect(t, slice.equal(events.reconnected[:], []int{2}), "reconnected")
	frame(game, pad(30, .SOUTH, false))

	// Leaving: later players move down a number
	Players_Leave(0, game)
	testing.expect_value(t, Players_Count(game), 2)
	testing.expect_value(t, Players_Get(0, game).device, PlayerDeviceKind.Keyboard)
	testing.expect_value(t, Players_Get(1, game).index, 1)
	testing.expect(t, slice.equal(events.left[:], []int{0}), "left")
	// An action added later: players get it too
	Input_AddAction("fire", KeyBinding{.F}, game = game)
	frame(game, key(.F, true))
	testing.expect(t, Player_IsActionPressed(0, "fire", game), "a new action")
	Players_Clear(game)
	testing.expect_value(t, Players_Count(game), 0)
}

@(test)
local_players_join_action_and_settings :: proc(t: ^testing.T) {
	project, err := ParseProject(`<project formatVersion="13" name="P"><players max="2" keyboard="false" joinAction="join"/></project>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, project.players.maxPlayers, 2)
	testing.expect(t, !project.players.keyboard, "no keyboard")
	testing.expect_value(t, project.players.joinAction, "join")
	plain, _ := ParseProject(`<project formatVersion="13" name="P"/>`)
	defer ProjectData_Destroy(&plain)
	testing.expect_value(t, plain.players, DEFAULT_PLAYER_SETTINGS)

	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	Input_AddAction("join", KeyBinding{.J}, GamepadButtonBinding{.North, -1}, game = game)
	Players_Setup(game, project.players)
	plugIn(game, 1)
	Players_StartJoining(game)
	// The default buttons don't join with a join action set; North (its binding) does
	frame(game, pad(1, .SOUTH, true))
	testing.expect_value(t, Players_Count(game), 0)
	frame(game, pad(1, .SOUTH, false), pad(1, .NORTH, true))
	testing.expect_value(t, Players_Count(game), 1)
	// The keyboard isn't a device here: J joins nobody, nor does code
	frame(game, key(.J, true))
	testing.expect_value(t, Players_Count(game), 1)
	testing.expect_value(t, Players_Join(.Keyboard, game = game), -1)
}

@(test)
split_screen_rectangles :: proc(t: ^testing.T) {
	area := [2]f32{1280, 720}
	testing.expect_value(t, SplitScreen_Rect(0, 1, area), sdl.FRect{0, 0, 1280, 720})
	testing.expect_value(t, SplitScreen_Rect(1, 2, area, 10), sdl.FRect{645, 0, 635, 720})
	testing.expect_value(t, SplitScreen_Rect(0, 3, area), sdl.FRect{0, 0, 1280, 360})
	testing.expect_value(t, SplitScreen_Rect(2, 3, area), sdl.FRect{640, 360, 640, 360})
	testing.expect_value(t, SplitScreen_Rect(3, 4, area), sdl.FRect{640, 360, 640, 360})
	// Six: a 3 x 2 grid
	r := SplitScreen_Rect(5, 6, {1200, 600})
	testing.expect_value(t, r, sdl.FRect{800, 300, 400, 300})
}
