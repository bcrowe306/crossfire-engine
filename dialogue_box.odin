package crossfire

import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

/*
**DialogueBox** nodes show conversations (dialogue.odin): a box at the bottom of the screen with
the speaker's name, the line typed out a letter at a time, and the options to choose from.

- **Playing:** `dialogue` (a `.dialogue.xml` asset) from `startNode` (its own start when ""), when
  the scene starts (`autostart`) or when a script calls `DialogueBox_Start`. Variables are the
  game's (`Game.dialogueVariables`), shared by every box and kept between conversations.
- **The player:** the game's `ui_accept` action (or Space / Enter / a click) shows the whole line
  while it types, then goes on; at options, `ui_up` / `ui_down` (or the arrows) pick and
  `ui_accept` chooses, or a click on one.
- **Commands** (`<<shake 2>>`): `onCommand` (data: the command's text, `text :=
  data.(string)`), then it goes on, unless a listener calls `DialogueBox_Hold` (then
  `DialogueBox_Continue` when the game is done). `wait 1.5` waits that long by itself.
- **Events:** `onLine` (data: the line's text), `onCommand`, `onFinished` (the conversation
  ended). It hides itself when a conversation ends (`hideWhenDone`).

It draws in screen space at its position (a UI node: put it on a screen layer, or under no
camera), `settings.size` across, its text wrapped inside.
*/

// A DialogueBox's look and behaviour (scene files' attributes)
DialogueBoxSettings :: struct {
	// The box's size (`boxWidth`, `boxHeight`)
	size: [2]f32,
	// Letters typed a second (`typeSpeed`; 0: the whole line at once)
	typeSpeed: f32,
	// Text size, and the font ("" for the default; `fontSize`, `font`)
	fontSize: f32,
	font: string,
	// Space inside the box's edge (`boxPadding`)
	padding: f32,
	// Colors: the box, the text, the speaker's name, the option picked (`boxColor`, `textColor`,
	// `nameColor`, `pickColor`)
	background: sdl.Color,
	textColor: sdl.Color,
	nameColor: sdl.Color,
	pickColor: sdl.Color,
	// Starts its dialogue when the scene starts (`autostart`)
	autostart: bool,
	// Hides when a conversation ends, shows when one starts (`hideWhenDone`)
	hideWhenDone: bool,
}

DEFAULT_DIALOGUE_BOX_SETTINGS :: DialogueBoxSettings{
	size = {600, 140},
	typeSpeed = 40,
	fontSize = 20,
	padding = 14,
	background = {16, 18, 28, 230},
	textColor = {240, 240, 240, 255},
	nameColor = {255, 210, 110, 255},
	pickColor = {120, 200, 255, 255},
	autostart = true,
	hideWhenDone = true,
}

// Shows a conversation
DialogueBox :: struct {
	using node: Node,
	settings: DialogueBoxSettings,
	// The dialogue asset and the node it starts in (node arena)
	dialogue: string,
	startNode: string,
	runner: DialogueRunner,
	// Letters of the line shown so far, and the time since the line began
	typed: f32,
	// The option highlighted
	pick: int,
	// A command's wait (seconds left), and a listener holding it
	waiting: f64,
	held: bool,
	started: bool,
	// A line began: it says so on onLine
	onLine: EventSubject `event:"A line shows (its speaker and text are the box's runner's)" data:"text := data.(string)"`,
	onCommand: EventSubject `event:"A command ran (<<shake 2>>): do it; DialogueBox_Hold to make it wait" data:"text := data.(string)"`,
	onFinished: EventSubject `event:"The conversation ended"`,
}

// Makes a DialogueBox for a dialogue asset (path relative to the project)
CreateDialogueBox :: proc(scene: ^Scene, dialogue: string, startNode := "", settings := DEFAULT_DIALOGUE_BOX_SETTINGS) -> ^DialogueBox {
	b := CreateNode(scene, DialogueBox)
	allocator := Node_GetAllocator(b)
	b.settings = settings
	b.dialogue = strings.clone(dialogue, allocator)
	b.startNode = strings.clone(startNode, allocator)
	b.transformMode = .Position_Only
	b.runner.allocator = context.allocator
	EventSubject_Init(&b.onLine, allocator)
	EventSubject_Init(&b.onCommand, allocator)
	EventSubject_Init(&b.onFinished, allocator)
	b.update = dialogueBoxUpdate
	b.draw = dialogueBoxDraw
	b.destroy = proc(node: ^Node) {
		b := cast(^DialogueBox)node
		DialogueRunner_Destroy(&b.runner)
	}
	b.getBounds = proc(node: ^Node) -> (sdl.FRect, bool) {
		b := cast(^DialogueBox)node
		return {0, 0, b.settings.size.x, b.settings.size.y}, true
	}
	return b
}

