#+build !js
package crossfire

import "core:fmt"
import "core:math"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// UI controls (ui_controls.odin): layouts and anchors from a scene file, the mouse, keyboard
// focus and typing, scroll boxes, rich text, themes; sliders and check boxes (the mouse, keys,
// ui_* actions, disabled ones)

@(private="file")
UI_SCENE :: `<scene formatVersion="13" name="S">
	<node kind="Panel" name="Menu" anchor="Center" layout="Column" padding="10" spacing="5" align="Stretch">
		<node kind="Button" name="Play" text="Play" width="100" height="30" action="quit"/>
		<node kind="Button" name="Quit" text="Quit" width="80" height="30"/>
		<node kind="ProgressBar" name="Load" width="120" height="10" value="25" max="50"/>
	</node>
	<node kind="Panel" name="Bar" anchor="Bottom_Wide" margin="4" height="40" layout="Row" padding="0" spacing="0">
		<node kind="Button" name="A" width="50" height="40"/>
		<node kind="Button" name="B" height="40" expand="true"/>
	</node>
	<node kind="ProgressBar" name="Corner" anchor="Top_Right" x="-8" y="8" width="60" height="12"/>
	<node kind="TextField" name="Name" anchor="Top_Left" width="150" height="30" maxLength="5" placeholder="Name"/>
	<node kind="ScrollBox" name="List" anchor="Left" width="100" height="70" padding="0" spacing="0">
		<node kind="Button" name="R1" width="100" height="30"/>
		<node kind="Button" name="R2" width="100" height="30"/>
		<node kind="Button" name="R3" width="100" height="30"/>
	</node>
</scene>`

@(private="file")
mouseEvent :: proc(type: sdl.EventType, at: [2]f32) -> sdl.Event {
	event: sdl.Event
	event.type = type
	if type == .MOUSE_MOTION {
		event.motion.x, event.motion.y = at.x, at.y
	} else {
		event.button.button = sdl.BUTTON_LEFT
		event.button.x, event.button.y = at.x, at.y
		event.button.down = type == .MOUSE_BUTTON_DOWN
	}
	return event
}

@(private="file")
keyEvent :: proc(scancode: sdl.Scancode) -> sdl.Event {
	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = scancode
	event.key.down = true
	return event
}

@(private="file")
UIPresses :: struct {
	presses: int,
	submitted: string,
}

