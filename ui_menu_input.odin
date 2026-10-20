package crossfire

import sdl "vendor:sdl3"

// MENU INPUT HANDLING

/*
The input action that moves a menu's focus up.

Menus navigate with the MENU_ACTION_* input actions when the game has `MENU_ACTION_ACCEPT`
(Godot's names; the editor adds them to new projects, bound to arrows / WASD, the d-pad and the
left stick to move, Enter / Space and the gamepad's South button to press, Escape and East to go
back). A game without them gets the keys only.
*/
MENU_ACTION_UP :: "ui_up"
// The input action that moves a menu's focus down (see `MENU_ACTION_UP`)
MENU_ACTION_DOWN :: "ui_down"
// The input action that decreases a slider, steps radios back and cycles select options back (see `MENU_ACTION_UP`)
MENU_ACTION_LEFT :: "ui_left"
// The input action that increases a slider, steps radios forward and cycles select options forward (see `MENU_ACTION_UP`)
MENU_ACTION_RIGHT :: "ui_right"
// The input action that presses the focused item. Its presence makes menus use the actions instead of the keys
MENU_ACTION_ACCEPT :: "ui_accept"
// The input action that closes an open dropdown or runs `Menu.onBack` (see `MENU_ACTION_UP`)
MENU_ACTION_CANCEL :: "ui_cancel"

// Seconds a menu direction action is held before it starts repeating (every `MENU_REPEAT_INTERVAL`)
MENU_REPEAT_DELAY :: 0.4
// Seconds between repeats of a held menu direction action, after `MENU_REPEAT_DELAY`
MENU_REPEAT_INTERVAL :: 0.08

// What a key press or an action asks a menu to do (see `Menu_Command`)
MenuCommand :: enum u8 {
	// Does nothing
	None,
	Up,
	Down,
	Left,
	Right,
	Accept,
	Cancel,
}

@(private)
Menu_update :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	menu := cast(^Menu)node
	defer reportFocus(menu)
	if !Node_IsVisibleInTree(menu) do return
	// Item rects are relative to the menu's origin; mouse events are in screen coordinates
	origin := Node_GetScreenPosition(menu)

	// Commands return true after a button press or onBack, which commonly switch scenes.
	// Remaining input is then left alone so it doesn't act on a menu that is going away
	game := menu.scene != nil ? menu.scene.game : nil
	useActions := game != nil && Input_HasAction(MENU_ACTION_ACCEPT, game)
	if useActions && navigateByActions(menu, game, deltaTime) do return

	for &event in events {
		#partial switch event.type {
		case .KEY_DOWN:
			if !useActions && Menu_Command(menu, keyCommand(event.key.scancode), event.key.repeat) do return

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

/*
Does what a navigation command asks, as a key or an action would: move the focus, adjust the
focused item, press it, or go back. For games that drive menus themselves (another input, a
tutorial's script). While a select's dropdown is open, Up / Down move its highlight, Accept picks
the option and Cancel closes it; Left / Right do nothing.

Inputs:
- menu: The menu
- command: What to do
- repeat: It comes from a held key or direction repeating (pressing and going back don't repeat)

Returns:
- true when a button was pressed or onBack ran (the menu may be going away: stop using it)

Example:
	// Given: menu: ^e.Menu
	if e.Menu_Command(menu, .Accept) do return
	e.Menu_Command(menu, .Down)
*/
Menu_Command :: proc(menu: ^Menu, command: MenuCommand, repeat := false) -> bool {
	// An open dropdown takes all navigation until it closes
	if menu.popupOpen {
		item := &menu.items[menu.focused]
		count := len(item.options)
		#partial switch command {
		case .Up:
			menu.popupHover = (menu.popupHover - 1 + count) % count
		case .Down:
			menu.popupHover = (menu.popupHover + 1) % count
		case .Accept:
			if !repeat {
				selectOption(menu, item, menu.popupHover)
				menu.popupOpen = false
			}
		case .Cancel:
			if !repeat do menu.popupOpen = false
		}
		return false
	}

	switch command {
	case .None:
	case .Up:
		moveFocus(menu, -1)
	case .Down:
		moveFocus(menu, 1)
	case .Left:
		adjustFocused(menu, -1)
	case .Right:
		adjustFocused(menu, 1)
	case .Accept:
		if !repeat && menu.focused >= 0 {
			return activate(menu, menu.focused)
		}
	case .Cancel:
		if !repeat {
			Event_Notify(&menu.onBackPressed, menu, nil)
			if menu.onBack != nil {
				menu.onBack(menu, nil)
				return true
			}
			return len(menu.onBackPressed.listeners) > 0
		}
	}
	return false
}

