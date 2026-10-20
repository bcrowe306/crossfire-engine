package engine

import "core:fmt"
import "core:math"
import sdl "vendor:sdl3"

// MENU DRAWING

@(private)
Menu_draw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	menu := cast(^Menu)node
	rm := &menu.scene.game.resourceManager

	for i in 0..<menu.itemCount {
		drawItem(menu, rm, renderer, i)
	}
	// Drawn last so the dropdown covers the rows below it
	if menu.popupOpen && menu.focused >= 0 {
		drawPopup(menu, rm, renderer, menu.focused)
	}
}

@(private="file")
drawItem :: proc(menu: ^Menu, rm: ^ResourceManager, renderer: ^sdl.Renderer, index: int) {
	item := &menu.items[index]
	style := menuItemStyle(menu, item)
	row := menuItemRect(menu, index)
	centerY := row.y + row.h * 0.5

	if item.kind == .Label {
		drawTextLeft(rm, style, {row.x + style.padding, centerY}, Tr_Text(item.label, menu.scene.game), style.labelColor)
		return
	}

	focused := index == menu.focused && isFocusable(item)
	textColor := style.textColor
	if !item.enabled {
		textColor = style.textDisabledColor
	} else if focused {
		textColor = style.textFocusedColor
	}
	controlColor := focused ? style.controlFocusedColor : style.controlColor

	drawPanel(renderer, row, style.cornerRadius, style.borderWidth,
		focused ? style.backgroundFocusedColor : style.backgroundColor,
		focused ? style.borderFocusedColor : style.borderColor)

	if item.kind == .Button {
		DrawTextCentered(rm, {row.x + row.w * 0.5, centerY}, Tr_Text(item.label, menu.scene.game), style.font, style.textSize, textColor)
		return
	}

	drawTextLeft(rm, style, {row.x + style.padding, centerY}, Tr_Text(item.label, menu.scene.game), textColor)

	#partial switch item.kind {
	case .Checkbox:
		box := boxRect(row, style)
		DrawRoundedRectangle(renderer, &box, box.w * 0.2, controlColor)
		if item.checked {
			// Check mark
			s := box.w
			a := sdl.FPoint{box.x + s * 0.22, box.y + s * 0.52}
			b := sdl.FPoint{box.x + s * 0.42, box.y + s * 0.72}
			c := sdl.FPoint{box.x + s * 0.78, box.y + s * 0.30}
			DrawLineThick(renderer, a, b, s * 0.14, style.accentColor)
			DrawLineThick(renderer, b, c, s * 0.14, style.accentColor)
		}

	case .Radio:
		box := boxRect(row, style)
		center := sdl.FPoint{box.x + box.w * 0.5, box.y + box.h * 0.5}
		DrawCircle(renderer, center, box.w * 0.5, controlColor)
		if item.checked {
			DrawCircle(renderer, center, box.w * 0.25, style.accentColor)
		}

	case .Slider:
		ctrl := menuControlRect(menu, index)
		track := menuSliderTrack(menu, index)
		t: f32 = 0
		if item.maxValue > item.minValue {
			t = (item.value - item.minValue) / (item.maxValue - item.minValue)
		}

		DrawRoundedRectangle(renderer, &track, track.h * 0.5, controlColor)
		filled := sdl.FRect{track.x, track.y, track.w * t, track.h}
		if filled.w > 0 do DrawRoundedRectangle(renderer, &filled, track.h * 0.5, style.accentColor)
		DrawCircle(renderer, {track.x + track.w * t, track.y + track.h * 0.5}, ctrl.h * 0.3, style.accentColor)

		// Value, right-aligned just left of the slider
		valueText := formatSliderValue(item)
		valueSize := MeasureText(rm, valueText, style.font, style.textSize * 0.8)
		DrawText(rm, {ctrl.x - valueSize.x - style.padding * 0.5, centerY - valueSize.y * 0.5}, valueText, style.font, style.textSize * 0.8, textColor)

	case .Select:
		box := menuControlRect(menu, index)
		DrawRoundedRectangle(renderer, &box, style.cornerRadius * 0.6, controlColor)

		optionColor := focused ? style.textFocusedColor : style.textColor
		if !item.enabled do optionColor = style.textDisabledColor
		drawTextLeft(rm, style, {box.x + style.padding * 0.6, centerY}, Tr_Text(Menu_SelectedOption(item), menu.scene.game), optionColor, 0.85)

		// Arrow, pointing up while the dropdown is open
		s := box.h * 0.22
		ax := box.x + box.w - style.padding * 0.6 - s
		dir: f32 = (focused && menu.popupOpen) ? -1 : 1
		DrawTriangle(renderer,
			{ax - s, centerY - s * 0.5 * dir},
			{ax + s, centerY - s * 0.5 * dir},
			{ax, centerY + s * 0.5 * dir},
			optionColor)
	}
}

