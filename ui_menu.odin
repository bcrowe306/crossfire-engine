package engine

import "core:math"
import "core:strings"
import sdl "vendor:sdl3"

// Most items a `Menu` can hold (`Menu_Add*` asserts past it)
MAX_MENU_ITEMS :: 32

// Called when a menu item is pressed or its value changes. For `Menu.onBack`, item is nil
MenuCallback :: proc(menu: ^Menu, item: ^MenuItem)

// What a `MenuItem` is, which decides how it is drawn and what input does to it
MenuItemKind :: enum {
	// Non-interactive text, e.g. a section header. Never takes focus
	Label,
	Button,
	Checkbox,
	// Only one radio per group is checked at a time
	Radio,
	Slider,
	// Dropdown list of options
	Select,
}

/*
One row of a `Menu`. Made by the `Menu_Add*` procedures, which return a pointer to it; the
pointer stays valid for the menu's lifetime. Fields below a kind's comment only apply to that kind.
*/
MenuItem :: struct {
	// What the item is
	kind: MenuItemKind,
	// Text drawn on the row, or "@key" for a translated string. Copied into the menu node's arena
	label: string,
	// Disabled items are drawn with `MenuStyle.textDisabledColor` and can't be focused or used. true when added
	enabled: bool,
	// Called when the button is pressed or the value changes (nil for none)
	onChange: MenuCallback,
	// Free for game code, e.g. a pointer to the setting this item controls
	userData: rawptr,
	// Style override for this item (set with `MenuItem_SetStyle`); nil uses the menu's style
	style: Maybe(MenuStyle),

	// Checkbox, Radio: whether it is checked
	checked: bool,
	// Radio: the group number; radios sharing one are mutually exclusive
	group: int,
	// Slider: current value, range and step (0 for a continuous slider)
	value, minValue, maxValue, step: f32,
	// Select: the option strings (or "@key" translation keys), copied into the menu node's arena
	options: []string,
	// Select: index of the selected option in `options`
	selectedOption: int,
}

/*
A node that draws a vertical list of interactive UI items, with built-in keyboard, gamepad and
mouse navigation.

The node's position is the top-center of the first row; the rest stack below it. Menus are
`.Position_Only` nodes: they follow their world position but don't rotate or scale. A menu only
takes input while it is visible in the tree (`Node_IsVisibleInTree`).

Keyboard and gamepad: through the game's ui_* input actions when it has `MENU_ACTION_ACCEPT`
(ui_up / ui_down move focus, ui_left / ui_right adjust sliders, radios and select boxes,
ui_accept activates, ui_cancel closes an open dropdown or runs onBack; held directions repeat),
else the keys W/S or Up/Down, A/D or Left/Right, Enter/Space, Escape. `Menu_Command` drives it
from code. Mouse: hover to focus, click to activate, click and drag sliders.

Example:
	menu := e.CreateMenu(scene, {640, 200})
	e.Menu_AddLabel(menu, "Settings")
	e.Menu_AddSlider(menu, "Volume", 0.8, 0, 1, 0.05, proc(menu: ^e.Menu, item: ^e.MenuItem) {
		log.infof("volume %.2f", item.value)
	})
	e.Menu_AddButton(menu, "Play", proc(menu: ^e.Menu, item: ^e.MenuItem) {
		log.info("play")
	})
	menu.onBack = proc(menu: ^e.Menu, item: ^e.MenuItem) { log.info("back") }
*/
Menu :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Style of the menu and of items without their own (`MenuItem_SetStyle`)
	style: MenuStyle,
	// The items; only the first `itemCount` are in use
	items: [MAX_MENU_ITEMS]MenuItem,
	// Number of items added
	itemCount: int,
	// Index of the focused item, -1 if none. The first interactive item added gets the focus
	focused: int,
	// Called (with a nil item) on Escape / ui_cancel when no dropdown is open; nil for none
	onBack: MenuCallback,

	// Interaction state

	// Slider being dragged, -1 if none
	dragging: int,
	// Dropdown of the focused select item is open
	popupOpen: bool,
	// Highlighted option in the open dropdown
	popupHover: int,
	// Direction action held down (ui_up...), repeating
	held: MenuCommand,
	// Seconds to its next repeat
	repeatTimer: f32,
}

