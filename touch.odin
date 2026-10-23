package crossfire

import "core:math"
import "core:math/linalg"
import "core:strings"
import sdl "vendor:sdl3"

/*
Touch input and on-screen controls: phones, tablets, Steam Deck and touch-screen laptops.

- **Touches** (`Input_GetTouches`, `Input_GetTouchCount`): every finger on the screen this frame,
  in game coordinates (the app converts SDL's finger positions like the mouse's), with where it
  started, how far it moved and whether it just went down or up. A finger keeps its index while
  it's down; lifted fingers are listed (released) for one frame.
- **The mouse from touches:** SDL also turns the first finger into mouse presses, so menus,
  buttons and anything else that reads the mouse work with touches already.
- **VirtualJoystick nodes**: a stick drawn on the screen, moved by a finger (or the mouse, to
  try it on a desktop). It pushes up to four input actions (`touchActions="move_left,move_right,
  move_up,move_down"`), so a game reading `Input_GetVector` moves the same with keys, a gamepad or
  the stick. `VirtualJoystick_GetVector` reads it directly. **Floating** joysticks appear where the
  thumb lands inside their zone.
- **TouchButton nodes**: a round button pressing an action while touched (`touchActions="jump"`),
  with a label, and `onPressed` / `onReleased` events.

Each control takes one finger: the first that lands in its zone, until it lifts (it can move
anywhere meanwhile). A finger taken by a control isn't taken by another. Controls hidden in the
tree, or in scenes not updating, take none.

**Where to put them:** on a layer the camera doesn't move (a scene's screen layers), so they stay
put on the screen; their position is the middle of the stick or button. They draw unturned and
unscaled (like Labels). By default they show only once the screen has been touched, or in
development runs (`Game.devKeys`: Play from the editor), so desktop players don't see them
(`TouchControlSettings.visibility`).

Example:
	stick := e.CreateVirtualJoystick(scene, {"move_left", "move_right", "move_up", "move_down"})
	stick.position = {120, 600}
	stick.layer = .Layer8
	jump := e.CreateTouchButton(scene, "jump", "A")
	jump.position = {1160, 620}
	jump.layer = .Layer8
*/

// A finger on the screen
Touch :: struct {
	// SDL's id for the finger (the same while it's down)
	id: sdl.FingerID,
	// Where it is, where it went down, and how far it moved this frame, in game coordinates
	position, start, motion: [2]f32,
	// How hard it presses (0 to 1; 1 on screens that can't tell)
	pressure: f32,
	// It went down this frame; it was lifted this frame (it's gone next frame)
	pressed, released: bool,
	// A VirtualJoystick or TouchButton took it
	claimed: bool,
}

// When a touch control shows
TouchVisibility :: enum {
	// Once the screen has been touched, or in development runs (Play from the editor)
	Touch_Screens,
	// Always (also on desktops without touches)
	Always,
	// Never (it still works: an invisible touch zone)
	Never,
}

// A VirtualJoystick's or TouchButton's settings (scene files' attributes; a plain value)
TouchControlSettings :: struct {
	// The stick's or button's radius, in game pixels
	radius: f32,
	// A stick moved less than this fraction of its radius counts as centered
	deadzone: f32,
	// The area that takes a finger, centered on the node (0 x 0: the circle itself)
	zone: [2]f32,
	// A joystick that starts where the finger lands in its zone (and goes back when it lifts)
	floating: bool,
	// When it's drawn
	visibility: TouchVisibility,
	// The mouse works it too (trying touch controls on a desktop)
	mouse: bool,
	// Its color (the knob and a pressed button are brighter) and opacity
	color: sdl.Color,
	opacity: f32,
}

// A joystick's defaults (a TouchButton's radius is TOUCH_BUTTON_RADIUS)
DEFAULT_TOUCH_CONTROL_SETTINGS :: TouchControlSettings{radius = 64, deadzone = 0.2, mouse = true, color = {255, 255, 255, 255}, opacity = 0.5}
// A TouchButton's radius by default
TOUCH_BUTTON_RADIUS :: 40

// A touch control kind's default settings (a button is smaller); other kinds get a joystick's
TouchControl_Defaults :: proc(kind: SceneNodeKind) -> TouchControlSettings {
	s := DEFAULT_TOUCH_CONTROL_SETTINGS
	if kind == .TouchButton do s.radius = TOUCH_BUTTON_RADIUS
	return s
}

// What a touch control is
TouchControlKind :: enum {
	Joystick,
	Button,
}