@(private="file")
drawPopup :: proc(menu: ^Menu, rm: ^ResourceManager, renderer: ^sdl.Renderer, index: int) {
	item := &menu.items[index]
	style := menuItemStyle(menu, item)
	count := len(item.options)
	if count == 0 do return

	first := menuPopupOptionRect(menu, index, 0)
	area := sdl.FRect{first.x, first.y, first.w, first.h * f32(count)}
	drawPanel(renderer, area, style.cornerRadius * 0.6, max(style.borderWidth, 1), style.popupColor, style.borderFocusedColor)

	for option in 0..<count {
		rect := menuPopupOptionRect(menu, index, option)
		hovered := option == menu.popupHover
		if hovered {
			highlight := sdl.FRect{rect.x + 2, rect.y + 2, rect.w - 4, rect.h - 4}
			DrawRoundedRectangle(renderer, &highlight, style.cornerRadius * 0.4, style.popupHighlightColor)
		}
		color := hovered ? style.textFocusedColor : style.textColor
		drawTextLeft(rm, style, {rect.x + style.padding * 0.6, rect.y + rect.h * 0.5}, Tr_Text(item.options[option], menu.scene.game), color, 0.85)
	}
}

// Rounded rectangle with a border of any width: the border color fills the whole shape,
// then the background is drawn inset on top of it
@(private="file")
drawPanel :: proc(renderer: ^sdl.Renderer, rect: sdl.FRect, radius, borderWidth: f32, background, border: sdl.Color) {
	rect := rect
	if borderWidth <= 0 {
		DrawRoundedRectangle(renderer, &rect, radius, background)
		return
	}
	DrawRoundedRectangle(renderer, &rect, radius, border)
	inner := sdl.FRect{rect.x + borderWidth, rect.y + borderWidth, rect.w - borderWidth * 2, rect.h - borderWidth * 2}
	DrawRoundedRectangle(renderer, &inner, max(radius - borderWidth, 0), background)
}

// Square for a checkbox or radio, right-aligned in the row
@(private="file")
boxRect :: proc(row: sdl.FRect, style: ^MenuStyle) -> sdl.FRect {
	size := row.h * 0.5
	return {row.x + row.w - style.padding - size, row.y + (row.h - size) * 0.5, size, size}
}

// Text with its left edge at pos.x, vertically centered on pos.y
@(private="file")
drawTextLeft :: proc(rm: ^ResourceManager, style: ^MenuStyle, pos: [2]f32, text: string, color: sdl.Color, scale: f32 = 1) {
	size := style.textSize * scale
	textSize := MeasureText(rm, text, style.font, size)
	DrawText(rm, {pos.x, pos.y - textSize.y * 0.5}, text, style.font, size, color)
}

@(private="file")
formatSliderValue :: proc(item: ^MenuItem) -> string {
	// Whole-number steps show as integers, everything else with two decimals
	if item.step > 0 && item.step == math.floor(item.step) {
		return fmt.tprintf("%.0f", item.value)
	}
	return fmt.tprintf("%.2f", item.value)
}