/*
Creates an empty `Menu` node and adds it to the scene (at the start of the next update). Add items
with the `Menu_Add*` procedures.

Inputs:
- scene: The scene that owns the menu
- pos: Position of the top-center of the first row, in pixels, relative to the menu's parent
- style: Look of the menu and its items

Returns:
- The new menu, owned by the scene

Example:
	menu := e.CreateMenu(scene, {640, 200})
	e.Menu_AddButton(menu, "Quit", proc(menu: ^e.Menu, item: ^e.MenuItem) { log.info("quit") })
*/
CreateMenu :: proc(scene: ^Scene, pos: [2]f32, style := DEFAULT_MENU_STYLE) -> ^Menu {
	menu := CreateNode(scene, Menu)
	menu.update = Menu_update
	menu.draw = Menu_draw
	menu.getBounds = Menu_getBounds
	menu.position = pos
	menu.transformMode = .Position_Only
	menu.style = style
	menu.focused = -1
	menu.dragging = -1
	return menu
}


// BUILDING

/*
Adds a non-interactive text row, e.g. a section header. It never takes focus.

Inputs:
- menu: The menu
- text: The text, or "@key" for a translated string. Copied into the menu node's arena

Returns:
- The new item
*/
Menu_AddLabel :: proc(menu: ^Menu, text: string) -> ^MenuItem {
	return addItem(menu, {kind = .Label, label = text})
}

/*
Adds a button row. Pressing it (Enter / Space / ui_accept, or a click) calls `onPress`, then the
menu ignores the rest of that frame's input, since buttons often switch scenes.

Inputs:
- menu: The menu
- label: The button text, or "@key" for a translated string. Copied into the menu node's arena
- onPress: Called when the button is pressed

Returns:
- The new item

Example:
	// Given: menu: ^e.Menu
	e.Menu_AddButton(menu, "Play", proc(menu: ^e.Menu, item: ^e.MenuItem) {
		log.info("play pressed")
	})
*/
Menu_AddButton :: proc(menu: ^Menu, label: string, onPress: MenuCallback) -> ^MenuItem {
	return addItem(menu, {kind = .Button, label = label, onChange = onPress})
}

/*
Adds a checkbox row. Pressing it toggles `checked`, then calls `onChange`.

Inputs:
- menu: The menu
- label: The row text, or "@key" for a translated string. Copied into the menu node's arena
- checked: The starting state
- onChange: Called after it is toggled (nil for none)

Returns:
- The new item

Example:
	// Given: menu: ^e.Menu
	e.Menu_AddCheckbox(menu, "Fullscreen", false, proc(menu: ^e.Menu, item: ^e.MenuItem) {
		log.infof("fullscreen: %v", item.checked)
	})
*/
Menu_AddCheckbox :: proc(menu: ^Menu, label: string, checked: bool, onChange: MenuCallback = nil) -> ^MenuItem {
	return addItem(menu, {kind = .Checkbox, label = label, checked = checked, onChange = onChange})
}

/*
Adds a radio row. Radios sharing a group number form one set of mutually exclusive choices:
checking one unchecks the others, then calls its `onChange` (only the newly checked radio's).
Left / Right on a focused radio moves to the previous / next radio of its group and checks it.

Inputs:
- menu: The menu
- label: The row text, or "@key" for a translated string. Copied into the menu node's arena
- group: The group number
- checked: The starting state (check at most one per group)
- onChange: Called when this radio becomes checked (nil for none)

Returns:
- The new item

Example:
	// Given: menu: ^e.Menu
	e.Menu_AddRadio(menu, "Easy", 0, true)
	e.Menu_AddRadio(menu, "Hard", 0, false)
	difficulty := e.Menu_GetRadioIndex(menu, 0) // 0: Easy
	_ = difficulty
*/
Menu_AddRadio :: proc(menu: ^Menu, label: string, group: int, checked: bool, onChange: MenuCallback = nil) -> ^MenuItem {
	return addItem(menu, {kind = .Radio, label = label, group = group, checked = checked, onChange = onChange})
}