/*
Starts a conversation in the box (and shows it).

Inputs:
- box: The box
- node: The dialogue node to start in ("": the box's `startNode`, else the dialogue's start)

Returns:
- false when the dialogue or the node isn't there (logged)
*/
DialogueBox_Start :: proc(box: ^DialogueBox, node := "") -> bool {
	box.started = true
	data, ok := Game_LoadDialogue(box.scene.game, box.dialogue)
	if !ok do return false
	box.runner.shared = &box.scene.game.dialogueVariables
	start := node != "" ? node : box.startNode
	if box.settings.hideWhenDone do box.visible = true
	if !Dialogue_Start(&box.runner, data, start) {
		if start != "" && Dialogue_FindNode(data, start) < 0 do log.warnf("%s has no node %s", box.dialogue, start)
		dialogueBoxFinished(box)
		return false
	}
	dialogueBoxShown(box)
	return true
}

// Makes a command wait: call from an onCommand listener, then `DialogueBox_Continue`
DialogueBox_Hold :: proc(box: ^DialogueBox) {
	box.held = true
}

// Goes on after a held command (or skips the line showing)
DialogueBox_Continue :: proc(box: ^DialogueBox) {
	box.held = false
	if box.runner.state == .Command || box.runner.state == .Line {
		Dialogue_Continue(&box.runner)
		dialogueBoxShown(box)
	}
}

// Whether a conversation is playing in the box
DialogueBox_IsPlaying :: proc(box: ^DialogueBox) -> bool {
	s := box.runner.state
	return s == .Line || s == .Options || s == .Command
}

/*
A dialogue, read once per game (`Game.dialogues`): the file relative to the project folder.

Returns:
- The dialogue (the game's; nil when it can't be read, logged), and whether it was read
*/
Game_LoadDialogue :: proc(game: ^Game, path: string) -> (^DialogueData, bool) {
	if d, found := game.dialogues[path]; found do return d, d != nil
	allocator := Game_GetAllocator(game)
	if game.dialogues == nil do game.dialogues = make(map[string]^DialogueData, allocator)
	full := JoinPath(game.projectDir, path)
	d: ^DialogueData
	if text, read := Platform_ReadFile(full); !read {
		log.errorf("Couldn't read the dialogue %s", full)
	} else if parsed, err := ParseDialogue(string(text), allocator); err != .None {
		log.errorf("Couldn't load the dialogue %s: %v", full, err)
	} else {
		d = new_clone(parsed, allocator)
	}
	game.dialogues[strings.clone(path, allocator)] = d
	return d, d != nil
}

// INTERNAL

// What the box shows now changed: a line starts typing, options get a pick, a command runs
@(private="file")
dialogueBoxShown :: proc(box: ^DialogueBox) {
	for {
		switch box.runner.state {
		case .Line:
			box.typed = box.settings.typeSpeed > 0 ? 0 : f32(utf8.rune_count_in_string(box.runner.text))
			Event_Notify(&box.onLine, box, box.runner.text)
			return
		case .Options:
			box.pick = 0
			return
		case .Command:
			text := box.runner.command
			// wait N: by itself
			if strings.has_prefix(text, "wait ") {
				box.waiting = strconv.parse_f64(strings.trim_space(text[5:])) or_else 0
				return
			}
			box.held = false
			Event_Notify(&box.onCommand, box, text)
			if box.held || box.runner.state != .Command do return
			Dialogue_Continue(&box.runner)
		case .Finished, .Idle:
			dialogueBoxFinished(box)
			return
		}
	}
}

@(private="file")
dialogueBoxFinished :: proc(box: ^DialogueBox) {
	if box.runner.state == .Finished do Event_Notify(&box.onFinished, box, nil)
	box.runner.state = .Idle
	if box.settings.hideWhenDone do box.visible = false
}

