#+build !js
package engine

import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

// Tests for global scripts, data resources, saves and asset handles

@(private="file")
Difficulty :: enum { Easy, Hard }

@(private="file")
Upgrade :: struct {
	name: string,
	level: int,
}

@(private="file")
TestState :: struct {
	using script: Script,
	lives: int `export:"default=3 min=0"`,
	playerName: string `export:"default=Ace"`,
	difficulty: Difficulty `export:""`,
	music: SoundAsset `export:""`,
	// Saved but not exported: the game's own state
	score: int,
	unlocked: [dynamic]string,
	upgrades: [dynamic]Upgrade,
	best: map[string]int,
	// Not saved
	frames: int `save:"-"`,
	readied, loadedCount, scenesSeen, draws: int `save:"-"`,
}

@(private="file")
TestStats :: struct {
	health: int `export:"default=10"`,
	speed: f32 `export:"default=50"`,
	sprite: TextureAsset `export:""`,
	note: string,
}

@(private="file")
registerOnce: sync.Once

@(private="file")
register :: proc() {
	sync.once_do(&registerOnce, proc() {
		Script_Register(TestState, {
			ready = proc(self: ^TestState) { self.readied += 1 },
			update = proc(self: ^TestState, _: []sdl.Event, _: f64) { self.frames += 1 },
			draw = proc(self: ^TestState, _: ^sdl.Renderer) { self.draws += 1 },
			sceneChanged = proc(self: ^TestState, _: ^Scene) { self.scenesSeen += 1 },
			loaded = proc(self: ^TestState) { self.loadedCount += 1 },
		})
		Data_Register(TestStats)
	})
}

@(private="file")
testGame :: proc(dir: string) -> ^Game {
	game := new(Game)
	game.physics = DEFAULT_PHYSICS
	game.scenes = make(map[string]^Scene)
	game.name = strings.clone("Engine Test")
	game.projectDir = strings.clone(dir)
	game.update = Game_Update
	game.createScene = Game_CreateScene
	game.switchScene = Game_SwitchScene
	// No renderer here: its complaints about that aren't what's tested
	{
		context.logger = log.nil_logger()
		ResourceManager_Init(&game.resourceManager, nil, nil)
	}
	return game
}

@(private="file")
tempFolder :: proc(name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir := JoinPath(base, name)
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	return strings.clone(dir, context.temp_allocator)
}

