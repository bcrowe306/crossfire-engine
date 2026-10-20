#+build !js
package crossfire

import "core:testing"
import sdl "vendor:sdl3"

// Menu tests: navigation by keys (no actions), by the ui_* actions (a fake gamepad), repeats,
// every item kind, the mouse

@(private="file")
keyDown :: proc(scancode: sdl.Scancode, repeat := false) -> sdl.Event {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = scancode
	event.key.down = true
	event.key.repeat = repeat
	return event
}

@(private="file")
pad :: proc(button: sdl.GamepadButton, down: bool) -> sdl.Event {
	event: sdl.Event
	event.type = down ? .GAMEPAD_BUTTON_DOWN : .GAMEPAD_BUTTON_UP
	event.gbutton.which = 7
	event.gbutton.button = u8(button)
	event.gbutton.down = down
	return event
}

@(private="file")
Pressed :: struct {
	presses, changes, backs: int,
}

// The test's counts (menus have no user data; tests run on their own threads)
@(private="file", thread_local)
pressedNow: ^Pressed

@(private="file")
makeMenu :: proc(scene: ^Scene, pressed: ^Pressed) -> ^Menu {
	menu := CreateMenu(scene, {200, 0})
	onPress :: proc(menu: ^Menu, _: ^MenuItem) { pressedNow.presses += 1 }
	onChange :: proc(menu: ^Menu, _: ^MenuItem) { pressedNow.changes += 1 }
	pressedNow = pressed
	Menu_AddLabel(menu, "Title")
	Menu_AddButton(menu, "Play", onPress)
	Menu_AddCheckbox(menu, "Music", false, onChange)
	Menu_AddSlider(menu, "Volume", 0.5, 0, 1, 0.1, onChange)
	Menu_AddSelect(menu, "Size", {"Small", "Large"}, 0, onChange)
	menu.onBack = proc(menu: ^Menu, _: ^MenuItem) { pressedNow.backs += 1 }
	return menu
}

@(test)
menus_navigate_by_keys :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	pressed: Pressed
	menu := makeMenu(scene, &pressed)
	Scene_ProcessQueues(scene)
	update :: proc(menu: ^Menu, events: ..sdl.Event) { Menu_update(menu, events, 1.0 / 60) }

	testing.expect_value(t, menu.focused, 1) // the label can't take focus
	update(menu, keyDown(.RETURN))
	testing.expect_value(t, pressed.presses, 1)
	update(menu, keyDown(.RETURN, repeat = true))
	testing.expect_value(t, pressed.presses, 1) // held keys don't press again
	update(menu, keyDown(.DOWN))
	update(menu, keyDown(.SPACE))
	testing.expect(t, menu.items[2].checked && pressed.changes == 1, "the checkbox toggled")
	update(menu, keyDown(.S))
	update(menu, keyDown(.RIGHT))
	testing.expectf(t, abs(menu.items[3].value - 0.6) < 0.001, "the slider stepped: %v", menu.items[3].value)
	update(menu, keyDown(.A), keyDown(.A))
	testing.expectf(t, abs(menu.items[3].value - 0.4) < 0.001, "and back: %v", menu.items[3].value)
	// The select's dropdown takes navigation until it closes
	update(menu, keyDown(.DOWN), keyDown(.RETURN))
	testing.expect(t, menu.popupOpen && menu.popupHover == 0, "opened")
	update(menu, keyDown(.DOWN), keyDown(.RETURN))
	testing.expect(t, !menu.popupOpen && menu.items[4].selectedOption == 1, "picked Large")
	// Focus wraps past the end (skipping the label)
	update(menu, keyDown(.DOWN))
	testing.expect_value(t, menu.focused, 1)
	update(menu, keyDown(.UP))
	testing.expect_value(t, menu.focused, 4)
	update(menu, keyDown(.ESCAPE))
	testing.expect_value(t, pressed.backs, 1)

	// Menu_Command does the same from code
	testing.expect(t, !Menu_Command(menu, .Down), "moving isn't a press")
	testing.expect_value(t, menu.focused, 1)
	testing.expect(t, Menu_Command(menu, .Accept), "a button press says so")
	testing.expect_value(t, pressed.presses, 2)
}

