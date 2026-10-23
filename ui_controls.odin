package crossfire

import "core:fmt"
import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

/*
UI controls: panels that lay out what's in them, buttons, progress bars, text fields, scroll
boxes, rich text, sliders and check boxes, for menus, HUDs, dialogs and options screens. They're
nodes like any others (kinds Panel, Button, ProgressBar, TextField, ScrollBox, RichText, Slider,
CheckBox), drawn in the scene; put them on a screen layer (the scene's `screenLayers`) so the
camera doesn't move them.

- **Sizes and places** (`UISettings`): a control's `size` (0 on an axis: as big as what's in it),
  and where it goes in its parent: by its `anchor` (a corner, an edge's middle, the middle, or
  stretched across: `Full`, `Top_Wide`...) moved by its position (`Control.offset`), or by its
  parent's `layout` when that's a Row, Column or Grid. A top-level control's parent is the
  screen (the game's resolution, which the window scales), so anchors keep a HUD in the corners
  whatever the window. Under a node that isn't a control, the anchors are relative to that
  node's position.
- **Containers** (Panel, ScrollBox): `layout` None (each child by its anchor), Row, Column or
  Grid (`columns`); `padding` and `spacing` (-1: the theme's); `align` places children across the
  layout (Start, Center, End, Stretch); `justify` along it (Start, Center, End); a child with
  `expand` takes the room left along it. A ScrollBox is a column that scrolls (the wheel over
  it, or focus moving into a hidden child); children that don't fit wholly are hidden.
- **Looks:** a theme (ui_theme.odin: colors, text size, padding, font), from the control's
  `theme`, its control ancestors' or the project's. A control with a `texture` draws it instead
  of its fill, stretched as a 9-patch by `patchMargins` (left, top, right, bottom pixels that
  don't stretch): a framed panel, an image button.
- **Input:** the mouse (hover, press, release on the control; the wheel over a scroll box), the
  keyboard and gamepads through the game's ui_* actions (`MENU_ACTION_*`: ui_up / down / left /
  right move the focus to the nearest focusable control that way, ui_accept presses), else the
  arrow keys, Tab, Enter and Space. Buttons, text fields, sliders and check boxes take focus;
  a focused one is outlined. A text field takes typing while it has focus.
- **Sliders** (`value` between `minValue` and `maxValue`, snapped to `step` when it isn't 0):
  a press sets the value from the mouse's x and dragging follows it, even outside the slider
  while the button is held. While a slider has focus, ui_left / ui_right (or the Left and Right
  keys) move its value by `step` (1/20 of the range when 0) instead of moving the focus; up and
  down still move it. `showValue` writes the percentage right of its track.
- **Check boxes** (`checked`, their `text` right of the box): a click or ui_accept (Enter,
  Space) ticks or unticks them.
- **Events:** Button `onPressed` (data: its action), TextField `onChanged` and `onSubmitted`
  (data: the text), Slider `onValueChanged` (data: the f32 value), CheckBox `onToggled` (data:
  true when ticked), every control's `onFocusChanged` (data: true when it got focus). A button's
  `action` "scene:<Name>" switches scene and "quit" quits, like a Menu's. Changes from code
  (`Slider_SetValue`, `CheckBox_SetChecked`) send no event.
- **Text:** a Button's, TextField's, RichText's or CheckBox's `text` ("@key" translates: `Tr_Text`). RichText
  takes tags: `[color=#ff8000]...[/color]`, `[size=28]...[/size]`; it wraps at its width (0:
  only at line breaks).
- **Code:** `CreatePanel`, `CreateButton`, `CreateProgressBar`, `CreateTextField`,
  `CreateScrollBox`, `CreateRichText`, `CreateSlider`, `CreateCheckBox`; `Control_SetText`,
  `ProgressBar_SetValue`, `Slider_SetValue`, `CheckBox_SetChecked`, `Control_Focus`,
  `Control_GetRect`. Move a control with its `offset` (its position is set by
  the layout).
*/

// What a control is (one type per kind: Panel, Button...)
ControlKind :: enum {
	Panel,
	Button,
	ProgressBar,
	TextField,
	ScrollBox,
	RichText,
	Slider,
	CheckBox,
}

// Where a control goes in its parent when the parent doesn't lay it out
UIAnchor :: enum {
	Top_Left,
	Top,
	Top_Right,
	Left,
	Center,
	Right,
	Bottom_Left,
	Bottom,
	Bottom_Right,
	// Fills the parent (less `margin` on each side)
	Full,
	// The parent's width, at its top (less `margin` left and right)
	Top_Wide,
	// The parent's width, at its bottom
	Bottom_Wide,
	// The parent's height, at its left (less `margin` top and bottom)
	Left_Tall,
	// The parent's height, at its right
	Right_Tall,
}

// How a container places its control children
UILayout :: enum {
	// Each by its anchor and position
	None,
	// Side by side, left to right
	Row,
	// One under another
	Column,
	// In rows of `columns` cells
	Grid,
}

// Where children go across a layout (`align`) or along it (`justify`: Stretch is Start)
UIAlign :: enum {
	Start,
	Center,
	End,
	// As wide (in a column) or tall (in a row) as the container
	Stretch,
}

// Which way a progress bar fills
ProgressDirection :: enum {
	Right,
	Left,
	Up,
	Down,
}

// Where text goes in a control (Auto: centered in buttons, at the left elsewhere)
UITextAlign :: enum {
	Auto,
	Left,
	Center,
	Right,
}

/*
A control's settings in a scene file (`SceneNodeData.ui`). The strings are owned: free with
`UISettings_Destroy` (the parser's and `UISettings_Clone`'s).
*/
UISettings :: struct {
	// Width and height (0 on an axis: as big as what's in it)
	size: [2]f32,
	// Where it goes in a parent that doesn't lay it out
	anchor: UIAnchor,
	// Stretching anchors: the space left on each side
	margin: f32,
	// Containers: how children are placed
	layout: UILayout,
	// Containers: children across the layout
	align: UIAlign,
	// Containers: children along the layout
	justify: UIAlign,
	// Grids: cells in a row
	columns: int,
	// Space inside it (-1: the theme's)
	padding: f32,
	// Space between children (-1: the theme's)
	spacing: f32,
	// In a Row or Column: takes the room left along it
	expand: bool,
	// Buttons, text fields, sliders and check boxes: can't be used
	disabled: bool,
	// Progress bars and sliders: the value and its range
	value, minValue, maxValue: f32,
	// Sliders: the steps the value snaps to and keys move it by (0: continuous; keys move 1/20
	// of the range)
	step: f32,
	// Check boxes: ticked
	checked: bool,
	// Progress bars: which way it fills
	direction: ProgressDirection,
	// Progress bars and sliders: the value as a percentage on it (a slider's right of its track)
	showValue: bool,
	// Progress bars: show the loading screen's progress (`Game_LoadingProgress`) instead of `value`
	showLoading: bool,
	// Text fields: the most characters (0: any)
	maxLength: int,
	// With a texture: its edges that don't stretch, in pixels (left, top, right, bottom)
	patchMargins: [4]f32,
	// Text size in points (0: the theme's)
	textSize: f32,
	// Where text goes
	textAlign: UITextAlign,
	// A theme asset (`.theme.xml`) for it and the controls in it ("": its parent's)
	theme: string,
	// Text fields: shown while it's empty
	placeholder: string,
	// Buttons: "scene:<Name>" switches scene, "quit" quits ("" none; `onPressed` fires anyway)
	action: string,
}

// A control's settings when the scene file sets none
DEFAULT_UI_SETTINGS :: UISettings{padding = -1, spacing = -1, maxValue = 1, columns = 2}