@(test)
globals_run_with_the_game :: proc(t: ^testing.T) {
	register()
	dir := tempFolder("engine_test_globals")
	defer os.remove_all(dir)
	project, err := ParseProject(`<project formatVersion="5" name="G">
	<global script="TestState"><prop name="lives" value="5"/><prop name="difficulty" value="Hard"/><prop name="music" value="assets/song.ogg"/></global>
	<global script="Missing"/>
	<global script="TestState"/>
</project>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, len(project.globals), 3)

	game := testGame(dir)
	defer { Game_Destroy(game); free(game) }
	Globals_Start(game, project.globals[:])
	// The missing script and the duplicate are left out
	testing.expect_value(t, len(game.globals), 1)
	currentGame = game
	state := Global(TestState)
	testing.expect(t, state != nil && state.lives == 5 && state.difficulty == .Hard && state.playerName == "Ace")
	testing.expect_value(t, state.music.path, "assets/song.ogg")
	testing.expect(t, state.game == game && state.node == nil)

	Globals_Ready(game)
	testing.expect_value(t, state.readied, 1)
	scene := game->createScene("One")
	game->switchScene("One")
	Game_Update(game, nil, 1.0 / 60)
	Game_Update(game, nil, 1.0 / 60)
	testing.expect_value(t, state.frames, 2)
	testing.expect_value(t, state.scenesSeen, 1)
	Globals_Draw(game)
	state.hidden = true
	Globals_Draw(game)
	testing.expect_value(t, state.draws, 1)
	_ = scene

	// A new run starts from the project's values again
	game2 := testGame(dir)
	defer { Game_Destroy(game2); free(game2) }
	Globals_Start(game2, project.globals[:])
	fresh := Global(TestState, game2)
	testing.expect(t, fresh != state && fresh.frames == 0 && fresh.lives == 5)
	currentGame = nil
	testing.expect(t, Global(TestState) == nil)
}

@(test)
data_resources :: proc(t: ^testing.T) {
	register()
	dir := tempFolder("engine_test_data")
	defer os.remove_all(dir)
	_ = os.make_directory_all(JoinPath(dir, "data"))
	text := FormatDataResource("TestStats", {{"health", "30"}, {"sprite", "assets/goblin.png"}}, context.temp_allocator)
	_ = os.write_entire_file(JoinPath(dir, "data/goblin.data.json"), transmute([]byte)text)
	_ = os.write_entire_file(JoinPath(dir, "data/broken.data.json"), transmute([]byte)string("{nope"))

	// The file's text round-trips
	parsed, parseErr := ParseDataResource(text)
	defer DataResourceData_Destroy(&parsed)
	testing.expect(t, parseErr == .None && parsed.type == "TestStats" && len(parsed.values) == 2)

	game := testGame(dir)
	defer { Game_Destroy(game); free(game) }
	goblin := DataAsset{"data/goblin.data.json"}
	stats := Data(TestStats, goblin, game)
	testing.expect(t, stats != nil && stats.health == 30 && stats.speed == 50 && stats.sprite.path == "assets/goblin.png")
	// Shared: the same instance every time
	testing.expect(t, Data(TestStats, goblin, game) == stats)
	// Wrong type, missing file, bad file: nil (and logged errors, silenced here)
	{
		context.logger = log.nil_logger()
		testing.expect(t, Data(TestState, goblin, game) == nil)
		testing.expect(t, Data(TestStats, DataAsset{"data/none.data.json"}, game) == nil)
		testing.expect(t, Data(TestStats, DataAsset{"data/broken.data.json"}, game) == nil)
	}
	// Numbers and booleans written by hand are read too
	values, _ := ParseDataResource(`{"type": "TestStats", "values": {"health": 7, "speed": 2.5}}`, context.temp_allocator)
	testing.expect(t, len(values.values) == 2 && values.values[0].value == "7" && values.values[1].value == "2.5")
	testing.expect(t, Data_Find("TestStats") != nil)
	testing.expect(t, strings.contains(Script_DescribeJSON(context.temp_allocator), `"data": [{"name": "TestStats"`))
	free_all(context.temp_allocator)
}

@(test)
save_and_load :: proc(t: ^testing.T) {
	register()
	dir := tempFolder("engine_test_saves")
	defer os.remove_all(dir)
	saveRootOverride = dir
	defer saveRootOverride = ""
	project, _ := ParseProject(`<project formatVersion="5" name="S"><global script="TestState"/></project>`)
	defer ProjectData_Destroy(&project)

	game := testGame(dir)
	defer { Game_Destroy(game); free(game) }
	Globals_Start(game, project.globals[:])
	state := Global(TestState, game)
	state.score = 1200
	state.lives = 1
	state.difficulty = .Hard
	state.frames = 99
	allocator := Game_GetAllocator(game)
	state.unlocked = make([dynamic]string, allocator)
	append(&state.unlocked, "laser", "shield")
	state.upgrades = make([dynamic]Upgrade, allocator)
	append(&state.upgrades, Upgrade{"engine", 2})
	state.best = make(map[string]int, allocator)
	state.best["level1"] = 30

	testing.expect(t, !Save_Exists("slot1", game))
	testing.expect(t, Save_Game("slot1", game))
	testing.expect(t, Save_Exists("slot1", game))
	text, _ := Save_ToJSON(game, context.temp_allocator)
	testing.expect(t, strings.contains(text, `"score": 1200`))
	testing.expect(t, strings.contains(text, `"difficulty": "Hard"`))
	testing.expect(t, !strings.contains(text, "frames"))
	testing.expect(t, !strings.contains(text, "\"script\""))

	// A new run loads it back; the loaded hook runs
	game2 := testGame(dir)
	defer { Game_Destroy(game2); free(game2) }
	Globals_Start(game2, project.globals[:])
	loaded := Global(TestState, game2)
	loaded.frames = 5
	testing.expect(t, Load_Game("slot1", game2))
	testing.expect(t, loaded.score == 1200 && loaded.lives == 1 && loaded.difficulty == .Hard)
	testing.expect(t, len(loaded.unlocked) == 2 && loaded.unlocked[1] == "shield")
	testing.expect(t, len(loaded.upgrades) == 1 && loaded.upgrades[0].name == "engine" && loaded.upgrades[0].level == 2)
	testing.expect_value(t, loaded.best["level1"], 30)
	testing.expect_value(t, loaded.frames, 5)
	testing.expect_value(t, loaded.loadedCount, 1)

	// Fields missing from an older save keep their values; unknown globals are ignored
	testing.expect(t, Save_FromJSON(game2, `{"formatVersion": 1, "globals": {"TestState": {"lives": 9}, "Gone": {"x": 1}}}`))
	testing.expect(t, loaded.lives == 9 && loaded.score == 1200)
	testing.expect(t, !Save_FromJSON(game2, "not json"))
	{
		context.logger = log.nil_logger()
		testing.expect(t, !Load_Game("none", game2))
	}
	// Runs from the editor save apart from exported games
	game2.devKeys = true
	testing.expect(t, !Save_Exists("slot1", game2))
	game2.devKeys = false
	Save_Delete("slot1", game2)
	testing.expect(t, !Save_Exists("slot1", game2))
	{
		context.logger = log.nil_logger()
		testing.expect(t, !Load_Game("slot1", game2))
	}
	free_all(context.temp_allocator)
}