// The part VirtualJoystick and TouchButton share: settings, the finger it holds, its actions
TouchControl :: struct {
	// The node part: transform, hierarchy, hooks
	using node: Node,
	// Which control it is
	kind: TouchControlKind,
	// Its settings
	settings: TouchControlSettings,
	// The actions it presses: a joystick's left, right, up, down; a button's first ("" none). In
	// the node's arena
	actions: [4]string,
	// Being held: by a finger (its id), or by the mouse
	held, byMouse: bool,
	finger: sdl.FingerID,
	// Where the stick's base is now (a floating one moves), in game coordinates
	base: [2]f32,
	// The stick's position: -1..1 each way, deadzone applied (a button: {0, 0})
	value: [2]f32,
	// The input frame it last updated in (Input_Update uses controls that updated last frame)
	updatedFrame: u64,
}

// A stick on the screen moved by a finger, pushing input actions
VirtualJoystick :: struct {
	using control: TouchControl,
}

// A round button on the screen pressing an input action while touched
TouchButton :: struct {
	using control: TouchControl,
	// Its label (in the node's arena; "" none)
	text: string,
	// Touched (data: none); let go
	onPressed: EventSubject `event:"The button was touched"`,
	onReleased: EventSubject `event:"The finger left the button"`,
}

/*
Every finger on the screen this frame (and those lifted this frame, `released`).

Inputs:
- game: The game (nil: the current one)

Returns:
- The touches (valid until the next update)

Example:
	for touch in e.Input_GetTouches() {
		if touch.pressed && !touch.claimed do e.Debug_Circle(scene, touch.position, 20, {255, 0, 0, 255}, seconds = 0.5)
	}
*/
Input_GetTouches :: proc(game: ^Game = nil) -> []Touch {
	input := inputOf(game)
	if input == nil do return nil
	return input.touches[:]
}

// How many fingers are down (lifted ones not counted)
Input_GetTouchCount :: proc(game: ^Game = nil) -> int {
	input := inputOf(game)
	if input == nil do return 0
	n := 0
	for t in input.touches do if !t.released do n += 1
	return n
}

// Whether the screen has been touched since the game started (touch controls show then)
Input_IsTouchScreen :: proc(game: ^Game = nil) -> bool {
	input := inputOf(game)
	return input != nil && input.touched
}

/*
Creates a VirtualJoystick and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- actions: The input actions it pushes: left, right, up, down ("" for none)
- settings: Its radius, deadzone, zone, look

Returns:
- The joystick

Example:
	stick := e.CreateVirtualJoystick(scene, {"move_left", "move_right", "move_up", "move_down"})
	stick.settings.floating = true
	stick.settings.zone = {400, 400}
*/
CreateVirtualJoystick :: proc(scene: ^Scene, actions: [4]string = {}, settings := DEFAULT_TOUCH_CONTROL_SETTINGS) -> ^VirtualJoystick {
	j := CreateNode(scene, VirtualJoystick)
	touchControlInit(j, .Joystick, settings)
	allocator := Node_GetAllocator(j)
	for a, i in actions do j.actions[i] = strings.clone(a, allocator)
	return j
}

/*
Creates a TouchButton and adds it to the scene (at the start of the next update).

Inputs:
- scene: The scene
- action: The input action it presses ("" none: listen to `onPressed`)
- text: Its label
- settings: Its radius, zone, look (the radius defaults to TOUCH_BUTTON_RADIUS)

Returns:
- The button

Example:
	jump := e.CreateTouchButton(scene, "jump", "A")
	jump.position = {1160, 620}
*/
CreateTouchButton :: proc(scene: ^Scene, action: ActionName = "", text := "", settings := TouchControlSettings{}) -> ^TouchButton {
	b := CreateNode(scene, TouchButton)
	s := settings
	if s == {} {
		s = DEFAULT_TOUCH_CONTROL_SETTINGS
		s.radius = TOUCH_BUTTON_RADIUS
	}
	touchControlInit(b, .Button, s)
	allocator := Node_GetAllocator(b)
	b.actions[0] = strings.clone(action, allocator)
	b.text = strings.clone(text, allocator)
	EventSubject_Init(&b.onPressed, allocator)
	EventSubject_Init(&b.onReleased, allocator)
	return b
}

// A joystick's position: -1..1 each way (x right, y down), the deadzone applied
VirtualJoystick_GetVector :: proc(joystick: ^VirtualJoystick) -> [2]f32 {
	if joystick == nil do return {}
	return joystick.value
}

// Whether a touch button is held
TouchButton_IsPressed :: proc(button: ^TouchButton) -> bool {
	return button != nil && button.held
}

/*
Sets the actions a touch control presses (a joystick's left, right, up, down; a button's
first).

Inputs:
- control: A VirtualJoystick or TouchButton
- actions: The action names ("" none)
*/
TouchControl_SetActions :: proc(control: ^TouchControl, actions: [4]string) {
	allocator := Node_GetAllocator(control)
	for a, i in actions do control.actions[i] = strings.clone(a, allocator)
}