/*
The part every control type starts with: its settings, its laid-out size, its state. Control
types: `Panel`, `Button`, `ProgressBar`, `TextField`, `ScrollBox`, `RichText`, `Slider`,
`CheckBox`.
*/
Control :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Which control it is
	kind: ControlKind,
	// Its settings (strings in the node's arena)
	settings: UISettings,
	// Its text (node arena; `Control_SetText`)
	text: string,
	// Its image (nil: the theme's fill)
	texture: ^sdl.Texture,
	// Where it is from its anchor (its scene file position); a layout ignores it. Set this, not
	// `position`, to move a control
	offset: [2]f32,
	// Its size after the last layout
	size: [2]f32,
	// The mouse is over it
	hovered: bool,
	// The mouse pressed it and hasn't been released
	pressed: bool,
	// A scroll box's parent hid it: it doesn't fit wholly
	clipped: bool,
	// The layout pass it was last laid out in
	layoutStamp: u64,
	// Its focus changed (data: true when it got focus)
	onFocusChanged: EventSubject `event:"It got or lost the keyboard's or gamepad's focus (data: true when it got it)" data:"focused := data.(bool)"`,
}

// A box that lays out the controls in it, with the theme's fill (or its texture)
Panel :: struct {
	using control: Control,
}

// A button with text, an image, or both
Button :: struct {
	using control: Control,
	// Pressed: clicked, or accepted while focused
	onPressed: EventSubject `event:"It was pressed: clicked, or accepted with the keyboard or a gamepad (data: its action)" data:"action := data.(string)"`,
}

// A bar showing a value in its range: health, loading
ProgressBar :: struct {
	using control: Control,
}

// A box to type a line of text in
TextField :: struct {
	using control: Control,
	// The text, edited in place (node arena)
	buffer: [dynamic]u8,
	// The caret's byte offset
	caret: int,
	// Seconds the caret has blinked
	blink: f32,
	// Its text changed
	onChanged: EventSubject `event:"Its text changed (data: the text)" data:"text := data.(string)"`,
	// Enter was pressed in it
	onSubmitted: EventSubject `event:"Enter was pressed in it (data: the text)" data:"text := data.(string)"`,
}

// A column of controls that scrolls
ScrollBox :: struct {
	using control: Control,
	// How far it's scrolled, in pixels
	scroll: f32,
	// The height of what's in it
	contentHeight: f32,
}

// Text with colors and sizes (`[color=#ff8000]...[/color]`, `[size=28]...[/size]`), wrapped
RichText :: struct {
	using control: Control,
}

// A value picked by dragging a knob along a track: volume, brightness, difficulty
Slider :: struct {
	using control: Control,
	// Its value changed: pressed, dragged, or moved with the keys or a gamepad (not by `Slider_SetValue`)
	onValueChanged: EventSubject `event:"Its value changed: dragged, or moved with the keys or a gamepad (data: the value)" data:"value := data.(f32)"`,
}

// A box to tick, with its text right of it: on / off settings
CheckBox :: struct {
	using control: Control,
	// It was ticked or unticked: clicked, or accepted while focused (not by `CheckBox_SetChecked`)
	onToggled: EventSubject `event:"It was ticked or unticked: clicked, or accepted with the keyboard or a gamepad (data: true when ticked)" data:"checked := data.(bool)"`,
}

// Pixels a wheel step scrolls a scroll box
UI_SCROLL_STEP :: 40

/*
Creates a Panel and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- layout: How it places the controls in it
- size: Its size (0 on an axis: as big as what's in it)

Returns:
- The panel

Example:
	panel := e.CreatePanel(scene, .Column)
	panel.settings.anchor = .Center
	e.Node_AddChild(panel, e.CreateButton(scene, "Play", "scene:Level1"))
	e.Node_AddChild(panel, e.CreateButton(scene, "Quit", "quit"))
*/
CreatePanel :: proc(scene: ^Scene, layout := UILayout.None, size := [2]f32{}) -> ^Panel {
	c := createControl(scene, Panel, .Panel)
	c.settings.layout = layout
	c.settings.size = size
	return c
}

/*
Creates a Button and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- text: Its text ("@key" translates)
- action: "scene:<Name>", "quit" or "" (listen to `onPressed` instead)

Returns:
- The button

Example:
	play := e.CreateButton(scene, "Play", "scene:Level1")
	play.settings.anchor = .Bottom
	play.offset = {0, -40}
*/
CreateButton :: proc(scene: ^Scene, text: string, action := "") -> ^Button {
	c := createControl(scene, Button, .Button)
	EventSubject_Init(&c.onPressed, Node_GetAllocator(c))
	Control_SetText(c, text)
	c.settings.action = strings.clone(action, Node_GetAllocator(c))
	return c
}

/*
Creates a ProgressBar and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- value: Its value
- maxValue: The full bar's value (its minimum is 0)

Returns:
- The bar

Example:
	health := e.CreateProgressBar(scene, 80, 100)
	health.settings.anchor = .Top_Left
	health.offset = {16, 16}
*/
CreateProgressBar :: proc(scene: ^Scene, value: f32 = 0, maxValue: f32 = 1) -> ^ProgressBar {
	c := createControl(scene, ProgressBar, .ProgressBar)
	c.settings.value, c.settings.maxValue = value, maxValue
	return c
}

/*
Creates a TextField and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- text: Its text at first
- placeholder: Shown while it's empty

Returns:
- The field

Example:
	name := e.CreateTextField(scene, "", "Your name")
	name.settings.maxLength = 12
*/
CreateTextField :: proc(scene: ^Scene, text := "", placeholder := "") -> ^TextField {
	c := createControl(scene, TextField, .TextField)
	allocator := Node_GetAllocator(c)
	EventSubject_Init(&c.onChanged, allocator)
	EventSubject_Init(&c.onSubmitted, allocator)
	c.buffer = make([dynamic]u8, allocator)
	Control_SetText(c, text)
	c.settings.placeholder = strings.clone(placeholder, allocator)
	return c
}

/*
Creates a ScrollBox and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- size: Its size (what's in it scrolls inside)

Returns:
- The scroll box
*/
CreateScrollBox :: proc(scene: ^Scene, size := [2]f32{300, 200}) -> ^ScrollBox {
	c := createControl(scene, ScrollBox, .ScrollBox)
	c.settings.size = size
	c.settings.layout = .Column
	return c
}

/*
Creates a RichText and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- text: Its text, with tags (`[color=#ff8000]gold[/color]`, `[size=28]big[/size]`)
- width: The width it wraps at (0: only at line breaks)

Returns:
- The text

Example:
	note := e.CreateRichText(scene, "You found [color=#ffd040]the key[/color]!", 300)
*/
CreateRichText :: proc(scene: ^Scene, text: string, width: f32 = 0) -> ^RichText {
	c := createControl(scene, RichText, .RichText)
	Control_SetText(c, text)
	c.settings.size.x = width
	return c
}

/*
Creates a Slider and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- value: Its value (kept in its range, snapped to its step)
- minValue: Its value at the left end
- maxValue: Its value at the right end
- step: The steps its value snaps to (0: any value; keys then move it by 1/20 of the range)

Returns:
- The slider

Example:
	volume := e.CreateSlider(scene, 80, 0, 100, 5)
	volume.settings.showValue = true
	e.Event_Subscribe(&volume.onValueChanged, proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, _: rawptr) {
		e.Audio_SetBusVolume("Music", data.(f32) / 100)
	}, nil)
*/
CreateSlider :: proc(scene: ^Scene, value: f32 = 0, minValue: f32 = 0, maxValue: f32 = 1, step: f32 = 0) -> ^Slider {
	c := createControl(scene, Slider, .Slider)
	EventSubject_Init(&c.onValueChanged, Node_GetAllocator(c))
	c.settings.minValue, c.settings.maxValue, c.settings.step = minValue, maxValue, max(step, 0)
	Slider_SetValue(c, value)
	return c
}

/*
Creates a CheckBox and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- text: Its text, right of the box ("@key" translates)
- checked: Whether it starts ticked

Returns:
- The check box

Example:
	fullscreen := e.CreateCheckBox(scene, "Fullscreen", e.Game_IsFullscreen(game))
	fullscreen.settings.anchor = .Center
*/
CreateCheckBox :: proc(scene: ^Scene, text: string, checked := false) -> ^CheckBox {
	c := createControl(scene, CheckBox, .CheckBox)
	EventSubject_Init(&c.onToggled, Node_GetAllocator(c))
	Control_SetText(c, text)
	c.settings.checked = checked
	return c
}

