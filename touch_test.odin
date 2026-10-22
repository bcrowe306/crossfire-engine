#+build !js
package crossfire

import "core:log"
import "core:math"
import "core:os"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

// Touch input and on-screen controls (touch.odin), and Steam's stub backend (steam.odin):
// synthetic finger and mouse events into a test game (no window, no devices)

@(private="file")
finger :: proc(type: sdl.EventType, id: sdl.FingerID, at: [2]f32) -> sdl.Event {
	event: sdl.Event
	event.type = type
	event.tfinger.fingerID = id
	event.tfinger.x, event.tfinger.y = at.x, at.y
	event.tfinger.pressure = 1
	return event
}

@(private="file")
mouse :: proc(type: sdl.EventType, at: [2]f32, fromTouch := false) -> sdl.Event {
	event: sdl.Event
	event.type = type
	if type == .MOUSE_MOTION {
		event.motion.x, event.motion.y = at.x, at.y
		return event
	}
	event.button.button = 1
	event.button.x, event.button.y = at.x, at.y
	event.button.down = type == .MOUSE_BUTTON_DOWN
	if fromTouch do event.button.which = sdl.TOUCH_MOUSEID
	return event
}

@(private="file")
frame :: proc(game: ^Game, scene: ^Scene, events: ..sdl.Event) {
	Input_Update(&game.input, events)
	Scene_Update(scene, events, 1.0 / 60)
}

TOUCH_SCENE :: `<scene formatVersion="13">
	<node name="Stick" kind="VirtualJoystick" x="100" y="300" touchActions="left,right,up,down" touchRadius="50" deadzone="0.2"/>
	<node name="Jump" kind="TouchButton" x="500" y="300" touchActions="jump" text="A"/>
	<node name="Float" kind="VirtualJoystick" x="300" y="100" touchActions=",,,dive" floating="true" zoneWidth="200" zoneHeight="100" touchMouse="false" touchVisibility="Always"/>
</scene>`

@(private="file")
TouchPresses :: struct {
	pressed, released: int,
}

