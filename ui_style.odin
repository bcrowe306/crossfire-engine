package engine

import sdl "vendor:sdl3"

// Appearance of a Menu and its items. Copy DEFAULT_MENU_STYLE and change what you need.
// A style can be set for a whole menu, or overridden per item with MenuItem_SetStyle.
MenuStyle :: struct {
	font: string,     // Font path, or DEFAULT_FONT
	textSize: f32,

	itemSize: [2]f32, // Width and height of every row
	spacing: f32,     // Vertical gap between rows
	padding: f32,     // Inner horizontal padding of a row
	cornerRadius: f32,
	borderWidth: f32, // 0 disables borders

	// Width of the control (slider track, select box) on the right side of a row, as a fraction of the row
	controlWidth: f32,

	textColor: sdl.Color,
	textFocusedColor: sdl.Color,
	textDisabledColor: sdl.Color,
	labelColor: sdl.Color,          // Label items (section headers)

	backgroundColor: sdl.Color,
	backgroundFocusedColor: sdl.Color,
	borderColor: sdl.Color,
	borderFocusedColor: sdl.Color,

	controlColor: sdl.Color,        // Checkbox / radio box, slider track, select box
	controlFocusedColor: sdl.Color,
	accentColor: sdl.Color,         // Check mark, radio dot, slider fill and knob

	popupColor: sdl.Color,          // Select dropdown list
	popupHighlightColor: sdl.Color,
}

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