/*
A control's actions as scene files store them: comma-separated, a joystick's left, right, up,
down (`"move_left,move_right,move_up,move_down"`; empty ones for none).

Inputs:
- text: The comma-separated names

Returns:
- The four names (slices of `text`)
*/
TouchControl_ParseActions :: proc(text: string) -> (actions: [4]string) {
	rest := text
	for i in 0 ..< 4 {
		if rest == "" do break
		name, _, after := strings.partition(rest, ",")
		actions[i] = strings.trim_space(name)
		rest = after
	}
	return
}

// The actions as scene files store them (temp allocated; trailing empty ones left out)
TouchControl_FormatActions :: proc(given: [4]string) -> string {
	actions := given
	last := -1
	for a, i in actions do if a != "" do last = i
	if last < 0 do return ""
	return strings.join(actions[:last + 1], ",", context.temp_allocator)
}

// INTERNAL

@(private="file")
touchControlInit :: proc(c: ^TouchControl, kind: TouchControlKind, settings: TouchControlSettings) {
	c.kind = kind
	c.settings = settings
	c.transformMode = .Position_Only
	c.update = touchControlUpdate
	c.draw = touchControlDraw
	c.destroy = touchControlDestroy
	c.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
		c := cast(^TouchControl)node
		r := max(c.settings.radius, 1)
		w, h := max(c.settings.zone.x, r * 2), max(c.settings.zone.y, r * 2)
		return {-w / 2, -h / 2, w, h}, true
	}
	if c.scene != nil && c.scene.game != nil {
		input := &c.scene.game.input
		if input.touchControls == nil do input.touchControls = make([dynamic]^TouchControl)
		append(&input.touchControls, c)
	}
}

// Marks it as updating: Input_Update hands it fingers next frame
@(private="file")
touchControlUpdate :: proc(node: ^Node, events: []sdl.Event, deltaTime: f64) {
	c := cast(^TouchControl)node
	if c.scene != nil && c.scene.game != nil do c.updatedFrame = c.scene.game.input.frame
}

@(private="file")
touchControlDestroy :: proc(node: ^Node) {
	c := cast(^TouchControl)node
	if c.scene == nil || c.scene.game == nil do return
	list := &c.scene.game.input.touchControls
	for other, i in list do if other == c {
		unordered_remove(list, i)
		break
	}
	// The last one gone: the list too (games that never reach Input_Destroy, editors' previews)
	if len(list) == 0 {
		delete(list^)
		list^ = nil
	}
}

@(private="file")
touchControlDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	c := cast(^TouchControl)node
	game := c.scene != nil ? c.scene.game : nil
	switch c.settings.visibility {
	case .Never:
		return
	case .Always:
	case .Touch_Screens:
		if game == nil || !(game.input.touched || game.devKeys || game.input.showTouchControls) do return
	}
	color :: proc(c: sdl.Color, opacity: f32, brightness: f32 = 1) -> sdl.Color {
		return {u8(f32(c.r) * brightness), u8(f32(c.g) * brightness), u8(f32(c.b) * brightness), u8(clamp(f32(c.a) * opacity, 0, 255))}
	}
	s := c.settings
	r := max(s.radius, 1)
	// Drawn in its local space (unturned, unscaled): the base is where the stick is now
	offset := [2]f32{}
	if c.held && c.kind == .Joystick do offset = c.base - Node_GetScreenPosition(c)
	center := sdl.FPoint{offset.x, offset.y}
	switch c.kind {
	case .Joystick:
		DrawCircle(renderer, center, r, color(s.color, s.opacity * 0.35, 0.6))
		DrawCircleOutline(renderer, center, r, color(s.color, s.opacity))
		knob := center + sdl.FPoint{c.value.x, c.value.y} * r * 0.6
		DrawCircle(renderer, knob, r * 0.4, color(s.color, c.held ? min(s.opacity * 1.6, 1) : s.opacity))
	case .Button:
		b := cast(^TouchButton)c
		DrawCircle(renderer, center, r, color(s.color, c.held ? min(s.opacity * 1.6, 1) : s.opacity * 0.6, c.held ? 1 : 0.7))
		DrawCircleOutline(renderer, center, r, color(s.color, s.opacity))
		if b.text != "" && game != nil {
			DrawTextCentered(&game.resourceManager, center, b.text, DEFAULT_FONT, r * 0.7, color({0, 0, 0, 255}, max(s.opacity, 0.6)))
		}
	}
}