@(test)
ui_controls_lay_out_and_take_input :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.size = {400, 300}
	scene := game->createScene("S")
	data, err := ParseScene(UI_SCENE)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, data.nodes[0].ui.layout, UILayout.Column)
	testing.expect_value(t, data.nodes[3].ui.maxValue, f32(50))
	created := Scene_Build(scene, &data, "testdata")
	frame :: proc(game: ^Game, scene: ^Scene, events: ..sdl.Event) {
		Input_Update(&game.input, events)
		Scene_Update(scene, events, 1.0 / 60)
	}
	frame(game, scene)
	find :: proc(scene: ^Scene, name: string) -> ^Control { return cast(^Control)Scene_FindNode(scene, name) }
	rect :: proc(scene: ^Scene, name: string) -> sdl.FRect { return Control_GetRect(find(scene, name)) }
	_ = created

	// The column: 100 wide (its widest) + padding, buttons stretched across, centered on the screen
	menu := rect(scene, "Menu")
	testing.expect_value(t, menu, sdl.FRect{130, 100, 140, 100})
	testing.expect_value(t, rect(scene, "Play"), sdl.FRect{menu.x + 10, menu.y + 10, 120, 30})
	testing.expect_value(t, rect(scene, "Quit"), sdl.FRect{menu.x + 10, menu.y + 45, 120, 30})
	// The row across the bottom: B takes what A leaves
	testing.expect_value(t, rect(scene, "Bar"), sdl.FRect{4, 300 - 4 - 40, 392, 40})
	testing.expect_value(t, rect(scene, "B"), sdl.FRect{54, 256, 342, 40})
	// A corner, moved in by its offset
	testing.expect_value(t, rect(scene, "Corner"), sdl.FRect{400 - 60 - 8, 8, 60, 12})
	// The scroll box: the third row doesn't fit, so it's hidden
	testing.expect(t, !find(scene, "R2").clipped && find(scene, "R3").clipped, "R3 hidden")

	// A click on Quit (no action: only onPressed)
	presses := UIPresses{}
	play := cast(^Button)find(scene, "Play")
	Event_Subscribe(&play.onPressed, proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
		p := cast(^UIPresses)user
		p.presses += 1
	}, &presses)
	quit := cast(^Button)find(scene, "Quit")
	Event_Subscribe(&quit.onPressed, proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
		(cast(^UIPresses)user).presses += 10
	}, &presses)
	at := [2]f32{rect(scene, "Quit").x + 5, rect(scene, "Quit").y + 5}
	frame(game, scene, mouseEvent(.MOUSE_MOTION, at), mouseEvent(.MOUSE_BUTTON_DOWN, at))
	testing.expect(t, quit.pressed && quit.hovered, "pressed")
	frame(game, scene, mouseEvent(.MOUSE_BUTTON_UP, at))
	testing.expect_value(t, presses.presses, 10)
	testing.expect(t, Control_Focused(scene) == quit, "a click focuses")

	// The keyboard (no ui_* actions: the arrow keys): Up moves to Play, Enter presses it
	frame(game, scene, keyEvent(.UP))
	testing.expect(t, Control_Focused(scene) == play, "up to Play")
	frame(game, scene, keyEvent(.RETURN))
	testing.expect_value(t, presses.presses, 11)
	testing.expect(t, game.shouldQuit, "Play's action quits")
	game.shouldQuit = false

	// Typing: a click focuses the field; text, Backspace, the length limit, Enter
	name := cast(^TextField)find(scene, "Name")
	Event_Subscribe(&name.onSubmitted, proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
		(cast(^UIPresses)user).submitted = data.(string)
	}, &presses)
	at = {10, 10}
	frame(game, scene, mouseEvent(.MOUSE_MOTION, at), mouseEvent(.MOUSE_BUTTON_DOWN, at))
	frame(game, scene, mouseEvent(.MOUSE_BUTTON_UP, at))
	testing.expect(t, Control_Focused(scene) == name, "the field has focus")
	text: sdl.Event
	text.type = .TEXT_INPUT
	text.text.text = "Heroes!"
	frame(game, scene, text)
	testing.expect_value(t, name.text, "Heroe")
	frame(game, scene, keyEvent(.BACKSPACE), keyEvent(.LEFT), keyEvent(.BACKSPACE))
	testing.expect_value(t, name.text, "Heo")
	frame(game, scene, keyEvent(.RETURN))
	testing.expect_value(t, presses.submitted, "Heo")
	// A click elsewhere takes the focus away
	at = {200, 20}
	frame(game, scene, mouseEvent(.MOUSE_MOTION, at), mouseEvent(.MOUSE_BUTTON_DOWN, at))
	testing.expect(t, Control_Focused(scene) == nil, "no focus")

	// The wheel scrolls the list: R1 goes out, R3 comes in
	list := find(scene, "List")
	listRect := Control_GetRect(list)
	at = {listRect.x + 10, listRect.y + 10}
	wheel: sdl.Event
	wheel.type = .MOUSE_WHEEL
	wheel.wheel.y = -1
	frame(game, scene, mouseEvent(.MOUSE_MOTION, at), wheel)
	frame(game, scene)
	testing.expect(t, find(scene, "R1").clipped && !find(scene, "R3").clipped, "scrolled")

	// A progress bar's value stays in its range
	load := cast(^ProgressBar)find(scene, "Load")
	ProgressBar_SetValue(load, 80)
	testing.expect_value(t, load.settings.value, f32(50))

	// Moving a control: its offset (its position is the layout's)
	corner := find(scene, "Corner")
	corner.offset = {-20, 8}
	frame(game, scene)
	testing.expect_value(t, rect(scene, "Corner").x, f32(400 - 60 - 20))
	free_all(context.temp_allocator)
}