/*
Sets a control's text (a text field's too: its caret goes to the end).

Inputs:
- control: The control
- text: The text (copied)
*/
Control_SetText :: proc(control: ^Control, text: string) {
	allocator := Node_GetAllocator(control)
	if control.kind == .TextField {
		field := cast(^TextField)control
		clear(&field.buffer)
		append(&field.buffer, text)
		field.caret = len(field.buffer)
		control.text = string(field.buffer[:])
		return
	}
	control.text = strings.clone(text, allocator)
}

/*
Sets a progress bar's value (clamped to its range).

Inputs:
- bar: The bar
- value: The value
*/
ProgressBar_SetValue :: proc(bar: ^ProgressBar, value: f32) {
	bar.settings.value = clamp(value, min(bar.settings.minValue, bar.settings.maxValue), max(bar.settings.minValue, bar.settings.maxValue))
}

/*
Sets a slider's value: kept in its range and snapped to its step. Sends no `onValueChanged`.

Inputs:
- slider: The slider
- value: The value

Example:
	// Given: slider: ^e.Slider, volume: f32
	e.Slider_SetValue(slider, volume * 100)
*/
Slider_SetValue :: proc(slider: ^Slider, value: f32) {
	slider.settings.value = sliderSnap(slider.settings, value)
}

/*
Ticks or unticks a check box. Sends no `onToggled`.

Inputs:
- box: The check box
- checked: Ticked or not

Example:
	// Given: box: ^e.CheckBox
	e.CheckBox_SetChecked(box, e.Game_IsFullscreen(game))
*/
CheckBox_SetChecked :: proc(box: ^CheckBox, checked: bool) {
	box.settings.checked = checked
}

/*
Gives a control the keyboard's and gamepads' focus (nil takes it from whatever has it). Only
buttons, text fields, sliders and check boxes take it (not disabled ones).

Inputs:
- scene: The scene
- control: The control, or nil
*/
Control_Focus :: proc(scene: ^Scene, control: ^Control) {
	old := uiFocused(scene)
	if old == control do return
	if control != nil && !controlFocusable(control) do return
	scene.ui.focus = control != nil ? control.id : {}
	if old != nil {
		if old.kind == .TextField do textInput(old, false)
		Event_Notify(&old.onFocusChanged, old, false)
	}
	if control != nil {
		if control.kind == .TextField {
			field := cast(^TextField)control
			field.caret = len(field.buffer)
			textInput(control, true)
		}
		Event_Notify(&control.onFocusChanged, control, true)
	}
}

/*
The control with the focus.

Inputs:
- scene: The scene

Returns:
- The control, or nil
*/
Control_Focused :: proc(scene: ^Scene) -> ^Control {
	return uiFocused(scene)
}

/*
A control's rectangle on the screen (game coordinates), as last laid out.

Inputs:
- control: The control

Returns:
- Its rectangle
*/
Control_GetRect :: proc(control: ^Control) -> sdl.FRect {
	ensureLayout(control)
	p := Node_GetScreenPosition(control)
	return {p.x, p.y, control.size.x, control.size.y}
}

/*
Whether a node is a UI control (`Control` starts its type).

Inputs:
- node: The node

Returns:
- true for Panel, Button, ProgressBar, TextField, ScrollBox, RichText, Slider and CheckBox nodes
*/
Node_IsControl :: proc(node: ^Node) -> bool {
	if node == nil do return false
	switch node.type {
	case Panel, Button, ProgressBar, TextField, ScrollBox, RichText, Slider, CheckBox: return true
	}
	return false
}

/*
The theme a control is drawn with: its own `theme`, else its nearest control ancestor's, else
the project's (`Game.uiTheme`), else `DEFAULT_UI_THEME`.

Inputs:
- control: The control

Returns:
- The theme, and the font's full path (or `DEFAULT_FONT`)
*/
Control_Theme :: proc(control: ^Control) -> (UITheme, string) {
	game := control.scene != nil ? control.scene.game : nil
	for n: ^Node = control; n != nil; n = n.parent {
		if !Node_IsControl(n) do continue
		if path := (cast(^Control)n).settings.theme; path != "" {
			if data, ok := Game_LoadTheme(game, path); ok do return data.theme, themeFont(game, data)
		}
	}
	if game != nil && game.uiTheme != "" {
		if data, ok := Game_LoadTheme(game, game.uiTheme); ok do return data.theme, themeFont(game, data)
	}
	return DEFAULT_UI_THEME, DEFAULT_FONT
}

/*
A copy of control settings, its strings cloned.

Inputs:
- settings: The settings
- allocator: For the strings

Returns:
- The copy (free with `UISettings_Destroy`)
*/
UISettings_Clone :: proc(settings: UISettings, allocator := context.allocator) -> UISettings {
	out := settings
	out.theme = strings.clone(settings.theme, allocator)
	out.placeholder = strings.clone(settings.placeholder, allocator)
	out.action = strings.clone(settings.action, allocator)
	return out
}

/*
Frees control settings' strings (the parser's, `UISettings_Clone`'s).

Inputs:
- settings: The settings
*/
UISettings_Destroy :: proc(settings: ^UISettings) {
	delete(settings.theme)
	delete(settings.placeholder)
	delete(settings.action)
	settings.theme, settings.placeholder, settings.action = "", "", ""
}

// INTERNAL

// Per scene: the focus, and the layout passes (Scene.ui)
SceneUI :: struct {
	// The focused control (zero: none)
	focus: EntityId,
	// Bumped by each update and draw: controls lay out once per pass
	stamp: u64,
	// The update pass whose focus moves were done (one move per frame, whichever control sees it)
	navigated: u64,
	// The update pass in which a press hit a control (one per frame)
	pressed: u64,
}

@(private="file")
createControl :: proc(scene: ^Scene, $T: typeid, kind: ControlKind) -> ^T {
	c := CreateNode(scene, T)
	c.kind = kind
	c.settings = DEFAULT_UI_SETTINGS
	c.transformMode = .Position_Only
	EventSubject_Init(&c.onFocusChanged, Node_GetAllocator(c))
	c.update = controlUpdate
	c.draw = controlDraw
	c.getBounds = controlBounds
	return c
}

// Builds a scene file's control (project_loader.odin)
@(private)
uiBuildNode :: proc(scene: ^Scene, data: ^SceneNodeData, projectDir: string, attachScripts: bool) -> ^Node {
	c: ^Control
	#partial switch data.kind {
	case .Panel: c = CreatePanel(scene)
	case .Button: c = CreateButton(scene, data.text)
	case .ProgressBar: c = CreateProgressBar(scene)
	case .TextField: c = CreateTextField(scene, data.text)
	case .ScrollBox: c = CreateScrollBox(scene)
	case .RichText: c = CreateRichText(scene, data.text)
	case .Slider: c = CreateSlider(scene)
	case .CheckBox: c = CreateCheckBox(scene, data.text)
	case: return CreateNode(scene, Node)
	}
	allocator := Node_GetAllocator(c)
	c.settings = UISettings_Clone(data.ui, allocator)
	if c.kind == .Panel || c.kind == .ScrollBox || c.kind == .Slider do c.text = ""
	if c.kind == .Slider do Slider_SetValue(cast(^Slider)c, c.settings.value)
	c.offset = data.position
	if data.texture != "" && c.kind != .Slider && c.kind != .CheckBox do c.texture = loadAsset(&scene.game.resourceManager, projectDir, data.texture)
	return c
}

@(private="file")
themeFont :: proc(game: ^Game, data: ^ThemeData) -> string {
	if data.font == "" || data.font == DEFAULT_FONT do return DEFAULT_FONT
	if game == nil do return DEFAULT_FONT
	if data.fontPath == "" do data.fontPath = strings.clone(JoinPath(game.projectDir, data.font), Game_GetAllocator(game))
	return data.fontPath
}

