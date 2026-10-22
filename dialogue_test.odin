#+build !js
package crossfire

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// Dialogue (dialogue.odin, yarn.odin, dialogue_box.odin): expressions, files, the runner, Yarn
// files converted and played, DialogueBox nodes typing, commands, finishing

@(private="file")
DIALOGUE :: `<dialogue formatVersion="13" start="Start">
	<node name="Start" x="0" y="0">
		<line speaker="Guide" text="Welcome! You have {$gold} gold."/>
		<options>
			<option text="Buy a sword" next="Buy" if="$gold &gt;= 5"/>
			<option text="Buy a castle" next="Buy" if="$gold &gt;= 5000"/>
			<option text="Goodbye" next="End"/>
		</options>
	</node>
	<node name="Buy" x="240" y="0">
		<set var="$gold" value="$gold - 5"/>
		<command text="give sword"/>
		<line speaker="Guide" text="Here you go. {$gold} left."/>
		<jump next="End" if="visited(&quot;Buy&quot;)"/>
		<line text="(never)"/>
	</node>
	<node name="End" x="480" y="0">
		<line text="Bye!"/>
		<stop/>
		<line text="(never)"/>
	</node>
</dialogue>`

@(test)
dialogue_expressions :: proc(t: ^testing.T) {
	runner: DialogueRunner
	defer DialogueRunner_Destroy(&runner)
	Dialogue_SetVariable(&runner, "$gold", f64(12))
	Dialogue_SetVariable(&runner, "$name", "Ada")
	check :: proc(t: ^testing.T, runner: ^DialogueRunner, expression, want: string, loc := #caller_location) {
		v, ok := Dialogue_Evaluate(runner, expression)
		testing.expectf(t, ok, "%s parses", expression, loc = loc)
		testing.expectf(t, DialogueValue_Text(v) == want, "%s = %s, not %s", expression, DialogueValue_Text(v), want, loc = loc)
	}
	check(t, &runner, "1 + 2 * 3", "7")
	check(t, &runner, "(1 + 2) * 3", "9")
	check(t, &runner, "$gold - 5", "7")
	check(t, &runner, "$gold >= 10 and not ($gold > 20)", "true")
	check(t, &runner, "$gold gt 20 || false", "false")
	check(t, &runner, "$name == \"Ada\"", "true")
	check(t, &runner, "$name is \"Bob\"", "false")
	check(t, &runner, "\"Hi \" + $name", "Hi Ada")
	check(t, &runner, "$unset", "0")
	check(t, &runner, "-$gold + 2", "-10")
	check(t, &runner, "7 % 4", "3")
	check(t, &runner, "dice(6) >= 1", "true")
	_, bad := Dialogue_Evaluate(&runner, "1 +")
	testing.expect(t, !bad, "an unfinished expression")
	_, unknown := Dialogue_Evaluate(&runner, "frobnicate(2)")
	testing.expect(t, !unknown, "an unknown function")
	testing.expect_value(t, Dialogue_Interpolate(&runner, "{$name} has {$gold + 1} gold"), "Ada has 13 gold")
}