@(test)
ui_themes_and_rich_text :: proc(t: ^testing.T) {
	data, err := ParseTheme(`<theme formatVersion="13" font="fonts/x.ttf" textSize="28" buttonColor="#102030" nonsense="1"/>`)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect(t, data.font == "fonts/x.ttf" && data.theme.textSize == 28 && data.theme.buttonColor == {16, 32, 48, 255}, "parsed")
	testing.expect_value(t, data.theme.panelColor, DEFAULT_UI_THEME.panelColor)
	text := FormatTheme(data, context.temp_allocator)
	back, _ := ParseTheme(text)
	testing.expect(t, back.theme == data.theme && back.font == data.font, "round trip")
	delete(data.font)
	delete(back.font)
	testing.expect_value(t, FormatTheme({theme = DEFAULT_UI_THEME}, context.temp_allocator), fmt.tprintf("<theme formatVersion=\"%d\"/>\n", PROJECT_FORMAT_VERSION))
	testing.expect(t, !UITheme_Set(&data.theme, "textSize", "big"), "not a number")
	// The check mark's color: parsed, written when it isn't the default
	checked, _ := ParseTheme(`<theme formatVersion="14" checkColor="#ff8000"/>`)
	testing.expect_value(t, checked.theme.checkColor, sdl.Color{255, 128, 0, 255})
	checkedText := FormatTheme(checked, context.temp_allocator)
	testing.expect_value(t, checkedText, fmt.tprintf("<theme formatVersion=\"%d\" checkColor=\"#ff8000\"/>\n", PROJECT_FORMAT_VERSION))
	again, _ := ParseTheme(checkedText)
	testing.expect(t, again.theme == checked.theme, "the check mark's round trip")
	testing.expect_value(t, UITheme_Fields()[len(UITheme_Fields()) - 1].group, "Check boxes")
	testing.expect(t, len(UITheme_Fields()) > 10 && UITheme_Fields()[0].group == "Text", "fields")

	// Rich text: tags, wrapping (measured with SDL_ttf)
	sync.guard(&ttfLock)
	if ttf.WasInit() == 0 do ttf.Init()
	surface := sdl.CreateSurface(64, 64, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := new(Game)
	defer free(game)
	Game_Init(game, nil, renderer, nil)
	defer Game_Destroy(game)
	rm := &game.resourceManager
	lines := RichText_Layout(rm, "A [color=#ff0000]red[/color] word\nand [size=40]big[/size]", DEFAULT_FONT, 20, 0)
	testing.expect_value(t, len(lines.runs), 6)
	// "A ", "red" (red), " ", "word", then the second line: "and ", "big" (40 points)
	if len(lines.runs) == 6 {
		testing.expect_value(t, lines.runs[1].text, "red")
		testing.expect_value(t, lines.runs[1].color, sdl.Color{255, 0, 0, 255})
		testing.expect_value(t, lines.runs[2].color, sdl.Color{})
		testing.expect_value(t, lines.runs[4].text, "and ")
		testing.expect_value(t, lines.runs[4].at.x, f32(0))
		testing.expect(t, lines.runs[4].at.y > lines.runs[0].at.y, "a second line")
		testing.expect_value(t, lines.runs[5].size, f32(40))
	}
	narrow := RichText_Layout(rm, "one two three four", DEFAULT_FONT, 20, 60)
	testing.expect(t, narrow.size.x == 60 && narrow.size.y > 40, "wrapped onto lines")
	// Aligned: each line centered (or right) in the width, or in the widest line without one
	short := MeasureText(rm, "ab", DEFAULT_FONT, 20).x
	long := MeasureText(rm, "abcdef", DEFAULT_FONT, 20).x
	centered := RichText_Layout(rm, "ab\nabcdef", DEFAULT_FONT, 20, 200, .Center)
	testing.expect_value(t, centered.runs[0].at.x, math.round((200 - short) * 0.5))
	testing.expect_value(t, centered.runs[1].at.x, math.round((200 - long) * 0.5))
	right := RichText_Layout(rm, "ab \nabcdef", DEFAULT_FONT, 20, 0, .Right)
	testing.expect_value(t, right.size.x, long)
	testing.expect_value(t, right.runs[0].at.x, math.round(long - short))
	testing.expect_value(t, right.runs[1].at.x, f32(0))
	free_all(context.temp_allocator)
}

@(private="file")
OPTIONS_SCENE :: `<scene formatVersion="14" name="Options">
	<node kind="Panel" name="Options" anchor="Top_Left" layout="Column" padding="0" spacing="10">
		<node kind="Slider" name="Music" width="220" height="20" value="0.5" step="0.25"/>
		<node kind="Slider" name="Sfx" value="30" max="100" showValue="true"/>
		<node kind="CheckBox" name="Full" text="Fullscreen" checked="true"/>
		<node kind="CheckBox" name="Off" text="Off" disabled="true"/>
		<node kind="Slider" name="Locked" width="100" height="20" value="5" max="10" disabled="true"/>
		<node kind="ProgressBar" name="Bar" step="3" checked="true"/>
	</node>
</scene>`

@(private="file")
OptionEvents :: struct {
	values: [dynamic]f32,
	toggles: [dynamic]bool,
}

@(private="file")
uiFrame :: proc(game: ^Game, scene: ^Scene, events: ..sdl.Event) {
	Input_Update(&game.input, events)
	Scene_Update(scene, events, 1.0 / 60)
}

// A key pressed in one frame and released in the next
@(private="file")
uiKey :: proc(game: ^Game, scene: ^Scene, scancode: sdl.Scancode) {
	uiFrame(game, scene, keyEvent(scancode))
	up := keyEvent(scancode)
	up.type = .KEY_UP
	up.key.down = false
	uiFrame(game, scene, up)
}

@(private="file")
optionsGame :: proc(t: ^testing.T, data: ^SceneData) -> (^Game, ^Scene) {
	game := testGame("testdata")
	game.size = {400, 300}
	scene := game->createScene("Options")
	parsed, err := ParseScene(OPTIONS_SCENE)
	testing.expect_value(t, err, ProjectError.None)
	data^ = parsed
	Scene_Build(scene, data, "testdata")
	uiFrame(game, scene)
	return game, scene
}

@(private="file")
optionsListen :: proc(scene: ^Scene, events: ^OptionEvents) {
	for name in ([]string{"Music", "Sfx", "Locked"}) {
		s := cast(^Slider)Scene_FindNode(scene, name)
		Event_Subscribe(&s.onValueChanged, proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
			append(&(cast(^OptionEvents)user).values, data.(f32))
		}, events)
	}
	for name in ([]string{"Full", "Off"}) {
		b := cast(^CheckBox)Scene_FindNode(scene, name)
		Event_Subscribe(&b.onToggled, proc(_: ^EventSubject, _: rawptr, data: EventData, user: rawptr) {
			append(&(cast(^OptionEvents)user).toggles, data.(bool))
		}, events)
	}
}

