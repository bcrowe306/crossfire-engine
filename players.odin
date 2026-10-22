package crossfire

import "core:fmt"
import "core:log"
import "core:math"
import sdl "vendor:sdl3"

/*
Local multiplayer: players joining with a device (a gamepad, or the keyboard and mouse), each
reading the project's input actions from their own device only.

- **Joining** (`Players_StartJoining`): while joining is on (a lobby), a press of the join input on
  a device no player has adds a player with that device: by default a gamepad's South (Xbox A) or
  Start button, or the keyboard's Enter or Space; with the project's `joinAction` set, that
  action on the device. `Players_Join` adds one from code (a single-player game can make player 0
  the keyboard at start). At most `maxPlayers`.
- **Per-player input:** `Player_IsActionPressed(1, "jump")`, `Player_GetVector(1, ...)` read the
  same actions as `Input_IsActionPressed`, from that player's device: a gamepad player's gamepad
  bindings (any device number in them is ignored: the player's own pad), the keyboard player's key
  and mouse bindings (and touch controls). `Input_IsActionPressed` still reads every device.
- **Disconnects:** a player whose gamepad is unplugged stays (`connected` false, `onDisconnected`);
  the next gamepad plugged in while one is missing goes back to the first player waiting
  (`onReconnected`). `Players_Leave` removes a player; the later ones move down a number.
- **Events** (`Game.input.players`): `onJoined` (data: the player's number, an int), `onLeft`,
  `onDisconnected`, `onReconnected`.
- **Split screen:** a CameraView per player (camera_tools.odin) placed by `SplitScreen_Rect`.

Players are numbered from 0 in the order they joined.

Example:
	// A lobby: everyone presses A (or Enter) to join
	e.Players_StartJoining()
	// Later, in a player's script (its `player` field is exported: set per node)
	// move := e.Player_GetVector(self.player, "left", "right", "up", "down")
*/

// The most local players a game can have
MAX_LOCAL_PLAYERS :: 8

// What a player plays with
PlayerDeviceKind :: enum {
	// The keyboard and mouse (and touch controls)
	Keyboard,
	// A gamepad
	Gamepad,
}

// A local player
Player :: struct {
	// Its number (0 the first to join)
	index: int,
	// What it plays with
	device: PlayerDeviceKind,
	// Its gamepad (SDL's id; kept while unplugged, to tell it apart)
	gamepad: sdl.JoystickID,
	// Its gamepad is plugged in (a keyboard player always is)
	connected: bool,
	// Its actions this frame (one per input action, in order)
	actions: [dynamic]PlayerActionState,
}

// A player's action this frame
PlayerActionState :: struct {
	strength: f32,
	down, pressed, released: bool,
}

// The project's players settings (project.xml's `<players max keyboard joinAction/>`)
PlayerSettings :: struct {
	// The most that can join (1 to MAX_LOCAL_PLAYERS)
	maxPlayers: int,
	// The keyboard (and mouse) can be a player's device
	keyboard: bool,
	// The input action that joins ("": a gamepad's South or Start, the keyboard's Enter or Space).
	// In the game's arena
	joinAction: string,
}

// Four players, the keyboard among them, joining with the default buttons
DEFAULT_PLAYER_SETTINGS :: PlayerSettings{maxPlayers = 4, keyboard = true}

// The game's players (`InputState.players`)
PlayersState :: struct {
	settings: PlayerSettings,
	// Joining is on (`Players_StartJoining`)
	joining: bool,
	// The players, in order
	list: [dynamic]Player,
	// A player joined, left, lost its gamepad, got one back (data: the player's number)
	onJoined, onLeft, onDisconnected, onReconnected: EventSubject,
	// The events are set up (Players_Setup, or on first use)
	ready: bool,
}

/*
Sets the players settings (Game_LoadProject does it with the project's).

Inputs:
- game: The game
- settings: Max players, the keyboard, the join action (copied)
*/
Players_Setup :: proc(game: ^Game, settings: PlayerSettings) {
	p := playersReady(game)
	p.settings = settings
	p.settings.maxPlayers = clamp(settings.maxPlayers, 1, MAX_LOCAL_PLAYERS)
	p.settings.joinAction = clone(settings.joinAction, Game_GetAllocator(game))
	if p.settings != DEFAULT_PLAYER_SETTINGS {
		log.infof("Local players: up to %d%s, joining with %s", p.settings.maxPlayers, p.settings.keyboard ? " (the keyboard too)" : "",
			p.settings.joinAction != "" ? p.settings.joinAction : "South / Start, Enter / Space")
	}
}

