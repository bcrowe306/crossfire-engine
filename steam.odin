package crossfire

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

/*
Steam: achievements, stats and cloud saves, through one API whatever runs them.

- **Achievements** are listed in project.xml (`<achievement name="FIRST_BLOOD" title="First Blood"
  description="Defeat an enemy"/>`; the editor's Project Settings > Steam): scripts unlock them
  by name (`Steam_UnlockAchievement("FIRST_BLOOD")`; the editor writes `ACHIEVEMENT_X`
  constants into scripts/assets.odin). Names are Steam's API names, as set up on Steamworks.
- **Stats** are numbers by name (`Steam_SetStat`, `Steam_AddStat`, `Steam_GetStat`): kills,
  distance walked. `Steam_StoreStats` sends them (and unlocked achievements), as Steam wants.
- **Cloud files** (`Steam_CloudWrite` / `Read` / `Delete` / `Exists`): files that follow the
  player between computers. With the project's `steamCloud="true"`, `Save_Game` and `Load_Game`
  go through them.

**The backend:** the calls go to a `SteamBackend` (`Game.steam.backend`). Until the Steamworks SDK
is part of the engine, every game runs the **stub** (`STEAM_STUB_BACKEND`): achievements and stats
are kept in the game's save storage (`steam-stub`; runs from the editor apart, like saves), cloud
files are save files named `steam-cloud-<file>`, and each unlock is logged ("Steam (stub):
achievement FIRST_BLOOD unlocked"). Games written against the API need no change when the real
backend arrives. `Steam_SetBackend` replaces it (tests, or a backend of your own).

`onAchievementUnlocked` (`Game.steam`) is notified on each new unlock (data: the name as a
string), so a game can show its own toast.

Example:
	if !e.Steam_IsAchievementUnlocked("FIRST_BLOOD") do e.Steam_UnlockAchievement("FIRST_BLOOD")
	e.Steam_AddStat("ENEMIES_DEFEATED", 1)
	e.Steam_StoreStats()
*/

// An achievement the project lists: `<achievement name title description hidden/>`
SteamAchievementData :: struct {
	// Steam's API name ("FIRST_BLOOD")
	name: string,
	// What players see, and how to get it (tools show them; Steam shows its own)
	title: string,
	description: string,
	// Hidden until unlocked (on Steam's pages)
	hidden: bool,
}

// The project's Steam settings (project.xml's `steamAppId`, `steamCloud`)
SteamSettings :: struct {
	// The game's Steam app ID (0: not set)
	appId: u32,
	// Saves (`Save_Game`) go to Steam Cloud files
	cloudSaves: bool,
}

/*
What runs the Steam calls. Every proc gets the game's Steam state. The stub
(`STEAM_STUB_BACKEND`) keeps everything locally; the Steamworks one will call Steam.
*/
SteamBackend :: struct {
	// Shown in logs ("stub")
	name: string,
	// Starts it (the project loaded); returns whether Steam is reachable
	start: proc(steam: ^SteamState) -> bool,
	// Writes what's pending and stops (the game ends)
	stop: proc(steam: ^SteamState),
	// Achievements by name
	unlock: proc(steam: ^SteamState, name: string) -> bool,
	clear: proc(steam: ^SteamState, name: string) -> bool,
	isUnlocked: proc(steam: ^SteamState, name: string) -> bool,
	// Stats by name
	setStat: proc(steam: ^SteamState, name: string, value: f64) -> bool,
	getStat: proc(steam: ^SteamState, name: string) -> (f64, bool),
	// Sends stats and achievements
	store: proc(steam: ^SteamState) -> bool,
	// Cloud files by name
	cloudWrite: proc(steam: ^SteamState, file: string, data: []byte) -> bool,
	cloudRead: proc(steam: ^SteamState, file: string) -> ([]byte, bool),
	cloudDelete: proc(steam: ^SteamState, file: string) -> bool,
	cloudExists: proc(steam: ^SteamState, file: string) -> bool,
}