@(private="file")
keyCommand :: proc(scancode: sdl.Scancode) -> MenuCommand {
	#partial switch scancode {
	case .UP, .W:                   return .Up
	case .DOWN, .S:                 return .Down
	case .LEFT, .A:                 return .Left
	case .RIGHT, .D:                return .Right
	case .RETURN, .KP_ENTER, .SPACE: return .Accept
	case .ESCAPE:                   return .Cancel
	}
	return .None
}

// The ui_* actions this frame: presses, and held directions repeating
@(private="file")
navigateByActions :: proc(menu: ^Menu, game: ^Game, deltaTime: f64) -> bool {
	if Input_IsActionJustPressed(MENU_ACTION_ACCEPT, game) && Menu_Command(menu, .Accept) do return true
	if Input_IsActionJustPressed(MENU_ACTION_CANCEL, game) && Menu_Command(menu, .Cancel) do return true

	DIRECTIONS :: [?]struct{action: string, command: MenuCommand}{
		{MENU_ACTION_UP, .Up}, {MENU_ACTION_DOWN, .Down}, {MENU_ACTION_LEFT, .Left}, {MENU_ACTION_RIGHT, .Right},
	}
	for direction in DIRECTIONS {
		if Input_IsActionJustPressed(direction.action, game) {
			menu.held = direction.command
			menu.repeatTimer = MENU_REPEAT_DELAY
			_ = Menu_Command(menu, direction.command)
		}
	}
	if menu.held == .None do return false
	heldAction: string
	for direction in DIRECTIONS do if direction.command == menu.held do heldAction = direction.action
	if !Input_IsActionPressed(heldAction, game) {
		menu.held = .None
		return false
	}
	menu.repeatTimer -= f32(deltaTime)
	for menu.repeatTimer <= 0 {
		menu.repeatTimer += MENU_REPEAT_INTERVAL
		_ = Menu_Command(menu, menu.held, repeat = true)
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
		Event_Notify(&menu.onButtonPressed, menu, index)
		return true
	case .Checkbox:
		item.checked = !item.checked
		if item.onChange != nil do item.onChange(menu, item)
		Event_Notify(&menu.onValueChanged, menu, index)
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
	Event_Notify(&menu.onValueChanged, menu, index)
}

@(private="file")
selectOption :: proc(menu: ^Menu, item: ^MenuItem, option: int) {
	if option == item.selectedOption do return
	item.selectedOption = option
	if item.onChange != nil do item.onChange(menu, item)
	Event_Notify(&menu.onValueChanged, menu, itemIndex(menu, item))
}

@(private="file")
setSliderValue :: proc(menu: ^Menu, item: ^MenuItem, value: f32) {
	snapped := snapSliderValue(item, value)
	if snapped == item.value do return
	item.value = snapped
	if item.onChange != nil do item.onChange(menu, item)
	Event_Notify(&menu.onValueChanged, menu, itemIndex(menu, item))
}

// An item's index in its menu's items
@(private="file")
itemIndex :: proc(menu: ^Menu, item: ^MenuItem) -> int {
	return int((uintptr(item) - uintptr(&menu.items[0])) / size_of(MenuItem))
}

// Notifies onFocusChanged when the focus moved since the last update (the first only records it)
@(private="file")
reportFocus :: proc(menu: ^Menu) {
	if menu.focusReported && menu.focused != menu.reportedFocus && menu.focused >= 0 {
		Event_Notify(&menu.onFocusChanged, menu, menu.focused)
	}
	menu.reportedFocus = menu.focused
	menu.focusReported = true
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