@(test)
touches_and_touch_controls :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	game.size = {640, 400}
	Input_AddAction("left", game = game)
	Input_AddAction("right", game = game)
	Input_AddAction("up", game = game)
	Input_AddAction("down", game = game)
	Input_AddAction("jump", KeyBinding{.Space}, game = game)
	Input_AddAction("dive", game = game)
	scene := game->createScene("S")
	data, err := ParseScene(TOUCH_SCENE)
	defer SceneData_Destroy(&data)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, data.nodes[0].touch.radius, f32(50))
	testing.expect_value(t, data.nodes[1].touch.radius, f32(TOUCH_BUTTON_RADIUS))
	testing.expect_value(t, data.nodes[2].touch.zone, [2]f32{200, 100})
	testing.expect_value(t, data.nodes[2].touch.visibility, TouchVisibility.Always)
	testing.expect_value(t, TouchControl_ParseActions(data.nodes[2].touchActions), [4]string{"", "", "", "dive"})
	testing.expect_value(t, TouchControl_FormatActions({"", "", "", "dive"}), ",,,dive")
	testing.expect_value(t, TouchControl_FormatActions({"jump", "", "", ""}), "jump")
	_ = Scene_Build(scene, &data, "testdata")
	frame(game, scene)
	stick := cast(^VirtualJoystick)Scene_FindNode(scene, "Stick")
	jump := cast(^TouchButton)Scene_FindNode(scene, "Jump")
	float := cast(^VirtualJoystick)Scene_FindNode(scene, "Float")
	testing.expect(t, stick != nil && jump != nil && float != nil, "built")
	testing.expect_value(t, len(game.input.touchControls), 3)
	presses: TouchPresses
	Event_Subscribe(&jump.onPressed, proc(event: ^EventSubject, source: rawptr, data: EventData, user: rawptr) { (cast(^TouchPresses)user).pressed += 1 }, &presses)
	Event_Subscribe(&jump.onReleased, proc(event: ^EventSubject, source: rawptr, data: EventData, user: rawptr) { (cast(^TouchPresses)user).released += 1 }, &presses)

	// A finger outside every control: a touch, taken by none
	testing.expect(t, !Input_IsTouchScreen(game), "not touched yet")
	frame(game, scene, finger(.FINGER_DOWN, 1, {320, 380}))
	testing.expect(t, Input_IsTouchScreen(game), "touched")
	testing.expect_value(t, Input_GetTouchCount(game), 1)
	touches := Input_GetTouches(game)
	testing.expect(t, touches[0].pressed && !touches[0].claimed, "a new free touch")
	frame(game, scene, finger(.FINGER_MOTION, 1, {330, 370}))
	testing.expect_value(t, Input_GetTouches(game)[0].motion, [2]f32{10, -10})
	testing.expect_value(t, Input_GetTouches(game)[0].start, [2]f32{320, 380})
	frame(game, scene, finger(.FINGER_UP, 1, {330, 370}))
	testing.expect(t, Input_GetTouches(game)[0].released, "lifted this frame")
	testing.expect_value(t, Input_GetTouchCount(game), 0)
	frame(game, scene)
	testing.expect_value(t, len(Input_GetTouches(game)), 0)

	// The stick: a finger landing on it, pushed right past its radius, then up a little
	frame(game, scene, finger(.FINGER_DOWN, 2, {100, 300}))
	testing.expect(t, stick.held, "the stick took the finger")
	testing.expect(t, Input_GetTouches(game)[0].claimed, "claimed")
	frame(game, scene, finger(.FINGER_MOTION, 2, {200, 300}))
	testing.expect_value(t, VirtualJoystick_GetVector(stick), [2]f32{1, 0})
	testing.expect_value(t, Input_GetActionStrength("right", game), 1)
	testing.expect_value(t, Input_GetActionStrength("left", game), 0)
	testing.expect(t, Input_IsActionPressed("right", game), "right is pressed")
	// Inside the deadzone: centered
	frame(game, scene, finger(.FINGER_MOTION, 2, {105, 300}))
	testing.expect_value(t, VirtualJoystick_GetVector(stick), [2]f32{0, 0})
	testing.expect(t, !Input_IsActionPressed("right", game), "centered")
	// Halfway up: rescaled from the deadzone's edge ((0.5 - 0.2) / 0.8)
	frame(game, scene, finger(.FINGER_MOTION, 2, {100, 275}))
	v := VirtualJoystick_GetVector(stick)
	testing.expect(t, math.abs(v.y + 0.375) < 0.001 && v.x == 0, "up, rescaled")
	testing.expect(t, math.abs(Input_GetActionStrength("up", game) - 0.375) < 0.001, "up's strength")
	testing.expect(t, math.abs(Input_GetVector("left", "right", "up", "down", game).y + 0.375) < 0.001, "the action vector follows")

	// A second finger on the button while the stick is held: both work; the stick's finger
	// moving over the button doesn't press it
	frame(game, scene, finger(.FINGER_DOWN, 3, {505, 295}))
	testing.expect(t, TouchButton_IsPressed(jump), "the button is held")
	testing.expect(t, Input_IsActionJustPressed("jump", game), "jump pressed")
	testing.expect_value(t, presses.pressed, 1)
	testing.expect(t, stick.held, "the stick keeps its finger")
	frame(game, scene, finger(.FINGER_MOTION, 2, {500, 300}))
	testing.expect(t, stick.held && stick.finger == 2, "it follows its finger anywhere")
	frame(game, scene, finger(.FINGER_UP, 3, {505, 295}))
	testing.expect(t, !TouchButton_IsPressed(jump), "let go")
	testing.expect(t, Input_IsActionJustReleased("jump", game), "jump released")
	testing.expect_value(t, presses.released, 1)
	frame(game, scene, finger(.FINGER_UP, 2, {500, 300}))
	testing.expect(t, !stick.held, "the stick lets go")
	testing.expect_value(t, VirtualJoystick_GetVector(stick), [2]f32{0, 0})
	frame(game, scene)

	// A floating stick starts where the finger lands in its zone (not on the circle)
	frame(game, scene, finger(.FINGER_DOWN, 4, {380, 120}))
	testing.expect(t, float.held, "taken in its zone")
	testing.expect_value(t, float.base, [2]f32{380, 120})
	frame(game, scene, finger(.FINGER_MOTION, 4, {380, 200}))
	testing.expect_value(t, Input_GetActionStrength("dive", game), 1)
	frame(game, scene, finger(.FINGER_CANCELED, 4, {380, 200}))
	testing.expect(t, !float.held, "a canceled touch lets go")
	frame(game, scene)

	// The mouse works the stick (desktop testing), but a mouse press made from a finger doesn't
	frame(game, scene, mouse(.MOUSE_BUTTON_DOWN, {100, 300}))
	testing.expect(t, stick.held && stick.byMouse, "the mouse holds it")
	frame(game, scene, mouse(.MOUSE_MOTION, {50, 300}))
	testing.expect_value(t, VirtualJoystick_GetVector(stick), [2]f32{-1, 0})
	frame(game, scene, mouse(.MOUSE_BUTTON_UP, {50, 300}))
	testing.expect(t, !stick.held, "released")
	frame(game, scene, mouse(.MOUSE_BUTTON_DOWN, {100, 300}, fromTouch = true))
	testing.expect(t, !stick.held, "a finger's mouse press is the finger's")
	frame(game, scene, mouse(.MOUSE_BUTTON_UP, {100, 300}, fromTouch = true))
	// The float stick takes no mouse
	frame(game, scene, mouse(.MOUSE_BUTTON_DOWN, {300, 100}))
	testing.expect(t, !float.held, "touchMouse off")
	frame(game, scene, mouse(.MOUSE_BUTTON_UP, {300, 100}))

	// Hidden controls let go and take nothing
	frame(game, scene, finger(.FINGER_DOWN, 5, {500, 300}))
	testing.expect(t, jump.held, "held")
	jump.visible = false
	frame(game, scene)
	testing.expect(t, !jump.held, "a hidden button lets go")
	testing.expect_value(t, presses.released, 2)
	frame(game, scene, finger(.FINGER_UP, 5, {500, 300}))

	// Removed controls leave the input's list
	Scene_RemoveNode(scene, jump.id)
	frame(game, scene)
	testing.expect_value(t, len(game.input.touchControls), 2)
}

