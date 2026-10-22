#+build !js
package crossfire

import "core:log"
import "core:strings"
import "core:sync"
import "core:testing"

TestReloadState :: struct {
	using script: Script,
	lives: int `export:"default=3" save:""`,
}

@(private="file")
reloadOnce: sync.Once

// Hot reload's snapshots (hot_reload.odin): a game's state written, then put back into a freshly
// built game: globals, nodes' transforms and script fields, missing nodes skipped

HOT_RELOAD_SCENE :: `<scene formatVersion="13">
	<node name="World" kind="Node2D">
		<node name="Ship" kind="Node2D" x="10" y="20"><script name="TestScript"/></node>
	</node>
</scene>`

@(private="file")
startGame :: proc(project: ^ProjectData) -> ^Game {
	game := testGame("testdata")
	Globals_Start(game, project.globals[:])
	scene := game->createScene("Level")
	data, _ := ParseScene(HOT_RELOAD_SCENE)
	defer SceneData_Destroy(&data)
	_ = Scene_Build(scene, &data, "testdata")
	game.currentScene = scene
	return game
}

@(test)
hot_reload_snapshots_restore_the_game :: proc(t: ^testing.T) {
	registerTestScript()
	sync.once_do(&reloadOnce, proc() { Script_Register(TestReloadState, {}) })
	project, _ := ParseProject(`<project formatVersion="13" name="H"><global script="TestReloadState"/></project>`)
	defer ProjectData_Destroy(&project)

	// A game played a while: the ship moved and turned, its script's speed changed, a global's lives
	game := startGame(&project)
	Game_Update(game, nil, 1.0 / 60)
	ship := Scene_FindNode(game.currentScene, "World/Ship")
	ship.position = {300, 200}
	ship.rotation = 45
	Node_GetScript(ship, TestScript).speed = 0
	Global(TestReloadState, game).lives = 1
	snapshot := Game_Snapshot(game)
	testing.expect(t, strings.contains(snapshot, `"path": "World/Ship"`), "the ship by its path")
	testing.expect(t, strings.contains(snapshot, `"script.speed"`), "its script's fields")
	parsed, ok := Snapshot_Parse(snapshot)
	testing.expect(t, ok && parsed.scene == "Level", "its scene")
	Game_Destroy(game)
	free(game)

	// Restarted (the scene from its file), then the snapshot on top
	again := startGame(&project)
	defer { Game_Destroy(again); free(again) }
	testing.expect(t, Game_RestoreSnapshot(again, snapshot), "restored")
	testing.expect_value(t, Global(TestReloadState, again).lives, 1)
	{
		context.logger = log.nil_logger()
		Game_Update(again, nil, 0)
	}
	ship2 := Scene_FindNode(again.currentScene, "World/Ship")
	testing.expect_value(t, ship2.position, [2]f32{300, 200})
	testing.expect_value(t, ship2.rotation, 45)
	testing.expect_value(t, Node_GetScript(ship2, TestScript).speed, 0)
	testing.expect_value(t, again.pendingSnapshot, "")
	testing.expect(t, !Game_RestoreSnapshot(again, "not json"), "garbage refused")
	testing.expect_value(t, Node_NamePath(ship2), "World/Ship")
}