@(test)
menus_navigate_by_actions_and_gamepads :: proc(t: ^testing.T) {
	game: Game
	defer {
		Input_Destroy(&game.input)
		if game.arenaReady do MemoryArena_Destroy(&game.arena)
	}
	Input_AddAction(MENU_ACTION_UP, KeyBinding{.Up}, GamepadButtonBinding{.DpadUp, -1}, game = &game)
	Input_AddAction(MENU_ACTION_DOWN, KeyBinding{.Down}, GamepadButtonBinding{.DpadDown, -1}, game = &game)
	Input_AddAction(MENU_ACTION_LEFT, GamepadButtonBinding{.DpadLeft, -1}, game = &game)
	Input_AddAction(MENU_ACTION_RIGHT, GamepadButtonBinding{.DpadRight, -1}, game = &game)
	Input_AddAction(MENU_ACTION_ACCEPT, GamepadButtonBinding{.South, -1}, game = &game)
	Input_AddAction(MENU_ACTION_CANCEL, GamepadButtonBinding{.East, -1}, game = &game)
	game.input.gamepads = make([dynamic]GamepadState)
	append(&game.input.gamepads, GamepadState{id = 7})

	scene := new(Scene)
	Scene_Init(scene)
	scene.game = &game
	defer { Scene_Destroy(scene); free(scene) }
	pressed: Pressed
	menu := makeMenu(scene, &pressed)
	Scene_ProcessQueues(scene)
	frame :: proc(game: ^Game, menu: ^Menu, dt: f64, events: ..sdl.Event) {
		Input_Update(&game.input, events)
		Menu_update(menu, events, dt)
	}

	frame(&game, menu, 1.0 / 60, pad(.SOUTH, true))
	testing.expect_value(t, pressed.presses, 1)
	frame(&game, menu, 1.0 / 60, pad(.SOUTH, false))
	// W isn't bound to ui_down here: with actions the menu follows them, not its own keys
	frame(&game, menu, 1.0 / 60, keyDown(.S))
	testing.expect_value(t, menu.focused, 1)
	frame(&game, menu, 1.0 / 60, pad(.DPAD_DOWN, true))
	testing.expect_value(t, menu.focused, 2)
	// Held: nothing until MENU_REPEAT_DELAY, then every MENU_REPEAT_INTERVAL
	frame(&game, menu, 0.3)
	testing.expect_value(t, menu.focused, 2)
	frame(&game, menu, 0.11)
	testing.expect_value(t, menu.focused, 3)
	frame(&game, menu, MENU_REPEAT_INTERVAL)
	testing.expect_value(t, menu.focused, 4)
	frame(&game, menu, 1.0 / 60, pad(.DPAD_DOWN, false))
	frame(&game, menu, 1)
	testing.expect_value(t, menu.focused, 4)
	// Right cycles the select; East goes back
	frame(&game, menu, 1.0 / 60, pad(.DPAD_RIGHT, true))
	testing.expect_value(t, menu.items[4].selectedOption, 1)
	frame(&game, menu, 1.0 / 60, pad(.DPAD_RIGHT, false), pad(.EAST, true))
	testing.expect_value(t, pressed.backs, 1)
	// Keys bound to the actions work too
	frame(&game, menu, 1.0 / 60, pad(.EAST, false), keyDown(.UP))
	testing.expect_value(t, menu.focused, 3)
}

@(test)
menus_follow_the_mouse :: proc(t: ^testing.T) {
	scene := new(Scene)
	Scene_Init(scene)
	defer { Scene_Destroy(scene); free(scene) }
	pressed: Pressed
	menu := makeMenu(scene, &pressed)
	Scene_ProcessQueues(scene)

	middle :: proc(menu: ^Menu, index: int) -> [2]f32 {
		r := menuItemRect(menu, index)
		return Node_GetScreenPosition(menu) + {r.x + r.w * 0.5, r.y + r.h * 0.5}
	}
	motion :: proc(at: [2]f32) -> sdl.Event {
		event: sdl.Event
		event.type = .MOUSE_MOTION
		event.motion.x, event.motion.y = at.x, at.y
		return event
	}
	click :: proc(at: [2]f32, down: bool) -> sdl.Event {
		event: sdl.Event
		event.type = down ? .MOUSE_BUTTON_DOWN : .MOUSE_BUTTON_UP
		event.button.button = sdl.BUTTON_LEFT
		event.button.x, event.button.y = at.x, at.y
		return event
	}
	Menu_update(menu, {motion(middle(menu, 2))}, 0)
	testing.expect_value(t, menu.focused, 2)
	Menu_update(menu, {motion(middle(menu, 0))}, 0)
	testing.expect_value(t, menu.focused, 2) // the label doesn't take focus
	Menu_update(menu, {click(middle(menu, 1), true), click(middle(menu, 1), false)}, 0)
	testing.expect(t, pressed.presses == 1 && menu.focused == 1, "clicked Play")
	// Dragging the slider's track sets its value
	track := menuSliderTrack(menu, 3)
	origin := Node_GetScreenPosition(menu)
	Menu_update(menu, {click(origin + {track.x + track.w, track.y}, true)}, 0)
	testing.expectf(t, menu.items[3].value == 1 && menu.dragging == 3, "jumped to the end: %v", menu.items[3].value)
	Menu_update(menu, {motion(origin + {track.x, track.y}), click(origin + {track.x, track.y}, false)}, 0)
	testing.expect(t, menu.items[3].value == 0 && menu.dragging == -1, "dragged to the start")
}