// A game's Steam state (`Game.steam`)
SteamState :: struct {
	// The game (for its save names)
	game: ^Game,
	// The project's settings and achievements (in the game's arena)
	settings: SteamSettings,
	achievements: [dynamic]SteamAchievementData,
	// What runs the calls (the stub by default)
	backend: SteamBackend,
	// Started (Game_LoadProject), and whether Steam answered
	started, running: bool,
	// A new unlock (data: the name, a string)
	onAchievementUnlocked: EventSubject,
	// The stub's own state: unlocked achievements and stats (heap)
	stub: SteamStubData,
}

// What the stub keeps (written to save storage as JSON)
SteamStubData :: struct {
	unlocked: map[string]bool,
	stats: map[string]f64,
	dirty: bool,
}

/*
Sets the project's Steam settings and achievements and starts the backend (Game_LoadProject does
it with the project's).

Inputs:
- game: The game
- settings: App ID, cloud saves
- achievements: The achievements (copied into the game's arena)
*/
Steam_Setup :: proc(game: ^Game, settings: SteamSettings, achievements: []SteamAchievementData) {
	steam := &game.steam
	if steam.started do steamStop(game)
	allocator := Game_GetAllocator(game)
	steam.game = game
	steam.settings = settings
	steam.achievements = make([dynamic]SteamAchievementData, 0, len(achievements), allocator)
	for a in achievements {
		append(&steam.achievements, SteamAchievementData{strings.clone(a.name, allocator), strings.clone(a.title, allocator), strings.clone(a.description, allocator), a.hidden})
	}
	if steam.backend.name == "" do steam.backend = STEAM_STUB_BACKEND
	EventSubject_Init(&steam.onAchievementUnlocked, allocator)
	steam.started = true
	steam.running = steam.backend.start != nil && steam.backend.start(steam)
	log.infof("Steam: %s backend (app %d)%s", steam.backend.name, settings.appId, steam.running ? "" : ", not running")
}

/*
Replaces what runs the Steam calls (before the project loads, or between runs).

Inputs:
- backend: The backend
- game: The game (nil: the current one)
*/
Steam_SetBackend :: proc(backend: SteamBackend, game: ^Game = nil) {
	g := gameOrCurrent(game)
	if g == nil do return
	if g.steam.started && g.steam.backend.stop != nil do g.steam.backend.stop(&g.steam)
	g.steam.backend = backend
	if g.steam.started do g.steam.running = backend.start != nil && backend.start(&g.steam)
}

// Whether Steam answers (the stub always does)
Steam_IsRunning :: proc(game: ^Game = nil) -> bool {
	g := gameOrCurrent(game)
	return g != nil && g.steam.running
}

// The backend's name ("stub")
Steam_BackendName :: proc(game: ^Game = nil) -> string {
	g := gameOrCurrent(game)
	return g != nil ? g.steam.backend.name : ""
}

// The achievements the project lists
Steam_GetAchievements :: proc(game: ^Game = nil) -> []SteamAchievementData {
	g := gameOrCurrent(game)
	return g != nil ? g.steam.achievements[:] : nil
}

/*
Unlocks an achievement (once: unlocking it again does nothing). Steam keeps it once stats are
stored (`Steam_StoreStats`); the stub writes it at once.

Inputs:
- name: Its API name ("FIRST_BLOOD"); one the project doesn't list is warned about
- game: The game (nil: the current one)

Returns:
- Whether it's unlocked now
*/
Steam_UnlockAchievement :: proc(name: string, game: ^Game = nil) -> bool {
	steam := steamOf(game)
	if steam == nil do return false
	steamCheckName(steam, name)
	if steam.backend.isUnlocked != nil && steam.backend.isUnlocked(steam, name) do return true
	if steam.backend.unlock == nil || !steam.backend.unlock(steam, name) do return false
	Event_Notify(&steam.onAchievementUnlocked, nil, name)
	return true
}

// Whether an achievement is unlocked
Steam_IsAchievementUnlocked :: proc(name: string, game: ^Game = nil) -> bool {
	steam := steamOf(game)
	return steam != nil && steam.backend.isUnlocked != nil && steam.backend.isUnlocked(steam, name)
}

// Locks an achievement again (testing). Returns whether it worked
Steam_ClearAchievement :: proc(name: string, game: ^Game = nil) -> bool {
	steam := steamOf(game)
	return steam != nil && steam.backend.clear != nil && steam.backend.clear(steam, name)
}