@(test)
ui_sliders_and_check_boxes :: proc(t: ^testing.T) {
	// Check boxes measure their text with SDL_ttf
	sync.guard(&ttfLock)
	if ttf.WasInit() == 0 do ttf.Init()
	data: SceneData
	game, scene := optionsGame(t, &data)
	defer { Game_Destroy(game); free(game) }
	defer SceneData_Destroy(&data)
	events: OptionEvents
	defer { delete(events.values); delete(events.toggles) }
	optionsListen(scene, &events)
	find :: proc(scene: ^Scene, name: string) -> ^Control { return cast(^Control)Scene_FindNode(scene, name) }

	// Parsed: a slider's step, a check box's checked; not for other kinds
	testing.expect_value(t, data.nodes[1].ui.step, f32(0.25))
	testing.expect_value(t, data.nodes[2].ui.step, f32(0))
	testing.expect(t, data.nodes[3].ui.checked && !data.nodes[4].ui.checked, "checked")
	testing.expect(t, data.nodes[6].ui.step == 0 && !data.nodes[6].ui.checked, "a progress bar has no step or checked")

	// Built and laid out: the default slider 220 x 20, the check box its box, gap and text
	music, sfx := cast(^Slider)find(scene, "Music"), cast(^Slider)find(scene, "Sfx")
	full, off := cast(^CheckBox)find(scene, "Full"), cast(^CheckBox)find(scene, "Off")
	testing.expect_value(t, Control_GetRect(music), sdl.FRect{0, 0, 220, 20})
	sfxRect := Control_GetRect(sfx)
	testing.expect(t, sfxRect.y == 30 && sfxRect.h == 20 && sfxRect.w > 220, "the percentage's room right of the track")
	fullRect := Control_GetRect(full)
	side := math.round(DEFAULT_UI_THEME.textSize * 1.2)
	testing.expect(t, fullRect.y == 60 && fullRect.h >= side && fullRect.w > side + DEFAULT_UI_THEME.spacing + 40, "box, gap and text")
	testing.expect(t, full.settings.checked && music.settings.value == 0.5 && sfx.settings.value == 30, "values from the file")

	// A press sets the value from x, snapped to the step: the track runs from 10 to 210
	at := [2]f32{10 + 200 * 0.8, 10}
	uiFrame(game, scene, mouseEvent(.MOUSE_MOTION, at), mouseEvent(.MOUSE_BUTTON_DOWN, at))
	testing.expect_value(t, music.settings.value, f32(0.75))
	testing.expect(t, Control_Focused(scene) == music, "a press focuses")
	// Dragging follows it outside the slider, clamped to the range
	uiFrame(game, scene, mouseEvent(.MOUSE_MOTION, {-50, 80}))
	testing.expect_value(t, music.settings.value, f32(0))
	uiFrame(game, scene, mouseEvent(.MOUSE_MOTION, {500, 80}))
	testing.expect_value(t, music.settings.value, f32(1))
	uiFrame(game, scene, mouseEvent(.MOUSE_BUTTON_UP, {500, 80}))
	uiFrame(game, scene, mouseEvent(.MOUSE_MOTION, {60, 10}))
	testing.expect_value(t, music.settings.value, f32(1))
	testing.expect_value(t, len(events.values), 3)
	if len(events.values) == 3 do testing.expect(t, events.values[0] == 0.75 && events.values[1] == 0 && events.values[2] == 1, "the values sent")

	// The keys (no ui_* actions): Left and Right move the focused slider by its step
	clear(&events.values)
	uiKey(game, scene, .LEFT)
	testing.expect_value(t, music.settings.value, f32(0.75))
	uiKey(game, scene, .RIGHT)
	uiKey(game, scene, .RIGHT)
	testing.expect_value(t, music.settings.value, f32(1))
	testing.expect_value(t, len(events.values), 2)
	testing.expect(t, Control_Focused(scene) == music, "left and right keep the focus")
	// Down still moves the focus; a slider without a step moves 1/20 of its range
	uiKey(game, scene, .DOWN)
	testing.expect(t, Control_Focused(scene) == sfx, "down to Sfx")
	uiKey(game, scene, .RIGHT)
	testing.expect_value(t, sfx.settings.value, f32(35))
	uiKey(game, scene, .UP)
	testing.expect(t, Control_Focused(scene) == music, "up to Music")

	// The check box: accepted (Enter, Space) and clicked
	uiKey(game, scene, .DOWN)
	uiKey(game, scene, .DOWN)
	testing.expect(t, Control_Focused(scene) == full, "down to the check box")
	uiKey(game, scene, .RETURN)
	testing.expect(t, !full.settings.checked, "unticked by Enter")
	uiKey(game, scene, .SPACE)
	testing.expect(t, full.settings.checked, "ticked by Space")
	// Right moves the focus from a check box (to a wider slider's middle, right of its own)
	uiKey(game, scene, .RIGHT)
	testing.expect(t, Control_Focused(scene) != full && Control_Focused(scene) != nil, "right moves the focus")
	Control_Focus(scene, full)
	at = {fullRect.x + 5, fullRect.y + fullRect.h * 0.5}
	uiFrame(game, scene, mouseEvent(.MOUSE_MOTION, at), mouseEvent(.MOUSE_BUTTON_DOWN, at))
	testing.expect(t, full.settings.checked && full.pressed, "pressed, not yet toggled")
	uiFrame(game, scene, mouseEvent(.MOUSE_BUTTON_UP, at))
	testing.expect(t, !full.settings.checked, "unticked by a click")
	testing.expect_value(t, len(events.toggles), 3)
	if len(events.toggles) == 3 do testing.expect(t, !events.toggles[0] && events.toggles[1] && !events.toggles[2], "the states sent")

	// Disabled ones ignore the mouse and can't take the focus
	clear(&events.values)
	clear(&events.toggles)
	locked := cast(^Slider)find(scene, "Locked")
	for name in ([]string{"Off", "Locked"}) {
		r := Control_GetRect(find(scene, name))
		at = {r.x + r.w * 0.9, r.y + r.h * 0.5}
		uiFrame(game, scene, mouseEvent(.MOUSE_MOTION, at), mouseEvent(.MOUSE_BUTTON_DOWN, at))
		uiFrame(game, scene, mouseEvent(.MOUSE_BUTTON_UP, at))
	}
	testing.expect(t, !off.settings.checked && locked.settings.value == 5, "disabled: unchanged")
	testing.expect(t, len(events.values) == 0 && len(events.toggles) == 0, "no events")
	Control_Focus(scene, full)
	uiKey(game, scene, .DOWN)
	testing.expect(t, Control_Focused(scene) == full, "the disabled ones below are skipped")

	// From code: clamped and snapped, no events
	Slider_SetValue(music, 0.4)
	testing.expect_value(t, music.settings.value, f32(0.5))
	Slider_SetValue(music, 7)
	testing.expect_value(t, music.settings.value, f32(1))
	CheckBox_SetChecked(full, true)
	testing.expect(t, full.settings.checked && len(events.values) == 0 && len(events.toggles) == 0, "no events from code")
	free_all(context.temp_allocator)
}