// Fingers down, moved and lifted (Input_Update)
@(private)
touchEvent :: proc(input: ^InputState, event: ^sdl.Event) {
	f := event.tfinger
	position := [2]f32{f.x, f.y}
	#partial switch event.type {
	case .FINGER_DOWN:
		input.touched = true
		if input.touches == nil do input.touches = make([dynamic]Touch)
		append(&input.touches, Touch{id = f.fingerID, position = position, start = position, pressure = f.pressure, pressed = true})
	case .FINGER_MOTION:
		for &t in input.touches do if t.id == f.fingerID && !t.released {
			t.motion += position - t.position
			t.position = position
			t.pressure = f.pressure
		}
	case .FINGER_UP, .FINGER_CANCELED:
		for &t in input.touches do if t.id == f.fingerID && !t.released {
			t.position = position
			t.released = true
		}
	}
}

// Last frame's lifted fingers go; this frame's flags clear (Input_Update, before the events)
@(private)
touchesBeginFrame :: proc(input: ^InputState) {
	input.frame += 1
	for i := 0; i < len(input.touches); {
		if input.touches[i].released {
			ordered_remove(&input.touches, i)
			continue
		}
		input.touches[i].pressed = false
		input.touches[i].motion = {}
		i += 1
	}
}

// Controls take fingers (or the mouse) and work out their values (Input_Update, after the events)
@(private)
touchControlsUpdate :: proc(input: ^InputState) {
	for &t in input.touches do t.claimed = false
	for c in input.touchControls {
		// Controls whose scene isn't updating (or hidden ones) let go
		active := c.updatedFrame + 1 >= input.frame && c.updatedFrame != 0 && Node_IsVisibleInTree(c)
		was := c.held
		if !active {
			touchControlRelease(c)
			touchControlEvents(c, was)
			continue
		}
		center := Node_GetScreenPosition(c)
		s := c.settings
		r := max(s.radius, 1)
		inZone :: proc(p, center: [2]f32, s: TouchControlSettings, r: f32) -> bool {
			if s.zone.x > 0 && s.zone.y > 0 do return abs(p.x - center.x) <= s.zone.x / 2 && abs(p.y - center.y) <= s.zone.y / 2
			return linalg.length(p - center) <= r
		}
		// Still held: its finger (lifted: let go), or the mouse button
		point: [2]f32
		if c.held && !c.byMouse {
			found := false
			for &t in input.touches do if t.id == c.finger {
				t.claimed = true
				if t.released do break
				found = true
				point = t.position
			}
			if !found do touchControlRelease(c)
		} else if c.held && c.byMouse {
			if input.mouse[.Left] && !input.mouseFromTouch do point = input.mousePosition
			else do touchControlRelease(c)
		}
		// Not held: a finger that just landed in its zone, or a mouse press there
		if !c.held {
			for &t in input.touches do if t.pressed && !t.claimed && !t.released && inZone(t.position, center, s, r) {
				t.claimed = true
				c.held, c.byMouse, c.finger = true, false, t.id
				point = t.position
				c.base = s.floating && c.kind == .Joystick ? t.position : center
				break
			}
			if !c.held && s.mouse && input.mousePressed[.Left] && !input.mouseFromTouch && inZone(input.mousePosition, center, s, r) {
				c.held, c.byMouse = true, true
				point = input.mousePosition
				c.base = s.floating && c.kind == .Joystick ? input.mousePosition : center
			}
		}
		c.value = {}
		if c.held && c.kind == .Joystick {
			if !s.floating do c.base = center
			v := (point - c.base) / r
			length := linalg.length(v)
			if length > 1 do v /= length
			length = min(length, 1)
			// The deadzone: centered below it, then rescaled to start at 0
			if length <= s.deadzone {
				v = {}
			} else {
				v = v / length * ((length - s.deadzone) / max(1 - s.deadzone, 0.0001))
			}
			c.value = v
		}
		touchControlEvents(c, was)
	}
}

// The strength a touch control gives an action this frame (actions' strength: the strongest)
@(private)
touchActionStrength :: proc(input: ^InputState, name: string) -> f32 {
	best: f32
	for c in input.touchControls {
		if !c.held do continue
		switch c.kind {
		case .Joystick:
			// left, right, up, down
			pushes := [4]f32{max(-c.value.x, 0), max(c.value.x, 0), max(-c.value.y, 0), max(c.value.y, 0)}
			for a, i in c.actions do if a != "" && a == name do best = max(best, pushes[i])
		case .Button:
			if c.actions[0] != "" && c.actions[0] == name do best = 1
		}
	}
	return math.clamp(best, 0, 1)
}

@(private="file")
touchControlRelease :: proc(c: ^TouchControl) {
	c.held, c.byMouse, c.finger = false, false, 0
	c.value = {}
}

@(private="file")
touchControlEvents :: proc(c: ^TouchControl, was: bool) {
	if c.kind != .Button || was == c.held do return
	b := cast(^TouchButton)c
	if c.held do Event_Notify(&b.onPressed, b, nil)
	else do Event_Notify(&b.onReleased, b, nil)
}