@(test)
dialogue_files_and_the_runner :: proc(t: ^testing.T) {
	data, err := ParseDialogue(DIALOGUE)
	defer DialogueData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, len(data.nodes), 3)
	testing.expect_value(t, len(data.nodes[0].steps[1].options), 3)
	// Written and read back alike
	again, err2 := ParseDialogue(FormatDialogue(data, context.temp_allocator))
	defer DialogueData_Destroy(&again)
	testing.expect_value(t, err2, ProjectError.None)
	testing.expect(t, DialogueData_Equal(data, again), "round trip")
	copy := DialogueData_Clone(data)
	defer DialogueData_Destroy(&copy)
	testing.expect(t, DialogueData_Equal(data, copy), "clone")

	runner: DialogueRunner
	defer DialogueRunner_Destroy(&runner)
	Dialogue_SetVariable(&runner, "$gold", f64(12))
	testing.expect(t, Dialogue_Start(&runner, &data), "started")
	testing.expect_value(t, runner.state, DialogueState.Line)
	testing.expect_value(t, runner.speaker, "Guide")
	testing.expect_value(t, runner.text, "Welcome! You have 12 gold.")
	Dialogue_Continue(&runner)
	testing.expect_value(t, runner.state, DialogueState.Options)
	// The castle's condition doesn't hold: two options show
	testing.expect_value(t, len(runner.options), 2)
	testing.expect_value(t, runner.options[1].text, "Goodbye")
	Dialogue_Choose(&runner, 0)
	testing.expect_value(t, runner.state, DialogueState.Command)
	testing.expect_value(t, runner.command, "give sword")
	Dialogue_Continue(&runner)
	testing.expect_value(t, runner.text, "Here you go. 7 left.")
	Dialogue_Continue(&runner)
	// The jump's condition held (Buy was visited): End, then a stop
	testing.expect_value(t, runner.text, "Bye!")
	testing.expect(t, !Dialogue_Continue(&runner), "stopped")
	testing.expect_value(t, runner.state, DialogueState.Finished)
	testing.expect_value(t, DialogueValue_Text(Dialogue_GetVariable(&runner, "$gold")), "7")
	// A missing node
	testing.expect(t, !Dialogue_Start(&runner, &data, "Nowhere"), "no such node")
}

@(private="file")
YARN :: `title: Start
position: 10,20
---
Guide: Hello, traveller. #line:1
<<declare $coins = 3>>
<<if $coins > 2>>
    Guide: You look rich.
<<else>>
    Guide: You look poor.
<<endif>>
-> Buy a map <<if $coins >= 2>>
    <<set $coins to $coins - 2>>
    Guide: A map for you.
-> Leave
    <<jump Bye>>
Guide: You have {$coins} coins.
<<shake 2>>
===
title: Bye
---
Guide: Farewell.
===
`

@(test)
yarn_files_convert_and_play :: proc(t: ^testing.T) {
	data, warnings, ok := Yarn_Convert(YARN)
	defer DialogueData_Destroy(&data)
	testing.expect(t, ok, "converted")
	for w in warnings do log.infof("Yarn: %s", w)
	testing.expect_value(t, data.start, "Start")
	testing.expect(t, Dialogue_FindNode(&data, "Bye") >= 0, "the second node")
	testing.expect_value(t, data.nodes[0].position, [2]f32{10, 20})
	// Played: the greeting (tag dropped), the if's branch, options, the option's body, the
	// continuation after the group
	runner: DialogueRunner
	defer DialogueRunner_Destroy(&runner)
	Dialogue_Start(&runner, &data)
	testing.expect(t, runner.speaker == "Guide" && runner.text == "Hello, traveller.", "the greeting")
	Dialogue_Continue(&runner)
	testing.expect_value(t, runner.text, "You look rich.")
	Dialogue_Continue(&runner)
	testing.expect_value(t, runner.state, DialogueState.Options)
	testing.expect_value(t, len(runner.options), 2)
	testing.expect_value(t, runner.options[0].text, "Buy a map")
	Dialogue_Choose(&runner, 0)
	testing.expect_value(t, runner.text, "A map for you.")
	Dialogue_Continue(&runner)
	testing.expect_value(t, runner.text, "You have 1 coins.")
	Dialogue_Continue(&runner)
	testing.expect(t, runner.state == .Command && runner.command == "shake 2", "the command")
	testing.expect(t, !Dialogue_Continue(&runner), "the end")
	// The other way: the jump
	Dialogue_Start(&runner, &data)
	Dialogue_Continue(&runner)
	Dialogue_Continue(&runner)
	// $coins is 1 now and the declare doesn't run again: the map isn't offered
	testing.expect_value(t, len(runner.options), 1)
	Dialogue_Choose(&runner, 0)
	testing.expect_value(t, runner.text, "Farewell.")
	// Saved as a dialogue file and read back
	again, err := ParseDialogue(FormatDialogue(data, context.temp_allocator))
	defer DialogueData_Destroy(&again)
	testing.expect(t, err == .None && DialogueData_Equal(data, again), "a dialogue file")
}