@(test)
ui_sliders_and_check_boxes_by_actions :: proc(t: ^testing.T) {
	// Check boxes measure their text with SDL_ttf
	sync.guard(&ttfLock)
	if ttf.WasInit() == 0 do ttf.Init()
	data: SceneData
	game, scene := optionsGame(t, &data)
	defer { Game_Destroy(game); free(game) }
	defer SceneData_Destroy(&data)
	events: OptionEvents
	defer { delete(events.values); delete(events.toggles) }
	optionsListen(scene, &events)
	Input_AddAction(MENU_ACTION_UP, KeyBinding{.W}, game = game)
	Input_AddAction(MENU_ACTION_DOWN, KeyBinding{.S}, game = game)
	Input_AddAction(MENU_ACTION_LEFT, KeyBinding{.A}, game = game)
	Input_AddAction(MENU_ACTION_RIGHT, KeyBinding{.D}, game = game)
	Input_AddAction(MENU_ACTION_ACCEPT, KeyBinding{.J}, game = game)
	music := cast(^Slider)Scene_FindNode(scene, "Music")
	full := cast(^CheckBox)Scene_FindNode(scene, "Full")

	// The first press focuses the first control; ui_right and ui_left then move its value
	uiKey(game, scene, .D)
	testing.expect(t, Control_Focused(scene) == &music.control, "focused")
	testing.expect_value(t, music.settings.value, f32(0.5))
	uiKey(game, scene, .D)
	testing.expect_value(t, music.settings.value, f32(0.75))
	uiKey(game, scene, .A)
	uiKey(game, scene, .A)
	testing.expect_value(t, music.settings.value, f32(0.25))
	// The arrow keys aren't bound: nothing
	uiKey(game, scene, .RIGHT)
	testing.expect_value(t, music.settings.value, f32(0.25))
	testing.expect_value(t, len(events.values), 3)
	// ui_down moves the focus; ui_accept ticks the check box
	uiKey(game, scene, .S)
	uiKey(game, scene, .S)
	testing.expect(t, Control_Focused(scene) == &full.control, "down to the check box")
	uiKey(game, scene, .J)
	testing.expect(t, !full.settings.checked && len(events.toggles) == 1, "toggled by ui_accept")
	uiKey(game, scene, .W)
	uiKey(game, scene, .W)
	testing.expect(t, Control_Focused(scene) == &music.control, "up to Music")
	free_all(context.temp_allocator)
}