// Turns joining on: a press of the join input on a free device adds a player
Players_StartJoining :: proc(game: ^Game = nil) {
	if g := gameOf(game); g != nil do playersReady(g).joining = true
}

// Turns joining off (the lobby is done)
Players_StopJoining :: proc(game: ^Game = nil) {
	if g := gameOf(game); g != nil do playersReady(g).joining = false
}

// Whether joining is on
Players_IsJoining :: proc(game: ^Game = nil) -> bool {
	g := gameOf(game)
	return g != nil && g.input.players.joining
}

/*
Adds a player with a device, from code.

Inputs:
- device: The keyboard, or a gamepad
- gamepad: Which gamepad (its number among the connected ones, 0 the first) for a gamepad player
- game: The game (nil: the current one)

Returns:
- The new player's number; -1 when the game is full, the device is taken, or there's no such
  gamepad

Example:
	// A one-player game: the keyboard is player 0
	e.Players_Join(.Keyboard)
*/
Players_Join :: proc(device: PlayerDeviceKind, gamepad := 0, game: ^Game = nil) -> int {
	g := gameOf(game)
	if g == nil do return -1
	switch device {
	case .Keyboard:
		return playerAdd(g, .Keyboard, 0)
	case .Gamepad:
		if gamepad < 0 || gamepad >= len(g.input.gamepads) do return -1
		return playerAdd(g, .Gamepad, g.input.gamepads[gamepad].id)
	}
	return -1
}

/*
Removes a player. The players after it move down a number (player 2 becomes 1).

Inputs:
- index: The player's number
- game: The game (nil: the current one)
*/
Players_Leave :: proc(index: int, game: ^Game = nil) {
	g := gameOf(game)
	if g == nil do return
	p := playersReady(g)
	if index < 0 || index >= len(p.list) do return
	delete(p.list[index].actions)
	ordered_remove(&p.list, index)
	for &player, i in p.list do player.index = i
	log.infof("Player %d left", index + 1)
	Event_Notify(&p.onLeft, nil, index)
}

// Removes every player
Players_Clear :: proc(game: ^Game = nil) {
	g := gameOf(game)
	if g == nil do return
	p := &g.input.players
	for len(p.list) > 0 do Players_Leave(len(p.list) - 1, g)
}

// How many players have joined
Players_Count :: proc(game: ^Game = nil) -> int {
	g := gameOf(game)
	return g != nil ? len(g.input.players.list) : 0
}

// A player (nil: no such player); valid until a player joins or leaves
Players_Get :: proc(index: int, game: ^Game = nil) -> ^Player {
	g := gameOf(game)
	if g == nil || index < 0 || index >= len(g.input.players.list) do return nil
	return &g.input.players.list[index]
}

// Whether a player's action is held
Player_IsActionPressed :: proc(player: int, name: string, game: ^Game = nil) -> bool {
	a := playerAction(player, name, game)
	return a != nil && a.down
}

// Whether a player's action went down this frame
Player_IsActionJustPressed :: proc(player: int, name: string, game: ^Game = nil) -> bool {
	a := playerAction(player, name, game)
	return a != nil && a.pressed
}

// Whether a player's action was let go this frame
Player_IsActionJustReleased :: proc(player: int, name: string, game: ^Game = nil) -> bool {
	a := playerAction(player, name, game)
	return a != nil && a.released
}

// How strongly a player's action is pressed (0 to 1)
Player_GetActionStrength :: proc(player: int, name: string, game: ^Game = nil) -> f32 {
	a := playerAction(player, name, game)
	return a != nil ? a.strength : 0
}

// A player's axis from two actions: positive minus negative (-1 to 1)
Player_GetAxis :: proc(player: int, negative, positive: string, game: ^Game = nil) -> f32 {
	return Player_GetActionStrength(player, positive, game) - Player_GetActionStrength(player, negative, game)
}

/*
A player's direction from four actions, at most 1 long (diagonals aren't faster).

Inputs:
- player: The player's number
- negativeX, positiveX, negativeY, positiveY: Left, right, up, down
- game: The game (nil: the current one)

Returns:
- The direction (y down)
*/
Player_GetVector :: proc(player: int, negativeX, positiveX, negativeY, positiveY: string, game: ^Game = nil) -> [2]f32 {
	v := [2]f32{Player_GetAxis(player, negativeX, positiveX, game), Player_GetAxis(player, negativeY, positiveY, game)}
	length := math.sqrt(v.x * v.x + v.y * v.y)
	if length > 1 do v /= length
	return v
}

