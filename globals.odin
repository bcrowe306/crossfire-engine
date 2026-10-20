package engine

import "base:runtime"
import "core:log"
import sdl "vendor:sdl3"

/*
Global scripts: game-wide state and services that live for the whole run, across scenes
(score, lives, settings, a music manager, a HUD).

Any registered script can be global: project.xml lists the globals, in the order they start,
with their exported field values (the editor's Project Settings > Globals):

	<global script="GameState">
		<prop name="lives" value="3"/>
	</global>

When the game starts (`Game_LoadProject`) each global gets its struct (fields from those values:
every run starts from them, so Play always resets the game's state), then the scenes are built,
then the globals' `ready` runs in order. Any script reaches a global by its type:

	state := e.Global(GameState)
	state.score += 10

Hooks (all optional; `self.node` and `self.scene` are nil for globals, `self.game` is set):
- `ready`, `update` (every frame, before the scene's nodes), `destroy` (when the game ends)
- `sceneChanged(self, scene)`: the game switched scenes
- `draw(self, renderer)`: draws over the scene in screen space (not moved by the camera),
  after the scene, in the globals' order. Leave it out for globals that draw nothing; set
  `self.hidden` to skip it for a while
- `loaded(self)`: `Load_Game` just restored its fields (save.odin)

Globals are also what `Save_Game` saves: their state (fields that aren't exported, unless tagged
`save:"-"`, and exported ones tagged `save:""`: save.odin).
*/

// A global in project.xml: its script and field values
GlobalData :: struct {
	script: string,
	props: [dynamic]ScriptPropData,
}

// A running global (Game.globals)
GlobalInstance :: struct {
	info: ^ScriptInfo,
	data: rawptr,
}

/*
The game's global of type T (nil if the project has none).

Example:
	if state := e.Global(GameState); state != nil do state.score += 10
*/
Global :: proc($T: typeid, game: ^Game = nil) -> ^T {
	game := game != nil ? game : currentGame
	if game == nil do return nil
	for g in game.globals do if g.info.type == T do return cast(^T)g.data
	return nil
}

/*
Creates the project's globals, fields set, before the scenes are built (`Game_LoadProject`).
Unknown scripts are reported and left out.
*/
@(private)
Globals_Start :: proc(game: ^Game, globals: []GlobalData) {
	allocator := Game_GetAllocator(game)
	for g in globals {
		info := Script_Find(g.script)
		if info == nil {
			log.warnf("Global %s: no script with that name (is the project's scripts package built into this player?)", g.script)
			continue
		}
		duplicate := false
		for existing in game.globals do if existing.info == info do duplicate = true
		if duplicate {
			log.warnf("Global %s is listed twice; the first one is used", g.script)
			continue
		}
		memory, err := runtime.mem_alloc(info.size, info.align, allocator)
		if err != nil do continue
		self := raw_data(memory)
		(cast(^Script)self).game = game
		setFields(self, info.name, info.fields, g.props[:], allocator)
		append(&game.globals, GlobalInstance{info, self})
	}
}

// Runs the globals' `ready`, in order (after the scenes exist)
@(private)
Globals_Ready :: proc(game: ^Game) {
	for g in game.globals do if g.info.ready != nil do g.info.ready(g.data)
}

// Every frame, before the scene updates
@(private)
Globals_Update :: proc(game: ^Game, events: []sdl.Event, deltaTime: f64) {
	for g in game.globals do if g.info.update != nil do g.info.update(g.data, events, deltaTime)
}

// After the scene draws: globals with a `draw`, in screen space
@(private)
Globals_Draw :: proc(game: ^Game) {
	SetDrawState(TRANSFORM2D_IDENTITY)
	if game.renderer != nil do sdl.SetRenderDrawBlendMode(game.renderer, sdl.BLENDMODE_BLEND)
	for g in game.globals {
		if g.info.draw == nil || (cast(^Script)g.data).hidden do continue
		g.info.draw(g.data, game.renderer)
	}
	SetDrawState(TRANSFORM2D_IDENTITY)
}

// The game switched to another scene
@(private)
Globals_SceneChanged :: proc(game: ^Game, scene: ^Scene) {
	for g in game.globals do if g.info.sceneChanged != nil do g.info.sceneChanged(g.data, scene)
}

// The game ends: `destroy` hooks, in reverse order (their memory goes with the game's)
@(private)
Globals_Destroy :: proc(game: ^Game) {
	#reverse for g in game.globals do if g.info.destroy != nil do g.info.destroy(g.data)
	clear(&game.globals)
}