@(test)
ui_scroll_box_rows_hide_and_scroll_to_the_focus :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.size = {400, 300}
	scene := game->createScene("S")
	// A list of rows (a label and a button each), three rows' room: an options screen's controls
	data, err := ParseScene(`<scene formatVersion="14" name="S">
	<node kind="ScrollBox" name="List" anchor="Top_Left" width="200" height="100" padding="0" spacing="0">
		<node kind="Panel" name="Row1" layout="Row" padding="0" height="30"><node kind="Button" name="B1" width="80" height="30"/></node>
		<node kind="Panel" name="Row2" layout="Row" padding="0" height="30"><node kind="Button" name="B2" width="80" height="30"/></node>
		<node kind="Panel" name="Row3" layout="Row" padding="0" height="30"><node kind="Button" name="B3" width="80" height="30"/></node>
		<node kind="Panel" name="Row4" layout="Row" padding="0" height="30"><node kind="Button" name="B4" width="80" height="30"/></node>
		<node kind="Panel" name="Row5" layout="Row" padding="0" height="30"><node kind="Button" name="B5" width="80" height="30"/></node>
	</node>
</scene>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	Scene_Build(scene, &data, "testdata")
	frame :: proc(game: ^Game, scene: ^Scene, events: ..sdl.Event) {
		Input_Update(&game.input, events)
		Scene_Update(scene, events, 1.0 / 60)
	}
	find :: proc(scene: ^Scene, name: string) -> ^Control { return cast(^Control)Scene_FindNode(scene, name) }
	frame(game, scene)
	// Rows past the box are hidden, and so are the buttons in them: they take no clicks or focus
	testing.expect(t, find(scene, "Row4").clipped && !find(scene, "Row3").clipped, "the fourth row is hidden")
	b4 := Control_GetRect(find(scene, "B4"))
	at := [2]f32{b4.x + 5, b4.y + 5}
	presses := 0
	Event_Subscribe(&(cast(^Button)find(scene, "B4")).onPressed, proc(_: ^EventSubject, _: rawptr, _: EventData, user: rawptr) {
		(cast(^int)user)^ += 1
	}, &presses)
	frame(game, scene, mouseEvent(.MOUSE_MOTION, at), mouseEvent(.MOUSE_BUTTON_DOWN, at))
	frame(game, scene, mouseEvent(.MOUSE_BUTTON_UP, at))
	testing.expect_value(t, presses, 0)
	// The keys move the focus down the rows, and onto a hidden one: the box scrolls to show it
	Control_Focus(scene, find(scene, "B3"))
	frame(game, scene)
	frame(game, scene, keyEvent(.DOWN))
	frame(game, scene)
	focusedNow := Control_Focused(scene)
	testing.expect(t, focusedNow == find(scene, "B4"), "the focus is on the fourth row's button")
	testing.expect(t, !find(scene, "Row4").clipped && find(scene, "Row1").clipped, "scrolled to it")
}

@(test)
labels_keep_their_text_and_font :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	scene := game->createScene("S")
	// Both made in the frame's memory, which is freed at the frame's end
	label := CreateLabel(scene, fmt.tprintf("+%d", 10), {0, 0}, 20, {255, 255, 255, 255}, true, JoinPath("assets", "font.ttf"))
	free_all(context.temp_allocator)
	_ = fmt.tprintf("%s", "something else in the frame's memory now")
	testing.expect_value(t, label.text, "+10")
	testing.expect_value(t, label.font, "assets/font.ttf")
}
