/*
The Crossfire Engine: a 2D game engine on SDL3, with Box2D physics, and the runtime of the
Crossfire Editor's games.

Games are **scenes** of **nodes**. A node has a transform relative to its parent, a layer, a
tint and optional `update` and `draw` procedures; node kinds (sprites, labels, menus, cameras,
physics bodies, particle emitters, sound players, LDtk levels...) embed `Node` as their first
field. A **game** owns its scenes, switches between them and holds what lives as long as the
game: resources, input, mix buses, globals. The **application** owns the window and runs the
frame loop.

	Application   the window and its renderer, audio and text; the frame loop (app.odin)
	  Game        resolution and scaling, scenes by name, input, sound, globals (game.odin)
	    Scene     nodes, add and remove queues, the camera, physics, tweens (scene.odin)
	      Node    transform, parent and children, layer, visibility, hooks (node.odin)

Most games are made in the editor: scenes are XML files (project_format.odin) built at run time
(project_loader.odin), and game code is **scripts**, Odin structs attached to nodes
(script.odin). Code can make everything as well.

Example:
	package mygame

	import e "engine:."
	import sdl "vendor:sdl3"

	Ship :: struct {
		using node: e.Node,
		speed: f32,
	}

	main :: proc() {
		app: e.Application
		game := new(e.Game)
		game.size = {1280, 720}
		game.build = proc(game: ^e.Game) {
			scene := game->createScene("Space")
			ship := e.CreateNode(scene, Ship)
			ship.position = {640, 360}
			ship.speed = 300
			ship.update = proc(node: ^e.Node, _: []sdl.Event, dt: f64) {
				ship := cast(^Ship)node
				move := e.Input_GetVector("ui_left", "ui_right", "ui_up", "ui_down")
				ship.position += move * ship.speed * f32(dt)
			}
			ship.draw = proc(_: ^e.Node, renderer: ^sdl.Renderer) {
				// In the node's own space: (0, 0) is its position
				e.DrawCircle(renderer, {0, 0}, 16, {120, 200, 255, 255})
			}
			_ = game->switchScene("Space")
		}
		if !e.Application_Setup(&app, "Space", {1280, 720}) do return
		e.Application_Run(&app, game)
		// Destroys the game too
		e.Application_Cleanup(&app)
	}

Where things are:
- Drawing: primitives.odin (shapes, `DrawTexture`), text_primitives.odin, render_target.odin,
  layers.odin, transform.odin (the draw state), camera.odin, debug.odin (debug shapes, the
  overlay).
- Nodes: project_loader.odin (Sprite, AnimatedSprite), ui_label.odin, ui_menu.odin,
  particles.odin, audio_nodes.odin, ldtk_nodes.odin, timer.odin, ticker.odin.
- Motion: animation.odin, animation_player.odin, tween.odin, easing.odin.
- Physics: physics.odin (the world, queries, the character mover), physics_nodes.odin,
  physics_events.odin, physics_joints.odin, physics_debug.odin.
- Input: input.odin (state and actions), input_rebind.odin (rebinding, rumble).
- Game data: globals.odin, data.odin, save.odin, assets.odin, localization.odin.
- Running games: player.odin (the player program), pack.odin (games in one file), the
  platform layer (platform_native.odin, platform_web.odin; player_web.odin for browsers).

Memory: each node lives in its own arena, freed when it's removed (`Node_GetAllocator`); a
scene's and the game's shared data live in their arenas (`Scene_GetAllocator`,
`Game_GetAllocator`); `context.temp_allocator` is freed every frame.
*/
package engine
