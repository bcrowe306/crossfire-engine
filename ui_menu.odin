package engine

import "core:math"
import "core:strings"
import sdl "vendor:sdl3"

// A vertical list of interactive UI items with built-in keyboard and mouse navigation.
//
// Keyboard: W/S or Up/Down move focus, Enter/Space activate, A/D or Left/Right adjust
// sliders and cycle select boxes, Escape closes an open dropdown or runs onBack.
// Mouse: hover to focus, click to activate, click and drag sliders.
//
// Usage:
//	menu := CreateMenu(scene, {640, 200})
//	Menu_AddButton(menu, "Play", proc(menu: ^Menu, item: ^MenuItem) { ... })
//	Menu_AddSlider(menu, "Volume", 0.8, 0, 1, 0.05, onVolumeChanged)

MAX_MENU_ITEMS :: 32

// Called when an item is pressed or its value changes. For onBack, item is nil
MenuCallback :: proc(menu: ^Menu, item: ^MenuItem)

MenuItemKind :: enum {
	Label,    // Non-interactive text, e.g. a section header
	Button,
	Checkbox,
	Radio,    // Only one radio per group is checked at a time
	Slider,
	Select,   // Dropdown list of options
}

MenuItem :: struct {
	kind: MenuItemKind,
	label: string,
	enabled: bool,
	onChange: MenuCallback,
	// Free for game code, e.g. a pointer to the setting this item controls
	userData: rawptr,
	style: Maybe(MenuStyle),

	// Checkbox, Radio
	checked: bool,
	// Radio
	group: int,
	// Slider
	value, minValue, maxValue, step: f32,
	// Select
	options: []string,
	selectedOption: int,
}

Menu :: struct {
	using node: Node,
	// Top-center of the first row; the rest stack below it
	pos: [2]f32,
	style: MenuStyle,
	items: [MAX_MENU_ITEMS]MenuItem,
	itemCount: int,
	focused: int,
	onBack: MenuCallback,

	// Interaction state
	dragging: int,     // Slider being dragged, -1 if none
	popupOpen: bool,   // Dropdown of the focused select item is open
	popupHover: int,   // Highlighted option in the open dropdown
}

CreateMenu :: proc(scene: ^Scene, pos: [2]f32, style := DEFAULT_MENU_STYLE) -> ^Menu {
	menu := CreateNode(scene, Menu)
	menu.update = Menu_update
	menu.draw = Menu_draw
	menu.pos = pos
	menu.style = style
	menu.focused = -1
	menu.dragging = -1
	return menu
}


// BUILDING

Menu_AddLabel :: proc(menu: ^Menu, text: string) -> ^MenuItem {
	return addItem(menu, {kind = .Label, label = text})
}

Menu_AddButton :: proc(menu: ^Menu, label: string, onPress: MenuCallback) -> ^MenuItem {
	return addItem(menu, {kind = .Button, label = label, onChange = onPress})
}

Menu_AddCheckbox :: proc(menu: ^Menu, label: string, checked: bool, onChange: MenuCallback = nil) -> ^MenuItem {
	return addItem(menu, {kind = .Checkbox, label = label, checked = checked, onChange = onChange})
}

// Radios sharing a group number form one set of mutually exclusive choices
Menu_AddRadio :: proc(menu: ^Menu, label: string, group: int, checked: bool, onChange: MenuCallback = nil) -> ^MenuItem {
	return addItem(menu, {kind = .Radio, label = label, group = group, checked = checked, onChange = onChange})
}

// step of 0 makes the slider continuous (keyboard then moves it in 5% increments)
Menu_AddSlider :: proc(menu: ^Menu, label: string, value, minValue, maxValue: f32, step: f32 = 0, onChange: MenuCallback = nil) -> ^MenuItem {
	item := addItem(menu, {kind = .Slider, label = label, minValue = minValue, maxValue = maxValue, step = step, onChange = onChange})
	item.value = snapSliderValue(item, value)
	return item
}

// options are copied into the menu node, so a temporary slice literal is fine
Menu_AddSelect :: proc(menu: ^Menu, label: string, options: []string, selected: int = 0, onChange: MenuCallback = nil) -> ^MenuItem {
	allocator := Node_GetAllocator(menu)
	copied := make([]string, len(options), allocator)
	for option, i in options {
		copied[i] = strings.clone(option, allocator)
	}
	return addItem(menu, {kind = .Select, label = label, options = copied, selectedOption = clamp(selected, 0, max(len(options) - 1, 0)), onChange = onChange})
}

MenuItem_SetStyle :: proc(item: ^MenuItem, style: MenuStyle) {
	item.style = style
}

// Value of the checked radio in a group, as the index of that radio within the group. -1 if none
Menu_GetRadioIndex :: proc(menu: ^Menu, group: int) -> int {
	index := 0
	for &item in menu.items[:menu.itemCount] {
		if item.kind != .Radio || item.group != group do continue
		if item.checked do return index
		index += 1
	}
	return -1
}

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
	y := menu.pos.y
	for i in 0..<index {
		y += menuItemStyle(menu, &menu.items[i]).itemSize.y + menu.style.spacing
	}
	size := menuItemStyle(menu, &menu.items[index]).itemSize
	return {menu.pos.x - size.x * 0.5, y, size.x, size.y}
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
	if game := menu.scene.game; game != nil && y + ctrl.h * count > game.size.y {
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