@(private="file")
uiFocused :: proc(scene: ^Scene) -> ^Control {
	if scene == nil || scene.ui.focus == {} do return nil
	node := Scene_GetNode(scene, scene.ui.focus)
	return Node_IsControl(node) ? cast(^Control)node : nil
}

@(private="file")
controlFocusable :: proc(c: ^Control) -> bool {
	return takesInput(c) && Node_IsVisibleInTree(c) && !c.clipped
}

// The kinds the mouse and the keyboard use (not disabled ones)
@(private="file")
takesInput :: proc(c: ^Control) -> bool {
	switch c.kind {
	case .Button, .TextField, .Slider, .CheckBox: return !c.settings.disabled
	case .Panel, .ProgressBar, .ScrollBox, .RichText:
	}
	return false
}

@(private="file")
textInput :: proc(c: ^Control, on: bool) {
	game := c.scene != nil ? c.scene.game : nil
	if game == nil || game.window == nil do return
	if on do _ = sdl.StartTextInput(game.window)
	else do _ = sdl.StopTextInput(game.window)
}

// The padding and spacing it uses
@(private="file")
gaps :: proc(c: ^Control, theme: UITheme) -> (padding, spacing: f32) {
	padding = c.settings.padding >= 0 ? c.settings.padding : theme.padding
	spacing = c.settings.spacing >= 0 ? c.settings.spacing : theme.spacing
	return
}

@(private="file")
textSizeOf :: proc(c: ^Control, theme: UITheme) -> f32 {
	return c.settings.textSize > 0 ? c.settings.textSize : theme.textSize
}

// Lays out the control's whole tree (from its topmost control), once per pass
@(private)
ensureLayout :: proc(c: ^Control) {
	scene := c.scene
	if scene == nil do return
	if scene.ui.stamp == 0 do scene.ui.stamp = 1
	if c.layoutStamp == scene.ui.stamp do return
	top := c
	for n := c.parent; n != nil && Node_IsControl(n); n = n.parent do top = cast(^Control)n
	// The parent's rectangle: the screen at the top level, a point at a node that isn't a control
	area := sdl.FRect{}
	if top.parent == nil && scene.game != nil do area = {0, 0, scene.game.size.x, scene.game.size.y}
	desired := measure(top)
	rect := anchored(top, desired, area)
	arrange(top, rect)
}

// The size a control wants: its settings', else what's in it
@(private="file")
measure :: proc(c: ^Control) -> [2]f32 {
	theme, font := Control_Theme(c)
	padding, spacing := gaps(c, theme)
	size := c.settings.size
	if size.x > 0 && size.y > 0 do return size
	content: [2]f32
	rm := c.scene != nil && c.scene.game != nil ? &c.scene.game.resourceManager : nil
	textSize := textSizeOf(c, theme)
	switch c.kind {
	case .Button:
		if c.text != "" && rm != nil {
			m := MeasureText(rm, Tr_Text(c.text, c.scene.game), font, textSize)
			content = {m.x + padding * 2, m.y + padding * 2}
		} else if c.texture != nil {
			w, h: f32
			sdl.GetTextureSize(c.texture, &w, &h)
			content = {w, h}
		} else {
			content = {textSize * 4, textSize + padding * 2}
		}
	case .TextField:
		content = {textSize * 10, textSize * 1.3 + padding * 2}
	case .ProgressBar:
		content = {200, 20}
	case .Slider:
		// A 200 pixel track, a knob as tall as the slider at each end, the percentage right of it
		height := size.y > 0 ? size.y : 20
		content = {200 + height + sliderTextRoom(c, rm, font, height, theme), 20}
	case .CheckBox:
		side := checkBoxSide(textSize)
		content = {side, side}
		if c.text != "" && rm != nil {
			m := MeasureText(rm, Tr_Text(c.text, c.scene.game), font, textSize)
			content = {side + spacing + m.x, max(side, m.y)}
		}
	case .RichText:
		lines := richLayout(c, rm, font, textSize, c.settings.size.x)
		content = lines.size
	case .Panel, .ScrollBox:
		content = childrenSize(c, padding, spacing)
		if c.kind == .ScrollBox do content = {max(content.x, 300), 200}
		if len(c.children) == 0 && c.texture != nil {
			w, h: f32
			sdl.GetTextureSize(c.texture, &w, &h)
			content = {w, h}
		}
	}
	if size.x <= 0 do size.x = content.x
	if size.y <= 0 do size.y = content.y
	return size
}

// What a container's control children need, laid out
@(private="file")
childrenSize :: proc(c: ^Control, padding, spacing: f32) -> [2]f32 {
	total, biggest: [2]f32
	count := 0
	for child in c.children {
		if !Node_IsControl(child) || !child.visible do continue
		d := measure(cast(^Control)child)
		switch c.settings.layout {
		case .None:
			o := (cast(^Control)child).offset
			biggest = {max(biggest.x, o.x + d.x), max(biggest.y, o.y + d.y)}
		case .Row:
			total.x += d.x
			biggest.y = max(biggest.y, d.y)
		case .Column:
			total.y += d.y
			biggest.x = max(biggest.x, d.x)
		case .Grid:
			biggest = {max(biggest.x, d.x), max(biggest.y, d.y)}
		}
		count += 1
	}
	gapsAlong := f32(max(count - 1, 0)) * spacing
	switch c.settings.layout {
	case .None: return biggest + padding * 2
	case .Row: return {total.x + gapsAlong, biggest.y} + padding * 2
	case .Column: return {biggest.x, total.y + gapsAlong} + padding * 2
	case .Grid:
		columns := max(c.settings.columns, 1)
		rows := (count + columns - 1) / columns
		used := min(count, columns)
		return {biggest.x * f32(used) + f32(max(used - 1, 0)) * spacing, biggest.y * f32(rows) + f32(max(rows - 1, 0)) * spacing} + padding * 2
	}
	return padding * 2
}

// Where a control goes in an area by its anchor and offset
@(private="file")
anchored :: proc(c: ^Control, desired: [2]f32, area: sdl.FRect) -> sdl.FRect {
	m := c.settings.margin
	o := c.offset
	point :: proc(area: sdl.FRect, desired, o: [2]f32, ax, ay: f32) -> sdl.FRect {
		return {area.x + area.w * ax - desired.x * ax + o.x, area.y + area.h * ay - desired.y * ay + o.y, desired.x, desired.y}
	}
	switch c.settings.anchor {
	case .Top_Left: return point(area, desired, o, 0, 0)
	case .Top: return point(area, desired, o, 0.5, 0)
	case .Top_Right: return point(area, desired, o, 1, 0)
	case .Left: return point(area, desired, o, 0, 0.5)
	case .Center: return point(area, desired, o, 0.5, 0.5)
	case .Right: return point(area, desired, o, 1, 0.5)
	case .Bottom_Left: return point(area, desired, o, 0, 1)
	case .Bottom: return point(area, desired, o, 0.5, 1)
	case .Bottom_Right: return point(area, desired, o, 1, 1)
	case .Full: return {area.x + m + o.x, area.y + m + o.y, max(area.w - m * 2, 0), max(area.h - m * 2, 0)}
	case .Top_Wide: return {area.x + m, area.y + m + o.y, max(area.w - m * 2, 0), desired.y}
	case .Bottom_Wide: return {area.x + m, area.y + area.h - m - desired.y + o.y, max(area.w - m * 2, 0), desired.y}
	case .Left_Tall: return {area.x + m + o.x, area.y + m, desired.x, max(area.h - m * 2, 0)}
	case .Right_Tall: return {area.x + area.w - m - desired.x + o.x, area.y + m, desired.x, max(area.h - m * 2, 0)}
	}
	return {area.x + o.x, area.y + o.y, desired.x, desired.y}
}