@(private="file")
dialogueBoxUpdate :: proc(node: ^Node, events: []sdl.Event, dt: f64) {
	box := cast(^DialogueBox)node
	game := box.scene.game
	if !box.started {
		box.started = true
		if box.settings.autostart && box.dialogue != "" {
			DialogueBox_Start(box)
		} else if box.settings.hideWhenDone {
			box.visible = false
		}
		return
	}
	// The game's ui_* actions when it has them (not every project does), and the keys always
	action :: proc(name: string, game: ^Game) -> bool { return Input_HasAction(name, game) && Input_IsActionJustPressed(name, game) }
	accept := action(MENU_ACTION_ACCEPT, game) || Input_IsKeyJustPressed(.Space, game) || Input_IsKeyJustPressed(.Enter, game)
	click := Input_IsMouseButtonJustPressed(.Left, game) && dialogueBoxUnderMouse(box)
	switch box.runner.state {
	case .Line:
		total := f32(utf8.rune_count_in_string(box.runner.text))
		if box.typed < total {
			box.typed = min(total, box.typed + box.settings.typeSpeed * f32(dt))
			// The first press shows the whole line
			if accept || click do box.typed = total
		} else if accept || click {
			Dialogue_Continue(&box.runner)
			dialogueBoxShown(box)
		}
	case .Options:
		count := len(box.runner.options)
		if action("ui_down", game) || Input_IsKeyJustPressed(.Down, game) do box.pick = (box.pick + 1) % count
		if action("ui_up", game) || Input_IsKeyJustPressed(.Up, game) do box.pick = (box.pick + count - 1) % count
		if click {
			if hit := dialogueBoxOptionAt(box, Input_GetMousePosition(game)); hit >= 0 do box.pick = hit
			else do click = false
		}
		if accept || click {
			Dialogue_Choose(&box.runner, box.pick)
			dialogueBoxShown(box)
		}
	case .Command:
		if box.held do return
		if box.waiting > 0 {
			box.waiting -= dt
			if box.waiting > 0 do return
		}
		Dialogue_Continue(&box.runner)
		dialogueBoxShown(box)
	case .Finished, .Idle:
	}
}

// The option rows' top and height (local to the box)
@(private="file")
optionRows :: proc(box: ^DialogueBox) -> (top, height: f32) {
	s := box.settings
	return s.padding + s.fontSize * 1.4, s.fontSize * 1.35
}

@(private="file")
dialogueBoxUnderMouse :: proc(box: ^DialogueBox) -> bool {
	p := Input_GetMousePosition(box.scene.game) - Node_GetScreenPosition(box)
	return p.x >= 0 && p.y >= 0 && p.x <= box.settings.size.x && p.y <= box.settings.size.y
}

@(private="file")
dialogueBoxOptionAt :: proc(box: ^DialogueBox, mouse: [2]f32) -> int {
	p := mouse - Node_GetScreenPosition(box)
	top, height := optionRows(box)
	if p.x < 0 || p.x > box.settings.size.x do return -1
	row := int(math.floor((p.y - top) / height))
	return row >= 0 && row < len(box.runner.options) ? row : -1
}

@(private="file")
dialogueBoxDraw :: proc(node: ^Node, renderer: ^sdl.Renderer) {
	box := cast(^DialogueBox)node
	if box.runner.state == .Idle || box.runner.state == .Finished do return
	s := box.settings
	rm := &box.scene.game.resourceManager
	font := s.font != "" ? JoinPath(box.scene.game.projectDir, s.font) : DEFAULT_FONT
	rect := sdl.FRect{0, 0, s.size.x, s.size.y}
	DrawRoundedRectangle(renderer, &rect, 8, s.background)
	inner := s.size.x - s.padding * 2
	y := s.padding
	switch box.runner.state {
	case .Line:
		if box.runner.speaker != "" {
			DrawText(rm, {s.padding, y}, box.runner.speaker, font, s.fontSize * 0.85, s.nameColor)
			y += s.fontSize * 1.2
		}
		// The letters typed so far
		text := box.runner.text
		shown := int(box.typed)
		if shown < utf8.rune_count_in_string(text) {
			cut, n := 0, 0
			for _, i in text {
				if n == shown {
					cut = i
					break
				}
				n += 1
			}
			text = text[:cut]
		}
		DrawTextWrapped(rm, {s.padding, y}, text, font, s.fontSize, s.textColor, inner)
	case .Options:
		// The line asked, dimmed, over its options
		if box.runner.text != "" {
			faded := s.textColor
			faded.a = u8(f32(faded.a) * 0.6)
			DrawText(rm, {s.padding, y}, box.runner.text, font, s.fontSize * 0.9, faded)
		}
		top, height := optionRows(box)
		for o, i in box.runner.options {
			picked := i == box.pick
			label := picked ? strings.concatenate({"> ", o.text}, context.temp_allocator) : strings.concatenate({"   ", o.text}, context.temp_allocator)
			DrawText(rm, {s.padding, top + f32(i) * height}, label, font, s.fontSize, picked ? s.pickColor : s.textColor)
		}
	case .Command, .Idle, .Finished:
	}
}