/*
Sets a stat.

Inputs:
- name: Its API name ("ENEMIES_DEFEATED")
- value: The value
- game: The game (nil: the current one)

Returns:
- Whether it was set
*/
Steam_SetStat :: proc(name: string, value: f64, game: ^Game = nil) -> bool {
	steam := steamOf(game)
	return steam != nil && steam.backend.setStat != nil && steam.backend.setStat(steam, name, value)
}

// Adds to a stat (0 when it was never set). Returns whether it was set
Steam_AddStat :: proc(name: string, delta: f64, game: ^Game = nil) -> bool {
	return Steam_SetStat(name, Steam_GetStat(name, game) + delta, game)
}

// A stat's value (0 when it was never set)
Steam_GetStat :: proc(name: string, game: ^Game = nil) -> f64 {
	steam := steamOf(game)
	if steam == nil || steam.backend.getStat == nil do return 0
	value, _ := steam.backend.getStat(steam, name)
	return value
}

// Sends stats and unlocked achievements to Steam (the stub writes them). Returns whether it worked
Steam_StoreStats :: proc(game: ^Game = nil) -> bool {
	steam := steamOf(game)
	return steam != nil && steam.backend.store != nil && steam.backend.store(steam)
}

/*
Writes a Steam Cloud file.

Inputs:
- file: Its name ("save1"; letters, digits, `-`, `_` and `.`)
- data: Its contents
- game: The game (nil: the current one)

Returns:
- Whether it was written
*/
Steam_CloudWrite :: proc(file: string, data: []byte, game: ^Game = nil) -> bool {
	steam := steamOf(game)
	return steam != nil && steam.backend.cloudWrite != nil && steam.backend.cloudWrite(steam, file, data)
}

// Reads a Steam Cloud file (temp allocated). Returns false when there's none
Steam_CloudRead :: proc(file: string, game: ^Game = nil) -> ([]byte, bool) {
	steam := steamOf(game)
	if steam == nil || steam.backend.cloudRead == nil do return nil, false
	return steam.backend.cloudRead(steam, file)
}

// Deletes a Steam Cloud file. Returns whether there was one
Steam_CloudDelete :: proc(file: string, game: ^Game = nil) -> bool {
	steam := steamOf(game)
	return steam != nil && steam.backend.cloudDelete != nil && steam.backend.cloudDelete(steam, file)
}

// Whether a Steam Cloud file exists
Steam_CloudExists :: proc(file: string, game: ^Game = nil) -> bool {
	steam := steamOf(game)
	return steam != nil && steam.backend.cloudExists != nil && steam.backend.cloudExists(steam, file)
}

/*
The stub backend: achievements and stats kept in the game's save storage (`steam-stub`), cloud
files as save files (`steam-cloud-<file>`), each unlock logged. Every game runs it until the
Steamworks backend exists.
*/
STEAM_STUB_BACKEND :: SteamBackend{
	name = "stub",
	start = stubStart,
	stop = stubStop,
	unlock = proc(steam: ^SteamState, name: string) -> bool {
		if name == "" do return false
		steam.stub.unlocked[strings.clone(name)] = true
		steam.stub.dirty = true
		log.infof("Steam (stub): achievement %s unlocked", name)
		stubWrite(steam)
		return true
	},
	clear = proc(steam: ^SteamState, name: string) -> bool {
		if name in steam.stub.unlocked {
			key, _ := delete_key(&steam.stub.unlocked, name)
			delete(key)
			steam.stub.dirty = true
			stubWrite(steam)
		}
		return true
	},
	isUnlocked = proc(steam: ^SteamState, name: string) -> bool {
		return steam.stub.unlocked[name]
	},
	setStat = proc(steam: ^SteamState, name: string, value: f64) -> bool {
		if name == "" do return false
		if _, ok := steam.stub.stats[name]; ok {
			steam.stub.stats[name] = value
		} else {
			steam.stub.stats[strings.clone(name)] = value
		}
		steam.stub.dirty = true
		return true
	},
	getStat = proc(steam: ^SteamState, name: string) -> (f64, bool) {
		value, ok := steam.stub.stats[name]
		return value, ok
	},
	store = proc(steam: ^SteamState) -> bool {
		return stubWrite(steam)
	},
	cloudWrite = proc(steam: ^SteamState, file: string, data: []byte) -> bool {
		name, ok := stubCloudName(steam, file)
		return ok && Platform_SaveWrite(name, data)
	},
	cloudRead = proc(steam: ^SteamState, file: string) -> ([]byte, bool) {
		name, ok := stubCloudName(steam, file)
		if !ok do return nil, false
		return Platform_SaveRead(name)
	},
	cloudDelete = proc(steam: ^SteamState, file: string) -> bool {
		name, ok := stubCloudName(steam, file)
		if !ok || !Platform_SaveExists(name) do return false
		Platform_SaveDelete(name)
		return true
	},
	cloudExists = proc(steam: ^SteamState, file: string) -> bool {
		name, ok := stubCloudName(steam, file)
		return ok && Platform_SaveExists(name)
	},
}