// Places a control (rect in its parent's space) and lays out its children
@(private="file")
arrange :: proc(c: ^Control, rect: sdl.FRect) {
	c.layoutStamp = c.scene.ui.stamp
	c.position = {rect.x, rect.y}
	c.size = {rect.w, rect.h}
	if c.kind != .Panel && c.kind != .ScrollBox {
		for child in c.children do if Node_IsControl(child) do arrange(cast(^Control)child, anchored(cast(^Control)child, measure(cast(^Control)child), {0, 0, c.size.x, c.size.y}))
		return
	}
	theme, _ := Control_Theme(c)
	padding, spacing := gaps(c, theme)
	inner := sdl.FRect{padding, padding, max(c.size.x - padding * 2, 0), max(c.size.y - padding * 2, 0)}
	kids := make([dynamic]^Control, context.temp_allocator)
	for child in c.children do if Node_IsControl(child) && child.visible do append(&kids, cast(^Control)child)
	layout := c.kind == .ScrollBox && c.settings.layout == .None ? UILayout.Column : c.settings.layout
	sizes := make([][2]f32, len(kids), context.temp_allocator)
	for k, i in kids do sizes[i] = measure(k)
	cross :: proc(align: UIAlign, start, room, want: f32) -> (f32, f32) {
		switch align {
		case .Start: return start, want
		case .Center: return start + (room - want) * 0.5, want
		case .End: return start + room - want, want
		case .Stretch: return start, room
		}
		return start, want
	}
	switch layout {
	case .None:
		for k, i in kids do arrange(k, anchored(k, sizes[i], inner))
	case .Row, .Column:
		row := layout == .Row
		along := row ? inner.w : inner.h
		fixed: f32
		expanding := 0
		for k, i in kids {
			if k.settings.expand do expanding += 1
			else do fixed += row ? sizes[i].x : sizes[i].y
		}
		gapTotal := f32(max(len(kids) - 1, 0)) * spacing
		left := max(along - fixed - gapTotal, 0)
		share := expanding > 0 ? left / f32(expanding) : 0
		at := row ? inner.x : inner.y
		if expanding == 0 && c.kind != .ScrollBox {
			switch c.settings.justify {
			case .Center: at += left * 0.5
			case .End: at += left
			case .Start, .Stretch:
			}
		}
		if c.kind == .ScrollBox {
			box := cast(^ScrollBox)c
			content: f32 = 0
			for _, i in kids do content += sizes[i].y
			box.contentHeight = content + gapTotal
			box.scroll = clamp(box.scroll, 0, max(box.contentHeight - inner.h, 0))
			at -= box.scroll
		}
		for k, i in kids {
			length := k.settings.expand ? share : (row ? sizes[i].x : sizes[i].y)
			r: sdl.FRect
			if row {
				y, h := cross(c.settings.align, inner.y, inner.h, sizes[i].y)
				r = {at, y, length, h}
			} else {
				x, w := cross(c.settings.align, inner.x, inner.w, sizes[i].x)
				r = {x, at, w, length}
			}
			arrange(k, r)
			// A scroll box hides what doesn't fit wholly
			k.clipped = c.kind == .ScrollBox && (r.y < inner.y - 0.5 || r.y + r.h > inner.y + inner.h + 0.5)
			at += length + spacing
		}
	case .Grid:
		columns := max(c.settings.columns, 1)
		cell: [2]f32
		for s in sizes do cell = {max(cell.x, s.x), max(cell.y, s.y)}
		if c.settings.align == .Stretch do cell.x = max((inner.w - f32(columns - 1) * spacing) / f32(columns), 0)
		for k, i in kids {
			column, line := i % columns, i / columns
			x := inner.x + f32(column) * (cell.x + spacing)
			y := inner.y + f32(line) * (cell.y + spacing)
			cx, w := cross(c.settings.align, x, cell.x, sizes[i].x)
			arrange(k, {cx, y, w, sizes[i].y})
		}
	}
}

@(private="file")
controlBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	c := cast(^Control)node
	ensureLayout(c)
	return {0, 0, c.size.x, c.size.y}, c.size.x > 0 || c.size.y > 0
}

@(private="file")
controlUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	c := cast(^Control)node
	ensureLayout(c)
	scene := c.scene
	game := scene != nil ? scene.game : nil
	if game == nil do return
	usable := Node_IsVisibleInTree(c) && !c.clipped
	rect := Control_GetRect(c)
	mouse := Input_GetMousePosition(game)
	inside := usable && mouse.x >= rect.x && mouse.x < rect.x + rect.w && mouse.y >= rect.y && mouse.y < rect.y + rect.h
	c.hovered = inside
	focused := scene.ui.focus == c.id

	// The wheel scrolls the scroll box under the mouse
	if c.kind == .ScrollBox && inside && game.input.wheel.y != 0 {
		box := cast(^ScrollBox)c
		box.scroll -= game.input.wheel.y * UI_SCROLL_STEP
	}
	// The mouse: a press on a button, field, slider or check box (the topmost: the last to
	// update), a release on the button or check box it pressed; a pressed slider follows it
	if takesInput(c) {
		if Input_IsMouseButtonJustPressed(.Left, game) {
			if inside {
				c.pressed = true
				Control_Focus(scene, c)
				if c.kind == .TextField do caretAt(cast(^TextField)c, mouse.x - rect.x)
			} else if focused && c.kind == .TextField {
				Control_Focus(scene, nil)
			}
		}
		held := Input_IsMouseButtonPressed(.Left, game)
		if c.pressed && held && c.kind == .Slider do sliderChange(cast(^Slider)c, sliderValueAt(c, mouse.x - rect.x))
		if c.pressed && !held {
			c.pressed = false
			if inside && c.kind == .Button do press(cast(^Button)c)
			if inside && c.kind == .CheckBox do toggle(cast(^CheckBox)c)
		}
	} else {
		c.pressed = false
	}
	if c.kind == .TextField && scene.ui.focus == c.id do typeInto(cast(^TextField)c, events, f32(deltaTime))
	// The keyboard and gamepads: whichever focusable control updates first does this frame's move
	if controlFocusable(c) && scene.ui.navigated != scene.ui.stamp {
		navigate(c, game, events)
	}
}

// Moves the focus, or presses the focused button
@(private="file")
navigate :: proc(c: ^Control, game: ^Game, events: []sdl.Event) {
	scene := c.scene
	focus := uiFocused(scene)
	if focus != nil && focus != c do return
	dir: [2]f32
	accept := false
	typing := focus != nil && focus.kind == .TextField
	// A focused slider takes left and right: they move its value, not the focus
	sliding := focus != nil && focus.kind == .Slider
	left, right: bool
	if Input_HasAction(MENU_ACTION_ACCEPT, game) {
		if Input_IsActionJustPressed(MENU_ACTION_UP, game) do dir = {0, -1}
		if Input_IsActionJustPressed(MENU_ACTION_DOWN, game) do dir = {0, 1}
		left = !typing && Input_IsActionJustPressed(MENU_ACTION_LEFT, game)
		right = !typing && Input_IsActionJustPressed(MENU_ACTION_RIGHT, game)
		accept = !typing && Input_IsActionJustPressed(MENU_ACTION_ACCEPT, game)
	} else {
		if Input_IsKeyJustPressed(.Up, game) do dir = {0, -1}
		if Input_IsKeyJustPressed(.Down, game) || Input_IsKeyJustPressed(.Tab, game) do dir = {0, 1}
		left = !typing && Input_IsKeyJustPressed(.Left, game)
		right = !typing && Input_IsKeyJustPressed(.Right, game)
		accept = !typing && (Input_IsKeyJustPressed(.Enter, game) || Input_IsKeyJustPressed(.Space, game))
	}
	nudge: f32
	if sliding {
		if left do nudge -= 1
		if right do nudge += 1
	} else {
		if left do dir = {-1, 0}
		if right do dir = {1, 0}
	}
	if dir == {} && !accept && nudge == 0 && !(sliding && (left || right)) do return
	scene.ui.navigated = scene.ui.stamp
	if focus == nil {
		// Nothing focused: the first control takes it
		Control_Focus(scene, c)
		return
	}
	if dir == {} && sliding && (left || right) {
		s := c.settings
		by := s.step > 0 ? s.step : abs(s.maxValue - s.minValue) / 20
		if s.maxValue < s.minValue do by = -by
		sliderChange(cast(^Slider)c, s.value + nudge * by)
		return
	}
	if accept {
		if c.kind == .Button do press(cast(^Button)c)
		if c.kind == .CheckBox do toggle(cast(^CheckBox)c)
		return
	}
	// The nearest focusable control that way (by centers; across the way counts double)
	from := Control_GetRect(c)
	center := [2]f32{from.x + from.w * 0.5, from.y + from.h * 0.5}
	best: ^Control
	bestScore := max(f32)
	for node in scene.nodes {
		if node == c || !Node_IsControl(node) do continue
		other := cast(^Control)node
		if !controlFocusable(other) do continue
		r := Control_GetRect(other)
		d := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5} - center
		ahead := d.x * dir.x + d.y * dir.y
		if ahead <= 0.5 do continue
		side := abs(d.x * dir.y - d.y * dir.x)
		score := ahead + side * 2
		if score < bestScore do best, bestScore = other, score
	}
	if best != nil {
		Control_Focus(scene, best)
		revealInScrollBox(best)
	}
}