/*
Adds a slider row. Left / Right move it by one step, a click on the track jumps to that value and
dragging moves it. Values are clamped to the range and snapped to the step.

Inputs:
- menu: The menu
- label: The row text, or "@key" for a translated string. Copied into the menu node's arena
- value: The starting value (clamped and snapped)
- minValue: The lowest value
- maxValue: The highest value
- step: The increment; 0 makes the slider continuous (the keyboard then moves it in 5% of the range)
- onChange: Called when the value changes (nil for none)

Returns:
- The new item

Example:
	// Given: menu: ^e.Menu
	e.Menu_AddSlider(menu, "Volume", 0.8, 0, 1, 0.05, proc(menu: ^e.Menu, item: ^e.MenuItem) {
		log.infof("volume %.2f", item.value)
	})
*/
Menu_AddSlider :: proc(menu: ^Menu, label: string, value, minValue, maxValue: f32, step: f32 = 0, onChange: MenuCallback = nil) -> ^MenuItem {
	item := addItem(menu, {kind = .Slider, label = label, minValue = minValue, maxValue = maxValue, step = step, onChange = onChange})
	item.value = snapSliderValue(item, value)
	return item
}

/*
Adds a select row: a box showing the selected option, with a dropdown list. Pressing it opens the
dropdown (Up / Down pick, Accept selects, Cancel closes); Left / Right cycle the options without
opening it.

Inputs:
- menu: The menu
- label: The row text, or "@key" for a translated string. Copied into the menu node's arena
- options: The option strings (or "@key" translation keys). Copied into the menu node's arena, so a temporary slice literal is fine
- selected: Index of the starting option (clamped to the options)
- onChange: Called when the selected option changes (nil for none)

Returns:
- The new item

Example:
	// Given: menu: ^e.Menu
	e.Menu_AddSelect(menu, "Window", {"Windowed", "Fullscreen"}, 0, proc(menu: ^e.Menu, item: ^e.MenuItem) {
		log.infof("window mode: %s", e.Menu_SelectedOption(item))
	})
*/
Menu_AddSelect :: proc(menu: ^Menu, label: string, options: []string, selected: int = 0, onChange: MenuCallback = nil) -> ^MenuItem {
	allocator := Node_GetAllocator(menu)
	copied := make([]string, len(options), allocator)
	for option, i in options {
		copied[i] = strings.clone(option, allocator)
	}
	return addItem(menu, {kind = .Select, label = label, options = copied, selectedOption = clamp(selected, 0, max(len(options) - 1, 0)), onChange = onChange})
}

/*
Gives one item its own style instead of the menu's. Row spacing still comes from the menu's style.

Inputs:
- item: The item
- style: The style to use for it (copied)
*/
MenuItem_SetStyle :: proc(item: ^MenuItem, style: MenuStyle) {
	item.style = style
}

/*
Finds which radio of a group is checked.

Inputs:
- menu: The menu
- group: The radio group number

Returns:
- The index of the checked radio within its group (0 for the group's first radio, in menu order), or -1 if none is checked
*/
Menu_GetRadioIndex :: proc(menu: ^Menu, group: int) -> int {
	index := 0
	for &item in menu.items[:menu.itemCount] {
		if item.kind != .Radio || item.group != group do continue
		if item.checked do return index
		index += 1
	}
	return -1
}

/*
Gets the selected option of a select item.

Inputs:
- item: A select item

Returns:
- The selected option string as given to `Menu_AddSelect` (not translated: use `Tr_Text` for "@key" options), or "" if the item isn't a select or has no options
*/
Menu_SelectedOption :: proc(item: ^MenuItem) -> string {
	if item.kind != .Select || len(item.options) == 0 do return ""
	return item.options[item.selectedOption]
}