// Rumbles a gamepad player's gamepad (low and high frequency motors 0 to 1). Returns whether it took
Player_Rumble :: proc(player: int, low, high: f32, seconds: f32, game: ^Game = nil) -> bool {
	g := gameOf(game)
	p := Players_Get(player, g)
	if p == nil || p.device != .Gamepad || !p.connected do return false
	i := gamepadIndex(&g.input, p.gamepad)
	if i < 0 do return false
	return Input_Rumble(low, high, seconds, i, g)
}

// What a player plays with, for a lobby ("Keyboard", the gamepad's name, "(unplugged)")
Player_DeviceName :: proc(player: int, game: ^Game = nil) -> string {
	g := gameOf(game)
	p := Players_Get(player, g)
	if p == nil do return ""
	if p.device == .Keyboard do return "Keyboard"
	if !p.connected do return "(unplugged)"
	i := gamepadIndex(&g.input, p.gamepad)
	if i < 0 || g.input.gamepads[i].handle == nil do return fmt.tprintf("Gamepad %d", i + 1)
	return string(sdl.GetGamepadName(g.input.gamepads[i].handle))
}

/*
Where a player's view goes on a split screen: the area split for `count` players (1: all of it;
2: side by side; 3: one on top, two below; 4: four corners; more: a grid of columns).

Inputs:
- player: The player's number (0 first)
- count: How many players share the screen
- area: The screen (the game's size)
- gap: Pixels between views

Returns:
- The player's rectangle

Example:
	// Given: views: []^e.CameraView, one per player
	for view, i in views {
		r := e.SplitScreen_Rect(i, len(views), game.size)
		view.position = {r.x, r.y}
		view.size = {r.w, r.h}
	}
*/
SplitScreen_Rect :: proc(player, count: int, area: [2]f32, gap: f32 = 0) -> sdl.FRect {
	n := max(count, 1)
	i := clamp(player, 0, n - 1)
	cell :: proc(column, row, columns, rows: int, area: [2]f32, gap: f32) -> sdl.FRect {
		w := (area.x - gap * f32(columns - 1)) / f32(columns)
		h := (area.y - gap * f32(rows - 1)) / f32(rows)
		return {f32(column) * (w + gap), f32(row) * (h + gap), w, h}
	}
	switch n {
	case 1: return {0, 0, area.x, area.y}
	case 2: return cell(i, 0, 2, 1, area, gap)
	case 3:
		if i == 0 do return {0, 0, area.x, (area.y - gap) / 2}
		return cell(i - 1, 1, 2, 2, area, gap)
	case 4: return cell(i % 2, i / 2, 2, 2, area, gap)
	}
	columns := int(math.ceil(math.sqrt(f32(n))))
	rows := (n + columns - 1) / columns
	return cell(i % columns, i / columns, columns, rows, area, gap)
}

// INTERNAL

@(private="file")
gameOf :: proc(game: ^Game) -> ^Game {
	return game != nil ? game : currentGame
}

@(private="file")
clone :: proc(s: string, allocator := context.allocator) -> string {
	if s == "" do return ""
	out := make([]u8, len(s), allocator)
	copy(out, s)
	return string(out)
}

// The players state with its events set up
@(private="file")
playersReady :: proc(game: ^Game) -> ^PlayersState {
	p := &game.input.players
	if !p.ready {
		allocator := Game_GetAllocator(game)
		EventSubject_Init(&p.onJoined, allocator)
		EventSubject_Init(&p.onLeft, allocator)
		EventSubject_Init(&p.onDisconnected, allocator)
		EventSubject_Init(&p.onReconnected, allocator)
		if p.settings.maxPlayers == 0 do p.settings = DEFAULT_PLAYER_SETTINGS
		p.ready = true
	}
	return p
}

@(private="file")
playerAdd :: proc(game: ^Game, device: PlayerDeviceKind, gamepad: sdl.JoystickID) -> int {
	p := playersReady(game)
	if len(p.list) >= p.settings.maxPlayers do return -1
	for other in p.list {
		if device == .Keyboard && other.device == .Keyboard do return -1
		if device == .Gamepad && other.device == .Gamepad && other.gamepad == gamepad do return -1
	}
	if device == .Keyboard && !p.settings.keyboard do return -1
	if p.list == nil do p.list = make([dynamic]Player)
	index := len(p.list)
	append(&p.list, Player{index = index, device = device, gamepad = gamepad, connected = true})
	log.infof("Player %d joined (%v)", index + 1, device)
	Event_Notify(&p.onJoined, nil, index)
	return index
}

@(private="file")
playerAction :: proc(player: int, name: string, game: ^Game) -> ^PlayerActionState {
	g := gameOf(game)
	if g == nil do return nil
	p := Players_Get(player, g)
	if p == nil do return nil
	for a, i in g.input.actions do if a.data.name == name {
		if i < len(p.actions) do return &p.actions[i]
		return nil
	}
	_ = findAction(g, name) // warns once about an unknown name
	return nil
}