// A control focused inside a scroll box is scrolled into view
@(private="file")
revealInScrollBox :: proc(c: ^Control) {
	parent := c.parent
	if parent == nil || !Node_Is(parent, ScrollBox) do return
	box := cast(^ScrollBox)parent
	theme, _ := Control_Theme(box)
	padding, _ := gaps(box, theme)
	room := box.size.y - padding * 2
	top := c.position.y - padding
	if top < 0 do box.scroll += top
	else if top + c.size.y > room do box.scroll += top + c.size.y - room
	// Laid out again with the new scroll
	box.layoutStamp = 0
	c.clipped = false
}

@(private="file")
press :: proc(b: ^Button) {
	Event_Notify(&b.onPressed, b, b.settings.action)
	game := b.scene.game
	action := b.settings.action
	if action != "" && !Game_RunAction(game, action) do log.warnf("Button %s: unknown action '%s'", b.name, action)
}

// A check box clicked or accepted
@(private="file")
toggle :: proc(b: ^CheckBox) {
	b.settings.checked = !b.settings.checked
	Event_Notify(&b.onToggled, b, b.settings.checked)
}

// A slider's value kept in its range, snapped to its step
@(private="file")
sliderSnap :: proc(s: UISettings, value: f32) -> f32 {
	v := value
	if s.step > 0 do v = s.minValue + math.round((v - s.minValue) / s.step) * s.step
	return clamp(v, min(s.minValue, s.maxValue), max(s.minValue, s.maxValue))
}

// A slider's value set by the player: snapped, `onValueChanged` when it changed
@(private="file")
sliderChange :: proc(s: ^Slider, value: f32) {
	v := sliderSnap(s.settings, value)
	if v == s.settings.value do return
	s.settings.value = v
	Event_Notify(&s.onValueChanged, s, v)
}

// The width a slider leaves right of its track for its percentage ("100%" and a gap)
@(private="file")
sliderTextRoom :: proc(c: ^Control, rm: ^ResourceManager, font: string, height: f32, theme: UITheme) -> f32 {
	if !c.settings.showValue || rm == nil do return 0
	_, spacing := gaps(c, theme)
	return MeasureText(rm, "100%", font, sliderTextSize(c, theme, height)).x + spacing
}

@(private="file")
sliderTextSize :: proc(c: ^Control, theme: UITheme, height: f32) -> f32 {
	return min(textSizeOf(c, theme), max(height, 8) * 0.8)
}

// Where a slider's track runs (from the knob's center at the left end to the right end's), and
// the knob's size: as tall as the slider
@(private="file")
sliderTrack :: proc(c: ^Control) -> (left, right, knob: f32) {
	theme, font := Control_Theme(c)
	rm := c.scene != nil && c.scene.game != nil ? &c.scene.game.resourceManager : nil
	knob = c.size.y
	left = knob * 0.5
	right = max(c.size.x - sliderTextRoom(c, rm, font, c.size.y, theme) - knob * 0.5, left)
	return
}

// The value at an x from a slider's left
@(private="file")
sliderValueAt :: proc(c: ^Control, x: f32) -> f32 {
	left, right, _ := sliderTrack(c)
	t := right > left ? clamp((x - left) / (right - left), 0, 1) : 0
	return c.settings.minValue + (c.settings.maxValue - c.settings.minValue) * t
}

// A check box's box: a little taller than its text
@(private="file")
checkBoxSide :: proc(textSize: f32) -> f32 {
	return math.round(textSize * 1.2)
}

// Typing into a focused text field: text events, Backspace, Delete, the arrows, Home, End, Enter
@(private="file")
typeInto :: proc(f: ^TextField, events: []sdl.Event, dt: f32) {
	f.blink += dt
	changed := false
	for &event in events {
		#partial switch event.type {
		case .TEXT_INPUT:
			text := string(event.text.text)
			for r in text {
				if f.settings.maxLength > 0 && utf8.rune_count(string(f.buffer[:])) >= f.settings.maxLength do break
				bytes, n := utf8.encode_rune(r)
				inject_at(&f.buffer, f.caret, ..bytes[:n])
				f.caret += n
				changed = true
			}
			f.blink = 0
		case .KEY_DOWN:
			f.blink = 0
			#partial switch event.key.scancode {
			case .BACKSPACE:
				if f.caret > 0 {
					_, n := utf8.decode_last_rune(f.buffer[:f.caret])
					remove_range(&f.buffer, f.caret - n, f.caret)
					f.caret -= n
					changed = true
				}
			case .DELETE:
				if f.caret < len(f.buffer) {
					_, n := utf8.decode_rune(f.buffer[f.caret:])
					remove_range(&f.buffer, f.caret, f.caret + n)
					changed = true
				}
			case .LEFT:
				if f.caret > 0 {
					_, n := utf8.decode_last_rune(f.buffer[:f.caret])
					f.caret -= n
				}
			case .RIGHT:
				if f.caret < len(f.buffer) {
					_, n := utf8.decode_rune(f.buffer[f.caret:])
					f.caret += n
				}
			case .HOME: f.caret = 0
			case .END: f.caret = len(f.buffer)
			case .RETURN, .KP_ENTER:
				Event_Notify(&f.onSubmitted, f, string(f.buffer[:]))
			}
		}
	}
	f.text = string(f.buffer[:])
	if changed do Event_Notify(&f.onChanged, f, f.text)
}

// The caret at a click's x (from the field's left)
@(private="file")
caretAt :: proc(f: ^TextField, x: f32) {
	theme, font := Control_Theme(f)
	padding, _ := gaps(f, theme)
	rm := &f.scene.game.resourceManager
	size := textSizeOf(f, theme)
	f.caret = len(f.buffer)
	for i := 0; i < len(f.buffer); {
		_, n := utf8.decode_rune(f.buffer[i:])
		w := MeasureText(rm, string(f.buffer[:i + n]), font, size).x
		if padding + w > x {
			f.caret = i
			return
		}
		i += n
	}
}

