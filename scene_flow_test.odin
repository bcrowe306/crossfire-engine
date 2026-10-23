#+build !js
package crossfire

import "core:fmt"
import "core:os"
import "core:testing"
import sdl "vendor:sdl3"

// Scene changes (scene_flow.odin): a fade's halves with the switch under the cover, scenes pushed
// over others (pausing them) and popped, the loading screen (scenes built when entered)

@(private="file")
FLOW_A :: `<scene formatVersion="13" name="A">
	<node kind="Node2D" name="Mover"/>
	<node kind="Animator" name="Anim" autoplay="go">
		<clip name="go" length="100">
			<track node="/Mover" property="position.x"><key time="0" value="0"/><key time="100" value="100"/></track>
		</clip>
	</node>
</scene>`

@(private="file")
FLOW_B :: `<scene formatVersion="13" name="B">
	<node kind="Node2D" name="Thing"/>
</scene>`

// A project of scenes A (start), B, Pause (a copy of A) and Loading, written to a folder
@(private="file")
flowProject :: proc(dir: string, transition: string, loading: string) -> (^Game, ProjectData) {
	os.make_directory("build")
	os.make_directory(dir)
	write :: proc(dir, name, text: string) {
		_ = os.write_entire_file(JoinPath(dir, name), transmute([]u8)text)
	}
	write(dir, "A.scene.xml", FLOW_A)
	write(dir, "B.scene.xml", FLOW_B)
	write(dir, "Pause.scene.xml", FLOW_A)
	write(dir, "Loading.scene.xml", `<scene formatVersion="13" name="Loading"/>`)
	project, _ := ParseProjectText(transition, loading)
	game := testGame(dir)
	Game_LoadProject(game, &project, dir)
	return game, project
}

@(private="file")
ParseProjectText :: proc(transition, loading: string) -> (ProjectData, ProjectError) {
	text := fmt.tprintf(`<project formatVersion="13" name="Flow" width="320" height="180" startScene="A" %s %s>
		<scene name="A" path="A.scene.xml"/>
		<scene name="B" path="B.scene.xml"/>
		<scene name="Pause" path="Pause.scene.xml"/>
		<scene name="Loading" path="Loading.scene.xml"/>
	</project>`, transition, loading)
	return ParseProject(text)
}

@(private="file")
step :: proc(game: ^Game, seconds: f64) {
	Game_Update(game, nil, seconds)
}

@(test)
transitions_change_scenes_under_their_cover :: proc(t: ^testing.T) {
	dir := "build/test_flow_fade"
	game, project := flowProject(dir, `transition="Fade" transitionTime="1" transitionColor="#000000"`, "")
	defer { Game_Destroy(game); free(game); ProjectData_Destroy(&project); removeTestDir(dir) }
	testing.expect(t, project.transition.kind == .Fade && project.transition.duration == 1, "the project's transition")
	step(game, 0.01)
	testing.expect_value(t, game.currentScene.name, "A")
	testing.expect(t, Game_RunAction(game, "scene:B"), "an action")
	step(game, 0.25)
	testing.expectf(t, abs(SceneFlow_Cover(game) - 0.5) < 0.01, "half covered: %v", SceneFlow_Cover(game))
	testing.expect_value(t, game.currentScene.name, "A")
	step(game, 0.3)
	// Covered: the switch happens on the next update
	step(game, 0.01)
	testing.expect_value(t, game.currentScene.name, "B")
	testing.expect(t, Game_IsChangingScene(game) && SceneFlow_Cover(game) > 0.9, "uncovering")
	step(game, 0.6)
	testing.expect(t, !Game_IsChangingScene(game) && SceneFlow_Cover(game) == 0, "done")
	// None: at once
	Game_ChangeScene(game, "A", Transition{kind = .None})
	step(game, 0.01)
	testing.expect_value(t, game.currentScene.name, "A")
	testing.expect(t, !Game_RunAction(game, "nonsense"), "unknown action")
}

@(test)
scenes_pushed_over_others_pause_them :: proc(t: ^testing.T) {
	dir := "build/test_flow_push"
	game, project := flowProject(dir, "", "")
	defer { Game_Destroy(game); free(game); ProjectData_Destroy(&project); removeTestDir(dir) }
	step(game, 0.01)
	step(game, 1)
	mover := Scene_FindNode(game.scenes["A"], "Mover")
	before := mover.position.x
	testing.expect(t, before > 0, "A plays")
	testing.expect(t, Game_RunAction(game, "push:Pause"), "pushed")
	testing.expect_value(t, Game_TopScene(game), game.scenes["Pause"])
	step(game, 0.01)
	step(game, 1)
	pauseMover := Scene_FindNode(game.scenes["Pause"], "Mover")
	testing.expect_value(t, mover.position.x, before)
	testing.expect(t, pauseMover.position.x > 0, "the pushed scene plays")
	testing.expect(t, !Game_PushScene(game, "Pause"), "not twice")
	testing.expect(t, Game_RunAction(game, "pop"), "popped")
	testing.expect_value(t, Game_TopScene(game), game.scenes["A"])
	step(game, 1)
	testing.expect(t, mover.position.x > before, "A plays again")
	// Not pausing: both play
	Game_PushScene(game, "Pause", pauseBelow = false)
	held := mover.position.x
	step(game, 1)
	testing.expect(t, mover.position.x > held, "both play")
	// A scene change closes them
	Game_ChangeScene(game, "B", Transition{kind = .None})
	testing.expect_value(t, len(game.flow.overlays), 0)
}