// Gamepads plugged in and out (Input_Update's events)
@(private)
playersGamepadAdded :: proc(input: ^InputState, id: sdl.JoystickID) {
	p := &input.players
	for &player in p.list do if player.device == .Gamepad && !player.connected {
		player.gamepad = id
		player.connected = true
		log.infof("Player %d's gamepad is back", player.index + 1)
		if p.ready do Event_Notify(&p.onReconnected, nil, player.index)
		return
	}
}

@(private)
playersGamepadRemoved :: proc(input: ^InputState, id: sdl.JoystickID) {
	p := &input.players
	for &player in p.list do if player.device == .Gamepad && player.gamepad == id && player.connected {
		player.connected = false
		log.infof("Player %d's gamepad was unplugged", player.index + 1)
		if p.ready do Event_Notify(&p.onDisconnected, nil, player.index)
	}
}

// Joins from this frame's presses, then each player's actions (Input_Update, after the game's)
@(private)
playersUpdate :: proc(input: ^InputState, game: ^Game) {
	p := &input.players
	if p.joining && game != nil {
		// A gamepad no player has
		for &pad in input.gamepads {
			taken := false
			for player in p.list do if player.device == .Gamepad && player.gamepad == pad.id do taken = true
			if taken do continue
			if playerJoinPressed(input, .Gamepad, pad.id) do playerAdd(game, .Gamepad, pad.id)
		}
		// The keyboard
		if p.settings.keyboard {
			taken := false
			for player in p.list do if player.device == .Keyboard do taken = true
			if !taken && playerJoinPressed(input, .Keyboard, 0) do playerAdd(game, .Keyboard, 0)
		}
	}
	for &player in p.list {
		if len(player.actions) != len(input.actions) do resize(&player.actions, len(input.actions))
		for &a, i in input.actions {
			strength := playerActionStrength(input, &player, &a)
			state := &player.actions[i]
			down := strength > 0
			state.pressed = down && !state.down
			state.released = !down && state.down
			state.down = down
			state.strength = strength
		}
	}
}

// Frees the players (Input_Destroy)
@(private)
playersDestroy :: proc(input: ^InputState) {
	for player in input.players.list do delete(player.actions)
	delete(input.players.list)
	input.players.list = nil
}

// The join input pressed this frame on a device
@(private="file")
playerJoinPressed :: proc(input: ^InputState, device: PlayerDeviceKind, gamepad: sdl.JoystickID) -> bool {
	join := input.players.settings.joinAction
	if join != "" {
		for &a in input.actions do if a.data.name == join {
			// Its bindings on this device, pressed this frame
			probe := Player{device = device, gamepad = gamepad, connected = true}
			return playerActionStrength(input, &probe, &a, pressedOnly = true) > 0
		}
		return false
	}
	switch device {
	case .Keyboard:
		return input.keysPressed[.Enter] || input.keysPressed[.Space]
	case .Gamepad:
		i := gamepadIndex(input, gamepad)
		return i >= 0 && (input.gamepads[i].pressed[.South] || input.gamepads[i].pressed[.Start])
	}
	return false
}

// An action's strength from one player's device (pressedOnly: buttons and keys that went down
// this frame)
@(private="file")
playerActionStrength :: proc(input: ^InputState, player: ^Player, a: ^ActionState, pressedOnly := false) -> f32 {
	best: f32
	switch player.device {
	case .Keyboard:
		for binding in a.data.bindings {
			#partial switch b in binding {
			case KeyBinding:
				if pressedOnly ? input.keysPressed[b.key] : input.keys[b.key] do best = 1
			case MouseBinding:
				if pressedOnly ? input.mousePressed[b.button] : input.mouse[b.button] do best = 1
			}
		}
		if !pressedOnly && len(input.touchControls) > 0 do best = max(best, touchActionStrength(input, a.data.name))
	case .Gamepad:
		if !player.connected do return 0
		i := gamepadIndex(input, player.gamepad)
		if i < 0 do return 0
		pad := &input.gamepads[i]
		for binding in a.data.bindings {
			#partial switch b in binding {
			case GamepadButtonBinding:
				if pressedOnly ? pad.pressed[b.button] : pad.down[b.button] do best = 1
			case GamepadAxisBinding:
				if pressedOnly do continue
				value := pad.axes[b.axis] * b.direction
				if value <= a.data.deadzone do continue
				best = max(best, math.clamp((value - a.data.deadzone) / max(1 - a.data.deadzone, 0.0001), 0, 1))
			}
		}
	}
	return best
}