// INTERNAL

// Ends Steam (Game_Destroy): the backend writes what's pending
@(private)
steamStop :: proc(game: ^Game) {
	steam := &game.steam
	if steam.started && steam.backend.stop != nil do steam.backend.stop(steam)
	steam.started, steam.running = false, false
	steam.achievements = nil
}

@(private="file")
gameOrCurrent :: proc(game: ^Game) -> ^Game {
	return game != nil ? game : currentGame
}

@(private="file")
steamOf :: proc(game: ^Game) -> ^SteamState {
	g := gameOrCurrent(game)
	if g == nil || !g.steam.started do return nil
	return &g.steam
}

@(private="file")
steamCheckName :: proc(steam: ^SteamState, name: string) {
	if len(steam.achievements) == 0 do return
	for a in steam.achievements do if a.name == name do return
	log.warnf("Steam: no achievement named %s (Project Settings > Steam lists them)", name)
}

// The JSON the stub writes
@(private="file")
StubFile :: struct {
	unlocked: []string,
	stats: map[string]f64,
}

@(private="file")
stubStart :: proc(steam: ^SteamState) -> bool {
	steam.stub.unlocked = make(map[string]bool)
	steam.stub.stats = make(map[string]f64)
	data, ok := Platform_SaveRead(saveName(steam.game, "steam-stub"))
	if !ok do return true
	file: StubFile
	if err := json.unmarshal(data, &file, allocator = context.temp_allocator); err != nil {
		log.warnf("Steam (stub): couldn't read the saved achievements: %v", err)
		return true
	}
	for name in file.unlocked do steam.stub.unlocked[strings.clone(name)] = true
	for name, value in file.stats do steam.stub.stats[strings.clone(name)] = value
	return true
}

@(private="file")
stubStop :: proc(steam: ^SteamState) {
	if steam.stub.dirty do stubWrite(steam)
	for name in steam.stub.unlocked do delete(name)
	delete(steam.stub.unlocked)
	for name in steam.stub.stats do delete(name)
	delete(steam.stub.stats)
	steam.stub = {}
}

@(private="file")
stubWrite :: proc(steam: ^SteamState) -> bool {
	file := StubFile{stats = steam.stub.stats}
	names := make([dynamic]string, context.temp_allocator)
	for name in steam.stub.unlocked do append(&names, name)
	file.unlocked = names[:]
	data, err := json.marshal(file, {pretty = true, sort_maps_by_key = true}, context.temp_allocator)
	if err != nil do return false
	ok := Platform_SaveWrite(saveName(steam.game, "steam-stub"), data)
	if ok do steam.stub.dirty = false
	return ok
}

// A cloud file's save name; false for names with other characters
@(private="file")
stubCloudName :: proc(steam: ^SteamState, file: string) -> (string, bool) {
	if file == "" do return "", false
	for c in file {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'
		if !ok {
			log.warnf("Steam: a cloud file name takes letters, digits, '-', '_' and '.': %q", file)
			return "", false
		}
	}
	return saveName(steam.game, fmt.tprintf("steam-cloud-%s", file)), true
}