@(test)
touch_controls_from_code :: proc(t: ^testing.T) {
	game := testGame("testdata")
	defer { Game_Destroy(game); free(game) }
	Input_AddAction("fire", game = game)
	scene := game->createScene("S")
	button := CreateTouchButton(scene, "fire", "B")
	button.position = {50, 50}
	testing.expect_value(t, button.settings.radius, f32(TOUCH_BUTTON_RADIUS))
	stick := CreateVirtualJoystick(scene)
	TouchControl_SetActions(stick, {"", "", "", "fire"})
	stick.position = {300, 300}
	frame(game, scene)
	frame(game, scene, finger(.FINGER_DOWN, 1, {300, 300}))
	frame(game, scene, finger(.FINGER_MOTION, 1, {300, 400}))
	testing.expect(t, Input_IsActionPressed("fire", game), "the stick pushes down: fire")
	bounds, ok := Node_GetLocalBounds(button)
	testing.expect(t, ok && bounds == {-40, -40, 80, 80}, "its bounds are its circle")
}

// Saves and the stub's storage share the save folder override: one test at a time
@(private)
saveFolderLock: sync.Mutex

@(test)
steam_stub_achievements_stats_and_cloud :: proc(t: ^testing.T) {
	sync.mutex_lock(&saveFolderLock)
	defer sync.mutex_unlock(&saveFolderLock)
	dir := tempFolder("engine_test_steam")
	defer os.remove_all(dir)
	saveRootOverride = dir
	defer saveRootOverride = ""
	project, err := ParseProject(`<project formatVersion="13" name="SteamTest" steamAppId="480" steamCloud="true">
	<achievement name="FIRST_BLOOD" title="First Blood" description="Defeat an enemy"/>
	<achievement name="SECRET" title="Secret" hidden="true"/>
</project>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, project.steam, SteamSettings{appId = 480, cloudSaves = true})
	testing.expect_value(t, len(project.achievements), 2)
	testing.expect(t, project.achievements[1].hidden, "hidden")

	game := testGame(dir)
	Steam_Setup(game, project.steam, project.achievements[:])
	testing.expect(t, Steam_IsRunning(game), "the stub runs")
	testing.expect_value(t, Steam_BackendName(game), "stub")
	testing.expect_value(t, len(Steam_GetAchievements(game)), 2)
	unlocked := 0
	Event_Subscribe(&game.steam.onAchievementUnlocked, proc(event: ^EventSubject, source: rawptr, data: EventData, user: rawptr) { (cast(^int)user)^ += 1 }, &unlocked)

	testing.expect(t, !Steam_IsAchievementUnlocked("FIRST_BLOOD", game), "locked")
	testing.expect(t, Steam_UnlockAchievement("FIRST_BLOOD", game), "unlocked")
	testing.expect(t, Steam_UnlockAchievement("FIRST_BLOOD", game), "again: still unlocked")
	testing.expect_value(t, unlocked, 1)
	testing.expect(t, Steam_IsAchievementUnlocked("FIRST_BLOOD", game), "is unlocked")
	{
		context.logger = log.nil_logger()
		testing.expect(t, Steam_UnlockAchievement("NOT_LISTED", game), "an unlisted one still unlocks (warned)")
	}
	testing.expect(t, Steam_ClearAchievement("NOT_LISTED", game), "cleared")
	testing.expect(t, Steam_SetStat("KILLS", 3, game), "set")
	testing.expect(t, Steam_AddStat("KILLS", 2, game), "added")
	testing.expect_value(t, Steam_GetStat("KILLS", game), 5)
	testing.expect_value(t, Steam_GetStat("NEVER", game), 0)
	testing.expect(t, Steam_StoreStats(game), "stored")

	// Cloud files; saves go through them with steamCloud
	testing.expect(t, Steam_CloudWrite("notes.txt", transmute([]byte)string("hello"), game), "written")
	data, ok := Steam_CloudRead("notes.txt", game)
	testing.expect(t, ok && string(data) == "hello", "read back")
	testing.expect(t, Steam_CloudExists("notes.txt", game), "exists")
	testing.expect(t, Steam_CloudDelete("notes.txt", game), "deleted")
	testing.expect(t, !Steam_CloudExists("notes.txt", game), "gone")
	{
		context.logger = log.nil_logger()
		testing.expect(t, !Steam_CloudWrite("../escape", {1}, game), "a bad name is refused")
	}
	currentGame = game
	testing.expect(t, Save_Game("slot", game), "saved")
	testing.expect(t, Steam_CloudExists("slot", game), "the save is a cloud file")
	testing.expect(t, Save_Exists("slot", game), "Save_Exists sees it")
	Save_Delete("slot", game)
	testing.expect(t, !Steam_CloudExists("slot", game), "deleted from the cloud")
	Game_Destroy(game)
	free(game)

	// The stub kept them: a new run sees the achievement and the stat
	game2 := testGame(dir)
	defer { Game_Destroy(game2); free(game2) }
	Steam_Setup(game2, project.steam, project.achievements[:])
	testing.expect(t, Steam_IsAchievementUnlocked("FIRST_BLOOD", game2), "kept")
	testing.expect(t, !Steam_IsAchievementUnlocked("NOT_LISTED", game2), "the cleared one stays cleared")
	testing.expect_value(t, Steam_GetStat("KILLS", game2), 5)
	// A game without a project's Steam setup answers nothing
	game3 := testGame(dir)
	defer { Game_Destroy(game3); free(game3) }
	testing.expect(t, !Steam_IsRunning(game3), "not set up")
	testing.expect(t, !Steam_UnlockAchievement("FIRST_BLOOD", game3), "nothing to unlock with")
}