@(private="file")
controlDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	c := cast(^Control)node
	ensureLayout(c)
	if c.clipped || c.scene == nil || c.scene.game == nil do return
	theme, font := Control_Theme(c)
	rm := &c.scene.game.resourceManager
	padding, _ := gaps(c, theme)
	rect := sdl.FRect{0, 0, c.size.x, c.size.y}
	textSize := textSizeOf(c, theme)
	focused := c.scene.ui.focus == c.id
	switch c.kind {
	case .Panel:
		fill(renderer, c, rect, theme.panelColor, theme)
	case .ScrollBox:
		fill(renderer, c, rect, theme.panelColor, theme)
		box := cast(^ScrollBox)c
		room := c.size.y - padding * 2
		if box.contentHeight > room && room > 0 {
			h := max(room * room / box.contentHeight, 12)
			y := padding + (room - h) * (box.scroll / max(box.contentHeight - room, 1))
			bar := sdl.FRect{c.size.x - 6, y, 4, h}
			DrawRoundedRectangle(renderer, &bar, 2, theme.scrollbarColor)
		}
	case .Button:
		color := theme.buttonColor
		switch {
		case c.settings.disabled: color = theme.buttonDisabledColor
		case c.pressed && c.hovered: color = theme.buttonPressedColor
		case c.hovered: color = theme.buttonHoverColor
		}
		fill(renderer, c, rect, color, theme)
		if c.text != "" {
			text := Tr_Text(c.text, c.scene.game)
			textColor := c.settings.disabled ? theme.disabledTextColor : theme.buttonTextColor
			drawAligned(rm, c, text, font, textSize, textColor, padding, .Center)
		}
	case .ProgressBar:
		if c.settings.showLoading do c.settings.value = c.settings.minValue + (c.settings.maxValue - c.settings.minValue) * Game_LoadingProgress(c.scene.game)
		back := rect
		DrawRoundedRectangle(renderer, &back, min(theme.cornerRadius, c.size.y * 0.5), theme.progressBackColor)
		s := c.settings
		span := s.maxValue - s.minValue
		t := span != 0 ? clamp((s.value - s.minValue) / span, 0, 1) : 0
		bar := rect
		switch s.direction {
		case .Right: bar.w = rect.w * t
		case .Left: bar.w = rect.w * t; bar.x = rect.w - bar.w
		case .Up: bar.h = rect.h * t; bar.y = rect.h - bar.h
		case .Down: bar.h = rect.h * t
		}
		if bar.w > 0 && bar.h > 0 {
			if c.texture != nil do drawPatch(renderer, c, bar)
			else do DrawRoundedRectangle(renderer, &bar, min(theme.cornerRadius, min(bar.w, bar.h) * 0.5), theme.progressFillColor)
		}
		if theme.borderWidth > 0 do DrawRoundedRectangleOutline(renderer, &back, min(theme.cornerRadius, c.size.y * 0.5), theme.borderColor)
		if s.showValue do drawAligned(rm, c, fmt.tprintf("%d%%", int(math.round(t * 100))), font, min(textSize, c.size.y * 0.8), theme.textColor, 0, .Center)
	case .TextField:
		f := cast(^TextField)c
		fill(renderer, c, rect, theme.fieldColor, theme)
		if len(f.buffer) == 0 && f.settings.placeholder != "" && !focused {
			drawAligned(rm, c, Tr_Text(f.settings.placeholder, c.scene.game), font, textSize, theme.placeholderColor, padding, .Left)
		} else {
			drawAligned(rm, c, string(f.buffer[:]), font, textSize, c.settings.disabled ? theme.disabledTextColor : theme.textColor, padding, .Left)
		}
		if focused && math.mod(f.blink, 1) < 0.6 {
			x := padding + (f.caret > 0 ? MeasureText(rm, string(f.buffer[:f.caret]), font, textSize).x : 0)
			caret := sdl.FRect{x, (c.size.y - textSize * 1.2) * 0.5, 2, textSize * 1.2}
			DrawRectangle(renderer, &caret, theme.caretColor)
		}
	case .RichText:
		lines := richLayout(c, rm, font, textSize, c.size.x)
		for run in lines.runs {
			DrawText(rm, {run.at.x, run.at.y}, run.text, font, run.size, run.color != {} ? run.color : theme.textColor)
		}
	case .Slider:
		s := c.settings
		left, right, knob := sliderTrack(c)
		span := s.maxValue - s.minValue
		t := span != 0 ? clamp((s.value - s.minValue) / span, 0, 1) : 0
		thick := max(math.round(c.size.y * 0.35), 2)
		track := sdl.FRect{left, (c.size.y - thick) * 0.5, right - left, thick}
		DrawRoundedRectangle(renderer, &track, thick * 0.5, theme.progressBackColor)
		filled := track
		filled.w = track.w * t
		if filled.w > 0 do DrawRoundedRectangle(renderer, &filled, min(thick * 0.5, filled.w * 0.5), s.disabled ? theme.buttonDisabledColor : theme.progressFillColor)
		color := theme.buttonColor
		switch {
		case s.disabled: color = theme.buttonDisabledColor
		case c.pressed: color = theme.buttonPressedColor
		case c.hovered: color = theme.buttonHoverColor
		}
		center := sdl.FPoint{left + (right - left) * t, c.size.y * 0.5}
		DrawCircle(renderer, center, knob * 0.5, color)
		if theme.borderWidth > 0 && theme.borderColor.a > 0 do DrawCircleOutline(renderer, center, knob * 0.5, theme.borderColor)
		if s.showValue {
			size := sliderTextSize(c, theme, c.size.y)
			text := fmt.tprintf("%d%%", int(math.round(t * 100)))
			m := MeasureText(rm, text, font, size)
			DrawText(rm, {c.size.x - m.x, (c.size.y - m.y) * 0.5}, text, font, size, s.disabled ? theme.disabledTextColor : theme.textColor)
		}
	case .CheckBox:
		s := c.settings
		side := checkBoxSide(textSize)
		box := sdl.FRect{0, (c.size.y - side) * 0.5, side, side}
		color := theme.fieldColor
		switch {
		case s.disabled: color = theme.buttonDisabledColor
		case c.pressed && c.hovered: color = theme.buttonPressedColor
		case c.hovered: color = theme.buttonHoverColor
		}
		radius := min(theme.cornerRadius, side * 0.25)
		DrawRoundedRectangle(renderer, &box, radius, color)
		if theme.borderWidth > 0 && theme.borderColor.a > 0 do DrawRoundedRectangleOutline(renderer, &box, radius, theme.borderColor)
		if s.checked {
			mark := s.disabled ? theme.disabledTextColor : theme.checkColor
			at :: proc(box: sdl.FRect, x, y: f32) -> sdl.FPoint { return {box.x + box.w * x, box.y + box.h * y} }
			thickness := max(side * 0.14, 2)
			DrawLineThick(renderer, at(box, 0.22, 0.52), at(box, 0.42, 0.72), thickness, mark)
			DrawLineThick(renderer, at(box, 0.42, 0.72), at(box, 0.78, 0.3), thickness, mark)
			// The joint's gap filled
			DrawCircle(renderer, at(box, 0.42, 0.72), thickness * 0.5, mark)
		}
		if c.text != "" {
			_, spacing := gaps(c, theme)
			text := Tr_Text(c.text, c.scene.game)
			m := MeasureText(rm, text, font, textSize)
			DrawText(rm, {side + spacing, (c.size.y - m.y) * 0.5}, text, font, textSize, s.disabled ? theme.disabledTextColor : theme.textColor)
		}
	}
	if focused {
		outline := sdl.FRect{-2, -2, c.size.x + 4, c.size.y + 4}
		DrawRoundedRectangleOutline(renderer, &outline, theme.cornerRadius + 2, theme.focusColor)
		outline = {-1, -1, c.size.x + 2, c.size.y + 2}
		DrawRoundedRectangleOutline(renderer, &outline, theme.cornerRadius + 1, theme.focusColor)
	}
}

// A control's fill: its texture as a 9-patch, else the color with the theme's border
@(private="file")
fill :: proc(renderer: ^sdl.Renderer, c: ^Control, rect: sdl.FRect, color: sdl.Color, theme: UITheme) {
	if c.texture != nil {
		drawPatch(renderer, c, rect)
		return
	}
	r := rect
	radius := min(theme.cornerRadius, min(rect.w, rect.h) * 0.5)
	if color.a > 0 do DrawRoundedRectangle(renderer, &r, radius, color)
	if theme.borderWidth > 0 && theme.borderColor.a > 0 {
		for i in 0..<int(math.round(theme.borderWidth)) {
			o := sdl.FRect{f32(i), f32(i), rect.w - f32(i) * 2, rect.h - f32(i) * 2}
			if o.w > 0 && o.h > 0 do DrawRoundedRectangleOutline(renderer, &o, max(radius - f32(i), 0), theme.borderColor)
		}
	}
}

