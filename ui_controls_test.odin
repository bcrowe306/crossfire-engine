#+build !js
package crossfire

import "core:fmt"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// UI controls (ui_controls.odin): layouts and anchors from a scene file, the mouse, keyboard
// focus and typing, scroll boxes, rich text, themes

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
	free_all(context.temp_allocator)
}