@(test)
loading_screens_show_while_scenes_load :: proc(t: ^testing.T) {
	dir := "build/test_flow_loading"
	game, project := flowProject(dir, "", `loadingScene="Loading"`)
	defer { Game_Destroy(game); free(game); ProjectData_Destroy(&project); removeTestDir(dir) }
	// Built at the start: the start scene and the loading scene only
	testing.expect(t, !game.scenes["A"].unbuilt && !game.scenes["Loading"].unbuilt, "built")
	testing.expect(t, game.scenes["B"].unbuilt && len(game.scenes["B"].nodes) == 0, "B waits")
	step(game, 0.01)
	Game_ChangeScene(game, "B", Transition{kind = .None})
	step(game, 0.01)
	testing.expect_value(t, game.currentScene.name, "Loading")
	testing.expect(t, Game_LoadingProgress(game) <= 1, "progress")
	// The loading screen stays at least LOADING_MIN_SECONDS
	step(game, 0.1)
	testing.expect_value(t, game.currentScene.name, "Loading")
	for _ in 0..<10 do step(game, 0.1)
	testing.expect_value(t, game.currentScene.name, "B")
	testing.expect(t, !game.scenes["B"].unbuilt && len(game.scenes["B"].nodes) == 1, "B built when entered")
	testing.expect_value(t, Game_LoadingProgress(game), f32(1))
}

@(private="file")
removeTestDir :: proc(dir: string) {
	// File by file: os.remove_all goes through the shell on Windows (unsafe on test threads)
	for name in ([4]string{"A.scene.xml", "B.scene.xml", "Pause.scene.xml", "Loading.scene.xml"}) do _ = os.remove(JoinPath(dir, name))
	_ = os.remove(dir)
}

@(test)
pushed_scenes_start_fresh_and_ignore_the_press_that_opened_them :: proc(t: ^testing.T) {
	dir := "build/test_flow_push_fresh"
	os.make_directory("build")
	os.make_directory(dir)
	write :: proc(dir, name, text: string) {
		_ = os.write_entire_file(JoinPath(dir, name), transmute([]u8)text)
	}
	write(dir, "Menu.scene.xml", `<scene formatVersion="14" name="Menu">
	<node kind="Button" name="Open" anchor="Center" width="80" height="30" action="push:Popup"/>
</scene>`)
	write(dir, "Popup.scene.xml", `<scene formatVersion="14" name="Popup">
	<node kind="Button" name="Close" anchor="Center" width="80" height="30" action="pop"/>
</scene>`)
	project, _ := ParseProject(`<project formatVersion="14" name="Flow" width="320" height="180" startScene="Menu">
		<scene name="Menu" path="Menu.scene.xml"/>
		<scene name="Popup" path="Popup.scene.xml"/>
	</project>`)
	game := testGame(dir)
	Game_LoadProject(game, &project, dir)
	defer { Game_Destroy(game); free(game); ProjectData_Destroy(&project); removeTestDir(dir) }
	enter: sdl.Event
	enter.type = .KEY_DOWN
	enter.key.scancode = .RETURN
	enter.key.down = true
	up := enter
	up.type = .KEY_UP
	up.key.down = false
	Game_Update(game, nil, 0.01)
	menu, popup := game.scenes["Menu"], game.scenes["Popup"]
	Control_Focus(menu, cast(^Control)Scene_FindNode(menu, "Open"))
	// The popup's button has the focus when it opens (a menu's script would focus it in ready)
	close := cast(^Control)Scene_FindNode(popup, "Close")
	Control_Focus(popup, close)
	// Enter presses Open: the popup opens, and the same press doesn't press its Close
	Game_Update(game, {enter}, 0.01)
	testing.expect_value(t, Game_TopScene(game), popup)
	Game_Update(game, {up}, 0.01)
	testing.expect_value(t, Game_TopScene(game), popup)
	// The next press does
	Control_Focus(popup, close)
	Game_Update(game, {enter}, 0.01)
	testing.expect_value(t, Game_TopScene(game), menu)
	// Opened again, it's built again (its scripts would be ready again): a new Close
	Game_Update(game, nil, 0.01)
	closeId := close.id
	testing.expect(t, Game_PushScene(game, "Popup"), "pushed again")
	Game_Update(game, nil, 0.01)
	again := Scene_FindNode(popup, "Close")
	testing.expect(t, again != nil && again.id != closeId, "fresh nodes")
}