// The control's texture stretched over a rect, its `patchMargins` kept unstretched
@(private="file")
drawPatch :: proc(renderer: ^sdl.Renderer, c: ^Control, rect: sdl.FRect) {
	tw, th: f32
	sdl.GetTextureSize(c.texture, &tw, &th)
	m := c.settings.patchMargins
	if m == {} {
		DrawTexture(renderer, c.texture, rect)
		return
	}
	sx := [4]f32{0, m[0], tw - m[2], tw}
	sy := [4]f32{0, m[1], th - m[3], th}
	dx := [4]f32{rect.x, rect.x + m[0], rect.x + max(rect.w - m[2], m[0]), rect.x + max(rect.w, m[0] + m[2])}
	dy := [4]f32{rect.y, rect.y + m[1], rect.y + max(rect.h - m[3], m[1]), rect.y + max(rect.h, m[1] + m[3])}
	for row in 0..<3 do for column in 0..<3 {
		src := sdl.FRect{sx[column], sy[row], sx[column + 1] - sx[column], sy[row + 1] - sy[row]}
		dst := sdl.FRect{dx[column], dy[row], dx[column + 1] - dx[column], dy[row + 1] - dy[row]}
		if src.w <= 0 || src.h <= 0 || dst.w <= 0 || dst.h <= 0 do continue
		DrawTexture(renderer, c.texture, dst, 0, src)
	}
}

// One line of text in the control, by its alignment (Auto: `auto`), centered up and down
@(private="file")
drawAligned :: proc(rm: ^ResourceManager, c: ^Control, text, font: string, size: f32, color: sdl.Color, padding: f32, auto: UITextAlign) {
	align := c.settings.textAlign == .Auto ? auto : c.settings.textAlign
	m := MeasureText(rm, text, font, size)
	y := (c.size.y - m.y) * 0.5
	x: f32
	#partial switch align {
	case .Left: x = padding
	case .Center: x = (c.size.x - m.x) * 0.5
	case .Right: x = c.size.x - padding - m.x
	}
	DrawText(rm, {x, y}, text, font, size, color)
}

// RICH TEXT

// A word or space of rich text, placed
RichRun :: struct {
	text: string,
	at: [2]f32,
	size: f32,
	// Zero: the theme's text color
	color: sdl.Color,
	// Its width without the spaces after it
	width: f32,
}

// Rich text laid out: its runs and the size they take
RichLines :: struct {
	runs: []RichRun,
	size: [2]f32,
}

/*
Lays out rich text: its tags (`[color=#rrggbb]`, `[/color]`, `[size=N]`, `[/size]`) read, words
wrapped at a width.

Inputs:
- rm: The resource manager (for measuring)
- text: The text
- font: The font
- size: Its text size where no `[size]` says otherwise
- width: Where lines wrap (0: only at line breaks)
- align: Where each line goes across the width (or, with no width, the widest line): Left
  (and Auto), Center or Right

Returns:
- The runs (temp allocated) and their size

Example:
	lines := e.RichText_Layout(&game.resourceManager, "[size=40]Credits[/size]\nArt: Anokolisa", e.DEFAULT_FONT, 24, 400, .Center)
	for run in lines.runs do e.DrawText(&game.resourceManager, run.at, run.text, e.DEFAULT_FONT, run.size, {255, 255, 255, 255})
*/
RichText_Layout :: proc(rm: ^ResourceManager, text, font: string, size, width: f32, align := UITextAlign.Left) -> RichLines {
	runs := make([dynamic]RichRun, context.temp_allocator)
	// Each line's first run and its width, for the alignment
	lineSpans := make([dynamic]RichLineSpan, context.temp_allocator)
	colors := make([dynamic]sdl.Color, context.temp_allocator)
	sizes := make([dynamic]f32, context.temp_allocator)
	x, y, lineHeight, widest: f32
	lineStart := 0
	newLine :: proc(runs: [dynamic]RichRun, spans: ^[dynamic]RichLineSpan, lineStart: int, x, y, lineHeight, size: ^f32, widest: ^f32) {
		h := lineHeight^ > 0 ? lineHeight^ : size^ * 1.25
		lineWidth := x^
		if len(runs) > lineStart {
			// Trailing spaces don't count toward where a line is centered
			last := runs[len(runs) - 1]
			lineWidth = last.at.x + last.width
		}
		append(spans, RichLineSpan{lineStart, len(runs), lineWidth})
		// The line's words sit on its tallest's baseline (their tops: by their size's difference)
		for &r in runs[lineStart:] do r.at.y = y^ + (h - r.size * 1.25)
		widest^ = max(widest^, x^)
		x^ = 0
		y^ += h
		lineHeight^ = 0
	}
	current :: proc(sizes: [dynamic]f32, size: f32) -> f32 { return len(sizes) > 0 ? sizes[len(sizes) - 1] : size }
	rest := text
	for len(rest) > 0 {
		// Tags
		if rest[0] == '[' {
			if end := strings.index_byte(rest, ']'); end > 0 {
				tag := rest[1:end]
				handled := true
				switch {
				case strings.has_prefix(tag, "color="):
					c, _ := ParseColor(strings.trim_space(tag[len("color="):]))
					append(&colors, c)
				case tag == "/color":
					if len(colors) > 0 do pop(&colors)
				case strings.has_prefix(tag, "size="):
					v := strings.trim_space(tag[len("size="):])
					n: f32 = size
					if parsed, ok := strconv.parse_f32(v); ok do n = parsed
					append(&sizes, max(n, 1))
				case tag == "/size":
					if len(sizes) > 0 do pop(&sizes)
				case:
					handled = false
				}
				if handled {
					rest = rest[end + 1:]
					continue
				}
			}
		}
		if rest[0] == '\n' {
			s := current(sizes, size)
			newLine(runs, &lineSpans, lineStart, &x, &y, &lineHeight, &s, &widest)
			lineStart = len(runs)
			rest = rest[1:]
			continue
		}
		// A word (to the next space, line break or tag) and the spaces after it
		end := 0
		for end < len(rest) && rest[end] != ' ' && rest[end] != '\n' && rest[end] != '[' do end += 1
		for end < len(rest) && rest[end] == ' ' do end += 1
		if end == 0 do end = 1
		word := rest[:end]
		rest = rest[end:]
		s := current(sizes, size)
		m := MeasureText(rm, word, font, s)
		trimmed := MeasureText(rm, strings.trim_right(word, " "), font, s).x
		if width > 0 && x > 0 && x + trimmed > width {
			newLine(runs, &lineSpans, lineStart, &x, &y, &lineHeight, &s, &widest)
			lineStart = len(runs)
		}
		color := len(colors) > 0 ? colors[len(colors) - 1] : sdl.Color{}
		append(&runs, RichRun{word, {x, y}, s, color, trimmed})
		x += m.x
		lineHeight = max(lineHeight, s * 1.25)
	}
	s := size
	if x > 0 || len(runs) > lineStart do newLine(runs, &lineSpans, lineStart, &x, &y, &lineHeight, &s, &widest)
	across := width > 0 ? width : widest
	if align == .Center || align == .Right {
		for span in lineSpans {
			shift := across - span.width
			if align == .Center do shift *= 0.5
			for &r in runs[span.first:span.end] do r.at.x += math.round(max(shift, 0))
		}
	}
	return {runs[:], {across, y}}
}

// A laid-out line of rich text: its runs (first to end) and how wide it is
@(private="file")
RichLineSpan :: struct {
	first, end: int,
	width: f32,
}


@(private="file")
richLayout :: proc(c: ^Control, rm: ^ResourceManager, font: string, size, width: f32) -> RichLines {
	if rm == nil do return {}
	return RichText_Layout(rm, Tr_Text(c.text, c.scene.game), font, size, width, c.settings.textAlign)
}