@(private="file")
addItem :: proc(menu: ^Menu, item: MenuItem) -> ^MenuItem {
	assert(menu.itemCount < MAX_MENU_ITEMS, "Too many menu items")
	item := item
	item.enabled = true
	// Copy the label into the menu node so callers can pass temporary strings
	item.label = strings.clone(item.label, Node_GetAllocator(menu))

	menu.items[menu.itemCount] = item
	added := &menu.items[menu.itemCount]
	menu.itemCount += 1

	// Focus the first interactive item by default
	if menu.focused < 0 && isFocusable(added) {
		menu.focused = menu.itemCount - 1
	}
	return added
}


// LAYOUT (shared by input and drawing)

@(private)
menuItemStyle :: proc(menu: ^Menu, item: ^MenuItem) -> ^MenuStyle {
	if style, ok := &item.style.?; ok do return style
	return &menu.style
}

@(private)
menuItemRect :: proc(menu: ^Menu, index: int) -> sdl.FRect {
	// Rows use the menu's spacing so per-item style overrides can't break the column
	// Relative to the menu's origin
	y: f32 = 0
	for i in 0..<index {
		y += menuItemStyle(menu, &menu.items[i]).itemSize.y + menu.style.spacing
	}
	size := menuItemStyle(menu, &menu.items[index]).itemSize
	return {-size.x * 0.5, y, size.x, size.y}
}

// Area on the right side of a row used by sliders and select boxes
@(private)
menuControlRect :: proc(menu: ^Menu, index: int) -> sdl.FRect {
	row := menuItemRect(menu, index)
	style := menuItemStyle(menu, &menu.items[index])
	w := row.w * style.controlWidth
	h := row.h * 0.64
	return {row.x + row.w - style.padding - w, row.y + (row.h - h) * 0.5, w, h}
}

// Slider track inside the control area, leaving room for the knob at both ends
@(private)
menuSliderTrack :: proc(menu: ^Menu, index: int) -> sdl.FRect {
	ctrl := menuControlRect(menu, index)
	knob := ctrl.h * 0.35
	h := max(ctrl.h * 0.18, 4)
	return {ctrl.x + knob, ctrl.y + (ctrl.h - h) * 0.5, ctrl.w - knob * 2, h}
}

// Dropdown option rows of a select item. Opens upward if there is no room below the menu's game
@(private)
menuPopupOptionRect :: proc(menu: ^Menu, index: int, option: int) -> sdl.FRect {
	ctrl := menuControlRect(menu, index)
	count := f32(len(menu.items[index].options))
	y := ctrl.y + ctrl.h
	screenY := Node_GetScreenPosition(menu).y
	if game := menu.scene.game; game != nil && screenY + y + ctrl.h * count > game.size.y {
		y = ctrl.y - ctrl.h * count
	}
	return {ctrl.x, y + f32(option) * ctrl.h, ctrl.w, ctrl.h}
}

@(private)
isFocusable :: proc(item: ^MenuItem) -> bool {
	return item.enabled && item.kind != .Label
}

@(private)
snapSliderValue :: proc(item: ^MenuItem, value: f32) -> f32 {
	v := clamp(value, item.minValue, item.maxValue)
	if item.step > 0 {
		v = item.minValue + math.round((v - item.minValue) / item.step) * item.step
		v = clamp(v, item.minValue, item.maxValue)
	}
	return v
}

// The rows' combined rectangle, relative to the menu's origin
@(private)
Menu_getBounds :: proc(node: ^Node) -> (sdl.FRect, bool) {
	menu := cast(^Menu)node
	if menu.itemCount == 0 do return {}, false
	first := menuItemRect(menu, 0)
	last := menuItemRect(menu, menu.itemCount - 1)
	return {min(first.x, last.x), first.y, max(first.w, last.w), last.y + last.h - first.y}, true
}
