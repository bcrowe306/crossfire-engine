package engine

import sdl "vendor:sdl3"

// MENU INPUT HANDLING

Menu_update :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	menu := cast(^Menu)node
	if !Node_IsVisibleInTree(menu) do return
	// Item rects are relative to the menu's origin; mouse events are in screen coordinates
	origin := Node_GetScreenPosition(menu)

	// Handlers return true after a button press or onBack, which commonly switch scenes.
	// Remaining events are then left alone so they don't act on a menu that is going away
	for &event in events {
		#partial switch event.type {
		case .KEY_DOWN:
			if handleKey(menu, event.key) do return

		case .MOUSE_MOTION:
			handleMouseMotion(menu, [2]f32{event.motion.x, event.motion.y} - origin)

		case .MOUSE_BUTTON_DOWN:
			if event.button.button == sdl.BUTTON_LEFT && handleMouseDown(menu, [2]f32{event.button.x, event.button.y} - origin) {
				return
			}

		case .MOUSE_BUTTON_UP:
			if event.button.button == sdl.BUTTON_LEFT do menu.dragging = -1
		}
	}
}

@(private="file")
handleKey :: proc(menu: ^Menu, key: sdl.KeyboardEvent) -> bool {
	// An open dropdown takes all keyboard input until it closes
	if menu.popupOpen {
		item := &menu.items[menu.focused]
		count := len(item.options)
		#partial switch key.scancode {
		case .UP, .W:
			menu.popupHover = (menu.popupHover - 1 + count) % count
		case .DOWN, .S:
			menu.popupHover = (menu.popupHover + 1) % count
		case .RETURN, .KP_ENTER, .SPACE:
			if !key.repeat {
				selectOption(menu, item, menu.popupHover)
				menu.popupOpen = false
			}
		case .ESCAPE:
			if !key.repeat do menu.popupOpen = false
		}
		return false
	}

	#partial switch key.scancode {
	case .UP, .W:
		moveFocus(menu, -1)
	case .DOWN, .S:
		moveFocus(menu, 1)
	case .LEFT, .A:
		adjustFocused(menu, -1)
	case .RIGHT, .D:
		adjustFocused(menu, 1)
	case .RETURN, .KP_ENTER, .SPACE:
		if !key.repeat && menu.focused >= 0 {
			return activate(menu, menu.focused)
		}
	case .ESCAPE:
		if !key.repeat && menu.onBack != nil {
			menu.onBack(menu, nil)
			return true
		}
	}
	return false
}

@(private="file")
handleMouseMotion :: proc(menu: ^Menu, point: [2]f32) {
	if menu.dragging >= 0 {
		setSliderFromX(menu, menu.dragging, point.x)
		return
	}
	if menu.popupOpen {
		if option, ok := popupOptionAt(menu, point); ok do menu.popupHover = option
		return
	}
	if index, ok := itemAt(menu, point); ok && isFocusable(&menu.items[index]) {
		menu.focused = index
	}
}

@(private="file")
handleMouseDown :: proc(menu: ^Menu, point: [2]f32) -> bool {
	// While a dropdown is open, a click either picks an option or closes it
	if menu.popupOpen {
		if option, ok := popupOptionAt(menu, point); ok {
			selectOption(menu, &menu.items[menu.focused], option)
		}
		menu.popupOpen = false
		return false
	}

	index, ok := itemAt(menu, point)
	if !ok || !isFocusable(&menu.items[index]) do return false
	menu.focused = index

	if menu.items[index].kind == .Slider {
		// Clicking the slider control jumps to that value and starts a drag
		if sdl.PointInRectFloat(sdl.FPoint(point), menuControlRect(menu, index)) {
			menu.dragging = index
			setSliderFromX(menu, index, point.x)
		}
		return false
	}
	return activate(menu, index)
}

// Enter/Space or click on an item. Returns true if a button was pressed
@(private="file")
activate :: proc(menu: ^Menu, index: int) -> bool {
	item := &menu.items[index]
	if !isFocusable(item) do return false

	#partial switch item.kind {
	case .Button:
		if item.onChange != nil do item.onChange(menu, item)
		return true
	case .Checkbox:
		item.checked = !item.checked
		if item.onChange != nil do item.onChange(menu, item)
	case .Radio:
		checkRadio(menu, index)
	case .Select:
		if len(item.options) > 0 {
			menu.popupOpen = true
			menu.popupHover = item.selectedOption
		}
	}
	return false
}

// Left/Right on the focused item
@(private="file")
adjustFocused :: proc(menu: ^Menu, direction: int) {
	if menu.focused < 0 do return
	item := &menu.items[menu.focused]
	if !isFocusable(item) do return

	#partial switch item.kind {
	case .Slider:
		step := item.step > 0 ? item.step : (item.maxValue - item.minValue) * 0.05
		setSliderValue(menu, item, item.value + f32(direction) * step)
	case .Select:
		count := len(item.options)
		if count > 0 do selectOption(menu, item, (item.selectedOption + direction + count) % count)
	case .Radio:
		// Step through the radios of the same group
		for offset in 1..<menu.itemCount {
			next := (menu.focused + offset * direction) %% menu.itemCount
			other := &menu.items[next]
			if other.kind == .Radio && other.group == item.group && isFocusable(other) {
				menu.focused = next
				checkRadio(menu, next)
				return
			}
		}
	}
}

@(private="file")
moveFocus :: proc(menu: ^Menu, direction: int) {
	start := max(menu.focused, 0)
	for offset in 1..=menu.itemCount {
		next := (start + direction * offset) %% menu.itemCount
		if isFocusable(&menu.items[next]) {
			menu.focused = next
			return
		}
	}
}

@(private="file")
checkRadio :: proc(menu: ^Menu, index: int) {
	item := &menu.items[index]
	if item.checked do return
	for &other in menu.items[:menu.itemCount] {
		if other.kind == .Radio && other.group == item.group do other.checked = false
	}
	item.checked = true
	if item.onChange != nil do item.onChange(menu, item)
}

@(private="file")
selectOption :: proc(menu: ^Menu, item: ^MenuItem, option: int) {
	if option == item.selectedOption do return
	item.selectedOption = option
	if item.onChange != nil do item.onChange(menu, item)
}

@(private="file")
setSliderValue :: proc(menu: ^Menu, item: ^MenuItem, value: f32) {
	snapped := snapSliderValue(item, value)
	if snapped == item.value do return
	item.value = snapped
	if item.onChange != nil do item.onChange(menu, item)
}

@(private="file")
setSliderFromX :: proc(menu: ^Menu, index: int, x: f32) {
	item := &menu.items[index]
	track := menuSliderTrack(menu, index)
	t := clamp((x - track.x) / track.w, 0, 1)
	setSliderValue(menu, item, item.minValue + t * (item.maxValue - item.minValue))
}

@(private="file")
itemAt :: proc(menu: ^Menu, point: [2]f32) -> (int, bool) {
	for i in 0..<menu.itemCount {
		if sdl.PointInRectFloat(sdl.FPoint(point), menuItemRect(menu, i)) do return i, true
	}
	return -1, false
}

@(private="file")
popupOptionAt :: proc(menu: ^Menu, point: [2]f32) -> (int, bool) {
	for i in 0..<len(menu.items[menu.focused].options) {
		if sdl.PointInRectFloat(sdl.FPoint(point), menuPopupOptionRect(menu, menu.focused, i)) do return i, true
	}
	return -1, false
}
