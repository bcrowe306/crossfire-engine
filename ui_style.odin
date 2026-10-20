package crossfire

import sdl "vendor:sdl3"

/*
Appearance of a `Menu` and its items: sizes in pixels, colors, font.

Copy `DEFAULT_MENU_STYLE` and change what you need. A style is set for a whole menu
(`CreateMenu`), or overridden per item with `MenuItem_SetStyle`. Row spacing always comes from the
menu's style, so per-item overrides keep the column intact.
*/
MenuStyle :: struct {
	// Font path, or `DEFAULT_FONT`
	font: string,
	// Font size of item text, in points (slider values and select options use a smaller size)
	textSize: f32,

	// Width and height of every row, in pixels
	itemSize: [2]f32,
	// Vertical gap between rows, in pixels (only the menu's own style is used for this)
	spacing: f32,
	// Inner horizontal padding of a row, in pixels
	padding: f32,
	// Corner radius of rows, in pixels
	cornerRadius: f32,
	// Border width of rows, in pixels. 0 disables borders
	borderWidth: f32,

	// Width of the control (slider track, select box) on the right side of a row, as a fraction of the row (0 to 1)
	controlWidth: f32,

	// Item text
	textColor: sdl.Color,
	// Text of the focused item
	textFocusedColor: sdl.Color,
	// Text of disabled items
	textDisabledColor: sdl.Color,
	// Text of label items (section headers)
	labelColor: sdl.Color,

	// Row background
	backgroundColor: sdl.Color,
	// Background of the focused row
	backgroundFocusedColor: sdl.Color,
	// Row border
	borderColor: sdl.Color,
	// Border of the focused row, and of an open dropdown
	borderFocusedColor: sdl.Color,

	// Checkbox / radio box, slider track, select box
	controlColor: sdl.Color,
	// Controls of the focused row
	controlFocusedColor: sdl.Color,
	// Check mark, radio dot, slider fill and knob
	accentColor: sdl.Color,

	// Background of a select item's dropdown list
	popupColor: sdl.Color,
	// Highlighted option in the dropdown list
	popupHighlightColor: sdl.Color,
}

/*
The engine's default menu style: 360 x 56 pixel rows on a dark blue theme, with the default font.

Example:
	style := e.DEFAULT_MENU_STYLE
	style.itemSize = {480, 64}
	style.accentColor = {120, 255, 140, 255}
	menu := e.CreateMenu(scene, {640, 200}, style)
*/
DEFAULT_MENU_STYLE :: MenuStyle{
	font = DEFAULT_FONT,
	textSize = 26,

	itemSize = {360, 56},
	spacing = 14,
	padding = 18,
	cornerRadius = 10,
	borderWidth = 1,
	controlWidth = 0.45,

	textColor = {180, 190, 215, 255},
	textFocusedColor = {20, 24, 40, 255},
	textDisabledColor = {90, 98, 120, 255},
	labelColor = {235, 240, 255, 255},

	backgroundColor = {35, 42, 65, 255},
	backgroundFocusedColor = {120, 200, 255, 255},
	borderColor = {70, 80, 115, 255},
	borderFocusedColor = {200, 235, 255, 255},

	controlColor = {20, 24, 40, 255},
	controlFocusedColor = {235, 245, 255, 255},
	accentColor = {255, 190, 70, 255},

	popupColor = {28, 34, 54, 255},
	popupHighlightColor = {120, 200, 255, 255},
}