@(test)
dialogue_boxes_play_conversations :: proc(t: ^testing.T) {
	dir := tempFolder("engine_test_dialogue")
	defer os.remove_all(dir)
	_ = os.write_entire_file(JoinPath(dir, "talk.dialogue.xml"), transmute([]byte)string(`<dialogue start="A">
	<node name="A"><line speaker="Ann" text="Hello there"/><command text="wave"/><command text="wait 0.5"/><line text="Bye"/></node>
</dialogue>`))
	surface := sdl.CreateSurface(320, 200, .ARGB8888)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	game := testGame(dir)
	defer { Game_Destroy(game); free(game) }
	game.renderer = renderer
	game.resourceManager.renderer = renderer
	scene := game->createScene("S")
	data, err := ParseScene(`<scene formatVersion="13">
	<node kind="DialogueBox" name="Box" x="10" y="20" dialogue="talk.dialogue.xml" typeSpeed="10" boxWidth="300" boxHeight="100" boxColor="#2040a0"/>
</scene>`)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect(t, data.nodes[0].dialogue == "talk.dialogue.xml" && data.nodes[0].dialogueBox.typeSpeed == 10, "parsed")
	_ = Scene_Build(scene, &data, dir)
	box := cast(^DialogueBox)Scene_FindNode(scene, "Box")
	lines := 0
	commands := make([dynamic]string, context.temp_allocator)
	Event_Subscribe(&box.onLine, proc(_: ^EventSubject, source: rawptr, data: EventData, listener: rawptr) { (cast(^int)listener)^ += 1 }, &lines)
	Event_Subscribe(&box.onCommand, proc(_: ^EventSubject, source: rawptr, data: EventData, listener: rawptr) {
		list := cast(^[dynamic]string)listener
		text, _ := data.(string)
		append(list, strings.clone(text, context.temp_allocator))
		// The game holds the conversation while it waves
		DialogueBox_Hold(cast(^DialogueBox)source)
	}, &commands)
	finished := false
	Event_Subscribe(&box.onFinished, proc(_: ^EventSubject, source: rawptr, data: EventData, listener: rawptr) { (cast(^bool)listener)^ = true }, &finished)
	Scene_Update(scene, nil, 0)
	testing.expect(t, DialogueBox_IsPlaying(box) && box.visible, "autostarted and shown")
	testing.expect_value(t, lines, 1)
	// Typing: 10 letters a second
	Scene_Update(scene, nil, 0.5)
	testing.expect_value(t, int(box.typed), 5)
	// Drawn: the box's color at its corner
	_ = sdl.RenderClear(renderer)
	Scene_DrawWithView(scene, renderer, TRANSFORM2D_IDENTITY)
	_ = sdl.RenderPresent(renderer)
	p := (cast([^]u32)surface.pixels)[(20 + 50) * 320 + 10 + 150]
	testing.expectf(t, p & 0xff > 0x80 && (p >> 16) & 0xff < 0x40, "the box drawn: %08x", p)
	// Went on (a script's continue): the command fires and holds
	DialogueBox_Continue(box)
	testing.expect(t, len(commands) == 1 && commands[0] == "wave", "the command")
	testing.expect_value(t, box.runner.state, DialogueState.Command)
	Scene_Update(scene, nil, 1)
	testing.expect_value(t, box.runner.state, DialogueState.Command)
	DialogueBox_Continue(box)
	// wait 0.5 waits by itself
	testing.expect_value(t, box.runner.state, DialogueState.Command)
	Scene_Update(scene, nil, 0.3)
	testing.expect_value(t, box.runner.state, DialogueState.Command)
	Scene_Update(scene, nil, 0.3)
	testing.expect_value(t, box.runner.state, DialogueState.Line)
	testing.expect_value(t, box.runner.text, "Bye")
	DialogueBox_Continue(box)
	testing.expect(t, finished, "finished")
	testing.expect(t, !box.visible, "hidden when done")
	// Again from code, in another node of none: refused
	{
		context.logger = log.nil_logger()
		testing.expect(t, !DialogueBox_Start(box, "Nope"), "no such node")
	}
	testing.expect(t, DialogueBox_Start(box), "again")
	testing.expect(t, box.visible, "shown again")
}
